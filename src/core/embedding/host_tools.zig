//! Runtime-owned descriptors for tools implemented by the embedding host.
const std = @import("std");
const dispatch = @import("../tooling/tool_dispatch.zig");
const tool_set = @import("../tooling/tool_set.zig");
const builtins = @import("../../builtins/tools.zig");

pub const Spec = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
    read_only: bool = false,
};

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    value: tool_set.ToolSet,

    /// Copies all descriptors and schemas; no input borrows escape this call.
    pub fn init(alloc: std.mem.Allocator, specs: []const Spec, native: bool) !Registry {
        if (specs.len > 128) return error.TooManyHostTools;
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const base = if (native) builtins.advertisement_set else tool_set.empty;
        const tools = try owned.alloc(dispatch.Tool, base.registry.tools.len + specs.len);
        @memcpy(tools[0..base.registry.tools.len], base.registry.tools);
        var order: std.ArrayList([]const u8) = .empty;
        var read_only: std.ArrayList([]const u8) = .empty;
        try order.appendSlice(owned, base.order);
        try read_only.appendSlice(owned, base.read_only_tool_names);
        for (specs, 0..) |spec, index| {
            if (spec.name.len == 0 or spec.name.len > 128 or spec.description.len > 4096)
                return error.InvalidHostTool;
            for (spec.name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-')
                return error.InvalidHostTool;
            if (std.mem.eql(u8, spec.name, "run_command")) return error.ReservedToolName;
            for (builtins.registry.tools) |tool| if (std.mem.eql(u8, tool.name, spec.name))
                return error.ReservedToolName;
            for (specs[0..index]) |earlier| if (std.mem.eql(u8, earlier.name, spec.name))
                return error.DuplicateToolName;
            if (spec.parameters != .object) return error.InvalidToolSchema;
            const kind = spec.parameters.object.get("type") orelse return error.InvalidToolSchema;
            if (kind != .string or !std.mem.eql(u8, kind.string, "object")) return error.InvalidToolSchema;
            const schema = try std.json.Stringify.valueAlloc(owned, spec.parameters, .{});
            if (schema.len > 64 * 1024) return error.ToolSchemaTooLarge;
            const name = try owned.dupe(u8, spec.name);
            const description = try owned.dupe(u8, spec.description);
            tools[base.registry.tools.len + index] = .{
                .name = name,
                .description = description,
                .model_schema = .{ .name = name, .description = description, .input_schema = .{ .raw_json = schema } },
                .executor_kind = .host,
                .requires_approval = !spec.read_only,
                .decode = decode,
                .call = call,
                .reads_only_fn = if (spec.read_only) yes else no,
                .irreversible_fn = no,
            };
            try order.append(owned, name);
            if (spec.read_only) try read_only.append(owned, name);
        }
        return .{ .arena = arena, .value = .{
            .registry = .{ .tools = tools },
            .order = try order.toOwnedSlice(owned),
            .read_only_tool_names = try read_only.toOwnedSlice(owned),
        } };
    }

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
    }
};

const Input = struct {
    json: []u8,

    fn destroy(raw: *anyopaque, alloc: std.mem.Allocator) void {
        const self: *Input = @ptrCast(@alignCast(raw));
        alloc.free(self.json);
        alloc.destroy(self);
    }
};

fn decode(ctx: dispatch.DispatchContext, bytes: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
    if (bytes.len > 256 * 1024) return error.InvalidToolArguments;
    const parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolArguments;
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .json = try ctx.allocator.dupe(u8, bytes) };
    return .{ .input = .{ .ptr = input, .deinit_fn = Input.destroy } };
}

fn call(ctx: dispatch.DispatchContext, input: dispatch.ToolInput) dispatch.DispatchError!dispatch.ToolResult {
    const executor = ctx.host_tool_executor orelse
        return .{ .failure = try ctx.allocator.dupe(u8, "Host tool executor unavailable") };
    return executor.call_fn(executor.context, ctx, input.as(Input).json);
}

fn yes(_: dispatch.ToolInput) bool {
    return true;
}
fn no(_: dispatch.ToolInput) bool {
    return false;
}

test "embedded host tools preserve schemas and cannot replace native executors" {
    const alloc = std.testing.allocator;
    const schema = try std.json.parseFromSlice(std.json.Value, alloc, "{\"type\":\"object\",\"properties\":{\"sku\":{\"type\":\"string\"}},\"required\":[\"sku\"],\"additionalProperties\":false}", .{});
    defer schema.deinit();
    const specs = [_]Spec{.{ .name = "inventory", .description = "Read inventory", .parameters = schema.value, .read_only = true }};
    var registry = try Registry.init(alloc, &specs, false);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 1), registry.value.registry.tools.len);
    const tool = registry.value.registry.tools[0];
    try std.testing.expectEqual(dispatch.ExecutorKind.host, tool.executor_kind);
    try std.testing.expect(!tool.requires_approval);
    const stored = try std.json.parseFromSlice(std.json.Value, alloc, tool.model_schema.input_schema.raw_json.?, .{});
    defer stored.deinit();
    try std.testing.expectEqualStrings("sku", stored.value.object.get("required").?.array.items[0].string);
    const collision = [_]Spec{.{ .name = "exec_command", .description = "replace", .parameters = schema.value }};
    try std.testing.expectError(error.ReservedToolName, Registry.init(alloc, &collision, false));
    const duplicate = [_]Spec{ specs[0], specs[0] };
    try std.testing.expectError(error.DuplicateToolName, Registry.init(alloc, &duplicate, true));
}
