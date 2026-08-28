const std = @import("std");
const types = @import("../shared/types.zig");

pub const StreamState = types.StreamState;

const ActivityPart = struct {
    count: usize,
    singular: []const u8,
    plural: []const u8,
    verb: []const u8,
};

/// Braille frames and cadence match codex-cli's status indicator. Keeping the
/// frame selection in the output contract lets the TUI and terminal-title
/// surfaces present the same notion of active work.
pub const spinner_interval_ms: i64 = 100;
pub const spinner_frames = [_][]const u8{
    "⠋",
    "⠙",
    "⠹",
    "⠸",
    "⠼",
    "⠴",
    "⠦",
    "⠧",
    "⠇",
    "⠏",
};

pub fn spinnerFrame(now_ms: i64, started_ms: i64) []const u8 {
    const origin = if (started_ms > 0 and started_ms <= now_ms) started_ms else now_ms;
    const elapsed = @max(@as(i64, 0), now_ms - origin);
    const index: usize = @intCast(@mod(@divTrunc(elapsed, spinner_interval_ms), spinner_frames.len));
    return spinner_frames[index];
}

fn streamStatusVerb(stream: StreamState) []const u8 {
    return switch (stream.last_activity_kind orelse return "thinking") {
        .list => "listing",
        .read => "reading",
        .write => "writing",
        .edit => "editing",
        .command => "running",
        .subagent => "delegating",
        .open => "opening",
        .ask => "asking",
    };
}

pub fn buildWorkingLabel(
    buf: []u8,
    stream: StreamState,
    now_ms: i64,
    heading: []const u8,
) []const u8 {
    var out: std.Io.Writer = .fixed(buf);
    out.writeAll(spinnerFrame(now_ms, stream.turn_started_ms)) catch return heading;
    out.writeByte(' ') catch return heading;
    out.writeAll(heading) catch return out.buffered();
    appendWorkingElapsedSuffix(&out, stream, now_ms) catch return out.buffered();
    appendTurnTokenSuffix(&out, stream) catch return out.buffered();
    return out.buffered();
}

pub const thinking_blink_half_period_ms: i64 = 500;

/// The instant the Working clock reads. While fx waits on user input the
/// clock is frozen at the moment the wait began, so time spent on an approval
/// or question never counts as thinking.
fn workingClockNow(stream: StreamState, now_ms: i64) i64 {
    if (stream.waiting_since_ms > 0 and stream.waiting_since_ms < now_ms) {
        return stream.waiting_since_ms;
    }
    return now_ms;
}

/// Marker visibility locked to the elapsed counter's clock: on for the first
/// half of every elapsed second, so the marker relights exactly when the
/// seconds digit advances. Steady on while waiting on user input (a frozen
/// clock would otherwise strand the marker dark). Null when no turn is being
/// timed.
pub fn thinkingBlinkVisible(stream: StreamState, now_ms: i64) ?bool {
    if (stream.turn_started_ms <= 0 or now_ms < stream.turn_started_ms) return null;
    if (stream.waiting_since_ms > 0) return true;
    const half_periods = @divTrunc(now_ms - stream.turn_started_ms, thinking_blink_half_period_ms);
    return @mod(half_periods, 2) == 0;
}

fn appendWorkingElapsedSuffix(writer: *std.Io.Writer, stream: StreamState, now_ms: i64) !void {
    if (stream.turn_started_ms <= 0 or now_ms < stream.turn_started_ms) return;
    // One displayed second spans exactly one on/off blink period.
    const ms_per_second = 2 * thinking_blink_half_period_ms;
    const seconds = @divTrunc(workingClockNow(stream, now_ms) - stream.turn_started_ms, ms_per_second);
    try writer.writeAll(" (");
    try writeElapsed(writer, seconds);
    try writer.writeByte(')');
}

/// Formats an elapsed duration as `1h2m3s`, dropping leading units that are
/// zero so short turns stay `5s` while long ones read `18m0s` instead of a
/// wall of seconds.
fn writeElapsed(writer: *std.Io.Writer, seconds: i64) !void {
    const secs = @mod(seconds, 60);
    const total_minutes = @divTrunc(seconds, 60);
    const mins = @mod(total_minutes, 60);
    const hours = @divTrunc(total_minutes, 60);
    if (hours > 0) {
        try writer.print("{d}h{d}m{d}s", .{ hours, mins, secs });
    } else if (mins > 0) {
        try writer.print("{d}m{d}s", .{ mins, secs });
    } else {
        try writer.print("{d}s", .{secs});
    }
}

/// Tracks whether fx is waiting on user input (approval prompt or question)
/// and keeps the Working clock honest: the clock freezes when the wait
/// begins, and on resume the whole wait is excluded by shifting
/// turn_started_ms forward. Call whenever the waiting state may have changed.
pub fn syncWaitingClock(stream: *StreamState, waiting: bool, now_ms: i64) void {
    if (waiting) {
        if (stream.active and stream.waiting_since_ms == 0) {
            stream.waiting_since_ms = now_ms;
        }
        return;
    }
    if (stream.waiting_since_ms == 0) return;
    const waited = now_ms - stream.waiting_since_ms;
    if (waited > 0 and stream.turn_started_ms > 0) {
        stream.turn_started_ms += waited;
    }
    stream.waiting_since_ms = 0;
}

pub fn buildProgressLabel(buf: []u8, stream: StreamState) ?[]const u8 {
    if (!stream.active) return null;
    return buildActivityLabel(buf, stream);
}

fn buildActivityLabel(buf: []u8, stream: StreamState) []const u8 {
    var out: std.Io.Writer = .fixed(buf);
    out.writeAll(streamStatusVerb(stream)) catch return streamStatusVerb(stream);

    const parts = activityParts(stream);
    if (!hasActivityParts(&parts)) {
        appendTurnTokenSuffix(&out, stream) catch return out.buffered();
        return out.buffered();
    }

    out.writeAll(" | ") catch return out.buffered();

    var first = true;
    for (parts) |part| {
        if (part.count == 0) continue;
        writeActivityPart(&out, &first, part) catch return out.buffered();
    }

    appendTurnTokenSuffix(&out, stream) catch return out.buffered();
    return out.buffered();
}

fn activityParts(stream: StreamState) [7]ActivityPart {
    return .{
        .{ .count = stream.read_count, .singular = "file", .plural = "files", .verb = "read" },
        .{ .count = stream.list_count, .singular = "directory", .plural = "directories", .verb = "listed" },
        .{ .count = stream.write_count, .singular = "file", .plural = "files", .verb = "wrote" },
        .{ .count = stream.edit_count, .singular = "file", .plural = "files", .verb = "edited" },
        .{ .count = stream.command_count, .singular = "command", .plural = "commands", .verb = "started" },
        .{ .count = stream.subagent_count, .singular = "subagent", .plural = "subagents", .verb = "created" },
        .{ .count = stream.open_count, .singular = "file", .plural = "files", .verb = "opened" },
    };
}

fn hasActivityParts(parts: []const ActivityPart) bool {
    for (parts) |part| {
        if (part.count > 0) return true;
    }
    return false;
}

fn writeActivityPart(writer: *std.Io.Writer, first: *bool, part: ActivityPart) !void {
    if (!first.*) try writer.writeAll(", ");
    first.* = false;
    try writer.print("{d} {s} {s}", .{ part.count, if (part.count == 1) part.singular else part.plural, part.verb });
}

pub fn formatTokenCountCompact(buf: []u8, tokens: u64) []const u8 {
    if (tokens < 1000) return std.fmt.bufPrint(buf, "{d}", .{tokens}) catch "0";

    const whole = tokens / 1000;
    const tenths = (tokens % 1000) / 100;
    if (whole < 10 and tenths > 0) {
        return std.fmt.bufPrint(buf, "{d}.{d}k", .{ whole, tenths }) catch "1k";
    }
    return std.fmt.bufPrint(buf, "{d}k", .{whole}) catch "1k";
}

fn writeTokenProgress(writer: *std.Io.Writer, progress: types.TurnTokenProgress) !void {
    var input_buf: [24]u8 = undefined;
    var output_buf: [24]u8 = undefined;
    try writer.print("(↑{s} ↓{s})", .{
        formatTokenCountCompact(&input_buf, progress.input_tokens),
        formatTokenCountCompact(&output_buf, progress.output_tokens),
    });
}

pub fn appendTokenProgressSuffix(writer: *std.Io.Writer, progress: types.TurnTokenProgress) !void {
    if (progress.input_tokens == 0 and progress.output_tokens == 0) return;
    try writer.writeByte(' ');
    try writeTokenProgress(writer, progress);
}

pub fn appendTurnTokenSuffix(writer: *std.Io.Writer, stream: StreamState) !void {
    try appendTokenProgressSuffix(writer, stream.token_progress);
}

test "buildWorkingLabel renders turn token suffix with input only" {
    var buf: [64]u8 = undefined;
    const label = buildWorkingLabel(&buf, .{
        .active = true,
        .token_progress = .{ .input_tokens = 10 },
    }, 0, "Working");
    try std.testing.expectEqualStrings("⠋ Working (↑10 ↓0)", label);
}

test "buildWorkingLabel renders turn token suffix with input and output" {
    var buf: [64]u8 = undefined;
    const label = buildWorkingLabel(&buf, .{
        .active = true,
        .token_progress = .{ .input_tokens = 10, .output_tokens = 20 },
    }, 0, "Working");
    try std.testing.expectEqualStrings("⠋ Working (↑10 ↓20)", label);
}

test "buildWorkingLabel renders elapsed seconds for the running turn" {
    var buf: [64]u8 = undefined;
    const label = buildWorkingLabel(&buf, .{
        .active = true,
        .turn_started_ms = 1_000,
    }, 6_500, "Working");
    try std.testing.expectEqualStrings("⠴ Working (5s)", label);
}

test "buildWorkingLabel renders elapsed minutes and seconds for long turns" {
    var buf: [64]u8 = undefined;
    // 1080s of blink periods elapsed → 18m0s instead of a raw second count.
    const label = buildWorkingLabel(&buf, .{
        .active = true,
        .turn_started_ms = 1_000,
    }, 1_000 + 1_080 * 1_000, "Working");
    try std.testing.expectEqualStrings("⠋ Working (18m0s)", label);
}

test "buildWorkingLabel renders elapsed hours for very long turns" {
    var buf: [64]u8 = undefined;
    // 3663s → 1h1m3s.
    const label = buildWorkingLabel(&buf, .{
        .active = true,
        .turn_started_ms = 1_000,
    }, 1_000 + 3_663 * 1_000, "Working");
    try std.testing.expectEqualStrings("⠋ Working (1h1m3s)", label);
}

test "buildWorkingLabel renders elapsed seconds before the token suffix" {
    var buf: [64]u8 = undefined;
    const label = buildWorkingLabel(&buf, .{
        .active = true,
        .turn_started_ms = 1_000,
        .token_progress = .{ .input_tokens = 10, .output_tokens = 20 },
    }, 13_000, "Working");
    try std.testing.expectEqualStrings("⠋ Working (12s) (↑10 ↓20)", label);
}

test "thinking blink relights exactly when the seconds digit advances" {
    const stream: StreamState = .{ .active = true, .turn_started_ms = 1_000 };
    try std.testing.expectEqual(@as(?bool, true), thinkingBlinkVisible(stream, 1_000));
    try std.testing.expectEqual(@as(?bool, true), thinkingBlinkVisible(stream, 1_499));
    try std.testing.expectEqual(@as(?bool, false), thinkingBlinkVisible(stream, 1_500));
    try std.testing.expectEqual(@as(?bool, false), thinkingBlinkVisible(stream, 1_999));
    try std.testing.expectEqual(@as(?bool, true), thinkingBlinkVisible(stream, 2_000));

    var label_buf: [64]u8 = undefined;
    const at_relight = buildWorkingLabel(&label_buf, stream, 2_000, "Working");
    try std.testing.expectEqualStrings("⠋ Working (1s)", at_relight);
}

test "thinking blink has no clock without a running turn" {
    try std.testing.expectEqual(@as(?bool, null), thinkingBlinkVisible(.{ .active = true }, 5_000));
    try std.testing.expectEqual(
        @as(?bool, null),
        thinkingBlinkVisible(.{ .active = true, .turn_started_ms = 6_000 }, 5_000),
    );
}

test "thinking clock freezes while waiting on user input and excludes the wait" {
    var stream: StreamState = .{ .active = true, .turn_started_ms = 1_000 };
    var buf: [64]u8 = undefined;

    syncWaitingClock(&stream, true, 5_000);
    try std.testing.expectEqual(@as(i64, 5_000), stream.waiting_since_ms);

    try std.testing.expectEqualStrings("⠋ Working (4s)", buildWorkingLabel(&buf, stream, 900_000, "Working"));
    try std.testing.expectEqual(@as(?bool, true), thinkingBlinkVisible(stream, 900_000));

    syncWaitingClock(&stream, false, 900_000);
    try std.testing.expectEqual(@as(i64, 0), stream.waiting_since_ms);
    try std.testing.expectEqualStrings("⠋ Working (4s)", buildWorkingLabel(&buf, stream, 900_000, "Working"));
    try std.testing.expectEqualStrings("⠋ Working (7s)", buildWorkingLabel(&buf, stream, 903_000, "Working"));
}

test "waiting clock accumulates across repeated prompts in one turn" {
    var stream: StreamState = .{ .active = true, .turn_started_ms = 0 };
    syncWaitingClock(&stream, true, 1_000);
    syncWaitingClock(&stream, false, 9_000);
    try std.testing.expectEqual(@as(i64, 0), stream.turn_started_ms);
    try std.testing.expectEqual(@as(i64, 0), stream.waiting_since_ms);

    stream = .{ .active = true, .turn_started_ms = 1_000 };
    syncWaitingClock(&stream, true, 2_000);
    syncWaitingClock(&stream, false, 10_000);
    syncWaitingClock(&stream, true, 11_000);
    syncWaitingClock(&stream, false, 20_000);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("⠋ Working (2s)", buildWorkingLabel(&buf, stream, 20_000, "Working"));
}

test "waiting clock does not start without an active stream" {
    var stream: StreamState = .{ .active = false };
    syncWaitingClock(&stream, true, 5_000);
    try std.testing.expectEqual(@as(i64, 0), stream.waiting_since_ms);
}

test "buildWorkingLabel hides elapsed seconds when the clock runs behind the mark" {
    var buf: [64]u8 = undefined;
    const label = buildWorkingLabel(&buf, .{
        .active = true,
        .turn_started_ms = 2_000,
    }, 1_000, "Working");
    try std.testing.expectEqualStrings("⠋ Working", label);
}

test "buildActivityLabel renders ordered activity counts" {
    var buf: [256]u8 = undefined;
    const label = buildActivityLabel(&buf, .{
        .active = true,
        .last_activity_kind = .list,
        .read_count = 2,
        .list_count = 3,
        .write_count = 4,
        .edit_count = 5,
        .command_count = 6,
        .subagent_count = 7,
        .open_count = 8,
    });

    try std.testing.expectEqualStrings(
        "listing | 2 files read, 3 directories listed, 4 files wrote, 5 files edited, 6 commands started, 7 subagents created, 8 files opened",
        label,
    );
}

test "buildProgressLabel surfaces active phase and command count" {
    var buf: [256]u8 = undefined;
    const label = buildProgressLabel(&buf, .{
        .active = true,
        .last_activity_kind = .command,
        .command_count = 1,
    });

    try std.testing.expectEqualStrings("running | 1 command started", label.?);
}

test "buildProgressLabel keeps ask status semantic" {
    var buf: [256]u8 = undefined;
    const label = buildProgressLabel(&buf, .{
        .active = true,
        .last_activity_kind = .ask,
    });

    try std.testing.expectEqualStrings("asking", label.?);
}

test "buildProgressLabel appends turn token suffix after activity list" {
    var buf: [256]u8 = undefined;
    const label = buildProgressLabel(&buf, .{
        .active = true,
        .last_activity_kind = .list,
        .read_count = 2,
        .list_count = 3,
        .token_progress = .{ .input_tokens = 10, .output_tokens = 20 },
    });

    try std.testing.expectEqualStrings("listing | 2 files read, 3 directories listed (↑10 ↓20)", label.?);
}

test "buildProgressLabel keeps worst case activity and token suffix within buffer" {
    var buf: [256]u8 = undefined;
    const label = buildProgressLabel(&buf, .{
        .active = true,
        .last_activity_kind = .command,
        .read_count = 9,
        .list_count = 9,
        .write_count = 9,
        .edit_count = 9,
        .command_count = 9,
        .subagent_count = 9,
        .open_count = 9,
        .token_progress = .{ .input_tokens = 999_999, .output_tokens = 999_999 },
    });

    try std.testing.expect(std.mem.find(u8, label.?, "(↑999k ↓999k)") != null);
    try std.testing.expect(!std.mem.eql(u8, label.?, "running"));
}

test "token progress suffix abbreviates values without exactness markers" {
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try appendTokenProgressSuffix(&out, .{
        .input_tokens = 50_000,
        .output_tokens = 1_250,
        .input_exact = true,
        .output_exact = false,
    });
    try std.testing.expectEqualStrings(" (↑50k ↓1.2k)", out.buffered());
}
