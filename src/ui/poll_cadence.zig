const std = @import("std");

pub const active_timeout_ms: i32 = 8;
pub const native_idle_timeout_ms: i32 = 50;
pub const wasm_idle_timeout_ms: i32 = 16;

/// Streaming presentation needs a short cadence. An idle native terminal can
/// block longer because terminal input wakes the poll immediately; the bound
/// only affects background fact delivery latency.
pub fn resolveTimeoutMs(
    active_timeout: i32,
    is_wasm: bool,
    stream_active: bool,
    pacer_pending: bool,
) i32 {
    if (stream_active or pacer_pending) return active_timeout;
    return if (is_wasm) wasm_idle_timeout_ms else native_idle_timeout_ms;
}

test "poll cadence is short only while presentation is active" {
    try std.testing.expectEqual(@as(i32, 7), resolveTimeoutMs(7, false, true, false));
    try std.testing.expectEqual(@as(i32, 7), resolveTimeoutMs(7, false, false, true));
    try std.testing.expectEqual(native_idle_timeout_ms, resolveTimeoutMs(7, false, false, false));
    try std.testing.expectEqual(wasm_idle_timeout_ms, resolveTimeoutMs(7, true, false, false));
}
