const std = @import("std");
const process_identity = @import("process_supervisor.zig");
const session_child_store = @import("../session/session_child_store.zig");

const Allocator = std.mem.Allocator;
const legacy_schema_version: i64 = 1;
const schema_version: i64 = 2;
const max_record_bytes: usize = 256 * 1024;

const TaskState = enum {
    running,
    exited,
    failed,
    stopped,
    dead,
    stale,
};

/// Historical background records are read-only compatibility data. There is
/// deliberately no writer or live task registry: session doctor only validates
/// records created by older fx versions so those sessions remain inspectable.
pub fn validateAllManagedRecords(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
) !void {
    var entries = try capability.iterate(alloc, .background_records);
    defer entries.deinit();
    for (entries.names) |name| {
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        try validateRecordName(name);
        const bytes = try readRecordFile(alloc, capability, name);
        defer alloc.free(bytes);
        try validateRecordText(alloc, bytes);
    }
}

fn validateRecordName(name: []const u8) !void {
    if (!std.mem.endsWith(u8, name, ".json")) {
        return error.InvalidBackgroundRecord;
    }
    _ = std.fmt.parseUnsigned(
        u64,
        name[0 .. name.len - ".json".len],
        10,
    ) catch return error.InvalidBackgroundRecord;
}

fn readRecordFile(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    name: []const u8,
) ![]u8 {
    var file = capability.openFileReadOnly(
        alloc,
        .background_records,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.BackgroundRecordNotFound,
        else => return err,
    };
    defer file.deinit();

    return file.readToEnd(alloc, max_record_bytes) catch |err| switch (err) {
        error.StreamTooLong => return error.InvalidBackgroundRecord,
        else => return err,
    };
}

fn validateRecordText(alloc: Allocator, json_text: []const u8) !void {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        alloc,
        json_text,
        .{},
    ) catch return error.InvalidBackgroundRecord;
    defer parsed.deinit();

    const root = try requireObject(parsed.value);
    const record_schema_version = try requireI64(root, "schema_version");
    if (record_schema_version != legacy_schema_version and
        record_schema_version != schema_version)
    {
        return error.UnsupportedBackgroundSchema;
    }

    _ = try requireU64(root, "id");
    if (record_schema_version == schema_version) {
        try validateStableId(try requireString(root, "background_record_id"));
        if (try optionalString(root.get("process_token"))) |token| {
            _ = process_identity.ProcessInstanceToken.parse(token) catch
                return error.InvalidBackgroundRecord;
        }
        try validateLogStorage(root.get("log_storage") orelse
            return error.InvalidBackgroundRecord);
    }

    _ = try requireString(root, "pid");
    _ = try requireString(root, "command");
    _ = try requireString(root, "cwd");
    _ = try requireString(root, "log_path");
    _ = try requireBool(root, "expect_url");
    _ = try optionalString(root.get("server_url"));
    _ = try requireI64(root, "started_at_ms");
    _ = try requireI64(root, "updated_at_ms");
    _ = try optionalI32(root.get("exit_code"));
    _ = std.meta.stringToEnum(TaskState, try requireString(root, "state")) orelse
        return error.InvalidBackgroundRecord;
    _ = try optionalString(root.get("diagnostic"));
}

fn validateLogStorage(value: std.json.Value) !void {
    const object = try requireObject(value);
    const kind = try requireString(object, "kind");
    if (std.mem.eql(u8, kind, "managed_session")) {
        session_child_store.SessionChildCapability.validateManagedName(
            try requireString(object, "managed_log_name"),
        ) catch return error.InvalidBackgroundRecord;
        return;
    }
    if (std.mem.eql(u8, kind, "external")) {
        if (!std.fs.path.isAbsolute(try requireString(object, "path"))) {
            return error.InvalidBackgroundRecord;
        }
        return;
    }
    return error.InvalidBackgroundRecord;
}

fn validateStableId(text: []const u8) !void {
    if (text.len != 32) return error.InvalidBackgroundRecord;
    for (text) |byte| {
        if (std.ascii.isUpper(byte)) return error.InvalidBackgroundRecord;
        _ = std.fmt.charToDigit(byte, 16) catch
            return error.InvalidBackgroundRecord;
    }
}

fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidBackgroundRecord;
    return value.object;
}

fn requireString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidBackgroundRecord;
    if (value != .string) return error.InvalidBackgroundRecord;
    return value.string;
}

fn requireBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.InvalidBackgroundRecord;
    if (value != .bool) return error.InvalidBackgroundRecord;
    return value.bool;
}

fn requireI64(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidBackgroundRecord;
    return switch (value) {
        .integer => |number| number,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch
            return error.InvalidBackgroundRecord,
        else => error.InvalidBackgroundRecord,
    };
}

fn requireU64(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.InvalidBackgroundRecord;
    return switch (value) {
        .integer => |number| blk: {
            if (number < 0) return error.InvalidBackgroundRecord;
            break :blk @intCast(number);
        },
        .number_string => |text| std.fmt.parseUnsigned(u64, text, 10) catch
            return error.InvalidBackgroundRecord,
        else => error.InvalidBackgroundRecord,
    };
}

fn optionalString(maybe_value: ?std.json.Value) !?[]const u8 {
    const value = maybe_value orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.InvalidBackgroundRecord,
    };
}

fn optionalI32(maybe_value: ?std.json.Value) !?i32 {
    const value = maybe_value orelse return null;
    return switch (value) {
        .null => null,
        .integer => |number| blk: {
            if (number < std.math.minInt(i32) or number > std.math.maxInt(i32)) {
                return error.InvalidBackgroundRecord;
            }
            break :blk @intCast(number);
        },
        .number_string => |text| std.fmt.parseInt(i32, text, 10) catch
            return error.InvalidBackgroundRecord,
        else => error.InvalidBackgroundRecord,
    };
}

test "historical background validator accepts both supported schemas" {
    const legacy =
        \\{"schema_version":1,"id":1,"started_at_ms":1,"updated_at_ms":2,"pid":"123","command":"serve","cwd":"/tmp","log_path":"/tmp/serve.log","expect_url":true,"server_url":null,"exit_code":null,"state":"running","diagnostic":null}
    ;
    try validateRecordText(std.testing.allocator, legacy);

    const current =
        \\{"schema_version":2,"id":2,"background_record_id":"00112233445566778899aabbccddeeff","process_token":"linux:00112233445566778899aabbccddeeff:123","log_storage":{"kind":"managed_session","managed_log_name":"serve.log"},"started_at_ms":1,"updated_at_ms":2,"pid":"123","command":"serve","cwd":"/tmp","log_path":"/tmp/serve.log","expect_url":true,"server_url":"http://localhost:3000","exit_code":0,"state":"exited","diagnostic":null}
    ;
    try validateRecordText(std.testing.allocator, current);
}

test "historical background validator rejects unsafe and unsupported records" {
    const unsupported =
        \\{"schema_version":3}
    ;
    try std.testing.expectError(
        error.UnsupportedBackgroundSchema,
        validateRecordText(std.testing.allocator, unsupported),
    );

    const unsafe =
        \\{"schema_version":2,"id":2,"background_record_id":"00112233445566778899aabbccddeeff","process_token":null,"log_storage":{"kind":"external","path":"relative.log"},"started_at_ms":1,"updated_at_ms":2,"pid":"123","command":"serve","cwd":"/tmp","log_path":"/tmp/serve.log","expect_url":true,"server_url":null,"exit_code":null,"state":"running","diagnostic":null}
    ;
    try std.testing.expectError(
        error.InvalidBackgroundRecord,
        validateRecordText(std.testing.allocator, unsafe),
    );
    try std.testing.expectError(
        error.InvalidBackgroundRecord,
        validateRecordName("not-an-id.json"),
    );
}
