const std = @import("std");

const Allocator = std.mem.Allocator;

/// Classifies command-shaped tool calls that use captured execution. Historical
/// `run_command` records remain presentation-compatible even though that tool
/// is no longer executable.
pub fn isToolCall(
    alloc: Allocator,
    tool_name: []const u8,
    arguments_json: []const u8,
) Allocator.Error!bool {
    _ = alloc;
    _ = arguments_json;
    return std.mem.eql(u8, tool_name, "run_command") or
        std.mem.eql(u8, tool_name, "exec_command");
}

test "captured command classification recognizes unified exec and history" {
    const alloc = std.testing.allocator;
    try std.testing.expect(try isToolCall(
        alloc,
        "exec_command",
        "{\"cmd\":\"printf ok\"}",
    ));
    try std.testing.expect(try isToolCall(alloc, "run_command", "{}"));
    try std.testing.expect(!try isToolCall(alloc, "read_file", "{}"));
}
