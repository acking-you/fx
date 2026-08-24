const std = @import("std");
const chatgpt_oauth = @import("../core/auth/chatgpt_oauth.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const codex_usage = @import("../core/gateway/codex_usage.zig");
const output_contracts = @import("../core/output/output_contracts.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;

pub const provider = gateway_provider.AccountUsageProvider{
    .fetch_fn = fetch,
};

fn fetch(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.AccountUsageLookupInput,
) output_contracts.CodexAccountUsageSnapshot {
    if (input.credential_source != .chatgpt_subscription) {
        return failure(.unsupported_credential_source, null);
    }
    const access_token = input.credential orelse return failure(.missing_credential, null);
    if (access_token.len == 0) return failure(.missing_credential, null);
    const account_id = input.account_id orelse return failure(.missing_account_id, null);
    if (account_id.len == 0) return failure(.missing_account_id, null);

    var endpoints = codex_usage.resolveEndpointsAlloc(
        alloc,
        codex_usage.EndpointOverrides.fromEnvironment(),
    ) catch |err| {
        debug_trace.logf("codex_usage", "endpoint resolution failed err={s}", .{@errorName(err)});
        return failure(failureKindForError(err), null);
    };
    defer endpoints.deinit(alloc);

    var first = fetchPair(
        alloc,
        endpoints,
        access_token,
        account_id,
        input.cancel_flag,
    );
    const retry_mode: chatgpt_oauth.RefreshMode = if (first.failure) |first_failure|
        switch (first_failure.kind) {
            .unauthorized => .force,
            .credential_changed => .stored,
            else => return first,
        }
    else
        return first;
    first.deinit(alloc);

    var refreshed = (chatgpt_oauth.loadAccess(alloc, input.oauth_transport, retry_mode) catch |err| {
        debug_trace.logf("codex_usage", "credential retry failed mode={t} err={s}", .{ retry_mode, @errorName(err) });
        return failure(failureKindForError(err), null);
    }) orelse return failure(.credential_unavailable, null);
    defer refreshed.deinit(alloc);
    if (!std.mem.eql(u8, refreshed.account_id, account_id)) {
        return failure(.credential_changed, null);
    }
    return fetchPair(
        alloc,
        endpoints,
        refreshed.access_token,
        refreshed.account_id,
        input.cancel_flag,
    );
}

fn fetchPair(
    alloc: Allocator,
    endpoints: codex_usage.Endpoints,
    access_token: []const u8,
    account_id: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
) output_contracts.CodexAccountUsageSnapshot {
    var usage_response = gateway_client.fetchCodexJsonBounded(alloc, .{
        .method = .get,
        .url = endpoints.usage,
        .access_token = access_token,
        .account_id = account_id,
        .cancel_flag = cancel_flag,
        .max_response_bytes = codex_usage.max_response_bytes,
    }) catch |err| {
        debug_trace.logf("codex_usage", "usage request failed err={s}", .{@errorName(err)});
        return failure(failureKindForError(err), null);
    };
    defer usage_response.deinit(alloc);
    if (usage_response.status != .ok) return failureForStatus(usage_response.status);

    // The second request is checked against the same stored token and account.
    // A concurrent login change discards the partial pair and retries once.
    var profile_response = gateway_client.fetchCodexJsonBounded(alloc, .{
        .method = .get,
        .url = endpoints.profile,
        .access_token = access_token,
        .account_id = account_id,
        .cancel_flag = cancel_flag,
        .max_response_bytes = codex_usage.max_response_bytes,
    }) catch |err| {
        debug_trace.logf("codex_usage", "profile request failed err={s}", .{@errorName(err)});
        return failure(failureKindForError(err), null);
    };
    defer profile_response.deinit(alloc);
    if (profile_response.status != .ok) return failureForStatus(profile_response.status);

    const data = codex_usage.parseSnapshot(
        alloc,
        usage_response.body,
        profile_response.body,
        io_mod.milliTimestamp(),
    ) catch |err| {
        debug_trace.logf("codex_usage", "response parse failed err={s}", .{@errorName(err)});
        return failure(failureKindForError(err), null);
    };
    return .{ .data = data };
}

fn failure(
    kind: codex_usage.FailureKind,
    status: ?std.http.Status,
) output_contracts.CodexAccountUsageSnapshot {
    return .{ .failure = .{ .kind = kind, .http_status = status } };
}

fn failureForStatus(status: std.http.Status) output_contracts.CodexAccountUsageSnapshot {
    const kind: codex_usage.FailureKind = switch (status) {
        .unauthorized => .unauthorized,
        .forbidden => .forbidden,
        .too_many_requests => .rate_limited,
        else => .http_error,
    };
    return failure(kind, status);
}

fn failureKindForError(err: anyerror) codex_usage.FailureKind {
    return switch (err) {
        error.OutOfMemory => .resource_exhausted,
        error.Cancelled => .cancelled,
        error.Timeout => .timeout,
        error.CodexCredentialUnavailable,
        error.ChatGptOAuthUnavailable,
        => .credential_unavailable,
        error.ChatGptAccountChanged,
        error.CodexCredentialChanged,
        => .credential_changed,
        error.CodexJsonResponseTooLarge,
        error.CodexUsageResponseTooLarge,
        => .response_too_large,
        error.InvalidCodexUsageResponse,
        error.InvalidCodexTokenProfileResponse,
        error.TooManyCodexRateLimits,
        error.TooManyCodexDailyUsageBuckets,
        => .invalid_response,
        error.InvalidBaseUrl,
        error.BaseUrlContainsUserInfo,
        error.BaseUrlContainsQueryOrFragment,
        error.InsecureBaseUrl,
        error.InvalidUri,
        => .invalid_endpoint,
        else => .transport,
    };
}

test "Codex account usage rejects the wrong credential source before transport" {
    var snapshot = fetch(null, std.testing.allocator, .{
        .credential = "key",
        .account_id = "account",
        .credential_source = .openai_api_key,
        .oauth_transport = @import("../core/auth/oauth_transport.zig").unavailable_provider,
    });
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        codex_usage.FailureKind.unsupported_credential_source,
        snapshot.failure.?.kind,
    );
}

test "Codex account usage rejects missing account identity before transport" {
    var snapshot = fetch(null, std.testing.allocator, .{
        .credential = "access",
        .account_id = null,
        .credential_source = .chatgpt_subscription,
        .oauth_transport = @import("../core/auth/oauth_transport.zig").unavailable_provider,
    });
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(codex_usage.FailureKind.missing_account_id, snapshot.failure.?.kind);
}

test "Codex account usage classifies provider HTTP failures" {
    var unauthorized = failureForStatus(.unauthorized);
    defer unauthorized.deinit(std.testing.allocator);
    try std.testing.expectEqual(codex_usage.FailureKind.unauthorized, unauthorized.failure.?.kind);
    try std.testing.expectEqual(std.http.Status.unauthorized, unauthorized.failure.?.http_status.?);

    var throttled = failureForStatus(.too_many_requests);
    defer throttled.deinit(std.testing.allocator);
    try std.testing.expectEqual(codex_usage.FailureKind.rate_limited, throttled.failure.?.kind);
}
