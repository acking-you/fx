const std = @import("std");

const collections = @import("../core/shared/collections.zig");
const credentials = @import("../core/auth/credentials.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const provider_catalog = @import("../core/auth/provider_catalog.zig");
const provider_route = @import("../core/gateway/provider_route.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const oauth_http_transport = @import("oauth_http_transport.zig");
const http_client = @import("../gateway/client.zig");
const openai_models = @import("../gateway/openai_models.zig");
const openai_responses = @import("../gateway/openai_responses.zig");
const openai_responses_permission_reviewer = @import("../gateway/openai_responses_permission_reviewer.zig");

const Allocator = std.mem.Allocator;

pub const default_model = provider_route.openai_default_model;
pub const default_chat_url = provider_route.openai_responses_endpoint;
pub const models_path = "/models";
pub const retry_count: usize = 3;

pub const agent_stream_provider = openai_responses.agent_stream_provider;
pub const permission_reviewer = openai_responses_permission_reviewer;

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchModelCatalog,
};

pub const provider_bundle = provider_set.Bundle{
    .presentation = provider_catalog.find(.gateway),
    .auth_strategy = .api_key,
    .fallback_model_capabilities_fn = model_capabilities.capabilitiesForModel,
    .agent_stream = agent_stream_provider,
    .cli_model_catalog = cli_model_catalog_provider,
    .model_catalog = model_catalog_provider,
    .responses_compaction = openai_responses.compaction_provider,
    .permission_reviewer = permission_reviewer.provider,
};

pub const oauth_transport_provider = oauth_http_transport.provider;

pub const chat_url_provider = gateway_provider.ChatUrlProvider{
    .resolve_fn = resolveChatUrl,
};

pub const provider = gateway_provider.Provider{
    .oauth_transport = oauth_transport_provider,
    .chat_url = chat_url_provider,
};

pub fn defaultChatUrl() []const u8 {
    return default_chat_url;
}

fn resolveChatUrl(_: ?*anyopaque, _: []const u8) []const u8 {
    return default_chat_url;
}

pub fn buildAgentRequest(
    alloc: Allocator,
    request: @import("../core/agent/stream_provider.zig").RequestData,
) ![]u8 {
    return openai_responses.buildRequest(alloc, request);
}

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    const result = model_catalog.fetchCatalog(model_catalog_provider, alloc, .{
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

fn fetchModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    if (input.cancel_flag) |flag| {
        if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    }
    if (input.access.credentialSource() != .openai_api_key) {
        return .{ .failure = model_catalog.failureForHttpStatus(.unauthorized) };
    }
    const api_key = input.access.authorizationCredential() orelse
        return .{ .failure = model_catalog.failureForHttpStatus(.unauthorized) };

    const endpoint = (if (std.mem.startsWith(u8, input.endpoint, "https://") or
        std.mem.startsWith(u8, input.endpoint, "http://"))
        provider_route.appendModelsEndpointAlloc(alloc, input.endpoint)
    else endpoint: {
        const base_url = provider_route.resolveBaseUrlAlloc(
            alloc,
            .openai_responses_byok,
            provider_route.EndpointOverrides.fromEnvironment(),
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .failure = .{ .category = .transport } };
        };
        defer alloc.free(base_url);
        break :endpoint provider_route.appendModelsEndpointAlloc(alloc, base_url);
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .transport } };
    };
    defer alloc.free(endpoint);

    const response = if (input.cancel_flag) |flag|
        http_client.fetchProviderJsonCancellable(alloc, .openai_api_key, api_key, endpoint, flag)
    else
        http_client.fetchProviderJson(alloc, .openai_api_key, api_key, endpoint);
    const fetched = response catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{
            .category = if (err == error.Cancelled) .cancellation else .transport,
            .retryable = err != error.Cancelled and http_client.isRetryableGatewayError(err),
        } };
    };
    const json_text = switch (fetched) {
        .success => |body| body,
        .http_status => |status| return .{ .failure = model_catalog.failureForHttpStatus(status) },
    };
    defer alloc.free(json_text);

    const catalog = openai_models.parse(alloc, json_text, input.view) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{ .category = .malformed_response, .http_status = .ok } };
    };
    return .{ .catalog = catalog };
}

test "Responses bundle exposes only the BYOK API-key route" {
    try std.testing.expectEqual(provider_set.Bundle.AuthStrategy.api_key, provider_bundle.auth_strategy.?);
    try std.testing.expect(provider_bundle.fx_search == null);
    try std.testing.expect(agent_stream_provider.stream_fn == openai_responses.agent_stream_provider.stream_fn);
}

test "CLI catalog rejects non-BYOK credentials" {
    const result = cli_model_catalog_provider.fetch(std.testing.allocator, .{
        .access = credentials.catalogAccessForCredential(.chatgpt_subscription, "token"),
        .endpoint = models_path,
    });
    switch (result) {
        .failure => |failure| try std.testing.expectEqual(
            model_catalog.FailureCategory.authentication,
            failure.failure.category,
        ),
        .loaded => |loaded| {
            var ids = loaded.ids;
            collections.freeStringList(std.testing.allocator, &ids);
            return error.TestExpectedEqual;
        },
    }
}
