const std = @import("std");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

pub const path = "alpha/search";

pub const Request = struct {
    id: []const u8,
    model: []const u8,
    input_json: ?[]const u8 = null,
    commands_json: []const u8,
    settings_json: ?[]const u8 = null,
    reasoning_json: ?[]const u8 = null,
    max_output_tokens: ?u64 = null,
    extra_fields_json: ?[]const u8 = null,
};

/// Builds an owned standalone search request. Raw Responses input may be a
/// string or item array; commands/settings/reasoning and extra fields must be
/// objects. Owned fields cannot be shadowed through the future-field object.
pub fn buildRequest(alloc: Allocator, request: Request) ![]u8 {
    var parsed = try ParsedRequest.init(alloc, request);
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"id\":");
    try std.json.Stringify.value(request.id, .{}, &out.writer);
    try out.writer.writeAll(",\"model\":");
    try std.json.Stringify.value(request.model, .{}, &out.writer);
    if (parsed.input) |input| {
        try out.writer.writeAll(",\"input\":");
        try std.json.Stringify.value(input.value, .{}, &out.writer);
    }
    try out.writer.writeAll(",\"commands\":");
    try std.json.Stringify.value(parsed.commands.value, .{}, &out.writer);
    if (parsed.settings) |settings| {
        try out.writer.writeAll(",\"settings\":");
        try std.json.Stringify.value(settings.value, .{}, &out.writer);
    }
    if (parsed.reasoning) |reasoning| {
        try out.writer.writeAll(",\"reasoning\":");
        try std.json.Stringify.value(reasoning.value, .{}, &out.writer);
    }
    if (request.max_output_tokens) |max_output_tokens| {
        try out.writer.print(",\"max_output_tokens\":{d}", .{max_output_tokens});
    }
    if (parsed.extra) |extra| {
        var iterator = extra.value.object.iterator();
        while (iterator.next()) |entry| {
            try out.writer.writeByte(',');
            try std.json.Stringify.value(entry.key_ptr.*, .{}, &out.writer);
            try out.writer.writeByte(':');
            try std.json.Stringify.value(entry.value_ptr.*, .{}, &out.writer);
        }
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

const ParsedRequest = struct {
    input: ?std.json.Parsed(JsonValue) = null,
    commands: std.json.Parsed(JsonValue),
    settings: ?std.json.Parsed(JsonValue) = null,
    reasoning: ?std.json.Parsed(JsonValue) = null,
    extra: ?std.json.Parsed(JsonValue) = null,

    fn init(alloc: Allocator, request: Request) !ParsedRequest {
        var commands = try parseRaw(alloc, request.commands_json, error.InvalidResponsesSearchCommands);
        var commands_owned = true;
        errdefer if (commands_owned) commands.deinit();
        if (commands.value != .object) return error.InvalidResponsesSearchCommands;
        var parsed: ParsedRequest = .{ .commands = commands };
        commands_owned = false;
        errdefer parsed.deinit();
        if (request.input_json) |raw| {
            parsed.input = try parseRaw(alloc, raw, error.InvalidResponsesSearchInput);
            if (parsed.input.?.value != .string and parsed.input.?.value != .array) {
                return error.InvalidResponsesSearchInput;
            }
        }
        if (request.settings_json) |raw| {
            parsed.settings = try parseRaw(alloc, raw, error.InvalidResponsesSearchSettings);
            if (parsed.settings.?.value != .object) return error.InvalidResponsesSearchSettings;
        }
        if (request.reasoning_json) |raw| {
            parsed.reasoning = try parseRaw(alloc, raw, error.InvalidResponsesSearchReasoning);
            if (parsed.reasoning.?.value != .object) return error.InvalidResponsesSearchReasoning;
        }
        if (request.extra_fields_json) |raw| {
            parsed.extra = try parseRaw(alloc, raw, error.InvalidResponsesSearchExtraFields);
            if (parsed.extra.?.value != .object) return error.InvalidResponsesSearchExtraFields;
            var iterator = parsed.extra.?.value.object.iterator();
            while (iterator.next()) |entry| {
                if (isOwnedRequestField(entry.key_ptr.*)) {
                    return error.DuplicateResponsesSearchRequestField;
                }
            }
        }
        return parsed;
    }

    fn deinit(self: *ParsedRequest) void {
        if (self.input) |*parsed| parsed.deinit();
        self.commands.deinit();
        if (self.settings) |*parsed| parsed.deinit();
        if (self.reasoning) |*parsed| parsed.deinit();
        if (self.extra) |*parsed| parsed.deinit();
    }
};

fn parseRaw(alloc: Allocator, raw: []const u8, parse_error: anyerror) !std.json.Parsed(JsonValue) {
    return std.json.parseFromSlice(JsonValue, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => parse_error,
    };
}

fn isOwnedRequestField(name: []const u8) bool {
    for ([_][]const u8{
        "id",
        "model",
        "input",
        "commands",
        "settings",
        "reasoning",
        "max_output_tokens",
    }) |field| {
        if (std.mem.eql(u8, name, field)) return true;
    }
    return false;
}

pub const DecodedResponse = struct {
    allocator: Allocator,
    raw_json: []u8,
    parsed: std.json.Parsed(JsonValue),
    encrypted_output: ?[]const u8,
    output: []const u8,
    results: ?[]const JsonValue,

    pub fn deinit(self: *DecodedResponse) void {
        self.parsed.deinit();
        self.allocator.free(self.raw_json);
        self.* = undefined;
    }

    pub fn json(self: *const DecodedResponse) *const JsonValue {
        return &self.parsed.value;
    }
};

pub const ResultSource = struct {
    ref_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    url: []const u8,
};

/// Projects the stable hyperlink fields shared by current search, open, and
/// image result variants. Unknown result kinds and fields remain available in
/// `DecodedResponse.results`; malformed or non-HTTP URLs are not rendered as
/// links by the product layer.
pub fn resultSource(value: JsonValue) ?ResultSource {
    if (value != .object) return null;
    const url_value = value.object.get("url") orelse return null;
    if (url_value != .string or !isRenderableUrl(url_value.string)) return null;
    return .{
        .ref_id = optionalBorrowedString(value, "ref_id"),
        .title = optionalBorrowedString(value, "title"),
        .url = url_value.string,
    };
}

fn optionalBorrowedString(value: JsonValue, name: []const u8) ?[]const u8 {
    const field = value.object.get(name) orelse return null;
    if (field != .string or field.string.len == 0) return null;
    return field.string;
}

fn isRenderableUrl(url: []const u8) bool {
    if ((!std.mem.startsWith(u8, url, "https://") and
        !std.mem.startsWith(u8, url, "http://")) or url.len > 8 * 1024)
    {
        return false;
    }
    for (url) |byte| {
        if (std.ascii.isControl(byte) or std.ascii.isWhitespace(byte) or
            byte == '<' or byte == '>') return false;
    }
    return true;
}

/// Decodes a standalone search response without discarding unknown envelope or
/// result fields. Projected slices borrow the owned parse tree.
pub fn decodeResponse(alloc: Allocator, body: []const u8) !DecodedResponse {
    const raw = try alloc.dupe(u8, body);
    errdefer alloc.free(raw);
    var parsed = std.json.parseFromSlice(JsonValue, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponsesSearchResponse,
    };
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponsesSearchResponse;
    const output_value = parsed.value.object.get("output") orelse
        return error.InvalidResponsesSearchResponse;
    if (output_value != .string) return error.InvalidResponsesSearchResponse;
    const encrypted_output = try optionalStringField(parsed.value, "encrypted_output");
    const results = if (parsed.value.object.get("results")) |value| blk: {
        if (value == .null) break :blk null;
        if (value != .array) return error.InvalidResponsesSearchResponse;
        break :blk value.array.items;
    } else null;
    return .{
        .allocator = alloc,
        .raw_json = raw,
        .parsed = parsed,
        .encrypted_output = encrypted_output,
        .output = output_value.string,
        .results = results,
    };
}

fn optionalStringField(value: JsonValue, name: []const u8) !?[]const u8 {
    if (value != .object) return error.InvalidResponsesSearchResponse;
    const field = value.object.get(name) orelse return null;
    if (field == .null) return null;
    if (field != .string) return error.InvalidResponsesSearchResponse;
    return field.string;
}

test "Responses standalone search tool declares the latest command surface" {
    const tool = try @import("web_search_projection.zig").codexNamespaceToolAlloc(std.testing.allocator);
    defer std.testing.allocator.free(tool);
    var parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, tool, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("namespace", parsed.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("web", parsed.value.object.get("name").?.string);
    const run = parsed.value.object.get("tools").?.array.items[0].object;
    try std.testing.expectEqualStrings("function", run.get("type").?.string);
    try std.testing.expectEqualStrings("run", run.get("name").?.string);
    try std.testing.expect(!run.get("strict").?.bool);
    try std.testing.expectEqual(@as(usize, 7507), run.get("description").?.string.len);
    try std.testing.expect(std.mem.startsWith(
        u8,
        run.get("description").?.string,
        "Tool for accessing the internet.",
    ));
    const parameters = run.get("parameters").?;
    const properties = parameters.object.get("properties").?.object;
    for ([_][]const u8{
        "search_query",
        "image_query",
        "open",
        "click",
        "find",
        "screenshot",
        "finance",
        "weather",
        "sports",
        "time",
        "response_length",
    }) |command| try std.testing.expect(properties.get(command) != null);
    try std.testing.expect(parameters.object.get("additionalProperties") == null);
    const time = properties.get("time").?.object;
    try std.testing.expectEqualStrings(
        "Get time for the given UTC offsets.",
        time.get("description").?.string,
    );
    const time_item = time.get("items").?.object;
    try std.testing.expect(time_item.get("additionalProperties") == null);
    try std.testing.expectEqualStrings(
        "UTC offset formatted like \"+03:00\".",
        time_item.get("properties").?.object.get("utc_offset").?.object.get("description").?.string,
    );
    const recency = properties.get("search_query").?.object
        .get("items").?.object
        .get("properties").?.object
        .get("recency").?.object;
    try std.testing.expect(recency.get("minimum") == null);
    try std.testing.expectEqualStrings(
        "Whether to filter by recency, as a number of recent days.",
        recency.get("description").?.string,
    );
}

test "Responses standalone search request preserves raw commands and future fields" {
    const body = try buildRequest(std.testing.allocator, .{
        .id = "session_1",
        .model = "gpt-5.6-sol",
        .input_json = "\"recent context\"",
        .commands_json = "{\"search_query\":[{\"q\":\"OpenAI news\",\"recency\":7}],\"response_length\":\"short\"}",
        .settings_json = "{\"allowed_callers\":[\"direct\"],\"external_web_access\":true}",
        .reasoning_json = "{\"effort\":\"high\"}",
        .max_output_tokens = 2048,
        .extra_fields_json = "{\"future_search_control\":{\"enabled\":true}}",
    });
    defer std.testing.allocator.free(body);
    var parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("session_1", parsed.value.object.get("id").?.string);
    try std.testing.expectEqualStrings("recent context", parsed.value.object.get("input").?.string);
    try std.testing.expectEqualStrings(
        "OpenAI news",
        parsed.value.object.get("commands").?.object.get("search_query").?.array.items[0].object.get("q").?.string,
    );
    try std.testing.expect(parsed.value.object.get("future_search_control") != null);
}

test "Responses standalone search request rejects malformed raw fields and collisions" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidResponsesSearchCommands,
        buildRequest(alloc, .{ .id = "id", .model = "model", .commands_json = "[]" }),
    );
    try std.testing.expectError(
        error.InvalidResponsesSearchInput,
        buildRequest(alloc, .{ .id = "id", .model = "model", .commands_json = "{}", .input_json = "{}" }),
    );
    try std.testing.expectError(
        error.DuplicateResponsesSearchRequestField,
        buildRequest(alloc, .{ .id = "id", .model = "model", .commands_json = "{}", .extra_fields_json = "{\"model\":\"other\"}" }),
    );
}

test "Responses standalone search response preserves unknown result fields" {
    const raw = "{\"encrypted_output\":\"opaque\",\"output\":\"search result\",\"results\":[{\"type\":\"text_result\",\"ref_id\":\"turn0search0\",\"url\":\"https://example.com\",\"future\":true}],\"future_envelope\":1}";
    var decoded = try decodeResponse(std.testing.allocator, raw);
    defer decoded.deinit();
    try std.testing.expectEqualStrings(raw, decoded.raw_json);
    try std.testing.expectEqualStrings("opaque", decoded.encrypted_output.?);
    try std.testing.expectEqualStrings("search result", decoded.output);
    try std.testing.expect(decoded.results.?[0].object.get("future") != null);
    try std.testing.expect(decoded.json().object.get("future_envelope") != null);
    const source = resultSource(decoded.results.?[0]).?;
    try std.testing.expectEqualStrings("turn0search0", source.ref_id.?);
    try std.testing.expectEqualStrings("https://example.com", source.url);
}

test "Responses standalone search source projection rejects unsafe URLs" {
    for ([_][]const u8{
        "{\"url\":\"javascript:alert(1)\"}",
        "{\"url\":\"https://example.com/line\\nfeed\"}",
        "{\"url\":42}",
    }) |raw| {
        var parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, raw, .{});
        defer parsed.deinit();
        try std.testing.expect(resultSource(parsed.value) == null);
    }
}

fn checkAllocationFailures(alloc: Allocator) !void {
    const tool = try @import("web_search_projection.zig").codexNamespaceToolAlloc(alloc);
    defer alloc.free(tool);
    const body = buildRequest(alloc, .{
        .id = "session_1",
        .model = "gpt-5.6-sol",
        .input_json = "\"context\"",
        .commands_json = "{\"search_query\":[{\"q\":\"OpenAI\"}]}",
        .settings_json = "{\"external_web_access\":true}",
        .reasoning_json = "{\"effort\":\"high\"}",
        .extra_fields_json = "{\"future\":true}",
    }) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer alloc.free(body);
    var response = try decodeResponse(
        alloc,
        "{\"output\":\"answer\",\"results\":[{\"url\":\"https://example.com\"}]}",
    );
    defer response.deinit();
}

test "Responses standalone search codecs clean up allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkAllocationFailures,
        .{},
    );
}
