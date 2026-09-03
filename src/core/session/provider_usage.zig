const std = @import("std");
const model_provider = @import("../config/model_provider.zig");
const session_usage = @import("session_usage.zig");
const types = @import("../shared/types.zig");

/// A provider-neutral usage view shared by the TUI footer, ACP, and CLI
/// integrations.  It deliberately contains only aggregates, so callers do
/// not need to duplicate provider-specific wire formats or expose tokens.
pub const WindowKind = enum {
    five_hour,
    weekly,
    daily,
    monthly,
    unknown,

    pub fn label(self: WindowKind) []const u8 {
        return switch (self) {
            .five_hour => "5h",
            .weekly => "week",
            .daily => "day",
            .monthly => "month",
            .unknown => "limit",
        };
    }
};

pub const WindowRemaining = struct {
    kind: WindowKind = .unknown,
    remaining_percent: u8 = 0,
};

pub const Summary = struct {
    provider: model_provider.ProviderId = .gateway,
    credential_source: ?types.CredentialSource = null,
    account_id_present: bool = false,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    total_tokens: u64 = 0,
    request_count: u64 = 0,
    context_used: u64 = 0,
    context_total: ?u32 = null,
    primary_limit: ?WindowRemaining = null,
    secondary_limit: ?WindowRemaining = null,

    pub fn fromSession(
        provider: model_provider.ProviderId,
        credential_source: ?types.CredentialSource,
        account_id: ?[]const u8,
        usage: session_usage.Snapshot,
        context_total: ?u32,
    ) Summary {
        return fromCounters(
            provider,
            credential_source,
            account_id,
            usage.input_tokens,
            usage.output_tokens,
            usage.request_count orelse 0,
            context_total,
        );
    }

    pub fn fromCounters(
        provider: model_provider.ProviderId,
        credential_source: ?types.CredentialSource,
        account_id: ?[]const u8,
        input_tokens: u64,
        output_tokens: u64,
        request_count: u64,
        context_total: ?u32,
    ) Summary {
        return .{
            .provider = provider,
            .credential_source = credential_source,
            .account_id_present = if (account_id) |value| value.len > 0 else false,
            .input_tokens = input_tokens,
            .output_tokens = output_tokens,
            .total_tokens = input_tokens +| output_tokens,
            .request_count = request_count,
            .context_used = input_tokens,
            .context_total = context_total,
        };
    }

    pub fn fromAccountLimits(
        provider: model_provider.ProviderId,
        credential_source: ?types.CredentialSource,
        account_id: ?[]const u8,
        primary: ?WindowRemaining,
        secondary: ?WindowRemaining,
    ) Summary {
        return .{
            .provider = provider,
            .credential_source = credential_source,
            .account_id_present = if (account_id) |value| value.len > 0 else false,
            .primary_limit = primary,
            .secondary_limit = secondary,
        };
    }

    pub fn statusline(self: Summary, out: []u8) []const u8 {
        if (self.primary_limit != null or self.secondary_limit != null) {
            return formatAccountLimits(self, out);
        }
        if (self.total_tokens == 0 and self.request_count == 0) return "Usage: 0";
        const total_k = self.total_tokens / 1000;
        return std.fmt.bufPrint(out, "Usage: {d}k", .{total_k}) catch "Usage";
    }

    pub fn writeJson(self: Summary, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"provider\":");
        try std.json.Stringify.value(@tagName(self.provider), .{}, writer);
        try writer.writeAll(",\"credentialSource\":");
        if (self.credential_source) |source| {
            try std.json.Stringify.value(@tagName(source), .{}, writer);
        } else try writer.writeAll("null");
        try writer.print(",\"accountIdPresent\":{s},\"inputTokens\":{d},\"outputTokens\":{d},\"totalTokens\":{d},\"requestCount\":{d},\"contextUsed\":{d},\"contextTotal\":", .{
            if (self.account_id_present) "true" else "false",
            self.input_tokens,
            self.output_tokens,
            self.total_tokens,
            self.request_count,
            self.context_used,
        });
        if (self.context_total) |total| {
            try writer.print("{d}", .{total});
        } else try writer.writeAll("null");
        try writeLimitJson(writer, "primaryLimit", self.primary_limit);
        try writeLimitJson(writer, "secondaryLimit", self.secondary_limit);
        try writer.writeByte('}');
    }
};

fn formatAccountLimits(summary: Summary, out: []u8) []const u8 {
    var end: usize = 0;
    if (summary.primary_limit) |window| {
        appendWindow(out, &end, window);
    }
    if (summary.secondary_limit) |window| {
        if (end > 0) appendBytes(out, &end, " · ");
        appendWindow(out, &end, window);
    }
    return if (end == 0) "Usage" else out[0..end];
}

fn appendWindow(out: []u8, end: *usize, window: WindowRemaining) void {
    const formatted = std.fmt.bufPrint(
        out[end.*..],
        "{s} {d}%",
        .{ window.kind.label(), window.remaining_percent },
    ) catch return;
    end.* += formatted.len;
}

fn appendBytes(out: []u8, end: *usize, bytes: []const u8) void {
    if (end.* + bytes.len > out.len) return;
    @memcpy(out[end.* .. end.* + bytes.len], bytes);
    end.* += bytes.len;
}

fn writeLimitJson(writer: *std.Io.Writer, field: []const u8, window: ?WindowRemaining) !void {
    try writer.print(",\"{s}\":", .{field});
    if (window) |value| {
        try writer.writeAll("{\"kind\":");
        try std.json.Stringify.value(@tagName(value.kind), .{}, writer);
        try writer.print(",\"remainingPercent\":{d}}}", .{value.remaining_percent});
    } else {
        try writer.writeAll("null");
    }
}

test "provider usage summary is shared across counters and session snapshots" {
    const summary = Summary.fromCounters(.grok, .grok_subscription, "acct", 1200, 800, 2, 16000);
    try std.testing.expectEqual(@as(u64, 2000), summary.total_tokens);
    try std.testing.expect(summary.account_id_present);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Usage: 2k", summary.statusline(&buf));
}

test "provider usage summary prefers remaining account windows" {
    const summary = Summary.fromAccountLimits(
        .codex,
        .chatgpt_subscription,
        "acct",
        .{ .kind = .five_hour, .remaining_percent = 88 },
        .{ .kind = .weekly, .remaining_percent = 65 },
    );
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("5h 88% · week 65%", summary.statusline(&buf));
}

test "provider usage summary omits a missing 5h window" {
    const summary = Summary.fromAccountLimits(
        .codex,
        .chatgpt_subscription,
        "acct",
        null,
        .{ .kind = .weekly, .remaining_percent = 91 },
    );
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("week 91%", summary.statusline(&buf));
}
