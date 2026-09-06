//! Immutable, reference-counted environment snapshots for embedded runtimes.
//! Each worker inherits its parent's snapshot without changing the process
//! environment. The ordinary CLI path has no snapshot and no extra allocation.
const std = @import("std");

threadlocal var active: ?*Environment = null;
var original_vtable: *const std.Io.VTable = undefined;
var scoped_vtable: std.Io.VTable = undefined;

/// Install once before embedded workers start. Default child processes inherit
/// the calling instance's environment; explicit child environments still win.
pub fn wrapIo(io: std.Io) std.Io {
    original_vtable = io.vtable;
    scoped_vtable = io.vtable.*;
    scoped_vtable.processSpawn = spawnProcess;
    scoped_vtable.processSpawnPath = spawnProcessPath;
    return .{ .userdata = io.userdata, .vtable = &scoped_vtable };
}

fn scopedOptions(options: std.process.SpawnOptions) std.process.SpawnOptions {
    var scoped = options;
    if (scoped.environ_map == null) scoped.environ_map = current();
    return scoped;
}

fn spawnProcess(userdata: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    return original_vtable.processSpawn(userdata, scopedOptions(options));
}

fn spawnProcessPath(userdata: ?*anyopaque, dir: std.Io.Dir, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    return original_vtable.processSpawnPath(userdata, dir, scopedOptions(options));
}

pub const Environment = struct {
    alloc: std.mem.Allocator,
    values: std.process.Environ.Map,
    references: std.atomic.Value(usize) = .init(1),

    /// Takes ownership of `values` on success. The caller retains the initial
    /// reference and must release it after leaving its environment scope.
    pub fn create(alloc: std.mem.Allocator, values: std.process.Environ.Map) !*Environment {
        const self = try alloc.create(Environment);
        self.* = .{ .alloc = alloc, .values = values };
        return self;
    }

    pub fn release(self: *Environment) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        var iterator = self.values.iterator();
        // Environ.Map owns duplicated strings, exposed through const slices.
        while (iterator.next()) |entry| std.crypto.secureZero(u8, @constCast(entry.value_ptr.*));
        self.values.deinit();
        self.alloc.destroy(self);
    }

    fn retain(self: *Environment) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }
};

pub const Guard = struct {
    previous: ?*Environment,

    pub fn leave(self: Guard) void {
        active = self.previous;
    }
};

/// Borrows a reference held by the caller until `Guard.leave()`.
pub fn enter(environment: *Environment) Guard {
    const guard = Guard{ .previous = active };
    active = environment;
    return guard;
}

pub fn current() ?*const std.process.Environ.Map {
    return if (active) |environment| &environment.values else null;
}

/// Cross-thread envelopes use the C allocator, like owned worker events. The
/// environment's own reference keeps its map alive even for detached workers.
pub fn spawn(config: std.Thread.SpawnConfig, comptime function: anytype, args: anytype) std.Thread.SpawnError!std.Thread {
    const environment = active orelse return std.Thread.spawn(config, function, args);
    const Payload = struct {
        environment: *Environment,
        args: @TypeOf(args),

        fn run(self: *@This()) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
            defer std.heap.c_allocator.destroy(self);
            defer self.environment.release();
            const guard = enter(self.environment);
            defer guard.leave();
            return @call(.auto, function, self.args);
        }
    };
    const payload = try std.heap.c_allocator.create(Payload);
    errdefer std.heap.c_allocator.destroy(payload);
    environment.retain();
    errdefer environment.release();
    payload.* = .{ .environment = environment, .args = args };
    return std.Thread.spawn(config, Payload.run, .{payload});
}

test "embedded environment is inherited by nested workers and restores its caller" {
    const alloc = std.testing.allocator;
    var values = std.process.Environ.Map.init(alloc);
    try values.put("FX_SCOPE_TEST", "instance-a");
    const environment = try Environment.create(alloc, values);
    defer environment.release();
    const guard = enter(environment);
    const Worker = struct {
        fn run(result: *bool) void {
            result.* = std.mem.eql(u8, current().?.get("FX_SCOPE_TEST").?, "instance-a");
        }

        fn parent(result: *bool) void {
            const child = spawn(.{}, run, .{result}) catch return;
            child.join();
        }
    };
    var observed = false;
    const worker = try spawn(.{}, Worker.parent, .{&observed});
    guard.leave();
    worker.join();
    try std.testing.expect(current() == null);
    try std.testing.expect(observed);
}
