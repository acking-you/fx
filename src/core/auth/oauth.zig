const std = @import("std");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

pub const OAuthError = error{InvalidOAuthResponse};

pub const TokenSet = struct {
    access_token: []u8,
    refresh_token: ?[]u8 = null,
    expires_in: i64,
    scope: []u8,
    token_type: []u8,

    pub fn deinit(self: *TokenSet, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        if (self.refresh_token) |value| secret.zeroAndFree(alloc, value);
        if (self.scope.len > 0) alloc.free(self.scope);
        if (self.token_type.len > 0) alloc.free(self.token_type);
        self.* = undefined;
    }
};

pub const PollResult = union(enum) {
    pending,
    slow_down,
    success: TokenSet,
};

pub fn expiry_timestamp_ms(now_ms: i64, expires_in_seconds: i64) OAuthError!i64 {
    if (expires_in_seconds <= 0) return OAuthError.InvalidOAuthResponse;
    const duration_ms = std.math.mul(i64, expires_in_seconds, std.time.ms_per_s) catch
        return OAuthError.InvalidOAuthResponse;
    return std.math.add(i64, now_ms, duration_ms) catch OAuthError.InvalidOAuthResponse;
}

test "oauth expiry timestamps reject invalid durations" {
    try std.testing.expectEqual(@as(i64, 11_000), try expiry_timestamp_ms(1_000, 10));
    try std.testing.expectError(OAuthError.InvalidOAuthResponse, expiry_timestamp_ms(1_000, 0));
    try std.testing.expectError(OAuthError.InvalidOAuthResponse, expiry_timestamp_ms(1_000, -1));
    try std.testing.expectError(OAuthError.InvalidOAuthResponse, expiry_timestamp_ms(1_000, std.math.maxInt(i64)));
    try std.testing.expectError(OAuthError.InvalidOAuthResponse, expiry_timestamp_ms(std.math.maxInt(i64), 1));
}
