const std = @import("std");
const grok_oauth = @import("../core/auth/grok_oauth.zig");
const grok_session = @import("../core/auth/grok_session.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const codex_usage = @import("../core/gateway/codex_usage.zig");
const output_contracts = @import("../core/output/output_contracts.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const gateway_client = @import("client.zig");

const Allocator = std.mem.Allocator;

const max_billing_bytes: usize = 64 * 1024;
const fetch_timeout_ms: i64 = 15_000;
const default_billing_endpoint = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
const e2e_billing_endpoint_env = "FX_E2E_XAI_GROK_BILLING_URL";
const weekly_window_seconds: i32 = 7 * 24 * 60 * 60;
const monthly_window_seconds: i32 = 30 * 24 * 60 * 60;
const daily_window_seconds: i32 = 24 * 60 * 60;

pub const provider = gateway_provider.AccountUsageProvider{
    .fetch_fn = fetch,
};

const ParsedBilling = struct {
    used_percent: i32,
    window_seconds: i32,
};

const FetchResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *FetchResponse, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        self.* = undefined;
    }
};

const FetchOperation = struct {
    alloc: Allocator,
    url: []const u8,
    credential: []const u8,
    account_id: []const u8,

    pub fn run(self: *@This()) !FetchResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const auth_header = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{self.credential});
        defer secret.zeroAndFree(self.alloc, auth_header);
        const body_buffer = try self.alloc.alloc(u8, max_billing_bytes + 1);
        defer secret.zeroAndFree(self.alloc, body_buffer);
        var response_writer = std.Io.Writer.fixed(body_buffer);
        const extra_headers = [_]std.http.Header{
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "X-XAI-Token-Auth", .value = "xai-grok-cli" },
            .{ .name = "x-userid", .value = self.account_id },
        };
        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{
                .authorization = .{ .override = auth_header },
                .user_agent = .{ .override = gateway_client.user_agent },
                .accept_encoding = .omit,
            },
            .extra_headers = &extra_headers,
            .response_writer = &response_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.GrokBillingTooLarge,
            else => return err,
        };
        const body = response_writer.buffered();
        if (body.len > max_billing_bytes) return error.GrokBillingTooLarge;
        return .{
            .status = result.status,
            .body = try self.alloc.dupe(u8, body),
        };
    }
};

fn fetch(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.AccountUsageLookupInput,
) output_contracts.CodexAccountUsageSnapshot {
    if (input.credential_source != .grok_subscription) {
        return failure(.unsupported_credential_source, null);
    }
    const access_token = input.credential orelse return failure(.missing_credential, null);
    if (access_token.len == 0) return failure(.missing_credential, null);
    const account_id = input.account_id orelse return failure(.missing_account_id, null);
    if (!grok_session.validAccountId(account_id)) return failure(.missing_account_id, null);

    var first = fetchOnce(alloc, access_token, account_id, input.cancel_flag);
    const retry_mode: grok_oauth.RefreshMode = if (first.failure) |first_failure|
        switch (first_failure.kind) {
            .unauthorized => .force,
            .credential_changed => .stored,
            else => return first,
        }
    else
        return first;
    first.deinit(alloc);

    var refreshed = (grok_oauth.loadAccess(alloc, input.oauth_transport, retry_mode) catch |err| {
        debug_trace.logf("grok_usage", "credential retry failed mode={t} err={s}", .{ retry_mode, @errorName(err) });
        return failure(failureKindForError(err), null);
    }) orelse return failure(.credential_unavailable, null);
    defer refreshed.deinit(alloc);
    if (!std.mem.eql(u8, refreshed.account_id, account_id)) {
        return failure(.credential_changed, null);
    }
    return fetchOnce(alloc, refreshed.access_token, refreshed.account_id, input.cancel_flag);
}

fn fetchOnce(
    alloc: Allocator,
    access_token: []const u8,
    account_id: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
) output_contracts.CodexAccountUsageSnapshot {
    const url = billingUrl(alloc) catch |err| {
        debug_trace.logf("grok_usage", "endpoint resolution failed err={s}", .{@errorName(err)});
        return failure(failureKindForError(err), null);
    };
    defer alloc.free(url);

    var fallback_cancel = std.atomic.Value(bool).init(false);
    const flag = cancel_flag orelse &fallback_cancel;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(fetch_timeout_ms),
    });
    var operation = FetchOperation{
        .alloc = alloc,
        .url = url,
        .credential = access_token,
        .account_id = account_id,
    };
    var response = gateway_client.runBoundedHttpOperation(
        FetchResponse,
        alloc,
        flag,
        deadline,
        &operation,
    ) catch |err| {
        debug_trace.logf("grok_usage", "billing request failed err={s}", .{@errorName(err)});
        return failure(failureKindForError(err), null);
    };
    defer response.deinit(alloc);
    if (response.status != .ok) return failureForStatus(response.status);

    const parsed = parseBilling(alloc, response.body) catch |err| {
        debug_trace.logf("grok_usage", "billing parse failed err={s}", .{@errorName(err)});
        return failure(failureKindForError(err), null);
    };
    const data = snapshotFromParsed(alloc, parsed, io_mod.milliTimestamp()) catch |err| {
        debug_trace.logf("grok_usage", "billing snapshot failed err={s}", .{@errorName(err)});
        return failure(failureKindForError(err), null);
    };
    return .{ .data = data };
}

fn billingUrl(alloc: Allocator) ![]u8 {
    const base = io_mod.getenv(e2e_billing_endpoint_env) orelse default_billing_endpoint;
    if (io_mod.getenv(e2e_billing_endpoint_env) != null and !gateway_client.isLoopbackUrl(base)) {
        return error.InvalidE2EGrokBillingEndpoint;
    }
    return alloc.dupe(u8, base);
}

fn parseBilling(alloc: Allocator, json: []const u8) !ParsedBilling {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGrokBillingResponse;
    const root = parsed.value.object;
    const config_value = objectValue(root, &.{"config"}) orelse parsed.value;
    if (config_value != .object) return error.InvalidGrokBillingResponse;
    return parseConfigObject(config_value.object);
}

fn parseConfigObject(config: std.json.ObjectMap) !ParsedBilling {
    const used = objectNumber(config, &.{ "creditUsagePercent", "credit_usage_percent" }) orelse
        usedPercentFromLegacy(config) orelse
        return error.InvalidGrokBillingResponse;
    const period = objectValue(config, &.{ "currentPeriod", "current_period" });
    const period_type = if (period) |value| switch (value) {
        .object => objectString(value.object, &.{ "type", "periodType", "period_type" }),
        else => null,
    } else null;
    return .{
        .used_percent = usedPercentFromFloat(used),
        .window_seconds = windowSecondsFromPeriodType(period_type),
    };
}

fn usedPercentFromLegacy(config: std.json.ObjectMap) ?f64 {
    const used = objectCent(config, &.{"used"}) orelse return null;
    const limit = objectCent(config, &.{ "monthlyLimit", "monthly_limit" }) orelse return null;
    if (limit <= 0) return null;
    return used / limit * 100.0;
}

fn usedPercentFromFloat(used: f64) i32 {
    if (!std.math.isFinite(used)) return 0;
    const clamped = std.math.clamp(used, 0, 100);
    return @intFromFloat(@round(clamped));
}

fn windowSecondsFromPeriodType(raw: ?[]const u8) i32 {
    const value = raw orelse return weekly_window_seconds;
    if (containsIgnoreCase(value, "DAILY") or containsIgnoreCase(value, "daily")) {
        return daily_window_seconds;
    }
    if (containsIgnoreCase(value, "MONTH") or containsIgnoreCase(value, "month")) {
        return monthly_window_seconds;
    }
    return weekly_window_seconds;
}

fn snapshotFromParsed(
    alloc: Allocator,
    parsed: ParsedBilling,
    fetched_at_ms: i64,
) !codex_usage.Snapshot {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const rate_limits = try owned.alloc(codex_usage.RateLimit, 1);
    rate_limits[0] = .{
        .id = try owned.dupe(u8, "grok"),
        .primary_window = .{
            .used_percent = parsed.used_percent,
            .limit_window_seconds = parsed.window_seconds,
            .reset_after_seconds = 0,
            .reset_at = 0,
        },
    };
    return .{
        .plan_type = try owned.dupe(u8, "grok"),
        .rate_limits = rate_limits,
        .credits = null,
        .spend_control = null,
        .rate_limit_reached_type = null,
        .rate_limit_reset_credits_available = null,
        .token_usage = .{},
        .daily_usage_buckets = &.{},
        .fetched_at_ms = fetched_at_ms,
        .arena = arena,
    };
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
        error.GrokOAuthUnavailable => .credential_unavailable,
        error.GrokAccountChanged => .credential_changed,
        error.GrokBillingTooLarge => .response_too_large,
        error.InvalidGrokBillingResponse => .invalid_response,
        error.InvalidE2EGrokBillingEndpoint => .invalid_endpoint,
        else => .transport,
    };
}

fn objectValue(object: std.json.ObjectMap, keys: []const []const u8) ?std.json.Value {
    for (keys) |key| {
        if (object.get(key)) |value| return value;
    }
    return null;
}

fn objectString(object: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    const value = objectValue(object, keys) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn objectNumber(object: std.json.ObjectMap, keys: []const []const u8) ?f64 {
    const value = objectValue(object, keys) orelse return null;
    return jsonNumber(value);
}

fn objectCent(object: std.json.ObjectMap, keys: []const []const u8) ?f64 {
    const value = objectValue(object, keys) orelse return null;
    if (jsonNumber(value)) |number| return number;
    if (value != .object) return null;
    return jsonNumber(objectValue(value.object, &.{"val"}) orelse return null);
}

fn jsonNumber(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch null,
        else => null,
    };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

test "Grok account usage rejects the wrong credential source before transport" {
    var snapshot = fetch(null, std.testing.allocator, .{
        .credential = "key",
        .account_id = "acct",
        .credential_source = .chatgpt_subscription,
        .oauth_transport = @import("../core/auth/oauth_transport.zig").unavailable_provider,
    });
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(
        codex_usage.FailureKind.unsupported_credential_source,
        snapshot.failure.?.kind,
    );
}

test "Grok billing weekly remaining maps from creditUsagePercent" {
    const parsed = try parseBilling(
        std.testing.allocator,
        \\{"config":{"creditUsagePercent":42.5,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY"}}}
        ,
    );
    try std.testing.expectEqual(@as(i32, 43), parsed.used_percent);
    try std.testing.expectEqual(weekly_window_seconds, parsed.window_seconds);
}

test "Grok billing monthly remaining maps from camelCase period type" {
    const parsed = try parseBilling(
        std.testing.allocator,
        \\{"config":{"credit_usage_percent":12,"current_period":{"periodType":"USAGE_PERIOD_TYPE_MONTHLY"}}}
        ,
    );
    try std.testing.expectEqual(@as(i32, 12), parsed.used_percent);
    try std.testing.expectEqual(monthly_window_seconds, parsed.window_seconds);
}

test "Grok billing falls back to used and monthly limit cents" {
    const parsed = try parseBilling(
        std.testing.allocator,
        \\{"config":{"used":{"val":250},"monthlyLimit":{"val":1000},"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY"}}}
        ,
    );
    try std.testing.expectEqual(@as(i32, 25), parsed.used_percent);
    try std.testing.expectEqual(weekly_window_seconds, parsed.window_seconds);
}
