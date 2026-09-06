const std = @import("std");
const oauth_transport = @import("../auth/oauth_transport.zig");
const secret = @import("../auth/secret.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const codex_usage = @import("../gateway/codex_usage.zig");
const model_provider = @import("../config/model_provider.zig");
const provider_usage = @import("../session/provider_usage.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const refresh_interval_ms: i64 = 5 * 60 * 1000;

pub const Snapshot = struct {
    primary: ?provider_usage.WindowRemaining = null,
    secondary: ?provider_usage.WindowRemaining = null,
};

const LoadState = enum {
    idle,
    loading,
    ready,
    failed,
};

pub const Transition = enum {
    none,
    ready,
    failed,
};

const LoadRequest = struct {
    provider: gateway_provider.AccountUsageProvider,
    oauth_transport: oauth_transport.Provider,
    credential: []u8,
    account_id: []u8,
    credential_source: types.CredentialSource,
};

pub const Runtime = struct {
    const Self = @This();

    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    state: LoadState = .idle,
    completion_pending: bool = false,
    cache: ?Snapshot = null,
    last_error: ?anyerror = null,
    last_refresh_ms: i64 = 0,
    cancel_requested: std.atomic.Value(bool) = .init(false),

    pub fn init(alloc: Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn initInto(storage: *Self, alloc: Allocator) void {
        comptime {
            if (std.meta.fields(Self).len != 9) {
                @compileError("update Runtime.initInto for the changed field set");
            }
        }
        storage.* = undefined;
        storage.alloc = alloc;
        storage.mutex = .init;
        storage.thread = null;
        storage.state = .idle;
        storage.completion_pending = false;
        storage.cache = null;
        storage.last_error = null;
        storage.last_refresh_ms = 0;
        storage.cancel_requested = .init(false);
    }

    pub fn deinit(self: *Self) void {
        self.cancel_requested.store(true, .seq_cst);
        if (self.thread) |thread| {
            self.thread = null;
            thread.join();
        }
        self.* = undefined;
    }

    pub fn hasCachedOrPending(self: *Self) bool {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.state != .idle or self.cache != null or self.thread != null;
    }

    pub fn clear(self: *Self) void {
        if (!self.hasCachedOrPending()) return;
        self.cancel_requested.store(true, .seq_cst);
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        self.cache = null;
        self.last_error = null;
        self.last_refresh_ms = 0;
        self.completion_pending = false;
        if (self.thread == null) {
            self.state = .idle;
            self.mutex.unlock(io_mod.getIo());
            self.cancel_requested.store(false, .seq_cst);
            return;
        }
        // Leave the in-flight worker running. The TUI/ACP event loop must not
        // join HTTP cleanup; finishThreadIfDone reaps it after the thread exits.
        self.mutex.unlock(io_mod.getIo());
    }

    pub fn requestRefresh(
        self: *Self,
        provider: gateway_provider.AccountUsageProvider,
        oauth: oauth_transport.Provider,
        credential: []const u8,
        account_id: []const u8,
        credential_source: types.CredentialSource,
        now_ms: i64,
        force: bool,
    ) !bool {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.state == .loading) {
            self.mutex.unlock(io_mod.getIo());
            return false;
        }
        if (!force and self.last_refresh_ms != 0 and now_ms - self.last_refresh_ms < refresh_interval_ms) {
            self.mutex.unlock(io_mod.getIo());
            return false;
        }
        self.state = .loading;
        self.completion_pending = false;
        self.last_error = null;
        self.mutex.unlock(io_mod.getIo());
        self.cancel_requested.store(false, .seq_cst);

        const owned_credential = self.alloc.dupe(u8, credential) catch |err| {
            self.failStart(err);
            return err;
        };
        errdefer secret.zeroAndFree(self.alloc, owned_credential);
        const owned_account_id = self.alloc.dupe(u8, account_id) catch |err| {
            self.failStart(err);
            return err;
        };
        errdefer self.alloc.free(owned_account_id);

        self.thread = io_mod.spawn(
            .{},
            loadThreadMain,
            .{
                self,
                LoadRequest{
                    .provider = provider,
                    .oauth_transport = oauth,
                    .credential = owned_credential,
                    .account_id = owned_account_id,
                    .credential_source = credential_source,
                },
            },
        ) catch |err| {
            self.failStart(err);
            return err;
        };
        return true;
    }

    pub fn snapshot(self: *Self) ?Snapshot {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.cache;
    }

    pub fn summary(
        self: *Self,
        provider: model_provider.ProviderId,
        credential_source: ?types.CredentialSource,
        account_id: ?[]const u8,
    ) ?provider_usage.Summary {
        const cached = self.snapshot() orelse return null;
        if (cached.primary == null and cached.secondary == null) return null;
        return provider_usage.Summary.fromAccountLimits(
            provider,
            credential_source,
            account_id,
            cached.primary,
            cached.secondary,
        );
    }

    pub fn pollTransition(self: *Self) Transition {
        self.finishThreadIfDone();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.completion_pending) return .none;
        self.completion_pending = false;
        return if (self.last_error == null) .ready else .failed;
    }

    fn failStart(self: *Self, err: anyerror) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.state = if (self.cache != null) .ready else .failed;
        self.last_error = err;
        self.completion_pending = true;
        self.mutex.unlock(io_mod.getIo());
    }

    fn finishThreadIfDone(self: *Self) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        const should_join = self.state != .loading and self.thread != null;
        const thread = if (should_join) self.thread.? else null;
        if (should_join) self.thread = null;
        self.mutex.unlock(io_mod.getIo());
        if (thread) |handle| handle.join();
    }

    fn loadThreadMain(self: *Self, request: LoadRequest) void {
        defer secret.zeroAndFree(self.alloc, request.credential);
        defer self.alloc.free(request.account_id);

        var fetched = request.provider.fetch(self.alloc, .{
            .credential = request.credential,
            .account_id = request.account_id,
            .credential_source = request.credential_source,
            .oauth_transport = request.oauth_transport,
            .cancel_flag = &self.cancel_requested,
        });
        defer fetched.deinit(self.alloc);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.cancel_requested.load(.seq_cst)) {
            self.state = .idle;
            self.last_error = null;
            self.completion_pending = false;
            self.cancel_requested.store(false, .seq_cst);
            return;
        }
        if (fetched.failure != null or fetched.data == null) {
            self.state = if (self.cache != null) .ready else .failed;
            self.last_error = error.AccountUsageUnavailable;
            self.last_refresh_ms = io_mod.milliTimestamp();
            self.completion_pending = true;
            return;
        }
        self.cache = snapshotFromCodex(fetched.data.?);
        self.state = .ready;
        self.last_error = null;
        self.last_refresh_ms = io_mod.milliTimestamp();
        self.completion_pending = true;
    }
};

pub fn snapshotFromCodex(data: codex_usage.Snapshot) Snapshot {
    const limit = if (data.rate_limits.len > 0) data.rate_limits[0] else return .{};
    var five_hour: ?provider_usage.WindowRemaining = null;
    var weekly: ?provider_usage.WindowRemaining = null;
    var daily: ?provider_usage.WindowRemaining = null;
    var monthly: ?provider_usage.WindowRemaining = null;
    var unknown: ?provider_usage.WindowRemaining = null;
    if (limit.primary_window) |window| {
        assignClassifiedWindow(&five_hour, &weekly, &daily, &monthly, &unknown, window);
    }
    if (limit.secondary_window) |window| {
        assignClassifiedWindow(&five_hour, &weekly, &daily, &monthly, &unknown, window);
    }
    return .{
        .primary = five_hour orelse daily orelse monthly orelse unknown,
        .secondary = weekly,
    };
}

fn assignClassifiedWindow(
    five_hour: *?provider_usage.WindowRemaining,
    weekly: *?provider_usage.WindowRemaining,
    daily: *?provider_usage.WindowRemaining,
    monthly: *?provider_usage.WindowRemaining,
    unknown: *?provider_usage.WindowRemaining,
    window: codex_usage.Window,
) void {
    const remaining = windowRemaining(window);
    switch (remaining.kind) {
        .five_hour => {
            if (five_hour.* == null) five_hour.* = remaining;
        },
        .weekly => {
            if (weekly.* == null) weekly.* = remaining;
        },
        .daily => {
            if (daily.* == null) daily.* = remaining;
        },
        .monthly => {
            if (monthly.* == null) monthly.* = remaining;
        },
        .unknown => {
            if (unknown.* == null) unknown.* = remaining;
        },
    }
}

fn windowRemaining(window: codex_usage.Window) provider_usage.WindowRemaining {
    return .{
        .kind = windowKindFromSeconds(window.limit_window_seconds),
        .remaining_percent = remainingPercent(window.used_percent),
    };
}

fn remainingPercent(used_percent: i32) u8 {
    const remaining = 100 - used_percent;
    if (remaining <= 0) return 0;
    if (remaining >= 100) return 100;
    return @intCast(remaining);
}

fn windowKindFromSeconds(seconds: i32) provider_usage.WindowKind {
    const minutes = @divTrunc(@max(seconds, 0), 60);
    if (isApproximateWindow(minutes, 5 * 60)) return .five_hour;
    if (isApproximateWindow(minutes, 24 * 60)) return .daily;
    if (isApproximateWindow(minutes, 7 * 24 * 60)) return .weekly;
    if (isApproximateWindow(minutes, 30 * 24 * 60)) return .monthly;
    return .unknown;
}

fn isApproximateWindow(actual_minutes: i32, expected_minutes: i32) bool {
    const delta = if (actual_minutes > expected_minutes)
        actual_minutes - expected_minutes
    else
        expected_minutes - actual_minutes;
    return delta <= @max(@divTrunc(expected_minutes, 10), 1);
}

test "account usage runtime in-place initialization preserves idle state" {
    var runtime: Runtime = undefined;
    Runtime.initInto(&runtime, std.testing.allocator);
    defer runtime.deinit();

    try std.testing.expect(runtime.thread == null);
    try std.testing.expect(runtime.state == .idle);
    try std.testing.expect(runtime.cache == null);
    try std.testing.expect(runtime.last_error == null);
}

test "Codex windows map 5h and week remaining percents" {
    const snapshot = snapshotFromCodex(.{
        .plan_type = "plus",
        .rate_limits = &.{.{
            .id = "codex",
            .primary_window = .{
                .used_percent = 12,
                .limit_window_seconds = 18_000,
                .reset_after_seconds = 900,
                .reset_at = 2000,
            },
            .secondary_window = .{
                .used_percent = 34,
                .limit_window_seconds = 604_800,
                .reset_after_seconds = 800,
                .reset_at = 3000,
            },
        }},
        .credits = null,
        .spend_control = null,
        .rate_limit_reached_type = null,
        .rate_limit_reset_credits_available = null,
        .token_usage = .{},
        .daily_usage_buckets = &.{},
        .fetched_at_ms = 1,
        .arena = undefined,
    });
    try std.testing.expectEqual(provider_usage.WindowKind.five_hour, snapshot.primary.?.kind);
    try std.testing.expectEqual(@as(u8, 88), snapshot.primary.?.remaining_percent);
    try std.testing.expectEqual(provider_usage.WindowKind.weekly, snapshot.secondary.?.kind);
    try std.testing.expectEqual(@as(u8, 66), snapshot.secondary.?.remaining_percent);
}

test "Codex weekly-only window omits the 5h slot" {
    const snapshot = snapshotFromCodex(.{
        .plan_type = "pro",
        .rate_limits = &.{.{
            .id = "codex",
            .primary_window = .{
                .used_percent = 9,
                .limit_window_seconds = 604_800,
                .reset_after_seconds = 800,
                .reset_at = 3000,
            },
            .secondary_window = null,
        }},
        .credits = null,
        .spend_control = null,
        .rate_limit_reached_type = null,
        .rate_limit_reset_credits_available = null,
        .token_usage = .{},
        .daily_usage_buckets = &.{},
        .fetched_at_ms = 1,
        .arena = undefined,
    });
    try std.testing.expect(snapshot.primary == null);
    try std.testing.expectEqual(provider_usage.WindowKind.weekly, snapshot.secondary.?.kind);
    try std.testing.expectEqual(@as(u8, 91), snapshot.secondary.?.remaining_percent);
}

test "Codex monthly plus weekly maps remaining percents" {
    const snapshot = snapshotFromCodex(.{
        .plan_type = "pro",
        .rate_limits = &.{.{
            .id = "codex",
            .primary_window = .{
                .used_percent = 35,
                .limit_window_seconds = 30 * 24 * 60 * 60,
                .reset_after_seconds = 800,
                .reset_at = 3000,
            },
            .secondary_window = .{
                .used_percent = 94,
                .limit_window_seconds = 604_800,
                .reset_after_seconds = 800,
                .reset_at = 3000,
            },
        }},
        .credits = null,
        .spend_control = null,
        .rate_limit_reached_type = null,
        .rate_limit_reset_credits_available = null,
        .token_usage = .{},
        .daily_usage_buckets = &.{},
        .fetched_at_ms = 1,
        .arena = undefined,
    });
    try std.testing.expectEqual(provider_usage.WindowKind.monthly, snapshot.primary.?.kind);
    try std.testing.expectEqual(@as(u8, 65), snapshot.primary.?.remaining_percent);
    try std.testing.expectEqual(provider_usage.WindowKind.weekly, snapshot.secondary.?.kind);
    try std.testing.expectEqual(@as(u8, 6), snapshot.secondary.?.remaining_percent);
}

test "account usage runtime fetches off the caller thread" {
    const Gate = struct {
        allow_finish: std.atomic.Value(bool) = .init(false),
        loads: std.atomic.Value(usize) = .init(0),

        fn fetch(
            raw: ?*anyopaque,
            _: Allocator,
            _: gateway_provider.AccountUsageLookupInput,
        ) @import("../output/output_contracts.zig").CodexAccountUsageSnapshot {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.loads.fetchAdd(1, .seq_cst);
            while (!self.allow_finish.load(.seq_cst)) {
                io_mod.sleep(std.time.ns_per_ms);
            }
            return .{};
        }
    };

    var gate = Gate{};
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    try std.testing.expect(try runtime.requestRefresh(
        .{ .context = &gate, .fetch_fn = Gate.fetch },
        oauth_transport.unavailable_provider,
        "access",
        "acct",
        .chatgpt_subscription,
        1,
        true,
    ));
    try std.testing.expect(!(try runtime.requestRefresh(
        .{ .context = &gate, .fetch_fn = Gate.fetch },
        oauth_transport.unavailable_provider,
        "access",
        "acct",
        .chatgpt_subscription,
        1,
        true,
    )));
    gate.allow_finish.store(true, .seq_cst);
    var remaining_ms: usize = 5000;
    while (runtime.pollTransition() == .none and remaining_ms > 0) : (remaining_ms -= 1) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(remaining_ms > 0);
    try std.testing.expectEqual(@as(usize, 1), gate.loads.load(.seq_cst));
}

test "account usage clear does not join an in-flight refresh" {
    const Gate = struct {
        allow_finish: std.atomic.Value(bool) = .init(false),
        loads: std.atomic.Value(usize) = .init(0),
        entered: std.atomic.Value(bool) = .init(false),

        fn fetch(
            raw: ?*anyopaque,
            _: Allocator,
            input: gateway_provider.AccountUsageLookupInput,
        ) @import("../output/output_contracts.zig").CodexAccountUsageSnapshot {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.loads.fetchAdd(1, .seq_cst);
            self.entered.store(true, .seq_cst);
            while (!self.allow_finish.load(.seq_cst)) {
                if (input.cancel_flag) |flag| {
                    if (flag.load(.seq_cst)) break;
                }
                io_mod.sleep(std.time.ns_per_ms);
            }
            return .{};
        }
    };

    var gate = Gate{};
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    try std.testing.expect(try runtime.requestRefresh(
        .{ .context = &gate, .fetch_fn = Gate.fetch },
        oauth_transport.unavailable_provider,
        "access",
        "acct",
        .chatgpt_subscription,
        1,
        true,
    ));
    var remaining_ms: usize = 5000;
    while (!gate.entered.load(.seq_cst) and remaining_ms > 0) : (remaining_ms -= 1) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(gate.entered.load(.seq_cst));
    runtime.clear();
    try std.testing.expect(runtime.snapshot() == null);
    gate.allow_finish.store(true, .seq_cst);
    remaining_ms = 5000;
    while (runtime.hasCachedOrPending() and remaining_ms > 0) : (remaining_ms -= 1) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(remaining_ms > 0);
    try std.testing.expectEqual(@as(usize, 1), gate.loads.load(.seq_cst));
}
