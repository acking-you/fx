const std = @import("std");

const model_capabilities = @import("../../config/model_capabilities.zig");
const provider_route = @import("../../gateway/provider_route.zig");
const responses_compaction_binding = @import("../../gateway/responses_compaction_binding.zig");
const responses_compaction_provider = @import("../../gateway/responses_compaction_provider.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const types = @import("../../shared/types.zig");

const Allocator = std.mem.Allocator;

const local_summary_max_bytes: usize = 16 * 1024;
const local_summary_max_messages: usize = 24;
const local_summary_max_message_bytes: usize = 2 * 1024;
const remote_compaction_truncated_tool_output =
    "[Tool output truncated before remote context compaction to fit the model context window.]";

pub const Request = struct {
    provider: ?responses_compaction_provider.Provider,
    credential_source: ?types.CredentialSource,
    credential: []const u8,
    account_id: ?[]const u8,
    session_id: ?[]const u8,
    model: []const u8,
    serialized_tools: []const u8,
    selected_dynamic_tool_schemas: []const []const u8 = &.{},
    messages: []const types.ChatMessage,
    capabilities: model_capabilities.Capabilities = .{},
    provider_options: model_capabilities.ResolvedProviderOptions,
    cancel_flag: *std.atomic.Value(bool),
};

pub const Result = struct {
    message: types.ChatMessage,
    used_remote: bool,
    owned_binding: ?types.ResponsesCompactionProviderBinding = null,
    owned_remote: ?responses_compaction_provider.Completed = null,

    pub fn deinit(self: *Result, alloc: Allocator) void {
        if (self.message.content) |content| alloc.free(@constCast(content));
        if (self.owned_remote) |*completed| completed.deinit(alloc);
        if (self.owned_binding) |binding| {
            types.freeResponsesCompactionProviderBinding(alloc, binding);
        }
        self.* = undefined;
    }
};

pub fn supportsAutomaticCompaction(source: ?types.CredentialSource) bool {
    const present = source orelse return false;
    const route = provider_route.fromCredentialSource(present) orelse return false;
    return route.contract().wire_api == .openai_responses;
}

pub fn shouldCompact(usage: types.Usage, capabilities: model_capabilities.Capabilities) bool {
    const limit = model_capabilities.autoCompactTokenLimit(capabilities) orelse return false;
    const active = usage.total_tokens orelse
        (usage.input_tokens orelse 0) +| (usage.output_tokens orelse 0);
    return active >= @as(u64, limit);
}

pub fn isContextOverflow(status: std.http.Status, detail: []const u8) bool {
    if (status == .payload_too_large) return true;
    if (status != .bad_request) return false;

    const needles = [_][]const u8{
        "context_length_exceeded",
        "context_window_exceeded",
        "maximum context length",
        "context window",
        "prompt is too long",
        "prompt_too_long",
        "too many tokens",
    };
    for (needles) |needle| {
        if (containsIgnoreCase(detail, needle)) return true;
    }
    return false;
}

/// Compacts one complete direct-Responses request input. A provider rejection,
/// missing endpoint, or unsupported route deterministically falls back to one
/// local summary message. Returned slices borrow `alloc`.
pub fn compact(alloc: Allocator, request: Request) !Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    const local_summary = try buildLocalSummaryAlloc(alloc, request.messages);
    errdefer alloc.free(local_summary);
    const source = request.credential_source orelse return localResult(local_summary);
    const route = provider_route.fromCredentialSource(source) orelse
        return localResult(local_summary);
    if (route.contract().wire_api != .openai_responses or
        route.contract().remote_compaction == .unsupported)
    {
        return localResult(local_summary);
    }
    const provider = request.provider orelse return localResult(local_summary);

    const binding = responses_compaction_binding.buildFromEnvironmentAlloc(
        alloc,
        source,
        request.credential,
        request.account_id,
    ) catch |err| {
        debug_trace.logf("compaction", "provider binding unavailable err={s}", .{@errorName(err)});
        return localResult(local_summary);
    };
    var owns_binding = true;
    errdefer if (owns_binding) {
        types.freeResponsesCompactionProviderBinding(alloc, binding);
    };

    var prepared_messages = try prepareRemoteMessagesAlloc(
        alloc,
        request.messages,
        request.serialized_tools,
        request.selected_dynamic_tool_schemas,
        request.capabilities,
    );
    defer prepared_messages.deinit(alloc);

    const outcome = provider.fetch(alloc, .{
        .credential = request.credential,
        .account_id = request.account_id,
        .provider_binding = binding.view(),
        .build_request = .{
            .credential_source = source,
            .provider_credential = request.credential,
            .account_id = request.account_id,
            .responses_compaction_binding = binding.view(),
            .session_id = request.session_id,
            .model = request.model,
            .serialized_tools = request.serialized_tools,
            .selected_dynamic_tool_schemas = request.selected_dynamic_tool_schemas,
            .messages = prepared_messages.messages,
            .tool_choice = .auto,
            .provider_options = request.provider_options,
            .budget = .{ .cancel_flag = request.cancel_flag },
        },
    }) catch |err| switch (err) {
        error.Cancelled => return error.Cancelled,
        else => {
            debug_trace.logf("compaction", "remote request failed err={s}", .{@errorName(err)});
            types.freeResponsesCompactionProviderBinding(alloc, binding);
            owns_binding = false;
            return localResult(local_summary);
        },
    };

    return switch (outcome) {
        .unsupported => {
            debug_trace.logf("compaction", "remote request unsupported for active route", .{});
            types.freeResponsesCompactionProviderBinding(alloc, binding);
            owns_binding = false;
            return localResult(local_summary);
        },
        .rejected => |status| {
            debug_trace.logf("compaction", "remote request rejected status={d}", .{@intFromEnum(status)});
            types.freeResponsesCompactionProviderBinding(alloc, binding);
            owns_binding = false;
            return localResult(local_summary);
        },
        .compacted => |completed| blk: {
            owns_binding = false;
            break :blk .{
                .message = .{
                    .role = .system,
                    .content = local_summary,
                    .responses_compaction = .{
                        .credential_source = completed.credential_source,
                        .wire_model = completed.wire_model,
                        .input_json = completed.input_json,
                        .provider_binding = binding.view(),
                    },
                },
                .used_remote = true,
                .owned_binding = binding,
                .owned_remote = completed,
            };
        },
    };
}

const PreparedRemoteMessages = struct {
    messages: []const types.ChatMessage,
    owned_messages: ?[]types.ChatMessage = null,

    fn deinit(self: *PreparedRemoteMessages, alloc: Allocator) void {
        if (self.owned_messages) |messages| alloc.free(messages);
        self.* = undefined;
    }
};

fn prepareRemoteMessagesAlloc(
    alloc: Allocator,
    messages: []const types.ChatMessage,
    serialized_tools: []const u8,
    selected_dynamic_tool_schemas: []const []const u8,
    capabilities: model_capabilities.Capabilities,
) !PreparedRemoteMessages {
    const token_limit = model_capabilities.autoCompactTokenLimit(capabilities) orelse
        return .{ .messages = messages };
    if (token_limit == 0) return .{ .messages = messages };

    var estimated_tokens = estimateRemoteCompactionTokens(
        messages,
        serialized_tools,
        selected_dynamic_tool_schemas,
    );
    if (estimated_tokens <= token_limit) return .{ .messages = messages };
    const initial_estimated_tokens = estimated_tokens;

    const prepared = try alloc.dupe(types.ChatMessage, messages);
    errdefer alloc.free(prepared);
    const replacement_tokens = estimateTextTokens(remote_compaction_truncated_tool_output);
    var rewritten_outputs: usize = 0;
    var index = prepared.len;
    while (index > 0 and estimated_tokens > token_limit) {
        index -= 1;
        const message = &prepared[index];
        if (message.role != .tool) continue;
        const content = message.content orelse continue;
        const content_tokens = estimateTextTokens(content);
        if (content_tokens <= replacement_tokens) continue;
        message.content = remote_compaction_truncated_tool_output;
        estimated_tokens = estimated_tokens -| content_tokens;
        estimated_tokens +|= replacement_tokens;
        rewritten_outputs += 1;
    }

    if (rewritten_outputs == 0) {
        alloc.free(prepared);
        return .{ .messages = messages };
    }
    debug_trace.logf(
        "compaction",
        "trimmed tool outputs before remote request rewritten={d} estimated_tokens_before={d} estimated_tokens_after={d} target={d}",
        .{ rewritten_outputs, initial_estimated_tokens, estimated_tokens, token_limit },
    );
    return .{ .messages = prepared, .owned_messages = prepared };
}

fn estimateRemoteCompactionTokens(
    messages: []const types.ChatMessage,
    serialized_tools: []const u8,
    selected_dynamic_tool_schemas: []const []const u8,
) usize {
    var total = estimateTextTokens(serialized_tools);
    for (selected_dynamic_tool_schemas) |schema| {
        total +|= estimateTextTokens(schema);
    }
    for (messages) |message| {
        total +|= 8;
        if (message.content) |content| total +|= estimateTextTokens(content);
        if (message.tool_call_id) |value| total +|= estimateTextTokens(value);
        if (message.tool_name) |value| total +|= estimateTextTokens(value);
        for (message.tool_calls) |call| {
            total +|= 8;
            total +|= estimateTextTokens(call.id);
            total +|= estimateTextTokens(call.name);
            total +|= estimateTextTokens(call.arguments_json);
        }
        if (message.provider_state_json) |value| total +|= estimateTextTokens(value);
        if (message.reasoning) |value| total +|= estimateTextTokens(value);
        if (message.reasoning_signature) |value| total +|= estimateTextTokens(value);
        if (message.reasoning_item_id) |value| total +|= estimateTextTokens(value);
        if (message.reasoning_encrypted_content) |value| total +|= estimateTextTokens(value);
        for (message.reasoning_items) |item| {
            if (item.id) |value| total +|= estimateTextTokens(value);
            if (item.summary) |value| total +|= estimateTextTokens(value);
            if (item.encrypted_content) |value| total +|= estimateTextTokens(value);
        }
        for (message.responses_provider_output_items) |item| {
            total +|= estimateTextTokens(item.json);
        }
    }
    return total;
}

fn estimateTextTokens(text: []const u8) usize {
    var count: usize = 0;
    var span_len: usize = 0;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (span_len > 0) {
                count +|= (span_len + 3) / 4;
                span_len = 0;
            }
        } else {
            span_len +|= 1;
        }
    }
    if (span_len > 0) count +|= (span_len + 3) / 4;
    return count;
}

fn localResult(summary: []u8) Result {
    return .{
        .message = .{ .role = .system, .content = summary },
        .used_remote = false,
    };
}

/// Rebuilds a request after inline compaction. Stable and ephemeral system
/// context remains outside the provider-owned checkpoint; only messages added
/// after `suffix_start` are replayed after the compacted base.
pub fn buildMessagesAfterCompaction(
    alloc: Allocator,
    stable_prefix: []const types.ChatMessage,
    ephemeral_overlay: []const types.ChatMessage,
    compacted_base: types.ChatMessage,
    within_turn_suffix: []const types.ChatMessage,
    suffix_start: usize,
) !std.ArrayList(types.ChatMessage) {
    var messages: std.ArrayList(types.ChatMessage) = .empty;
    errdefer messages.deinit(alloc);
    try messages.appendSlice(alloc, stable_prefix);
    for (ephemeral_overlay) |overlay| {
        var copy = overlay;
        copy.cache_policy = .no_cache;
        try messages.append(alloc, copy);
    }
    try messages.append(alloc, compacted_base);
    try messages.appendSlice(alloc, within_turn_suffix[@min(suffix_start, within_turn_suffix.len)..]);
    return messages;
}

fn buildLocalSummaryAlloc(alloc: Allocator, messages: []const types.ChatMessage) ![]u8 {
    var selected: std.ArrayList(usize) = .empty;
    defer selected.deinit(alloc);

    var estimated_bytes: usize = 0;
    var index = messages.len;
    while (index > 0 and selected.items.len < local_summary_max_messages) {
        index -= 1;
        const message = messages[index];
        if (message.role == .system) continue;
        const cost = estimateSummaryMessageBytes(message);
        if (selected.items.len > 0 and estimated_bytes +| cost > local_summary_max_bytes) continue;
        try selected.append(alloc, index);
        estimated_bytes +|= cost;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(
        "This turn is continuing after local context compaction. " ++
            "The newest conversation and tool evidence are summarized below.\n",
    );

    var selected_index = selected.items.len;
    while (selected_index > 0) {
        selected_index -= 1;
        const message = messages[selected.items[selected_index]];
        try writeSummaryMessage(&out.writer, message);
        if (out.written().len >= local_summary_max_bytes) break;
    }
    return out.toOwnedSlice();
}

fn estimateSummaryMessageBytes(message: types.ChatMessage) usize {
    var total: usize = 32;
    if (message.content) |content| total +|= @min(content.len, local_summary_max_message_bytes);
    for (message.tool_calls) |call| {
        total +|= @min(call.name.len, 128);
        total +|= @min(call.arguments_json.len, 512);
    }
    return total;
}

fn writeSummaryMessage(writer: *std.Io.Writer, message: types.ChatMessage) !void {
    try writer.print("\n[{s}", .{@tagName(message.role)});
    if (message.tool_name) |name| try writer.print(" tool={s}", .{name});
    if (message.tool_result_status) |status| try writer.print(" status={s}", .{@tagName(status)});
    try writer.writeAll("] ");

    if (message.content) |content| {
        try writeClipped(writer, content, local_summary_max_message_bytes);
    }
    for (message.tool_calls) |call| {
        try writer.print("\n- tool_call {s}: ", .{call.name});
        try writeClipped(writer, call.arguments_json, 512);
    }
}

fn writeClipped(writer: *std.Io.Writer, text: []const u8, max_bytes: usize) !void {
    const clipped = text[0..@min(text.len, max_bytes)];
    for (clipped) |byte| {
        try writer.writeByte(if (byte == '\n' or byte == '\r' or byte == '\t') ' ' else byte);
    }
    if (clipped.len < text.len) try writer.writeAll(" …");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

test "auto compaction threshold uses provider total usage" {
    const capabilities: model_capabilities.Capabilities = .{ .context_window = 100_000 };
    try std.testing.expect(!shouldCompact(.{ .input_tokens = 89_000, .output_tokens = 999 }, capabilities));
    try std.testing.expect(shouldCompact(.{ .total_tokens = 90_000 }, capabilities));
}

test "remote compaction trims oversized tool outputs to the model budget" {
    var oversized_output: [4096]u8 = undefined;
    @memset(&oversized_output, 'x');
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "stable instructions" },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "call", .name = "exec_command", .arguments_json = "{\"cmd\":\"true\"}" }} },
        .{
            .role = .tool,
            .tool_call_id = "call",
            .tool_name = "exec_command",
            .content = &oversized_output,
            .tool_result_status = .success,
        },
        .{ .role = .user, .content = "retain the newest user intent" },
    };

    var prepared = try prepareRemoteMessagesAlloc(
        std.testing.allocator,
        &messages,
        "[]",
        &.{},
        .{ .context_window = 1000 },
    );
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expect(prepared.owned_messages != null);
    try std.testing.expectEqualStrings(
        remote_compaction_truncated_tool_output,
        prepared.messages[2].content.?,
    );
    try std.testing.expectEqualStrings("call", prepared.messages[2].tool_call_id.?);
    try std.testing.expectEqualStrings("retain the newest user intent", prepared.messages[3].content.?);
}

test "remote compaction provider receives context-safe tool output" {
    const Fake = struct {
        fn fetch(
            _: ?*anyopaque,
            alloc: Allocator,
            request: responses_compaction_provider.Request,
        ) !responses_compaction_provider.Outcome {
            try std.testing.expectEqual(@as(usize, 4), request.build_request.messages.len);
            try std.testing.expectEqualStrings(
                remote_compaction_truncated_tool_output,
                request.build_request.messages[2].content.?,
            );
            try std.testing.expectEqualStrings(
                "retain the newest user intent",
                request.build_request.messages[3].content.?,
            );
            return .{ .compacted = .{
                .credential_source = .openai_api_key,
                .wire_model = try alloc.dupe(u8, "gpt-5.4"),
                .input_json = try alloc.dupe(u8, "[{\"type\":\"compaction\",\"encrypted_content\":\"opaque\"}]"),
            } };
        }
    };

    var oversized_output: [4096]u8 = undefined;
    @memset(&oversized_output, 'x');
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "stable instructions" },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "call", .name = "exec_command", .arguments_json = "{\"cmd\":\"true\"}" }} },
        .{
            .role = .tool,
            .tool_call_id = "call",
            .tool_name = "exec_command",
            .content = &oversized_output,
        },
        .{ .role = .user, .content = "retain the newest user intent" },
    };
    var cancel_flag = std.atomic.Value(bool).init(false);
    var result = try compact(std.testing.allocator, .{
        .provider = .{ .fetch_fn = Fake.fetch },
        .credential_source = .openai_api_key,
        .credential = "sk-test",
        .account_id = null,
        .session_id = "session",
        .model = "gpt-5.4",
        .serialized_tools = "[]",
        .messages = &messages,
        .capabilities = .{ .context_window = 1000 },
        .provider_options = .{},
        .cancel_flag = &cancel_flag,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.used_remote);
}

test "remote compaction keeps messages untouched when they fit" {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "stable instructions" },
        .{ .role = .user, .content = "small request" },
    };
    var prepared = try prepareRemoteMessagesAlloc(
        std.testing.allocator,
        &messages,
        "[]",
        &.{},
        .{ .context_window = 1000 },
    );
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expect(prepared.owned_messages == null);
    try std.testing.expect(prepared.messages.ptr == messages[0..].ptr);
}

test "context overflow recognizes 413 and OpenAI 400 details" {
    try std.testing.expect(isContextOverflow(.payload_too_large, ""));
    try std.testing.expect(isContextOverflow(.bad_request, "{\"code\":\"context_length_exceeded\"}"));
    try std.testing.expect(isContextOverflow(.bad_request, "maximum context length reached"));
    try std.testing.expect(!isContextOverflow(.bad_request, "invalid tool schema"));
    try std.testing.expect(!isContextOverflow(.too_many_requests, "context_length_exceeded"));
}

test "automatic compaction supports OAuth and Responses BYOK only" {
    try std.testing.expect(supportsAutomaticCompaction(.chatgpt_subscription));
    try std.testing.expect(supportsAutomaticCompaction(.openai_api_key));
    try std.testing.expect(!supportsAutomaticCompaction(.grok_subscription));
    try std.testing.expect(!supportsAutomaticCompaction(null));
}

test "missing remote compact provider falls back to bounded local summary" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "stable" },
        .{ .role = .user, .content = "inspect the repository" },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "call", .name = "read_file", .arguments_json = "{\"path\":\"src/main.zig\"}" }} },
        .{ .role = .tool, .tool_name = "read_file", .content = "file evidence" },
    };
    var cancel_flag = std.atomic.Value(bool).init(false);
    var result = try compact(alloc, .{
        .provider = null,
        .credential_source = .openai_api_key,
        .credential = "key",
        .account_id = null,
        .session_id = "session",
        .model = "gpt-5.4",
        .serialized_tools = "[]",
        .messages = &messages,
        .provider_options = .{},
        .cancel_flag = &cancel_flag,
    });
    defer result.deinit(alloc);
    try std.testing.expect(!result.used_remote);
    try std.testing.expect(std.mem.find(u8, result.message.content.?, "inspect the repository") != null);
    try std.testing.expect(std.mem.find(u8, result.message.content.?, "file evidence") != null);
}

test "BYOK remote compact rejection falls back locally" {
    const Fake = struct {
        fn fetch(
            _: ?*anyopaque,
            _: Allocator,
            request: responses_compaction_provider.Request,
        ) !responses_compaction_provider.Outcome {
            try std.testing.expectEqual(types.CredentialSource.openai_api_key, request.build_request.credential_source.?);
            return .{ .rejected = .not_found };
        }
    };

    const alloc = std.testing.allocator;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var result = try compact(alloc, .{
        .provider = .{ .fetch_fn = Fake.fetch },
        .credential_source = .openai_api_key,
        .credential = "sk-test",
        .account_id = null,
        .session_id = "session",
        .model = "gpt-5.4",
        .serialized_tools = "[]",
        .messages = &.{.{ .role = .user, .content = "retain this intent" }},
        .provider_options = .{},
        .cancel_flag = &cancel_flag,
    });
    defer result.deinit(alloc);
    try std.testing.expect(!result.used_remote);
    try std.testing.expect(std.mem.find(u8, result.message.content.?, "retain this intent") != null);
}
