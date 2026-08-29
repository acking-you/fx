const std = @import("std");

const agent_stream_provider = @import("../stream_provider.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const provider_route = @import("../../gateway/provider_route.zig");
const responses_compaction_binding = @import("../../gateway/responses_compaction_binding.zig");
const responses_compaction_provider = @import("../../gateway/responses_compaction_provider.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const io_mod = @import("../../shared/io.zig");
const session_usage = @import("../../session/session_usage.zig");
const types = @import("../../shared/types.zig");
const runtime_gateway_step = @import("gateway_step.zig");

const Allocator = std.mem.Allocator;

const local_summary_max_bytes: usize = 16 * 1024;
const local_summary_max_messages: usize = 24;
const local_summary_max_message_bytes: usize = 2 * 1024;
const local_model_summary_max_bytes: usize = 64 * 1024;
const local_model_default_output_tokens: u32 = 8192;
const local_model_max_output_tokens: u32 = 32 * 1024;
const local_model_max_summary_attempts: usize = 3;
const local_model_min_summary_bytes: usize = 500;
const local_compaction_prompt = @embedFile("compaction_prompt.md");
const remote_compaction_truncated_tool_output =
    "[Tool output truncated before remote context compaction to fit the model context window.]";
const local_compaction_truncated_message =
    "[Earlier message content omitted while fitting local context compaction input.]";
const ephemeral_tool_context_omitted =
    "[Transient skill or tool-discovery context omitted; load it again when needed.]";

pub const Request = struct {
    remote_provider: ?responses_compaction_provider.Provider,
    local_provider: agent_stream_provider.Provider,
    credential_source: ?types.CredentialSource,
    credential: []const u8,
    account_id: ?[]const u8,
    session_id: ?[]const u8,
    model: []const u8,
    serialized_tools: []const u8,
    selected_dynamic_tool_schemas: []const []const u8 = &.{},
    messages: []const types.ChatMessage,
    /// Index of the first conversation-owned message. Stable system prompts
    /// before this boundary are sent to native remote compaction but are not
    /// summarized into the portable local handoff.
    history_start: usize = 0,
    capabilities: model_capabilities.Capabilities = .{},
    provider_options: model_capabilities.ResolvedProviderOptions,
    /// When supplied, use the caller's captured route identity instead of
    /// rebuilding it from the live process environment. Background callers
    /// use this to keep the request and its stale-result check bound to the
    /// same provider endpoint and credential identity.
    provider_binding: ?types.ResponsesCompactionProviderBindingView = null,
    /// Exact endpoint for the ordinary model stream used by local-model
    /// compaction. It is deliberately separate from the Responses compact
    /// endpoint because the two transports do not share path semantics.
    local_endpoint_override: ?[]const u8 = null,
    /// Exact Responses endpoint used only to build a remote binding when the
    /// caller did not already capture one.
    remote_endpoint_override: ?[]const u8 = null,
    gateway_retry_count: usize = 1,
    trace_ctx: debug_trace.TraceContext = .{},
    cooperative_pulse: ?agent_stream_provider.CooperativePulse = null,
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
    allow_remote: bool = true,
    cancel_flag: *std.atomic.Value(bool),
};

pub const RemoteResult = struct {
    credential_source: types.CredentialSource,
    wire_model: []u8,
    input_json: []u8,
    provider_binding: types.ResponsesCompactionProviderBinding,
};

pub const Result = struct {
    summary: []u8,
    strategy: types.CompactionStrategy,
    remote: ?RemoteResult = null,

    pub fn deinit(self: *Result, alloc: Allocator) void {
        alloc.free(self.summary);
        if (self.remote) |remote| {
            alloc.free(remote.wire_model);
            alloc.free(remote.input_json);
            types.freeResponsesCompactionProviderBinding(alloc, remote.provider_binding);
        }
        self.* = undefined;
    }

    pub fn message(self: *const Result) types.ChatMessage {
        return .{
            .role = .system,
            .content = self.summary,
            .responses_compaction = if (self.remote) |remote| .{
                .credential_source = remote.credential_source,
                .wire_model = remote.wire_model,
                .input_json = remote.input_json,
                .provider_binding = remote.provider_binding.view(),
            } else null,
        };
    }
};

pub fn supportsAutomaticCompaction(source: ?types.CredentialSource) bool {
    return source != null;
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

/// Compacts one complete request through the only strategy selector in core.
/// Native Responses compaction wins when the active route supports it. Every
/// other route, and every rejected remote attempt, uses the active model to
/// produce a validated local handoff. A bounded deterministic handoff is the
/// final availability fallback. Returned values own allocations from `alloc`.
///
/// Strategy ladder:
///
///   messages -> eligible Responses route -> remote checkpoint
///            -> otherwise or rejected  -> active model summary
///            -> unavailable or invalid -> deterministic summary
///
/// Callers never implement fallback policy themselves. They only install the
/// returned portable summary and optional opaque Responses checkpoint.
pub fn compact(alloc: Allocator, request: Request) !Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    const history = request.messages[@min(request.history_start, request.messages.len)..];
    const fallback_summary = try buildDeterministicSummaryAlloc(alloc, history);
    var owns_fallback = true;
    defer if (owns_fallback) alloc.free(fallback_summary);

    if (request.allow_remote) {
        if (try tryRemoteCompaction(alloc, request, fallback_summary)) |remote| {
            return remote;
        }
    }

    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const local = tryLocalModelCompaction(alloc, request) catch |err| switch (err) {
        error.Cancelled => return error.Cancelled,
        else => blk: {
            debug_trace.logf(
                "compaction",
                "local model compaction unavailable err={s}; using deterministic fallback",
                .{@errorName(err)},
            );
            break :blk null;
        },
    };
    if (local) |result| return result;

    owns_fallback = false;
    return .{
        .summary = fallback_summary,
        .strategy = .local_fallback,
    };
}

fn tryRemoteCompaction(
    alloc: Allocator,
    request: Request,
    fallback_summary: []const u8,
) !?Result {
    const source = request.credential_source orelse return null;
    const route = provider_route.fromCredentialSource(source) orelse return null;
    if (route.contract().wire_api != .openai_responses or
        route.contract().remote_compaction == .unsupported)
    {
        return null;
    }
    const provider = request.remote_provider orelse return null;

    var owned_binding: ?types.ResponsesCompactionProviderBinding = null;
    const binding_view = if (request.provider_binding) |provided| blk: {
        responses_compaction_binding.validate(source, provided) catch |err| {
            debug_trace.logf("compaction", "provider binding unavailable err={s}", .{@errorName(err)});
            return null;
        };
        if (!responses_compaction_binding.credentialMatches(
            source,
            request.credential,
            request.account_id,
            provided,
        )) {
            debug_trace.logf("compaction", "provider binding unavailable err=CredentialBindingMismatch", .{});
            return null;
        }
        break :blk provided;
    } else blk: {
        const options = if (request.remote_endpoint_override) |endpoint|
            responses_compaction_binding.BuildOptions{
                .endpoint_overrides = .{ .responses_base_url = endpoint },
                .organization = io_mod.getenv("OPENAI_ORG_ID"),
                .project = io_mod.getenv("OPENAI_PROJECT_ID"),
            }
        else
            responses_compaction_binding.BuildOptions.fromEnvironment();
        owned_binding = responses_compaction_binding.buildAlloc(
            alloc,
            source,
            request.credential,
            request.account_id,
            options,
        ) catch |err| {
            debug_trace.logf("compaction", "provider binding unavailable err={s}", .{@errorName(err)});
            return null;
        };
        break :blk owned_binding.?.view();
    };
    defer if (owned_binding) |binding| {
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

    const observation = try session_usage.InvocationObservation.begin(request.usage);
    const outcome = provider.fetch(alloc, .{
        .credential = request.credential,
        .account_id = request.account_id,
        .provider_binding = binding_view,
        .build_request = .{
            .credential_source = source,
            .provider_credential = request.credential,
            .account_id = request.account_id,
            .responses_compaction_binding = binding_view,
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
        error.Cancelled => {
            try observation.fail(.ambiguous_delivery);
            return error.Cancelled;
        },
        else => {
            try observation.fail(.ambiguous_delivery);
            debug_trace.logf("compaction", "remote request failed err={s}", .{@errorName(err)});
            return null;
        },
    };

    return switch (outcome) {
        .unsupported => {
            try observation.fail(.unbilled);
            debug_trace.logf("compaction", "remote request unsupported for active route", .{});
            return null;
        },
        .rejected => |status| {
            try observation.fail(.unbilled);
            debug_trace.logf("compaction", "remote request rejected status={d}", .{@intFromEnum(status)});
            return null;
        },
        .compacted => |completed| blk: {
            var owned_remote = completed;
            var owns_remote = true;
            defer if (owns_remote) owned_remote.deinit(alloc);
            try observation.completeDirect(
                request.usage_allocator,
                completed.wire_model,
                completed.usage,
                .{ .http_ok = true },
            );
            const result_binding = if (owned_binding) |binding| blk_binding: {
                owned_binding = null;
                break :blk_binding binding;
            } else try types.dupeResponsesCompactionProviderBinding(alloc, binding_view);
            errdefer types.freeResponsesCompactionProviderBinding(alloc, result_binding);
            const summary = try alloc.dupe(u8, fallback_summary);
            const wire_model = owned_remote.wire_model;
            const input_json = owned_remote.input_json;
            owns_remote = false;
            break :blk .{
                .summary = summary,
                .strategy = .remote,
                .remote = .{
                    .credential_source = completed.credential_source,
                    .wire_model = wire_model,
                    .input_json = input_json,
                    .provider_binding = result_binding,
                },
            };
        },
    };
}

const LocalInputMode = enum {
    fitted,
    lossy,
};

fn tryLocalModelCompaction(alloc: Allocator, request: Request) !?Result {
    if (request.credential_source == null or request.credential.len == 0) return null;
    const history = request.messages[@min(request.history_start, request.messages.len)..];
    if (history.len == 0) return null;

    const modes = [_]LocalInputMode{ .fitted, .lossy };
    modes_loop: for (modes) |mode| {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var input = try prepareLocalInput(arena, request, mode);
        defer input.deinit(arena);

        var attempt: usize = 1;
        while (attempt <= local_model_max_summary_attempts) : (attempt += 1) {
            if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
            var delivery = agent_stream_provider.DeliveryCertainty.init();
            var attempt_evidence: agent_stream_provider.AttemptEvidence = .{};
            var sink_context: u8 = 0;
            var streamed = runtime_gateway_step.streamModelCompletion(
                request.local_provider,
                arena,
                .{
                    .credential = .{
                        .secret = request.credential,
                        .source = request.credential_source,
                        .account_id = request.account_id,
                    },
                    .endpoint = request.local_endpoint_override,
                    .session_id = request.session_id,
                    .model = request.model,
                    .retry_count = request.gateway_retry_count,
                    .messages = input.items,
                    .tool_choice = .none,
                    .provider_options = request.provider_options,
                    .max_output_tokens = localSummaryOutputTokens(request.capabilities),
                    .budget = .{ .cancel_flag = request.cancel_flag },
                    .trace_ctx = request.trace_ctx,
                    .content_capture_limit = local_model_summary_max_bytes,
                    .cooperative_pulse = request.cooperative_pulse,
                    .delivery = &delivery,
                    .attempt_evidence = &attempt_evidence,
                    .events = .{ .context = &sink_context, .emit_fn = discardLocalCompactionEvent },
                    .cancel_flag = request.cancel_flag,
                },
                request.usage,
                request.usage_allocator,
            ) catch |err| switch (err) {
                error.Cancelled => return error.Cancelled,
                else => {
                    debug_trace.logf(
                        "compaction",
                        "local model request failed mode={s} attempt={d} err={s}",
                        .{ @tagName(mode), attempt, @errorName(err) },
                    );
                    return null;
                },
            };
            defer streamed.deinit(arena);

            switch (streamed) {
                .failed => |failure| {
                    debug_trace.logf(
                        "compaction",
                        "local model request rejected mode={s} attempt={d} kind={s}",
                        .{ @tagName(mode), attempt, @tagName(failure.kind) },
                    );
                    if (failure.kind == .request_too_large and mode == .fitted) {
                        continue :modes_loop;
                    }
                    return null;
                },
                .completed => |completed| {
                    const content = completed.completion.content orelse {
                        debug_trace.logf(
                            "compaction",
                            "local model summary missing mode={s} attempt={d}",
                            .{ @tagName(mode), attempt },
                        );
                        if (attempt < local_model_max_summary_attempts) continue;
                        continue :modes_loop;
                    };
                    const cleaned = cleanLocalSummaryAlloc(alloc, content) catch |err| switch (err) {
                        error.InvalidLocalCompactionSummary => {
                            debug_trace.logf(
                                "compaction",
                                "local model summary rejected mode={s} attempt={d}",
                                .{ @tagName(mode), attempt },
                            );
                            if (attempt < local_model_max_summary_attempts) continue;
                            continue :modes_loop;
                        },
                        else => return err,
                    };
                    defer alloc.free(cleaned);
                    const anchors = try buildContinuationAnchorsAlloc(alloc, history);
                    defer alloc.free(anchors);
                    const summary = try assembleLocalSummaryAlloc(alloc, cleaned, anchors);
                    return .{
                        .summary = summary,
                        .strategy = .local_model,
                    };
                },
            }
        }
    }
    return null;
}

fn discardLocalCompactionEvent(_: *anyopaque, _: agent_stream_provider.Event) void {}

fn prepareLocalInput(
    alloc: Allocator,
    request: Request,
    mode: LocalInputMode,
) !std.ArrayList(types.ChatMessage) {
    const history = request.messages[@min(request.history_start, request.messages.len)..];
    var input: std.ArrayList(types.ChatMessage) = .empty;
    errdefer input.deinit(alloc);

    if (mode == .lossy) {
        const fallback = try buildDeterministicSummaryAlloc(alloc, history);
        try input.append(alloc, .{ .role = .user, .content = fallback });
        try input.append(alloc, .{ .role = .user, .content = local_compaction_prompt });
        return input;
    }

    const budget = localInputTokenBudget(request.capabilities);
    const prompt_tokens = estimateTextTokens(local_compaction_prompt) + 16;
    const prepared = try alloc.dupe(types.ChatMessage, history);
    var estimated = estimateMessagesTokens(prepared) +| prompt_tokens;
    if (estimated > budget) {
        const replacement_tokens = estimateTextTokens(local_compaction_truncated_message);
        var index = prepared.len;
        while (index > 0 and estimated > budget) {
            index -= 1;
            const message = &prepared[index];
            if (message.role != .tool) continue;
            const content = message.content orelse continue;
            const content_tokens = estimateTextTokens(content);
            if (content_tokens <= replacement_tokens) continue;
            message.content = local_compaction_truncated_message;
            estimated = estimated -| content_tokens;
            estimated +|= replacement_tokens;
        }
    }

    if (estimated <= budget) {
        try input.appendSlice(alloc, prepared);
    } else {
        var suffix_start = prepared.len;
        var suffix_tokens = prompt_tokens;
        while (suffix_start > 0) {
            const candidate = suffix_start - 1;
            const tokens = estimateMessageTokens(prepared[candidate]);
            if (suffix_tokens +| tokens > budget and suffix_start < prepared.len) break;
            suffix_start = candidate;
            suffix_tokens +|= tokens;
        }
        while (suffix_start < prepared.len and
            prepared[suffix_start].role != .user and
            prepared[suffix_start].role != .system)
        {
            suffix_start += 1;
        }
        if (suffix_start >= prepared.len and prepared.len > 0) {
            suffix_start = prepared.len - 1;
        }

        if (prepared.len > 0 and prepared[0].role == .system and suffix_start > 0) {
            try input.append(alloc, prepared[0]);
        }
        if (suffix_start < prepared.len) try input.appendSlice(alloc, prepared[suffix_start..]);
    }
    try input.append(alloc, .{ .role = .user, .content = local_compaction_prompt });
    return input;
}

fn localSummaryOutputTokens(capabilities: model_capabilities.Capabilities) u32 {
    return @min(
        capabilities.max_output_tokens orelse local_model_default_output_tokens,
        local_model_max_output_tokens,
    );
}

fn localInputTokenBudget(capabilities: model_capabilities.Capabilities) usize {
    const context_window = model_capabilities.effectiveContextWindowTokens(capabilities) orelse 128 * 1024;
    const reserve = @max(@as(u32, 4096), localSummaryOutputTokens(capabilities));
    if (context_window <= reserve + 1024) return @max(@as(usize, 1024), context_window / 2);
    return context_window - reserve;
}

fn estimateMessagesTokens(messages: []const types.ChatMessage) usize {
    var total: usize = 0;
    for (messages) |message| total +|= estimateMessageTokens(message);
    return total;
}

fn estimateMessageTokens(message: types.ChatMessage) usize {
    var total: usize = 8;
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
    return total;
}

fn cleanLocalSummaryAlloc(alloc: Allocator, raw: []const u8) ![]u8 {
    var body = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.find(u8, body, "<summary>")) |start| {
        const content_start = start + "<summary>".len;
        const end = findLastSlice(body, "</summary>") orelse body.len;
        if (end >= content_start) body = std.mem.trim(u8, body[content_start..end], " \t\r\n");
    } else if (std.mem.startsWith(u8, body, "<analysis>")) {
        const end = std.mem.find(u8, body, "</analysis>") orelse
            return error.InvalidLocalCompactionSummary;
        body = std.mem.trim(u8, body[end + "</analysis>".len ..], " \t\r\n");
    }
    if (body.len < local_model_min_summary_bytes) {
        return error.InvalidLocalCompactionSummary;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var index: usize = 0;
    var consecutive_newlines: usize = 0;
    while (index < body.len and out.written().len < local_model_summary_max_bytes) : (index += 1) {
        if (transientContextBlockEnd(body, index)) |end| {
            try out.writer.writeAll(ephemeral_tool_context_omitted);
            index = end - 1;
            continue;
        }
        const byte = body[index];
        if (byte == 0 or byte == 0x1b) continue;
        if (byte == '\r') continue;
        if (byte == '\n') {
            consecutive_newlines += 1;
            if (consecutive_newlines > 2) continue;
        } else {
            consecutive_newlines = 0;
        }
        if (byte == '<' and startsWithControlTag(body[index..])) {
            try out.writer.writeByte('[');
            continue;
        }
        try out.writer.writeByte(byte);
    }
    var sanitized = std.mem.trim(u8, out.written(), " \t\r\n");
    var utf8_backtrack: usize = 0;
    while (!std.unicode.utf8ValidateSlice(sanitized) and
        sanitized.len > 0 and utf8_backtrack < 4)
    {
        sanitized = sanitized[0 .. sanitized.len - 1];
        utf8_backtrack += 1;
    }
    if (!std.unicode.utf8ValidateSlice(sanitized)) {
        return error.InvalidLocalCompactionSummary;
    }
    if (sanitized.len < local_model_min_summary_bytes) {
        return error.InvalidLocalCompactionSummary;
    }
    const owned = try alloc.dupe(u8, sanitized);
    out.deinit();
    return owned;
}

fn transientContextBlockEnd(text: []const u8, start: usize) ?usize {
    if (start >= text.len or text[start] != '<') return null;
    const blocks = [_]struct {
        open: []const u8,
        close: []const u8,
    }{
        .{ .open = "<skill_content", .close = "</skill_content>" },
        .{ .open = "<loaded_skill_context", .close = "</loaded_skill_context>" },
    };
    for (blocks) |block| {
        if (text.len - start < block.open.len or
            !std.ascii.eqlIgnoreCase(text[start .. start + block.open.len], block.open))
        {
            continue;
        }
        const remainder = text[start..];
        const close_start = findIgnoreCase(remainder, block.close) orelse return text.len;
        return start + close_start + block.close.len;
    }
    return null;
}

fn findIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    }
    return null;
}

fn findLastSlice(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var index = haystack.len - needle.len + 1;
    while (index > 0) {
        index -= 1;
        if (std.mem.eql(u8, haystack[index .. index + needle.len], needle)) return index;
    }
    return null;
}

fn startsWithControlTag(text: []const u8) bool {
    const tags = [_][]const u8{
        "<system",
        "</system",
        "<developer",
        "</developer",
        "<user_query",
        "</user_query",
        "<summary",
        "</summary",
        "<analysis",
        "</analysis",
        "<summary_request",
        "</summary_request",
    };
    for (tags) |tag| {
        if (text.len >= tag.len and std.ascii.eqlIgnoreCase(text[0..tag.len], tag)) return true;
    }
    return false;
}

fn buildContinuationAnchorsAlloc(
    alloc: Allocator,
    history: []const types.ChatMessage,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var latest_user: ?[]const u8 = null;
    var latest_assistant: ?[]const u8 = null;
    var tool_count: usize = 0;
    var index = history.len;
    while (index > 0) {
        index -= 1;
        const message = history[index];
        if (latest_user == null and message.role == .user) latest_user = message.content;
        if (latest_assistant == null and message.role == .assistant) latest_assistant = message.content;
        if (message.role == .tool and tool_count < 4) {
            if (tool_count == 0) try out.writer.writeAll("- Latest tool evidence:\n");
            try out.writer.print("  - {s}", .{message.tool_name orelse "tool"});
            if (message.tool_result_status) |status| try out.writer.print(" ({s})", .{@tagName(status)});
            try out.writer.writeAll(": ");
            if (isEphemeralContextTool(message.tool_name)) {
                try out.writer.writeAll(ephemeral_tool_context_omitted);
            } else if (message.content) |content| {
                try writeClipped(&out.writer, content, 1024);
            }
            try out.writer.writeByte('\n');
            tool_count += 1;
        }
        if (latest_user != null and latest_assistant != null and tool_count >= 4) break;
    }
    if (latest_user) |text| {
        try out.writer.writeAll("- Latest user intent: ");
        try writeClipped(&out.writer, text, 2048);
        try out.writer.writeByte('\n');
    }
    if (latest_assistant) |text| {
        try out.writer.writeAll("- Latest assistant state: ");
        try writeClipped(&out.writer, text, 1024);
        try out.writer.writeByte('\n');
    }
    if (out.written().len == 0) try out.writer.writeAll("- No additional continuation anchors.\n");
    return out.toOwnedSlice();
}

fn assembleLocalSummaryAlloc(
    alloc: Allocator,
    model_summary: []const u8,
    anchors: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("Conversation summary:\n");
    try out.writer.writeAll(model_summary);
    try out.writer.writeAll("\n\nContinuation anchors preserved by fx:\n");
    try out.writer.writeAll(anchors);
    return out.toOwnedSlice();
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
    total +|= estimateMessagesTokens(messages);
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

/// Builds the one bounded deterministic continuation summary used when model
/// compaction is unavailable and by legacy turn-window projections. Keeping
/// this fallback here prevents session, TUI, ACP, and agent paths from growing
/// independent summary algorithms.
pub fn buildDeterministicSummaryAlloc(
    alloc: Allocator,
    messages: []const types.ChatMessage,
) ![]u8 {
    var selected: std.ArrayList(usize) = .empty;
    defer selected.deinit(alloc);

    var leading_summary_count: usize = 0;
    while (leading_summary_count < messages.len and
        leading_summary_count < 4 and
        messages[leading_summary_count].role == .system)
    {
        leading_summary_count += 1;
    }
    var estimated_bytes: usize = 0;
    for (messages[0..leading_summary_count]) |message| {
        estimated_bytes +|= estimateSummaryMessageBytes(message);
    }
    var index = messages.len;
    const recent_capacity = local_summary_max_messages - leading_summary_count;
    while (index > leading_summary_count and selected.items.len < recent_capacity) {
        index -= 1;
        const message = messages[index];
        const cost = estimateSummaryMessageBytes(message);
        if (selected.items.len > 0 and estimated_bytes +| cost > local_summary_max_bytes) continue;
        try selected.append(alloc, index);
        estimated_bytes +|= cost;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(
        "Conversation summary:\n" ++
            "- The active model could not produce a full compaction summary. " ++
            "The newest conversation and tool evidence follow as a deterministic fallback.\n",
    );

    for (messages[0..leading_summary_count]) |message| {
        try writeSummaryMessage(&out.writer, message);
    }

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

    if (isEphemeralContextTool(message.tool_name)) {
        try writer.writeAll(ephemeral_tool_context_omitted);
    } else if (message.content) |content| {
        try writeClipped(writer, content, local_summary_max_message_bytes);
    }
    for (message.tool_calls) |call| {
        try writer.print("\n- tool_call {s}: ", .{call.name});
        try writeClipped(writer, call.arguments_json, 512);
    }
}

fn isEphemeralContextTool(tool_name: ?[]const u8) bool {
    const name = tool_name orelse return false;
    return std.mem.eql(u8, name, "skill") or
        std.mem.eql(u8, name, "skill_search") or
        std.mem.eql(u8, name, "capability_search") or
        std.mem.eql(u8, name, "mcp_select_tool");
}

fn writeClipped(writer: *std.Io.Writer, text: []const u8, max_bytes: usize) !void {
    if (text.len <= max_bytes) {
        return writeNormalized(writer, text);
    }
    const prefix_budget = max_bytes / 2;
    const suffix_budget = max_bytes - prefix_budget;
    var prefix_end = prefix_budget;
    while (prefix_end > 0 and prefix_end < text.len and isUtf8Continuation(text[prefix_end])) {
        prefix_end -= 1;
    }
    var suffix_start = text.len - suffix_budget;
    while (suffix_start < text.len and isUtf8Continuation(text[suffix_start])) {
        suffix_start += 1;
    }
    try writeNormalized(writer, text[0..prefix_end]);
    try writer.writeAll(" ...[middle truncated]... ");
    try writeNormalized(writer, text[suffix_start..]);
}

fn writeNormalized(writer: *std.Io.Writer, text: []const u8) !void {
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == 0 or byte == 0x1b) continue;
        if (byte == '<' and startsWithControlTag(text[index..])) {
            try writer.writeByte('[');
            continue;
        }
        try writer.writeByte(if (byte == '\n' or byte == '\r' or byte == '\t') ' ' else byte);
    }
}

fn isUtf8Continuation(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return findIgnoreCase(haystack, needle) != null;
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
        .remote_provider = .{ .fetch_fn = Fake.fetch },
        .local_provider = agent_stream_provider.unavailable_provider,
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
    try std.testing.expectEqual(types.CompactionStrategy.remote, result.strategy);
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

test "remote compaction honors a caller-captured provider binding" {
    const Fake = struct {
        fn fetch(
            _: ?*anyopaque,
            alloc: Allocator,
            request: responses_compaction_provider.Request,
        ) !responses_compaction_provider.Outcome {
            try std.testing.expectEqualStrings(
                "https://captured.example/v1/responses",
                request.provider_binding.normalized_origin,
            );
            try std.testing.expectEqualStrings(
                request.provider_binding.api_key_sha256.?,
                request.build_request.responses_compaction_binding.?.api_key_sha256.?,
            );
            return .{ .compacted = .{
                .credential_source = .openai_api_key,
                .wire_model = try alloc.dupe(u8, "gpt-5.4"),
                .input_json = try alloc.dupe(u8, "[{\"type\":\"compaction\"}]"),
            } };
        }
    };

    const alloc = std.testing.allocator;
    const captured = try responses_compaction_binding.buildAlloc(
        alloc,
        .openai_api_key,
        "sk-captured",
        null,
        .{ .endpoint_overrides = .{ .responses_base_url = "https://captured.example/v1" } },
    );
    defer types.freeResponsesCompactionProviderBinding(alloc, captured);

    var cancel_flag = std.atomic.Value(bool).init(false);
    var result = try compact(alloc, .{
        .remote_provider = .{ .fetch_fn = Fake.fetch },
        .local_provider = agent_stream_provider.unavailable_provider,
        .credential_source = .openai_api_key,
        .credential = "sk-captured",
        .account_id = null,
        .session_id = "session",
        .model = "gpt-5.4",
        .serialized_tools = "[]",
        .messages = &.{.{ .role = .user, .content = "retain this intent" }},
        .provider_options = .{},
        .provider_binding = captured.view(),
        .cancel_flag = &cancel_flag,
    });
    defer result.deinit(alloc);
    try std.testing.expectEqual(types.CompactionStrategy.remote, result.strategy);
}

test "remote compaction binds a connection-scoped endpoint to its key" {
    const Fake = struct {
        fn fetch(
            _: ?*anyopaque,
            alloc: Allocator,
            request: responses_compaction_provider.Request,
        ) !responses_compaction_provider.Outcome {
            try std.testing.expectEqualStrings(
                "https://connection.example/v1/responses",
                request.provider_binding.normalized_origin,
            );
            try std.testing.expect(responses_compaction_binding.credentialMatches(
                .openai_api_key,
                request.credential,
                request.account_id,
                request.provider_binding,
            ));
            return .{ .compacted = .{
                .credential_source = .openai_api_key,
                .wire_model = try alloc.dupe(u8, "gpt-5.4"),
                .input_json = try alloc.dupe(u8, "[{\"type\":\"compaction\"}]"),
            } };
        }
    };

    var cancel_flag = std.atomic.Value(bool).init(false);
    var result = try compact(std.testing.allocator, .{
        .remote_provider = .{ .fetch_fn = Fake.fetch },
        .local_provider = agent_stream_provider.unavailable_provider,
        .credential_source = .openai_api_key,
        .credential = "sk-connection",
        .account_id = null,
        .session_id = "session",
        .model = "gpt-5.4",
        .serialized_tools = "[]",
        .messages = &.{.{ .role = .user, .content = "retain this intent" }},
        .provider_options = .{},
        .remote_endpoint_override = "https://connection.example/v1/responses",
        .cancel_flag = &cancel_flag,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.CompactionStrategy.remote, result.strategy);
}

test "context overflow recognizes 413 and OpenAI 400 details" {
    try std.testing.expect(isContextOverflow(.payload_too_large, ""));
    try std.testing.expect(isContextOverflow(.bad_request, "{\"code\":\"context_length_exceeded\"}"));
    try std.testing.expect(isContextOverflow(.bad_request, "maximum context length reached"));
    try std.testing.expect(!isContextOverflow(.bad_request, "invalid tool schema"));
    try std.testing.expect(!isContextOverflow(.too_many_requests, "context_length_exceeded"));
}

test "automatic compaction supports every authenticated provider" {
    try std.testing.expect(supportsAutomaticCompaction(.chatgpt_subscription));
    try std.testing.expect(supportsAutomaticCompaction(.openai_api_key));
    try std.testing.expect(supportsAutomaticCompaction(.grok_subscription));
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
        .remote_provider = null,
        .local_provider = agent_stream_provider.unavailable_provider,
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
    try std.testing.expectEqual(types.CompactionStrategy.local_fallback, result.strategy);
    try std.testing.expect(std.mem.find(u8, result.summary, "inspect the repository") != null);
    try std.testing.expect(std.mem.find(u8, result.summary, "file evidence") != null);
}

test "BYOK remote rejection uses the active model through the same compaction core" {
    const Fake = struct {
        fn fetch(
            _: ?*anyopaque,
            _: Allocator,
            request: responses_compaction_provider.Request,
        ) !responses_compaction_provider.Outcome {
            try std.testing.expectEqual(types.CredentialSource.openai_api_key, request.build_request.credential_source.?);
            return .{ .rejected = .not_found };
        }

        fn stream(
            _: ?*anyopaque,
            _: Allocator,
            request: agent_stream_provider.ModelRequest,
        ) !agent_stream_provider.Result {
            try request.admission.admit();
            try std.testing.expectEqual(types.ToolChoice.none, request.tool_choice);
            try std.testing.expect(std.mem.find(
                u8,
                request.messages[request.messages.len - 1].content.?,
                "Latest user intent",
            ) != null);
            return .{ .completed = .{
                .completion = .{
                    .content = "<summary>\nThe user asked fx to retain this intent after a rejected remote compaction. No tools ran, no files changed, and the next turn should continue from that exact request. " ++
                        ("Preserve the exact provider route, observed failure, current code state, pending verification, and latest user constraint. " ** 6) ++
                        "\n</summary>",
                    .usage = .{ .input_tokens = 80, .output_tokens = 36, .total_tokens = 116 },
                },
                .usage = .{ .exact = .gateway },
            } };
        }
    };

    const alloc = std.testing.allocator;
    var cancel_flag = std.atomic.Value(bool).init(false);
    var result = try compact(alloc, .{
        .remote_provider = .{ .fetch_fn = Fake.fetch },
        .local_provider = .{ .stream_fn = Fake.stream },
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
    try std.testing.expectEqual(types.CompactionStrategy.local_model, result.strategy);
    try std.testing.expect(std.mem.find(u8, result.summary, "retain this intent") != null);
    try std.testing.expect(std.mem.find(u8, result.summary, "Latest user intent") != null);
}

test "Grok compaction uses the active model and preserves continuation anchors" {
    const Fake = struct {
        fn stream(
            _: ?*anyopaque,
            _: Allocator,
            request: agent_stream_provider.ModelRequest,
        ) !agent_stream_provider.Result {
            try request.admission.admit();
            try std.testing.expectEqualStrings("grok-code-fast-1", request.model);
            try std.testing.expectEqual(types.ToolChoice.none, request.tool_choice);
            return .{ .completed = .{
                .completion = .{
                    .content = "<analysis>private drafting</analysis>\n<summary>\nThe repository inspection found a reproducible rendering regression. The user wants the compact implementation unified, with the active Grok model producing the portable local handoff and preserving exact evidence. " ++
                        ("Carry forward exact paths, commands, errors, decisions, completed checks, unresolved risks, and the next justified action. " ** 6) ++
                        "\n</summary>",
                    .usage = .{ .input_tokens = 120, .output_tokens = 44, .total_tokens = 164 },
                },
                .usage = .{ .exact = .gateway },
            } };
        }
    };

    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "inspect the rendering regression" },
        .{ .role = .assistant, .content = "I found the likely owner and will verify it." },
        .{
            .role = .tool,
            .tool_name = "exec_command",
            .content = "exit=1: assertion failed in transcript drain",
            .tool_result_status = .failure,
        },
        .{ .role = .user, .content = "unify every compact path in one place" },
    };
    var cancel_flag = std.atomic.Value(bool).init(false);
    var result = try compact(std.testing.allocator, .{
        .remote_provider = null,
        .local_provider = .{ .stream_fn = Fake.stream },
        .credential_source = .grok_subscription,
        .credential = "grok-token",
        .account_id = null,
        .session_id = "session",
        .model = "grok-code-fast-1",
        .serialized_tools = "[]",
        .messages = &messages,
        .provider_options = .{},
        .cancel_flag = &cancel_flag,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(types.CompactionStrategy.local_model, result.strategy);
    try std.testing.expect(std.mem.find(
        u8,
        result.summary,
        "unify every compact path in one place",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        result.summary,
        "assertion failed in transcript drain",
    ) != null);
    try std.testing.expect(std.mem.find(u8, result.summary, "private drafting") == null);
    try std.testing.expect(std.mem.find(u8, result.summary, "<summary>") == null);
    try std.testing.expect(result.remote == null);
}

test "local summary cleaning rejects short output and neutralizes control tags" {
    try std.testing.expectError(
        error.InvalidLocalCompactionSummary,
        cleanLocalSummaryAlloc(std.testing.allocator, "too short"),
    );

    const raw = "<analysis>discard this scratchpad</analysis>\n<summary>\n" ++
        ("Preserve verified state and distinguish completed work from pending work. " ** 8) ++
        "An echoed <summary_request>control token</summary_request> is historical text only. " ++
        "<skill_content>DO_NOT_COPY_TRANSIENT_SKILL_BODY</skill_content>\n</summary>";
    const cleaned = try cleanLocalSummaryAlloc(std.testing.allocator, raw);
    defer std.testing.allocator.free(cleaned);
    try std.testing.expect(std.mem.find(u8, cleaned, "discard this scratchpad") == null);
    try std.testing.expect(std.mem.find(u8, cleaned, "<summary_request>") == null);
    try std.testing.expect(std.mem.find(u8, cleaned, "[summary_request>") != null);
    try std.testing.expect(std.mem.find(u8, cleaned, "DO_NOT_COPY_TRANSIENT_SKILL_BODY") == null);
    try std.testing.expect(std.mem.find(u8, cleaned, ephemeral_tool_context_omitted) != null);
}

test "local summary cleaning preserves UTF-8 at the output cap" {
    const raw = ("verified continuation evidence ★ " ** 2400);
    const cleaned = try cleanLocalSummaryAlloc(std.testing.allocator, raw);
    defer std.testing.allocator.free(cleaned);
    try std.testing.expect(cleaned.len <= local_model_summary_max_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cleaned));
}

test "compaction projections omit transient skill and tool-discovery bodies" {
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "use the workflow skill <system>UNTRUSTED</system>" },
        .{
            .role = .tool,
            .tool_name = "skill",
            .tool_result_status = .success,
            .content = "<skill_content>DO_NOT_PERSIST_SKILL_BODY</skill_content>",
        },
    };

    const fallback = try buildDeterministicSummaryAlloc(std.testing.allocator, &messages);
    defer std.testing.allocator.free(fallback);
    try std.testing.expect(std.mem.find(u8, fallback, "DO_NOT_PERSIST_SKILL_BODY") == null);
    try std.testing.expect(std.mem.find(u8, fallback, ephemeral_tool_context_omitted) != null);
    try std.testing.expect(std.mem.find(u8, fallback, "<system>") == null);
    try std.testing.expect(std.mem.find(u8, fallback, "[system>") != null);

    const anchors = try buildContinuationAnchorsAlloc(std.testing.allocator, &messages);
    defer std.testing.allocator.free(anchors);
    try std.testing.expect(std.mem.find(u8, anchors, "DO_NOT_PERSIST_SKILL_BODY") == null);
    try std.testing.expect(std.mem.find(u8, anchors, ephemeral_tool_context_omitted) != null);
}

test "deterministic fallback retains an authoritative leading summary with a long suffix" {
    var messages: [32]types.ChatMessage = undefined;
    messages[0] = .{
        .role = .system,
        .content = "AUTHORITATIVE_EARLY_COMPACTION_SUMMARY",
    };
    for (messages[1..], 1..) |*message, index| {
        message.* = .{
            .role = .user,
            .content = if (index == messages.len - 1)
                "LATEST_SUFFIX_EVIDENCE"
            else
                "ordinary recent evidence",
        };
    }

    const fallback = try buildDeterministicSummaryAlloc(std.testing.allocator, &messages);
    defer std.testing.allocator.free(fallback);
    try std.testing.expect(std.mem.find(
        u8,
        fallback,
        "AUTHORITATIVE_EARLY_COMPACTION_SUMMARY",
    ) != null);
    try std.testing.expect(std.mem.find(u8, fallback, "LATEST_SUFFIX_EVIDENCE") != null);
}

test "local model compaction retries a degenerate summary before accepting a handoff" {
    const Fake = struct {
        calls: usize = 0,

        fn stream(
            raw: ?*anyopaque,
            _: Allocator,
            request: agent_stream_provider.ModelRequest,
        ) !agent_stream_provider.Result {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            try request.admission.admit();
            if (self.calls == 1) {
                return .{ .completed = .{
                    .completion = .{ .content = "short and unusable" },
                    .usage = .{ .exact = .gateway },
                } };
            }
            return .{ .completed = .{
                .completion = .{
                    .content = ("The handoff preserves the user's request, exact evidence, completed checks, current code state, unresolved risks, and next action. " ** 6),
                },
                .usage = .{ .exact = .gateway },
            } };
        }
    };

    var fake: Fake = .{};
    var cancel_flag = std.atomic.Value(bool).init(false);
    var result = try compact(std.testing.allocator, .{
        .remote_provider = null,
        .local_provider = .{ .context = &fake, .stream_fn = Fake.stream },
        .credential_source = .openai_api_key,
        .credential = "key",
        .account_id = null,
        .session_id = "session",
        .model = "gpt-5.4",
        .serialized_tools = "[]",
        .messages = &.{.{ .role = .user, .content = "continue the implementation" }},
        .provider_options = .{},
        .cancel_flag = &cancel_flag,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqual(types.CompactionStrategy.local_model, result.strategy);
    try std.testing.expect(std.mem.find(u8, result.summary, "continue the implementation") != null);
}
