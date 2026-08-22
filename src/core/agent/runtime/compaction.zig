const std = @import("std");

const model_capabilities = @import("../../config/model_capabilities.zig");
const provider_route = @import("../../gateway/provider_route.zig");
const responses_compaction_binding = @import("../../gateway/responses_compaction_binding.zig");
const responses_compaction_provider = @import("../../gateway/responses_compaction_provider.zig");
const types = @import("../../shared/types.zig");

const Allocator = std.mem.Allocator;

const local_summary_max_bytes: usize = 16 * 1024;
const local_summary_max_messages: usize = 24;
const local_summary_max_message_bytes: usize = 2 * 1024;

pub const Request = struct {
    provider: ?responses_compaction_provider.Provider,
    credential_source: ?types.CredentialSource,
    credential: []const u8,
    account_id: ?[]const u8,
    session_id: ?[]const u8,
    model: []const u8,
    serialized_tools: []const u8,
    messages: []const types.ChatMessage,
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
    ) catch return localResult(local_summary);
    var owns_binding = true;
    errdefer if (owns_binding) {
        types.freeResponsesCompactionProviderBinding(alloc, binding);
    };

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
            .messages = request.messages,
            .tool_choice = .auto,
            .provider_options = request.provider_options,
            .budget = .{ .cancel_flag = request.cancel_flag },
        },
    }) catch |err| switch (err) {
        error.Cancelled => return error.Cancelled,
        else => {
            types.freeResponsesCompactionProviderBinding(alloc, binding);
            owns_binding = false;
            return localResult(local_summary);
        },
    };

    return switch (outcome) {
        .unsupported, .rejected => {
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
    try std.testing.expect(!supportsAutomaticCompaction(.ai_gateway_api_key));
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
