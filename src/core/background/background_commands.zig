const std = @import("std");
const unified_exec = @import("../execution/unified_exec.zig");

const Selection = union(enum) {
    last,
    id: u64,
};

fn parseSelectionOrUsage(app: anytype, target: []const u8) !?Selection {
    const trimmed = std.mem.trim(u8, target, " \t");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "last")) return .last;
    return .{ .id = std.fmt.parseInt(u64, trimmed, 10) catch {
        try app.writeDomainNotice(.{
            .topic = "background",
            .tone = .@"error",
            .body = "usage: /background stop <id|last>",
        }, true);
        return null;
    } };
}

pub fn Commands(comptime App: type) type {
    return struct {
        pub fn show(app: *App) !void {
            const commands = try app.unified_exec.snapshotProcesses(app.alloc);
            defer unified_exec.Manager.freeProcessSnapshots(app.alloc, commands);
            return writeSnapshot(app, commands);
        }

        fn writeSnapshot(
            app: *App,
            commands: []const unified_exec.Manager.ProcessSnapshot,
        ) !void {
            if (commands.len == 0) {
                try app.writeDomainNotice(.{
                    .topic = "background",
                    .tone = .neutral,
                    .body = "No background commands are running.",
                }, true);
                return;
            }

            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            try out.writer.print("{d} background process{s}\n", .{
                commands.len,
                if (commands.len == 1) "" else "s",
            });
            for (commands) |command| {
                try out.writer.print(
                    " - #{d} [{s}] {s}\n   pid: {d}\n   cwd: {s}\n   mode: {s}\n",
                    .{
                        command.process_id,
                        @tagName(command.status),
                        command.command,
                        command.pid,
                        command.cwd,
                        command.mode.label(),
                    },
                );
            }

            const text = try out.toOwnedSlice();
            defer app.alloc.free(text);
            try app.writeDomainNotice(.{
                .topic = "background",
                .tone = .neutral,
                .body = std.mem.trimEnd(u8, text, "\n"),
            }, true);
        }

        pub fn stop(app: *App, target: []const u8) !void {
            const selection = (try parseSelectionOrUsage(app, target)) orelse return;
            const process_id: ?u64 = switch (selection) {
                .id => |id| id,
                .last => blk: {
                    const commands = try app.unified_exec.snapshotProcesses(app.alloc);
                    defer unified_exec.Manager.freeProcessSnapshots(app.alloc, commands);
                    var latest: ?u64 = null;
                    for (commands) |command| {
                        if (latest == null or command.process_id > latest.?) {
                            latest = command.process_id;
                        }
                    }
                    break :blk latest;
                },
            };
            if (process_id) |id| {
                if (app.unified_exec.terminate(id)) {
                    const body = try std.fmt.allocPrint(app.alloc, "Stopped background command #{d}.", .{id});
                    defer app.alloc.free(body);
                    try app.writeDomainNotice(.{
                        .topic = "background",
                        .tone = .cancelled,
                        .body = body,
                    }, true);
                    return;
                }
            }
            try app.writeDomainNotice(.{
                .topic = "background",
                .tone = .neutral,
                .body = "No matching background command.",
            }, true);
        }
    };
}
