const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const command_contract = @import("command_contract.zig");
const command_runner = @import("command_runner.zig");
const session_child_store = @import("../session/session_child_store.zig");

const Allocator = std.mem.Allocator;

/// The process lifetime used by the model-facing Unified Exec tools.  The
/// manager owns processes independently from a worker turn: a short command
/// is returned inline, while a command that outlives its yield window remains
/// addressable by its numeric id through write_stdin.
pub const Manager = struct {
    const max_processes: usize = 64;

    mutex: std.Io.Mutex = .init,
    operation_mutex: std.Io.Mutex = .init,
    processes: std.AutoHashMap(u64, *Process),
    next_id: u64 = 1,
    stopping: bool = false,
    alloc: Allocator,

    pub fn init(alloc: Allocator) Manager {
        return .{ .processes = std.AutoHashMap(u64, *Process).init(alloc), .alloc = alloc };
    }

    pub fn deinit(self: *Manager) void {
        const zio = io_mod.getIo();
        self.operation_mutex.lockUncancelable(zio);
        defer self.operation_mutex.unlock(zio);
        self.mutex.lockUncancelable(zio);
        self.stopping = true;
        var values: std.ArrayList(*Process) = .empty;
        defer values.deinit(self.alloc);
        var iterator = self.processes.iterator();
        while (iterator.next()) |entry| values.append(self.alloc, entry.value_ptr.*) catch {};
        self.processes.clearRetainingCapacity();
        self.mutex.unlock(zio);

        for (values.items) |process| {
            process.stopAndJoin();
            process.destroy();
        }
        self.processes.deinit();
    }

    pub fn supported() bool {
        return std.process.can_spawn and builtin.os.tag != .windows and builtin.os.tag != .wasi;
    }

    pub const ExecRequest = struct {
        command: []const u8,
        cwd: []const u8,
        shell: []const u8 = "sh",
        login: bool = false,
        yield_time_ms: u64 = 10_000,
        max_output_tokens: ?u64 = null,
        command_artifact_capability: ?*session_child_store.SessionChildCapability = null,
        command_artifact_dir: ?[]const u8 = null,
        command_artifact_threshold: usize = 0,
    };

    pub const WriteRequest = struct {
        process_id: u64,
        chars: []const u8 = "",
        yield_time_ms: u64 = 250,
        max_output_tokens: ?u64 = null,
    };

    pub const Result = struct {
        process_id: ?u64 = null,
        status: Status = .exited,
        exit_code: ?i32 = null,
        signal: ?u8 = null,
        wall_time_seconds: f64 = 0,
        stdout: []u8,
        stderr: []u8,
        stdout_bytes: usize,
        stderr_bytes: usize,
        stdout_truncated: bool,
        stderr_truncated: bool,
        output_file: ?[]u8 = null,
        stdout_file: ?[]u8 = null,
        stderr_file: ?[]u8 = null,
        command: ?[]u8 = null,
        cwd: ?[]u8 = null,

        pub fn deinit(self: *Result, alloc: Allocator) void {
            alloc.free(self.stdout);
            alloc.free(self.stderr);
            if (self.output_file) |path| alloc.free(path);
            if (self.stdout_file) |path| alloc.free(path);
            if (self.stderr_file) |path| alloc.free(path);
            if (self.command) |command| alloc.free(command);
            if (self.cwd) |cwd| alloc.free(cwd);
            self.* = undefined;
        }
    };

    pub const Status = enum { running, exited };

    pub fn exec(self: *Manager, alloc: Allocator, request: ExecRequest) !Result {
        if (!supported()) return error.UnsupportedHost;
        self.operation_mutex.lockUncancelable(io_mod.getIo());
        defer self.operation_mutex.unlock(io_mod.getIo());
        const process = try self.createProcess(request);
        const id = process.id;
        const yield_ms = clampInitialYield(request.yield_time_ms);
        if (!process.waitUntilDone(yield_ms)) {
            return process.snapshot(alloc, id, .running, request.max_output_tokens);
        }
        const removed = self.take(id) orelse return error.ProcessUnavailable;
        // The wait thread may observe exit before the pipe readers have drained
        // their final bytes. Join them before taking the terminal snapshot.
        removed.stopAndJoin();
        removed.finalizeArtifact();
        defer removed.destroy();
        return removed.snapshot(alloc, null, .exited, request.max_output_tokens);
    }

    pub fn writeStdin(self: *Manager, alloc: Allocator, request: WriteRequest) !Result {
        self.operation_mutex.lockUncancelable(io_mod.getIo());
        defer self.operation_mutex.unlock(io_mod.getIo());
        const process = self.lookup(request.process_id) orelse return error.UnknownProcessId;
        try process.write(request.chars);
        const yield_ms = if (request.chars.len == 0)
            clampPollYield(request.yield_time_ms)
        else
            clampInitialYield(request.yield_time_ms);
        if (!process.waitUntilDone(yield_ms)) {
            return process.snapshot(alloc, request.process_id, .running, request.max_output_tokens);
        }
        const removed = self.take(request.process_id) orelse return error.ProcessUnavailable;
        removed.stopAndJoin();
        removed.finalizeArtifact();
        defer removed.destroy();
        return removed.snapshot(alloc, null, .exited, request.max_output_tokens);
    }

    /// Explicitly terminate one background process and its process group.
    /// This is an internal lifecycle hook; the model-facing surface remains
    /// the two Codex-compatible exec_command/write_stdin tools.
    pub fn terminate(self: *Manager, process_id: u64) bool {
        self.operation_mutex.lockUncancelable(io_mod.getIo());
        defer self.operation_mutex.unlock(io_mod.getIo());
        const process = self.take(process_id) orelse return false;
        process.stopAndJoin();
        process.destroy();
        return true;
    }

    fn createProcess(self: *Manager, request: ExecRequest) !*Process {
        const zio = io_mod.getIo();
        const id = blk: {
            self.mutex.lockUncancelable(zio);
            defer self.mutex.unlock(zio);
            if (self.stopping) return error.RuntimeStopping;
            if (self.processes.count() >= max_processes) return error.ProcessLimitReached;
            const value = self.next_id;
            self.next_id +%= 1;
            if (self.next_id == 0) self.next_id = 1;
            break :blk value;
        };

        const argv = [_][]const u8{ request.shell, if (request.login) "-lc" else "-c", request.command, "fx-exec" };
        var child = try std.process.spawn(zio, .{
            .argv = &argv,
            .cwd = .{ .path = request.cwd },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = 0,
        });
        var child_owned = true;
        errdefer if (child_owned) {
            child.kill(zio);
            _ = child.wait(zio) catch {};
        };
        const stdin = child.stdin orelse return error.SpawnFailed;
        const stdout = child.stdout orelse return error.SpawnFailed;
        const stderr = child.stderr orelse return error.SpawnFailed;
        try setNonblocking(stdin.handle);
        child.stdin = null;
        child.stdout = null;
        child.stderr = null;
        const process = try self.alloc.create(Process);
        process.* = Process.init(
            self.alloc,
            id,
            child.id orelse return error.SpawnFailed,
            child,
            stdin,
            stdout,
            stderr,
            request,
        ) catch |err| {
            self.alloc.destroy(process);
            return err;
        };
        child_owned = false;
        errdefer {
            process.stopAndJoin();
            process.destroy();
        }
        try process.start();

        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        if (self.stopping) return error.RuntimeStopping;
        try self.processes.put(id, process);
        return process;
    }

    fn lookup(self: *Manager, id: u64) ?*Process {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.processes.get(id);
    }

    fn take(self: *Manager, id: u64) ?*Process {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const entry = self.processes.fetchRemove(id) orelse return null;
        return entry.value;
    }
};

const initial_min_yield_ms: u64 = 250;
const empty_min_yield_ms: u64 = 5_000;
const max_yield_ms: u64 = 30_000;
const max_poll_yield_ms: u64 = 300_000;
const output_limit: usize = 1024 * 1024;

fn clampInitialYield(value: u64) u64 {
    return @max(initial_min_yield_ms, @min(max_yield_ms, value));
}

fn clampPollYield(value: u64) u64 {
    return @max(empty_min_yield_ms, @min(max_poll_yield_ms, value));
}

const Process = struct {
    alloc: Allocator,
    id: u64,
    pid: std.posix.pid_t,
    child: std.process.Child,
    stdin: ?std.Io.File,
    stdout: std.Io.File,
    stderr: std.Io.File,
    mutex: std.Io.Mutex = .init,
    stdout_buffer: HeadTailBuffer = .{},
    stderr_buffer: HeadTailBuffer = .{},
    artifact_threshold: usize,
    artifact_eager: bool,
    artifact_capability: ?*session_child_store.SessionChildCapability,
    artifact_dir: ?[]const u8,
    artifact_total: usize = 0,
    artifact_stdout_pending: std.ArrayList(u8) = .empty,
    artifact_stderr_pending: std.ArrayList(u8) = .empty,
    artifact: ?command_runner.CommandArtifact = null,
    artifact_failed: bool = false,
    command: []u8,
    cwd: []u8,
    started_at_ms: i64,
    done: bool = false,
    term: ?std.process.Child.Term = null,
    readers_done: u8 = 0,
    stop_requested: std.atomic.Value(bool) = .init(false),
    wait_thread: ?std.Thread = null,
    stdout_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,

    fn init(
        alloc: Allocator,
        id: u64,
        pid: std.posix.pid_t,
        child: std.process.Child,
        stdin: std.Io.File,
        stdout: std.Io.File,
        stderr: std.Io.File,
        request: Manager.ExecRequest,
    ) !Process {
        const command = try alloc.dupe(u8, request.command);
        errdefer alloc.free(command);
        const cwd = try alloc.dupe(u8, request.cwd);
        return .{
            .alloc = alloc,
            .id = id,
            .pid = pid,
            .child = child,
            .stdin = stdin,
            .stdout = stdout,
            .stderr = stderr,
            .artifact_threshold = if (request.command_artifact_threshold == 0)
                0
            else
                @min(request.command_artifact_threshold, output_limit),
            // Session-owned commands need a durable handle even when they
            // yield before crossing the retention cap.  This lets an
            // interrupted turn keep its output available in Ctrl-O while the
            // process continues running in the background.
            .artifact_eager = request.command_artifact_capability != null,
            .artifact_capability = request.command_artifact_capability,
            .artifact_dir = request.command_artifact_dir,
            .command = command,
            .cwd = cwd,
            .started_at_ms = io_mod.milliTimestamp(),
        };
    }

    fn start(self: *Process) !void {
        self.stdout_thread = try std.Thread.spawn(.{}, readerMain, .{ self, false });
        self.stderr_thread = std.Thread.spawn(.{}, readerMain, .{ self, true }) catch |err| {
            self.stopAndJoin();
            return err;
        };
        self.wait_thread = std.Thread.spawn(.{}, waitMain, .{self}) catch |err| {
            self.stopAndJoin();
            return err;
        };
    }

    fn waitUntilDone(self: *Process, yield_ms: u64) bool {
        const deadline = io_mod.milliTimestamp() + @as(i64, @intCast(yield_ms));
        while (true) {
            self.mutex.lockUncancelable(io_mod.getIo());
            const finished = self.done;
            self.mutex.unlock(io_mod.getIo());
            if (finished) return true;
            if (io_mod.milliTimestamp() >= deadline) return false;
            io_mod.sleep(5 * std.time.ns_per_ms);
        }
    }

    fn write(self: *Process, chars: []const u8) !void {
        if (chars.len == 0) return;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.done) return error.ProcessExited;
        const stdin = self.stdin orelse return error.ProcessStdinClosed;
        var offset: usize = 0;
        while (offset < chars.len) {
            const rc = std.posix.system.write(stdin.handle, chars[offset..].ptr, chars.len - offset);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    const written = @as(usize, @intCast(rc));
                    if (written == 0) return error.WriteFailed;
                    offset += written;
                },
                .AGAIN => return error.WriteWouldBlock,
                .PIPE => return error.ProcessStdinClosed,
                else => return error.WriteFailed,
            }
        }
    }

    fn snapshot(self: *Process, alloc: Allocator, process_id: ?u64, status: Manager.Status, max_output_tokens: ?u64) !Manager.Result {
        var stdout_buffer: HeadTailBuffer = .{};
        var stderr_buffer: HeadTailBuffer = .{};
        var term: ?std.process.Child.Term = null;
        var artifact_paths: ?command_runner.CommandArtifact.Paths = null;
        self.mutex.lockUncancelable(io_mod.getIo());
        stdout_buffer = self.stdout_buffer;
        stderr_buffer = self.stderr_buffer;
        self.stdout_buffer = .{};
        self.stderr_buffer = .{};
        term = self.term;
        if (self.artifact) |*artifact| artifact_paths = artifact.paths();
        self.mutex.unlock(io_mod.getIo());
        defer stdout_buffer.deinit(self.alloc);
        defer stderr_buffer.deinit(self.alloc);
        const out = try stdout_buffer.snapshot(alloc, maxOutputBytes(max_output_tokens));
        errdefer alloc.free(out.bytes);
        const err = try stderr_buffer.snapshot(alloc, maxOutputBytes(max_output_tokens));
        errdefer alloc.free(err.bytes);
        var result = Manager.Result{
            .process_id = process_id,
            .status = status,
            .wall_time_seconds = @as(f64, @floatFromInt(@max(
                @as(i64, 0),
                io_mod.milliTimestamp() - self.started_at_ms,
            ))) / 1000.0,
            .stdout = out.bytes,
            .stderr = err.bytes,
            .stdout_bytes = out.total,
            .stderr_bytes = err.total,
            .stdout_truncated = out.truncated,
            .stderr_truncated = err.truncated,
        };
        if (artifact_paths) |paths| {
            result.output_file = try alloc.dupe(u8, paths.output_file);
            errdefer if (result.output_file) |path| alloc.free(path);
            result.stdout_file = try alloc.dupe(u8, paths.stdout_file);
            errdefer if (result.stdout_file) |path| alloc.free(path);
            result.stderr_file = try alloc.dupe(u8, paths.stderr_file);
        }
        result.command = try alloc.dupe(u8, self.command);
        errdefer if (result.command) |command| alloc.free(command);
        result.cwd = try alloc.dupe(u8, self.cwd);
        if (term) |term_value| switch (term_value) {
            .exited => |code| result.exit_code = code,
            .signal => |signal| result.signal = @intCast(@intFromEnum(signal)),
            .stopped, .unknown => {},
        };
        return result;
    }

    fn stopAndJoin(self: *Process) void {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
        if (!self.stop_requested.swap(true, .seq_cst)) {
            self.mutex.lockUncancelable(io_mod.getIo());
            var done = self.done;
            var readers_done = self.readers_done == 2;
            self.mutex.unlock(io_mod.getIo());
            const process_group: std.posix.pid_t = -self.pid;
            if (!done or !readers_done) {
                std.posix.kill(process_group, std.posix.SIG.TERM) catch {};
                var waited_ms: u64 = 0;
                while (waited_ms < 20) : (waited_ms += 2) {
                    io_mod.sleep(2 * std.time.ns_per_ms);
                    self.mutex.lockUncancelable(io_mod.getIo());
                    done = self.done;
                    readers_done = self.readers_done == 2;
                    self.mutex.unlock(io_mod.getIo());
                    if (done and readers_done) break;
                }
                if (!done or !readers_done) std.posix.kill(process_group, std.posix.SIG.KILL) catch {};
            }
            self.mutex.lockUncancelable(io_mod.getIo());
            const stdin = self.stdin;
            self.stdin = null;
            self.mutex.unlock(io_mod.getIo());
            if (stdin) |file| file.close(io_mod.getIo());
        }
        if (self.wait_thread) |thread| {
            thread.join();
            self.wait_thread = null;
        } else {
            // A failed thread start can leave a child without a waiter. Reap
            // it here so a partially-created process never becomes a zombie.
            self.mutex.lockUncancelable(io_mod.getIo());
            const done = self.done;
            self.mutex.unlock(io_mod.getIo());
            if (!done) {
                const term = self.child.wait(io_mod.getIo()) catch @as(std.process.Child.Term, .{ .unknown = 0 });
                self.mutex.lockUncancelable(io_mod.getIo());
                self.term = term;
                self.done = true;
                self.mutex.unlock(io_mod.getIo());
            }
        }
        if (self.stdout_thread) |thread| {
            thread.join();
            self.stdout_thread = null;
        }
        if (self.stderr_thread) |thread| {
            thread.join();
            self.stderr_thread = null;
        }
    }

    fn destroy(self: *Process) void {
        if (self.artifact) |*artifact| {
            artifact.deinit(self.alloc);
        }
        self.artifact_stdout_pending.deinit(self.alloc);
        self.artifact_stderr_pending.deinit(self.alloc);
        self.alloc.free(self.command);
        self.alloc.free(self.cwd);
        self.stdout_buffer.deinit(self.alloc);
        self.stderr_buffer.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    fn waitMain(self: *Process) void {
        const term = self.child.wait(io_mod.getIo()) catch @as(std.process.Child.Term, .{ .unknown = 0 });
        self.mutex.lockUncancelable(io_mod.getIo());
        self.term = term;
        self.done = true;
        self.mutex.unlock(io_mod.getIo());
    }

    fn readerMain(self: *Process, stderr: bool) void {
        var buffer: [8192]u8 = undefined;
        var file = if (stderr) self.stderr else self.stdout;
        defer file.close(io_mod.getIo());
        while (true) {
            const count = file.readStreaming(io_mod.getIo(), &.{buffer[0..]}) catch break;
            if (count == 0) break;
            self.mutex.lockUncancelable(io_mod.getIo());
            if (stderr)
                self.stderr_buffer.append(self.alloc, buffer[0..count]) catch {}
            else
                self.stdout_buffer.append(self.alloc, buffer[0..count]) catch {};
            self.appendArtifactLocked(stderr, buffer[0..count]);
            self.mutex.unlock(io_mod.getIo());
        }
        self.mutex.lockUncancelable(io_mod.getIo());
        self.readers_done += 1;
        self.mutex.unlock(io_mod.getIo());
    }

    fn appendArtifactLocked(self: *Process, stderr: bool, bytes: []const u8) void {
        if (self.artifact_threshold == 0 and !self.artifact_eager and self.artifact == null) return;
        self.artifact_total +|= bytes.len;
        if (self.artifact_failed) return;
        if (self.artifact) |*artifact| {
            artifact.append(if (stderr) .stderr else .stdout, bytes) catch |err| {
                self.artifact_failed = true;
                debug_trace.logf("core", "unified exec artifact append failed err={s}", .{@errorName(err)});
            };
            return;
        }

        const pending = if (stderr) &self.artifact_stderr_pending else &self.artifact_stdout_pending;
        pending.appendSlice(self.alloc, bytes) catch {
            self.artifact_failed = true;
            return;
        };
        if (self.artifact_total <= self.artifact_threshold and !self.artifact_eager) return;

        var artifact = command_runner.createCommandArtifact(
            self.alloc,
            self.artifact_capability,
            self.artifact_dir,
        ) catch |err| {
            self.artifact_failed = true;
            debug_trace.logf(
                "core",
                "unified exec command output artifact creation failed err={s} threshold={d}",
                .{ @errorName(err), self.artifact_threshold },
            );
            return;
        };
        errdefer artifact.deinit(self.alloc);
        artifact.append(.stdout, self.artifact_stdout_pending.items) catch |err| {
            self.artifact_failed = true;
            debug_trace.logf("core", "unified exec stdout artifact promotion failed err={s}", .{@errorName(err)});
            return;
        };
        artifact.append(.stderr, self.artifact_stderr_pending.items) catch |err| {
            self.artifact_failed = true;
            debug_trace.logf("core", "unified exec stderr artifact promotion failed err={s}", .{@errorName(err)});
            return;
        };
        self.artifact_stdout_pending.clearRetainingCapacity();
        self.artifact_stderr_pending.clearRetainingCapacity();
        self.artifact = artifact;
        debug_trace.logf("command_output", "command output artifact created", .{});
        debug_trace.logf(
            "command_output",
            "command output retention cap reached retained={d} cap={d}; subsequent records count only",
            .{ self.artifact_total, self.artifact_threshold },
        );
    }

    fn finalizeArtifact(self: *Process) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.artifact) |*artifact| {
            artifact.sync() catch |err| {
                self.artifact_failed = true;
                debug_trace.logf("core", "unified exec command artifact sync failed err={s}", .{@errorName(err)});
            };
        }
    }
};

const HeadTailBuffer = struct {
    const Snapshot = struct { bytes: []u8, total: usize, truncated: bool };
    head: std.ArrayList(u8) = .empty,
    tail: std.ArrayList(u8) = .empty,
    total: usize = 0,

    fn append(self: *HeadTailBuffer, alloc: Allocator, bytes: []const u8) !void {
        self.total +|= bytes.len;
        const head_limit = output_limit / 2;
        const tail_limit = output_limit - head_limit;
        const take = @min(head_limit -| self.head.items.len, bytes.len);
        if (take > 0) try self.head.appendSlice(alloc, bytes[0..take]);
        if (tail_limit == 0) return;
        const remainder = bytes[take..];
        const tail_input = if (remainder.len > tail_limit) remainder[remainder.len - tail_limit ..] else remainder;
        if (self.tail.items.len + tail_input.len > tail_limit) {
            const drop = self.tail.items.len + tail_input.len - tail_limit;
            const keep = self.tail.items.len -| drop;
            std.mem.copyForwards(u8, self.tail.items[0..keep], self.tail.items[drop..]);
            self.tail.items.len = keep;
        }
        try self.tail.appendSlice(alloc, tail_input);
    }

    fn snapshot(self: *const HeadTailBuffer, alloc: Allocator, requested_limit: usize) !Snapshot {
        const limit = @max(@as(usize, 1), @min(output_limit, requested_limit));
        const omitted = self.total > limit;
        const marker = if (omitted) "\n[... output truncated ...]\n" else "";
        const head_limit = limit / 2;
        const tail_limit = limit - head_limit;
        const head = utf8SafeHead(self.head.items, head_limit);
        const tail = utf8SafeTail(self.tail.items, tail_limit);
        const bytes = try alloc.alloc(u8, head.len + marker.len + tail.len);
        @memcpy(bytes[0..head.len], head);
        @memcpy(bytes[head.len .. head.len + marker.len], marker);
        @memcpy(bytes[head.len + marker.len ..], tail);
        return .{ .bytes = bytes, .total = self.total, .truncated = omitted };
    }

    fn deinit(self: *HeadTailBuffer, alloc: Allocator) void {
        self.head.deinit(alloc);
        self.tail.deinit(alloc);
        self.* = undefined;
    }
};

fn maxOutputBytes(max_output_tokens: ?u64) usize {
    const tokens = max_output_tokens orelse 10_000;
    const bytes = std.math.mul(usize, std.math.cast(usize, tokens) orelse output_limit, 4) catch output_limit;
    return @min(output_limit, bytes);
}

fn setNonblocking(fd: std.posix.fd_t) !void {
    const current = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
    const current_flags = switch (std.posix.errno(current)) {
        .SUCCESS => @as(usize, @intCast(current)),
        else => return error.SpawnFailed,
    };
    const next = current_flags | (@as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK"));
    switch (std.posix.errno(std.posix.system.fcntl(fd, std.posix.F.SETFL, next))) {
        .SUCCESS => return,
        else => return error.SpawnFailed,
    }
}

fn utf8SafeHead(bytes: []const u8, limit: usize) []const u8 {
    var end = @min(bytes.len, limit);
    while (end > 0 and !std.unicode.utf8ValidateSlice(bytes[0..end])) : (end -= 1) {}
    return bytes[0..end];
}

fn utf8SafeTail(bytes: []const u8, limit: usize) []const u8 {
    var start = bytes.len -| @min(bytes.len, limit);
    while (start < bytes.len and !std.unicode.utf8ValidateSlice(bytes[start..])) : (start += 1) {}
    return bytes[start..];
}

test "unified exec keeps long process addressable and polls output" {
    if (!Manager.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var first = try manager.exec(std.testing.allocator, .{
        .command = "printf ready; sleep 1; printf done",
        .cwd = "/tmp",
        .yield_time_ms = 250,
    });
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.process_id != null);
    try std.testing.expectEqual(Manager.Status.running, first.status);
    try std.testing.expectEqualStrings("ready", first.stdout);
    var second = try manager.writeStdin(std.testing.allocator, .{
        .process_id = first.process_id.?,
        .yield_time_ms = 2_000,
    });
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(Manager.Status.exited, second.status);
    try std.testing.expectEqualStrings("done", second.stdout);
}

test "unified exec returns short commands synchronously" {
    if (!Manager.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var result = try manager.exec(std.testing.allocator, .{
        .command = "printf synchronous",
        .cwd = "/tmp",
        .yield_time_ms = 250,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Manager.Status.exited, result.status);
    try std.testing.expect(result.process_id == null);
    try std.testing.expectEqualStrings("synchronous", result.stdout);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code.?);
}

test "unified exec retains oversized output in command artifacts" {
    if (!Manager.supported()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "artifacts");
    const artifact_dir = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "artifacts");
    defer std.testing.allocator.free(artifact_dir);

    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var result = try manager.exec(std.testing.allocator, .{
        .command = "printf '0123456789'",
        .cwd = "/tmp",
        .yield_time_ms = 250,
        .command_artifact_dir = artifact_dir,
        .command_artifact_threshold = 4,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.stdout_file != null);
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), result.stdout_file.?, .{});
    defer file.close(io_mod.getIo());
    const stored = try io_mod.readFileToEnd(std.testing.allocator, &file, 1024);
    defer std.testing.allocator.free(stored);
    try std.testing.expectEqualStrings("0123456789", stored);
}

test "unified exec writes interactive input without blocking the caller" {
    if (!Manager.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var first = try manager.exec(std.testing.allocator, .{
        .command = "IFS= read -r line; printf 'got:%s' \"$line\"",
        .cwd = "/tmp",
        .yield_time_ms = 250,
    });
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(Manager.Status.running, first.status);
    var second = try manager.writeStdin(std.testing.allocator, .{
        .process_id = first.process_id.?,
        .chars = "hello\n",
        .yield_time_ms = 2_000,
    });
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(Manager.Status.exited, second.status);
    try std.testing.expectEqualStrings("got:hello", second.stdout);
}

test "unified exec clamps empty polls and retains head tail bounds" {
    try std.testing.expectEqual(@as(u64, 250), clampInitialYield(0));
    try std.testing.expectEqual(@as(u64, 30_000), clampInitialYield(100_000));
    try std.testing.expectEqual(@as(u64, 5_000), clampPollYield(0));
    try std.testing.expectEqual(@as(u64, 300_000), clampPollYield(500_000));
    var buffer: HeadTailBuffer = .{};
    defer buffer.deinit(std.testing.allocator);
    const bytes = [_]u8{'x'} ** (output_limit + 100);
    try buffer.append(std.testing.allocator, &bytes);
    const snap = try buffer.snapshot(std.testing.allocator, output_limit);
    defer std.testing.allocator.free(snap.bytes);
    try std.testing.expect(snap.truncated);
    try std.testing.expect(snap.bytes.len <= output_limit + 64);

    var utf8_buffer: HeadTailBuffer = .{};
    defer utf8_buffer.deinit(std.testing.allocator);
    try utf8_buffer.append(std.testing.allocator, "😀");
    const utf8_snap = try utf8_buffer.snapshot(std.testing.allocator, 2);
    defer std.testing.allocator.free(utf8_snap.bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(utf8_snap.bytes));
}

test "unified exec manager cleanup terminates a still-running process group" {
    if (!Manager.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    var running = try manager.exec(std.testing.allocator, .{
        .command = "sleep 30 & child=$!; printf '%d' \"$child\"; wait",
        .cwd = "/tmp",
        .yield_time_ms = 250,
    });
    const child_pid = try std.fmt.parseInt(std.posix.pid_t, running.stdout, 10);
    running.deinit(std.testing.allocator);
    const started = io_mod.milliTimestamp();
    manager.deinit();
    const elapsed = io_mod.milliTimestamp() - started;
    try std.testing.expect(elapsed < 2_000);
    const deadline = io_mod.milliTimestamp() + 2_000;
    while (io_mod.milliTimestamp() < deadline) {
        std.posix.kill(child_pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => break,
            else => return err,
        };
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expectError(
        error.ProcessNotFound,
        std.posix.kill(child_pid, @enumFromInt(0)),
    );
}

test "unified exec explicitly terminates a live session" {
    if (!Manager.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var running = try manager.exec(std.testing.allocator, .{
        .command = "sleep 30",
        .cwd = "/tmp",
        .yield_time_ms = 250,
    });
    const process_id = running.process_id.?;
    running.deinit(std.testing.allocator);
    try std.testing.expect(manager.terminate(process_id));
    try std.testing.expect(!manager.terminate(process_id));
    try std.testing.expectError(error.UnknownProcessId, manager.writeStdin(
        std.testing.allocator,
        .{ .process_id = process_id },
    ));
}

test "unified exec drains large output without unbounded retained memory" {
    if (!Manager.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var result = try manager.exec(std.testing.allocator, .{
        .command = "yes x | head -c 2000000",
        .cwd = "/tmp",
        .yield_time_ms = 5_000,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Manager.Status.exited, result.status);
    try std.testing.expectEqual(@as(usize, 2_000_000), result.stdout_bytes);
    try std.testing.expect(result.stdout.len <= output_limit + 64);
    try std.testing.expect(result.stdout_truncated);
}
