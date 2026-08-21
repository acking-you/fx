const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const secret = @import("../core/auth/secret.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const provider_route = @import("../core/gateway/provider_route.zig");
const io_mod = @import("../core/shared/io.zig");
const builtin_gateway = @import("../builtins/gateway.zig");
const host_stream_provider = @import("host_stream_provider.zig");

const Allocator = std.mem.Allocator;
const max_response_bytes: usize = 4 * 1024 * 1024;

pub const ProviderContext = struct {
    transport: host_stream_provider.Transport,
    endpoint_overrides: ?provider_route.EndpointOverrides = null,
};

pub fn initContext(transport: host_stream_provider.Transport) ProviderContext {
    return .{ .transport = transport };
}

pub fn provider(context: *ProviderContext) model_catalog.Provider {
    return .{ .context = context, .fetch_fn = fetch };
}

pub fn cliProvider(context: *ProviderContext) gateway_provider.CliModelCatalogProvider {
    return .{ .context = context, .fetch_fn = fetchCli };
}

fn fetchCli(
    raw: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    const context: *ProviderContext = @ptrCast(@alignCast(raw.?));
    const result = model_catalog.fetchWithPublicFallback(provider(context), alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    });
    return switch (result) {
        .loaded => |loaded| project: {
            var catalog = loaded.catalog;
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .anonymous_fallback_used = loaded.provenance.anonymous_fallback_used,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :project .{ .loaded = .{
                .ids = ids,
                .provenance = loaded.provenance,
            } };
        },
        .failed => |failed| .{ .failure = failed },
    };
}

fn fetch(
    raw: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    const context: *ProviderContext = @ptrCast(@alignCast(raw.?));
    if (cancelled(input.cancel_flag)) return .{ .failure = .{ .category = .cancellation } };

    var plan = prepareRequest(
        alloc,
        input.access,
        input.endpoint,
        context.endpoint_overrides orelse provider_route.EndpointOverrides.fromEnvironment(),
    ) catch |err| return if (err == error.OutOfMemory)
        error.OutOfMemory
    else
        .{ .failure = .{ .category = .runtime } };
    defer plan.deinit(alloc);

    const Header = struct { name: []const u8, value: []const u8 };
    var headers: std.ArrayList(Header) = .empty;
    defer headers.deinit(alloc);
    const authorization = if (input.access.authorizationCredential()) |credential|
        try std.fmt.allocPrint(alloc, "Bearer {s}", .{credential})
    else
        null;
    defer if (authorization) |value| secret.zeroAndFree(alloc, value);
    if (authorization) |value| try headers.append(alloc, .{ .name = "authorization", .value = value });
    switch (plan.route) {
        .vercel_gateway => if (input.access.teamContext()) |team| {
            try headers.append(alloc, .{ .name = "x-vercel-ai-gateway-team", .value = team });
        },
        .openai_responses_byok => {
            try headers.append(alloc, .{ .name = "accept", .value = "application/json" });
            if (io_mod.getenv("OPENAI_ORG_ID")) |organization| {
                if (organization.len > 0) try headers.append(alloc, .{ .name = "OpenAI-Organization", .value = organization });
            }
            if (io_mod.getenv("OPENAI_PROJECT_ID")) |project| {
                if (project.len > 0) try headers.append(alloc, .{ .name = "OpenAI-Project", .value = project });
            }
        },
        .codex_responses_oauth => unreachable,
    }

    var headers_json: std.Io.Writer.Allocating = .init(alloc);
    defer headers_json.deinit();
    std.json.Stringify.value(headers.items, .{}, &headers_json.writer) catch return error.OutOfMemory;

    const handle = context.transport.open("GET", plan.url, headers_json.writer.buffered(), "") catch |err| {
        return if (err == error.OutOfMemory)
            error.OutOfMemory
        else if (err == error.Cancelled)
            .{ .failure = .{ .category = .cancellation } }
        else
            .{ .failure = .{ .category = .transport, .retryable = true } };
    };
    if (handle < 0) return .{ .failure = .{ .category = .transport, .retryable = true } };
    defer context.transport.close(handle);

    var status_code: u16 = 0;
    while (true) {
        if (cancelled(input.cancel_flag)) return .{ .failure = .{ .category = .cancellation } };
        const status_result = context.transport.status(handle, &status_code);
        if (status_result == 1) break;
        if (status_result == -2) return .{ .failure = .{ .category = .cancellation } };
        if (status_result < 0) return .{ .failure = .{ .category = .transport, .retryable = true } };
    }

    const status: std.http.Status = @enumFromInt(status_code);
    if (status != .ok) return .{ .failure = model_catalog.failureForHttpStatus(status) };

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        if (cancelled(input.cancel_flag)) return .{ .failure = .{ .category = .cancellation } };
        const count = context.transport.next(handle, &chunk);
        if (count == -3) continue;
        if (count == -2) return .{ .failure = .{ .category = .cancellation } };
        if (count < 0) return .{ .failure = .{ .category = .transport, .retryable = true } };
        if (count == 0) break;
        const len: usize = @intCast(count);
        if (len > max_response_bytes - body.items.len) {
            return .{ .failure = .{ .category = .resource_exhausted } };
        }
        try body.appendSlice(alloc, chunk[0..len]);
    }

    const catalog = builtin_gateway.parseModelCatalogForProvider(
        alloc,
        body.items,
        input.view,
        plan.route.contract().catalog,
    ) catch |err| return .{ .failure = .{
        .category = if (err == error.OutOfMemory) .resource_exhausted else .malformed_response,
        .http_status = .ok,
    } };
    return .{ .catalog = catalog };
}

fn cancelled(cancel_flag: ?*std.atomic.Value(bool)) bool {
    const flag = cancel_flag orelse return false;
    return flag.load(.seq_cst);
}

const RequestPlan = struct {
    route: provider_route.ProviderRoute,
    url: []u8,

    fn deinit(self: *RequestPlan, alloc: Allocator) void {
        alloc.free(self.url);
        self.* = undefined;
    }
};

fn prepareRequest(
    alloc: Allocator,
    access: credentials.CatalogAccess,
    endpoint: []const u8,
    endpoint_overrides: provider_route.EndpointOverrides,
) !RequestPlan {
    const route = if (access.credentialSource()) |source|
        provider_route.fromCredentialSource(source) orelse return error.UnsupportedCredentialSource
    else
        provider_route.ProviderRoute.vercel_gateway;
    const url = switch (route) {
        .vercel_gateway => try std.fmt.allocPrint(alloc, "{s}{s}", .{
            builtin_gateway.default_model_catalog_base_url,
            endpoint,
        }),
        .openai_responses_byok => direct: {
            const base_url = try provider_route.resolveBaseUrlAlloc(alloc, route, endpoint_overrides);
            defer alloc.free(base_url);
            break :direct try provider_route.appendModelsEndpointAlloc(alloc, base_url);
        },
        .codex_responses_oauth => return error.CodexCredentialUnavailable,
    };
    return .{ .route = route, .url = url };
}

const CatalogFixture = struct {
    open_calls: usize = 0,
    status_code: u16 = 200,
    body: []const u8 = "{\"object\":\"list\",\"data\":[{\"id\":\"gpt-5.4\",\"object\":\"model\",\"created\":7}]}",
    offset: usize = 0,
    url_buf: [1024]u8 = undefined,
    url_len: usize = 0,
    headers_buf: [4096]u8 = undefined,
    headers_len: usize = 0,

    fn transport(self: *@This()) host_stream_provider.Transport {
        return .{
            .context = self,
            .open_fn = open,
            .status_fn = status,
            .next_fn = next,
            .close_fn = close,
        };
    }

    fn open(raw: ?*anyopaque, method: []const u8, request_url: []const u8, request_headers: []const u8, body: []const u8) anyerror!i32 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.open_calls += 1;
        if (!std.mem.eql(u8, method, "GET") or body.len != 0) return error.InvalidCatalogRequest;
        if (request_url.len > self.url_buf.len or request_headers.len > self.headers_buf.len) return error.TestCaptureTooSmall;
        @memcpy(self.url_buf[0..request_url.len], request_url);
        self.url_len = request_url.len;
        @memcpy(self.headers_buf[0..request_headers.len], request_headers);
        self.headers_len = request_headers.len;
        return 1;
    }

    fn status(raw: ?*anyopaque, _: i32, status_out: *u16) i32 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        status_out.* = self.status_code;
        return 1;
    }

    fn next(raw: ?*anyopaque, _: i32, out: []u8) i32 {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        const len = @min(out.len, self.body.len - self.offset);
        if (len == 0) return 0;
        @memcpy(out[0..len], self.body[self.offset..][0..len]);
        self.offset += len;
        return @intCast(len);
    }

    fn close(_: ?*anyopaque, _: i32) void {}

    fn url(self: *const @This()) []const u8 {
        return self.url_buf[0..self.url_len];
    }

    fn headers(self: *const @This()) []const u8 {
        return self.headers_buf[0..self.headers_len];
    }
};

test "host catalog scopes OpenAI credentials to its models endpoint and parser" {
    var fixture: CatalogFixture = .{};
    var context = ProviderContext{
        .transport = fixture.transport(),
        .endpoint_overrides = .{ .responses_base_url = "http://127.0.0.1:43123/v1/responses" },
    };
    const access = credentials.catalogAccessForCredential(.openai_api_key, "openai-secret", "must-not-cross-provider");
    const result = try provider(&context).fetch(std.testing.allocator, .{
        .access = access,
        .endpoint = "/v1/models",
    });
    var catalog = switch (result) {
        .catalog => |value| value,
        .failure => return error.TestExpectedCatalog,
    };
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);

    try std.testing.expectEqual(@as(usize, 1), fixture.open_calls);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/v1/models", fixture.url());
    try std.testing.expect(std.mem.find(u8, fixture.headers(), "Bearer openai-secret") != null);
    try std.testing.expect(std.mem.find(u8, fixture.headers(), "must-not-cross-provider") == null);
    try std.testing.expect(std.mem.find(u8, fixture.headers(), "x-vercel-ai-gateway-team") == null);
    try std.testing.expectEqual(@as(usize, 1), catalog.items.len);
    try std.testing.expectEqualStrings("gpt-5.4", catalog.items[0].id);
}

test "host catalog rejects Codex OAuth before opening its transport" {
    var fixture: CatalogFixture = .{};
    var context = initContext(fixture.transport());
    const result = try provider(&context).fetch(std.testing.allocator, .{
        .access = credentials.catalogAccessForCredential(.codex_oauth, "codex-secret-must-not-leave", null),
        .endpoint = "/v1/models",
    });
    switch (result) {
        .failure => |failure| try std.testing.expectEqual(model_catalog.FailureCategory.runtime, failure.category),
        .catalog => |catalog| {
            var owned = catalog;
            model_catalog.freeModelCatalog(std.testing.allocator, &owned);
            return error.TestExpectedFailure;
        },
    }
    try std.testing.expectEqual(@as(usize, 0), fixture.open_calls);
}
