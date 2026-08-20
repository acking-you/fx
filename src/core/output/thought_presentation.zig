//! Display truncation for streamed provider reasoning.
//!
//! Reasoning is replayed to the provider in full (see `ChatMessage.reasoning`);
//! only the transcript view is bounded. Long reasoning would otherwise push the
//! answer off screen, so the view keeps the most recent lines: the tail is what
//! the model is working on now.
//!
//! This module is pure so it can be tested without a TTY or a live stream.

const std = @import("std");

/// Visual lines of reasoning kept in the transcript. Matches the tail-window
/// size used by comparable reasoning displays; the full body still reaches the
/// provider.
pub const default_visible_lines: usize = 8;

/// Marker prefixed to a clipped body so the view does not imply the reasoning
/// started where the visible text does.
pub const ellipsis_line = "…";

/// Returns the byte offset in `body` where the last `visible_lines` lines start,
/// or null when the body already fits. Trailing newlines do not open a line, so
/// a body ending in "\n" is not charged for a line it does not render.
pub fn tailOffset(body: []const u8, visible_lines: usize) ?usize {
    if (visible_lines == 0 or body.len == 0) return null;

    // Ignore trailing newlines so a body that just ended a line is not charged
    // for an empty one.
    var end = body.len;
    while (end > 0 and body[end - 1] == '\n') end -= 1;
    if (end == 0) return null;

    var seen: usize = 0;
    var index = end;
    while (index > 0) {
        index -= 1;
        if (body[index] != '\n') continue;
        seen += 1;
        if (seen == visible_lines) return index + 1;
    }
    return null;
}

/// Reasoning body clipped for display, plus whether anything was dropped.
pub const VisibleBody = struct {
    text: []const u8,
    truncated: bool,
};

/// Returns the trailing window of `body` to render. The result borrows from
/// `body` and stays valid only as long as the caller's buffer does.
pub fn visibleBody(body: []const u8, visible_lines: usize) VisibleBody {
    const offset = tailOffset(body, visible_lines) orelse
        return .{ .text = body, .truncated = false };
    return .{ .text = body[offset..], .truncated = true };
}

test "visibleBody keeps a short body whole" {
    const result = visibleBody("one\ntwo", 8);
    try std.testing.expect(!result.truncated);
    try std.testing.expectEqualStrings("one\ntwo", result.text);
}

test "visibleBody keeps the trailing window of a long body" {
    const result = visibleBody("a\nb\nc\nd\ne", 3);
    try std.testing.expect(result.truncated);
    try std.testing.expectEqualStrings("c\nd\ne", result.text);
}

test "visibleBody does not charge a line for a trailing newline" {
    const result = visibleBody("a\nb\nc\n", 3);
    try std.testing.expect(!result.truncated);
    try std.testing.expectEqualStrings("a\nb\nc\n", result.text);
}

test "visibleBody keeps an exact fit whole" {
    const result = visibleBody("a\nb\nc", 3);
    try std.testing.expect(!result.truncated);
    try std.testing.expectEqualStrings("a\nb\nc", result.text);
}

test "visibleBody handles empty and single-line bodies" {
    const empty = visibleBody("", 8);
    try std.testing.expect(!empty.truncated);
    try std.testing.expectEqualStrings("", empty.text);

    const single = visibleBody("only line", 1);
    try std.testing.expect(!single.truncated);
    try std.testing.expectEqualStrings("only line", single.text);
}

test "visibleBody with zero visible lines keeps the body unchanged" {
    const result = visibleBody("a\nb\nc", 0);
    try std.testing.expect(!result.truncated);
    try std.testing.expectEqualStrings("a\nb\nc", result.text);
}

test "visibleBody keeps blank interior lines inside the window" {
    const result = visibleBody("a\n\nb\n\nc", 3);
    try std.testing.expect(result.truncated);
    try std.testing.expectEqualStrings("b\n\nc", result.text);
}
