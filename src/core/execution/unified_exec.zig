const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const command_contract = @import("command_contract.zig");
const command_runner = @import("command_runner.zig");
const session_child_store = @import("../session/session_child_store.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

/// The process lifetime used by the model-facing Unified Exec tools.  The
/// manager owns processes independently from a worker turn: a short command
/// is returned inline, while a command that outlives its yield window remains
/// addressable by its numeric id through write_stdin.
pub const Manager = struct {
    const max_processes: usize = 64;
    const ProcessIdentity = struct { id: u64, generation: u64 };

    mutex: std.Io.Mutex = .init,
    lifecycle_mutex: std.Io.Mutex = .init,
    processes: std.AutoHashMap(u64, *Process),
    next_id: u64 = 1,
    generation: u64 = 1,
    pending_processes: usize = 0,
    active_operations: usize = 0,
    resetting: bool = false,
    stopping: bool = false,
    alloc: Allocator,

    pub fn init(alloc: Allocator) Manager {
        return .{ .processes = std.AutoHashMap(u64, *Process).init(alloc), .alloc = alloc };
    }

    pub fn deinit(self: *Manager) void {
        self.stopAll(true);
        self.processes.deinit();
    }

    /// Stops every process still owned by the manager without making the
    /// manager unusable. ACP session changes call this so a process ID from a
    /// previous session cannot be reused against the newly active session.
    pub fn terminateAll(self: *Manager) void {
        self.stopAll(false);
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
        output_sink: ?OutputSink = null,
        cancel_flag: ?*const std.atomic.Value(bool) = null,
    };

    pub const WriteRequest = struct {
        process_id: u64,
        chars: []const u8 = "",
        yield_time_ms: u64 = 250,
        max_output_tokens: ?u64 = null,
        output_sink: ?OutputSink = null,
        cancel_flag: ?*const std.atomic.Value(bool) = null,
    };

    /// Borrowed for one exec or write_stdin operation. Pipe readers only queue
    /// owned chunks; the calling operation drains them outside process locks,
    /// so no callback can outlive the tool call or block process control.
    pub const OutputSink = struct {
        context: *anyopaque,
        lifecycle_id: ?types.ToolLifecycleId = null,
        callback: command_contract.CommandOutputCallback,
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
        if (request.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        const process = try self.createProcess(request);
        defer self.releaseActive(process);
        defer process.finishOutputProjection(request.output_sink);
        const id = process.id;
        const yield_ms = clampInitialYield(request.yield_time_ms);
        if (!process.waitUntilDone(yield_ms, request.output_sink, request.cancel_flag)) {
            if (request.cancel_flag) |flag| {
                if (flag.load(.seq_cst)) {
                    if (!self.detachHeld(id, process)) return error.ProcessUnavailable;
                    process.cancelAndJoin();
                    process.finalizeArtifact();
                    return error.Cancelled;
                }
            }
            return process.snapshot(alloc, id, .running, request.max_output_tokens, .model);
        }
        if (!self.detachHeld(id, process)) return error.ProcessUnavailable;
        // The wait thread may observe exit before the pipe readers have drained
        // their final bytes. Join them before taking the terminal snapshot.
        process.stopAndJoin();
        process.finalizeArtifact();
        return process.snapshot(alloc, null, .exited, request.max_output_tokens, .model);
    }

    pub fn writeStdin(self: *Manager, alloc: Allocator, request: WriteRequest) !Result {
        if (request.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        const process = self.acquire(request.process_id) orelse return error.UnknownProcessId;
        defer self.releaseActive(process);
        try process.beginOutputProjection(request.output_sink, true);
        defer process.finishOutputProjection(request.output_sink);
        try process.write(request.chars);
        const yield_ms = if (request.chars.len == 0)
            clampPollYield(request.yield_time_ms)
        else
            clampInitialYield(request.yield_time_ms);
        if (!process.waitUntilDone(yield_ms, request.output_sink, request.cancel_flag)) {
            return process.snapshot(alloc, request.process_id, .running, request.max_output_tokens, .model);
        }
        if (!self.detachHeld(request.process_id, process)) return error.ProcessUnavailable;
        process.stopAndJoin();
        process.finalizeArtifact();
        return process.snapshot(alloc, null, .exited, request.max_output_tokens, .model);
    }

    /// Writes input and returns the output currently available without a
    /// bounded wait. ACP uses this path so process control cannot stall its
    /// request dispatch loop.
    pub fn writeStdinNonblocking(self: *Manager, alloc: Allocator, request: WriteRequest) !Result {
        const process = self.acquire(request.process_id) orelse return error.UnknownProcessId;
        defer self.releaseActive(process);
        // Establish ACP's independent cursor before input can make the child
        // emit its final bytes and let the model-facing poll drain them.
        try process.activateObserver();
        try process.write(request.chars);
        const status: Status = if (process.isSettled()) .exited else .running;
        // ACP is an observer of the model-owned process. It must neither drain
        // the model's output cursor nor claim terminal cleanup when the child
        // exits; the model-facing write_stdin path remains the sole consumer.
        return process.snapshot(
            alloc,
            if (status == .running) request.process_id else null,
            status,
            request.max_output_tokens,
            .observer,
        );
    }

    /// Explicitly terminate one background process and its process group.
    /// This is an internal lifecycle hook; the model-facing surface remains
    /// the two Codex-compatible exec_command/write_stdin tools.
    pub fn terminate(self: *Manager, process_id: u64) bool {
        const process = self.takeForOperation(process_id) orelse return false;
        defer self.releaseActive(process);
        process.stopAndJoin();
        return true;
    }

    fn createProcess(self: *Manager, request: ExecRequest) !*Process {
        const zio = io_mod.getIo();
        const identity: ProcessIdentity = blk: {
            self.mutex.lockUncancelable(zio);
            defer self.mutex.unlock(zio);
            if (self.stopping or self.resetting) return error.RuntimeStopping;
            if (self.processes.count() + self.pending_processes >= max_processes)
                return error.ProcessLimitReached;
            self.pending_processes += 1;
            const value = self.next_id;
            self.next_id +%= 1;
            if (self.next_id == 0) self.next_id = 1;
            break :blk .{ .id = value, .generation = self.generation };
        };
        var pending_reserved = true;
        defer if (pending_reserved) self.releasePending();
        const id = identity.id;

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
        if (self.stopping or self.generation != identity.generation) {
            self.mutex.unlock(zio);
            return error.RuntimeStopping;
        }
        self.processes.put(id, process) catch |err| {
            self.mutex.unlock(zio);
            return err;
        };
        std.debug.assert(self.pending_processes > 0);
        self.pending_processes -= 1;
        pending_reserved = false;
        // The map and this exec call each own one reference. Later callers
        // retain under the same mutex before borrowing the process pointer.
        process.references = 2;
        self.active_operations += 1;
        self.mutex.unlock(zio);
        return process;
    }

    fn acquire(self: *Manager, id: u64) ?*Process {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const process = self.processes.get(id) orelse return null;
        process.references += 1;
        self.active_operations += 1;
        return process;
    }

    fn releasePending(self: *Manager) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        std.debug.assert(self.pending_processes > 0);
        self.pending_processes -= 1;
    }

    /// Detaches the map-owned reference while the caller keeps its retained
    /// operation reference. Only the winner may join and finalize the process.
    fn detachHeld(self: *Manager, id: u64, process: *Process) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const current = self.processes.get(id) orelse return false;
        if (current != process) return false;
        const entry = self.processes.fetchRemove(id) orelse return false;
        std.debug.assert(entry.value == process);
        std.debug.assert(process.references >= 2);
        process.references -= 1;
        return true;
    }

    /// Removes a process and converts the map's owning reference into an active
    /// operation reference. No new operation can retain it after this returns.
    fn takeForOperation(self: *Manager, id: u64) ?*Process {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const entry = self.processes.fetchRemove(id) orelse return null;
        self.active_operations += 1;
        return entry.value;
    }

    fn releaseActive(self: *Manager, process: *Process) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        std.debug.assert(self.active_operations > 0);
        std.debug.assert(process.references > 0);
        self.active_operations -= 1;
        process.references -= 1;
        const destroy = process.references == 0;
        self.mutex.unlock(zio);
        if (destroy) process.destroy();
    }

    fn releaseOwned(self: *Manager, process: *Process) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        std.debug.assert(process.references > 0);
        process.references -= 1;
        const destroy = process.references == 0;
        self.mutex.unlock(zio);
        if (destroy) process.destroy();
    }

    fn stopAll(self: *Manager, mark_stopping: bool) void {
        const zio = io_mod.getIo();
        self.lifecycle_mutex.lockUncancelable(zio);
        defer self.lifecycle_mutex.unlock(zio);
        self.mutex.lockUncancelable(zio);
        if (mark_stopping) self.stopping = true;
        self.resetting = true;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        var values: [max_processes]*Process = undefined;
        var count: usize = 0;
        var iterator = self.processes.iterator();
        while (iterator.next()) |entry| {
            if (count == values.len) break;
            values[count] = entry.value_ptr.*;
            count += 1;
        }
        self.processes.clearRetainingCapacity();
        self.mutex.unlock(zio);

        for (values[0..count]) |process| {
            process.stopAndJoin();
            self.releaseOwned(process);
        }

        // A session reset must outlive creators and callers that crossed the
        // fence. Killing the map-owned processes wakes bounded polls, so this
        // wait is normally only a few scheduler ticks.
        while (true) {
            self.mutex.lockUncancelable(zio);
            const drained = self.pending_processes == 0 and self.active_operations == 0;
            self.mutex.unlock(zio);
            if (drained) break;
            io_mod.sleep(std.time.ns_per_ms);
        }
        if (!mark_stopping) {
            self.mutex.lockUncancelable(zio);
            self.resetting = false;
            self.mutex.unlock(zio);
        }
    }
};

const initial_min_yield_ms: u64 = 250;
const empty_min_yield_ms: u64 = 5_000;
const max_yield_ms: u64 = 30_000;
const max_poll_yield_ms: u64 = 300_000;
const output_limit: usize = 1024 * 1024;
const output_projection_limit: usize = 1024 * 1024;
const output_projection_omitted = "\n[... live output omitted while the consumer was unavailable ...]\n";

fn clampInitialYield(value: u64) u64 {
    return @max(initial_min_yield_ms, @min(max_yield_ms, value));
}

fn clampPollYield(value: u64) u64 {
    return @max(empty_min_yield_ms, @min(max_poll_yield_ms, value));
}

const OutputProjectionChunk = struct {
    stream: command_contract.CommandOutputStream,
    bytes: []u8,
};

const OutputProjectionBatch = struct {
    chunks: std.ArrayList(OutputProjectionChunk) = .empty,
    stdout_omitted: bool = false,
    stderr_omitted: bool = false,

    fn deinit(self: *OutputProjectionBatch, alloc: Allocator) void {
        for (self.chunks.items) |chunk| alloc.free(chunk.bytes);
        self.chunks.deinit(alloc);
        self.* = undefined;
    }
};

const Process = struct {
    const SnapshotConsumer = enum { model, observer };

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
    output_projection_active: bool = false,
    output_projection_chunks: std.ArrayList(OutputProjectionChunk) = .empty,
    output_projection_bytes: usize = 0,
    output_projection_stdout_omitted: bool = false,
    output_projection_stderr_omitted: bool = false,
    observer_stdout_buffer: HeadTailBuffer = .{},
    observer_stderr_buffer: HeadTailBuffer = .{},
    observer_active: bool = false,
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
    /// Protected by Manager.mutex. The process is destroyed only after its map
    /// ownership and every in-flight operation have both been released.
    references: usize = 0,
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
        errdefer alloc.free(cwd);
        return .{
            .alloc = alloc,
            .id = id,
            .pid = pid,
            .child = child,
            .stdin = stdin,
            .stdout = stdout,
            .stderr = stderr,
            .output_projection_active = request.output_sink != null,
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

    fn waitUntilDone(
        self: *Process,
        yield_ms: u64,
        output_sink: ?Manager.OutputSink,
        cancel_flag: ?*const std.atomic.Value(bool),
    ) bool {
        const deadline = io_mod.milliTimestamp() + @as(i64, @intCast(yield_ms));
        while (true) {
            self.drainOutputProjection(output_sink);
            self.mutex.lockUncancelable(io_mod.getIo());
            const finished = self.done;
            self.mutex.unlock(io_mod.getIo());
            if (finished) return true;
            if (cancel_flag) |flag| if (flag.load(.seq_cst)) return false;
            if (io_mod.milliTimestamp() >= deadline) return false;
            io_mod.sleep(5 * std.time.ns_per_ms);
        }
    }

    fn isSettled(self: *Process) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.done and self.readers_done == 2;
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

    fn beginOutputProjection(
        self: *Process,
        requested: ?Manager.OutputSink,
        replay_buffered: bool,
    ) !void {
        if (requested == null) return;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.output_projection_active) return error.OutputSinkBusy;
        self.output_projection_active = true;
        if (!replay_buffered) return;
        self.queueReplayBufferLocked(.stdout, self.stdout_buffer);
        self.queueReplayBufferLocked(.stderr, self.stderr_buffer);
    }

    fn finishOutputProjection(self: *Process, sink: ?Manager.OutputSink) void {
        if (sink == null) return;
        self.mutex.lockUncancelable(io_mod.getIo());
        self.output_projection_active = false;
        var batch = self.takeOutputProjectionLocked();
        self.mutex.unlock(io_mod.getIo());
        self.emitOutputProjection(sink.?, &batch);
    }

    fn drainOutputProjection(self: *Process, requested: ?Manager.OutputSink) void {
        const sink = requested orelse return;
        self.mutex.lockUncancelable(io_mod.getIo());
        var batch = self.takeOutputProjectionLocked();
        self.mutex.unlock(io_mod.getIo());
        self.emitOutputProjection(sink, &batch);
    }

    fn queueReplayBufferLocked(
        self: *Process,
        stream: command_contract.CommandOutputStream,
        buffer: HeadTailBuffer,
    ) void {
        if (buffer.head.items.len > 0) self.queueOutputLocked(stream, buffer.head.items);
        if (buffer.total > buffer.head.items.len +| buffer.tail.items.len) {
            self.queueOutputLocked(stream, "\n[... output omitted before observation ...]\n");
        }
        if (buffer.tail.items.len > 0) self.queueOutputLocked(stream, buffer.tail.items);
    }

    fn queueOutputLocked(
        self: *Process,
        stream: command_contract.CommandOutputStream,
        bytes: []const u8,
    ) void {
        if (!self.output_projection_active or bytes.len == 0) return;
        if (bytes.len > output_projection_limit -| self.output_projection_bytes) {
            self.markOutputProjectionOmittedLocked(stream);
            return;
        }
        const owned = self.alloc.dupe(u8, bytes) catch {
            self.markOutputProjectionOmittedLocked(stream);
            return;
        };
        self.output_projection_chunks.append(self.alloc, .{
            .stream = stream,
            .bytes = owned,
        }) catch {
            self.alloc.free(owned);
            self.markOutputProjectionOmittedLocked(stream);
            return;
        };
        self.output_projection_bytes += owned.len;
    }

    fn markOutputProjectionOmittedLocked(
        self: *Process,
        stream: command_contract.CommandOutputStream,
    ) void {
        switch (stream) {
            .stdout => self.output_projection_stdout_omitted = true,
            .stderr => self.output_projection_stderr_omitted = true,
        }
    }

    fn takeOutputProjectionLocked(self: *Process) OutputProjectionBatch {
        const batch = OutputProjectionBatch{
            .chunks = self.output_projection_chunks,
            .stdout_omitted = self.output_projection_stdout_omitted,
            .stderr_omitted = self.output_projection_stderr_omitted,
        };
        self.output_projection_chunks = .empty;
        self.output_projection_bytes = 0;
        self.output_projection_stdout_omitted = false;
        self.output_projection_stderr_omitted = false;
        return batch;
    }

    fn emitOutputProjection(
        self: *Process,
        sink: Manager.OutputSink,
        batch: *OutputProjectionBatch,
    ) void {
        defer batch.deinit(self.alloc);
        for (batch.chunks.items) |chunk| {
            self.emitOutputChunk(sink, chunk.stream, chunk.bytes);
        }
        if (batch.stdout_omitted) {
            self.emitOutputChunk(sink, .stdout, output_projection_omitted);
        }
        if (batch.stderr_omitted) {
            self.emitOutputChunk(sink, .stderr, output_projection_omitted);
        }
    }

    fn emitOutputChunk(
        _: *Process,
        sink: Manager.OutputSink,
        stream: command_contract.CommandOutputStream,
        bytes: []const u8,
    ) void {
        sink.callback(sink.context, sink.lifecycle_id, stream, bytes) catch |err| {
            debug_trace.logf(
                "command_output",
                "unified exec output projection failed stream={s} err={s}",
                .{ @tagName(stream), @errorName(err) },
            );
        };
    }

    fn activateObserver(self: *Process) !void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        try self.activateObserverLocked();
    }

    fn activateObserverLocked(self: *Process) !void {
        if (self.observer_active) return;
        var observer_stdout = try self.stdout_buffer.clone(self.alloc);
        errdefer observer_stdout.deinit(self.alloc);
        const observer_stderr = try self.stderr_buffer.clone(self.alloc);
        self.observer_stdout_buffer = observer_stdout;
        self.observer_stderr_buffer = observer_stderr;
        self.observer_active = true;
    }

    fn snapshot(
        self: *Process,
        alloc: Allocator,
        process_id: ?u64,
        status: Manager.Status,
        max_output_tokens: ?u64,
        consumer: SnapshotConsumer,
    ) !Manager.Result {
        var stdout_buffer: HeadTailBuffer = .{};
        var stderr_buffer: HeadTailBuffer = .{};
        var term: ?std.process.Child.Term = null;
        var artifact_paths: ?command_runner.CommandArtifact.Paths = null;
        self.mutex.lockUncancelable(io_mod.getIo());
        switch (consumer) {
            .model => {
                stdout_buffer = self.stdout_buffer;
                stderr_buffer = self.stderr_buffer;
                self.stdout_buffer = .{};
                self.stderr_buffer = .{};
            },
            .observer => {
                self.activateObserverLocked() catch |err| {
                    self.mutex.unlock(io_mod.getIo());
                    return err;
                };
                stdout_buffer = self.observer_stdout_buffer;
                stderr_buffer = self.observer_stderr_buffer;
                self.observer_stdout_buffer = .{};
                self.observer_stderr_buffer = .{};
            },
        }
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
        self.stopAndJoinWithGrace(20);
    }

    /// A command cancelled before its initial yield is still the active
    /// foreground action. Give its process group the same bounded cooperative
    /// shutdown window as the legacy command runner before forcing cleanup.
    fn cancelAndJoin(self: *Process) void {
        self.stopAndJoinWithGrace(800);
    }

    fn stopAndJoinWithGrace(self: *Process, grace_ms: u64) void {
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
                while (waited_ms < grace_ms) : (waited_ms += 2) {
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
        var projection = self.takeOutputProjectionLocked();
        projection.deinit(self.alloc);
        self.stdout_buffer.deinit(self.alloc);
        self.stderr_buffer.deinit(self.alloc);
        self.observer_stdout_buffer.deinit(self.alloc);
        self.observer_stderr_buffer.deinit(self.alloc);
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
            if (stderr) {
                self.stderr_buffer.append(self.alloc, buffer[0..count]) catch {};
                if (self.observer_active)
                    self.observer_stderr_buffer.append(self.alloc, buffer[0..count]) catch {};
            } else {
                self.stdout_buffer.append(self.alloc, buffer[0..count]) catch {};
                if (self.observer_active)
                    self.observer_stdout_buffer.append(self.alloc, buffer[0..count]) catch {};
            }
            self.appendArtifactLocked(stderr, buffer[0..count]);
            self.queueOutputLocked(if (stderr) .stderr else .stdout, buffer[0..count]);
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

    fn clone(self: *const HeadTailBuffer, alloc: Allocator) !HeadTailBuffer {
        var result: HeadTailBuffer = .{};
        errdefer result.deinit(alloc);
        try result.head.appendSlice(alloc, self.head.items);
        try result.tail.appendSlice(alloc, self.tail.items);
        result.total = self.total;
        return result;
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

const TestOutputCapture = struct {
    mutex: std.Io.Mutex = .init,
    bytes: [4096]u8 = undefined,
    len: usize = 0,
    saw_expected_lifecycle: bool = false,

    fn callback(
        raw: *anyopaque,
        lifecycle_id: ?types.ToolLifecycleId,
        _: command_contract.CommandOutputStream,
        chunk: []const u8,
    ) !void {
        const self: *TestOutputCapture = @ptrCast(@alignCast(raw));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        if (lifecycle_id) |id| {
            self.saw_expected_lifecycle = id.turn_id == 7 and
                std.mem.eql(u8, id.call_id, "command-7");
        }
        if (chunk.len > self.bytes.len - self.len) return error.NoSpaceLeft;
        @memcpy(self.bytes[self.len .. self.len + chunk.len], chunk);
        self.len += chunk.len;
    }

    fn reset(self: *TestOutputCapture) void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.len = 0;
        self.saw_expected_lifecycle = false;
    }

    fn expect(self: *TestOutputCapture, expected: []const u8) !void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        try std.testing.expectEqualStrings(expected, self.bytes[0..self.len]);
    }

    fn expectPrefix(self: *TestOutputCapture, expected: []const u8) !void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        try std.testing.expect(self.len >= expected.len);
        try std.testing.expectEqualStrings(expected, self.bytes[0..expected.len]);
    }

    fn expectLifecycle(self: *TestOutputCapture) !void {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        try std.testing.expect(self.saw_expected_lifecycle);
    }
};

const BlockingOutputCapture = struct {
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn callback(
        raw: *anyopaque,
        _: ?types.ToolLifecycleId,
        _: command_contract.CommandOutputStream,
        _: []const u8,
    ) !void {
        const self: *BlockingOutputCapture = @ptrCast(@alignCast(raw));
        self.started.store(true, .release);
        while (!self.release.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
    }
};

const BlockingExecContext = struct {
    manager: *Manager,
    capture: *BlockingOutputCapture,
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *BlockingExecContext) void {
        var result = self.manager.exec(std.heap.c_allocator, .{
            .command = "printf blocked; sleep 5",
            .cwd = "/tmp",
            .yield_time_ms = 5_000,
            .output_sink = .{
                .context = @ptrCast(self.capture),
                .callback = BlockingOutputCapture.callback,
            },
        }) catch {
            self.finished.store(true, .release);
            return;
        };
        result.deinit(std.heap.c_allocator);
        self.finished.store(true, .release);
    }
};

const TerminateContext = struct {
    manager: *Manager,
    process_id: u64,
    result: bool = false,
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *TerminateContext) void {
        self.result = self.manager.terminate(self.process_id);
        self.finished.store(true, .release);
    }
};

const DelayedCancel = struct {
    flag: *std.atomic.Value(bool),
    delay_ms: u64 = 50,

    fn run(self: *DelayedCancel) void {
        io_mod.sleep(self.delay_ms * std.time.ns_per_ms);
        self.flag.store(true, .seq_cst);
    }
};

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

test "unified exec projects live and between-poll output through one sink" {
    if (!Manager.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var capture = TestOutputCapture{};
    const sink: Manager.OutputSink = .{
        .context = @ptrCast(&capture),
        .lifecycle_id = .{ .turn_id = 7, .call_id = "command-7" },
        .callback = TestOutputCapture.callback,
    };

    var first = try manager.exec(std.testing.allocator, .{
        .command = "printf ready; sleep 1; i=1; while [ \"$i\" -le 60 ]; do printf 'chunk_%02d\\n' \"$i\"; sleep 0.01; i=$((i+1)); done; sleep 1",
        .cwd = "/tmp",
        .yield_time_ms = 250,
        .output_sink = sink,
    });
    const process_id = first.process_id.?;
    defer first.deinit(std.testing.allocator);
    try capture.expect("ready");
    try capture.expectLifecycle();

    capture.reset();
    io_mod.sleep(1050 * std.time.ns_per_ms);
    try capture.expect("");

    var second = try manager.writeStdin(std.testing.allocator, .{
        .process_id = process_id,
        .chars = "x",
        .yield_time_ms = 250,
        .output_sink = sink,
    });
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, second.stdout, "chunk_") != null);
    try capture.expectPrefix(second.stdout);
    try capture.expectLifecycle();
    try std.testing.expect(manager.terminate(process_id));
}

test "blocked output sink does not hold process control or reader threads" {
    if (!Manager.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.heap.c_allocator);
    defer manager.deinit();
    var capture = BlockingOutputCapture{};
    var exec_context = BlockingExecContext{
        .manager = &manager,
        .capture = &capture,
    };
    const exec_thread = try std.Thread.spawn(.{}, BlockingExecContext.run, .{&exec_context});

    const started_deadline = io_mod.milliTimestamp() + 2_000;
    while (!capture.started.load(.acquire) and io_mod.milliTimestamp() < started_deadline) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    if (!capture.started.load(.acquire)) {
        capture.release.store(true, .release);
        exec_thread.join();
        return error.TestExpectedEqual;
    }

    var terminate_context = TerminateContext{ .manager = &manager, .process_id = 1 };
    const terminate_thread = std.Thread.spawn(.{}, TerminateContext.run, .{&terminate_context}) catch |err| {
        capture.release.store(true, .release);
        exec_thread.join();
        return err;
    };
    const control_deadline = io_mod.milliTimestamp() + 2_000;
    while (!terminate_context.finished.load(.acquire) and io_mod.milliTimestamp() < control_deadline) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    const control_finished_before_sink_release = terminate_context.finished.load(.acquire);
    capture.release.store(true, .release);
    terminate_thread.join();
    exec_thread.join();

    try std.testing.expect(control_finished_before_sink_release);
    try std.testing.expect(terminate_context.result);
    try std.testing.expect(exec_context.finished.load(.acquire));
}

test "unified exec cancellation terminates an initial foreground wait" {
    if (!Manager.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.heap.c_allocator);
    defer manager.deinit();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var delayed = DelayedCancel{ .flag = &cancel_flag };
    const cancel_thread = try std.Thread.spawn(.{}, DelayedCancel.run, .{&delayed});

    const started_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.Cancelled,
        manager.exec(std.testing.allocator, .{
            .command = "sleep 30",
            .cwd = "/tmp",
            .yield_time_ms = max_yield_ms,
            .cancel_flag = &cancel_flag,
        }),
    );
    cancel_thread.join();

    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 2_000);
    try std.testing.expectError(error.UnknownProcessId, manager.writeStdin(
        std.testing.allocator,
        .{ .process_id = 1 },
    ));
}

test "unified exec cancellation releases an empty poll without consuming the process" {
    if (!Manager.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.heap.c_allocator);
    defer manager.deinit();
    var running = try manager.exec(std.testing.allocator, .{
        .command = "sleep 30",
        .cwd = "/tmp",
        .yield_time_ms = 250,
    });
    const process_id = running.process_id.?;
    running.deinit(std.testing.allocator);

    var cancel_flag = std.atomic.Value(bool).init(false);
    var delayed = DelayedCancel{ .flag = &cancel_flag };
    const cancel_thread = try std.Thread.spawn(.{}, DelayedCancel.run, .{&delayed});
    const started_ms = io_mod.milliTimestamp();
    var result = try manager.writeStdin(std.testing.allocator, .{
        .process_id = process_id,
        .yield_time_ms = max_poll_yield_ms,
        .cancel_flag = &cancel_flag,
    });
    cancel_thread.join();
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(Manager.Status.running, result.status);
    try std.testing.expectEqual(process_id, result.process_id.?);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 2_000);
    try std.testing.expect(manager.terminate(process_id));
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

test "unified exec nonblocking writes return a live process immediately" {
    if (!Manager.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var first = try manager.exec(std.testing.allocator, .{
        .command = "IFS= read -r line; printf 'got:%s' \"$line\"; sleep 30",
        .cwd = "/tmp",
        .yield_time_ms = 250,
    });
    const process_id = first.process_id.?;
    first.deinit(std.testing.allocator);

    var second = try manager.writeStdinNonblocking(std.testing.allocator, .{
        .process_id = process_id,
        .chars = "hello\n",
        .yield_time_ms = max_poll_yield_ms,
    });
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(Manager.Status.running, second.status);
    try std.testing.expectEqual(process_id, second.process_id.?);
    try std.testing.expect(manager.terminate(process_id));
}

test "unified exec activates the observer before a direct write can fail" {
    if (!Manager.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var first = try manager.exec(std.testing.allocator, .{
        .command = "sleep 30",
        .cwd = "/tmp",
        .yield_time_ms = 250,
    });
    const process_id = first.process_id.?;
    first.deinit(std.testing.allocator);

    const input = try std.testing.allocator.alloc(u8, 4 * 1024 * 1024);
    defer std.testing.allocator.free(input);
    @memset(input, 'x');
    try std.testing.expectError(error.WriteWouldBlock, manager.writeStdinNonblocking(
        std.testing.allocator,
        .{ .process_id = process_id, .chars = input },
    ));

    const process = manager.acquire(process_id) orelse return error.ProcessUnavailable;
    defer manager.releaseActive(process);
    process.mutex.lockUncancelable(io_mod.getIo());
    const observer_active = process.observer_active;
    process.mutex.unlock(io_mod.getIo());
    try std.testing.expect(observer_active);
}

test "unified exec direct control stays responsive during a model poll" {
    if (!Manager.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var first = try manager.exec(std.testing.allocator, .{
        .command = "IFS= read -r first; printf 'model:%s' \"$first\"; IFS= read -r second",
        .cwd = "/tmp",
        .yield_time_ms = 250,
    });
    const process_id = first.process_id.?;
    first.deinit(std.testing.allocator);

    const Poll = struct {
        manager: *Manager,
        process_id: u64,
        entered: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,
        status: ?Manager.Status = null,
        stdout: [64]u8 = undefined,
        stdout_len: usize = 0,

        fn run(self: *@This()) void {
            self.entered.store(true, .release);
            var result = self.manager.writeStdin(std.testing.allocator, .{
                .process_id = self.process_id,
                .yield_time_ms = max_poll_yield_ms,
            }) catch |err| {
                self.failure = err;
                return;
            };
            self.status = result.status;
            self.stdout_len = @min(self.stdout.len, result.stdout.len);
            @memcpy(self.stdout[0..self.stdout_len], result.stdout[0..self.stdout_len]);
            result.deinit(std.testing.allocator);
        }
    };
    var poll = Poll{ .manager = &manager, .process_id = process_id };
    const thread = try std.Thread.spawn(.{}, Poll.run, .{&poll});
    while (!poll.entered.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
    // Give the poller enough time to enter its bounded wait. This reproduces
    // the old global-operation-lock stall without making the assertion depend
    // on private manager state.
    io_mod.sleep(50 * std.time.ns_per_ms);

    const started = io_mod.milliTimestamp();
    var direct = try manager.writeStdinNonblocking(std.testing.allocator, .{
        .process_id = process_id,
        .chars = "hello\n",
        .yield_time_ms = max_poll_yield_ms,
    });
    const elapsed = io_mod.milliTimestamp() - started;
    try std.testing.expectEqual(Manager.Status.running, direct.status);
    try std.testing.expect(elapsed < 1_000);
    var observed = std.mem.find(u8, direct.stdout, "model:hello") != null;
    direct.deinit(std.testing.allocator);

    const observation_deadline = io_mod.milliTimestamp() + 2_000;
    while (!observed and io_mod.milliTimestamp() < observation_deadline) {
        io_mod.sleep(5 * std.time.ns_per_ms);
        var observation = try manager.writeStdinNonblocking(std.testing.allocator, .{
            .process_id = process_id,
        });
        observed = std.mem.find(u8, observation.stdout, "model:hello") != null;
        observation.deinit(std.testing.allocator);
    }
    try std.testing.expect(observed);

    var finish = try manager.writeStdinNonblocking(std.testing.allocator, .{
        .process_id = process_id,
        .chars = "done\n",
    });
    finish.deinit(std.testing.allocator);
    thread.join();
    try std.testing.expect(poll.failure == null);
    try std.testing.expectEqual(Manager.Status.exited, poll.status.?);
    try std.testing.expect(std.mem.find(u8, poll.stdout[0..poll.stdout_len], "model:hello") != null);
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

test "unified exec terminateAll clears live sessions and preserves the manager" {
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

    manager.terminateAll();
    try std.testing.expectError(error.UnknownProcessId, manager.writeStdin(
        std.testing.allocator,
        .{ .process_id = process_id },
    ));

    var result = try manager.exec(std.testing.allocator, .{
        .command = "printf reusable",
        .cwd = "/tmp",
        .yield_time_ms = 250,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Manager.Status.exited, result.status);
    try std.testing.expectEqualStrings("reusable", result.stdout);
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
