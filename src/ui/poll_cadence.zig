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
    worker_wake_available: bool,
) i32 {
    // The native event wake makes an in-flight network/tool wait event-driven;
    // only the local presentation pacer still needs its short cadence. WASM
    // has no fd to wake, so it retains the short stream timeout.
    if (pacer_pending or (stream_active and (is_wasm or !worker_wake_available))) {
        return active_timeout;
    }
    return if (is_wasm) wasm_idle_timeout_ms else native_idle_timeout_ms;
}

test "poll cadence waits for native worker wake while preserving pacer latency" {
    try std.testing.expectEqual(native_idle_timeout_ms, resolveTimeoutMs(7, false, true, false, true));
    try std.testing.expectEqual(@as(i32, 7), resolveTimeoutMs(7, false, true, false, false));
    try std.testing.expectEqual(@as(i32, 7), resolveTimeoutMs(7, false, false, true, true));
    try std.testing.expectEqual(native_idle_timeout_ms, resolveTimeoutMs(7, false, false, false, true));
    try std.testing.expectEqual(wasm_idle_timeout_ms, resolveTimeoutMs(7, true, false, false, false));
}
