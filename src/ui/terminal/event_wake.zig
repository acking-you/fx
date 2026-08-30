const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;

pub const Wake = struct {
    windows_event: if (builtin.os.tag == .windows) ?windows.HANDLE else void = if (builtin.os.tag == .windows) null else {},
    read_fd: if (builtin.os.tag == .windows or builtin.os.tag == .wasi) void else std.posix.fd_t = if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {} else -1,
    write_fd: if (builtin.os.tag == .windows or builtin.os.tag == .wasi) void else std.posix.fd_t = if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {} else -1,

    pub fn init(self: *Wake) !void {
        if (comptime builtin.os.tag == .windows) {
            if (self.windows_event != null) return;
            self.windows_event = CreateEventW(null, .FALSE, .FALSE, null) orelse
                return error.EventWakeCreationFailed;
        } else if (comptime builtin.os.tag != .wasi) {
            if (self.read_fd >= 0 or self.write_fd >= 0) return;
            var fds: [2]std.posix.fd_t = undefined;
            if (std.c.pipe(&fds) != 0) return error.EventWakeCreationFailed;
            errdefer {
                closeFd(fds[0]);
                closeFd(fds[1]);
            }
            try setFdFlags(fds[0]);
            try setFdFlags(fds[1]);
            self.read_fd = fds[0];
            self.write_fd = fds[1];
        }
    }

    pub fn deinit(self: *Wake) void {
        if (comptime builtin.os.tag == .windows) {
            if (self.windows_event) |handle| windows.CloseHandle(handle);
            self.windows_event = null;
        } else if (comptime builtin.os.tag != .wasi) {
            if (self.read_fd >= 0) closeFd(self.read_fd);
            if (self.write_fd >= 0) closeFd(self.write_fd);
            self.read_fd = -1;
            self.write_fd = -1;
        }
    }

    pub fn available(self: Wake) bool {
        if (comptime builtin.os.tag == .windows) return self.windows_event != null;
        if (comptime builtin.os.tag == .wasi) return false;
        return self.read_fd >= 0 and self.write_fd >= 0;
    }

    pub fn notify(self: *Wake) void {
        if (comptime builtin.os.tag == .windows) {
            if (self.windows_event) |handle| _ = SetEvent(handle);
        } else if (comptime builtin.os.tag != .wasi) {
            if (self.write_fd < 0) return;
            const byte = [_]u8{1};
            _ = std.c.write(self.write_fd, &byte, byte.len);
        }
    }

    pub fn drain(self: Wake) void {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
        if (self.read_fd < 0) return;
        var bytes: [64]u8 = undefined;
        while (true) {
            const count = std.c.read(self.read_fd, &bytes, bytes.len);
            if (count <= 0 or count < bytes.len) break;
        }
    }
};

fn setFdFlags(fd: std.posix.fd_t) !void {
    while (true) switch (std.posix.errno(std.posix.system.fcntl(
        fd,
        std.posix.F.SETFD,
        @as(usize, std.posix.FD_CLOEXEC),
    ))) {
        .SUCCESS => break,
        .INTR => continue,
        else => return error.EventWakeCreationFailed,
    };

    const current = while (true) {
        const rc = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
        switch (std.posix.errno(rc)) {
            .SUCCESS => break @as(usize, @intCast(rc)),
            .INTR => continue,
            else => return error.EventWakeCreationFailed,
        }
    };
    const nonblock = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    while (true) switch (std.posix.errno(std.posix.system.fcntl(
        fd,
        std.posix.F.SETFL,
        current | nonblock,
    ))) {
        .SUCCESS => break,
        .INTR => continue,
        else => return error.EventWakeCreationFailed,
    };
}

fn closeFd(fd: std.posix.fd_t) void {
    while (true) switch (std.posix.errno(std.posix.system.close(fd))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return,
    };
}

extern "kernel32" fn CreateEventW(
    event_attributes: ?*anyopaque,
    manual_reset: windows.BOOL,
    initial_state: windows.BOOL,
    name: ?[*:0]const u16,
) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetEvent(event: windows.HANDLE) callconv(.winapi) windows.BOOL;
