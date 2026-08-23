const std = @import("std");

const permission_auto_classifier = @import("../core/permissions/auto_classifier.zig");
const provider_route = @import("../core/gateway/provider_route.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const responses_reviewer = @import("responses_permission_reviewer.zig");
const openai_responses = @import("openai_responses.zig");

const Allocator = std.mem.Allocator;

pub const provider = permission_auto_classifier.Provider{
    .review_fn = reviewOpenAI,
};

fn reviewOpenAI(
    _: ?*anyopaque,
    alloc: Allocator,
    input: permission_auto_classifier.ProviderInput,
    request: permission_auto_classifier.ReviewRequest,
) !permission_auto_classifier.ParseOutcome {
    if (input.model.len == 0) return .invalid;
    return responses_reviewer.review(alloc, input, request, .{
        .source = .openai_api_key,
        .model = provider_route.wireModel(.openai_responses_byok, input.model),
        .validate_fn = validateCredential,
        .build_fn = openai_responses.buildRequest,
        .send_fn = sendPrepared,
    });
}

fn validateCredential(
    _: Allocator,
    input: permission_auto_classifier.ProviderInput,
) !void {
    if (input.credential_source != .openai_api_key or input.credential.len == 0) {
        return error.OpenAIResponsesApiKeyRequired;
    }
}

fn sendPrepared(
    alloc: Allocator,
    request: stream_provider.ModelRequest,
    payload: []const u8,
) !stream_provider.Result {
    return openai_responses.streamPrepared(alloc, request, payload);
}

test "OpenAI reviewer keeps the active BYOK model" {
    try std.testing.expectEqualStrings(
        "gpt-5.4",
        provider_route.wireModel(.openai_responses_byok, "openai/gpt-5.4"),
    );
}
