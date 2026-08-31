const std = @import("std");
const builtin = @import("builtin");
const command_policy = @import("command_policy.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_args = @import("tool_args.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const types = @import("../shared/types.zig");
const test_builtin_tools = if (builtin.is_test)
    @import("../../builtins/tools.zig")
else
    struct {};

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;
const max_command_activity_bytes = 120;
const max_command_activity_source_bytes = max_command_activity_bytes * max_command_activity_bytes;
pub const max_auto_permission_reason_presentation_bytes: usize = 160;

pub const ToolActionInput = struct {
    tool_registry: tool_dispatch.Registry,
    call: ToolCall,
    workspace_root: []const u8 = "",
    display_target: ?[]const u8 = null,
    is_available_dynamic_mcp_tool: bool = false,
};

pub const ActionState = enum {
    active,
    completed,
    denied,
};

const ActionSeparator = enum {
    space,
    colon,
};

const ResolvedAction = struct {
    label: []const u8,
    value: []const u8,
    separator: ActionSeparator = .space,
};

pub const CommandActivity = struct {
    detail: []const u8,
};

fn projectCommandActivitySource(
    command: []const u8,
    workspace_root_input: []const u8,
    storage: *[max_command_activity_bytes + 1]u8,
) []const u8 {
    const display_command = stripNoopCurrentDirectoryPrefix(command);
    var workspace_root_end = workspace_root_input.len;
    while (workspace_root_end > 1 and workspace_root_input[workspace_root_end - 1] == '/') {
        workspace_root_end -= 1;
    }
    const workspace_root = workspace_root_input[0..workspace_root_end];
    const can_abbreviate_workspace = workspace_root.len > 1 and workspace_root[0] == '/';
    const source_limit = @min(display_command.len, max_command_activity_source_bytes);
    var source_index: usize = 0;
    var projected_len: usize = 0;
    var line_boundary_pending = false;

    while (source_index < source_limit) {
        const byte = display_command[source_index];
        if (byte == '\r' or byte == '\n') {
            line_boundary_pending = true;
            source_index += 1;
            continue;
        }
        if (line_boundary_pending and (byte == ' ' or byte == '\t')) {
            source_index += 1;
            continue;
        }
        if (line_boundary_pending) {
            line_boundary_pending = false;
            if (projected_len > 0) {
                storage[projected_len] = ' ';
                projected_len += 1;
                if (projected_len == storage.len) break;
            }
        }

        if (can_abbreviate_workspace and
            workspace_root.len <= source_limit - source_index and
            workspaceRootMatchesAt(display_command, workspace_root, source_index))
        {
            storage[projected_len] = '.';
            projected_len += 1;
            if (projected_len == storage.len) break;
            source_index += workspace_root.len;
            continue;
        }

        storage[projected_len] = byte;
        projected_len += 1;
        if (projected_len == storage.len) break;
        source_index += 1;
    }

    return storage[0..projected_len];
}

fn stripNoopCurrentDirectoryPrefix(command: []const u8) []const u8 {
    const prefix = "cd . &&";
    if (!std.mem.startsWith(u8, command, prefix)) return command;
    if (command.len == prefix.len or !std.ascii.isWhitespace(command[prefix.len])) return command;

    const remainder = std.mem.trimStart(u8, command[prefix.len..], " \t\r\n");
    return if (remainder.len > 0) remainder else command;
}

fn workspaceRootMatchesAt(command: []const u8, workspace_root: []const u8, index: usize) bool {
    if (!std.mem.startsWith(u8, command[index..], workspace_root)) return false;
    if (index > 0 and isPathTokenByte(command[index - 1])) return false;

    const next_index = index + workspace_root.len;
    if (next_index == command.len) return true;
    return command[next_index] == '/' or !isPathTokenByte(command[next_index]);
}

fn isPathTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '/', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatCommandPermissionLabel(
    alloc: Allocator,
    command: []const u8,
) ![]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const encoded = try text_utils.encodeTerminalSafe(
        scratch,
        command,
        max_command_activity_bytes,
    );
    const suffix = try commandApprovalLabelSuffix(scratch, "exec_command", command);
    return std.fmt.allocPrint(alloc, "exec_command {s}{s}", .{ encoded.bytes, suffix });
}

pub fn isAdvertisedDynamicMcpName(registry: tool_dispatch.Registry, name: []const u8, advertised: []const []const u8) bool {
    if (registry.lookup(name) != null) return false;
    for (advertised) |advertised_name| {
        if (std.mem.eql(u8, advertised_name, name)) return true;
    }
    return false;
}

/// The caller owns `detail` and must free it with `alloc`.
pub fn formatCommandActivity(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    workspace_root: []const u8,
    call: ToolCall,
) !?CommandActivity {
    var scratch_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch return null;
    if (!isCommandCall(registry, call)) return null;
    const command = tool_args.optionalStringArg(args, if (std.mem.eql(u8, call.name, "exec_command")) "cmd" else "command") orelse return null;
    var projected_storage: [max_command_activity_bytes + 1]u8 = undefined;
    const projected = projectCommandActivitySource(command, workspace_root, &projected_storage);
    const encoded = try text_utils.encodeTerminalSafe(scratch, projected, max_command_activity_bytes);
    return .{ .detail = try alloc.dupe(u8, encoded.bytes) };
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatPlainAction(alloc: Allocator, input: ToolActionInput) ![]const u8 {
    return formatPlainActionForState(alloc, input, .active, null);
}

/// Formats the same lifecycle state for ACP, noninteractive CLI, and child
/// sessions. The caller owns the returned allocation and must free it.
pub fn formatPlainActionForState(
    alloc: Allocator,
    input: ToolActionInput,
    state: ActionState,
    denied_label: ?[]const u8,
) ![]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const action = try resolveAction(scratch_state.allocator(), input, state, denied_label);
    return formatResolvedAction(alloc, action, false);
}

/// Formats the shared lifecycle state for the inline TUI transcript.
pub fn formatStyledActionForState(
    alloc: Allocator,
    input: ToolActionInput,
    state: ActionState,
    denied_label: ?[]const u8,
) ![]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const action = try resolveAction(scratch_state.allocator(), input, state, denied_label);
    return formatResolvedAction(alloc, action, true);
}

fn resolveAction(
    alloc: Allocator,
    input: ToolActionInput,
    state: ActionState,
    denied_label: ?[]const u8,
) !ResolvedAction {
    const call = input.call;
    if (file_mutation_contract.isToolName(call.name)) {
        const spec = input.tool_registry.lookup(call.name) orelse return fallbackAction(state, denied_label, call.name);
        return .{
            .label = lifecycleLabel(spec.action_label, spec.completed_action_label, state, denied_label),
            .value = input.display_target orelse spec.label_arg_default,
        };
    }

    if (try formatCommandActivity(alloc, input.tool_registry, input.workspace_root, call)) |activity| {
        return .{
            .label = lifecycleLabel("Running", "Ran", state, denied_label),
            .value = activity.detail,
        };
    }

    const spec = input.tool_registry.lookup(call.name) orelse {
        if (input.is_available_dynamic_mcp_tool) return .{
            .label = lifecycleLabel("Running MCP", "Ran MCP", state, denied_label),
            .value = call.name,
        };
        return fallbackAction(state, denied_label, call.name);
    };
    const args = tool_args.parseToolArgsObject(alloc, call.arguments_json) catch {
        return fallbackAction(state, denied_label, "tool call");
    };

    const presentation = tool_dispatch.presentationForArgs(spec.*, args);
    if (spec.executor_kind == .web_search) {
        return .{
            .label = lifecycleLabel(spec.action_label, spec.completed_action_label, state, denied_label),
            .value = try formatWebSearchActionDetail(alloc, args),
        };
    }
    if (try copyRenameLabel(alloc, call.name, args)) |value| {
        return .{
            .label = lifecycleLabel(presentation.action_label, presentation.completed_action_label, state, denied_label),
            .value = value,
        };
    }
    const value = input.display_target orelse
        try presentationValue(alloc, presentation, args) orelse
        presentation.label_arg_default;
    return .{
        .label = lifecycleLabel(presentation.action_label, presentation.completed_action_label, state, denied_label),
        .value = value,
    };
}

fn presentationValue(
    alloc: Allocator,
    presentation: tool_dispatch.CallPresentation,
    args: std.json.ObjectMap,
) !?[]const u8 {
    if (presentation.label_arg_kind != .session_id) {
        return tool_dispatch.presentationLabelValue(presentation, args);
    }
    const value = args.get("session_id") orelse return null;
    return switch (value) {
        .integer => |session_id| try std.fmt.allocPrint(alloc, "{d}", .{session_id}),
        .string => |session_id| session_id,
        else => null,
    };
}

fn fallbackAction(state: ActionState, denied_label: ?[]const u8, value: []const u8) ResolvedAction {
    return .{
        .label = lifecycleLabel("Working", "Completed", state, denied_label),
        .value = value,
        .separator = if (state == .active) .colon else .space,
    };
}

fn lifecycleLabel(active: []const u8, completed: []const u8, state: ActionState, denied_label: ?[]const u8) []const u8 {
    return switch (state) {
        .active => active,
        .completed => completed,
        .denied => denied_label orelse "Denied",
    };
}

fn formatResolvedAction(alloc: Allocator, action: ResolvedAction, styled: bool) ![]const u8 {
    const separator: []const u8 = switch (action.separator) {
        .space => " ",
        .colon => ": ",
    };
    if (styled) {
        return std.fmt.allocPrint(
            alloc,
            "● {s}\x1b[0m{s}\x1b[38;5;245m{s}\x1b[0m",
            .{ action.label, separator, action.value },
        );
    }
    return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ action.label, separator, action.value });
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatPermissionLabel(alloc: Allocator, registry: tool_dispatch.Registry, call: ToolCall) ![]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const args = tool_args.parseToolArgsObject(scratch, call.arguments_json) catch {
        return try alloc.dupe(u8, call.name);
    };
    if (isCommandCall(registry, call)) {
        const command = tool_args.optionalStringArg(args, if (std.mem.eql(u8, call.name, "exec_command")) "cmd" else "command") orelse
            return try alloc.dupe(u8, call.name);
        return formatCommandPermissionLabel(alloc, command);
    }
    const spec = registry.lookup(call.name) orelse return try alloc.dupe(u8, call.name);
    if (file_mutation_contract.isToolName(call.name)) {
        return std.fmt.allocPrint(
            alloc,
            "{s} {s}",
            .{ call.name, spec.label_arg_default },
        );
    }
    const value = tool_dispatch.toolLabelValue(spec.*, args) orelse return try alloc.dupe(u8, call.name);

    if (spec.label_arg_kind == .command or spec.label_arg_kind == .cmd) {
        const suffix = try commandApprovalLabelSuffix(scratch, call.name, value);
        const cwd_key: []const u8 = if (spec.label_arg_kind == .cmd) "workdir" else "cwd";
        if (tool_args.optionalStringArg(args, cwd_key)) |cwd| {
            return std.fmt.allocPrint(alloc, "{s} {s} @ {s}{s}", .{ call.name, value, cwd, suffix });
        }
        return std.fmt.allocPrint(alloc, "{s} {s}{s}", .{ call.name, value, suffix });
    }

    return std.fmt.allocPrint(alloc, "{s} {s}", .{ call.name, value });
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatWebSearchActionDetail(alloc: Allocator, args: std.json.ObjectMap) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var label_buf: [160]u8 = undefined;
    const query = tool_args.optionalStringArg(args, "query") orelse "web";
    try out.writer.writeAll(text_utils.clippedLabel(&label_buf, query, 120));
    try appendWebSearchDomains(&out.writer, "allowed", args.get("allowed_domains"));
    try appendWebSearchDomains(&out.writer, "blocked", args.get("blocked_domains"));
    return try out.toOwnedSlice();
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatWebSearchProgressPlain(alloc: Allocator, progress: types.WebSearchProgress) ![]u8 {
    var query_buf: [160]u8 = undefined;
    return switch (progress) {
        .query_started => |query| std.fmt.allocPrint(
            alloc,
            "Searching web {s}",
            .{text_utils.clippedLabel(&query_buf, query, 120)},
        ),
        .results_received => |entry| std.fmt.allocPrint(
            alloc,
            "Found {d} web result{s} for {s}",
            .{ entry.result_count, if (entry.result_count == 1) "" else "s", text_utils.clippedLabel(&query_buf, entry.query, 120) },
        ),
    };
}

/// The caller owns the returned allocation and must free it with `alloc`.
pub fn formatWebFetchProgressPlain(alloc: Allocator, progress: types.WebFetchProgress) ![]u8 {
    var url_buf: [types.WebFetchCompletion.max_url_len]u8 = undefined;
    return switch (progress) {
        .fetching => |url| std.fmt.allocPrint(alloc, "Fetching {s}", .{text_utils.clippedLabel(&url_buf, url, 96)}),
        .converting => |url| std.fmt.allocPrint(alloc, "Converting {s}", .{text_utils.clippedLabel(&url_buf, url, 96)}),
    };
}

fn appendWebSearchDomains(writer: *std.Io.Writer, label: []const u8, value: ?std.json.Value) !void {
    const array = value orelse return;
    if (array != .array or array.array.items.len == 0) return;
    try writer.print(" | {s}: ", .{label});
    var domain_buf: [64]u8 = undefined;
    const shown = @min(array.array.items.len, 3);
    for (array.array.items[0..shown], 0..) |item, index| {
        if (index > 0) try writer.writeAll(", ");
        if (item != .string) {
            try writer.writeAll("?");
            continue;
        }
        try writer.writeAll(text_utils.clippedLabel(&domain_buf, item.string, 48));
    }
    if (array.array.items.len > shown) try writer.print(" +{d}", .{array.array.items.len - shown});
}

fn commandApprovalLabelSuffix(alloc: Allocator, tool_name: []const u8, command: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, tool_name, "run_command") and
        !std.mem.eql(u8, tool_name, "exec_command")) return "";
    const risk = command_policy.command_risk_note_for(command);
    const safer = command_policy.command_safer_alternative_for(command);
    if (risk == null and safer == null) return "";
    const risk_text = if (risk) |note| stripNotePrefix(note) else null;
    if (risk_text) |note| {
        if (safer) |alternative| {
            return std.fmt.allocPrint(alloc, " (risk: {s}; {s})", .{ note, alternative });
        }
        return std.fmt.allocPrint(alloc, " (risk: {s})", .{note});
    }
    if (safer) |alternative| {
        return std.fmt.allocPrint(alloc, " ({s})", .{alternative});
    }
    return "";
}

fn stripNotePrefix(note: []const u8) []const u8 {
    const prefix = "note: ";
    if (std.mem.startsWith(u8, note, prefix)) return note[prefix.len..];
    return note;
}

fn isCommandCall(
    registry: tool_dispatch.Registry,
    call: ToolCall,
) bool {
    // Historical sessions retain their original tool name. Presentation may
    // interpret those records, but execution remains unavailable because the
    // registry no longer contains a `run_command` tool.
    if (std.mem.eql(u8, call.name, "run_command")) return true;
    const tool = registry.lookup(call.name) orelse return false;
    return tool.executor_kind == .exec_command;
}

fn copyRenameLabel(alloc: Allocator, tool_name: []const u8, args: std.json.ObjectMap) !?[]const u8 {
    if (std.mem.eql(u8, tool_name, "copy_file")) {
        const source = tool_args.optionalStringArg(args, "source") orelse return null;
        const destination = tool_args.optionalStringArg(args, "destination") orelse return null;
        return try std.fmt.allocPrint(alloc, "{s} -> {s}", .{ source, destination });
    }
    if (std.mem.eql(u8, tool_name, "rename_file")) {
        const old_path = tool_args.optionalStringArg(args, "old_path") orelse return null;
        const new_path = tool_args.optionalStringArg(args, "new_path") orelse return null;
        return try std.fmt.allocPrint(alloc, "{s} -> {s}", .{ old_path, new_path });
    }
    return null;
}

const test_web_search = blk: {
    var tool = test_builtin_tools.read_file;
    tool.name = "web_search";
    tool.model_schema.name = "web_search";
    tool.executor_kind = .web_search;
    tool.action_label = "Searching web";
    tool.completed_action_label = "Searched web";
    tool.label_arg_kind = .query;
    tool.label_arg_default = "web";
    break :blk tool;
};

const test_tools = [_]tool_dispatch.Tool{
    test_builtin_tools.read_file,
    test_builtin_tools.write_file,
    test_builtin_tools.edit_file,
    test_web_search,
    test_builtin_tools.exec_command,
    test_builtin_tools.write_stdin,
    test_builtin_tools.memory,
    test_builtin_tools.skill,
    test_builtin_tools.install_skill,
    test_builtin_tools.ask_user_question,
};
const test_tool_registry = tool_dispatch.Registry{ .tools = test_tools[0..] };
const custom_presentation_tool = blk: {
    var tool = test_builtin_tools.read_file;
    tool.name = "custom_presentation";
    tool.action_label = "Inspecting";
    tool.label_arg_kind = .name;
    tool.label_arg_default = "custom fallback";
    break :blk tool;
};
const custom_presentation_registry = tool_dispatch.Registry{ .tools = &.{custom_presentation_tool} };

test "tool presentation formats dynamic MCP availability distinctly" {
    const alloc = std.testing.allocator;
    const call: ToolCall = .{
        .id = "dynamic",
        .name = "mcp_lookup",
        .arguments_json = "{}",
    };

    const available = try formatPlainAction(alloc, .{
        .tool_registry = test_tool_registry,
        .call = call,
        .is_available_dynamic_mcp_tool = true,
    });
    defer alloc.free(available);
    try std.testing.expectEqualStrings("Running MCP mcp_lookup", available);

    const unavailable = try formatPlainAction(alloc, .{ .tool_registry = test_tool_registry, .call = call });
    defer alloc.free(unavailable);
    try std.testing.expectEqualStrings("Working: mcp_lookup", unavailable);
}

test "tool presentation reads labels from the supplied registry" {
    const alloc = std.testing.allocator;
    const label = try formatPlainAction(alloc, .{
        .tool_registry = custom_presentation_registry,
        .call = .{
            .id = "custom",
            .name = "custom_presentation",
            .arguments_json = "{\"name\":\"registry metadata\"}",
        },
    });
    defer alloc.free(label);

    try std.testing.expectEqualStrings("Inspecting registry metadata", label);
}

test "tool presentation formats plain web progress variants" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        text: []const u8,
        progress: union(enum) {
            search: types.WebSearchProgress,
            fetch: types.WebFetchProgress,
        },
    }{
        .{ .text = "Searching web current Zig release", .progress = .{ .search = .{ .query_started = "current Zig release" } } },
        .{ .text = "Found 1 web result for current Zig release", .progress = .{ .search = .{ .results_received = .{ .query = "current Zig release", .result_count = 1 } } } },
        .{ .text = "Fetching https://ziglang.org", .progress = .{ .fetch = .{ .fetching = "https://ziglang.org" } } },
        .{ .text = "Converting https://ziglang.org", .progress = .{ .fetch = .{ .converting = "https://ziglang.org" } } },
    };

    for (cases) |case| {
        const text = switch (case.progress) {
            .search => |progress| try formatWebSearchProgressPlain(alloc, progress),
            .fetch => |progress| try formatWebFetchProgressPlain(alloc, progress),
        };
        defer alloc.free(text);
        try std.testing.expectEqualStrings(case.text, text);
    }
}

test "run command activity projects line boundaries without changing other bytes" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        arguments_json: []const u8,
        expected: []const u8,
    }{
        .{
            .arguments_json = "{\"command\":\"cat <<'EOF'\\nline one\\nEOF\"}",
            .expected = "cat <<'EOF' line one EOF",
        },
        .{
            .arguments_json = "{\"command\":\"\\r\\n\\tprintf first\\r\\n    printf  second\\r\\t\\n\"}",
            .expected = "printf first printf  second",
        },
        .{
            .arguments_json = "{\"command\":\"printf  'literal \\\\x0a'\"}",
            .expected = "printf  'literal \\x0a'",
        },
        .{
            .arguments_json = "{\"command\":\"printf \\u0007\"}",
            .expected = "printf \\x07",
        },
    };

    for (cases) |case| {
        const activity = (try formatCommandActivity(alloc, test_tool_registry, "", .{
            .id = "projected_command",
            .name = "run_command",
            .arguments_json = case.arguments_json,
        })) orelse return error.TestExpectedEqual;
        defer alloc.free(activity.detail);

        try std.testing.expectEqualStrings(case.expected, activity.detail);
    }
}

test "run command activity abbreviates only active workspace paths" {
    const alloc = std.testing.allocator;
    const workspace_root = "/Users/example/workspace";
    const cases = [_]struct {
        arguments_json: []const u8,
        expected: []const u8,
    }{
        .{
            .arguments_json = "{\"command\":\"cd /Users/example/workspace/packages/cli && pwd\"}",
            .expected = "cd ./packages/cli && pwd",
        },
        .{
            .arguments_json = "{\"command\":\"printf '/Users/example/workspace'\"}",
            .expected = "printf '.'",
        },
        .{
            .arguments_json = "{\"command\":\"printf \\\"/Users/example/workspace/src/main.zig\\\"\"}",
            .expected = "printf \"./src/main.zig\"",
        },
        .{
            .arguments_json = "{\"command\":\"printf /Users/example/workspace /Users/example/workspace/src\"}",
            .expected = "printf . ./src",
        },
        .{
            .arguments_json = "{\"command\":\"cd /Users/example/workspace-other && pwd\"}",
            .expected = "cd /Users/example/workspace-other && pwd",
        },
        .{
            .arguments_json = "{\"command\":\"cd /Users/example/other && pwd\"}",
            .expected = "cd /Users/example/other && pwd",
        },
        .{
            .arguments_json = "{\"command\":\"cd /prefix/Users/example/workspace && pwd\"}",
            .expected = "cd /prefix/Users/example/workspace && pwd",
        },
    };

    for (cases) |case| {
        const call: ToolCall = .{
            .id = "workspace_command",
            .name = "run_command",
            .arguments_json = case.arguments_json,
        };
        const activity = (try formatCommandActivity(
            alloc,
            test_tool_registry,
            workspace_root ++ "/",
            call,
        )) orelse return error.TestExpectedEqual;
        defer alloc.free(activity.detail);
        try std.testing.expectEqualStrings(case.expected, activity.detail);
    }

    const permission = try formatPermissionLabel(alloc, test_tool_registry, .{
        .id = "raw_workspace_command",
        .name = "run_command",
        .arguments_json = "{\"command\":\"cd /Users/example/workspace/packages/cli && pwd\"}",
    });
    defer alloc.free(permission);
    try std.testing.expectEqualStrings(
        "exec_command cd /Users/example/workspace/packages/cli && pwd",
        permission,
    );
}

test "run command activity hides only a leading no-op current directory prefix" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        command: []const u8,
        expected: []const u8,
    }{
        .{ .command = "cd . && zig build", .expected = "zig build" },
        .{ .command = "cd . &&\n  zig build test", .expected = "zig build test" },
        .{ .command = "cd ./packages && pwd", .expected = "cd ./packages && pwd" },
        .{ .command = "cd .. && pwd", .expected = "cd .. && pwd" },
        .{ .command = "cd . || pwd", .expected = "cd . || pwd" },
        .{ .command = "printf 'cd . && pwd'", .expected = "printf 'cd . && pwd'" },
        .{ .command = "cd . &&", .expected = "cd . &&" },
    };

    for (cases) |case| {
        const arguments_json = try std.fmt.allocPrint(alloc, "{{\"command\":{f}}}", .{std.json.fmt(case.command, .{})});
        defer alloc.free(arguments_json);
        const activity = (try formatCommandActivity(alloc, test_tool_registry, "", .{
            .id = "current_directory_command",
            .name = "run_command",
            .arguments_json = arguments_json,
        })) orelse return error.TestExpectedEqual;
        defer alloc.free(activity.detail);

        try std.testing.expectEqualStrings(case.expected, activity.detail);
    }

    const permission = try formatPermissionLabel(alloc, test_tool_registry, .{
        .id = "raw_current_directory_command",
        .name = "run_command",
        .arguments_json = "{\"command\":\"cd . && zig build\"}",
    });
    defer alloc.free(permission);
    try std.testing.expectEqualStrings("exec_command cd . && zig build", permission);
}

test "tool presentation formats bounded web search action detail" {
    const alloc = std.testing.allocator;
    const label = try formatPlainAction(alloc, .{
        .tool_registry = test_tool_registry,
        .call = .{
            .id = "call_search",
            .name = "web_search",
            .arguments_json = "{\"query\":\"current Zig release\",\"blocked_domains\":[\"spam.example\",\"ads.example\"]}",
        },
    });
    defer alloc.free(label);
    try std.testing.expectEqualStrings("Searching web current Zig release | blocked: spam.example, ads.example", label);
}

test "tool presentation bounds a large multiline run command activity" {
    const alloc = std.testing.allocator;
    const arguments_json = "{\"command\":\"" ++ ("é\\r\\n" ** 20_000) ++ "\"}";
    const label = try formatPlainAction(alloc, .{
        .tool_registry = test_tool_registry,
        .call = .{
            .id = "large_command",
            .name = "run_command",
            .arguments_json = arguments_json,
        },
    });
    defer alloc.free(label);

    try std.testing.expect(label.len <= 128);
    try std.testing.expect(std.mem.findScalar(u8, label, '\r') == null);
    try std.testing.expect(std.mem.findScalar(u8, label, '\n') == null);
    try std.testing.expect(std.mem.find(u8, label, "\\x0a") == null);
    try std.testing.expect(std.mem.find(u8, label, "\\x0d") == null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(label));
    try std.testing.expect(std.mem.endsWith(u8, label, "..."));
}

test "tool presentation formats permission labels" {
    const alloc = std.testing.allocator;
    const cwd = try formatPermissionLabel(alloc, test_tool_registry, .{
        .id = "command",
        .name = "run_command",
        .arguments_json = "{\"command\":\"npm test\",\"cwd\":\"/tmp/fx\"}",
    });
    defer alloc.free(cwd);
    try std.testing.expectEqualStrings("exec_command npm test", cwd);

    const risk = try formatPermissionLabel(alloc, test_tool_registry, .{
        .id = "risk",
        .name = "run_command",
        .arguments_json = "{\"command\":\"git reset --hard\"}",
    });
    defer alloc.free(risk);
    try expectContains(risk, "risk: command may discard version-control state");
    try expectContains(risk, "safer: inspect git status first");
}

test "tool presentation preserves plain action fallbacks" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        call: ToolCall,
        expected: []const u8,
    }{
        .{ .call = .{ .id = "read", .name = "read_file", .arguments_json = "{\"path\":\"src/main.zig\"}" }, .expected = "Reading src/main.zig" },
        .{ .call = .{ .id = "command", .name = "run_command", .arguments_json = "{\"command\":\"zig build\"}" }, .expected = "Running zig build" },
        .{ .call = .{ .id = "ask", .name = "ask_user_question", .arguments_json = "{}" }, .expected = "Asking " },
        .{ .call = .{ .id = "skill", .name = "skill", .arguments_json = "{\"name\":\"workflow\"}" }, .expected = "Loading skill workflow" },
        .{ .call = .{ .id = "install", .name = "install_skill", .arguments_json = "{\"source\":\"example/agent-skills\",\"skill\":\"workflow\"}" }, .expected = "Installing skill example/agent-skills" },
        .{ .call = .{ .id = "copy", .name = "copy_file", .arguments_json = "{\"source\":\"src/a.zig\",\"destination\":\"src/b.zig\"}" }, .expected = "Copying src/a.zig -> src/b.zig" },
        .{ .call = .{ .id = "rename", .name = "rename_file", .arguments_json = "{\"old_path\":\"src/a.zig\",\"new_path\":\"src/b.zig\"}" }, .expected = "Renaming src/a.zig -> src/b.zig" },
        .{ .call = .{ .id = "unknown", .name = "unknown_tool", .arguments_json = "{}" }, .expected = "Working: unknown_tool" },
    };

    for (cases) |case| {
        const label = try formatPlainAction(alloc, .{ .tool_registry = test_tool_registry, .call = case.call });
        defer alloc.free(label);
        try std.testing.expectEqualStrings(case.expected, label);
    }
}

test "tool presentation shares Codex-style command lifecycle labels" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        call: ToolCall,
        active: []const u8,
        completed: []const u8,
    }{
        .{
            .call = .{ .id = "exec", .name = "exec_command", .arguments_json = "{\"cmd\":\"zig build\"}" },
            .active = "Running zig build",
            .completed = "Ran zig build",
        },
        .{
            .call = .{ .id = "poll", .name = "write_stdin", .arguments_json = "{\"session_id\":42}" },
            .active = "Waiting for 42",
            .completed = "Waited for 42",
        },
        .{
            .call = .{ .id = "input", .name = "write_stdin", .arguments_json = "{\"session_id\":42,\"chars\":\"yes\\n\"}" },
            .active = "Interacting with 42",
            .completed = "Interacted with 42",
        },
    };

    for (cases) |case| {
        const active = try formatPlainActionForState(
            alloc,
            .{ .tool_registry = test_tool_registry, .call = case.call },
            .active,
            null,
        );
        defer alloc.free(active);
        try std.testing.expectEqualStrings(case.active, active);

        const completed = try formatPlainActionForState(
            alloc,
            .{ .tool_registry = test_tool_registry, .call = case.call },
            .completed,
            null,
        );
        defer alloc.free(completed);
        try std.testing.expectEqualStrings(case.completed, completed);
    }
}

test "tool presentation frees all formatted output with a normal allocator" {
    const alloc = std.testing.allocator;

    const search = try formatPlainAction(alloc, .{
        .tool_registry = test_tool_registry,
        .call = .{
            .id = "search",
            .name = "web_search",
            .arguments_json = "{\"query\":\"current Zig release\",\"allowed_domains\":[\"ziglang.org\"]}",
        },
    });
    defer alloc.free(search);
    try std.testing.expectEqualStrings("Searching web current Zig release | allowed: ziglang.org", search);

    const provider_search = try formatPlainAction(alloc, .{
        .tool_registry = test_tool_registry,
        .call = .{
            .id = "provider_search",
            .name = "provider_search",
            .arguments_json = "{}",
            .provenance = .provider_executed,
        },
    });
    defer alloc.free(provider_search);
    try std.testing.expectEqualStrings("Working: provider_search", provider_search);

    const command = try formatPermissionLabel(alloc, test_tool_registry, .{
        .id = "command",
        .name = "run_command",
        .arguments_json = "{\"command\":\"git reset --hard\"}",
    });
    defer alloc.free(command);
    try expectContains(command, "risk: command may discard version-control state");

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"query\":\"current Zig release\",\"blocked_domains\":[\"spam.example\"]}", .{});
    defer parsed.deinit();
    const detail = try formatWebSearchActionDetail(alloc, parsed.value.object);
    defer alloc.free(detail);
    try std.testing.expectEqualStrings("current Zig release | blocked: spam.example", detail);
}

fn expectContains(text: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.find(u8, text, needle) != null);
}
