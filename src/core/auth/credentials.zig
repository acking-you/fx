const std = @import("std");
const chatgpt_oauth = @import("chatgpt_oauth.zig");
const grok_oauth = @import("grok_oauth.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const model_provider = @import("../config/model_provider.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");
const types = @import("../shared/types.zig");

pub const Source = types.CredentialSource;

pub const CatalogPublicOnly = union(enum) {
    no_credential,
    credential_refresh_failed: Source,

    fn credentialSource(self: CatalogPublicOnly) ?Source {
        return switch (self) {
            .no_credential => null,
            .credential_refresh_failed => |source| source,
        };
    }
};

pub const CatalogPublicOnlyReason = std.meta.Tag(CatalogPublicOnly);

pub const CatalogAuthenticatedSource = enum {
    openai_api_key,
    chatgpt_subscription,
    grok_subscription,

    fn credentialSource(self: CatalogAuthenticatedSource) Source {
        return switch (self) {
            .openai_api_key => .openai_api_key,
            .chatgpt_subscription => .chatgpt_subscription,
            .grok_subscription => .grok_subscription,
        };
    }
};

/// A borrowed authorization decision for one model-catalog request. Public-only
/// states cannot carry credential bytes; authenticated states carry only the
/// values the selected provider is allowed to receive.
pub const CatalogAccess = union(enum) {
    public_only: CatalogPublicOnly,
    authenticated: struct {
        source: CatalogAuthenticatedSource,
        credential: []const u8,
        account_id: ?[]const u8 = null,
    },

    pub fn credentialSource(self: CatalogAccess) ?Source {
        return switch (self) {
            .public_only => |access| access.credentialSource(),
            .authenticated => |access| access.source.credentialSource(),
        };
    }

    pub fn publicOnlyReason(self: CatalogAccess) ?CatalogPublicOnlyReason {
        const access = self.publicOnly() orelse return null;
        return std.meta.activeTag(access);
    }

    pub fn publicOnly(self: CatalogAccess) ?CatalogPublicOnly {
        return switch (self) {
            .public_only => |access| access,
            .authenticated => null,
        };
    }

    pub fn authorizationCredential(self: CatalogAccess) ?[]const u8 {
        return switch (self) {
            .public_only => null,
            .authenticated => |access| access.credential,
        };
    }

    pub fn accountId(self: CatalogAccess) ?[]const u8 {
        const account_id = switch (self) {
            .public_only => return null,
            .authenticated => |access| access.account_id orelse return null,
        };
        return if (account_id.len > 0) account_id else null;
    }
};

pub fn catalogAccessAt(credential: ?Credential, now_ms: i64) CatalogAccess {
    const selected = credential orelse return .{ .public_only = .no_credential };
    _ = now_ms;
    return catalogAccessForCredentialAndAccount(
        selected.source,
        selected.token,
        selected.accountId(),
    );
}

pub fn catalogAccessAfterRefreshFailure(source: Source) CatalogAccess {
    return .{
        .public_only = .{
            .credential_refresh_failed = source,
        },
    };
}

pub fn catalogAccessForCredential(
    source: ?Source,
    credential: []const u8,
) CatalogAccess {
    return catalogAccessForCredentialAndAccount(source, credential, null);
}

pub fn catalogAccessForCredentialAndAccount(
    source: ?Source,
    credential: []const u8,
    account_id: ?[]const u8,
) CatalogAccess {
    const selected_source = source orelse return .{ .public_only = .no_credential };
    const authenticated_source: CatalogAuthenticatedSource = switch (selected_source) {
        .openai_api_key => .openai_api_key,
        .chatgpt_subscription => .chatgpt_subscription,
        .grok_subscription => .grok_subscription,
    };
    return .{
        .authenticated = .{
            .source = authenticated_source,
            .credential = credential,
            .account_id = if (authenticated_source == .grok_subscription) account_id else null,
        },
    };
}

/// Both modes resolve the same source set; the mode selects only whether an
/// expired subscription credential is refreshed first.
pub const LoadMode = enum { stored, refresh_if_needed };

pub const missing_credential_message = "Fx needs a model credential. Set OPENAI_API_KEY for a Responses API, use fx login codex for ChatGPT Codex, or use fx login grok for Grok.";
pub const missing_interactive_credential_message = "Fx needs a model credential. Set OPENAI_API_KEY for a Responses API, or use /login for ChatGPT Codex or Grok.";
pub const missing_chatgpt_credential_message = "fx needs a Codex subscription login for this model. Run fx login codex.";
pub const missing_chatgpt_interactive_credential_message = "Codex needs a subscription login. Run /login and choose Sign in with Codex.";
pub const missing_grok_credential_message = "fx needs a Grok subscription login for this model. Run fx login grok.";
pub const missing_grok_interactive_credential_message = "Grok needs a subscription login. Run /login and choose Sign in with Grok.";

pub const Credential = struct {
    token: []u8,
    source: Source,
    account_id: ?[]u8 = null,
    refresh_after_ms: ?i64 = null,

    pub fn deinit(self: *Credential, alloc: std.mem.Allocator) void {
        secret.zeroAndFree(alloc, self.token);
        if (self.account_id) |account_id| alloc.free(account_id);
        self.* = undefined;
    }

    pub fn accountId(self: Credential) ?[]const u8 {
        return self.account_id;
    }

    pub fn needsRefreshAt(self: Credential, now_ms: i64) bool {
        const refresh_after_ms = self.refresh_after_ms orelse return false;
        return refresh_after_ms <= now_ms;
    }
};

pub const Resolution = struct {
    credential: ?Credential = null,
};

/// The single credential resolution method. Walks the supported source precedence.
pub fn resolve(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    mode: LoadMode,
) !Resolution {
    return resolvePreferring(alloc, transport, secret_store, mode, null);
}

pub fn resolveForProvider(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    mode: LoadMode,
    provider: model_provider.ProviderId,
    preferred: ?Source,
) !Resolution {
    switch (provider) {
        .codex => {
            const credential = switch (mode) {
                .stored => try loadStoredChatGptCredential(alloc),
                .refresh_if_needed => try loadChatGptCredential(alloc, transport, .if_needed),
            };
            return .{ .credential = credential };
        },
        .grok => {
            const credential = switch (mode) {
                .stored => try loadStoredGrokCredential(alloc),
                .refresh_if_needed => try loadGrokCredential(alloc, transport, .if_needed),
            };
            return .{ .credential = credential };
        },
        .gateway => {},
    }
    return resolvePreferring(
        alloc,
        transport,
        secret_store,
        mode,
        if (preferred == .chatgpt_subscription or preferred == .grok_subscription) null else preferred,
    );
}

/// `preferred` is the source the user last chose in the hub. It wins over the
/// precedence order below, including over the environment, because it is an
/// explicit choice rather than a default. A preferred source that no longer
/// resolves falls through to precedence instead of failing.
pub fn resolvePreferring(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    mode: LoadMode,
    preferred: ?Source,
) !Resolution {
    if (preferred) |source| {
        const chosen = loadPreferredSource(alloc, transport, secret_store, mode, source) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            debug_trace.logf("auth", "preferred source load failed source={t} err={s}", .{ source, @errorName(err) });
            break :blk null;
        };
        if (chosen) |credential| return .{ .credential = credential };
        debug_trace.logf("auth", "preferred source unavailable source={t}; using precedence", .{source});
    }

    if (try loadSource(alloc, transport, secret_store, .openai_api_key)) |credential| return .{ .credential = credential };
    return .{};
}

/// Loading a subscription source may refresh an expired credential, which
/// `.stored` mode forbids: a diagnostic must not rewrite the session file or
/// make an OAuth request. Honour the mode for the preferred source too.
fn loadPreferredSource(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    mode: LoadMode,
    source: Source,
) !?Credential {
    return switch (source) {
        .chatgpt_subscription => switch (mode) {
            .stored => loadStoredChatGptCredential(alloc),
            .refresh_if_needed => loadChatGptCredential(alloc, transport, .if_needed),
        },
        .grok_subscription => switch (mode) {
            .stored => loadStoredGrokCredential(alloc),
            .refresh_if_needed => loadGrokCredential(alloc, transport, .if_needed),
        },
        else => loadSource(alloc, transport, secret_store, source),
    };
}

pub fn loadSource(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    _: host.SecretStore,
    source: Source,
) !?Credential {
    return switch (source) {
        .openai_api_key => loadEnvCredential(alloc, "OPENAI_API_KEY", source),
        .chatgpt_subscription => loadChatGptCredential(alloc, transport, .if_needed),
        .grok_subscription => loadGrokCredential(alloc, transport, .if_needed),
    };
}

pub fn sourceExists(
    alloc: std.mem.Allocator,
    _: host.SecretStore,
    source: Source,
) !bool {
    return switch (source) {
        .openai_api_key => nonEmptyEnvValue("OPENAI_API_KEY") != null,
        .chatgpt_subscription => chatgpt_oauth.sourceExists(alloc),
        .grok_subscription => grok_oauth.sourceExists(alloc),
    };
}

fn loadEnvCredential(
    alloc: std.mem.Allocator,
    name: []const u8,
    source: Source,
) !?Credential {
    const value = nonEmptyEnvValue(name) orelse return null;
    return .{
        .token = try alloc.dupe(u8, value),
        .source = source,
    };
}

fn loadChatGptCredential(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    mode: chatgpt_oauth.RefreshMode,
) !?Credential {
    var access = (try chatgpt_oauth.loadAccess(alloc, transport, mode)) orelse return null;
    defer access.deinit(alloc);
    const token = access.access_token;
    access.access_token = &.{};
    const account_id = access.account_id;
    access.account_id = &.{};
    return .{
        .token = token,
        .source = .chatgpt_subscription,
        .account_id = account_id,
        .refresh_after_ms = access.refresh_after_ms,
    };
}

fn loadStoredChatGptCredential(alloc: std.mem.Allocator) !?Credential {
    return loadChatGptCredential(alloc, oauth_transport.unavailable_provider, .stored);
}

fn loadGrokCredential(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
    mode: grok_oauth.RefreshMode,
) !?Credential {
    var access = (try grok_oauth.loadAccess(alloc, transport, mode)) orelse return null;
    defer access.deinit(alloc);
    const token = access.access_token;
    access.access_token = &.{};
    const account_id = access.account_id;
    access.account_id = &.{};
    return .{
        .token = token,
        .source = .grok_subscription,
        .account_id = account_id,
        .refresh_after_ms = access.refresh_after_ms,
    };
}

fn loadStoredGrokCredential(alloc: std.mem.Allocator) !?Credential {
    return loadGrokCredential(alloc, oauth_transport.unavailable_provider, .stored);
}

fn nonEmptyEnvValue(name: []const u8) ?[]const u8 {
    return nonEmptyValue(io_mod.getenv(name));
}

fn nonEmptyValue(value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return null;
    return raw;
}

pub fn refreshChatGptCredential(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
) !?Credential {
    return loadChatGptCredential(alloc, transport, .force);
}

pub fn refreshGrokCredential(
    alloc: std.mem.Allocator,
    transport: oauth_transport.Provider,
) !?Credential {
    return loadGrokCredential(alloc, transport, .force);
}

pub fn sourceLabel(source: Source) []const u8 {
    return switch (source) {
        .openai_api_key => "OPENAI_API_KEY",
        .chatgpt_subscription => "Codex subscription",
        .grok_subscription => "Grok subscription",
    };
}

pub fn sourceRefreshable(source: Source) bool {
    return source == .chatgpt_subscription or source == .grok_subscription;
}

test "missing credential messages use surface commands in preferred order" {
    try std.testing.expect(std.mem.find(u8, missing_credential_message, "OPENAI_API_KEY") != null);
    try std.testing.expect(std.mem.find(u8, missing_credential_message, "fx login codex") != null);
    try std.testing.expect(std.mem.find(u8, missing_interactive_credential_message, "/login") != null);
}

test "catalog access isolates public and authenticated provider credentials" {
    const missing = catalogAccessAt(null, 0);
    try std.testing.expectEqual(CatalogPublicOnlyReason.no_credential, missing.publicOnlyReason().?);
    try std.testing.expect(missing.credentialSource() == null);
    try std.testing.expect(missing.authorizationCredential() == null);

    const refresh_failed = catalogAccessAfterRefreshFailure(.chatgpt_subscription);
    try std.testing.expectEqual(CatalogPublicOnlyReason.credential_refresh_failed, refresh_failed.publicOnlyReason().?);
    try std.testing.expectEqual(Source.chatgpt_subscription, refresh_failed.credentialSource().?);

    const chatgpt = catalogAccessForCredential(
        .chatgpt_subscription,
        "chatgpt-secret",
    );
    try std.testing.expectEqual(Source.chatgpt_subscription, chatgpt.credentialSource().?);
    try std.testing.expectEqualStrings("chatgpt-secret", chatgpt.authorizationCredential().?);

    var grok_credential = Credential{
        .token = try std.testing.allocator.dupe(u8, "grok-secret"),
        .source = .grok_subscription,
        .account_id = try std.testing.allocator.dupe(u8, "acct_grok"),
    };
    defer grok_credential.deinit(std.testing.allocator);
    const grok = catalogAccessAt(grok_credential, 0);
    try std.testing.expectEqualStrings("acct_grok", grok.accountId().?);
}

test "authenticated catalog access carries a BYOK source" {
    var credential = Credential{
        .token = try std.testing.allocator.dupe(u8, "token"),
        .source = .openai_api_key,
    };
    defer credential.deinit(std.testing.allocator);

    const authenticated = catalogAccessAt(credential, 0);
    try std.testing.expect(authenticated.publicOnlyReason() == null);
    try std.testing.expectEqual(Source.openai_api_key, authenticated.credentialSource().?);
    try std.testing.expectEqualStrings("token", authenticated.authorizationCredential().?);
}

var stable_credential_test_environ: ?*std.process.Environ.Map = null;

fn stableCredentialTestEnviron() !*const std.process.Environ.Map {
    if (stable_credential_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_credential_test_environ = map;
    return map;
}

const CredentialTestEnv = struct {
    alloc: std.mem.Allocator,
    map: std.process.Environ.Map,

    /// Installs exactly `entries`, so anything the resolver reads from the real
    /// environment, `HOME` included, is absent for the duration of the test.
    fn install(alloc: std.mem.Allocator, entries: []const [2][]const u8) !*CredentialTestEnv {
        _ = try stableCredentialTestEnviron();

        const self = try alloc.create(CredentialTestEnv);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        for (entries) |entry| try self.map.put(entry[0], entry[1]);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *CredentialTestEnv) void {
        if (stable_credential_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

test "BYOK credential resolution loads OPENAI_API_KEY" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{
        .{ "OPENAI_API_KEY", "api-key" },
    });
    defer env.deinit();

    const resolution = try resolve(alloc, oauth_transport.unavailable_provider, host.unavailable_secret_store, .refresh_if_needed);
    var startup = resolution.credential orelse return error.TestExpectedCredential;
    defer startup.deinit(alloc);
    try std.testing.expectEqualStrings("api-key", startup.token);
    try std.testing.expectEqual(Source.openai_api_key, startup.source);
    try std.testing.expect(try sourceExists(alloc, host.unavailable_secret_store, .openai_api_key));
}

test "no remembered choice resolves exactly as plain precedence" {
    const alloc = std.testing.allocator;
    const env = try CredentialTestEnv.install(alloc, &.{
        .{ "OPENAI_API_KEY", "api-key" },
    });
    defer env.deinit();

    var preferred = try resolvePreferring(alloc, oauth_transport.unavailable_provider, host.unavailable_secret_store, .refresh_if_needed, null);
    defer if (preferred.credential) |*credential| credential.deinit(alloc);
    var plain = try resolve(alloc, oauth_transport.unavailable_provider, host.unavailable_secret_store, .refresh_if_needed);
    defer if (plain.credential) |*credential| credential.deinit(alloc);

    try std.testing.expectEqual(plain.credential.?.source, preferred.credential.?.source);
    try std.testing.expectEqualStrings(plain.credential.?.token, preferred.credential.?.token);
}
