const std = @import("std");
const stream_provider = @import("../agent/stream_provider.zig");
const responses_compaction_provider = @import("responses_compaction_provider.zig");
const image_attachments = @import("../images/image_attachments.zig");
const responses_output_items = @import("../shared/responses_output_items.zig");
const types = @import("../shared/types.zig");
const message_history = @import("message_history.zig");
const gateway_schema = @import("../tooling/model_tool_schema.zig");
const compaction_binding = @import("responses_compaction_binding.zig");

pub const compaction = @import("responses_compaction.zig");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;
const system_only_continuation_input =
    "Continue from the context in the instructions and complete the pending user request.";

pub const PreparedTools = struct {
    base_json: []u8,
    dynamic_json: [][]u8,

    pub fn deinit(self: *PreparedTools, alloc: Allocator) void {
        alloc.free(self.base_json);
        for (self.dynamic_json) |schema| alloc.free(schema);
        alloc.free(self.dynamic_json);
        self.* = undefined;
    }
};

fn containsToolName(names: []const []const u8, expected: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, expected)) return true;
    return false;
}

/// Serializes one provider-neutral tool selection for any Responses route.
/// Keeping this beside the shared request codec prevents OpenAI and Codex
/// transports from drifting into distinct schema projections.
pub fn prepareTools(
    alloc: Allocator,
    selection: stream_provider.ToolSelection,
) !PreparedTools {
    var base: std.Io.Writer.Allocating = .init(alloc);
    errdefer base.deinit();
    try base.writer.writeByte('[');
    var count: usize = 0;
    for (selection.advertised_names) |name| {
        const schema = selection.advertisedFunction(name) orelse continue;
        if (count > 0) try base.writer.writeByte(',');
        try gateway_schema.writeBuiltinFunctionSchema(alloc, &base.writer, schema);
        count += 1;
    }
    for (selection.additional_functions) |schema| {
        if (containsToolName(selection.advertised_names, schema.name)) continue;
        if (count > 0) try base.writer.writeByte(',');
        try gateway_schema.writeBuiltinFunctionSchema(alloc, &base.writer, schema);
        count += 1;
    }
    try base.writer.writeByte(']');
    const base_json = try base.toOwnedSlice();
    errdefer alloc.free(base_json);

    var dynamic: std.ArrayList([]u8) = .empty;
    errdefer {
        for (dynamic.items) |schema| alloc.free(schema);
        dynamic.deinit(alloc);
    }
    for (selection.selected_dynamic) |tool| {
        if (containsToolName(selection.advertised_names, tool.name)) continue;
        var schema: std.Io.Writer.Allocating = .init(alloc);
        defer schema.deinit();
        try std.json.Stringify.value(tool.input_schema, .{}, &schema.writer);
        const encoded = try gateway_schema.dynamicFunctionSchemaJsonAlloc(
            alloc,
            tool.name,
            tool.description,
            schema.written(),
        );
        try dynamic.append(alloc, encoded);
    }
    return .{
        .base_json = base_json,
        .dynamic_json = try dynamic.toOwnedSlice(alloc),
    };
}

// Request codec

pub const RequestCapabilities = struct {
    supports_max_output_tokens: bool = true,
    supports_prompt_cache_key: bool = true,
    supports_encrypted_reasoning: bool = true,
};

pub const RequestOptions = struct {
    capabilities: RequestCapabilities = .{},
    store: bool = false,
    stream: bool = true,
    include: []const []const u8 = &.{"reasoning.encrypted_content"},
    prompt_cache_key: ?[]const u8 = null,
    service_tier: ?[]const u8 = null,
    reasoning_summary: ?[]const u8 = null,
    function_tools_strict: ?bool = null,
    structured_output_strict: bool = true,
    /// Complete raw Responses `input`. It may be a string or array and is
    /// mutually exclusive with message-derived input (system-only messages
    /// remain available as top-level instructions).
    responses_input_json: ?[]const u8 = null,
    /// Raw Responses `text` and `reasoning` objects. They are merged with fx's
    /// typed subfields, and overlapping keys are rejected.
    responses_text_options_json: ?[]const u8 = null,
    responses_reasoning_options_json: ?[]const u8 = null,
    /// A complete Responses `tool_choice` JSON value. When absent, the value
    /// is projected from `BuildRequest.tool_choice` (or forced to `required`
    /// for a required vision request).
    tool_choice_json: ?[]const u8 = null,
    /// Provider-specific or newly-added Responses fields. Known fields owned
    /// by this codec cannot be overridden through this object.
    extra_fields_json: ?[]const u8 = null,
};

pub fn buildRequest(
    alloc: Allocator,
    request: responses_compaction_provider.BuildRequest,
    options: RequestOptions,
) ![]u8 {
    try checkBudget(request.budget);
    try message_history.validateToolMessageHistory(alloc, request.messages);
    try validateCompactionCheckpointProjection(request);
    const replay_web_namespace = try declaresWebRunNamespace(
        alloc,
        request.serialized_tools,
    );

    var raw_options = try ParsedRawRequestOptions.init(alloc, request, options);
    defer raw_options.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, &out.writer);

    const instructions = try collectInstructions(alloc, request);
    defer if (instructions) |value| alloc.free(value);
    if (instructions) |value| {
        try out.writer.writeAll(",\"instructions\":");
        try std.json.Stringify.value(value, .{}, &out.writer);
    }

    try out.writer.writeAll(",\"input\":");
    if (raw_options.input) |raw_input| {
        if (request.responses_compaction_trigger) {
            try writeInputArrayWithCompactionTrigger(&out.writer, raw_input.value.array.items);
        } else {
            try std.json.Stringify.value(raw_input.value, .{}, &out.writer);
        }
    } else {
        try out.writer.writeByte('[');
        var wrote_item = false;
        const verified_message_index = if (request.verified_images != null)
            lastUserMessageIndex(request.messages) orelse return error.InvalidResponsesHistory
        else
            null;
        for (request.messages, 0..) |message, message_index| {
            try checkBudget(request.budget);
            switch (message.role) {
                .system => {
                    const checkpoint = matchingCompactionCheckpoint(request, message) orelse continue;
                    try writeReplayInputItems(
                        alloc,
                        &out.writer,
                        checkpoint.input_json,
                        &wrote_item,
                    );
                },
                .user => {
                    try writeComma(&out.writer, &wrote_item);
                    try writeUserMessage(
                        alloc,
                        &out.writer,
                        message,
                        if (verified_message_index == message_index) request.verified_images else null,
                        request.budget,
                    );
                },
                .assistant => try writeAssistantItems(
                    alloc,
                    &out.writer,
                    message,
                    options.capabilities,
                    replay_web_namespace,
                    &wrote_item,
                ),
                .tool => {
                    try writeComma(&out.writer, &wrote_item);
                    try writeFunctionCallOutput(&out.writer, message, replay_web_namespace);
                },
            }
        }
        if (request.responses_compaction_trigger) {
            try writeComma(&out.writer, &wrote_item);
            try compaction.writeV2Trigger(&out.writer);
        }
        if (!wrote_item) {
            if (instructions == null) return error.MissingResponsesInput;
            try writeComma(&out.writer, &wrote_item);
            try writeUserMessage(
                alloc,
                &out.writer,
                .{ .role = .user, .content = system_only_continuation_input },
                null,
                request.budget,
            );
        }
        try out.writer.writeByte(']');
    }

    try out.writer.writeAll(",\"tools\":[");
    try writeTools(alloc, &out.writer, request, options.function_tools_strict);
    try out.writer.writeByte(']');

    try out.writer.writeAll(",\"tool_choice\":");
    if (request.vision_mode == .required) {
        try out.writer.writeAll("\"required\"");
    } else if (options.tool_choice_json) |raw_choice| {
        try writeParsedJsonValue(alloc, &out.writer, raw_choice, error.InvalidResponsesToolChoice);
    } else {
        try std.json.Stringify.value(request.tool_choice.label(), .{}, &out.writer);
    }

    if (request.provider_options.parallel_tool_calls) |parallel| {
        try out.writer.writeAll(",\"parallel_tool_calls\":");
        try out.writer.writeAll(if (parallel) "true" else "false");
    }

    try writeReasoningOptions(&out.writer, request, options, raw_options.reasoning);
    try writeTextOptions(alloc, &out.writer, request, options, raw_options.text);
    if (request.max_output_tokens) |limit| {
        if (options.capabilities.supports_max_output_tokens) {
            try out.writer.print(",\"max_output_tokens\":{d}", .{limit});
        }
    }

    try out.writer.writeAll(",\"store\":");
    try out.writer.writeAll(if (options.store) "true" else "false");
    try out.writer.writeAll(",\"stream\":");
    try out.writer.writeAll(if (options.stream) "true" else "false");

    if (options.include.len > 0) {
        try out.writer.writeAll(",\"include\":");
        try std.json.Stringify.value(options.include, .{}, &out.writer);
    }
    if (options.prompt_cache_key) |key| {
        if (options.capabilities.supports_prompt_cache_key) {
            try out.writer.writeAll(",\"prompt_cache_key\":");
            try std.json.Stringify.value(key, .{}, &out.writer);
        }
    }
    if (options.service_tier) |tier| {
        try out.writer.writeAll(",\"service_tier\":");
        try std.json.Stringify.value(tier, .{}, &out.writer);
    } else if (request.provider_options.fast) {
        try out.writer.writeAll(",\"service_tier\":\"priority\"");
    }

    if (options.extra_fields_json) |extra| {
        try writeExtraFields(alloc, &out.writer, extra);
    }
    try out.writer.writeByte('}');
    try checkBudget(request.budget);
    return out.toOwnedSlice();
}

/// Builds the dedicated `/responses/compact` payload from the same typed
/// Responses projection as an inference request. This deliberately renders
/// the ordinary request first, then selects only fields owned by the compact
/// protocol, so history, tool, reasoning, and opaque-checkpoint replay cannot
/// drift between the two product paths.
pub fn buildCompactRequest(
    alloc: Allocator,
    request: responses_compaction_provider.BuildRequest,
    options: RequestOptions,
) ![]u8 {
    if (request.responses_compaction_trigger) {
        return error.InvalidResponsesCompactionMode;
    }

    var projection_options = options;
    projection_options.store = false;
    projection_options.stream = false;
    projection_options.include = &.{};
    const projected = try buildRequest(alloc, request, projection_options);
    defer alloc.free(projected);

    var parsed = std.json.parseFromSlice(JsonValue, alloc, projected, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponsesCompactProjection,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponsesCompactProjection;
    const object = parsed.value.object;

    const input_json = try jsonFieldAlloc(
        alloc,
        object,
        "input",
        error.InvalidResponsesCompactProjection,
    );
    defer alloc.free(input_json);
    const tools_json = try jsonFieldAlloc(
        alloc,
        object,
        "tools",
        error.InvalidResponsesCompactProjection,
    );
    defer alloc.free(tools_json);
    const reasoning_json = try optionalJsonFieldAlloc(alloc, object, "reasoning");
    defer if (reasoning_json) |raw| alloc.free(raw);
    const text_json = try optionalJsonFieldAlloc(alloc, object, "text");
    defer if (text_json) |raw| alloc.free(raw);

    return compaction.buildRequest(alloc, .{
        .model = request.model,
        .input_json = input_json,
        .instructions = try optionalStringObjectField(object, "instructions"),
        .tools_json = tools_json,
        .parallel_tool_calls = try optionalBoolObjectField(object, "parallel_tool_calls"),
        .reasoning_json = reasoning_json,
        .service_tier = try optionalStringObjectField(object, "service_tier"),
        .prompt_cache_key = try optionalStringObjectField(object, "prompt_cache_key"),
        .text_json = text_json,
        .extra_fields_json = options.extra_fields_json,
    });
}

fn jsonFieldAlloc(
    alloc: Allocator,
    object: std.json.ObjectMap,
    name: []const u8,
    missing_error: anyerror,
) ![]u8 {
    const value = object.get(name) orelse return missing_error;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn optionalJsonFieldAlloc(
    alloc: Allocator,
    object: std.json.ObjectMap,
    name: []const u8,
) !?[]u8 {
    if (object.get(name) == null) return null;
    return try jsonFieldAlloc(
        alloc,
        object,
        name,
        error.InvalidResponsesCompactProjection,
    );
}

fn optionalStringObjectField(
    object: std.json.ObjectMap,
    name: []const u8,
) !?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return error.InvalidResponsesCompactProjection;
    return value.string;
}

fn optionalBoolObjectField(
    object: std.json.ObjectMap,
    name: []const u8,
) !?bool {
    const value = object.get(name) orelse return null;
    if (value != .bool) return error.InvalidResponsesCompactProjection;
    return value.bool;
}

const ParsedRawRequestOptions = struct {
    input: ?std.json.Parsed(JsonValue) = null,
    text: ?std.json.Parsed(JsonValue) = null,
    reasoning: ?std.json.Parsed(JsonValue) = null,

    fn init(
        alloc: Allocator,
        request: responses_compaction_provider.BuildRequest,
        options: RequestOptions,
    ) !ParsedRawRequestOptions {
        var parsed: ParsedRawRequestOptions = .{};
        errdefer parsed.deinit();

        if (options.responses_input_json) |raw| {
            if (hasMessageDerivedInput(request.messages) or
                hasMatchingCompactionCheckpoint(request) or
                request.verified_images != null)
            {
                return error.ConflictingResponsesInput;
            }
            parsed.input = try parseRawRequestValue(
                alloc,
                raw,
                error.InvalidResponsesInput,
            );
            switch (parsed.input.?.value) {
                .string => |value| if (std.mem.trim(u8, value, " \t\r\n").len == 0)
                    return error.InvalidResponsesInput,
                .array => |value| if (value.items.len == 0)
                    return error.InvalidResponsesInput,
                else => return error.InvalidResponsesInput,
            }
            if (request.responses_compaction_trigger) {
                try compaction.validateV2Input(parsed.input.?.value);
            }
        }

        if (options.responses_text_options_json) |raw| {
            parsed.text = try parseRawRequestValue(
                alloc,
                raw,
                error.InvalidResponsesTextOptions,
            );
            if (parsed.text.?.value != .object) return error.InvalidResponsesTextOptions;
            if (request.response_format != null and parsed.text.?.value.object.get("format") != null) {
                return error.DuplicateResponsesTextField;
            }
        }

        if (options.responses_reasoning_options_json) |raw| {
            parsed.reasoning = try parseRawRequestValue(
                alloc,
                raw,
                error.InvalidResponsesReasoningOptions,
            );
            if (parsed.reasoning.?.value != .object) return error.InvalidResponsesReasoningOptions;
            const object = parsed.reasoning.?.value.object;
            if (request.provider_options.reasoning != null and object.get("effort") != null) {
                return error.DuplicateResponsesReasoningField;
            }
            if (options.reasoning_summary != null and object.get("summary") != null) {
                return error.DuplicateResponsesReasoningField;
            }
        }
        return parsed;
    }

    fn deinit(self: *ParsedRawRequestOptions) void {
        if (self.input) |*parsed| parsed.deinit();
        if (self.text) |*parsed| parsed.deinit();
        if (self.reasoning) |*parsed| parsed.deinit();
        self.* = .{};
    }
};

fn parseRawRequestValue(
    alloc: Allocator,
    raw: []const u8,
    parse_error: anyerror,
) !std.json.Parsed(JsonValue) {
    return std.json.parseFromSlice(JsonValue, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return parse_error,
    };
}

fn hasMessageDerivedInput(messages: []const types.ChatMessage) bool {
    for (messages) |message| {
        if (message.role != .system) return true;
    }
    return false;
}

fn writeReasoningOptions(
    writer: *std.Io.Writer,
    request: responses_compaction_provider.BuildRequest,
    options: RequestOptions,
    raw: ?std.json.Parsed(JsonValue),
) !void {
    if (request.provider_options.reasoning == null and
        options.reasoning_summary == null and
        raw == null) return;

    try writer.writeAll(",\"reasoning\":{");
    var wrote = false;
    if (request.provider_options.reasoning) |effort| {
        try writeObjectField(writer, &wrote, "effort", .{ .string = effort.label() });
    }
    if (options.reasoning_summary) |summary| {
        try writeObjectField(writer, &wrote, "summary", .{ .string = summary });
    }
    if (raw) |parsed| try writeRawObjectFields(writer, parsed.value.object, &wrote);
    try writer.writeByte('}');
}

fn writeTextOptions(
    alloc: Allocator,
    writer: *std.Io.Writer,
    request: responses_compaction_provider.BuildRequest,
    options: RequestOptions,
    raw: ?std.json.Parsed(JsonValue),
) !void {
    if (request.response_format == null and raw == null) return;

    try writer.writeAll(",\"text\":{");
    var wrote = false;
    if (request.response_format) |format| {
        try writeComma(writer, &wrote);
        try writeStructuredOutputFormat(
            alloc,
            writer,
            format,
            options.structured_output_strict,
        );
    }
    if (raw) |parsed| try writeRawObjectFields(writer, parsed.value.object, &wrote);
    try writer.writeByte('}');
}

fn writeRawObjectFields(
    writer: *std.Io.Writer,
    object: std.json.ObjectMap,
    wrote: *bool,
) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        try writeObjectField(writer, wrote, entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn writeObjectField(
    writer: *std.Io.Writer,
    wrote: *bool,
    name: []const u8,
    value: JsonValue,
) !void {
    try writeComma(writer, wrote);
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeByte(':');
    try std.json.Stringify.value(value, .{}, writer);
}

fn checkBudget(budget: ?stream_provider.BuildBudget) !void {
    const active = budget orelse return;
    try (image_attachments.CaptureBudget{
        .deadline = active.deadline,
        .cancel_flag = active.cancel_flag,
    }).check();
}

fn collectInstructions(
    alloc: Allocator,
    request: responses_compaction_provider.BuildRequest,
) !?[]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var wrote = false;
    for (request.messages) |message| {
        if (message.role != .system) continue;
        if (matchingCompactionCheckpoint(request, message) != null) continue;
        const content = message.content orelse continue;
        if (content.len == 0) continue;
        if (wrote) try out.writer.writeAll("\n\n");
        try out.writer.writeAll(content);
        wrote = true;
    }
    return if (wrote) try out.toOwnedSlice() else null;
}

fn matchingCompactionCheckpoint(
    request: responses_compaction_provider.BuildRequest,
    message: types.ChatMessage,
) ?types.ResponsesCompactionView {
    const checkpoint = message.responses_compaction orelse return null;
    const source = request.credential_source orelse return null;
    const request_binding = request.responses_compaction_binding orelse return null;
    const checkpoint_binding = checkpoint.provider_binding orelse return null;
    if (source != checkpoint.credential_source or
        !std.mem.eql(u8, request.model, checkpoint.wire_model) or
        !compaction_binding.eql(request_binding, checkpoint_binding))
    {
        return null;
    }
    compaction_binding.validate(source, request_binding) catch return null;
    compaction_binding.validate(source, checkpoint_binding) catch return null;
    return checkpoint;
}

fn hasMatchingCompactionCheckpoint(request: responses_compaction_provider.BuildRequest) bool {
    for (request.messages) |message| {
        if (matchingCompactionCheckpoint(request, message) != null) return true;
    }
    return false;
}

fn validateCompactionCheckpointProjection(request: responses_compaction_provider.BuildRequest) !void {
    var matching: usize = 0;
    for (request.messages) |message| {
        if (matchingCompactionCheckpoint(request, message) == null) continue;
        matching += 1;
        if (matching > 1) return error.InvalidResponsesHistory;
    }
}

fn writeReplayInputItems(
    alloc: Allocator,
    writer: *std.Io.Writer,
    raw_input: []const u8,
    wrote_item: *bool,
) !void {
    try compaction.validateReplayInputJson(alloc, raw_input);
    const trimmed = std.mem.trim(u8, raw_input, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        return error.InvalidResponsesCompactInput;
    }
    const items = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
    if (items.len == 0) return error.MissingResponsesCompactionItem;
    try writeComma(writer, wrote_item);
    try writer.writeAll(items);
}

fn lastUserMessageIndex(messages: []const types.ChatMessage) ?usize {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        if (messages[index].role == .user) return index;
    }
    return null;
}

fn writeComma(writer: *std.Io.Writer, wrote: *bool) !void {
    if (wrote.*) try writer.writeByte(',');
    wrote.* = true;
}

fn writeInputArrayWithCompactionTrigger(
    writer: *std.Io.Writer,
    items: []const JsonValue,
) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, index| {
        if (index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(item, .{}, writer);
    }
    if (items.len > 0) try writer.writeByte(',');
    try compaction.writeV2Trigger(writer);
    try writer.writeByte(']');
}

fn writeUserMessage(
    alloc: Allocator,
    writer: *std.Io.Writer,
    message: types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
    budget: ?stream_provider.BuildBudget,
) !void {
    try writer.writeAll("{\"type\":\"message\",\"role\":\"user\",\"content\":[");
    var wrote_part = false;
    if (message.content) |content| {
        if (content.len > 0) {
            try writer.writeAll("{\"type\":\"input_text\",\"text\":");
            try std.json.Stringify.value(content, .{}, writer);
            try writer.writeByte('}');
            wrote_part = true;
        }
    }

    if (verified_images) |snapshots| {
        for (snapshots) |snapshot| {
            try checkBudget(budget);
            if (wrote_part) try writer.writeByte(',');
            try writeImagePart(alloc, writer, snapshot);
            wrote_part = true;
        }
    } else {
        for (message.images) |attachment| {
            try checkBudget(budget);
            var snapshot = try image_attachments.loadVerifiedSnapshot(
                alloc,
                attachment,
                .{
                    .deadline = if (budget) |active| active.deadline else null,
                    .cancel_flag = if (budget) |active| active.cancel_flag else null,
                },
            );
            defer snapshot.deinit(alloc);
            if (wrote_part) try writer.writeByte(',');
            try writeImagePart(alloc, writer, snapshot);
            wrote_part = true;
        }
    }
    try writer.writeAll("]}");
}

fn writeImagePart(
    alloc: Allocator,
    writer: *std.Io.Writer,
    snapshot: image_attachments.VerifiedSnapshot,
) !void {
    var data_url: std.Io.Writer.Allocating = .init(alloc);
    defer data_url.deinit();
    try data_url.writer.writeAll("data:");
    try data_url.writer.writeAll(snapshot.media_type);
    try data_url.writer.writeAll(";base64,");
    try std.base64.standard.Encoder.encodeWriter(&data_url.writer, snapshot.bytes);

    try writer.writeAll("{\"type\":\"input_image\",\"image_url\":");
    try std.json.Stringify.value(data_url.written(), .{}, writer);
    try writer.writeAll(",\"detail\":\"auto\"}");
}

fn writeAssistantItems(
    alloc: Allocator,
    writer: *std.Io.Writer,
    message: types.ChatMessage,
    capabilities: RequestCapabilities,
    replay_web_namespace: bool,
    wrote_item: *bool,
) !void {
    // A terminal `response.output` is the only lossless representation of a
    // provider response. Prefer the complete sequence so
    // hosted calls and multiple reasoning items replay in their original
    // order. Tool result messages are separate history entries and remain
    // appended immediately after this response.
    if (message.responses_output_sequence_complete) {
        try responses_output_items.validateComplete(alloc, message.responses_provider_output_items);
        for (message.responses_provider_output_items) |item| {
            try writeComma(writer, wrote_item);
            try responses_output_items.writeValidated(alloc, writer, item);
        }
        return;
    }
    if (message.responses_provider_output_items.len > 0) {
        return writeAssistantItemsWithIncompleteRaw(
            alloc,
            writer,
            message,
            capabilities,
            replay_web_namespace,
            wrote_item,
        );
    }

    // Sessions written by the former Codex-only stream reducer stored
    // encrypted reasoning as a JSON array instead of the typed Responses
    // fields. Replay that bounded legacy shape while those sessions age out;
    // every current direct Responses stream persists the typed form below.
    if (message.reasoning_items.len == 0 and
        message.reasoning_item_id == null and
        message.reasoning_encrypted_content == null)
    {
        if (message.provider_state_json) |legacy_state| {
            try writeLegacyReasoningState(alloc, writer, legacy_state, wrote_item);
        }
    }

    if (message.reasoning_items.len > 0) {
        for (message.reasoning_items) |item| {
            _ = try writeReasoningItem(writer, item, capabilities, wrote_item);
        }
    } else {
        _ = try writeReasoningItem(writer, .{
            .id = message.reasoning_item_id,
            .summary = message.reasoning,
            .encrypted_content = message.reasoning_encrypted_content,
        }, capabilities, wrote_item);
    }

    if (message.content) |content| {
        if (content.len > 0) {
            try writeComma(writer, wrote_item);
            try writer.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
            try std.json.Stringify.value(content, .{}, writer);
            try writer.writeAll("}]}");
        }
    }

    for (message.tool_calls) |call| {
        try writeProjectedToolCall(writer, call, replay_web_namespace, wrote_item);
    }
}

fn writeLegacyReasoningState(
    alloc: Allocator,
    writer: *std.Io.Writer,
    state_json: []const u8,
    wrote_item: *bool,
) !void {
    var parsed = std.json.parseFromSlice(JsonValue, alloc, state_json, .{}) catch
        return error.InvalidResponsesProviderState;
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidResponsesProviderState;
    for (parsed.value.array.items) |item| {
        if (item != .object or
            !std.mem.eql(u8, stringField(item, "type") orelse "", "reasoning") or
            stringField(item, "encrypted_content") == null)
        {
            return error.InvalidResponsesProviderState;
        }
        try writeComma(writer, wrote_item);
        try std.json.Stringify.value(item, .{}, writer);
    }
}

const ReplayCandidateKind = enum { raw, reasoning, message, tool };

const ReplayCandidate = struct {
    kind: ReplayCandidateKind,
    output_index: u32,
};

fn chooseReplayCandidate(
    current: ?ReplayCandidate,
    candidate: ReplayCandidate,
) !ReplayCandidate {
    const selected = current orelse return candidate;
    if (selected.output_index == candidate.output_index) {
        return error.InvalidResponsesOutputOrder;
    }
    return if (candidate.output_index < selected.output_index) candidate else selected;
}

fn writeAssistantItemsWithIncompleteRaw(
    alloc: Allocator,
    writer: *std.Io.Writer,
    message: types.ChatMessage,
    capabilities: RequestCapabilities,
    replay_web_namespace: bool,
    wrote_item: *bool,
) !void {
    try responses_output_items.validate(alloc, message.responses_provider_output_items);
    if (message.reasoning_items.len == 0) {
        const legacy = types.ResponsesReasoningItem{
            .id = message.reasoning_item_id,
            .summary = message.reasoning,
            .encrypted_content = message.reasoning_encrypted_content,
        };
        if (reasoningItemReplayable(legacy, capabilities)) {
            // Legacy projections do not carry a wire index, so mixing them
            // with fallback raw items would guess at provider order.
            return error.InvalidResponsesOutputOrder;
        }
    }

    var raw_index: usize = 0;
    var reasoning_index: usize = 0;
    var tool_index: usize = 0;
    var message_written = false;
    var expected_output_index: u32 = 0;
    const has_message = if (message.content) |content| content.len > 0 else false;

    while (true) {
        var selected: ?ReplayCandidate = null;
        if (raw_index < message.responses_provider_output_items.len) {
            selected = try chooseReplayCandidate(selected, .{
                .kind = .raw,
                .output_index = message.responses_provider_output_items[raw_index].output_index,
            });
        }
        if (reasoning_index < message.reasoning_items.len) {
            const reasoning = message.reasoning_items[reasoning_index];
            if (!reasoningItemReplayable(reasoning, capabilities)) {
                return error.InvalidResponsesOutputOrder;
            }
            selected = try chooseReplayCandidate(selected, .{
                .kind = .reasoning,
                .output_index = reasoning.output_index orelse
                    return error.InvalidResponsesOutputOrder,
            });
        }
        if (has_message and !message_written) {
            selected = try chooseReplayCandidate(selected, .{
                .kind = .message,
                .output_index = message.responses_message_output_index orelse
                    return error.InvalidResponsesOutputOrder,
            });
        }
        if (tool_index < message.tool_calls.len) {
            selected = try chooseReplayCandidate(selected, .{
                .kind = .tool,
                .output_index = message.tool_calls[tool_index].responses_output_index orelse
                    return error.InvalidResponsesOutputOrder,
            });
        }

        const candidate = selected orelse break;
        if (candidate.output_index != expected_output_index) {
            return error.InvalidResponsesOutputOrder;
        }
        switch (candidate.kind) {
            .raw => {
                try writeComma(writer, wrote_item);
                try responses_output_items.writeValidated(
                    alloc,
                    writer,
                    message.responses_provider_output_items[raw_index],
                );
                raw_index += 1;
            },
            .reasoning => {
                if (!try writeReasoningItem(
                    writer,
                    message.reasoning_items[reasoning_index],
                    capabilities,
                    wrote_item,
                )) return error.InvalidResponsesOutputOrder;
                reasoning_index += 1;
            },
            .message => {
                try writeProjectedAssistantMessage(writer, message.content.?, wrote_item);
                message_written = true;
            },
            .tool => {
                try writeProjectedToolCall(
                    writer,
                    message.tool_calls[tool_index],
                    replay_web_namespace,
                    wrote_item,
                );
                tool_index += 1;
            },
        }
        expected_output_index = std.math.add(u32, expected_output_index, 1) catch
            return error.InvalidResponsesOutputOrder;
    }
}

fn writeProjectedAssistantMessage(
    writer: *std.Io.Writer,
    content: []const u8,
    wrote_item: *bool,
) !void {
    try writeComma(writer, wrote_item);
    try writer.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
    try std.json.Stringify.value(content, .{}, writer);
    try writer.writeAll("}]}");
}

fn writeProjectedToolCall(
    writer: *std.Io.Writer,
    call: types.ToolCall,
    replay_web_namespace: bool,
    wrote_item: *bool,
) !void {
    try writeComma(writer, wrote_item);
    try writer.writeAll("{\"type\":\"function_call\"");
    if (call.responses_item_id) |item_id| {
        try writer.writeAll(",\"id\":");
        try std.json.Stringify.value(item_id, .{}, writer);
    }
    try writer.writeAll(",\"call_id\":");
    try std.json.Stringify.value(call.id, .{}, writer);
    if (replay_web_namespace and std.mem.eql(u8, call.name, "web_search")) {
        try writer.writeAll(",\"namespace\":\"web\",\"name\":\"run\"");
    } else {
        try writer.writeAll(",\"name\":");
        try std.json.Stringify.value(call.name, .{}, writer);
    }
    try writer.writeAll(",\"arguments\":");
    // Responses carries function arguments as a JSON-encoded string.
    try std.json.Stringify.value(call.arguments_json, .{}, writer);
    try writer.writeByte('}');
}

/// Tool execution uses the local, permissioned `web_search` identity. When the
/// active Responses tool declaration is Codex's `web.run` namespace, replay
/// that provider identity instead of inventing a top-level function tool.
fn declaresWebRunNamespace(alloc: Allocator, serialized_tools: []const u8) !bool {
    var parsed = std.json.parseFromSlice(JsonValue, alloc, serialized_tools, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponsesTools,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidResponsesTools;

    var declares_namespace = false;
    var declares_local_function = false;
    for (parsed.value.array.items) |tool| {
        if (tool != .object) continue;
        const tool_type = stringField(tool, "type") orelse continue;
        if (std.mem.eql(u8, tool_type, "function")) {
            const fields = valueField(tool, "function") orelse tool;
            if (stringField(fields, "name")) |name| {
                declares_local_function = declares_local_function or
                    std.mem.eql(u8, name, "web_search");
            }
            continue;
        }
        if (!std.mem.eql(u8, tool_type, "namespace") or
            !std.mem.eql(u8, stringField(tool, "name") orelse "", "web")) continue;
        const tools = valueField(tool, "tools") orelse continue;
        if (tools != .array) continue;
        for (tools.array.items) |nested| {
            if (nested != .object) continue;
            if (std.mem.eql(u8, stringField(nested, "type") orelse "", "function") and
                std.mem.eql(u8, stringField(nested, "name") orelse "", "run"))
            {
                declares_namespace = true;
            }
        }
    }
    if (declares_namespace and declares_local_function) {
        return error.AmbiguousResponsesWebSearchTools;
    }
    return declares_namespace;
}

fn writeReasoningItem(
    writer: *std.Io.Writer,
    item: types.ResponsesReasoningItem,
    capabilities: RequestCapabilities,
    wrote_item: *bool,
) !bool {
    const has_summary = item.summary != null and item.summary.?.len > 0;
    const has_id = item.id != null and item.id.?.len > 0;
    const has_encrypted = capabilities.supports_encrypted_reasoning and
        item.encrypted_content != null and item.encrypted_content.?.len > 0;
    if (!has_summary and !has_id and !has_encrypted) return false;

    try writeComma(writer, wrote_item);
    try writer.writeAll("{\"type\":\"reasoning\"");
    if (has_id) {
        try writer.writeAll(",\"id\":");
        try std.json.Stringify.value(item.id.?, .{}, writer);
    }
    try writer.writeAll(",\"summary\":[");
    if (has_summary) {
        try writer.writeAll("{\"type\":\"summary_text\",\"text\":");
        try std.json.Stringify.value(item.summary.?, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
    if (has_encrypted) {
        try writer.writeAll(",\"encrypted_content\":");
        try std.json.Stringify.value(item.encrypted_content.?, .{}, writer);
    }
    try writer.writeByte('}');
    return true;
}

fn reasoningItemReplayable(
    item: types.ResponsesReasoningItem,
    capabilities: RequestCapabilities,
) bool {
    return (item.summary != null and item.summary.?.len > 0) or
        (item.id != null and item.id.?.len > 0) or
        (capabilities.supports_encrypted_reasoning and
            item.encrypted_content != null and item.encrypted_content.?.len > 0);
}

fn writeFunctionCallOutput(
    writer: *std.Io.Writer,
    message: types.ChatMessage,
    replay_web_namespace: bool,
) !void {
    const call_id = message.tool_call_id orelse return error.InvalidResponsesHistory;
    const output = message.content orelse return error.InvalidResponsesHistory;
    try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
    try std.json.Stringify.value(call_id, .{}, writer);
    if (replay_web_namespace and
        std.mem.eql(u8, message.tool_name orelse "", "web_search"))
    {
        try writer.writeAll(",\"namespace\":\"web\",\"name\":\"run\"");
    }
    try writer.writeAll(",\"output\":");
    try std.json.Stringify.value(output, .{}, writer);
    try writer.writeByte('}');
}

fn writeTools(
    alloc: Allocator,
    writer: *std.Io.Writer,
    request: responses_compaction_provider.BuildRequest,
    strict_default: ?bool,
) !void {
    var wrote = false;

    if (request.vision_mode != .required) {
        var base = std.json.parseFromSlice(JsonValue, alloc, request.serialized_tools, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResponsesTools,
        };
        defer base.deinit();
        if (base.value != .array) return error.InvalidResponsesTools;
        for (base.value.array.items) |tool| {
            try writeComma(writer, &wrote);
            try writeResponseTool(writer, tool, strict_default);
        }

        for (request.selected_dynamic_tool_schemas) |schema_json| {
            var selected = std.json.parseFromSlice(JsonValue, alloc, schema_json, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidResponsesTools,
            };
            defer selected.deinit();
            switch (selected.value) {
                .array => |array| for (array.items) |tool| {
                    try writeComma(writer, &wrote);
                    try writeResponseTool(writer, tool, strict_default);
                },
                .object => {
                    try writeComma(writer, &wrote);
                    try writeResponseTool(writer, selected.value, strict_default);
                },
                else => return error.InvalidResponsesTools,
            }
        }
    }

    if (request.vision_mode != .unavailable) {
        const vision = request.tool_registry.lookup("vision") orelse
            return error.VisionToolNotRegistered;
        const schema_json = try gateway_schema.builtinFunctionSchemaJsonAlloc(
            alloc,
            vision.model_schema,
        );
        defer alloc.free(schema_json);
        var parsed = try std.json.parseFromSlice(JsonValue, alloc, schema_json, .{});
        defer parsed.deinit();
        try writeComma(writer, &wrote);
        try writeResponseTool(writer, parsed.value, strict_default);
    }
}

fn writeResponseTool(writer: *std.Io.Writer, tool: JsonValue, strict_default: ?bool) !void {
    if (tool != .object) return error.InvalidResponsesTools;
    const type_value = tool.object.get("type") orelse return error.InvalidResponsesTools;
    if (type_value != .string) return error.InvalidResponsesTools;
    if (!std.mem.eql(u8, type_value.string, "function")) {
        try std.json.Stringify.value(tool, .{}, writer);
        return;
    }

    const nested_function = tool.object.get("function");
    const fields = if (nested_function) |nested| blk: {
        if (nested != .object) return error.InvalidResponsesTools;
        break :blk nested.object;
    } else tool.object;

    const name = fields.get("name") orelse return error.InvalidResponsesTools;
    if (name != .string or name.string.len == 0) return error.InvalidResponsesTools;
    const input_schema = fields.get("parameters") orelse fields.get("inputSchema");
    if (fields.get("parameters") != null and fields.get("inputSchema") != null) {
        return error.InvalidResponsesTools;
    }
    if (input_schema) |schema| if (schema != .object) return error.InvalidResponsesTools;

    try writer.writeAll("{\"type\":\"function\"");
    var iterator = fields.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "type") or
            std.mem.eql(u8, key, "function") or
            std.mem.eql(u8, key, "parameters") or
            std.mem.eql(u8, key, "inputSchema")) continue;
        try writer.writeByte(',');
        try std.json.Stringify.value(key, .{}, writer);
        try writer.writeByte(':');
        try std.json.Stringify.value(entry.value_ptr.*, .{}, writer);
    }
    try writer.writeAll(",\"parameters\":");
    if (input_schema) |schema| {
        try std.json.Stringify.value(schema, .{}, writer);
    } else {
        try writer.writeAll("{\"type\":\"object\",\"properties\":{}}");
    }
    if (strict_default) |strict| {
        if (fields.get("strict") == null) {
            try writer.writeAll(",\"strict\":");
            try writer.writeAll(if (strict) "true" else "false");
        }
    }
    try writer.writeByte('}');
}

fn writeStructuredOutputFormat(
    alloc: Allocator,
    writer: *std.Io.Writer,
    format: responses_compaction_provider.StructuredResponseFormat,
    strict: bool,
) !void {
    var schema = std.json.parseFromSlice(JsonValue, alloc, format.schema_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidStructuredResponseSchema,
    };
    defer schema.deinit();
    if (schema.value != .object) return error.InvalidStructuredResponseSchema;

    try writer.writeAll("\"format\":{\"type\":\"json_schema\",\"name\":");
    try std.json.Stringify.value(format.name, .{}, writer);
    if (format.description.len > 0) {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(format.description, .{}, writer);
    }
    try writer.writeAll(",\"schema\":");
    try std.json.Stringify.value(schema.value, .{}, writer);
    try writer.writeAll(",\"strict\":");
    try writer.writeAll(if (strict) "true" else "false");
    try writer.writeByte('}');
}

fn writeParsedJsonValue(
    alloc: Allocator,
    writer: *std.Io.Writer,
    raw: []const u8,
    parse_error: anyerror,
) !void {
    var parsed = std.json.parseFromSlice(JsonValue, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return parse_error,
    };
    defer parsed.deinit();
    try std.json.Stringify.value(parsed.value, .{}, writer);
}

fn writeExtraFields(alloc: Allocator, writer: *std.Io.Writer, raw: []const u8) !void {
    var parsed = std.json.parseFromSlice(JsonValue, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponsesExtraFields,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponsesExtraFields;

    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        if (isOwnedRequestField(entry.key_ptr.*)) return error.DuplicateResponsesRequestField;
        try writer.writeByte(',');
        try std.json.Stringify.value(entry.key_ptr.*, .{}, writer);
        try writer.writeByte(':');
        try std.json.Stringify.value(entry.value_ptr.*, .{}, writer);
    }
}

fn isOwnedRequestField(name: []const u8) bool {
    const owned = [_][]const u8{
        "model",
        "instructions",
        "input",
        "tools",
        "tool_choice",
        "parallel_tool_calls",
        "reasoning",
        "text",
        "max_output_tokens",
        "store",
        "stream",
        "include",
        "prompt_cache_key",
        "service_tier",
    };
    for (owned) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

// Event codec

pub const Usage = compaction.Usage;

pub const ResponseError = struct {
    error_type: ?[]const u8 = null,
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
    param: ?[]const u8 = null,
    plan_type: ?[]const u8 = null,
    resets_at: ?i64 = null,
    status_code: ?u16 = null,
    retry_after_seconds: ?f64 = null,
};

pub const Lifecycle = struct {
    response_id: ?[]const u8 = null,
    status: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

pub const Terminal = struct {
    response_id: ?[]const u8 = null,
    status: ?[]const u8 = null,
    model: ?[]const u8 = null,
    usage: Usage = .{},
    error_info: ?ResponseError = null,
    incomplete_reason: ?[]const u8 = null,
    end_turn: ?bool = null,
    output: ?std.json.Value = null,
};

pub const TextDelta = struct {
    item_id: ?[]const u8 = null,
    output_index: ?u64 = null,
    content_index: ?u64 = null,
    delta: []const u8,
};

pub const TextDone = struct {
    item_id: ?[]const u8 = null,
    output_index: ?u64 = null,
    content_index: ?u64 = null,
    text: []const u8,
};

pub const ToolInputDelta = struct {
    item_id: ?[]const u8 = null,
    call_id: ?[]const u8 = null,
    output_index: ?u64 = null,
    delta: []const u8,
};

pub const ToolInputDone = struct {
    item_id: ?[]const u8 = null,
    call_id: ?[]const u8 = null,
    output_index: ?u64 = null,
    value: []const u8,
};

pub const ReasoningTextDelta = struct {
    item_id: ?[]const u8 = null,
    output_index: ?u64 = null,
    summary_index: ?u64 = null,
    content_index: ?u64 = null,
    delta: []const u8,
};

pub const ReasoningTextDone = struct {
    item_id: ?[]const u8 = null,
    output_index: ?u64 = null,
    summary_index: ?u64 = null,
    content_index: ?u64 = null,
    text: []const u8,
};

pub const UrlCitation = struct {
    url: []const u8,
    title: ?[]const u8 = null,
    start_index: u64,
    end_index: u64,
};

pub const OutputTextAnnotationAdded = struct {
    item_id: ?[]const u8 = null,
    output_index: ?u64 = null,
    content_index: ?u64 = null,
    annotation_index: ?u64 = null,
    annotation_type: ?[]const u8 = null,
    url_citation: ?UrlCitation = null,
};

pub const OutputItemKind = enum {
    message,
    reasoning,
    function_call,
    function_call_output,
    custom_tool_call,
    custom_tool_call_output,
    web_search_call,
    file_search_call,
    image_generation_call,
    computer_call,
    local_shell_call,
    mcp_call,
    other,
};

pub const OutputItem = struct {
    kind: OutputItemKind,
    raw_type: []const u8,
    id: ?[]const u8 = null,
    status: ?[]const u8 = null,
    role: ?[]const u8 = null,
    call_id: ?[]const u8 = null,
    namespace: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    input: ?[]const u8 = null,
    encrypted_content: ?[]const u8 = null,
    reasoning_summary: ?std.json.Value = null,
    content: ?std.json.Value = null,
};

pub const OutputItemEvent = struct {
    output_index: ?u64 = null,
    item: OutputItem,
};

pub const ContentPartEvent = struct {
    item_id: ?[]const u8 = null,
    output_index: ?u64 = null,
    content_index: ?u64 = null,
    part_type: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

pub const ReasoningPartEvent = struct {
    item_id: ?[]const u8 = null,
    output_index: ?u64 = null,
    summary_index: ?u64 = null,
    part_type: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

pub const UnknownEvent = struct {
    event_type: []const u8,
};

pub const Projection = union(enum) {
    response_created: Lifecycle,
    response_in_progress: Lifecycle,
    response_queued: Lifecycle,
    response_completed: Terminal,
    response_failed: Terminal,
    response_incomplete: Terminal,
    output_text_delta: TextDelta,
    output_text_done: TextDone,
    output_text_annotation_added: OutputTextAnnotationAdded,
    refusal_delta: TextDelta,
    refusal_done: TextDone,
    function_call_arguments_delta: ToolInputDelta,
    function_call_arguments_done: ToolInputDone,
    custom_tool_call_input_delta: ToolInputDelta,
    custom_tool_call_input_done: ToolInputDone,
    reasoning_summary_text_delta: ReasoningTextDelta,
    reasoning_summary_text_done: ReasoningTextDone,
    reasoning_text_delta: ReasoningTextDelta,
    reasoning_text_done: ReasoningTextDone,
    output_item_added: OutputItemEvent,
    output_item_done: OutputItemEvent,
    content_part_added: ContentPartEvent,
    content_part_done: ContentPartEvent,
    reasoning_summary_part_added: ReasoningPartEvent,
    reasoning_summary_part_done: ReasoningPartEvent,
    websocket_error: ResponseError,
    unknown: UnknownEvent,
};

/// Owns both the exact wire JSON and all decoded string storage. Projection
/// slices remain valid until `deinit`.
pub const DecodedEvent = struct {
    allocator: Allocator,
    raw_json: []u8,
    parsed: std.json.Parsed(JsonValue),
    projection: Projection,

    pub fn deinit(self: *DecodedEvent) void {
        self.parsed.deinit();
        self.allocator.free(self.raw_json);
        self.* = undefined;
    }

    pub fn json(self: *const DecodedEvent) *const JsonValue {
        return &self.parsed.value;
    }
};

pub fn decodeEvent(alloc: Allocator, data: []const u8) !DecodedEvent {
    const raw = try alloc.dupe(u8, data);
    errdefer alloc.free(raw);
    var parsed = std.json.parseFromSlice(JsonValue, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponsesEvent,
    };
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponsesEvent;
    const event_type = stringField(parsed.value, "type") orelse return error.InvalidResponsesEvent;
    const projection = try projectEvent(parsed.value, event_type);
    return .{
        .allocator = alloc,
        .raw_json = raw,
        .parsed = parsed,
        .projection = projection,
    };
}

fn projectEvent(root: JsonValue, event_type: []const u8) !Projection {
    if (std.mem.eql(u8, event_type, "response.created")) {
        return .{ .response_created = projectLifecycle(root) };
    }
    if (std.mem.eql(u8, event_type, "response.in_progress")) {
        return .{ .response_in_progress = projectLifecycle(root) };
    }
    if (std.mem.eql(u8, event_type, "response.queued")) {
        return .{ .response_queued = projectLifecycle(root) };
    }
    if (std.mem.eql(u8, event_type, "response.completed")) {
        return .{ .response_completed = projectTerminal(root) };
    }
    if (std.mem.eql(u8, event_type, "response.failed")) {
        return .{ .response_failed = projectTerminal(root) };
    }
    if (std.mem.eql(u8, event_type, "response.incomplete")) {
        return .{ .response_incomplete = projectTerminal(root) };
    }
    if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
        return .{ .output_text_delta = try projectTextDelta(root) };
    }
    if (std.mem.eql(u8, event_type, "response.output_text.done")) {
        return .{ .output_text_done = try projectTextDone(root, "text") };
    }
    if (std.mem.eql(u8, event_type, "response.output_text.annotation.added")) {
        return .{ .output_text_annotation_added = projectOutputTextAnnotationAdded(root) };
    }
    if (std.mem.eql(u8, event_type, "response.refusal.delta")) {
        return .{ .refusal_delta = try projectTextDelta(root) };
    }
    if (std.mem.eql(u8, event_type, "response.refusal.done")) {
        return .{ .refusal_done = try projectTextDone(root, "refusal") };
    }
    if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
        return .{ .function_call_arguments_delta = try projectToolDelta(root) };
    }
    if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
        return .{ .function_call_arguments_done = try projectToolDone(root, "arguments") };
    }
    if (std.mem.eql(u8, event_type, "response.custom_tool_call_input.delta")) {
        return .{ .custom_tool_call_input_delta = try projectToolDelta(root) };
    }
    if (std.mem.eql(u8, event_type, "response.custom_tool_call_input.done")) {
        return .{ .custom_tool_call_input_done = try projectToolDone(root, "input") };
    }
    if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta")) {
        return .{ .reasoning_summary_text_delta = try projectReasoningDelta(root) };
    }
    if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.done")) {
        return .{ .reasoning_summary_text_done = try projectReasoningDone(root) };
    }
    if (std.mem.eql(u8, event_type, "response.reasoning_text.delta")) {
        return .{ .reasoning_text_delta = try projectReasoningDelta(root) };
    }
    if (std.mem.eql(u8, event_type, "response.reasoning_text.done")) {
        return .{ .reasoning_text_done = try projectReasoningDone(root) };
    }
    if (std.mem.eql(u8, event_type, "response.output_item.added")) {
        return .{ .output_item_added = try projectOutputItemEvent(root) };
    }
    if (std.mem.eql(u8, event_type, "response.output_item.done")) {
        return .{ .output_item_done = try projectOutputItemEvent(root) };
    }
    if (std.mem.eql(u8, event_type, "response.content_part.added")) {
        return .{ .content_part_added = projectContentPart(root) };
    }
    if (std.mem.eql(u8, event_type, "response.content_part.done")) {
        return .{ .content_part_done = projectContentPart(root) };
    }
    if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.added")) {
        return .{ .reasoning_summary_part_added = projectReasoningPart(root) };
    }
    if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.done")) {
        return .{ .reasoning_summary_part_done = projectReasoningPart(root) };
    }
    if (std.mem.eql(u8, event_type, "error")) {
        const error_value = valueField(root, "error") orelse root;
        return .{ .websocket_error = projectError(error_value, root) };
    }
    return .{ .unknown = .{ .event_type = event_type } };
}

fn responseValue(root: JsonValue) JsonValue {
    const response = root.object.get("response") orelse return root;
    return if (response == .object) response else root;
}

fn projectLifecycle(root: JsonValue) Lifecycle {
    const response = responseValue(root);
    return .{
        .response_id = stringField(response, "id"),
        .status = stringField(response, "status"),
        .model = stringField(response, "model"),
    };
}

fn projectTerminal(root: JsonValue) Terminal {
    const response = responseValue(root);
    const incomplete_details = objectField(response, "incomplete_details");
    const error_value = objectField(response, "error");
    const metadata = projectTerminalMetadata(response, incomplete_details, root);
    return .{
        .response_id = stringField(response, "id"),
        .status = stringField(response, "status"),
        .model = stringField(response, "model"),
        .usage = projectUsage(objectField(response, "usage")),
        .error_info = if (error_value) |value|
            mergeTerminalError(projectError(value, root), metadata)
        else if (hasResponseErrorMetadata(metadata))
            metadata
        else
            null,
        .incomplete_reason = if (incomplete_details) |value| stringField(value, "reason") else null,
        .end_turn = boolField(response, "end_turn"),
        .output = valueField(response, "output"),
    };
}

fn projectTextDelta(root: JsonValue) !TextDelta {
    return .{
        .item_id = stringField(root, "item_id"),
        .output_index = unsignedField(root, "output_index"),
        .content_index = unsignedField(root, "content_index"),
        .delta = stringField(root, "delta") orelse return error.InvalidResponsesEvent,
    };
}

fn projectTextDone(root: JsonValue, field_name: []const u8) !TextDone {
    return .{
        .item_id = stringField(root, "item_id"),
        .output_index = unsignedField(root, "output_index"),
        .content_index = unsignedField(root, "content_index"),
        .text = stringField(root, field_name) orelse return error.InvalidResponsesEvent,
    };
}

fn projectToolDelta(root: JsonValue) !ToolInputDelta {
    return .{
        .item_id = stringField(root, "item_id"),
        .call_id = stringField(root, "call_id"),
        .output_index = unsignedField(root, "output_index"),
        .delta = stringField(root, "delta") orelse return error.InvalidResponsesEvent,
    };
}

fn projectToolDone(root: JsonValue, field_name: []const u8) !ToolInputDone {
    return .{
        .item_id = stringField(root, "item_id"),
        .call_id = stringField(root, "call_id"),
        .output_index = unsignedField(root, "output_index"),
        .value = stringField(root, field_name) orelse return error.InvalidResponsesEvent,
    };
}

fn projectReasoningDelta(root: JsonValue) !ReasoningTextDelta {
    return .{
        .item_id = stringField(root, "item_id"),
        .output_index = unsignedField(root, "output_index"),
        .summary_index = unsignedField(root, "summary_index"),
        .content_index = unsignedField(root, "content_index"),
        .delta = stringField(root, "delta") orelse return error.InvalidResponsesEvent,
    };
}

fn projectReasoningDone(root: JsonValue) !ReasoningTextDone {
    return .{
        .item_id = stringField(root, "item_id"),
        .output_index = unsignedField(root, "output_index"),
        .summary_index = unsignedField(root, "summary_index"),
        .content_index = unsignedField(root, "content_index"),
        .text = stringField(root, "text") orelse return error.InvalidResponsesEvent,
    };
}

fn projectOutputTextAnnotationAdded(root: JsonValue) OutputTextAnnotationAdded {
    const annotation = objectField(root, "annotation");
    const annotation_type = if (annotation) |value| stringField(value, "type") else null;
    return .{
        .item_id = stringField(root, "item_id"),
        .output_index = unsignedField(root, "output_index"),
        .content_index = unsignedField(root, "content_index"),
        .annotation_index = unsignedField(root, "annotation_index"),
        .annotation_type = annotation_type,
        .url_citation = if (annotation) |value| urlCitationFromAnnotation(value) else null,
    };
}

pub fn urlCitationFromAnnotation(value: JsonValue) ?UrlCitation {
    const annotation_type = stringField(value, "type") orelse return null;
    if (!std.mem.eql(u8, annotation_type, "url_citation")) return null;
    const url = stringField(value, "url") orelse return null;
    const start_index = unsignedField(value, "start_index") orelse return null;
    const end_index = unsignedField(value, "end_index") orelse return null;
    return .{
        .url = url,
        .title = stringField(value, "title"),
        .start_index = start_index,
        .end_index = end_index,
    };
}

fn projectOutputItemEvent(root: JsonValue) !OutputItemEvent {
    const item = objectField(root, "item") orelse return error.InvalidResponsesEvent;
    const raw_type = stringField(item, "type") orelse return error.InvalidResponsesEvent;
    return .{
        .output_index = unsignedField(root, "output_index"),
        .item = .{
            .kind = outputItemKind(raw_type),
            .raw_type = raw_type,
            .id = stringField(item, "id"),
            .status = stringField(item, "status"),
            .role = stringField(item, "role"),
            .call_id = stringField(item, "call_id"),
            .namespace = stringField(item, "namespace"),
            .name = stringField(item, "name"),
            .arguments = stringField(item, "arguments"),
            .input = stringField(item, "input"),
            .encrypted_content = stringField(item, "encrypted_content"),
            .reasoning_summary = valueField(item, "summary"),
            .content = valueField(item, "content"),
        },
    };
}

fn outputItemKind(raw: []const u8) OutputItemKind {
    const mappings = [_]struct { []const u8, OutputItemKind }{
        .{ "message", .message },
        .{ "reasoning", .reasoning },
        .{ "function_call", .function_call },
        .{ "function_call_output", .function_call_output },
        .{ "custom_tool_call", .custom_tool_call },
        .{ "custom_tool_call_output", .custom_tool_call_output },
        .{ "web_search_call", .web_search_call },
        .{ "file_search_call", .file_search_call },
        .{ "image_generation_call", .image_generation_call },
        .{ "computer_call", .computer_call },
        .{ "local_shell_call", .local_shell_call },
        .{ "mcp_call", .mcp_call },
    };
    for (mappings) |mapping| {
        if (std.mem.eql(u8, raw, mapping[0])) return mapping[1];
    }
    return .other;
}

fn projectContentPart(root: JsonValue) ContentPartEvent {
    const part = objectField(root, "part");
    return .{
        .item_id = stringField(root, "item_id"),
        .output_index = unsignedField(root, "output_index"),
        .content_index = unsignedField(root, "content_index"),
        .part_type = if (part) |value| stringField(value, "type") else null,
        .text = if (part) |value| stringField(value, "text") orelse stringField(value, "refusal") else null,
    };
}

fn projectReasoningPart(root: JsonValue) ReasoningPartEvent {
    const part = objectField(root, "part");
    return .{
        .item_id = stringField(root, "item_id"),
        .output_index = unsignedField(root, "output_index"),
        .summary_index = unsignedField(root, "summary_index"),
        .part_type = if (part) |value| stringField(value, "type") else null,
        .text = if (part) |value| stringField(value, "text") else null,
    };
}

fn projectUsage(value: ?JsonValue) Usage {
    return compaction.projectUsage(value);
}

fn projectError(value: JsonValue, envelope: JsonValue) ResponseError {
    return .{
        .error_type = stringField(value, "type"),
        .code = stringField(value, "code"),
        .message = stringField(value, "message"),
        .param = stringField(value, "param"),
        .plan_type = stringField(value, "plan_type"),
        .resets_at = signedField(value, "resets_at"),
        .status_code = statusField(value) orelse statusField(envelope),
        .retry_after_seconds = retryAfterSeconds(value, envelope),
    };
}

fn projectTerminalMetadata(
    response: JsonValue,
    incomplete_details: ?JsonValue,
    envelope: JsonValue,
) ResponseError {
    const details = incomplete_details orelse response;
    return .{
        .status_code = statusField(details) orelse statusField(response) orelse statusField(envelope),
        .retry_after_seconds = retryAfterSeconds(details, response) orelse
            retryAfterSeconds(response, envelope),
        .resets_at = signedField(details, "resets_at") orelse
            signedField(response, "resets_at") orelse
            signedField(envelope, "resets_at"),
    };
}

fn mergeTerminalError(info_source: ResponseError, metadata: ResponseError) ResponseError {
    var info = info_source;
    if (info.status_code == null) info.status_code = metadata.status_code;
    if (info.retry_after_seconds == null) info.retry_after_seconds = metadata.retry_after_seconds;
    if (info.resets_at == null) info.resets_at = metadata.resets_at;
    return info;
}

fn hasResponseErrorMetadata(info: ResponseError) bool {
    return info.status_code != null or info.retry_after_seconds != null or info.resets_at != null;
}

fn stringField(value: JsonValue, name: []const u8) ?[]const u8 {
    const field = valueField(value, name) orelse return null;
    return if (field == .string) field.string else null;
}

fn valueField(value: JsonValue, name: []const u8) ?JsonValue {
    if (value != .object) return null;
    return value.object.get(name);
}

fn objectField(value: JsonValue, name: []const u8) ?JsonValue {
    const field = valueField(value, name) orelse return null;
    return if (field == .object) field else null;
}

fn boolField(value: JsonValue, name: []const u8) ?bool {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .bool) field.bool else null;
}

fn signedField(value: JsonValue, name: []const u8) ?i64 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return switch (field) {
        .integer => |number| number,
        else => null,
    };
}

fn unsignedField(value: JsonValue, name: []const u8) ?u64 {
    const signed = signedField(value, name) orelse return null;
    return std.math.cast(u64, signed);
}

fn numberField(value: JsonValue, name: []const u8) ?f64 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return switch (field) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => null,
    };
}

fn statusField(value: JsonValue) ?u16 {
    const raw = unsignedField(value, "status") orelse unsignedField(value, "status_code") orelse return null;
    return std.math.cast(u16, raw);
}

fn retryAfterSeconds(error_value: JsonValue, envelope: JsonValue) ?f64 {
    if (numberField(error_value, "retry_after")) |seconds| return seconds;
    if (numberField(error_value, "retry_after_seconds")) |seconds| return seconds;
    if (numberField(envelope, "retry_after")) |seconds| return seconds;
    const headers = objectField(envelope, "headers") orelse return null;
    var iterator = headers.object.iterator();
    while (iterator.next()) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.key_ptr.*, "retry-after")) continue;
        return switch (entry.value_ptr.*) {
            .integer => |number| @floatFromInt(number),
            .float => |number| number,
            .string => |text| std.fmt.parseFloat(f64, text) catch null,
            else => null,
        };
    }
    return null;
}

pub const DecodedError = struct {
    allocator: Allocator,
    raw_body: []u8,
    parsed: ?std.json.Parsed(JsonValue),
    info: ResponseError,

    pub fn deinit(self: *DecodedError) void {
        if (self.parsed) |*parsed| parsed.deinit();
        self.allocator.free(self.raw_body);
        self.* = undefined;
    }
};

/// Decodes the standard `{ "error": ... }` response envelope while retaining
/// non-JSON bodies as the error message and exact raw body.
pub fn decodeErrorResponse(
    alloc: Allocator,
    status_code: ?u16,
    body: []const u8,
) Allocator.Error!DecodedError {
    const raw = try alloc.dupe(u8, body);
    errdefer alloc.free(raw);
    var parsed = std.json.parseFromSlice(JsonValue, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{
            .allocator = alloc,
            .raw_body = raw,
            .parsed = null,
            .info = .{ .message = raw, .status_code = status_code },
        },
    };
    errdefer parsed.deinit();

    const error_value = valueField(parsed.value, "error") orelse parsed.value;
    var info = projectError(error_value, parsed.value);
    if (info.message == null and error_value == .string) info.message = error_value.string;
    if (info.status_code == null) info.status_code = status_code;
    return .{
        .allocator = alloc,
        .raw_body = raw,
        .parsed = parsed,
        .info = info,
    };
}

// Tests

fn testRequest(messages: []const types.ChatMessage, serialized_tools: []const u8) responses_compaction_provider.BuildRequest {
    return .{
        .model = "gpt-5.4",
        .serialized_tools = serialized_tools,
        .messages = messages,
        .tool_choice = .auto,
        .provider_options = .{},
    };
}

fn testField(value: JsonValue, name: []const u8) !JsonValue {
    return valueField(value, name) orelse error.TestMissingJsonField;
}

fn expectJsonString(expected: []const u8, value: JsonValue) !void {
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings(expected, value.string);
}

fn expectJsonBool(expected: bool, value: JsonValue) !void {
    try std.testing.expect(value == .bool);
    try std.testing.expectEqual(expected, value.bool);
}

test "Responses request preserves conversation semantics and controls" {
    const alloc = std.testing.allocator;
    const tool_calls = [_]types.ToolCall{.{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = "{\"path\":\"notes.txt\"}",
    }};
    var image_bytes = [_]u8{ 0x01, 0x02, 0x03 };
    const verified_images = [_]image_attachments.VerifiedSnapshot{.{
        .bytes = image_bytes[0..],
        .media_type = "image/png",
    }};
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "first instruction" },
        .{ .role = .system, .content = "second instruction" },
        .{ .role = .user, .content = "inspect this" },
        .{
            .role = .assistant,
            .content = "I will inspect it.",
            .tool_calls = &tool_calls,
            .reasoning = "Need the file contents.",
            .reasoning_signature = "anthropic-signature-must-not-appear",
            .reasoning_item_id = "rs_1",
            .reasoning_encrypted_content = "encrypted-responses-state",
        },
        .{
            .role = .tool,
            .content = "file contents",
            .tool_call_id = "call_1",
            .tool_name = "read_file",
        },
    };
    const dynamic_tools = [_][]const u8{
        "{\"type\":\"function\",\"name\":\"lookup\",\"description\":\"Lookup\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}",
    };
    const request = responses_compaction_provider.BuildRequest{
        .model = "gpt-5.4",
        .serialized_tools =
        \\[{"type":"function","name":"read_file","description":"Read a file","inputSchema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}]
        ,
        .messages = &messages,
        .tool_choice = .auto,
        .selected_dynamic_tool_schemas = &dynamic_tools,
        .provider_options = .{
            .reasoning = types.ReasoningEffort.literal("high"),
            .parallel_tool_calls = true,
        },
        .max_output_tokens = 4096,
        .verified_images = &verified_images,
        .response_format = .{
            .name = "answer",
            .description = "A structured answer",
            .schema_json = "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}},\"required\":[\"answer\"]}",
        },
    };

    const body = try buildRequest(alloc, request, .{
        .store = true,
        .include = &.{ "reasoning.encrypted_content", "message.output_text.logprobs" },
        .prompt_cache_key = "session-1",
        .service_tier = "flex",
        .reasoning_summary = "detailed",
        .function_tools_strict = true,
        .tool_choice_json = "{\"type\":\"function\",\"name\":\"read_file\"}",
        .extra_fields_json = "{\"background\":false,\"temperature\":0.25}",
    });
    defer alloc.free(body);

    try std.testing.expect(std.mem.find(u8, body, "anthropic-signature-must-not-appear") == null);
    try std.testing.expect(std.mem.find(u8, body, "tool_name") == null);

    var parsed = try std.json.parseFromSlice(JsonValue, alloc, body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    try expectJsonString("gpt-5.4", try testField(root, "model"));
    try expectJsonString("first instruction\n\nsecond instruction", try testField(root, "instructions"));
    try expectJsonBool(true, try testField(root, "store"));
    try expectJsonBool(true, try testField(root, "stream"));
    try expectJsonBool(true, try testField(root, "parallel_tool_calls"));
    try expectJsonBool(false, try testField(root, "background"));
    try expectJsonString("session-1", try testField(root, "prompt_cache_key"));
    try expectJsonString("flex", try testField(root, "service_tier"));
    try std.testing.expectEqual(@as(i64, 4096), (try testField(root, "max_output_tokens")).integer);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), (try testField(root, "temperature")).float, 0.000001);

    const reasoning_config = try testField(root, "reasoning");
    try expectJsonString("high", try testField(reasoning_config, "effort"));
    try expectJsonString("detailed", try testField(reasoning_config, "summary"));

    const input = (try testField(root, "input")).array.items;
    try std.testing.expectEqual(@as(usize, 5), input.len);
    try expectJsonString("message", try testField(input[0], "type"));
    try expectJsonString("user", try testField(input[0], "role"));
    const user_parts = (try testField(input[0], "content")).array.items;
    try std.testing.expectEqual(@as(usize, 2), user_parts.len);
    try expectJsonString("input_text", try testField(user_parts[0], "type"));
    try expectJsonString("inspect this", try testField(user_parts[0], "text"));
    try expectJsonString("input_image", try testField(user_parts[1], "type"));
    try expectJsonString("data:image/png;base64,AQID", try testField(user_parts[1], "image_url"));

    try expectJsonString("reasoning", try testField(input[1], "type"));
    try expectJsonString("rs_1", try testField(input[1], "id"));
    try expectJsonString("encrypted-responses-state", try testField(input[1], "encrypted_content"));
    const summary = (try testField(input[1], "summary")).array.items;
    try std.testing.expectEqual(@as(usize, 1), summary.len);
    try expectJsonString("summary_text", try testField(summary[0], "type"));
    try expectJsonString("Need the file contents.", try testField(summary[0], "text"));

    try expectJsonString("message", try testField(input[2], "type"));
    try expectJsonString("assistant", try testField(input[2], "role"));
    const assistant_parts = (try testField(input[2], "content")).array.items;
    try expectJsonString("output_text", try testField(assistant_parts[0], "type"));
    try expectJsonString("I will inspect it.", try testField(assistant_parts[0], "text"));
    try expectJsonString("function_call", try testField(input[3], "type"));
    try expectJsonString("call_1", try testField(input[3], "call_id"));
    try expectJsonString("read_file", try testField(input[3], "name"));
    try expectJsonString("{\"path\":\"notes.txt\"}", try testField(input[3], "arguments"));
    try expectJsonString("function_call_output", try testField(input[4], "type"));
    try expectJsonString("call_1", try testField(input[4], "call_id"));
    try expectJsonString("file contents", try testField(input[4], "output"));
    try std.testing.expect(valueField(input[4], "name") == null);

    const tools = (try testField(root, "tools")).array.items;
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    try expectJsonString("function", try testField(tools[0], "type"));
    try expectJsonString("read_file", try testField(tools[0], "name"));
    try std.testing.expect(valueField(tools[0], "inputSchema") == null);
    try std.testing.expect((try testField(tools[0], "parameters")) == .object);
    try expectJsonBool(true, try testField(tools[0], "strict"));
    try expectJsonString("lookup", try testField(tools[1], "name"));
    try std.testing.expect(valueField(tools[1], "inputSchema") == null);

    const choice = try testField(root, "tool_choice");
    try expectJsonString("function", try testField(choice, "type"));
    try expectJsonString("read_file", try testField(choice, "name"));
    const format = try testField(try testField(root, "text"), "format");
    try expectJsonString("json_schema", try testField(format, "type"));
    try expectJsonString("answer", try testField(format, "name"));
    try expectJsonBool(true, try testField(format, "strict"));
    try std.testing.expect((try testField(format, "schema")) == .object);
}

test "Responses system-only continuation emits required input" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "compacted session context" },
    };
    const body = try buildRequest(alloc, testRequest(&messages, "[]"), .{});
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(JsonValue, alloc, body, .{});
    defer parsed.deinit();
    try expectJsonString(
        "compacted session context",
        try testField(parsed.value, "instructions"),
    );
    const input = (try testField(parsed.value, "input")).array.items;
    try std.testing.expectEqual(@as(usize, 1), input.len);
    try expectJsonString("user", try testField(input[0], "role"));
    const content = (try testField(input[0], "content")).array.items;
    try expectJsonString(
        system_only_continuation_input,
        try testField(content[0], "text"),
    );
}

test "Responses request replays permissioned web search with its namespace identity" {
    const alloc = std.testing.allocator;
    const tool_calls = [_]types.ToolCall{.{
        .id = "call_web",
        .name = "web_search",
        .arguments_json = "{\"search_query\":[{\"q\":\"Zig news\"}]}",
        .responses_item_id = "fc_web",
    }};
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &tool_calls },
        .{
            .role = .tool,
            .tool_call_id = "call_web",
            .tool_name = "web_search",
            .content = "search results",
        },
    };
    const body = try buildRequest(alloc, testRequest(
        &messages,
        "[{\"type\":\"namespace\",\"name\":\"web\",\"tools\":[{\"type\":\"function\",\"name\":\"run\",\"parameters\":{\"type\":\"object\"}}]}]",
    ), .{});
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(JsonValue, alloc, body, .{});
    defer parsed.deinit();
    const input = (try testField(parsed.value, "input")).array.items;
    try std.testing.expectEqual(@as(usize, 2), input.len);
    try expectJsonString("function_call", try testField(input[0], "type"));
    try expectJsonString("fc_web", try testField(input[0], "id"));
    try expectJsonString("call_web", try testField(input[0], "call_id"));
    try expectJsonString("web", try testField(input[0], "namespace"));
    try expectJsonString("run", try testField(input[0], "name"));
    try expectJsonString(
        "{\"search_query\":[{\"q\":\"Zig news\"}]}",
        try testField(input[0], "arguments"),
    );
    try expectJsonString("function_call_output", try testField(input[1], "type"));
    try expectJsonString("call_web", try testField(input[1], "call_id"));
    try expectJsonString("web", try testField(input[1], "namespace"));
    try expectJsonString("run", try testField(input[1], "name"));
    try expectJsonString("search results", try testField(input[1], "output"));
    try std.testing.expect(valueField(input[0], "web_search") == null);
}

test "Responses request rejects ambiguous local and namespace web search tools" {
    const messages = [_]types.ChatMessage{};
    try std.testing.expectError(
        error.AmbiguousResponsesWebSearchTools,
        buildRequest(std.testing.allocator, testRequest(
            &messages,
            "[{\"type\":\"function\",\"name\":\"web_search\"},{\"type\":\"namespace\",\"name\":\"web\",\"tools\":[{\"type\":\"function\",\"name\":\"run\"}]}]",
        ), .{}),
    );
}

test "Responses request capability filters do not confuse Anthropic reasoning signatures" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{.{
        .role = .assistant,
        .reasoning_signature = "anthropic-only",
        .reasoning_item_id = "rs_replay",
        .reasoning_encrypted_content = "encrypted-but-disabled",
    }};
    var request = testRequest(&messages, "[]");
    request.tool_choice = .none;
    request.max_output_tokens = 1234;

    const body = try buildRequest(alloc, request, .{
        .capabilities = .{
            .supports_max_output_tokens = false,
            .supports_prompt_cache_key = false,
            .supports_encrypted_reasoning = false,
        },
        .include = &.{},
        .prompt_cache_key = "must-be-omitted",
    });
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "anthropic-only") == null);
    try std.testing.expect(std.mem.find(u8, body, "encrypted-but-disabled") == null);

    var parsed = try std.json.parseFromSlice(JsonValue, alloc, body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    try std.testing.expect(valueField(root, "max_output_tokens") == null);
    try std.testing.expect(valueField(root, "prompt_cache_key") == null);
    try std.testing.expect(valueField(root, "include") == null);
    try expectJsonString("none", try testField(root, "tool_choice"));
    const input = (try testField(root, "input")).array.items;
    try std.testing.expectEqual(@as(usize, 1), input.len);
    try expectJsonString("reasoning", try testField(input[0], "type"));
    try expectJsonString("rs_replay", try testField(input[0], "id"));
    try std.testing.expect(valueField(input[0], "encrypted_content") == null);
    try std.testing.expectEqual(@as(usize, 0), (try testField(input[0], "summary")).array.items.len);
}

test "Responses request replays finalized reasoning items in order" {
    const alloc = std.testing.allocator;
    const reasoning_items = [_]types.ResponsesReasoningItem{
        .{ .id = "rs_1", .summary = "first", .encrypted_content = "opaque-1" },
        .{ .id = "rs_2", .summary = "second", .encrypted_content = "opaque-2" },
    };
    const messages = [_]types.ChatMessage{.{
        .role = .assistant,
        .reasoning = "legacy-must-not-duplicate",
        .reasoning_item_id = "legacy-id",
        .reasoning_encrypted_content = "legacy-opaque",
        .reasoning_items = &reasoning_items,
    }};
    const body = try buildRequest(alloc, testRequest(&messages, "[]"), .{});
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(JsonValue, alloc, body, .{});
    defer parsed.deinit();
    const input = (try testField(parsed.value, "input")).array.items;
    try std.testing.expectEqual(@as(usize, 2), input.len);
    try expectJsonString("rs_1", try testField(input[0], "id"));
    try expectJsonString("opaque-1", try testField(input[0], "encrypted_content"));
    try expectJsonString(
        "first",
        try testField((try testField(input[0], "summary")).array.items[0], "text"),
    );
    try expectJsonString("rs_2", try testField(input[1], "id"));
    try expectJsonString("opaque-2", try testField(input[1], "encrypted_content"));
    try expectJsonString(
        "second",
        try testField((try testField(input[1], "summary")).array.items[0], "text"),
    );
    try std.testing.expect(std.mem.find(u8, body, "legacy-must-not-duplicate") == null);
    try std.testing.expect(std.mem.find(u8, body, "legacy-opaque") == null);
}

test "Responses request replays a complete terminal output sequence verbatim in order" {
    const alloc = std.testing.allocator;
    const output_items = [_]types.ResponsesProviderOutputItem{
        .{ .output_index = 0, .json = "{\"type\":\"reasoning\",\"id\":\"rs_wire_1\",\"summary\":[]}" },
        .{ .output_index = 1, .json = "{\"type\":\"web_search_call\",\"id\":\"ws_wire\",\"status\":\"completed\",\"results\":[{\"title\":\"Zig\",\"url\":\"https://ziglang.org\"}]}" },
        .{ .output_index = 2, .json = "{\"type\":\"reasoning\",\"id\":\"rs_wire_2\",\"summary\":[]}" },
        .{ .output_index = 3, .json = "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"wire answer\"}]}" },
    };
    const semantic_reasoning = [_]types.ResponsesReasoningItem{.{
        .output_index = 7,
        .id = "semantic-must-not-replay",
    }};
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "previous question" },
        .{
            .role = .assistant,
            .content = "semantic answer must not replay",
            .reasoning_items = &semantic_reasoning,
            .responses_provider_output_items = &output_items,
            .responses_output_sequence_complete = true,
        },
        .{ .role = .user, .content = "current question" },
    };

    const body = try buildRequest(alloc, testRequest(&messages, "[]"), .{});
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "semantic-must-not-replay") == null);
    try std.testing.expect(std.mem.find(u8, body, "semantic answer must not replay") == null);

    var parsed = try std.json.parseFromSlice(JsonValue, alloc, body, .{});
    defer parsed.deinit();
    const input = (try testField(parsed.value, "input")).array.items;
    try std.testing.expectEqual(@as(usize, 6), input.len);
    try expectJsonString("previous question", try testField(
        (try testField(input[0], "content")).array.items[0],
        "text",
    ));
    try expectJsonString("rs_wire_1", try testField(input[1], "id"));
    try expectJsonString("web_search_call", try testField(input[2], "type"));
    try expectJsonString("rs_wire_2", try testField(input[3], "id"));
    try expectJsonString(
        "wire answer",
        try testField((try testField(input[4], "content")).array.items[0], "text"),
    );
    try expectJsonString("current question", try testField(
        (try testField(input[5], "content")).array.items[0],
        "text",
    ));
}

test "Responses complete output sequence survives canonical session resume" {
    const session = @import("../session/session.zig");
    const session_codec = @import("../session/session_codec.zig");
    const alloc = std.testing.allocator;
    var output_items = [_]types.ResponsesProviderOutputItem{
        .{ .output_index = 0, .json = "{\"type\":\"reasoning\",\"id\":\"rs_resume_1\",\"summary\":[]}" },
        .{ .output_index = 1, .json = "{\"type\":\"web_search_call\",\"id\":\"ws_resume\",\"status\":\"completed\"}" },
        .{ .output_index = 2, .json = "{\"type\":\"reasoning\",\"id\":\"rs_resume_2\",\"summary\":[]}" },
        .{ .output_index = 3, .json = "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"resumed answer\"}]}" },
    };
    const history_turn = session.HistoryTurn{ .assistant = .{
        .user = .{ .text = @constCast("previous question") },
        .assistant = @constCast("resumed answer"),
        .responses_message_output_index = 3,
        .responses_provider_output_items = &output_items,
        .responses_output_sequence_complete = true,
    } };
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try session_codec.writeHistoryTurn(&encoded.writer, history_turn);
    var parsed_turn = try std.json.parseFromSlice(JsonValue, alloc, encoded.written(), .{});
    defer parsed_turn.deinit();
    const resumed = try session_codec.parseHistoryTurn(alloc, parsed_turn.value);
    defer session.freeHistoryTurn(alloc, resumed);

    var messages: std.ArrayList(types.ChatMessage) = .empty;
    defer messages.deinit(alloc);
    try session.appendHistoryChatMessages(alloc, &messages, &.{resumed});
    try messages.append(alloc, .{ .role = .user, .content = "current question" });
    const body = try buildRequest(alloc, testRequest(messages.items, "[]"), .{});
    defer alloc.free(body);
    var request = try std.json.parseFromSlice(JsonValue, alloc, body, .{});
    defer request.deinit();
    const input = (try testField(request.value, "input")).array.items;
    try std.testing.expectEqual(@as(usize, 6), input.len);
    try expectJsonString("reasoning", try testField(input[1], "type"));
    try expectJsonString("web_search_call", try testField(input[2], "type"));
    try expectJsonString("rs_resume_2", try testField(input[3], "id"));
    try expectJsonString("resumed answer", try testField(
        (try testField(input[4], "content")).array.items[0],
        "text",
    ));
    try expectJsonString("current question", try testField(
        (try testField(input[5], "content")).array.items[0],
        "text",
    ));
}

test "Responses request merges incomplete raw and indexed semantic projections" {
    const alloc = std.testing.allocator;
    const raw_items = [_]types.ResponsesProviderOutputItem{.{
        .output_index = 1,
        .json = "{\"type\":\"web_search_call\",\"id\":\"ws_1\",\"status\":\"completed\"}",
    }};
    const reasoning_items = [_]types.ResponsesReasoningItem{.{
        .output_index = 0,
        .id = "rs_1",
        .summary = "checked sources",
    }};
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "previous question" },
        .{
            .role = .assistant,
            .content = "projected answer",
            .responses_message_output_index = 2,
            .reasoning_items = &reasoning_items,
            .responses_provider_output_items = &raw_items,
        },
        .{ .role = .user, .content = "current question" },
    };

    const body = try buildRequest(alloc, testRequest(&messages, "[]"), .{});
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(JsonValue, alloc, body, .{});
    defer parsed.deinit();
    const input = (try testField(parsed.value, "input")).array.items;
    try std.testing.expectEqual(@as(usize, 5), input.len);
    try expectJsonString("reasoning", try testField(input[1], "type"));
    try expectJsonString("web_search_call", try testField(input[2], "type"));
    try expectJsonString("message", try testField(input[3], "type"));
    try expectJsonString("current question", try testField(
        (try testField(input[4], "content")).array.items[0],
        "text",
    ));

    var missing_index = messages;
    missing_index[1].responses_message_output_index = null;
    try std.testing.expectError(
        error.InvalidResponsesOutputOrder,
        buildRequest(alloc, testRequest(&missing_index, "[]"), .{}),
    );
}

test "Responses raw request options preserve non-fx input and merge typed objects" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{.{
        .role = .system,
        .content = "Keep this instruction.",
    }};
    var request = testRequest(&messages, "[]");
    request.provider_options.reasoning = types.ReasoningEffort.literal("high");
    request.response_format = .{
        .name = "answer",
        .description = "",
        .schema_json = "{\"type\":\"object\",\"properties\":{}}",
    };

    const body = try buildRequest(alloc, request, .{
        .reasoning_summary = "auto",
        .responses_input_json =
        \\[{
        \\  "type":"message",
        \\  "role":"user",
        \\  "content":[
        \\    {"type":"input_audio","input_audio":{"data":"UklGRg==","format":"wav"}},
        \\    {"type":"input_file","file_id":"file_123"}
        \\  ]
        \\},{
        \\  "type":"function_call_output",
        \\  "call_id":"call_1",
        \\  "output":[
        \\    {"type":"input_text","text":"tool result"},
        \\    {"type":"input_file","file_url":"https://example.test/result.txt"}
        \\  ]
        \\}]
        ,
        .responses_text_options_json =
        \\{"verbosity":"low","future_output_control":true}
        ,
        .responses_reasoning_options_json =
        \\{"context":"auto","future_reasoning_mode":"compact"}
        ,
    });
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(JsonValue, alloc, body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    try expectJsonString("Keep this instruction.", try testField(root, "instructions"));

    const input = (try testField(root, "input")).array.items;
    try std.testing.expectEqual(@as(usize, 2), input.len);
    const raw_content = (try testField(input[0], "content")).array.items;
    try expectJsonString("input_audio", try testField(raw_content[0], "type"));
    try expectJsonString(
        "wav",
        try testField(try testField(raw_content[0], "input_audio"), "format"),
    );
    try expectJsonString("input_file", try testField(raw_content[1], "type"));
    try expectJsonString("file_123", try testField(raw_content[1], "file_id"));
    try expectJsonString("function_call_output", try testField(input[1], "type"));
    try std.testing.expect((try testField(input[1], "output")) == .array);

    const text_options = try testField(root, "text");
    try expectJsonString("low", try testField(text_options, "verbosity"));
    try expectJsonBool(true, try testField(text_options, "future_output_control"));
    try expectJsonString(
        "json_schema",
        try testField(try testField(text_options, "format"), "type"),
    );

    const reasoning_options = try testField(root, "reasoning");
    try expectJsonString("high", try testField(reasoning_options, "effort"));
    try expectJsonString("auto", try testField(reasoning_options, "summary"));
    try expectJsonString("auto", try testField(reasoning_options, "context"));
    try expectJsonString(
        "compact",
        try testField(reasoning_options, "future_reasoning_mode"),
    );
}

test "Responses raw input also accepts the string form" {
    const body = try buildRequest(
        std.testing.allocator,
        testRequest(&.{}, "[]"),
        .{ .responses_input_json = "\"plain prompt\"" },
    );
    defer std.testing.allocator.free(body);
    var parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try expectJsonString("plain prompt", try testField(parsed.value, "input"));
}

test "Responses V2 compaction appends exactly one final trigger" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "compact this" }};
    var request = testRequest(&messages, "[]");
    request.responses_compaction_trigger = true;

    const body = try buildRequest(alloc, request, .{});
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(JsonValue, alloc, body, .{});
    defer parsed.deinit();
    const input = (try testField(parsed.value, "input")).array.items;
    try std.testing.expectEqual(@as(usize, 2), input.len);
    try expectJsonString("message", try testField(input[0], "type"));
    try expectJsonString(compaction.v2_trigger_type, try testField(input[1], "type"));

    const raw_request = blk: {
        var value = testRequest(&.{}, "[]");
        value.responses_compaction_trigger = true;
        break :blk value;
    };
    const raw_body = try buildRequest(alloc, raw_request, .{
        .responses_input_json = "[{\"type\":\"compaction\",\"encrypted_content\":\"opaque\"}]",
    });
    defer alloc.free(raw_body);
    var raw_parsed = try std.json.parseFromSlice(JsonValue, alloc, raw_body, .{});
    defer raw_parsed.deinit();
    const raw_input = (try testField(raw_parsed.value, "input")).array.items;
    try std.testing.expectEqual(@as(usize, 2), raw_input.len);
    try expectJsonString("compaction", try testField(raw_input[0], "type"));
    try expectJsonString(compaction.v2_trigger_type, try testField(raw_input[1], "type"));

    try std.testing.expectError(
        error.InvalidResponsesCompactionTriggerInput,
        buildRequest(alloc, raw_request, .{ .responses_input_json = "\"prompt\"" }),
    );
    try std.testing.expectError(
        error.DuplicateResponsesCompactionTrigger,
        buildRequest(alloc, raw_request, .{
            .responses_input_json = "[{\"type\":\"compaction_trigger\"}]",
        }),
    );
}

test "Responses checkpoint replays only for its exact provider and wire model" {
    const alloc = std.testing.allocator;
    const replay_json =
        "[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"future\":1}," ++
        "{\"type\":\"compaction\",\"encrypted_content\":\"opaque\"}]";
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "base instruction" },
        .{
            .role = .system,
            .content = "portable local summary",
            .responses_compaction = .{
                .credential_source = .chatgpt_subscription,
                .wire_model = "gpt-5.6-sol",
                .input_json = replay_json,
                .provider_binding = .{
                    .normalized_origin = "https://chatgpt.com/backend-api/codex/responses",
                    .account_id = "account-a",
                },
            },
        },
        .{ .role = .user, .content = "new turn" },
    };
    var exact = testRequest(&messages, "[]");
    exact.model = "gpt-5.6-sol";
    exact.credential_source = .chatgpt_subscription;
    exact.responses_compaction_binding = .{
        .normalized_origin = "https://chatgpt.com/backend-api/codex/responses",
        .account_id = "account-a",
    };
    const exact_body = try buildRequest(alloc, exact, .{});
    defer alloc.free(exact_body);
    var exact_parsed = try std.json.parseFromSlice(JsonValue, alloc, exact_body, .{});
    defer exact_parsed.deinit();
    try expectJsonString(
        "base instruction",
        try testField(exact_parsed.value, "instructions"),
    );
    const exact_input = (try testField(exact_parsed.value, "input")).array.items;
    try std.testing.expectEqual(@as(usize, 3), exact_input.len);
    try expectJsonString("message", try testField(exact_input[0], "type"));
    try std.testing.expect(exact_input[0].object.get("future") != null);
    try expectJsonString("compaction", try testField(exact_input[1], "type"));
    try expectJsonString("message", try testField(exact_input[2], "type"));

    var mismatched = exact;
    mismatched.model = "gpt-5.4";
    const mismatch_body = try buildRequest(alloc, mismatched, .{});
    defer alloc.free(mismatch_body);
    var mismatch_parsed = try std.json.parseFromSlice(JsonValue, alloc, mismatch_body, .{});
    defer mismatch_parsed.deinit();
    try expectJsonString(
        "base instruction\n\nportable local summary",
        try testField(mismatch_parsed.value, "instructions"),
    );
    const mismatch_input = (try testField(mismatch_parsed.value, "input")).array.items;
    try std.testing.expectEqual(@as(usize, 1), mismatch_input.len);
    const mismatch_content = (try testField(mismatch_input[0], "content")).array.items;
    try expectJsonString(
        "new turn",
        mismatch_content[0].object.get("text").?,
    );

    var wrong_account = exact;
    wrong_account.responses_compaction_binding = .{
        .normalized_origin = "https://chatgpt.com/backend-api/codex/responses",
        .account_id = "account-b",
    };
    const wrong_account_body = try buildRequest(alloc, wrong_account, .{});
    defer alloc.free(wrong_account_body);
    var wrong_account_parsed = try std.json.parseFromSlice(
        JsonValue,
        alloc,
        wrong_account_body,
        .{},
    );
    defer wrong_account_parsed.deinit();
    try expectJsonString(
        "base instruction\n\nportable local summary",
        try testField(wrong_account_parsed.value, "instructions"),
    );

    var legacy_messages = messages;
    legacy_messages[1].responses_compaction = .{
        .credential_source = .chatgpt_subscription,
        .wire_model = "gpt-5.6-sol",
        .input_json = replay_json,
    };
    var legacy_request = testRequest(&legacy_messages, "[]");
    legacy_request.model = "gpt-5.6-sol";
    legacy_request.credential_source = .chatgpt_subscription;
    legacy_request.responses_compaction_binding = exact.responses_compaction_binding;
    const legacy_body = try buildRequest(alloc, legacy_request, .{});
    defer alloc.free(legacy_body);
    var legacy_parsed = try std.json.parseFromSlice(JsonValue, alloc, legacy_body, .{});
    defer legacy_parsed.deinit();
    try expectJsonString(
        "base instruction\n\nportable local summary",
        try testField(legacy_parsed.value, "instructions"),
    );
}

test "Responses checkpoint rejects OpenAI key base organization and project drift" {
    const alloc = std.testing.allocator;
    const digest_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const digest_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const replay_json =
        "[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}," ++
        "{\"type\":\"compaction\",\"encrypted_content\":\"opaque\"}]";
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "base instruction" },
        .{
            .role = .system,
            .content = "portable local summary",
            .responses_compaction = .{
                .credential_source = .openai_api_key,
                .wire_model = "gpt-5.4",
                .input_json = replay_json,
                .provider_binding = .{
                    .normalized_origin = "https://api.openai.com/v1/responses",
                    .api_key_sha256 = digest_a,
                    .organization = "org-a",
                    .project = "project-a",
                },
            },
        },
        .{ .role = .user, .content = "new turn" },
    };
    const changed_bindings = [_]types.ResponsesCompactionProviderBindingView{
        .{
            .normalized_origin = "https://api.openai.com/v1/responses",
            .api_key_sha256 = digest_b,
            .organization = "org-a",
            .project = "project-a",
        },
        .{
            .normalized_origin = "https://proxy.example/v1/responses",
            .api_key_sha256 = digest_a,
            .organization = "org-a",
            .project = "project-a",
        },
        .{
            .normalized_origin = "https://api.openai.com/v1/responses",
            .api_key_sha256 = digest_a,
            .organization = "org-b",
            .project = "project-a",
        },
        .{
            .normalized_origin = "https://api.openai.com/v1/responses",
            .api_key_sha256 = digest_a,
            .organization = "org-a",
            .project = "project-b",
        },
    };

    for (changed_bindings) |changed| {
        var request = testRequest(&messages, "[]");
        request.model = "gpt-5.4";
        request.credential_source = .openai_api_key;
        request.responses_compaction_binding = changed;
        const body = try buildRequest(alloc, request, .{});
        defer alloc.free(body);
        var parsed = try std.json.parseFromSlice(JsonValue, alloc, body, .{});
        defer parsed.deinit();
        try expectJsonString(
            "base instruction\n\nportable local summary",
            try testField(parsed.value, "instructions"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            (try testField(parsed.value, "input")).array.items.len,
        );
    }
}

test "dedicated Responses compact request reuses normal history and controls" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "compact instruction" },
        .{ .role = .user, .content = "compact this" },
    };
    var request = testRequest(&messages,
        \\[{"type":"function","name":"lookup","description":"Lookup","inputSchema":{"type":"object","properties":{}}}]
    );
    request.credential_source = .openai_api_key;
    request.provider_options = .{
        .reasoning = types.ReasoningEffort.literal("high"),
        .parallel_tool_calls = true,
        .fast = true,
    };
    const body = try buildCompactRequest(alloc, request, .{
        .prompt_cache_key = "session-compact",
        .reasoning_summary = "auto",
        .function_tools_strict = false,
    });
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(JsonValue, alloc, body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    try expectJsonString("gpt-5.4", try testField(root, "model"));
    try expectJsonString("compact instruction", try testField(root, "instructions"));
    try std.testing.expectEqual(@as(usize, 1), (try testField(root, "input")).array.items.len);
    try std.testing.expectEqual(@as(usize, 1), (try testField(root, "tools")).array.items.len);
    try expectJsonBool(true, try testField(root, "parallel_tool_calls"));
    try expectJsonString("high", try testField(try testField(root, "reasoning"), "effort"));
    try expectJsonString("auto", try testField(try testField(root, "reasoning"), "summary"));
    try expectJsonString("priority", try testField(root, "service_tier"));
    try expectJsonString("session-compact", try testField(root, "prompt_cache_key"));
    try std.testing.expect(root.object.get("store") == null);
    try std.testing.expect(root.object.get("stream") == null);
    try std.testing.expect(root.object.get("include") == null);

    request.responses_compaction_trigger = true;
    try std.testing.expectError(
        error.InvalidResponsesCompactionMode,
        buildCompactRequest(alloc, request, .{}),
    );
}

test "Responses raw request options reject invalid types and typed conflicts" {
    const alloc = std.testing.allocator;
    const system_messages = [_]types.ChatMessage{.{ .role = .system, .content = "instruction" }};
    const raw_input = "[{\"role\":\"user\",\"content\":\"hello\"}]";
    var request = testRequest(&system_messages, "[]");

    const user_messages = [_]types.ChatMessage{.{ .role = .user, .content = "derived" }};
    try std.testing.expectError(
        error.ConflictingResponsesInput,
        buildRequest(alloc, testRequest(&user_messages, "[]"), .{
            .responses_input_json = raw_input,
        }),
    );

    const empty_images = [_]image_attachments.VerifiedSnapshot{};
    request.verified_images = &empty_images;
    try std.testing.expectError(
        error.ConflictingResponsesInput,
        buildRequest(alloc, request, .{ .responses_input_json = raw_input }),
    );
    request.verified_images = null;

    for ([_][]const u8{ "{", "null", "123", "{}", "\"\"", "[]" }) |invalid| {
        try std.testing.expectError(
            error.InvalidResponsesInput,
            buildRequest(alloc, request, .{ .responses_input_json = invalid }),
        );
    }
    try std.testing.expectError(
        error.InvalidResponsesTextOptions,
        buildRequest(alloc, request, .{ .responses_text_options_json = "[]" }),
    );
    try std.testing.expectError(
        error.InvalidResponsesReasoningOptions,
        buildRequest(alloc, request, .{ .responses_reasoning_options_json = "\"high\"" }),
    );

    request.response_format = .{
        .name = "answer",
        .description = "",
        .schema_json = "{\"type\":\"object\"}",
    };
    try std.testing.expectError(
        error.DuplicateResponsesTextField,
        buildRequest(alloc, request, .{
            .responses_text_options_json = "{\"format\":{\"type\":\"text\"}}",
        }),
    );
    request.response_format = null;

    request.provider_options.reasoning = types.ReasoningEffort.literal("high");
    try std.testing.expectError(
        error.DuplicateResponsesReasoningField,
        buildRequest(alloc, request, .{
            .responses_reasoning_options_json = "{\"effort\":\"low\"}",
        }),
    );
    request.provider_options.reasoning = null;
    try std.testing.expectError(
        error.DuplicateResponsesReasoningField,
        buildRequest(alloc, request, .{
            .reasoning_summary = "auto",
            .responses_reasoning_options_json = "{\"summary\":\"detailed\"}",
        }),
    );
}

fn checkRawResponsesRequestAllocationFailures(alloc: Allocator) !void {
    const messages = [_]types.ChatMessage{.{ .role = .system, .content = "instruction" }};
    var request = testRequest(&messages, "[]");
    request.provider_options.reasoning = types.ReasoningEffort.literal("high");
    request.response_format = .{
        .name = "answer",
        .description = "",
        .schema_json = "{\"type\":\"object\"}",
    };
    request.responses_compaction_trigger = true;
    const body = buildRequest(alloc, request, .{
        .reasoning_summary = "auto",
        .responses_input_json = "[{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_file\",\"file_id\":\"file_123\"}]}]",
        .responses_text_options_json = "{\"verbosity\":\"low\"}",
        .responses_reasoning_options_json = "{\"context\":\"auto\"}",
    }) catch |err| switch (err) {
        // Allocating writers expose allocator exhaustion as WriteFailed.
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer alloc.free(body);
}

test "Responses raw request options clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkRawResponsesRequestAllocationFailures,
        .{},
    );
}

test "Responses request rejects invalid extension and schema boundaries" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hello" }};
    const base = testRequest(&messages, "[]");

    try std.testing.expectError(
        error.DuplicateResponsesRequestField,
        buildRequest(alloc, base, .{ .extra_fields_json = "{\"model\":\"override\"}" }),
    );
    try std.testing.expectError(
        error.DuplicateResponsesRequestField,
        buildRequest(alloc, base, .{ .extra_fields_json = "{\"input\":[]}" }),
    );
    try std.testing.expectError(
        error.InvalidResponsesExtraFields,
        buildRequest(alloc, base, .{ .extra_fields_json = "[]" }),
    );
    try std.testing.expectError(
        error.InvalidResponsesToolChoice,
        buildRequest(alloc, base, .{ .tool_choice_json = "{" }),
    );

    var bad_format = base;
    bad_format.response_format = .{
        .name = "bad",
        .description = "",
        .schema_json = "[]",
    };
    try std.testing.expectError(
        error.InvalidStructuredResponseSchema,
        buildRequest(alloc, bad_format, .{}),
    );

    var bad_tools = base;
    bad_tools.serialized_tools =
        \\[{"type":"function","name":"bad","inputSchema":[]}]
    ;
    try std.testing.expectError(error.InvalidResponsesTools, buildRequest(alloc, bad_tools, .{}));
}

test "Responses request rejects incomplete function call history" {
    const alloc = std.testing.allocator;
    const calls = [_]types.ToolCall{.{
        .id = "call_missing",
        .name = "lookup",
        .arguments_json = "{}",
    }};
    const messages = [_]types.ChatMessage{.{
        .role = .assistant,
        .tool_calls = &calls,
    }};
    try std.testing.expectError(
        error.InvalidGatewayHistory,
        buildRequest(alloc, testRequest(&messages, "[]"), .{}),
    );
}

test "Responses completed event projects detailed usage" {
    const raw =
        \\{"type":"response.completed","sequence_number":42,"response":{"id":"resp_1","status":"completed","model":"gpt-5.4","end_turn":true,"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":25,"cache_write_tokens":5},"output_tokens":20,"output_tokens_details":{"reasoning_tokens":7},"total_tokens":120,"codex_rollout_budget_units":1.25}}}
    ;
    var decoded = try decodeEvent(std.testing.allocator, raw);
    defer decoded.deinit();
    const terminal = switch (decoded.projection) {
        .response_completed => |value| value,
        else => return error.TestUnexpectedProjection,
    };
    try std.testing.expectEqualStrings("resp_1", terminal.response_id.?);
    try std.testing.expectEqualStrings("completed", terminal.status.?);
    try std.testing.expectEqualStrings("gpt-5.4", terminal.model.?);
    try std.testing.expectEqual(true, terminal.end_turn.?);
    try std.testing.expectEqual(@as(?u64, 100), terminal.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 25), terminal.usage.cached_input_tokens);
    try std.testing.expectEqual(@as(?u64, 5), terminal.usage.cache_write_input_tokens);
    try std.testing.expectEqual(@as(?u64, 20), terminal.usage.output_tokens);
    try std.testing.expectEqual(@as(?u64, 7), terminal.usage.reasoning_output_tokens);
    try std.testing.expectEqual(@as(?u64, 120), terminal.usage.total_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), terminal.usage.codex_rollout_budget_units.?, 0.000001);
}

test "Responses failed and incomplete events retain terminal diagnostics" {
    {
        const raw =
            \\{"type":"response.failed","status":429,"headers":{"Retry-After":"1.5"},"response":{"id":"resp_failed","status":"failed","error":{"type":"rate_limit_error","code":"rate_limit_exceeded","message":"slow down","param":"model","plan_type":"plus","resets_at":12345}}}
        ;
        var decoded = try decodeEvent(std.testing.allocator, raw);
        defer decoded.deinit();
        const terminal = switch (decoded.projection) {
            .response_failed => |value| value,
            else => return error.TestUnexpectedProjection,
        };
        const info = terminal.error_info orelse return error.TestMissingErrorInfo;
        try std.testing.expectEqualStrings("rate_limit_error", info.error_type.?);
        try std.testing.expectEqualStrings("rate_limit_exceeded", info.code.?);
        try std.testing.expectEqualStrings("slow down", info.message.?);
        try std.testing.expectEqualStrings("model", info.param.?);
        try std.testing.expectEqualStrings("plus", info.plan_type.?);
        try std.testing.expectEqual(@as(?i64, 12345), info.resets_at);
        try std.testing.expectEqual(@as(?u16, 429), info.status_code);
        try std.testing.expectApproxEqAbs(@as(f64, 1.5), info.retry_after_seconds.?, 0.000001);
    }
    {
        const raw =
            \\{"type":"response.incomplete","response":{"id":"resp_incomplete","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":9,"output_tokens":3,"total_tokens":12}}}
        ;
        var decoded = try decodeEvent(std.testing.allocator, raw);
        defer decoded.deinit();
        const terminal = switch (decoded.projection) {
            .response_incomplete => |value| value,
            else => return error.TestUnexpectedProjection,
        };
        try std.testing.expectEqualStrings("max_output_tokens", terminal.incomplete_reason.?);
        try std.testing.expectEqual(@as(?u64, 12), terminal.usage.total_tokens);
    }
    {
        const raw =
            \\{"type":"response.incomplete","response":{"id":"resp_window","status":"incomplete","incomplete_details":{"reason":"provider_error","status_code":429,"retry_after_seconds":2.25,"resets_at":98765}}}
        ;
        var decoded = try decodeEvent(std.testing.allocator, raw);
        defer decoded.deinit();
        const terminal = switch (decoded.projection) {
            .response_incomplete => |value| value,
            else => return error.TestUnexpectedProjection,
        };
        const info = terminal.error_info orelse return error.TestMissingErrorInfo;
        try std.testing.expectEqual(@as(?u16, 429), info.status_code);
        try std.testing.expectApproxEqAbs(@as(f64, 2.25), info.retry_after_seconds.?, 0.000001);
        try std.testing.expectEqual(@as(?i64, 98765), info.resets_at);
    }
}

test "Responses text refusal and tool deltas are selected by JSON type" {
    {
        var decoded = try decodeEvent(
            std.testing.allocator,
            "{\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":1,\"delta\":\"hello\"}",
        );
        defer decoded.deinit();
        const delta = switch (decoded.projection) {
            .output_text_delta => |value| value,
            else => return error.TestUnexpectedProjection,
        };
        try std.testing.expectEqualStrings("msg_1", delta.item_id.?);
        try std.testing.expectEqualStrings("hello", delta.delta);
        try std.testing.expectEqual(@as(?u64, 1), delta.content_index);
    }
    {
        var decoded = try decodeEvent(
            std.testing.allocator,
            "{\"type\":\"response.refusal.done\",\"item_id\":\"msg_2\",\"output_index\":1,\"content_index\":0,\"refusal\":\"cannot comply\"}",
        );
        defer decoded.deinit();
        const done = switch (decoded.projection) {
            .refusal_done => |value| value,
            else => return error.TestUnexpectedProjection,
        };
        try std.testing.expectEqualStrings("cannot comply", done.text);
    }
    {
        var decoded = try decodeEvent(
            std.testing.allocator,
            "{\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_1\",\"call_id\":\"call_1\",\"output_index\":2,\"delta\":\"{\\\"path\\\":\"}",
        );
        defer decoded.deinit();
        const delta = switch (decoded.projection) {
            .function_call_arguments_delta => |value| value,
            else => return error.TestUnexpectedProjection,
        };
        try std.testing.expectEqualStrings("call_1", delta.call_id.?);
        try std.testing.expectEqualStrings("{\"path\":", delta.delta);
    }
    {
        var decoded = try decodeEvent(
            std.testing.allocator,
            "{\"type\":\"response.custom_tool_call_input.done\",\"item_id\":\"ct_1\",\"call_id\":\"call_2\",\"output_index\":3,\"input\":\"raw input\"}",
        );
        defer decoded.deinit();
        const done = switch (decoded.projection) {
            .custom_tool_call_input_done => |value| value,
            else => return error.TestUnexpectedProjection,
        };
        try std.testing.expectEqualStrings("raw input", done.value);
    }
}

test "Responses URL citation annotations retain title and text offsets" {
    var decoded = try decodeEvent(
        std.testing.allocator,
        "{\"type\":\"response.output_text.annotation.added\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"annotation_index\":1,\"annotation\":{\"type\":\"url_citation\",\"url\":\"https://example.com/source\",\"title\":\"Example source\",\"start_index\":12,\"end_index\":19}}",
    );
    defer decoded.deinit();
    const event = switch (decoded.projection) {
        .output_text_annotation_added => |value| value,
        else => return error.TestUnexpectedProjection,
    };
    try std.testing.expectEqualStrings("msg_1", event.item_id.?);
    try std.testing.expectEqual(@as(?u64, 1), event.annotation_index);
    try std.testing.expectEqualStrings("url_citation", event.annotation_type.?);
    const citation = event.url_citation orelse return error.TestMissingUrlCitation;
    try std.testing.expectEqualStrings("https://example.com/source", citation.url);
    try std.testing.expectEqualStrings("Example source", citation.title.?);
    try std.testing.expectEqual(@as(u64, 12), citation.start_index);
    try std.testing.expectEqual(@as(u64, 19), citation.end_index);
}

test "Responses reasoning events and output items retain replay identity" {
    {
        var decoded = try decodeEvent(
            std.testing.allocator,
            "{\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":1,\"delta\":\"because\"}",
        );
        defer decoded.deinit();
        const delta = switch (decoded.projection) {
            .reasoning_summary_text_delta => |value| value,
            else => return error.TestUnexpectedProjection,
        };
        try std.testing.expectEqualStrings("rs_1", delta.item_id.?);
        try std.testing.expectEqual(@as(?u64, 1), delta.summary_index);
        try std.testing.expectEqualStrings("because", delta.delta);
    }
    {
        var decoded = try decodeEvent(
            std.testing.allocator,
            "{\"type\":\"response.reasoning_text.done\",\"item_id\":\"rs_1\",\"output_index\":0,\"content_index\":2,\"text\":\"private reasoning\"}",
        );
        defer decoded.deinit();
        const done = switch (decoded.projection) {
            .reasoning_text_done => |value| value,
            else => return error.TestUnexpectedProjection,
        };
        try std.testing.expectEqual(@as(?u64, 2), done.content_index);
        try std.testing.expectEqualStrings("private reasoning", done.text);
    }
    {
        var decoded = try decodeEvent(
            std.testing.allocator,
            "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"reasoning\",\"id\":\"rs_opaque\",\"status\":\"completed\",\"encrypted_content\":\"ciphertext\",\"summary\":[]}}",
        );
        defer decoded.deinit();
        const event = switch (decoded.projection) {
            .output_item_done => |value| value,
            else => return error.TestUnexpectedProjection,
        };
        try std.testing.expectEqual(OutputItemKind.reasoning, event.item.kind);
        try std.testing.expectEqualStrings("rs_opaque", event.item.id.?);
        try std.testing.expectEqualStrings("ciphertext", event.item.encrypted_content.?);
    }
    {
        var decoded = try decodeEvent(
            std.testing.allocator,
            "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"fc_web\",\"call_id\":\"call_web\",\"namespace\":\"web\",\"name\":\"run\",\"arguments\":\"{\\\"search_query\\\":[{\\\"q\\\":\\\"zig\\\"}]}\"}}",
        );
        defer decoded.deinit();
        const event = switch (decoded.projection) {
            .output_item_done => |value| value,
            else => return error.TestUnexpectedProjection,
        };
        try std.testing.expectEqual(OutputItemKind.function_call, event.item.kind);
        try std.testing.expectEqualStrings("web", event.item.namespace.?);
        try std.testing.expectEqualStrings("run", event.item.name.?);
        try std.testing.expectEqualStrings("call_web", event.item.call_id.?);
    }
    {
        var decoded = try decodeEvent(
            std.testing.allocator,
            "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"compaction\",\"id\":\"cmp_1\",\"encrypted_content\":\"opaque\",\"future\":true}}",
        );
        defer decoded.deinit();
        const event = switch (decoded.projection) {
            .output_item_done => |value| value,
            else => return error.TestUnexpectedProjection,
        };
        try std.testing.expectEqual(OutputItemKind.other, event.item.kind);
        try std.testing.expect(compaction.isCompactionOutputItemType(event.item.raw_type));
        try std.testing.expectEqualStrings("cmp_1", event.item.id.?);
        try std.testing.expectEqualStrings("opaque", event.item.encrypted_content.?);
        try std.testing.expect(decoded.json().object.get("item").?.object.get("future") != null);
    }
    {
        var decoded = try decodeEvent(
            std.testing.allocator,
            "{\"type\":\"response.output_item.added\",\"output_index\":4,\"item\":{\"type\":\"future_tool_call\",\"id\":\"future_1\",\"payload\":{\"kept\":true}}}",
        );
        defer decoded.deinit();
        const event = switch (decoded.projection) {
            .output_item_added => |value| value,
            else => return error.TestUnexpectedProjection,
        };
        try std.testing.expectEqual(OutputItemKind.other, event.item.kind);
        try std.testing.expectEqualStrings("future_tool_call", event.item.raw_type);
        try std.testing.expect(std.mem.find(u8, decoded.raw_json, "\"kept\":true") != null);
    }
}

test "Responses part events retain typed content projections" {
    {
        var decoded = try decodeEvent(
            std.testing.allocator,
            "{\"type\":\"response.content_part.added\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":1,\"part\":{\"type\":\"output_text\",\"text\":\"hello\"}}",
        );
        defer decoded.deinit();
        const event = switch (decoded.projection) {
            .content_part_added => |value| value,
            else => return error.TestUnexpectedProjection,
        };
        try std.testing.expectEqualStrings("output_text", event.part_type.?);
        try std.testing.expectEqualStrings("hello", event.text.?);
    }
    {
        var decoded = try decodeEvent(
            std.testing.allocator,
            "{\"type\":\"response.content_part.done\",\"item_id\":\"msg_2\",\"output_index\":1,\"content_index\":0,\"part\":{\"type\":\"refusal\",\"refusal\":\"cannot comply\"}}",
        );
        defer decoded.deinit();
        const event = switch (decoded.projection) {
            .content_part_done => |value| value,
            else => return error.TestUnexpectedProjection,
        };
        try std.testing.expectEqualStrings("refusal", event.part_type.?);
        try std.testing.expectEqualStrings("cannot comply", event.text.?);
    }
    {
        var decoded = try decodeEvent(
            std.testing.allocator,
            "{\"type\":\"response.reasoning_summary_part.done\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0,\"part\":{\"type\":\"summary_text\",\"text\":\"summary\"}}",
        );
        defer decoded.deinit();
        const event = switch (decoded.projection) {
            .reasoning_summary_part_done => |value| value,
            else => return error.TestUnexpectedProjection,
        };
        try std.testing.expectEqualStrings("summary_text", event.part_type.?);
        try std.testing.expectEqualStrings("summary", event.text.?);
    }
}

test "Responses unknown events retain exact raw JSON" {
    const raw = "{\"type\":\"response.future.delta\",\"sequence_number\":7,\"future\":{\"value\":true}}";
    var decoded = try decodeEvent(std.testing.allocator, raw);
    defer decoded.deinit();
    const unknown = switch (decoded.projection) {
        .unknown => |value| value,
        else => return error.TestUnexpectedProjection,
    };
    try std.testing.expectEqualStrings("response.future.delta", unknown.event_type);
    try std.testing.expectEqualStrings(raw, decoded.raw_json);
    try std.testing.expectEqualStrings(
        "response.future.delta",
        decoded.json().object.get("type").?.string,
    );
}

test "Responses event rejects malformed or typeless JSON" {
    try std.testing.expectError(
        error.InvalidResponsesEvent,
        decodeEvent(std.testing.allocator, "not json"),
    );
    try std.testing.expectError(
        error.InvalidResponsesEvent,
        decodeEvent(std.testing.allocator, "{\"sequence_number\":1}"),
    );
}

test "Responses error decoder handles object string and plain bodies" {
    {
        var decoded = try decodeErrorResponse(
            std.testing.allocator,
            400,
            "{\"error\":{\"type\":\"invalid_request_error\",\"code\":\"bad_model\",\"message\":\"invalid model\",\"param\":\"model\",\"retry_after_seconds\":2.5}}",
        );
        defer decoded.deinit();
        try std.testing.expectEqualStrings("invalid_request_error", decoded.info.error_type.?);
        try std.testing.expectEqualStrings("bad_model", decoded.info.code.?);
        try std.testing.expectEqualStrings("invalid model", decoded.info.message.?);
        try std.testing.expectEqualStrings("model", decoded.info.param.?);
        try std.testing.expectEqual(@as(?u16, 400), decoded.info.status_code);
        try std.testing.expectApproxEqAbs(@as(f64, 2.5), decoded.info.retry_after_seconds.?, 0.000001);
    }
    {
        var decoded = try decodeErrorResponse(
            std.testing.allocator,
            401,
            "{\"error\":\"token expired\"}",
        );
        defer decoded.deinit();
        try std.testing.expectEqualStrings("token expired", decoded.info.message.?);
        try std.testing.expectEqual(@as(?u16, 401), decoded.info.status_code);
    }
    {
        const body = "upstream gateway unavailable";
        var decoded = try decodeErrorResponse(std.testing.allocator, 503, body);
        defer decoded.deinit();
        try std.testing.expect(decoded.parsed == null);
        try std.testing.expectEqualStrings(body, decoded.info.message.?);
        try std.testing.expectEqualStrings(body, decoded.raw_body);
        try std.testing.expectEqual(@as(?u16, 503), decoded.info.status_code);
    }
}
