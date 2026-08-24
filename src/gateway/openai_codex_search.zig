const std = @import("std");
const responses_search = @import("../core/gateway/responses_search.zig");
const provider_route = @import("../core/gateway/provider_route.zig");
const io_mod = @import("../core/shared/io.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const web_search_contract = @import("../core/tooling/web_search_contract.zig");
const web_search_policy = @import("../core/tooling/web_search_policy.zig");
const web_search_provider = @import("../core/tooling/web_search_provider.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;
const Request = web_search_contract.ProviderRequest;
const Response = web_search_contract.ProviderResponse;
const ProgressFn = web_search_contract.ProgressFn;

const backend_id = web_search_contract.SearchBackendId{ .value = "codex_standalone_search" };
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
    .preferred_backends_fn = preferredBackends,
    .execute_fn = execute,
};

fn preferredBackends(_: ?*anyopaque) !?[]const web_search_contract.SearchBackendId {
    return &preferred_backends;
}

fn execute(
    _: ?*anyopaque,
    alloc: Allocator,
    inputs: web_search_provider.Inputs,
    request: Request,
    on_progress: ?ProgressFn,
    progress_ctx: ?*anyopaque,
) !Response {
    if (!request.backend.eql(backend_id)) return error.InvalidWebSearchBackend;
    if (inputs.credential_source != .chatgpt_subscription) {
        return error.InvalidWebSearchCredential;
    }
    if (inputs.api_key.len == 0) return error.MissingWebSearchCredential;
    const account_id = inputs.account_id orelse return error.MissingWebSearchAccountId;
    if (account_id.len == 0) return error.MissingWebSearchAccountId;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    try reportProgress(on_progress, progress_ctx, .{ .query_update = request.query });

    const endpoint = try provider_route.resolveSearchEndpointFromEnvironmentAlloc(
        alloc,
        .codex_responses_oauth,
    );
    defer alloc.free(endpoint);
    const commands = if (request.commands_json) |raw|
        try alloc.dupe(u8, raw)
    else
        try buildCommandsAlloc(alloc, request);
    defer alloc.free(commands);
    const settings = try buildSettingsAlloc(alloc, request);
    defer alloc.free(settings);
    const payload = try responses_search.buildRequest(alloc, .{
        .id = request.request_id orelse "fx_web_search",
        .model = provider_route.wireModel(.codex_responses_oauth, inputs.worker_model),
        .input_json = request.input_json,
        .commands_json = commands,
        .settings_json = settings,
        .max_output_tokens = request.max_output_tokens,
    });
    defer alloc.free(payload);

    var result = try gateway_client.fetchCodexJsonBounded(alloc, .{
        .method = .post_json,
        .url = endpoint,
        .access_token = inputs.api_key,
        .account_id = account_id,
        .payload = payload,
        .cancel_flag = @constCast(request.cancel_flag),
        .deadline = deadlineAfterMs(request.timeout_ms),
        .max_response_bytes = 512 * 1024,
    });
    defer result.deinit(alloc);
    if (result.status.class() != .success) return error.CodexSearchRequestFailed;

    var decoded = try responses_search.decodeResponse(alloc, result.body);
    defer decoded.deinit();
    const content = try materializeContent(
        alloc,
        decoded,
        request.request_id orelse "codex-search",
        request.max_results,
        request.max_output_chars,
    );
    errdefer {
        for (content) |item| item.deinit(alloc);
        alloc.free(content);
    }
    try reportProgress(on_progress, progress_ctx, .{ .results_received = .{
        .query = request.query,
        .result_count = if (decoded.results) |items| items.len else 0,
    } });
    return .{
        .content = content,
        .stop_reason = try alloc.dupe(u8, "stop"),
        .usage = .{ .web_search_requests = 1 },
    };
}

fn reportProgress(
    callback: ?ProgressFn,
    context: ?*anyopaque,
    progress: web_search_contract.Progress,
) !void {
    const active = callback orelse return;
    active(context orelse return error.MissingProgressContext, progress);
}

fn deadlineAfterMs(timeout_ms: u32) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(timeout_ms),
    });
}

const max_sources: usize = 64;
const max_title_bytes: usize = 1024;

fn materializeContent(
    alloc: Allocator,
    decoded: responses_search.DecodedResponse,
    search_id: []const u8,
    max_results: u8,
    max_output_chars: usize,
) ![]const web_search_contract.ResultItem {
    var content: std.ArrayList(web_search_contract.ResultItem) = .empty;
    errdefer {
        for (content.items) |item| item.deinit(alloc);
        content.deinit(alloc);
    }
    const commentary = try alloc.dupe(
        u8,
        text_utils.utf8PrefixByBytes(decoded.output, max_output_chars),
    );
    content.append(alloc, .{ .commentary = commentary }) catch |err| {
        alloc.free(commentary);
        return err;
    };

    var source_count: usize = 0;
    const source_limit = @min(max_sources, @as(usize, max_results));
    for (decoded.results orelse &.{}) |result| {
        if (source_count >= source_limit) break;
        const projected = responses_search.resultSource(result) orelse continue;
        var item = try materializeSource(alloc, projected, search_id);
        content.append(alloc, item) catch |err| {
            item.deinit(alloc);
            return err;
        };
        source_count += 1;
    }
    return content.toOwnedSlice(alloc);
}

fn materializeSource(
    alloc: Allocator,
    projected: responses_search.ResultSource,
    search_id: []const u8,
) !web_search_contract.ResultItem {
    const raw_title = projected.title orelse projected.url;
    const title = text_utils.utf8PrefixByBytes(raw_title, max_title_bytes);
    const owned_url = try alloc.dupe(u8, projected.url);
    errdefer alloc.free(owned_url);
    const owned_title = try alloc.dupe(u8, if (title.len > 0) title else projected.url);
    errdefer alloc.free(owned_title);
    const sources = try alloc.alloc(web_search_contract.Source, 1);
    errdefer alloc.free(sources);
    sources[0] = .{ .title = owned_title, .url = owned_url };
    return .{ .search = .{
        .tool_use_id = try alloc.dupe(u8, projected.ref_id orelse search_id),
        .content = sources,
    } };
}

fn buildCommandsAlloc(alloc: Allocator, request: Request) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"search_query\":[{\"q\":");
    try std.json.Stringify.value(request.query, .{}, &out.writer);
    if (hasValues(request.allowed_domains)) {
        try out.writer.writeAll(",\"domains\":");
        try std.json.Stringify.value(request.allowed_domains.?, .{}, &out.writer);
    }
    try out.writer.writeAll("}]}");
    return out.toOwnedSlice();
}

fn buildSettingsAlloc(alloc: Allocator, request: Request) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"allowed_callers\":[\"direct\"],\"external_web_access\":true");
    if (hasValues(request.allowed_domains) or hasValues(request.blocked_domains)) {
        try out.writer.writeAll(",\"filters\":{");
        if (hasValues(request.allowed_domains)) {
            try out.writer.writeAll("\"allowed_domains\":");
            try std.json.Stringify.value(request.allowed_domains.?, .{}, &out.writer);
        } else {
            try out.writer.writeAll("\"blocked_domains\":");
            try std.json.Stringify.value(request.blocked_domains.?, .{}, &out.writer);
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn hasValues(values: ?[]const []const u8) bool {
    return if (values) |actual| actual.len > 0 else false;
}

test "Codex search policy admits one standalone backend" {
    try std.testing.expect(web_search_policy.hasAdmittedBackendPolicy(provider.policy.backend_policies));
    try std.testing.expectEqual(@as(usize, 1), provider.policy.preferred_backends.len);
    try std.testing.expect(backend_id.eql(provider.policy.preferred_backends[0]));
}

test "Codex search rejects missing account identity before transport" {
    var cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(error.MissingWebSearchAccountId, provider.execute(
        std.testing.allocator,
        .{
            .api_key = "access",
            .credential_source = .chatgpt_subscription,
            .worker_model = "gpt-5.6-sol",
            .gateway_retry_count = 1,
            .gateway_chat_url = "unused",
        },
        .{ .backend = backend_id, .query = "Zig", .cancel_flag = &cancel },
        null,
        null,
    ));
}

test "Codex search materializes bounded structured citations" {
    const alloc = std.testing.allocator;
    var decoded = try responses_search.decodeResponse(
        alloc,
        "{\"output\":\"Search answer\",\"results\":[{\"ref_id\":\"turn0search0\",\"title\":\"Primary source\",\"url\":\"https://example.com/source\"},{\"title\":\"Unsafe\",\"url\":\"javascript:alert(1)\"}]}",
    );
    defer decoded.deinit();
    const content = try materializeContent(alloc, decoded, "session-search", 10, 100_000);
    defer {
        for (content) |item| item.deinit(alloc);
        alloc.free(content);
    }

    try std.testing.expectEqual(@as(usize, 2), content.len);
    try std.testing.expectEqualStrings("Search answer", content[0].commentary);
    try std.testing.expectEqualStrings("turn0search0", content[1].search.tool_use_id);
    try std.testing.expectEqualStrings("Primary source", content[1].search.content[0].title);
}

test "Codex search post-filters commentary and source bounds" {
    const alloc = std.testing.allocator;
    var decoded = try responses_search.decodeResponse(
        alloc,
        "{\"output\":\"bounded answer\",\"results\":[{\"title\":\"One\",\"url\":\"https://example.com/one\"},{\"title\":\"Two\",\"url\":\"https://example.com/two\"}]}",
    );
    defer decoded.deinit();
    const content = try materializeContent(alloc, decoded, "session-search", 1, 7);
    defer {
        for (content) |item| item.deinit(alloc);
        alloc.free(content);
    }

    try std.testing.expectEqual(@as(usize, 2), content.len);
    try std.testing.expectEqualStrings("bounded", content[0].commentary);
    try std.testing.expectEqual(@as(usize, 1), content[1].search.content.len);
    try std.testing.expectEqualStrings("One", content[1].search.content[0].title);
}

fn checkMaterializationAllocationFailures(alloc: Allocator) !void {
    var decoded = try responses_search.decodeResponse(
        alloc,
        "{\"output\":\"Search answer\",\"results\":[{\"ref_id\":\"turn0search0\",\"title\":\"Primary\",\"url\":\"https://example.com/one\"}]}",
    );
    defer decoded.deinit();
    const content = try materializeContent(alloc, decoded, "session-search", 10, 100_000);
    defer {
        for (content) |item| item.deinit(alloc);
        alloc.free(content);
    }
}

test "Codex search result ownership survives allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkMaterializationAllocationFailures,
        .{},
    );
}
