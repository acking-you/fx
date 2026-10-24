const std = @import("std");

const Allocator = std.mem.Allocator;

const max_info_bytes: usize = 4 * 1024;

extern "fx" fn fx_workspace_available() i32;
extern "fx" fn fx_workspace_info(out_ptr: [*]u8, out_cap: usize) i32;

const ImportedHost = struct {
    fn workspaceAvailable() i32 {
        return fx_workspace_available();
    }

    fn workspaceInfo(out_ptr: [*]u8, out_cap: usize) i32 {
        return fx_workspace_info(out_ptr, out_cap);
    }
};

pub const Permission = enum {
    allow_sandboxed,
    prompt,
};

const PathSpan = struct {
    offset: u16,
    len: u16,
};

pub const Info = struct {
    storage: [max_info_bytes]u8 = undefined,
    root_span: PathSpan,
    cwd_span: PathSpan,
    home_span: PathSpan,
    git_available: bool,
    ephemeral: bool,
    permission: Permission,

    pub fn root(self: *const Info) []const u8 {
        return self.path(self.root_span);
    }

    pub fn cwd(self: *const Info) []const u8 {
        return self.path(self.cwd_span);
    }

    pub fn home(self: *const Info) []const u8 {
        return self.path(self.home_span);
    }

    fn path(self: *const Info, span: PathSpan) []const u8 {
        const start: usize = span.offset;
        return self.storage[start .. start + span.len];
    }
};

const JsonInfo = struct {
    version: u32,
    root: []const u8,
    cwd: []const u8,
    home: []const u8,
    git: bool,
    ephemeral: bool,
    permission: []const u8,
};

pub fn Adapter(comptime Host: type) type {
    return struct {
        pub fn loadInfo(alloc: Allocator) !Info {
            return switch (Host.workspaceAvailable()) {
                0 => error.WorkspaceUnavailable,
                1 => loadAvailableInfo(alloc),
                else => error.InvalidContract,
            };
        }

        fn loadAvailableInfo(alloc: Allocator) !Info {
            var buffer: [max_info_bytes]u8 = undefined;
            const result = Host.workspaceInfo(&buffer, buffer.len);
            if (result < 0) return switch (result) {
                -1 => error.WorkspaceHostFailure,
                -2 => error.WorkspaceUnavailable,
                -3 => error.WorkspaceInfoTooSmall,
                -4 => error.InvalidContract,
                else => error.InvalidContract,
            };
            const len: usize = @intCast(result);
            if (len > buffer.len) return error.InvalidContract;

            const parsed = std.json.parseFromSlice(JsonInfo, alloc, buffer[0..len], .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidContract,
            };
            defer parsed.deinit();
            const value = parsed.value;
            if (value.version != 1 or value.git or !value.ephemeral) return error.InvalidContract;
            if (!validAbsolutePath(value.root) or
                !validAbsolutePath(value.cwd) or
                !validAbsolutePath(value.home) or
                !std.mem.eql(u8, value.root, value.cwd)) return error.InvalidContract;
            const permission: Permission = if (std.mem.eql(u8, value.permission, "allow-sandboxed"))
                .allow_sandboxed
            else if (std.mem.eql(u8, value.permission, "prompt"))
                .prompt
            else
                return error.InvalidContract;

            var info = Info{
                .root_span = undefined,
                .cwd_span = undefined,
                .home_span = undefined,
                .git_available = false,
                .ephemeral = true,
                .permission = permission,
            };
            var offset: usize = 0;
            info.root_span = copyPath(&info.storage, &offset, value.root) orelse return error.InvalidContract;
            info.cwd_span = copyPath(&info.storage, &offset, value.cwd) orelse return error.InvalidContract;
            info.home_span = copyPath(&info.storage, &offset, value.home) orelse return error.InvalidContract;
            return info;
        }
    };
}

pub fn HostRuntime(comptime Host: type) type {
    return struct {
        workspace_info: ?Info = null,

        pub fn init(alloc: Allocator) !@This() {
            return .{ .workspace_info = try Adapter(Host).loadInfo(alloc) };
        }

        pub fn available(self: *const @This()) bool {
            return self.workspace_info != null;
        }

        pub fn info(self: *const @This()) ?*const Info {
            return if (self.workspace_info) |*metadata| metadata else null;
        }
    };
}

pub const Runtime = HostRuntime(ImportedHost);

fn copyPath(storage: *[max_info_bytes]u8, offset: *usize, path: []const u8) ?PathSpan {
    if (path.len > storage.len - offset.*) return null;
    const start = offset.*;
    @memcpy(storage[start .. start + path.len], path);
    offset.* += path.len;
    return .{ .offset = @intCast(start), .len = @intCast(path.len) };
}

fn validAbsolutePath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/' or !std.unicode.utf8ValidateSlice(path)) return false;
    if (std.mem.findScalar(u8, path, 0) != null) return false;
    if (path.len == 1) return true;
    if (path[path.len - 1] == '/') return false;
    var segments = std.mem.splitScalar(u8, path[1..], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

const valid_info_json =
    "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"allow-sandboxed\"}";

const FakeInfoHost = struct {
    var available_result: i32 = 1;
    var info_result: ?i32 = null;
    var info_json: []const u8 = valid_info_json;

    fn workspaceAvailable() i32 {
        return available_result;
    }

    fn workspaceInfo(out_ptr: [*]u8, out_cap: usize) i32 {
        if (info_result) |result| return result;
        if (info_json.len > out_cap) return -3;
        @memcpy(out_ptr[0..info_json.len], info_json);
        return @intCast(info_json.len);
    }
};

test "workspace info is unavailable when the host adapter is absent" {
    FakeInfoHost.available_result = 0;
    defer FakeInfoHost.available_result = 1;

    try std.testing.expectError(
        error.WorkspaceUnavailable,
        Adapter(FakeInfoHost).loadInfo(std.testing.allocator),
    );
}

test "workspace info accepts the bounded v1 browser contract" {
    const info = try Adapter(FakeInfoHost).loadInfo(std.testing.allocator);
    try std.testing.expectEqualStrings("/workspace", info.root());
    try std.testing.expectEqualStrings("/workspace", info.cwd());
    try std.testing.expectEqualStrings("/home/visitor", info.home());
    try std.testing.expect(!info.git_available);
    try std.testing.expect(info.ephemeral);
    try std.testing.expectEqual(Permission.allow_sandboxed, info.permission);
}

test "workspace runtime keeps one validated metadata snapshot" {
    FakeInfoHost.available_result = 1;
    const runtime = try HostRuntime(FakeInfoHost).init(std.testing.allocator);
    FakeInfoHost.available_result = 0;
    defer FakeInfoHost.available_result = 1;

    try std.testing.expect(runtime.available());
    try std.testing.expectEqualStrings("/workspace", runtime.info().?.root());
}

test "workspace info rejects invalid host contracts and stable error codes" {
    defer {
        FakeInfoHost.available_result = 1;
        FakeInfoHost.info_result = null;
        FakeInfoHost.info_json = valid_info_json;
    }
    const invalid = [_][]const u8{
        "{\"version\":2,\"root\":\"/workspace\",\"cwd\":\"/workspace\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"prompt\"}",
        "{\"version\":1,\"root\":\"workspace\",\"cwd\":\"/workspace\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"prompt\"}",
        "{\"version\":1,\"root\":\"/workspace/./src\",\"cwd\":\"/workspace/src\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"prompt\"}",
        "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace/src\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"prompt\"}",
        "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace-other\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"prompt\"}",
        "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace\",\"home\":\"/home\\u0000visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"prompt\"}",
        "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace\",\"home\":\"/home/visitor\",\"git\":true,\"ephemeral\":true,\"permission\":\"prompt\"}",
        "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":false,\"permission\":\"prompt\"}",
        "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"allow\"}",
    };
    for (invalid) |payload| {
        FakeInfoHost.info_json = payload;
        try std.testing.expectError(
            error.InvalidContract,
            Adapter(FakeInfoHost).loadInfo(std.testing.allocator),
        );
    }

    FakeInfoHost.info_json =
        "{\"version\":1,\"root\":\"/workspace\",\"cwd\":\"/workspace\",\"home\":\"/home/visitor\",\"git\":false,\"ephemeral\":true,\"permission\":\"prompt\"}";
    const prompt_info = try Adapter(FakeInfoHost).loadInfo(std.testing.allocator);
    try std.testing.expectEqual(Permission.prompt, prompt_info.permission);

    FakeInfoHost.info_result = -3;
    try std.testing.expectError(
        error.WorkspaceInfoTooSmall,
        Adapter(FakeInfoHost).loadInfo(std.testing.allocator),
    );
    FakeInfoHost.info_result = @intCast(max_info_bytes + 1);
    try std.testing.expectError(
        error.InvalidContract,
        Adapter(FakeInfoHost).loadInfo(std.testing.allocator),
    );
}
