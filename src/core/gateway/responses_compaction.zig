const std = @import("std");
const responses_output_items = @import("../shared/responses_output_items.zig");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

pub const dedicated_path = "responses/compact";
pub const v2_trigger_type = "compaction_trigger";
pub const v2_beta_feature = "remote_compaction_v2";
pub const output_item_type = "compaction";

pub fn isCompactionOutputItemType(raw_type: []const u8) bool {
    return std.mem.eql(u8, raw_type, output_item_type);
}

/// Validates the input boundary required by remote compaction V2. The trigger
/// is a request control, must be appended last, and may occur at most once.
pub fn validateV2Input(input: std.json.Value) !void {
    if (input != .array) return error.InvalidResponsesCompactionTriggerInput;
    for (input.array.items) |item| {
        if (item != .object) continue;
        const item_type = item.object.get("type") orelse continue;
        if (item_type == .string and std.mem.eql(u8, item_type.string, v2_trigger_type)) {
            return error.DuplicateResponsesCompactionTrigger;
        }
    }
}

pub fn writeV2Trigger(writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"type\":\"" ++ v2_trigger_type ++ "\"}");
}

/// Standalone helper for callers that already own raw Responses input. The
/// result is an owned array with exactly one trigger appended as the last item.
pub fn appendV2TriggerInputAlloc(alloc: Allocator, input_json: []const u8) ![]u8 {
    var parsed = parseRaw(
        alloc,
        input_json,
        error.InvalidResponsesCompactionTriggerInput,
    ) catch |err| return err;
    defer parsed.deinit();
    try validateV2Input(parsed.value);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    for (parsed.value.array.items, 0..) |item, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(item, .{}, &out.writer);
    }
    if (parsed.value.array.items.len > 0) try out.writer.writeByte(',');
    try writeV2Trigger(&out.writer);
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

/// Request fields shared by OpenAI's dedicated `/responses/compact` endpoint
/// and Codex's legacy remote-compaction transport. Complex and evolving
/// Responses values remain raw JSON, while scalar controls stay typed.
pub const Request = struct {
    model: ?[]const u8 = null,
    input_json: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    tools_json: ?[]const u8 = null,
    parallel_tool_calls: ?bool = null,
    reasoning_json: ?[]const u8 = null,
    service_tier: ?[]const u8 = null,
    prompt_cache_key: ?[]const u8 = null,
    prompt_cache_options_json: ?[]const u8 = null,
    previous_response_id: ?[]const u8 = null,
    text_json: ?[]const u8 = null,
    /// Provider additions and future compact fields. Fields owned above cannot
    /// be repeated here, even when their typed value is absent.
    extra_fields_json: ?[]const u8 = null,
};

/// Builds an owned compact request body. `input` and `tools` must be arrays;
/// reasoning, text, prompt-cache options, and extra fields must be objects.
/// Raw values are parsed before writing, so invalid JSON and collisions with
/// codec-owned top-level fields never reach transport.
pub fn buildRequest(alloc: Allocator, request: Request) ![]u8 {
    var parsed = try ParsedRequest.init(alloc, request);
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeByte('{');
    var wrote = false;

    if (request.model) |model| {
        try writeField(&out.writer, &wrote, "model", .{ .string = model });
    }
    if (parsed.input) |input| {
        try writeField(&out.writer, &wrote, "input", input.value);
    }
    if (request.instructions) |instructions| {
        if (instructions.len > 0) {
            try writeField(&out.writer, &wrote, "instructions", .{ .string = instructions });
        }
    }
    if (parsed.tools) |tools| {
        try writeField(&out.writer, &wrote, "tools", tools.value);
    }
    if (request.parallel_tool_calls) |parallel| {
        try writeField(&out.writer, &wrote, "parallel_tool_calls", .{ .bool = parallel });
    }
    if (parsed.reasoning) |reasoning| {
        try writeField(&out.writer, &wrote, "reasoning", reasoning.value);
    }
    if (request.service_tier) |service_tier| {
        try writeField(&out.writer, &wrote, "service_tier", .{ .string = service_tier });
    }
    if (request.prompt_cache_key) |prompt_cache_key| {
        try writeField(&out.writer, &wrote, "prompt_cache_key", .{ .string = prompt_cache_key });
    }
    if (parsed.prompt_cache_options) |options| {
        try writeField(&out.writer, &wrote, "prompt_cache_options", options.value);
    }
    if (request.previous_response_id) |previous_response_id| {
        try writeField(&out.writer, &wrote, "previous_response_id", .{ .string = previous_response_id });
    }
    if (parsed.text) |text| {
        try writeField(&out.writer, &wrote, "text", text.value);
    }
    if (parsed.extra) |extra| {
        var iterator = extra.value.object.iterator();
        while (iterator.next()) |entry| {
            try writeField(&out.writer, &wrote, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

const ParsedRequest = struct {
    input: ?std.json.Parsed(JsonValue) = null,
    tools: ?std.json.Parsed(JsonValue) = null,
    reasoning: ?std.json.Parsed(JsonValue) = null,
    prompt_cache_options: ?std.json.Parsed(JsonValue) = null,
    text: ?std.json.Parsed(JsonValue) = null,
    extra: ?std.json.Parsed(JsonValue) = null,

    fn init(alloc: Allocator, request: Request) !ParsedRequest {
        var parsed: ParsedRequest = .{};
        errdefer parsed.deinit();

        if (request.input_json) |raw| {
            parsed.input = try parseRaw(alloc, raw, error.InvalidResponsesCompactInput);
            if (parsed.input.?.value != .array) return error.InvalidResponsesCompactInput;
        }
        if (request.tools_json) |raw| {
            parsed.tools = try parseRaw(alloc, raw, error.InvalidResponsesCompactTools);
            if (parsed.tools.?.value != .array) return error.InvalidResponsesCompactTools;
        }
        if (request.reasoning_json) |raw| {
            parsed.reasoning = try parseRaw(alloc, raw, error.InvalidResponsesCompactReasoning);
            if (parsed.reasoning.?.value != .object) return error.InvalidResponsesCompactReasoning;
        }
        if (request.prompt_cache_options_json) |raw| {
            parsed.prompt_cache_options = try parseRaw(
                alloc,
                raw,
                error.InvalidResponsesCompactPromptCacheOptions,
            );
            if (parsed.prompt_cache_options.?.value != .object) {
                return error.InvalidResponsesCompactPromptCacheOptions;
            }
        }
        if (request.text_json) |raw| {
            parsed.text = try parseRaw(alloc, raw, error.InvalidResponsesCompactText);
            if (parsed.text.?.value != .object) return error.InvalidResponsesCompactText;
        }
        if (request.extra_fields_json) |raw| {
            parsed.extra = try parseRaw(alloc, raw, error.InvalidResponsesCompactExtraFields);
            if (parsed.extra.?.value != .object) return error.InvalidResponsesCompactExtraFields;
            var iterator = parsed.extra.?.value.object.iterator();
            while (iterator.next()) |entry| {
                if (isOwnedRequestField(entry.key_ptr.*)) {
                    return error.DuplicateResponsesCompactRequestField;
                }
            }
        }
        return parsed;
    }

    fn deinit(self: *ParsedRequest) void {
        if (self.input) |*parsed| parsed.deinit();
        if (self.tools) |*parsed| parsed.deinit();
        if (self.reasoning) |*parsed| parsed.deinit();
        if (self.prompt_cache_options) |*parsed| parsed.deinit();
        if (self.text) |*parsed| parsed.deinit();
        if (self.extra) |*parsed| parsed.deinit();
        self.* = .{};
    }
};

fn parseRaw(
    alloc: Allocator,
    raw: []const u8,
    parse_error: anyerror,
) !std.json.Parsed(JsonValue) {
    return std.json.parseFromSlice(JsonValue, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return parse_error,
    };
}

fn writeField(
    writer: *std.Io.Writer,
    wrote: *bool,
    name: []const u8,
    value: JsonValue,
) !void {
    if (wrote.*) try writer.writeByte(',');
    wrote.* = true;
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeByte(':');
    try std.json.Stringify.value(value, .{}, writer);
}

fn isOwnedRequestField(name: []const u8) bool {
    const owned = [_][]const u8{
        "model",
        "input",
        "instructions",
        "tools",
        "parallel_tool_calls",
        "reasoning",
        "service_tier",
        "prompt_cache_key",
        "prompt_cache_options",
        "previous_response_id",
        "text",
    };
    for (owned) |field| {
        if (std.mem.eql(u8, name, field)) return true;
    }
    return false;
}

/// Token usage reported by either a normal Responses terminal event or the
/// dedicated compact response. Missing and future fields remain harmless.
pub const Usage = struct {
    input_tokens: ?u64 = null,
    cached_input_tokens: ?u64 = null,
    cache_write_input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    reasoning_output_tokens: ?u64 = null,
    total_tokens: ?u64 = null,
    codex_rollout_budget_units: ?f64 = null,
};

pub fn projectUsage(value: ?JsonValue) Usage {
    const usage = value orelse return .{};
    const input_details = objectField(usage, "input_tokens_details");
    const output_details = objectField(usage, "output_tokens_details");
    return .{
        .input_tokens = unsignedField(usage, "input_tokens"),
        .cached_input_tokens = if (input_details) |details| unsignedField(details, "cached_tokens") else null,
        .cache_write_input_tokens = if (input_details) |details| unsignedField(details, "cache_write_tokens") else null,
        .output_tokens = unsignedField(usage, "output_tokens"),
        .reasoning_output_tokens = if (output_details) |details| unsignedField(details, "reasoning_tokens") else null,
        .total_tokens = unsignedField(usage, "total_tokens"),
        .codex_rollout_budget_units = numberField(usage, "codex_rollout_budget_units"),
    };
}

pub const CompactionItem = struct {
    id: ?[]const u8 = null,
    encrypted_content: []const u8,
    agent: ?CompactionAgent = null,
    created_by: ?[]const u8 = null,
    /// Exact parsed item, including unknown fields. It borrows the decoded
    /// response and remains valid until that response is deinitialized.
    value: JsonValue,
};

pub const CompactionAgent = struct {
    agent_name: []const u8,
    value: JsonValue,
};

/// Owns the exact compact response body and every decoded slice. Official
/// envelope fields are projected without dropping unknown top-level or output
/// item fields. Legacy Codex `{ "output": [...] }` envelopes remain accepted.
pub const DecodedResponse = struct {
    allocator: Allocator,
    raw_json: []u8,
    parsed: std.json.Parsed(JsonValue),
    id: ?[]const u8,
    object_type: ?[]const u8,
    created_at: ?u64,
    output: []const JsonValue,
    usage: Usage,
    usage_present: bool,

    pub fn deinit(self: *DecodedResponse) void {
        self.parsed.deinit();
        self.allocator.free(self.raw_json);
        self.* = undefined;
    }

    pub fn json(self: *const DecodedResponse) *const JsonValue {
        return &self.parsed.value;
    }

    /// Enforces the semantic compact result used by both dedicated and V2
    /// transports: exactly one valid compaction item. Other output item types
    /// are retained for replay and forward compatibility.
    pub fn singleCompactionItem(self: *const DecodedResponse) !CompactionItem {
        return findSingleCompactionItem(self.output);
    }

    /// Returns an owned, replay-ready copy of the complete compact endpoint
    /// `output` array. Retained user messages are deliberately preserved next
    /// to the opaque compaction item.
    pub fn replayInputJsonAlloc(self: *const DecodedResponse, alloc: Allocator) ![]u8 {
        try validateReplayItems(self.output);
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try std.json.Stringify.value(self.output, .{}, &out.writer);
        return out.toOwnedSlice();
    }
};

pub fn decodeResponse(alloc: Allocator, body: []const u8) !DecodedResponse {
    const raw = try alloc.dupe(u8, body);
    errdefer alloc.free(raw);
    var parsed = std.json.parseFromSlice(JsonValue, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponsesCompactResponse,
    };
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponsesCompactResponse;
    const root = parsed.value;

    const id = try optionalStringField(root, "id");
    const object_type = try optionalStringField(root, "object");
    if (object_type) |value| {
        if (!std.mem.eql(u8, value, "response.compaction") and
            !std.mem.eql(u8, value, "response"))
        {
            return error.UnexpectedResponsesCompactObject;
        }
    }
    const created_at = try optionalUnsignedField(root, "created_at");
    const output_value = valueField(root, "output") orelse
        return error.InvalidResponsesCompactResponse;
    if (output_value != .array) return error.InvalidResponsesCompactResponse;
    for (output_value.array.items) |item| {
        if (item != .object) return error.InvalidResponsesCompactResponse;
        const item_type = valueField(item, "type") orelse
            return error.InvalidResponsesCompactResponse;
        if (item_type != .string) return error.InvalidResponsesCompactResponse;
    }

    const usage_value = valueField(root, "usage");
    if (usage_value) |usage| {
        if (usage != .object) return error.InvalidResponsesCompactResponse;
    }
    return .{
        .allocator = alloc,
        .raw_json = raw,
        .parsed = parsed,
        .id = id,
        .object_type = object_type,
        .created_at = created_at,
        .output = output_value.array.items,
        .usage = projectUsage(usage_value),
        .usage_present = usage_value != null,
    };
}

/// Validates a raw output array shared by the dedicated response decoder and
/// a streaming V2 collector.
pub fn findSingleCompactionItem(output: []const JsonValue) !CompactionItem {
    var found: ?JsonValue = null;
    for (output) |item| {
        if (item != .object) return error.InvalidResponsesCompactItem;
        const item_type = try requiredStringField(item, "type");
        if (!isCompactionOutputItemType(item_type)) continue;
        if (found != null) return error.MultipleResponsesCompactionItems;
        found = item;
    }
    const item = found orelse return error.MissingResponsesCompactionItem;
    return projectCompactionItem(item);
}

/// Validates one persisted replay payload without interpreting its encrypted
/// content. Dedicated compact output always ends in exactly one compaction
/// item; every earlier item is retained as an opaque Responses input item.
pub fn validateReplayInputJson(alloc: Allocator, raw: []const u8) !void {
    var parsed = parseRaw(alloc, raw, error.InvalidResponsesCompactInput) catch |err| return err;
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidResponsesCompactInput;
    try validateReplayItems(parsed.value.array.items);
}

/// Serializes the finalized items collected from a V2 Responses stream into
/// the durable replay contract shared with the dedicated compact endpoint.
/// Output indices must be complete and wire ordered, and the final item must
/// be the stream's single opaque compaction checkpoint.
pub fn replayInputJsonFromOutputItemsAlloc(
    alloc: Allocator,
    items: []const responses_output_items.Item,
) ![]u8 {
    try responses_output_items.validateComplete(alloc, items);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    for (items, 0..) |item, index| {
        if (index > 0) try out.writer.writeByte(',');
        try responses_output_items.writeValidated(alloc, &out.writer, item);
    }
    try out.writer.writeByte(']');
    try validateReplayInputJson(alloc, out.written());
    return out.toOwnedSlice();
}

fn validateReplayItems(output: []const JsonValue) !void {
    if (output.len == 0) return error.MissingResponsesCompactionItem;
    _ = try findSingleCompactionItem(output);
    const final_type = try requiredStringField(output[output.len - 1], "type");
    if (!isCompactionOutputItemType(final_type)) {
        return error.InvalidResponsesCompactItem;
    }
    for (output) |item| {
        const item_type = try requiredStringField(item, "type");
        if (std.mem.eql(u8, item_type, v2_trigger_type)) {
            return error.InvalidResponsesCompactItem;
        }
    }
}

/// Projects one V2 `response.output_item.done` item or one dedicated output
/// item into the same replay-safe compaction contract.
pub fn projectCompactionItem(item: std.json.Value) !CompactionItem {
    if (item != .object) return error.InvalidResponsesCompactItem;
    const item_type = try requiredStringField(item, "type");
    if (!isCompactionOutputItemType(item_type)) return error.InvalidResponsesCompactItem;
    const encrypted_content = try requiredStringField(item, "encrypted_content");
    if (encrypted_content.len == 0) return error.InvalidResponsesCompactItem;
    return .{
        .id = try optionalItemStringField(item, "id"),
        .encrypted_content = encrypted_content,
        .agent = try optionalCompactionAgent(item),
        .created_by = try optionalItemStringField(item, "created_by"),
        .value = item,
    };
}

fn valueField(value: JsonValue, name: []const u8) ?JsonValue {
    if (value != .object) return null;
    return value.object.get(name);
}

fn objectField(value: JsonValue, name: []const u8) ?JsonValue {
    const field = valueField(value, name) orelse return null;
    return if (field == .object) field else null;
}

fn requiredStringField(value: JsonValue, name: []const u8) ![]const u8 {
    const field = valueField(value, name) orelse return error.InvalidResponsesCompactItem;
    if (field != .string) return error.InvalidResponsesCompactItem;
    return field.string;
}

fn optionalStringField(value: JsonValue, name: []const u8) !?[]const u8 {
    const field = valueField(value, name) orelse return null;
    if (field == .null) return null;
    if (field != .string) return error.InvalidResponsesCompactResponse;
    return field.string;
}

fn optionalItemStringField(value: JsonValue, name: []const u8) !?[]const u8 {
    const field = valueField(value, name) orelse return null;
    if (field == .null) return null;
    if (field != .string) return error.InvalidResponsesCompactItem;
    return field.string;
}

fn optionalCompactionAgent(item: JsonValue) !?CompactionAgent {
    const field = valueField(item, "agent") orelse return null;
    if (field == .null) return null;
    if (field != .object) return error.InvalidResponsesCompactItem;
    const agent_name = try requiredStringField(field, "agent_name");
    return .{ .agent_name = agent_name, .value = field };
}

fn optionalUnsignedField(value: JsonValue, name: []const u8) !?u64 {
    const field = valueField(value, name) orelse return null;
    if (field == .null) return null;
    if (field != .integer) return error.InvalidResponsesCompactResponse;
    return std.math.cast(u64, field.integer) orelse error.InvalidResponsesCompactResponse;
}

fn signedField(value: JsonValue, name: []const u8) ?i64 {
    const field = valueField(value, name) orelse return null;
    return if (field == .integer) field.integer else null;
}

fn unsignedField(value: JsonValue, name: []const u8) ?u64 {
    const signed = signedField(value, name) orelse return null;
    return std.math.cast(u64, signed);
}

fn numberField(value: JsonValue, name: []const u8) ?f64 {
    const field = valueField(value, name) orelse return null;
    return switch (field) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => null,
    };
}

fn testField(value: JsonValue, name: []const u8) !JsonValue {
    return valueField(value, name) orelse error.TestMissingJsonField;
}

fn expectJsonString(expected: []const u8, value: JsonValue) !void {
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings(expected, value.string);
}

test "Responses compact V2 helper appends one final typed trigger" {
    const alloc = std.testing.allocator;
    const input = try appendV2TriggerInputAlloc(
        alloc,
        "[{\"type\":\"message\",\"role\":\"user\",\"content\":\"hello\"}]",
    );
    defer alloc.free(input);
    var parsed = try std.json.parseFromSlice(JsonValue, alloc, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try expectJsonString(
        v2_trigger_type,
        try testField(parsed.value.array.items[1], "type"),
    );

    try std.testing.expectError(
        error.InvalidResponsesCompactionTriggerInput,
        appendV2TriggerInputAlloc(alloc, "\"prompt\""),
    );
    try std.testing.expectError(
        error.DuplicateResponsesCompactionTrigger,
        appendV2TriggerInputAlloc(alloc, "[{\"type\":\"compaction_trigger\"}]"),
    );
}

test "Responses compact V2 stream items become validated replay input" {
    const items = [_]responses_output_items.Item{
        .{
            .output_index = 0,
            .json = "{\"id\":\"cmp_1\",\"type\":\"compaction\",\"encrypted_content\":\"opaque\",\"future\":true}",
        },
    };
    const replay = try replayInputJsonFromOutputItemsAlloc(std.testing.allocator, &items);
    defer std.testing.allocator.free(replay);
    try std.testing.expectEqualStrings(
        "[{\"id\":\"cmp_1\",\"type\":\"compaction\",\"encrypted_content\":\"opaque\",\"future\":true}]",
        replay,
    );

    const wrong_index = [_]responses_output_items.Item{.{
        .output_index = 1,
        .json = items[0].json,
    }};
    try std.testing.expectError(
        error.InvalidResponsesOutputOrder,
        replayInputJsonFromOutputItemsAlloc(std.testing.allocator, &wrong_index),
    );

    const missing = [_]responses_output_items.Item{.{
        .output_index = 0,
        .json = "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}",
    }};
    try std.testing.expectError(
        error.MissingResponsesCompactionItem,
        replayInputJsonFromOutputItemsAlloc(std.testing.allocator, &missing),
    );
}

test "Responses compact request preserves canonical and future fields without duplicate keys" {
    const alloc = std.testing.allocator;
    const body = try buildRequest(alloc, .{
        .model = "gpt-5.6-sol",
        .input_json =
        \\[{"type":"message","role":"user","content":[{"type":"input_audio","input_audio":{"data":"UklGRg==","format":"wav"}},{"type":"input_file","file_id":"file_123"}]},{"type":"function_call_output","call_id":"call_1","output":[{"type":"input_text","text":"tool output"}]},{"type":"compaction","id":"cmp_old","encrypted_content":"opaque-old"}]
        ,
        .instructions = "keep behavior stable",
        .tools_json = "[{\"type\":\"function\",\"name\":\"lookup\",\"parameters\":{\"type\":\"object\"}}]",
        .parallel_tool_calls = true,
        .reasoning_json = "{\"effort\":\"high\",\"future_reasoning_control\":true}",
        .service_tier = "priority",
        .prompt_cache_key = "session-1",
        .prompt_cache_options_json = "{\"mode\":\"explicit\",\"ttl\":\"30m\"}",
        .previous_response_id = "resp_previous",
        .text_json = "{\"verbosity\":\"low\"}",
        .extra_fields_json = "{\"prompt_cache_retention\":\"24h\",\"future_compact_control\":{\"enabled\":true}}",
    });
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(JsonValue, alloc, body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    try expectJsonString("gpt-5.6-sol", try testField(root, "model"));
    const input = (try testField(root, "input")).array.items;
    try std.testing.expectEqual(@as(usize, 3), input.len);
    const content = (try testField(input[0], "content")).array.items;
    try expectJsonString("input_audio", try testField(content[0], "type"));
    try expectJsonString("input_file", try testField(content[1], "type"));
    try std.testing.expect((try testField(input[1], "output")) == .array);
    try expectJsonString("keep behavior stable", try testField(root, "instructions"));
    try std.testing.expect((try testField(root, "tools")) == .array);
    try std.testing.expect((try testField(root, "parallel_tool_calls")).bool);
    try expectJsonString("high", try testField(try testField(root, "reasoning"), "effort"));
    try expectJsonString("priority", try testField(root, "service_tier"));
    try expectJsonString("session-1", try testField(root, "prompt_cache_key"));
    try expectJsonString("explicit", try testField(try testField(root, "prompt_cache_options"), "mode"));
    try expectJsonString("resp_previous", try testField(root, "previous_response_id"));
    try expectJsonString("low", try testField(try testField(root, "text"), "verbosity"));
    try expectJsonString("24h", try testField(root, "prompt_cache_retention"));
    try std.testing.expect((try testField(root, "future_compact_control")) == .object);
    try std.testing.expectEqual(@as(usize, 13), root.object.count());
}

test "Responses compact request accepts the minimal legacy Codex shape" {
    const body = try buildRequest(std.testing.allocator, .{
        .model = "gpt-5.6-sol",
        .input_json = "[]",
        .instructions = "",
        .parallel_tool_calls = true,
    });
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"model\":\"gpt-5.6-sol\",\"input\":[],\"parallel_tool_calls\":true}",
        body,
    );
}

test "Responses compact request rejects malformed types and owned-field collisions" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidResponsesCompactInput,
        buildRequest(alloc, .{ .input_json = "\"prompt\"" }),
    );
    try std.testing.expectError(
        error.InvalidResponsesCompactTools,
        buildRequest(alloc, .{ .tools_json = "{}" }),
    );
    try std.testing.expectError(
        error.InvalidResponsesCompactReasoning,
        buildRequest(alloc, .{ .reasoning_json = "[]" }),
    );
    try std.testing.expectError(
        error.InvalidResponsesCompactPromptCacheOptions,
        buildRequest(alloc, .{ .prompt_cache_options_json = "null" }),
    );
    try std.testing.expectError(
        error.InvalidResponsesCompactText,
        buildRequest(alloc, .{ .text_json = "\"low\"" }),
    );
    try std.testing.expectError(
        error.InvalidResponsesCompactExtraFields,
        buildRequest(alloc, .{ .extra_fields_json = "[]" }),
    );
    for ([_][]const u8{
        "{\"model\":\"override\"}",
        "{\"input\":[]}",
        "{\"previous_response_id\":\"override\"}",
        "{\"prompt_cache_options\":{}}",
    }) |extra| {
        try std.testing.expectError(
            error.DuplicateResponsesCompactRequestField,
            buildRequest(alloc, .{ .extra_fields_json = extra }),
        );
    }
}

test "Responses compact decoder preserves official envelope usage and unknown fields" {
    const raw =
        \\{"id":"resp_001","object":"response.compaction","created_at":1764967971,"output":[{"id":"msg_000","type":"message","status":"completed","role":"user","content":[{"type":"input_text","text":"hello","future_part":true}]},{"id":"cmp_001","type":"compaction","encrypted_content":"opaque","agent":{"agent_name":"agent_1","future":true},"created_by":"actor_1","future_item":{"kept":true}}],"usage":{"input_tokens":139,"input_tokens_details":{"cached_tokens":11,"cache_write_tokens":7},"output_tokens":438,"output_tokens_details":{"reasoning_tokens":64},"total_tokens":577,"codex_rollout_budget_units":2.5},"future_envelope":{"kept":true}}
    ;
    var decoded = try decodeResponse(std.testing.allocator, raw);
    defer decoded.deinit();

    try std.testing.expectEqualStrings(raw, decoded.raw_json);
    try std.testing.expectEqualStrings("resp_001", decoded.id.?);
    try std.testing.expectEqualStrings("response.compaction", decoded.object_type.?);
    try std.testing.expectEqual(@as(?u64, 1764967971), decoded.created_at);
    try std.testing.expectEqual(@as(usize, 2), decoded.output.len);
    try std.testing.expect(decoded.usage_present);
    try std.testing.expectEqual(@as(?u64, 139), decoded.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 11), decoded.usage.cached_input_tokens);
    try std.testing.expectEqual(@as(?u64, 7), decoded.usage.cache_write_input_tokens);
    try std.testing.expectEqual(@as(?u64, 438), decoded.usage.output_tokens);
    try std.testing.expectEqual(@as(?u64, 64), decoded.usage.reasoning_output_tokens);
    try std.testing.expectEqual(@as(?u64, 577), decoded.usage.total_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), decoded.usage.codex_rollout_budget_units.?, 0.000001);
    try std.testing.expect(decoded.json().object.get("future_envelope") != null);

    const item = try decoded.singleCompactionItem();
    try std.testing.expectEqualStrings("cmp_001", item.id.?);
    try std.testing.expectEqualStrings("opaque", item.encrypted_content);
    try std.testing.expectEqualStrings("agent_1", item.agent.?.agent_name);
    try std.testing.expect(item.agent.?.value.object.get("future") != null);
    try std.testing.expectEqualStrings("actor_1", item.created_by.?);
    try std.testing.expect(item.value.object.get("future_item") != null);
}

test "Responses compact decoder accepts output-only legacy envelopes" {
    var decoded = try decodeResponse(
        std.testing.allocator,
        "{\"output\":[{\"type\":\"compaction\",\"encrypted_content\":\"legacy\",\"future\":1}]}",
    );
    defer decoded.deinit();
    try std.testing.expect(decoded.id == null);
    try std.testing.expect(decoded.object_type == null);
    try std.testing.expect(decoded.created_at == null);
    try std.testing.expect(!decoded.usage_present);
    const item = try decoded.singleCompactionItem();
    try std.testing.expectEqualStrings("legacy", item.encrypted_content);
    try std.testing.expect(item.value.object.get("future") != null);
}

test "Responses compact replay preserves the full output array exactly once" {
    const alloc = std.testing.allocator;
    var decoded = try decodeResponse(
        alloc,
        "{\"output\":[{\"type\":\"message\",\"role\":\"user\",\"content\":[],\"future\":1},{\"type\":\"compaction\",\"encrypted_content\":\"opaque\",\"future_item\":true}]}",
    );
    defer decoded.deinit();
    const replay = try decoded.replayInputJsonAlloc(alloc);
    defer alloc.free(replay);
    try validateReplayInputJson(alloc, replay);

    var parsed = try std.json.parseFromSlice(JsonValue, alloc, replay, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try std.testing.expect(parsed.value.array.items[0].object.get("future") != null);
    try std.testing.expect(parsed.value.array.items[1].object.get("future_item") != null);

    try std.testing.expectError(
        error.InvalidResponsesCompactItem,
        validateReplayInputJson(
            alloc,
            "[{\"type\":\"compaction\",\"encrypted_content\":\"opaque\"},{\"type\":\"message\"}]",
        ),
    );
    try std.testing.expectError(
        error.InvalidResponsesCompactItem,
        validateReplayInputJson(
            alloc,
            "[{\"type\":\"compaction_trigger\"},{\"type\":\"compaction\",\"encrypted_content\":\"opaque\"}]",
        ),
    );
}

test "Responses compact decoder separates envelope and semantic errors" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        "not-json",
        "[]",
        "{}",
        "{\"output\":{}}",
        "{\"output\":[null]}",
        "{\"output\":[{}]}",
        "{\"object\":123,\"output\":[]}",
        "{\"created_at\":-1,\"output\":[]}",
        "{\"usage\":[],\"output\":[]}",
    }) |invalid| {
        try std.testing.expectError(error.InvalidResponsesCompactResponse, decodeResponse(alloc, invalid));
    }
    try std.testing.expectError(
        error.UnexpectedResponsesCompactObject,
        decodeResponse(alloc, "{\"object\":\"unexpected\",\"output\":[]}"),
    );

    {
        var decoded = try decodeResponse(alloc, "{\"output\":[{\"type\":\"message\"}]}");
        defer decoded.deinit();
        try std.testing.expectError(error.MissingResponsesCompactionItem, decoded.singleCompactionItem());
    }
    {
        var decoded = try decodeResponse(
            alloc,
            "{\"output\":[{\"type\":\"compaction\",\"encrypted_content\":\"one\"},{\"type\":\"compaction\",\"encrypted_content\":\"two\"}]}",
        );
        defer decoded.deinit();
        try std.testing.expectError(error.MultipleResponsesCompactionItems, decoded.singleCompactionItem());
    }
    {
        var decoded = try decodeResponse(alloc, "{\"output\":[{\"type\":\"compaction\",\"encrypted_content\":\"\"}]}");
        defer decoded.deinit();
        try std.testing.expectError(error.InvalidResponsesCompactItem, decoded.singleCompactionItem());
    }
    {
        var decoded = try decodeResponse(alloc, "{\"output\":[{\"type\":\"compaction\",\"id\":7,\"encrypted_content\":\"opaque\"}]}");
        defer decoded.deinit();
        try std.testing.expectError(error.InvalidResponsesCompactItem, decoded.singleCompactionItem());
    }
}

fn checkCompactRequestAllocationFailures(alloc: Allocator) !void {
    const triggered_input = appendV2TriggerInputAlloc(
        alloc,
        "[{\"type\":\"message\",\"role\":\"user\",\"content\":\"hello\"}]",
    ) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer alloc.free(triggered_input);

    const body = buildRequest(alloc, .{
        .model = "gpt-5.6-sol",
        .input_json = "[{\"type\":\"message\",\"role\":\"user\",\"content\":\"hello\"}]",
        .tools_json = "[]",
        .reasoning_json = "{\"effort\":\"high\"}",
        .prompt_cache_options_json = "{\"mode\":\"explicit\"}",
        .text_json = "{\"verbosity\":\"low\"}",
        .extra_fields_json = "{\"future\":true}",
    }) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer alloc.free(body);
}

fn checkCompactResponseAllocationFailures(alloc: Allocator) !void {
    var decoded = try decodeResponse(
        alloc,
        "{\"id\":\"resp_1\",\"object\":\"response.compaction\",\"created_at\":1,\"output\":[{\"type\":\"compaction\",\"encrypted_content\":\"opaque\"}],\"usage\":{\"total_tokens\":1}}",
    );
    defer decoded.deinit();
    _ = try decoded.singleCompactionItem();
}

test "Responses compact codecs clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCompactRequestAllocationFailures,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCompactResponseAllocationFailures,
        .{},
    );
}
