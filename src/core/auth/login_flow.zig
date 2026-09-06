const std = @import("std");
const chatgpt_session = @import("chatgpt_session.zig");
const grok_session = @import("grok_session.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const oauth = @import("oauth.zig");
const oauth_transport = @import("oauth_transport.zig");

const Allocator = std.mem.Allocator;
const poll_wait_slice_ms: u64 = 100;
pub const poll_request_timeout_ms: i64 = 15_000;
const max_poll_interval_ms = std.math.maxInt(u64) / std.time.ns_per_ms;

pub const LoginError = error{
    LoginTimedOut,
};

pub const SignInState = enum {
    idle,
    polling,
    succeeded,
    failed,
    cancelled,
};

pub const SignInSnapshot = struct {
    state: SignInState = .idle,
    authorization_url: []const u8 = "",
    accepts_manual_code: bool = false,
};

pub const max_manual_code_bytes: usize = 4096;

pub const SignInCompletion = union(enum) {
    none,
    chatgpt: chatgpt_session.Session,
    grok: grok_session.Session,

    pub fn deinit(self: *SignInCompletion, alloc: Allocator) void {
        switch (self.*) {
            .none => {},
            .chatgpt => |*session| session.deinit(alloc),
            .grok => |*session| session.deinit(alloc),
        }
        self.* = .none;
    }

    pub fn take(self: *SignInCompletion) SignInCompletion {
        const completion = self.*;
        self.* = .none;
        return completion;
    }
};

pub const SignInTransition = union(enum) {
    none,
    succeeded: SignInCompletion,
    failed: anyerror,
    cancelled,
};

pub const PreparedLogin = struct {
    token_endpoint: []u8,
    authorization_url: []u8,
    expires_in_seconds: i64,
    poll_interval_seconds: i64,

    pub fn deinit(self: *PreparedLogin, alloc: Allocator) void {
        alloc.free(self.token_endpoint);
        alloc.free(self.authorization_url);
        self.* = undefined;
    }
};

pub const CompleteSignInFn = *const fn (
    ?*anyopaque,
    Allocator,
    *oauth.TokenSet,
) anyerror!SignInCompletion;
pub const SaveSignInFn = *const fn (?*anyopaque, Allocator, SignInCompletion) anyerror!void;
pub const DeinitSignInContextFn = *const fn (?*anyopaque, Allocator) void;
pub const SubmitManualCodeFn = *const fn (?*anyopaque, Allocator, []const u8) anyerror!void;

pub const SignInRuntimeDeps = struct {
    ctx: ?*anyopaque = null,
    deinit_ctx: ?DeinitSignInContextFn = null,
    oauth_transport: oauth_transport.Provider = oauth_transport.unavailable_provider,
    poll: LoginPollDeps = .{},
    complete: CompleteSignInFn = unavailableCompleteSignIn,
    save: SaveSignInFn = unavailableSaveSignIn,
    submit_manual_code: ?SubmitManualCodeFn = null,
};

fn unavailableCompleteSignIn(
    _: ?*anyopaque,
    _: Allocator,
    _: *oauth.TokenSet,
) !SignInCompletion {
    return error.SignInCompletionUnavailable;
}

fn unavailableSaveSignIn(_: ?*anyopaque, _: Allocator, _: SignInCompletion) !void {
    return error.SignInStorageUnavailable;
}

pub const SignInRuntime = struct {
    const Self = @This();

    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    state: SignInState = .idle,
    flow: ?PreparedLogin = null,
    completion: ?SignInCompletion = null,
    failure: ?anyerror = null,
    poll_state: ?LoginPollState = null,
    deps: SignInRuntimeDeps = .{},

    pub fn startPrepared(
        self: *Self,
        alloc: Allocator,
        prepared: PreparedLogin,
        deps: SignInRuntimeDeps,
    ) !bool {
        return self.startPreparedWithMode(alloc, prepared, deps, host_target.is_wasm);
    }

    fn startPreparedCooperative(
        self: *Self,
        alloc: Allocator,
        prepared: PreparedLogin,
        deps: SignInRuntimeDeps,
    ) !bool {
        return self.startPreparedWithMode(alloc, prepared, deps, true);
    }

    fn startPreparedWithMode(
        self: *Self,
        alloc: Allocator,
        prepared: PreparedLogin,
        deps: SignInRuntimeDeps,
        comptime cooperative: bool,
    ) !bool {
        const poll_state = if (cooperative)
            LoginPollState.init(deps.poll, prepared.expires_in_seconds, prepared.poll_interval_seconds) catch |err| {
                var rejected = prepared;
                rejected.deinit(alloc);
                if (deps.deinit_ctx) |deinit_ctx| deinit_ctx(deps.ctx, alloc);
                return err;
            }
        else
            null;
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.thread != null or self.state == .polling or self.completion != null) {
            self.mutex.unlock(io_mod.getIo());
            var rejected = prepared;
            rejected.deinit(alloc);
            if (deps.deinit_ctx) |deinit_ctx| deinit_ctx(deps.ctx, alloc);
            return false;
        }
        self.state = .polling;
        self.failure = null;
        self.flow = prepared;
        self.poll_state = poll_state;
        self.deps = deps;
        self.deps.poll.cancel_flag = &self.cancel_requested;
        self.cancel_requested.store(false, .seq_cst);
        self.mutex.unlock(io_mod.getIo());

        if (cooperative) return true;
        self.thread = io_mod.spawn(.{}, workerMain, .{ self, alloc }) catch |err| {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.state = .idle;
            self.mutex.unlock(io_mod.getIo());
            self.clearFlow(alloc);
            return err;
        };
        return true;
    }

    pub fn cancel(self: *Self, alloc: Allocator) bool {
        self.cancel_requested.store(true, .seq_cst);
        self.mutex.lockUncancelable(io_mod.getIo());
        const cancelled = self.state == .polling;
        if (cancelled) self.state = .cancelled;
        const thread = self.thread;
        self.thread = null;
        self.mutex.unlock(io_mod.getIo());

        if (comptime !host_target.is_wasm) {
            if (thread) |handle| handle.join();
        }
        self.clearFlow(alloc);
        return cancelled;
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        _ = self.cancel(alloc);
        if (self.completion) |*selection| selection.deinit(alloc);
        self.completion = null;
        self.failure = null;
        self.state = .idle;
    }

    pub fn snapshot(self: *const Self) SignInSnapshot {
        const mutable = @constCast(self);
        mutable.mutex.lockUncancelable(io_mod.getIo());
        defer mutable.mutex.unlock(io_mod.getIo());
        const flow = self.flow orelse return .{ .state = self.state };
        return .{
            .state = self.state,
            .authorization_url = flow.authorization_url,
            .accepts_manual_code = self.deps.submit_manual_code != null,
        };
    }

    pub fn submitManualCode(self: *Self, alloc: Allocator, code: []const u8) !bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .polling) return false;
        const submit = self.deps.submit_manual_code orelse return false;
        try submit(self.deps.ctx, alloc, code);
        return true;
    }

    pub fn browserUrlAlloc(self: *Self, alloc: Allocator) !?[]u8 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const flow = self.flow orelse return null;
        return try alloc.dupe(u8, flow.authorization_url);
    }

    pub fn pollTransition(self: *Self, alloc: Allocator) SignInTransition {
        self.mutex.lockUncancelable(io_mod.getIo());
        const terminal = switch (self.state) {
            .succeeded, .failed, .cancelled => true,
            .idle, .polling => false,
        };
        const thread = if (terminal) self.thread else null;
        if (terminal) self.thread = null;
        self.mutex.unlock(io_mod.getIo());
        if (!terminal) return .none;

        if (comptime !host_target.is_wasm) {
            if (thread) |handle| handle.join();
        }
        self.clearFlow(alloc);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const state = self.state;
        self.state = .idle;
        return switch (state) {
            .succeeded => blk: {
                const completion = self.completion orelse break :blk .{ .failed = error.LoginCompletionMissing };
                self.completion = null;
                break :blk .{ .succeeded = completion };
            },
            .failed => blk: {
                const failure = self.failure orelse error.OAuthRequestFailed;
                self.failure = null;
                break :blk .{ .failed = failure };
            },
            .cancelled => .cancelled,
            .idle, .polling => .none,
        };
    }

    fn workerMain(self: *Self, alloc: Allocator) void {
        const flow = if (self.flow) |*prepared| prepared else return;
        var token = pollForTokenWithDeps(
            alloc,
            self.deps.oauth_transport,
            flow.*,
            self.deps.poll,
        ) catch |err| {
            self.publishFailure(err);
            return;
        };
        defer token.deinit(alloc);

        self.completeToken(alloc, &token);
    }

    pub fn pulse(self: *Self, alloc: Allocator) void {
        if (comptime !host_target.is_wasm) return;
        self.pulseCooperative(alloc);
    }

    fn pulseCooperative(self: *Self, alloc: Allocator) void {
        if (self.state != .polling) return;
        const flow = if (self.flow) |*prepared| prepared else return;
        const poll_state = if (self.poll_state) |*state| state else {
            self.publishFailure(error.LoginPollStateMissing);
            return;
        };
        const step = pollTokenStep(
            alloc,
            self.deps.oauth_transport,
            flow.*,
            self.deps.poll,
            poll_state,
        ) catch |err| {
            self.publishFailure(err);
            return;
        };
        switch (step) {
            .waiting => {},
            .succeeded => |token| {
                var owned = token;
                defer owned.deinit(alloc);
                self.completeToken(alloc, &owned);
            },
        }
    }

    fn completeToken(self: *Self, alloc: Allocator, token: *oauth.TokenSet) void {
        if (self.flow == null) {
            self.publishFailure(error.LoginFlowMissing);
            return;
        }
        if (self.cancel_requested.load(.seq_cst)) {
            debug_trace.logf("auth", "sign-in discarded token after cancel", .{});
            return;
        }
        var completion = self.deps.complete(
            self.deps.ctx,
            alloc,
            token,
        ) catch |err| {
            self.publishFailure(err);
            return;
        };
        defer completion.deinit(alloc);

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .polling or self.cancel_requested.load(.seq_cst)) {
            debug_trace.logf("auth", "sign-in discarded session after cancel state={t}", .{self.state});
            return;
        }
        self.deps.save(self.deps.ctx, alloc, completion) catch |err| {
            debug_trace.logf("auth", "sign-in session save failed err={s}", .{@errorName(err)});
            self.failure = err;
            self.state = .failed;
            return;
        };
        self.completion = completion.take();
        self.state = .succeeded;
    }

    fn publishFailure(self: *Self, err: anyerror) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .polling or self.cancel_requested.load(.seq_cst)) {
            debug_trace.logf(
                "auth",
                "sign-in suppressed post-cancel failure err={s} state={t}",
                .{ @errorName(err), self.state },
            );
            return;
        }
        if (err == error.Cancelled) {
            self.state = .cancelled;
            return;
        }
        self.failure = err;
        self.state = .failed;
    }

    fn clearFlow(self: *Self, alloc: Allocator) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        var flow = self.flow;
        const deps = self.deps;
        self.flow = null;
        self.poll_state = null;
        self.deps = .{};
        self.mutex.unlock(io_mod.getIo());
        if (flow) |*prepared| prepared.deinit(alloc);
        if (deps.deinit_ctx) |deinit_ctx| deinit_ctx(deps.ctx, alloc);
    }
};

pub const LoginPollDeps = struct {
    ctx: ?*anyopaque = null,
    now_ms: *const fn (?*anyopaque) i64 = realNowMs,
    poll_token: *const fn (
        ?*anyopaque,
        Allocator,
        oauth_transport.Provider,
        []const u8,
        *std.atomic.Value(bool),
        std.Io.Clock.Timestamp,
    ) anyerror!oauth.PollResult = unavailablePollToken,
    sleep_ms: *const fn (?*anyopaque, u64) void = realSleepMs,
    is_cancelled: *const fn (?*anyopaque) bool = neverCancelled,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    request_timeout_ms: i64 = poll_request_timeout_ms,
};

const LoginPollState = struct {
    expires_at_ms: i64,
    interval_ms: u64,
    next_poll_at_ms: i64,

    fn init(deps: LoginPollDeps, expires_in_seconds: i64, poll_interval_seconds: i64) !LoginPollState {
        const now_ms = deps.now_ms(deps.ctx);
        return .{
            .expires_at_ms = try oauth.expiry_timestamp_ms(now_ms, expires_in_seconds),
            .interval_ms = try poll_interval_ms(poll_interval_seconds),
            .next_poll_at_ms = now_ms,
        };
    }

    fn scheduleNext(self: *LoginPollState, now_ms: i64) !void {
        const interval_ms = std.math.cast(i64, self.interval_ms) orelse
            return oauth.OAuthError.InvalidOAuthResponse;
        self.next_poll_at_ms = std.math.add(i64, now_ms, interval_ms) catch
            return oauth.OAuthError.InvalidOAuthResponse;
    }

    fn waitMs(self: LoginPollState, now_ms: i64) u64 {
        if (now_ms >= self.next_poll_at_ms) return 0;
        return @intCast(self.next_poll_at_ms - now_ms);
    }
};

const LoginPollStep = union(enum) {
    waiting,
    succeeded: oauth.TokenSet,
};

fn pollForTokenWithDeps(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    flow: PreparedLogin,
    deps: LoginPollDeps,
) !oauth.TokenSet {
    var state = try LoginPollState.init(deps, flow.expires_in_seconds, flow.poll_interval_seconds);
    while (true) {
        switch (try pollTokenStep(alloc, transport, flow, deps, &state)) {
            .succeeded => |token| return token,
            .waiting => {
                const wait_ms = state.waitMs(deps.now_ms(deps.ctx));
                if (wait_ms > 0) try waitBetweenPolls(deps, wait_ms);
            },
        }
    }
}

fn pollTokenStep(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    flow: PreparedLogin,
    deps: LoginPollDeps,
    state: *LoginPollState,
) !LoginPollStep {
    const now_ms = deps.now_ms(deps.ctx);
    if (now_ms >= state.expires_at_ms) return LoginError.LoginTimedOut;
    if (pollCancelled(deps)) return error.Cancelled;
    if (now_ms < state.next_poll_at_ms) return .waiting;

    var local_cancel_flag = std.atomic.Value(bool).init(false);
    const cancel_flag = deps.cancel_flag orelse &local_cancel_flag;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(deps.request_timeout_ms),
    });
    switch (try deps.poll_token(
        deps.ctx,
        alloc,
        transport,
        flow.token_endpoint,
        cancel_flag,
        deadline,
    )) {
        .success => |token| {
            if (pollCancelled(deps)) {
                var owned = token;
                owned.deinit(alloc);
                debug_trace.logf("auth", "sign-in poll discarded granted token after cancel", .{});
                return error.Cancelled;
            }
            return .{ .succeeded = token };
        },
        .pending => {},
        .slow_down => {
            state.interval_ms = std.math.add(u64, state.interval_ms, 5 * std.time.ms_per_s) catch
                return oauth.OAuthError.InvalidOAuthResponse;
            if (state.interval_ms > max_poll_interval_ms) return oauth.OAuthError.InvalidOAuthResponse;
        },
    }
    try state.scheduleNext(deps.now_ms(deps.ctx));
    return .waiting;
}

fn poll_interval_ms(interval_seconds: i64) oauth.OAuthError!u64 {
    const seconds = @max(interval_seconds, 1);
    const signed_interval_ms = std.math.mul(i64, seconds, std.time.ms_per_s) catch
        return oauth.OAuthError.InvalidOAuthResponse;
    const interval_ms = std.math.cast(u64, signed_interval_ms) orelse
        return oauth.OAuthError.InvalidOAuthResponse;
    if (interval_ms > max_poll_interval_ms) return oauth.OAuthError.InvalidOAuthResponse;
    return interval_ms;
}

fn waitBetweenPolls(
    deps: LoginPollDeps,
    interval_ms: u64,
) error{Cancelled}!void {
    var remaining_ms = interval_ms;
    while (remaining_ms > 0) {
        if (pollCancelled(deps)) return error.Cancelled;
        const slice_ms = @min(remaining_ms, poll_wait_slice_ms);
        deps.sleep_ms(deps.ctx, slice_ms);
        remaining_ms -= slice_ms;
    }
    if (pollCancelled(deps)) return error.Cancelled;
}

fn pollCancelled(deps: LoginPollDeps) bool {
    if (deps.is_cancelled(deps.ctx)) return true;
    const flag = deps.cancel_flag orelse return false;
    return flag.load(.seq_cst);
}

fn realNowMs(_: ?*anyopaque) i64 {
    return io_mod.milliTimestamp();
}

fn unavailablePollToken(
    _: ?*anyopaque,
    _: Allocator,
    _: oauth_transport.Provider,
    _: []const u8,
    _: *std.atomic.Value(bool),
    _: std.Io.Clock.Timestamp,
) !oauth.PollResult {
    return error.SignInPollUnavailable;
}

fn neverCancelled(_: ?*anyopaque) bool {
    return false;
}

fn realSleepMs(_: ?*anyopaque, ms: u64) void {
    io_mod.sleep(ms *| std.time.ns_per_ms);
}

const ScriptedPollResult = enum {
    pending,
    slow_down,
    success,
};

const LoginPollTestState = struct {
    alloc: Allocator,
    results: []const ScriptedPollResult,
    poll_index: usize = 0,
    sleep_calls: std.ArrayList(u64) = .empty,
    now_ms: i64 = 0,

    fn init(alloc: Allocator, results: []const ScriptedPollResult) LoginPollTestState {
        return .{ .alloc = alloc, .results = results };
    }

    fn deinit(self: *LoginPollTestState) void {
        self.sleep_calls.deinit(self.alloc);
    }

    fn deps(self: *LoginPollTestState) LoginPollDeps {
        return .{
            .ctx = self,
            .now_ms = testNowMs,
            .poll_token = testPollToken,
            .sleep_ms = testSleepMs,
        };
    }

    fn testNowMs(raw: ?*anyopaque) i64 {
        const self = testState(raw);
        return self.now_ms;
    }

    fn testPollToken(
        raw: ?*anyopaque,
        alloc: Allocator,
        _: oauth_transport.Provider,
        _: []const u8,
        _: *std.atomic.Value(bool),
        _: std.Io.Clock.Timestamp,
    ) !oauth.PollResult {
        const self = testState(raw);
        if (self.poll_index >= self.results.len) return error.TestUnexpectedDevicePoll;
        const result = self.results[self.poll_index];
        self.poll_index += 1;
        return switch (result) {
            .pending => .pending,
            .slow_down => .slow_down,
            .success => .{ .success = try testTokenSet(alloc) },
        };
    }

    fn testSleepMs(raw: ?*anyopaque, ms: u64) void {
        const self = testState(raw);
        self.sleep_calls.append(self.alloc, ms) catch unreachable;
        self.now_ms += @intCast(ms);
    }

    fn testState(raw: ?*anyopaque) *LoginPollTestState {
        return @ptrCast(@alignCast(raw.?));
    }
};

fn testPreparedLogin() PreparedLogin {
    return .{
        .token_endpoint = @constCast("https://provider.test/token"),
        .authorization_url = @constCast("https://provider.test/oauth/authorize"),
        .expires_in_seconds = 60,
        .poll_interval_seconds = 1,
    };
}

fn testTokenSet(alloc: Allocator) !oauth.TokenSet {
    return .{
        .access_token = try alloc.dupe(u8, "access"),
        .refresh_token = try alloc.dupe(u8, "refresh"),
        .expires_in = 3600,
        .scope = try alloc.dupe(u8, "openid offline_access"),
        .token_type = try alloc.dupe(u8, "Bearer"),
    };
}

const SignInTestPollMode = enum {
    pending_then_wait,
    in_flight,
    success,
};

const SignInTestState = struct {
    mode: SignInTestPollMode,
    poll_started: std.atomic.Value(bool) = .init(false),
    poll_count: std.atomic.Value(usize) = .init(0),
    complete_count: std.atomic.Value(usize) = .init(0),
    save_count: std.atomic.Value(usize) = .init(0),

    fn deps(self: *@This()) SignInRuntimeDeps {
        return .{
            .ctx = self,
            .poll = .{
                .ctx = self,
                .poll_token = poll,
            },
            .complete = complete,
            .save = save,
        };
    }

    fn poll(
        raw: ?*anyopaque,
        alloc: Allocator,
        _: oauth_transport.Provider,
        _: []const u8,
        cancel_flag: *std.atomic.Value(bool),
        _: std.Io.Clock.Timestamp,
    ) !oauth.PollResult {
        const self = state(raw);
        _ = self.poll_count.fetchAdd(1, .seq_cst);
        self.poll_started.store(true, .seq_cst);
        return switch (self.mode) {
            .pending_then_wait => .pending,
            .in_flight => {
                while (!cancel_flag.load(.seq_cst)) blockingSleep(1);
                return error.Cancelled;
            },
            .success => .{ .success = try testTokenSet(alloc) },
        };
    }

    fn complete(
        raw: ?*anyopaque,
        _: Allocator,
        _: *oauth.TokenSet,
    ) !SignInCompletion {
        const self = state(raw);
        _ = self.complete_count.fetchAdd(1, .seq_cst);
        return .none;
    }

    fn save(raw: ?*anyopaque, _: Allocator, _: SignInCompletion) !void {
        const self = state(raw);
        _ = self.save_count.fetchAdd(1, .seq_cst);
    }

    fn state(raw: ?*anyopaque) *@This() {
        return @ptrCast(@alignCast(raw.?));
    }
};

const CooperativeSignInTestState = struct {
    poll: LoginPollTestState,
    complete_count: usize = 0,
    save_count: usize = 0,
    fail_save: bool = false,

    fn init(alloc: Allocator, results: []const ScriptedPollResult) @This() {
        return .{ .poll = LoginPollTestState.init(alloc, results) };
    }

    fn deinit(self: *@This()) void {
        self.poll.deinit();
    }

    fn deps(self: *@This()) SignInRuntimeDeps {
        return .{
            .ctx = self,
            .poll = self.poll.deps(),
            .complete = complete,
            .save = save,
        };
    }

    fn complete(
        raw: ?*anyopaque,
        _: Allocator,
        _: *oauth.TokenSet,
    ) !SignInCompletion {
        const self = state(raw);
        self.complete_count += 1;
        return .none;
    }

    fn save(raw: ?*anyopaque, _: Allocator, _: SignInCompletion) !void {
        const self = state(raw);
        self.save_count += 1;
        if (self.fail_save) return error.TestStoreCommitFailed;
    }

    fn state(raw: ?*anyopaque) *@This() {
        return @ptrCast(@alignCast(raw.?));
    }
};

fn makeTestPreparedLogin(alloc: Allocator) !PreparedLogin {
    return .{
        .token_endpoint = try alloc.dupe(u8, "https://provider.test/token"),
        .authorization_url = try alloc.dupe(u8, "https://provider.test/oauth/authorize"),
        .expires_in_seconds = 60,
        .poll_interval_seconds = 1,
    };
}

fn blockingSleep(milliseconds: u64) void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.io().sleep(.fromMilliseconds(@intCast(milliseconds)), .real) catch {};
}

fn waitForAtomic(flag: *std.atomic.Value(bool), timeout_ms: u64) bool {
    var remaining_ms = timeout_ms;
    while (remaining_ms > 0) : (remaining_ms -= 1) {
        if (flag.load(.seq_cst)) return true;
        blockingSleep(1);
    }
    return flag.load(.seq_cst);
}

fn waitForSignInTransition(
    runtime: *SignInRuntime,
    alloc: Allocator,
    timeout_ms: u64,
) SignInTransition {
    var remaining_ms = timeout_ms;
    while (remaining_ms > 0) : (remaining_ms -= 1) {
        const transition = runtime.pollTransition(alloc);
        if (transition != .none) return transition;
        blockingSleep(1);
    }
    return runtime.pollTransition(alloc);
}

test "sign-in runtime releases an owned provider context exactly once" {
    const Cleanup = struct {
        fn run(raw: ?*anyopaque, _: Allocator) void {
            const count: *usize = @ptrCast(@alignCast(raw.?));
            count.* += 1;
        }
    };

    const alloc = std.testing.allocator;
    var cleanup_count: usize = 0;
    var runtime: SignInRuntime = .{};
    try std.testing.expect(try runtime.startPreparedCooperative(
        alloc,
        try makeTestPreparedLogin(alloc),
        .{
            .ctx = &cleanup_count,
            .deinit_ctx = Cleanup.run,
        },
    ));
    try std.testing.expect(runtime.cancel(alloc));
    runtime.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "cooperative sign-in polls once per pulse and shares pending and slow_down timing" {
    const alloc = std.testing.allocator;
    var runtime: SignInRuntime = .{};
    defer runtime.deinit(alloc);
    var state = CooperativeSignInTestState.init(alloc, &.{ .pending, .slow_down, .success });
    defer state.deinit();
    try std.testing.expect(try runtime.startPreparedCooperative(
        alloc,
        try makeTestPreparedLogin(alloc),
        state.deps(),
    ));

    runtime.pulseCooperative(alloc);
    try std.testing.expectEqual(@as(usize, 1), state.poll.poll_index);
    try std.testing.expectEqual(@as(i64, 1000), runtime.poll_state.?.next_poll_at_ms);
    runtime.pulseCooperative(alloc);
    try std.testing.expectEqual(@as(usize, 1), state.poll.poll_index);

    state.poll.now_ms = 1000;
    runtime.pulseCooperative(alloc);
    try std.testing.expectEqual(@as(usize, 2), state.poll.poll_index);
    try std.testing.expectEqual(@as(u64, 6000), runtime.poll_state.?.interval_ms);
    try std.testing.expectEqual(@as(i64, 7000), runtime.poll_state.?.next_poll_at_ms);
    state.poll.now_ms = 6999;
    runtime.pulseCooperative(alloc);
    try std.testing.expectEqual(@as(usize, 2), state.poll.poll_index);

    state.poll.now_ms = 7000;
    runtime.pulseCooperative(alloc);
    var transition = runtime.pollTransition(alloc);
    switch (transition) {
        .succeeded => |*selection| selection.deinit(alloc),
        else => return error.TestExpectedSuccessfulSignIn,
    }
    try std.testing.expectEqual(@as(usize, 1), state.complete_count);
    try std.testing.expectEqual(@as(usize, 1), state.save_count);
}

test "cooperative sign-in cancellation publishes no session" {
    const alloc = std.testing.allocator;
    var runtime: SignInRuntime = .{};
    defer runtime.deinit(alloc);
    var state = CooperativeSignInTestState.init(alloc, &.{.pending});
    defer state.deinit();
    try std.testing.expect(try runtime.startPreparedCooperative(
        alloc,
        try makeTestPreparedLogin(alloc),
        state.deps(),
    ));
    runtime.pulseCooperative(alloc);

    try std.testing.expect(runtime.cancel(alloc));
    try std.testing.expectEqual(SignInTransition.cancelled, runtime.pollTransition(alloc));
    try std.testing.expectEqual(@as(usize, 0), state.complete_count);
    try std.testing.expectEqual(@as(usize, 0), state.save_count);
}

test "cooperative sign-in reports authorization expiry without another poll" {
    const alloc = std.testing.allocator;
    var runtime: SignInRuntime = .{};
    defer runtime.deinit(alloc);
    var state = CooperativeSignInTestState.init(alloc, &.{.success});
    defer state.deinit();
    var prepared = try makeTestPreparedLogin(alloc);
    prepared.expires_in_seconds = 1;
    try std.testing.expect(try runtime.startPreparedCooperative(alloc, prepared, state.deps()));
    state.poll.now_ms = 1000;
    runtime.pulseCooperative(alloc);

    switch (runtime.pollTransition(alloc)) {
        .failed => |err| try std.testing.expectEqual(LoginError.LoginTimedOut, err),
        else => return error.TestExpectedExpiredSignIn,
    }
    try std.testing.expectEqual(@as(usize, 0), state.poll.poll_index);
    try std.testing.expectEqual(@as(usize, 0), state.save_count);
}

test "cooperative sign-in store failure is traced and becomes a recoverable transition" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "sign-in-store-failure.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "auth");

    var runtime: SignInRuntime = .{};
    defer runtime.deinit(alloc);
    var state = CooperativeSignInTestState.init(alloc, &.{.success});
    defer state.deinit();
    state.fail_save = true;
    try std.testing.expect(try runtime.startPreparedCooperative(
        alloc,
        try makeTestPreparedLogin(alloc),
        state.deps(),
    ));
    runtime.pulseCooperative(alloc);

    switch (runtime.pollTransition(alloc)) {
        .failed => |err| try std.testing.expectEqual(error.TestStoreCommitFailed, err),
        else => return error.TestExpectedStoreFailure,
    }
    debug_trace.shutdown();
    var trace_file = try std.Io.Dir.openFileAbsolute(std.testing.io, trace_path, .{});
    defer trace_file.close(std.testing.io);
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 4096);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "sign-in session save failed err=TestStoreCommitFailed") != null);
    try std.testing.expect(std.mem.find(u8, trace, "access") == null);
    try std.testing.expect(std.mem.find(u8, trace, "refresh") == null);
}

test "VT-8(b) cancelling sign-in during the inter-poll wait publishes and saves nothing" {
    const alloc = std.testing.allocator;
    var runtime: SignInRuntime = .{};
    defer runtime.deinit(alloc);
    var state = SignInTestState{ .mode = .pending_then_wait };

    try std.testing.expect(try runtime.startPrepared(
        alloc,
        try makeTestPreparedLogin(alloc),
        state.deps(),
    ));
    try std.testing.expect(waitForAtomic(&state.poll_started, 500));
    try std.testing.expect(runtime.cancel(alloc));

    try std.testing.expectEqual(SignInTransition.cancelled, runtime.pollTransition(alloc));
    try std.testing.expectEqual(@as(usize, 0), state.complete_count.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), state.save_count.load(.seq_cst));
    try std.testing.expect(runtime.thread == null);
    try std.testing.expect(runtime.flow == null);
}

test "VT-8(b) cancelling sign-in during an in-flight poll publishes and saves nothing" {
    const alloc = std.testing.allocator;
    var runtime: SignInRuntime = .{};
    defer runtime.deinit(alloc);
    var state = SignInTestState{ .mode = .in_flight };

    try std.testing.expect(try runtime.startPrepared(
        alloc,
        try makeTestPreparedLogin(alloc),
        state.deps(),
    ));
    try std.testing.expect(waitForAtomic(&state.poll_started, 500));
    try std.testing.expect(runtime.cancel(alloc));

    try std.testing.expectEqual(SignInTransition.cancelled, runtime.pollTransition(alloc));
    try std.testing.expectEqual(@as(usize, 0), state.complete_count.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), state.save_count.load(.seq_cst));
    try std.testing.expect(runtime.thread == null);
    try std.testing.expect(runtime.flow == null);
}

test "VT-8(c) cancelled sign-in is reaped before a second flow completes" {
    const alloc = std.testing.allocator;
    var runtime: SignInRuntime = .{};
    defer runtime.deinit(alloc);
    var state = SignInTestState{ .mode = .in_flight };

    try std.testing.expect(try runtime.startPrepared(
        alloc,
        try makeTestPreparedLogin(alloc),
        state.deps(),
    ));
    try std.testing.expect(waitForAtomic(&state.poll_started, 500));
    try std.testing.expect(runtime.cancel(alloc));
    try std.testing.expectEqual(SignInTransition.cancelled, runtime.pollTransition(alloc));
    try std.testing.expect(runtime.thread == null);

    state.mode = .success;
    state.poll_started.store(false, .seq_cst);
    try std.testing.expect(try runtime.startPrepared(
        alloc,
        try makeTestPreparedLogin(alloc),
        state.deps(),
    ));
    const transition = waitForSignInTransition(&runtime, alloc, 500);
    switch (transition) {
        .succeeded => |completed| {
            var selection = completed;
            defer selection.deinit(alloc);
        },
        else => try std.testing.expect(false),
    }
    try std.testing.expectEqual(@as(usize, 1), state.complete_count.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), state.save_count.load(.seq_cst));
    try std.testing.expect(runtime.thread == null);
}

test "VT-8(d) sign-in deinit cancels and joins a live worker" {
    const alloc = std.testing.allocator;
    var runtime: SignInRuntime = .{};
    var state = SignInTestState{ .mode = .in_flight };

    try std.testing.expect(try runtime.startPrepared(
        alloc,
        try makeTestPreparedLogin(alloc),
        state.deps(),
    ));
    try std.testing.expect(waitForAtomic(&state.poll_started, 500));
    runtime.deinit(alloc);

    try std.testing.expect(runtime.thread == null);
    try std.testing.expect(runtime.flow == null);
    try std.testing.expectEqual(SignInState.idle, runtime.state);
    try std.testing.expectEqual(@as(usize, 0), state.complete_count.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), state.save_count.load(.seq_cst));
}

test "login polling starts immediately" {
    const alloc = std.testing.allocator;
    var state = LoginPollTestState.init(alloc, &.{.success});
    defer state.deinit();

    var token = try pollForTokenWithDeps(alloc, oauth_transport.unavailable_provider, testPreparedLogin(), state.deps());
    defer token.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), state.poll_index);
    try std.testing.expectEqual(@as(usize, 0), state.sleep_calls.items.len);
}

test "login polling slow_down increases the next interval" {
    const alloc = std.testing.allocator;
    var state = LoginPollTestState.init(alloc, &.{ .slow_down, .success });
    defer state.deinit();

    var token = try pollForTokenWithDeps(alloc, oauth_transport.unavailable_provider, testPreparedLogin(), state.deps());
    defer token.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), state.poll_index);
    try std.testing.expectEqual(@as(usize, 60), state.sleep_calls.items.len);
    for (state.sleep_calls.items) |sleep_ms| {
        try std.testing.expectEqual(@as(u64, 100), sleep_ms);
    }
}

test "login polling waits in bounded cancellation slices" {
    const alloc = std.testing.allocator;
    var state = LoginPollTestState.init(alloc, &.{ .pending, .success });
    defer state.deinit();

    var token = try pollForTokenWithDeps(alloc, oauth_transport.unavailable_provider, testPreparedLogin(), state.deps());
    defer token.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), state.poll_index);
    try std.testing.expectEqual(@as(usize, 10), state.sleep_calls.items.len);
    for (state.sleep_calls.items) |sleep_ms| {
        try std.testing.expectEqual(@as(u64, 100), sleep_ms);
    }
}

test "login polling rejects invalid provider timing values" {
    const alloc = std.testing.allocator;
    var state = LoginPollTestState.init(alloc, &.{});
    defer state.deinit();

    var prepared = testPreparedLogin();
    prepared.expires_in_seconds = -1;
    try std.testing.expectError(
        oauth.OAuthError.InvalidOAuthResponse,
        pollForTokenWithDeps(alloc, oauth_transport.unavailable_provider, prepared, state.deps()),
    );

    prepared = testPreparedLogin();
    prepared.poll_interval_seconds = @intCast(max_poll_interval_ms / std.time.ms_per_s + 1);
    try std.testing.expectError(
        oauth.OAuthError.InvalidOAuthResponse,
        pollForTokenWithDeps(alloc, oauth_transport.unavailable_provider, prepared, state.deps()),
    );
    try std.testing.expectEqual(@as(usize, 0), state.poll_index);
}
