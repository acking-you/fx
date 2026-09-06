//! Owned bounded bytes crossing the native host/runtime boundary.
const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const Queue = struct {
    alloc: std.mem.Allocator,
    limit: usize,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    bytes: std.ArrayList(u8) = .empty,
    offset: usize = 0,
    closed: bool = false,

    pub fn init(alloc: std.mem.Allocator, limit: usize) Queue {
        return .{ .alloc = alloc, .limit = limit };
    }

    /// The owner must join producers and consumers before deinitialization.
    pub fn deinit(self: *Queue) void {
        std.crypto.secureZero(u8, self.bytes.allocatedSlice());
        self.bytes.deinit(self.alloc);
    }

    pub fn write(self: *Queue, value: []const u8) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed) return error.Closed;
        const available = self.bytes.items.len - self.offset;
        if (value.len > self.limit - available) return error.Backpressure;
        if (self.offset > 0) {
            std.mem.copyForwards(u8, self.bytes.items[0..available], self.bytes.items[self.offset..]);
            self.bytes.shrinkRetainingCapacity(available);
            self.offset = 0;
        }
        try self.bytes.appendSlice(self.alloc, value);
        self.changed.broadcast(io);
    }

    pub fn read(self: *Queue, destination: []u8) !usize {
        if (destination.len == 0) return 0;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.offset == self.bytes.items.len and !self.closed) {
            try self.changed.wait(io, &self.mutex);
        }
        const count = @min(destination.len, self.bytes.items.len - self.offset);
        @memcpy(destination[0..count], self.bytes.items[self.offset..][0..count]);
        self.offset += count;
        if (self.offset == self.bytes.items.len) {
            self.bytes.clearRetainingCapacity();
            self.offset = 0;
        }
        return count;
    }

    pub fn close(self: *Queue) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.closed = true;
        self.changed.broadcast(io);
    }

    /// Stop admission immediately, discarding commands not yet consumed.
    pub fn abort(self: *Queue) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.closed = true;
        std.crypto.secureZero(u8, self.bytes.allocatedSlice());
        self.bytes.clearRetainingCapacity();
        self.offset = 0;
        self.changed.broadcast(io);
    }
};

test "embedded queue enforces its bound and drains before EOF" {
    var queue = Queue.init(std.testing.allocator, 4);
    defer queue.deinit();
    try queue.write("abcd");
    try std.testing.expectError(error.Backpressure, queue.write("e"));
    var buffer: [2]u8 = undefined;
    try std.testing.expectEqual(2, try queue.read(&buffer));
    try std.testing.expectEqualStrings("ab", &buffer);
    try queue.write("ef");
    queue.close();
    try std.testing.expectError(error.Closed, queue.write("g"));
    try std.testing.expectEqual(2, try queue.read(&buffer));
    try std.testing.expectEqualStrings("cd", &buffer);
    try std.testing.expectEqual(2, try queue.read(&buffer));
    try std.testing.expectEqualStrings("ef", &buffer);
    try std.testing.expectEqual(0, try queue.read(&buffer));
}

test "embedded abort discards queued commands and wakes readers" {
    var queue = Queue.init(std.testing.allocator, 16);
    defer queue.deinit();
    try queue.write("queued command");
    queue.abort();
    var destination: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try queue.read(&destination));
    try std.testing.expectError(error.Closed, queue.write("new"));
}
