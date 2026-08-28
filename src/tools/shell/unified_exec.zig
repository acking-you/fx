const std = @import("std");
const builtin = @import("builtin");
const command_admission = @import("../../core/permissions/command_admission.zig");
const command_contract = @import("../../core/execution/command_contract.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const shell_resolver = @import("../../core/terminal/shell_resolver.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const types = @import("../../core/shared/types.zig");
const unified_exec = @import("../../core/execution/unified_exec.zig");

const Allocator = std.mem.Allocator;

pub const ExecInput = struct {
    cmd: []u8,
    workdir: []u8,
    shell: []u8,
    login: bool = false,
    tty: bool = false,
    yield_time_ms: u64 = 10_000,
    max_output_tokens: ?u64 = null,

    fn deinit(self: *ExecInput, alloc: Allocator) void {
        alloc.free(self.cmd);
        alloc.free(self.workdir);
        alloc.free(self.shell);
        self.* = undefined;
    }
};

pub const WriteInput = struct {
    session_id: u64,
    chars: []u8,
    yield_time_ms: u64 = 250,
    max_output_tokens: ?u64 = null,

    fn deinit(self: *WriteInput, alloc: Allocator) void {
        alloc.free(self.chars);
        self.* = undefined;
    }
};

fn deinitExec(ptr: *anyopaque, alloc: Allocator) void {
    const input: *ExecInput = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn deinitWrite(ptr: *anyopaque, alloc: Allocator) void {
    const input: *WriteInput = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn decodeExec(ctx: tool_dispatch.DispatchContext, raw: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, raw, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "exec_command arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .failure = try ctx.allocator.dupe(u8, "exec_command arguments must be an object") };
    const cmd_value = parsed.value.object.get("cmd") orelse return .{ .failure = try ctx.allocator.dupe(u8, "exec_command requires string field \"cmd\"") };
    if (cmd_value != .string) return .{ .failure = try ctx.allocator.dupe(u8, "exec_command field \"cmd\" must be a string") };
    if (parsed.value.object.get("workdir")) |value| if (value != .string)
        return .{ .failure = try ctx.allocator.dupe(u8, "exec_command field \"workdir\" must be a string") };
    if (parsed.value.object.get("shell")) |value| if (value != .string)
        return .{ .failure = try ctx.allocator.dupe(u8, "exec_command field \"shell\" must be a string") };
    if (parsed.value.object.get("login")) |value| if (value != .bool)
        return .{ .failure = try ctx.allocator.dupe(u8, "exec_command field \"login\" must be a boolean") };
    if (parsed.value.object.get("tty")) |value| if (value != .bool)
        return .{ .failure = try ctx.allocator.dupe(u8, "exec_command field \"tty\" must be a boolean") };
    const yield_time_ms = tool_args.optionalIntArg(parsed.value.object, "yield_time_ms");
    if (yield_time_ms) |value| if (value < 0) return .{ .failure = try ctx.allocator.dupe(u8, "yield_time_ms must not be negative") };
    const max_output_tokens = tool_args.optionalIntArg(parsed.value.object, "max_output_tokens");
    if (max_output_tokens) |value| if (value < 0) return .{ .failure = try ctx.allocator.dupe(u8, "max_output_tokens must not be negative") };
    const input = try ctx.allocator.create(ExecInput);
    errdefer ctx.allocator.destroy(input);
    var shell_buffer: [4096]u8 = undefined;
    const default_shell = shell_resolver.configuredOrDefaultLoginShellInto(&shell_buffer);
    input.* = .{
        .cmd = try ctx.allocator.dupe(u8, cmd_value.string),
        .workdir = try ctx.allocator.dupe(u8, tool_args.optionalStringArg(parsed.value.object, "workdir") orelse "."),
        .shell = try ctx.allocator.dupe(u8, tool_args.optionalStringArg(parsed.value.object, "shell") orelse default_shell),
        .login = tool_args.optionalBoolArg(parsed.value.object, "login") orelse false,
        .tty = tool_args.optionalBoolArg(parsed.value.object, "tty") orelse false,
    };
    errdefer input.deinit(ctx.allocator);
    if (yield_time_ms) |value| input.yield_time_ms = @intCast(value);
    if (max_output_tokens) |value| input.max_output_tokens = @intCast(value);
    return .{ .input = .{ .ptr = input, .deinit_fn = deinitExec } };
}

pub fn decodeWrite(ctx: tool_dispatch.DispatchContext, raw: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, raw, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "write_stdin arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .failure = try ctx.allocator.dupe(u8, "write_stdin arguments must be an object") };
    const id = parsed.value.object.get("session_id") orelse return .{ .failure = try ctx.allocator.dupe(u8, "write_stdin requires integer field \"session_id\"") };
    if (id != .integer or id.integer < 1) return .{ .failure = try ctx.allocator.dupe(u8, "write_stdin field \"session_id\" must be a positive integer") };
    const session_id = std.math.cast(u64, id.integer) orelse return .{ .failure = try ctx.allocator.dupe(u8, "write_stdin session_id is out of range") };
    if (parsed.value.object.get("chars")) |value| if (value != .string)
        return .{ .failure = try ctx.allocator.dupe(u8, "write_stdin field \"chars\" must be a string") };
    const chars = tool_args.optionalStringArg(parsed.value.object, "chars") orelse "";
    const yield_time_ms = tool_args.optionalIntArg(parsed.value.object, "yield_time_ms");
    if (yield_time_ms) |value| if (value < 0) return .{ .failure = try ctx.allocator.dupe(u8, "yield_time_ms must not be negative") };
    const max_output_tokens = tool_args.optionalIntArg(parsed.value.object, "max_output_tokens");
    if (max_output_tokens) |value| if (value < 0) return .{ .failure = try ctx.allocator.dupe(u8, "max_output_tokens must not be negative") };
    const input = try ctx.allocator.create(WriteInput);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .session_id = session_id,
        .chars = try ctx.allocator.dupe(u8, chars),
    };
    errdefer input.deinit(ctx.allocator);
    if (yield_time_ms) |value| input.yield_time_ms = @intCast(value);
    if (max_output_tokens) |value| input.max_output_tokens = @intCast(value);
    return .{ .input = .{ .ptr = input, .deinit_fn = deinitWrite } };
}

pub fn validateExec(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(ExecInput);
    if (std.mem.trim(u8, input.cmd, " \t\r\n").len == 0) return try ctx.allocator.dupe(u8, "exec_command field \"cmd\" must not be empty");
    if (std.mem.trim(u8, input.shell, " \t\r\n").len == 0) return try ctx.allocator.dupe(u8, "exec_command field \"shell\" must not be empty");
    if (!shell_resolver.isSupportedShell(input.shell)) return try ctx.allocator.dupe(u8, "exec_command field \"shell\" must be an absolute bash or zsh path");
    if (input.tty) return try ctx.allocator.dupe(u8, "exec_command tty=true is unavailable on this host; omit tty");
    return null;
}

pub fn validateWrite(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn callExec(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(ExecInput);
    const manager = ctx.unified_exec orelse return .{ .failure = try ctx.allocator.dupe(u8, "exec_command is unavailable on this host") };
    const cwd = pathing.resolveWorkspaceOrExternalPath(ctx.allocator, ctx.workspace_root, input.workdir) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "exec_command working directory is invalid: {s}", .{@errorName(err)}) };
    };
    defer ctx.allocator.free(cwd);
    const command_context: command_admission.CommandContext = .{
        .command = input.cmd,
        .resolved_cwd = cwd,
        .background = false,
        .target_os = builtin.os.tag,
        .environment = .{ .user = input.shell },
    };
    const fingerprint = switch (ctx.execution_authority orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "exec_command requires command execution authority") };
    }) {
        .run_command => |authority| switch (authority) {
            .direct_only => |value| value,
            .shell_allowed => |value| value.fingerprint,
        },
        else => return .{ .failure = try ctx.allocator.dupe(u8, "exec_command received invalid execution authority") },
    };
    if (!fingerprint.matches(command_context)) {
        return .{ .failure = try ctx.allocator.dupe(u8, "exec_command execution authority does not match the requested command") };
    }
    var result = manager.exec(ctx.allocator, .{
        .command = input.cmd,
        .cwd = cwd,
        .shell = input.shell,
        .login = input.login,
        .yield_time_ms = input.yield_time_ms,
        .max_output_tokens = input.max_output_tokens,
        .command_artifact_capability = ctx.session_child_capability,
        .command_artifact_dir = ctx.command_artifact_dir,
        .command_artifact_threshold = ctx.max_command_output_bytes,
    }) catch |err| return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "exec_command failed: {s}", .{@errorName(err)}) };
    defer result.deinit(ctx.allocator);
    reportResultMemory(ctx, result) catch return error.OutOfMemory;
    if (ctx.command_result_json_sink) |sink| {
        sink.* = commandResultJson(ctx.allocator, input.cmd, cwd, result) catch return error.OutOfMemory;
    }
    const body = formatResult(ctx.allocator, result) catch return error.OutOfMemory;
    return if (result.status == .exited and
        ((result.exit_code orelse 0) != 0 or result.signal != null))
        .{ .failure = body }
    else
        .{ .success = body };
}

pub fn callWrite(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(WriteInput);
    const manager = ctx.unified_exec orelse return .{ .failure = try ctx.allocator.dupe(u8, "write_stdin is unavailable on this host") };
    var result = manager.writeStdin(ctx.allocator, .{
        .process_id = input.session_id,
        .chars = input.chars,
        .yield_time_ms = input.yield_time_ms,
        .max_output_tokens = input.max_output_tokens,
    }) catch |err| return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "write_stdin failed: {s}", .{@errorName(err)}) };
    defer result.deinit(ctx.allocator);
    reportResultMemory(ctx, result) catch return error.OutOfMemory;
    if (ctx.command_result_json_sink) |sink| {
        sink.* = commandResultJson(
            ctx.allocator,
            result.command orelse "",
            result.cwd orelse "",
            result,
        ) catch return error.OutOfMemory;
    }
    const body = formatResult(ctx.allocator, result) catch return error.OutOfMemory;
    return if (result.status == .exited and
        ((result.exit_code orelse 0) != 0 or result.signal != null))
        .{ .failure = body }
    else
        .{ .success = body };
}

fn reportResultMemory(ctx: tool_dispatch.DispatchContext, result: unified_exec.Manager.Result) !void {
    var memory: types.ToolResultMemory = .{};
    if (result.output_file) |path| {
        memory.command_artifact_handle = try ctx.allocator.dupe(u8, std.fs.path.basename(path));
    }
    if (result.status == .exited) {
        if (result.signal) |signal| {
            memory.command_process_presentation = .{ .signal = signal };
        } else if (result.exit_code) |code| {
            memory.command_process_presentation = .{ .exit_code = code };
        }
    }
    if (memory.command_artifact_handle != null or
        memory.command_process_presentation != null)
    {
        tool_dispatch.reportToolResultMemory(ctx, memory);
    }
}

fn commandResultJson(alloc: Allocator, command: []const u8, cwd: []const u8, result: unified_exec.Manager.Result) ![]u8 {
    var foreground = command_contract.ForegroundCommandResult{
        .command = command,
        .cwd = cwd,
        .exit_code = if (result.exit_code) |code| @as(i64, code) else null,
        .signal = if (result.signal) |signal| @as(u32, signal) else null,
        .duration_ms = @intFromFloat(result.wall_time_seconds * 1000.0),
        .stdout_bytes = result.stdout_bytes,
        .stderr_bytes = result.stderr_bytes,
        .truncated = result.stdout_truncated or result.stderr_truncated,
    };
    if (result.output_file) |path| foreground.output_file = path;
    if (result.stdout_file) |path| foreground.stdout_file = path;
    if (result.stderr_file) |path| foreground.stderr_file = path;
    return (command_contract.CommandResult{ .foreground = foreground }).toJson(alloc);
}

fn formatResult(alloc: Allocator, result: unified_exec.Manager.Result) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeByte('{');
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(alloc);
    try combined.appendSlice(alloc, result.stdout);
    if (result.stderr.len > 0) {
        if (combined.items.len > 0) try combined.append(alloc, '\n');
        try combined.appendSlice(alloc, result.stderr);
    }
    try out.writer.print("\"wall_time_seconds\":{d:.3},\"output\":", .{result.wall_time_seconds});
    try std.json.Stringify.value(combined.items, .{}, &out.writer);
    if (result.exit_code) |code| try out.writer.print(",\"exit_code\":{d}", .{code});
    if (result.signal) |signal| try out.writer.print(",\"signal\":{d}", .{signal});
    if (result.process_id) |id| try out.writer.print(",\"session_id\":{d}", .{id});
    const original_token_count = (result.stdout_bytes +| result.stderr_bytes +| 3) / 4;
    try out.writer.print(",\"original_token_count\":{d}}}", .{original_token_count});
    return out.toOwnedSlice();
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}
pub fn irreversible(_: tool_dispatch.ToolInput) bool {
    return true;
}

test "unified exec tool formats a completed result" {
    var result: unified_exec.Manager.Result = .{
        .status = .exited,
        .exit_code = 0,
        .stdout = try std.testing.allocator.dupe(u8, "ok"),
        .stderr = try std.testing.allocator.dupe(u8, ""),
        .stdout_bytes = 2,
        .stderr_bytes = 0,
        .stdout_truncated = false,
        .stderr_truncated = false,
    };
    defer result.deinit(std.testing.allocator);
    const body = try formatResult(std.testing.allocator, result);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"exit_code\":0") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"output\":\"ok\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"wall_time_seconds\":0.000") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"original_token_count\":1") != null);
}
