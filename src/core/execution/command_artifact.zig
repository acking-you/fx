const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const command_contract = @import("command_contract.zig");
const io_mod = @import("../shared/io.zig");
const config_runtime = @import("../config/config_runtime.zig");
const session_child_store = @import("../session/session_child_store.zig");
const Allocator = std.mem.Allocator;
const CommandOutputStream = command_contract.CommandOutputStream;

const command_artifact_file_prefix = "fx-command-";
const command_artifact_fallback_dir_name = "fx-command-output";
const command_artifact_log_suffix = ".log";
const command_artifact_stdout_suffix = ".stdout.log";
const command_artifact_stderr_suffix = ".stderr.log";

const ArtifactFile = union(enum) {
    external: std.Io.File,
    managed: session_child_store.ManagedFile,

    fn writeAll(self: *ArtifactFile, bytes: []const u8) !void {
        switch (self.*) {
            .external => |file| try file.writeStreamingAll(io_mod.getIo(), bytes),
            .managed => |*file| try file.writeAll(bytes),
        }
    }

    fn sync(self: *ArtifactFile) !void {
        switch (self.*) {
            .external => |file| try file.sync(io_mod.getIo()),
            .managed => |*file| try file.sync(),
        }
    }

    fn close(self: *ArtifactFile) void {
        switch (self.*) {
            .external => |file| file.close(io_mod.getIo()),
            .managed => |*file| file.deinit(),
        }
    }
};

pub const CommandArtifact = struct {
    pub const Paths = struct {
        output_file: []const u8,
        stdout_file: []const u8,
        stderr_file: []const u8,
    };

    output_file: []const u8,
    stdout_file: []const u8,
    stderr_file: []const u8,
    output: ArtifactFile,
    stdout: ArtifactFile,
    stderr: ArtifactFile,

    pub fn append(self: *CommandArtifact, stream: CommandOutputStream, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.output.writeAll(bytes);
        switch (stream) {
            .stdout => try self.stdout.writeAll(bytes),
            .stderr => try self.stderr.writeAll(bytes),
        }
    }

    fn close(self: *CommandArtifact) void {
        self.output.close();
        self.stdout.close();
        self.stderr.close();
    }

    pub fn deinit(self: *CommandArtifact, alloc: Allocator) void {
        self.close();
        alloc.free(self.output_file);
        alloc.free(self.stdout_file);
        alloc.free(self.stderr_file);
        self.* = undefined;
    }

    pub fn sync(self: *CommandArtifact) !void {
        try self.output.sync();
        try self.stdout.sync();
        try self.stderr.sync();
    }

    pub fn paths(self: *const CommandArtifact) Paths {
        return .{
            .output_file = self.output_file,
            .stdout_file = self.stdout_file,
            .stderr_file = self.stderr_file,
        };
    }
};

pub fn createCommandArtifact(
    alloc: Allocator,
    capability: ?*session_child_store.SessionChildCapability,
    preferred_dir: ?[]const u8,
) !CommandArtifact {
    if (capability) |managed| {
        return createManagedCommandArtifact(alloc, managed);
    }
    if (preferred_dir) |dir| {
        if (createCommandArtifactInDir(alloc, dir)) |artifact| {
            return artifact;
        } else |err| {
            debug_trace.logf("core", "command artifact preferred dir failed dir={s} err={s}", .{ dir, @errorName(err) });
        }
    }

    const fallback_dir = try fallbackCommandArtifactDir(alloc);
    defer alloc.free(fallback_dir);
    return createCommandArtifactInDir(alloc, fallback_dir);
}

fn createManagedCommandArtifact(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
) !CommandArtifact {
    const stem = try std.fmt.allocPrint(
        alloc,
        "{s}{d}-{d}",
        .{
            command_artifact_file_prefix,
            io_mod.milliTimestamp(),
            io_mod.nanoTimestamp(),
        },
    );
    defer alloc.free(stem);
    const output_name = try artifactName(
        alloc,
        stem,
        command_artifact_log_suffix,
    );
    defer alloc.free(output_name);
    const stdout_name = try artifactName(
        alloc,
        stem,
        command_artifact_stdout_suffix,
    );
    defer alloc.free(stdout_name);
    const stderr_name = try artifactName(
        alloc,
        stem,
        command_artifact_stderr_suffix,
    );
    defer alloc.free(stderr_name);

    var output = try capability.createExclusiveFile(
        alloc,
        .command_artifacts,
        output_name,
    );
    errdefer {
        output.deinit();
        capability.delete(.command_artifacts, output_name) catch {};
    }
    var stdout = try capability.createExclusiveFile(
        alloc,
        .command_artifacts,
        stdout_name,
    );
    errdefer {
        stdout.deinit();
        capability.delete(.command_artifacts, stdout_name) catch {};
    }
    var stderr = try capability.createExclusiveFile(
        alloc,
        .command_artifacts,
        stderr_name,
    );
    errdefer {
        stderr.deinit();
        capability.delete(.command_artifacts, stderr_name) catch {};
    }
    const output_file = try alloc.dupe(u8, output.displayPath().?);
    errdefer alloc.free(output_file);
    const stdout_file = try alloc.dupe(u8, stdout.displayPath().?);
    errdefer alloc.free(stdout_file);
    const stderr_file = try alloc.dupe(u8, stderr.displayPath().?);
    errdefer alloc.free(stderr_file);

    return .{
        .output_file = output_file,
        .stdout_file = stdout_file,
        .stderr_file = stderr_file,
        .output = .{ .managed = output },
        .stdout = .{ .managed = stdout },
        .stderr = .{ .managed = stderr },
    };
}

fn createCommandArtifactInDir(alloc: Allocator, dir: []const u8) !CommandArtifact {
    try config_runtime.makeAbsolutePath(dir);

    const stem = try std.fmt.allocPrint(
        alloc,
        "{s}{d}-{d}",
        .{ command_artifact_file_prefix, io_mod.milliTimestamp(), io_mod.nanoTimestamp() },
    );
    defer alloc.free(stem);

    const output_file = try artifactPath(alloc, dir, stem, command_artifact_log_suffix);
    errdefer alloc.free(output_file);
    const stdout_file = try artifactPath(alloc, dir, stem, command_artifact_stdout_suffix);
    errdefer alloc.free(stdout_file);
    const stderr_file = try artifactPath(alloc, dir, stem, command_artifact_stderr_suffix);
    errdefer alloc.free(stderr_file);

    const zio = io_mod.getIo();
    var output = try std.Io.Dir.createFileAbsolute(zio, output_file, .{ .truncate = true });
    errdefer output.close(zio);
    var stdout = try std.Io.Dir.createFileAbsolute(zio, stdout_file, .{ .truncate = true });
    errdefer stdout.close(zio);
    var stderr = try std.Io.Dir.createFileAbsolute(zio, stderr_file, .{ .truncate = true });
    errdefer stderr.close(zio);

    return .{
        .output_file = output_file,
        .stdout_file = stdout_file,
        .stderr_file = stderr_file,
        .output = .{ .external = output },
        .stdout = .{ .external = stdout },
        .stderr = .{ .external = stderr },
    };
}

fn artifactName(
    alloc: Allocator,
    stem: []const u8,
    suffix: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ stem, suffix });
}

fn artifactPath(alloc: Allocator, dir: []const u8, stem: []const u8, suffix: []const u8) ![]u8 {
    const name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ stem, suffix });
    defer alloc.free(name);
    return std.Io.Dir.path.join(alloc, &.{ dir, name });
}

fn fallbackCommandArtifactDir(alloc: Allocator) ![]u8 {
    const temp_root = io_mod.getenv("TMPDIR") orelse "/tmp";
    const pid_text = try std.fmt.allocPrint(alloc, "{d}", .{currentProcessId()});
    defer alloc.free(pid_text);
    return std.Io.Dir.path.join(alloc, &.{ temp_root, command_artifact_fallback_dir_name, pid_text });
}

fn currentProcessId() u64 {
    return @intCast(io_mod.processId());
}
