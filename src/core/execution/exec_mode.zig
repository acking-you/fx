const std = @import("std");

/// Session-local policy for a Unified Exec process that outlives its initial
/// yield window. The process implementation is shared by both policies.
pub const Mode = enum {
    /// Keep the model turn active. The model observes the returned session id
    /// and uses write_stdin with empty chars to poll it.
    codex,
    /// Finish the current model turn after the command yields. A terminal
    /// process transition schedules a separate continuation turn.
    claude,

    pub fn label(self: Mode) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) ?Mode {
        if (std.ascii.eqlIgnoreCase(value, "codex")) return .codex;
        if (std.ascii.eqlIgnoreCase(value, "claude")) return .claude;
        return null;
    }
};

test "exec mode defaults and parser" {
    try std.testing.expectEqual(Mode.codex, @as(Mode, .codex));
    try std.testing.expectEqual(Mode.codex, Mode.parse("CODEX").?);
    try std.testing.expectEqual(Mode.claude, Mode.parse("claude").?);
    try std.testing.expect(Mode.parse("background") == null);
}
