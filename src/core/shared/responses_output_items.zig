const std = @import("std");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

/// Provider-owned Responses output is retained only for stateless replay. The
/// limits are independent of the transport frame limit so one response cannot
/// grow every later request and the durable session without bound.
pub const max_items: usize = 64;
pub const max_item_bytes: usize = 2 * 1024 * 1024;
pub const max_total_bytes: usize = 4 * 1024 * 1024;

/// One finalized provider-generated Responses output item. `json` owns one
/// complete JSON object exactly as it must be replayed for `store: false`.
pub const Item = struct {
    output_index: u32,
    json: []const u8,
};

pub fn dupe(alloc: Allocator, items: []const Item) ![]Item {
    if (items.len == 0) return &.{};
    const copy = try alloc.alloc(Item, items.len);
    errdefer alloc.free(copy);
    var copied: usize = 0;
    errdefer {
        for (copy[0..copied]) |item| alloc.free(@constCast(item.json));
    }
    for (items, 0..) |item, index| {
        copy[index] = .{
            .output_index = item.output_index,
            .json = try alloc.dupe(u8, item.json),
        };
        copied += 1;
    }
    return copy;
}

pub fn free(alloc: Allocator, items: []const Item) void {
    for (items) |item| alloc.free(@constCast(item.json));
    if (items.len > 0) alloc.free(@constCast(items));
}

/// Collects the complete finalized terminal `response.output`. Array order is
/// authoritative and becomes each item's replay index.
pub fn collectTerminalOutput(alloc: Allocator, maybe_output: ?JsonValue) ![]Item {
    const output = maybe_output orelse return &.{};
    if (output != .array) return error.InvalidResponsesOutput;
    if (output.array.items.len > std.math.maxInt(u32)) {
        return error.TooManyResponsesOutputItems;
    }

    var items: std.ArrayList(Item) = .empty;
    errdefer freeArrayListItems(alloc, &items);
    var total_bytes: usize = 0;
    for (output.array.items, 0..) |value, output_index| {
        const item = try materializeProviderItem(
            alloc,
            @intCast(output_index),
            value,
        );
        errdefer alloc.free(@constCast(item.json));
        try admitSize(items.items.len, &total_bytes, item.json.len);
        try items.append(alloc, item);
    }
    return items.toOwnedSlice(alloc);
}

/// Fallback for streams whose terminal event omits `response.output`. Only a
/// finalized `response.output_item.done` envelope should be passed here.
pub fn collectDoneEnvelope(
    alloc: Allocator,
    raw_json: []const u8,
    fallback_output_index: u32,
) !Item {
    var parsed = std.json.parseFromSlice(JsonValue, alloc, raw_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponsesOutput,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponsesOutput;
    const output_index = if (parsed.value.object.get("output_index")) |value|
        try parseOutputIndex(value)
    else
        fallback_output_index;
    const value = parsed.value.object.get("item") orelse
        return error.InvalidResponsesOutput;
    return materializeProviderItem(alloc, output_index, value);
}

/// Replaces the fallback item at the same output index or inserts it in wire
/// order. The caller retains ownership only when this function fails.
pub fn upsertOwned(
    alloc: Allocator,
    items: *std.ArrayList(Item),
    owned: Item,
) !void {
    var total_bytes: usize = 0;
    for (items.items) |item| total_bytes = std.math.add(usize, total_bytes, item.json.len) catch
        return error.ResponsesOutputItemsTooLarge;

    var insert_at = items.items.len;
    for (items.items, 0..) |item, index| {
        if (item.output_index == owned.output_index) {
            var without_old = total_bytes - item.json.len;
            try admitSize(items.items.len - 1, &without_old, owned.json.len);
            alloc.free(@constCast(items.items[index].json));
            items.items[index] = owned;
            return;
        }
        if (item.output_index > owned.output_index) {
            insert_at = index;
            break;
        }
    }
    try admitSize(items.items.len, &total_bytes, owned.json.len);
    try items.insert(alloc, insert_at, owned);
}

pub fn validate(alloc: Allocator, items: []const Item) !void {
    if (items.len > max_items) return error.TooManyResponsesOutputItems;
    var total_bytes: usize = 0;
    var previous_index: ?u32 = null;
    for (items) |item| {
        if (previous_index) |previous| {
            if (item.output_index <= previous) return error.InvalidResponsesOutputOrder;
        }
        previous_index = item.output_index;
        try admitSize(0, &total_bytes, item.json.len);
        var parsed = std.json.parseFromSlice(JsonValue, alloc, item.json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidResponsesOutput,
        };
        defer parsed.deinit();
        if (!isProviderOwnedItem(parsed.value)) return error.InvalidResponsesOutput;
    }
}

pub fn validateComplete(alloc: Allocator, items: []const Item) !void {
    try validate(alloc, items);
    for (items, 0..) |item, index| {
        if (item.output_index != @as(u32, @intCast(index))) {
            return error.InvalidResponsesOutputOrder;
        }
    }
}

/// Writes a retained item only after validating that the durable bytes still
/// contain exactly one provider-owned JSON object.
pub fn writeValidated(
    alloc: Allocator,
    writer: *std.Io.Writer,
    item: Item,
) !void {
    if (item.json.len == 0 or item.json.len > max_item_bytes) {
        return error.ResponsesOutputItemTooLarge;
    }
    var parsed = std.json.parseFromSlice(JsonValue, alloc, item.json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponsesOutput,
    };
    defer parsed.deinit();
    if (!isProviderOwnedItem(parsed.value)) return error.InvalidResponsesOutput;
    try std.json.Stringify.value(parsed.value, .{}, writer);
}

pub fn isProviderOwnedItem(value: JsonValue) bool {
    if (value != .object) return false;
    const type_value = value.object.get("type") orelse return false;
    if (type_value != .string or type_value.string.len == 0) return false;
    return true;
}

fn materializeProviderItem(
    alloc: Allocator,
    output_index: u32,
    value: JsonValue,
) !Item {
    if (value != .object) return error.InvalidResponsesOutput;
    const type_value = value.object.get("type") orelse
        return error.InvalidResponsesOutput;
    if (type_value != .string or type_value.string.len == 0) {
        return error.InvalidResponsesOutput;
    }
    var json: std.Io.Writer.Allocating = .init(alloc);
    errdefer json.deinit();
    std.json.Stringify.value(value, .{}, &json.writer) catch
        return error.OutOfMemory;
    if (json.written().len == 0 or json.written().len > max_item_bytes) {
        return error.ResponsesOutputItemTooLarge;
    }
    return .{
        .output_index = output_index,
        .json = try json.toOwnedSlice(),
    };
}

fn parseOutputIndex(value: JsonValue) !u32 {
    if (value != .integer or value.integer < 0 or
        value.integer > std.math.maxInt(u32))
    {
        return error.InvalidResponsesOutput;
    }
    return @intCast(value.integer);
}

fn admitSize(item_count: usize, total_bytes: *usize, item_bytes: usize) !void {
    if (item_count >= max_items) return error.TooManyResponsesOutputItems;
    if (item_bytes == 0 or item_bytes > max_item_bytes) {
        return error.ResponsesOutputItemTooLarge;
    }
    total_bytes.* = std.math.add(usize, total_bytes.*, item_bytes) catch
        return error.ResponsesOutputItemsTooLarge;
    if (total_bytes.* > max_total_bytes) return error.ResponsesOutputItemsTooLarge;
}

fn freeArrayListItems(alloc: Allocator, items: *std.ArrayList(Item)) void {
    for (items.items) |item| alloc.free(@constCast(item.json));
    items.deinit(alloc);
}

test "terminal output retains the complete provider sequence in wire order" {
    var parsed = try std.json.parseFromSlice(
        JsonValue,
        std.testing.allocator,
        "[" ++
            "{\"type\":\"reasoning\",\"id\":\"rs_1\"}," ++
            "{\"type\":\"web_search_call\",\"id\":\"ws_1\",\"status\":\"completed\"}," ++
            "{\"type\":\"future_provider_item\",\"payload\":{\"kept\":true}}," ++
            "{\"type\":\"function_call_output\",\"call_id\":\"call_1\",\"output\":\"done\"}," ++
            "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}" ++
            "]",
        .{},
    );
    defer parsed.deinit();

    const items = try collectTerminalOutput(std.testing.allocator, parsed.value);
    defer free(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 5), items.len);
    for (items, 0..) |item, index| {
        try std.testing.expectEqual(@as(u32, @intCast(index)), item.output_index);
    }
    try std.testing.expect(std.mem.find(u8, items[1].json, "web_search_call") != null);
    try validate(std.testing.allocator, items);
}

test "done envelope upsert is ordered and replaces duplicate indices" {
    var items: std.ArrayList(Item) = .empty;
    defer freeArrayListItems(std.testing.allocator, &items);
    const later = try collectDoneEnvelope(
        std.testing.allocator,
        "{\"type\":\"response.output_item.done\",\"output_index\":3,\"item\":{\"type\":\"future_provider_call\",\"id\":\"future_1\"}}",
        0,
    );
    try upsertOwned(std.testing.allocator, &items, later);
    const earlier = try collectDoneEnvelope(
        std.testing.allocator,
        "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"web_search_call\",\"id\":\"ws_old\"}}",
        0,
    );
    try upsertOwned(std.testing.allocator, &items, earlier);
    const replacement = try collectDoneEnvelope(
        std.testing.allocator,
        "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"web_search_call\",\"id\":\"ws_new\"}}",
        0,
    );
    try upsertOwned(std.testing.allocator, &items, replacement);

    try std.testing.expectEqual(@as(usize, 2), items.items.len);
    try std.testing.expectEqual(@as(u32, 1), items.items[0].output_index);
    try std.testing.expect(std.mem.find(u8, items.items[0].json, "ws_new") != null);
    try std.testing.expectEqual(@as(u32, 3), items.items[1].output_index);
}

fn checkAllocationFailures(alloc: Allocator) !void {
    var parsed = try std.json.parseFromSlice(
        JsonValue,
        alloc,
        "[{\"type\":\"web_search_call\",\"id\":\"ws_1\",\"action\":{\"type\":\"search\",\"query\":\"zig\"}}]",
        .{},
    );
    defer parsed.deinit();
    const items = try collectTerminalOutput(alloc, parsed.value);
    defer free(alloc, items);
    const copy = try dupe(alloc, items);
    defer free(alloc, copy);
    try validate(alloc, copy);
}

test "provider output item ownership is allocation failure safe" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkAllocationFailures,
        .{},
    );
}
