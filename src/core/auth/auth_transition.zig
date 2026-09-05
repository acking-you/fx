const std = @import("std");
const credentials = @import("credentials.zig");
const model_provider = @import("../config/model_provider.zig");

pub const ProviderSwitchDecision = enum {
    no_change,
    busy,
    prepare,
};

pub const ProviderSwitchIntent = enum {
    manual,
    post_oauth,
};

pub const ProviderSwitchFacts = struct {
    current: model_provider.ProviderId,
    target: model_provider.ProviderId,
    target_credential_ready: bool,
    intent: ProviderSwitchIntent,
    stream_active: bool,
    queued_prompts: usize,
    force_prepare: bool = false,
};

pub fn decideProviderSwitch(facts: ProviderSwitchFacts) ProviderSwitchDecision {
    if (facts.intent == .manual and facts.current == facts.target and facts.target_credential_ready and !facts.force_prepare) {
        return .no_change;
    }
    if (facts.stream_active or facts.queued_prompts > 0) return .busy;
    return .prepare;
}

pub const SignInCompletionAction = union(enum) {
    switch_provider: model_provider.ProviderId,
    activate_source: credentials.Source,
};

pub fn signInCompletion(
    provider: model_provider.ProviderId,
    provider_routing_supported: bool,
) SignInCompletionAction {
    return switch (provider) {
        .gateway => unreachable,
        .codex => if (provider_routing_supported)
            .{ .switch_provider = .codex }
        else
            .{ .activate_source = .chatgpt_subscription },
        .grok => if (provider_routing_supported)
            .{ .switch_provider = .grok }
        else
            .{ .activate_source = .grok_subscription },
    };
}

test "provider switch decisions are pure and provider keyed" {
    try std.testing.expectEqual(ProviderSwitchDecision.no_change, decideProviderSwitch(.{
        .current = .codex,
        .target = .codex,
        .target_credential_ready = true,
        .intent = .manual,
        .stream_active = false,
        .queued_prompts = 0,
    }));
    try std.testing.expectEqual(ProviderSwitchDecision.prepare, decideProviderSwitch(.{
        .current = .gateway,
        .target = .gateway,
        .target_credential_ready = true,
        .intent = .manual,
        .stream_active = false,
        .queued_prompts = 0,
        .force_prepare = true,
    }));
    try std.testing.expectEqual(ProviderSwitchDecision.busy, decideProviderSwitch(.{
        .current = .gateway,
        .target = .grok,
        .target_credential_ready = true,
        .intent = .manual,
        .stream_active = true,
        .queued_prompts = 0,
    }));
}

test "sign in completion selects routing or credential activation without effects" {
    try std.testing.expectEqual(
        SignInCompletionAction{ .switch_provider = .codex },
        signInCompletion(.codex, true),
    );
    try std.testing.expectEqual(
        SignInCompletionAction{ .activate_source = .grok_subscription },
        signInCompletion(.grok, false),
    );
}
