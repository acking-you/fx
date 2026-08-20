const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");

const Allocator = std.mem.Allocator;

const linux_self_exe = "/proc/self/exe";

/// Path used to spawn another copy of *this* process.
///
/// `zig build` replaces `zig-out/bin/fx` by unlink+rename. The running
/// inode stays alive, but `std.process.executablePathAlloc` realpaths
/// `/proc/self/exe` to the old on-disk name, and the next spawn is
/// `FileNotFound`. Linux `/proc/self/exe` still execs the live inode.
pub fn pathForReexec(alloc: Allocator) ![]u8 {
    if (testProductExe()) |path| return alloc.dupe(u8, path);
    if (comptime builtin.os.tag == .linux) return alloc.dupe(u8, linux_self_exe);
    return std.process.executablePathAlloc(io_mod.getIo(), alloc);
}

/// Path another process can use to exec this fx.
///
/// Tmux bootstraps and similar scripts run later, so `/proc/self/exe`
/// would be the shell, not fx. Prefer the resolved on-disk path: it is the
/// only form that still works once this process is gone, and a tmux
/// `pipe-pane` command or a recovered session outlives the fx that created
/// it. `/proc/<pid>/exe` is the fallback for a replaced binary, where an
/// on-disk path would be `FileNotFound`; it dies with this process, so it is
/// used only when there is no on-disk file left to name.
pub fn pathForPeerReexec(alloc: Allocator) ![]u8 {
    if (testProductExe()) |path| return alloc.dupe(u8, path);
    if (comptime builtin.os.tag == .linux) {
        if (std.process.executablePathAlloc(io_mod.getIo(), alloc)) |resolved| {
            if (onDiskPathIsExecutable(resolved)) return resolved;
            alloc.free(resolved);
        } else |_| {}
        return std.fmt.allocPrint(alloc, "/proc/{d}/exe", .{std.c.getpid()});
    }
    return std.process.executablePathAlloc(io_mod.getIo(), alloc);
}

/// True when `path` still names a file this process could exec. A rebuild
/// unlinks the old binary, so the resolved name can point at nothing.
fn onDiskPathIsExecutable(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{}) catch return false;
    file.close(io_mod.getIo());
    return true;
}

fn testProductExe() ?[]const u8 {
    if (comptime !builtin.is_test) return null;
    const path_z = std.c.getenv("FX_TEST_PRODUCT_EXE") orelse return null;
    const path = std.mem.sliceTo(path_z, 0);
    return if (path.len == 0) null else path;
}

test "linux re-exec path uses procfs instead of the replaced on-disk name" {
    if (builtin.os.tag != .linux) return;
    const alloc = std.testing.allocator;
    const path = try pathForReexec(alloc);
    defer alloc.free(path);
    if (testProductExe() != null) {
        try std.testing.expect(path.len > 0);
        return;
    }
    try std.testing.expectEqualStrings(linux_self_exe, path);
}

test "peer re-exec path prefers a name that outlives this process" {
    if (builtin.os.tag != .linux) return;
    const alloc = std.testing.allocator;
    const path = try pathForPeerReexec(alloc);
    defer alloc.free(path);
    if (testProductExe() != null) {
        try std.testing.expect(path.len > 0);
        return;
    }
    // A tmux pipe-pane command and a recovered session both run after this
    // process exits, so a /proc/<pid>/exe path would be dangling by then.
    // Only fall back to it when no on-disk name is left to use.
    if (std.mem.startsWith(u8, path, "/proc/")) {
        const resolved = std.process.executablePathAlloc(io_mod.getIo(), alloc) catch return;
        defer alloc.free(resolved);
        try std.testing.expect(!onDiskPathIsExecutable(resolved));
        return;
    }
    try std.testing.expect(onDiskPathIsExecutable(path));
}

test "on-disk probe rejects a replaced binary so the peer path falls back" {
    if (builtin.os.tag != .linux) return;
    const alloc = std.testing.allocator;

    // The probe is what decides between the durable name and procfs, so cover
    // the rebuild case directly: a path unlinked while a process holds the
    // inode must read as unusable.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir_path);
    const victim = try std.fs.path.join(alloc, &.{ dir_path, "fx-probe" });
    defer alloc.free(victim);

    {
        var file = try std.Io.Dir.cwd().createFile(io_mod.getIo(), victim, .{});
        file.close(io_mod.getIo());
    }
    try std.testing.expect(onDiskPathIsExecutable(victim));

    try std.Io.Dir.cwd().deleteFile(io_mod.getIo(), victim);
    try std.testing.expect(!onDiskPathIsExecutable(victim));

    // A relative name could resolve against the spawned process's cwd, so it
    // is never trusted as a peer path.
    try std.testing.expect(!onDiskPathIsExecutable("fx"));
}
