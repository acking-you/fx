const provider_set = @import("../core/gateway/provider_set.zig");
const responses = @import("responses.zig");
const openai_responses = @import("../gateway/openai_responses.zig");
const openai_codex = @import("../gateway/openai_codex.zig");
const openai_codex_models = @import("../gateway/openai_codex_models.zig");
const openai_codex_permission_reviewer = @import("../gateway/openai_codex_permission_reviewer.zig");
const openai_codex_search = @import("../gateway/openai_codex_search.zig");
const openai_codex_usage = @import("../gateway/openai_codex_usage.zig");
const xai_grok = @import("../gateway/xai_grok.zig");
const xai_grok_models = @import("../gateway/xai_grok_models.zig");
const xai_grok_permission_reviewer = @import("../gateway/xai_grok_permission_reviewer.zig");
const xai_grok_usage = @import("../gateway/xai_grok_usage.zig");
const configured_responses_search = @import("../gateway/configured_responses_search.zig");
const provider_catalog = @import("../core/auth/provider_catalog.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");

fn grokFallbackModelCapabilities(model: []const u8) model_capabilities.Capabilities {
    // Grok's current subscription Responses route supports backend search by
    // default. A loaded catalog entry can still override this to false for a
    // model that explicitly does not support it. Reasoning menus come from the
    // live catalog when present, otherwise from the provider-owned fallback
    // for the current Grok 4 family.
    return xai_grok_models.fallbackModelCapabilities(model);
}

pub const native = provider_set.Set{
    .gateway = responses.provider_bundle,
    .codex = .{
        .presentation = provider_catalog.find(.codex),
        .auth_strategy = .chatgpt,
        .agent_stream = openai_codex.agent_stream_provider,
        .cli_model_catalog = openai_codex_models.cli_model_catalog_provider,
        .model_catalog = openai_codex_models.model_catalog_provider,
        .permission_reviewer = openai_codex_permission_reviewer.provider,
        .responses_compaction = openai_responses.compaction_provider,
        .web_search = .{
            .projection = .codex_namespace,
            .executor = openai_codex_search.provider,
        },
        .account_usage = openai_codex_usage.provider,
    },
    .grok = .{
        .presentation = provider_catalog.find(.grok),
        .auth_strategy = .grok,
        .fallback_model_capabilities_fn = grokFallbackModelCapabilities,
        .agent_stream = xai_grok.agent_stream_provider,
        .cli_model_catalog = xai_grok_models.cli_model_catalog_provider,
        .model_catalog = xai_grok_models.model_catalog_provider,
        .permission_reviewer = xai_grok_permission_reviewer.provider,
        .account_usage = xai_grok_usage.provider,
        .web_search = .{
            .projection = .hosted,
            .executor = configured_responses_search.provider,
        },
    },
};

test "default provider is direct BYOK Responses" {
    try @import("std").testing.expect(
        native.gateway.agent_stream.?.stream_fn == responses.agent_stream_provider.stream_fn,
    );
}

test "Grok fallback capabilities accept high for grok-4.6" {
    const capabilities = native.grok.fallbackModelCapabilities("grok-4.6");
    try @import("std").testing.expect(model_capabilities.reasoningEffortSupported(
        capabilities,
        @import("../core/shared/types.zig").ReasoningEffort.literal("high"),
    ));
    try @import("std").testing.expectEqualStrings("high", capabilities.default_reasoning_effort.label());
}
