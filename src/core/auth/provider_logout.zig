const std = @import("std");
const builtin = @import("builtin");
const chatgpt_oauth = @import("chatgpt_oauth.zig");
const chatgpt_session = @import("chatgpt_session.zig");
const grok_oauth = @import("grok_oauth.zig");
const model_provider = @import("../config/model_provider.zig");
const oauth_transport = @import("oauth_transport.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Outcome = union(enum) {
    codex: chatgpt_session.DeleteOutcome,
    grok: grok_oauth.LogoutResult,
    failed: anyerror,
};

pub const Completion = struct {
    target: model_provider.ProviderId,
    outcome: Outcome,
};

const Operation = struct {
    context: ?*anyopaque = null,
    run_fn: *const fn (
        context: ?*anyopaque,
        alloc: Allocator,
        target: model_provider.ProviderId,
        transport: oauth_transport.Provider,
    ) Outcome = runLogout,

    fn run(
        self: Operation,
        alloc: Allocator,
        target: model_provider.ProviderId,
        transport: oauth_transport.Provider,
    ) Outcome {
        return self.run_fn(self.context, alloc, target, transport);
    }
};

fn runLogout(
    _: ?*anyopaque,
    alloc: Allocator,
    target: model_provider.ProviderId,
    transport: oauth_transport.Provider,
) Outcome {
    return switch (target) {
        .codex => .{ .codex = chatgpt_oauth.logout() catch |err| return .{ .failed = err } },
        .grok => .{ .grok = grok_oauth.logout(alloc, transport) catch |err| return .{ .failed = err } },
        .gateway => unreachable,
    };
}

/// Runs durable subscription logout away from the TUI event loop. A provider
/// refresh can hold the session mutation lock while it performs network I/O;
/// waiting for that lock here would otherwise freeze input and rendering.
pub const Runtime = struct {
    const Self = @This();

    alloc: Allocator,
    operation: Operation = .{},
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    running: bool = false,
    completion: ?Completion = null,
    cancel_requested: std.atomic.Value(bool) = .init(false),

    pub fn init(alloc: Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        self.cancel_requested.store(true, .seq_cst);
        const thread = self.detachThread();
        if (thread) |handle| handle.join();
        self.mutex.lockUncancelable(io_mod.getIo());
        self.running = false;
        self.completion = null;
        self.mutex.unlock(io_mod.getIo());
    }

    pub fn start(
        self: *Self,
        target: model_provider.ProviderId,
        transport: oauth_transport.Provider,
        retry_lock_busy: bool,
    ) !bool {
        std.debug.assert(target != .gateway);
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.running or self.completion != null or self.thread != null) {
            self.mutex.unlock(io_mod.getIo());
            return false;
        }
        self.cancel_requested.store(false, .seq_cst);
        self.running = true;
        if (comptime builtin.single_threaded) {
            self.mutex.unlock(io_mod.getIo());
            self.threadMain(target, transport, retry_lock_busy);
            return true;
        }
        const thread = std.Thread.spawn(.{}, threadMain, .{
            self,
            target,
            transport,
            retry_lock_busy,
        }) catch |err| {
            self.running = false;
            self.mutex.unlock(io_mod.getIo());
            return err;
        };
        self.thread = thread;
        self.mutex.unlock(io_mod.getIo());
        return true;
    }

    pub fn isRunning(self: *Self) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.running;
    }

    pub fn takeCompletion(self: *Self) ?Completion {
        self.mutex.lockUncancelable(io_mod.getIo());
        const completion = self.completion orelse {
            const thread = if (!self.running) self.thread else null;
            if (thread != null) {
                self.thread = null;
            }
            self.mutex.unlock(io_mod.getIo());
            if (thread) |handle| handle.join();
            return null;
        };
        self.completion = null;
        const thread = self.thread;
        self.thread = null;
        self.mutex.unlock(io_mod.getIo());
        if (thread) |handle| handle.join();
        return completion;
    }

    fn threadMain(
        self: *Self,
        target: model_provider.ProviderId,
        transport: oauth_transport.Provider,
        retry_lock_busy: bool,
    ) void {
        const completion = Completion{
            .target = target,
            .outcome = while (true) {
                const outcome = self.operation.run(self.alloc, target, transport);
                switch (outcome) {
                    .failed => |err| if (retry_lock_busy and err == error.LockBusy and
                        !self.cancel_requested.load(.seq_cst))
                    {
                        io_mod.sleep(10 * std.time.ns_per_ms);
                        continue;
                    },
                    else => {},
                }
                break outcome;
            },
        };
        self.mutex.lockUncancelable(io_mod.getIo());
        self.completion = completion;
        self.running = false;
        self.mutex.unlock(io_mod.getIo());
    }

    fn detachThread(self: *Self) ?std.Thread {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const thread = self.thread;
        self.thread = null;
        return thread;
    }
};

test "provider logout completion never joins a stalled operation while polling" {
    const FakeOperation = struct {
        entered: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        calls: std.atomic.Value(u32) = .init(0),

        fn run(
            raw: ?*anyopaque,
            _: Allocator,
            _: model_provider.ProviderId,
            _: oauth_transport.Provider,
        ) Outcome {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const call = self.calls.fetchAdd(1, .seq_cst);
            if (call == 0) {
                self.entered.store(true, .release);
                while (!self.release.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
                return .{ .failed = error.LockBusy };
            }
            return .{ .codex = .missing };
        }
    };

    var fake = FakeOperation{};
    var runtime = Runtime.init(std.testing.allocator);
    runtime.operation = .{ .context = &fake, .run_fn = FakeOperation.run };
    defer runtime.deinit();

    try std.testing.expect(try runtime.start(
        .codex,
        oauth_transport.unavailable_provider,
        true,
    ));
    while (!fake.entered.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);

    const started_ns = io_mod.nanoTimestamp();
    try std.testing.expect(runtime.takeCompletion() == null);
    const elapsed_ns = io_mod.nanoTimestamp() - started_ns;
    try std.testing.expect(elapsed_ns < std.time.ns_per_ms * 100);

    fake.release.store(true, .release);
    while (runtime.isRunning()) io_mod.sleep(std.time.ns_per_ms);
    const completion = runtime.takeCompletion() orelse return error.MissingLogoutCompletion;
    try std.testing.expectEqual(@as(u32, 2), fake.calls.load(.seq_cst));
    try std.testing.expectEqual(model_provider.ProviderId.codex, completion.target);
    try std.testing.expectEqual(chatgpt_session.DeleteOutcome.missing, completion.outcome.codex);
}
