const std = @import("std");
const host = @import("../core/hosts/host.zig");
const activity_status = @import("../core/output/activity_status.zig");

/// Codex keeps the terminal title update independent from full-frame paints:
/// while work is in progress only the spinner frame changes, and unchanged
/// titles are never written again. This small state machine gives fx the same
/// property without making the title an owner of product state.
pub const State = struct {
    base: [124]u8 = undefined,
    base_len: usize = 0,
    last: [128]u8 = undefined,
    last_len: usize = 0,
    last_busy: bool = false,
    initialized: bool = false,
    spinner_started_ms: i64 = 0,

    pub fn setBase(
        self: *State,
        provider: host.TerminalTitle,
        label: []const u8,
        busy: bool,
        now_ms: i64,
    ) void {
        self.base_len = @min(label.len, self.base.len);
        @memcpy(self.base[0..self.base_len], label[0..self.base_len]);
        self.initialized = false;
        self.sync(provider, busy, now_ms);
    }

    pub fn sync(self: *State, provider: host.TerminalTitle, busy: bool, now_ms: i64) void {
        if (!self.initialized) {
            self.spinner_started_ms = now_ms;
            self.last_busy = busy;
        } else if (busy and !self.last_busy) {
            self.spinner_started_ms = now_ms;
        }

        var title: [128]u8 = undefined;
        var title_len: usize = 0;
        if (busy) {
            const frame = activity_status.spinnerFrame(now_ms, self.spinner_started_ms);
            @memcpy(title[0..frame.len], frame);
            title_len = frame.len;
            title[title_len] = ' ';
            title_len += 1;
        }
        if (title_len + self.base_len > title.len) return;
        @memcpy(title[title_len .. title_len + self.base_len], self.base[0..self.base_len]);
        title_len += self.base_len;

        if (!self.initialized or busy != self.last_busy or
            self.last_len != title_len or
            !std.mem.eql(u8, self.last[0..self.last_len], title[0..title_len]))
        {
            provider.set(title[0..title_len]);
            @memcpy(self.last[0..title_len], title[0..title_len]);
            self.last_len = title_len;
        }
        self.last_busy = busy;
        self.initialized = true;
    }

    pub fn clear(self: *State, provider: host.TerminalTitle) void {
        provider.clear();
        self.* = .{};
    }
};

test "terminal title spinner advances only at its display cadence" {
    const Capture = struct {
        label: [128]u8 = undefined,
        len: usize = 0,

        fn set(raw: ?*anyopaque, value: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.len = value.len;
            @memcpy(self.label[0..value.len], value);
        }

        fn clear(_: ?*anyopaque) void {}
    };

    var capture = Capture{};
    const provider = host.TerminalTitle{
        .context = &capture,
        .set_fn = Capture.set,
        .clear_fn = Capture.clear,
    };
    var state = State{};
    state.setBase(provider, "workspace · model", true, 1_000);
    var first: [128]u8 = undefined;
    const first_len = capture.len;
    @memcpy(first[0..first_len], capture.label[0..first_len]);
    state.sync(provider, true, 1_050);
    try std.testing.expectEqualSlices(u8, first[0..first_len], capture.label[0..capture.len]);
    state.sync(provider, true, 1_100);
    try std.testing.expect(!std.mem.eql(u8, first[0..first_len], capture.label[0..capture.len]));
    state.sync(provider, false, 1_101);
    try std.testing.expectEqualStrings("workspace · model", capture.label[0..capture.len]);
}
