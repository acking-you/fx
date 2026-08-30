const std = @import("std");
const gateway_client = @import("client.zig");
const io_mod = @import("../core/shared/io.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const web_search_contract = @import("../core/tooling/web_search_contract.zig");
const web_search_policy = @import("../core/tooling/web_search_policy.zig");
const web_search_provider = @import("../core/tooling/web_search_provider.zig");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

const api_key_env = "FX_WEB_SEARCH_API_KEY";
const base_url_env = "FX_WEB_SEARCH_BASE_URL";
const model_env = "FX_WEB_SEARCH_MODEL";
const default_base_url = "https://api.openai.com/v1";
const backend_id = web_search_contract.SearchBackendId{ .value = "configured_responses_search" };
const preferred_backends = [_]web_search_contract.SearchBackendId{backend_id};
const backend_policies = [_]web_search_policy.BackendPolicy{.{
    .id = backend_id,
    .features = .{
        .max_uses = .best_effort,
        .allowed_domains = .pass_through,
        .blocked_domains = .pass_through,
        .ordered_sources = true,
        .usage = true,
        .terminal_incomplete = true,
        .timeout = true,
        .cancellation = true,
        .result_bounds = .post_filter,
    },
}};

pub const provider = web_search_provider.Provider{
    .policy = .{
        .preferred_backends = &preferred_backends,
        .backend_policies = &backend_policies,
    },
    .available_fn = configured,
    .preferred_backends_fn = preferredBackends,
    .execute_fn = execute,
};

fn configured(_: ?*anyopaque) bool {
    return environmentValue(api_key_env) != null and
        environmentValue(model_env) != null;
}

fn preferredBackends(_: ?*anyopaque) !?[]const web_search_contract.SearchBackendId {
    return if (configured(null)) &preferred_backends else null;
}

fn execute(
    _: ?*anyopaque,
    alloc: Allocator,
    _: web_search_provider.Inputs,
    request: web_search_contract.ProviderRequest,
    on_progress: ?web_search_contract.ProgressFn,
    progress_ctx: ?*anyopaque,
) !web_search_contract.ProviderResponse {
    if (!request.backend.eql(backend_id)) return error.InvalidWebSearchBackend;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const api_key = environmentValue(api_key_env) orelse
        return error.MissingConfiguredWebSearchApiKey;
    const model = environmentValue(model_env) orelse
        return error.MissingConfiguredWebSearchModel;
    const base_url = environmentValue(base_url_env) orelse default_base_url;
    const endpoint = try responsesEndpointAlloc(alloc, base_url);
    defer alloc.free(endpoint);
    const payload = try buildRequestAlloc(alloc, model, request);
    defer alloc.free(payload);
    try reportProgress(on_progress, progress_ctx, .{ .query_update = request.query });

    var response = try gateway_client.fetchOpenAIJsonBounded(alloc, .{
        .url = endpoint,
        .api_key = api_key,
        .payload = payload,
        .cancel_flag = @constCast(request.cancel_flag),
        .deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(request.timeout_ms),
        }),
        .max_response_bytes = 512 * 1024,
    });
    defer response.deinit(alloc);
    if (response.status.class() != .success) {
        return error.ConfiguredWebSearchRequestFailed;
    }
    var decoded = try decodeResponse(alloc, response.body, request);
    errdefer decoded.deinit(alloc);
    try reportProgress(on_progress, progress_ctx, .{ .results_received = .{
        .query = request.query,
        .result_count = decoded.source_count,
    } });
    const stop_reason = try alloc.dupe(u8, "stop");
    errdefer alloc.free(stop_reason);
    return .{
        .content = decoded.takeContent(),
        .stop_reason = stop_reason,
        .usage = .{ .web_search_requests = 1 },
    };
}

fn environmentValue(key: []const u8) ?[]const u8 {
    const value = io_mod.getenv(key) orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

fn responsesEndpointAlloc(alloc: Allocator, raw_base_url: []const u8) ![]u8 {
    const base_url = std.mem.trimEnd(u8, raw_base_url, "/");
    if (std.mem.endsWith(u8, base_url, "/responses")) {
        return alloc.dupe(u8, base_url);
    }
    return std.fmt.allocPrint(alloc, "{s}/responses", .{base_url});
}

fn buildRequestAlloc(
    alloc: Allocator,
    model: []const u8,
    request: web_search_contract.ProviderRequest,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"model\":");
    try std.json.Stringify.value(model, .{}, &out.writer);
    try out.writer.writeAll(",\"input\":");
    try std.json.Stringify.value(request.query, .{}, &out.writer);
    try out.writer.writeAll(",\"tools\":[{\"type\":\"web_search\"");
    if (hasValues(request.allowed_domains) or hasValues(request.blocked_domains)) {
        try out.writer.writeAll(",\"filters\":{");
        if (hasValues(request.allowed_domains)) {
            try out.writer.writeAll("\"allowed_domains\":");
            try std.json.Stringify.value(request.allowed_domains.?, .{}, &out.writer);
        } else {
            try out.writer.writeAll("\"excluded_domains\":");
            try std.json.Stringify.value(request.blocked_domains.?, .{}, &out.writer);
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("}],\"store\":false,\"max_output_tokens\":");
    try out.writer.print("{d}", .{request.max_output_tokens});
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

const Decoded = struct {
    content: []const web_search_contract.ResultItem,
    source_count: usize,

    fn takeContent(self: *Decoded) []const web_search_contract.ResultItem {
        const content = self.content;
        self.content = &.{};
        return content;
    }

    fn deinit(self: *Decoded, alloc: Allocator) void {
        for (self.content) |item| item.deinit(alloc);
        if (self.content.len > 0) alloc.free(self.content);
        self.* = .{ .content = &.{}, .source_count = 0 };
    }
};

fn decodeResponse(
    alloc: Allocator,
    body: []const u8,
    request: web_search_contract.ProviderRequest,
) !Decoded {
    var parsed = std.json.parseFromSlice(JsonValue, alloc, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConfiguredWebSearchResponse,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidConfiguredWebSearchResponse;
    const output = parsed.value.object.get("output") orelse
        return error.InvalidConfiguredWebSearchResponse;
    if (output != .array) return error.InvalidConfiguredWebSearchResponse;

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    var sources: std.ArrayList(web_search_contract.Source) = .empty;
    defer {
        for (sources.items) |source| source.deinit(alloc);
        sources.deinit(alloc);
    }
    for (output.array.items) |item| {
        if (item != .object or !jsonStringEquals(item.object.get("type"), "message")) continue;
        const content = item.object.get("content") orelse continue;
        if (content != .array) continue;
        for (content.array.items) |part| {
            if (part != .object or !jsonStringEquals(part.object.get("type"), "output_text")) continue;
            if (part.object.get("text")) |value| if (value == .string) {
                try appendBoundedText(alloc, &text, value.string, request.max_output_chars);
            };
            const annotations = part.object.get("annotations") orelse continue;
            if (annotations != .array) continue;
            for (annotations.array.items) |annotation| {
                if (sources.items.len >= @as(usize, request.max_results)) break;
                try appendCitation(alloc, &sources, annotation);
            }
        }
    }
    if (text.items.len == 0) {
        try text.appendSlice(alloc, "No search results found.");
    }

    var results: std.ArrayList(web_search_contract.ResultItem) = .empty;
    errdefer {
        for (results.items) |item| item.deinit(alloc);
        results.deinit(alloc);
    }
    const commentary = try text.toOwnedSlice(alloc);
    results.append(alloc, .{ .commentary = commentary }) catch |err| {
        alloc.free(commentary);
        return err;
    };
    const source_count = sources.items.len;
    if (sources.items.len > 0) {
        const owned_sources = try sources.toOwnedSlice(alloc);
        const search_id = try alloc.dupe(u8, request.request_id orelse "configured-responses-search");
        results.append(alloc, .{ .search = .{
            .tool_use_id = search_id,
            .content = owned_sources,
        } }) catch |err| {
            alloc.free(search_id);
            for (owned_sources) |source| source.deinit(alloc);
            alloc.free(owned_sources);
            return err;
        };
    }
    return .{
        .content = try results.toOwnedSlice(alloc),
        .source_count = source_count,
    };
}

fn appendBoundedText(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
    maximum: usize,
) !void {
    if (out.items.len >= maximum) return;
    if (out.items.len > 0) try out.append(alloc, '\n');
    const remaining = maximum - out.items.len;
    try out.appendSlice(alloc, text_utils.utf8PrefixByBytes(value, remaining));
}

fn appendCitation(
    alloc: Allocator,
    sources: *std.ArrayList(web_search_contract.Source),
    annotation: JsonValue,
) !void {
    if (annotation != .object or
        !jsonStringEquals(annotation.object.get("type"), "url_citation")) return;
    const url_value = annotation.object.get("url") orelse return;
    if (url_value != .string or !renderableUrl(url_value.string)) return;
    for (sources.items) |source| {
        if (std.mem.eql(u8, source.url, url_value.string)) return;
    }
    const title_value = annotation.object.get("title");
    const title = if (title_value) |value|
        if (value == .string and value.string.len > 0) value.string else url_value.string
    else
        url_value.string;
    const owned_url = try alloc.dupe(u8, url_value.string);
    errdefer alloc.free(owned_url);
    const owned_title = try alloc.dupe(u8, text_utils.utf8PrefixByBytes(title, 1024));
    errdefer alloc.free(owned_title);
    try sources.append(alloc, .{ .title = owned_title, .url = owned_url });
}

fn jsonStringEquals(value: ?JsonValue, expected: []const u8) bool {
    const actual = value orelse return false;
    return actual == .string and std.mem.eql(u8, actual.string, expected);
}

fn renderableUrl(url: []const u8) bool {
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

fn hasValues(values: ?[]const []const u8) bool {
    return if (values) |actual| actual.len > 0 else false;
}

fn reportProgress(
    callback: ?web_search_contract.ProgressFn,
    context: ?*anyopaque,
    progress: web_search_contract.Progress,
) !void {
    const active = callback orelse return;
    active(context orelse return error.MissingProgressContext, progress);
}

test "configured Responses search request follows Grok Build fallback shape" {
    var cancel = std.atomic.Value(bool).init(false);
    const request = web_search_contract.ProviderRequest{
        .backend = backend_id,
        .query = "latest Zig release",
        .blocked_domains = &.{"example.invalid"},
        .max_output_tokens = 2048,
        .cancel_flag = &cancel,
    };
    const body = try buildRequestAlloc(std.testing.allocator, "search-model", request);
    defer std.testing.allocator.free(body);
    var parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const tool = parsed.value.object.get("tools").?.array.items[0].object;
    try std.testing.expectEqualStrings("web_search", tool.get("type").?.string);
    try std.testing.expectEqualStrings(
        "example.invalid",
        tool.get("filters").?.object.get("excluded_domains").?.array.items[0].string,
    );
}

test "configured Responses search decodes bounded text and citations" {
    var cancel = std.atomic.Value(bool).init(false);
    const request = web_search_contract.ProviderRequest{
        .backend = backend_id,
        .query = "Zig",
        .request_id = "search_1",
        .max_results = 2,
        .max_output_chars = 128,
        .cancel_flag = &cancel,
    };
    var decoded = try decodeResponse(
        std.testing.allocator,
        "{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Zig news\",\"annotations\":[{\"type\":\"url_citation\",\"url\":\"https://ziglang.org/news\",\"title\":\"Zig News\"},{\"type\":\"url_citation\",\"url\":\"javascript:bad\",\"title\":\"bad\"}]}]}]}",
        request,
    );
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), decoded.source_count);
    try std.testing.expectEqualStrings("Zig news", decoded.content[0].commentary);
    try std.testing.expectEqualStrings(
        "https://ziglang.org/news",
        decoded.content[1].search.content[0].url,
    );
}
