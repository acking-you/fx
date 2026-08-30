const std = @import("std");
const stream_provider = @import("../agent/stream_provider.zig");
const model_provider = @import("../config/model_provider.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const gateway_provider = @import("gateway_provider.zig");
const web_search_contract = @import("../tooling/web_search_contract.zig");
const web_search_provider = @import("../tooling/web_search_provider.zig");
const auto_classifier = @import("../permissions/auto_classifier.zig");
const model_catalog = @import("model_catalog.zig");
const responses_compaction_provider = @import("responses_compaction_provider.zig");
const web_search_projection = @import("web_search_projection.zig");

const Allocator = std.mem.Allocator;

pub const Bundle = struct {
    pub const AuthStrategy = enum {
        api_key,
        chatgpt,
        grok,
    };
    pub const Capabilities = struct {
        vision_fallback: bool = false,
    };
    pub const WebSearchRoute = struct {
        /// Provider boundary used after the provider's current model
        /// capabilities are resolved.
        projection: web_search_projection.Kind = .function,
        /// Local execution contract. For hosted routes this is the configured
        /// fallback used only when the model cannot execute native search.
        executor: ?web_search_provider.Provider = null,

        pub fn nativeAvailable(
            self: WebSearchRoute,
            capabilities: model_capabilities.Capabilities,
        ) bool {
            return self.projection == .hosted and capabilities.supports_web_search;
        }

        pub fn available(
            self: WebSearchRoute,
            capabilities: model_capabilities.Capabilities,
        ) bool {
            const local_available = if (self.executor) |provider|
                provider.isAvailable()
            else
                false;
            return switch (self.projection) {
                .function, .codex_namespace => local_available,
                .hosted => self.nativeAvailable(capabilities) or local_available,
            };
        }

        pub fn executionProvider(
            self: WebSearchRoute,
            capabilities: model_capabilities.Capabilities,
        ) ?web_search_provider.Provider {
            if (self.nativeAvailable(capabilities)) return null;
            const provider = self.executor orelse return null;
            return if (provider.isAvailable()) provider else null;
        }

        pub fn effectiveProjection(
            self: WebSearchRoute,
            capabilities: model_capabilities.Capabilities,
        ) web_search_projection.Kind {
            if (self.nativeAvailable(capabilities)) return .hosted;
            return switch (self.projection) {
                .hosted => .function,
                else => self.projection,
            };
        }
    };
    capabilities: Capabilities = .{},
    presentation: ?*const provider_catalog.Entry = null,
    auth_strategy: ?AuthStrategy = null,
    fallback_model_capabilities_fn: *const fn ([]const u8) model_capabilities.Capabilities = emptyModelCapabilities,
    agent_stream: ?stream_provider.Provider = null,
    cli_model_catalog: ?gateway_provider.CliModelCatalogProvider = null,
    model_catalog: ?model_catalog.Provider = null,
    responses_compaction: ?responses_compaction_provider.Provider = null,
    permission_reviewer: ?auto_classifier.Provider = null,
    account_usage: ?gateway_provider.AccountUsageProvider = null,
    web_search: WebSearchRoute = .{},

    pub fn agent_stream_or_unavailable(self: Bundle) stream_provider.Provider {
        return self.agent_stream orelse stream_provider.unavailable_provider;
    }

    pub fn fallbackModelCapabilities(self: Bundle, model: []const u8) model_capabilities.Capabilities {
        return self.fallback_model_capabilities_fn(model);
    }

    pub fn webSearchAvailable(
        self: Bundle,
        capabilities: model_capabilities.Capabilities,
    ) bool {
        return self.web_search.available(capabilities);
    }
};

fn emptyModelCapabilities(_: []const u8) model_capabilities.Capabilities {
    return .{};
}

pub const Set = struct {
    gateway: Bundle,
    codex: Bundle,
    grok: Bundle,

    pub fn select(self: Set, provider: model_provider.ProviderId) Bundle {
        return switch (provider) {
            .gateway => self.gateway,
            .codex => self.codex,
            .grok => self.grok,
        };
    }
};

pub fn gateway_only(gateway: Bundle) Set {
    return .{
        .gateway = gateway,
        .codex = .{},
        .grok = .{},
    };
}

test "provider set selects each provider's complete route" {
    var gateway_tag: u8 = 0;
    var codex_tag: u8 = 0;
    var grok_tag: u8 = 0;

    const Fake = struct {
        fn cli_catalog(
            _: ?*anyopaque,
            _: Allocator,
            _: gateway_provider.CliModelCatalogInput,
        ) gateway_provider.CliModelCatalogResult {
            return .{ .failure = .{
                .access = .init(.{ .public_only = .no_credential }),
                .failure = .{ .category = .runtime },
            } };
        }

        fn model_catalog_fetch(
            _: ?*anyopaque,
            _: Allocator,
            _: model_catalog.FetchInput,
        ) Allocator.Error!model_catalog.ProviderResult {
            return .{ .catalog = .empty };
        }

        fn review(
            _: ?*anyopaque,
            _: Allocator,
            _: auto_classifier.ProviderInput,
            _: auto_classifier.ReviewRequest,
        ) anyerror!auto_classifier.ParseOutcome {
            return .invalid;
        }

        fn search_backends(_: ?*anyopaque) anyerror!?[]const web_search_contract.SearchBackendId {
            return null;
        }

        fn search(
            _: ?*anyopaque,
            _: Allocator,
            _: web_search_provider.Inputs,
            _: web_search_contract.ProviderRequest,
            _: ?web_search_contract.ProgressFn,
            _: ?*anyopaque,
        ) anyerror!web_search_contract.ProviderResponse {
            return error.TestSearchUnavailable;
        }
    };

    const gateway = Bundle{
        .capabilities = .{ .vision_fallback = true },
        .presentation = provider_catalog.find(.gateway),
        .auth_strategy = .api_key,
        .agent_stream = stream_provider.Provider{
            .context = &gateway_tag,
            .stream_fn = stream_provider.unavailable_provider.stream_fn,
        },
        .cli_model_catalog = .{ .context = &gateway_tag, .fetch_fn = Fake.cli_catalog },
        .model_catalog = .{ .context = &gateway_tag, .fetch_fn = Fake.model_catalog_fetch },
        .permission_reviewer = .{ .context = &gateway_tag, .review_fn = Fake.review },
    };
    const codex = Bundle{
        .agent_stream = stream_provider.Provider{
            .context = &codex_tag,
            .stream_fn = stream_provider.unavailable_provider.stream_fn,
        },
        .cli_model_catalog = .{ .context = &codex_tag, .fetch_fn = Fake.cli_catalog },
        .model_catalog = .{ .context = &codex_tag, .fetch_fn = Fake.model_catalog_fetch },
        .permission_reviewer = .{ .context = &codex_tag, .review_fn = Fake.review },
        .web_search = .{
            .projection = .codex_namespace,
            .executor = .{
                .policy = .{},
                .preferred_backends_fn = Fake.search_backends,
                .execute_fn = Fake.search,
            },
        },
    };
    const grok = Bundle{
        .agent_stream = stream_provider.Provider{
            .context = &grok_tag,
            .stream_fn = stream_provider.unavailable_provider.stream_fn,
        },
        .cli_model_catalog = .{ .context = &grok_tag, .fetch_fn = Fake.cli_catalog },
        .model_catalog = .{ .context = &grok_tag, .fetch_fn = Fake.model_catalog_fetch },
        .permission_reviewer = .{ .context = &grok_tag, .review_fn = Fake.review },
    };
    var providers = Set{ .gateway = gateway, .codex = codex, .grok = grok };

    try std.testing.expect(providers.select(.gateway).agent_stream.?.context.? == @as(*anyopaque, @ptrCast(&gateway_tag)));
    try std.testing.expect(providers.select(.gateway).capabilities.vision_fallback);
    try std.testing.expectEqualStrings("byok", providers.select(.gateway).presentation.?.slug);
    try std.testing.expectEqual(Bundle.AuthStrategy.api_key, providers.select(.gateway).auth_strategy.?);
    try std.testing.expect(providers.select(.codex).webSearchAvailable(.{}));
    try std.testing.expect(!providers.select(.gateway).webSearchAvailable(.{}));
    try std.testing.expect(providers.select(.gateway).cli_model_catalog.?.context.? == @as(*anyopaque, @ptrCast(&gateway_tag)));
    try std.testing.expect(providers.select(.codex).model_catalog.?.context.? == @as(*anyopaque, @ptrCast(&codex_tag)));
    try std.testing.expect(providers.select(.grok).permission_reviewer.?.context.? == @as(*anyopaque, @ptrCast(&grok_tag)));
    try std.testing.expect(providers.select(.codex).agent_stream_or_unavailable().context.? == @as(*anyopaque, @ptrCast(&codex_tag)));

    providers.codex.model_catalog = null;
    try std.testing.expect(providers.select(.codex).model_catalog == null);
    try std.testing.expect(providers.select(.gateway).model_catalog != null);
}

test "hosted web search prefers native capability and falls back locally" {
    const hosted = Bundle.WebSearchRoute{ .projection = .hosted };
    try std.testing.expect(!hosted.available(.{}));
    try std.testing.expect(hosted.available(.{ .supports_web_search = true }));
    try std.testing.expectEqual(
        web_search_projection.Kind.hosted,
        hosted.effectiveProjection(.{ .supports_web_search = true }),
    );

    const Fake = struct {
        fn unavailable(_: ?*anyopaque) bool {
            return false;
        }

        fn backends(_: ?*anyopaque) anyerror!?[]const web_search_contract.SearchBackendId {
            return null;
        }

        fn search(
            _: ?*anyopaque,
            _: Allocator,
            _: web_search_provider.Inputs,
            _: web_search_contract.ProviderRequest,
            _: ?web_search_contract.ProgressFn,
            _: ?*anyopaque,
        ) anyerror!web_search_contract.ProviderResponse {
            return error.TestSearchUnavailable;
        }
    };
    const fallback = Bundle.WebSearchRoute{
        .projection = .hosted,
        .executor = .{
            .policy = .{},
            .preferred_backends_fn = Fake.backends,
            .execute_fn = Fake.search,
        },
    };
    try std.testing.expect(fallback.available(.{}));
    try std.testing.expect(fallback.executionProvider(.{}) != null);
    try std.testing.expectEqual(
        web_search_projection.Kind.function,
        fallback.effectiveProjection(.{}),
    );

    var unavailable_fallback = fallback;
    unavailable_fallback.executor.?.available_fn = Fake.unavailable;
    try std.testing.expect(!unavailable_fallback.available(.{}));
    try std.testing.expect(unavailable_fallback.executionProvider(.{}) == null);
}
