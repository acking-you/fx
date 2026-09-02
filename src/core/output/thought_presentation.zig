//! Display truncation and transcript rendering for streamed provider reasoning.
//!
//! Reasoning is replayed to the provider in full (see `ChatMessage.reasoning`);
//! only the transcript view is bounded. Long reasoning would otherwise push the
//! answer off screen, so the view keeps the most recent lines: the tail is what
//! the model is working on now.
//!
//! The visual contract is the pre-upstream dim italic bullet summary: no
//! `Thinking:` label, first line prefixed with `• `, later lines indented two
//! spaces. This module is pure so it can be tested without a TTY or a live stream.

const std = @import("std");
const display_width = @import("../shared/display_width.zig");

const Allocator = std.mem.Allocator;

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

/// Returns the first completed Markdown bold span. Reasoning-summary providers
/// conventionally put the current activity label in that span, matching the
/// live status extraction used by Codex's TUI.
pub fn firstBoldHeading(body: []const u8) ?[]const u8 {
    const open = std.mem.find(u8, body, "**") orelse return null;
    const content_start = open + 2;
    const close_relative = std.mem.find(u8, body[content_start..], "**") orelse return null;
    const heading = std.mem.trim(u8, body[content_start .. content_start + close_relative], " \t\r\n");
    return if (heading.len == 0) null else heading;
}

const LeadingBoldSummary = struct {
    heading: []const u8,
    body: []const u8,
};

fn splitLeadingBoldSummary(reasoning: []const u8) ?LeadingBoldSummary {
    const trimmed = std.mem.trimStart(u8, reasoning, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "**")) return null;
    const close_relative = std.mem.find(u8, trimmed[2..], "**") orelse return null;
    const close = 2 + close_relative;
    const heading = std.mem.trim(u8, trimmed[2..close], " \t\r\n");
    if (heading.len == 0) return null;
    return .{
        .heading = heading,
        .body = std.mem.trim(u8, trimmed[close + 2 ..], " \t\r\n"),
    };
}

/// Compact body used while reasoning is streaming. Prefer the provider's first
/// completed bold activity header; raw providers fall back to the recent tail.
pub fn activeBody(body: []const u8, visible_lines: usize) VisibleBody {
    if (firstBoldHeading(body)) |heading| {
        return .{ .text = heading, .truncated = heading.len != body.len };
    }
    return visibleBody(body, visible_lines);
}

/// Compact body retained after reasoning settles. A leading bold activity
/// header is presentation metadata, so show the summary beneath it. Header-only
/// summaries remain visible instead of producing an empty block.
pub fn finalizedBody(body: []const u8, visible_lines: usize) VisibleBody {
    if (splitLeadingBoldSummary(body)) |summary| {
        if (summary.body.len > 0) return visibleBody(summary.body, visible_lines);
        return .{ .text = summary.heading, .truncated = false };
    }
    return visibleBody(body, visible_lines);
}

/// Renders a thinking notice as a dim italic bullet summary. The returned
/// buffer is owned by the caller.
pub fn renderTranscript(
    alloc: Allocator,
    body: []const u8,
    style: []const u8,
    reset: []const u8,
    cols: u16,
) ![]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return try alloc.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var first_row = true;
    var line_start: usize = 0;
    while (true) {
        const line_end = std.mem.findScalarPos(u8, trimmed, line_start, '\n') orelse trimmed.len;
        try appendWrappedReasoningLine(
            &out,
            alloc,
            trimmed[line_start..line_end],
            first_row,
            style,
            reset,
            cols,
        );
        first_row = false;
        if (line_end == trimmed.len) break;
        line_start = line_end + 1;
    }
    return out.toOwnedSlice(alloc);
}

fn appendWrappedReasoningLine(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    source_line: []const u8,
    block_first: bool,
    style: []const u8,
    reset: []const u8,
    cols: u16,
) !void {
    var rest = source_line;
    var chunk_first = true;
    while (true) {
        if (out.items.len > 0) try out.append(alloc, '\n');
        const block_start = block_first and chunk_first;
        const indent_cells: usize = if (block_start) 0 else 2;
        const prefix: []const u8 = if (block_start) "• " else "";
        try out.appendNTimes(alloc, ' ', indent_cells);
        try out.appendSlice(alloc, style);
        try out.appendSlice(alloc, prefix);
        const used_cells = indent_cells + if (block_start) @as(usize, 2) else 0;
        const available = @max(@as(usize, cols) -| used_cells, 1);
        const take = display_width.prefixByWidthIgnoringAnsi(rest, available);
        try out.appendSlice(alloc, take);
        try out.appendSlice(alloc, reset);
        rest = rest[take.len..];
        chunk_first = false;
        if (rest.len == 0) break;
    }
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

test "activeBody prefers the first completed bold reasoning header" {
    const result = activeBody("prefix **Inspecting clipboard input**\nmore detail", 3);
    try std.testing.expect(result.truncated);
    try std.testing.expectEqualStrings("Inspecting clipboard input", result.text);
}

test "activeBody falls back to the recent raw reasoning tail" {
    const result = activeBody("one\ntwo\nthree", 2);
    try std.testing.expect(result.truncated);
    try std.testing.expectEqualStrings("two\nthree", result.text);
}

test "finalizedBody removes a leading bold header" {
    const result = finalizedBody(
        "**Inspecting clipboard input**\n\nThe TUI already routes Ctrl+V.\nLinux capture is missing.",
        8,
    );
    try std.testing.expect(!result.truncated);
    try std.testing.expectEqualStrings(
        "The TUI already routes Ctrl+V.\nLinux capture is missing.",
        result.text,
    );
}

test "finalizedBody retains a header-only summary" {
    const result = finalizedBody("  **Checking the focused tests**  ", 8);
    try std.testing.expect(!result.truncated);
    try std.testing.expectEqualStrings("Checking the focused tests", result.text);
}

test "firstBoldHeading ignores incomplete and empty spans" {
    try std.testing.expect(firstBoldHeading("**still streaming") == null);
    try std.testing.expect(firstBoldHeading("before **** after") == null);
}

test "renderTranscript uses a dim italic bullet summary without a Thinking label" {
    const alloc = std.testing.allocator;
    const rendered = try renderTranscript(
        alloc,
        "Checked the runtime path.\nThe focused test passes.",
        "<reasoning>",
        "</>",
        80,
    );
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings(
        "<reasoning>• Checked the runtime path.</>\n  <reasoning>The focused test passes.</>",
        rendered,
    );
    try std.testing.expect(std.mem.find(u8, rendered, "Thinking:") == null);
}

test "renderTranscript wraps long reasoning onto indented continuation rows" {
    const alloc = std.testing.allocator;
    const rendered = try renderTranscript(
        alloc,
        "abcdefghijklmnop",
        "<reasoning>",
        "</>",
        8,
    );
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings(
        "<reasoning>• abcdef</>\n  <reasoning>ghijkl</>\n  <reasoning>mnop</>",
        rendered,
    );
}

test "renderTranscript returns empty for blank reasoning" {
    const alloc = std.testing.allocator;
    const rendered = try renderTranscript(alloc, "  \n\t", "<reasoning>", "</>", 80);
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings("", rendered);
}
