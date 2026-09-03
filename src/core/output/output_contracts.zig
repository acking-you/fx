const std = @import("std");
const auth_runtime = @import("../auth/auth_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const codex_usage = @import("../gateway/codex_usage.zig");
const doctor_runtime = @import("../cli/doctor_runtime.zig");
const model_provider = @import("../config/model_provider.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const permissions = @import("../permissions/permissions.zig");
const session_display_metadata = @import("../session/session_display_metadata.zig");
const session_json = @import("../session/session_json.zig");
const session_store = @import("../session/session_store.zig");
const usage_report = @import("../session/usage_report.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const workspace_commands = @import("../workspace/workspace_commands.zig");

const Allocator = std.mem.Allocator;

fn permissionModeLabel(mode: types.PermissionMode) []const u8 {
    return permissions.permissionModeLabel(mode);
}

pub const OutputFormat = enum {
    text,
    json,
};

pub const CommandFailureSnapshot = struct {
    kind: []const u8,
    message: []const u8,
    code: []const u8,

    pub fn renderJson(self: CommandFailureSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("{\"kind\":");
        try std.json.Stringify.value(self.kind, .{}, &out.writer);
        try out.writer.writeAll(",\"error\":");
        try std.json.Stringify.value(self.message, .{}, &out.writer);
        try out.writer.writeAll(",\"code\":");
        try std.json.Stringify.value(self.code, .{}, &out.writer);
        try out.writer.writeByte('}');
        return try out.toOwnedSlice();
    }
};

pub const UsageSnapshot = struct {
    report: *const usage_report.Snapshot,

    pub fn render(
        self: UsageSnapshot,
        alloc: Allocator,
        format: OutputFormat,
    ) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: UsageSnapshot, alloc: Allocator) ![]u8 {
        const report = self.report;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("Usage ({s})\n", .{report.scope.label()});
        switch (report.coverage) {
            .not_started => try out.writer.writeAll("Tracking has not started.\n"),
            .partial => {
                var date_buf: [24]u8 = undefined;
                try out.writer.print(
                    "Tracking since {s} (partial window).\n",
                    .{usage_report.formatUtcDate(
                        &date_buf,
                        report.coverage_started_at_ms.?,
                    )},
                );
            },
            .full => {},
        }
        switch (report.completeness) {
            .complete => {},
            .pending => try out.writer.writeAll(
                "Known totals exclude pending Gateway reconciliation.\n",
            ),
            .incomplete => try out.writer.writeAll(
                "Known totals may be incomplete.\n",
            ),
            .legacy => try out.writer.writeAll(
                "This session predates complete usage tracking.\n",
            ),
        }

        const totals = report.totals orelse return try out.toOwnedSlice();
        try out.writer.print(
            "Total tokens  {d}\nInput         {d}\nOutput        {d}\n",
            .{ totals.total_tokens, totals.input_tokens, totals.output_tokens },
        );
        try out.writer.print(
            "Cache         {d} read · {d} write\n",
            .{ totals.cache_read_tokens, totals.cache_write_tokens },
        );
        if (totals.reasoning_tokens) |reasoning| {
            try out.writer.print("Reasoning     {d}\n", .{reasoning});
        }
        if (totals.request_count) |requests| {
            try out.writer.print("Requests      {d}\n", .{requests});
        }
        try out.writer.print("Spend         ${d:.4}\n", .{totals.total_cost});

        if (report.models.len > 0) {
            try out.writer.writeAll("\nBy model\n");
            for (report.models) |model| {
                try out.writer.writeAll("- ");
                try writeTerminalSafe(&out.writer, alloc, model.model);
                try out.writer.print(
                    "  {d} tokens  ${d:.4}\n",
                    .{ model.totals.total_tokens, model.totals.total_cost },
                );
            }
        }
        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: UsageSnapshot, alloc: Allocator) ![]u8 {
        const report = self.report;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("{\"kind\":\"usage\",\"schema_version\":1,\"period\":");
        try std.json.Stringify.value(report.scope.cliValue() orelse "session", .{}, &out.writer);
        try out.writer.print(
            ",\"snapshot_time_ms\":{d},\"window_start_ms\":{d},\"coverage\":{{\"status\":",
            .{ report.snapshot_time_ms, report.window_start_ms },
        );
        try std.json.Stringify.value(@tagName(report.coverage), .{}, &out.writer);
        try out.writer.writeAll(",\"started_at_ms\":");
        if (report.coverage_started_at_ms) |started_at_ms| {
            try out.writer.print("{d}", .{started_at_ms});
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.print(
            ",\"full_window\":{}}},\"completeness\":",
            .{report.coverage == .full},
        );
        try std.json.Stringify.value(@tagName(report.completeness), .{}, &out.writer);
        try out.writer.writeAll(",\"totals\":");
        if (report.totals) |totals| {
            try writeUsageTotalsJson(&out.writer, totals);
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.writeAll(",\"models\":[");
        for (report.models, 0..) |model, index| {
            if (index > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"model\":");
            try std.json.Stringify.value(model.model, .{}, &out.writer);
            try out.writer.writeAll(",\"totals\":");
            try writeUsageTotalsJson(&out.writer, model.totals);
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }
};

fn writeUsageTotalsJson(
    writer: *std.Io.Writer,
    totals: usage_report.Totals,
) !void {
    try writer.print(
        "{{\"total_tokens\":{d},\"input_tokens\":{d},\"output_tokens\":{d},\"cache_read_tokens\":{d},\"cache_write_tokens\":{d},\"reasoning_tokens\":",
        .{
            totals.total_tokens,
            totals.input_tokens,
            totals.output_tokens,
            totals.cache_read_tokens,
            totals.cache_write_tokens,
        },
    );
    if (totals.reasoning_tokens) |reasoning| {
        try writer.print("{d}", .{reasoning});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"request_count\":");
    if (totals.request_count) |requests| {
        try writer.print("{d}", .{requests});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"spend\":{d}}}", .{totals.total_cost});
}

pub fn workspaceErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidWorkspaceArgs => null,
        error.InvalidPath => "path is invalid",
        error.PathNotFound => "directory does not exist",
        error.NotDirectory => "path is not a directory",
        error.UnknownAdditionalDirectory => "directory is not configured as an additional workspace",
        error.PrimaryDirectory => "the primary workspace cannot be added or removed",
        error.TooManyDirectories => "additional directory limit reached",
        error.HomeNotSet => "HOME is not set",
        error.SettingsStoreUnavailable => "settings are unavailable",
        error.DurablePathUnsafe, error.PrivateStatePermissionsUnsupported => "settings path is unsafe",
        else => "workspace update failed",
    };
}

pub const WorkspaceSnapshot = struct {
    primary_directory: []const u8,
    saved_suppressed: bool,
    additional_directories: []const workspace_access.Entry,
    mutation: ?workspace_commands.Mutation = null,

    pub fn fromAccess(primary_directory: []const u8, access: *const workspace_access.WorkspaceAccess) WorkspaceSnapshot {
        return .{
            .primary_directory = primary_directory,
            .saved_suppressed = access.saved_suppressed,
            .additional_directories = access.entries,
        };
    }

    pub fn render(self: WorkspaceSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: WorkspaceSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("[workspace] primary=");
        try writeTerminalSafe(&out.writer, alloc, self.primary_directory);
        try out.writer.writeByte('\n');
        try out.writer.print("[workspace] saved_suppressed={} limit={d}\n", .{ self.saved_suppressed, workspace_access.max_additional_directories });
        if (self.mutation) |mutation| {
            try out.writer.print("[workspace] {s}", .{mutation.action});
            if (mutation.path) |path| {
                try out.writer.writeByte(' ');
                try writeTerminalSafe(&out.writer, alloc, path);
            }
            try out.writer.print(" saved_changed={} runtime_changed={} launch_flag_can_restore={}\n", .{
                mutation.saved_changed,
                mutation.runtime_changed,
                mutation.launch_flag_can_restore,
            });
            if (mutation.launch_flag_can_restore) {
                try out.writer.writeAll("[workspace] warning: repeating --add-dir can restore removed access on the next launch\n");
            }
        }
        if (self.additional_directories.len == 0) {
            try out.writer.writeAll("[workspace] additional directories: (none)\n");
            return try out.toOwnedSlice();
        }
        try out.writer.writeAll("[workspace] additional directories:\n");
        for (self.additional_directories) |entry| {
            try out.writer.writeAll(" - ");
            try writeTerminalSafe(&out.writer, alloc, entry.path);
            try out.writer.print(" saved={} command_line={} available={} active={}\n", .{
                entry.saved,
                entry.command_line,
                entry.available,
                entry.active,
            });
        }
        return try out.toOwnedSlice();
    }

    pub fn renderInteractiveBody(self: WorkspaceSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("primary=");
        try writeTerminalSafe(&out.writer, alloc, self.primary_directory);
        try out.writer.writeByte('\n');
        try out.writer.print("saved_suppressed={} limit={d}\n", .{ self.saved_suppressed, workspace_access.max_additional_directories });
        if (self.mutation) |mutation| {
            try out.writer.writeAll(mutation.action);
            if (mutation.path) |path| {
                try out.writer.writeByte(' ');
                try writeTerminalSafe(&out.writer, alloc, path);
            }
            try out.writer.print(" saved_changed={} runtime_changed={} launch_flag_can_restore={}\n", .{
                mutation.saved_changed,
                mutation.runtime_changed,
                mutation.launch_flag_can_restore,
            });
            if (mutation.launch_flag_can_restore) {
                try out.writer.writeAll("warning: repeating --add-dir can restore removed access on the next launch\n");
            }
        }
        if (self.additional_directories.len == 0) {
            try out.writer.writeAll("additional directories: (none)");
            return try out.toOwnedSlice();
        }
        try out.writer.writeAll("additional directories:\n");
        for (self.additional_directories, 0..) |entry, index| {
            try out.writer.writeAll(" - ");
            try writeTerminalSafe(&out.writer, alloc, entry.path);
            try out.writer.print(" saved={} command_line={} available={} active={}", .{
                entry.saved,
                entry.command_line,
                entry.available,
                entry.active,
            });
            if (index + 1 < self.additional_directories.len) try out.writer.writeByte('\n');
        }
        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: WorkspaceSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        const action = if (self.mutation) |mutation| mutation.action else "list";
        const changed = if (self.mutation) |mutation| mutation.saved_changed or mutation.runtime_changed else false;
        try out.writer.writeAll("{\"kind\":\"workspace\",\"action\":");
        try std.json.Stringify.value(action, .{}, &out.writer);
        try out.writer.print(",\"changed\":{}", .{changed});
        try out.writer.writeAll(",\"primary_directory\":");
        try std.json.Stringify.value(self.primary_directory, .{}, &out.writer);
        try out.writer.print(",\"saved_suppressed\":{},\"limit\":{d}", .{ self.saved_suppressed, workspace_access.max_additional_directories });
        if (self.mutation) |mutation| {
            if (mutation.path) |path| {
                try out.writer.writeAll(",\"path\":");
                try std.json.Stringify.value(path, .{}, &out.writer);
            }
            try out.writer.print(",\"saved_changed\":{},\"runtime_changed\":{},\"launch_flag_can_restore\":{}", .{
                mutation.saved_changed,
                mutation.runtime_changed,
                mutation.launch_flag_can_restore,
            });
        }
        try out.writer.writeAll(",\"additional_directories\":[");
        for (self.additional_directories, 0..) |entry, index| {
            if (index > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"path\":");
            try std.json.Stringify.value(entry.path, .{}, &out.writer);
            try out.writer.print(",\"saved\":{},\"command_line\":{},\"available\":{},\"active\":{}}}", .{
                entry.saved,
                entry.command_line,
                entry.available,
                entry.active,
            });
        }
        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }
};

fn writeTerminalSafe(writer: *std.Io.Writer, alloc: Allocator, raw: []const u8) !void {
    var encoded = try text_utils.encodeTerminalSafe(alloc, raw, std.math.maxInt(usize));
    defer encoded.deinit(alloc);
    try writer.writeAll(encoded.bytes);
}

fn gatewayProviderConnected(auth: auth_runtime.StatusSnapshot) bool {
    const source = auth.active_source orelse return auth.gateway_connected;
    return auth.gateway_connected or (source != .chatgpt_subscription and source != .grok_subscription);
}

fn chatGptProviderConnected(auth: auth_runtime.StatusSnapshot) bool {
    return auth.chatgpt_connected or auth.active_source == .chatgpt_subscription;
}

fn grokProviderConnected(auth: auth_runtime.StatusSnapshot) bool {
    return auth.grok_connected or auth.active_source == .grok_subscription;
}

fn writeConnectedProvidersText(writer: *std.Io.Writer, auth: auth_runtime.StatusSnapshot) !void {
    var wrote_provider = false;
    if (gatewayProviderConnected(auth)) {
        try writer.writeAll("BYOK Responses");
        wrote_provider = true;
    }
    if (chatGptProviderConnected(auth)) {
        if (wrote_provider) try writer.writeAll(", Codex");
        if (!wrote_provider) try writer.writeAll("Codex");
        wrote_provider = true;
    }
    if (grokProviderConnected(auth)) {
        if (wrote_provider) try writer.writeAll(", Grok");
        if (!wrote_provider) try writer.writeAll("Grok");
        wrote_provider = true;
    }
    if (!wrote_provider) try writer.writeAll("none");
}

pub const StatusSnapshot = struct {
    model: []const u8,
    provider: model_provider.ProviderId = .gateway,
    auth: auth_runtime.StatusSnapshot = .{},
    auth_help: ?[]const u8 = null,
    permission_mode: types.PermissionMode,
    workspace_root: []const u8,
    history_turns: usize,
    session_permission_grants: usize,
    agent_step_limit: usize,

    pub fn render(self: StatusSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: StatusSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("[status] model={s}\n", .{self.model});
        if (self.provider != .gateway) {
            try out.writer.print("[status] model_source={s}\n", .{provider_catalog.label(self.provider)});
        }
        try out.writer.print("[status] auth={s}\n", .{self.auth.activeSourceLabel()});
        if (self.provider != .gateway) {
            try out.writer.writeAll("[status] connected_providers=");
            try writeConnectedProvidersText(&out.writer, self.auth);
            try out.writer.writeByte('\n');
        }
        try out.writer.print("[status] auth_refreshable={}\n", .{self.auth.refreshable()});
        if (self.auth.expired) try out.writer.writeAll("[status] auth_expired=true\n");
        if (self.auth_help) |help| {
            try out.writer.print("[status] auth_help={s}\n", .{help});
        }
        try out.writer.print("[status] permission_mode={s}\n", .{permissionModeLabel(self.permission_mode)});
        try out.writer.print("[status] workspace={s}\n", .{self.workspace_root});
        try out.writer.print("[status] history_turns={d}\n", .{self.history_turns});
        try out.writer.print("[status] session_permission_grants={d}\n", .{self.session_permission_grants});
        try out.writer.print("[status] agent_step_limit={d}\n", .{self.agent_step_limit});
        return try out.toOwnedSlice();
    }

    pub fn renderInteractiveBody(self: StatusSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("model={s}\n", .{self.model});
        if (self.provider != .gateway) {
            try out.writer.print("model_source={s}\n", .{provider_catalog.label(self.provider)});
        }
        try out.writer.print("auth={s}\n", .{self.auth.activeSourceLabel()});
        if (self.provider != .gateway) {
            try out.writer.writeAll("connected_providers=");
            try writeConnectedProvidersText(&out.writer, self.auth);
            try out.writer.writeByte('\n');
        }
        try out.writer.print("auth_refreshable={}\n", .{self.auth.refreshable()});
        if (self.auth.expired) try out.writer.writeAll("auth_expired=true\n");
        if (self.auth_help) |help| try out.writer.print("auth_help={s}\n", .{help});
        try out.writer.print("permission_mode={s}\n", .{permissionModeLabel(self.permission_mode)});
        try out.writer.print("workspace={s}\n", .{self.workspace_root});
        try out.writer.print("history_turns={d}\n", .{self.history_turns});
        try out.writer.print("session_permission_grants={d}\n", .{self.session_permission_grants});
        try out.writer.print("agent_step_limit={d}", .{self.agent_step_limit});
        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: StatusSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try self.writeJson(&out.writer);
        return try out.toOwnedSlice();
    }

    pub fn writeJson(self: StatusSnapshot, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"kind\":\"status\",\"model\":");
        try std.json.Stringify.value(self.model, .{}, writer);
        if (self.provider != .gateway) {
            try writer.writeAll(",\"model_source\":");
            try std.json.Stringify.value(provider_catalog.label(self.provider), .{}, writer);
        }
        try writer.writeAll(",\"auth\":");
        try std.json.Stringify.value(self.auth.activeSourceLabel(), .{}, writer);
        if (self.provider != .gateway) {
            try writer.writeAll(",\"connected_providers\":[");
            var wrote_provider = false;
            if (gatewayProviderConnected(self.auth)) {
                try std.json.Stringify.value("byok-responses", .{}, writer);
                wrote_provider = true;
            }
            if (chatGptProviderConnected(self.auth)) {
                if (wrote_provider) try writer.writeByte(',');
                try std.json.Stringify.value("codex", .{}, writer);
                wrote_provider = true;
            }
            if (grokProviderConnected(self.auth)) {
                if (wrote_provider) try writer.writeByte(',');
                try std.json.Stringify.value("grok", .{}, writer);
            }
            try writer.writeByte(']');
        }
        try writer.print(",\"auth_refreshable\":{}", .{self.auth.refreshable()});
        if (self.auth.expired) try writer.writeAll(",\"auth_expired\":true");
        if (self.auth_help) |help| {
            try writer.writeAll(",\"auth_help\":");
            try std.json.Stringify.value(help, .{}, writer);
        }
        try writer.writeAll(",\"permission_mode\":");
        try std.json.Stringify.value(permissionModeLabel(self.permission_mode), .{}, writer);
        try writer.writeAll(",\"workspace\":");
        try std.json.Stringify.value(self.workspace_root, .{}, writer);
        try writer.print(",\"history_turns\":{d}", .{self.history_turns});
        try writer.print(",\"session_permission_grants\":{d}", .{self.session_permission_grants});
        try writer.print(",\"agent_step_limit\":{d}", .{self.agent_step_limit});
        try writer.writeByte('}');
    }
};

pub const PermissionsSnapshot = struct {
    workspace_root: []const u8,
    mode: types.PermissionMode,
    grants: []const types.PermissionGrant,
    rules: types.PermissionRuleSet = .{},
    runtime_grants_available: bool = true,

    pub fn render(self: PermissionsSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: PermissionsSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("[permissions] mode={s}\n", .{permissionModeLabel(self.mode)});
        try writePermissionRulesText(&out.writer, self.rules);
        if (self.grants.len == 0) {
            try out.writer.writeAll("[permissions] session grants: (none)\n");
            return try out.toOwnedSlice();
        }

        try out.writer.writeAll("[permissions] session grants:\n");
        for (self.grants) |grant| {
            const display_target = try displayGrantTarget(alloc, self.workspace_root, grant);
            defer alloc.free(display_target);
            try out.writer.print(" - {s} -> {s}\n", .{ grant.tool_name, display_target });
        }

        return try out.toOwnedSlice();
    }

    pub fn renderInteractiveBody(self: PermissionsSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("mode={s}\n", .{permissionModeLabel(self.mode)});
        if (self.rules.rules.len == 0) {
            try out.writer.writeAll("configured rules: (none)\n");
        } else {
            try out.writer.writeAll("configured rules:\n");
            for (self.rules.rules) |rule| {
                try out.writer.print(" - {s} {s} -> {s}\n", .{ @tagName(rule.action), rule.permission, rule.pattern });
            }
        }
        if (self.grants.len == 0) {
            try out.writer.writeAll("session grants: (none)");
            return try out.toOwnedSlice();
        }
        try out.writer.writeAll("session grants:\n");
        for (self.grants, 0..) |grant, index| {
            const display_target = try displayGrantTarget(alloc, self.workspace_root, grant);
            defer alloc.free(display_target);
            try out.writer.print(" - {s} -> {s}", .{ grant.tool_name, display_target });
            if (index + 1 < self.grants.len) try out.writer.writeByte('\n');
        }
        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: PermissionsSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("{\"kind\":\"permissions\",\"mode\":");
        try std.json.Stringify.value(permissionModeLabel(self.mode), .{}, &out.writer);
        try out.writer.print(",\"grant_count\":{d}", .{self.grants.len});
        try out.writer.writeAll(",\"grant_scope\":\"session\"");
        try out.writer.print(",\"runtime_grants_available\":{}", .{self.runtime_grants_available});
        try out.writer.writeAll(",\"rules_scope\":\"persistent_config\",\"rules\":");
        try writePermissionRulesJson(&out.writer, self.rules);
        try out.writer.writeAll(",\"grants\":[");

        for (self.grants, 0..) |grant, i| {
            if (i > 0) try out.writer.writeByte(',');

            const display_target = try displayGrantTarget(alloc, self.workspace_root, grant);
            defer alloc.free(display_target);

            try out.writer.writeAll("{\"tool_name\":");
            try std.json.Stringify.value(grant.tool_name, .{}, &out.writer);
            try out.writer.writeAll(",\"target_path\":");
            try std.json.Stringify.value(grant.target_path, .{}, &out.writer);
            try out.writer.writeAll(",\"display_target\":");
            try std.json.Stringify.value(display_target, .{}, &out.writer);
            try out.writer.writeByte('}');
        }

        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }
};

pub const ModelListSnapshot = struct {
    ids: []const []const u8,
    provider: model_provider.ProviderId = .gateway,
    limit: ?usize = null,
    private_models_hidden: bool = false,
    public_only_reason: ?credentials.CatalogPublicOnlyReason = null,

    pub fn render(self: ModelListSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: ModelListSnapshot, alloc: Allocator) ![]u8 {
        if (self.ids.len == 0) {
            const provider_name = self.emptyCatalogProviderName();
            if (self.catalogExplanation()) |explanation| {
                return std.fmt.allocPrint(alloc, "[models] no models returned by {s}\n[models] {s}\n", .{ provider_name, explanation });
            }
            return std.fmt.allocPrint(alloc, "[models] no models returned by {s}\n", .{provider_name});
        }

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("[models] {d} available\n", .{self.ids.len});

        const shown = self.shownCount();
        for (self.ids[0..shown]) |id| {
            if (self.provider != .gateway) {
                try out.writer.print(" - {s} · {s}\n", .{ id, provider_catalog.label(self.provider) });
            } else {
                try out.writer.print(" - {s}\n", .{id});
            }
        }
        if (self.ids.len > shown) {
            try out.writer.print(" ... and {d} more\n", .{self.ids.len - shown});
        }
        if (self.catalogExplanation()) |explanation| try out.writer.print("[models] {s}\n", .{explanation});

        return try out.toOwnedSlice();
    }

    pub fn renderInteractiveBody(self: ModelListSnapshot, alloc: Allocator) ![]u8 {
        if (self.ids.len == 0) {
            const provider_name = self.emptyCatalogProviderName();
            if (self.catalogExplanation()) |explanation| {
                return std.fmt.allocPrint(alloc, "no models returned by {s}\n{s}", .{ provider_name, explanation });
            }
            return std.fmt.allocPrint(alloc, "no models returned by {s}", .{provider_name});
        }

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.print("{d} available", .{self.ids.len});
        const shown = self.shownCount();
        for (self.ids[0..shown]) |id| {
            if (self.provider != .gateway) {
                try out.writer.print("\n - {s} · {s}", .{ id, provider_catalog.label(self.provider) });
            } else {
                try out.writer.print("\n - {s}", .{id});
            }
        }
        if (self.ids.len > shown) try out.writer.print("\n ... and {d} more", .{self.ids.len - shown});
        if (self.catalogExplanation()) |explanation| try out.writer.print("\n{s}", .{explanation});
        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: ModelListSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        const shown = self.shownCount();
        try out.writer.print(
            "{{\"kind\":\"models\",\"count\":{d},\"shown_count\":{d},\"more_count\":{d},\"private_models_hidden\":{},\"ids\":[",
            .{ self.ids.len, shown, self.ids.len - shown, self.private_models_hidden },
        );
        for (self.ids[0..shown], 0..) |id, i| {
            if (i > 0) try out.writer.writeByte(',');
            try std.json.Stringify.value(id, .{}, &out.writer);
        }
        if (self.provider != .gateway) {
            try out.writer.writeAll("],\"models\":[");
            for (self.ids[0..shown], 0..) |id, i| {
                if (i > 0) try out.writer.writeByte(',');
                try out.writer.writeAll("{\"id\":");
                try std.json.Stringify.value(id, .{}, &out.writer);
                try out.writer.writeAll(",\"source\":");
                try std.json.Stringify.value(provider_catalog.label(self.provider), .{}, &out.writer);
                try out.writer.writeByte('}');
            }
        }
        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }

    fn shownCount(self: ModelListSnapshot) usize {
        return if (self.limit) |value| @min(self.ids.len, value) else self.ids.len;
    }

    fn emptyCatalogProviderName(self: ModelListSnapshot) []const u8 {
        return switch (self.provider) {
            .gateway => "gateway",
            .codex => provider_catalog.label(.codex),
            .grok => provider_catalog.label(.grok),
        };
    }

    fn catalogExplanation(self: ModelListSnapshot) ?[]const u8 {
        if (!self.private_models_hidden) return null;
        const reason = self.public_only_reason orelse return "Using the public model catalog.";
        return switch (reason) {
            .no_credential => "Using the public model catalog; set OPENAI_API_KEY for authenticated BYOK models.",
            .credential_refresh_failed => "Credential refresh failed; using the public model catalog.",
        };
    }
};

pub const SessionListSnapshot = struct {
    sessions: []const session_store.SessionSummary,
    has_more: bool = false,
    next_cursor: ?[]const u8 = null,
    skipped_invalid: usize = 0,
    all_workspaces: bool = false,

    pub fn render(self: SessionListSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: SessionListSnapshot, alloc: Allocator) ![]u8 {
        if (self.sessions.len == 0 and self.skipped_invalid == 0) {
            return std.fmt.allocPrint(alloc, "[sessions] no saved sessions\n", .{});
        }

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        if (self.sessions.len == 0) {
            try out.writer.writeAll("[sessions] no readable saved sessions\n");
        } else {
            try out.writer.print("[sessions] {d} saved\n", .{self.sessions.len});
            for (self.sessions) |entry| {
                try out.writer.writeAll(" - ");
                try writeTerminalSafe(
                    &out.writer,
                    alloc,
                    entry.title orelse session_display_metadata.fallback_title,
                );
                try out.writer.writeByte('\n');
                try writeSessionListDetails(&out.writer, alloc, entry);
            }
        }
        if (self.has_more) {
            try out.writer.print(
                "[sessions] more saved sessions; continue with `fx sessions {s}--cursor {s}`\n",
                .{ if (self.all_workspaces) "--all " else "", self.next_cursor orelse "" },
            );
        }
        if (self.skipped_invalid > 0) {
            try out.writer.print(
                "[sessions] warning: skipped {d} unreadable saved session{s}; run `fx doctor` for recovery guidance\n",
                .{ self.skipped_invalid, if (self.skipped_invalid == 1) "" else "s" },
            );
        }

        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: SessionListSnapshot, alloc: Allocator) ![]u8 {
        if (self.sessions.len == 0 and self.skipped_invalid == 0) {
            return alloc.dupe(u8, "{\"kind\":\"sessions\",\"count\":0,\"sessions\":[]}");
        }

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print("{{\"kind\":\"sessions\",\"count\":{d}", .{self.sessions.len});
        if (self.skipped_invalid > 0) {
            try out.writer.print(",\"skipped_invalid\":{d}", .{self.skipped_invalid});
        }
        if (self.has_more) {
            try out.writer.writeAll(",\"has_more\":true,\"next_cursor\":");
            try std.json.Stringify.value(self.next_cursor orelse "", .{}, &out.writer);
        }
        try out.writer.writeAll(",\"sessions\":[");
        for (self.sessions, 0..) |entry, i| {
            if (i > 0) try out.writer.writeByte(',');
            try out.writer.writeAll("{\"id\":");
            try std.json.Stringify.value(entry.id, .{}, &out.writer);
            try writeSessionDisplayJsonFields(&out.writer, entry);
            try out.writer.print(",\"created_at_ms\":{d},\"updated_at_ms\":{d},\"history_len\":{d}", .{ entry.created_at_ms, entry.updated_at_ms, entry.history_len });
            try out.writer.writeAll(",\"conversation_language\":");
            try std.json.Stringify.value(entry.conversation_language.view(), .{}, &out.writer);
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }
};

fn writeSessionListDetails(
    writer: *std.Io.Writer,
    alloc: Allocator,
    entry: session_store.SessionSummary,
) !void {
    try writer.print(
        "   id={s} | {d} turn{s}",
        .{ entry.id, entry.history_len, if (entry.history_len == 1) "" else "s" },
    );
    if (sessionLanguageLabel(entry.conversation_language.view())) |label| {
        try writer.writeAll(" | ");
        try writeTerminalSafe(writer, alloc, label);
    }
    try writer.writeAll(" | updated ");
    try writeUtcTimestamp(writer, entry.updated_at_ms);
    try writer.writeByte('\n');
}

fn sessionLanguageLabel(tag: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(tag, "und")) return null;

    if (tag.len > 4 and std.ascii.eqlIgnoreCase(tag[0..4], "und-")) {
        const script = tag[4..];
        if (std.ascii.eqlIgnoreCase(script, "Latn")) return "Latin script";
        if (std.ascii.eqlIgnoreCase(script, "Hani")) return "Han script";
        if (std.ascii.eqlIgnoreCase(script, "Arab")) return "Arabic script";
        if (std.ascii.eqlIgnoreCase(script, "Hebr")) return "Hebrew script";
        if (std.ascii.eqlIgnoreCase(script, "Cyrl")) return "Cyrillic script";
        if (std.ascii.eqlIgnoreCase(script, "Grek")) return "Greek script";
        if (std.ascii.eqlIgnoreCase(script, "Deva")) return "Devanagari script";
        if (std.ascii.eqlIgnoreCase(script, "Thai")) return "Thai script";
        return tag;
    }

    const separator = std.mem.findScalar(u8, tag, '-') orelse tag.len;
    const primary = tag[0..separator];
    if (std.ascii.eqlIgnoreCase(primary, "en")) return "English";
    if (std.ascii.eqlIgnoreCase(primary, "es")) return "Spanish";
    if (std.ascii.eqlIgnoreCase(primary, "fr")) return "French";
    if (std.ascii.eqlIgnoreCase(primary, "de")) return "German";
    if (std.ascii.eqlIgnoreCase(primary, "it")) return "Italian";
    if (std.ascii.eqlIgnoreCase(primary, "pt")) return "Portuguese";
    if (std.ascii.eqlIgnoreCase(primary, "ja")) return "Japanese";
    if (std.ascii.eqlIgnoreCase(primary, "ko")) return "Korean";
    if (std.ascii.eqlIgnoreCase(primary, "zh")) return "Chinese";
    if (std.ascii.eqlIgnoreCase(primary, "ar")) return "Arabic";
    if (std.ascii.eqlIgnoreCase(primary, "he")) return "Hebrew";
    if (std.ascii.eqlIgnoreCase(primary, "ru")) return "Russian";
    if (std.ascii.eqlIgnoreCase(primary, "el")) return "Greek";
    if (std.ascii.eqlIgnoreCase(primary, "hi")) return "Hindi";
    if (std.ascii.eqlIgnoreCase(primary, "th")) return "Thai";
    return tag;
}

fn writeUtcTimestamp(writer: *std.Io.Writer, timestamp_ms: i64) !void {
    const max_supported_timestamp_ms: i64 = 253_402_300_799_999;
    if (timestamp_ms < 0 or timestamp_ms > max_supported_timestamp_ms) {
        try writer.writeAll("unknown");
        return;
    }

    const epoch_secs: u64 = @intCast(@divTrunc(timestamp_ms, std.time.ms_per_s));
    const milliseconds: u16 = @intCast(@mod(timestamp_ms, std.time.ms_per_s));
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    try writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} UTC", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
        milliseconds,
    });
}

pub const SessionSummarySnapshot = struct {
    summary: session_store.SessionSummary,

    pub fn render(self: SessionSummarySnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: SessionSummarySnapshot, alloc: Allocator) ![]u8 {
        return std.fmt.allocPrint(
            alloc,
            "[session] {s}\ncreated_at_ms: {d}\nupdated_at_ms: {d}\nlanguage: {s}\nhistory_len: {d}\n",
            .{
                self.summary.id,
                self.summary.created_at_ms,
                self.summary.updated_at_ms,
                self.summary.conversation_language.view(),
                self.summary.history_len,
            },
        );
    }

    pub fn renderJson(self: SessionSummarySnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("{\"kind\":\"session_summary\",\"id\":");
        try std.json.Stringify.value(self.summary.id, .{}, &out.writer);
        try writeSessionDisplayJsonFields(&out.writer, self.summary);
        try out.writer.print(
            ",\"created_at_ms\":{d},\"updated_at_ms\":{d},\"history_len\":{d},\"conversation_language\":",
            .{
                self.summary.created_at_ms,
                self.summary.updated_at_ms,
                self.summary.history_len,
            },
        );
        try std.json.Stringify.value(
            self.summary.conversation_language.view(),
            .{},
            &out.writer,
        );
        try out.writer.writeByte('}');
        return out.toOwnedSlice();
    }
};

fn writeSessionDisplayJsonFields(writer: *std.Io.Writer, summary: session_store.SessionSummary) !void {
    try writer.writeAll(",\"title\":");
    try std.json.Stringify.value(
        summary.title orelse session_display_metadata.fallback_title,
        .{},
        writer,
    );
    try writer.writeAll(",\"preview\":");
    if (summary.preview) |preview| {
        try std.json.Stringify.value(preview, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"workspace_root\":");
    if (summary.workspace_root) |workspace_root| {
        try std.json.Stringify.value(workspace_root, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"origin_workspace_root\":");
    if (summary.origin_workspace_root) |origin_workspace_root| {
        try std.json.Stringify.value(origin_workspace_root, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

pub const SessionDetailSnapshot = struct {
    detail: session_store.ReadOnlyDetail,

    pub fn render(self: SessionDetailSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: SessionDetailSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        const state = self.detail.state;
        try out.writer.print("[session] {s}\n", .{state.id});
        try out.writer.print("created_at_ms: {d}\n", .{state.created_at_ms});
        try out.writer.print("updated_at_ms: {d}\n", .{state.updated_at_ms});
        try out.writer.print("language: {s}\n", .{state.conversation_language.view()});
        try out.writer.print("history_len: {d}\n", .{state.history.len});

        if (state.history.len == 0) {
            try out.writer.writeAll("\n(no history yet)\n");
            return try out.toOwnedSlice();
        }

        for (state.history, 0..) |turn, i| {
            try out.writer.print("\n[turn {d}]\n", .{i + 1});
            try writeSessionHistoryTurnText(&out.writer, turn);
        }

        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: SessionDetailSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        const state = self.detail.state;
        try out.writer.writeAll("{\"kind\":\"session_detail\",\"id\":");
        try std.json.Stringify.value(state.id, .{}, &out.writer);
        try out.writer.print(",\"created_at_ms\":{d},\"updated_at_ms\":{d},\"history_len\":{d}", .{ state.created_at_ms, state.updated_at_ms, state.history.len });
        try out.writer.writeAll(",\"conversation_language\":");
        try std.json.Stringify.value(state.conversation_language.view(), .{}, &out.writer);
        try out.writer.writeAll(",\"history\":[");

        for (state.history, 0..) |turn, i| {
            if (i > 0) try out.writer.writeByte(',');
            try writeSessionHistoryTurnJson(&out.writer, turn);
        }

        try out.writer.writeAll("]}");
        return try out.toOwnedSlice();
    }
};

pub const SessionMigrationSnapshot = struct {
    result: session_store.SessionMigrationResult,

    pub fn render(self: SessionMigrationSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: SessionMigrationSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.print(
            "[session migration] {s}\nstatus: {s}\nsource_schema_version: {d}\nsource_bytes: {d}\n",
            .{
                self.result.session_id,
                sessionMigrationStatusLabel(self.result.status),
                self.result.source_schema_version,
                self.result.source_bytes,
            },
        );
        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: SessionMigrationSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try out.writer.writeAll("{\"kind\":\"session_migration\",\"id\":");
        try std.json.Stringify.value(self.result.session_id, .{}, &out.writer);
        try out.writer.writeAll(",\"status\":");
        try std.json.Stringify.value(sessionMigrationStatusLabel(self.result.status), .{}, &out.writer);
        try out.writer.print(
            ",\"source_schema_version\":{d},\"source_bytes\":{d}}}",
            .{ self.result.source_schema_version, self.result.source_bytes },
        );
        return try out.toOwnedSlice();
    }
};

fn sessionMigrationStatusLabel(status: session_store.SessionMigrationStatus) []const u8 {
    return switch (status) {
        .migrated => "migrated",
        .already_current => "already_current",
    };
}

pub const SessionRecoverySnapshot = struct {
    result: session_store.SessionRecoveryResult,

    pub fn render(
        self: SessionRecoverySnapshot,
        alloc: Allocator,
        format: OutputFormat,
    ) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(
        self: SessionRecoverySnapshot,
        alloc: Allocator,
    ) ![]u8 {
        if (self.result.status == .indeterminate) {
            return std.fmt.allocPrint(
                alloc,
                "[session recovery] could not confirm target {s}\nsource: {s} (unchanged)\nresolve: fx --resume {s}\ninspect: fx doctor\n",
                .{
                    self.result.recovered_session_id,
                    self.result.source_session_id,
                    self.result.recovered_session_id,
                },
            );
        }
        if (self.result.status == .recovered_with_unverified_artifacts) {
            return std.fmt.allocPrint(
                alloc,
                "[session recovery] copied {s} to {s}\nhistory_turns: {d}\nwarning: legacy command artifacts could not be authenticated\nresume: fx --resume {s}\n",
                .{
                    self.result.source_session_id,
                    self.result.recovered_session_id,
                    self.result.history_len,
                    self.result.recovered_session_id,
                },
            );
        }
        return std.fmt.allocPrint(
            alloc,
            "[session recovery] copied {s} to {s}\nhistory_turns: {d}\nresume: fx --resume {s}\n",
            .{
                self.result.source_session_id,
                self.result.recovered_session_id,
                self.result.history_len,
                self.result.recovered_session_id,
            },
        );
    }

    pub fn renderJson(
        self: SessionRecoverySnapshot,
        alloc: Allocator,
    ) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll(
            "{\"kind\":\"session_recovery\",\"source_id\":",
        );
        try std.json.Stringify.value(
            self.result.source_session_id,
            .{},
            &out.writer,
        );
        try out.writer.writeAll(",\"recovered_id\":");
        try std.json.Stringify.value(
            self.result.recovered_session_id,
            .{},
            &out.writer,
        );
        try out.writer.writeAll(",\"status\":");
        try std.json.Stringify.value(
            @tagName(self.result.status),
            .{},
            &out.writer,
        );
        try out.writer.print(
            ",\"history_turns\":{d}}}",
            .{self.result.history_len},
        );
        return try out.toOwnedSlice();
    }
};

pub const DoctorSnapshot = struct {
    workspace_root: []const u8,
    model: []const u8,
    provider: model_provider.ProviderId = .gateway,
    auth: auth_runtime.StatusSnapshot = .{},
    permission_mode: types.PermissionMode,
    agent_step_limit: usize,
    checks: []const doctor_runtime.Check,

    pub fn render(self: DoctorSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: DoctorSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        const counts = countDoctorChecks(self.checks);
        try out.writer.print(
            "[doctor] ok={d} warn={d} fail={d}\n",
            .{ counts.ok, counts.warn, counts.fail },
        );
        try out.writer.print("[doctor] workspace={s}\n", .{self.workspace_root});
        try out.writer.print("[doctor] model={s}\n", .{self.model});
        if (self.provider != .gateway) {
            try out.writer.print("[doctor] model_source={s}\n", .{provider_catalog.label(self.provider)});
        }
        try out.writer.print("[doctor] auth={s}\n", .{self.auth.activeSourceLabel()});
        try out.writer.print("[doctor] auth_refreshable={}\n", .{self.auth.refreshable()});
        if (self.auth.expired) try out.writer.writeAll("[doctor] auth_expired=true\n");
        try out.writer.print("[doctor] permission_mode={s}\n", .{permissionModeLabel(self.permission_mode)});
        try out.writer.print("[doctor] agent_step_limit={d}\n", .{self.agent_step_limit});

        for (self.checks) |entry| {
            try out.writer.print("[{s}] ", .{checkStatusLabel(entry.status)});
            try writeTerminalSafe(&out.writer, alloc, entry.name);
            try out.writer.writeAll(": ");
            try writeTerminalSafe(&out.writer, alloc, entry.detail);
            try out.writer.writeByte('\n');
        }

        return try out.toOwnedSlice();
    }

    pub fn renderJson(self: DoctorSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        try self.writeJson(&out.writer);
        return try out.toOwnedSlice();
    }

    pub fn writeJson(self: DoctorSnapshot, writer: *std.Io.Writer) !void {
        const counts = countDoctorChecks(self.checks);
        try writer.print(
            "{{\"kind\":\"doctor\",\"ok_count\":{d},\"warn_count\":{d},\"fail_count\":{d}",
            .{ counts.ok, counts.warn, counts.fail },
        );
        try writer.writeAll(",\"workspace\":");
        try std.json.Stringify.value(self.workspace_root, .{}, writer);
        try writer.writeAll(",\"model\":");
        try std.json.Stringify.value(self.model, .{}, writer);
        if (self.provider != .gateway) {
            try writer.writeAll(",\"model_source\":");
            try std.json.Stringify.value(provider_catalog.label(self.provider), .{}, writer);
        }
        try writer.writeAll(",\"auth\":");
        try std.json.Stringify.value(self.auth.activeSourceLabel(), .{}, writer);
        try writer.print(",\"auth_refreshable\":{}", .{self.auth.refreshable()});
        if (self.auth.expired) try writer.writeAll(",\"auth_expired\":true");
        try writer.writeAll(",\"permission_mode\":");
        try std.json.Stringify.value(permissionModeLabel(self.permission_mode), .{}, writer);
        try writer.print(",\"agent_step_limit\":{d},\"checks\":[", .{self.agent_step_limit});

        for (self.checks, 0..) |entry, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.writeAll("{\"name\":");
            try std.json.Stringify.value(entry.name, .{}, writer);
            try writer.writeAll(",\"status\":");
            try std.json.Stringify.value(checkStatusLabel(entry.status), .{}, writer);
            try writer.writeAll(",\"detail\":");
            try std.json.Stringify.value(entry.detail, .{}, writer);
            try writer.writeByte('}');
        }

        try writer.writeByte(']');
        try writer.writeByte('}');
    }
};

pub const CodexAccountUsageSnapshot = struct {
    data: ?codex_usage.Snapshot = null,
    failure: ?codex_usage.Failure = null,

    pub fn deinit(self: *CodexAccountUsageSnapshot, _: Allocator) void {
        if (self.data) |*data| data.deinit();
        self.* = undefined;
    }

    pub fn render(
        self: *const CodexAccountUsageSnapshot,
        alloc: Allocator,
        format: OutputFormat,
    ) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => self.renderJson(alloc),
        };
    }

    pub fn renderText(self: *const CodexAccountUsageSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        if (self.failure) |failure| {
            try out.writer.print("[codex usage] error: {s}", .{codexUsageFailureMessage(failure.kind)});
            if (failure.http_status) |status| {
                try out.writer.print(" (HTTP {d})", .{@intFromEnum(status)});
            }
            try out.writer.writeByte('\n');
            return out.toOwnedSlice();
        }
        const data = self.data orelse {
            try out.writer.writeAll("[codex usage] no data returned\n");
            return out.toOwnedSlice();
        };

        try out.writer.writeAll("Codex account usage\n");
        try out.writer.print("Fetched at (ms): {d}\n", .{data.fetched_at_ms});
        try out.writer.writeAll("Plan: ");
        try writeTerminalSafe(&out.writer, alloc, data.plan_type);
        try out.writer.writeByte('\n');
        try out.writer.writeAll("Rate limits:\n");
        for (data.rate_limits) |limit| {
            try out.writer.writeAll("  ");
            try writeTerminalSafe(&out.writer, alloc, limit.id);
            if (limit.name) |name| {
                try out.writer.writeAll(" (");
                try writeTerminalSafe(&out.writer, alloc, name);
                try out.writer.writeByte(')');
            }
            if (limit.allowed) |allowed| {
                try out.writer.print(" allowed={s}", .{if (allowed) "true" else "false"});
            }
            if (limit.limit_reached) |reached| {
                try out.writer.print(" limit_reached={s}", .{if (reached) "true" else "false"});
            }
            try out.writer.writeByte('\n');
            if (limit.primary_window) |window| {
                try writeCodexUsageWindowText(&out.writer, "primary", window);
            }
            if (limit.secondary_window) |window| {
                try writeCodexUsageWindowText(&out.writer, "secondary", window);
            }
        }
        if (data.credits) |credits| {
            try out.writer.print("Credits: has_credits={s} unlimited={s}", .{
                if (credits.has_credits) "true" else "false",
                if (credits.unlimited) "true" else "false",
            });
            if (credits.balance) |balance| {
                try out.writer.writeAll(" balance=");
                try writeTerminalSafe(&out.writer, alloc, balance);
            }
            try out.writer.writeByte('\n');
        }
        if (data.spend_control) |control| {
            try out.writer.print("Spend control: reached={s}\n", .{if (control.reached) "true" else "false"});
            if (control.individual_limit) |limit| {
                if (limit.source) |source| {
                    try out.writer.writeAll("  source=");
                    try writeTerminalSafe(&out.writer, alloc, source);
                    try out.writer.writeByte('\n');
                }
                try out.writer.writeAll("  individual limit=");
                try writeTerminalSafe(&out.writer, alloc, limit.limit);
                try out.writer.writeAll(" used=");
                try writeTerminalSafe(&out.writer, alloc, limit.used);
                try out.writer.writeAll(" remaining=");
                try writeTerminalSafe(&out.writer, alloc, limit.remaining);
                try out.writer.print(
                    " used_percent={d} remaining_percent={d} reset_after_seconds={d} reset_at={d}\n",
                    .{
                        limit.used_percent,
                        limit.remaining_percent,
                        limit.reset_after_seconds,
                        limit.reset_at,
                    },
                );
            }
        }
        if (data.rate_limit_reached_type) |reached_type| {
            try out.writer.writeAll("Rate limit reached type: ");
            try writeTerminalSafe(&out.writer, alloc, reached_type);
            try out.writer.writeByte('\n');
        }
        if (data.rate_limit_reset_credits_available) |available| {
            try out.writer.print("Rate limit reset credits: {d}\n", .{available});
        }

        const stats = data.token_usage;
        try out.writer.writeAll("Token activity:");
        var wrote_stat = false;
        inline for (.{
            .{ "lifetime_tokens", stats.lifetime_tokens },
            .{ "peak_daily_tokens", stats.peak_daily_tokens },
            .{ "longest_running_turn_sec", stats.longest_running_turn_sec },
            .{ "current_streak_days", stats.current_streak_days },
            .{ "longest_streak_days", stats.longest_streak_days },
        }) |field| {
            if (field[1]) |value| {
                try out.writer.print(" {s}={d}", .{ field[0], value });
                wrote_stat = true;
            }
        }
        if (!wrote_stat) try out.writer.writeAll(" unavailable");
        try out.writer.writeByte('\n');
        for (data.daily_usage_buckets) |bucket| {
            try out.writer.writeAll("  ");
            try writeTerminalSafe(&out.writer, alloc, bucket.start_date);
            try out.writer.print(": {d} tokens\n", .{bucket.tokens});
        }
        return out.toOwnedSlice();
    }

    pub fn renderJson(self: *const CodexAccountUsageSnapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        if (self.failure) |failure| {
            try out.writer.writeAll("{\"kind\":\"codex_account_usage\",\"schema_version\":1,\"error\":{\"code\":");
            try std.json.Stringify.value(@tagName(failure.kind), .{}, &out.writer);
            try out.writer.writeAll(",\"http_status\":");
            if (failure.http_status) |status| {
                try out.writer.print("{d}", .{@intFromEnum(status)});
            } else {
                try out.writer.writeAll("null");
            }
            try out.writer.writeAll("}}");
            return out.toOwnedSlice();
        }
        const data = self.data orelse {
            try out.writer.writeAll("{\"kind\":\"codex_account_usage\",\"schema_version\":1,\"error\":{\"code\":\"invalid_response\",\"http_status\":null}}");
            return out.toOwnedSlice();
        };
        try std.json.Stringify.value(.{
            .kind = "codex_account_usage",
            .schema_version = @as(u8, 1),
            .fetched_at_ms = data.fetched_at_ms,
            .plan_type = data.plan_type,
            .rate_limits = data.rate_limits,
            .credits = data.credits,
            .spend_control = data.spend_control,
            .rate_limit_reached_type = data.rate_limit_reached_type,
            .rate_limit_reset_credits_available = data.rate_limit_reset_credits_available,
            .token_usage = data.token_usage,
            .daily_usage_buckets = data.daily_usage_buckets,
        }, .{}, &out.writer);
        return out.toOwnedSlice();
    }
};

fn writeCodexUsageWindowText(
    writer: *std.Io.Writer,
    label: []const u8,
    window: codex_usage.Window,
) !void {
    try writer.print(
        "    {s}: used_percent={d} window_seconds={d} reset_after_seconds={d} reset_at={d}\n",
        .{
            label,
            window.used_percent,
            window.limit_window_seconds,
            window.reset_after_seconds,
            window.reset_at,
        },
    );
}

fn codexUsageFailureMessage(kind: codex_usage.FailureKind) []const u8 {
    return switch (kind) {
        .unsupported_credential_source => "available only with a Codex subscription login",
        .missing_credential => "Codex access token is missing",
        .missing_account_id => "Codex account identity is missing",
        .credential_unavailable => "stored Codex credential is unavailable",
        .credential_changed => "Codex credential changed during the request",
        .unauthorized => "Codex authentication failed",
        .forbidden => "Codex account usage is forbidden",
        .rate_limited => "Codex account usage request was rate limited",
        .http_error => "Codex account usage request failed",
        .invalid_endpoint => "Codex account usage endpoint is invalid",
        .response_too_large => "Codex account usage response is too large",
        .invalid_response => "Codex account usage response is invalid",
        .timeout => "Codex account usage request timed out",
        .cancelled => "Codex account usage request was cancelled",
        .transport => "Codex account usage transport failed",
        .resource_exhausted => "insufficient memory for Codex account usage",
    };
}

fn displayGrantTarget(alloc: Allocator, workspace_root: []const u8, grant: types.PermissionGrant) ![]u8 {
    if (std.mem.eql(u8, grant.tool_name, "run_command") or std.mem.eql(u8, grant.tool_name, "bash")) {
        return alloc.dupe(u8, grant.target_path);
    }

    if (std.fs.path.isAbsolute(grant.target_path)) {
        return std.fs.path.relative(alloc, "/", null, workspace_root, grant.target_path) catch alloc.dupe(u8, grant.target_path);
    }

    return alloc.dupe(u8, grant.target_path);
}

fn writePermissionRulesText(writer: *std.Io.Writer, rules: types.PermissionRuleSet) !void {
    if (rules.rules.len == 0) {
        try writer.writeAll("[permissions] configured rules: (none)\n");
        return;
    }

    try writer.writeAll("[permissions] configured rules:\n");
    for (rules.rules) |rule| {
        try writer.print(" - {s} {s} -> {s}\n", .{ @tagName(rule.action), rule.permission, rule.pattern });
    }
}

fn writePermissionRulesJson(writer: *std.Io.Writer, rules: types.PermissionRuleSet) !void {
    try writer.writeByte('[');
    for (rules.rules, 0..) |rule, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"permission\":");
        try std.json.Stringify.value(rule.permission, .{}, writer);
        try writer.writeAll(",\"pattern\":");
        try std.json.Stringify.value(rule.pattern, .{}, writer);
        try writer.writeAll(",\"action\":");
        try std.json.Stringify.value(@tagName(rule.action), .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

const DoctorCheckCounts = struct {
    ok: usize = 0,
    warn: usize = 0,
    fail: usize = 0,
};

fn countDoctorChecks(checks: []const doctor_runtime.Check) DoctorCheckCounts {
    var counts: DoctorCheckCounts = .{};
    for (checks) |entry| {
        switch (entry.status) {
            .ok => counts.ok += 1,
            .warn => counts.warn += 1,
            .fail => counts.fail += 1,
        }
    }
    return counts;
}

fn checkStatusLabel(status: doctor_runtime.CheckStatus) []const u8 {
    return switch (status) {
        .ok => "ok",
        .warn => "warn",
        .fail => "fail",
    };
}

fn writeSessionHistoryTurnText(writer: *std.Io.Writer, turn: types.HistoryTurn) !void {
    switch (turn) {
        .compacted_summary => |entry| {
            try writer.print("[compacted] removed_turns={d} compactions={d}\n", .{ entry.removed_turn_count, entry.compaction_count });
            try writeTextBlock(writer, entry.summary);
        },
        .assistant => |entry| {
            try writeSessionUserTurnText(writer, entry.user);
            try writeSessionExecutionText(writer, entry.execution);
            try writer.writeAll("[assistant]\n");
            try writeTextBlock(writer, entry.assistant);
        },
        .background_command => |entry| {
            try writeSessionUserTurnText(writer, entry.user);
            try writeSessionExecutionText(writer, entry.execution);
            if (entry.assistant) |assistant| {
                try writer.writeAll("[assistant]\n");
                try writeTextBlock(writer, assistant);
            }
            try writer.writeAll("[background]\n");
            try writer.print("log: {s}\n", .{entry.log_path});
            try writer.print("expect_url: {s}\n", .{if (entry.expect_url) "true" else "false"});
            try writer.print("url: {s}\n", .{entry.url orelse "(none)"});
            if (entry.background_record_id) |record_id| {
                try writer.writeAll("record_id: ");
                try writeHexBytes(writer, &record_id);
                try writer.writeByte('\n');
            }
        },
        .interrupted => |entry| {
            try writeSessionUserTurnText(writer, entry.user);
            try writeSessionExecutionText(writer, entry.execution);
            if (entry.assistant) |assistant| {
                try writer.writeAll("[assistant]\n");
                try writeTextBlock(writer, assistant);
            }
            try writer.writeAll("[interrupted]\n");
            if (entry.tool_call) |tool_call| {
                try writer.print("tool_call_id: {s}\n", .{tool_call.id});
                try writer.print("tool_name: {s}\n", .{tool_call.name});
            } else {
                try writer.writeAll("tool: (none)\n");
            }
            if (entry.completed_tool_names.len > 0) {
                try writer.writeAll("completed_tools: ");
                for (entry.completed_tool_names, 0..) |name, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(name);
                }
                try writer.writeByte('\n');
            }
        },
    }
}

fn writeSessionExecutionText(writer: *std.Io.Writer, execution: types.ExecutionMemory) !void {
    if (execution.isEmpty()) return;

    try writer.writeAll("[execution]\n");
    for (execution.tool_steps) |step| {
        if (step.assistant) |assistant| {
            try writer.writeAll("assistant:\n");
            try writeTextBlock(writer, assistant);
        }
        for (step.tool_calls) |call| {
            try writer.print("tool_call: {s} {s}\n", .{ call.id, call.name });
            try writer.writeAll("arguments:\n");
            try writeTextBlock(writer, call.arguments_json);
        }
        for (step.tool_results) |result| {
            try writer.print(
                "tool_result: {s} {s} {s}\n",
                .{ result.tool_call_id, result.tool_name, @tagName(result.status) },
            );
            try writer.writeAll("output:\n");
            try writeTextBlock(writer, result.output);
        }
    }
    for (execution.files) |file| {
        try writer.print(
            "file: {s} {s} {s}\n",
            .{ @tagName(file.action), @tagName(file.status), file.path },
        );
    }
}

fn writeSessionUserTurnText(writer: *std.Io.Writer, user: types.UserTurn) !void {
    try writer.writeAll("[user]\n");
    try writeTextBlock(writer, user.text);
    if (user.images.len > 0) {
        try writer.print("[images] {d}\n", .{user.images.len});
        for (user.images) |image| {
            try writer.print(" - {s} ({s})\n", .{ image.path, image.media_type });
        }
    }
}

fn writeTextBlock(writer: *std.Io.Writer, text: []const u8) !void {
    if (text.len == 0) {
        try writer.writeAll("(empty)\n");
        return;
    }

    try writer.writeAll(text);
    if (text[text.len - 1] != '\n') try writer.writeByte('\n');
}

fn writeSessionHistoryTurnJson(writer: *std.Io.Writer, turn: types.HistoryTurn) !void {
    switch (turn) {
        .compacted_summary => |entry| {
            try writer.writeAll("{\"kind\":\"compacted_summary\",\"summary\":");
            try std.json.Stringify.value(entry.summary, .{}, writer);
            try writer.print(",\"removed_turn_count\":{d},\"compaction_count\":{d}", .{ entry.removed_turn_count, entry.compaction_count });
            try writer.writeByte('}');
        },
        .assistant => |entry| {
            try writer.writeAll("{\"kind\":\"assistant\",\"user\":");
            try writeSessionUserTurnJson(writer, entry.user);
            try writer.writeAll(",\"assistant\":");
            try std.json.Stringify.value(entry.assistant, .{}, writer);
            try writer.writeAll(",\"execution\":");
            try session_json.writeExecutionMemoryJson(writer, entry.execution);
            try writer.writeByte('}');
        },
        .background_command => |entry| {
            try writer.writeAll("{\"kind\":\"background_command\",\"user\":");
            try writeSessionUserTurnJson(writer, entry.user);
            if (entry.assistant) |assistant| {
                try writer.writeAll(",\"assistant\":");
                try std.json.Stringify.value(assistant, .{}, writer);
            }
            if (!entry.execution.isEmpty()) {
                try writer.writeAll(",\"execution\":");
                try session_json.writeExecutionMemoryJson(writer, entry.execution);
            }
            try writer.writeAll(",\"log_path\":");
            try std.json.Stringify.value(entry.log_path, .{}, writer);
            try writer.print(",\"expect_url\":{s}", .{if (entry.expect_url) "true" else "false"});
            try writer.writeAll(",\"url\":");
            if (entry.url) |url| {
                try std.json.Stringify.value(url, .{}, writer);
            } else {
                try writer.writeAll("null");
            }
            if (entry.background_record_id) |record_id| {
                try writer.writeAll(",\"background_record_id\":\"");
                try writeHexBytes(writer, &record_id);
                try writer.writeByte('"');
            }
            try writer.writeByte('}');
        },
        .interrupted => |entry| {
            try writer.writeAll("{\"kind\":\"interrupted\",\"user\":");
            try writeSessionUserTurnJson(writer, entry.user);
            try writer.writeAll(",\"assistant\":");
            if (entry.assistant) |assistant| {
                try std.json.Stringify.value(assistant, .{}, writer);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"tool_call\":");
            if (entry.tool_call) |tool_call| {
                try writer.writeAll("{\"id\":");
                try std.json.Stringify.value(tool_call.id, .{}, writer);
                try writer.writeAll(",\"name\":");
                try std.json.Stringify.value(tool_call.name, .{}, writer);
                try writer.writeAll(",\"arguments_json\":");
                try std.json.Stringify.value(tool_call.arguments_json, .{}, writer);
                try writer.writeByte('}');
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"completed_tool_names\":[");
            for (entry.completed_tool_names, 0..) |name, i| {
                if (i > 0) try writer.writeByte(',');
                try std.json.Stringify.value(name, .{}, writer);
            }
            try writer.writeByte(']');
            if (!entry.execution.isEmpty()) {
                try writer.writeAll(",\"execution\":");
                try session_json.writeExecutionMemoryJson(writer, entry.execution);
            }
            try writer.writeByte('}');
        },
    }
}

fn writeHexBytes(writer: *std.Io.Writer, bytes: []const u8) !void {
    const alphabet = "0123456789abcdef";
    for (bytes) |byte| {
        try writer.writeByte(alphabet[byte >> 4]);
        try writer.writeByte(alphabet[byte & 0x0f]);
    }
}

fn writeSessionUserTurnJson(writer: *std.Io.Writer, user: types.UserTurn) !void {
    try writer.writeAll("{\"text\":");
    try std.json.Stringify.value(user.text, .{}, writer);
    try writer.writeAll(",\"images\":[");

    for (user.images, 0..) |image, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":");
        try std.json.Stringify.value(image.path, .{}, writer);
        try writer.writeAll(",\"media_type\":");
        try std.json.Stringify.value(image.media_type, .{}, writer);
        try writer.writeByte('}');
    }

    try writer.writeAll("]}");
}

test "command failure snapshot renders stable escaped json" {
    const rendered = try (CommandFailureSnapshot{
        .kind = "models",
        .message = "could not list \"models\"",
        .code = "ConnectionRefused",
    }).renderJson(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "{\"kind\":\"models\",\"error\":\"could not list \\\"models\\\"\",\"code\":\"ConnectionRefused\"}",
        rendered,
    );
}

test "core status snapshot text and json stay stable" {
    const snapshot = StatusSnapshot{
        .model = "alpha",
        .auth_help = "Fx needs a model credential. Set OPENAI_API_KEY for a Responses API, use fx login codex for ChatGPT Codex, or use fx login grok for Grok.",
        .permission_mode = .ask,
        .workspace_root = "/tmp/fx",
        .history_turns = 3,
        .session_permission_grants = 1,
        .agent_step_limit = 24,
    };

    const text = try snapshot.renderText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "[status] model=alpha\n[status] auth=missing\n[status] auth_refreshable=false\n[status] auth_help=Fx needs a model credential. Set OPENAI_API_KEY for a Responses API, use fx login codex for ChatGPT Codex, or use fx login grok for Grok.\n[status] permission_mode=ask\n[status] workspace=/tmp/fx\n[status] history_turns=3\n[status] session_permission_grants=1\n[status] agent_step_limit=24\n",
        text,
    );

    const json = try snapshot.renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"status\",\"model\":\"alpha\",\"auth\":\"missing\",\"auth_refreshable\":false,\"auth_help\":\"Fx needs a model credential. Set OPENAI_API_KEY for a Responses API, use fx login codex for ChatGPT Codex, or use fx login grok for Grok.\",\"permission_mode\":\"ask\",\"workspace\":\"/tmp/fx\",\"history_turns\":3,\"session_permission_grants\":1,\"agent_step_limit\":24}",
        json,
    );
}

test "status distinguishes the selected model route from connected providers" {
    const snapshot = StatusSnapshot{
        .model = "gpt-5.4",
        .provider = .codex,
        .auth = .{
            .active_source = .chatgpt_subscription,
            .gateway_connected = true,
            .chatgpt_connected = true,
        },
        .permission_mode = .auto,
        .workspace_root = "/tmp/fx",
        .history_turns = 0,
        .session_permission_grants = 0,
        .agent_step_limit = 24,
    };
    const text = try snapshot.renderText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "model_source=Codex subscription") != null);
    try std.testing.expect(std.mem.find(u8, text, "connected_providers=BYOK Responses, Codex") != null);

    const json = try snapshot.renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"model_source\":\"Codex subscription\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"connected_providers\":[\"byok-responses\",\"codex\"]") != null);
}

test "core permissions snapshot text and json stay stable" {
    const grants = [_]types.PermissionGrant{
        .{ .tool_name = @constCast("write_file"), .target_path = @constCast("/tmp/workspace/src/app.zig") },
        .{ .tool_name = @constCast("run_command"), .target_path = @constCast("/tmp/workspace::npm test") },
    };
    const rules = [_]types.PermissionRule{
        .{ .permission = @constCast("edit"), .pattern = @constCast("src/*"), .action = .allow },
        .{ .permission = @constCast("open_url"), .pattern = @constCast("*"), .action = .ask },
    };
    const snapshot = PermissionsSnapshot{
        .workspace_root = "/tmp/workspace",
        .mode = .auto,
        .grants = &grants,
        .rules = .{ .rules = @constCast(&rules) },
    };

    const text = try snapshot.renderText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "[permissions] mode=auto\n[permissions] configured rules:\n - allow edit -> src/*\n - ask open_url -> *\n[permissions] session grants:\n - write_file -> src/app.zig\n - run_command -> /tmp/workspace::npm test\n",
        text,
    );

    const json = try snapshot.renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"permissions\",\"mode\":\"auto\",\"grant_count\":2,\"grant_scope\":\"session\",\"runtime_grants_available\":true,\"rules_scope\":\"persistent_config\",\"rules\":[{\"permission\":\"edit\",\"pattern\":\"src/*\",\"action\":\"allow\"},{\"permission\":\"open_url\",\"pattern\":\"*\",\"action\":\"ask\"}],\"grants\":[{\"tool_name\":\"write_file\",\"target_path\":\"/tmp/workspace/src/app.zig\",\"display_target\":\"src/app.zig\"},{\"tool_name\":\"run_command\",\"target_path\":\"/tmp/workspace::npm test\",\"display_target\":\"/tmp/workspace::npm test\"}]}",
        json,
    );
}

test "model list explains public-only catalogs" {
    const alloc = std.testing.allocator;
    const ids = [_][]const u8{"alpha"};
    const shown = ModelListSnapshot{ .ids = &ids };
    const cases = [_]struct {
        snapshot: ModelListSnapshot,
        text: []const u8,
        body: []const u8,
    }{
        .{
            .snapshot = .{ .ids = &ids, .private_models_hidden = true, .public_only_reason = .no_credential },
            .text = "[models] 1 available\n - alpha\n[models] Using the public model catalog; set OPENAI_API_KEY for authenticated BYOK models.\n",
            .body = "1 available\n - alpha\nUsing the public model catalog; set OPENAI_API_KEY for authenticated BYOK models.",
        },
        .{
            .snapshot = .{ .ids = &.{}, .private_models_hidden = true, .public_only_reason = .no_credential },
            .text = "[models] no models returned by gateway\n[models] Using the public model catalog; set OPENAI_API_KEY for authenticated BYOK models.\n",
            .body = "no models returned by gateway\nUsing the public model catalog; set OPENAI_API_KEY for authenticated BYOK models.",
        },
        .{
            .snapshot = .{ .ids = &.{}, .provider = .codex },
            .text = "[models] no models returned by Codex subscription\n",
            .body = "no models returned by Codex subscription",
        },
    };

    for (cases) |case| {
        const text = try case.snapshot.renderText(alloc);
        defer alloc.free(text);
        try std.testing.expectEqualStrings(case.text, text);

        const body = try case.snapshot.renderInteractiveBody(alloc);
        defer alloc.free(body);
        try std.testing.expectEqualStrings(case.body, body);
    }

    const json = try cases[0].snapshot.renderJson(alloc);
    defer alloc.free(json);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"models\",\"count\":1,\"shown_count\":1,\"more_count\":0,\"private_models_hidden\":true,\"ids\":[\"alpha\"]}",
        json,
    );

    // An API key hides nothing, so the note must stay absent.
    const quiet_text = try shown.renderText(alloc);
    defer alloc.free(quiet_text);
    try std.testing.expect(std.mem.find(u8, quiet_text, "authenticated models") == null);
    const quiet_body = try shown.renderInteractiveBody(alloc);
    defer alloc.free(quiet_body);
    try std.testing.expect(std.mem.find(u8, quiet_body, "authenticated models") == null);
}

test "core model list snapshot handles limits and empty lists" {
    const ids = [_][]const u8{ "alpha", "beta", "gamma" };

    const all_text = try (ModelListSnapshot{ .ids = &ids }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(all_text);
    try std.testing.expectEqualStrings(
        "[models] 3 available\n - alpha\n - beta\n - gamma\n",
        all_text,
    );

    const limit_text = try (ModelListSnapshot{ .ids = &ids, .limit = 2 }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(limit_text);
    try std.testing.expectEqualStrings(
        "[models] 3 available\n - alpha\n - beta\n ... and 1 more\n",
        limit_text,
    );

    const limit_json = try (ModelListSnapshot{ .ids = &ids, .limit = 2 }).renderJson(std.testing.allocator);
    defer std.testing.allocator.free(limit_json);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"models\",\"count\":3,\"shown_count\":2,\"more_count\":1,\"private_models_hidden\":false,\"ids\":[\"alpha\",\"beta\"]}",
        limit_json,
    );

    const empty_text = try (ModelListSnapshot{ .ids = &.{} }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(empty_text);
    try std.testing.expectEqualStrings("[models] no models returned by gateway\n", empty_text);

    const empty_json = try (ModelListSnapshot{ .ids = &.{} }).renderJson(std.testing.allocator);
    defer std.testing.allocator.free(empty_json);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"models\",\"count\":0,\"shown_count\":0,\"more_count\":0,\"private_models_hidden\":false,\"ids\":[]}",
        empty_json,
    );
}

test "core session list snapshot text and json stay stable" {
    const sessions = [_]session_store.SessionSummary{
        .{
            .id = @constCast("abc"),
            .workspace_root = @constCast("/tmp/workspace"),
            .origin_workspace_root = @constCast("/tmp/origin"),
            .title = @constCast("Session title"),
            .preview = @constCast("Session title\npreview line"),
            .display_metadata_present = true,
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .conversation_language = types.ConversationLanguage.literal("es"),
            .history_len = 3,
        },
    };

    const text = try (SessionListSnapshot{ .sessions = &sessions }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "[sessions] 1 saved\n - Session title\n   id=abc | 3 turns | Spanish | updated 1970-01-01 00:00:00.002 UTC\n",
        text,
    );

    const json = try (SessionListSnapshot{ .sessions = &sessions }).renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"sessions\",\"count\":1,\"sessions\":[{\"id\":\"abc\",\"title\":\"Session title\",\"preview\":\"Session title\\npreview line\",\"workspace_root\":\"/tmp/workspace\",\"origin_workspace_root\":\"/tmp/origin\",\"created_at_ms\":1,\"updated_at_ms\":2,\"history_len\":3,\"conversation_language\":\"es\"}]}",
        json,
    );

    const paged_text = try (SessionListSnapshot{
        .sessions = &sessions,
        .has_more = true,
        .next_cursor = "v1:2:abc",
    }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(paged_text);
    try std.testing.expectEqualStrings(
        "[sessions] 1 saved\n - Session title\n   id=abc | 3 turns | Spanish | updated 1970-01-01 00:00:00.002 UTC\n" ++
            "[sessions] more saved sessions; continue with `fx sessions --cursor v1:2:abc`\n",
        paged_text,
    );

    const paged_json = try (SessionListSnapshot{
        .sessions = &sessions,
        .has_more = true,
        .next_cursor = "v1:2:abc",
    }).renderJson(std.testing.allocator);
    defer std.testing.allocator.free(paged_json);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"sessions\",\"count\":1,\"has_more\":true,\"next_cursor\":\"v1:2:abc\",\"sessions\":[{\"id\":\"abc\",\"title\":\"Session title\",\"preview\":\"Session title\\npreview line\",\"workspace_root\":\"/tmp/workspace\",\"origin_workspace_root\":\"/tmp/origin\",\"created_at_ms\":1,\"updated_at_ms\":2,\"history_len\":3,\"conversation_language\":\"es\"}]}",
        paged_json,
    );

    const fallback_sessions = [_]session_store.SessionSummary{
        .{
            .id = @constCast("legacy"),
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .conversation_language = types.ConversationLanguage.default(),
            .history_len = 0,
        },
    };
    const fallback_text = try (SessionListSnapshot{ .sessions = &fallback_sessions }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(fallback_text);
    try std.testing.expectEqualStrings(
        "[sessions] 1 saved\n - Untitled session\n   id=legacy | 0 turns | updated 1970-01-01 00:00:00.002 UTC\n",
        fallback_text,
    );

    var script_session = fallback_sessions[0];
    script_session.conversation_language = types.ConversationLanguage.literal("und-Latn");
    script_session.history_len = 1;
    const script_text = try (SessionListSnapshot{ .sessions = @as(*const [1]session_store.SessionSummary, &script_session) }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(script_text);
    try std.testing.expectEqualStrings(
        "[sessions] 1 saved\n - Untitled session\n   id=legacy | 1 turn | Latin script | updated 1970-01-01 00:00:00.002 UTC\n",
        script_text,
    );

    const long_title = "a" ** session_display_metadata.max_title_bytes;
    var long_session = sessions[0];
    long_session.title = @constCast(long_title);
    const long_text = try (SessionListSnapshot{ .sessions = @as(*const [1]session_store.SessionSummary, &long_session) }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(long_text);
    try std.testing.expect(std.mem.startsWith(u8, long_text, "[sessions] 1 saved\n - " ++ long_title ++ "\n"));
    try std.testing.expect(std.mem.find(u8, long_text, "\n   id=abc | 3 turns") != null);

    const warning_text = try (SessionListSnapshot{
        .sessions = &sessions,
        .skipped_invalid = 2,
    }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(warning_text);
    try std.testing.expect(std.mem.find(u8, warning_text, "skipped 2 unreadable saved sessions") != null);

    const warning_json = try (SessionListSnapshot{
        .sessions = &.{},
        .skipped_invalid = 2,
    }).renderJson(std.testing.allocator);
    defer std.testing.allocator.free(warning_json);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"sessions\",\"count\":0,\"skipped_invalid\":2,\"sessions\":[]}",
        warning_json,
    );
}

test "core session list text visibly escapes terminal controls in titles" {
    const sessions = [_]session_store.SessionSummary{
        .{
            .id = @constCast("hostile-title"),
            .title = @constCast("\x1b[2Jbreak\nnext"),
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .conversation_language = types.ConversationLanguage.default(),
            .history_len = 0,
        },
    };

    const text = try (SessionListSnapshot{ .sessions = &sessions }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "[sessions] 1 saved\n - \\x1b[2Jbreak\\x0anext\n" ++
            "   id=hostile-title | 0 turns | updated 1970-01-01 00:00:00.002 UTC\n",
        text,
    );
}

test "core session list text visibly escapes terminal controls in unknown language tags" {
    const sessions = [_]session_store.SessionSummary{
        .{
            .id = @constCast("hostile-language"),
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .conversation_language = try types.ConversationLanguage.fromSlice("\x1b[2J"),
            .history_len = 0,
        },
    };

    const text = try (SessionListSnapshot{ .sessions = &sessions }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "[sessions] 1 saved\n - Untitled session\n" ++
            "   id=hostile-language | 0 turns | \\x1b[2J | updated 1970-01-01 00:00:00.002 UTC\n",
        text,
    );
}

test "core session summary snapshot text and json stay stable" {
    const summary = session_store.SessionSummary{
        .id = @constCast("abc"),
        .workspace_root = @constCast("/tmp/workspace"),
        .origin_workspace_root = @constCast("/tmp/origin"),
        .title = @constCast("Session title"),
        .preview = @constCast("Session preview"),
        .display_metadata_present = true,
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = types.ConversationLanguage.literal("es"),
        .history_len = 3,
    };

    const text = try (SessionSummarySnapshot{
        .summary = summary,
    }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "[session] abc\ncreated_at_ms: 1\nupdated_at_ms: 2\nlanguage: es\nhistory_len: 3\n",
        text,
    );

    const json = try (SessionSummarySnapshot{
        .summary = summary,
    }).renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"session_summary\",\"id\":\"abc\",\"title\":\"Session title\",\"preview\":\"Session preview\",\"workspace_root\":\"/tmp/workspace\",\"origin_workspace_root\":\"/tmp/origin\",\"created_at_ms\":1,\"updated_at_ms\":2,\"history_len\":3,\"conversation_language\":\"es\"}",
        json,
    );
}

test "core session JSON uses fallback title for metadata-missing summaries" {
    const summary = session_store.SessionSummary{
        .id = @constCast("old-session"),
        .workspace_root = null,
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = types.ConversationLanguage.literal("en"),
        .history_len = 1,
    };

    const json = try (SessionSummarySnapshot{
        .summary = summary,
    }).renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"session_summary\",\"id\":\"old-session\",\"title\":\"Untitled session\",\"preview\":null,\"workspace_root\":null,\"origin_workspace_root\":null,\"created_at_ms\":1,\"updated_at_ms\":2,\"history_len\":1,\"conversation_language\":\"en\"}",
        json,
    );
}

test "core empty session detail snapshot text and json stay stable" {
    const detail = session_store.ReadOnlyDetail{
        .summary = .{
            .id = @constCast("sess-empty"),
            .workspace_root = @constCast("/tmp/fx"),
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .conversation_language = types.ConversationLanguage.literal("en"),
            .history_len = 0,
        },
        .state = .{
            .id = @constCast("sess-empty"),
            .origin_workspace_root = @constCast("/tmp/fx"),
            .workspace_root = @constCast("/tmp/fx"),
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .conversation_language = types.ConversationLanguage.literal("en"),
            .preferences = .{
                .model = @constCast("model"),
                .effort = .auto,
                .fast_mode = false,
            },
            .history = &.{},
            .total_input_tokens = 0,
            .total_output_tokens = 0,
        },
        .storage_format = .schema_v3,
    };

    const text = try (SessionDetailSnapshot{ .detail = detail }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "[session] sess-empty\ncreated_at_ms: 1\nupdated_at_ms: 2\nlanguage: en\nhistory_len: 0\n\n(no history yet)\n",
        text,
    );

    const json = try (SessionDetailSnapshot{ .detail = detail }).renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"session_detail\",\"id\":\"sess-empty\",\"created_at_ms\":1,\"updated_at_ms\":2,\"history_len\":0,\"conversation_language\":\"en\",\"history\":[]}",
        json,
    );
}

test "core session detail snapshot preserves history variant shapes" {
    const images = [_]types.ImageAttachment{
        .{ .path = @constCast("/tmp/a.png"), .media_type = @constCast("image/png") },
    };
    var files = [_]types.FileEvidence{.{
        .path = @constCast("src/main.zig"),
        .tool_call_id = @constCast("call_read"),
        .tool_name = @constCast("read_file"),
        .action = .read,
        .status = .success,
    }};
    const record_id = types.StableBackgroundRecordId{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    };
    const history = [_]types.HistoryTurn{
        .{ .compacted_summary = .{
            .summary = @constCast("summary"),
            .removed_turn_count = 3,
            .compaction_count = 1,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("hola"), .images = @constCast(&images) },
            .assistant = @constCast("que tal"),
        } },
        .{ .background_command = .{
            .user = .{ .text = @constCast("npm run dev") },
            .assistant = @constCast("The server is starting."),
            .execution = .{ .files = files[0..] },
            .log_path = @constCast("/tmp/server.log"),
            .expect_url = true,
            .url = @constCast("http://localhost:3000"),
            .background_record_id = record_id,
        } },
        .{ .interrupted = .{
            .user = .{ .text = @constCast("inspect") },
            .assistant = @constCast("I inspected the entry point."),
            .execution = .{ .files = files[0..] },
        } },
    };
    const detail = session_store.ReadOnlyDetail{
        .summary = .{
            .id = @constCast("sess-history"),
            .workspace_root = @constCast("/tmp/fx"),
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .conversation_language = types.ConversationLanguage.literal("es"),
            .history_len = history.len,
        },
        .state = .{
            .id = @constCast("sess-history"),
            .origin_workspace_root = @constCast("/tmp/fx"),
            .workspace_root = @constCast("/tmp/fx"),
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .conversation_language = types.ConversationLanguage.literal("es"),
            .preferences = .{
                .model = @constCast("model"),
                .effort = .auto,
                .fast_mode = false,
            },
            .history = @constCast(&history),
            .total_input_tokens = 0,
            .total_output_tokens = 0,
        },
        .storage_format = .schema_v3,
    };

    const text = try (SessionDetailSnapshot{ .detail = detail }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "[compacted] removed_turns=3 compactions=1") != null);
    try std.testing.expect(std.mem.find(u8, text, "[user]\nhola\n[images] 1\n - /tmp/a.png (image/png)\n[assistant]\nque tal\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "[execution]\nfile: read success src/main.zig\n[assistant]\nThe server is starting.\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "[background]\nlog: /tmp/server.log\nexpect_url: true\nurl: http://localhost:3000\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "record_id: 00112233445566778899aabbccddeeff") != null);
    try std.testing.expect(std.mem.find(u8, text, "[assistant]\nI inspected the entry point.\n[interrupted]") != null);

    const json = try (SessionDetailSnapshot{ .detail = detail }).renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"kind\":\"compacted_summary\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"kind\":\"assistant\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"kind\":\"background_command\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"kind\":\"interrupted\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "{\"path\":\"/tmp/a.png\",\"media_type\":\"image/png\"}") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"assistant\":\"The server is starting.\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"background_record_id\":\"00112233445566778899aabbccddeeff\"") != null);
    try std.testing.expect(std.mem.count(u8, json, "\"execution\"") >= 2);
}

test "core session detail JSON includes assistant execution memory" {
    var calls = [_]types.ToolCall{.{
        .id = "fetch_1",
        .name = "web_fetch",
        .arguments_json = "{\"url\":\"https://example.com/file.pdf\",\"prompt\":\"[REDACTED]\"}",
    }};
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("fetch_1"),
        .tool_name = @constCast("web_fetch"),
        .status = .success,
        .output = @constCast("<artifact_handle>artifact-file.pdf</artifact_handle>"),
        .output_bytes = 48,
        .stored_output_bytes = 48,
        .command_output_replay = .{ .available = .{
            .handle = "fx-command-replay-private-sentinel.bin",
            .framed_bytes = 77,
        } },
        .command_process_presentation = .{ .exit_code = 9 },
    }};
    var steps = [_]types.ToolExecutionStep{.{
        .assistant = @constCast("Fetching artifact."),
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    const history = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("fetch pdf") },
        .assistant = @constCast("artifact saved"),
        .execution = .{
            .tool_steps = steps[0..],
            .turn_summary = .{
                .started_at_ms = 100,
                .completed_at_ms = 250,
                .thinking_duration_ms = 40,
                .turn_duration_ms = 150,
                .token_progress = .{ .input_tokens = 12, .output_tokens = 34 },
            },
        },
    } }};
    const detail = session_store.ReadOnlyDetail{
        .summary = .{
            .id = @constCast("sess-exec"),
            .workspace_root = @constCast("/tmp/fx"),
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .conversation_language = types.ConversationLanguage.literal("en"),
            .history_len = history.len,
        },
        .state = .{
            .id = @constCast("sess-exec"),
            .origin_workspace_root = @constCast("/tmp/fx"),
            .workspace_root = @constCast("/tmp/fx"),
            .created_at_ms = 1,
            .updated_at_ms = 2,
            .conversation_language = types.ConversationLanguage.literal("en"),
            .preferences = .{
                .model = @constCast("model"),
                .effort = .auto,
                .fast_mode = false,
            },
            .history = @constCast(&history),
            .total_input_tokens = 0,
            .total_output_tokens = 0,
        },
        .storage_format = .schema_v3,
    };

    const json = try (SessionDetailSnapshot{ .detail = detail }).renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"execution\":{\"schema_version\":2") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"turn_summary\"") == null);
    try std.testing.expect(std.mem.find(u8, json, "\"name\":\"web_fetch\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "artifact-file.pdf") != null);
    try std.testing.expect(std.mem.find(u8, json, "command_output_replay") == null);
    try std.testing.expect(std.mem.find(u8, json, "command_process_presentation") == null);
    try std.testing.expect(std.mem.find(u8, json, "fx-command-replay-private-sentinel.bin") == null);

    const text = try (SessionDetailSnapshot{ .detail = detail }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "started_at_ms") == null);
    try std.testing.expect(std.mem.find(u8, text, "input_tokens") == null);
}

test "core session migration snapshot text and json stay stable" {
    const result = session_store.SessionMigrationResult{
        .session_id = @constCast("session.v3"),
        .source_schema_version = 2,
        .source_bytes = 4096,
        .status = .migrated,
    };

    const text = try (SessionMigrationSnapshot{ .result = result }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "[session migration] session.v3\nstatus: migrated\nsource_schema_version: 2\nsource_bytes: 4096\n",
        text,
    );

    const json = try (SessionMigrationSnapshot{ .result = result }).renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"session_migration\",\"id\":\"session.v3\",\"status\":\"migrated\",\"source_schema_version\":2,\"source_bytes\":4096}",
        json,
    );
}

test "core session recovery snapshot text and json stay stable" {
    const result = session_store.SessionRecoveryResult{
        .source_session_id = @constCast("source-session"),
        .recovered_session_id = @constCast("recovered-session"),
        .history_len = 4,
    };

    const text = try (SessionRecoverySnapshot{ .result = result }).renderText(
        std.testing.allocator,
    );
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "[session recovery] copied source-session to recovered-session\nhistory_turns: 4\nresume: fx --resume recovered-session\n",
        text,
    );

    const json = try (SessionRecoverySnapshot{ .result = result }).renderJson(
        std.testing.allocator,
    );
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"session_recovery\",\"source_id\":\"source-session\",\"recovered_id\":\"recovered-session\",\"status\":\"recovered\",\"history_turns\":4}",
        json,
    );

    const partial = session_store.SessionRecoveryResult{
        .source_session_id = @constCast("source-session"),
        .recovered_session_id = @constCast("partial-session"),
        .history_len = 4,
        .status = .recovered_with_unverified_artifacts,
    };
    const partial_text = try (SessionRecoverySnapshot{
        .result = partial,
    }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(partial_text);
    try std.testing.expectEqualStrings(
        "[session recovery] copied source-session to partial-session\nhistory_turns: 4\nwarning: legacy command artifacts could not be authenticated\nresume: fx --resume partial-session\n",
        partial_text,
    );
    const partial_json = try (SessionRecoverySnapshot{
        .result = partial,
    }).renderJson(std.testing.allocator);
    defer std.testing.allocator.free(partial_json);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"session_recovery\",\"source_id\":\"source-session\",\"recovered_id\":\"partial-session\",\"status\":\"recovered_with_unverified_artifacts\",\"history_turns\":4}",
        partial_json,
    );

    const indeterminate = session_store.SessionRecoveryResult{
        .source_session_id = @constCast("source-session"),
        .recovered_session_id = @constCast("target-session"),
        .history_len = 4,
        .status = .indeterminate,
    };
    const warning = try (SessionRecoverySnapshot{
        .result = indeterminate,
    }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(warning);
    try std.testing.expectEqualStrings(
        "[session recovery] could not confirm target target-session\nsource: source-session (unchanged)\nresolve: fx --resume target-session\ninspect: fx doctor\n",
        warning,
    );
}

test "core doctor snapshot text and json stay stable" {
    const checks = [_]doctor_runtime.Check{
        .{ .name = @constCast("auth"), .status = .ok, .detail = @constCast("OPENAI_API_KEY is configured") },
        .{ .name = @constCast("gh"), .status = .warn, .detail = @constCast("GitHub CLI not found in PATH") },
    };
    const snapshot = DoctorSnapshot{
        .workspace_root = "/tmp/fx",
        .model = "alpha",
        .auth = .{ .active_source = .openai_api_key },
        .permission_mode = .ask,
        .agent_step_limit = 24,
        .checks = &checks,
    };

    const text = try snapshot.renderText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "[doctor] ok=1 warn=1 fail=0\n[doctor] workspace=/tmp/fx\n[doctor] model=alpha\n[doctor] auth=OPENAI_API_KEY\n[doctor] auth_refreshable=false\n[doctor] permission_mode=ask\n[doctor] agent_step_limit=24\n[ok] auth: OPENAI_API_KEY is configured\n[warn] gh: GitHub CLI not found in PATH\n",
        text,
    );

    const json = try snapshot.renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"doctor\",\"ok_count\":1,\"warn_count\":1,\"fail_count\":0,\"workspace\":\"/tmp/fx\",\"model\":\"alpha\",\"auth\":\"OPENAI_API_KEY\",\"auth_refreshable\":false,\"permission_mode\":\"ask\",\"agent_step_limit\":24,\"checks\":[{\"name\":\"auth\",\"status\":\"ok\",\"detail\":\"OPENAI_API_KEY is configured\"},{\"name\":\"gh\",\"status\":\"warn\",\"detail\":\"GitHub CLI not found in PATH\"}]}",
        json,
    );
}

test "doctor text escapes hostile check details while json preserves data" {
    const checks = [_]doctor_runtime.Check{.{
        .name = "config_warning",
        .status = .warn,
        .detail = "warning key=bad\n\x1b]0;pwn\x07",
    }};
    const snapshot = DoctorSnapshot{
        .workspace_root = "/tmp/fx",
        .model = "alpha",
        .permission_mode = .ask,
        .agent_step_limit = 24,
        .checks = &checks,
    };

    const text = try snapshot.renderText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(
        u8,
        text,
        "warning key=bad\\x0a\\x1b]0;pwn\\x07",
    ) != null);
    try std.testing.expect(std.mem.findScalar(u8, text, 0x1b) == null);

    const json = try snapshot.renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.find(
        u8,
        json,
        "\"detail\":\"warning key=bad\\n\\u001b]0;pwn\\u0007\"",
    ) != null);
}

test "Codex account usage failure has stable text and JSON contracts" {
    const snapshot = CodexAccountUsageSnapshot{ .failure = .{
        .kind = .rate_limited,
        .http_status = .too_many_requests,
    } };

    const text_output = try snapshot.renderText(std.testing.allocator);
    defer std.testing.allocator.free(text_output);
    try std.testing.expectEqualStrings(
        "[codex usage] error: Codex account usage request was rate limited (HTTP 429)\n",
        text_output,
    );

    const json_output = try snapshot.renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json_output);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"codex_account_usage\",\"schema_version\":1,\"error\":{\"code\":\"rate_limited\",\"http_status\":429}}",
        json_output,
    );
}

test "Codex account usage text visibly escapes provider controls" {
    const usage_json =
        \\{"plan_type":"pro\u001b[31m","credits":{"has_credits":true,"unlimited":false,"balance":"7\n50"},"spend_control":{"reached":false,"individual_limit":{"source":"user\rname","limit":"1\t00","used":"2\u001b","remaining":"8\n0","used_percent":20,"remaining_percent":80,"reset_after_seconds":60,"reset_at":100}},"additional_rate_limits":[{"limit_name":"Code\nreview","metered_feature":"codex\tfeature"}],"rate_limit_reached_type":{"type":"hard\rlimit"}}
    ;
    const profile_json =
        \\{"stats":{"daily_usage_buckets":[{"start_date":"2026-08-24\u001b","tokens":10}]}}
    ;
    const data = try codex_usage.parseSnapshot(
        std.testing.allocator,
        usage_json,
        profile_json,
        1234,
    );
    var snapshot = CodexAccountUsageSnapshot{ .data = data };
    defer snapshot.deinit(std.testing.allocator);

    const text_output = try snapshot.renderText(std.testing.allocator);
    defer std.testing.allocator.free(text_output);
    try std.testing.expect(std.mem.findScalar(u8, text_output, 0x1b) == null);
    for ([_][]const u8{
        "Plan: pro\\x1b[31m\n",
        "codex\\x09feature (Code\\x0areview)",
        "balance=7\\x0a50",
        "source=user\\x0dname",
        "limit=1\\x0900 used=2\\x1b remaining=8\\x0a0",
        "Rate limit reached type: hard\\x0dlimit",
        "2026-08-24\\x1b: 10 tokens",
    }) |escaped| {
        try std.testing.expect(std.mem.find(u8, text_output, escaped) != null);
    }
}

test "workspace snapshot renders source availability and mutation in text and json" {
    const entries = [_]workspace_access.Entry{
        .{
            .path = @constCast("/tmp/shared"),
            .saved = true,
            .command_line = false,
            .available = true,
            .active = true,
        },
        .{
            .path = @constCast("/tmp/run-only"),
            .saved = false,
            .command_line = true,
            .available = true,
            .active = true,
        },
    };
    const snapshot = WorkspaceSnapshot{
        .primary_directory = "/tmp/project",
        .saved_suppressed = false,
        .additional_directories = &entries,
        .mutation = .{
            .action = "remove",
            .path = "/tmp/removed",
            .saved_changed = false,
            .runtime_changed = true,
            .launch_flag_can_restore = true,
        },
    };

    const text_output = try snapshot.renderText(std.testing.allocator);
    defer std.testing.allocator.free(text_output);
    try std.testing.expect(std.mem.find(u8, text_output, "[workspace] remove /tmp/removed saved_changed=false runtime_changed=true launch_flag_can_restore=true") != null);
    try std.testing.expect(std.mem.find(u8, text_output, "warning: repeating --add-dir can restore removed access on the next launch") != null);
    try std.testing.expect(std.mem.find(u8, text_output, "/tmp/run-only saved=false command_line=true available=true active=true") != null);

    const json_output = try snapshot.renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json_output);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"workspace\",\"action\":\"remove\",\"changed\":true,\"primary_directory\":\"/tmp/project\",\"saved_suppressed\":false,\"limit\":16,\"path\":\"/tmp/removed\",\"saved_changed\":false,\"runtime_changed\":true,\"launch_flag_can_restore\":true,\"additional_directories\":[{\"path\":\"/tmp/shared\",\"saved\":true,\"command_line\":false,\"available\":true,\"active\":true},{\"path\":\"/tmp/run-only\",\"saved\":false,\"command_line\":true,\"available\":true,\"active\":true}]}",
        json_output,
    );

    var saved_only = snapshot;
    saved_only.mutation = .{
        .action = "remove",
        .path = "/tmp/shared",
        .saved_changed = true,
        .runtime_changed = true,
    };
    const saved_text = try saved_only.renderText(std.testing.allocator);
    defer std.testing.allocator.free(saved_text);
    try std.testing.expect(std.mem.find(u8, saved_text, "launch_flag_can_restore=false") != null);
    try std.testing.expect(std.mem.find(u8, saved_text, "warning: repeating --add-dir") == null);

    const saved_json = try saved_only.renderJson(std.testing.allocator);
    defer std.testing.allocator.free(saved_json);
    try std.testing.expect(std.mem.find(u8, saved_json, "\"launch_flag_can_restore\":false") != null);
}

test "workspace errors expose shared user-facing copy" {
    try std.testing.expectEqualStrings("path is invalid", workspaceErrorMessage(error.InvalidPath).?);
    try std.testing.expectEqualStrings(
        "directory is not configured as an additional workspace",
        workspaceErrorMessage(error.UnknownAdditionalDirectory).?,
    );
    try std.testing.expectEqualStrings(
        "the primary workspace cannot be added or removed",
        workspaceErrorMessage(error.PrimaryDirectory).?,
    );
    try std.testing.expectEqualStrings(
        "additional directory limit reached",
        workspaceErrorMessage(error.TooManyDirectories).?,
    );
    try std.testing.expect(workspaceErrorMessage(error.InvalidWorkspaceArgs) == null);
}

test "workspace text snapshot terminal-encodes paths" {
    const entries = [_]workspace_access.Entry{.{
        .path = @constCast("/tmp/shared\x1b[31m\n"),
        .saved = true,
        .command_line = false,
        .available = true,
        .active = true,
    }};
    const output = try (WorkspaceSnapshot{
        .primary_directory = "/tmp/project\r",
        .saved_suppressed = false,
        .additional_directories = &entries,
    }).renderText(std.testing.allocator);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.find(u8, output, "\\x1b[31m\\x0a") != null);
    try std.testing.expect(std.mem.find(u8, output, "project\\x0d") != null);
    try std.testing.expect(std.mem.findScalar(u8, output, 0x1b) == null);
    try std.testing.expect(std.mem.findScalar(u8, output, '\r') == null);
}

test "usage text and JSON render the same optional and ordered facts" {
    const alloc = std.testing.allocator;
    var models = [_]usage_report.ModelUsage{.{
        .model = @constCast("provider/model"),
        .totals = .{
            .total_tokens = 12,
            .input_tokens = 10,
            .output_tokens = 2,
            .cache_read_tokens = 3,
            .cache_write_tokens = 1,
            .reasoning_tokens = null,
            .request_count = 1,
            .total_cost = 0.25,
        },
    }};
    const report = usage_report.Snapshot{
        .scope = .days_7,
        .snapshot_time_ms = 200,
        .window_start_ms = 100,
        .coverage_started_at_ms = 150,
        .coverage = .partial,
        .completeness = .complete,
        .totals = models[0].totals,
        .models = &models,
    };
    const snapshot = UsageSnapshot{ .report = &report };

    const text = try snapshot.render(alloc, .text);
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "Total tokens  12") != null);
    try std.testing.expect(std.mem.find(u8, text, "Reasoning") == null);
    try std.testing.expect(std.mem.find(u8, text, "provider/model") != null);

    const json = try snapshot.render(alloc, .json);
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "7d",
        parsed.value.object.get("period").?.string,
    );
    try std.testing.expect(
        parsed.value.object.get("totals").?.object.get("reasoning_tokens").? == .null,
    );
    try std.testing.expectEqualStrings(
        "provider/model",
        parsed.value.object.get("models").?.array.items[0].object.get("model").?.string,
    );
}
