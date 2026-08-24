const std = @import("std");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const sort_utils = @import("../core/shared/sort_utils.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

/// Parses the standard OpenAI `GET /v1/models` response into Fx's owned
/// catalog contract. The endpoint does not publish capability metadata, so
/// only exact model IDs with controls maintained by Fx receive those controls.
pub fn parse(
    alloc: Allocator,
    json_text: []const u8,
    view: model_catalog.View,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var catalog = try parseFull(alloc, json_text);
    switch (view) {
        .full => return catalog,
        .picker => {
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            return model_catalog.projectPickerModelCatalog(alloc, catalog.items);
        },
    }
}

fn parseFull(
    alloc: Allocator,
    json_text: []const u8,
) !std.ArrayList(model_catalog.ModelCatalogEntry) {
    var candidates: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &candidates);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedResponse;
    const data = parsed.value.object.get("data") orelse return error.MalformedResponse;
    if (data != .array) return error.MalformedResponse;

    for (data.array.items) |raw| {
        if (raw != .object) continue;
        const id_value = raw.object.get("id") orelse continue;
        if (id_value != .string or id_value.string.len == 0) continue;

        const id = try alloc.dupe(u8, id_value.string);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        const reasoning_model = isReasoningModel(id);
        const text_model = isTextModel(id);
        var reasoning_efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer reasoning_efforts.deinit(alloc);
        if (hasKnownGpt56Controls(id)) {
            try reasoning_efforts.appendSlice(alloc, &gpt56_reasoning_efforts);
        }
        try candidates.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .released = optionalInteger(raw.object.get("created")),
            .has_tool_use = text_model,
            .has_reasoning = reasoning_model,
            .reasoning_efforts = reasoning_efforts,
            .supports_fast_mode = hasKnownGpt56Controls(id),
            .has_vision = text_model,
            .has_file_input = text_model,
            .has_web_search = text_model,
        });
    }
    sort_utils.sort(
        model_catalog.ModelCatalogEntry,
        candidates.items,
        {},
        model_catalog.compareModelCatalogEntries,
    );
    return candidates;
}

const gpt56_reasoning_efforts = [_]types.ReasoningEffort{
    types.ReasoningEffort.literal("none"),
    types.ReasoningEffort.literal("low"),
    types.ReasoningEffort.literal("medium"),
    types.ReasoningEffort.literal("high"),
    types.ReasoningEffort.literal("xhigh"),
    types.ReasoningEffort.literal("max"),
};

fn hasKnownGpt56Controls(model: []const u8) bool {
    inline for (.{
        "gpt-5.6",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
    }) |candidate| {
        if (std.mem.eql(u8, model, candidate)) return true;
    }
    return false;
}

fn isReasoningModel(model: []const u8) bool {
    if (std.mem.startsWith(u8, model, "gpt-5")) return true;
    return model.len >= 2 and model[0] == 'o' and std.ascii.isDigit(model[1]);
}

fn isTextModel(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "gpt-") or
        isReasoningModel(model) or
        std.mem.startsWith(u8, model, "codex-") or
        std.mem.startsWith(u8, model, "chatgpt-");
}

fn optionalInteger(value: ?std.json.Value) i64 {
    const present = value orelse return 0;
    return switch (present) {
        .integer => |integer| integer,
        else => 0,
    };
}

test "OpenAI catalog preserves wire IDs and exact maintained controls" {
    const json_text =
        \\{"object":"list","data":[
        \\  {"id":"gpt-5.6-sol","object":"model","created":42},
        \\  {"id":"text-embedding-3-large","object":"model","created":41}
        \\]}
    ;
    var catalog = try parse(std.testing.allocator, json_text, .full);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);

    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", catalog.items[0].id);
    try std.testing.expect(catalog.items[0].has_tool_use);
    try std.testing.expect(catalog.items[0].has_reasoning);
    try std.testing.expect(catalog.items[0].has_vision);
    try std.testing.expectEqual(@as(usize, 6), catalog.items[0].reasoning_efforts.items.len);
    try std.testing.expectEqualStrings("none", catalog.items[0].reasoning_efforts.items[0].label());
    try std.testing.expectEqualStrings("max", catalog.items[0].reasoning_efforts.items[5].label());
    try std.testing.expect(catalog.items[0].supports_fast_mode);
    try std.testing.expectEqualStrings("text-embedding-3-large", catalog.items[1].id);
    try std.testing.expect(!catalog.items[1].has_tool_use);
}

test "OpenAI catalog does not infer maintained controls for custom IDs" {
    const json_text =
        \\{"data":[
        \\  {"id":"gpt-5.6-company-custom","object":"model"},
        \\  {"id":"company/gpt-5.6-sol","object":"model"}
        \\]}
    ;
    var catalog = try parse(std.testing.allocator, json_text, .full);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);

    try std.testing.expectEqual(@as(usize, 2), catalog.items.len);
    for (catalog.items) |entry| {
        try std.testing.expectEqual(@as(usize, 0), entry.reasoning_efforts.items.len);
        try std.testing.expect(!entry.supports_fast_mode);
    }
}

fn checkAllocationFailures(alloc: Allocator) !void {
    var catalog = try parse(
        alloc,
        "{\"data\":[{\"id\":\"gpt-5.6-sol\",\"object\":\"model\"}]}",
        .full,
    );
    defer model_catalog.freeModelCatalog(alloc, &catalog);
}

test "OpenAI catalog cleans all partial allocations" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkAllocationFailures,
        .{},
    );
}

test "OpenAI catalog rejects malformed envelopes" {
    try std.testing.expectError(
        error.MalformedResponse,
        parse(std.testing.allocator, "{\"data\":{}}", .full),
    );
}
