//! Versioned C boundary. Valid handles remain owned by the host, which must
//! serialize destruction against every other operation on the same handle.
const std = @import("std");
const runtime = @import("core/embedding/runtime.zig");
const build_options = @import("build_options");

pub const Handle = opaque {};
threadlocal var error_buffer: [256]u8 = @splat(0);

fn fail(err: anyerror) c_int {
    _ = std.fmt.bufPrintZ(&error_buffer, "{s}", .{@errorName(err)}) catch unreachable;
    return switch (err) {
        error.Closed => 3,
        error.Backpressure => 4,
        error.OutOfMemory => 5,
        else => 2,
    };
}

fn unwrap(handle: *Handle) *runtime.Runtime {
    return @ptrCast(@alignCast(handle));
}

export fn fx_abi_version() callconv(.c) u32 {
    return 1;
}

export fn fx_revision() callconv(.c) [*:0]const u8 {
    return build_options.git_commit ++ "\x00";
}

export fn fx_last_error() callconv(.c) [*:0]const u8 {
    return @ptrCast(&error_buffer);
}

export fn fx_runtime_create(config: ?[*]const u8, length: usize, output: ?*?*Handle) callconv(.c) c_int {
    const destination = output orelse return 1;
    destination.* = null;
    const bytes = config orelse return 1;
    const instance = runtime.Runtime.create(std.heap.c_allocator, bytes[0..length]) catch |err| return fail(err);
    destination.* = @ptrCast(instance);
    return 0;
}

export fn fx_runtime_write(handle: ?*Handle, bytes: ?[*]const u8, length: usize) callconv(.c) c_int {
    const instance = unwrap(handle orelse return 1);
    const input = bytes orelse return 1;
    instance.input.write(input[0..length]) catch |err| return fail(err);
    return 0;
}

export fn fx_runtime_read(handle: ?*Handle, buffer: ?[*]u8, capacity: usize, written: ?*usize) callconv(.c) c_int {
    const result = written orelse return 1;
    result.* = 0;
    const instance = unwrap(handle orelse return 1);
    const destination = buffer orelse return 1;
    if (capacity == 0) return 1;
    result.* = instance.output.read(destination[0..capacity]) catch |err| return fail(err);
    return 0;
}

export fn fx_runtime_close(handle: ?*Handle) callconv(.c) void {
    if (handle) |value| unwrap(value).close();
}

export fn fx_runtime_exit_code(handle: ?*Handle) callconv(.c) u32 {
    return if (handle) |value| unwrap(value).exit_code.load(.acquire) else 1;
}

export fn fx_runtime_destroy(handle: ?*Handle) callconv(.c) void {
    if (handle) |value| unwrap(value).destroy();
}

test {
    _ = runtime;
}
