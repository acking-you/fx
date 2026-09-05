const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../shared/types.zig");
const command_effect = @import("../../shell_command/command_effect.zig");
const command_lex = @import("../../shell_command/command_lex.zig");

pub const warning = "Repeated inspections are returning the same evidence. Use the results already collected to perform the remaining work or explain the concrete blocker. Another sustained window of unchanged inspections will stop this turn.";
pub const stopped = "Stopped after repeated inspections kept returning the same evidence despite a progress reminder. The work and tool results are saved; continue with a follow-up prompt to choose the next action.";

/// Bounded observation window, not a task-length or identical-command limit.
/// New evidence counts as progress. Writes and unknown actions clear the
/// window. Failed observations and process polling do not count toward it.
pub const Guard = struct {
    fingerprints: [256]u64 = @splat(0),
    used: usize = 0,
    cursor: usize = 0,
    batches: usize = 0,
    repeated_batches: usize = 0,
    inspection_kinds: u8 = 0,
    warned: bool = false,

    pub const Decision = enum { proceed, remind, stop };

    pub fn reset(self: *Guard) void {
        self.* = .{};
    }

    pub fn observeBatch(self: *Guard, alloc: std.mem.Allocator, messages: []const types.ChatMessage) !Decision {
        var observed = false;
        var novel = false;
        for (messages) |message| {
            if (message.is_turn_input or message.permission_feedback) {
                self.reset();
                return .proceed;
            }
            for (message.tool_calls) |call| {
                if (!try isInspection(alloc, call)) {
                    self.reset();
                    return .proceed;
                }
                var output: ?[]const u8 = null;
                for (messages) |result| {
                    if (result.role != .tool or !std.mem.eql(u8, result.tool_call_id orelse "", call.id)) continue;
                    if (result.tool_result_status != .success) {
                        return .proceed;
                    }
                    output = result.content;
                    break;
                }
                const content = output orelse {
                    self.reset();
                    return .proceed;
                };
                self.inspection_kinds |= inspectionKind(call.name);
                var hash = std.hash.Wyhash.init(0);
                hash.update(call.name);
                if (std.mem.eql(u8, call.name, "exec_command")) {
                    // Exclude process/chunk IDs and timing from evidence.
                    var parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch null;
                    defer if (parsed) |*value| value.deinit();
                    const value = if (parsed) |value| value.value else null;
                    const text = if (value != null and value.? == .object) value.?.object.get("output") else null;
                    if (value != null and value.? == .object and value.?.object.contains("session_id")) return .proceed;
                    hash.update(if (text != null and text.? == .string) text.?.string else content);
                } else if (std.mem.eql(u8, call.name, "glob_files") or std.mem.eql(u8, call.name, "grep_files")) {
                    // Search headings repeat the query. Different queries with
                    // the same matches do not establish new workspace evidence.
                    const first_line = std.mem.findScalar(u8, content, '\n');
                    hash.update(if (std.mem.startsWith(u8, content, "[glob]") or std.mem.startsWith(u8, content, "[grep]"))
                        if (first_line) |end| content[end + 1 ..] else ""
                    else
                        content);
                } else {
                    hash.update(call.arguments_json);
                    hash.update(content);
                }
                const fingerprint = hash.final();
                observed = true;
                if (std.mem.findScalar(u64, self.fingerprints[0..self.used], fingerprint) == null) {
                    novel = true;
                    self.fingerprints[self.cursor] = fingerprint;
                    self.cursor = (self.cursor + 1) % self.fingerprints.len;
                    self.used = @min(self.used + 1, self.fingerprints.len);
                }
            }
        }
        if (!observed) return .proceed;
        self.batches += 1;
        if (!novel) self.repeated_batches += 1;
        if (self.batches < 64) return .proceed;
        // One repeatedly observed resource may be an intentional poll. Require
        // sustained reconnaissance through multiple inspection capabilities.
        const stuck = self.repeated_batches >= 40 and @popCount(self.inspection_kinds) >= 2;
        self.batches = 0;
        self.repeated_batches = 0;
        self.inspection_kinds = 0;
        if (!stuck) {
            self.warned = false;
            return .proceed;
        }
        if (self.warned) return .stop;
        self.warned = true;
        return .remind;
    }
};

fn inspectionKind(name: []const u8) u8 {
    if (std.mem.eql(u8, name, "read_file")) return 1;
    if (std.mem.eql(u8, name, "glob_files") or std.mem.eql(u8, name, "list_files")) return 2;
    if (std.mem.eql(u8, name, "grep_files")) return 4;
    if (std.mem.eql(u8, name, "exec_command")) return 8;
    return 0;
}

fn isInspection(alloc: std.mem.Allocator, call: types.ToolCall) !bool {
    for ([_][]const u8{ "read_file", "glob_files", "grep_files", "list_files", "update_plan", "skill" }) |name| {
        if (std.mem.eql(u8, call.name, name)) return true;
    }
    if (!std.mem.eql(u8, call.name, "exec_command")) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, call.arguments_json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const command = parsed.value.object.get("cmd") orelse return false;
    if (command != .string) return false;
    // Recognize quoted literals and lists of observational commands.
    // All unfamiliar shell syntax stays outside this guard.
    const command_text = try std.mem.replaceOwned(u8, alloc, command.string, "2>/dev/null", "");
    defer alloc.free(command_text);
    var quote: ?u8 = null;
    var start: usize = 0;
    var index: usize = 0;
    while (index < command_text.len) : (index += 1) {
        const byte = command_text[index];
        if (byte == '\\' or byte == '`' or byte == '$') return false;
        if (quote) |delimiter| {
            if (byte == delimiter) quote = null;
        } else if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == ';' or ((byte == '&' or byte == '|') and index + 1 < command_text.len and command_text[index + 1] == byte)) {
            if (!try readOnlySegment(alloc, command_text[start..index])) return false;
            if (byte != ';') index += 1;
            start = index + 1;
        }
    }
    return quote == null and try readOnlySegment(alloc, command_text[start..]);
}

fn readOnlySegment(alloc: std.mem.Allocator, command: []const u8) !bool {
    var plan = try command_effect.plan(alloc, command, ".", false, builtin.os.tag);
    defer plan.deinit(alloc);
    if (plan == .direct_read_only) return true;
    const pipelines = command_lex.pipe_segments(alloc, command) catch return false;
    defer alloc.free(pipelines);
    if (pipelines.len > 1) {
        for (pipelines) |segment| if (!try readOnlySegment(alloc, segment.text)) return false;
        return true;
    }
    var quote: ?u8 = null;
    for (command) |byte| {
        if (quote) |delimiter| {
            if (byte == delimiter) quote = null;
        } else if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (std.mem.findScalar(u8, ";<>|&\n", byte) != null) return false;
    }
    var argv = command_lex.tokenize_argv(alloc, command) catch return false;
    defer argv.deinit(alloc);
    if (argv.tokens.len == 0) return false;
    if (std.mem.eql(u8, argv.tokens[0].value, "echo")) return true;
    for ([_][]const u8{ "head", "tail", "cat", "wc", "ls", "pwd" }) |name| {
        if (!std.mem.eql(u8, argv.tokens[0].value, name)) continue;
        if (std.mem.eql(u8, name, "tail")) {
            for (argv.tokens[1..]) |token| {
                if (std.mem.eql(u8, token.value, "-f") or std.mem.eql(u8, token.value, "-F") or
                    std.mem.startsWith(u8, token.value, "--follow")) return false;
            }
        }
        return true;
    }
    if (std.mem.eql(u8, argv.tokens[0].value, "rg")) {
        for (argv.tokens[1..]) |token| {
            if (std.mem.startsWith(u8, token.value, "--pre") or
                std.mem.startsWith(u8, token.value, "--hostname-bin")) return false;
        }
        return true;
    }
    if (std.mem.eql(u8, argv.tokens[0].value, "find")) {
        var index: usize = 1;
        while (index < argv.tokens.len) : (index += 1) {
            const arg = argv.tokens[index].value;
            if (!std.mem.startsWith(u8, arg, "-")) continue;
            const takes_value = for ([_][]const u8{ "-name", "-iname", "-path", "-ipath", "-maxdepth", "-mindepth", "-type" }) |flag| {
                if (std.mem.eql(u8, arg, flag)) break true;
            } else false;
            if (takes_value) {
                index += 1;
                if (index >= argv.tokens.len) return false;
                continue;
            }
            if (!std.mem.eql(u8, arg, "-o") and !std.mem.eql(u8, arg, "-a") and
                !std.mem.eql(u8, arg, "-print") and !std.mem.eql(u8, arg, "-print0")) return false;
        }
        return true;
    }
    if (argv.tokens.len >= 3 and std.mem.eql(u8, argv.tokens[0].value, "gh")) {
        const family = argv.tokens[1].value;
        if (!std.mem.eql(u8, family, "pr") and !std.mem.eql(u8, family, "issue") and
            !std.mem.eql(u8, family, "run")) return false;
        const action = argv.tokens[2].value;
        return std.mem.eql(u8, action, "view") or std.mem.eql(u8, action, "list") or std.mem.eql(u8, action, "status");
    }
    if (argv.tokens.len < 2 or !std.mem.eql(u8, argv.tokens[0].value, "git")) return false;
    const subcommand = argv.tokens[1].value;
    // These commands inspect repository state. This classification is only a
    // progress signal: execution still passes through the permission owner.
    for (argv.tokens[2..]) |token| {
        if (std.mem.startsWith(u8, token.value, "--output") or
            std.mem.eql(u8, token.value, "--ext-diff") or
            std.mem.startsWith(u8, token.value, "--exec")) return false;
    }
    for ([_][]const u8{ "status", "diff", "log", "show", "rev-parse", "ls-files", "ls-tree" }) |name| {
        if (std.mem.eql(u8, subcommand, name)) return true;
    }
    if (std.mem.eql(u8, subcommand, "stash"))
        return argv.tokens.len == 3 and std.mem.eql(u8, argv.tokens[2].value, "list");
    if (std.mem.eql(u8, subcommand, "remote"))
        return argv.tokens.len == 3 and std.mem.eql(u8, argv.tokens[2].value, "-v");
    if (std.mem.eql(u8, subcommand, "branch")) {
        for (argv.tokens[2..]) |token| {
            const allowed = for ([_][]const u8{ "-v", "-vv", "-a", "-r", "--list", "--show-current", "--no-color" }) |flag| {
                if (std.mem.eql(u8, flag, token.value)) break true;
            } else false;
            if (!allowed) return false;
        }
        return true;
    }
    return false;
}

test "progress guard reminds then stops sustained unchanged inspection windows" {
    var guard: Guard = .{};
    const calls = [_]types.ToolCall{
        .{ .id = "read", .name = "read_file", .arguments_json = "{}" },
        .{ .id = "search", .name = "grep_files", .arguments_json = "{}" },
    };
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "read", .content = "unchanged", .tool_result_status = .success },
        .{ .role = .tool, .tool_call_id = "search", .content = "unchanged", .tool_result_status = .success },
    };
    for (0..128) |index| {
        const result = try guard.observeBatch(std.testing.allocator, &messages);
        try std.testing.expectEqual(if (index == 63) Guard.Decision.remind else if (index == 127) Guard.Decision.stop else Guard.Decision.proceed, result);
    }
}

test "progress guard permits long useful reads failures polling and repeated tests" {
    var guard: Guard = .{};
    var calls = [_]types.ToolCall{.{ .id = "read", .name = "read_file", .arguments_json = "{}" }};
    var messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "read", .content = "", .tool_result_status = .success },
    };
    var buf: [32]u8 = undefined;
    for (0..1024) |index| {
        messages[1].content = try std.fmt.bufPrint(&buf, "evidence {d}", .{index});
        try std.testing.expectEqual(Guard.Decision.proceed, try guard.observeBatch(std.testing.allocator, &messages));
    }
    for ([_][]const u8{ "write_stdin", "write_file", "exec_command" }) |name| {
        calls[0].name = name;
        calls[0].arguments_json = "{\"cmd\":\"zig build test\"}";
        for (0..256) |_| try std.testing.expectEqual(Guard.Decision.proceed, try guard.observeBatch(std.testing.allocator, &messages));
    }
    calls[0].name = "read_file";
    for (0..256) |_| try std.testing.expectEqual(Guard.Decision.proceed, try guard.observeBatch(std.testing.allocator, &messages));
    messages[1].tool_result_status = .failure;
    for (0..256) |_| try std.testing.expectEqual(Guard.Decision.proceed, try guard.observeBatch(std.testing.allocator, &messages));
}

test "progress guard permits mixed inspections that keep discovering evidence" {
    var guard: Guard = .{};
    const calls = [_]types.ToolCall{
        .{ .id = "read", .name = "read_file", .arguments_json = "{}" },
        .{ .id = "search", .name = "grep_files", .arguments_json = "{}" },
    };
    var messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "read", .content = "", .tool_result_status = .success },
        .{ .role = .tool, .tool_call_id = "search", .content = "unchanged", .tool_result_status = .success },
    };
    var buf: [32]u8 = undefined;
    for (0..1024) |index| {
        messages[1].content = try std.fmt.bufPrint(&buf, "new evidence {d}", .{index});
        try std.testing.expectEqual(Guard.Decision.proceed, try guard.observeBatch(std.testing.allocator, &messages));
    }
}

test "progress guard recognizes incident git inspection lists but excludes arbitrary shell" {
    for ([_][]const u8{ "{\"cmd\":\"git status --short && echo '---' && git log --oneline -15 && git diff --stat\"}", "{\"cmd\":\"rg --files\"}", "{\"cmd\":\"git branch -vv | head -20\"}" }) |args| {
        try std.testing.expect(try isInspection(std.testing.allocator, .{ .id = "x", .name = "exec_command", .arguments_json = args }));
    }
    try std.testing.expect(!try isInspection(std.testing.allocator, .{ .id = "x", .name = "exec_command", .arguments_json = "{\"cmd\":\"git status && zig build test\"}" }));
}

test "progress guard replay saved execution fixture" {
    const io_mod = @import("../../shared/io.zig");
    const codec = @import("../../session/session_codec.zig");
    const alloc = std.testing.allocator;
    var environment = try std.testing.environ.createMap(alloc);
    defer environment.deinit();
    const path = environment.get("FX_PROGRESS_GUARD_FIXTURE") orelse return error.SkipZigTest;
    var file = try std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, 32 * 1024 * 1024);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    var checkpoint = try codec.parseRecoveryCheckpoint(alloc, parsed.value.object.get("recovery_checkpoint").?);
    defer checkpoint.deinit(alloc);
    var guard: Guard = .{};
    for (checkpoint.execution.tool_steps, 0..) |step, index| {
        const messages = try alloc.alloc(types.ChatMessage, 1 + step.tool_results.len);
        defer alloc.free(messages);
        messages[0] = .{ .role = .assistant, .tool_calls = step.tool_calls };
        for (step.tool_results, messages[1..]) |result, *message| message.* = .{
            .role = .tool,
            .tool_call_id = result.tool_call_id,
            .tool_name = result.tool_name,
            .tool_result_status = result.status,
            .content = result.output,
        };
        const decision = try guard.observeBatch(alloc, messages);
        if (decision != .proceed) std.debug.print("progress replay step={d} decision={t}\n", .{ index + 1, decision });
        if (decision == .stop) return;
    }
    return error.InspectionLoopNotDetected;
}
