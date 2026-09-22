const std = @import("std");
const theme = @import("../core/shared/theme.zig");

// Retained assistant text contains ANSI, rather than source Markdown. Match
// whole styles against the palette that produced it, including unchanged
// overrides, before replacing them with the corresponding destination slot.
// Inline roles take precedence where the builtin palette shares an escape.
const slots = .{
    "inline_code_open",          "task_completed_open",          "link_style",
    "tag_style",                 "hint_style",                   "system_notice_label_style",
    "system_notice_text_style",  "dim_style",                    "divider_style",
    "statusline_style",          "subtitle_style",               "warning_style",
    "green_style",               "red_style",                    "diff_added_style",
    "diff_removed_style",        "approval_button_active_style", "approval_button_inactive_style",
    "selected_completion_style", "permission_auto_style",        "user_card_marker_style",
    "user_card_accent_style",    "tool_stdout_style",            "tool_stderr_style",
};

/// Caller owns the replacement. Null means the original bytes can be kept.
pub fn bytes(alloc: std.mem.Allocator, input: []const u8, from: theme.Theme, to: theme.Theme) !?[]u8 {
    if (std.meta.eql(from, to)) return null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var index: usize = 0;
    var old_close: ?[]const u8 = null;
    var new_close: []const u8 = "";
    var bold = false;
    var dim = false;
    var italic = false;
    while (index < input.len) {
        if (input[index] != 0x1b) {
            const count = std.mem.findScalar(u8, input[index..], 0x1b) orelse input.len - index;
            try out.writer.writeAll(input[index..][0..count]);
            index += count;
            continue;
        }
        if (old_close) |close| {
            if (std.mem.startsWith(u8, input[index..], close)) {
                try out.writer.writeAll(new_close);
                // A destination slot can introduce emphasis resets that the
                // original renderer had no reason to restore afterwards.
                if (std.mem.find(u8, new_close, "\x1b[22m") != null and std.mem.find(u8, close, "\x1b[22m") == null) {
                    if (bold) try out.writer.writeAll("\x1b[1m");
                    if (dim) try out.writer.writeAll("\x1b[2m");
                }
                if (italic and std.mem.find(u8, new_close, "\x1b[23m") != null and std.mem.find(u8, close, "\x1b[23m") == null)
                    try out.writer.writeAll("\x1b[3m");
                index += close.len;
                old_close = null;
                continue;
            }
        }
        var matched_from: []const u8 = "";
        var matched_to: []const u8 = "";
        inline for (slots) |slot| {
            const source = @field(from, slot);
            if (source.len > matched_from.len and std.mem.startsWith(u8, input[index..], source)) {
                matched_from = source;
                matched_to = @field(to, slot);
            }
        }
        if (matched_from.len > 0) {
            try out.writer.writeAll(matched_to);
            index += matched_from.len;
            old_close = theme.closingFor(matched_from);
            new_close = theme.closingFor(matched_to);
        } else {
            const tail = input[index..];
            if (std.mem.startsWith(u8, tail, "\x1b[1m")) bold = true;
            if (std.mem.startsWith(u8, tail, "\x1b[2m")) dim = true;
            if (std.mem.startsWith(u8, tail, "\x1b[3m")) italic = true;
            if (std.mem.startsWith(u8, tail, "\x1b[22m")) {
                bold = false;
                dim = false;
            }
            if (std.mem.startsWith(u8, tail, "\x1b[23m")) italic = false;
            if (std.mem.startsWith(u8, tail, "\x1b[0m")) {
                bold = false;
                dim = false;
                italic = false;
            }
            try out.writer.writeByte(input[index]);
            index += 1;
        }
    }
    if (std.mem.eql(u8, input, out.written())) {
        out.deinit();
        return null;
    }
    return try out.toOwnedSlice();
}

test "theme retint preserves outer emphasis when the destination adds resets" {
    var to = theme.fx_light;
    to.link_style = "\x1b[1;3;38;5;25m";
    const result = (try bytes(std.testing.allocator, "\x1b[1m\x1b[3mbefore \x1b[38;5;75mlink\x1b[39m tail\x1b[23m\x1b[22m", theme.fx_dark, to)).?;
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.find(u8, result, "\x1b[39m\x1b[22m\x1b[23m\x1b[1m\x1b[3m tail") != null);
}

test "theme retint uses custom slots and their complete closing sequences" {
    var from = theme.fx_dark;
    from.link_style = "\x1b[1;38;2;12;34;56;48;5;7m";
    from.inline_code_open = "\x1b[38;2;65;43;21m";
    var to = theme.fx_light;
    to.link_style = "\x1b[3;38;2;21;43;65m";
    to.inline_code_open = "\x1b[38;2;56;34;12m";
    const result = (try bytes(std.testing.allocator, "\x1b[1;38;2;12;34;56;48;5;7mlink\x1b[39m\x1b[49m\x1b[22m " ++
        "\x1b[38;2;65;43;21mcode\x1b[39m", from, to)).?;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\x1b[3;38;2;21;43;65mlink\x1b[39m\x1b[23m " ++
        "\x1b[38;2;56;34;12mcode\x1b[39m", result);
}
