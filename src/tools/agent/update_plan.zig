const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

const max_plan_items: usize = 128;
const max_step_bytes: usize = 4096;
const max_explanation_bytes: usize = 4096;

pub const StepStatus = enum { pending, in_progress, completed };

pub const PlanItem = struct {
    step: []u8,
    status: StepStatus,
};

pub const Input = struct {
    explanation: ?[]u8 = null,
    plan: []PlanItem = &.{},

    pub fn deinit(self: *Input, alloc: Allocator) void {
        if (self.explanation) |text| alloc.free(text);
        for (self.plan) |item| alloc.free(item.step);
        if (self.plan.len > 0) alloc.free(self.plan);
        self.* = .{};
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "update_plan arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "update_plan arguments must be an object") };
    }

    const object = parsed.value.object;
    var explanation: ?[]u8 = null;
    var plan: []PlanItem = &.{};
    var initialized: usize = 0;
    var committed = false;
    defer if (!committed) {
        if (explanation) |text| ctx.allocator.free(text);
        for (plan[0..initialized]) |item| ctx.allocator.free(item.step);
        if (plan.len > 0) ctx.allocator.free(plan);
    };
    if (object.get("explanation")) |value| {
        if (value != .string or value.string.len > max_explanation_bytes) {
            return .{ .failure = try ctx.allocator.dupe(u8, "update_plan field \"explanation\" must be a bounded string") };
        }
        explanation = try ctx.allocator.dupe(u8, value.string);
    }

    const raw_plan = object.get("plan") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "update_plan field \"plan\" is required") };
    };
    if (raw_plan != .array or raw_plan.array.items.len > max_plan_items) {
        return .{ .failure = try ctx.allocator.dupe(u8, "update_plan field \"plan\" must be an array of at most 128 items") };
    }
    plan = try ctx.allocator.alloc(PlanItem, raw_plan.array.items.len);
    for (raw_plan.array.items, 0..) |value, index| {
        if (value != .object) {
            return .{ .failure = try ctx.allocator.dupe(u8, "update_plan items must be objects") };
        }
        var fields = value.object.iterator();
        while (fields.next()) |field| {
            if (!std.mem.eql(u8, field.key_ptr.*, "step") and
                !std.mem.eql(u8, field.key_ptr.*, "status"))
            {
                return .{ .failure = try ctx.allocator.dupe(u8, "update_plan items may contain only step and status") };
            }
        }
        const step_value = value.object.get("step") orelse {
            return .{ .failure = try ctx.allocator.dupe(u8, "update_plan item field \"step\" is required") };
        };
        const status_value = value.object.get("status") orelse {
            return .{ .failure = try ctx.allocator.dupe(u8, "update_plan item field \"status\" is required") };
        };
        if (step_value != .string or step_value.string.len == 0 or step_value.string.len > max_step_bytes) {
            return .{ .failure = try ctx.allocator.dupe(u8, "update_plan item \"step\" must be a bounded non-empty string") };
        }
        const status = parseStatus(status_value) orelse {
            return .{ .failure = try ctx.allocator.dupe(u8, "update_plan item \"status\" must be pending, in_progress, or completed") };
        };
        plan[index] = .{ .step = try ctx.allocator.dupe(u8, step_value.string), .status = status };
        initialized += 1;
    }

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .explanation = explanation, .plan = plan };
    explanation = null;
    committed = true;
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn parseStatus(value: std.json.Value) ?StepStatus {
    if (value != .string) return null;
    if (std.mem.eql(u8, value.string, "pending")) return .pending;
    if (std.mem.eql(u8, value.string, "in_progress")) return .in_progress;
    if (std.mem.eql(u8, value.string, "completed")) return .completed;
    return null;
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    var active: usize = 0;
    for (input.plan) |item| {
        if (item.status == .in_progress) active += 1;
    }
    if (active > 1) return try ctx.allocator.dupe(u8, "update_plan may contain at most one in_progress step");
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    if (ctx.on_plan_update) |sink| {
        const body = formatPlan(ctx.allocator, input.*) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .failure = try ctx.allocator.dupe(u8, "update_plan could not render the plan") },
        };
        defer ctx.allocator.free(body);
        try sink(ctx.plan_update_ctx, body);
    }
    return .{ .success = try ctx.allocator.dupe(u8, "Plan updated") };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn formatPlan(alloc: Allocator, input: Input) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (input.explanation) |text| {
        if (text.len > 0) try out.writer.print("{s}\n", .{text});
    }
    for (input.plan) |item| {
        const marker = switch (item.status) {
            .pending => "[ ]",
            .in_progress => "[>]",
            .completed => "[x]",
        };
        try out.writer.print("{s} {s}\n", .{ marker, item.step });
    }
    return try out.toOwnedSlice();
}

test "update_plan decodes and formats a checklist" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"explanation\":\"ship it\",\"plan\":[{\"step\":\"test\",\"status\":\"in_progress\"},{\"step\":\"release\",\"status\":\"pending\"}]}");
    switch (decoded) {
        .failure => |reason| {
            alloc.free(reason);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const text = try formatPlan(alloc, input.as(Input).*);
            defer alloc.free(text);
            try std.testing.expectEqualStrings("ship it\n[>] test\n[ ] release\n", text);
        },
    }
}

test "update_plan rejects multiple active steps" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"plan\":[{\"step\":\"one\",\"status\":\"in_progress\"},{\"step\":\"two\",\"status\":\"in_progress\"}]}");
    switch (decoded) {
        .failure => |reason| {
            alloc.free(reason);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const error_text = (try validate(.{ .allocator = alloc }, input)).?;
            defer alloc.free(error_text);
            try std.testing.expectEqualStrings(
                "update_plan may contain at most one in_progress step",
                error_text,
            );
        },
    }
}

test "update_plan rejects unknown plan item fields" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"plan\":[{\"step\":\"inspect\",\"status\":\"pending\",\"extra\":true}]}");
    switch (decoded) {
        .failure => |reason| {
            defer alloc.free(reason);
            try std.testing.expectEqualStrings(
                "update_plan items may contain only step and status",
                reason,
            );
        },
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
    }
}

const PlanCapture = struct {
    alloc: Allocator,
    body: []u8 = &.{},

    fn deinit(self: *PlanCapture) void {
        if (self.body.len > 0) self.alloc.free(self.body);
        self.* = undefined;
    }
};

fn capturePlan(raw_ctx: ?*anyopaque, body: []const u8) error{OutOfMemory}!void {
    const capture: *PlanCapture = @ptrCast(@alignCast(raw_ctx orelse return));
    if (capture.body.len > 0) capture.alloc.free(capture.body);
    capture.body = try capture.alloc.dupe(u8, body);
}

test "update_plan publishes a worker-facing snapshot and Codex result" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"plan\":[{\"step\":\"inspect\",\"status\":\"completed\"}]}");
    switch (decoded) {
        .failure => |reason| {
            alloc.free(reason);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            var capture = PlanCapture{ .alloc = alloc };
            defer capture.deinit();
            const result = try call(.{
                .allocator = alloc,
                .plan_update_ctx = @ptrCast(&capture),
                .on_plan_update = capturePlan,
            }, input);
            defer result.deinit(alloc);
            try std.testing.expectEqualStrings("Plan updated", result.success);
            try std.testing.expectEqualStrings("[x] inspect\n", capture.body);
        },
    }
}
