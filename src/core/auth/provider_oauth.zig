const std = @import("std");
const chatgpt_oauth = @import("chatgpt_oauth.zig");
const grok_oauth = @import("grok_oauth.zig");
const login_flow = @import("login_flow.zig");
const oauth_transport = @import("oauth_transport.zig");
const types = @import("../shared/types.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

/// OAuth-backed providers supported by the fork.  The transport, login flow,
/// credential loading, and ACP/TUI callers all use this identity instead of
/// switching on provider-specific modules at each call site.
pub const Provider = enum {
    codex,
    grok,

    pub fn source(self: Provider) types.CredentialSource {
        return switch (self) {
            .codex => .chatgpt_subscription,
            .grok => .grok_subscription,
        };
    }

    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .codex => "Codex",
            .grok => "Grok",
        };
    }

    pub fn parse(value: []const u8) ?Provider {
        if (std.ascii.eqlIgnoreCase(value, "codex")) return .codex;
        if (std.ascii.eqlIgnoreCase(value, "grok")) return .grok;
        return null;
    }
};

pub const RefreshMode = enum {
    if_needed,
    force,
    stored,
};

pub const Access = struct {
    access_token: []u8,
    account_id: []u8,
    refresh_after_ms: i64,

    pub fn deinit(self: *Access, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        alloc.free(self.account_id);
        self.* = undefined;
    }
};

pub fn startSignIn(
    provider: Provider,
    runtime: *login_flow.SignInRuntime,
    alloc: Allocator,
    transport: oauth_transport.Provider,
) !bool {
    return switch (provider) {
        .codex => chatgpt_oauth.startSignIn(runtime, alloc, transport),
        .grok => grok_oauth.startSignIn(runtime, alloc, transport),
    };
}

pub fn sourceExists(provider: Provider, alloc: Allocator) !bool {
    return switch (provider) {
        .codex => chatgpt_oauth.sourceExists(alloc),
        .grok => grok_oauth.sourceExists(alloc),
    };
}

pub fn loadAccess(
    provider: Provider,
    alloc: Allocator,
    transport: oauth_transport.Provider,
    mode: RefreshMode,
) !?Access {
    return switch (provider) {
        .codex => {
            const access = try chatgpt_oauth.loadAccess(alloc, transport, switch (mode) {
                .if_needed => .if_needed,
                .force => .force,
                .stored => .stored,
            });
            return if (access) |value| .{
                .access_token = value.access_token,
                .account_id = value.account_id,
                .refresh_after_ms = value.refresh_after_ms,
            } else null;
        },
        .grok => {
            const access = try grok_oauth.loadAccess(alloc, transport, switch (mode) {
                .if_needed => .if_needed,
                .force => .force,
                .stored => .stored,
            });
            return if (access) |value| .{
                .access_token = value.access_token,
                .account_id = value.account_id,
                .refresh_after_ms = value.refresh_after_ms,
            } else null;
        },
    };
}

/// Detects a stored OAuth credential without making a refresh request.  The
/// order is intentional: Codex remains the historical default, while Grok is
/// a deterministic fallback when Codex is not connected.
pub fn detectStored(alloc: Allocator) !?Provider {
    const providers = [_]Provider{ .codex, .grok };
    for (providers) |provider| {
        if (!try sourceExists(provider, alloc)) continue;
        // Probe the stored payload as well as the file marker. A truncated or
        // stale auth file must fall through to the other OAuth provider.
        var access = loadAccess(provider, alloc, oauth_transport.unavailable_provider, .stored) catch continue;
        if (access) |*value| {
            value.deinit(alloc);
            return provider;
        }
    }
    return null;
}

test "provider OAuth maps identity, source, and fallback order" {
    try std.testing.expectEqual(types.CredentialSource.chatgpt_subscription, Provider.codex.source());
    try std.testing.expectEqual(types.CredentialSource.grok_subscription, Provider.grok.source());
    try std.testing.expectEqual(Provider.grok, Provider.parse("GROK").?);
    try std.testing.expect(Provider.parse("unknown") == null);
}
