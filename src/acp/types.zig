const std = @import("std");
const build_options = @import("build_options");
const jsonrpc = @import("jsonrpc.zig");
const core_types = @import("../core/shared/types.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;
const writeJsonStr = jsonrpc.writeJsonStr;

pub const protocol_version: u32 = 1;

pub fn writeModelRecoveryInfoUpdate(
    writer: *std.Io.Writer,
    status: ?core_types.RouteRecoveryStatus,
    durable: bool,
) !void {
    try writer.writeAll("{\"sessionUpdate\":\"session_info_update\",\"_meta\":{\"fx\":{\"modelResponseRecovery\":");
    const recovery = status orelse {
        try writer.writeAll("null}}}");
        return;
    };
    try writer.writeAll("{\"state\":");
    try writeJsonStr(
        if (recovery.isRecovered())
            "recovered"
        else if (recovery.kind == .terminal_provider_error)
            "paused"
        else
            "active",
        writer,
    );
    try writer.writeAll(",\"kind\":");
    try writeJsonStr(@tagName(recovery.kind), writer);
    if (recovery.cause) |cause| {
        try writer.writeAll(",\"cause\":");
        try writeJsonStr(@tagName(cause), writer);
    }
    if (recovery.action) |action| {
        try writer.writeAll(",\"action\":");
        try writeJsonStr(@tagName(action), writer);
    }
    if (recovery.required_action != .none) {
        try writer.writeAll(",\"requiredAction\":");
        try writeJsonStr(@tagName(recovery.required_action), writer);
    }
    const reported_attempt = recovery.reportedAttempt();
    if (reported_attempt != 0) {
        try writer.print(",\"attempt\":{d}", .{reported_attempt});
    }
    if (recovery.attempt_limit != 0) {
        try writer.print(",\"attemptLimit\":{d}", .{recovery.attempt_limit});
    }
    if (recovery.delay_seconds != 0) {
        try writer.print(",\"delaySeconds\":{d}", .{recovery.delay_seconds});
    }
    try writer.print(",\"durable\":{s},\"message\":", .{if (durable) "true" else "false"});
    var label_buf: [core_types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
    try writeJsonStr(recovery.label(&label_buf), writer);
    try writer.writeAll("}}}}");
}

pub const StopReason = enum {
    end_turn,
    max_output_tokens,
    max_model_turns,
    refused,
    cancelled,

    pub fn jsonString(self: StopReason) []const u8 {
        return switch (self) {
            .end_turn => "end_turn",
            .max_output_tokens => "max_output_tokens",
            .max_model_turns => "max_model_turns",
            .refused => "refused",
            .cancelled => "cancelled",
        };
    }
};

pub const ToolCallKind = enum {
    read,
    edit,
    delete,
    move,
    search,
    execute,
    think,
    fetch,
    other,

    pub fn jsonString(self: ToolCallKind) []const u8 {
        return switch (self) {
            .read => "read",
            .edit => "edit",
            .delete => "delete",
            .move => "move",
            .search => "search",
            .execute => "execute",
            .think => "think",
            .fetch => "fetch",
            .other => "other",
        };
    }
};

pub const ToolCallStatus = enum {
    pending,
    in_progress,
    completed,
    failed,

    pub fn jsonString(self: ToolCallStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
            .failed => "failed",
        };
    }
};

pub fn writeSessionUpdate(w: *std.Io.Writer, session_id: []const u8, update_json: []const u8) !void {
    try w.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, w);
    try w.writeAll(",\"update\":");
    try w.writeAll(update_json);
    try w.writeAll("}");
}

pub fn writeAgentMessageChunk(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":");
    try writeJsonStr(text, w);
    try w.writeAll("}}");
}

pub fn writeAgentThoughtChunk(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":");
    try writeJsonStr(text, w);
    try w.writeAll("}}");
}

pub fn writeUserMessageChunk(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"user_message_chunk\",\"content\":{\"type\":\"text\",\"text\":");
    try writeJsonStr(text, w);
    try w.writeAll("}}");
}

/// Publishes the complete replacement plan using ACP's native plan update.
/// Clients replace their current checklist when this notification arrives.
pub fn writePlanUpdate(
    w: *std.Io.Writer,
    explanation: ?[]const u8,
    plan: []const tool_dispatch.PlanStep,
) !void {
    try w.writeAll("{\"sessionUpdate\":\"plan\",\"entries\":[");
    for (plan, 0..) |item, index| {
        if (index > 0) try w.writeByte(',');
        try w.writeAll("{\"content\":");
        try writeJsonStr(item.step, w);
        try w.writeAll(",\"priority\":\"medium\",\"status\":");
        try writeJsonStr(@tagName(item.status), w);
        try w.writeByte('}');
    }
    try w.writeByte(']');
    if (explanation) |text| {
        try w.writeAll(",\"_meta\":{\"fx\":{\"explanation\":");
        try writeJsonStr(text, w);
        try w.writeAll("}}");
    }
    try w.writeByte('}');
}

pub fn writeToolCall(
    w: *std.Io.Writer,
    tool_call_id: []const u8,
    title: []const u8,
    kind: ToolCallKind,
    status: ToolCallStatus,
    raw_input_json: ?[]const u8,
) !void {
    try w.writeAll("{\"sessionUpdate\":\"tool_call\",\"toolCallId\":");
    try writeJsonStr(tool_call_id, w);
    try w.writeAll(",\"title\":");
    try writeJsonStr(title, w);
    try w.writeAll(",\"kind\":");
    try writeJsonStr(kind.jsonString(), w);
    try w.writeAll(",\"status\":");
    try writeJsonStr(status.jsonString(), w);
    if (raw_input_json) |json| {
        try w.writeAll(",\"rawInput\":");
        try w.writeAll(json);
    }
    try w.writeAll("}");
}

pub fn writeToolCallUpdate(w: *std.Io.Writer, tool_call_id: []const u8, status: ToolCallStatus, content_text: ?[]const u8) !void {
    try writeToolCallUpdateFields(w, tool_call_id, status, null, content_text, null);
}

pub fn writeToolCallTerminalUpdate(
    w: *std.Io.Writer,
    tool_call_id: []const u8,
    status: ToolCallStatus,
    title: ?[]const u8,
    content_text: ?[]const u8,
    command_result_json: ?[]const u8,
) !void {
    try writeToolCallUpdateFields(
        w,
        tool_call_id,
        status,
        title,
        content_text,
        command_result_json,
    );
}

fn writeToolCallUpdateFields(
    w: *std.Io.Writer,
    tool_call_id: []const u8,
    status: ToolCallStatus,
    title: ?[]const u8,
    content_text: ?[]const u8,
    command_result_json: ?[]const u8,
) !void {
    try w.writeAll("{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":");
    try writeJsonStr(tool_call_id, w);
    if (title) |value| {
        try w.writeAll(",\"title\":");
        try writeJsonStr(value, w);
    }
    try w.writeAll(",\"status\":");
    try writeJsonStr(status.jsonString(), w);
    if (content_text) |text| {
        try w.writeAll(",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":");
        try writeJsonStr(text, w);
        try w.writeAll("}}]");
    }
    if (command_result_json) |json| {
        try w.writeAll(",\"command_result\":");
        try w.writeAll(json);
    }
    if (content_text != null or command_result_json != null) {
        try w.writeAll(",\"rawOutput\":");
        if (command_result_json) |json| {
            try w.writeAll("{\"output\":");
            if (content_text) |text| {
                try writeJsonStr(text, w);
            } else {
                try w.writeAll("null");
            }
            try w.writeAll(",\"commandResult\":");
            try w.writeAll(json);
            try w.writeByte('}');
        } else {
            try writeJsonStr(content_text.?, w);
        }
    }
    try w.writeAll("}");
}

pub fn writeCommandOutputUpdate(
    w: *std.Io.Writer,
    tool_call_id: []const u8,
    stream: []const u8,
    chunk: []const u8,
    aggregated_output: []const u8,
    truncated: bool,
) !void {
    try w.writeAll("{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":");
    try writeJsonStr(tool_call_id, w);
    try w.writeAll(",\"status\":\"in_progress\",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":");
    try writeJsonStr(aggregated_output, w);
    try w.writeAll("}}],\"rawOutput\":{\"stream\":");
    try writeJsonStr(stream, w);
    try w.writeAll(",\"chunk\":");
    try writeJsonStr(chunk, w);
    try w.writeAll(",\"aggregatedOutput\":");
    try writeJsonStr(aggregated_output, w);
    try w.writeAll(",\"truncated\":");
    try w.writeAll(if (truncated) "true" else "false");
    try w.writeAll("}}");
}

pub const InitializeOptions = struct {
    image_capable: bool = true,
    unified_exec_capable: bool = true,
    provider_control_capable: bool = true,
};

pub fn writeInitializeResponse(w: *std.Io.Writer) !void {
    return writeInitializeResponseWithOptions(w, .{});
}

pub fn writeInitializeResponseWithOptions(
    w: *std.Io.Writer,
    options: InitializeOptions,
) !void {
    try w.writeAll("{\"protocolVersion\":");
    try w.print("{d}", .{protocol_version});
    try w.writeAll(",\"agentCapabilities\":{");
    try w.writeAll("\"loadSession\":true,");
    try w.writeAll("\"promptCapabilities\":{\"image\":");
    try w.writeAll(if (options.image_capable) "true" else "false");
    try w.writeAll(",\"audio\":false,\"embeddedContext\":true},");
    try w.writeAll("\"mcpCapabilities\":{\"http\":true,\"sse\":true},");
    try w.writeAll("\"sessionCapabilities\":{\"list\":{},\"resume\":{},\"close\":{}}");
    try w.writeAll("},\"agentInfo\":{\"name\":\"fx\",\"title\":\"fx\",\"version\":");
    try writeJsonStr(build_options.app_version, w);
    try w.writeAll("},");
    try w.writeAll("\"authMethods\":[],");
    try w.writeAll("\"_meta\":{\"fx\":{");
    try w.writeAll("\"turnSteer\":true,\"turnStatus\":true,");
    try w.writeAll("\"backgroundTerminals\":true,\"processStatusCommand\":\"/ps\",\"toolModes\":{\"bashFirst\":true},\"planUpdates\":true");
    if (options.unified_exec_capable) {
        try w.writeAll(",\"unifiedExec\":{\"writeStdin\":true,\"kill\":true}");
    }
    if (options.provider_control_capable) {
        try w.writeAll(",\"providerControl\":{\"switch\":true,\"login\":true,\"setup\":true,\"configureByok\":true,\"usage\":true}");
    }
    try w.writeAll("}}}");
}

pub fn writePromptResponse(w: *std.Io.Writer, reason: StopReason) !void {
    try w.writeAll("{\"stopReason\":");
    try writeJsonStr(reason.jsonString(), w);
    try w.writeAll("}");
}

pub fn writeAvailableCommandsUpdate(w: *std.Io.Writer, commands_json: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"available_commands_update\",\"availableCommands\":");
    try w.writeAll(commands_json);
    try w.writeAll("}");
}

test "writeAgentMessageChunk produces valid json" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeAgentMessageChunk(&out.writer, "Hello world");
    const expected = "{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"Hello world\"}}";
    try std.testing.expectEqualStrings(expected, out.writer.buffered());
}

test "writeAgentThoughtChunk produces valid json" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeAgentThoughtChunk(&out.writer, "plan the change");
    const expected = "{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"plan the change\"}}";
    try std.testing.expectEqualStrings(expected, out.writer.buffered());
}

test "writePlanUpdate produces a native ACP checklist update" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const steps = [_]tool_dispatch.PlanStep{
        .{ .step = @constCast("inspect"), .status = .in_progress },
        .{ .step = @constCast("verify"), .status = .completed },
    };
    try writePlanUpdate(&out.writer, "keep the root request visible", &steps);
    try std.testing.expectEqualStrings(
        "{\"sessionUpdate\":\"plan\",\"entries\":[{\"content\":\"inspect\",\"priority\":\"medium\",\"status\":\"in_progress\"},{\"content\":\"verify\",\"priority\":\"medium\",\"status\":\"completed\"}],\"_meta\":{\"fx\":{\"explanation\":\"keep the root request visible\"}}}",
        out.writer.buffered(),
    );
}

test "writeToolCall produces valid json" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeToolCall(
        &out.writer,
        "call_001",
        "Reading file",
        .read,
        .pending,
        "{\"path\":\"src/main.zig\"}",
    );
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"toolCallId\":\"call_001\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"kind\":\"read\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"rawInput\":{\"path\":\"src/main.zig\"}") != null);
}

test "writePromptResponse produces valid json" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writePromptResponse(&out.writer, .end_turn);
    try std.testing.expectEqualStrings("{\"stopReason\":\"end_turn\"}", out.writer.buffered());
}

test "StopReason jsonString values" {
    try std.testing.expectEqualStrings("end_turn", StopReason.end_turn.jsonString());
    try std.testing.expectEqualStrings("cancelled", StopReason.cancelled.jsonString());
    try std.testing.expectEqualStrings("max_output_tokens", StopReason.max_output_tokens.jsonString());
}

test "ToolCallKind jsonString values" {
    try std.testing.expectEqualStrings("read", ToolCallKind.read.jsonString());
    try std.testing.expectEqualStrings("edit", ToolCallKind.edit.jsonString());
    try std.testing.expectEqualStrings("execute", ToolCallKind.execute.jsonString());
    try std.testing.expectEqualStrings("search", ToolCallKind.search.jsonString());
    try std.testing.expectEqualStrings("other", ToolCallKind.other.jsonString());
}

test "ToolCallStatus jsonString values" {
    try std.testing.expectEqualStrings("pending", ToolCallStatus.pending.jsonString());
    try std.testing.expectEqualStrings("in_progress", ToolCallStatus.in_progress.jsonString());
    try std.testing.expectEqualStrings("completed", ToolCallStatus.completed.jsonString());
    try std.testing.expectEqualStrings("failed", ToolCallStatus.failed.jsonString());
}

test "writeToolCallUpdate with content" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeToolCallUpdate(&out.writer, "call_002", .completed, "File written successfully");
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"tool_call_update\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"completed\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "File written successfully") != null);
}

test "writeToolCallUpdate can include structured command result" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeToolCallTerminalUpdate(
        &out.writer,
        "call_002",
        .completed,
        null,
        "exit_code=0\n<stdout>\nok\n</stdout>\n",
        "{\"kind\":\"foreground\",\"command\":\"printf ok\",\"cwd\":\"/tmp\",\"exit_code\":0,\"signal\":null,\"timed_out\":false,\"stdout_bytes\":2,\"stderr_bytes\":0,\"truncated\":false}",
    );
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.writer.buffered(), .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("tool_call_update", parsed.value.object.get("sessionUpdate").?.string);
    const command_result = parsed.value.object.get("command_result").?.object;
    try std.testing.expectEqualStrings("foreground", command_result.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 0), command_result.get("exit_code").?.integer);
    try std.testing.expect(parsed.value.object.get("content") != null);
    const raw_output = parsed.value.object.get("rawOutput").?.object;
    try std.testing.expectEqualStrings("printf ok", raw_output.get("commandResult").?.object.get("command").?.string);
}

test "writeCommandOutputUpdate preserves stream and accumulated preview" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeCommandOutputUpdate(
        &out.writer,
        "call_exec",
        "stderr",
        "warning\n",
        "ready\nwarning\n",
        false,
    );
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.writer.buffered(), .{});
    defer parsed.deinit();
    const raw_output = parsed.value.object.get("rawOutput").?.object;
    try std.testing.expectEqualStrings("stderr", raw_output.get("stream").?.string);
    try std.testing.expectEqualStrings("warning\n", raw_output.get("chunk").?.string);
    try std.testing.expectEqualStrings("ready\nwarning\n", raw_output.get("aggregatedOutput").?.string);
    try std.testing.expectEqualStrings(
        "ready\nwarning\n",
        parsed.value.object.get("content").?.array.items[0].object.get("content").?.object.get("text").?.string,
    );
}

test "writeToolCallUpdate without content" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeToolCallUpdate(&out.writer, "call_003", .in_progress, null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"in_progress\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "content") == null);
}

test "writeToolCallTerminalUpdate combines presentation and result" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeToolCallTerminalUpdate(
        &out.writer,
        "call_exec",
        .completed,
        "Ran zig build",
        "build succeeded",
        "{\"kind\":\"foreground\",\"exit_code\":0}",
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("tool_call_update", parsed.value.object.get("sessionUpdate").?.string);
    try std.testing.expectEqualStrings("call_exec", parsed.value.object.get("toolCallId").?.string);
    try std.testing.expectEqualStrings("completed", parsed.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("Ran zig build", parsed.value.object.get("title").?.string);
    try std.testing.expectEqualStrings(
        "build succeeded",
        parsed.value.object.get("content").?.array.items[0].object.get("content").?.object.get("text").?.string,
    );
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("command_result").?.object.get("exit_code").?.integer);
}

test "writeInitializeResponse contains required fields" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeInitializeResponse(&out.writer);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.writer.buffered(), .{});
    defer parsed.deinit();

    const agent_capabilities = parsed.value.object.get("agentCapabilities").?.object;
    const mcp_capabilities = agent_capabilities.get("mcpCapabilities").?.object;
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"protocolVersion\":1") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"loadSession\":true") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"name\":\"fx\"") != null);
    try std.testing.expectEqualStrings(
        build_options.app_version,
        parsed.value.object.get("agentInfo").?.object.get("version").?.string,
    );
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"image\":true") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"list\":{}") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"resume\":{}") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"close\":{}") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"providerControl\":") != null);
    try std.testing.expect(mcp_capabilities.get("http").?.bool);
    try std.testing.expect(mcp_capabilities.get("sse").?.bool);
    const fx_meta = parsed.value.object.get("_meta").?.object.get("fx").?.object;
    try std.testing.expect(fx_meta.get("turnSteer").?.bool);
    try std.testing.expect(fx_meta.get("turnStatus").?.bool);
    try std.testing.expect(fx_meta.get("backgroundTerminals").?.bool);
    try std.testing.expect(fx_meta.get("planUpdates").?.bool);
    try std.testing.expectEqualStrings("/ps", fx_meta.get("processStatusCommand").?.string);
    try std.testing.expect(fx_meta.get("toolModes").?.object.get("bashFirst").?.bool);
    const unified_exec = fx_meta.get("unifiedExec").?.object;
    try std.testing.expect(unified_exec.get("writeStdin").?.bool);
    try std.testing.expect(unified_exec.get("kill").?.bool);
}

test "writeUserMessageChunk produces valid json" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeUserMessageChunk(&out.writer, "User says hello");
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"user_message_chunk\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "User says hello") != null);
}

test "writeSessionUpdate wraps update with sessionId" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeSessionUpdate(&out.writer, "sess_123", "{\"sessionUpdate\":\"test\"}");
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"sessionId\":\"sess_123\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"sessionUpdate\":\"test\"") != null);
}

test "model recovery info update is structured and clearable" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeModelRecoveryInfoUpdate(&out.writer, .{
        .kind = .terminal_provider_error,
        .failed_attempt = 4,
        .attempt_limit = 10,
        .cause = .system_resumed,
        .action = .paused,
        .required_action = .continue_later,
        .delay_seconds = 4,
        .diagnostic = core_types.ModelFailureDiagnostic.init("ConnectionResetByPeer"),
    }, true);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"state\":\"paused\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"cause\":\"system_resumed\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"requiredAction\":\"continue_later\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"attempt\":4") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"delaySeconds\":4") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"durable\":true") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "ConnectionResetByPeer") != null);

    out.writer.end = 0;
    try writeModelRecoveryInfoUpdate(&out.writer, .{
        .kind = .auto_recovered,
        .succeeded_attempt = 5,
        .attempt_limit = 10,
    }, true);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"state\":\"recovered\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"attempt\":5") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "ConnectionResetByPeer") == null);

    out.writer.end = 0;
    try writeModelRecoveryInfoUpdate(&out.writer, null, false);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"modelResponseRecovery\":null") != null);
}
