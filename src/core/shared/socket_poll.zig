const std = @import("std");
const builtin = @import("builtin");

pub const Events = if (builtin.os.tag == .windows) struct {
    pub const in: i16 = 0x0300;
    pub const out: i16 = 0x0010;
    pub const err: i16 = 0x0001;
    pub const hup: i16 = 0x0002;
    pub const nval: i16 = 0x0004;
} else struct {
    pub const in: i16 = std.posix.POLL.IN;
    pub const out: i16 = std.posix.POLL.OUT;
    pub const err: i16 = std.posix.POLL.ERR;
    pub const hup: i16 = std.posix.POLL.HUP;
    pub const nval: i16 = std.posix.POLL.NVAL;
};

pub const PollFd = if (builtin.os.tag == .windows) extern struct {
    fd: std.Io.net.Socket.Handle,
    events: i16,
    revents: i16,
} else std.posix.pollfd;

pub const PollError = error{ Interrupted, SystemResources, NetworkDown, Unexpected };

pub fn poll(fds: []PollFd, timeout_ms: i32) PollError!usize {
    if (comptime builtin.os.tag == .windows) {
        const rc = WSAPoll(fds.ptr, @intCast(fds.len), timeout_ms);
        if (rc >= 0) return @intCast(rc);
        return error.NetworkDown;
    } else {
        const fds_count = std.math.cast(std.posix.nfds_t, fds.len) orelse
            return error.SystemResources;
        const rc = std.posix.system.poll(fds.ptr, fds_count, timeout_ms);
        return switch (std.posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => error.Interrupted,
            .NOMEM => error.SystemResources,
            .NETDOWN => error.NetworkDown,
            else => error.Unexpected,
        };
    }
}

pub fn setTimeouts(socket: std.Io.net.Socket.Handle, timeout_ms: u32) !void {
    if (comptime builtin.os.tag == .windows) {
        const native_socket = @intFromPtr(socket);
        if (setsockopt(native_socket, 0xffff, 0x1006, @ptrCast(&timeout_ms), @sizeOf(u32)) != 0 or
            setsockopt(native_socket, 0xffff, 0x1005, @ptrCast(&timeout_ms), @sizeOf(u32)) != 0)
        {
            return error.SocketOptionFailed;
        }
    } else {
        const timeout = std.posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        const receive_rc = std.c.setsockopt(
            socket,
            std.c.SOL.SOCKET,
            std.c.SO.RCVTIMEO,
            &timeout,
            @sizeOf(std.posix.timeval),
        );
        if (receive_rc != 0) return error.SocketOptionFailed;
        const send_rc = std.c.setsockopt(
            socket,
            std.c.SOL.SOCKET,
            std.c.SO.SNDTIMEO,
            &timeout,
            @sizeOf(std.posix.timeval),
        );
        if (send_rc != 0) return error.SocketOptionFailed;
    }
}

extern "ws2_32" fn WSAPoll(fds: [*]PollFd, count: u32, timeout_ms: i32) callconv(.winapi) i32;
extern "ws2_32" fn setsockopt(socket: usize, level: c_int, option: c_int, value: [*]const u8, value_len: c_int) callconv(.winapi) c_int;
