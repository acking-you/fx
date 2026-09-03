const std = @import("std");
const types = @import("../shared/types.zig");

pub const ResolvedProviderOptions = struct {
    reasoning: ?types.ReasoningEffort = null,
    fast: bool = false,
    native_web_search: bool = false,
    parallel_tool_calls: ?bool = null,
    prompt_caching: bool = false,
};

pub const ReasoningEffortOptions = struct {
    values: [types.ReasoningEffort.max_options]types.ReasoningEffort = undefined,
    len: usize = 0,

    pub fn fromSlice(source: []const types.ReasoningEffort) ReasoningEffortOptions {
        var result: ReasoningEffortOptions = .{};
        result.len = @min(source.len, result.values.len);
        for (source[0..result.len], 0..) |value, index| result.values[index] = value;
        return result;
    }

    pub fn slice(self: *const ReasoningEffortOptions) []const types.ReasoningEffort {
        return self.values[0..self.len];
    }
};

pub const ImageInputSupport = enum {
    unknown,
    non_native,
    native,
};

pub const GatewayMetadata = struct {
    supports_reasoning: bool = false,
    reasoning_efforts: ReasoningEffortOptions = .{},
    default_reasoning_effort: types.ReasoningEffort = .auto,
    supports_fast_mode: bool = false,
    supports_tool_use: bool = false,
    supports_vision: bool = false,
    supports_file_input: bool = false,
    supports_web_search: bool = false,
    supports_explicit_caching: bool = false,
    supports_implicit_caching: bool = false,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
    auto_compact_token_limit: ?u32 = null,
    effective_context_window_percent: ?u8 = null,
};

pub const Capabilities = struct {
    supports_reasoning: bool = false,
    reasoning_efforts: ReasoningEffortOptions = .{},
    default_reasoning_effort: types.ReasoningEffort = .auto,
    supports_fast_mode: bool = false,
    supports_tool_use: bool = false,
    supports_vision: bool = false,
    supports_file_input: bool = false,
    image_input_support: ImageInputSupport = .unknown,
    supports_web_search: bool = false,
    supports_explicit_caching: bool = false,
    supports_implicit_caching: bool = false,
    prompt_caching: bool = false,
    parallel_tool_calls: ?bool = null,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
    auto_compact_token_limit: ?u32 = null,
    effective_context_window_percent: ?u8 = null,
};

pub const ResolveError = error{Cancelled};

pub const Resolver = struct {
    ctx: *anyopaque,
    resolve_fn: *const fn (
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        model: []const u8,
    ) ResolveError!Capabilities,

    pub fn resolve(self: Resolver, arena: std.mem.Allocator, model: []const u8) ResolveError!Capabilities {
        return self.resolve_fn(self.ctx, arena, model);
    }
};

pub fn mergeCapabilities(capabilities_value: Capabilities, gateway_metadata: ?GatewayMetadata) Capabilities {
    var capabilities = capabilities_value;
    if (gateway_metadata) |metadata| {
        if (metadata.reasoning_efforts.len > 0) {
            capabilities.reasoning_efforts = metadata.reasoning_efforts;
        } else if (!metadata.supports_reasoning) {
            capabilities.reasoning_efforts = .{};
            capabilities.default_reasoning_effort = .auto;
        }
        if (!metadata.default_reasoning_effort.isDefault() and
            reasoningEffortSupported(.{ .reasoning_efforts = capabilities.reasoning_efforts }, metadata.default_reasoning_effort))
        {
            capabilities.default_reasoning_effort = metadata.default_reasoning_effort;
        } else if (!reasoningEffortSupported(.{ .reasoning_efforts = capabilities.reasoning_efforts }, capabilities.default_reasoning_effort)) {
            capabilities.default_reasoning_effort = .auto;
        }
        capabilities.supports_reasoning = metadata.supports_reasoning or capabilities.reasoning_efforts.len > 0;
        capabilities.supports_fast_mode = metadata.supports_fast_mode;
        capabilities.supports_tool_use = metadata.supports_tool_use;
        capabilities.supports_vision = metadata.supports_vision;
        capabilities.supports_file_input = metadata.supports_file_input;
        capabilities.image_input_support = if (metadata.supports_vision and metadata.supports_file_input)
            .native
        else
            .non_native;
        capabilities.supports_web_search = metadata.supports_web_search;
        capabilities.supports_explicit_caching = metadata.supports_explicit_caching;
        capabilities.supports_implicit_caching = metadata.supports_implicit_caching;
        if (metadata.context_window) |window| capabilities.context_window = window;
        if (metadata.max_output_tokens) |tokens| capabilities.max_output_tokens = tokens;
        if (metadata.auto_compact_token_limit) |tokens| capabilities.auto_compact_token_limit = tokens;
        if (metadata.effective_context_window_percent) |percent| capabilities.effective_context_window_percent = percent;
    }
    return capabilities;
}

pub fn resolveCapabilities(_: []const u8, gateway_metadata: ?GatewayMetadata) Capabilities {
    return mergeCapabilities(.{}, gateway_metadata);
}

pub fn capabilitiesForModel(model: []const u8) Capabilities {
    return resolveCapabilities(model, null);
}

pub fn resolveForApp(comptime App: type, app: *App, model: []const u8) Capabilities {
    if (comptime @hasDecl(App, "resolvedModelCapabilities")) {
        return app.resolvedModelCapabilities(model);
    }
    return capabilitiesForModel(model);
}

pub fn reasoningEffortSupported(capabilities: Capabilities, effort: types.ReasoningEffort) bool {
    if (effort.isDefault()) return true;
    for (capabilities.reasoning_efforts.slice()) |option| {
        if (option.eql(effort)) return true;
    }
    return false;
}

pub fn reasoningEffortIndex(capabilities: Capabilities, effort: types.ReasoningEffort) usize {
    if (effort.isDefault()) return 0;
    for (capabilities.reasoning_efforts.slice(), 0..) |option, i| {
        if (option.eql(effort)) return i + 1;
    }
    return 0;
}

pub fn reasoningEffortAtIndex(capabilities: Capabilities, index: usize) types.ReasoningEffort {
    if (index == 0 or capabilities.reasoning_efforts.len == 0) return .auto;
    return capabilities.reasoning_efforts.values[(index - 1) % capabilities.reasoning_efforts.len];
}

pub fn reasoningEffortLabelAtIndex(capabilities: *const Capabilities, index: usize) []const u8 {
    if (index == 0 or capabilities.reasoning_efforts.len == 0) return "default";
    return capabilities.reasoning_efforts.values[(index - 1) % capabilities.reasoning_efforts.len].displayLabel();
}

pub fn reasoningEffortOptionCount(capabilities: Capabilities) usize {
    return if (capabilities.reasoning_efforts.len == 0) 0 else capabilities.reasoning_efforts.len + 1;
}

pub fn clampReasoningEffort(capabilities: Capabilities, effort: types.ReasoningEffort) types.ReasoningEffort {
    if (effort.isDefault()) return .auto;
    if (reasoningEffortSupported(capabilities, effort)) return effort;
    if (!capabilities.default_reasoning_effort.isDefault() and
        reasoningEffortSupported(capabilities, capabilities.default_reasoning_effort))
    {
        return capabilities.default_reasoning_effort;
    }
    return .auto;
}

pub fn resolveReasoningEffortForRequest(
    capabilities: Capabilities,
    effort: types.ReasoningEffort,
) ?types.ReasoningEffort {
    if (!effort.isDefault() and reasoningEffortSupported(capabilities, effort)) return effort;
    if (!capabilities.default_reasoning_effort.isDefault() and
        reasoningEffortSupported(capabilities, capabilities.default_reasoning_effort))
    {
        return capabilities.default_reasoning_effort;
    }
    return null;
}

pub fn effectiveContextWindowTokens(capabilities: Capabilities) ?u32 {
    const context_window = capabilities.context_window orelse return null;
    const percent = capabilities.effective_context_window_percent orelse return context_window;
    return @intCast((@as(u64, context_window) * @min(@as(u64, percent), 100)) / 100);
}

pub fn autoCompactTokenLimit(capabilities: Capabilities) ?u32 {
    const configured = capabilities.auto_compact_token_limit;
    const context_limit = if (capabilities.context_window) |context_window|
        @as(u32, @intCast((@as(u64, context_window) * 9) / 10))
    else
        null;
    if (context_limit) |limit| {
        return if (configured) |value| @min(value, limit) else limit;
    }
    return configured;
}

pub fn resolveProviderOptionsForCapabilities(
    capabilities: Capabilities,
    effort: types.ReasoningEffort,
    fast_mode: bool,
) ResolvedProviderOptions {
    var resolved: ResolvedProviderOptions = .{
        .parallel_tool_calls = capabilities.parallel_tool_calls,
        .prompt_caching = capabilities.prompt_caching,
    };
    resolved.reasoning = resolveReasoningEffortForRequest(capabilities, effort);
    resolved.fast = fast_mode and capabilities.supports_fast_mode;
    resolved.native_web_search = capabilities.supports_web_search;
    return resolved;
}

test "capabilities never infer reasoning or Fast controls from model IDs" {
    const models = [_][]const u8{
        "openai/gpt-5.6-sol",
        "anthropic/claude-opus-4.8",
        "zai/glm-5.2",
        "zai/glm-5.2-fast",
    };
    for (models) |model| {
        const capabilities = capabilitiesForModel(model);
        try std.testing.expectEqual(@as(usize, 0), capabilities.reasoning_efforts.len);
        try std.testing.expect(!capabilities.supports_fast_mode);
    }
}

test "Codex context budget reserves five percent and compacts at ninety percent" {
    const capabilities: Capabilities = .{
        .context_window = 272_000,
        .auto_compact_token_limit = 250_000,
        .effective_context_window_percent = 95,
    };
    try std.testing.expectEqual(@as(?u32, 258_400), effectiveContextWindowTokens(capabilities));
    try std.testing.expectEqual(@as(?u32, 244_800), autoCompactTokenLimit(capabilities));
    try std.testing.expectEqual(@as(?u32, 230_000), autoCompactTokenLimit(.{
        .context_window = 272_000,
        .auto_compact_token_limit = 230_000,
    }));
}

test "mergeCapabilities preserves provider controls and supplied fallback policy" {
    const efforts = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("future-tier"),
        types.ReasoningEffort.literal("high"),
    };
    const capabilities = mergeCapabilities(.{ .prompt_caching = true }, .{
        .reasoning_efforts = .fromSlice(&efforts),
        .supports_fast_mode = true,
        .supports_tool_use = true,
        .supports_vision = true,
        .supports_file_input = true,
        .supports_web_search = true,
        .supports_explicit_caching = true,
        .supports_implicit_caching = true,
        .context_window = 300_000,
        .max_output_tokens = 32_000,
    });

    try std.testing.expect(capabilities.supports_reasoning);
    try std.testing.expectEqual(@as(usize, 2), capabilities.reasoning_efforts.len);
    try std.testing.expectEqualStrings("future-tier", capabilities.reasoning_efforts.values[0].label());
    try std.testing.expect(capabilities.default_reasoning_effort.isDefault());
    try std.testing.expect(capabilities.supports_fast_mode);
    try std.testing.expect(capabilities.supports_tool_use);
    try std.testing.expect(capabilities.supports_vision);
    try std.testing.expect(capabilities.supports_file_input);
    try std.testing.expect(capabilities.supports_web_search);
    try std.testing.expect(capabilities.supports_explicit_caching);
    try std.testing.expect(capabilities.supports_implicit_caching);
    try std.testing.expect(capabilities.prompt_caching);
    try std.testing.expectEqual(@as(?u32, 300_000), capabilities.context_window);
    try std.testing.expectEqual(@as(?u32, 32_000), capabilities.max_output_tokens);
}

test "image input support distinguishes unknown native and non native capability" {
    try std.testing.expectEqual(
        ImageInputSupport.unknown,
        capabilitiesForModel("provider/unknown").image_input_support,
    );

    const native = mergeCapabilities(.{}, .{
        .supports_vision = true,
        .supports_file_input = true,
    });
    try std.testing.expectEqual(ImageInputSupport.native, native.image_input_support);

    const non_native = mergeCapabilities(.{}, .{
        .supports_vision = true,
        .supports_file_input = false,
    });
    try std.testing.expectEqual(ImageInputSupport.non_native, non_native.image_input_support);
}

test "reasoning effort picker helpers prepend default and preserve Gateway order" {
    const efforts = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("future-tier"),
        types.ReasoningEffort.literal("high"),
    };
    const capabilities = Capabilities{ .reasoning_efforts = .fromSlice(&efforts) };

    try std.testing.expectEqual(@as(usize, 3), reasoningEffortOptionCount(capabilities));
    try std.testing.expect(reasoningEffortAtIndex(capabilities, 0).isDefault());
    try std.testing.expectEqualStrings("future-tier", reasoningEffortLabelAtIndex(&capabilities, 1));
    try std.testing.expectEqualStrings("high", reasoningEffortLabelAtIndex(&capabilities, 2));
    try std.testing.expectEqual(@as(usize, 1), reasoningEffortIndex(capabilities, types.ReasoningEffort.literal("future-tier")));
    try std.testing.expectEqual(@as(usize, 0), reasoningEffortIndex(capabilities, types.ReasoningEffort.literal("stale")));
}

test "request controls form a total fail-closed state machine" {
    const declared_efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("future-tier")};
    const selected = types.ReasoningEffort.literal("future-tier");
    const stale = types.ReasoningEffort.literal("stale");
    const cases = [_]struct {
        capabilities: Capabilities,
        effort: types.ReasoningEffort,
        fast_mode: bool,
        expected_effort: ?[]const u8,
        expected_fast: bool,
    }{
        .{ .capabilities = .{}, .effort = .auto, .fast_mode = false, .expected_effort = null, .expected_fast = false },
        .{ .capabilities = .{}, .effort = selected, .fast_mode = true, .expected_effort = null, .expected_fast = false },
        .{ .capabilities = .{ .reasoning_efforts = .fromSlice(&declared_efforts) }, .effort = .auto, .fast_mode = false, .expected_effort = null, .expected_fast = false },
        .{ .capabilities = .{ .reasoning_efforts = .fromSlice(&declared_efforts) }, .effort = selected, .fast_mode = false, .expected_effort = "future-tier", .expected_fast = false },
        .{ .capabilities = .{ .reasoning_efforts = .fromSlice(&declared_efforts) }, .effort = stale, .fast_mode = false, .expected_effort = null, .expected_fast = false },
        .{ .capabilities = .{ .supports_fast_mode = true }, .effort = .auto, .fast_mode = true, .expected_effort = null, .expected_fast = true },
        .{ .capabilities = .{ .reasoning_efforts = .fromSlice(&declared_efforts), .supports_fast_mode = true }, .effort = selected, .fast_mode = true, .expected_effort = "future-tier", .expected_fast = true },
    };

    for (cases) |case| {
        const resolved = resolveProviderOptionsForCapabilities(case.capabilities, case.effort, case.fast_mode);
        try std.testing.expectEqual(case.expected_fast, resolved.fast);
        if (case.expected_effort) |expected| {
            try std.testing.expectEqualStrings(expected, resolved.reasoning.?.label());
        } else {
            try std.testing.expect(resolved.reasoning == null);
        }
    }
}

test "request controls remain safe across repeated state transitions" {
    const declared_efforts = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("future-tier"),
        types.ReasoningEffort.literal("high"),
    };
    const states = [_]struct {
        capabilities: Capabilities,
        effort: types.ReasoningEffort,
        fast_mode: bool,
    }{
        .{ .capabilities = .{}, .effort = .auto, .fast_mode = false },
        .{ .capabilities = .{}, .effort = types.ReasoningEffort.literal("future-tier"), .fast_mode = true },
        .{ .capabilities = .{ .reasoning_efforts = .fromSlice(&declared_efforts) }, .effort = types.ReasoningEffort.literal("future-tier"), .fast_mode = true },
        .{ .capabilities = .{ .reasoning_efforts = .fromSlice(&declared_efforts), .supports_fast_mode = true }, .effort = types.ReasoningEffort.literal("high"), .fast_mode = true },
        .{ .capabilities = .{ .supports_fast_mode = true }, .effort = types.ReasoningEffort.literal("stale"), .fast_mode = false },
    };

    var transition: usize = 0;
    while (transition < 1_000) : (transition += 1) {
        const state = states[transition % states.len];
        const resolved = resolveProviderOptionsForCapabilities(state.capabilities, state.effort, state.fast_mode);
        if (resolved.reasoning) |effort| {
            try std.testing.expect(reasoningEffortSupported(state.capabilities, effort));
            try std.testing.expect(effort.eql(resolveReasoningEffortForRequest(state.capabilities, state.effort).?));
        }
        try std.testing.expect(!resolved.fast or (state.fast_mode and state.capabilities.supports_fast_mode));
    }
}

test "generic fallback capabilities contain no vendor policy" {
    const fallback = capabilitiesForModel("anthropic/claude-any");
    try std.testing.expect(!fallback.prompt_caching);
    try std.testing.expect(fallback.context_window == null);
}

test "mergeCapabilities keeps fallback efforts when catalog supports reasoning without a menu" {
    const fallback_efforts = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("xhigh"),
        types.ReasoningEffort.literal("high"),
        types.ReasoningEffort.literal("medium"),
        types.ReasoningEffort.literal("low"),
    };
    const fallback = Capabilities{
        .supports_tool_use = true,
        .supports_web_search = true,
        .reasoning_efforts = .fromSlice(&fallback_efforts),
        .default_reasoning_effort = types.ReasoningEffort.literal("high"),
    };

    const kept = mergeCapabilities(fallback, .{
        .supports_reasoning = true,
        .supports_web_search = false,
    });
    try std.testing.expect(kept.supports_reasoning);
    try std.testing.expectEqual(@as(usize, 4), kept.reasoning_efforts.len);
    try std.testing.expectEqualStrings("high", kept.default_reasoning_effort.label());
    try std.testing.expect(!kept.supports_web_search);

    const cleared = mergeCapabilities(fallback, .{
        .supports_reasoning = false,
        .supports_web_search = true,
    });
    try std.testing.expect(!cleared.supports_reasoning);
    try std.testing.expectEqual(@as(usize, 0), cleared.reasoning_efforts.len);
    try std.testing.expect(cleared.default_reasoning_effort.isDefault());
}

test "auto and unsupported effort resolve to the model default on the wire" {
    const efforts = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("xhigh"),
        types.ReasoningEffort.literal("high"),
        types.ReasoningEffort.literal("low"),
    };
    const capabilities = Capabilities{
        .reasoning_efforts = .fromSlice(&efforts),
        .default_reasoning_effort = types.ReasoningEffort.literal("high"),
    };

    try std.testing.expectEqualStrings(
        "high",
        resolveReasoningEffortForRequest(capabilities, .auto).?.label(),
    );
    try std.testing.expectEqualStrings(
        "low",
        resolveReasoningEffortForRequest(capabilities, types.ReasoningEffort.literal("low")).?.label(),
    );
    try std.testing.expectEqualStrings(
        "high",
        resolveReasoningEffortForRequest(capabilities, types.ReasoningEffort.literal("stale")).?.label(),
    );
    try std.testing.expectEqualStrings(
        "high",
        clampReasoningEffort(capabilities, types.ReasoningEffort.literal("stale")).label(),
    );
    try std.testing.expect(clampReasoningEffort(capabilities, .auto).isDefault());
}
