const std = @import("std");
const io_mod = @import("../shared/io.zig");
const provider_route = @import("provider_route.zig");

const Allocator = std.mem.Allocator;

pub const account_base_url_env = "FX_CODEX_ACCOUNT_BASE_URL";
pub const default_account_base_url = "https://chatgpt.com/backend-api";

/// Both backend payloads are small today. Keeping a shared hard limit prevents
/// an authenticated endpoint (or a configured proxy) from growing memory
/// without bound before JSON validation runs.
pub const max_response_bytes: usize = 512 * 1024;
pub const max_additional_rate_limits: usize = 64;
pub const max_daily_usage_buckets: usize = 400;

pub const EndpointOverrides = struct {
    /// Account API root, for example `https://chatgpt.com/backend-api`.
    account_base_url: ?[]const u8 = null,
    responses: provider_route.EndpointOverrides = .{},

    pub fn fromEnvironment() EndpointOverrides {
        return .{
            .account_base_url = io_mod.getenv(account_base_url_env),
            .responses = provider_route.EndpointOverrides.fromEnvironment(),
        };
    }
};

pub const Endpoints = struct {
    usage: []u8,
    profile: []u8,

    pub fn deinit(self: *Endpoints, alloc: Allocator) void {
        alloc.free(self.usage);
        alloc.free(self.profile);
        self.* = undefined;
    }
};

/// Resolves the two account endpoints from one normalized base. An explicit
/// account override wins. Otherwise the Codex Responses base is parsed only at
/// its final `/codex` path segment; no substring replacement is performed.
pub fn resolveEndpointsAlloc(
    alloc: Allocator,
    overrides: EndpointOverrides,
) !Endpoints {
    const account_base = if (overrides.account_base_url) |explicit| blk: {
        try provider_route.validateBaseUrl(explicit);
        break :blk try alloc.dupe(u8, std.mem.trimEnd(u8, explicit, "/"));
    } else blk: {
        const responses_base = try provider_route.resolveBaseUrlAlloc(
            alloc,
            .codex_responses_oauth,
            overrides.responses,
        );
        defer alloc.free(responses_base);
        break :blk try accountBaseFromResponsesBaseAlloc(alloc, responses_base);
    };
    defer alloc.free(account_base);

    const chatgpt_style = std.mem.endsWith(u8, account_base, "/backend-api");
    const usage_path = if (chatgpt_style) "/wham/usage" else "/api/codex/usage";
    const profile_path = if (chatgpt_style) "/wham/profiles/me" else "/api/codex/profiles/me";

    const usage = try std.fmt.allocPrint(alloc, "{s}{s}", .{ account_base, usage_path });
    errdefer alloc.free(usage);
    return .{
        .usage = usage,
        .profile = try std.fmt.allocPrint(alloc, "{s}{s}", .{ account_base, profile_path }),
    };
}

fn accountBaseFromResponsesBaseAlloc(alloc: Allocator, responses_base: []const u8) ![]u8 {
    try provider_route.validateBaseUrl(responses_base);
    var normalized = std.mem.trimEnd(u8, responses_base, "/");
    if (std.mem.endsWith(u8, normalized, "/responses/compact")) {
        normalized = std.mem.trimEnd(
            u8,
            normalized[0 .. normalized.len - "/responses/compact".len],
            "/",
        );
    } else if (std.mem.endsWith(u8, normalized, "/responses")) {
        normalized = std.mem.trimEnd(
            u8,
            normalized[0 .. normalized.len - "/responses".len],
            "/",
        );
    }
    const account_base = if (std.mem.endsWith(u8, normalized, "/codex"))
        normalized[0 .. normalized.len - "/codex".len]
    else
        normalized;
    try provider_route.validateBaseUrl(account_base);
    return alloc.dupe(u8, account_base);
}

pub const Window = struct {
    used_percent: i32,
    limit_window_seconds: i32,
    reset_after_seconds: i32,
    reset_at: i64,
};

pub const RateLimit = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    allowed: ?bool = null,
    limit_reached: ?bool = null,
    primary_window: ?Window = null,
    secondary_window: ?Window = null,
};

pub const Credits = struct {
    has_credits: bool,
    unlimited: bool,
    balance: ?[]const u8 = null,
};

pub const SpendControlLimit = struct {
    source: ?[]const u8 = null,
    limit: []const u8,
    used: []const u8,
    remaining: []const u8,
    used_percent: i32,
    remaining_percent: i32,
    reset_after_seconds: i32,
    reset_at: i64,
};

pub const SpendControl = struct {
    reached: bool,
    individual_limit: ?SpendControlLimit = null,
};

pub const TokenUsageStats = struct {
    lifetime_tokens: ?i64 = null,
    peak_daily_tokens: ?i64 = null,
    longest_running_turn_sec: ?i64 = null,
    current_streak_days: ?i64 = null,
    longest_streak_days: ?i64 = null,
};

pub const DailyUsageBucket = struct {
    start_date: []const u8,
    tokens: i64,
};

pub const Snapshot = struct {
    plan_type: []const u8,
    rate_limits: []const RateLimit,
    credits: ?Credits,
    spend_control: ?SpendControl,
    /// Preserved as a string so a newly introduced backend kind remains
    /// observable instead of making the entire response undecodable.
    rate_limit_reached_type: ?[]const u8,
    rate_limit_reset_credits_available: ?i64,
    token_usage: TokenUsageStats,
    daily_usage_buckets: []const DailyUsageBucket,
    fetched_at_ms: i64,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const FailureKind = enum {
    unsupported_credential_source,
    missing_credential,
    missing_account_id,
    credential_unavailable,
    credential_changed,
    unauthorized,
    forbidden,
    rate_limited,
    http_error,
    invalid_endpoint,
    response_too_large,
    invalid_response,
    timeout,
    cancelled,
    transport,
    resource_exhausted,
};

pub const Failure = struct {
    kind: FailureKind,
    http_status: ?std.http.Status = null,
};

const WireWindow = struct {
    used_percent: i32,
    limit_window_seconds: i32,
    reset_after_seconds: i32,
    reset_at: i32,
};

const WireRateLimit = struct {
    allowed: bool,
    limit_reached: bool,
    primary_window: ?WireWindow = null,
    secondary_window: ?WireWindow = null,
};

const WireCredits = struct {
    has_credits: bool,
    unlimited: bool,
    balance: ?[]const u8 = null,
};

const WireSpendControlLimit = struct {
    source: ?[]const u8 = null,
    limit: []const u8,
    used: []const u8,
    remaining: []const u8,
    used_percent: i32,
    remaining_percent: i32,
    reset_after_seconds: i32,
    reset_at: i32,
};

const WireSpendControl = struct {
    reached: bool,
    individual_limit: ?WireSpendControlLimit = null,
};

const WireAdditionalRateLimit = struct {
    limit_name: []const u8,
    metered_feature: []const u8,
    rate_limit: ?WireRateLimit = null,
};

const WireReachedType = struct {
    type: []const u8,
};

const WireResetCredits = struct {
    available_count: i64,
};

const WireUsage = struct {
    plan_type: []const u8,
    rate_limit: ?WireRateLimit = null,
    credits: ?WireCredits = null,
    spend_control: ?WireSpendControl = null,
    additional_rate_limits: ?[]const WireAdditionalRateLimit = null,
    rate_limit_reached_type: ?WireReachedType = null,
    rate_limit_reset_credits: ?WireResetCredits = null,
};

const WireDailyUsageBucket = struct {
    start_date: []const u8,
    tokens: i64,
};

const WireTokenUsageStats = struct {
    lifetime_tokens: ?i64 = null,
    peak_daily_tokens: ?i64 = null,
    longest_running_turn_sec: ?i64 = null,
    current_streak_days: ?i64 = null,
    longest_streak_days: ?i64 = null,
    daily_usage_buckets: ?[]const WireDailyUsageBucket = null,
};

const WireProfile = struct {
    stats: WireTokenUsageStats,
};

pub fn parseSnapshot(
    alloc: Allocator,
    usage_json: []const u8,
    profile_json: []const u8,
    fetched_at_ms: i64,
) !Snapshot {
    if (usage_json.len > max_response_bytes or profile_json.len > max_response_bytes) {
        return error.CodexUsageResponseTooLarge;
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();
    const parse_options: std.json.ParseOptions = .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    };
    const usage = std.json.parseFromSliceLeaky(
        WireUsage,
        arena_alloc,
        usage_json,
        parse_options,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCodexUsageResponse,
    };
    const profile = std.json.parseFromSliceLeaky(
        WireProfile,
        arena_alloc,
        profile_json,
        parse_options,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCodexTokenProfileResponse,
    };

    const additional = usage.additional_rate_limits orelse &.{};
    if (additional.len > max_additional_rate_limits) {
        return error.TooManyCodexRateLimits;
    }
    const wire_buckets = profile.stats.daily_usage_buckets orelse &.{};
    if (wire_buckets.len > max_daily_usage_buckets) {
        return error.TooManyCodexDailyUsageBuckets;
    }

    const rate_limits = try arena_alloc.alloc(RateLimit, 1 + additional.len);
    rate_limits[0] = rateLimitFromWire("codex", null, usage.rate_limit);
    for (additional, 0..) |limit, index| {
        rate_limits[index + 1] = rateLimitFromWire(
            limit.metered_feature,
            limit.limit_name,
            limit.rate_limit,
        );
    }

    const daily_usage_buckets = try arena_alloc.alloc(DailyUsageBucket, wire_buckets.len);
    for (wire_buckets, 0..) |bucket, index| {
        daily_usage_buckets[index] = .{
            .start_date = bucket.start_date,
            .tokens = bucket.tokens,
        };
    }

    return .{
        .plan_type = usage.plan_type,
        .rate_limits = rate_limits,
        .credits = if (usage.credits) |credits| .{
            .has_credits = credits.has_credits,
            .unlimited = credits.unlimited,
            .balance = credits.balance,
        } else null,
        .spend_control = if (usage.spend_control) |control| .{
            .reached = control.reached,
            .individual_limit = if (control.individual_limit) |limit| .{
                .source = limit.source,
                .limit = limit.limit,
                .used = limit.used,
                .remaining = limit.remaining,
                .used_percent = limit.used_percent,
                .remaining_percent = limit.remaining_percent,
                .reset_after_seconds = limit.reset_after_seconds,
                .reset_at = limit.reset_at,
            } else null,
        } else null,
        .rate_limit_reached_type = if (usage.rate_limit_reached_type) |value| value.type else null,
        .rate_limit_reset_credits_available = if (usage.rate_limit_reset_credits) |value| value.available_count else null,
        .token_usage = .{
            .lifetime_tokens = profile.stats.lifetime_tokens,
            .peak_daily_tokens = profile.stats.peak_daily_tokens,
            .longest_running_turn_sec = profile.stats.longest_running_turn_sec,
            .current_streak_days = profile.stats.current_streak_days,
            .longest_streak_days = profile.stats.longest_streak_days,
        },
        .daily_usage_buckets = daily_usage_buckets,
        .fetched_at_ms = fetched_at_ms,
        .arena = arena,
    };
}

fn rateLimitFromWire(
    id: []const u8,
    name: ?[]const u8,
    wire: ?WireRateLimit,
) RateLimit {
    const details = wire orelse return .{ .id = id, .name = name };
    return .{
        .id = id,
        .name = name,
        .allowed = details.allowed,
        .limit_reached = details.limit_reached,
        .primary_window = if (details.primary_window) |window| windowFromWire(window) else null,
        .secondary_window = if (details.secondary_window) |window| windowFromWire(window) else null,
    };
}

fn windowFromWire(window: WireWindow) Window {
    return .{
        .used_percent = window.used_percent,
        .limit_window_seconds = window.limit_window_seconds,
        .reset_after_seconds = window.reset_after_seconds,
        .reset_at = window.reset_at,
    };
}

test "Codex account endpoints derive from only the final typed Codex segment" {
    const alloc = std.testing.allocator;
    var production = try resolveEndpointsAlloc(alloc, .{});
    defer production.deinit(alloc);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/wham/usage", production.usage);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/wham/profiles/me", production.profile);

    var proxied = try resolveEndpointsAlloc(alloc, .{
        .responses = .{ .codex_base_url = "http://127.0.0.1:43123/backend-api/codex/" },
    });
    defer proxied.deinit(alloc);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/backend-api/wham/usage", proxied.usage);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/backend-api/wham/profiles/me", proxied.profile);

    var responses_endpoint = try resolveEndpointsAlloc(alloc, .{
        .responses = .{ .codex_base_url = "http://127.0.0.1:43123/backend-api/codex/responses/compact" },
    });
    defer responses_endpoint.deinit(alloc);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/backend-api/wham/usage", responses_endpoint.usage);

    var explicit = try resolveEndpointsAlloc(alloc, .{
        .account_base_url = "http://127.0.0.1:43123/account-root/",
        .responses = .{ .codex_base_url = "https://must-not-win.example/codex" },
    });
    defer explicit.deinit(alloc);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/account-root/api/codex/usage", explicit.usage);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/account-root/api/codex/profiles/me", explicit.profile);

    var embedded = try resolveEndpointsAlloc(alloc, .{
        .responses = .{ .codex_base_url = "https://codex.example.test/team/codex-proxy" },
    });
    defer embedded.deinit(alloc);
    try std.testing.expectEqualStrings(
        "https://codex.example.test/team/codex-proxy/api/codex/usage",
        embedded.usage,
    );
}

test "Codex account usage parser preserves complete data and ignores unknown fields" {
    const usage_json =
        \\{
        \\  "plan_type":"plus",
        \\  "rate_limit":{"allowed":true,"limit_reached":false,
        \\    "primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_after_seconds":900,"reset_at":2000},
        \\    "secondary_window":{"used_percent":34,"limit_window_seconds":604800,"reset_after_seconds":800,"reset_at":3000}},
        \\  "credits":{"has_credits":true,"unlimited":false,"balance":"7.50","future_credit_field":1},
        \\  "spend_control":{"reached":false,"individual_limit":{"source":"user","limit":"100","used":"25","remaining":"75","used_percent":25,"remaining_percent":75,"reset_after_seconds":600,"reset_at":4000}},
        \\  "additional_rate_limits":[{"limit_name":"Code review","metered_feature":"codex_review","rate_limit":{"allowed":false,"limit_reached":true}}],
        \\  "rate_limit_reached_type":{"type":"future_limit_kind"},
        \\  "rate_limit_reset_credits":{"available_count":3},
        \\  "future_root":{"kept_out_of_contract":true}
        \\}
    ;
    const profile_json =
        \\{"stats":{"lifetime_tokens":1000,"peak_daily_tokens":500,"longest_running_turn_sec":90,"current_streak_days":2,"longest_streak_days":8,"daily_usage_buckets":[{"start_date":"2026-08-20","tokens":300}],"future_stat":true},"future_root":true}
    ;

    var snapshot = try parseSnapshot(std.testing.allocator, usage_json, profile_json, 1234);
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("plus", snapshot.plan_type);
    try std.testing.expectEqual(@as(usize, 2), snapshot.rate_limits.len);
    try std.testing.expectEqualStrings("codex", snapshot.rate_limits[0].id);
    try std.testing.expectEqual(@as(i32, 12), snapshot.rate_limits[0].primary_window.?.used_percent);
    try std.testing.expectEqualStrings("codex_review", snapshot.rate_limits[1].id);
    try std.testing.expectEqualStrings("Code review", snapshot.rate_limits[1].name.?);
    try std.testing.expect(snapshot.rate_limits[1].limit_reached.?);
    try std.testing.expectEqualStrings("7.50", snapshot.credits.?.balance.?);
    try std.testing.expectEqualStrings("75", snapshot.spend_control.?.individual_limit.?.remaining);
    try std.testing.expectEqualStrings("future_limit_kind", snapshot.rate_limit_reached_type.?);
    try std.testing.expectEqual(@as(i64, 3), snapshot.rate_limit_reset_credits_available.?);
    try std.testing.expectEqual(@as(i64, 1000), snapshot.token_usage.lifetime_tokens.?);
    try std.testing.expectEqualStrings("2026-08-20", snapshot.daily_usage_buckets[0].start_date);
    try std.testing.expectEqual(@as(i64, 300), snapshot.daily_usage_buckets[0].tokens);
}

test "Codex account usage parser rejects malformed required structures" {
    try std.testing.expectError(
        error.InvalidCodexUsageResponse,
        parseSnapshot(std.testing.allocator, "{}", "{\"stats\":{}}", 0),
    );
    try std.testing.expectError(
        error.InvalidCodexTokenProfileResponse,
        parseSnapshot(std.testing.allocator, "{\"plan_type\":\"plus\"}", "{}", 0),
    );
}
