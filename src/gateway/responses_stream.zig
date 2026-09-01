const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const responses_protocol = @import("../core/gateway/responses_protocol.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const responses_output_items = @import("../core/shared/responses_output_items.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

const max_sse_line_bytes: usize = 32 * 1024 * 1024;
const max_sse_event_bytes: usize = 32 * 1024 * 1024;
const max_failure_detail_bytes: usize = 600;
const max_url_citations: usize = 64;
const max_url_citation_url_bytes: usize = 8 * 1024;
const max_url_citation_title_bytes: usize = 1024;
const max_url_citation_total_bytes: usize = 256 * 1024;

/// `wire_type` is an unknown event or an event/output-item discriminator that
/// the semantic fx completion contract does not consume. Both slices are
/// borrowed from the decoded event and remain valid only for the duration of
/// the callback. Consumers that retain an event must copy them.
pub const UnknownEventCallback = stream_provider.RawEventCallback;

pub const Callbacks = struct {
    context: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback = null,
    on_provider_tool_start: ?stream_provider.ProviderToolStartCallback = null,
    on_provider_tool_done: ?stream_provider.ProviderToolDoneCallback = null,
    on_reasoning_chunk: ?stream_provider.StreamCallback = null,
    on_tool_input_chunk: ?stream_provider.StreamCallback = null,
    on_unknown_event: ?UnknownEventCallback = null,
    content_capture_limit: ?usize = null,
};

const ToolInputKind = enum {
    unknown,
    function_json,
    custom_freeform,
};

const ToolState = struct {
    item_id: std.ArrayList(u8) = .empty,
    call_id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    input_kind: ToolInputKind = .unknown,
    output_index: ?u64 = null,
    start_reported: bool = false,

    fn deinit(self: *ToolState, alloc: Allocator) void {
        self.item_id.deinit(alloc);
        self.call_id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

const ReasoningState = struct {
    item_id: std.ArrayList(u8) = .empty,
    summary: std.ArrayList(u8) = .empty,
    content: std.ArrayList(u8) = .empty,
    encrypted_content: std.ArrayList(u8) = .empty,
    output_index: ?u64 = null,
    finalized: bool = false,

    fn deinit(self: *ReasoningState, alloc: Allocator) void {
        self.item_id.deinit(alloc);
        self.summary.deinit(alloc);
        self.content.deinit(alloc);
        self.encrypted_content.deinit(alloc);
        self.* = undefined;
    }
};

const CitationState = struct {
    url: []u8,
    title: []u8,
    start_index: u64,
    end_index: u64,

    fn deinit(self: *CitationState, alloc: Allocator) void {
        alloc.free(self.url);
        alloc.free(self.title);
        self.* = undefined;
    }
};

const DeltaStreamKind = enum {
    output_text,
    refusal,
    reasoning_summary,
    reasoning_text,
};

const DeltaStreamKey = struct {
    kind: DeltaStreamKind,
    item_id: ?[]u8 = null,
    output_index: ?u64 = null,
    content_index: ?u64 = null,
    summary_index: ?u64 = null,

    fn deinit(self: *DeltaStreamKey, alloc: Allocator) void {
        if (self.item_id) |value| alloc.free(value);
        self.* = undefined;
    }

    fn matches(
        self: DeltaStreamKey,
        kind: DeltaStreamKind,
        item_id: ?[]const u8,
        output_index: ?u64,
        content_index: ?u64,
        summary_index: ?u64,
    ) bool {
        if (self.kind != kind or
            self.output_index != output_index or
            self.content_index != content_index or
            self.summary_index != summary_index)
        {
            return false;
        }
        if (self.item_id) |stored| {
            const candidate = item_id orelse return false;
            return std.mem.eql(u8, stored, candidate);
        }
        return item_id == null;
    }
};

const Accumulator = struct {
    content: std.ArrayList(u8) = .empty,
    reasoning_items: std.ArrayList(ReasoningState) = .empty,
    tools: std.ArrayList(ToolState) = .empty,
    citations: std.ArrayList(CitationState) = .empty,
    provider_output_items: std.ArrayList(responses_output_items.Item) = .empty,
    message_output_index: ?u64 = null,
    message_output_index_ambiguous: bool = false,
    provider_output_sequence_complete: bool = false,
    citation_bytes: usize = 0,
    citation_sources_emitted: bool = false,
    generation_id: ?[]u8 = null,
    usage: types.Usage = .{},
    finish_reason: ?types.ProviderFinishReason = null,
    failure_detail: ?[]u8 = null,
    failure_metadata: ?types.ProviderFailureMetadata = null,
    delta_streams: std.ArrayList(DeltaStreamKey) = .empty,
    terminal: bool = false,

    fn deinit(self: *Accumulator, alloc: Allocator) void {
        self.content.deinit(alloc);
        for (self.reasoning_items.items) |*item| item.deinit(alloc);
        self.reasoning_items.deinit(alloc);
        for (self.tools.items) |*tool| tool.deinit(alloc);
        self.tools.deinit(alloc);
        for (self.citations.items) |*citation| citation.deinit(alloc);
        self.citations.deinit(alloc);
        for (self.provider_output_items.items) |item| {
            alloc.free(@constCast(item.json));
        }
        self.provider_output_items.deinit(alloc);
        for (self.delta_streams.items) |*key| key.deinit(alloc);
        self.delta_streams.deinit(alloc);
        if (self.generation_id) |value| alloc.free(value);
        if (self.failure_detail) |value| alloc.free(value);
        self.* = undefined;
    }

    fn markDelta(
        self: *Accumulator,
        alloc: Allocator,
        kind: DeltaStreamKind,
        item_id: ?[]const u8,
        output_index: ?u64,
        content_index: ?u64,
        summary_index: ?u64,
    ) !void {
        if (self.sawDelta(kind, item_id, output_index, content_index, summary_index)) return;
        var key: DeltaStreamKey = .{
            .kind = kind,
            .item_id = if (item_id) |value| try alloc.dupe(u8, value) else null,
            .output_index = output_index,
            .content_index = content_index,
            .summary_index = summary_index,
        };
        errdefer key.deinit(alloc);
        try self.delta_streams.append(alloc, key);
    }

    fn sawDelta(
        self: Accumulator,
        kind: DeltaStreamKind,
        item_id: ?[]const u8,
        output_index: ?u64,
        content_index: ?u64,
        summary_index: ?u64,
    ) bool {
        for (self.delta_streams.items) |key| {
            if (key.matches(kind, item_id, output_index, content_index, summary_index)) return true;
        }
        return false;
    }

    fn findTool(
        self: *Accumulator,
        item_id: ?[]const u8,
        call_id: ?[]const u8,
        output_index: ?u64,
    ) !?*ToolState {
        var item_match: ?*ToolState = null;
        var call_match: ?*ToolState = null;
        var index_match: ?*ToolState = null;
        for (self.tools.items) |*tool| {
            if (call_id) |wanted| {
                if (tool.call_id.items.len > 0 and std.mem.eql(u8, tool.call_id.items, wanted)) {
                    call_match = tool;
                }
            }
            if (item_id) |wanted| {
                if (tool.item_id.items.len > 0 and std.mem.eql(u8, tool.item_id.items, wanted)) {
                    item_match = tool;
                }
            }
            if (output_index) |wanted| {
                if (tool.output_index != null and tool.output_index.? == wanted) {
                    index_match = tool;
                }
            }
        }
        if (item_match != null and call_match != null and item_match.? != call_match.?) {
            return error.ConflictingResponsesToolIdentity;
        }
        if (item_match != null and index_match != null and item_match.? != index_match.?) {
            return error.ConflictingResponsesToolIdentity;
        }
        if (call_match != null and index_match != null and call_match.? != index_match.?) {
            return error.ConflictingResponsesToolIdentity;
        }
        const matched = item_match orelse call_match orelse index_match orelse return null;
        if (item_id) |wanted| {
            if (matched.item_id.items.len > 0 and !std.mem.eql(u8, matched.item_id.items, wanted)) {
                return error.ConflictingResponsesToolIdentity;
            }
        }
        if (call_id) |wanted| {
            if (matched.call_id.items.len > 0 and !std.mem.eql(u8, matched.call_id.items, wanted)) {
                return error.ConflictingResponsesToolIdentity;
            }
        }
        if (output_index) |wanted| {
            if (matched.output_index != null and matched.output_index.? != wanted) {
                return error.ConflictingResponsesToolIdentity;
            }
        }
        return matched;
    }

    fn ensureTool(
        self: *Accumulator,
        alloc: Allocator,
        item_id: ?[]const u8,
        call_id: ?[]const u8,
        output_index: ?u64,
    ) !*ToolState {
        if (try self.findTool(item_id, call_id, output_index)) |tool| {
            if (tool.item_id.items.len == 0) if (item_id) |value| try tool.item_id.appendSlice(alloc, value);
            if (tool.call_id.items.len == 0) if (call_id) |value| try tool.call_id.appendSlice(alloc, value);
            if (tool.output_index == null) tool.output_index = output_index;
            return tool;
        }
        var tool: ToolState = .{ .output_index = output_index };
        errdefer tool.deinit(alloc);
        if (item_id) |value| try tool.item_id.appendSlice(alloc, value);
        if (call_id) |value| try tool.call_id.appendSlice(alloc, value);
        try self.tools.append(alloc, tool);
        return &self.tools.items[self.tools.items.len - 1];
    }

    fn findReasoning(
        self: *Accumulator,
        item_id: ?[]const u8,
        output_index: ?u64,
    ) !?*ReasoningState {
        var item_match: ?*ReasoningState = null;
        var index_match: ?*ReasoningState = null;
        for (self.reasoning_items.items) |*reasoning| {
            if (item_id) |wanted| {
                if (reasoning.item_id.items.len > 0 and std.mem.eql(u8, reasoning.item_id.items, wanted)) {
                    item_match = reasoning;
                }
            }
            if (output_index) |wanted| {
                if (reasoning.output_index != null and reasoning.output_index.? == wanted) {
                    index_match = reasoning;
                }
            }
        }
        if (item_match != null and index_match != null and item_match.? != index_match.?) {
            return error.ConflictingResponsesReasoningIdentity;
        }
        const matched = item_match orelse index_match orelse return null;
        if (item_id) |wanted| {
            if (matched.item_id.items.len > 0 and !std.mem.eql(u8, matched.item_id.items, wanted)) {
                return error.ConflictingResponsesReasoningIdentity;
            }
        }
        if (output_index) |wanted| {
            if (matched.output_index != null and matched.output_index.? != wanted) {
                return error.ConflictingResponsesReasoningIdentity;
            }
        }
        return matched;
    }

    fn ensureReasoning(
        self: *Accumulator,
        alloc: Allocator,
        item_id: ?[]const u8,
        output_index: ?u64,
    ) !*ReasoningState {
        if (try self.findReasoning(item_id, output_index)) |reasoning| {
            if (reasoning.item_id.items.len == 0) if (item_id) |value| try reasoning.item_id.appendSlice(alloc, value);
            if (reasoning.output_index == null) reasoning.output_index = output_index;
            return reasoning;
        }
        var reasoning: ReasoningState = .{ .output_index = output_index };
        errdefer reasoning.deinit(alloc);
        if (item_id) |value| try reasoning.item_id.appendSlice(alloc, value);
        try self.reasoning_items.append(alloc, reasoning);
        return &self.reasoning_items.items[self.reasoning_items.items.len - 1];
    }
};

/// Consumes a standard Responses SSE stream and returns the existing semantic
/// completion contract used by the agent loop. Unknown and semantically
/// unhandled events remain available as exact raw JSON so additive protocol
/// changes do not break a turn or silently discard their wire representation.
pub fn consume(
    alloc: Allocator,
    reader: anytype,
    callbacks: Callbacks,
    cancel_flag: *std.atomic.Value(bool),
) !types.ModelCompletion {
    var state: Accumulator = .{};
    defer state.deinit(alloc);
    var frames: FrameReader = .{};
    defer frames.deinit(alloc);

    while (!state.terminal) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        const frame = try frames.next(alloc, reader);
        switch (frame) {
            .eof => return error.ResponsesStreamEndedEarly,
            .read_failed => return error.ReadFailed,
            .done => return error.ResponsesStreamEndedEarly,
            .ignored => continue,
            .data => |data| {
                var event = try responses_protocol.decodeEvent(alloc, data);
                defer event.deinit();
                try applyEvent(alloc, &state, event.projection, event.raw_json, callbacks);
            },
        }
    }

    return materialize(alloc, &state);
}

fn applyEvent(
    alloc: Allocator,
    state: *Accumulator,
    projection: responses_protocol.Projection,
    raw_json: []const u8,
    callbacks: Callbacks,
) !void {
    switch (projection) {
        .response_created => observeUnknown(callbacks, "response.created", raw_json),
        .response_in_progress => observeUnknown(callbacks, "response.in_progress", raw_json),
        .response_queued => observeUnknown(callbacks, "response.queued", raw_json),
        .content_part_added => observeUnknown(callbacks, "response.content_part.added", raw_json),
        .content_part_done => observeUnknown(callbacks, "response.content_part.done", raw_json),
        .reasoning_summary_part_added => observeUnknown(callbacks, "response.reasoning_summary_part.added", raw_json),
        .reasoning_summary_part_done => observeUnknown(callbacks, "response.reasoning_summary_part.done", raw_json),
        .unknown => |event| observeUnknown(callbacks, event.event_type, raw_json),
        .output_text_delta => |event| {
            try observeMessageOutputIndex(state, event.output_index);
            try state.markDelta(alloc, .output_text, event.item_id, event.output_index, event.content_index, null);
            try appendContent(state, alloc, event.delta, callbacks);
        },
        .output_text_done => |event| {
            try observeMessageOutputIndex(state, event.output_index);
            if (!state.sawDelta(.output_text, event.item_id, event.output_index, event.content_index, null)) {
                try appendContent(state, alloc, event.text, callbacks);
            }
        },
        .output_text_annotation_added => |event| {
            if (event.url_citation) |citation| {
                try appendUrlCitation(alloc, state, citation);
            } else {
                observeUnknown(callbacks, "response.output_text.annotation.added", raw_json);
            }
        },
        .refusal_delta => |event| {
            try observeMessageOutputIndex(state, event.output_index);
            try state.markDelta(alloc, .refusal, event.item_id, event.output_index, event.content_index, null);
            try appendContent(state, alloc, event.delta, callbacks);
        },
        .refusal_done => |event| {
            try observeMessageOutputIndex(state, event.output_index);
            if (!state.sawDelta(.refusal, event.item_id, event.output_index, event.content_index, null) and event.text.len > 0) {
                try appendContent(state, alloc, event.text, callbacks);
            }
        },
        .reasoning_summary_text_delta => |event| {
            try state.markDelta(alloc, .reasoning_summary, event.item_id, event.output_index, event.content_index, event.summary_index);
            const reasoning = try state.ensureReasoning(alloc, event.item_id, event.output_index);
            try reasoning.summary.appendSlice(alloc, event.delta);
            if (callbacks.on_reasoning_chunk) |callback| callback(callbacks.context, event.delta);
        },
        .reasoning_summary_text_done => |event| {
            if (!state.sawDelta(.reasoning_summary, event.item_id, event.output_index, event.content_index, event.summary_index) and event.text.len > 0) {
                const reasoning = try state.ensureReasoning(alloc, event.item_id, event.output_index);
                try reasoning.summary.appendSlice(alloc, event.text);
                if (callbacks.on_reasoning_chunk) |callback| callback(callbacks.context, event.text);
            }
        },
        .reasoning_text_delta => |event| {
            try state.markDelta(alloc, .reasoning_text, event.item_id, event.output_index, event.content_index, event.summary_index);
            const reasoning = try state.ensureReasoning(alloc, event.item_id, event.output_index);
            try reasoning.content.appendSlice(alloc, event.delta);
            if (reasoning.summary.items.len == 0) {
                if (callbacks.on_reasoning_chunk) |callback| callback(callbacks.context, event.delta);
            }
        },
        .reasoning_text_done => |event| {
            if (!state.sawDelta(.reasoning_text, event.item_id, event.output_index, event.content_index, event.summary_index) and event.text.len > 0) {
                const reasoning = try state.ensureReasoning(alloc, event.item_id, event.output_index);
                try reasoning.content.appendSlice(alloc, event.text);
                if (reasoning.summary.items.len == 0) {
                    if (callbacks.on_reasoning_chunk) |callback| callback(callbacks.context, event.text);
                }
            }
        },
        .function_call_arguments_delta => |event| try appendToolInputDelta(alloc, state, event, .function_json, callbacks),
        .custom_tool_call_input_delta => |event| try appendToolInputDelta(alloc, state, event, .custom_freeform, callbacks),
        .function_call_arguments_done => |event| try replaceToolInput(alloc, state, event, .function_json),
        .custom_tool_call_input_done => |event| try replaceToolInput(alloc, state, event, .custom_freeform),
        .output_item_added => |event| {
            observeHostedWebSearchStart(callbacks, event);
            if (!semanticallyHandlesOutputItem(event.item.kind)) {
                observeUnknown(callbacks, event.item.raw_type, raw_json);
            } else {
                try applyOutputItem(alloc, state, event, false, callbacks);
            }
        },
        .output_item_done => |event| {
            if (!semanticallyHandlesOutputItem(event.item.kind)) {
                const fallback_output_index = if (event.output_index == null)
                    try nextFallbackOutputIndex(state.provider_output_items.items)
                else
                    0;
                const item = try responses_output_items.collectDoneEnvelope(
                    alloc,
                    raw_json,
                    fallback_output_index,
                );
                var item_owned = true;
                errdefer if (item_owned) alloc.free(@constCast(item.json));
                try responses_output_items.upsertOwned(
                    alloc,
                    &state.provider_output_items,
                    item,
                );
                item_owned = false;
                observeHostedWebSearchDone(callbacks, event);
                observeUnknown(callbacks, event.item.raw_type, raw_json);
            } else {
                try applyOutputItem(alloc, state, event, true, callbacks);
            }
        },
        .response_completed => |terminal| {
            try replaceGenerationId(alloc, state, terminal.response_id);
            state.usage = mapUsage(terminal.usage);
            state.finish_reason = if (state.tools.items.len > 0) .tool_calls else .stop;
            try replaceProviderOutputItemsFromTerminal(alloc, state, terminal.output);
            try applyResponseOutputAnnotations(alloc, state, terminal.output);
            try emitCitationSources(alloc, state, callbacks);
            state.terminal = true;
        },
        .response_incomplete => |terminal| {
            try replaceGenerationId(alloc, state, terminal.response_id);
            state.usage = mapUsage(terminal.usage);
            state.finish_reason = incompleteFinishReason(terminal.incomplete_reason);
            try setTerminalDetail(alloc, state, terminal);
            try replaceProviderOutputItemsFromTerminal(alloc, state, terminal.output);
            try applyResponseOutputAnnotations(alloc, state, terminal.output);
            try emitCitationSources(alloc, state, callbacks);
            state.terminal = true;
        },
        .response_failed => |terminal| {
            try replaceGenerationId(alloc, state, terminal.response_id);
            state.usage = mapUsage(terminal.usage);
            state.finish_reason = .provider_error;
            try setTerminalDetail(alloc, state, terminal);
            clearUrlCitations(alloc, state);
            clearProviderOutputItems(alloc, state);
            state.terminal = true;
        },
        .websocket_error => |error_info| {
            state.finish_reason = .provider_error;
            state.failure_detail = try formatFailureDetail(alloc, error_info, null);
            state.failure_metadata = mapFailureMetadata(error_info);
            clearUrlCitations(alloc, state);
            clearProviderOutputItems(alloc, state);
            state.terminal = true;
        },
    }
}

fn observeHostedWebSearchStart(
    callbacks: Callbacks,
    event: responses_protocol.OutputItemEvent,
) void {
    if (event.item.kind != .web_search_call) return;
    const id = event.item.id orelse return;
    if (callbacks.on_provider_tool_start) |callback| {
        callback(callbacks.context, id, "web_search", null);
    }
}

fn observeHostedWebSearchDone(
    callbacks: Callbacks,
    event: responses_protocol.OutputItemEvent,
) void {
    if (event.item.kind != .web_search_call) return;
    const id = event.item.id orelse return;
    const succeeded = if (event.item.status) |status|
        !std.mem.eql(u8, status, "failed") and
            !std.mem.eql(u8, status, "cancelled")
    else
        true;
    if (callbacks.on_provider_tool_done) |callback| {
        callback(
            callbacks.context,
            id,
            "web_search",
            if (event.item.web_search_action) |action| action.detail else null,
            succeeded,
        );
    }
}

fn replaceGenerationId(
    alloc: Allocator,
    state: *Accumulator,
    response_id: ?[]const u8,
) !void {
    const value = response_id orelse return;
    if (state.generation_id) |current| {
        if (std.mem.eql(u8, current, value)) return;
    }
    const replacement = try alloc.dupe(u8, value);
    if (state.generation_id) |current| alloc.free(current);
    state.generation_id = replacement;
}

fn replaceProviderOutputItemsFromTerminal(
    alloc: Allocator,
    state: *Accumulator,
    maybe_output: ?std.json.Value,
) !void {
    if (maybe_output == null) return;
    const authoritative = try responses_output_items.collectTerminalOutput(
        alloc,
        maybe_output,
    );
    if (!try terminalOutputCoversSemanticState(alloc, state, authoritative) or
        !try terminalOutputCoversCollectedProviderItems(
            alloc,
            state.provider_output_items.items,
            authoritative,
        ))
    {
        const item_count = authoritative.len;
        responses_output_items.free(alloc, authoritative);
        debug_trace.logf(
            "responses",
            "event=terminal_output_incomplete semantic_tools={d} semantic_reasoning={d} output_items={d}",
            .{ state.tools.items.len, state.reasoning_items.items.len, item_count },
        );
        return;
    }
    clearProviderOutputItems(alloc, state);
    state.provider_output_items = .fromOwnedSlice(authoritative);
    state.provider_output_sequence_complete = true;
}

fn terminalOutputCoversCollectedProviderItems(
    alloc: Allocator,
    collected: []const responses_output_items.Item,
    authoritative: []const responses_output_items.Item,
) !bool {
    for (collected) |item| {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, item.json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const item_type = parsed.value.object.get("type") orelse return false;
        if (item_type != .string or item_type.string.len == 0) return false;
        const item_id = if (parsed.value.object.get("id")) |value|
            if (value == .string) value.string else null
        else
            null;
        const call_id = if (parsed.value.object.get("call_id")) |value|
            if (value == .string) value.string else null
        else
            null;
        if (!try terminalItemMatches(
            alloc,
            authoritative,
            item.output_index,
            item_type.string,
            item_id,
            call_id,
        )) return false;
    }
    return true;
}

fn terminalOutputCoversSemanticState(
    alloc: Allocator,
    state: *const Accumulator,
    items: []const responses_output_items.Item,
) !bool {
    if (state.message_output_index_ambiguous) return false;
    if (state.message_output_index) |output_index| {
        if (!try terminalItemMatches(alloc, items, output_index, "message", null, null)) return false;
    }
    for (state.reasoning_items.items) |reasoning| {
        const output_index = reasoning.output_index orelse return false;
        if (!try terminalItemMatches(
            alloc,
            items,
            output_index,
            "reasoning",
            if (reasoning.item_id.items.len > 0) reasoning.item_id.items else null,
            null,
        )) return false;
    }
    for (state.tools.items) |tool| {
        const output_index = tool.output_index orelse return false;
        const expected_type: []const u8 = switch (tool.input_kind) {
            .function_json => "function_call",
            .custom_freeform => "custom_tool_call",
            .unknown => return false,
        };
        if (!try terminalItemMatches(
            alloc,
            items,
            output_index,
            expected_type,
            if (tool.item_id.items.len > 0) tool.item_id.items else null,
            if (tool.call_id.items.len > 0) tool.call_id.items else null,
        )) return false;
    }
    return true;
}

fn terminalItemMatches(
    alloc: Allocator,
    items: []const responses_output_items.Item,
    output_index: u64,
    expected_type: []const u8,
    expected_id: ?[]const u8,
    expected_call_id: ?[]const u8,
) !bool {
    if (output_index > std.math.maxInt(u32)) return false;
    const index: usize = @intCast(output_index);
    if (index >= items.len or items[index].output_index != output_index) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, items[index].json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const item_type = parsed.value.object.get("type") orelse return false;
    if (item_type != .string or !std.mem.eql(u8, item_type.string, expected_type)) return false;
    if (expected_id) |value| {
        const item_id = parsed.value.object.get("id") orelse return false;
        if (item_id != .string or !std.mem.eql(u8, item_id.string, value)) return false;
    }
    if (expected_call_id) |value| {
        const call_id = parsed.value.object.get("call_id") orelse return false;
        if (call_id != .string or !std.mem.eql(u8, call_id.string, value)) return false;
    }
    return true;
}

fn clearProviderOutputItems(alloc: Allocator, state: *Accumulator) void {
    for (state.provider_output_items.items) |item| {
        alloc.free(@constCast(item.json));
    }
    state.provider_output_items.deinit(alloc);
    state.provider_output_items = .empty;
    state.provider_output_sequence_complete = false;
}

fn observeMessageOutputIndex(state: *Accumulator, output_index: ?u64) !void {
    const value = output_index orelse return;
    if (state.message_output_index_ambiguous) return;
    if (state.message_output_index) |existing| {
        if (existing != value) {
            // Fx concatenates multiple assistant message items into one
            // semantic content projection. That projection has no single
            // truthful wire index, so terminal-output-omitted replay must
            // fail closed if it also needs to merge raw items.
            state.message_output_index = null;
            state.message_output_index_ambiguous = true;
        }
    } else {
        state.message_output_index = value;
    }
}

fn nextFallbackOutputIndex(items: []const responses_output_items.Item) !u32 {
    if (items.len == 0) return 0;
    return std.math.add(u32, items[items.len - 1].output_index, 1) catch
        return error.TooManyResponsesOutputItems;
}

fn observeUnknown(callbacks: Callbacks, wire_type: []const u8, raw_json: []const u8) void {
    debug_trace.logf("responses", "event=unhandled type={s} bytes={d}", .{ wire_type, raw_json.len });
    if (callbacks.on_unknown_event) |callback| {
        callback(callbacks.context, wire_type, raw_json);
    }
}

fn semanticallyHandlesOutputItem(kind: responses_protocol.OutputItemKind) bool {
    return switch (kind) {
        .function_call, .custom_tool_call, .reasoning, .message => true,
        .function_call_output,
        .custom_tool_call_output,
        .web_search_call,
        .file_search_call,
        .image_generation_call,
        .computer_call,
        .local_shell_call,
        .other,
        => false,
    };
}

fn setToolInputKind(tool: *ToolState, input_kind: ToolInputKind) !void {
    if (tool.input_kind == .unknown) {
        tool.input_kind = input_kind;
    } else if (tool.input_kind != input_kind) {
        return error.ConflictingResponsesToolKind;
    }
}

fn appendToolInputDelta(
    alloc: Allocator,
    state: *Accumulator,
    event: responses_protocol.ToolInputDelta,
    input_kind: ToolInputKind,
    callbacks: Callbacks,
) !void {
    const tool = try state.ensureTool(alloc, event.item_id, event.call_id, event.output_index);
    try setToolInputKind(tool, input_kind);
    try tool.arguments.appendSlice(alloc, event.delta);
    if (callbacks.on_tool_input_chunk) |callback| callback(callbacks.context, event.delta);
}

fn replaceToolInput(
    alloc: Allocator,
    state: *Accumulator,
    event: responses_protocol.ToolInputDone,
    input_kind: ToolInputKind,
) !void {
    const tool = try state.ensureTool(alloc, event.item_id, event.call_id, event.output_index);
    try setToolInputKind(tool, input_kind);
    tool.arguments.clearRetainingCapacity();
    try tool.arguments.appendSlice(alloc, event.value);
}

fn appendContent(state: *Accumulator, alloc: Allocator, delta: []const u8, callbacks: Callbacks) !void {
    if (delta.len == 0) return;
    const retained = if (callbacks.content_capture_limit) |limit|
        delta[0..@min(delta.len, limit -| state.content.items.len)]
    else
        delta;
    try state.content.appendSlice(alloc, retained);
    callbacks.on_content_chunk(callbacks.context, delta);
}

fn appendUrlCitation(
    alloc: Allocator,
    state: *Accumulator,
    citation: responses_protocol.UrlCitation,
) !void {
    const title = if (citation.title) |value|
        if (value.len > 0) value else citation.url
    else
        citation.url;
    if (citation.url.len == 0 or
        citation.url.len > max_url_citation_url_bytes or
        title.len > max_url_citation_title_bytes or
        citation.end_index < citation.start_index)
    {
        return;
    }
    for (state.citations.items) |*existing| {
        if (existing.start_index == citation.start_index and
            existing.end_index == citation.end_index and
            std.mem.eql(u8, existing.url, citation.url))
        {
            if (!std.mem.eql(u8, existing.title, title)) {
                const updated_bytes = state.citation_bytes - existing.title.len + title.len;
                if (updated_bytes > max_url_citation_total_bytes) return;
                const owned_title = try alloc.dupe(u8, title);
                alloc.free(existing.title);
                existing.title = owned_title;
                state.citation_bytes = updated_bytes;
            }
            return;
        }
    }
    if (state.citations.items.len >= max_url_citations) return;
    const added_bytes = citation.url.len + title.len;
    if (added_bytes > max_url_citation_total_bytes - state.citation_bytes) return;

    const url = try alloc.dupe(u8, citation.url);
    errdefer alloc.free(url);
    const owned_title = try alloc.dupe(u8, title);
    errdefer alloc.free(owned_title);
    try state.citations.append(alloc, .{
        .url = url,
        .title = owned_title,
        .start_index = citation.start_index,
        .end_index = citation.end_index,
    });
    state.citation_bytes += added_bytes;
}

fn clearUrlCitations(alloc: Allocator, state: *Accumulator) void {
    for (state.citations.items) |*citation| citation.deinit(alloc);
    state.citations.clearRetainingCapacity();
    state.citation_bytes = 0;
}

fn isRenderableCitationUrl(url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://") and
        !std.mem.startsWith(u8, url, "http://"))
    {
        return false;
    }
    for (url) |byte| {
        if (std.ascii.isControl(byte) or std.ascii.isWhitespace(byte) or byte == '<' or byte == '>') return false;
    }
    return true;
}

fn applyMessageAnnotations(
    alloc: Allocator,
    state: *Accumulator,
    maybe_content: ?std.json.Value,
) !void {
    const content = maybe_content orelse return;
    if (content != .array) return;
    for (content.array.items) |part| {
        if (part != .object) continue;
        const annotations = part.object.get("annotations") orelse continue;
        if (annotations != .array) continue;
        for (annotations.array.items) |annotation| {
            if (responses_protocol.urlCitationFromAnnotation(annotation)) |citation| {
                try appendUrlCitation(alloc, state, citation);
            }
        }
    }
}

fn applyResponseOutputAnnotations(
    alloc: Allocator,
    state: *Accumulator,
    maybe_output: ?std.json.Value,
) !void {
    const output = maybe_output orelse return;
    if (output != .array) return;
    for (output.array.items) |item| {
        if (item != .object) continue;
        const item_type = item.object.get("type") orelse continue;
        if (item_type != .string or !std.mem.eql(u8, item_type.string, "message")) continue;
        try applyMessageAnnotations(alloc, state, item.object.get("content"));
    }
}

fn emitCitationSources(
    alloc: Allocator,
    state: *Accumulator,
    callbacks: Callbacks,
) !void {
    if (state.citation_sources_emitted or state.citations.items.len == 0) return;
    state.citation_sources_emitted = true;

    var has_renderable_url = false;
    for (state.citations.items) |citation| {
        if (isRenderableCitationUrl(citation.url)) {
            has_renderable_url = true;
            break;
        }
    }
    if (!has_renderable_url) return;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("\n\nSources:\n");
    for (state.citations.items, 0..) |citation, index| {
        if (!isRenderableCitationUrl(citation.url)) continue;
        var duplicate_url = false;
        for (state.citations.items[0..index]) |prior| {
            if (std.mem.eql(u8, prior.url, citation.url)) {
                duplicate_url = true;
                break;
            }
        }
        if (duplicate_url) continue;
        try out.writer.writeAll("- [");
        try writeMarkdownLinkText(&out.writer, citation.title);
        try out.writer.writeAll("](<");
        try out.writer.writeAll(citation.url);
        try out.writer.writeAll(">)\n");
    }
    try appendContent(state, alloc, out.written(), callbacks);
}

fn writeMarkdownLinkText(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '\\', '[', ']' => {
                try writer.writeByte('\\');
                try writer.writeByte(byte);
            },
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            '\n', '\r', '\t' => try writer.writeByte(' '),
            else => if (!std.ascii.isControl(byte)) try writer.writeByte(byte),
        }
    }
}

fn applyOutputItem(
    alloc: Allocator,
    state: *Accumulator,
    event: responses_protocol.OutputItemEvent,
    finalized: bool,
    callbacks: Callbacks,
) !void {
    const item = event.item;
    switch (item.kind) {
        .function_call => try applyToolOutputItem(alloc, state, event, item.arguments, .function_json, callbacks),
        .custom_tool_call => try applyToolOutputItem(alloc, state, event, item.input, .custom_freeform, callbacks),
        .reasoning => {
            const reasoning = try state.ensureReasoning(alloc, item.id, event.output_index);
            if (item.encrypted_content) |value| {
                reasoning.encrypted_content.clearRetainingCapacity();
                try reasoning.encrypted_content.appendSlice(alloc, value);
            }
            if (finalized) {
                try appendFinalReasoningSummary(alloc, reasoning, item.reasoning_summary, callbacks);
                reasoning.finalized = true;
            }
        },
        .message => {
            try observeMessageOutputIndex(state, event.output_index);
            try applyMessageAnnotations(alloc, state, item.content);
        },
        else => {},
    }
}

fn appendFinalReasoningSummary(
    alloc: Allocator,
    reasoning: *ReasoningState,
    maybe_summary: ?std.json.Value,
    callbacks: Callbacks,
) !void {
    if (reasoning.summary.items.len > 0) return;
    const summary = maybe_summary orelse return;
    if (summary != .array) return;
    for (summary.array.items) |part| {
        if (part != .object) continue;
        const part_type = part.object.get("type") orelse continue;
        if (part_type != .string or !std.mem.eql(u8, part_type.string, "summary_text")) continue;
        const text = part.object.get("text") orelse continue;
        if (text != .string or text.string.len == 0) continue;
        try reasoning.summary.appendSlice(alloc, text.string);
        if (callbacks.on_reasoning_chunk) |callback| callback(callbacks.context, text.string);
    }
}

fn applyToolOutputItem(
    alloc: Allocator,
    state: *Accumulator,
    event: responses_protocol.OutputItemEvent,
    input: ?[]const u8,
    input_kind: ToolInputKind,
    callbacks: Callbacks,
) !void {
    const item = event.item;
    const tool = try state.ensureTool(alloc, item.id, item.call_id, event.output_index);
    try setToolInputKind(tool, input_kind);
    if (try localToolName(item)) |name| {
        if (tool.name.items.len == 0) try tool.name.appendSlice(alloc, name) else if (!std.mem.eql(u8, tool.name.items, name)) return error.ConflictingResponsesToolName;
    }
    if (input) |value| {
        tool.arguments.clearRetainingCapacity();
        try tool.arguments.appendSlice(alloc, value);
    }
    if (!tool.start_reported and tool.call_id.items.len > 0 and tool.name.items.len > 0) {
        tool.start_reported = true;
        if (callbacks.on_tool_start) |callback| callback(
            callbacks.context,
            tool.call_id.items,
            tool.name.items,
            null,
        );
    }
}

fn localToolName(item: responses_protocol.OutputItem) !?[]const u8 {
    const namespace = item.namespace orelse return item.name;
    const name = item.name orelse return error.InvalidResponsesToolCall;
    if (std.mem.eql(u8, namespace, "web") and std.mem.eql(u8, name, "run")) {
        return "web_search";
    }
    return error.UnsupportedResponsesNamespaceTool;
}

fn mapUsage(usage: responses_protocol.Usage) types.Usage {
    return .{
        .input_tokens = usage.input_tokens,
        .output_tokens = usage.output_tokens,
        .cached_input_tokens = usage.cached_input_tokens,
        .cache_write_input_tokens = usage.cache_write_input_tokens,
        .reasoning_output_tokens = usage.reasoning_output_tokens,
        .total_tokens = usage.total_tokens,
        .codex_rollout_budget_units = usage.codex_rollout_budget_units,
    };
}

fn incompleteFinishReason(reason: ?[]const u8) types.ProviderFinishReason {
    const value = reason orelse return .provider_error;
    if (std.mem.eql(u8, value, "max_output_tokens") or
        std.mem.eql(u8, value, "length")) return .length;
    if (std.mem.eql(u8, value, "content_filter")) return .content_filter;
    return .provider_error;
}

fn setTerminalDetail(
    alloc: Allocator,
    state: *Accumulator,
    terminal: responses_protocol.Terminal,
) !void {
    if (terminal.error_info) |info| {
        state.failure_detail = try formatFailureDetail(alloc, info, terminal.incomplete_reason);
        state.failure_metadata = mapFailureMetadata(info);
    } else if (terminal.incomplete_reason) |reason| {
        state.failure_detail = try alloc.dupe(u8, reason[0..@min(reason.len, max_failure_detail_bytes)]);
    }
}

fn mapFailureMetadata(info: responses_protocol.ResponseError) types.ProviderFailureMetadata {
    return .{
        .kind = if (isRateLimitFailure(info))
            .rate_limited
        else if (info.status_code != null and info.status_code.? >= 500)
            .provider_unavailable
        else
            .unknown,
        .status_code = info.status_code,
        .retry_after_seconds = roundedRetryAfterSeconds(info.retry_after_seconds),
        .resets_at = info.resets_at,
    };
}

fn isRateLimitFailure(info: responses_protocol.ResponseError) bool {
    if (info.status_code == 429 or info.resets_at != null) return true;
    for ([_]?[]const u8{ info.code, info.error_type }) |candidate| {
        const value = candidate orelse continue;
        if (std.mem.find(u8, value, "rate_limit") != null or
            std.mem.find(u8, value, "rate-limit") != null or
            std.mem.find(u8, value, "usage_limit") != null)
        {
            return true;
        }
    }
    return false;
}

fn roundedRetryAfterSeconds(value: ?f64) ?u64 {
    const seconds = value orelse return null;
    if (!std.math.isFinite(seconds) or seconds < 0) return null;
    const rounded = @ceil(seconds);
    if (rounded >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
        return std.math.maxInt(u64);
    }
    return @intFromFloat(rounded);
}

fn formatFailureDetail(
    alloc: Allocator,
    info: responses_protocol.ResponseError,
    fallback: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    if (info.code) |code| try out.writer.print("{s}: ", .{code}) else if (info.error_type) |kind| try out.writer.print("{s}: ", .{kind});
    try out.writer.writeAll(info.message orelse fallback orelse "Responses request failed");
    if (out.written().len <= max_failure_detail_bytes) return out.toOwnedSlice();
    const clipped = try alloc.dupe(u8, out.written()[0..max_failure_detail_bytes]);
    out.deinit();
    return clipped;
}

fn materialize(alloc: Allocator, state: *Accumulator) !types.ModelCompletion {
    var completion: types.ModelCompletion = .{};
    errdefer freeCompletion(alloc, &completion);
    if (state.content.items.len > 0) completion.content = try alloc.dupe(u8, state.content.items);
    completion.responses_message_output_index = try optionalOutputIndex(state.message_output_index);
    completion.reasoning_items = try materializeReasoningItems(alloc, state.reasoning_items.items);
    if (completion.reasoning_items.len == 1) {
        if (completion.reasoning_items[0].id) |value| {
            completion.reasoning_item_id = try alloc.dupe(u8, value);
        }
        if (completion.reasoning_items[0].encrypted_content) |value| {
            completion.reasoning_encrypted_content = try alloc.dupe(u8, value);
        }
    }
    completion.reasoning = try materializeReasoningText(alloc, state.reasoning_items.items);
    completion.responses_provider_output_items = try responses_output_items.dupe(
        alloc,
        state.provider_output_items.items,
    );
    completion.responses_output_sequence_complete = state.provider_output_sequence_complete;
    completion.url_citations = try materializeUrlCitations(alloc, state.citations.items);
    if (state.finish_reason == .tool_calls) {
        completion.tool_calls = try materializeTools(alloc, state.tools.items);
    }
    completion.provider_failure_detail = if (state.failure_detail) |detail| try alloc.dupe(u8, detail) else null;
    completion.provider_failure_metadata = state.failure_metadata;
    completion.finish_reason = state.finish_reason;
    completion.generation_id = state.generation_id;
    state.generation_id = null;
    completion.usage = state.usage;
    return completion;
}

fn materializeUrlCitations(
    alloc: Allocator,
    citations: []const CitationState,
) ![]const types.ResponsesUrlCitation {
    if (citations.len == 0) return &.{};
    const views = try alloc.alloc(types.ResponsesUrlCitation, citations.len);
    defer alloc.free(views);
    for (citations, 0..) |citation, index| {
        views[index] = .{
            .url = citation.url,
            .title = citation.title,
            .start_index = citation.start_index,
            .end_index = citation.end_index,
        };
    }
    return try types.dupeResponsesUrlCitations(alloc, views);
}

fn materializeReasoningText(
    alloc: Allocator,
    states: []const ReasoningState,
) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const order = try orderedReasoningStateIndices(alloc, states, false);
    defer if (order.len > 0) alloc.free(order);
    for (order) |state_index| {
        const state = states[state_index];
        const text = if (state.summary.items.len > 0) state.summary.items else state.content.items;
        try out.appendSlice(alloc, text);
    }
    if (out.items.len == 0) {
        out.deinit(alloc);
        return null;
    }
    return try out.toOwnedSlice(alloc);
}

fn materializeReasoningItems(
    alloc: Allocator,
    states: []const ReasoningState,
) ![]const types.ResponsesReasoningItem {
    const order = try orderedReasoningStateIndices(alloc, states, true);
    defer if (order.len > 0) alloc.free(order);
    if (order.len == 0) return &.{};

    const projected = try alloc.alloc(types.ResponsesReasoningItem, order.len);
    defer alloc.free(projected);
    for (order, 0..) |state_index, i| {
        const state = states[state_index];
        const summary = if (state.summary.items.len > 0) state.summary.items else state.content.items;
        projected[i] = .{
            .output_index = try optionalOutputIndex(state.output_index),
            .id = if (state.item_id.items.len > 0) state.item_id.items else null,
            .summary = if (summary.len > 0) summary else null,
            .encrypted_content = if (state.encrypted_content.items.len > 0) state.encrypted_content.items else null,
        };
    }
    return try types.dupeResponsesReasoningItems(alloc, projected);
}

fn optionalOutputIndex(value: ?u64) !?u32 {
    const index = value orelse return null;
    if (index > std.math.maxInt(u32)) return error.InvalidResponsesOutput;
    return @intCast(index);
}

fn orderedReasoningStateIndices(
    alloc: Allocator,
    states: []const ReasoningState,
    finalized_only: bool,
) ![]usize {
    var count: usize = 0;
    for (states) |state| {
        if (!finalized_only or state.finalized) count += 1;
    }
    if (count == 0) return &.{};
    const indices = try alloc.alloc(usize, count);
    var len: usize = 0;
    for (states, 0..) |state, state_index| {
        if (finalized_only and !state.finalized) continue;
        var insertion = len;
        while (insertion > 0 and reasoningStateComesBefore(
            states,
            state_index,
            indices[insertion - 1],
        )) : (insertion -= 1) {
            indices[insertion] = indices[insertion - 1];
        }
        indices[insertion] = state_index;
        len += 1;
    }
    return indices;
}

fn reasoningStateComesBefore(
    states: []const ReasoningState,
    lhs_index: usize,
    rhs_index: usize,
) bool {
    const lhs = states[lhs_index].output_index;
    const rhs = states[rhs_index].output_index;
    if (lhs != null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    if (lhs.? != rhs.?) return lhs.? < rhs.?;
    return lhs_index < rhs_index;
}

fn materializeTools(alloc: Allocator, tools: []const ToolState) ![]const types.ToolCall {
    if (tools.len == 0) return &.{};
    const order = try orderedToolStateIndices(alloc, tools);
    defer alloc.free(order);
    const output = try alloc.alloc(types.ToolCall, tools.len);
    var initialized: usize = 0;
    errdefer {
        for (output[0..initialized]) |call| types.freeToolCall(alloc, call);
        alloc.free(output);
    }
    for (order, 0..) |tool_index, index| {
        output[index] = try materializeTool(alloc, tools[tool_index]);
        initialized += 1;
    }
    return output;
}

fn orderedToolStateIndices(alloc: Allocator, tools: []const ToolState) ![]usize {
    const indices = try alloc.alloc(usize, tools.len);
    var len: usize = 0;
    for (tools, 0..) |tool, tool_index| {
        _ = tool;
        var insertion = len;
        while (insertion > 0 and toolStateComesBefore(
            tools,
            tool_index,
            indices[insertion - 1],
        )) : (insertion -= 1) {
            indices[insertion] = indices[insertion - 1];
        }
        indices[insertion] = tool_index;
        len += 1;
    }
    return indices;
}

fn toolStateComesBefore(
    tools: []const ToolState,
    lhs_index: usize,
    rhs_index: usize,
) bool {
    const lhs = tools[lhs_index].output_index;
    const rhs = tools[rhs_index].output_index;
    if (lhs != null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    if (lhs.? != rhs.?) return lhs.? < rhs.?;
    return lhs_index < rhs_index;
}

fn materializeTool(alloc: Allocator, tool: ToolState) !types.ToolCall {
    if (tool.call_id.items.len == 0 or tool.name.items.len == 0) {
        return error.InvalidResponsesToolCall;
    }
    if (tool.input_kind == .unknown) return error.InvalidResponsesToolCall;
    const input = if (tool.arguments.items.len > 0)
        tool.arguments.items
    else if (tool.input_kind == .custom_freeform)
        ""
    else
        "{}";
    const id = try alloc.dupe(u8, tool.call_id.items);
    errdefer alloc.free(id);
    const responses_item_id = if (tool.item_id.items.len > 0)
        try alloc.dupe(u8, tool.item_id.items)
    else
        null;
    errdefer if (responses_item_id) |value| alloc.free(value);
    const name = try alloc.dupe(u8, tool.name.items);
    errdefer alloc.free(name);
    // The shared ToolCall contract stores JSON, while Responses custom tools
    // deliberately carry arbitrary plaintext. Encoding that plaintext as a
    // JSON string preserves every byte and prevents valid freeform input from
    // being mislabeled as malformed function arguments.
    const encoded_arguments = if (tool.input_kind == .custom_freeform)
        try stringifyJsonStringOwned(alloc, input)
    else
        try alloc.dupe(u8, input);
    defer alloc.free(encoded_arguments);
    const argument_integrity = try types.ToolArgumentIntegrity.classifySerialized(
        alloc,
        encoded_arguments,
    );
    // A rejected malformed call still enters paired history so the model can
    // recover on its next step. Keep the integrity marker, but never persist
    // invalid JSON into the standard Responses input contract.
    const arguments_json = try alloc.dupe(
        u8,
        if (argument_integrity == .malformed_json) "{}" else encoded_arguments,
    );
    errdefer alloc.free(arguments_json);
    return .{
        .id = id,
        .name = name,
        .arguments_json = arguments_json,
        .argument_integrity = argument_integrity,
        .responses_item_id = responses_item_id,
        .responses_output_index = try optionalOutputIndex(tool.output_index),
    };
}

fn stringifyJsonStringOwned(alloc: Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn freeCompletion(alloc: Allocator, completion: *types.ModelCompletion) void {
    if (completion.content) |value| alloc.free(@constCast(value));
    if (completion.reasoning) |value| alloc.free(@constCast(value));
    if (completion.reasoning_item_id) |value| alloc.free(@constCast(value));
    if (completion.reasoning_encrypted_content) |value| alloc.free(@constCast(value));
    types.freeResponsesReasoningItems(alloc, completion.reasoning_items);
    types.freeResponsesProviderOutputItems(alloc, completion.responses_provider_output_items);
    types.freeResponsesUrlCitations(alloc, completion.url_citations);
    types.freeToolCallSlice(alloc, @constCast(completion.tool_calls));
    if (completion.generation_id) |value| alloc.free(@constCast(value));
    if (completion.provider_failure_detail) |value| alloc.free(@constCast(value));
    completion.* = .{};
}

const FrameRead = union(enum) {
    data: []const u8,
    done,
    ignored,
    read_failed,
    eof,
};

const LineRead = union(enum) { line: []const u8, read_failed, eof };

/// SSE framing: joins repeated `data:` fields with a newline and ignores
/// comments and non-data fields. The event name is intentionally not trusted;
/// the JSON `type` discriminator is the Responses wire contract.
const FrameReader = struct {
    pending_line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,

    fn deinit(self: *FrameReader, alloc: Allocator) void {
        self.pending_line.deinit(alloc);
        self.data.deinit(alloc);
    }

    fn next(self: *FrameReader, alloc: Allocator, reader: anytype) !FrameRead {
        self.data.clearRetainingCapacity();
        var saw_data_field = false;
        while (true) {
            self.pending_line.clearRetainingCapacity();
            const line = switch (try self.readLine(alloc, reader)) {
                .line => |value| value,
                .read_failed => return .read_failed,
                .eof => {
                    if (saw_data_field) return self.finishData();
                    return .eof;
                },
            };
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len == 0) {
                if (!saw_data_field) return .ignored;
                return self.finishData();
            }
            if (trimmed[0] == ':') continue;
            if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
            var value = trimmed["data:".len..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            const separator_bytes: usize = if (saw_data_field) 1 else 0;
            if (!sseDataFieldFits(self.data.items.len, value.len, separator_bytes)) {
                return error.ResponsesSseEventTooLarge;
            }
            if (separator_bytes > 0) try self.data.append(alloc, '\n');
            try self.data.appendSlice(alloc, value);
            saw_data_field = true;
        }
    }

    fn finishData(self: *FrameReader) FrameRead {
        if (std.mem.eql(u8, self.data.items, "[DONE]") or std.mem.eql(u8, self.data.items, "DONE")) return .done;
        return .{ .data = self.data.items };
    }

    fn readLine(self: *FrameReader, alloc: Allocator, reader: anytype) !LineRead {
        while (true) {
            const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const buffered = reader.buffered();
                    if (buffered.len == 0) return error.ResponsesSseReadStalled;
                    if (buffered.len > max_sse_line_bytes - self.pending_line.items.len) return error.ResponsesSseEventTooLarge;
                    try self.pending_line.appendSlice(alloc, buffered);
                    reader.tossBuffered();
                    continue;
                },
                error.ReadFailed => return .read_failed,
            } orelse {
                if (self.pending_line.items.len > 0) return .{ .line = self.pending_line.items };
                return .eof;
            };
            if (fragment.len > max_sse_line_bytes - self.pending_line.items.len) return error.ResponsesSseEventTooLarge;
            if (self.pending_line.items.len == 0) return .{ .line = fragment };
            try self.pending_line.appendSlice(alloc, fragment);
            return .{ .line = self.pending_line.items };
        }
    }
};

fn sseDataFieldFits(current_len: usize, value_len: usize, separator_bytes: usize) bool {
    if (separator_bytes > max_sse_event_bytes) return false;
    if (current_len > max_sse_event_bytes - separator_bytes) return false;
    return value_len <= max_sse_event_bytes - separator_bytes - current_len;
}

test "Responses stream joins SSE data lines and retains reasoning tool and usage" {
    const payload =
        "event: response.reasoning_summary_text.delta\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\n" ++
        "data: \"delta\":\"think\"}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"read_file\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_1\",\"delta\":\"{\\\"path\\\":\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_1\",\"delta\":\"\\\"a.txt\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"opaque\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":9,\"input_tokens_details\":{\"cached_tokens\":2},\"output_tokens\":4,\"output_tokens_details\":{\"reasoning_tokens\":1},\"total_tokens\":13}}}\n\n";
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    const Noop = struct {
        fn chunk(_: *anyopaque, _: []const u8) void {}
    };
    var context: u8 = 0;
    var completion = try consume(std.testing.allocator, &reader, .{
        .context = &context,
        .on_content_chunk = Noop.chunk,
        .on_reasoning_chunk = Noop.chunk,
        .on_tool_input_chunk = Noop.chunk,
    }, &cancel);
    defer freeCompletion(std.testing.allocator, &completion);

    try std.testing.expectEqualStrings("think", completion.reasoning.?);
    try std.testing.expectEqualStrings("rs_1", completion.reasoning_item_id.?);
    try std.testing.expectEqualStrings("opaque", completion.reasoning_encrypted_content.?);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqualStrings("resp_1", completion.generation_id.?);
    try std.testing.expectEqual(@as(?u64, 2), completion.usage.cached_input_tokens);
    try std.testing.expectEqual(@as(?u64, 1), completion.usage.reasoning_output_tokens);
}

test "Responses malformed function arguments retain rejection and valid history JSON" {
    const payload =
        "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_bad\",\"call_id\":\"call_bad\",\"name\":\"read_file\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_bad\",\"call_id\":\"call_bad\",\"output_index\":0,\"arguments\":\"{\\\"path\\\":\\\"a\\\",\\\"path\\\":\\\"b\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    const Noop = struct {
        fn chunk(_: *anyopaque, _: []const u8) void {}
    };
    var context: u8 = 0;
    var completion = try consume(std.testing.allocator, &reader, .{
        .context = &context,
        .on_content_chunk = Noop.chunk,
    }, &cancel);
    defer freeCompletion(std.testing.allocator, &completion);

    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqual(
        types.ToolArgumentIntegrity.malformed_json,
        completion.tool_calls[0].argument_integrity,
    );
    try std.testing.expectEqualStrings("{}", completion.tool_calls[0].arguments_json);
}

test "Responses namespace web run maps to the local permissioned web search tool" {
    const payload =
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_web\",\"call_id\":\"call_web\",\"namespace\":\"web\",\"name\":\"run\",\"arguments\":\"{\\\"search_query\\\":[{\\\"q\\\":\\\"Zig news\\\"}]}\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n";
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    const Noop = struct {
        fn chunk(_: *anyopaque, _: []const u8) void {}
    };
    var context: u8 = 0;
    var completion = try consume(std.testing.allocator, &reader, .{
        .context = &context,
        .on_content_chunk = Noop.chunk,
    }, &cancel);
    defer freeCompletion(std.testing.allocator, &completion);

    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("web_search", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("fc_web", completion.tool_calls[0].responses_item_id.?);
    try std.testing.expect(!completion.responses_output_sequence_complete);
    try std.testing.expectEqualStrings(
        "{\"search_query\":[{\"q\":\"Zig news\"}]}",
        completion.tool_calls[0].arguments_json,
    );
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
}

test "Responses stream rejects unadvertised namespace tools" {
    try std.testing.expectError(error.UnsupportedResponsesNamespaceTool, localToolName(.{
        .kind = .function_call,
        .raw_type = "function_call",
        .namespace = "future",
        .name = "run",
    }));
}

test "Responses failed terminal retains error and ignores partial tool state" {
    const payload =
        "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_partial\",\"delta\":\"{\"}\n\n" ++
        "data: {\"type\":\"response.output_text.annotation.added\",\"item_id\":\"msg_partial\",\"annotation\":{\"type\":\"url_citation\",\"url\":\"https://example.com/partial\",\"title\":\"Partial\",\"start_index\":0,\"end_index\":1}}\n\n" ++
        "data: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"type\":\"rate_limit_error\",\"code\":\"overloaded\",\"message\":\"try later\",\"status_code\":429,\"retry_after_seconds\":1.5,\"resets_at\":12345},\"usage\":{\"input_tokens\":5,\"output_tokens\":1}}}\n\n";
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    const Noop = struct {
        fn chunk(_: *anyopaque, _: []const u8) void {}
    };
    var context: u8 = 0;
    var completion = try consume(std.testing.allocator, &reader, .{
        .context = &context,
        .on_content_chunk = Noop.chunk,
    }, &cancel);
    defer freeCompletion(std.testing.allocator, &completion);

    try std.testing.expectEqual(types.ProviderFinishReason.provider_error, completion.finish_reason.?);
    try std.testing.expectEqual(@as(usize, 0), completion.tool_calls.len);
    try std.testing.expectEqual(@as(usize, 0), completion.url_citations.len);
    try std.testing.expect(completion.content == null);
    try std.testing.expectEqualStrings("overloaded: try later", completion.provider_failure_detail.?);
    try std.testing.expectEqual(@as(?u64, 5), completion.usage.input_tokens);
    const metadata = completion.provider_failure_metadata.?;
    try std.testing.expectEqual(types.ProviderFailureKind.rate_limited, metadata.kind);
    try std.testing.expectEqual(@as(?u16, 429), metadata.status_code);
    try std.testing.expectEqual(@as(?u64, 2), metadata.retry_after_seconds);
    try std.testing.expectEqual(@as(?i64, 12345), metadata.resets_at);
}

test "Responses tool identity conflicts are rejected" {
    const payload =
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_1\",\"name\":\"read_file\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_2\",\"name\":\"read_file\",\"arguments\":\"{}\"}}\n\n";
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    const Noop = struct {
        fn chunk(_: *anyopaque, _: []const u8) void {}
    };
    var context: u8 = 0;
    try std.testing.expectError(
        error.ConflictingResponsesToolIdentity,
        consume(std.testing.allocator, &reader, .{
            .context = &context,
            .on_content_chunk = Noop.chunk,
        }, &cancel),
    );
}

test "Responses finalized reasoning items preserve order and opaque identity pairing" {
    const payload =
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_2\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"second\"}],\"encrypted_content\":\"opaque-2\"}}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0,\"delta\":\"first\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"opaque-1\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    const Noop = struct {
        fn chunk(_: *anyopaque, _: []const u8) void {}
    };
    var context: u8 = 0;
    var completion = try consume(std.testing.allocator, &reader, .{
        .context = &context,
        .on_content_chunk = Noop.chunk,
    }, &cancel);
    defer freeCompletion(std.testing.allocator, &completion);
    try std.testing.expectEqualStrings("firstsecond", completion.reasoning.?);
    try std.testing.expect(completion.reasoning_item_id == null);
    try std.testing.expect(completion.reasoning_encrypted_content == null);
    try std.testing.expectEqual(@as(usize, 2), completion.reasoning_items.len);
    try std.testing.expectEqualStrings("rs_1", completion.reasoning_items[0].id.?);
    try std.testing.expectEqualStrings("first", completion.reasoning_items[0].summary.?);
    try std.testing.expectEqualStrings("opaque-1", completion.reasoning_items[0].encrypted_content.?);
    try std.testing.expectEqualStrings("rs_2", completion.reasoning_items[1].id.?);
    try std.testing.expectEqualStrings("second", completion.reasoning_items[1].summary.?);
    try std.testing.expectEqualStrings("opaque-2", completion.reasoning_items[1].encrypted_content.?);
}

test "Responses reasoning identity rejects either id or output index conflicts" {
    const payloads = [_][]const u8{
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0,\"delta\":\"first\"}\n\n" ++
            "data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"output_index\":1,\"summary_index\":0,\"delta\":\"wrong\"}\n\n",
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0,\"delta\":\"first\"}\n\n" ++
            "data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_2\",\"output_index\":0,\"summary_index\":0,\"delta\":\"wrong\"}\n\n",
    };
    const Noop = struct {
        fn chunk(_: *anyopaque, _: []const u8) void {}
    };
    for (payloads) |payload| {
        var reader = std.Io.Reader.fixed(payload);
        var cancel = std.atomic.Value(bool).init(false);
        var context: u8 = 0;
        try std.testing.expectError(
            error.ConflictingResponsesReasoningIdentity,
            consume(std.testing.allocator, &reader, .{
                .context = &context,
                .on_content_chunk = Noop.chunk,
            }, &cancel),
        );
    }
}

test "Responses reasoning text callback is scoped to its own summary item" {
    const payload =
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0,\"delta\":\"summary-one\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"opaque-1\"}}\n\n" ++
        "data: {\"type\":\"response.reasoning_text.delta\",\"item_id\":\"rs_2\",\"output_index\":1,\"content_index\":0,\"delta\":\"text-two\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_2\",\"encrypted_content\":\"opaque-2\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";
    const Capture = struct {
        bytes: [64]u8 = undefined,
        len: usize = 0,

        fn content(_: *anyopaque, _: []const u8) void {}
        fn reasoning(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            @memcpy(self.bytes[self.len..][0..chunk.len], chunk);
            self.len += chunk.len;
        }
    };
    var capture: Capture = .{};
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    var completion = try consume(std.testing.allocator, &reader, .{
        .context = &capture,
        .on_content_chunk = Capture.content,
        .on_reasoning_chunk = Capture.reasoning,
    }, &cancel);
    defer freeCompletion(std.testing.allocator, &completion);
    try std.testing.expectEqualStrings("summary-onetext-two", capture.bytes[0..capture.len]);
    try std.testing.expectEqualStrings("summary-onetext-two", completion.reasoning.?);
    try std.testing.expectEqualStrings("summary-one", completion.reasoning_items[0].summary.?);
    try std.testing.expectEqualStrings("text-two", completion.reasoning_items[1].summary.?);
}

test "Responses incomplete and error events retain typed retry metadata" {
    const payloads = [_]struct {
        payload: []const u8,
        expected_kind: types.ProviderFailureKind,
        expected_status: ?u16,
        expected_retry: ?u64,
        expected_reset: ?i64,
    }{
        .{
            .payload = "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"provider_error\",\"status_code\":503,\"retry_after_seconds\":3}}}\n\n",
            .expected_kind = .provider_unavailable,
            .expected_status = 503,
            .expected_retry = 3,
            .expected_reset = null,
        },
        .{
            .payload = "data: {\"type\":\"error\",\"error\":{\"type\":\"usage_limit_error\",\"code\":\"usage_limit_reached\",\"message\":\"window exhausted\",\"resets_at\":777}}\n\n",
            .expected_kind = .rate_limited,
            .expected_status = null,
            .expected_retry = null,
            .expected_reset = 777,
        },
    };
    const Noop = struct {
        fn chunk(_: *anyopaque, _: []const u8) void {}
    };
    for (payloads) |case| {
        var reader = std.Io.Reader.fixed(case.payload);
        var cancel = std.atomic.Value(bool).init(false);
        var context: u8 = 0;
        var completion = try consume(std.testing.allocator, &reader, .{
            .context = &context,
            .on_content_chunk = Noop.chunk,
        }, &cancel);
        defer freeCompletion(std.testing.allocator, &completion);
        const metadata = completion.provider_failure_metadata.?;
        try std.testing.expectEqual(case.expected_kind, metadata.kind);
        try std.testing.expectEqual(case.expected_status, metadata.status_code);
        try std.testing.expectEqual(case.expected_retry, metadata.retry_after_seconds);
        try std.testing.expectEqual(case.expected_reset, metadata.resets_at);
    }
}

test "Responses done events supply content when deltas are absent" {
    const payload =
        "data: {\"type\":\"response.output_text.done\",\"item_id\":\"msg_1\",\"text\":\"answer\"}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.done\",\"item_id\":\"rs_1\",\"text\":\"thought\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    const Noop = struct {
        fn chunk(_: *anyopaque, _: []const u8) void {}
    };
    var context: u8 = 0;
    var completion = try consume(std.testing.allocator, &reader, .{
        .context = &context,
        .on_content_chunk = Noop.chunk,
        .on_reasoning_chunk = Noop.chunk,
    }, &cancel);
    defer freeCompletion(std.testing.allocator, &completion);
    try std.testing.expectEqualStrings("answer", completion.content.?);
    try std.testing.expectEqualStrings("thought", completion.reasoning.?);
}

test "Responses hosted search citations are owned rendered and deduplicated" {
    const payload =
        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"Latest.\"}\n\n" ++
        "data: {\"type\":\"response.output_text.annotation.added\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"annotation_index\":0,\"annotation\":{\"type\":\"url_citation\",\"url\":\"https://example.com/source\",\"title\":\"Example [source]\",\"start_index\":0,\"end_index\":7}}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Latest.\",\"annotations\":[{\"type\":\"url_citation\",\"url\":\"https://example.com/source\",\"title\":\"Example [source]\",\"start_index\":0,\"end_index\":7}]}]}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"id\":\"msg_1\",\"content\":[{\"type\":\"output_text\",\"text\":\"Latest.\",\"annotations\":[{\"type\":\"url_citation\",\"url\":\"https://example.org/fallback\",\"title\":\"Terminal fallback\",\"start_index\":0,\"end_index\":7}]}]}]}}\n\n";
    const expected = "Latest.\n\nSources:\n- [Example \\[source\\]](<https://example.com/source>)\n- [Terminal fallback](<https://example.org/fallback>)\n";
    const Capture = struct {
        bytes: [512]u8 = undefined,
        len: usize = 0,

        fn chunk(raw: *anyopaque, value: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            @memcpy(self.bytes[self.len..][0..value.len], value);
            self.len += value.len;
        }
    };
    var capture: Capture = .{};
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    var completion = try consume(std.testing.allocator, &reader, .{
        .context = &capture,
        .on_content_chunk = Capture.chunk,
    }, &cancel);
    defer freeCompletion(std.testing.allocator, &completion);

    try std.testing.expectEqualStrings(expected, capture.bytes[0..capture.len]);
    try std.testing.expectEqualStrings(expected, completion.content.?);
    try std.testing.expectEqual(@as(usize, 2), completion.url_citations.len);
    const citation = completion.url_citations[0];
    try std.testing.expectEqualStrings("https://example.com/source", citation.url);
    try std.testing.expectEqualStrings("Example [source]", citation.title);
    try std.testing.expectEqual(@as(u64, 0), citation.start_index);
    try std.testing.expectEqual(@as(u64, 7), citation.end_index);
    try std.testing.expectEqualStrings("https://example.org/fallback", completion.url_citations[1].url);
}

test "Responses done fallback is scoped to each output item" {
    const payload =
        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"first\"}\n\n" ++
        "data: {\"type\":\"response.output_text.done\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"text\":\"first\"}\n\n" ++
        "data: {\"type\":\"response.output_text.done\",\"item_id\":\"msg_2\",\"output_index\":1,\"content_index\":0,\"text\":\"second\"}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"output_index\":2,\"summary_index\":0,\"delta\":\"thought-one\"}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.done\",\"item_id\":\"rs_1\",\"output_index\":2,\"summary_index\":0,\"text\":\"thought-one\"}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.done\",\"item_id\":\"rs_2\",\"output_index\":3,\"summary_index\":0,\"text\":\"thought-two\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    const Noop = struct {
        fn chunk(_: *anyopaque, _: []const u8) void {}
    };
    var context: u8 = 0;
    var completion = try consume(std.testing.allocator, &reader, .{
        .context = &context,
        .on_content_chunk = Noop.chunk,
        .on_reasoning_chunk = Noop.chunk,
    }, &cancel);
    defer freeCompletion(std.testing.allocator, &completion);

    try std.testing.expectEqualStrings("firstsecond", completion.content.?);
    try std.testing.expectEqualStrings("thought-onethought-two", completion.reasoning.?);
    try std.testing.expect(completion.responses_message_output_index == null);
}

test "Responses custom tool freeform input remains valid and lossless" {
    const freeform = "*** Begin Patch\n*** End Patch";
    const payload =
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"custom_tool_call\",\"id\":\"ct_1\",\"call_id\":\"call_1\",\"name\":\"apply_patch\"}}\n\n" ++
        "data: {\"type\":\"response.custom_tool_call_input.delta\",\"item_id\":\"ct_1\",\"call_id\":\"call_1\",\"delta\":\"*** Begin\"}\n\n" ++
        "data: {\"type\":\"response.custom_tool_call_input.done\",\"item_id\":\"ct_1\",\"call_id\":\"call_1\",\"input\":\"*** Begin Patch\\n*** End Patch\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    const Noop = struct {
        fn chunk(_: *anyopaque, _: []const u8) void {}
    };
    var context: u8 = 0;
    var completion = try consume(std.testing.allocator, &reader, .{
        .context = &context,
        .on_content_chunk = Noop.chunk,
        .on_tool_input_chunk = Noop.chunk,
    }, &cancel);
    defer freeCompletion(std.testing.allocator, &completion);

    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqual(types.ToolArgumentIntegrity.valid, completion.tool_calls[0].argument_integrity);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, completion.tool_calls[0].arguments_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .string);
    try std.testing.expectEqualStrings(freeform, parsed.value.string);
}

test "Responses stream exposes exact unknown events and rejects early EOF" {
    const raw = "{\"type\":\"response.future.delta\",\"delta\":\"x\"}";
    const Capture = struct {
        event_type_buf: [64]u8 = undefined,
        raw_json_buf: [128]u8 = undefined,
        event_type_len: usize = 0,
        raw_json_len: usize = 0,
        count: usize = 0,

        fn chunk(_: *anyopaque, _: []const u8) void {}

        fn unknown(raw_context: *anyopaque, event_type: []const u8, raw_json: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw_context));
            self.event_type_len = @min(event_type.len, self.event_type_buf.len);
            self.raw_json_len = @min(raw_json.len, self.raw_json_buf.len);
            @memcpy(self.event_type_buf[0..self.event_type_len], event_type[0..self.event_type_len]);
            @memcpy(self.raw_json_buf[0..self.raw_json_len], raw_json[0..self.raw_json_len]);
            self.count += 1;
        }
    };
    var capture: Capture = .{};
    var cancel = std.atomic.Value(bool).init(false);
    var reader = std.Io.Reader.fixed(
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"future_tool_call\",\"id\":\"future_1\"}}\n\n" ++
            "data: " ++ raw ++ "\n\n",
    );
    try std.testing.expectError(
        error.ResponsesStreamEndedEarly,
        consume(std.testing.allocator, &reader, .{
            .context = &capture,
            .on_content_chunk = Capture.chunk,
            .on_unknown_event = Capture.unknown,
        }, &cancel),
    );

    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqualStrings("response.future.delta", capture.event_type_buf[0..capture.event_type_len]);
    try std.testing.expectEqualStrings(raw, capture.raw_json_buf[0..capture.raw_json_len]);
}

test "Responses stream exposes known output items without semantic projections" {
    const raw = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"web_search_call\",\"id\":\"ws_1\",\"status\":\"completed\"}}";
    const Capture = struct {
        event_type: []const u8 = "",
        raw_json: []const u8 = "",
        event_type_buf: [64]u8 = undefined,
        raw_json_buf: [256]u8 = undefined,
        count: usize = 0,

        fn chunk(_: *anyopaque, _: []const u8) void {}

        fn event(raw_context: *anyopaque, event_type: []const u8, raw_json: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw_context));
            const event_len = @min(event_type.len, self.event_type_buf.len);
            const raw_len = @min(raw_json.len, self.raw_json_buf.len);
            @memcpy(self.event_type_buf[0..event_len], event_type[0..event_len]);
            @memcpy(self.raw_json_buf[0..raw_len], raw_json[0..raw_len]);
            self.event_type = self.event_type_buf[0..event_len];
            self.raw_json = self.raw_json_buf[0..raw_len];
            self.count += 1;
        }
    };
    var capture: Capture = .{};
    var cancel = std.atomic.Value(bool).init(false);
    var reader = std.Io.Reader.fixed(
        "data: " ++ raw ++ "\n\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n",
    );
    var completion = try consume(std.testing.allocator, &reader, .{
        .context = &capture,
        .on_content_chunk = Capture.chunk,
        .on_unknown_event = Capture.event,
    }, &cancel);
    defer freeCompletion(std.testing.allocator, &completion);

    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("web_search_call", capture.event_type);
    try std.testing.expectEqualStrings(raw, capture.raw_json);
    try std.testing.expectEqual(@as(usize, 1), completion.responses_provider_output_items.len);
    try std.testing.expectEqual(@as(u32, 0), completion.responses_provider_output_items[0].output_index);
    try std.testing.expect(std.mem.find(
        u8,
        completion.responses_provider_output_items[0].json,
        "web_search_call",
    ) != null);
}

test "Responses stream publishes hosted web search start and completion" {
    const Capture = struct {
        started: bool = false,
        completed: bool = false,
        label: [64]u8 = undefined,
        label_len: usize = 0,

        fn chunk(_: *anyopaque, _: []const u8) void {}
        fn start(raw: *anyopaque, id: []const u8, name: []const u8, _: ?[]const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.started = std.mem.eql(u8, id, "ws_1") and std.mem.eql(u8, name, "web_search");
        }
        fn done(raw: *anyopaque, id: []const u8, name: []const u8, label: ?[]const u8, succeeded: bool) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.completed = succeeded and std.mem.eql(u8, id, "ws_1") and std.mem.eql(u8, name, "web_search");
            const value = label orelse return;
            self.label_len = @min(value.len, self.label.len);
            @memcpy(self.label[0..self.label_len], value[0..self.label_len]);
        }
    };
    var capture: Capture = .{};
    var cancel = std.atomic.Value(bool).init(false);
    var reader = std.Io.Reader.fixed(
        "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"web_search_call\",\"id\":\"ws_1\",\"status\":\"in_progress\"}}\n\n" ++
            "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"web_search_call\",\"id\":\"ws_1\",\"status\":\"completed\",\"action\":{\"type\":\"search\",\"query\":\"Zig 0.16\"}}}\n\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n",
    );
    var completion = try consume(std.testing.allocator, &reader, .{
        .context = &capture,
        .on_content_chunk = Capture.chunk,
        .on_provider_tool_start = Capture.start,
        .on_provider_tool_done = Capture.done,
    }, &cancel);
    defer freeCompletion(std.testing.allocator, &completion);

    try std.testing.expect(capture.started);
    try std.testing.expect(capture.completed);
    try std.testing.expectEqualStrings("Zig 0.16", capture.label[0..capture.label_len]);
}

test "Responses terminal output authoritatively replaces the full fallback sequence" {
    const payload =
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"web_search_call\",\"id\":\"ws_1\",\"status\":\"in_progress\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"rs_1\"},{\"type\":\"web_search_call\",\"id\":\"ws_1\",\"status\":\"completed\",\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\"}]},{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}]}}\n\n";
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    const Noop = struct {
        fn chunk(_: *anyopaque, _: []const u8) void {}
    };
    var context: u8 = 0;
    var completion = try consume(std.testing.allocator, &reader, .{
        .context = &context,
        .on_content_chunk = Noop.chunk,
    }, &cancel);
    defer freeCompletion(std.testing.allocator, &completion);

    try std.testing.expect(completion.responses_output_sequence_complete);
    try std.testing.expectEqual(@as(usize, 3), completion.responses_provider_output_items.len);
    const item = completion.responses_provider_output_items[1];
    try std.testing.expectEqual(@as(u32, 1), item.output_index);
    try std.testing.expect(std.mem.find(u8, item.json, "\"results\"") != null);
    try std.testing.expect(std.mem.find(u8, item.json, "in_progress") == null);
}

test "Responses terminal empty output retains finalized compaction item" {
    const payload =
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"compaction\",\"id\":\"cmp_1\",\"encrypted_content\":\"opaque\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":12,\"output_tokens\":3,\"total_tokens\":15}}}\n\n";
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    const Noop = struct {
        fn chunk(_: *anyopaque, _: []const u8) void {}
    };
    var context: u8 = 0;
    var completion = try consume(std.testing.allocator, &reader, .{
        .context = &context,
        .on_content_chunk = Noop.chunk,
    }, &cancel);
    defer freeCompletion(std.testing.allocator, &completion);

    try std.testing.expect(!completion.responses_output_sequence_complete);
    try std.testing.expectEqual(@as(usize, 1), completion.responses_provider_output_items.len);
    try std.testing.expectEqual(@as(u32, 0), completion.responses_provider_output_items[0].output_index);
    try std.testing.expect(std.mem.find(
        u8,
        completion.responses_provider_output_items[0].json,
        "\"type\":\"compaction\"",
    ) != null);
    try std.testing.expectEqual(@as(?u64, 15), completion.usage.total_tokens);
}

test "Responses terminal without output retains indexed incomplete projections" {
    const payload =
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0,\"delta\":\"checked\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"opaque\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"web_search_call\",\"id\":\"ws_1\",\"status\":\"completed\"}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":2,\"content_index\":0,\"delta\":\"answer\"}\n\n" ++
        "data: {\"type\":\"response.output_text.done\",\"item_id\":\"msg_1\",\"output_index\":2,\"content_index\":0,\"text\":\"answer\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";
    var reader = std.Io.Reader.fixed(payload);
    var cancel = std.atomic.Value(bool).init(false);
    const Noop = struct {
        fn chunk(_: *anyopaque, _: []const u8) void {}
    };
    var context: u8 = 0;
    var completion = try consume(std.testing.allocator, &reader, .{
        .context = &context,
        .on_content_chunk = Noop.chunk,
    }, &cancel);
    defer freeCompletion(std.testing.allocator, &completion);

    try std.testing.expect(!completion.responses_output_sequence_complete);
    try std.testing.expectEqual(@as(usize, 1), completion.responses_provider_output_items.len);
    try std.testing.expectEqual(@as(u32, 1), completion.responses_provider_output_items[0].output_index);
    try std.testing.expectEqual(@as(usize, 1), completion.reasoning_items.len);
    try std.testing.expectEqual(@as(?u32, 0), completion.reasoning_items[0].output_index);
    try std.testing.expectEqual(@as(?u32, 2), completion.responses_message_output_index);
    try std.testing.expectEqualStrings("answer", completion.content.?);
}

test "Responses SSE event limit includes repeated data separators" {
    try std.testing.expect(sseDataFieldFits(0, max_sse_event_bytes, 0));
    try std.testing.expect(sseDataFieldFits(max_sse_event_bytes - 1, 0, 1));
    try std.testing.expect(!sseDataFieldFits(max_sse_event_bytes, 0, 1));
    try std.testing.expect(!sseDataFieldFits(max_sse_event_bytes - 1, 1, 1));
}

test "Responses stream tolerates unknown events without an observer" {
    const Noop = struct {
        fn chunk(_: *anyopaque, _: []const u8) void {}
    };
    var context: u8 = 0;
    var cancel = std.atomic.Value(bool).init(false);
    var reader = std.Io.Reader.fixed("data: {\"type\":\"response.future.delta\",\"delta\":\"x\"}\n\n");
    try std.testing.expectError(
        error.ResponsesStreamEndedEarly,
        consume(std.testing.allocator, &reader, .{
            .context = &context,
            .on_content_chunk = Noop.chunk,
        }, &cancel),
    );
}
