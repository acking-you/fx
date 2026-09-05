const std = @import("std");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const sort_utils = @import("../core/shared/sort_utils.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

/// Parses the standard OpenAI `GET /v1/models` response into Fx's owned
/// catalog contract. Compatible endpoints may publish capability metadata;
/// explicit metadata takes precedence over the standard OpenAI defaults.
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
        const object = raw.object;
        const supports_reasoning = try optionalBool(object, &.{ "supports_reasoning_effort", "supportsReasoningEffort" });
        var reasoning_efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer reasoning_efforts.deinit(alloc);
        const advertised_efforts = try aliasedValue(object, &.{ "reasoning_efforts", "reasoningEfforts" });
        const default_effort = if (advertised_efforts) |efforts|
            try parseReasoningEfforts(alloc, &reasoning_efforts, efforts, object)
        else
            types.ReasoningEffort.auto;
        if (advertised_efforts == null and supports_reasoning != false and hasKnownGpt56Controls(id)) {
            try reasoning_efforts.appendSlice(alloc, &gpt56_reasoning_efforts);
        }
        if (supports_reasoning == false) reasoning_efforts.clearRetainingCapacity();
        try candidates.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .released = optionalInteger(raw.object.get("created")),
            .has_tool_use = try optionalBool(object, &.{ "supports_tool_use", "supportsToolUse" }) orelse text_model,
            .has_reasoning = supports_reasoning orelse (reasoning_model or reasoning_efforts.items.len > 0),
            .reasoning_efforts = reasoning_efforts,
            .default_reasoning_effort = if (supports_reasoning == false) .auto else default_effort,
            .supports_fast_mode = try optionalBool(object, &.{ "supports_fast_mode", "supportsFastMode" }) orelse hasKnownGpt56Controls(id),
            .has_vision = try optionalBool(object, &.{ "supports_vision", "supportsVision" }) orelse text_model,
            .has_file_input = try optionalBool(object, &.{ "supports_file_input", "supportsFileInput" }) orelse text_model,
            .has_web_search = try optionalBool(object, &.{ "supports_backend_search", "supportsBackendSearch" }) orelse text_model,
            .context_window = try optionalLimit(object, &.{ "context_window", "contextWindow" }),
            .max_tokens = try optionalLimit(object, &.{ "max_output_tokens", "max_completion_tokens", "maxCompletionTokens" }),
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

fn aliasedValue(object: std.json.ObjectMap, keys: []const []const u8) !?std.json.Value {
    var found: ?std.json.Value = null;
    for (keys) |key| {
        if (object.get(key)) |value| {
            // Conflicting aliases must not silently enable a denied capability.
            if (found) |prior| {
                const equal = switch (prior) {
                    .bool => value == .bool and prior.bool == value.bool,
                    .integer => value == .integer and prior.integer == value.integer,
                    .string => value == .string and std.mem.eql(u8, prior.string, value.string),
                    else => false,
                };
                if (!equal) return error.MalformedResponse;
            } else found = value;
        }
    }
    return found;
}

fn optionalBool(object: std.json.ObjectMap, keys: []const []const u8) !?bool {
    const value = try aliasedValue(object, keys) orelse return null;
    if (value != .bool) return error.MalformedResponse;
    return value.bool;
}

fn optionalLimit(object: std.json.ObjectMap, keys: []const []const u8) !u32 {
    const value = try aliasedValue(object, keys) orelse return 0;
    if (value != .integer) return error.MalformedResponse;
    return std.math.cast(u32, value.integer) orelse error.MalformedResponse;
}

fn parseReasoningEfforts(
    alloc: Allocator,
    out: *std.ArrayList(types.ReasoningEffort),
    value: std.json.Value,
    object: std.json.ObjectMap,
) !types.ReasoningEffort {
    if (value != .array or value.array.items.len > types.ReasoningEffort.max_options) return error.MalformedResponse;
    var default: types.ReasoningEffort = .auto;
    for (value.array.items) |entry| {
        const name = switch (entry) {
            .string => entry,
            .object => try aliasedValue(entry.object, &.{ "value", "effort" }) orelse return error.MalformedResponse,
            else => return error.MalformedResponse,
        };
        if (name != .string) return error.MalformedResponse;
        const effort = types.ReasoningEffort.parse(name.string) orelse return error.MalformedResponse;
        if (effort.isDefault()) continue;
        const is_default = if (entry == .object) try optionalBool(entry.object, &.{"default"}) orelse false else false;
        if (is_default) {
            if (!default.isDefault() and !default.eql(effort)) return error.MalformedResponse;
            default = effort;
        }
        for (out.items) |existing| {
            if (existing.eql(effort)) break;
        } else try out.append(alloc, effort);
    }
    if (default.isDefault()) {
        if (try aliasedValue(object, &.{ "reasoning_effort", "reasoningEffort" })) |raw| {
            if (raw != .string) return error.MalformedResponse;
            const requested = types.ReasoningEffort.parse(raw.string) orelse return error.MalformedResponse;
            for (out.items) |effort| {
                if (effort.eql(requested)) {
                    default = effort;
                    break;
                }
            }
        }
    }
    if (default.isDefault() and out.items.len > 0) default = out.items[0];
    return default;
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

test "OpenAI catalog honors BYOK search and reasoning metadata independent of model names" {
    const json_text =
        \\{"data":[
        \\ {"id":"claude-custom[1m]","supports_backend_search":true,"supports_tool_use":true,"context_window":1000000,"max_output_tokens":32000,"supports_reasoning_effort":true,"reasoning_efforts":[{"value":"high","default":true},"low","high"]},
        \\ {"id":"grok-custom","supportsBackendSearch":true,"supportsToolUse":true,"contextWindow":500000,"maxCompletionTokens":16000,"supportsReasoningEffort":true,"reasoningEfforts":["provider-next","low"],"reasoningEffort":"low"},
        \\ {"id":"gpt-5.6-sol","supports_backend_search":false,"supports_reasoning_effort":false,"reasoning_efforts":["high"],"supports_fast_mode":false,"supports_vision":false,"supports_file_input":false}
        \\]}
    ;
    var catalog = try parse(std.testing.allocator, json_text, .full);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 3), catalog.items.len);
    // Capabilities are keyed by wire ID; picker ranking may reorder the list.
    const claude = for (catalog.items) |entry| {
        if (std.mem.eql(u8, entry.id, "claude-custom[1m]")) break entry;
    } else return error.TestExpectedModel;
    try std.testing.expect(claude.has_web_search and claude.has_tool_use and claude.has_reasoning);
    try std.testing.expectEqual(@as(u32, 1_000_000), claude.context_window);
    try std.testing.expectEqual(@as(u32, 32_000), claude.max_tokens);
    try std.testing.expectEqual(@as(usize, 2), claude.reasoning_efforts.items.len);
    try std.testing.expectEqualStrings("high", claude.default_reasoning_effort.label());
    const denied = for (catalog.items) |entry| {
        if (std.mem.eql(u8, entry.id, "gpt-5.6-sol")) break entry;
    } else return error.TestExpectedModel;
    try std.testing.expect(!denied.has_web_search and !denied.has_reasoning and !denied.supports_fast_mode);
    try std.testing.expect(!denied.has_vision and !denied.has_file_input);
    try std.testing.expectEqual(@as(usize, 0), denied.reasoning_efforts.items.len);
    const grok = for (catalog.items) |entry| {
        if (std.mem.eql(u8, entry.id, "grok-custom")) break entry;
    } else return error.TestExpectedModel;
    try std.testing.expect(grok.has_web_search and grok.has_tool_use and grok.has_reasoning);
    try std.testing.expectEqual(@as(u32, 500_000), grok.context_window);
    try std.testing.expectEqual(@as(u32, 16_000), grok.max_tokens);
    try std.testing.expectEqualStrings("low", grok.default_reasoning_effort.label());
    try std.testing.expectEqualStrings("provider-next", grok.reasoning_efforts.items[0].label());
}

test "OpenAI catalog rejects malformed or conflicting BYOK capability metadata" {
    for ([_][]const u8{
        "\"supports_backend_search\":\"true\"",
        "\"supports_backend_search\":true,\"supportsBackendSearch\":false",
        "\"context_window\":-1",
        "\"context_window\":4294967296",
        "\"reasoning_efforts\":{}",
        "\"reasoning_efforts\":[{\"value\":\"high\",\"default\":true},{\"value\":\"low\",\"default\":true}]",
    }) |fields| {
        const json = try std.fmt.allocPrint(std.testing.allocator, "{{\"data\":[{{\"id\":\"custom\",{s}}}]}}", .{fields});
        defer std.testing.allocator.free(json);
        try std.testing.expectError(error.MalformedResponse, parse(std.testing.allocator, json, .full));
    }
}

fn checkAllocationFailures(alloc: Allocator) !void {
    var catalog = try parse(
        alloc,
        "{\"data\":[{\"id\":\"gpt-5.6-sol\",\"object\":\"model\"},{\"id\":\"custom\",\"supports_backend_search\":true,\"reasoning_efforts\":[\"high\",\"low\"]}]}",
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
