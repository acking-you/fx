const builtin_tools = @import("tools.zig");
const tool_set = @import("../core/tooling/tool_set.zig");

/// Browser/WASM hosts do not provide the process manager required by Unified
/// Exec. They therefore expose no shell fallback; native hosts use the normal
/// BYOK tool set directly.
pub fn selectToolSet(comptime native_tools: bool, _: bool) tool_set.ToolSet {
    if (comptime native_tools) return builtin_tools.advertisement_set;
    return tool_set.empty;
}

test "unsupported browser hosts do not advertise a shell fallback" {
    const selected = selectToolSet(false, true);
    try @import("std").testing.expectEqual(@as(usize, 0), selected.registry.tools.len);
    try @import("std").testing.expectEqual(@as(usize, 0), selected.order.len);
}
