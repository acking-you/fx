const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");

const Handle = if (supported()) std.posix.fd_t else std.Io.File.Handle;

pub const Spawned = struct {
    master: Handle,
    child: std.process.Child,
};

extern "c" fn forkpty(
    master: *c_int,
    name: ?[*]u8,
    termios: ?*const anyopaque,
    window_size: ?*const anyopaque,
) c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

pub fn supported() bool {
    return switch (builtin.os.tag) {
        .linux, .macos => true,
        else => false,
    };
}

pub fn spawn(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
) !Spawned {
    if (comptime supported()) return spawnUnix(alloc, argv, cwd);
    return error.PtyUnavailable;
}

fn spawnUnix(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    cwd: []const u8,
) !Spawned {
    if (argv.len == 0) return error.PtyUnavailable;
    const cwd_z = try alloc.dupeZ(u8, cwd);
    defer alloc.free(cwd_z);
    const argv_z = try alloc.alloc([:0]u8, argv.len);
    defer alloc.free(argv_z);
    var copied: usize = 0;
    defer for (argv_z[0..copied]) |value| alloc.free(value);
    for (argv, 0..) |value, index| {
        argv_z[index] = try alloc.dupeZ(u8, value);
        copied += 1;
    }
    const argv_ptrs = try alloc.allocSentinel(?[*:0]const u8, argv.len, null);
    defer alloc.free(argv_ptrs);
    for (argv_z, 0..) |value, index| argv_ptrs[index] = value.ptr;

    // forkpty connects the child to the controlling slave while Unified Exec
    // retains only the parent-side master for readers and write_stdin.
    var master: c_int = -1;
    const pid = forkpty(&master, null, null, null);
    if (pid < 0) return error.PtyUnavailable;
    if (pid == 0) {
        if (std.c.chdir(cwd_z.ptr) != 0) std.c._exit(127);
        _ = execv(argv_z[0].ptr, argv_ptrs.ptr);
        std.c._exit(127);
    }
    errdefer close(master);
    var child = std.process.Child{
        .id = pid,
        .thread_handle = {},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
    errdefer child.kill(io_mod.getIo());
    try setParentFlags(master);
    return .{
        .master = master,
        .child = child,
    };
}

fn setParentFlags(fd: Handle) !void {
    const status_flags = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
    if (std.posix.errno(status_flags) != .SUCCESS) return error.PtyUnavailable;
    const nonblocking = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    if (std.posix.errno(std.posix.system.fcntl(
        fd,
        std.posix.F.SETFL,
        @as(usize, @intCast(status_flags)) | nonblocking,
    )) != .SUCCESS) return error.PtyUnavailable;
    if (std.posix.errno(std.posix.system.fcntl(
        fd,
        std.posix.F.SETFD,
        @as(usize, std.posix.FD_CLOEXEC),
    )) != .SUCCESS) return error.PtyUnavailable;
}

pub fn duplicate(fd: Handle) !Handle {
    if (comptime supported()) {
        const result = std.c.dup(fd);
        if (result < 0) return error.PtyUnavailable;
        return result;
    } else {
        return error.PtyUnavailable;
    }
}

pub fn file(fd: Handle, nonblocking: bool) std.Io.File {
    if (comptime supported()) {
        return .{ .handle = fd, .flags = .{ .nonblocking = nonblocking } };
    } else {
        unreachable;
    }
}

pub fn close(fd: Handle) void {
    if (comptime supported()) {
        switch (std.posix.errno(std.posix.system.close(fd))) {
            .SUCCESS, .BADF => {},
            else => {},
        }
    }
}

test "pseudo terminal child owns its controlling terminal" {
    if (comptime supported()) return testControllingTerminal();
    return error.SkipZigTest;
}

fn testControllingTerminal() !void {
    var spawned = try spawn(
        std.testing.allocator,
        &.{ "/bin/sh", "-c", "test -t 0 && test \"$(ps -o tpgid= -p $$ | tr -d ' ')\" = \"$$\"" },
        "/tmp",
    );
    defer close(spawned.master);
    const term = try spawned.child.wait(std.testing.io);
    try std.testing.expectEqual(@as(std.process.Child.Term, .{ .exited = 0 }), term);
}
