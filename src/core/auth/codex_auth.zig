const std = @import("std");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const shared_types = @import("../shared/types.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

const auth_file_env = "FX_CODEX_AUTH_FILE";
const issuer_env = "FX_CODEX_ISSUER";
const token_url_env = "FX_CODEX_TOKEN_URL";
const revoke_url_env = "FX_CODEX_REVOKE_URL";
const client_id_env = "FX_CODEX_CLIENT_ID";

const codex_refresh_url_env = "CODEX_REFRESH_TOKEN_URL_OVERRIDE";
const codex_revoke_url_env = "CODEX_REVOKE_TOKEN_URL_OVERRIDE";
const codex_client_id_env = "CODEX_APP_SERVER_LOGIN_CLIENT_ID";

const default_issuer = "https://auth.openai.com";
const default_token_url = "https://auth.openai.com/oauth/token";
const default_revoke_url = "https://auth.openai.com/oauth/revoke";
const default_client_id = "app_EMoamEEZ73f0CkXaXp7hrann";

const refresh_early_seconds: i64 = 5 * 60;
const fallback_refresh_days: i64 = 8;
const max_auth_file_bytes: usize = 512 * 1024;
const max_jwt_payload_bytes: usize = 64 * 1024;
const mutation_lock_file_name = ".fx-codex-auth.lock";
const default_lock_deadline_ms: u64 = 2_000;

pub const Options = struct {
    /// Explicit values are primarily useful to embedders and tests. When null,
    /// the normal Codex/fx environment and defaults are resolved at call time.
    auth_file: ?[]const u8 = null,
    issuer: ?[]const u8 = null,
    token_url: ?[]const u8 = null,
    revoke_url: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    lock_deadline_ms: u64 = default_lock_deadline_ms,
};

pub const Transport = oauth_transport.Provider;

pub const Tokens = struct {
    id_token: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    account_id: []const u8,
};

pub const Loaded = struct {
    access_token: []u8,
    account_id: []u8,
    fedramp: bool,
    refresh_after_ms: ?i64,
    refreshable: bool,

    pub fn deinit(self: *Loaded, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        alloc.free(self.account_id);
        self.* = undefined;
    }

    pub fn needsRefreshAt(self: Loaded, now_ms: i64) bool {
        if (!self.refreshable) return false;
        return if (self.refresh_after_ms) |deadline| deadline <= now_ms else false;
    }
};

pub const LogoutResult = struct {
    credentials_cleared: bool = false,
    remote_revocation_failed: bool = false,
};

const TokenView = struct {
    id_token: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    account_id: ?[]const u8,
};

const RefreshResponse = struct {
    id_token: ?[]const u8,
    access_token: ?[]const u8,
    refresh_token: ?[]const u8,
    account_id: ?[]const u8,
};

const RefreshMode = enum {
    if_needed,
    force,
};

const Mutation = struct {
    alloc: Allocator,
    path: []u8,
    parent: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,

    fn deinit(self: *Mutation) void {
        self.lock.release();
        self.parent.close();
        self.alloc.free(self.path);
        self.* = undefined;
    }

    fn fileName(self: Mutation) []const u8 {
        return std.fs.path.basename(self.path);
    }

    fn read(self: *Mutation, alloc: Allocator) !?[]u8 {
        return readAuthFileFromDir(alloc, self.parent.dir, self.fileName());
    }

    fn write(self: *Mutation, alloc: Allocator, bytes: []const u8) !void {
        try io_mod.durableReplaceVerified(alloc, &self.parent, self.fileName(), bytes);
    }
};

fn resolveAuthFilePath(alloc: Allocator, options: Options) ![]u8 {
    return resolveAuthFilePathFrom(
        alloc,
        options.auth_file orelse nonEmptyEnv(auth_file_env),
        nonEmptyEnv("CODEX_HOME"),
        nonEmptyEnv("HOME"),
        nonEmptyEnv("USERPROFILE"),
    );
}

fn resolveAuthFilePathFrom(
    alloc: Allocator,
    explicit: ?[]const u8,
    codex_home: ?[]const u8,
    home: ?[]const u8,
    user_profile: ?[]const u8,
) ![]u8 {
    if (explicit) |path| return alloc.dupe(u8, path);
    if (codex_home) |path| return std.fs.path.join(alloc, &.{ path, "auth.json" });
    const user_home = home orelse user_profile orelse return error.HomeNotSet;
    return std.fs.path.join(alloc, &.{ user_home, ".codex", "auth.json" });
}

pub fn issuerUrl(options: Options) []const u8 {
    const value = options.issuer orelse nonEmptyEnv(issuer_env) orelse default_issuer;
    return std.mem.trimEnd(u8, value, "/");
}

fn tokenUrl(options: Options) []const u8 {
    return options.token_url orelse
        nonEmptyEnv(token_url_env) orelse
        nonEmptyEnv(codex_refresh_url_env) orelse
        default_token_url;
}

fn validatedTokenUrl(options: Options) ![]const u8 {
    const url = tokenUrl(options);
    try validateAuthEndpoint(url);
    return url;
}

pub fn clientId(options: Options) []const u8 {
    return options.client_id orelse
        nonEmptyEnv(client_id_env) orelse
        nonEmptyEnv(codex_client_id_env) orelse
        default_client_id;
}

fn revokeUrlAlloc(alloc: Allocator, options: Options) ![]u8 {
    if (options.revoke_url orelse
        nonEmptyEnv(revoke_url_env) orelse
        nonEmptyEnv(codex_revoke_url_env)) |url|
    {
        try validateAuthEndpoint(url);
        return alloc.dupe(u8, url);
    }

    var uri = std.Uri.parse(try validatedTokenUrl(options)) catch
        return error.InvalidCodexAuthEndpoint;
    uri.path = .{ .raw = "/oauth/revoke" };
    uri.query = null;
    uri.fragment = null;
    const url = try std.fmt.allocPrint(alloc, "{f}", .{uri});
    errdefer alloc.free(url);
    try validateAuthEndpoint(url);
    return url;
}

/// OAuth endpoints may use plain HTTP only on an explicit loopback port. This
/// keeps test and local-development issuers available without allowing a
/// refresh token to be redirected over cleartext to a remote host.
pub fn validateAuthEndpoint(url: []const u8) !void {
    if (url.len == 0) return error.InvalidCodexAuthEndpoint;
    for (url) |byte| {
        if (std.ascii.isWhitespace(byte) or std.ascii.isControl(byte)) {
            return error.InvalidCodexAuthEndpoint;
        }
    }

    const uri = std.Uri.parse(url) catch return error.InvalidCodexAuthEndpoint;
    if (uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null)
    {
        return error.InvalidCodexAuthEndpoint;
    }
    const host_component = uri.host orelse return error.InvalidCodexAuthEndpoint;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buffer) catch
        return error.InvalidCodexAuthEndpoint;
    if (host.len == 0) return error.InvalidCodexAuthEndpoint;

    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or uri.port == null or
        !isLoopbackHost(host))
    {
        return error.InsecureCodexAuthEndpoint;
    }
}

fn isLoopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]") or
        std.mem.eql(u8, host, "::1");
}

pub fn loadStored(alloc: Allocator, options: Options) !?Loaded {
    if (comptime host_target.is_wasm) return null;
    const path = try resolveAuthFilePath(alloc, options);
    defer alloc.free(path);
    const bytes = (try readAuthFileAtPath(alloc, path)) orelse return null;
    defer secret.zeroAndFree(alloc, bytes);
    return parseLoaded(alloc, bytes);
}

pub fn load(alloc: Allocator, transport: Transport, options: Options) !?Loaded {
    var loaded = (try loadStored(alloc, options)) orelse return null;
    if (!loaded.needsRefreshAt(io_mod.milliTimestamp())) return loaded;

    const refreshed = refreshGuarded(
        alloc,
        transport,
        options,
        loaded.access_token,
        .if_needed,
    ) catch |err| {
        loaded.deinit(alloc);
        return err;
    };
    loaded.deinit(alloc);
    return refreshed;
}

pub fn refresh(alloc: Allocator, transport: Transport, options: Options) !?Loaded {
    var before = (try loadStored(alloc, options)) orelse return null;
    defer before.deinit(alloc);
    return refreshGuarded(alloc, transport, options, before.access_token, .force);
}

pub fn persistTokens(alloc: Allocator, options: Options, tokens: Tokens) !void {
    if (comptime host_target.is_wasm) return error.CodexAuthUnavailable;
    if (tokens.id_token.len == 0 or
        tokens.access_token.len == 0 or
        tokens.refresh_token.len == 0)
    {
        return error.InvalidCodexTokens;
    }
    const account_id = (try accountIdForTokens(alloc, tokens)) orelse
        return error.InvalidCodexTokens;
    defer alloc.free(account_id);

    var mutation = (try beginMutation(alloc, options, true)).?;
    defer mutation.deinit();
    const existing = try mutation.read(alloc);
    defer if (existing) |bytes| secret.zeroAndFree(alloc, bytes);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = try parseMutableDocument(arena, existing orelse "{}");
    try replaceTokens(arena, &root, .{
        .id_token = tokens.id_token,
        .access_token = tokens.access_token,
        .refresh_token = tokens.refresh_token,
        .account_id = account_id,
    });
    try writeMutableDocument(alloc, &mutation, root);
}

pub fn logout(alloc: Allocator, transport: Transport, options: Options) !LogoutResult {
    if (comptime host_target.is_wasm) return error.CodexAuthUnavailable;
    const existing = blk: {
        var mutation = (try beginMutation(alloc, options, false)) orelse return .{};
        defer mutation.deinit();
        break :blk (try mutation.read(alloc)) orelse return .{};
    };
    defer secret.zeroAndFree(alloc, existing);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try parseMutableDocument(arena, existing);
    if (!isManagedChatgptRoot(root)) return .{};

    var result: LogoutResult = .{};
    if (root.object.get("tokens")) |tokens| {
        if (tokens == .object) {
            const refresh_token = objectString(tokens.object, "refresh_token") orelse "";
            const access_token = objectString(tokens.object, "access_token") orelse "";
            const revoke_token = if (refresh_token.len > 0) refresh_token else access_token;
            if (revoke_token.len > 0) {
                const kind: RevokeTokenKind = if (refresh_token.len > 0) .refresh else .access;
                revokeToken(alloc, transport, options, revoke_token, kind) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => result.remote_revocation_failed = true,
                };
            }
        }
    }

    // Codex CLI does not participate in fx's advisory lock. Reacquire the lock
    // after the remote request and compare the complete document so a login or
    // any other concurrent auth-file replacement cannot be overwritten with
    // the stale root parsed above.
    var mutation = (try beginMutation(alloc, options, false)) orelse return result;
    defer mutation.deinit();
    const current_bytes = (try mutation.read(alloc)) orelse return result;
    defer secret.zeroAndFree(alloc, current_bytes);
    if (!std.mem.eql(u8, existing, current_bytes)) return result;

    var current_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer current_arena_state.deinit();
    const current_arena = current_arena_state.allocator();
    var current_root = try parseMutableDocument(current_arena, current_bytes);
    if (current_root.object.getPtr("tokens")) |tokens| {
        if (tokens.* == .object) {
            _ = tokens.object.orderedRemove("id_token");
            _ = tokens.object.orderedRemove("access_token");
            _ = tokens.object.orderedRemove("refresh_token");
            _ = tokens.object.orderedRemove("account_id");
            if (tokens.object.count() == 0) _ = current_root.object.orderedRemove("tokens");
        }
    }
    if (objectString(current_root.object, "auth_mode")) |mode| {
        if (std.ascii.eqlIgnoreCase(mode, "chatgpt")) {
            _ = current_root.object.orderedRemove("auth_mode");
        }
    }
    _ = current_root.object.orderedRemove("last_refresh");
    try writeMutableDocument(alloc, &mutation, current_root);
    result.credentials_cleared = true;
    return result;
}

fn parseLoaded(alloc: Allocator, bytes: []const u8) !?Loaded {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCodexAuthFile,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCodexAuthFile;
    return loadedFromRoot(alloc, parsed.value);
}

pub fn accountIdFromJwt(alloc: Allocator, jwt: []const u8) !?[]u8 {
    const payload = (try decodeJwtPayload(alloc, jwt)) orelse return null;
    defer secret.zeroAndFree(alloc, payload);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const nested = parsed.value.object.get("https://api.openai.com/auth") orelse return null;
    if (nested != .object) return null;
    const account_id = objectString(nested.object, "chatgpt_account_id") orelse return null;
    return try alloc.dupe(u8, account_id);
}

fn jwtExpirationUnix(alloc: Allocator, jwt: []const u8) !?i64 {
    const payload = (try decodeJwtPayload(alloc, jwt)) orelse return null;
    defer secret.zeroAndFree(alloc, payload);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const exp = parsed.value.object.get("exp") orelse return null;
    return switch (exp) {
        .integer => |value| value,
        else => null,
    };
}

fn fedrampFromJwt(alloc: Allocator, jwt: []const u8) !bool {
    const payload = (try decodeJwtPayload(alloc, jwt)) orelse return false;
    defer secret.zeroAndFree(alloc, payload);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const nested = parsed.value.object.get("https://api.openai.com/auth") orelse return false;
    if (nested != .object) return false;
    const value = nested.object.get("chatgpt_account_is_fedramp") orelse return false;
    return value == .bool and value.bool;
}

const RevokeTokenKind = enum { access, refresh };

fn revokeToken(
    alloc: Allocator,
    transport: Transport,
    options: Options,
    token: []const u8,
    kind: RevokeTokenKind,
) !void {
    const url = try revokeUrlAlloc(alloc, options);
    defer alloc.free(url);

    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    try payload.writer.writeAll("{\"token\":");
    try std.json.Stringify.value(token, .{}, &payload.writer);
    try payload.writer.writeAll(",\"token_type_hint\":");
    try std.json.Stringify.value(
        if (kind == .refresh) "refresh_token" else "access_token",
        .{},
        &payload.writer,
    );
    if (kind == .refresh) {
        try payload.writer.writeAll(",\"client_id\":");
        try std.json.Stringify.value(clientId(options), .{}, &payload.writer);
    }
    try payload.writer.writeByte('}');

    var response = try transport.execute(alloc, .{
        .method = .post_json,
        .url = url,
        .payload = payload.written(),
    });
    defer response.deinit(alloc);
    if (response.disposition != .accepted or response.status.class() != .success) {
        return error.CodexRevokeRejected;
    }
}

fn refreshGuarded(
    alloc: Allocator,
    transport: Transport,
    options: Options,
    expected_access_token: []const u8,
    mode: RefreshMode,
) !?Loaded {
    if (comptime host_target.is_wasm) return error.CodexAuthUnavailable;
    const existing = blk: {
        var mutation = (try beginMutation(alloc, options, false)) orelse return null;
        defer mutation.deinit();
        break :blk (try mutation.read(alloc)) orelse return null;
    };
    defer secret.zeroAndFree(alloc, existing);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try parseMutableDocument(arena, existing);
    const current = tokenView(root) orelse return error.InvalidCodexAuthFile;

    if (!std.mem.eql(u8, current.access_token, expected_access_token)) {
        return loadedFromRoot(alloc, root);
    }
    if (mode == .if_needed) {
        var reloaded = (try loadedFromRoot(alloc, root)) orelse return error.InvalidCodexAuthFile;
        if (!reloaded.needsRefreshAt(io_mod.milliTimestamp())) return reloaded;
        reloaded.deinit(alloc);
    }
    if (current.refresh_token.len == 0) return error.CodexRefreshUnavailable;

    var request_body: std.Io.Writer.Allocating = .init(alloc);
    defer request_body.deinit();
    try request_body.writer.writeAll("{\"client_id\":");
    try std.json.Stringify.value(clientId(options), .{}, &request_body.writer);
    try request_body.writer.writeAll(",\"grant_type\":\"refresh_token\",\"refresh_token\":");
    try std.json.Stringify.value(current.refresh_token, .{}, &request_body.writer);
    try request_body.writer.writeByte('}');

    const refresh_url = try validatedTokenUrl(options);
    var response = transport.execute(alloc, .{
        .method = .post_json,
        .url = refresh_url,
        .payload = request_body.written(),
    }) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (try loadedAfterFailedRefreshIfChanged(
            alloc,
            options,
            existing,
            current,
        )) |changed| return changed;
        return err;
    };
    defer response.deinit(alloc);
    if (response.disposition != .accepted or response.status.class() != .success) {
        if (try loadedAfterFailedRefreshIfChanged(
            alloc,
            options,
            existing,
            current,
        )) |changed| return changed;
        return error.CodexRefreshRejected;
    }

    const refreshed = try parseRefreshResponse(arena, response.body);
    const next = Tokens{
        .id_token = refreshed.id_token orelse current.id_token,
        .access_token = refreshed.access_token orelse current.access_token,
        .refresh_token = refreshed.refresh_token orelse current.refresh_token,
        // Validate any refreshed JWT against the account that was reloaded
        // under the mutation lock before carrying its explicit ID forward.
        .account_id = refreshed.account_id orelse "",
    };
    if (next.access_token.len == 0 or next.refresh_token.len == 0) {
        return error.InvalidCodexRefreshResponse;
    }

    const current_account = try accountIdForView(alloc, current);
    defer if (current_account) |value| alloc.free(value);
    const next_account = try accountIdForTokens(alloc, next);
    defer if (next_account) |value| alloc.free(value);
    if (current_account) |expected| {
        if (next_account) |actual| {
            if (!std.mem.eql(u8, expected, actual)) return error.CodexAccountChanged;
        }
    }
    const stable_account = next_account orelse current_account orelse
        return error.InvalidCodexRefreshResponse;

    // The Codex CLI writes this file without taking fx's advisory lock. Commit
    // only if the complete document is still the snapshot used for the remote
    // refresh; otherwise prefer the newly installed credential over a stale
    // refresh response.
    var mutation = (try beginMutation(alloc, options, false)) orelse
        return error.CodexCredentialChanged;
    defer mutation.deinit();
    const current_bytes = (try mutation.read(alloc)) orelse
        return error.CodexCredentialChanged;
    defer secret.zeroAndFree(alloc, current_bytes);
    if (!std.mem.eql(u8, existing, current_bytes)) {
        const changed = try loadedAfterCredentialChangeForAccount(
            alloc,
            current_bytes,
            current,
        );
        return changed;
    }

    var current_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer current_arena_state.deinit();
    const current_arena = current_arena_state.allocator();
    var current_root = try parseMutableDocument(current_arena, current_bytes);
    try replaceTokens(current_arena, &current_root, .{
        .id_token = next.id_token,
        .access_token = next.access_token,
        .refresh_token = next.refresh_token,
        .account_id = stable_account,
    });
    try writeMutableDocument(alloc, &mutation, current_root);
    return loadedFromRoot(alloc, current_root);
}

fn loadedAfterCredentialChange(alloc: Allocator, bytes: []const u8) !Loaded {
    return (parseLoaded(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CodexCredentialChanged,
    }) orelse return error.CodexCredentialChanged;
}

fn loadedAfterCredentialChangeForAccount(
    alloc: Allocator,
    bytes: []const u8,
    previous: TokenView,
) !Loaded {
    const previous_account = (try accountIdForView(alloc, previous)) orelse
        return error.CodexCredentialChanged;
    defer alloc.free(previous_account);

    var changed = try loadedAfterCredentialChange(alloc, bytes);
    errdefer changed.deinit(alloc);
    if (!std.mem.eql(u8, previous_account, changed.account_id)) {
        return error.CodexCredentialChanged;
    }
    return changed;
}

fn loadedAfterFailedRefreshIfChanged(
    alloc: Allocator,
    options: Options,
    previous_bytes: []const u8,
    previous: TokenView,
) !?Loaded {
    // The remote refresh has already completed (or failed) before this lock is
    // acquired. Re-read the complete document so a concurrent winner can be
    // accepted without ever holding the mutation lock across network I/O.
    var mutation = (try beginMutation(alloc, options, false)) orelse
        return error.CodexCredentialChanged;
    defer mutation.deinit();
    const current_bytes = (try mutation.read(alloc)) orelse
        return error.CodexCredentialChanged;
    defer secret.zeroAndFree(alloc, current_bytes);
    if (std.mem.eql(u8, previous_bytes, current_bytes)) return null;
    return try loadedAfterCredentialChangeForAccount(
        alloc,
        current_bytes,
        previous,
    );
}

fn parseRefreshResponse(arena: Allocator, bytes: []const u8) !RefreshResponse {
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        bytes,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCodexRefreshResponse,
    };
    if (value != .object) return error.InvalidCodexRefreshResponse;
    return .{
        .id_token = objectString(value.object, "id_token"),
        .access_token = objectString(value.object, "access_token"),
        .refresh_token = objectString(value.object, "refresh_token"),
        .account_id = objectString(value.object, "account_id"),
    };
}

fn loadedFromRoot(alloc: Allocator, root: std.json.Value) !?Loaded {
    const view = tokenView(root) orelse return null;
    const account_id = (try accountIdForView(alloc, view)) orelse return error.InvalidCodexAuthFile;
    errdefer alloc.free(account_id);
    const access_token = try alloc.dupe(u8, view.access_token);
    errdefer secret.zeroAndFree(alloc, access_token);
    return .{
        .access_token = access_token,
        .account_id = account_id,
        .fedramp = if (view.id_token.len > 0)
            try fedrampFromJwt(alloc, view.id_token)
        else
            try fedrampFromJwt(alloc, view.access_token),
        .refresh_after_ms = try refreshDeadlineMs(alloc, root, view.access_token),
        .refreshable = view.refresh_token.len > 0,
    };
}

fn tokenView(root: std.json.Value) ?TokenView {
    if (!isManagedChatgptRoot(root)) return null;
    const token_value = root.object.get("tokens") orelse return null;
    if (token_value != .object) return null;
    const access_token = objectString(token_value.object, "access_token") orelse return null;
    if (access_token.len == 0) return null;
    return .{
        .id_token = objectString(token_value.object, "id_token") orelse "",
        .access_token = access_token,
        .refresh_token = objectString(token_value.object, "refresh_token") orelse "",
        .account_id = objectString(token_value.object, "account_id"),
    };
}

fn isManagedChatgptRoot(root: std.json.Value) bool {
    if (root != .object) return false;
    if (objectString(root.object, "auth_mode")) |mode| {
        return std.ascii.eqlIgnoreCase(mode, "chatgpt");
    }
    // Match Codex's legacy-mode resolution: an auth file without an explicit
    // mode is API-key auth when this field is present, ChatGPT otherwise.
    return objectString(root.object, "OPENAI_API_KEY") == null;
}

fn accountIdForView(alloc: Allocator, view: TokenView) !?[]u8 {
    return accountIdForIdentitySources(
        alloc,
        view.account_id,
        view.id_token,
        view.access_token,
    );
}

pub fn accountIdForTokens(alloc: Allocator, tokens: Tokens) !?[]u8 {
    return accountIdForIdentitySources(
        alloc,
        if (tokens.account_id.len > 0) tokens.account_id else null,
        tokens.id_token,
        tokens.access_token,
    );
}

fn accountIdForIdentitySources(
    alloc: Allocator,
    explicit_account_id: ?[]const u8,
    id_token: []const u8,
    access_token: []const u8,
) !?[]u8 {
    var resolved: ?[]u8 = if (explicit_account_id) |account_id|
        if (account_id.len > 0) try alloc.dupe(u8, account_id) else null
    else
        null;
    errdefer if (resolved) |account_id| alloc.free(account_id);

    for ([_][]const u8{ id_token, access_token }) |token| {
        if (token.len == 0) continue;
        const parsed = (try accountIdFromJwt(alloc, token)) orelse continue;
        if (resolved) |account_id| {
            if (!std.mem.eql(u8, account_id, parsed)) {
                alloc.free(parsed);
                return error.CodexAccountChanged;
            }
            alloc.free(parsed);
        } else {
            resolved = parsed;
        }
    }
    return resolved;
}

fn refreshDeadlineMs(
    alloc: Allocator,
    root: std.json.Value,
    access_token: []const u8,
) !?i64 {
    if (try jwtExpirationUnix(alloc, access_token)) |expires_at_seconds| {
        const refresh_seconds = std.math.sub(i64, expires_at_seconds, refresh_early_seconds) catch
            return std.math.minInt(i64);
        return std.math.mul(i64, refresh_seconds, std.time.ms_per_s) catch
            if (refresh_seconds < 0) std.math.minInt(i64) else std.math.maxInt(i64);
    }

    const last_refresh = objectString(root.object, "last_refresh") orelse return null;
    const refreshed_at_ms = shared_types.parseGatewayTimestamp(last_refresh) catch return null;
    const interval_ms = fallback_refresh_days * std.time.ms_per_day;
    return std.math.add(i64, refreshed_at_ms, interval_ms) catch std.math.maxInt(i64);
}

fn replaceTokens(arena: Allocator, root: *std.json.Value, tokens: Tokens) !void {
    if (root.* != .object) return error.InvalidCodexAuthFile;
    try putString(arena, &root.object, "auth_mode", "chatgpt");
    try root.object.put(arena, "OPENAI_API_KEY", .null);
    const last_refresh = try rfc3339UtcAlloc(arena, @divFloor(io_mod.milliTimestamp(), 1000));
    try putString(arena, &root.object, "last_refresh", last_refresh);

    var token_value = if (root.object.getPtr("tokens")) |value| blk: {
        if (value.* == .null) value.* = .{ .object = .empty };
        if (value.* != .object) return error.InvalidCodexAuthFile;
        break :blk value;
    } else blk: {
        try root.object.put(arena, "tokens", .{ .object = .empty });
        break :blk root.object.getPtr("tokens").?;
    };
    try putString(arena, &token_value.object, "id_token", tokens.id_token);
    try putString(arena, &token_value.object, "access_token", tokens.access_token);
    try putString(arena, &token_value.object, "refresh_token", tokens.refresh_token);
    try putString(arena, &token_value.object, "account_id", tokens.account_id);
}

fn putString(
    arena: Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: []const u8,
) !void {
    try object.put(arena, key, .{ .string = try arena.dupe(u8, value) });
}

fn parseMutableDocument(arena: Allocator, bytes: []const u8) !std.json.Value {
    const root = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        bytes,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCodexAuthFile,
    };
    if (root != .object) return error.InvalidCodexAuthFile;
    return root;
}

fn writeMutableDocument(
    alloc: Allocator,
    mutation: *Mutation,
    root: std.json.Value,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(root, .{ .whitespace = .indent_2 }, &out.writer);
    try mutation.write(alloc, out.written());
}

fn beginMutation(
    alloc: Allocator,
    options: Options,
    create_parent: bool,
) !?Mutation {
    const path = try resolveAuthFilePath(alloc, options);
    errdefer alloc.free(path);
    const file_name = std.fs.path.basename(path);
    if (file_name.len == 0 or
        std.mem.eql(u8, file_name, ".") or
        std.mem.eql(u8, file_name, ".."))
    {
        return error.InvalidCodexAuthPath;
    }
    const parent_path = std.fs.path.dirname(path) orelse ".";
    if (create_parent) try io_mod.makeDirRecursive(parent_path);

    var parent_dir = openParentDir(parent_path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    errdefer parent_dir.close(io_mod.getIo());
    var verified = io_mod.VerifiedDir{ .dir = parent_dir };
    errdefer verified.close();
    var lock = try io_mod.acquireTimedAdvisoryLock(
        &verified,
        mutation_lock_file_name,
        options.lock_deadline_ms,
    );
    errdefer lock.release();
    return .{
        .alloc = alloc,
        .path = path,
        .parent = verified,
        .lock = lock,
    };
}

fn readAuthFileAtPath(alloc: Allocator, path: []const u8) !?[]u8 {
    const parent_path = std.fs.path.dirname(path) orelse ".";
    var parent = openParentDir(parent_path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer parent.close(io_mod.getIo());
    return readAuthFileFromDir(alloc, parent, std.fs.path.basename(path));
}

fn readAuthFileFromDir(
    alloc: Allocator,
    parent: std.Io.Dir,
    file_name: []const u8,
) !?[]u8 {
    var file = io_mod.openExistingRegularFile(parent, file_name, .read_only) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes);
    return bytes;
}

fn openParentDir(path: []const u8) !std.Io.Dir {
    const options: std.Io.Dir.OpenOptions = .{
        .iterate = true,
        .follow_symlinks = false,
    };
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openDirAbsolute(io_mod.getIo(), path, options);
    }
    return std.Io.Dir.cwd().openDir(io_mod.getIo(), path, options);
}

fn decodeJwtPayload(alloc: Allocator, jwt: []const u8) !?[]u8 {
    var parts = std.mem.splitScalar(u8, jwt, '.');
    const header = parts.next() orelse return null;
    const encoded_with_padding = parts.next() orelse return null;
    const signature = parts.next() orelse return null;
    if (header.len == 0 or encoded_with_padding.len == 0 or signature.len == 0 or
        parts.next() != null)
    {
        return null;
    }

    const encoded = std.mem.trimEnd(u8, encoded_with_padding, "=");
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(encoded) catch return null;
    if (decoded_len > max_jwt_payload_bytes) return null;
    const payload = try alloc.alloc(u8, decoded_len);
    decoder.decode(payload, encoded) catch {
        secret.zeroAndFree(alloc, payload);
        return null;
    };
    return payload;
}

fn objectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| if (text.len == 0) null else text,
        else => null,
    };
}

fn nonEmptyEnv(name: []const u8) ?[]const u8 {
    const value = io_mod.getenv(name) orelse return null;
    return if (std.mem.trim(u8, value, " \t\r\n").len == 0) null else value;
}

fn rfc3339UtcAlloc(alloc: Allocator, timestamp_s: i64) ![]u8 {
    const days = @divFloor(timestamp_s, 86_400);
    var seconds = @mod(timestamp_s, 86_400);
    if (seconds < 0) seconds += 86_400;
    const hour: u6 = @intCast(@divFloor(seconds, 3_600));
    const minute: u6 = @intCast(@divFloor(@mod(seconds, 3_600), 60));
    const second: u6 = @intCast(@mod(seconds, 60));
    const civil = civilFromDays(days);
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        civil.year,
        civil.month,
        civil.day,
        hour,
        minute,
        second,
    });
}

const CivilDate = struct { year: i64, month: u8, day: u8 };

fn civilFromDays(days: i64) CivilDate {
    const shifted = days + 719_468;
    const era = @divFloor(shifted, 146_097);
    const day_of_era = shifted - era * 146_097;
    const year_of_era = @divFloor(
        day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36_524) -
            @divFloor(day_of_era, 146_096),
        365,
    );
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era -
        (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_prime = @divFloor(5 * day_of_year + 2, 153);
    const day: u8 = @intCast(day_of_year - @divFloor(153 * month_prime + 2, 5) + 1);
    const month_i = month_prime + (if (month_prime < 10) @as(i64, 3) else -9);
    year += if (month_i <= 2) 1 else 0;
    return .{ .year = year, .month = @intCast(month_i), .day = day };
}

fn encodeTestJwt(alloc: Allocator, payload: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded = try alloc.alloc(u8, encoder.calcSize(payload.len));
    defer alloc.free(encoded);
    _ = encoder.encode(encoded, payload);
    return std.fmt.allocPrint(alloc, "e30.{s}.sig", .{encoded});
}

const FakeTransport = struct {
    status: std.http.Status = .ok,
    response_body: []const u8 = "{}",
    execute_error: ?anyerror = null,
    calls: usize = 0,
    expected_method: ?oauth_transport.Method = null,
    expected_url: ?[]const u8 = null,
    required_payload_fragment: ?[]const u8 = null,
    replacement_auth_file: ?[]const u8 = null,
    replacement_tokens: ?Tokens = null,
    request_matched: bool = true,

    fn provider(self: *FakeTransport) Transport {
        return .{ .context = self, .execute_fn = execute };
    }

    fn execute(
        raw: ?*anyopaque,
        alloc: Allocator,
        request: oauth_transport.Request,
    ) !oauth_transport.Response {
        const self: *FakeTransport = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.expected_method) |method| {
            self.request_matched = self.request_matched and request.method == method;
        }
        if (self.expected_url) |url| {
            self.request_matched = self.request_matched and std.mem.eql(u8, request.url, url);
        }
        if (self.required_payload_fragment) |fragment| {
            self.request_matched = self.request_matched and
                request.payload != null and
                std.mem.find(u8, request.payload.?, fragment) != null;
        }
        if (self.replacement_tokens) |tokens| {
            const auth_file = self.replacement_auth_file orelse
                return error.TestReplacementAuthFileMissing;
            try persistTokens(alloc, .{ .auth_file = auth_file }, tokens);
            self.replacement_tokens = null;
        }
        if (self.execute_error) |err| return err;
        return .{
            .disposition = if (self.status.class() == .success) .accepted else .rejected,
            .status = self.status,
            .body = try alloc.dupe(u8, self.response_body),
        };
    }
};

test "codex auth path precedence is explicit then CODEX_HOME then user home" {
    const alloc = std.testing.allocator;
    const explicit = try resolveAuthFilePathFrom(
        alloc,
        "/tmp/explicit.json",
        "/tmp/codex",
        "/tmp/home",
        null,
    );
    defer alloc.free(explicit);
    try std.testing.expectEqualStrings("/tmp/explicit.json", explicit);

    const codex_home = try resolveAuthFilePathFrom(alloc, null, "/tmp/codex", "/tmp/home", null);
    defer alloc.free(codex_home);
    try std.testing.expectEqualStrings("/tmp/codex/auth.json", codex_home);

    const home = try resolveAuthFilePathFrom(alloc, null, null, "/tmp/home", null);
    defer alloc.free(home);
    try std.testing.expectEqualStrings("/tmp/home/.codex/auth.json", home);
}

test "codex auth endpoints require HTTPS except explicit loopback development" {
    try validateAuthEndpoint("https://auth.openai.com/oauth/token");
    try validateAuthEndpoint("http://127.0.0.1:43178/oauth/token");
    try validateAuthEndpoint("http://localhost:43178/oauth/revoke");

    try std.testing.expectError(
        error.InsecureCodexAuthEndpoint,
        validateAuthEndpoint("http://auth.example/oauth/token"),
    );
    try std.testing.expectError(
        error.InsecureCodexAuthEndpoint,
        validateAuthEndpoint("http://localhost/oauth/token"),
    );
    try std.testing.expectError(
        error.InvalidCodexAuthEndpoint,
        validateAuthEndpoint("https://user@auth.example/oauth/token"),
    );
    try std.testing.expectError(
        error.InvalidCodexAuthEndpoint,
        validateAuthEndpoint("https://auth.example/oauth/token?redirect=elsewhere"),
    );
}

test "codex auth parse uses JWT metadata and five minute refresh window" {
    const alloc = std.testing.allocator;
    const jwt = try encodeTestJwt(
        alloc,
        "{\"exp\":1700000000,\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_1\",\"chatgpt_account_is_fedramp\":true}}",
    );
    defer alloc.free(jwt);
    const document = try std.fmt.allocPrint(
        alloc,
        "{{\"auth_mode\":\"chatgpt\",\"tokens\":{{\"id_token\":\"{s}\",\"access_token\":\"{s}\",\"refresh_token\":\"refresh\"}}}}",
        .{ jwt, jwt },
    );
    defer alloc.free(document);

    var loaded = (try parseLoaded(alloc, document)).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("acct_1", loaded.account_id);
    try std.testing.expect(loaded.fedramp);
    try std.testing.expectEqual(
        @as(i64, (1_700_000_000 - refresh_early_seconds) * std.time.ms_per_s),
        loaded.refresh_after_ms.?,
    );
}

test "codex auth persist preserves unknown fields and atomically hardens json to 0600" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "auth.json",
        .data = "{\"OPENAI_API_KEY\":\"sk-old\",\"future_root\":{\"enabled\":true},\"tokens\":{\"future_token_field\":17}}",
    });
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "auth.json" });
    defer alloc.free(path);

    try persistTokens(alloc, .{ .auth_file = path }, .{
        .id_token = "id",
        .access_token = "access",
        .refresh_token = "refresh",
        .account_id = "acct",
    });

    const stat = try tmp.dir.statFile(std.testing.io, "auth.json", .{});
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0o600),
        stat.permissions.toMode() & 0o777,
    );
    const bytes = (try readAuthFileAtPath(alloc, path)).?;
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("OPENAI_API_KEY").? == .null);
    try std.testing.expect(parsed.value.object.get("future_root") != null);
    const token_value = parsed.value.object.get("tokens").?;
    try std.testing.expect(token_value.object.get("future_token_field") != null);
    try std.testing.expectEqualStrings(
        "access",
        token_value.object.get("access_token").?.string,
    );
}

test "codex auth persist rejects an explicit account that contradicts a JWT" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "auth.json" });
    defer alloc.free(path);
    const other_account_jwt = try encodeTestJwt(
        alloc,
        "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-new\"}}",
    );
    defer alloc.free(other_account_jwt);
    const old_account_jwt = try encodeTestJwt(
        alloc,
        "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-old\"}}",
    );
    defer alloc.free(old_account_jwt);

    try std.testing.expectError(
        error.CodexAccountChanged,
        persistTokens(alloc, .{ .auth_file = path }, .{
            .id_token = other_account_jwt,
            .access_token = other_account_jwt,
            .refresh_token = "refresh",
            .account_id = "acct-old",
        }),
    );
    try std.testing.expectError(
        error.CodexAccountChanged,
        persistTokens(alloc, .{ .auth_file = path }, .{
            .id_token = old_account_jwt,
            .access_token = other_account_jwt,
            .refresh_token = "refresh",
            .account_id = "",
        }),
    );
    const stored = try readAuthFileAtPath(alloc, path);
    defer if (stored) |bytes| secret.zeroAndFree(alloc, bytes);
    try std.testing.expect(stored == null);
}

test "codex auth refresh reloads under lock and skips a token already changed on disk" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "auth.json" });
    defer alloc.free(path);

    try persistTokens(alloc, .{ .auth_file = path }, .{
        .id_token = "e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdCJ9fQ.sig",
        .access_token = "new-access",
        .refresh_token = "new-refresh",
        .account_id = "acct",
    });
    var transport = FakeTransport{};
    var loaded = (try refreshGuarded(
        alloc,
        transport.provider(),
        .{ .auth_file = path },
        "stale-access",
        .force,
    )).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("new-access", loaded.access_token);
    try std.testing.expectEqual(@as(usize, 0), transport.calls);
}

test "codex auth refresh posts JSON, rotates tokens, and preserves unknown fields" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "auth.json" });
    defer alloc.free(path);

    const expired = try encodeTestJwt(
        alloc,
        "{\"exp\":1,\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct\"}}",
    );
    defer alloc.free(expired);
    const fresh_exp = @divFloor(io_mod.milliTimestamp(), std.time.ms_per_s) + 3_600;
    const fresh_payload = try std.fmt.allocPrint(
        alloc,
        "{{\"exp\":{d},\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"acct\"}}}}",
        .{fresh_exp},
    );
    defer alloc.free(fresh_payload);
    const fresh = try encodeTestJwt(alloc, fresh_payload);
    defer alloc.free(fresh);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "auth.json",
        .data = "{\"future_root\":9}",
    });
    try persistTokens(alloc, .{ .auth_file = path }, .{
        .id_token = expired,
        .access_token = expired,
        .refresh_token = "refresh-1",
        .account_id = "acct",
    });
    const response_body = try std.fmt.allocPrint(
        alloc,
        "{{\"id_token\":\"{s}\",\"access_token\":\"{s}\",\"refresh_token\":\"refresh-2\"}}",
        .{ fresh, fresh },
    );
    defer alloc.free(response_body);
    var transport = FakeTransport{
        .response_body = response_body,
        .expected_method = .post_json,
        .expected_url = "https://auth.test/oauth/token",
        .required_payload_fragment = "\"refresh_token\":\"refresh-1\"",
    };

    var loaded = (try load(alloc, transport.provider(), .{
        .auth_file = path,
        .token_url = "https://auth.test/oauth/token",
    })).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings(fresh, loaded.access_token);
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
    try std.testing.expect(transport.request_matched);

    const bytes = (try readAuthFileAtPath(alloc, path)).?;
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("future_root") != null);
}

test "codex auth refresh does not overwrite a concurrent Codex login" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "auth.json" });
    defer alloc.free(path);

    try persistTokens(alloc, .{ .auth_file = path }, .{
        .id_token = "old-id",
        .access_token = "old-access",
        .refresh_token = "old-refresh",
        .account_id = "acct-old",
    });
    var transport = FakeTransport{
        .response_body =
        \\{"id_token":"stale-id","access_token":"stale-access","refresh_token":"stale-refresh","account_id":"acct-old"}
        ,
        // The replacement runs synchronously from execute(), proving the
        // network phase does not retain fx's mutation lock.
        .replacement_auth_file = path,
        .replacement_tokens = .{
            .id_token = "new-login-id",
            .access_token = "new-login-access",
            .refresh_token = "new-login-refresh",
            .account_id = "acct-old",
        },
    };

    var loaded = (try refresh(alloc, transport.provider(), .{
        .auth_file = path,
        .lock_deadline_ms = 100,
    })).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("new-login-access", loaded.access_token);
    try std.testing.expectEqualStrings("acct-old", loaded.account_id);
    try std.testing.expectEqual(@as(usize, 1), transport.calls);

    var stored = (try loadStored(alloc, .{ .auth_file = path })).?;
    defer stored.deinit(alloc);
    try std.testing.expectEqualStrings("new-login-access", stored.access_token);
    try std.testing.expectEqualStrings("acct-old", stored.account_id);
}

test "codex auth refresh rejects a concurrent login for another account" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "auth.json" });
    defer alloc.free(path);

    try persistTokens(alloc, .{ .auth_file = path }, .{
        .id_token = "old-id",
        .access_token = "old-access",
        .refresh_token = "old-refresh",
        .account_id = "acct-old",
    });
    var transport = FakeTransport{
        .response_body =
        \\{"id_token":"stale-id","access_token":"stale-access","refresh_token":"stale-refresh","account_id":"acct-old"}
        ,
        .replacement_auth_file = path,
        .replacement_tokens = .{
            .id_token = "new-login-id",
            .access_token = "new-login-access",
            .refresh_token = "new-login-refresh",
            .account_id = "acct-new",
        },
    };

    try std.testing.expectError(
        error.CodexCredentialChanged,
        refresh(alloc, transport.provider(), .{
            .auth_file = path,
            .lock_deadline_ms = 100,
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), transport.calls);

    var stored = (try loadStored(alloc, .{ .auth_file = path })).?;
    defer stored.deinit(alloc);
    try std.testing.expectEqualStrings("new-login-access", stored.access_token);
    try std.testing.expectEqualStrings("acct-new", stored.account_id);
}

test "codex auth refresh accepts a same-account concurrent winner after rejection" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "auth.json" });
    defer alloc.free(path);

    try persistTokens(alloc, .{ .auth_file = path }, .{
        .id_token = "old-id",
        .access_token = "old-access",
        .refresh_token = "old-refresh",
        .account_id = "acct",
    });
    var transport = FakeTransport{
        .status = .unauthorized,
        .response_body = "{\"error\":\"invalid_grant\"}",
        .replacement_auth_file = path,
        .replacement_tokens = .{
            .id_token = "winner-id",
            .access_token = "winner-access",
            .refresh_token = "winner-refresh",
            .account_id = "acct",
        },
    };

    var loaded = (try refresh(alloc, transport.provider(), .{
        .auth_file = path,
        .lock_deadline_ms = 100,
    })).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("winner-access", loaded.access_token);
    try std.testing.expectEqualStrings("acct", loaded.account_id);
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
}

test "codex auth refresh preserves rejection when the document is unchanged" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "auth.json" });
    defer alloc.free(path);

    try persistTokens(alloc, .{ .auth_file = path }, .{
        .id_token = "old-id",
        .access_token = "old-access",
        .refresh_token = "old-refresh",
        .account_id = "acct",
    });
    var transport = FakeTransport{
        .status = .unauthorized,
        .response_body = "{\"error\":\"invalid_grant\"}",
    };

    try std.testing.expectError(
        error.CodexRefreshRejected,
        refresh(alloc, transport.provider(), .{
            .auth_file = path,
            .lock_deadline_ms = 100,
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
}

test "codex auth refresh accepts a same-account winner after transport failure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "auth.json" });
    defer alloc.free(path);

    try persistTokens(alloc, .{ .auth_file = path }, .{
        .id_token = "old-id",
        .access_token = "old-access",
        .refresh_token = "old-refresh",
        .account_id = "acct",
    });
    var transport = FakeTransport{
        .execute_error = error.ConnectionResetByPeer,
        .replacement_auth_file = path,
        .replacement_tokens = .{
            .id_token = "winner-id",
            .access_token = "winner-access",
            .refresh_token = "winner-refresh",
            .account_id = "acct",
        },
    };

    var loaded = (try refresh(alloc, transport.provider(), .{
        .auth_file = path,
        .lock_deadline_ms = 100,
    })).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("winner-access", loaded.access_token);
    try std.testing.expectEqualStrings("acct", loaded.account_id);
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
}

test "codex auth refresh rejects a rotated JWT despite a stale explicit account" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "auth.json" });
    defer alloc.free(path);

    const old_jwt = try encodeTestJwt(
        alloc,
        "{\"exp\":1,\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-old\"}}",
    );
    defer alloc.free(old_jwt);
    const new_jwt = try encodeTestJwt(
        alloc,
        "{\"exp\":4102444800,\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-new\"}}",
    );
    defer alloc.free(new_jwt);
    try persistTokens(alloc, .{ .auth_file = path }, .{
        .id_token = old_jwt,
        .access_token = old_jwt,
        .refresh_token = "refresh-old",
        .account_id = "acct-old",
    });

    const response_body = try std.fmt.allocPrint(
        alloc,
        "{{\"id_token\":\"{s}\",\"access_token\":\"{s}\",\"refresh_token\":\"refresh-new\",\"account_id\":\"acct-old\"}}",
        .{ new_jwt, new_jwt },
    );
    defer alloc.free(response_body);
    var transport = FakeTransport{ .response_body = response_body };
    try std.testing.expectError(
        error.CodexAccountChanged,
        load(alloc, transport.provider(), .{ .auth_file = path }),
    );

    var loaded = (try loadStored(alloc, .{ .auth_file = path })).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings(old_jwt, loaded.access_token);
    try std.testing.expectEqualStrings("acct-old", loaded.account_id);
}

test "codex auth logout revokes at oauth revoke and retains unrelated document fields" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "auth.json" });
    defer alloc.free(path);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "auth.json",
        .data = "{\"future_root\":\"keep\",\"tokens\":{\"future_token_field\":17}}",
    });
    try persistTokens(alloc, .{ .auth_file = path }, .{
        .id_token = "id",
        .access_token = "access",
        .refresh_token = "refresh",
        .account_id = "acct",
    });

    var transport = FakeTransport{
        .expected_method = .post_json,
        .expected_url = "https://auth.test/oauth/revoke",
        .required_payload_fragment = "\"token_type_hint\":\"refresh_token\"",
    };
    const result = try logout(alloc, transport.provider(), .{
        .auth_file = path,
        .token_url = "https://auth.test/oauth/token",
    });
    try std.testing.expect(result.credentials_cleared);
    try std.testing.expect(!result.remote_revocation_failed);
    try std.testing.expect(transport.request_matched);

    const bytes = (try readAuthFileAtPath(alloc, path)).?;
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "keep",
        parsed.value.object.get("future_root").?.string,
    );
    const remaining_tokens = parsed.value.object.get("tokens").?;
    try std.testing.expectEqual(
        @as(i64, 17),
        remaining_tokens.object.get("future_token_field").?.integer,
    );
    try std.testing.expect(remaining_tokens.object.get("access_token") == null);
    try std.testing.expect(parsed.value.object.get("auth_mode") == null);
    try std.testing.expect(parsed.value.object.get("last_refresh") == null);
}

test "codex auth logout does not clear a concurrent Codex login" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "auth.json" });
    defer alloc.free(path);

    try persistTokens(alloc, .{ .auth_file = path }, .{
        .id_token = "old-id",
        .access_token = "old-access",
        .refresh_token = "old-refresh",
        .account_id = "acct-old",
    });
    var transport = FakeTransport{
        .replacement_auth_file = path,
        .replacement_tokens = .{
            .id_token = "new-login-id",
            .access_token = "new-login-access",
            .refresh_token = "new-login-refresh",
            .account_id = "acct-new",
        },
    };

    const result = try logout(alloc, transport.provider(), .{
        .auth_file = path,
        .lock_deadline_ms = 100,
    });
    try std.testing.expect(!result.credentials_cleared);
    try std.testing.expect(!result.remote_revocation_failed);
    try std.testing.expectEqual(@as(usize, 1), transport.calls);

    var stored = (try loadStored(alloc, .{ .auth_file = path })).?;
    defer stored.deinit(alloc);
    try std.testing.expectEqualStrings("new-login-access", stored.access_token);
    try std.testing.expectEqualStrings("acct-new", stored.account_id);
}
