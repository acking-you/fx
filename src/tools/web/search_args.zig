const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    query: []u8,
    allowed_domains: ?[][]u8 = null,
    blocked_domains: ?[][]u8 = null,
    commands_json: ?[]u8 = null,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.query);
        freeOptionalStrings(alloc, self.allowed_domains);
        freeOptionalStrings(alloc, self.blocked_domains);
        if (self.commands_json) |commands| alloc.free(commands);
        self.* = .{ .query = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "web_search arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "web_search arguments must be an object") };
    }
    const is_legacy = parsed.value.object.get("query") != null;
    if ((if (is_legacy) unknownLegacyField(parsed.value.object) else unknownCommandField(parsed.value.object))) |field| {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "web_search field \"{s}\" is not supported", .{field}) };
    }

    if (!is_legacy) return decodeCommands(ctx, parsed.value.object, args_json);

    const query_value = parsed.value.object.get("query") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "web_search field \"query\" is required") };
    };
    if (query_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "web_search field \"query\" must be a string") };
    }
    const query_len = std.unicode.utf8CountCodepoints(query_value.string) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "web_search field \"query\" must be valid UTF-8") };
    };
    if (query_len < 2) {
        return .{ .failure = try ctx.allocator.dupe(u8, "web_search field \"query\" must contain at least two characters") };
    }

    var owned = DecodeOwned{ .alloc = ctx.allocator };
    defer owned.deinit();

    owned.query = try ctx.allocator.dupe(u8, query_value.string);

    const allowed_decoded = try decodeOptionalStrings(ctx, parsed.value.object, "allowed_domains");
    owned.allowed_domains = switch (allowed_decoded) {
        .strings => |strings| strings,
        .failure => |reason| return .{ .failure = reason },
    };

    const blocked_decoded = try decodeOptionalStrings(ctx, parsed.value.object, "blocked_domains");
    owned.blocked_domains = switch (blocked_decoded) {
        .strings => |strings| strings,
        .failure => |reason| return .{ .failure = reason },
    };

    const input = try ctx.allocator.create(Input);
    input.* = owned.take();
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    if (hasValues(input.allowed_domains) and hasValues(input.blocked_domains)) {
        return try ctx.allocator.dupe(u8, "web_search accepts only one non-empty domain filter");
    }
    return null;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn freeOptionalStrings(alloc: Allocator, strings: ?[][]u8) void {
    const values = strings orelse return;
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

const OptionalStringsDecodeResult = union(enum) {
    strings: ?[][]u8,
    failure: []u8,
};

const DecodeOwned = struct {
    alloc: Allocator,
    query: ?[]u8 = null,
    allowed_domains: ?[][]u8 = null,
    blocked_domains: ?[][]u8 = null,
    commands_json: ?[]u8 = null,

    fn deinit(self: *DecodeOwned) void {
        if (self.query) |query| self.alloc.free(query);
        freeOptionalStrings(self.alloc, self.allowed_domains);
        freeOptionalStrings(self.alloc, self.blocked_domains);
        if (self.commands_json) |commands| self.alloc.free(commands);
        self.query = null;
        self.allowed_domains = null;
        self.blocked_domains = null;
        self.commands_json = null;
    }

    fn take(self: *DecodeOwned) Input {
        const input = Input{
            .query = self.query.?,
            .allowed_domains = self.allowed_domains,
            .blocked_domains = self.blocked_domains,
            .commands_json = self.commands_json,
        };
        self.query = null;
        self.allowed_domains = null;
        self.blocked_domains = null;
        self.commands_json = null;
        return input;
    }
};

fn decodeOptionalStrings(ctx: tool_dispatch.DispatchContext, object: std.json.ObjectMap, field: []const u8) tool_dispatch.DispatchError!OptionalStringsDecodeResult {
    const value = object.get(field) orelse return .{ .strings = null };
    if (value != .array) {
        return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "web_search field \"{s}\" must be an array of strings", .{field}) };
    }

    const strings = try ctx.allocator.alloc([]u8, value.array.items.len);
    var owned_strings: ?[][]u8 = strings;
    var initialized: usize = 0;
    defer {
        if (owned_strings) |values| {
            for (values[0..initialized]) |string| ctx.allocator.free(string);
            ctx.allocator.free(values);
        }
    }

    for (value.array.items, 0..) |item, index| {
        if (item != .string) {
            return .{ .failure = try std.fmt.allocPrint(ctx.allocator, "web_search field \"{s}\" item {d} must be a string", .{ field, index }) };
        }
        strings[index] = try ctx.allocator.dupe(u8, item.string);
        initialized += 1;
    }
    if (strings.len == 0) {
        return .{ .strings = null };
    }
    owned_strings = null;
    return .{ .strings = strings };
}

fn unknownLegacyField(object: std.json.ObjectMap) ?[]const u8 {
    var fields = object.iterator();
    while (fields.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "query")) continue;
        if (std.mem.eql(u8, entry.key_ptr.*, "allowed_domains")) continue;
        if (std.mem.eql(u8, entry.key_ptr.*, "blocked_domains")) continue;
        return entry.key_ptr.*;
    }
    return null;
}

fn unknownCommandField(object: std.json.ObjectMap) ?[]const u8 {
    var fields = object.iterator();
    while (fields.next()) |entry| {
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
        }) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) break;
        } else return entry.key_ptr.*;
    }
    return null;
}

fn decodeCommands(
    ctx: tool_dispatch.DispatchContext,
    object: std.json.ObjectMap,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const owned_query = try commandLabel(ctx.allocator, object);
    errdefer ctx.allocator.free(owned_query);
    const commands = try ctx.allocator.dupe(u8, args_json);
    errdefer ctx.allocator.free(commands);
    const input = try ctx.allocator.create(Input);
    input.* = .{
        .query = owned_query,
        .commands_json = commands,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn commandLabel(alloc: Allocator, object: std.json.ObjectMap) ![]u8 {
    for ([_][]const u8{ "search_query", "image_query" }) |field| {
        const values = object.get(field) orelse continue;
        if (values != .array or values.array.items.len == 0) continue;
        const first = values.array.items[0];
        if (first != .object) continue;
        const query = first.object.get("q") orelse continue;
        if (query == .string and query.string.len > 0) return alloc.dupe(u8, query.string);
    }
    for ([_][]const u8{ "open", "click", "find", "screenshot" }) |field| {
        const values = object.get(field) orelse continue;
        if (values != .array or values.array.items.len == 0) continue;
        const first = values.array.items[0];
        if (first != .object) continue;
        const ref_id = first.object.get("ref_id") orelse continue;
        if (ref_id == .string and ref_id.string.len > 0) return alloc.dupe(u8, ref_id.string);
    }
    for ([_][]const u8{ "ticker", "location", "utc_offset" }, [_][]const u8{ "finance", "weather", "time" }) |detail, field| {
        const values = object.get(field) orelse continue;
        if (values != .array or values.array.items.len == 0) continue;
        const first = values.array.items[0];
        if (first != .object) continue;
        const value = first.object.get(detail) orelse continue;
        if (value == .string and value.string.len > 0) return alloc.dupe(u8, value.string);
    }
    return alloc.dupe(u8, "web");
}

fn hasValues(strings: ?[][]u8) bool {
    return if (strings) |values| values.len > 0 else false;
}

fn expectDecodeFailure(args_json: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expectEqualStrings(expected, body);
        },
        .input => |input| {
            defer input.deinit(alloc);
            return error.TestExpectedEqual;
        },
    }
}

fn expectDecodeInput(args_json: []const u8, expected_query: []const u8) !tool_dispatch.ToolInput {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            return error.TestExpectedEqual;
        },
        .input => |input| {
            const decoded_input = input.as(Input);
            try std.testing.expectEqualStrings(expected_query, decoded_input.query);
            return input;
        },
    }
}

test "web_search decode rejects invalid argument shapes" {
    try expectDecodeFailure("{", "web_search arguments must be valid JSON");
    try expectDecodeFailure("[]", "web_search arguments must be an object");
    try expectDecodeFailure("{\"query\":\"ok\",\"extra\":true}", "web_search field \"extra\" is not supported");
    try expectDecodeFailure("{\"query\":1}", "web_search field \"query\" must be a string");
    try expectDecodeFailure("{\"query\":\"a\"}", "web_search field \"query\" must contain at least two characters");
    try expectDecodeFailure(
        "{\"query\":\"zig\",\"allowed_domains\":\"example.com\"}",
        "web_search field \"allowed_domains\" must be an array of strings",
    );
    try expectDecodeFailure(
        "{\"query\":\"zig\",\"blocked_domains\":[\"example.com\",1]}",
        "web_search field \"blocked_domains\" item 1 must be a string",
    );
}

test "web_search accepts empty latest command object for provider defaults" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{}");
    switch (decoded) {
        .failure => |failure| {
            defer alloc.free(failure);
            return error.TestExpectedEqual;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const value = input.as(Input);
            try std.testing.expectEqualStrings("web", value.query);
            try std.testing.expectEqualStrings("{}", value.commands_json.?);
        },
    }
}

test "web_search decode owns query and optional domain filters" {
    const alloc = std.testing.allocator;
    const input = try expectDecodeInput(
        "{\"query\":\"zig allocators\",\"allowed_domains\":[\"ziglang.org\",\"example.com\"],\"blocked_domains\":[]}",
        "zig allocators",
    );
    defer input.deinit(alloc);

    const decoded = input.as(Input);
    try std.testing.expect(decoded.allowed_domains != null);
    try std.testing.expect(decoded.blocked_domains == null);
    try std.testing.expectEqual(@as(usize, 2), decoded.allowed_domains.?.len);
    try std.testing.expectEqualStrings("ziglang.org", decoded.allowed_domains.?[0]);
    try std.testing.expectEqualStrings("example.com", decoded.allowed_domains.?[1]);
}

test "web_search decode preserves latest Codex command objects" {
    const alloc = std.testing.allocator;
    const input = try expectDecodeInput(
        "{\"search_query\":[{\"q\":\"latest Codex release\",\"recency\":7}],\"open\":[{\"ref_id\":\"turn0search0\",\"lineno\":12}],\"response_length\":\"short\"}",
        "latest Codex release",
    );
    defer input.deinit(alloc);

    const decoded = input.as(Input);
    try std.testing.expect(decoded.commands_json != null);
    try std.testing.expectEqualStrings(
        "{\"search_query\":[{\"q\":\"latest Codex release\",\"recency\":7}],\"open\":[{\"ref_id\":\"turn0search0\",\"lineno\":12}],\"response_length\":\"short\"}",
        decoded.commands_json.?,
    );
    try std.testing.expect(decoded.allowed_domains == null);
    try std.testing.expect(decoded.blocked_domains == null);
}

test "web_search command decode derives a safe fallback label and rejects unknown commands" {
    const alloc = std.testing.allocator;
    const input = try expectDecodeInput(
        "{\"sports\":[{\"fn\":\"schedule\",\"league\":\"nba\"}]}",
        "web",
    );
    input.deinit(alloc);
    try expectDecodeFailure(
        "{\"search_query\":[{\"q\":\"zig\"}],\"future_command\":[]}",
        "web_search field \"future_command\" is not supported",
    );
}

test "web_search validation allows only one non-empty domain filter" {
    const alloc = std.testing.allocator;
    const input = try expectDecodeInput(
        "{\"query\":\"zig allocators\",\"allowed_domains\":[\"ziglang.org\"],\"blocked_domains\":[\"example.com\"]}",
        "zig allocators",
    );
    defer input.deinit(alloc);

    const reason = try validate(.{ .allocator = alloc }, input);
    defer if (reason) |body| alloc.free(body);
    try std.testing.expectEqualStrings("web_search accepts only one non-empty domain filter", reason.?);
}

test "web_search validation allows one populated filter and one empty filter" {
    const alloc = std.testing.allocator;
    const input = try expectDecodeInput(
        "{\"query\":\"zig allocators\",\"allowed_domains\":[],\"blocked_domains\":[\"example.com\"]}",
        "zig allocators",
    );
    defer input.deinit(alloc);

    try std.testing.expect((try validate(.{ .allocator = alloc }, input)) == null);
}
