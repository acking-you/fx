const std = @import("std");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

pub const Kind = enum {
    /// fx executes the provider-neutral `web_search` function locally.
    function,
    /// ChatGPT Codex invokes the exact reserved `web.run` namespace, which fx
    /// executes through the account-bound standalone search endpoint.
    codex_namespace,
    /// The Responses provider executes its built-in web search inside the
    /// model request and returns `web_search_call` output items.
    hosted,
};

pub const Options = struct {
    kind: Kind,
    /// The effective tool set can advertise web search without placing the
    /// local schema in `serialized_tools` (for example, provider-owned tools).
    include_web_search: bool = false,
};

const codex_web_run_namespace_json = @embedFile("codex_web_run_tool.json");
const hosted_web_search_json = "{\"type\":\"web_search\"}";

pub fn codexNamespaceToolAlloc(alloc: Allocator) ![]u8 {
    return alloc.dupe(u8, codex_web_run_namespace_json);
}

/// Projects the one provider-neutral `web_search` declaration at the provider
/// boundary. Other tools retain their original JSON values and ambiguous
/// local/native duplicates are rejected before network admission.
pub fn projectToolsAlloc(
    alloc: Allocator,
    serialized_tools: []const u8,
    options: Options,
) ![]u8 {
    var parsed = std.json.parseFromSlice(JsonValue, alloc, serialized_tools, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponsesTools,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidResponsesTools;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    var search_declared = false;
    var wrote_tool = false;
    for (parsed.value.array.items) |tool| {
        const local_search = isLocalWebSearchFunction(tool);
        const native_search = isNativeWebSearch(tool);
        if ((local_search or native_search) and search_declared) {
            return error.AmbiguousResponsesWebSearchTools;
        }
        if (local_search or native_search) search_declared = true;

        if (wrote_tool) try out.writer.writeByte(',');
        if (local_search and options.kind != .function) {
            try writeProjectedSearch(&out.writer, options.kind);
        } else {
            if (native_search and !nativeMatchesKind(tool, options.kind)) {
                return error.AmbiguousResponsesWebSearchTools;
            }
            try std.json.Stringify.value(tool, .{}, &out.writer);
        }
        wrote_tool = true;
    }
    if (options.include_web_search and !search_declared) {
        if (options.kind == .function) return error.MissingResponsesWebSearchFunction;
        if (wrote_tool) try out.writer.writeByte(',');
        try writeProjectedSearch(&out.writer, options.kind);
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

fn writeProjectedSearch(writer: *std.Io.Writer, kind: Kind) !void {
    try writer.writeAll(switch (kind) {
        .function => unreachable,
        .codex_namespace => codex_web_run_namespace_json,
        .hosted => hosted_web_search_json,
    });
}

fn isLocalWebSearchFunction(tool: JsonValue) bool {
    if (tool != .object) return false;
    const type_value = tool.object.get("type") orelse return false;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "function")) return false;
    const fields = tool.object.get("function") orelse tool;
    if (fields != .object) return false;
    const name = fields.object.get("name") orelse return false;
    return name == .string and std.mem.eql(u8, name.string, "web_search");
}

fn isNativeWebSearch(tool: JsonValue) bool {
    if (tool != .object) return false;
    const type_value = tool.object.get("type") orelse return false;
    if (type_value != .string) return false;
    if (std.mem.eql(u8, type_value.string, "web_search")) return true;
    if (!std.mem.eql(u8, type_value.string, "namespace")) return false;
    const name = tool.object.get("name") orelse return false;
    return name == .string and std.mem.eql(u8, name.string, "web");
}

fn nativeMatchesKind(tool: JsonValue, kind: Kind) bool {
    if (kind == .function or tool != .object) return false;
    const type_value = tool.object.get("type") orelse return false;
    if (type_value != .string) return false;
    return switch (kind) {
        .function => false,
        .codex_namespace => std.mem.eql(u8, type_value.string, "namespace"),
        .hosted => std.mem.eql(u8, type_value.string, "web_search"),
    };
}

test "web search projection selects Codex namespace or hosted Responses tool" {
    const source =
        "[{\"type\":\"function\",\"name\":\"read_file\"}," ++
        "{\"type\":\"function\",\"name\":\"web_search\"}]";
    inline for (.{
        .{ .kind = Kind.codex_namespace, .expected_type = "namespace" },
        .{ .kind = Kind.hosted, .expected_type = "web_search" },
    }) |case| {
        const projected = try projectToolsAlloc(std.testing.allocator, source, .{ .kind = case.kind });
        defer std.testing.allocator.free(projected);
        var parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, projected, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
        try std.testing.expectEqualStrings(
            case.expected_type,
            parsed.value.array.items[1].object.get("type").?.string,
        );
    }
}

test "web search projection appends provider-owned declaration and rejects duplicates" {
    const projected = try projectToolsAlloc(
        std.testing.allocator,
        "[{\"type\":\"function\",\"name\":\"read_file\"}]",
        .{ .kind = .hosted, .include_web_search = true },
    );
    defer std.testing.allocator.free(projected);
    try std.testing.expect(std.mem.find(u8, projected, "\"type\":\"web_search\"") != null);

    try std.testing.expectError(
        error.AmbiguousResponsesWebSearchTools,
        projectToolsAlloc(
            std.testing.allocator,
            "[{\"type\":\"function\",\"name\":\"web_search\"},{\"type\":\"web_search\"}]",
            .{ .kind = .hosted },
        ),
    );
}
