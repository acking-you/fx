const std = @import("std");
const lexical_relevance = @import("../../core/shared/lexical_relevance.zig");
const result_store = @import("../../core/session/result_store.zig");
const capability_retrieval = @import("../../core/tooling/capability_retrieval.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const skill_search = @import("../skills/skill_search.zig");

const Allocator = std.mem.Allocator;

const Input = struct {
    query: []u8,
    prepared: lexical_relevance.PreparedQuery,

    fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.query);
        self.* = undefined;
    }

    fn request(self: *const Input) capability_retrieval.Request {
        return .{
            .query = &self.prepared,
            .limit = capability_retrieval.default_limit,
            .relevance_policy = .intent,
        };
    }
};

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(ctx.allocator, "capability_search arguments must be valid JSON"),
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return failure(ctx.allocator, "capability_search arguments must be an object");
    }
    const query_value = parsed.value.object.get("query") orelse
        return failure(ctx.allocator, "capability_search field \"query\" is required");
    if (query_value != .string) {
        return failure(ctx.allocator, "capability_search field \"query\" must be a string");
    }
    if (query_value.string.len == 0) {
        return failure(ctx.allocator, "capability_search field \"query\" must not be empty");
    }
    if (query_value.string.len > lexical_relevance.max_query_bytes) {
        return failure(ctx.allocator, "capability_search query must not exceed 4096 bytes");
    }

    const query = try ctx.allocator.dupe(u8, query_value.string);
    errdefer ctx.allocator.free(query);
    const prepared = lexical_relevance.prepare(query) catch |err| switch (err) {
        error.QueryTooLong => unreachable,
        error.TooManyTokens => {
            const result = try failure(
                ctx.allocator,
                "capability_search query must not exceed 64 tokens",
            );
            ctx.allocator.free(query);
            return result;
        },
    };
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .query = query, .prepared = prepared };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(
    _: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn presentation(_: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    return null;
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const output_cap = @min(
        ctx.max_tool_result_bytes,
        result_store.large_result_threshold_bytes,
    );
    const output = skill_search.searchRequest(ctx, input.request(), output_cap) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try std.fmt.allocPrint(
            ctx.allocator,
            "capability_search skill search failed: {s}",
            .{@errorName(err)},
        ) },
    };
    return .{ .success = output };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn failure(alloc: Allocator, message: []const u8) Allocator.Error!tool_dispatch.DecodeResult {
    return .{ .failure = try alloc.dupe(u8, message) };
}

test "capability search accepts a bounded skill query" {
    const decoded = try decode(.{
        .allocator = std.testing.allocator,
        .workspace_root = ".",
    }, "{\"query\":\"review a document\"}");
    try std.testing.expect(decoded == .input);
    const erased = decoded.input;
    defer erased.deinit(std.testing.allocator);
    const input = erased.as(Input);
    try std.testing.expectEqualStrings("review a document", input.query);
}
