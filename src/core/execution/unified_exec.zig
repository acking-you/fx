const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const pseudo_terminal = @import("pseudo_terminal.zig");
const command_contract = @import("command_contract.zig");
const command_runner = @import("command_runner.zig");
const exec_mode = @import("exec_mode.zig");
const session_child_store = @import("../session/session_child_store.zig");
const shell_resolver = @import("../terminal/shell_resolver.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

const WindowsJob = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const job_object_extended_limit_information: c_int = 9;
    const job_object_limit_kill_on_job_close: windows.DWORD = 0x00002000;
    const resume_thread_failed: windows.DWORD = std.math.maxInt(windows.DWORD);

    const BasicLimitInformation = extern struct {
        per_process_user_time_limit: windows.LARGE_INTEGER = 0,
        per_job_user_time_limit: windows.LARGE_INTEGER = 0,
        limit_flags: windows.DWORD = 0,
        minimum_working_set_size: windows.SIZE_T = 0,
        maximum_working_set_size: windows.SIZE_T = 0,
        active_process_limit: windows.DWORD = 0,
        affinity: windows.ULONG_PTR = 0,
        priority_class: windows.DWORD = 0,
        scheduling_class: windows.DWORD = 0,
    };

    const IoCounters = extern struct {
        read_operation_count: u64 = 0,
        write_operation_count: u64 = 0,
        other_operation_count: u64 = 0,
        read_transfer_count: u64 = 0,
        write_transfer_count: u64 = 0,
        other_transfer_count: u64 = 0,
    };

    const ExtendedLimitInformation = extern struct {
        basic_limit_information: BasicLimitInformation = .{},
        io_info: IoCounters = .{},
        process_memory_limit: windows.SIZE_T = 0,
        job_memory_limit: windows.SIZE_T = 0,
        peak_process_memory_used: windows.SIZE_T = 0,
        peak_job_memory_used: windows.SIZE_T = 0,
    };

    handle: ?windows.HANDLE = null,

    fn create(process_handle: windows.HANDLE) !WindowsJob {
        const handle = CreateJobObjectW(null, null) orelse return error.JobObjectCreateFailed;
        errdefer windows.CloseHandle(handle);

        var limits = ExtendedLimitInformation{};
        limits.basic_limit_information.limit_flags = job_object_limit_kill_on_job_close;
        if (SetInformationJobObject(
            handle,
            job_object_extended_limit_information,
            &limits,
            @sizeOf(ExtendedLimitInformation),
        ) == .FALSE) return error.JobObjectConfigureFailed;
        if (AssignProcessToJobObject(handle, process_handle) == .FALSE)
            return error.JobObjectAssignFailed;
        return .{ .handle = handle };
    }

    fn resumeChild(_: WindowsJob, thread_handle: windows.HANDLE) !void {
        if (ResumeThread(thread_handle) == resume_thread_failed)
            return error.ProcessResumeFailed;
    }

    fn terminate(self: WindowsJob) void {
        if (self.handle) |handle| _ = TerminateJobObject(handle, 1);
    }

    fn deinit(self: *WindowsJob) void {
        if (self.handle) |handle| windows.CloseHandle(handle);
        self.handle = null;
    }

    extern "kernel32" fn CreateJobObjectW(
        attributes: ?*windows.SECURITY_ATTRIBUTES,
        name: ?windows.LPCWSTR,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn SetInformationJobObject(
        job: windows.HANDLE,
        info_class: c_int,
        info: *const anyopaque,
        info_len: windows.DWORD,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn AssignProcessToJobObject(
        job: windows.HANDLE,
        process: windows.HANDLE,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn TerminateJobObject(
        job: windows.HANDLE,
        exit_code: windows.UINT,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn ResumeThread(thread: windows.HANDLE) callconv(.winapi) windows.DWORD;
} else struct {};

const WindowsProcessProbe = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const synchronize: windows.DWORD = 0x00100000;
    const wait_object_0: windows.DWORD = 0;

    fn exited(pid: windows.DWORD) bool {
        const handle = OpenProcess(synchronize, .FALSE, pid) orelse return true;
        defer windows.CloseHandle(handle);
        return WaitForSingleObject(handle, 0) == wait_object_0;
    }

    extern "kernel32" fn OpenProcess(
        desired_access: windows.DWORD,
        inherit_handle: windows.BOOL,
        process_id: windows.DWORD,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn WaitForSingleObject(
        handle: windows.HANDLE,
        milliseconds: windows.DWORD,
    ) callconv(.winapi) windows.DWORD;
} else struct {};

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
    event_mutex: std.Io.Mutex = .init,
    lifecycle_events: std.ArrayList(LifecycleEvent) = .empty,
    next_chunk_id: std.atomic.Value(u64) = .init(1),
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
        self.event_mutex.lockUncancelable(io_mod.getIo());
        for (self.lifecycle_events.items) |*event| event.deinit(self.alloc);
        self.lifecycle_events.deinit(self.alloc);
        self.event_mutex.unlock(io_mod.getIo());
        self.processes.deinit();
    }

    /// Stops every process still owned by the manager without making the
    /// manager unusable. ACP session changes call this so a process ID from a
    /// previous session cannot be reused against the newly active session.
    pub fn terminateAll(self: *Manager) void {
        self.stopAll(false);
    }

    pub fn supported() bool {
        return std.process.can_spawn and builtin.os.tag != .wasi;
    }

    pub const ExecRequest = struct {
        command: []const u8,
        cwd: []const u8,
        shell: []const u8 = if (builtin.os.tag == .windows)
            "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
        else
            "/bin/sh",
        login: bool = false,
        tty: bool = false,
        yield_time_ms: u64 = 10_000,
        max_output_tokens: ?u64 = null,
        command_artifact_capability: ?*session_child_store.SessionChildCapability = null,
        command_artifact_dir: ?[]const u8 = null,
        command_artifact_threshold: usize = 0,
        output_sink: ?OutputSink = null,
        cancel_flag: ?*const std.atomic.Value(bool) = null,
        mode: exec_mode.Mode = .codex,
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
        chunk_id: ?[6]u8 = null,
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

    pub const ProcessSnapshot = struct {
        process_id: u64,
        pid: u64,
        status: Status,
        command: []u8,
        cwd: []u8,
        started_at_ms: i64,
        mode: exec_mode.Mode,

        pub fn deinit(self: *ProcessSnapshot, alloc: Allocator) void {
            alloc.free(self.command);
            alloc.free(self.cwd);
            self.* = undefined;
        }
    };

    pub const LifecycleEvent = struct {
        process_id: u64,
        status: Status = .exited,
        exit_code: ?i32 = null,
        signal: ?u8 = null,
        command: []u8,
        cwd: []u8,
        stdout: []u8,
        stderr: []u8,
        started_at_ms: i64,

        pub fn deinit(self: *LifecycleEvent, alloc: Allocator) void {
            alloc.free(self.command);
            alloc.free(self.cwd);
            alloc.free(self.stdout);
            alloc.free(self.stderr);
            self.* = undefined;
        }

        fn clone(self: LifecycleEvent, alloc: Allocator) !LifecycleEvent {
            const command = try alloc.dupe(u8, self.command);
            errdefer alloc.free(command);
            const cwd = try alloc.dupe(u8, self.cwd);
            errdefer alloc.free(cwd);
            const stdout = try alloc.dupe(u8, self.stdout);
            errdefer alloc.free(stdout);
            return .{
                .process_id = self.process_id,
                .status = self.status,
                .exit_code = self.exit_code,
                .signal = self.signal,
                .command = command,
                .cwd = cwd,
                .stdout = stdout,
                .stderr = try alloc.dupe(u8, self.stderr),
                .started_at_ms = self.started_at_ms,
            };
        }
    };

    pub fn exec(self: *Manager, alloc: Allocator, request: ExecRequest) !Result {
        if (!supported()) return error.UnsupportedHost;
        if (request.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        const process = try self.createProcess(request);
        defer self.releaseActive(process);
        defer process.finishOutputProjection(request.output_sink);
        const id = process.id;
        const yield_ms = clampInitialYield(request.yield_time_ms);
        var finished = process.waitUntilDone(yield_ms, request.output_sink, request.cancel_flag);
        if (!finished and cancelRequested(request.cancel_flag)) {
            // Let the UI observe the active cancellation before the worker
            // releases turn-scoped mutation guards. The process itself stays
            // session-owned and addressable, just like an ordinary yield.
            finished = process.waitUntilDone(initial_min_yield_ms, request.output_sink, null);
        }
        if (!finished) {
            process.markBackgrounded();
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
        var wrote_tty_input = process.tty and request.chars.len > 0;
        process.write(request.chars) catch |err| {
            wrote_tty_input = false;
            // Codex treats a TTY write racing with process exit as a final
            // poll: retain the terminal bytes and report the exit instead of
            // losing them behind a stdin error.
            if (!(process.tty and process.hasExited())) return err;
        };
        if (wrote_tty_input) {
            // Match Codex's reaction window before beginning the requested
            // interaction wait, improving the chance of returning prompt
            // output from interactive programs in this same tool result.
            io_mod.sleep(100 * std.time.ns_per_ms);
        }
        const yield_ms = if (request.chars.len == 0)
            clampPollYield(request.yield_time_ms)
        else
            clampInitialYield(request.yield_time_ms);
        const operation_started_ms = io_mod.milliTimestamp();
        if (!process.waitUntilDone(yield_ms, request.output_sink, request.cancel_flag)) {
            var result = try process.snapshot(alloc, request.process_id, .running, request.max_output_tokens, .model);
            result.wall_time_seconds = elapsedSeconds(operation_started_ms);
            return result;
        }
        if (!self.detachHeld(request.process_id, process)) return error.ProcessUnavailable;
        process.stopAndJoin();
        process.finalizeArtifact();
        var result = try process.snapshot(alloc, null, .exited, request.max_output_tokens, .model);
        result.wall_time_seconds = elapsedSeconds(operation_started_ms);
        return result;
    }

    /// Writes input and returns the output currently available without a
    /// bounded wait. ACP uses this path so process control cannot stall its
    /// request dispatch loop.
    pub fn writeStdinNonblocking(self: *Manager, alloc: Allocator, request: WriteRequest) !Result {
        const operation_started_ms = io_mod.milliTimestamp();
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
        var result = try process.snapshot(
            alloc,
            if (status == .running) request.process_id else null,
            status,
            request.max_output_tokens,
            .observer,
        );
        result.wall_time_seconds = elapsedSeconds(operation_started_ms);
        return result;
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

    /// Returns owned snapshots of every command that has crossed its initial
    /// yield boundary. This is the single source used by /ps and host APIs.
    pub fn snapshotProcesses(self: *Manager, alloc: Allocator) ![]ProcessSnapshot {
        var snapshots: std.ArrayList(ProcessSnapshot) = .empty;
        errdefer {
            for (snapshots.items) |*snapshot| snapshot.deinit(alloc);
            snapshots.deinit(alloc);
        }
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var iterator = self.processes.iterator();
        while (iterator.next()) |entry| {
            const process = entry.value_ptr.*;
            if (try process.statusSnapshot(alloc)) |snapshot| {
                try snapshots.append(alloc, snapshot);
            }
        }
        return snapshots.toOwnedSlice(alloc);
    }

    pub fn freeProcessSnapshots(alloc: Allocator, snapshots: []ProcessSnapshot) void {
        for (snapshots) |*snapshot| snapshot.deinit(alloc);
        alloc.free(snapshots);
    }

    /// Transfers terminal events to the host. Reader/waiter threads only append
    /// owned data here; they never call the UI or agent worker directly.
    pub fn takeLifecycleEvents(self: *Manager) std.ArrayList(LifecycleEvent) {
        self.queueDueWatchdogs();
        self.event_mutex.lockUncancelable(io_mod.getIo());
        const events = self.lifecycle_events;
        self.lifecycle_events = .empty;
        self.event_mutex.unlock(io_mod.getIo());
        // Claude-mode completion is consumed by the host event, not by a later
        // model poll. Reap the settled map entries after releasing event_mutex
        // so process destruction can never participate in an event-queue lock.
        for (events.items) |event| {
            if (event.status != .exited) continue;
            if (self.takeForOperation(event.process_id)) |process| {
                process.stopAndJoin();
                self.releaseActive(process);
            }
        }
        return events;
    }

    /// Retains a lifecycle trigger when the host cannot yet enqueue its model
    /// continuation, for example while credentials are temporarily absent.
    pub fn retryLifecycleEvent(self: *Manager, event: LifecycleEvent) !void {
        var owned = try event.clone(self.alloc);
        errdefer owned.deinit(self.alloc);
        self.event_mutex.lockUncancelable(io_mod.getIo());
        defer self.event_mutex.unlock(io_mod.getIo());
        try self.lifecycle_events.append(self.alloc, owned);
    }

    fn queueDueWatchdogs(self: *Manager) void {
        const now_ms = io_mod.milliTimestamp();
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var iterator = self.processes.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.*.takeWatchdogEvent(now_ms)) |event| {
                self.queueLifecycleEvent(event);
            }
        }
    }

    fn queueLifecycleEvent(self: *Manager, event: LifecycleEvent) void {
        self.event_mutex.lockUncancelable(io_mod.getIo());
        defer self.event_mutex.unlock(io_mod.getIo());
        self.lifecycle_events.append(self.alloc, event) catch {
            var owned = event;
            owned.deinit(self.alloc);
        };
    }

    fn generateChunkId(self: *Manager) [6]u8 {
        const alphabet = "0123456789abcdef";
        var value = self.next_chunk_id.fetchAdd(1, .seq_cst) ^ @as(u64, @bitCast(io_mod.milliTimestamp()));
        var id: [6]u8 = undefined;
        var index: usize = id.len;
        while (index > 0) {
            index -= 1;
            id[index] = alphabet[@as(usize, @intCast(value & 0xf))];
            value >>= 4;
        }
        return id;
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

        const invocation = try shell_resolver.commandInvocation(request.shell, request.login, request.command);
        const pty: ?pseudo_terminal.Pair = if (request.tty) try pseudo_terminal.open() else null;
        var pty_master_owned = pty != null;
        errdefer if (pty_master_owned) pseudo_terminal.close(pty.?.master);
        defer if (pty) |pair| pseudo_terminal.close(pair.slave);
        const slave_file = if (pty) |pair| pseudo_terminal.file(pair.slave, false) else undefined;
        var child = try std.process.spawn(zio, .{
            .argv = invocation.argv(),
            .cwd = .{ .path = request.cwd },
            .stdin = if (request.tty) .{ .file = slave_file } else .pipe,
            .stdout = if (request.tty) .{ .file = slave_file } else .pipe,
            .stderr = if (request.tty) .{ .file = slave_file } else .pipe,
            .pgid = if (comptime builtin.os.tag == .windows) null else 0,
            .start_suspended = builtin.os.tag == .windows,
        });
        var child_owned = true;
        errdefer if (child_owned) {
            child.kill(zio);
            _ = child.wait(zio) catch {};
        };
        var windows_job: WindowsJob = if (comptime builtin.os.tag == .windows)
            try WindowsJob.create(child.id orelse return error.SpawnFailed)
        else
            .{};
        var windows_job_owned = true;
        errdefer if (windows_job_owned and comptime builtin.os.tag == .windows)
            windows_job.deinit();
        const stdin = if (pty) |pair|
            pseudo_terminal.file(try pseudo_terminal.duplicate(pair.master), true)
        else
            child.stdin orelse return error.SpawnFailed;
        const stdout = if (pty) |pair|
            pseudo_terminal.file(pair.master, true)
        else
            child.stdout orelse return error.SpawnFailed;
        const stderr = if (request.tty) null else child.stderr orelse return error.SpawnFailed;
        var process_io_owned = true;
        errdefer if (process_io_owned) {
            stdin.close(zio);
            stdout.close(zio);
            if (stderr) |file| file.close(zio);
        };
        try setNonblocking(stdin.handle);
        child.stdin = null;
        child.stdout = null;
        child.stderr = null;
        if (request.tty) pty_master_owned = false;
        const process = try self.alloc.create(Process);
        process.* = Process.init(
            self.alloc,
            self,
            id,
            child.id orelse return error.SpawnFailed,
            child,
            stdin,
            stdout,
            stderr,
            windows_job,
            request,
        ) catch |err| {
            self.alloc.destroy(process);
            return err;
        };
        process_io_owned = false;
        child_owned = false;
        windows_job_owned = false;
        errdefer {
            process.stopAndJoin();
            process.destroy();
        }
        try process.start();
        if (comptime builtin.os.tag == .windows) {
            try process.windows_job.resumeChild(process.child.thread_handle);
        }

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
const claude_watchdog_ms: i64 = 5 * 60 * 1000;
const output_limit: usize = 1024 * 1024;
const output_projection_limit: usize = 1024 * 1024;
const output_projection_omitted = "\n[... live output omitted while the consumer was unavailable ...]\n";

fn clampInitialYield(value: u64) u64 {
    return @max(initial_min_yield_ms, @min(max_yield_ms, value));
}

fn clampPollYield(value: u64) u64 {
    return @max(empty_min_yield_ms, @min(max_poll_yield_ms, value));
}

fn cancelRequested(flag: ?*const std.atomic.Value(bool)) bool {
    return if (flag) |value| value.load(.seq_cst) else false;
}

fn elapsedSeconds(started_at_ms: i64) f64 {
    return @as(f64, @floatFromInt(@max(
        @as(i64, 0),
        io_mod.milliTimestamp() - started_at_ms,
    ))) / 1000.0;
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
    manager: *Manager,
    id: u64,
    pid: std.process.Child.Id,
    child: std.process.Child,
    windows_job: WindowsJob,
    stdin: ?std.Io.File,
    stdout: std.Io.File,
    stderr: ?std.Io.File,
    tty: bool,
    reader_count: u8,
    mutex: std.Io.Mutex = .init,
    stop_mutex: std.Io.Mutex = .init,
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
    lifecycle_stdout_buffer: HeadTailBuffer = .{},
    lifecycle_stderr_buffer: HeadTailBuffer = .{},
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
    backgrounded: bool = false,
    lifecycle_event_emitted: bool = false,
    next_watchdog_ms: i64 = 0,
    mode: exec_mode.Mode,
    stop_requested: std.atomic.Value(bool) = .init(false),
    wait_thread: ?std.Thread = null,
    stdout_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,

    fn init(
        alloc: Allocator,
        manager: *Manager,
        id: u64,
        pid: std.process.Child.Id,
        child: std.process.Child,
        stdin: std.Io.File,
        stdout: std.Io.File,
        stderr: ?std.Io.File,
        windows_job: WindowsJob,
        request: Manager.ExecRequest,
    ) !Process {
        const command = try alloc.dupe(u8, request.command);
        errdefer alloc.free(command);
        const cwd = try alloc.dupe(u8, request.cwd);
        errdefer alloc.free(cwd);
        return .{
            .alloc = alloc,
            .manager = manager,
            .id = id,
            .pid = pid,
            .child = child,
            .windows_job = windows_job,
            .stdin = stdin,
            .stdout = stdout,
            .stderr = stderr,
            .tty = request.tty,
            .reader_count = if (request.tty) 1 else 2,
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
            .mode = request.mode,
        };
    }

    fn start(self: *Process) !void {
        self.stdout_thread = try std.Thread.spawn(.{}, readerMain, .{ self, false });
        if (self.stderr != null) {
            self.stderr_thread = std.Thread.spawn(.{}, readerMain, .{ self, true }) catch |err| {
                self.stopAndJoin();
                return err;
            };
        }
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
        return self.done and self.readers_done == self.reader_count;
    }

    fn hasExited(self: *Process) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.done;
    }

    fn markBackgrounded(self: *Process) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.backgrounded = true;
        self.next_watchdog_ms = io_mod.milliTimestamp() + claude_watchdog_ms;
        self.mutex.unlock(io_mod.getIo());
        self.maybeQueueLifecycleEvent();
    }

    fn statusSnapshot(self: *Process, alloc: Allocator) !?Manager.ProcessSnapshot {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.backgrounded) return null;
        const command = try alloc.dupe(u8, self.command);
        errdefer alloc.free(command);
        return .{
            .process_id = self.id,
            .pid = @intCast(self.pid),
            .status = if (self.done) .exited else .running,
            .command = command,
            .cwd = try alloc.dupe(u8, self.cwd),
            .started_at_ms = self.started_at_ms,
            .mode = self.mode,
        };
    }

    /// Thread handoff:
    ///
    /// child waiter/readers -> owned Manager event queue -> host event loop
    ///
    /// No transport, worker, transcript, or renderer callback occurs while a
    /// process lock is held. This keeps process completion independent from UI
    /// paint and from the model-facing output cursor.
    fn maybeQueueLifecycleEvent(self: *Process) void {
        var event: ?Manager.LifecycleEvent = null;
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.backgrounded and self.mode == .claude and self.done and
            self.readers_done == self.reader_count and !self.lifecycle_event_emitted)
        {
            event = self.buildLifecycleEventLocked(.exited);
            if (event != null) self.lifecycle_event_emitted = true;
        }
        self.mutex.unlock(io_mod.getIo());
        if (event) |owned| self.manager.queueLifecycleEvent(owned);
    }

    fn takeWatchdogEvent(self: *Process, now_ms: i64) ?Manager.LifecycleEvent {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.backgrounded or self.mode != .claude or self.done or
            now_ms < self.next_watchdog_ms)
        {
            return null;
        }
        const event = self.buildLifecycleEventLocked(.running) orelse return null;
        self.next_watchdog_ms = now_ms + claude_watchdog_ms;
        return event;
    }

    fn buildLifecycleEventLocked(self: *Process, status: Manager.Status) ?Manager.LifecycleEvent {
        const out = self.lifecycle_stdout_buffer.snapshot(self.alloc, output_limit) catch return null;
        const err = self.lifecycle_stderr_buffer.snapshot(self.alloc, output_limit) catch {
            self.alloc.free(out.bytes);
            return null;
        };
        const command = self.alloc.dupe(u8, self.command) catch {
            self.alloc.free(out.bytes);
            self.alloc.free(err.bytes);
            return null;
        };
        const cwd = self.alloc.dupe(u8, self.cwd) catch {
            self.alloc.free(out.bytes);
            self.alloc.free(err.bytes);
            self.alloc.free(command);
            return null;
        };
        var event = Manager.LifecycleEvent{
            .process_id = self.id,
            .status = status,
            .command = command,
            .cwd = cwd,
            .stdout = out.bytes,
            .stderr = err.bytes,
            .started_at_ms = self.started_at_ms,
        };
        if (status == .exited) {
            if (self.term) |term| switch (term) {
                .exited => |code| event.exit_code = code,
                .signal => |signal| event.signal = @intCast(@intFromEnum(signal)),
                .stopped, .unknown => {},
            };
        }
        return event;
    }

    fn write(self: *Process, chars: []const u8) !void {
        if (chars.len == 0) return;
        if (!self.tty) {
            if (std.mem.eql(u8, chars, "\x03")) {
                if (comptime builtin.os.tag == .windows) {
                    self.windows_job.terminate();
                } else {
                    std.posix.kill(-self.pid, std.posix.SIG.INT) catch return error.WriteFailed;
                }
                return;
            }
            return error.ProcessStdinClosed;
        }
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.stop_requested.load(.seq_cst)) return error.ProcessExited;
        if (self.done) return error.ProcessExited;
        const stdin = self.stdin orelse return error.ProcessStdinClosed;
        if (comptime builtin.os.tag == .windows) return error.PtyUnavailable;
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
            .chunk_id = self.manager.generateChunkId(),
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
        if (comptime builtin.os.tag == .wasi) return;
        self.stop_mutex.lockUncancelable(io_mod.getIo());
        defer self.stop_mutex.unlock(io_mod.getIo());
        if (!self.stop_requested.swap(true, .seq_cst)) {
            self.mutex.lockUncancelable(io_mod.getIo());
            var done = self.done;
            var readers_done = self.readers_done == self.reader_count;
            self.mutex.unlock(io_mod.getIo());
            if (!done or !readers_done) {
                if (comptime builtin.os.tag == .windows) {
                    self.windows_job.terminate();
                } else {
                    const process_group: std.posix.pid_t = -self.pid;
                    std.posix.kill(process_group, std.posix.SIG.TERM) catch {};
                    var waited_ms: u64 = 0;
                    while (waited_ms < 20) : (waited_ms += 2) {
                        io_mod.sleep(2 * std.time.ns_per_ms);
                        self.mutex.lockUncancelable(io_mod.getIo());
                        done = self.done;
                        readers_done = self.readers_done == self.reader_count;
                        self.mutex.unlock(io_mod.getIo());
                        if (done and readers_done) break;
                    }
                    if (!done or !readers_done) std.posix.kill(process_group, std.posix.SIG.KILL) catch {};
                }
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
        if (comptime builtin.os.tag == .windows) self.windows_job.deinit();
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
        self.lifecycle_stdout_buffer.deinit(self.alloc);
        self.lifecycle_stderr_buffer.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    fn waitMain(self: *Process) void {
        const term = self.child.wait(io_mod.getIo()) catch @as(std.process.Child.Term, .{ .unknown = 0 });
        self.mutex.lockUncancelable(io_mod.getIo());
        self.term = term;
        self.done = true;
        self.mutex.unlock(io_mod.getIo());
        self.maybeQueueLifecycleEvent();
    }

    fn readerMain(self: *Process, stderr: bool) void {
        var buffer: [8192]u8 = undefined;
        var file = if (stderr) self.stderr.? else self.stdout;
        defer file.close(io_mod.getIo());
        while (true) {
            const count = file.readStreaming(io_mod.getIo(), &.{buffer[0..]}) catch |err| {
                if (self.tty and err == error.WouldBlock) {
                    io_mod.sleep(std.time.ns_per_ms);
                    continue;
                }
                break;
            };
            if (count == 0) break;
            self.mutex.lockUncancelable(io_mod.getIo());
            if (stderr) {
                self.stderr_buffer.append(self.alloc, buffer[0..count]) catch {};
                self.lifecycle_stderr_buffer.append(self.alloc, buffer[0..count]) catch {};
                if (self.observer_active)
                    self.observer_stderr_buffer.append(self.alloc, buffer[0..count]) catch {};
            } else {
                self.stdout_buffer.append(self.alloc, buffer[0..count]) catch {};
                self.lifecycle_stdout_buffer.append(self.alloc, buffer[0..count]) catch {};
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
        self.maybeQueueLifecycleEvent();
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

fn setNonblocking(fd: std.Io.File.Handle) !void {
    if (comptime builtin.os.tag == .windows) {
        return;
    } else {
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
        .command = if (builtin.os.tag == .windows)
            "[Console]::Out.Write('ready'); Start-Sleep -Milliseconds 1000; [Console]::Out.Write('done')"
        else
            "printf ready; sleep 1; printf done",
        .cwd = if (builtin.os.tag == .windows) "." else "/tmp",
        .yield_time_ms = if (builtin.os.tag == .windows) 750 else 250,
    });
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.process_id != null);
    try std.testing.expectEqual(Manager.Status.running, first.status);
    const snapshots = try manager.snapshotProcesses(std.testing.allocator);
    defer Manager.freeProcessSnapshots(std.testing.allocator, snapshots);
    try std.testing.expectEqual(@as(usize, 1), snapshots.len);
    try std.testing.expectEqual(first.process_id.?, snapshots[0].process_id);
    try std.testing.expectEqual(Manager.Status.running, snapshots[0].status);

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(std.testing.allocator);
    try stdout.appendSlice(std.testing.allocator, first.stdout);

    var status = first.status;
    var polls: usize = 0;
    while (status == .running and polls < 20) : (polls += 1) {
        var next = try manager.writeStdin(std.testing.allocator, .{
            .process_id = first.process_id.?,
            .yield_time_ms = 500,
        });
        errdefer next.deinit(std.testing.allocator);
        try stdout.appendSlice(std.testing.allocator, next.stdout);
        status = next.status;
        next.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(Manager.Status.exited, status);
    try std.testing.expectEqualStrings("readydone", stdout.items);
}

test "unified exec queues one Claude continuation event from an independent cursor" {
    if (!Manager.supported() or builtin.os.tag == .windows) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var first = try manager.exec(std.testing.allocator, .{
        .command = "printf started; sleep 0.4; printf done",
        .cwd = "/tmp",
        .yield_time_ms = 250,
        .mode = .claude,
    });
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(Manager.Status.running, first.status);

    var events: std.ArrayList(Manager.LifecycleEvent) = .empty;
    const deadline = io_mod.milliTimestamp() + 3_000;
    while (events.items.len == 0 and io_mod.milliTimestamp() < deadline) {
        events.deinit(std.testing.allocator);
        io_mod.sleep(10 * std.time.ns_per_ms);
        events = manager.takeLifecycleEvents();
    }
    defer {
        for (events.items) |*event| event.deinit(std.testing.allocator);
        events.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(first.process_id.?, events.items[0].process_id);
    try std.testing.expectEqual(@as(?i32, 0), events.items[0].exit_code);
    try std.testing.expectEqualStrings("starteddone", events.items[0].stdout);
    try std.testing.expectError(error.UnknownProcessId, manager.writeStdin(
        std.testing.allocator,
        .{ .process_id = first.process_id.? },
    ));
    var duplicate = manager.takeLifecycleEvents();
    defer duplicate.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), duplicate.items.len);
}

test "Claude watchdog event keeps the running process addressable" {
    if (!Manager.supported() or builtin.os.tag == .windows) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var first = try manager.exec(std.testing.allocator, .{
        .command = "sleep 30",
        .cwd = "/tmp",
        .yield_time_ms = 250,
        .mode = .claude,
    });
    const process_id = first.process_id.?;
    first.deinit(std.testing.allocator);

    const process = manager.acquire(process_id) orelse return error.TestExpectedEqual;
    process.mutex.lockUncancelable(std.testing.io);
    process.next_watchdog_ms = io_mod.milliTimestamp() - 1;
    process.mutex.unlock(std.testing.io);
    manager.releaseActive(process);

    var events = manager.takeLifecycleEvents();
    defer {
        for (events.items) |*event| event.deinit(std.testing.allocator);
        events.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(Manager.Status.running, events.items[0].status);

    const snapshots = try manager.snapshotProcesses(std.testing.allocator);
    defer Manager.freeProcessSnapshots(std.testing.allocator, snapshots);
    try std.testing.expectEqual(@as(usize, 1), snapshots.len);
    try std.testing.expectEqual(process_id, snapshots[0].process_id);
    try std.testing.expect(manager.terminate(process_id));
}

test "Claude lifecycle trigger can be retained after host admission fails" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var event = Manager.LifecycleEvent{
        .process_id = 42,
        .status = .exited,
        .exit_code = 7,
        .command = try std.testing.allocator.dupe(u8, "false"),
        .cwd = try std.testing.allocator.dupe(u8, "/tmp"),
        .stdout = try std.testing.allocator.dupe(u8, ""),
        .stderr = try std.testing.allocator.dupe(u8, "failed"),
        .started_at_ms = 1,
    };
    defer event.deinit(std.testing.allocator);

    try manager.retryLifecycleEvent(event);
    var retained = manager.takeLifecycleEvents();
    defer {
        for (retained.items) |*item| item.deinit(std.testing.allocator);
        retained.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), retained.items.len);
    try std.testing.expectEqual(@as(u64, 42), retained.items[0].process_id);
    try std.testing.expectEqual(@as(?i32, 7), retained.items[0].exit_code);
    try std.testing.expectEqualStrings("failed", retained.items[0].stderr);
}

test "non-tty write_stdin accepts polling and control-c only" {
    if (!Manager.supported() or builtin.os.tag == .windows) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var first = try manager.exec(std.testing.allocator, .{
        .command = "sleep 30",
        .cwd = "/tmp",
        .yield_time_ms = 250,
    });
    const process_id = first.process_id.?;
    first.deinit(std.testing.allocator);
    try std.testing.expectError(error.ProcessStdinClosed, manager.writeStdinNonblocking(
        std.testing.allocator,
        .{ .process_id = process_id, .chars = "input" },
    ));
    var interrupted = try manager.writeStdin(std.testing.allocator, .{
        .process_id = process_id,
        .chars = "\x03",
        .yield_time_ms = 2_000,
    });
    defer interrupted.deinit(std.testing.allocator);
    try std.testing.expectEqual(Manager.Status.exited, interrupted.status);
}

test "unified exec projects live and between-poll output through one sink" {
    if (!Manager.supported()) return error.SkipZigTest;
    if (!pseudo_terminal.supported()) return error.SkipZigTest;
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
        .tty = true,
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

test "unified exec cancellation hands off before preserving the live process" {
    if (!Manager.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.heap.c_allocator);
    defer manager.deinit();
    var cancel_flag = std.atomic.Value(bool).init(false);
    var delayed = DelayedCancel{ .flag = &cancel_flag };
    const cancel_thread = try std.Thread.spawn(.{}, DelayedCancel.run, .{&delayed});

    const started_ms = io_mod.milliTimestamp();
    var result = try manager.exec(std.testing.allocator, .{
        .command = "sleep 30",
        .cwd = "/tmp",
        .yield_time_ms = max_yield_ms,
        .cancel_flag = &cancel_flag,
    });
    cancel_thread.join();
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(Manager.Status.running, result.status);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms >= initial_min_yield_ms);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 2_000);
    try std.testing.expect(manager.terminate(result.process_id.?));
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
        .command = if (builtin.os.tag == .windows)
            "[Console]::Out.Write('synchronous')"
        else
            "printf synchronous",
        .cwd = if (builtin.os.tag == .windows) "." else "/tmp",
        .yield_time_ms = if (builtin.os.tag == .windows) 2_000 else 250,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Manager.Status.exited, result.status);
    try std.testing.expect(result.process_id == null);
    try std.testing.expectEqualStrings("synchronous", result.stdout);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code.?);
}

test "unified exec Windows resolver runs commands through installed Git Bash" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var shell_buffer: [4096]u8 = undefined;
    const shell = shell_resolver.configuredOrDefaultLoginShellInto(&shell_buffer);
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(shell), "bash.exe"))
        return error.SkipZigTest;

    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var result = try manager.exec(std.testing.allocator, .{
        .command = "printf git-bash",
        .cwd = ".",
        .shell = shell,
        .yield_time_ms = 5_000,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Manager.Status.exited, result.status);
    try std.testing.expectEqualStrings("git-bash", result.stdout);
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
    if (!pseudo_terminal.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var first = try manager.exec(std.testing.allocator, .{
        .command = if (builtin.os.tag == .windows)
            "$line = [Console]::In.ReadLine(); [Console]::Out.Write(('got:{0}' -f $line))"
        else
            "IFS= read -r line; printf 'got:%s' \"$line\"",
        .cwd = if (builtin.os.tag == .windows) "." else "/tmp",
        .yield_time_ms = if (builtin.os.tag == .windows) 1_000 else 250,
        .tty = true,
    });
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(Manager.Status.running, first.status);
    var second = try manager.writeStdin(std.testing.allocator, .{
        .process_id = first.process_id.?,
        .chars = "hello\n",
        .yield_time_ms = if (builtin.os.tag == .windows) 5_000 else 2_000,
    });
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(Manager.Status.exited, second.status);
    try std.testing.expect(std.mem.find(u8, second.stdout, "got:hello") != null);
}

test "tty input racing with exit returns the final process result" {
    if (!Manager.supported() or !pseudo_terminal.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var first = try manager.exec(std.testing.allocator, .{
        .command = "printf final; sleep 0.35",
        .cwd = "/tmp",
        .yield_time_ms = 250,
        .tty = true,
    });
    const process_id = first.process_id.?;
    try std.testing.expect(std.mem.find(u8, first.stdout, "final") != null);
    first.deinit(std.testing.allocator);
    io_mod.sleep(250 * std.time.ns_per_ms);

    var final = try manager.writeStdin(std.testing.allocator, .{
        .process_id = process_id,
        .chars = "late input\n",
    });
    defer final.deinit(std.testing.allocator);
    try std.testing.expectEqual(Manager.Status.exited, final.status);
}

test "unified exec nonblocking writes return a live process immediately" {
    if (!Manager.supported()) return error.SkipZigTest;
    if (!pseudo_terminal.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var first = try manager.exec(std.testing.allocator, .{
        .command = "IFS= read -r line; printf 'got:%s' \"$line\"; sleep 30",
        .cwd = "/tmp",
        .yield_time_ms = 250,
        .tty = true,
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
    if (!pseudo_terminal.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var first = try manager.exec(std.testing.allocator, .{
        .command = if (builtin.os.tag == .windows) "Start-Sleep -Seconds 30" else "sleep 30",
        .cwd = if (builtin.os.tag == .windows) "." else "/tmp",
        .yield_time_ms = if (builtin.os.tag == .windows) 1_000 else 250,
        .tty = true,
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
    if (!pseudo_terminal.supported()) return error.SkipZigTest;
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    var first = try manager.exec(std.testing.allocator, .{
        .command = if (builtin.os.tag == .windows)
            "$first = [Console]::In.ReadLine(); [Console]::Out.Write(\"model:$first\"); [void][Console]::In.ReadLine()"
        else
            "IFS= read -r first; printf 'model:%s' \"$first\"; IFS= read -r second",
        .cwd = if (builtin.os.tag == .windows) "." else "/tmp",
        .yield_time_ms = 250,
        .tty = true,
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
        .command = if (builtin.os.tag == .windows)
            "$child = Start-Process -FilePath ($PSHOME + '\\powershell.exe') -ArgumentList '-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 30' -NoNewWindow -PassThru; [Console]::Out.Write($child.Id); Wait-Process -Id $child.Id"
        else
            "sleep 30 & child=$!; printf '%d' \"$child\"; wait",
        .cwd = if (builtin.os.tag == .windows) "." else "/tmp",
        .yield_time_ms = if (builtin.os.tag == .windows) 1_000 else 250,
    });
    const child_pid = try std.fmt.parseInt(u32, running.stdout, 10);
    running.deinit(std.testing.allocator);
    const started = io_mod.milliTimestamp();
    manager.deinit();
    const elapsed = io_mod.milliTimestamp() - started;
    try std.testing.expect(elapsed < 2_000);
    const deadline = io_mod.milliTimestamp() + 2_000;
    if (builtin.os.tag == .windows) {
        while (!WindowsProcessProbe.exited(child_pid) and io_mod.milliTimestamp() < deadline)
            io_mod.sleep(10 * std.time.ns_per_ms);
        try std.testing.expect(WindowsProcessProbe.exited(child_pid));
    } else {
        while (io_mod.milliTimestamp() < deadline) {
            std.posix.kill(@intCast(child_pid), @enumFromInt(0)) catch |err| switch (err) {
                error.ProcessNotFound => break,
                else => return err,
            };
            io_mod.sleep(10 * std.time.ns_per_ms);
        }
        try std.testing.expectError(
            error.ProcessNotFound,
            std.posix.kill(@intCast(child_pid), @enumFromInt(0)),
        );
    }
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
