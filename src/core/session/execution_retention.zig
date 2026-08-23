const std = @import("std");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// Full before/after file bodies make a recently completed edit expandable in
/// the transcript after resume. They are presentation data, not model context,
/// so keep them under a strict durable budget while always retaining the
/// bounded diff preview and lifecycle identity.
pub const FileBodyPolicy = struct {
    max_presentation_bytes: usize,
    max_execution_bytes: usize,
};

pub const durable_file_body_policy: FileBodyPolicy = .{
    .max_presentation_bytes = 512 * 1024,
    .max_execution_bytes = 1024 * 1024,
};

/// Applies newest-first retention and frees bodies that fall outside `policy`.
/// The caller retains ownership of the rest of `execution`.
pub fn boundFilePresentationBodies(
    alloc: Allocator,
    execution: *types.ExecutionMemory,
    policy: FileBodyPolicy,
) void {
    var retained_bytes: usize = 0;
    var step_index = execution.tool_steps.len;
    while (step_index > 0) {
        step_index -= 1;
        const step = &execution.tool_steps[step_index];
        var result_index = step.tool_results.len;
        while (result_index > 0) {
            result_index -= 1;
            const result = &step.tool_results[result_index];
            const presentation = if (result.committed_file_presentation) |*value|
                value
            else
                continue;
            const body_bytes = presentationBodyBytes(presentation.*);
            if (body_bytes == 0) continue;

            const exceeds_item_budget = body_bytes > policy.max_presentation_bytes;
            const exceeds_execution_budget = body_bytes >
                policy.max_execution_bytes -| @min(retained_bytes, policy.max_execution_bytes);
            if (exceeds_item_budget or exceeds_execution_budget) {
                dropBodies(alloc, presentation);
                continue;
            }
            retained_bytes += body_bytes;
        }
    }
}

fn retainedFilePresentationBodyBytes(execution: types.ExecutionMemory) usize {
    var total: usize = 0;
    for (execution.tool_steps) |step| {
        for (step.tool_results) |result| {
            const presentation = result.committed_file_presentation orelse continue;
            total +|= presentationBodyBytes(presentation);
        }
    }
    return total;
}

fn presentationBodyBytes(presentation: types.CommittedFilePresentation) usize {
    const previous_bytes = if (presentation.previous_content) |content| content.len else 0;
    const after_bytes = if (presentation.after_content) |content| content.len else 0;
    return previous_bytes +| after_bytes;
}

fn dropBodies(alloc: Allocator, presentation: *types.CommittedFilePresentation) void {
    if (presentation.previous_content) |content| alloc.free(@constCast(content));
    if (presentation.after_content) |content| alloc.free(@constCast(content));
    presentation.previous_content = null;
    presentation.after_content = null;
}

fn ownedPresentation(
    alloc: Allocator,
    call_id: []const u8,
    body_bytes: usize,
) !types.CommittedFilePresentation {
    const previous = try alloc.alloc(u8, body_bytes / 2);
    errdefer alloc.free(previous);
    const after = try alloc.alloc(u8, body_bytes - previous.len);
    errdefer alloc.free(after);
    @memset(previous, 'a');
    @memset(after, 'b');
    const path = try alloc.dupe(u8, "src/example.zig");
    errdefer alloc.free(path);
    const lifecycle_call_id = try alloc.dupe(u8, call_id);
    errdefer alloc.free(lifecycle_call_id);
    return .{
        .path = path,
        .kind = .edited,
        .lines = &.{},
        .additions = 1,
        .deletions = 1,
        .truncated = true,
        .previous_content = previous,
        .after_content = after,
        .lifecycle_id = .{
            .turn_id = 1,
            .call_id = lifecycle_call_id,
        },
    };
}

fn ownedResult(
    alloc: Allocator,
    call_id: []const u8,
    body_bytes: usize,
) !types.PersistedToolResult {
    const tool_call_id = try alloc.dupe(u8, call_id);
    errdefer alloc.free(tool_call_id);
    const tool_name = try alloc.dupe(u8, "edit_file");
    errdefer alloc.free(tool_name);
    const output = try alloc.dupe(u8, "edited");
    errdefer alloc.free(output);
    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .status = .success,
        .output = output,
        .output_bytes = 6,
        .stored_output_bytes = 6,
        .committed_file_presentation = try ownedPresentation(alloc, call_id, body_bytes),
    };
}

test "durable file bodies retain newest presentations within a global budget" {
    const alloc = std.testing.allocator;
    const results = try alloc.alloc(types.PersistedToolResult, 3);
    results[0] = try ownedResult(alloc, "old", 400);
    results[1] = try ownedResult(alloc, "middle", 400);
    results[2] = try ownedResult(alloc, "new", 400);
    const steps = try alloc.alloc(types.ToolExecutionStep, 1);
    steps[0] = .{ .tool_results = results };
    var execution: types.ExecutionMemory = .{ .tool_steps = steps };
    defer types.freeExecutionMemory(alloc, execution);

    boundFilePresentationBodies(alloc, &execution, .{
        .max_presentation_bytes = 500,
        .max_execution_bytes = 800,
    });

    try std.testing.expect(results[0].committed_file_presentation.?.previous_content == null);
    try std.testing.expect(results[0].committed_file_presentation.?.after_content == null);
    try std.testing.expect(results[1].committed_file_presentation.?.previous_content != null);
    try std.testing.expect(results[2].committed_file_presentation.?.after_content != null);
    try std.testing.expectEqual(@as(usize, 800), retainedFilePresentationBodyBytes(execution));
}

test "one oversized presentation cannot consume the execution budget" {
    const alloc = std.testing.allocator;
    const results = try alloc.alloc(types.PersistedToolResult, 2);
    results[0] = try ownedResult(alloc, "oversized", 700);
    results[1] = try ownedResult(alloc, "recent", 300);
    const steps = try alloc.alloc(types.ToolExecutionStep, 1);
    steps[0] = .{ .tool_results = results };
    var execution: types.ExecutionMemory = .{ .tool_steps = steps };
    defer types.freeExecutionMemory(alloc, execution);

    boundFilePresentationBodies(alloc, &execution, .{
        .max_presentation_bytes = 500,
        .max_execution_bytes = 1000,
    });

    try std.testing.expect(results[0].committed_file_presentation.?.previous_content == null);
    try std.testing.expect(results[1].committed_file_presentation.?.previous_content != null);
    try std.testing.expectEqual(@as(usize, 300), retainedFilePresentationBodyBytes(execution));
}
