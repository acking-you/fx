const std = @import("std");
const codex_auth = @import("codex_auth.zig");
const io_mod = @import("../shared/io.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

pub const Options = codex_auth.Options;
pub const Transport = oauth_transport.Provider;

const login_timeout_ms: i64 = 15 * std.time.ms_per_min;
const request_timeout_ms: i64 = 15 * std.time.ms_per_s;
const poll_wait_slice_ms: u64 = 100;
const max_response_bytes: usize = 512 * 1024;
const max_device_interval_seconds: u64 = @intCast(@divExact(login_timeout_ms, std.time.ms_per_s));

const Control = struct {
    cancel_flag: ?*std.atomic.Value(bool) = null,
    deadline: ?std.Io.Clock.Timestamp = null,
};

pub const DeviceCode = struct {
    verification_url: []u8,
    user_code: []u8,
    device_auth_id: []u8,
    interval_seconds: u64,

    pub fn deinit(self: *DeviceCode, alloc: Allocator) void {
        alloc.free(self.verification_url);
        secret.zeroAndFree(alloc, self.user_code);
        secret.zeroAndFree(alloc, self.device_auth_id);
        self.* = undefined;
    }
};

const AuthorizationGrant = struct {
    authorization_code: []u8,
    code_challenge: []u8,
    code_verifier: []u8,

    pub fn deinit(self: *AuthorizationGrant, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.authorization_code);
        secret.zeroAndFree(alloc, self.code_challenge);
        secret.zeroAndFree(alloc, self.code_verifier);
        self.* = undefined;
    }
};

const PollResult = union(enum) {
    pending,
    granted: AuthorizationGrant,
};

const ExchangedTokens = struct {
    id_token: []u8,
    access_token: []u8,
    refresh_token: []u8,
    account_id: []u8,

    pub fn deinit(self: *ExchangedTokens, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.id_token);
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.refresh_token);
        alloc.free(self.account_id);
        self.* = undefined;
    }

    pub fn authTokens(self: ExchangedTokens) codex_auth.Tokens {
        return .{
            .id_token = self.id_token,
            .access_token = self.access_token,
            .refresh_token = self.refresh_token,
            .account_id = self.account_id,
        };
    }
};

/// Starts the ChatGPT device-code flow. The caller owns the returned fields and
/// may show `verification_url` and `user_code` before calling `completeLogin`.
pub fn requestDeviceCode(
    alloc: Allocator,
    transport: Transport,
    options: Options,
) !DeviceCode {
    return requestDeviceCodeBounded(alloc, transport, options, .{});
}

fn requestDeviceCodeBounded(
    alloc: Allocator,
    transport: Transport,
    options: Options,
    control: Control,
) !DeviceCode {
    const issuer = try validatedIssuer(options);
    const url = try endpointAlloc(alloc, issuer, "/api/accounts/deviceauth/usercode");
    defer alloc.free(url);

    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    try payload.writer.writeAll("{\"client_id\":");
    try std.json.Stringify.value(codex_auth.clientId(options), .{}, &payload.writer);
    try payload.writer.writeByte('}');

    var response = try transport.execute(alloc, .{
        .method = .post_json,
        .url = url,
        .payload = payload.written(),
        .cancel_flag = control.cancel_flag,
        .deadline = control.deadline,
    });
    defer response.deinit(alloc);
    if (response.status == .not_found) return error.CodexDeviceCodeUnavailable;
    if (!accepted(response)) return error.CodexDeviceCodeRejected;
    if (response.body.len > max_response_bytes) return error.CodexLoginResponseTooLarge;
    return parseDeviceCodeResponse(alloc, issuer, response.body);
}

/// Performs one JSON poll against the Codex device authorization endpoint.
/// HTTP 403 and 404 mean the browser flow has not completed yet.
fn pollDeviceCode(
    alloc: Allocator,
    transport: Transport,
    options: Options,
    device: DeviceCode,
    control: Control,
) !PollResult {
    const issuer = try validatedIssuer(options);
    const url = try endpointAlloc(alloc, issuer, "/api/accounts/deviceauth/token");
    defer alloc.free(url);

    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    try payload.writer.writeAll("{\"device_auth_id\":");
    try std.json.Stringify.value(device.device_auth_id, .{}, &payload.writer);
    try payload.writer.writeAll(",\"user_code\":");
    try std.json.Stringify.value(device.user_code, .{}, &payload.writer);
    try payload.writer.writeByte('}');

    var response = try transport.execute(alloc, .{
        .method = .post_json,
        .url = url,
        .payload = payload.written(),
        .cancel_flag = control.cancel_flag,
        .deadline = control.deadline,
    });
    defer response.deinit(alloc);
    if (response.status == .forbidden or response.status == .not_found) return .pending;
    if (!accepted(response)) return error.CodexDeviceAuthorizationRejected;
    if (response.body.len > max_response_bytes) return error.CodexLoginResponseTooLarge;
    return .{ .granted = try parseAuthorizationGrant(alloc, response.body) };
}

/// Exchanges the short-lived authorization grant for managed ChatGPT tokens.
fn exchangeAuthorizationGrant(
    alloc: Allocator,
    transport: Transport,
    options: Options,
    grant: AuthorizationGrant,
    control: Control,
) !ExchangedTokens {
    const issuer = try validatedIssuer(options);
    const url = try endpointAlloc(alloc, issuer, "/oauth/token");
    defer alloc.free(url);
    const redirect_uri = try endpointAlloc(alloc, issuer, "/deviceauth/callback");
    defer alloc.free(redirect_uri);

    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    var form: FormBody = .{};
    try form.append(&payload.writer, "grant_type", "authorization_code");
    try form.append(&payload.writer, "code", grant.authorization_code);
    try form.append(&payload.writer, "redirect_uri", redirect_uri);
    try form.append(&payload.writer, "client_id", codex_auth.clientId(options));
    try form.append(&payload.writer, "code_verifier", grant.code_verifier);

    var response = try transport.execute(alloc, .{
        .method = .post_form,
        .url = url,
        .payload = payload.written(),
        .cancel_flag = control.cancel_flag,
        .deadline = control.deadline,
    });
    defer response.deinit(alloc);
    if (!accepted(response)) return error.CodexTokenExchangeRejected;
    if (response.body.len > max_response_bytes) return error.CodexLoginResponseTooLarge;
    return parseExchangedTokens(alloc, response.body);
}

/// Polls for up to fifteen awake-clock minutes, exchanges the grant, and saves
/// the tokens through the locked, atomic `auth.json` mutation path.
pub fn completeLogin(
    alloc: Allocator,
    transport: Transport,
    options: Options,
    device: DeviceCode,
    cancel_flag: ?*std.atomic.Value(bool),
) !void {
    var local_cancel = std.atomic.Value(bool).init(false);
    const cancellation = cancel_flag orelse &local_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(login_timeout_ms),
    });

    while (true) {
        try ensureActive(cancellation, deadline);
        const request_deadline = boundedRequestDeadline(deadline);
        const result = try pollDeviceCode(alloc, transport, options, device, .{
            .cancel_flag = cancellation,
            .deadline = request_deadline,
        });
        switch (result) {
            .pending => try waitForNextPoll(
                cancellation,
                deadline,
                @max(device.interval_seconds, 1) * std.time.ms_per_s,
            ),
            .granted => |value| {
                var grant = value;
                defer grant.deinit(alloc);
                try ensureActive(cancellation, deadline);
                var tokens = try exchangeAuthorizationGrant(
                    alloc,
                    transport,
                    options,
                    grant,
                    .{
                        .cancel_flag = cancellation,
                        .deadline = boundedRequestDeadline(deadline),
                    },
                );
                defer tokens.deinit(alloc);
                try ensureActive(cancellation, deadline);
                try codex_auth.persistTokens(alloc, options, tokens.authTokens());
                return;
            },
        }
    }
}

fn parseDeviceCodeResponse(
    alloc: Allocator,
    issuer: []const u8,
    bytes: []const u8,
) !DeviceCode {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCodexDeviceCodeResponse,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCodexDeviceCodeResponse;
    const object = parsed.value.object;

    const device_auth_id = try dupeRequiredString(
        alloc,
        object,
        "device_auth_id",
        error.InvalidCodexDeviceCodeResponse,
    );
    errdefer secret.zeroAndFree(alloc, device_auth_id);
    const user_code_value = object.get("user_code") orelse object.get("usercode") orelse
        return error.InvalidCodexDeviceCodeResponse;
    if (user_code_value != .string or user_code_value.string.len == 0) {
        return error.InvalidCodexDeviceCodeResponse;
    }
    const user_code = try alloc.dupe(u8, user_code_value.string);
    errdefer secret.zeroAndFree(alloc, user_code);
    const interval_seconds = try parseDeviceInterval(object.get("interval"));
    const verification_url = try endpointAlloc(alloc, issuer, "/codex/device");
    errdefer alloc.free(verification_url);

    return .{
        .verification_url = verification_url,
        .user_code = user_code,
        .device_auth_id = device_auth_id,
        .interval_seconds = interval_seconds,
    };
}

fn parseAuthorizationGrant(alloc: Allocator, bytes: []const u8) !AuthorizationGrant {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCodexDeviceAuthorization,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCodexDeviceAuthorization;
    const object = parsed.value.object;

    const authorization_code = try dupeRequiredString(
        alloc,
        object,
        "authorization_code",
        error.InvalidCodexDeviceAuthorization,
    );
    errdefer secret.zeroAndFree(alloc, authorization_code);
    const code_challenge = try dupeRequiredString(
        alloc,
        object,
        "code_challenge",
        error.InvalidCodexDeviceAuthorization,
    );
    errdefer secret.zeroAndFree(alloc, code_challenge);
    const code_verifier = try dupeRequiredString(
        alloc,
        object,
        "code_verifier",
        error.InvalidCodexDeviceAuthorization,
    );
    errdefer secret.zeroAndFree(alloc, code_verifier);

    return .{
        .authorization_code = authorization_code,
        .code_challenge = code_challenge,
        .code_verifier = code_verifier,
    };
}

fn parseExchangedTokens(alloc: Allocator, bytes: []const u8) !ExchangedTokens {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCodexTokenResponse,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCodexTokenResponse;
    const object = parsed.value.object;

    const id_token = try dupeRequiredString(
        alloc,
        object,
        "id_token",
        error.InvalidCodexTokenResponse,
    );
    errdefer secret.zeroAndFree(alloc, id_token);
    const access_token = try dupeRequiredString(
        alloc,
        object,
        "access_token",
        error.InvalidCodexTokenResponse,
    );
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeRequiredString(
        alloc,
        object,
        "refresh_token",
        error.InvalidCodexTokenResponse,
    );
    errdefer secret.zeroAndFree(alloc, refresh_token);

    const account_id = (try codex_auth.accountIdForTokens(alloc, .{
        .id_token = id_token,
        .access_token = access_token,
        .refresh_token = refresh_token,
        .account_id = optionalString(object, "account_id") orelse "",
    })) orelse return error.InvalidCodexTokenResponse;
    errdefer alloc.free(account_id);

    return .{
        .id_token = id_token,
        .access_token = access_token,
        .refresh_token = refresh_token,
        .account_id = account_id,
    };
}

fn accepted(response: oauth_transport.Response) bool {
    return response.disposition == .accepted and response.status.class() == .success;
}

fn validatedIssuer(options: Options) ![]const u8 {
    const issuer = codex_auth.issuerUrl(options);
    codex_auth.validateAuthEndpoint(issuer) catch return error.InvalidCodexIssuer;
    return issuer;
}

fn endpointAlloc(alloc: Allocator, issuer: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ issuer, path });
}

fn parseDeviceInterval(value: ?std.json.Value) !u64 {
    const seconds: u64 = switch (value orelse return 0) {
        .string => |text| std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t\r\n"), 10) catch
            return error.InvalidCodexDeviceCodeResponse,
        .integer => |number| std.math.cast(u64, number) orelse
            return error.InvalidCodexDeviceCodeResponse,
        else => return error.InvalidCodexDeviceCodeResponse,
    };
    if (seconds > max_device_interval_seconds) return error.InvalidCodexDeviceCodeResponse;
    return seconds;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn dupeRequiredString(
    alloc: Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
    invalid: anyerror,
) ![]u8 {
    const value = object.get(key) orelse return invalid;
    if (value != .string or value.string.len == 0) return invalid;
    return alloc.dupe(u8, value.string);
}

fn boundedRequestDeadline(login_deadline: std.Io.Clock.Timestamp) std.Io.Clock.Timestamp {
    const request_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(request_timeout_ms),
    });
    return if (std.Io.Clock.Timestamp.compare(request_deadline, .lt, login_deadline))
        request_deadline
    else
        login_deadline;
}

fn ensureActive(
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !void {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    if (!std.Io.Clock.Timestamp.compare(now, .lt, deadline)) {
        return error.CodexDeviceLoginTimedOut;
    }
}

fn waitForNextPoll(
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
    requested_ms: u64,
) !void {
    var remaining_ms = requested_ms;
    while (remaining_ms > 0) {
        try ensureActive(cancel_flag, deadline);
        const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        const deadline_ms = now.durationTo(deadline).raw.toMilliseconds();
        if (deadline_ms <= 0) return error.CodexDeviceLoginTimedOut;
        const slice_ms = @min(
            remaining_ms,
            @min(poll_wait_slice_ms, @as(u64, @intCast(deadline_ms))),
        );
        io_mod.sleep(slice_ms * @as(u64, std.time.ns_per_ms));
        remaining_ms -= slice_ms;
    }
    try ensureActive(cancel_flag, deadline);
}

const FormBody = struct {
    first: bool = true,

    fn append(
        self: *FormBody,
        writer: *std.Io.Writer,
        key: []const u8,
        value: []const u8,
    ) !void {
        if (!self.first) try writer.writeByte('&');
        self.first = false;
        try percentEncode(writer, key);
        try writer.writeByte('=');
        try percentEncode(writer, value);
    }
};

fn percentEncode(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

const FakeStep = struct {
    method: oauth_transport.Method,
    url: []const u8,
    status: std.http.Status = .ok,
    body: []const u8,
    payload_fragment: ?[]const u8 = null,
};

const FakeTransport = struct {
    steps: []const FakeStep,
    index: usize = 0,
    matched: bool = true,

    fn provider(self: *FakeTransport) Transport {
        return .{ .context = self, .execute_fn = execute };
    }

    fn execute(
        raw: ?*anyopaque,
        alloc: Allocator,
        request: oauth_transport.Request,
    ) !oauth_transport.Response {
        const self: *FakeTransport = @ptrCast(@alignCast(raw.?));
        if (self.index >= self.steps.len) return error.UnexpectedCodexLoginRequest;
        const step = self.steps[self.index];
        self.index += 1;
        self.matched = self.matched and request.method == step.method;
        self.matched = self.matched and std.mem.eql(u8, request.url, step.url);
        if (step.payload_fragment) |fragment| {
            self.matched = self.matched and request.payload != null and
                std.mem.find(u8, request.payload.?, fragment) != null;
        }
        return .{
            .disposition = if (step.status.class() == .success) .accepted else .rejected,
            .status = step.status,
            .body = try alloc.dupe(u8, step.body),
        };
    }
};

fn encodeTestJwt(alloc: Allocator, payload: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const encoded = try alloc.alloc(u8, encoder.calcSize(payload.len));
    defer alloc.free(encoded);
    _ = encoder.encode(encoded, payload);
    return std.fmt.allocPrint(alloc, "e30.{s}.sig", .{encoded});
}

fn testDevice(alloc: Allocator) !DeviceCode {
    const verification_url = try alloc.dupe(u8, "https://auth.test/codex/device");
    errdefer alloc.free(verification_url);
    const user_code = try alloc.dupe(u8, "ABCD-EFGH");
    errdefer secret.zeroAndFree(alloc, user_code);
    const device_auth_id = try alloc.dupe(u8, "device-1");
    errdefer secret.zeroAndFree(alloc, device_auth_id);
    return .{
        .verification_url = verification_url,
        .user_code = user_code,
        .device_auth_id = device_auth_id,
        .interval_seconds = 0,
    };
}

test "codex login device code request uses JSON endpoint and current aliases" {
    const steps = [_]FakeStep{.{
        .method = .post_json,
        .url = "https://auth.test/api/accounts/deviceauth/usercode",
        .body = "{\"device_auth_id\":\"device-1\",\"usercode\":\"ABCD-EFGH\",\"interval\":\"7\"}",
        .payload_fragment = "\"client_id\":\"client-1\"",
    }};
    var transport = FakeTransport{ .steps = &steps };
    var device = try requestDeviceCode(std.testing.allocator, transport.provider(), .{
        .issuer = "https://auth.test/",
        .client_id = "client-1",
    });
    defer device.deinit(std.testing.allocator);

    try std.testing.expect(transport.matched);
    try std.testing.expectEqual(@as(usize, 1), transport.index);
    try std.testing.expectEqualStrings("https://auth.test/codex/device", device.verification_url);
    try std.testing.expectEqualStrings("ABCD-EFGH", device.user_code);
    try std.testing.expectEqual(@as(u64, 7), device.interval_seconds);
}

test "codex login device authorization maps pending statuses and parses PKCE grant" {
    const steps = [_]FakeStep{
        .{
            .method = .post_json,
            .url = "https://auth.test/api/accounts/deviceauth/token",
            .status = .forbidden,
            .body = "{}",
            .payload_fragment = "\"device_auth_id\":\"device-1\"",
        },
        .{
            .method = .post_json,
            .url = "https://auth.test/api/accounts/deviceauth/token",
            .body = "{\"authorization_code\":\"code\",\"code_challenge\":\"challenge\",\"code_verifier\":\"verifier\"}",
        },
    };
    var transport = FakeTransport{ .steps = &steps };
    var device = try testDevice(std.testing.allocator);
    defer device.deinit(std.testing.allocator);

    const pending = try pollDeviceCode(
        std.testing.allocator,
        transport.provider(),
        .{ .issuer = "https://auth.test" },
        device,
        .{},
    );
    switch (pending) {
        .pending => {},
        .granted => |value| {
            var unexpected = value;
            unexpected.deinit(std.testing.allocator);
            return error.TestExpectedPending;
        },
    }

    const next = try pollDeviceCode(
        std.testing.allocator,
        transport.provider(),
        .{ .issuer = "https://auth.test" },
        device,
        .{},
    );
    var grant = switch (next) {
        .pending => return error.TestExpectedEqual,
        .granted => |value| value,
    };
    defer grant.deinit(std.testing.allocator);
    try std.testing.expect(transport.matched);
    try std.testing.expectEqualStrings("verifier", grant.code_verifier);
}

test "codex login token exchange form encodes fields and derives account from JWT" {
    const alloc = std.testing.allocator;
    const jwt = try encodeTestJwt(
        alloc,
        "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-1\"}}",
    );
    defer alloc.free(jwt);
    const response = try std.fmt.allocPrint(
        alloc,
        "{{\"id_token\":\"{s}\",\"access_token\":\"access\",\"refresh_token\":\"refresh\"}}",
        .{jwt},
    );
    defer alloc.free(response);
    const steps = [_]FakeStep{.{
        .method = .post_form,
        .url = "https://auth.test/oauth/token",
        .body = response,
        .payload_fragment = "code=code%20with%20space",
    }};
    var transport = FakeTransport{ .steps = &steps };
    const authorization_code = try alloc.dupe(u8, "code with space");
    errdefer secret.zeroAndFree(alloc, authorization_code);
    const code_challenge = try alloc.dupe(u8, "challenge");
    errdefer secret.zeroAndFree(alloc, code_challenge);
    const code_verifier = try alloc.dupe(u8, "verifier/with/slash");
    errdefer secret.zeroAndFree(alloc, code_verifier);
    var grant = AuthorizationGrant{
        .authorization_code = authorization_code,
        .code_challenge = code_challenge,
        .code_verifier = code_verifier,
    };
    defer grant.deinit(alloc);

    var tokens = try exchangeAuthorizationGrant(
        alloc,
        transport.provider(),
        .{ .issuer = "https://auth.test", .client_id = "client-1" },
        grant,
        .{},
    );
    defer tokens.deinit(alloc);
    try std.testing.expect(transport.matched);
    try std.testing.expectEqualStrings("acct-1", tokens.account_id);
}

test "codex login token exchange rejects an explicit account that contradicts JWTs" {
    const alloc = std.testing.allocator;
    const jwt = try encodeTestJwt(
        alloc,
        "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-new\"}}",
    );
    defer alloc.free(jwt);
    const response = try std.fmt.allocPrint(
        alloc,
        "{{\"id_token\":\"{s}\",\"access_token\":\"{s}\",\"refresh_token\":\"refresh\",\"account_id\":\"acct-old\"}}",
        .{ jwt, jwt },
    );
    defer alloc.free(response);

    try std.testing.expectError(
        error.CodexAccountChanged,
        parseExchangedTokens(alloc, response),
    );
}

test "codex login token exchange rejects conflicting ID and access JWT accounts" {
    const alloc = std.testing.allocator;
    const id_token = try encodeTestJwt(
        alloc,
        "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-old\"}}",
    );
    defer alloc.free(id_token);
    const access_token = try encodeTestJwt(
        alloc,
        "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-new\"}}",
    );
    defer alloc.free(access_token);
    const response = try std.fmt.allocPrint(
        alloc,
        "{{\"id_token\":\"{s}\",\"access_token\":\"{s}\",\"refresh_token\":\"refresh\"}}",
        .{ id_token, access_token },
    );
    defer alloc.free(response);

    try std.testing.expectError(
        error.CodexAccountChanged,
        parseExchangedTokens(alloc, response),
    );
}

test "codex login complete flow persists tokens while retaining unknown auth fields" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "auth.json",
        .data = "{\"future_root\":{\"keep\":true}}",
    });
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "auth.json" });
    defer alloc.free(path);

    const jwt = try encodeTestJwt(
        alloc,
        "{\"exp\":4102444800,\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-complete\"}}",
    );
    defer alloc.free(jwt);
    const token_body = try std.fmt.allocPrint(
        alloc,
        "{{\"id_token\":\"{s}\",\"access_token\":\"{s}\",\"refresh_token\":\"refresh\"}}",
        .{ jwt, jwt },
    );
    defer alloc.free(token_body);
    const steps = [_]FakeStep{
        .{
            .method = .post_json,
            .url = "https://auth.test/api/accounts/deviceauth/token",
            .body = "{\"authorization_code\":\"code\",\"code_challenge\":\"challenge\",\"code_verifier\":\"verifier\"}",
        },
        .{
            .method = .post_form,
            .url = "https://auth.test/oauth/token",
            .body = token_body,
        },
    };
    var transport = FakeTransport{ .steps = &steps };
    var device = try testDevice(alloc);
    defer device.deinit(alloc);

    try completeLogin(alloc, transport.provider(), .{
        .issuer = "https://auth.test",
        .auth_file = path,
    }, device, null);
    try std.testing.expect(transport.matched);

    var loaded = (try codex_auth.loadStored(alloc, .{ .auth_file = path })).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("acct-complete", loaded.account_id);
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "auth.json", alloc, .limited(max_response_bytes));
    defer alloc.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "\"future_root\"") != null);
}
