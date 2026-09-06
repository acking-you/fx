//! Device authorization protocols. Session identity and persistence stay with
//! each provider; this module owns only request, polling, and wire validation.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const login_flow = @import("login_flow.zig");
const oauth = @import("oauth.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");
const Allocator = std.mem.Allocator;

const Protocol = enum { codex, grok };
pub const Config = struct {
    protocol: Protocol,
    issuer: []const u8,
    token_endpoint: []const u8,
    client_id: []const u8,
    scope: []const u8 = "",
};

pub const Context = struct {
    protocol: Protocol,
    transport: oauth_transport.Provider,
    client_id: []u8,
    device_code: []u8,
    user_code: []u8,
    poll_endpoint: []u8,
    redirect_uri: []u8,
};

pub const Prepared = struct {
    flow: login_flow.PreparedLogin,
    context: *Context,
};

pub fn deinitContext(raw: ?*anyopaque, alloc: Allocator) void {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    alloc.free(context.client_id);
    secret.zeroAndFree(alloc, context.device_code);
    secret.zeroAndFree(alloc, context.user_code);
    alloc.free(context.poll_endpoint);
    alloc.free(context.redirect_uri);
    alloc.destroy(context);
}

/// Returns owned flow and context. Transfer both to SignInRuntime together.
pub fn prepare(alloc: Allocator, transport: oauth_transport.Provider, config: Config, cancel_flag: *std.atomic.Value(bool)) !Prepared {
    const issuer = std.mem.trimEnd(u8, config.issuer, "/");
    const request_url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ issuer, switch (config.protocol) {
        .codex => "/api/accounts/deviceauth/usercode",
        .grok => "/oauth2/device/code",
    } });
    defer alloc.free(request_url);
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    switch (config.protocol) {
        .codex => try std.json.Stringify.value(.{ .client_id = config.client_id }, .{}, &body.writer),
        .grok => try writeForm(&body.writer, &.{ .{ "client_id", config.client_id }, .{ "scope", config.scope }, .{ "referrer", "grok-build" } }),
    }
    var response = try transport.execute(alloc, .{
        .method = if (config.protocol == .codex) .post_json else .post_form,
        .url = request_url,
        .payload = body.written(),
        .cancel_flag = cancel_flag,
        .deadline = .fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(login_flow.poll_request_timeout_ms) }),
    });
    defer response.deinit(alloc);
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (response.disposition != .accepted) return if (response.status == .not_found) error.DeviceLoginUnavailable else error.DeviceCodeRequestFailed;
    var parsed = try parseResponse(alloc, response.body);
    defer parsed.deinit();
    const root = parsed.value;
    const code = try requiredString(root, if (config.protocol == .codex) "device_auth_id" else "device_code");
    const user_code = if (config.protocol == .codex and root.object.get("user_code") == null)
        try requiredString(root, "usercode")
    else
        try requiredString(root, "user_code");
    if (user_code.len > 128) return error.InvalidDeviceCodeResponse;
    for (user_code) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return error.InvalidDeviceCodeResponse;
    const verification_uri = if (config.protocol == .codex)
        try std.fmt.allocPrint(alloc, "{s}/codex/device", .{issuer})
    else
        try alloc.dupe(u8, try requiredString(root, "verification_uri"));
    errdefer alloc.free(verification_uri);
    try validateVerificationUri(verification_uri);
    const complete_uri = if (root.object.get("verification_uri_complete")) |value| if (value == .null) verification_uri else try string(value) else verification_uri;
    try validateVerificationUri(complete_uri);
    const expires = if (config.protocol == .codex) 15 * 60 else try positiveInteger(root, "expires_in", null);
    const interval = try positiveInteger(root, "interval", 5);
    _ = try oauth.expiry_timestamp_ms(io_mod.milliTimestamp(), expires);
    _ = try std.math.mul(i64, interval, std.time.ms_per_s);

    const authorization_url = try alloc.dupe(u8, complete_uri);
    errdefer alloc.free(authorization_url);
    const display_code = try alloc.dupe(u8, user_code);
    errdefer secret.zeroAndFree(alloc, display_code);
    const token_endpoint = try alloc.dupe(u8, config.token_endpoint);
    errdefer alloc.free(token_endpoint);
    const client_id = try alloc.dupe(u8, config.client_id);
    errdefer alloc.free(client_id);
    const device_code = try alloc.dupe(u8, code);
    errdefer secret.zeroAndFree(alloc, device_code);
    const owned_user_code = try alloc.dupe(u8, user_code);
    errdefer secret.zeroAndFree(alloc, owned_user_code);
    const poll_endpoint = if (config.protocol == .codex)
        try std.fmt.allocPrint(alloc, "{s}/api/accounts/deviceauth/token", .{issuer})
    else
        try alloc.dupe(u8, config.token_endpoint);
    errdefer alloc.free(poll_endpoint);
    const redirect_uri = try std.fmt.allocPrint(alloc, "{s}/deviceauth/callback", .{issuer});
    errdefer alloc.free(redirect_uri);
    const context = try alloc.create(Context);
    context.* = .{ .protocol = config.protocol, .transport = transport, .client_id = client_id, .device_code = device_code, .user_code = owned_user_code, .poll_endpoint = poll_endpoint, .redirect_uri = redirect_uri };
    return .{ .flow = .{
        .token_endpoint = token_endpoint,
        .authorization_url = authorization_url,
        .verification_uri = verification_uri,
        .user_code = display_code,
        .expires_in_seconds = expires,
        .poll_interval_seconds = interval,
        .delay_first_poll = true,
    }, .context = context };
}

pub fn poll(raw: ?*anyopaque, alloc: Allocator, transport: oauth_transport.Provider, token_endpoint: []const u8, cancel_flag: *std.atomic.Value(bool), deadline: std.Io.Clock.Timestamp) !oauth.PollResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const context: *Context = @ptrCast(@alignCast(raw.?));
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer {
        std.crypto.secureZero(u8, @constCast(body.written()));
        body.deinit();
    }
    switch (context.protocol) {
        .codex => try std.json.Stringify.value(.{ .device_auth_id = context.device_code, .user_code = context.user_code }, .{}, &body.writer),
        .grok => try writeForm(&body.writer, &.{ .{ "grant_type", "urn:ietf:params:oauth:grant-type:device_code" }, .{ "device_code", context.device_code }, .{ "client_id", context.client_id } }),
    }
    var response = try transport.execute(alloc, .{
        .method = if (context.protocol == .codex) .post_json else .post_form,
        .url = context.poll_endpoint,
        .payload = body.written(),
        .cancel_flag = cancel_flag,
        .deadline = deadline,
    });
    defer response.deinit(alloc);
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (response.disposition != .accepted) {
        if (context.protocol == .codex and (response.status == .forbidden or response.status == .not_found)) return .pending;
        var parsed = try parseResponse(alloc, response.body);
        defer parsed.deinit();
        const code = try requiredString(parsed.value, "error");
        if (std.mem.eql(u8, code, "authorization_pending")) return .pending;
        if (std.mem.eql(u8, code, "slow_down")) return .slow_down;
        if (std.mem.eql(u8, code, "access_denied")) return error.DeviceAuthorizationDenied;
        if (std.mem.eql(u8, code, "expired_token")) return error.DeviceCodeExpired;
        return error.DeviceTokenRequestFailed;
    }
    if (context.protocol == .grok) return .{ .success = try parseTokens(alloc, response.body) };

    // Codex issues an authorization code and PKCE verifier, which are then
    // exchanged against its ordinary token endpoint without a local callback.
    var parsed = try parseResponse(alloc, response.body);
    defer parsed.deinit();
    var exchange_body: std.Io.Writer.Allocating = .init(alloc);
    defer {
        std.crypto.secureZero(u8, @constCast(exchange_body.written()));
        exchange_body.deinit();
    }
    try writeForm(&exchange_body.writer, &.{
        .{ "grant_type", "authorization_code" },
        .{ "client_id", context.client_id },
        .{ "code", try requiredString(parsed.value, "authorization_code") },
        .{ "code_verifier", try requiredString(parsed.value, "code_verifier") },
        .{ "redirect_uri", context.redirect_uri },
    });
    var exchanged = try transport.execute(alloc, .{ .method = .post_form, .url = token_endpoint, .payload = exchange_body.written(), .cancel_flag = cancel_flag, .deadline = deadline });
    defer exchanged.deinit(alloc);
    if (exchanged.disposition != .accepted) return error.DeviceTokenExchangeFailed;
    return .{ .success = try parseTokens(alloc, exchanged.body) };
}

fn parseResponse(alloc: Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    if (bytes.len > 1024 * 1024) return error.InvalidDeviceCodeResponse;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    if (parsed.value != .object) {
        parsed.deinit();
        return error.InvalidDeviceCodeResponse;
    }
    return parsed;
}

fn string(value: std.json.Value) ![]const u8 {
    if (value != .string or value.string.len == 0 or value.string.len > 16 * 1024) return error.InvalidDeviceCodeResponse;
    return value.string;
}

fn requiredString(root: std.json.Value, name: []const u8) ![]const u8 {
    return string(root.object.get(name) orelse return error.InvalidDeviceCodeResponse);
}

fn positiveInteger(root: std.json.Value, name: []const u8, default: ?i64) !i64 {
    const value = root.object.get(name) orelse return default orelse error.InvalidDeviceCodeResponse;
    if (value == .null) return default orelse error.InvalidDeviceCodeResponse;
    const number = switch (value) {
        .integer => value.integer,
        .string => std.fmt.parseInt(i64, std.mem.trim(u8, value.string, " \t"), 10) catch return error.InvalidDeviceCodeResponse,
        else => return error.InvalidDeviceCodeResponse,
    };
    if (number <= 0) return error.InvalidDeviceCodeResponse;
    return number;
}

fn validateVerificationUri(value: []const u8) !void {
    for (value) |byte| if (byte < 0x21 or byte == 0x7f) return error.InvalidDeviceVerificationUri;
    const uri = std.Uri.parse(value) catch return error.InvalidDeviceVerificationUri;
    if (uri.host == null or uri.user != null or uri.password != null or
        (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http"))) return error.InvalidDeviceVerificationUri;
}

fn parseTokens(alloc: Allocator, bytes: []const u8) !oauth.TokenSet {
    var parsed = try parseResponse(alloc, bytes);
    defer parsed.deinit();
    const access = try alloc.dupe(u8, try requiredString(parsed.value, "access_token"));
    errdefer secret.zeroAndFree(alloc, access);
    const refresh = try alloc.dupe(u8, try requiredString(parsed.value, "refresh_token"));
    errdefer secret.zeroAndFree(alloc, refresh);
    return .{ .access_token = access, .refresh_token = refresh, .expires_in = try positiveInteger(parsed.value, "expires_in", 3600), .scope = &.{}, .token_type = &.{} };
}

fn writeForm(writer: *std.Io.Writer, fields: []const [2][]const u8) !void {
    const hex = "0123456789ABCDEF";
    for (fields, 0..) |field, index| {
        if (index > 0) try writer.writeByte('&');
        for (field, 0..) |part, part_index| {
            if (part_index > 0) try writer.writeByte('=');
            for (part) |byte| {
                if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
                    try writer.writeByte(byte);
                } else {
                    try writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 0xf] });
                }
            }
        }
    }
}

const TestTransport = struct {
    protocol: Protocol,
    calls: usize = 0,
    failure: ?[]const u8 = null,

    fn execute(raw: ?*anyopaque, alloc: Allocator, request: oauth_transport.Request) !oauth_transport.Response {
        const self: *TestTransport = @ptrCast(@alignCast(raw.?));
        const call = self.calls;
        self.calls += 1;
        var status: std.http.Status = .ok;
        const body: []const u8 = body: {
            if (call == 0) break :body switch (self.protocol) {
                .codex => "{\"device_auth_id\":\"private-id\",\"usercode\":\"CODE-1234\",\"interval\":\"1\"}",
                .grok => "{\"device_code\":\"private-id\",\"user_code\":\"CODE-1234\",\"verification_uri\":\"https://accounts.example/device\",\"verification_uri_complete\":\"https://accounts.example/device?user_code=CODE-1234\",\"expires_in\":900,\"interval\":1}",
            };
            if (self.failure) |failure| {
                status = .bad_request;
                break :body failure;
            }
            if (call == 1) {
                status = if (self.protocol == .codex) .forbidden else .bad_request;
                break :body "{\"error\":\"authorization_pending\"}";
            }
            if (self.protocol == .codex and call == 2) {
                try std.testing.expectEqual(oauth_transport.Method.post_json, request.method);
                try std.testing.expect(std.mem.endsWith(u8, request.url, "/api/accounts/deviceauth/token"));
                break :body "{\"authorization_code\":\"issued-code\",\"code_verifier\":\"pkce-verifier\"}";
            }
            if (self.protocol == .codex) {
                try std.testing.expect(std.mem.find(u8, request.payload.?, "redirect_uri=https%3A%2F%2Fauth.example%2Fdeviceauth%2Fcallback") != null);
                try std.testing.expect(std.mem.find(u8, request.payload.?, "code_verifier=pkce-verifier") != null);
            } else {
                try std.testing.expect(std.mem.find(u8, request.payload.?, "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code") != null);
            }
            break :body "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_in\":3600}";
        };
        return .{ .status = status, .disposition = if (status == .ok) .accepted else .rejected, .body = try alloc.dupe(u8, body) };
    }

    fn provider(self: *TestTransport) oauth_transport.Provider {
        return .{ .context = self, .execute_fn = execute };
    }
};

fn allocationTest(alloc: Allocator, protocol: Protocol) !void {
    var transport = TestTransport{ .protocol = protocol };
    var cancelled: std.atomic.Value(bool) = .init(false);
    var prepared = try prepare(alloc, transport.provider(), .{ .protocol = protocol, .issuer = "https://auth.example", .token_endpoint = "https://auth.example/token", .client_id = "client", .scope = "openid offline_access" }, &cancelled);
    defer prepared.flow.deinit(alloc);
    defer deinitContext(prepared.context, alloc);
    try std.testing.expectEqualStrings("CODE-1234", prepared.flow.user_code.?);
    try std.testing.expect(prepared.flow.delay_first_poll);
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromSeconds(5) });
    try std.testing.expectEqual(oauth.PollResult.pending, try poll(prepared.context, alloc, transport.provider(), prepared.flow.token_endpoint, &cancelled, deadline));
    var result = try poll(prepared.context, alloc, transport.provider(), prepared.flow.token_endpoint, &cancelled, deadline);
    defer if (result == .success) result.success.deinit(alloc);
    try std.testing.expectEqualStrings("access", result.success.access_token);
}

test "device OAuth preserves both provider protocols and frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationTest, .{Protocol.codex});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationTest, .{Protocol.grok});
}

test "device OAuth classifies slow down denial and expiry without exposing private codes" {
    const alloc = std.testing.allocator;
    var transport = TestTransport{ .protocol = .grok };
    var cancelled: std.atomic.Value(bool) = .init(false);
    var prepared = try prepare(alloc, transport.provider(), .{ .protocol = .grok, .issuer = "https://auth.example", .token_endpoint = "https://auth.example/token", .client_id = "client" }, &cancelled);
    defer prepared.flow.deinit(alloc);
    defer deinitContext(prepared.context, alloc);
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromSeconds(5) });
    transport.failure = "{\"error\":\"slow_down\"}";
    try std.testing.expectEqual(oauth.PollResult.slow_down, try poll(prepared.context, alloc, transport.provider(), prepared.flow.token_endpoint, &cancelled, deadline));
    transport.failure = "{\"error\":\"access_denied\"}";
    try std.testing.expectError(error.DeviceAuthorizationDenied, poll(prepared.context, alloc, transport.provider(), prepared.flow.token_endpoint, &cancelled, deadline));
    transport.failure = "{\"error\":\"expired_token\"}";
    try std.testing.expectError(error.DeviceCodeExpired, poll(prepared.context, alloc, transport.provider(), prepared.flow.token_endpoint, &cancelled, deadline));
    try std.testing.expectError(error.InvalidDeviceVerificationUri, validateVerificationUri("javascript:alert(1)"));
    try std.testing.expectError(error.InvalidDeviceVerificationUri, validateVerificationUri("https://user:password@example.com/device"));
}
