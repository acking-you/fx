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

const AcceptEvent = union(enum) {
    connection: anyerror!std.Io.net.Stream,
    timeout: anyerror!void,
};

fn accept_connection(
    io: std.Io,
    server: *std.Io.net.Server,
) anyerror!std.Io.net.Stream {
    return server.accept(io);
}

fn wait_accept_timeout(io: std.Io, timeout_ms: u32) anyerror!void {
    try io.sleep(.fromMilliseconds(timeout_ms), .awake);
}

fn cancel_accept(io: std.Io, select: *std.Io.Select(AcceptEvent)) void {
    while (select.cancel()) |event| switch (event) {
        .connection => |result| {
            const stream = result catch continue;
            stream.close(io);
        },
        .timeout => {},
    };
}

/// Windows' threaded std.Io listener is backed by AFD and cannot be polled as
/// a plain Winsock listener. Race one asynchronous accept against a bounded
/// timer instead. A connection that loses the timeout race is closed here so
/// ownership never escapes the select operation.
pub fn accept_with_timeout(
    io: std.Io,
    server: *std.Io.net.Server,
    timeout_ms: u32,
) !?std.Io.net.Stream {
    var buffer: [2]AcceptEvent = undefined;
    var select: std.Io.Select(AcceptEvent) = .init(io, &buffer);
    try select.concurrent(.connection, accept_connection, .{ io, server });
    select.concurrent(.timeout, wait_accept_timeout, .{ io, timeout_ms }) catch |err| {
        cancel_accept(io, &select);
        return err;
    };
    const event = select.await() catch |err| {
        cancel_accept(io, &select);
        return err;
    };
    return switch (event) {
        .connection => |result| blk: {
            select.cancelDiscard();
            break :blk try result;
        },
        .timeout => |result| blk: {
            result catch |err| {
                cancel_accept(io, &select);
                return err;
            };
            cancel_accept(io, &select);
            break :blk null;
        },
    };
}

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

test "Windows AFD listener accepts a connection arriving during the wait" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    try std.testing.expect((try accept_with_timeout(io, &server, 10)) == null);

    const ConnectState = struct {
        io: std.Io,
        address: std.Io.net.IpAddress,
        failed: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.io.sleep(.fromMilliseconds(20), .awake) catch {
                self.failed.store(true, .release);
                return;
            };
            var stream = self.address.connect(self.io, .{ .mode = .stream }) catch {
                self.failed.store(true, .release);
                return;
            };
            stream.close(self.io);
        }
    };
    var state = ConnectState{ .io = io, .address = server.socket.address };
    const connector = try std.Thread.spawn(.{}, ConnectState.run, .{&state});
    defer connector.join();

    var accepted = (try accept_with_timeout(io, &server, 1_000)) orelse
        return error.TestExpectedConnection;
    accepted.close(io);
    try std.testing.expect(!state.failed.load(.acquire));
}
