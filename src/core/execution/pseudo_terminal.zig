const std = @import("std");
const builtin = @import("builtin");

const Handle = if (supported()) std.posix.fd_t else std.Io.File.Handle;

pub const Pair = struct {
    master: Handle,
    slave: Handle,
};

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;

pub fn supported() bool {
    return switch (builtin.os.tag) {
        .linux, .macos => true,
        else => false,
    };
}

pub fn open() !Pair {
    if (comptime supported()) return openUnix();
    return error.PtyUnavailable;
}

fn openUnix() !Pair {
    const master = posix_openpt(@bitCast(std.posix.O{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .CLOEXEC = true,
        .NONBLOCK = true,
    }));
    if (master < 0) return error.PtyUnavailable;
    errdefer close(master);
    if (grantpt(master) != 0 or unlockpt(master) != 0)
        return error.PtyUnavailable;
    const slave_name = ptsname(master) orelse return error.PtyUnavailable;
    const slave = try std.posix.openatZ(
        std.posix.AT.FDCWD,
        slave_name,
        .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .CLOEXEC = true,
        },
        0,
    );
    return .{ .master = master, .slave = slave };
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

test "pseudo terminal opens a nonblocking master" {
    if (comptime supported()) return testOpen();
    return error.SkipZigTest;
}

fn testOpen() !void {
    const pair = try open();
    defer close(pair.master);
    defer close(pair.slave);
    const flags = std.posix.system.fcntl(pair.master, std.posix.F.GETFL, @as(usize, 0));
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(flags));
    const nonblocking = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    try std.testing.expect(@as(usize, @intCast(flags)) & nonblocking != 0);
}
