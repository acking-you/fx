const std = @import("std");
const model_provider = @import("../core/config/model_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const gateway = @import("gateway.zig");
const openai_codex_models = @import("../gateway/openai_codex_models.zig");
const xai_grok = @import("../gateway/xai_grok.zig");
const xai_grok_models = @import("../gateway/xai_grok_models.zig");

pub fn agentStream(provider: model_provider.ProviderId) stream_provider.Provider {
    return switch (provider) {
        .gateway => gateway.agent_stream_provider,
        .codex => gateway.agent_stream_provider,
        .grok => xai_grok.agent_stream_provider,
    };
}

test "Codex uses the shared Responses request and transport provider" {
    const codex = agentStream(.codex);
    try std.testing.expect(codex.build_fn == gateway.agent_stream_provider.build_fn);
    try std.testing.expect(codex.stream_fn == gateway.agent_stream_provider.stream_fn);
}

pub fn modelCatalog(provider: model_provider.ProviderId) model_catalog.Provider {
    return switch (provider) {
        .gateway => gateway.model_catalog_provider,
        .codex => openai_codex_models.model_catalog_provider,
        .grok => xai_grok_models.model_catalog_provider,
    };
}
