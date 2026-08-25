const std = @import("std");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const openai_base_url = "https://api.openai.com/v1";
pub const openai_responses_endpoint = openai_base_url ++ "/responses";
pub const openai_responses_compact_endpoint = openai_responses_endpoint ++ "/compact";
pub const codex_base_url = "https://chatgpt.com/backend-api/codex";
pub const codex_responses_endpoint = codex_base_url ++ "/responses";
pub const codex_responses_compact_endpoint = codex_responses_endpoint ++ "/compact";
pub const codex_search_endpoint = codex_base_url ++ "/alpha/search";

pub const openai_default_model = "gpt-5.4";
pub const codex_default_model = "gpt-5.6-sol";

const openai_model_prefix = "openai/";

pub const openai_base_url_env = "OPENAI_BASE_URL";
pub const responses_base_url_env = "FX_RESPONSES_BASE_URL";
pub const codex_base_url_env = "FX_CODEX_BASE_URL";

pub const WireApi = enum {
    openai_responses,
};

pub const AccountHeader = enum {
    none,
    chatgpt_account_id,

    pub fn name(self: AccountHeader) ?[]const u8 {
        return switch (self) {
            .none => null,
            .chatgpt_account_id => "ChatGPT-Account-ID",
        };
    }
};

/// Describes only headers whose availability differs by provider route.
/// Content-Type, Accept, User-Agent, and bearer authorization are common to
/// every current route and remain transport concerns.
pub const HeaderCapabilities = struct {
    account_header: AccountHeader = .none,
    openai_organization: bool = false,
    openai_project: bool = false,
    originator: bool = false,
};

pub const DirectUsage = enum {
    /// Usage is authoritative in the terminal Responses event.
    response_body,
};

pub const CatalogKind = enum {
    openai_models,
    codex_builtin,
};

/// Remote context-compaction protocols supported by a provider route. V2 is a
/// strict superset: it supports both `/responses/compact` and the streamed
/// `compaction_trigger` input item.
pub const RemoteCompactionSupport = enum {
    unsupported,
    v1,
    v2,
};

pub const ProviderContract = struct {
    wire_api: WireApi,
    headers: HeaderCapabilities,
    usage: DirectUsage,
    catalog: CatalogKind,
    supports_max_output_tokens: bool,
    supports_catalog: bool,
    remote_compaction: RemoteCompactionSupport,
};

pub const ProviderRoute = enum {
    openai_responses_byok,
    codex_responses_oauth,

    pub fn contract(self: ProviderRoute) ProviderContract {
        return switch (self) {
            .openai_responses_byok => .{
                .wire_api = .openai_responses,
                .headers = .{
                    .openai_organization = true,
                    .openai_project = true,
                },
                .usage = .response_body,
                .catalog = .openai_models,
                .supports_max_output_tokens = true,
                .supports_catalog = true,
                .remote_compaction = .v2,
            },
            .codex_responses_oauth => .{
                .wire_api = .openai_responses,
                .headers = .{
                    .account_header = .chatgpt_account_id,
                    .originator = true,
                },
                .usage = .response_body,
                .catalog = .codex_builtin,
                // The ChatGPT Codex endpoint currently rejects this field.
                .supports_max_output_tokens = false,
                .supports_catalog = true,
                .remote_compaction = .v2,
            },
        };
    }

    pub fn defaultBaseUrl(self: ProviderRoute) []const u8 {
        return switch (self) {
            .openai_responses_byok => openai_base_url,
            .codex_responses_oauth => codex_base_url,
        };
    }

    pub fn defaultEndpoint(self: ProviderRoute) []const u8 {
        return switch (self) {
            .openai_responses_byok => openai_responses_endpoint,
            .codex_responses_oauth => codex_responses_endpoint,
        };
    }

    pub fn defaultCompactEndpoint(self: ProviderRoute) ?[]const u8 {
        return switch (self) {
            .openai_responses_byok => openai_responses_compact_endpoint,
            .codex_responses_oauth => codex_responses_compact_endpoint,
        };
    }

    pub fn defaultSearchEndpoint(self: ProviderRoute) ?[]const u8 {
        return switch (self) {
            .openai_responses_byok => null,
            .codex_responses_oauth => codex_search_endpoint,
        };
    }
};

/// The exhaustive switch deliberately makes a new credential source fail to
/// compile until its provider route is assigned here.
pub fn fromCredentialSource(source: types.CredentialSource) ?ProviderRoute {
    return switch (source) {
        .openai_api_key => .openai_responses_byok,
        .chatgpt_subscription => .codex_responses_oauth,
        .grok_subscription => null,
    };
}

/// Projects an Fx catalog model ID to the ID sent on the selected wire API.
/// Returned slices borrow `model` unless a route default is returned.
pub fn wireModel(route: ProviderRoute, model: []const u8) []const u8 {
    const has_openai_prefix = std.mem.startsWith(u8, model, openai_model_prefix);
    const responses_model = if (has_openai_prefix)
        model[openai_model_prefix.len..]
    else
        model;
    return switch (route) {
        .openai_responses_byok => responses_model,
        .codex_responses_oauth => if (has_openai_prefix and isKnownCodexModelAlias(responses_model))
            responses_model
        else
            model,
    };
}

fn isKnownCodexModelAlias(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "gpt-") or
        std.mem.startsWith(u8, model, "codex-") or
        std.mem.startsWith(u8, model, "chatgpt-") or
        (model.len >= 2 and model[0] == 'o' and std.ascii.isDigit(model[1]));
}

pub fn wireModelForCredentialSource(
    source: types.CredentialSource,
    model: []const u8,
) []const u8 {
    return wireModel(fromCredentialSource(source) orelse unreachable, model);
}

/// Returns the route-native replacement for a model that is only one of Fx's
/// known route defaults. Arbitrary user-selected model IDs are deliberately
/// left untouched, and an explicit process override always wins.
pub fn reconciledDefaultModel(
    source: types.CredentialSource,
    model: []const u8,
    has_process_override: bool,
) ?[]const u8 {
    if (has_process_override or !isKnownDefaultModel(model)) return null;

    const target = switch (fromCredentialSource(source) orelse return null) {
        .openai_responses_byok => openai_default_model,
        .codex_responses_oauth => codex_default_model,
    };
    if (std.mem.eql(u8, model, target)) return null;
    return target;
}

fn isKnownDefaultModel(model: []const u8) bool {
    const responses_model = if (std.mem.startsWith(u8, model, openai_model_prefix))
        model[openai_model_prefix.len..]
    else
        model;
    return std.mem.eql(u8, responses_model, openai_default_model) or
        std.mem.eql(u8, responses_model, codex_default_model);
}

pub const EndpointOverrides = struct {
    /// Fx-specific OpenAI-compatible base URL. Takes precedence over
    /// `openai_base_url` when both are present.
    responses_base_url: ?[]const u8 = null,
    openai_base_url: ?[]const u8 = null,
    /// Explicit Codex override. Generic Responses overrides never redirect an
    /// OAuth credential away from the default ChatGPT Codex origin.
    codex_base_url: ?[]const u8 = null,

    pub fn fromEnvironment() EndpointOverrides {
        return .{
            .responses_base_url = io_mod.getenv(responses_base_url_env),
            .openai_base_url = io_mod.getenv(openai_base_url_env),
            .codex_base_url = io_mod.getenv(codex_base_url_env),
        };
    }
};

pub const ResolveEndpointError = Allocator.Error || error{
    InvalidBaseUrl,
    BaseUrlContainsUserInfo,
    BaseUrlContainsQueryOrFragment,
    InsecureBaseUrl,
};

pub const ResolveCompactEndpointError = ResolveEndpointError || error{
    UnsupportedProviderRoute,
};

pub const ResolveSearchEndpointError = ResolveEndpointError || error{
    UnsupportedProviderRoute,
};

/// Resolves an owned request endpoint. Responses overrides are base URLs, so
/// this function normalizes the trailing slash and appends `/responses`.
pub fn resolveEndpointAlloc(
    alloc: Allocator,
    route: ProviderRoute,
    overrides: EndpointOverrides,
) ResolveEndpointError![]u8 {
    const base_url = try resolveBaseUrlAlloc(alloc, route, overrides);
    defer alloc.free(base_url);
    return appendResponsesEndpointAlloc(alloc, base_url);
}

/// Resolves the dedicated compact endpoint for direct Responses routes. The
/// same scoped base-URL and origin validation used by ordinary Responses
/// transport applies here; subscription providers have their own endpoints.
pub fn resolveCompactEndpointAlloc(
    alloc: Allocator,
    route: ProviderRoute,
    overrides: EndpointOverrides,
) ResolveCompactEndpointError![]u8 {
    if (route.contract().remote_compaction == .unsupported) {
        return error.UnsupportedProviderRoute;
    }
    const base_url = try resolveBaseUrlAlloc(alloc, route, overrides);
    defer alloc.free(base_url);
    return appendResponsesCompactEndpointAlloc(alloc, base_url);
}

/// Resolves Codex's namespaced web-search endpoint from the same validated,
/// OAuth-pinned base used by Responses. Other provider routes intentionally do
/// not inherit a Codex-private endpoint shape.
pub fn resolveSearchEndpointAlloc(
    alloc: Allocator,
    route: ProviderRoute,
    overrides: EndpointOverrides,
) ResolveSearchEndpointError![]u8 {
    if (route != .codex_responses_oauth) return error.UnsupportedProviderRoute;
    const base_url = try resolveBaseUrlAlloc(alloc, route, overrides);
    defer alloc.free(base_url);
    return appendCodexSearchEndpointAlloc(alloc, base_url);
}

/// Resolves the normalized, owned base URL separately so model catalog and
/// other provider endpoints do not have to strip `/responses` back off.
pub fn resolveBaseUrlAlloc(
    alloc: Allocator,
    route: ProviderRoute,
    overrides: EndpointOverrides,
) ResolveEndpointError![]u8 {
    const base_url = switch (route) {
        .openai_responses_byok => overrides.responses_base_url orelse
            overrides.openai_base_url orelse
            openai_base_url,
        .codex_responses_oauth => overrides.codex_base_url orelse codex_base_url,
    };
    try validateBaseUrl(base_url);
    return alloc.dupe(u8, std.mem.trimEnd(u8, base_url, "/"));
}

pub fn resolveEndpointFromEnvironmentAlloc(
    alloc: Allocator,
    route: ProviderRoute,
) ResolveEndpointError![]u8 {
    return resolveEndpointAlloc(alloc, route, EndpointOverrides.fromEnvironment());
}

pub fn resolveCompactEndpointFromEnvironmentAlloc(
    alloc: Allocator,
    route: ProviderRoute,
) ResolveCompactEndpointError![]u8 {
    return resolveCompactEndpointAlloc(alloc, route, EndpointOverrides.fromEnvironment());
}

pub fn resolveSearchEndpointFromEnvironmentAlloc(
    alloc: Allocator,
    route: ProviderRoute,
) ResolveSearchEndpointError![]u8 {
    return resolveSearchEndpointAlloc(alloc, route, EndpointOverrides.fromEnvironment());
}

pub fn appendResponsesEndpointAlloc(
    alloc: Allocator,
    base_url: []const u8,
) ResolveEndpointError![]u8 {
    try validateBaseUrl(base_url);

    const normalized = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, normalized, "/responses")) {
        return alloc.dupe(u8, normalized);
    }
    return std.fmt.allocPrint(alloc, "{s}/responses", .{normalized});
}

/// Normalizes an API root, `/responses`, or `/responses/compact` URL to the
/// dedicated compact endpoint without duplicating path components.
pub fn appendResponsesCompactEndpointAlloc(
    alloc: Allocator,
    base_url: []const u8,
) ResolveEndpointError![]u8 {
    try validateBaseUrl(base_url);

    const normalized = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, normalized, "/responses/compact")) {
        return alloc.dupe(u8, normalized);
    }
    if (std.mem.endsWith(u8, normalized, "/responses")) {
        return std.fmt.allocPrint(alloc, "{s}/compact", .{normalized});
    }
    return std.fmt.allocPrint(alloc, "{s}/responses/compact", .{normalized});
}

/// Normalizes a Codex API root or one of its Responses endpoints to
/// `/alpha/search`. Validation runs before any suffix manipulation.
pub fn appendCodexSearchEndpointAlloc(
    alloc: Allocator,
    base_url: []const u8,
) ResolveEndpointError![]u8 {
    try validateBaseUrl(base_url);

    var normalized = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, normalized, "/alpha/search")) {
        return alloc.dupe(u8, normalized);
    }
    if (std.mem.endsWith(u8, normalized, "/responses/compact")) {
        normalized = std.mem.trimEnd(u8, normalized[0 .. normalized.len - "/responses/compact".len], "/");
    } else if (std.mem.endsWith(u8, normalized, "/responses")) {
        normalized = std.mem.trimEnd(u8, normalized[0 .. normalized.len - "/responses".len], "/");
    }
    return std.fmt.allocPrint(alloc, "{s}/alpha/search", .{normalized});
}

/// Resolves the model-catalog endpoint belonging to a Responses base URL.
/// Callers may provide either the API root, `/responses`, or `/models`; the
/// returned URL is always normalized to the provider's `/models` endpoint.
pub fn appendModelsEndpointAlloc(
    alloc: Allocator,
    base_url: []const u8,
) ResolveEndpointError![]u8 {
    try validateBaseUrl(base_url);

    var normalized = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.endsWith(u8, normalized, "/responses")) {
        normalized = std.mem.trimEnd(u8, normalized[0 .. normalized.len - "/responses".len], "/");
    }
    if (std.mem.endsWith(u8, normalized, "/models")) {
        return alloc.dupe(u8, normalized);
    }
    return std.fmt.allocPrint(alloc, "{s}/models", .{normalized});
}

pub fn validateBaseUrl(base_url: []const u8) ResolveEndpointError!void {
    if (base_url.len == 0) return error.InvalidBaseUrl;
    for (base_url) |byte| {
        if (std.ascii.isWhitespace(byte) or std.ascii.isControl(byte)) {
            return error.InvalidBaseUrl;
        }
    }

    const uri = std.Uri.parse(base_url) catch return error.InvalidBaseUrl;
    if (uri.user != null or uri.password != null) return error.BaseUrlContainsUserInfo;
    if (uri.query != null or uri.fragment != null) return error.BaseUrlContainsQueryOrFragment;

    const host_component = uri.host orelse return error.InvalidBaseUrl;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buffer) catch return error.InvalidBaseUrl;
    if (host.len == 0) return error.InvalidBaseUrl;

    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or uri.port == null) {
        return error.InsecureBaseUrl;
    }
    if (!isLoopbackHost(host)) return error.InsecureBaseUrl;
}

fn isLoopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]") or
        std.mem.eql(u8, host, "::1");
}

test "credential sources map to one typed provider route" {
    for (std.meta.tags(types.CredentialSource)) |source| {
        if (source == .grok_subscription) {
            try std.testing.expect(fromCredentialSource(source) == null);
            continue;
        }
        const route = fromCredentialSource(source) orelse return error.UnmappedCredentialSource;
        const expected: ProviderRoute = switch (source) {
            .openai_api_key => .openai_responses_byok,
            .chatgpt_subscription => .codex_responses_oauth,
            .grok_subscription => unreachable,
        };
        try std.testing.expectEqual(expected, route);
    }
}

test "wire model projects Responses IDs" {
    const cases = [_]struct {
        route: ProviderRoute,
        model: []const u8,
        expected: []const u8,
    }{
        .{ .route = .openai_responses_byok, .model = "openai/gpt-5.4", .expected = "gpt-5.4" },
        .{ .route = .openai_responses_byok, .model = "corporate/custom-model", .expected = "corporate/custom-model" },
        .{ .route = .codex_responses_oauth, .model = "openai/gpt-5.6-sol", .expected = "gpt-5.6-sol" },
        .{ .route = .codex_responses_oauth, .model = "gpt-5.3-codex", .expected = "gpt-5.3-codex" },
        .{ .route = .codex_responses_oauth, .model = "openai/o3", .expected = "o3" },
        .{ .route = .codex_responses_oauth, .model = "o4-mini", .expected = "o4-mini" },
        .{ .route = .codex_responses_oauth, .model = "anthropic/claude", .expected = "anthropic/claude" },
        .{ .route = .codex_responses_oauth, .model = "openrouter/custom", .expected = "openrouter/custom" },
        .{ .route = .codex_responses_oauth, .model = "openai/company-custom", .expected = "openai/company-custom" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, wireModel(case.route, case.model));
    }
}

test "credential source model projection uses its assigned route" {
    try std.testing.expectEqualStrings(
        "gpt-5.4",
        wireModelForCredentialSource(.openai_api_key, "openai/gpt-5.4"),
    );
    try std.testing.expectEqualStrings(
        "gpt-5.6-sol",
        wireModelForCredentialSource(.chatgpt_subscription, "openai/gpt-5.6-sol"),
    );
}

test "route default reconciliation normalizes only known defaults" {
    try std.testing.expectEqualStrings(
        openai_default_model,
        reconciledDefaultModel(.openai_api_key, codex_default_model, false).?,
    );
    try std.testing.expectEqualStrings(
        codex_default_model,
        reconciledDefaultModel(.chatgpt_subscription, "openai/" ++ openai_default_model, false).?,
    );
    try std.testing.expect(reconciledDefaultModel(.chatgpt_subscription, "company/custom-model", false) == null);
    try std.testing.expect(reconciledDefaultModel(.chatgpt_subscription, openai_default_model, true) == null);
    try std.testing.expect(reconciledDefaultModel(.chatgpt_subscription, codex_default_model, false) == null);
}

test "Responses base URLs normalize to their model catalog endpoint" {
    const cases = [_]struct {
        base_url: []const u8,
        expected: []const u8,
    }{
        .{ .base_url = "https://api.openai.com/v1", .expected = "https://api.openai.com/v1/models" },
        .{ .base_url = "https://proxy.example/v1/responses", .expected = "https://proxy.example/v1/models" },
        .{ .base_url = "http://127.0.0.1:43123/v1/models/", .expected = "http://127.0.0.1:43123/v1/models" },
    };
    for (cases) |case| {
        const actual = try appendModelsEndpointAlloc(std.testing.allocator, case.base_url);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "provider contracts keep protocol and product capabilities separate" {
    const openai = ProviderRoute.openai_responses_byok.contract();
    try std.testing.expectEqual(WireApi.openai_responses, openai.wire_api);
    try std.testing.expect(openai.headers.account_header.name() == null);
    try std.testing.expect(openai.headers.openai_organization);
    try std.testing.expect(openai.headers.openai_project);
    try std.testing.expect(openai.supports_max_output_tokens);
    try std.testing.expect(openai.supports_catalog);
    try std.testing.expectEqual(RemoteCompactionSupport.v2, openai.remote_compaction);

    const codex = ProviderRoute.codex_responses_oauth.contract();
    try std.testing.expectEqual(WireApi.openai_responses, codex.wire_api);
    try std.testing.expectEqualStrings("ChatGPT-Account-ID", codex.headers.account_header.name().?);
    try std.testing.expect(codex.headers.originator);
    try std.testing.expect(!codex.supports_max_output_tokens);
    try std.testing.expect(codex.supports_catalog);
    try std.testing.expectEqual(RemoteCompactionSupport.v2, codex.remote_compaction);
}

test "provider routes expose stable default bases and endpoints" {
    try std.testing.expectEqualStrings(openai_base_url, ProviderRoute.openai_responses_byok.defaultBaseUrl());
    try std.testing.expectEqualStrings(openai_responses_endpoint, ProviderRoute.openai_responses_byok.defaultEndpoint());
    try std.testing.expectEqualStrings(codex_base_url, ProviderRoute.codex_responses_oauth.defaultBaseUrl());
    try std.testing.expectEqualStrings(codex_responses_endpoint, ProviderRoute.codex_responses_oauth.defaultEndpoint());
    try std.testing.expectEqualStrings(
        openai_responses_compact_endpoint,
        ProviderRoute.openai_responses_byok.defaultCompactEndpoint().?,
    );
    try std.testing.expectEqualStrings(
        codex_responses_compact_endpoint,
        ProviderRoute.codex_responses_oauth.defaultCompactEndpoint().?,
    );
    try std.testing.expect(ProviderRoute.openai_responses_byok.defaultSearchEndpoint() == null);
    try std.testing.expectEqualStrings(
        codex_search_endpoint,
        ProviderRoute.codex_responses_oauth.defaultSearchEndpoint().?,
    );
}

test "Responses compact endpoints share direct-route base URL policy" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { base: []const u8, expected: []const u8 }{
        .{ .base = "https://api.openai.com/v1", .expected = "https://api.openai.com/v1/responses/compact" },
        .{ .base = "https://proxy.example/v1/responses/", .expected = "https://proxy.example/v1/responses/compact" },
        .{ .base = "https://proxy.example/v1/responses/compact/", .expected = "https://proxy.example/v1/responses/compact" },
        .{ .base = "http://127.0.0.1:43123/v1", .expected = "http://127.0.0.1:43123/v1/responses/compact" },
    };
    for (cases) |case| {
        const endpoint = try appendResponsesCompactEndpointAlloc(alloc, case.base);
        defer alloc.free(endpoint);
        try std.testing.expectEqualStrings(case.expected, endpoint);
    }

    const openai = try resolveCompactEndpointAlloc(alloc, .openai_responses_byok, .{
        .responses_base_url = "https://proxy.example/openai/v1/responses",
    });
    defer alloc.free(openai);
    try std.testing.expectEqualStrings("https://proxy.example/openai/v1/responses/compact", openai);

    const codex = try resolveCompactEndpointAlloc(alloc, .codex_responses_oauth, .{
        .responses_base_url = "https://must-not-redirect.example/v1",
        .codex_base_url = "http://localhost:43123/backend-api/codex",
    });
    defer alloc.free(codex);
    try std.testing.expectEqualStrings(
        "http://localhost:43123/backend-api/codex/responses/compact",
        codex,
    );
}

test "Codex search endpoint is pinned to the validated Codex route" {
    const alloc = std.testing.allocator;

    const default_endpoint = try resolveSearchEndpointAlloc(alloc, .codex_responses_oauth, .{});
    defer alloc.free(default_endpoint);
    try std.testing.expectEqualStrings(codex_search_endpoint, default_endpoint);

    const loopback = try resolveSearchEndpointAlloc(alloc, .codex_responses_oauth, .{
        .codex_base_url = "http://127.0.0.1:43123/backend-api/codex/responses/compact/",
    });
    defer alloc.free(loopback);
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:43123/backend-api/codex/alpha/search",
        loopback,
    );

    const already_search = try appendCodexSearchEndpointAlloc(
        alloc,
        "https://chatgpt.com/backend-api/codex/alpha/search/",
    );
    defer alloc.free(already_search);
    try std.testing.expectEqualStrings(codex_search_endpoint, already_search);

    try std.testing.expectError(
        error.UnsupportedProviderRoute,
        resolveSearchEndpointAlloc(alloc, .openai_responses_byok, .{}),
    );
}

test "Responses endpoint resolution applies scoped override precedence" {
    const alloc = std.testing.allocator;

    const fx_base = try resolveBaseUrlAlloc(alloc, .openai_responses_byok, .{
        .responses_base_url = "https://proxy.example.test/openai/v1/",
        .openai_base_url = "https://ignored.example.test/v1",
    });
    defer alloc.free(fx_base);
    try std.testing.expectEqualStrings("https://proxy.example.test/openai/v1", fx_base);

    const fx_openai = try resolveEndpointAlloc(alloc, .openai_responses_byok, .{
        .responses_base_url = "https://proxy.example.test/openai/v1/",
        .openai_base_url = "https://ignored.example.test/v1",
        .codex_base_url = "https://ignored.example.test/codex",
    });
    defer alloc.free(fx_openai);
    try std.testing.expectEqualStrings("https://proxy.example.test/openai/v1/responses", fx_openai);

    const standard_openai = try resolveEndpointAlloc(alloc, .openai_responses_byok, .{
        .openai_base_url = "https://api.example.test/v1",
    });
    defer alloc.free(standard_openai);
    try std.testing.expectEqualStrings("https://api.example.test/v1/responses", standard_openai);

    const codex = try resolveEndpointAlloc(alloc, .codex_responses_oauth, .{
        .responses_base_url = "https://must-not-redirect.example.test/v1",
        .codex_base_url = "http://127.0.0.1:43123/backend-api/codex",
    });
    defer alloc.free(codex);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/backend-api/codex/responses", codex);
}

test "Codex remains pinned to its default origin without its explicit override" {
    const alloc = std.testing.allocator;
    const endpoint = try resolveEndpointAlloc(alloc, .codex_responses_oauth, .{
        .responses_base_url = "https://proxy.example.test/v1",
        .openai_base_url = "https://other.example.test/v1",
    });
    defer alloc.free(endpoint);
    try std.testing.expectEqualStrings(codex_responses_endpoint, endpoint);
}

test "Responses base URL accepts HTTPS and explicit loopback HTTP" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { base: []const u8, expected: []const u8 }{
        .{ .base = "https://example.test/v1", .expected = "https://example.test/v1/responses" },
        .{ .base = "HTTPS://example.test/v1/", .expected = "HTTPS://example.test/v1/responses" },
        .{ .base = "https://example.test/v1/responses/", .expected = "https://example.test/v1/responses" },
        .{ .base = "http://127.0.0.1:43123/v1", .expected = "http://127.0.0.1:43123/v1/responses" },
        .{ .base = "http://localhost:43123/v1/", .expected = "http://localhost:43123/v1/responses" },
        .{ .base = "http://[::1]:43123/v1", .expected = "http://[::1]:43123/v1/responses" },
    };
    for (cases) |case| {
        const endpoint = try appendResponsesEndpointAlloc(alloc, case.base);
        defer alloc.free(endpoint);
        try std.testing.expectEqualStrings(case.expected, endpoint);
    }
}

test "Responses base URL rejects userinfo and insecure origins" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.BaseUrlContainsUserInfo,
        appendResponsesEndpointAlloc(alloc, "https://token@example.test/v1"),
    );
    try std.testing.expectError(
        error.BaseUrlContainsUserInfo,
        appendResponsesEndpointAlloc(alloc, "http://127.0.0.1:43123@evil.example/v1"),
    );
    try std.testing.expectError(
        error.InsecureBaseUrl,
        appendResponsesEndpointAlloc(alloc, "http://example.test:43123/v1"),
    );
    try std.testing.expectError(
        error.InsecureBaseUrl,
        appendResponsesEndpointAlloc(alloc, "http://127.0.0.1/v1"),
    );
    try std.testing.expectError(
        error.InsecureBaseUrl,
        appendResponsesEndpointAlloc(alloc, "ftp://example.test/v1"),
    );
    try std.testing.expectError(
        error.InvalidBaseUrl,
        appendResponsesEndpointAlloc(alloc, "example.test/v1"),
    );
    try std.testing.expectError(
        error.BaseUrlContainsQueryOrFragment,
        appendResponsesEndpointAlloc(alloc, "https://example.test/v1?tenant=one"),
    );
    try std.testing.expectError(
        error.BaseUrlContainsQueryOrFragment,
        appendResponsesEndpointAlloc(alloc, "https://example.test/v1#fragment"),
    );
    try std.testing.expectError(
        error.InvalidBaseUrl,
        appendResponsesEndpointAlloc(alloc, "https://example.test/v1\n"),
    );
}
