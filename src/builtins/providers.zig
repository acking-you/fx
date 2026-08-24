const provider_set = @import("../core/gateway/provider_set.zig");
const gateway = @import("gateway.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const openai_responses = @import("../gateway/openai_responses.zig");
const openai_responses_permission_reviewer = @import("../gateway/openai_responses_permission_reviewer.zig");
const openai_codex = @import("../gateway/openai_codex.zig");
const openai_codex_models = @import("../gateway/openai_codex_models.zig");
const openai_codex_permission_reviewer = @import("../gateway/openai_codex_permission_reviewer.zig");
const xai_grok = @import("../gateway/xai_grok.zig");
const xai_grok_models = @import("../gateway/xai_grok_models.zig");
const xai_grok_permission_reviewer = @import("../gateway/xai_grok_permission_reviewer.zig");
const provider_catalog = @import("../core/auth/provider_catalog.zig");

const gateway_agent_stream_provider = stream_provider.Provider{
    .stream_fn = streamGatewayOrOpenAI,
};
const gateway_permission_reviewer_provider = @import("../core/permissions/auto_classifier.zig").Provider{
    .review_fn = reviewGatewayOrOpenAI,
};

fn streamGatewayOrOpenAI(
    _: ?*anyopaque,
    alloc: @import("std").mem.Allocator,
    request: stream_provider.ModelRequest,
) anyerror!stream_provider.Result {
    return gatewayAgentStreamFor(request.credential.source).stream(alloc, request);
}

fn gatewayAgentStreamFor(source: ?@import("../core/shared/types.zig").CredentialSource) stream_provider.Provider {
    return if (source == .openai_api_key)
        openai_responses.agent_stream_provider
    else
        gateway.agent_stream_provider;
}

fn reviewGatewayOrOpenAI(
    _: ?*anyopaque,
    alloc: @import("std").mem.Allocator,
    input: @import("../core/permissions/auto_classifier.zig").ProviderInput,
    request: @import("../core/permissions/auto_classifier.zig").ReviewRequest,
) anyerror!@import("../core/permissions/auto_classifier.zig").ParseOutcome {
    const selected = if (input.credential_source == .openai_api_key)
        openai_responses_permission_reviewer.provider
    else
        gateway.permission_reviewer.provider;
    return selected.review_fn(selected.context, alloc, input, request);
}

pub const native = provider_set.Set{
    .gateway = blk: {
        var bundle = gateway.provider_bundle;
        bundle.agent_stream = gateway_agent_stream_provider;
        bundle.responses_compaction = openai_responses.compaction_provider;
        bundle.permission_reviewer = gateway_permission_reviewer_provider;
        break :blk bundle;
    },
    .codex = .{
        .presentation = provider_catalog.find(.codex),
        .auth_strategy = .chatgpt,
        .agent_stream = openai_codex.agent_stream_provider,
        .cli_model_catalog = openai_codex_models.cli_model_catalog_provider,
        .model_catalog = openai_codex_models.model_catalog_provider,
        .permission_reviewer = openai_codex_permission_reviewer.provider,
        .responses_compaction = openai_responses.compaction_provider,
    },
    .grok = .{
        .presentation = provider_catalog.find(.grok),
        .auth_strategy = .grok,
        .agent_stream = xai_grok.agent_stream_provider,
        .cli_model_catalog = xai_grok_models.cli_model_catalog_provider,
        .model_catalog = xai_grok_models.model_catalog_provider,
        .permission_reviewer = xai_grok_permission_reviewer.provider,
    },
};

test "gateway bundle dispatches only OpenAI API keys to Responses" {
    try @import("std").testing.expect(
        gatewayAgentStreamFor(.openai_api_key).stream_fn ==
            openai_responses.agent_stream_provider.stream_fn,
    );
    inline for (.{
        @import("../core/shared/types.zig").CredentialSource.ai_gateway_api_key,
        .vercel_oidc_token,
        .fx_login,
        .stored_key,
    }) |source| {
        try @import("std").testing.expect(
            gatewayAgentStreamFor(source).stream_fn == gateway.agent_stream_provider.stream_fn,
        );
    }
}
