const std = @import("std");
const std_builtin = @import("builtin");
const command_admission = @import("../core/permissions/command_admission.zig");
const auth_runtime = @import("../core/auth/auth_runtime.zig");
const credentials = @import("../core/auth/credentials.zig");
const model_provider = @import("../core/config/model_provider.zig");
const host = @import("../core/hosts/host.zig");
const host_target = @import("../core/hosts/target.zig");
const io_mod = @import("../core/shared/io.zig");
const jsonrpc = @import("jsonrpc.zig");
const acp_types = @import("types.zig");
const server = @import("server.zig");
const sessions = @import("sessions.zig");
const agent_runtime = @import("../core/agent/agent_runtime.zig");
const diff_mod = @import("../core/output/diff.zig");
const file_mutation = @import("../core/tooling/file_mutation.zig");
const file_mutation_contract = @import("../core/tooling/file_mutation_contract.zig");
const mcp_runtime = @import("../core/mcp/mcp_runtime.zig");
const mcp_model_catalog = @import("../core/mcp/model_catalog.zig");
const mcp_elicitation = @import("../core/mcp/elicitation.zig");
const mrtr = @import("../core/mcp/mrtr.zig");
const permission_auto_classifier = @import("../core/permissions/auto_classifier.zig");
const auto_classifier_context = @import("../core/permissions/auto_classifier_context.zig");
const permission_gate = @import("../core/permissions/permission_gate.zig");
const permission_request = @import("../core/permissions/permission_request.zig");
const session_codec = @import("../core/session/session_codec.zig");
const session_log = @import("../core/session/session_log.zig");
const session_store = @import("../core/session/session_store.zig");
const session_runtime = @import("../core/session/session.zig");
const session_usage = @import("../core/session/session_usage.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const runtime_compaction = @import("../core/agent/runtime/compaction.zig");
const subagent_agent_adapter = @import("../core/subagent/agent_adapter.zig");
const subagent_domain = @import("../core/subagent/domain.zig");
const subagent_execution = @import("../core/subagent/execution.zig");
const subagent_resume_admission = @import("../core/subagent/resume_admission.zig");
const parent_delivery_projector = @import("../core/subagent/parent_delivery_projector.zig");
const usage_recovery = @import("../core/session/usage_recovery.zig");
const skill_runtime = @import("../core/skills/skill_runtime.zig");
const skill_invocation = @import("../core/skills/skill_invocation.zig");
const context_contract = @import("../core/workspace/context_contract.zig");
const config_runtime = @import("../core/config/config_runtime.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const mode_registry = @import("../core/modes/mode_registry.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const display_width = @import("../core/shared/display_width.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const tool_projection_mod = @import("../core/tooling/tool_projection.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const tool_admission = @import("../core/tooling/tool_admission.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const tool_specs = @import("../core/tooling/tool_specs.zig");
const tool_set_contract = @import("../core/tooling/tool_set.zig");
const tool_mcp_runtime = @import("../core/tooling/tool_mcp_runtime.zig");
const tool_presentation = @import("../core/tooling/tool_presentation.zig");
const tool_result_errors = @import("../core/tooling/tool_result_errors.zig");
const tool_runtime = @import("../core/tooling/tool_runtime.zig");
const command_output_content = @import("../core/tooling/command_output_content.zig");
const builtin_tools = @import("../builtins/tools.zig");
const test_builtin_gateway = if (std_builtin.is_test)
    @import("../builtins/responses.zig")
else
    struct {};
const types = @import("../core/shared/types.zig");
const worker_runtime = @import("../core/agent/worker_runtime.zig");
const unified_exec_runtime = @import("../core/execution/unified_exec.zig");

const Allocator = std.mem.Allocator;
const ErrorCode = jsonrpc.ErrorCode;

pub const no_active_session_rpc_error = jsonrpc.RpcError{
    .code = ErrorCode.invalid_params,
    .message = "No active session",
};
const ToolCall = types.ToolCall;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;
const PermissionGrant = types.PermissionGrant;
const PermissionMode = types.PermissionMode;
const ToolPermissionDecision = types.ToolPermissionDecision;
const ToolExecutionResult = agent_runtime.ToolExecutionResult;
const McpHasToolFn = tool_mcp_runtime.HasToolFn;

pub const TerminalOutcome = union(enum) {
    stop_reason: acp_types.StopReason,
    rpc_error: jsonrpc.RpcError,
};

const max_acp_command_preview_bytes: usize = 64 * 1024;

const AcpCommandOutputSink = struct {
    alloc: Allocator,
    bytes: *std.ArrayList(u8),

    pub fn appendText(self: *AcpCommandOutputSink, text: []const u8) !void {
        try self.bytes.appendSlice(self.alloc, text);
    }

    pub fn finishLine(self: *AcpCommandOutputSink) !void {
        try self.bytes.append(self.alloc, '\n');
    }

    pub fn replaceLine(self: *AcpCommandOutputSink) !void {
        try self.bytes.append(self.alloc, '\r');
    }
};

const AcpCommandOutputPreview = struct {
    bytes: std.ArrayList(u8) = .empty,
    decoders: [2]command_output_content.Decoder = .{ .{}, .{} },
    truncated: bool = false,

    fn deinit(self: *AcpCommandOutputPreview, alloc: Allocator) void {
        self.bytes.deinit(alloc);
        self.* = undefined;
    }

    fn decode(
        self: *AcpCommandOutputPreview,
        alloc: Allocator,
        stream: command_output_content.Stream,
        raw: []const u8,
    ) ![]u8 {
        var visible: std.ArrayList(u8) = .empty;
        errdefer visible.deinit(alloc);
        var sink = AcpCommandOutputSink{ .alloc = alloc, .bytes = &visible };
        try self.decoders[@intFromEnum(stream)].append(raw, &sink);
        return visible.toOwnedSlice(alloc);
    }

    fn finishDecoder(
        self: *AcpCommandOutputPreview,
        alloc: Allocator,
        stream: command_output_content.Stream,
    ) ![]u8 {
        var visible: std.ArrayList(u8) = .empty;
        errdefer visible.deinit(alloc);
        var sink = AcpCommandOutputSink{ .alloc = alloc, .bytes = &visible };
        try self.decoders[@intFromEnum(stream)].finish(&sink);
        return visible.toOwnedSlice(alloc);
    }

    fn appendVisible(self: *AcpCommandOutputPreview, alloc: Allocator, chunk: []const u8) !void {
        if (chunk.len >= max_acp_command_preview_bytes) {
            self.bytes.clearRetainingCapacity();
            var start = chunk.len - max_acp_command_preview_bytes;
            while (start < chunk.len and isUtf8Continuation(chunk[start])) : (start += 1) {}
            try self.bytes.appendSlice(
                alloc,
                chunk[start..],
            );
            self.truncated = true;
            return;
        }
        const overflow = self.bytes.items.len +| chunk.len -| max_acp_command_preview_bytes;
        if (overflow > 0) {
            var drop = overflow;
            while (drop < self.bytes.items.len and isUtf8Continuation(self.bytes.items[drop])) : (drop += 1) {}
            std.mem.copyForwards(
                u8,
                self.bytes.items[0 .. self.bytes.items.len - drop],
                self.bytes.items[drop..],
            );
            self.bytes.items.len -= drop;
            self.truncated = true;
        }
        try self.bytes.appendSlice(alloc, chunk);
    }
};

fn isUtf8Continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

const AcpToolTerminal = struct {
    title: ?[]const u8 = null,
    lifecycle_status: ?acp_types.ToolCallStatus = null,
    result_status: ?acp_types.ToolCallStatus = null,
    content_text: ?[]const u8 = null,
    command_result_json: ?[]const u8 = null,
    emitted: bool = false,

    fn deinit(self: *AcpToolTerminal, alloc: Allocator) void {
        if (self.title) |value| alloc.free(@constCast(value));
        if (self.content_text) |value| alloc.free(@constCast(value));
        if (self.command_result_json) |value| alloc.free(@constCast(value));
        self.* = .{};
    }
};

const AcpContext = struct {
    const GatewayRouteView = union(enum) {
        live,
        snapshot: ?*const server.GatewayRouteSnapshot,
    };

    alloc: Allocator,
    state: *server.ServerState,
    session_id: []const u8,
    /// Tool-call IDs already announced with a pending update. Keys are owned
    /// copies of provider call ids so the ID stays stable from permission
    /// review through execution.
    published_tool_calls: std.StringHashMapUnmanaged(void) = .empty,
    /// ACP has one terminal update per tool call. The execution transport owns
    /// result content while the shared lifecycle owns the final `Ran`/failure
    /// title, and either side may arrive first. Keys borrow published ids.
    tool_terminals: std.StringHashMapUnmanaged(AcpToolTerminal) = .empty,
    /// Bounded accumulated command output for ACP's replace-semantics
    /// ToolCallUpdate.content field. Keys borrow published_tool_calls keys.
    /// Unified Exec queues both pipe readers and drains their owned chunks on
    /// the model operation thread, so this map has one writer and transport
    /// backpressure never holds a process-control lock.
    command_output_previews: std.StringHashMapUnmanaged(AcpCommandOutputPreview) = .empty,
    stop_reason: acp_types.StopReason = .end_turn,
    auto_classifier: permission_auto_classifier.Classifier =
        permission_auto_classifier.Classifier.disabled(),
    /// Mode and permission policy captured at prompt dispatch so mid-turn
    /// session/set_mode changes never mutate a running turn.
    captured_mode: ?[]const u8 = null,
    captured_permission_mode: ?PermissionMode = null,
    bash_first: bool = false,

    fn deinitPublishedToolCalls(self: *AcpContext) void {
        var terminals = self.tool_terminals.valueIterator();
        while (terminals.next()) |terminal| terminal.deinit(self.alloc);
        self.tool_terminals.deinit(self.alloc);
        var previews = self.command_output_previews.valueIterator();
        while (previews.next()) |preview| preview.deinit(self.alloc);
        self.command_output_previews.deinit(self.alloc);
        var keys = self.published_tool_calls.keyIterator();
        while (keys.next()) |key| self.alloc.free(key.*);
        self.published_tool_calls.deinit(self.alloc);
    }

    fn sendUpdate(self: *AcpContext, update_json: []const u8) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeSessionUpdate(&out.writer, self.session_id, update_json);
        try self.state.writer.writeNotification(self.alloc, "session/update", out.writer.buffered());
    }

    fn sendAgentText(self: *AcpContext, text: []const u8) !void {
        const plain = try stripAnsiAlloc(self.alloc, text);
        defer if (plain.ptr != text.ptr) self.alloc.free(plain);
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeAgentMessageChunk(&out.writer, plain);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendAgentThought(self: *AcpContext, text: []const u8) !void {
        const plain = try stripAnsiAlloc(self.alloc, text);
        defer if (plain.ptr != text.ptr) self.alloc.free(plain);
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeAgentThoughtChunk(&out.writer, plain);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendModelRecoveryStatus(
        self: *AcpContext,
        status: types.RouteRecoveryStatus,
    ) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeModelRecoveryInfoUpdate(
            &out.writer,
            status,
            self.state.active_session.?.writable != null,
        );
        try self.sendUpdate(out.writer.buffered());
    }

    fn clearModelRecoveryStatus(self: *AcpContext) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeModelRecoveryInfoUpdate(&out.writer, null, false);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendToolCallPending(self: *AcpContext, arena: Allocator, call: ToolCall) ![]const u8 {
        if (self.published_tool_calls.getKey(call.id)) |published| return published;
        const registry = self.toolRegistry();
        const title = describeToolTitle(registry, arena, call) catch "Tool call";
        const kind = mapToolKind(call.name);
        var validated_arguments: std.Io.Writer.Allocating = .init(arena);
        defer validated_arguments.deinit();
        const raw_input_json: ?[]const u8 = if (writeValidatedToolArguments(
            arena,
            &validated_arguments.writer,
            call.arguments_json,
        )) |_| validated_arguments.written() else |_| null;

        const owned_id = try self.alloc.dupe(u8, call.id);
        errdefer self.alloc.free(owned_id);
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeToolCall(
            &out.writer,
            owned_id,
            title,
            kind,
            .pending,
            raw_input_json,
        );
        try self.sendUpdate(out.writer.buffered());
        try self.published_tool_calls.put(self.alloc, owned_id, {});
        return owned_id;
    }

    fn sendToolCallProgressText(self: *AcpContext, tool_call_id: []const u8, text: ?[]const u8) !void {
        const plain = if (text) |value| try stripAnsiAlloc(self.alloc, value) else null;
        defer if (plain) |value| if (text) |original| {
            if (value.ptr != original.ptr) self.alloc.free(value);
        };
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeToolCallUpdate(&out.writer, tool_call_id, .in_progress, plain);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendToolCallTerminalPresentation(
        self: *AcpContext,
        tool_call_id: []const u8,
        outcome: types.ToolOutcome,
    ) !void {
        const stable_id = self.published_tool_calls.getKey(tool_call_id) orelse return;
        const plain = try stripAnsiAlloc(self.alloc, outcome.summary);
        defer if (plain.ptr != outcome.summary.ptr) self.alloc.free(plain);
        const owned_title = try self.alloc.dupe(u8, plain);
        const status: acp_types.ToolCallStatus = switch (outcome.kind) {
            .completed, .deferred => .completed,
            .denied, .cancelled, .failed => .failed,
        };
        const entry = self.tool_terminals.getOrPut(self.alloc, stable_id) catch |err| {
            self.alloc.free(owned_title);
            return err;
        };
        if (!entry.found_existing) entry.value_ptr.* = .{};
        if (entry.value_ptr.emitted) {
            self.alloc.free(owned_title);
            return;
        }
        if (entry.value_ptr.title) |old| self.alloc.free(@constCast(old));
        entry.value_ptr.title = owned_title;
        entry.value_ptr.lifecycle_status = status;
        try self.publishToolTerminal(stable_id, entry.value_ptr, false);
    }

    fn sendCommandOutputDelta(
        self: *AcpContext,
        tool_call_id: []const u8,
        stream: command_output_content.Stream,
        chunk: []const u8,
    ) !void {
        const stable_id = self.published_tool_calls.getKey(tool_call_id) orelse return;
        const entry = try self.command_output_previews.getOrPut(self.alloc, stable_id);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        const visible = try entry.value_ptr.decode(self.alloc, stream, chunk);
        defer self.alloc.free(visible);
        if (visible.len == 0) return;
        try self.sendVisibleCommandOutputDelta(stable_id, stream, visible, entry.value_ptr);
    }

    fn sendVisibleCommandOutputDelta(
        self: *AcpContext,
        stable_id: []const u8,
        stream: command_output_content.Stream,
        visible: []const u8,
        preview: *AcpCommandOutputPreview,
    ) !void {
        try preview.appendVisible(self.alloc, visible);

        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeCommandOutputUpdate(
            &out.writer,
            stable_id,
            @tagName(stream),
            visible,
            preview.bytes.items,
            preview.truncated,
        );
        try self.sendUpdate(out.writer.buffered());
    }

    fn flushCommandOutputPreview(self: *AcpContext, tool_call_id: []const u8) !void {
        const stable_id = self.published_tool_calls.getKey(tool_call_id) orelse return;
        const preview = self.command_output_previews.getPtr(stable_id) orelse return;
        for ([_]command_output_content.Stream{ .stdout, .stderr }) |stream| {
            const visible = try preview.finishDecoder(self.alloc, stream);
            defer self.alloc.free(visible);
            if (visible.len == 0) continue;
            try self.sendVisibleCommandOutputDelta(stable_id, stream, visible, preview);
        }
    }

    fn clearCommandOutputPreview(self: *AcpContext, tool_call_id: []const u8) void {
        const removed = self.command_output_previews.fetchRemove(tool_call_id) orelse return;
        var preview = removed.value;
        preview.deinit(self.alloc);
    }

    fn sendWebSearchProgress(self: *AcpContext, tool_call_id: []const u8, progress: types.WebSearchProgress) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try writeWebSearchProgressUpdate(self.alloc, &out.writer, tool_call_id, progress);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendWebFetchProgress(self: *AcpContext, tool_call_id: []const u8, progress: types.WebFetchProgress) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try writeWebFetchProgressUpdate(self.alloc, &out.writer, tool_call_id, progress);
        try self.sendUpdate(out.writer.buffered());
    }

    fn sendToolCallCompletedWithCommandResult(self: *AcpContext, tool_call_id: []const u8, result_text: ?[]const u8, command_result_json: ?[]const u8) !void {
        try self.flushCommandOutputPreview(tool_call_id);
        self.clearCommandOutputPreview(tool_call_id);
        try self.stageToolTerminalResult(tool_call_id, .completed, result_text, command_result_json);
    }

    fn sendToolCallError(self: *AcpContext, tool_call_id: []const u8, err_text: []const u8) !void {
        try self.sendToolCallErrorWithCommandResult(tool_call_id, err_text, null);
    }

    fn sendToolCallErrorWithCommandResult(self: *AcpContext, tool_call_id: []const u8, err_text: []const u8, command_result_json: ?[]const u8) !void {
        try self.flushCommandOutputPreview(tool_call_id);
        self.clearCommandOutputPreview(tool_call_id);
        try self.stageToolTerminalResult(tool_call_id, .failed, err_text, command_result_json);
    }

    fn stageToolTerminalResult(
        self: *AcpContext,
        tool_call_id: []const u8,
        status: acp_types.ToolCallStatus,
        content_text: ?[]const u8,
        command_result_json: ?[]const u8,
    ) !void {
        const stable_id = self.published_tool_calls.getKey(tool_call_id) orelse return;
        const owned_content = if (content_text) |value| try self.alloc.dupe(u8, value) else null;
        const owned_command_result = if (command_result_json) |value|
            self.alloc.dupe(u8, value) catch |err| {
                if (owned_content) |owned| self.alloc.free(owned);
                return err;
            }
        else
            null;

        const entry = self.tool_terminals.getOrPut(self.alloc, stable_id) catch |err| {
            if (owned_content) |value| self.alloc.free(value);
            if (owned_command_result) |value| self.alloc.free(value);
            return err;
        };
        if (!entry.found_existing) entry.value_ptr.* = .{};
        if (entry.value_ptr.emitted) {
            if (owned_content) |value| self.alloc.free(value);
            if (owned_command_result) |value| self.alloc.free(value);
            return;
        }
        if (entry.value_ptr.content_text) |old| self.alloc.free(@constCast(old));
        if (entry.value_ptr.command_result_json) |old| self.alloc.free(@constCast(old));
        entry.value_ptr.content_text = owned_content;
        entry.value_ptr.command_result_json = owned_command_result;
        entry.value_ptr.result_status = status;
        try self.publishToolTerminal(stable_id, entry.value_ptr, false);
    }

    fn publishToolTerminal(
        self: *AcpContext,
        stable_id: []const u8,
        terminal: *AcpToolTerminal,
        force: bool,
    ) !void {
        if (terminal.emitted) return;
        if (terminal.lifecycle_status == null and terminal.result_status == null) return;
        if (!force and (terminal.lifecycle_status == null or terminal.result_status == null)) return;
        const status: acp_types.ToolCallStatus = if (terminal.lifecycle_status == .failed or
            terminal.result_status == .failed)
            .failed
        else
            terminal.lifecycle_status orelse terminal.result_status.?;
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try acp_types.writeToolCallTerminalUpdate(
            &out.writer,
            stable_id,
            status,
            terminal.title,
            terminal.content_text,
            terminal.command_result_json,
        );
        try self.sendUpdate(out.writer.buffered());
        terminal.emitted = true;
    }

    fn flushToolTerminals(self: *AcpContext) !void {
        var entries = self.tool_terminals.iterator();
        while (entries.next()) |entry| {
            try self.publishToolTerminal(entry.key_ptr.*, entry.value_ptr, true);
        }
    }

    fn toolContext(self: *AcpContext) tool_runtime.Context {
        return self.toolContextWithGatewayRoute(.live);
    }

    fn toolContextWithGatewayRoute(
        self: *AcpContext,
        gateway_route: GatewayRouteView,
    ) tool_runtime.Context {
        const session = if (self.state.active_session) |*active| active else unreachable;
        const provider_bundle = self.state.cfg.provider_set.select(session.provider);
        const provider_capabilities = provider_bundle.capabilities;
        const search_capabilities = availableProviderModelCapabilities(
            self.state,
            session.provider,
            session.model,
        );
        const search_provider = provider_bundle.web_search.executionProvider(search_capabilities);
        const gateway_chat_url = switch (gateway_route) {
            .live => server.gatewayChatUrl(self.state),
            .snapshot => |route| if (route) |owned|
                owned.chat_url
            else
                self.state.cfg.gateway_chat_url,
        };
        const gateway_models_path = switch (gateway_route) {
            .live => server.gatewayModelsPath(self.state),
            .snapshot => |route| if (route) |owned|
                owned.models_url
            else
                self.state.cfg.gateway_models_path,
        };
        const provider_endpoint_override = switch (gateway_route) {
            .live => server.providerEndpointOverride(self.state, session.provider),
            .snapshot => |route| if (route) |owned|
                if (session.provider == .gateway) owned.chat_url else null
            else
                null,
        };
        if (search_provider) |provider| {
            self.state.web_search_runtime.configureForProvider(provider, .{
                .api_key = session.api_key,
                .credential_source = session.credential_source,
                .account_id = session.account_id,
                .worker_model = session.model,
                .gateway_retry_count = self.state.cfg.gateway_retry_count,
                .gateway_chat_url = gateway_chat_url,
                .usage = &session.session_rt.usage,
                .usage_allocator = self.state.alloc,
            });
        }
        var tc: tool_runtime.Context = .{
            .workspace_root = self.state.workspace_root,
            .access_scope = self.state.workspace_access.scope(self.state.workspace_root),
            .ignored_list_entries = self.state.cfg.ignored_list_entries,
            .max_list_entries = self.state.cfg.max_list_entries,
            .max_read_file_bytes = self.state.cfg.max_read_file_bytes,
            .max_read_file_lines = self.state.cfg.max_read_file_lines,
            .max_read_file_line_len = self.state.cfg.max_read_file_line_len,
            .max_command_output_bytes = self.state.cfg.max_command_output_bytes,
            .max_tool_result_bytes = session.max_tool_result_bytes,
            .api_key = session.api_key,
            .agent_stream_provider = server.streamProviderFor(self.state, session.provider),
            .credential_source = session.credential_source,
            .account_id = session.account_id,
            .provider = session.provider,
            .provider_capabilities = provider_capabilities,
            .oauth_transport = self.state.cfg.gateway_provider.oauth_transport,
            .secret_store = self.state.cfg.secret_store,
            .model = session.model,
            .gateway_retry_count = self.state.cfg.gateway_retry_count,
            .gateway_chat_url = gateway_chat_url,
            .provider_endpoint_override = provider_endpoint_override,
            .gateway_models_path = gateway_models_path,
            .agent_step_limit = session.agent_step_limit,
            .fast_mode = session.fast_mode,
            .effort = session.effort,
            .first_call_tool_choice = session.first_call_tool_choice,
            .permission_mode = self.captured_permission_mode orelse session.permission_mode,
            .permission_grants = session.session_grants,
            .permission_rules = session.permission_rules,
            .tool_registry = self.toolRegistry(),
            .permission_reviewer_provider = self.state.cfg.provider_set.select(session.provider).permission_reviewer,
            .auto_classifier = self.auto_classifier,
            .subagent_host = self.state.subagent_host,
            .subagent_caller_id = session.session_id,
            .worker = &self.state.worker,
            .permission_prompter = if (self.state.initialized) .{
                .context = @ptrCast(self),
                .request_fn = requestAcpPermission,
                .retain_grant_fn = retainAcpGrant,
            } else null,
            .cancel_flag = &session.cancel_flag,
            .background = &self.state.background,
            .session = &session.session_rt,
            .session_allocator = self.alloc,
            .skills_dir = self.state.skills.dir,
            .context_limits = self.state.context_limits,
            .context_enabled = self.state.context_enabled,
            .context_registry = self.state.cfg.context_registry,
            .plan_update_ctx = @ptrCast(self),
            .on_plan_update = onPlanUpdate,
            .output_chunk_ctx = @ptrCast(self),
            .on_output_chunk = onCommandOutputChunk,
            .mcp_progress_ctx = @ptrCast(self),
            .on_mcp_progress = onMcpProgress,
            .background_url_ctx = @ptrCast(self),
            .on_background_url_ready = onBackgroundUrlReady,
            .session_child_capability = if (session.writable) |*writable|
                writable.childCapability() catch null
            else
                null,
            .unified_exec = &self.state.unified_exec,
            .web_fetch_runtime = &self.state.web_fetch_runtime,
            .web_fetch_artifact_store = session.session_rt.webFetchArtifactStore(),
            .web_fetch_artifact_error = session.session_rt.webFetchArtifactError(),
            .web_search_runtime_ready = search_provider != null,
            .web_search_backend = if (search_provider != null)
                self.state.web_search_runtime.dispatchBackend()
            else
                null,
            .model_capability_resolver = .{
                .ctx = @ptrCast(self),
                .resolve_fn = resolveModelCapabilities,
            },
            .interactive = false,
            .lifecycle_view = self.state.lifecycle_view,
            .lifecycle_scope = .{
                .kind = .acp,
                .workspace_root = session.workspace_root,
                .session_id = session.session_id,
            },
        };
        if (comptime !host_target.is_wasm) {
            if (session.mcp != null) {
                tc.mcp_ctx = @ptrCast(self);
                tc.mcp_has_tool = mcpHasTool;
                tc.mcp_validate_tool = mcpValidateTool;
                tc.mcp_call_tool = mcpCallTool;
                tc.mcp_search_tools = mcpSearchTools;
                tc.mcp_tool_schema = mcpToolSchemaJson;
                tc.mcp_call_feature = mcpCallFeature;
            }
        }
        return tc;
    }

    fn modelVisibleProjectContext(self: *const AcpContext) []const u8 {
        if (!self.state.context_enabled) return "";
        return self.state.context_snapshot.modelVisibleBytes();
    }

    fn toolRegistry(self: *const AcpContext) tool_dispatch.Registry {
        return activeToolSet(self.state).registry;
    }
};

fn activeToolSet(state: *const server.ServerState) tool_set_contract.ToolSet {
    if (comptime host_target.is_wasm) return tool_set_contract.empty;
    return if (state.cfg.allow_native_tools) builtin_tools.advertisement_set else tool_set_contract.empty;
}

const AcpElicitationResponderContext = struct {
    const AcceptedLegacyUrl = struct {
        acp_id: []u8,

        fn deinit(self: *AcceptedLegacyUrl, alloc: Allocator) void {
            alloc.free(self.acp_id);
            self.* = undefined;
        }
    };

    acp: *AcpContext,
    tool_call_id: []const u8,
    operation_cancel_flag: ?*const std.atomic.Value(bool),
    accepted_url_ids: std.ArrayListUnmanaged([]u8) = .empty,
    accepted_legacy_urls: std.ArrayListUnmanaged(AcceptedLegacyUrl) = .empty,

    fn deinit(self: *AcpElicitationResponderContext) void {
        for (self.accepted_url_ids.items) |id| self.acp.state.alloc.free(id);
        self.accepted_url_ids.deinit(self.acp.state.alloc);
        for (self.accepted_legacy_urls.items) |*accepted| {
            server.removeLegacyUrl(self.acp.state, accepted.acp_id);
            accepted.deinit(self.acp.state.alloc);
        }
        self.accepted_legacy_urls.deinit(self.acp.state.alloc);
        self.* = undefined;
    }

    fn responder(self: *AcpElicitationResponderContext) ?tool_mcp_runtime.InputResponder {
        const capabilities = self.acp.state.client_elicitation;
        if (!capabilities.any()) return null;
        return .{
            .context = @ptrCast(self),
            .capabilities = capabilities,
            .callback = respondToAcpMcpInput,
            .continuation_terminal = finishAcpUrlElicitations,
        };
    }
};

const Osc8Link = struct {
    uri: []const u8,
    end: usize,
};

/// Parses an OSC-8 hyperlink sequence (`ESC ]8;params;uri ST`) starting at
/// `index`. An empty uri marks the end of a hyperlink span.
fn parseOsc8Link(text: []const u8, index: usize) ?Osc8Link {
    if (!std.mem.startsWith(u8, text[index..], "\x1b]8;")) return null;
    const end = display_width.ansiSequenceEnd(text, index);
    var body_end = end;
    if (body_end > index and text[body_end - 1] == 0x07) {
        body_end -= 1;
    } else if (body_end >= index + 2 and text[body_end - 2] == 0x1b and text[body_end - 1] == '\\') {
        body_end -= 2;
    }
    const body_start = index + "\x1b]8;".len;
    if (body_end < body_start) return null;
    const body = text[body_start..body_end];
    const separator = std.mem.findScalar(u8, body, ';') orelse return null;
    return .{ .uri = body[separator + 1 ..], .end = end };
}

/// Removes ANSI escape sequences so ACP clients receive Markdown-compatible
/// text. OSC-8 hyperlinks become Markdown links so their targets survive the
/// conversion. Returns the original slice when no escape byte is present;
/// callers free the result only when it differs from the input.
fn stripAnsiAlloc(alloc: Allocator, text: []const u8) ![]const u8 {
    if (std.mem.findScalar(u8, text, 0x1b) == null) return text;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var open_link_uri: ?[]const u8 = null;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b) {
            if (parseOsc8Link(text, index)) |link| {
                if (link.uri.len > 0) {
                    if (open_link_uri == null) {
                        try out.append(alloc, '[');
                        open_link_uri = link.uri;
                    }
                } else if (open_link_uri) |uri| {
                    try appendMarkdownLinkClose(alloc, &out, uri);
                    open_link_uri = null;
                }
                index = link.end;
            } else {
                index = display_width.ansiSequenceEnd(text, index);
            }
        } else {
            try out.append(alloc, text[index]);
            index += 1;
        }
    }
    // A link left open by a chunk boundary still closes with its target so
    // the emitted Markdown stays balanced.
    if (open_link_uri) |uri| try appendMarkdownLinkClose(alloc, &out, uri);
    return try out.toOwnedSlice(alloc);
}

fn appendMarkdownLinkClose(alloc: Allocator, out: *std.ArrayList(u8), uri: []const u8) !void {
    try out.appendSlice(alloc, "](");
    try out.appendSlice(alloc, uri);
    try out.append(alloc, ')');
}

fn isCompactCommand(text: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), "/compact");
}

fn handleCompactCommand(
    ctx: *AcpContext,
    session: *server.ActiveSessionState,
) !TerminalOutcome {
    if (!session.session_rt.hasFullCompactionCandidate()) {
        try ctx.sendAgentText("Context is already compacted.");
        return .{ .stop_reason = .end_turn };
    }

    try ctx.sendAgentThought("Compacting context.");
    const history = try session.session_rt.snapshotCompactionHistory(ctx.alloc);
    defer types.freeHistoryTurnSlice(ctx.alloc, history);
    var messages: std.ArrayList(ChatMessage) = .empty;
    defer messages.deinit(ctx.alloc);
    // Keep ACP's compaction input aligned with the interactive TUI: the
    // provider-owned checkpoint represents the conversation, while the
    // current system prompt and model-specific overlay remain stable context
    // that must be included when the remote summary is generated.
    if (ctx.state.cfg.prompt_policy.system_prompt.len > 0) {
        try messages.append(ctx.alloc, .{
            .role = .system,
            .content = ctx.state.cfg.prompt_policy.system_prompt,
        });
    }
    if (ctx.state.cfg.prompt_policy.modelPromptOverlay(session.model)) |overlay| {
        if (overlay.len > 0) {
            try messages.append(ctx.alloc, .{
                .role = .system,
                .content = overlay,
            });
        }
    }
    const history_start = messages.items.len;
    try session_runtime.appendHistoryChatMessages(ctx.alloc, &messages, history);

    var tool_projection = try ctx.state.cfg.mode_registry.buildModelToolProjection(
        ctx.alloc,
        activeToolSet(ctx.state),
        ctx.captured_mode orelse session.mode,
        .{
            .permission_mode = ctx.captured_permission_mode orelse session.permission_mode,
            .permission_rules = session.permission_rules,
            .mcp_runtime = session.mcp,
            .subagent_available = ctx.state.subagent_host != null,
            .web_search_available = providerWebSearchAvailable(
                ctx.state,
                session.provider,
                session.model,
            ),
            .bash_first = ctx.bash_first,
        },
    );
    defer tool_projection.deinit(ctx.alloc);
    const serialized_tools = try model_tool_schema.functionSchemaArrayJsonAlloc(
        ctx.alloc,
        tool_projection.advertised_functions,
    );
    defer ctx.alloc.free(serialized_tools);

    session.cancel_flag.store(false, .seq_cst);
    const capabilities = model_capabilities.capabilitiesForModel(session.model);
    var result = try runtime_compaction.compact(ctx.alloc, .{
        .remote_provider = ctx.state.cfg.provider_set.select(session.provider).responses_compaction,
        .local_provider = server.streamProviderFor(ctx.state, session.provider),
        .credential_source = session.credential_source,
        .credential = session.api_key,
        .account_id = session.account_id,
        .session_id = session.session_id,
        .model = session.model,
        .serialized_tools = serialized_tools,
        .messages = messages.items,
        .history_start = history_start,
        .capabilities = capabilities,
        .provider_options = model_capabilities.resolveProviderOptionsForCapabilities(
            capabilities,
            session.effort,
            session.fast_mode,
        ),
        .local_endpoint_override = server.providerEndpointOverride(ctx.state, session.provider),
        .remote_endpoint_override = server.providerEndpointOverride(ctx.state, session.provider),
        .gateway_retry_count = ctx.state.cfg.gateway_retry_count,
        .usage = &session.session_rt.usage,
        .usage_allocator = ctx.alloc,
        .cancel_flag = &session.cancel_flag,
    });
    defer result.deinit(ctx.alloc);

    const replacement = result.message();
    const changed = try session.session_rt.installCompaction(
        ctx.alloc,
        result.summary,
        replacement.responses_compaction,
    );

    if (changed) {
        session.session_write_mutex.lockUncancelable(io_mod.getIo());
        defer session.session_write_mutex.unlock(io_mod.getIo());
        if (session.writable) |*writable| {
            try commitAcpStateReplacement(ctx.alloc, session, writable, false);
        }
    }
    if (!changed) {
        try ctx.sendAgentText("Context is already compacted.");
    } else {
        var notice_buf: [512]u8 = undefined;
        const notice = runtime_compaction.formatInstalledNotice(
            &notice_buf,
            result.strategy,
            result.detail orelse "",
        );
        try ctx.sendAgentText(notice.body);
    }
    return .{ .stop_reason = .end_turn };
}

/// Runs a prompt turn under the mode and permission policy captured at
/// dispatch. Mid-turn session/set_mode changes only affect later prompts.
pub fn handlePrompt(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    captured_mode: []const u8,
    captured_permission_mode: PermissionMode,
    bash_first: bool,
) !TerminalOutcome {
    const session = if (state.active_session) |*active| active else return .{
        .rpc_error = no_active_session_rpc_error,
    };
    if (!try server.selectCredentialForProvider(state, session.provider)) {
        return .{ .rpc_error = .{
            .code = ErrorCode.invalid_request,
            .message = if (session.provider == .codex)
                credentials.missing_chatgpt_credential_message
            else if (session.provider == .grok)
                credentials.missing_grok_credential_message
            else
                credentials.missing_credential_message,
        } };
    }

    const params = msg.params_raw orelse return .{
        .rpc_error = .{
            .code = ErrorCode.invalid_params,
            .message = "Missing params",
        },
    };

    var prompt_input = parsePromptInput(alloc, params) catch |err| switch (err) {
        error.InvalidPromptImage,
        error.ImageTooLarge,
        => return .{
            .rpc_error = .{
                .code = ErrorCode.invalid_params,
                .message = "Invalid image prompt block",
            },
        },
        else => return err,
    };
    defer prompt_input.deinit(alloc);
    const prompt_text = prompt_input.text;

    if (prompt_input.continue_recovery and (prompt_text.len != 0 or prompt_input.images.len != 0)) {
        return .{
            .rpc_error = .{
                .code = ErrorCode.invalid_params,
                .message = "Recovery continuation cannot include a new prompt",
            },
        };
    }
    if (!prompt_input.continue_recovery and prompt_text.len == 0 and prompt_input.images.len == 0) {
        return .{
            .rpc_error = .{
                .code = ErrorCode.invalid_params,
                .message = "Empty prompt",
            },
        };
    }
    if (comptime host_target.is_wasm) {
        if (prompt_input.images.len > 0) {
            return .{ .rpc_error = .{
                .code = ErrorCode.invalid_params,
                .message = "Image prompts are unavailable in this WASM runtime",
            } };
        }
    }

    try refreshProjectContext(
        state,
        alloc,
        prompt_input.targets,
        prompt_input.omissions,
        prompt_input.omission_summary,
    );

    session.pending_prompt_id = msg.id;
    defer session.pending_prompt_id = null;

    var ctx = AcpContext{
        .alloc = alloc,
        .state = state,
        .session_id = session.session_id,
        .captured_mode = captured_mode,
        .captured_permission_mode = captured_permission_mode,
        .bash_first = bash_first,
    };
    defer ctx.deinitPublishedToolCalls();
    if (!prompt_input.continue_recovery and isCompactCommand(prompt_text)) {
        return handleCompactCommand(&ctx, session);
    }

    var recovery_checkpoint: ?session_codec.RecoveryCheckpoint = null;
    defer if (recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
    if (prompt_input.continue_recovery) {
        const writable = if (session.writable) |*value| value else return .{
            .rpc_error = .{
                .code = ErrorCode.invalid_params,
                .message = "This session does not support durable recovery",
            },
        };
        const checkpoint = writable.state.recovery_checkpoint orelse return .{
            .rpc_error = .{
                .code = ErrorCode.invalid_params,
                .message = "No paused model response to continue",
            },
        };
        recovery_checkpoint = try checkpoint.dupe(alloc);
    }

    var tool_projection = try state.cfg.mode_registry.buildModelToolProjection(alloc, activeToolSet(state), captured_mode, .{
        .permission_mode = captured_permission_mode,
        .permission_rules = session.permission_rules,
        .mcp_runtime = session.mcp,
        .subagent_available = state.subagent_host != null,
        .web_search_available = providerWebSearchAvailable(
            state,
            session.provider,
            session.model,
        ),
        .bash_first = bash_first,
    });
    defer tool_projection.deinit(alloc);

    const owned_prompt = try alloc.dupe(
        u8,
        if (recovery_checkpoint) |checkpoint| checkpoint.user.text else prompt_text,
    );
    defer alloc.free(owned_prompt);

    var bounded_skills = try state.skills.buildRoutedSystemPromptSection(alloc, owned_prompt, state.context_limits);
    defer bounded_skills.deinit(alloc);
    if (bounded_skills.notice) |notice| try pushContextNotice(@ptrCast(&ctx), notice);
    if (bounded_skills.diagnostic_notice) |notice| try pushContextNotice(@ptrCast(&ctx), notice);
    for (state.context_snapshot.notices) |notice| try pushContextNotice(@ptrCast(&ctx), notice);
    const skills_section = bounded_skills.text;

    var explicit_skills = try skill_invocation.buildExplicitPromptSection(
        alloc,
        .{ .skills = state.skills.items, .diagnostics = state.skills.diagnostics },
        owned_prompt,
        &.{},
        state.context_limits,
    );
    defer explicit_skills.deinit(alloc);
    if (explicit_skills.notice) |notice| try pushContextNotice(@ptrCast(&ctx), notice);
    if (explicit_skills.diagnostic_notice) |notice| try pushContextNotice(@ptrCast(&ctx), notice);

    session.session_rt.setConversationLanguageFromUserMessage(owned_prompt);
    const context_history = try session.session_rt.snapshotContextHistory(alloc);
    defer types.freeHistoryTurnSlice(alloc, context_history);
    var context_snapshot = try state.context_snapshot.dupe(alloc);
    defer context_snapshot.deinit(alloc);
    const root_user_intent_context = try auto_classifier_context.buildCanonicalRootUserContext(
        alloc,
        owned_prompt,
        session.session_rt.history.items,
    );
    defer alloc.free(root_user_intent_context);

    var current_images: []types.ImageAttachment = if (recovery_checkpoint) |checkpoint| checkpoint.user.images else &.{};
    var current_images_owned = false;
    if (recovery_checkpoint == null and prompt_input.images.len > 0) {
        current_images = materializeAcpImages(alloc, session, prompt_input.images) catch |err| switch (err) {
            error.ImageTooLarge,
            error.UnsupportedImageType,
            error.ImagePreparationFailed,
            error.ImageSnapshotMediaTypeMismatch,
            => return .{ .rpc_error = .{
                .code = ErrorCode.invalid_params,
                .message = "Image prompt could not be prepared",
            } },
            else => return err,
        };
        current_images_owned = true;
    }
    defer if (current_images_owned) {
        image_attachments.discardImageAttachmentSlice(alloc, current_images);
    };
    const authorized_image_catalog = try session.session_rt.snapshotImageCatalog(alloc, current_images);
    defer types.freeImageAttachmentSlice(alloc, authorized_image_catalog);

    const turn_id = if (recovery_checkpoint) |checkpoint|
        checkpoint.turn_id
    else
        debug_trace.nextTurnId();
    if (state.active_prompt) |active_prompt| active_prompt.setTurnId(turn_id);
    const job: worker_runtime.QueuedPrompt = .{
        .turn_id = turn_id,
        .prompt = @constCast(owned_prompt),
        .images = @constCast(current_images),
        .authorized_image_catalog = authorized_image_catalog,
        .model = session.model,
        .api_key = @constCast(session.api_key),
        .credential_source = session.credential_source,
        .account_id = if (session.account_id) |account_id| @constCast(account_id) else null,
        .provider = session.provider,
        .permission_mode = captured_permission_mode,
        .history = context_history,
        .root_user_intent_context = root_user_intent_context,
        .grants = session.session_grants,
        .context_snapshot = context_snapshot,
        .recovery_checkpoint = recovery_checkpoint,
        .recovery_source_already_presented = recovery_checkpoint != null,
    };

    session.session_rt.usage.configureCheckpointSink(
        if (session.writable != null)
            .{
                .context = @ptrCast(&ctx),
                .allocator = alloc,
                .persist = persistUsageCheckpoint,
            }
        else
            null,
    );
    defer session.session_rt.usage.configureCheckpointSink(null);
    const deps = agentRuntimeDeps(&ctx);
    var agent_config = buildAgentConfig(state, session, .{
        .skills_prompt_section = skills_section,
        .explicit_skills_prompt_section = explicit_skills.text,
        .advertised_tool_names = tool_projection.advertised_names,
        .advertised_functions = tool_projection.advertised_functions,
        .custom_tool_guidance = tool_projection.custom_guidance,
    });
    agent_config.session_child_capability = if (session.writable) |*writable|
        writable.childCapability() catch null
    else
        null;
    var process_succeeded = false;
    agent_runtime.processQueuedPrompt(&deps, null, .{
        .view = state.lifecycle_view,
        .scope = .{
            .kind = .acp,
            .workspace_root = session.workspace_root,
            .session_id = session.session_id,
        },
        .outcome_allocator = alloc,
    }, agent_config, job) catch |err| {
        if (err == error.NonInteractivePermissionRequired) {
            ctx.stop_reason = .refused;
        } else {
            return err;
        }
    };
    process_succeeded = ctx.stop_reason != .refused;

    if (current_images_owned and process_succeeded) {
        // The completed turn has persisted the snapshot metadata in history;
        // release only the temporary attachment structure here.
        types.freeImageAttachmentSlice(alloc, current_images);
        current_images_owned = false;
    }

    if (session.cancel_flag.load(.seq_cst)) {
        ctx.stop_reason = .cancelled;
    }

    return .{ .stop_reason = ctx.stop_reason };
}

fn writePromptResponse(
    state: *server.ServerState,
    alloc: Allocator,
    id: ?jsonrpc.RequestId,
    stop_reason: acp_types.StopReason,
) !void {
    var response: std.Io.Writer.Allocating = .init(alloc);
    defer response.deinit();
    try acp_types.writePromptResponse(&response.writer, stop_reason);
    try state.writer.writeResponse(alloc, id, response.writer.buffered());
}

fn writeTurnId(writer: *std.Io.Writer, turn_id: u64) !void {
    try writer.print("\"turn-{d}\"", .{turn_id});
}

fn parseExpectedTurnId(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |turn_id| if (turn_id > 0) @intCast(turn_id) else null,
        .string => |text| blk: {
            const prefix = "turn-";
            if (!std.mem.startsWith(u8, text, prefix)) break :blk null;
            break :blk std.fmt.parseInt(u64, text[prefix.len..], 10) catch null;
        },
        else => null,
    };
}

fn paramsMatchActiveSession(
    state: *server.ServerState,
    params: std.json.Value,
) bool {
    const active = state.active_session orelse return false;
    if (params != .object) return false;
    const value = params.object.get("sessionId") orelse return false;
    return value == .string and std.mem.eql(u8, value.string, active.session_id);
}

fn rawParamsMatchActiveSession(
    state: *server.ServerState,
    alloc: Allocator,
    params_raw: ?[]const u8,
) bool {
    const raw = params_raw orelse return false;
    const params = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch
        return false;
    defer params.deinit();
    return paramsMatchActiveSession(state, params.value);
}

pub fn handleTurnSteer(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
) !void {
    const active_prompt = state.active_prompt orelse return state.writer.writeError(
        alloc,
        msg.id,
        .{ .code = ErrorCode.invalid_request, .message = "No active turn" },
    );
    const params_raw = msg.params_raw orelse return state.writer.writeError(
        alloc,
        msg.id,
        .{ .code = ErrorCode.invalid_params, .message = "Missing params" },
    );
    const params = std.json.parseFromSlice(std.json.Value, alloc, params_raw, .{}) catch
        return state.writer.writeError(
            alloc,
            msg.id,
            .{ .code = ErrorCode.invalid_params, .message = "Invalid params" },
        );
    defer params.deinit();
    if (!paramsMatchActiveSession(state, params.value)) {
        return state.writer.writeError(
            alloc,
            msg.id,
            .{ .code = ErrorCode.invalid_request, .message = "Session does not own the active turn" },
        );
    }
    const expected_value = params.value.object.get("expectedTurnId") orelse
        return state.writer.writeError(
            alloc,
            msg.id,
            .{ .code = ErrorCode.invalid_params, .message = "Missing expectedTurnId" },
        );
    const expected_turn_id = parseExpectedTurnId(expected_value) orelse
        return state.writer.writeError(
            alloc,
            msg.id,
            .{ .code = ErrorCode.invalid_params, .message = "Invalid expectedTurnId" },
        );
    var prompt_input = parsePromptInput(alloc, params_raw) catch |err| switch (err) {
        error.InvalidPromptImage,
        error.ImageTooLarge,
        => return state.writer.writeError(
            alloc,
            msg.id,
            .{ .code = ErrorCode.invalid_params, .message = "Invalid image steer block" },
        ),
        else => return err,
    };
    defer prompt_input.deinit(alloc);
    if (prompt_input.continue_recovery or prompt_input.text.len == 0 or prompt_input.images.len > 0) {
        return state.writer.writeError(
            alloc,
            msg.id,
            .{ .code = ErrorCode.invalid_params, .message = "Steer input must contain text only" },
        );
    }

    switch (try active_prompt.admitSteer(expected_turn_id, prompt_input.text)) {
        .accepted => {},
        .turn_not_ready => return state.writer.writeError(
            alloc,
            msg.id,
            .{ .code = ErrorCode.invalid_request, .message = "Active turn is not ready for steering" },
        ),
        .turn_mismatch => return state.writer.writeError(
            alloc,
            msg.id,
            .{ .code = ErrorCode.invalid_request, .message = "expectedTurnId does not match the active turn" },
        ),
        .turn_finished => return state.writer.writeError(
            alloc,
            msg.id,
            .{ .code = ErrorCode.invalid_request, .message = "Active turn no longer accepts steering" },
        ),
    }

    var response: std.Io.Writer.Allocating = .init(alloc);
    defer response.deinit();
    try response.writer.writeAll("{\"turnId\":");
    try writeTurnId(&response.writer, expected_turn_id);
    try response.writer.writeAll("}");
    try state.writer.writeResponse(alloc, msg.id, response.writer.buffered());
}

fn writeTurnStatusJson(
    writer: *std.Io.Writer,
    state: *server.ServerState,
) !void {
    try writer.writeAll("{\"sessionId\":");
    if (state.active_session) |session| {
        try jsonrpc.writeJsonStr(session.session_id, writer);
    } else {
        try writer.writeAll("null");
    }
    if (state.active_prompt) |active_prompt| {
        const snapshot = active_prompt.snapshot();
        try writer.writeAll(",\"state\":\"running\",\"activeTurnId\":");
        if (snapshot.turn_id == 0) {
            try writer.writeAll("null");
        } else {
            try writeTurnId(writer, snapshot.turn_id);
        }
        try writer.print(
            ",\"acceptingSteers\":{s},\"pendingSteers\":{d}",
            .{ if (snapshot.accepting_steers) "true" else "false", snapshot.pending_steers },
        );
    } else {
        try writer.writeAll(",\"state\":\"idle\",\"activeTurnId\":null,\"acceptingSteers\":false,\"pendingSteers\":0");
    }
    const cancel_requested = if (state.active_session) |session|
        session.cancel_flag.load(.seq_cst)
    else
        false;
    try writer.print(",\"cancelRequested\":{s}}}", .{
        if (cancel_requested) "true" else "false",
    });
}

pub fn handleTurnStatus(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
) !void {
    if (state.active_session == null) {
        return state.writer.writeError(alloc, msg.id, no_active_session_rpc_error);
    }
    if (!rawParamsMatchActiveSession(state, alloc, msg.params_raw)) {
        return state.writer.writeError(
            alloc,
            msg.id,
            .{ .code = ErrorCode.invalid_request, .message = "Session does not match the active session" },
        );
    }
    var response: std.Io.Writer.Allocating = .init(alloc);
    defer response.deinit();
    try writeTurnStatusJson(&response.writer, state);
    try state.writer.writeResponse(alloc, msg.id, response.writer.buffered());
}

const UnifiedExecWriteInput = struct {
    session_id: []u8,
    process_id: u64,
    chars: []u8,
    max_output_tokens: ?u64 = null,

    fn deinit(self: *UnifiedExecWriteInput, alloc: Allocator) void {
        alloc.free(self.session_id);
        alloc.free(self.chars);
        self.* = undefined;
    }
};

fn parseUnifiedExecWriteInput(
    alloc: Allocator,
    state: *server.ServerState,
    raw: ?[]const u8,
) !UnifiedExecWriteInput {
    const params_raw = raw orelse return error.MissingParams;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params_raw, .{}) catch
        return error.InvalidParams;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidParams;

    const session_value = parsed.value.object.get("sessionId") orelse return error.MissingSessionId;
    if (session_value != .string) return error.InvalidSessionId;
    const active = state.active_session orelse return error.NoActiveSession;
    if (!std.mem.eql(u8, active.session_id, session_value.string)) return error.SessionMismatch;

    const process_value = parsed.value.object.get("processId") orelse return error.MissingProcessId;
    if (process_value != .integer or process_value.integer < 1) return error.InvalidProcessId;
    const process_id = std.math.cast(u64, process_value.integer) orelse return error.InvalidProcessId;

    if (parsed.value.object.get("chars")) |value| {
        if (value != .string) return error.InvalidChars;
    }
    const chars = if (parsed.value.object.get("chars")) |value| value.string else "";

    // Keep validating the legacy field for protocol compatibility, but never
    // honor it on the ACP read loop. Direct process control is intentionally
    // nonblocking regardless of the requested poll duration.
    if (parsed.value.object.get("yieldTimeMs")) |value| {
        if (value != .integer or value.integer < 0) return error.InvalidYieldTime;
        _ = std.math.cast(u64, value.integer) orelse return error.InvalidYieldTime;
    }

    var max_output_tokens: ?u64 = null;
    if (parsed.value.object.get("maxOutputTokens")) |value| {
        if (value != .integer or value.integer < 0) return error.InvalidMaxOutputTokens;
        max_output_tokens = std.math.cast(u64, value.integer) orelse return error.InvalidMaxOutputTokens;
    }

    const owned_session_id = try alloc.dupe(u8, session_value.string);
    errdefer alloc.free(owned_session_id);
    const owned_chars = try alloc.dupe(u8, chars);
    errdefer alloc.free(owned_chars);
    return .{
        .session_id = owned_session_id,
        .process_id = process_id,
        .chars = owned_chars,
        .max_output_tokens = max_output_tokens,
    };
}

fn writeUnifiedExecError(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    err: anyerror,
) !void {
    const code = switch (err) {
        error.NoActiveSession,
        error.SessionMismatch,
        error.UnknownProcessId,
        error.ProcessExited,
        error.ProcessStdinClosed,
        error.WriteWouldBlock,
        => ErrorCode.invalid_request,
        else => ErrorCode.invalid_params,
    };
    const message = switch (err) {
        error.NoActiveSession => "No active session",
        error.SessionMismatch => "Session does not match the active session",
        error.UnknownProcessId => "Unknown Unified Exec process id",
        error.ProcessExited => "Unified Exec process has already exited",
        error.ProcessStdinClosed => "Unified Exec process stdin is closed",
        error.WriteWouldBlock => "Unified Exec process stdin is not ready",
        error.MissingParams => "Missing params",
        error.MissingSessionId => "Missing sessionId",
        error.InvalidSessionId => "sessionId must be a string",
        error.MissingProcessId => "Missing processId",
        error.InvalidProcessId => "processId must be a positive integer",
        error.InvalidChars => "chars must be a string",
        error.InvalidYieldTime => "yieldTimeMs must be a non-negative integer",
        error.InvalidMaxOutputTokens => "maxOutputTokens must be a non-negative integer",
        error.InvalidParams => "Invalid params",
        else => @errorName(err),
    };
    try state.writer.writeError(alloc, msg.id, .{ .code = code, .message = message });
}

fn writeUnifiedExecOptionalInt(writer: *std.Io.Writer, value: anytype) !void {
    if (value) |number| {
        try writer.print("{d}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn writeUnifiedExecResult(
    writer: *std.Io.Writer,
    alloc: Allocator,
    session_id: []const u8,
    requested_process_id: u64,
    result: unified_exec_runtime.Manager.Result,
) !void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);
    try output.appendSlice(alloc, result.stdout);
    if (result.stderr.len > 0) {
        if (output.items.len > 0) try output.append(alloc, '\n');
        try output.appendSlice(alloc, result.stderr);
    }

    try writer.writeAll("{\"sessionId\":");
    try jsonrpc.writeJsonStr(session_id, writer);
    try writer.print(",\"processId\":{d},\"status\":\"{s}\",\"output\":", .{
        requested_process_id,
        @tagName(result.status),
    });
    try jsonrpc.writeJsonStr(output.items, writer);
    try writer.writeAll(",\"wallTimeSeconds\":");
    try writer.print("{d:.3}", .{result.wall_time_seconds});
    try writer.writeAll(",\"exitCode\":");
    try writeUnifiedExecOptionalInt(writer, result.exit_code);
    try writer.writeAll(",\"signal\":");
    try writeUnifiedExecOptionalInt(writer, result.signal);
    try writer.print(",\"stdoutBytes\":{d},\"stderrBytes\":{d},\"truncated\":{s}", .{
        result.stdout_bytes,
        result.stderr_bytes,
        if (result.stdout_truncated or result.stderr_truncated) "true" else "false",
    });
    if (result.command) |command| {
        try writer.writeAll(",\"command\":");
        try jsonrpc.writeJsonStr(command, writer);
    }
    if (result.cwd) |cwd| {
        try writer.writeAll(",\"cwd\":");
        try jsonrpc.writeJsonStr(cwd, writer);
    }
    try writer.writeByte('}');
}

/// Writes to or polls an existing Unified Exec process without routing the
/// request through the model. This is intentionally an fx extension: the
/// native manager owns numeric process IDs and plain pipes, not Codex's
/// connection-scoped PTY handles.
pub fn handleUnifiedExecWriteStdin(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
) !void {
    var input = parseUnifiedExecWriteInput(alloc, state, msg.params_raw) catch |err| {
        return writeUnifiedExecError(state, alloc, msg, err);
    };
    defer input.deinit(alloc);
    var result = state.unified_exec.writeStdinNonblocking(alloc, .{
        .process_id = input.process_id,
        .chars = input.chars,
        .max_output_tokens = input.max_output_tokens,
    }) catch |err| {
        return writeUnifiedExecError(state, alloc, msg, err);
    };
    defer result.deinit(alloc);

    var response: std.Io.Writer.Allocating = .init(alloc);
    defer response.deinit();
    try writeUnifiedExecResult(&response.writer, alloc, input.session_id, input.process_id, result);
    try state.writer.writeResponse(alloc, msg.id, response.writer.buffered());
}

pub fn handleUnifiedExecKill(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
) !void {
    var input = parseUnifiedExecWriteInput(alloc, state, msg.params_raw) catch |err| {
        return writeUnifiedExecError(state, alloc, msg, err);
    };
    defer input.deinit(alloc);
    if (!state.unified_exec.terminate(input.process_id)) {
        return writeUnifiedExecError(state, alloc, msg, error.UnknownProcessId);
    }

    var response: std.Io.Writer.Allocating = .init(alloc);
    defer response.deinit();
    try response.writer.writeAll("{\"sessionId\":");
    try jsonrpc.writeJsonStr(input.session_id, &response.writer);
    try response.writer.print(",\"processId\":{d},\"terminated\":true}}", .{input.process_id});
    try state.writer.writeResponse(alloc, msg.id, response.writer.buffered());
}

fn terminalVisibleInProcessStatus(row: anytype) bool {
    return row.lifecycle == .running or row.lifecycle == .starting;
}

fn writeBackgroundTerminalsJson(
    writer: *std.Io.Writer,
    state: *server.ServerState,
    alloc: Allocator,
) !void {
    var terminal_snapshot = try state.terminal_client.terminalProjection(alloc);
    defer terminal_snapshot.deinit();
    var task_snapshot = try state.background.snapshotTasks(alloc);
    defer task_snapshot.deinit(alloc);

    try writer.writeAll("{\"data\":[");
    var first = true;
    for (terminal_snapshot.rows) |row| {
        if (!terminalVisibleInProcessStatus(row)) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll("{\"kind\":\"terminal\",\"id\":");
        try jsonrpc.writeJsonStr(row.session_id, writer);
        try writer.writeAll(",\"command\":");
        try jsonrpc.writeJsonStr(row.label, writer);
        try writer.writeAll(",\"state\":");
        try jsonrpc.writeJsonStr(@tagName(row.lifecycle), writer);
        try writer.writeAll(",\"backend\":");
        try jsonrpc.writeJsonStr(@tagName(row.backend), writer);
        try writer.writeAll("}");
    }
    for (task_snapshot.items) |task| {
        if (task.state != .running) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll("{\"kind\":\"background\",\"id\":");
        try writer.print("\"background-{d}\",\"command\":", .{task.id});
        try jsonrpc.writeJsonStr(task.command, writer);
        try writer.writeAll(",\"state\":\"running\",\"cwd\":");
        try jsonrpc.writeJsonStr(task.cwd, writer);
        try writer.writeAll("}");
    }
    try writer.writeAll("],\"nextCursor\":null}");
}

pub fn handleBackgroundTerminalsList(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
) !void {
    if (state.active_session == null) {
        return state.writer.writeError(alloc, msg.id, no_active_session_rpc_error);
    }
    if (!rawParamsMatchActiveSession(state, alloc, msg.params_raw)) {
        return state.writer.writeError(
            alloc,
            msg.id,
            .{ .code = ErrorCode.invalid_request, .message = "Session does not match the active session" },
        );
    }
    var response: std.Io.Writer.Allocating = .init(alloc);
    defer response.deinit();
    try writeBackgroundTerminalsJson(&response.writer, state, alloc);
    try state.writer.writeResponse(alloc, msg.id, response.writer.buffered());
}

pub fn isProcessStatusPrompt(
    alloc: Allocator,
    params_raw: ?[]const u8,
) !bool {
    const params = params_raw orelse return false;
    var input = parsePromptInput(alloc, params) catch return false;
    defer input.deinit(alloc);
    return std.mem.eql(u8, std.mem.trim(u8, input.text, " \t\r\n"), "/ps");
}

pub fn handleProcessStatusPrompt(
    state: *server.ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
) !void {
    const session = if (state.active_session) |*active| active else return state.writer.writeError(alloc, msg.id, no_active_session_rpc_error);
    var terminal_snapshot = try state.terminal_client.terminalProjection(alloc);
    defer terminal_snapshot.deinit();
    var task_snapshot = try state.background.snapshotTasks(alloc);
    defer task_snapshot.deinit(alloc);

    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    if (state.active_prompt) |active_prompt| {
        const snapshot = active_prompt.snapshot();
        if (snapshot.turn_id == 0) {
            try text.writer.writeAll("Turn: starting\n");
        } else {
            try text.writer.print("Turn: running (turn-{d})\n", .{snapshot.turn_id});
        }
        try text.writer.print("Pending steers: {d}\n", .{snapshot.pending_steers});
    } else {
        try text.writer.writeAll("Turn: idle\nPending steers: 0\n");
    }

    var running_count: usize = 0;
    for (terminal_snapshot.rows) |row| {
        if (terminalVisibleInProcessStatus(row)) running_count += 1;
    }
    for (task_snapshot.items) |task| {
        if (task.state == .running) running_count += 1;
    }
    if (running_count == 0) {
        try text.writer.writeAll("Background processes: none");
    } else {
        try text.writer.print("Background processes: {d}\n", .{running_count});
        for (terminal_snapshot.rows) |row| {
            if (!terminalVisibleInProcessStatus(row)) continue;
            try text.writer.print(
                "- [{s}] {s} ({s}, {s})\n",
                .{ row.session_id, row.label, @tagName(row.lifecycle), @tagName(row.backend) },
            );
        }
        for (task_snapshot.items) |task| {
            if (task.state != .running) continue;
            try text.writer.print(
                "- [background-{d}] {s} (running)\n",
                .{ task.id, task.command },
            );
        }
    }

    var ctx = AcpContext{
        .alloc = alloc,
        .state = state,
        .session_id = session.session_id,
    };
    defer ctx.deinitPublishedToolCalls();
    try ctx.sendAgentText(text.writer.buffered());
    try writePromptResponse(state, alloc, msg.id, .end_turn);
}

pub fn runSubagentChild(
    raw: ?*anyopaque,
    turn: *subagent_execution.TurnContext,
    message: subagent_domain.QueuedMessage,
    admission: subagent_domain.AdmissionSnapshot,
    cancel: *std.atomic.Value(bool),
) subagent_execution.ServiceError!subagent_execution.RunOutcome {
    const state: *server.ServerState = @ptrCast(@alignCast(raw.?));
    const subagent_host = state.subagent_host orelse return error.ProviderFailed;
    const alloc = state.alloc;
    var gateway_route = if (admission.provider == .gateway)
        server.snapshotGatewayRoute(state, alloc) catch return error.OutOfMemory
    else
        null;
    defer if (gateway_route) |*route| route.deinit(alloc);
    state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
    const active = if (state.active_session) |*session| session else {
        state.subagent_authority_mutex.unlock(io_mod.getIo());
        return error.ProviderFailed;
    };
    const session_id = active.session_id;
    const captured_mode = active.mode;
    const bash_first = state.bash_first;
    const mcp = active.mcp;
    state.subagent_authority_mutex.unlock(io_mod.getIo());
    var ctx = AcpContext{
        .alloc = alloc,
        .state = state,
        .session_id = session_id,
        .captured_mode = captured_mode,
        .captured_permission_mode = admission.permission_mode,
        .bash_first = bash_first,
    };
    defer ctx.deinitPublishedToolCalls();
    var child_projection = state.cfg.mode_registry.buildModelToolProjection(
        alloc,
        builtin_tools.advertisement_set,
        captured_mode,
        .{
            .permission_mode = admission.permission_mode,
            .permission_rules = admission.rules,
            .mcp_runtime = mcp,
            .subagent_available = true,
            .web_search_available = providerWebSearchAvailable(
                state,
                admission.provider,
                admission.model,
            ),
            .bash_first = bash_first,
        },
    ) catch return error.OutOfMemory;
    defer child_projection.deinit(alloc);
    var bounded_skills = state.skills.buildRoutedSystemPromptSection(
        alloc,
        message.content,
        state.context_limits,
    ) catch return error.OutOfMemory;
    defer bounded_skills.deinit(alloc);
    var explicit_skills = skill_invocation.buildExplicitPromptSection(
        alloc,
        .{ .skills = state.skills.items, .diagnostics = state.skills.diagnostics },
        message.content,
        &.{},
        state.context_limits,
    ) catch return error.OutOfMemory;
    defer explicit_skills.deinit(alloc);
    const provider_route_override: ?subagent_agent_adapter.ProviderRouteOverride = if (gateway_route) |*route|
        .{
            .provider = .gateway,
            .api_key = route.credential.token,
            .credential_source = route.credential.source,
            .account_id = route.credential.account_id,
            .endpoint = route.chat_url,
            .models_path = route.models_url,
        }
    else
        null;
    const child_tool_context = ctx.toolContextWithGatewayRoute(
        .{ .snapshot = if (gateway_route) |*route| route else null },
    );
    return subagent_agent_adapter.run(.{
        .host = subagent_host,
        .tool_context = child_tool_context,
        .provider_set = state.cfg.provider_set,
        .resolved_model_capabilities = availableProviderModelCapabilities(
            state,
            admission.provider,
            admission.model,
        ),
        .system_prompt = state.cfg.prompt_policy.system_prompt,
        .model_prompt_overlay = state.cfg.prompt_policy.modelPromptOverlay(admission.model),
        .skills_prompt_section = bounded_skills.text,
        .explicit_skills_prompt_section = explicit_skills.text,
        .advertised_tool_names = child_projection.advertised_names,
        .advertised_functions = child_projection.advertised_functions,
        .custom_tool_guidance = child_projection.custom_guidance,
        .context_registry = state.cfg.context_registry,
        .context_enabled = state.context_enabled,
        .project_context = state.context_snapshot.modelVisibleBytes(),
        .lifecycle_view = state.lifecycle_view,
        .provider_route_override = provider_route_override,
    }, turn, message, admission, cancel);
}

fn refreshProjectContext(
    state: *server.ServerState,
    alloc: Allocator,
    targets: []const context_contract.ApplicableTarget,
    omissions: []const context_contract.ContextOmissionInput,
    omission_summary: ?context_contract.ContextOmissionSummary,
) context_contract.ProviderError!void {
    state.context_snapshot.deinit(alloc);
    if (!state.context_enabled) return;

    state.context_snapshot = state.cfg.context_registry.gatherDefaultSnapshot(alloc, .{
        .workspace_root = state.workspace_root,
        .access_scope = state.workspace_access.scope(state.workspace_root),
        .targets = targets,
        .omissions = omissions,
        .omission_summary = omission_summary,
        .context_limits = state.context_limits,
    }) catch |err| {
        debug_trace.logf("context", "acp gather failed err={s}", .{@errorName(err)});
        return err;
    };
}

const AgentConfigSections = struct {
    skills_prompt_section: []const u8,
    explicit_skills_prompt_section: []const u8,
    advertised_tool_names: []const []const u8 = &.{},
    advertised_functions: []const model_tool_schema.FunctionSchema = &.{},
    custom_tool_guidance: []const u8,
};

fn buildAgentConfig(state: *server.ServerState, session: *server.ActiveSessionState, sections: AgentConfigSections) agent_runtime.Config {
    return .{
        .system_prompt = state.cfg.prompt_policy.system_prompt,
        .model_prompt_overlay = state.cfg.prompt_policy.modelPromptOverlay(session.model),
        .skills_prompt_section = sections.skills_prompt_section,
        .explicit_skills_prompt_section = sections.explicit_skills_prompt_section,
        .gateway_retry_count = state.cfg.gateway_retry_count,
        .gateway_chat_url = server.gatewayChatUrl(state),
        .provider_endpoint_override = server.providerEndpointOverride(state, session.provider),
        .advertised_tool_names = sections.advertised_tool_names,
        .advertised_functions = sections.advertised_functions,
        .provider_capabilities = state.cfg.provider_set.select(session.provider).capabilities,
        .custom_tool_guidance = sections.custom_tool_guidance,
        .agent_step_limit = session.agent_step_limit,
        .max_tool_result_bytes = session.max_tool_result_bytes,
        .cancel_flag = &session.cancel_flag,
        .fast_mode = session.fast_mode,
        .effort = session.effort,
        .first_call_tool_choice = session.first_call_tool_choice,
        .workspace_root = state.workspace_root,
        .access_scope = state.workspace_access.scope(state.workspace_root),
        .origin = if (session.writable) |writable|
            if (writable.external_prompt_origin == .persistent_child) .subagent else .root
        else
            .root,
        .root_user_messages = if (session.writable) |writable|
            writable.external_root_user_messages
        else
            &.{},
        .root_user_evidence_complete = if (session.writable) |writable|
            writable.external_root_user_evidence_complete
        else
            false,
        .current_prompt_is_root_authority = if (session.writable) |writable|
            writable.external_prompt_origin == .persistent_child
        else
            false,
        .context_limits = state.context_limits,
    };
}

const ParsedPromptInput = struct {
    text: []u8,
    images: []AcpImageInput = &.{},
    continue_recovery: bool = false,
    targets: []context_contract.ApplicableTarget = &.{},
    omissions: []context_contract.ContextOmissionInput = &.{},
    omission_summary: ?context_contract.ContextOmissionSummary = null,

    fn deinit(self: *ParsedPromptInput, alloc: Allocator) void {
        alloc.free(self.text);
        for (self.images) |*image| image.deinit(alloc);
        if (self.images.len > 0) alloc.free(self.images);
        for (self.targets) |target| alloc.free(@constCast(target.path));
        if (self.targets.len > 0) alloc.free(self.targets);
        for (self.omissions) |omission| alloc.free(@constCast(omission.source));
        if (self.omissions.len > 0) alloc.free(self.omissions);
        self.* = undefined;
    }
};

const AcpImageInput = struct {
    data: []u8,
    media_type: ?[]u8 = null,

    fn deinit(self: *AcpImageInput, alloc: Allocator) void {
        alloc.free(self.data);
        if (self.media_type) |value| alloc.free(value);
        self.* = undefined;
    }
};

fn materializeAcpImages(
    alloc: Allocator,
    session: *server.ActiveSessionState,
    inputs: []const AcpImageInput,
) ![]types.ImageAttachment {
    const catalog = try session.session_rt.snapshotImageCatalog(alloc, &.{});
    defer types.freeImageAttachmentSlice(alloc, catalog);
    const bounds = try image_attachments.calculate_next_image_id(catalog);
    const snapshot_dir = try session_store.imageSnapshotStorageDir(
        alloc,
        if (session.store) |*store| store.sessions_dir else null,
        if (session.writable) |*writable| writable.active_id else null,
        &session.image_snapshot_temp_dir,
    );
    defer alloc.free(snapshot_dir);

    const attachments = try alloc.alloc(types.ImageAttachment, inputs.len);
    var materialized: usize = 0;
    errdefer {
        image_attachments.discardImageAttachmentSlice(alloc, attachments[0..materialized]);
        alloc.free(attachments);
    }
    for (inputs, 0..) |input, index| {
        const image_id = std.math.add(usize, bounds.next_id, index) catch
            return error.InvalidImageId;
        attachments[index] = try image_attachments.createImageAttachmentFromBytes(
            alloc,
            snapshot_dir,
            image_id,
            input.data,
            if (input.media_type) |value| value else null,
        );
        materialized += 1;
    }
    return attachments;
}

fn parsePromptInput(alloc: Allocator, params_json: []const u8) !ParsedPromptInput {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params_json, .{}) catch
        return .{ .text = try alloc.dupe(u8, "") };
    defer parsed.deinit();

    if (parsed.value != .object) return .{ .text = try alloc.dupe(u8, "") };

    const continue_recovery = blk: {
        const meta = parsed.value.object.get("_meta") orelse break :blk false;
        if (meta != .object) break :blk false;
        const fx = meta.object.get("fx") orelse break :blk false;
        if (fx != .object) break :blk false;
        const value = fx.object.get("continueRecovery") orelse break :blk false;
        break :blk value == .bool and value.bool;
    };

    const prompt_arr = parsed.value.object.get("prompt") orelse
        parsed.value.object.get("input") orelse
        return .{ .text = try alloc.dupe(u8, ""), .continue_recovery = continue_recovery };
    if (prompt_arr != .array) return .{ .text = try alloc.dupe(u8, ""), .continue_recovery = continue_recovery };

    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(alloc);
    var targets: std.ArrayList(context_contract.ApplicableTarget) = .empty;
    defer {
        for (targets.items) |target| alloc.free(@constCast(target.path));
        targets.deinit(alloc);
    }
    var omissions: std.ArrayList(context_contract.ContextOmissionInput) = .empty;
    var omission_summary: context_contract.ContextOmissionSummaryBuilder = .{};
    defer {
        for (omissions.items) |omission| alloc.free(@constCast(omission.source));
        omissions.deinit(alloc);
    }
    var images: std.ArrayList(AcpImageInput) = .empty;
    defer {
        for (images.items) |*image| image.deinit(alloc);
        images.deinit(alloc);
    }

    for (prompt_arr.array.items) |block| {
        if (block != .object) continue;
        const block_type = block.object.get("type") orelse continue;
        if (block_type != .string) continue;

        if (std.mem.eql(u8, block_type.string, "text")) {
            if (block.object.get("text")) |text_val| {
                if (text_val == .string) {
                    if (text_buf.items.len > 0) try text_buf.append(alloc, '\n');
                    try text_buf.appendSlice(alloc, text_val.string);
                }
            }
        } else if (std.mem.eql(u8, block_type.string, "image")) {
            const data_value = block.object.get("data") orelse
                return error.InvalidPromptImage;
            if (data_value != .string or data_value.string.len == 0) {
                return error.InvalidPromptImage;
            }
            const encoded = data_value.string;
            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch
                return error.InvalidPromptImage;
            if (decoded_len == 0 or decoded_len > image_attachments.max_image_bytes) {
                return error.ImageTooLarge;
            }
            const decoded = try alloc.alloc(u8, decoded_len);
            var decoded_owned = true;
            errdefer if (decoded_owned) alloc.free(decoded);
            std.base64.standard.Decoder.decode(decoded, encoded) catch
                return error.InvalidPromptImage;

            var media_type: ?[]u8 = null;
            if (block.object.get("mimeType") orelse block.object.get("mediaType")) |value| {
                if (value != .string or value.string.len == 0) return error.InvalidPromptImage;
                media_type = try alloc.dupe(u8, value.string);
            }
            errdefer if (media_type) |value| alloc.free(value);
            try images.append(alloc, .{ .data = decoded, .media_type = media_type });
            decoded_owned = false;
            media_type = null;
        } else if (std.mem.eql(u8, block_type.string, "resource")) {
            if (block.object.get("resource")) |resource| {
                if (resource == .object) {
                    const uri = if (resource.object.get("uri")) |uri_value|
                        if (uri_value == .string) uri_value.string else ""
                    else
                        "";
                    if (uri.len > 0) {
                        if (try localFileTargetPath(alloc, uri)) |path| {
                            errdefer alloc.free(path);
                            try targets.append(alloc, .{ .path = path, .kind = .file });
                        } else {
                            var duplicate = false;
                            for (omissions.items) |omission| {
                                if (omission.reason == .unsafe_target and std.mem.eql(u8, omission.source, uri)) {
                                    duplicate = true;
                                    break;
                                }
                            }
                            if (!duplicate) {
                                if (omissions.items.len < context_contract.Limits.project_omission_records) {
                                    const source = try alloc.dupe(u8, uri);
                                    errdefer alloc.free(source);
                                    try omissions.append(alloc, .{
                                        .source = source,
                                        .reason = .unsafe_target,
                                    });
                                } else {
                                    omission_summary.add(uri, .unsafe_target);
                                }
                            }
                        }
                    }
                    if (resource.object.get("text")) |text_val| {
                        if (text_val == .string) {
                            if (text_buf.items.len > 0) try text_buf.append(alloc, '\n');
                            if (uri.len > 0) {
                                try text_buf.appendSlice(alloc, "File: ");
                                try text_buf.appendSlice(alloc, uri);
                                try text_buf.append(alloc, '\n');
                            }
                            try text_buf.appendSlice(alloc, text_val.string);
                        }
                    }
                }
            }
        }
    }

    var result = ParsedPromptInput{
        .text = try alloc.dupe(u8, text_buf.items),
        .images = try images.toOwnedSlice(alloc),
        .continue_recovery = continue_recovery,
    };
    errdefer result.deinit(alloc);
    result.targets = try targets.toOwnedSlice(alloc);
    result.omissions = try omissions.toOwnedSlice(alloc);
    result.omission_summary = omission_summary.finish();
    return result;
}

fn localFileTargetPath(alloc: Allocator, uri_text: []const u8) Allocator.Error!?[]u8 {
    const uri = std.Uri.parse(uri_text) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "file") or
        uri.user != null or
        uri.password != null or
        uri.host != null or
        uri.port != null or
        uri.query != null or
        uri.fragment != null)
    {
        return null;
    }

    const encoded_path = switch (uri.path) {
        .raw, .percent_encoded => |path| path,
    };
    const decoded_storage = try alloc.dupe(u8, encoded_path);
    defer alloc.free(decoded_storage);

    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < decoded_storage.len) {
        const byte = if (decoded_storage[read_index] == '%') blk: {
            if (decoded_storage.len - read_index < 3) return null;
            const value = std.fmt.parseInt(
                u8,
                decoded_storage[read_index + 1 .. read_index + 3],
                16,
            ) catch return null;
            read_index += 3;
            break :blk value;
        } else blk: {
            const value = decoded_storage[read_index];
            read_index += 1;
            break :blk value;
        };
        if (byte == 0) return null;
        decoded_storage[write_index] = byte;
        write_index += 1;
    }
    const decoded_path = decoded_storage[0..write_index];
    if (!std.fs.path.isAbsolute(decoded_path)) return null;

    var components = std.mem.splitScalar(u8, decoded_path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return null;
    }

    return io_mod.realpathAlloc(alloc, decoded_path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

fn agentRuntimeDeps(ctx: *AcpContext) agent_runtime.AgentRuntimeDeps {
    const session = if (ctx.state.active_session) |*active| active else unreachable;
    return .{
        .ctx = @ptrCast(ctx),
        .agent_stream_provider = server.streamProviderFor(ctx.state, ctx.state.active_session.?.provider),
        .flush_assistant_stream_per_content_chunk = host_target.is_wasm,
        .tool_registry = ctx.toolRegistry(),
        .context_registry = ctx.state.cfg.context_registry,
        .context_enabled = ctx.state.context_enabled,
        .finalize_turn = finalizeTurn,
        .prepare_parent_turn_context = prepareParentTurnContext,
        .acknowledge_parent_turn_context = acknowledgeParentTurnContext,
        .append_runtime_context = appendRuntimeContext,
        .append_static_context = appendStaticContext,
        .validate_tool_call = validateToolCall,
        .check_tool_availability = checkToolAvailability,
        .request_tool_permission = requestToolPermissionOutcomeWithRequest,
        .request_prepared_file_mutation_permission = requestPreparedFileMutationPermissionOutcomeForRuntime,
        .resolve_tool_action_display_target = resolveToolActionDisplayTarget,
        .describe_tool_action = describeToolAction,
        .describe_tool_action_completed = describeToolActionCompleted,
        .describe_tool_action_denied = describeToolActionDenied,
        .permission_target_for_call = permissionTargetForCall,
        .execute_tool_call = if (comptime host_target.is_wasm) executeWebToolCall else executeToolCall,
        .publish_committed_file_handoff = publishCommittedFileHandoff,
        .publish_deferred_tool_completion = publishDeferredToolCompletion,
        .propagate_history_turn = propagateHistoryTurn,
        .take_pending_steer = takePendingSteer,
        .recovery_checkpoint = if (session.writable != null)
            .{
                .set = setRecoveryCheckpoint,
            }
        else
            null,
        .propagate_grant = retainAcpGrant,
        .push_event = pushEvent,
        .push_text = pushText,
        .push_route_recovery_status = pushRouteRecoveryStatus,
        .push_tool_lifecycle = pushToolLifecycle,
        .push_diff_block = pushDiffBlock,
        .push_system_notice = pushSystemNotice,
        .push_context_notice = pushContextNotice,
        .push_command_output_complete = pushCommandOutputComplete,
        .push_http_error = pushHttpError,
        .refresh_gateway_credential = refreshGatewayCredential,
        .available_model_capabilities = availableModelCapabilities,
        .resolve_model_capabilities = resolveModelCapabilities,
        .format_tool_execution_error = formatToolExecutionError,
        .record_tool_call_rejected = recordToolCallRejected,
        .usage = &session.session_rt.usage,
        .usage_allocator = ctx.state.alloc,
    };
}

fn takePendingSteer(
    raw: *anyopaque,
    alloc: Allocator,
    turn_id: u64,
    finish_if_empty: bool,
) !?worker_runtime.QueuedPrompt {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw));
    const active = ctx.state.active_prompt orelse return null;
    return active.takeSteer(alloc, turn_id, finish_if_empty);
}

fn refreshGatewayCredential(
    raw: *anyopaque,
    alloc: Allocator,
    source: types.CredentialSource,
    mode: auth_runtime.CredentialRefreshMode,
    expected_account_id: ?[]const u8,
) !?[]u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw));
    return server.refreshModelCredential(
        @ptrCast(ctx.state),
        alloc,
        source,
        mode,
        expected_account_id,
    );
}

fn persistUsageCheckpoint(
    raw_ctx: *anyopaque,
    snapshot: session_usage.Snapshot,
) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const active = if (ctx.state.active_session) |*session|
        session
    else
        return error.SessionPersistenceUnavailable;
    if (!std.mem.eql(u8, active.session_id, ctx.session_id)) {
        return error.SessionPersistenceUnavailable;
    }
    active.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer active.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (active.writable) |*value|
        value
    else
        return error.SessionPersistenceUnavailable;
    const store = if (active.store) |*value|
        value
    else
        return error.SessionPersistenceUnavailable;
    const recovery_checkpoint = try store.prepareUsageRecoveryCheckpoint(
        ctx.alloc,
        writable,
        snapshot,
    );
    if (writable.degradedTail() != null) {
        var current = try currentAcpState(
            ctx.alloc,
            active,
            writable,
            recovery_checkpoint.timestamp_ms,
        );
        defer current.deinit(ctx.alloc);
        try writable.retryDegradedWithStateReplacement(
            ctx.alloc,
            current,
            .{},
        );
    }
    _ = try writable.appendEvent(
        ctx.alloc,
        .{ .usage_checkpointed = .{ .usage = snapshot } },
        recovery_checkpoint.timestamp_ms,
        .retry_expected_tail,
        .{ .checkpoint_interval = 0 },
    );
    try store.finishUsageRecoveryCheckpoint(
        writable.active_id,
        recovery_checkpoint,
    );
}

fn availableProviderModelCapabilities(
    state: *server.ServerState,
    provider: model_provider.ProviderId,
    model: []const u8,
) model_capabilities.Capabilities {
    const bundle = state.cfg.provider_set.select(provider);
    return state.capability_resolver.available(
        model,
        bundle.fallbackModelCapabilities(model),
    );
}

fn providerWebSearchAvailable(
    state: *server.ServerState,
    provider: model_provider.ProviderId,
    model: []const u8,
) bool {
    const bundle = state.cfg.provider_set.select(provider);
    return bundle.webSearchAvailable(
        availableProviderModelCapabilities(state, provider, model),
    );
}

fn resolveModelCapabilities(
    raw_ctx: *anyopaque,
    _: Allocator,
    model: []const u8,
) model_capabilities.ResolveError!model_capabilities.Capabilities {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const session = if (ctx.state.active_session) |*active| active else return .{};
    const bundle = ctx.state.cfg.provider_set.select(session.provider);
    return ctx.state.capability_resolver.resolve(
        ctx.state.alloc,
        bundle.model_catalog orelse return bundle.fallbackModelCapabilities(model),
        .{
            .access = credentials.catalogAccessForCredentialAndAccount(
                session.credential_source,
                session.api_key,
                session.account_id,
            ),
            .endpoint = server.gatewayModelsPath(ctx.state),
            .cancel_flag = &session.cancel_flag,
        },
        model,
        bundle.fallbackModelCapabilities(model),
    );
}

fn availableModelCapabilities(
    raw_ctx: *anyopaque,
    model: []const u8,
) model_capabilities.Capabilities {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const session = if (ctx.state.active_session) |*active| active else return .{};
    return ctx.state.capability_resolver.available(
        model,
        ctx.state.cfg.provider_set.select(session.provider).fallbackModelCapabilities(model),
    );
}

fn finalizeTurn(raw_ctx: *anyopaque, turn_id: u64, outcome: types.TurnPresentationOutcome, disposition: ?types.ProviderCompletionDisposition) !void {
    std.debug.assert(turn_id != 0);
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    if (disposition == .length_limited) {
        ctx.stop_reason = .max_output_tokens;
    } else if (outcome == .failed or outcome == .paused) {
        ctx.stop_reason = .refused;
    }
}

fn appendRuntimeContext(raw_ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const session = if (ctx.state.active_session) |*active| active else unreachable;
    try ctx.state.cfg.context_registry.appendDefaultTransient(.{
        .workspace_root = ctx.state.workspace_root,
        .access_scope = ctx.state.workspace_access.scope(ctx.state.workspace_root),
        .interactive = false,
        .permission_mode = ctx.captured_permission_mode orelse session.permission_mode,
        .tracker = null,
        .background = &ctx.state.background,
        .session = &session.session_rt,
    }, arena, messages);
}

fn prepareParentTurnContext(
    raw_ctx: *anyopaque,
    arena: Allocator,
) !?agent_runtime.PreparedParentTurnContext {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const subagent_host = ctx.state.subagent_host orelse return null;
    const session = if (ctx.state.active_session) |*active| active else return null;
    return subagent_host.prepareParentTurnContext(arena, session.session_id);
}

fn acknowledgeParentTurnContext(
    raw_ctx: *anyopaque,
    arena: Allocator,
    acknowledgements: []const agent_runtime.ParentTurnDeliveryAck,
) void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const subagent_host = ctx.state.subagent_host orelse return;
    const retirement_ready = parent_delivery_projector
        .acknowledgeWithRetirementSignal(
        arena,
        subagent_host.sessions,
        subagent_host.manager.options.child_store,
        acknowledgements,
    );
    if (retirement_ready) {
        subagent_host.requestRetirementSweep(io_mod.milliTimestamp());
    }
}

fn appendStaticContext(raw_ctx: *anyopaque, arena: Allocator, messages: *std.ArrayList(ChatMessage)) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    try ctx.state.cfg.context_registry.appendDefaultStatic(.{
        .project_context = ctx.modelVisibleProjectContext(),
    }, arena, messages);
    const active_session = if (ctx.state.active_session) |*session| session else null;
    var snapshot = if (active_session) |session|
        if (session.mcp) |mcp|
            try mcp.snapshotModelCatalog(arena, session.permission_rules, false)
        else
            try mcp_model_catalog.Snapshot.empty(arena)
    else
        try mcp_model_catalog.Snapshot.empty(arena);
    defer snapshot.deinit(arena);
    const section = try mcp_model_catalog.render(arena, snapshot);
    if (section.text.len > 0) {
        try messages.append(arena, .{ .role = .system, .content = section.text });
    }
    if (section.notice) |notice| try pushContextNotice(raw_ctx, notice);
}

fn validateToolCall(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !agent_runtime.ToolCallValidationResult {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.state.active_session) |session| {
        const mode = ctx.captured_mode orelse session.mode;
        if (try ctx.state.cfg.mode_registry.toolPolicyDeniedJson(arena, activeToolSet(ctx.state), mode, call.name)) |reason| {
            return .{ .failure = reason };
        }
    }
    return tool_runtime.validateToolCall(ctx.toolContext(), arena, call);
}

fn checkToolAvailability(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    return tool_runtime.checkToolAvailability(ctx.toolContext(), arena, call);
}

fn requestPreparedFileMutationPermissionOutcomeForRuntime(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, prepared: *tool_admission.PreparedFileMutationCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    var tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(ctx.toolContext(), advertised_dynamic_tool_names);
    tool_ctx.permission_review_turn = review_turn;
    const admission = tool_ctx.admissionInputWithLiveAuthority(live_authority);
    return tool_admission.requestPreparedFileMutationPermissionOutcome(
        admission,
        arena,
        call,
        prepared,
        permission_mode,
        local_grants,
    );
}

fn requestToolPermissionOutcome(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, permission_mode: PermissionMode, local_grants: []const PermissionGrant, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(ctx.toolContext(), advertised_dynamic_tool_names);
    return tool_admission.requestPermissionOutcome(
        tool_ctx.admissionInput(),
        arena,
        call,
        permission_mode,
        local_grants,
    );
}

fn requestToolPermissionOutcomeWithRequest(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, review_turn: permission_auto_classifier.ReviewTurnContext, permission_mode: PermissionMode, local_grants: []const PermissionGrant, live_authority: ?agent_runtime.LiveToolAuthority, revalidation: ?agent_runtime.LivePermissionRevalidation, advertised_dynamic_tool_names: []const []const u8) !command_admission.PermissionOutcome {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    var tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(ctx.toolContext(), advertised_dynamic_tool_names);
    tool_ctx.permission_review_turn = review_turn;
    const admission = tool_ctx.admissionInputWithLiveAuthority(live_authority);
    return if (revalidation) |request| switch (request) {
        .action => |action| tool_admission.revalidateLiveActionPermissionOutcome(
            admission,
            arena,
            call,
            permission_mode,
            local_grants,
            action.authority,
            action.human_approval,
        ),
    } else tool_admission.requestPermissionOutcome(
        admission,
        arena,
        call,
        permission_mode,
        local_grants,
    );
}

const TestReviewTurn = struct {
    tool_calls: [1]ToolCall,
    root_messages: [1][]const u8,

    fn init(root_text: []const u8, call: ToolCall) TestReviewTurn {
        return .{
            .tool_calls = .{call},
            .root_messages = .{root_text},
        };
    }

    fn context(self: *const TestReviewTurn) permission_auto_classifier.ReviewTurnContext {
        return .{
            .model = "openai/gpt-5",
            .pending_assistant = .{ .role = .assistant, .tool_calls = &self.tool_calls },
            .target_call_id = self.tool_calls[0].id,
            .origin = .root,
            .current_root_request = self.root_messages[0],
        };
    }
};

fn requestAcpPermission(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    request: permission_request.PermissionRequest,
    call: ToolCall,
    _: ?*const diff_mod.FileReview,
    _: ?[]const PermissionGrant,
) anyerror!permission_request.OwnedPermissionResponse {
    var validated_arguments: std.Io.Writer.Allocating = .init(alloc);
    defer validated_arguments.deinit();
    try writeValidatedToolArguments(alloc, &validated_arguments.writer, call.arguments_json);

    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const request_id = server.beginPermissionRequest(ctx.state) orelse return error.PermissionRequestAlreadyPending;
    errdefer {
        server.cancelPermissionRequest(ctx.state, request_id);
        _ = server.awaitPermissionDecision(ctx.state, request_id);
    }

    var pending_arena = std.heap.ArenaAllocator.init(alloc);
    defer pending_arena.deinit();
    const tool_call_id = try ctx.sendToolCallPending(pending_arena.allocator(), call);

    var params: std.Io.Writer.Allocating = .init(alloc);
    defer params.deinit();
    try params.writer.writeAll("{\"sessionId\":");
    try jsonrpc.writeJsonStr(ctx.session_id, &params.writer);
    try params.writer.writeAll(",\"toolCall\":{\"toolCallId\":");
    try jsonrpc.writeJsonStr(tool_call_id, &params.writer);
    try params.writer.writeAll(",\"title\":");
    try jsonrpc.writeJsonStr(request.label, &params.writer);
    try params.writer.writeAll(",\"kind\":");
    try jsonrpc.writeJsonStr(mapToolKind(call.name).jsonString(), &params.writer);
    try params.writer.writeAll(",\"status\":\"pending\",\"rawInput\":");
    try params.writer.writeAll(validated_arguments.written());
    try params.writer.writeAll("},\"options\":[");
    try writePermissionOption(&params.writer, "allow_once", "Allow once", "allow_once");
    try params.writer.writeByte(',');
    try writePermissionOption(&params.writer, "allow_always", "Allow for this session", "allow_always");
    try params.writer.writeByte(',');
    try writePermissionOption(&params.writer, "reject_once", "Reject", "reject_once");
    try params.writer.writeAll("]}");

    try ctx.state.writer.writeRequest(
        alloc,
        .{ .integer = @intCast(request_id) },
        "session/request_permission",
        params.writer.buffered(),
    );
    const decision = server.awaitPermissionDecision(ctx.state, request_id);
    return permission_request.OwnedPermissionResponse.init(alloc, decision, null);
}

fn writeValidatedToolArguments(alloc: Allocator, writer: *std.Io.Writer, arguments_json: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch
        return error.InvalidToolArgumentsJson;
    defer parsed.deinit();
    try std.json.Stringify.value(parsed.value, .{}, writer);
}

fn writePermissionOption(
    writer: *std.Io.Writer,
    option_id: []const u8,
    name: []const u8,
    kind: []const u8,
) !void {
    try writer.writeAll("{\"optionId\":");
    try jsonrpc.writeJsonStr(option_id, writer);
    try writer.writeAll(",\"name\":");
    try jsonrpc.writeJsonStr(name, writer);
    try writer.writeAll(",\"kind\":");
    try jsonrpc.writeJsonStr(kind, writer);
    try writer.writeByte('}');
}

fn describeToolAction(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    return tool_presentation.formatPlainAction(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .display_target = display_target,
        .is_available_dynamic_mcp_tool = lifecycleDynamicMcpToolAvailable(ctx, call.name, advertised_dynamic_tool_names),
    });
}

fn resolveToolActionDisplayTarget(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall) !?[]const u8 {
    _ = raw_ctx;
    _ = arena;
    _ = call;
    return null;
}

fn describeToolActionCompleted(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    return tool_presentation.formatPlainActionForState(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .display_target = display_target,
        .is_available_dynamic_mcp_tool = lifecycleDynamicMcpToolAvailable(ctx, call.name, advertised_dynamic_tool_names),
    }, .completed, null);
}

fn describeToolActionDenied(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, display_target: ?[]const u8, label: []const u8, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    return tool_presentation.formatPlainActionForState(arena, .{
        .tool_registry = ctx.toolRegistry(),
        .call = call,
        .display_target = display_target,
        .is_available_dynamic_mcp_tool = lifecycleDynamicMcpToolAvailable(ctx, call.name, advertised_dynamic_tool_names),
    }, .denied, label);
}

fn lifecycleDynamicMcpToolAvailable(ctx: *AcpContext, name: []const u8, advertised_dynamic_tool_names: []const []const u8) bool {
    if (comptime host_target.is_wasm) return false;
    return dynamicMcpToolAvailable(ctx.toolRegistry(), name, advertised_dynamic_tool_names, @ptrCast(ctx), mcpHasTool, .unrestricted);
}

fn dynamicMcpToolAvailable(registry: tool_dispatch.Registry, name: []const u8, advertised_dynamic_tool_names: []const []const u8, mcp_ctx: ?*anyopaque, has_tool: ?McpHasToolFn, access: tool_mcp_runtime.Access) bool {
    if (!tool_presentation.isAdvertisedDynamicMcpName(registry, name, advertised_dynamic_tool_names)) return false;
    const raw_ctx = mcp_ctx orelse return false;
    const has = has_tool orelse return false;
    return has(raw_ctx, name, access);
}

fn permissionTargetForCall(raw_ctx: *anyopaque, arena: Allocator, call: ToolCall, advertised_dynamic_tool_names: []const []const u8) ![]const u8 {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const tool_ctx = tool_runtime.withAdvertisedDynamicToolNames(
        ctx.toolContext(),
        advertised_dynamic_tool_names,
    );
    return tool_admission.permissionTargetForCall(tool_ctx.admissionInput(), arena, call);
}

fn executeWebToolCall(
    _: *anyopaque,
    request: agent_runtime.ToolExecutionRequest,
) !ToolExecutionResult {
    return agent_runtime.unavailableHostToolResult(request.result_allocator);
}

fn executeToolCall(
    raw_ctx: *anyopaque,
    request: agent_runtime.ToolExecutionRequest,
) !ToolExecutionResult {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));

    const acp_id = ctx.sendToolCallPending(request.call_allocator, request.call) catch "call_unknown";
    ctx.sendToolCallProgressText(acp_id, null) catch {};

    var tool_ctx = ctx.toolContext();
    var elicitation_responder = AcpElicitationResponderContext{
        .acp = ctx,
        .tool_call_id = acp_id,
        .operation_cancel_flag = tool_ctx.cancel_flag,
    };
    defer elicitation_responder.deinit();
    tool_ctx.mcp_input_responder = elicitation_responder.responder();
    tool_ctx.root_user_intent_context = request.root_user_intent_context;
    tool_ctx.root_user_messages = request.root_user_messages;
    tool_ctx.root_user_evidence_complete = request.root_user_evidence_complete;
    var progress_ctx = AcpWebSearchProgressContext{ .ctx = ctx, .tool_call_id = acp_id };
    var fetch_progress_ctx = AcpWebFetchProgressContext{ .ctx = ctx, .tool_call_id = acp_id };
    tool_ctx.web_search_progress_ctx = @ptrCast(&progress_ctx);
    tool_ctx.on_web_search_progress = onWebSearchProgress;
    tool_ctx.web_fetch_progress_ctx = @ptrCast(&fetch_progress_ctx);
    tool_ctx.on_web_fetch_progress = onWebFetchProgress;
    tool_ctx.session_grants = request.session_grants;
    tool_ctx.advertised_dynamic_tool_names = request.advertised_dynamic_tool_names;
    tool_ctx.max_tool_result_bytes = request.max_tool_result_bytes;
    const result = tool_runtime.executeToolCallAuthorized(
        tool_ctx,
        request,
    ) catch |err| {
        const err_text = try formatToolExecutionError(
            raw_ctx,
            request.result_allocator,
            request.call.name,
            err,
        );
        sendAuthorizedToolCallError(ctx, request, acp_id, err, err_text);
        return err;
    };

    return completeAuthorizedToolCallTransport(ctx, request, acp_id, result);
}

fn sendAuthorizedToolCallError(
    ctx: *AcpContext,
    _: agent_runtime.ToolExecutionRequest,
    acp_id: []const u8,
    _: anyerror,
    err_text: []const u8,
) void {
    ctx.sendToolCallError(acp_id, err_text) catch {};
}

fn completeAuthorizedToolCallTransport(
    ctx: *AcpContext,
    request: agent_runtime.ToolExecutionRequest,
    acp_id: []const u8,
    result: ToolExecutionResult,
) ToolExecutionResult {
    return completeToolCallTransport(ctx, request.call, acp_id, result);
}

fn completeToolCallTransport(
    ctx: *AcpContext,
    call: ToolCall,
    acp_id: []const u8,
    result: ToolExecutionResult,
) ToolExecutionResult {
    const output_text = toolUpdateContentText(result);
    if (result.status == .failure) {
        ctx.sendToolCallErrorWithCommandResult(
            acp_id,
            output_text,
            result.command_result_json,
        ) catch {};
        return result;
    }
    if (file_mutation_contract.isToolName(call.name) and
        result.committed_file_handoff != null)
    {
        var deferred = result;
        deferred.deferred_tool_completion = .{
            .transport_id = acp_id,
            .content_text = output_text,
            .command_result_json = result.command_result_json,
        };
        return deferred;
    }
    ctx.sendToolCallCompletedWithCommandResult(
        acp_id,
        output_text,
        result.command_result_json,
    ) catch {};
    return result;
}

fn publishCommittedFileHandoff(
    _: *anyopaque,
    _: file_mutation.CommittedFileHandoff,
) agent_runtime.SecondaryPublicationReport {
    return .{ .diff = .skipped, .tracker = .skipped };
}

fn publishDeferredToolCompletion(
    raw_ctx: *anyopaque,
    completion: agent_runtime.DeferredToolCompletion,
) agent_runtime.TransportPublicationOutcome {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    ctx.sendToolCallCompletedWithCommandResult(
        completion.transport_id,
        completion.content_text,
        completion.command_result_json,
    ) catch |err| {
        debug_trace.logf(
            "acp",
            "deferred ACP completion publication failed call_id={s} err={s}",
            .{ completion.transport_id, @errorName(err) },
        );
        return .failed;
    };
    return .published;
}

const AcpWebSearchProgressContext = struct {
    ctx: *AcpContext,
    tool_call_id: []const u8,
};

const AcpWebFetchProgressContext = struct {
    ctx: *AcpContext,
    tool_call_id: []const u8,
};

fn onWebSearchProgress(raw_ctx: *anyopaque, _: []const u8, progress: types.WebSearchProgress) void {
    const progress_ctx: *AcpWebSearchProgressContext = @ptrCast(@alignCast(raw_ctx));
    progress_ctx.ctx.sendWebSearchProgress(progress_ctx.tool_call_id, progress) catch {};
}

fn onWebFetchProgress(raw_ctx: *anyopaque, _: []const u8, progress: types.WebFetchProgress) void {
    const progress_ctx: *AcpWebFetchProgressContext = @ptrCast(@alignCast(raw_ctx));
    progress_ctx.ctx.sendWebFetchProgress(progress_ctx.tool_call_id, progress) catch {};
}

fn writeWebSearchProgressUpdate(alloc: Allocator, writer: *std.Io.Writer, tool_call_id: []const u8, progress: types.WebSearchProgress) !void {
    const text = try tool_presentation.formatWebSearchProgressPlain(alloc, progress);
    defer alloc.free(text);
    try acp_types.writeToolCallUpdate(writer, tool_call_id, .in_progress, text);
}

fn writeWebFetchProgressUpdate(alloc: Allocator, writer: *std.Io.Writer, tool_call_id: []const u8, progress: types.WebFetchProgress) !void {
    const text = try tool_presentation.formatWebFetchProgressPlain(alloc, progress);
    defer alloc.free(text);
    try acp_types.writeToolCallUpdate(writer, tool_call_id, .in_progress, text);
}

fn recordToolCallRejected(
    raw_ctx: *anyopaque,
    arena: Allocator,
    call: ToolCall,
    model_output: []const u8,
    command_result_json: ?[]const u8,
) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const acp_id = ctx.sendToolCallPending(arena, call) catch "call_unknown";
    ctx.sendToolCallErrorWithCommandResult(
        acp_id,
        toolUpdateContentText(.{
            .status = .failure,
            .model_output = model_output,
        }),
        command_result_json,
    ) catch {};
}

fn toolUpdateContentText(result: ToolExecutionResult) []const u8 {
    if (!text_utils.isModelSafeText(result.model_output)) {
        debug_trace.logf(
            "acp",
            "tool update omitted binary or non-utf8 output bytes={d}",
            .{result.model_output.len},
        );
        return "binary or non-utf8 tool output omitted";
    }
    if (result.status == .failure and
        (tool_result_errors.isToolPermissionDeniedOutput(result.model_output) or
            tool_result_errors.isToolReviewHeldOutput(result.model_output)))
    {
        return result.model_output;
    }
    return text_utils.utf8PrefixByBytes(result.model_output, 200);
}

fn propagateHistoryTurn(raw_ctx: *anyopaque, turn: HistoryTurn) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    if (ctx.state.active_session) |*session| {
        try persistAcpHistoryTurn(ctx.alloc, session, turn);
    }
}

fn persistAcpHistoryTurn(
    alloc: Allocator,
    session: *server.ActiveSessionState,
    turn: HistoryTurn,
) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    try session.session_rt.appendHistoryEntry(alloc, turn);
    if (comptime host_target.is_wasm) {
        try sessions.commitWasmSessionLocked(alloc, session);
        return;
    }
    const writable = if (session.writable) |*value| value else return;
    try subagent_resume_admission.retainExternalRootUserTurn(
        alloc,
        writable,
        turn,
    );
    if (writable.degradedTail() != null) {
        const now_ms = io_mod.milliTimestamp();
        var current = try currentAcpState(alloc, session, writable, now_ms);
        defer current.deinit(alloc);
        if (current.recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
        current.recovery_checkpoint = null;
        try writable.retryDegradedWithStateReplacement(
            alloc,
            current,
            .{},
        );
        if (current.usage) |usage| session.session_rt.usage.markClean(usage);
        return;
    }
    _ = writable.appendEvent(
        alloc,
        .{ .history_turn_committed = .{
            .conversation_language = session.session_rt.languageSnapshot(),
            .total_input_tokens = writable.state.total_input_tokens,
            .total_output_tokens = writable.state.total_output_tokens,
            .turn = turn,
        } },
        io_mod.milliTimestamp(),
        .retry_expected_tail,
        .{},
    ) catch |err| switch (err) {
        error.EventFrameTooLarge => {
            try commitAcpStateReplacement(alloc, session, writable, true);
            return;
        },
        else => return err,
    };
}

test "ACP degraded history repair commits the finished turn once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var state = session_codec.DurableSessionState{
        .id = try alloc.dupe(u8, "acp-degraded-history"),
        .origin_workspace_root = try alloc.dupe(u8, workspace),
        .workspace_root = try alloc.dupe(u8, workspace),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session_runtime.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = try alloc.dupe(u8, "test/model"),
            .effort = .auto,
            .fast_mode = false,
        },
        .history = try alloc.alloc(HistoryTurn, 0),
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    defer state.deinit(alloc);
    const writable = try store.startWritableSession(alloc, state);
    var session = server.ActiveSessionState{
        .session_id = try alloc.dupe(u8, state.id),
        .writable = writable,
        .model = try alloc.dupe(u8, state.preferences.model),
        .mode = "code",
        .workspace_root = workspace,
        .api_key = "",
        .agent_step_limit = 1,
        .max_tool_result_bytes = 1024,
        .fast_mode = false,
        .effort = .auto,
        .first_call_tool_choice = .auto,
        .permission_mode = .auto,
        .permission_rules = .{},
        .session_rt = .{ .max_history_turns = 8 },
        .cancel_flag = std.atomic.Value(bool).init(false),
        .pending_prompt_id = null,
    };
    defer {
        session.session_rt.deinit(alloc);
        session.writable.?.deinit(alloc);
        alloc.free(session.model);
        alloc.free(session.session_id);
    }

    const Failure = struct {
        fn boundary(_: ?*anyopaque, point: session_log.Boundary) !void {
            if (point == .after_event_sync) return error.InjectedBoundaryFailure;
        }
    };
    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        session.writable.?.appendEvent(
            alloc,
            .{ .preferences_changed = .{ .fast_mode = true } },
            2,
            .retry_expected_tail,
            .{ .test_controls = .{ .boundary_fn = Failure.boundary } },
        ),
    );
    try std.testing.expect(session.writable.?.degradedTail() != null);

    const turn = try session_runtime.makeAssistantTurn(alloc, "hello", "done");
    defer types.freeHistoryTurn(alloc, turn);
    try persistAcpHistoryTurn(alloc, &session, turn);

    try std.testing.expect(session.writable.?.degradedTail() == null);
    try std.testing.expectEqual(@as(usize, 1), session.session_rt.history.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.writable.?.state.history.len);
    try std.testing.expectEqualStrings(
        "done",
        session.writable.?.state.history[0].assistant.assistant,
    );
}

fn setRecoveryCheckpoint(
    raw_ctx: *anyopaque,
    checkpoint: session_codec.RecoveryCheckpoint,
) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const session = if (ctx.state.active_session) |*value| value else return error.SessionPersistenceUnavailable;
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (session.writable) |*value| value else return error.SessionPersistenceUnavailable;
    const now_ms = io_mod.milliTimestamp();
    _ = writable.appendEvent(
        ctx.alloc,
        .{ .recovery_checkpoint_set = .{ .checkpoint = checkpoint } },
        now_ms,
        .retry_expected_tail,
        .{},
    ) catch |err| switch (err) {
        error.EventFrameTooLarge => {
            var current = try currentAcpState(ctx.alloc, session, writable, now_ms);
            defer current.deinit(ctx.alloc);
            if (current.recovery_checkpoint) |*old| old.deinit(ctx.alloc);
            current.recovery_checkpoint = try checkpoint.dupe(ctx.alloc);
            _ = try writable.commitStateReplacement(
                ctx.alloc,
                current,
                .compaction,
                .retry_expected_tail,
                .{},
            );
        },
        else => return err,
    };
}

fn currentAcpState(
    alloc: Allocator,
    session: *server.ActiveSessionState,
    writable: *session_store.LoadedWritableSession,
    now_ms: i64,
) !session_codec.DurableSessionState {
    var state = try writable.state.dupe(alloc);
    errdefer state.deinit(alloc);
    const history = try session.session_rt.snapshotHistory(alloc);
    types.freeHistoryTurnSlice(alloc, state.history);
    state.history = history;
    state.context_history_start = session.session_rt.contextHistoryStart();
    const permission_state = try session.session_rt.snapshotPermissionState(alloc);
    state.permission_state.deinit(alloc);
    state.permission_state = permission_state;
    state.conversation_language = session.session_rt.languageSnapshot();
    state.updated_at_ms = now_ms;
    const usage = try session.session_rt.usage.snapshot(alloc);
    if (state.usage) |*old| old.deinit(alloc);
    state.usage = usage;
    return state;
}

fn commitAcpStateReplacement(
    alloc: Allocator,
    session: *server.ActiveSessionState,
    writable: *session_store.LoadedWritableSession,
    clear_recovery_checkpoint: bool,
) !void {
    const now_ms = io_mod.milliTimestamp();
    var state = try currentAcpState(alloc, session, writable, now_ms);
    defer state.deinit(alloc);
    if (clear_recovery_checkpoint) {
        if (state.recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
        state.recovery_checkpoint = null;
    }
    _ = try writable.commitStateReplacement(
        alloc,
        state,
        .compaction,
        .retry_expected_tail,
        .{},
    );
    if (state.usage) |usage| {
        session.session_rt.usage.markClean(usage);
    }
}

/// Stores grants on the active ACP session without persisting them.
fn retainAcpGrant(raw_ctx: *anyopaque, tool_name: []const u8, target_path: []const u8) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    ctx.state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
    defer ctx.state.subagent_authority_mutex.unlock(io_mod.getIo());
    const session = if (ctx.state.active_session) |*active| active else return;
    try session.retainGrant(ctx.alloc, tool_name, target_path);
}

fn pushEvent(raw_ctx: *anyopaque, event: worker_runtime.WorkerEvent) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    switch (event) {
        .clear_route_recovery_status => try ctx.clearModelRecoveryStatus(),
        else => {},
    }
    worker_runtime.freeWorkerEvent(std.heap.c_allocator, event);
}

fn onPlanUpdate(
    raw_ctx: ?*anyopaque,
    explanation: ?[]const u8,
    plan: []const tool_dispatch.PlanStep,
) error{OutOfMemory}!void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx orelse return));
    var out: std.Io.Writer.Allocating = .init(ctx.alloc);
    defer out.deinit();
    acp_types.writePlanUpdate(&out.writer, explanation, plan) catch return error.OutOfMemory;
    ctx.sendUpdate(out.writer.buffered()) catch return error.OutOfMemory;
}

fn pushRouteRecoveryStatus(
    raw_ctx: *anyopaque,
    status: types.RouteRecoveryStatus,
) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    try ctx.sendModelRecoveryStatus(status);
}

fn pushText(raw_ctx: *anyopaque, emission: agent_runtime.TextEmission) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const text = switch (emission) {
        .assistant_source => |text| text,
        .assistant_rendered => return,
        .operational => |text| text,
        .thought => |text| {
            if (text.len > 0) ctx.sendAgentThought(text) catch {};
            return;
        },
    };
    if (text.len == 0) return;
    ctx.sendAgentText(text) catch {};
}

fn pushToolLifecycle(raw_ctx: *anyopaque, event: types.ToolLifecycleEvent) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    switch (event) {
        .authoritative_started => |started| {
            var arena_state = std.heap.ArenaAllocator.init(ctx.alloc);
            defer arena_state.deinit();
            _ = try ctx.sendToolCallPending(arena_state.allocator(), .{
                .id = started.id.call_id,
                .name = started.tool_name,
                .arguments_json = started.arguments_json orelse "{}",
            });
        },
        .terminal => |terminal| try ctx.sendToolCallTerminalPresentation(
            terminal.id.call_id,
            terminal.outcome,
        ),
        .turn_finished => try ctx.flushToolTerminals(),
        .provisional, .progress => {},
    }
}

fn pushSystemNotice(raw_ctx: *anyopaque, text: []const u8) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    ctx.sendAgentText(text) catch {};
}

fn pushContextNotice(raw_ctx: *anyopaque, text: []const u8) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const session = if (ctx.state.active_session) |*active| active else return;
    if (!try session.session_rt.claimContextNotice(ctx.alloc, text)) return;
    try pushSystemNotice(raw_ctx, text);
}

fn pushDiffBlock(raw_ctx: *anyopaque, payload: agent_runtime.DiffEntryPayload) !void {
    defer diff_mod.freeDiffEntryPayload(std.heap.c_allocator, payload);
    try pushText(raw_ctx, .{ .operational = payload.preview });
}

fn pushCommandOutputComplete(_: *anyopaque, _: ?types.ToolLifecycleId) !void {}

fn pushHttpError(raw_ctx: *anyopaque, status: std.http.Status, detail: []const u8, credential_source: ?types.CredentialSource) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    var buf: [1024]u8 = undefined;
    const auth_failure = auth_runtime.FailureSnapshot.fromHttp(status, credential_source);
    const owned_message = if (auth_failure) |failure|
        try failure.renderText(ctx.alloc)
    else
        null;
    defer if (owned_message) |message| ctx.alloc.free(message);
    const msg = owned_message orelse if (detail.len > 0)
        std.fmt.bufPrint(&buf, "HTTP {d}: {s}", .{ @intFromEnum(status), detail }) catch "HTTP error"
    else
        std.fmt.bufPrint(&buf, "HTTP {d}", .{@intFromEnum(status)}) catch "HTTP error";
    ctx.sendAgentText(msg) catch {};
}

fn formatToolExecutionError(_: *anyopaque, arena: Allocator, tool_name: []const u8, err: anyerror) ![]const u8 {
    return tool_result_errors.formatToolExecutionErrorJson(arena, tool_name, err);
}

fn onCommandOutputChunk(raw_ctx: *anyopaque, lifecycle_id: ?types.ToolLifecycleId, stream: command_output_content.Stream, chunk: []const u8) !void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const id = lifecycle_id orelse return;
    try ctx.sendCommandOutputDelta(id.call_id, stream, chunk);
}

fn onMcpProgress(raw_ctx: *anyopaque, lifecycle_id: types.ToolLifecycleId, text: []const u8) void {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    ctx.sendToolCallProgressText(lifecycle_id.call_id, text) catch |err| {
        debug_trace.logf("mcp", "failed to publish ACP MCP progress err={s}", .{@errorName(err)});
    };
}

const AcpInputResponse = struct {
    key: []const u8,
    json: []u8,

    fn deinit(self: *AcpInputResponse, alloc: Allocator) void {
        alloc.free(self.json);
        self.* = undefined;
    }
};

fn respondToAcpMcpInput(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    origin: tool_mcp_runtime.InputOrigin,
    required: tool_mcp_runtime.InputRequired,
) anyerror![]const u8 {
    const responder: *AcpElicitationResponderContext = @ptrCast(@alignCast(raw_ctx));
    const requests = try mrtr.parseRequestJsonForWire(
        alloc,
        required.input_requests_json,
        origin.wire,
        .{},
    );
    defer {
        for (requests) |*request| request.deinit(alloc);
        alloc.free(requests);
    }
    if (requests.len == 0) return error.McpInputRequired;

    const responses = try alloc.alloc(AcpInputResponse, requests.len);
    var response_count: usize = 0;
    errdefer {
        for (responses[0..response_count]) |*response| response.deinit(alloc);
        alloc.free(responses);
    }

    var cancelled = false;
    for (requests) |request| {
        const response_json = if (cancelled)
            try alloc.dupe(u8, "{\"action\":\"cancel\"}")
        else response: {
            const input_request = switch (request.payload) {
                .elicitation_create => |value| value,
                else => return error.McpInputRequired,
            };
            if (!responder.acp.state.client_elicitation.supports(input_request.mode)) {
                return error.McpInputRequired;
            }
            const direct = try requestAcpElicitation(
                responder,
                alloc,
                origin,
                input_request,
            );
            if (std.mem.eql(u8, direct, "{\"action\":\"cancel\"}")) cancelled = true;
            break :response direct;
        };
        responses[response_count] = .{ .key = request.key, .json = response_json };
        response_count += 1;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('{');
    for (responses, 0..) |response, index| {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(response.key, .{}, &out.writer);
        try out.writer.writeByte(':');
        try out.writer.writeAll(response.json);
    }
    try out.writer.writeByte('}');
    const result = try out.toOwnedSlice();
    for (responses) |*response| response.deinit(alloc);
    alloc.free(responses);
    return result;
}

fn requestAcpElicitation(
    responder: *AcpElicitationResponderContext,
    alloc: Allocator,
    origin: tool_mcp_runtime.InputOrigin,
    input_request: mcp_elicitation.Request,
) ![]u8 {
    const state = responder.acp.state;
    const outbound_id = (try server.beginOutboundRequest(state, .elicitation)) orelse
        return error.McpInputRequired;
    var awaiting = true;
    errdefer if (awaiting) {
        server.cancelOutboundRequest(state, outbound_id);
        if (server.awaitOutboundResponse(state, outbound_id, .elicitation)) |owned| {
            var response = owned;
            response.deinit(state.alloc);
        }
    };

    var id_buffer: [48]u8 = undefined;
    const url_id = if (input_request.mode == .url)
        try std.fmt.bufPrint(&id_buffer, "fx-{d}", .{outbound_id})
    else
        null;
    const legacy_source_id = if (origin.wire.isLegacy() and input_request.mode == .url)
        input_request.elicitation_id orelse return error.McpInputRequired
    else
        null;
    var legacy_url_retained = false;
    if (legacy_source_id) |source_id| {
        if (!try server.reserveLegacyUrl(
            state,
            origin,
            source_id,
            url_id.?,
            responder.acp.session_id,
            responder.tool_call_id,
        )) return error.McpInputRequired;
        if (activeMcp(responder.acp)) |runtime| {
            runtime.reconcileLegacyUrlCompletion(
                origin,
                source_id,
                server.legacyUrlCompletionSink(state),
            );
        }
    }
    defer if (legacy_source_id != null and !legacy_url_retained) {
        server.removeLegacyUrl(state, url_id.?);
    };
    const display_message = try formatAcpElicitationMessage(alloc, origin.server_name, input_request);
    defer alloc.free(display_message);
    const params = try mcp_elicitation.projectToAcpCreateParams(
        alloc,
        input_request,
        .{ .session = .{
            .session_id = responder.acp.session_id,
            .tool_call_id = responder.tool_call_id,
        } },
        url_id,
        display_message,
        .{},
    );
    defer alloc.free(params);
    try state.writer.writeRequest(
        alloc,
        .{ .integer = @intCast(outbound_id) },
        "elicitation/create",
        params,
    );

    const maybe_response = try awaitAcpElicitationResponse(
        state,
        outbound_id,
        origin,
        responder.operation_cancel_flag,
    );
    awaiting = false;
    var response = maybe_response orelse return error.Cancelled;
    defer response.deinit(state.alloc);
    if (response.cancelled) return error.Cancelled;
    if (response.error_json != null) return error.McpInputRequired;
    const response_json = response.result_json orelse return error.McpInputRequired;

    var projected_request = try mcp_elicitation.parseRequest(alloc, .acp, params, .{});
    defer projected_request.deinit(alloc);
    const canonical_response = try mcp_elicitation.canonicalResponse(
        alloc,
        projected_request,
        response_json,
        .{},
    );
    errdefer alloc.free(canonical_response);
    const action = try mcp_elicitation.validateResponse(
        alloc,
        projected_request,
        canonical_response,
        .{},
    );
    var transition_state: mcp_elicitation.RequestState = .pending;
    const live_witness = if (activeMcp(responder.acp)) |runtime|
        runtime.inputIdentityWitness(origin.server_name)
    else
        null;
    const transition = mcp_elicitation.decideTransition(
        transition_state,
        bindingForAcpInput(responder, origin),
        answerBindingForAcpInput(responder, origin, live_witness),
        acpAwakeMillis(),
        live_witness != null,
    );
    switch (transition) {
        .consume => transition_state = .consumed,
        .reject => return error.McpInputRequired,
    }
    std.debug.assert(transition_state == .consumed);

    if (input_request.mode == .url and action == .accept) {
        if (legacy_source_id != null) {
            const runtime = activeMcp(responder.acp) orelse return error.McpInputRequired;
            const accept_result = runtime.acceptLegacyUrlCompletion(
                origin,
                url_id.?,
                server.legacyUrlCompletionSink(state),
            ) orelse return error.McpInputRequired;
            if (accept_result == .awaiting_completion) {
                const retained_acp_id = try state.alloc.dupe(u8, url_id.?);
                errdefer state.alloc.free(retained_acp_id);
                try responder.accepted_legacy_urls.append(state.alloc, .{
                    .acp_id = retained_acp_id,
                });
                legacy_url_retained = true;
            }
        } else {
            const retained_id = try state.alloc.dupe(u8, url_id.?);
            errdefer state.alloc.free(retained_id);
            try responder.accepted_url_ids.append(state.alloc, retained_id);
        }
    }
    return canonical_response;
}

fn formatAcpElicitationMessage(
    alloc: Allocator,
    server_name: []const u8,
    request: mcp_elicitation.Request,
) ![]u8 {
    return switch (request.mode) {
        .form => std.fmt.allocPrint(
            alloc,
            "fx received a form request from MCP server {s}. {s}",
            .{ server_name, request.message },
        ),
        .url => std.fmt.allocPrint(
            alloc,
            "fx received a URL request from MCP server {s} for host {s}. {s}",
            .{ server_name, request.url_host orelse "unknown", request.message },
        ),
        .unknown => error.McpInputRequired,
    };
}

fn bindingForAcpInput(
    responder: *AcpElicitationResponderContext,
    origin: tool_mcp_runtime.InputOrigin,
) mcp_elicitation.Binding {
    return .{
        .server_name = origin.server_name,
        .scope = .{ .acp_session = .{
            .session_id = responder.acp.session_id,
            .tool_call_id = responder.tool_call_id,
        } },
        .runtime_generation = origin.runtime_generation,
        .connection_generation = origin.connection_generation,
        .client_generation = origin.client_generation,
        .catalog_generation = origin.catalog_generation,
        .request_generation = origin.request_generation,
        .auth_generation = origin.auth_generation,
        .deadline_ms = origin.deadline_ms,
    };
}

fn answerBindingForAcpInput(
    responder: *AcpElicitationResponderContext,
    origin: tool_mcp_runtime.InputOrigin,
    witness: ?tool_mcp_runtime.InputIdentityWitness,
) mcp_elicitation.AnswerBinding {
    const current: tool_mcp_runtime.InputIdentityWitness = witness orelse .{
        .runtime_generation = origin.runtime_generation,
        .connection_generation = origin.connection_generation,
        .client_generation = origin.client_generation,
        .catalog_generation = origin.catalog_generation,
        .auth_generation = origin.auth_generation,
    };
    return .{
        .server_name = origin.server_name,
        .scope = .{ .acp_session = .{
            .session_id = responder.acp.session_id,
            .tool_call_id = responder.tool_call_id,
        } },
        .runtime_generation = current.runtime_generation,
        .connection_generation = current.connection_generation,
        .client_generation = current.client_generation,
        .catalog_generation = current.catalog_generation,
        .request_generation = origin.request_generation,
        .auth_generation = current.auth_generation,
    };
}

const AcpElicitationWait = union(enum) {
    response: ?server.OutboundResponse,
    deadline: anyerror!void,
    cancelled: anyerror!void,
};

fn awaitAcpElicitationResponse(
    state: *server.ServerState,
    id: u64,
    origin: tool_mcp_runtime.InputOrigin,
    operation_cancel_flag: ?*const std.atomic.Value(bool),
) !?server.OutboundResponse {
    const Cleanup = struct {
        fn drain(state_alloc: Allocator, select: *std.Io.Select(AcpElicitationWait)) void {
            while (select.cancel()) |item| switch (item) {
                .response => |maybe_response| if (maybe_response) |owned| {
                    var response = owned;
                    response.deinit(state_alloc);
                },
                .deadline, .cancelled => {},
            };
        }
    };

    var select_buffer: [3]AcpElicitationWait = undefined;
    var select: std.Io.Select(AcpElicitationWait) = .init(io_mod.getIo(), &select_buffer);
    try select.concurrent(.response, server.awaitOutboundResponse, .{ state, id, server.OutboundKind.elicitation });
    select.concurrent(.deadline, waitForAcpElicitationDeadline, .{origin.deadline_ms}) catch |err| {
        Cleanup.drain(state.alloc, &select);
        return err;
    };
    select.concurrent(.cancelled, waitForAcpElicitationCancellation, .{
        origin.lifecycle_cancel_flag,
        operation_cancel_flag,
    }) catch |err| {
        Cleanup.drain(state.alloc, &select);
        return err;
    };
    const event = select.await() catch |err| {
        Cleanup.drain(state.alloc, &select);
        return err;
    };
    return switch (event) {
        .response => |response| result: {
            Cleanup.drain(state.alloc, &select);
            break :result response;
        },
        .deadline, .cancelled => result: {
            server.cancelOutboundRequest(state, id);
            Cleanup.drain(state.alloc, &select);
            break :result null;
        },
    };
}

fn waitForAcpElicitationDeadline(deadline_ms: i64) anyerror!void {
    while (acpAwakeMillis() < deadline_ms) {
        const remaining = deadline_ms - acpAwakeMillis();
        try io_mod.getIo().sleep(.fromMilliseconds(@intCast(@max(@min(remaining, 20), 1))), .awake);
    }
}

fn waitForAcpElicitationCancellation(
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool),
    operation_cancel_flag: ?*const std.atomic.Value(bool),
) anyerror!void {
    while ((lifecycle_cancel_flag == null or !lifecycle_cancel_flag.?.load(.acquire)) and
        (operation_cancel_flag == null or !operation_cancel_flag.?.load(.acquire)))
    {
        try io_mod.getIo().sleep(.fromMilliseconds(10), .awake);
    }
}

fn acpAwakeMillis() i64 {
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    const milliseconds = @divFloor(now.raw.nanoseconds, std.time.ns_per_ms);
    return std.math.cast(i64, milliseconds) orelse if (milliseconds < 0)
        std.math.minInt(i64)
    else
        std.math.maxInt(i64);
}

fn finishAcpUrlElicitations(
    raw_ctx: *anyopaque,
    alloc: Allocator,
    _: tool_mcp_runtime.InputOrigin,
    outcome: tool_mcp_runtime.ContinuationTerminal,
) void {
    const responder: *AcpElicitationResponderContext = @ptrCast(@alignCast(raw_ctx));
    for (responder.accepted_url_ids.items) |id| {
        if (outcome == .completed) {
            var params: std.Io.Writer.Allocating = .init(alloc);
            defer params.deinit();
            params.writer.writeAll("{\"elicitationId\":") catch continue;
            std.json.Stringify.value(id, .{}, &params.writer) catch continue;
            params.writer.writeByte('}') catch continue;
            responder.acp.state.writer.writeNotification(
                alloc,
                "elicitation/complete",
                params.writer.buffered(),
            ) catch {};
        }
        responder.acp.state.alloc.free(id);
    }
    responder.accepted_url_ids.clearRetainingCapacity();
    for (responder.accepted_legacy_urls.items) |*accepted| {
        if (outcome != .completed) {
            server.removeLegacyUrl(responder.acp.state, accepted.acp_id);
        }
        accepted.deinit(responder.acp.state.alloc);
    }
    responder.accepted_legacy_urls.clearRetainingCapacity();
}

fn mcpHasTool(raw_ctx: *anyopaque, name: []const u8, access: tool_mcp_runtime.Access) bool {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = activeMcp(ctx) orelse return false;
    return mcp.hasToolWithAccess(name, access);
}

fn mcpValidateTool(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, access: tool_mcp_runtime.Access) anyerror!tool_mcp_runtime.ValidationResult {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const runtime = activeMcp(ctx) orelse return .not_available;
    return runtime.validateToolArgumentsByNameWithAccess(
        arena,
        name,
        arguments_json,
        access,
    );
}

fn mcpCallTool(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, arguments_json: []const u8, max_tool_result_bytes: usize, options: tool_mcp_runtime.CallOptions) anyerror!?tool_mcp_runtime.CallResult {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = activeMcp(ctx) orelse return null;
    return mcp.callToolByNameWithOptions(
        arena,
        name,
        arguments_json,
        max_tool_result_bytes,
        options,
    );
}

fn mcpSearchTools(raw_ctx: *anyopaque, arena: Allocator, request: tool_mcp_runtime.SearchRequest, permission_rules: types.PermissionRuleSet, limits: config_runtime.context_limits.Values, access: tool_mcp_runtime.Access) anyerror!tool_mcp_runtime.SearchResult {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = activeMcp(ctx) orelse return error.McpServerNotFound;
    return mcp.searchToolsPrepared(arena, request, permission_rules, limits, access);
}

fn mcpToolSchemaJson(raw_ctx: *anyopaque, arena: Allocator, name: []const u8, permission_rules: types.PermissionRuleSet, limits: config_runtime.context_limits.Values, access: tool_mcp_runtime.Access) anyerror!?tool_mcp_runtime.ToolSchemaResult {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = activeMcp(ctx) orelse return null;
    return mcp.toolSchemaJsonByNameWithAccess(
        arena,
        name,
        permission_rules,
        limits,
        access,
    );
}

fn mcpCallFeature(
    raw_ctx: *anyopaque,
    arena: Allocator,
    request: tool_mcp_runtime.FeatureRequest,
    options: tool_mcp_runtime.FeatureCallOptions,
) anyerror!tool_mcp_runtime.FeatureResult {
    const ctx: *AcpContext = @ptrCast(@alignCast(raw_ctx));
    const mcp = activeMcp(ctx) orelse return error.McpRuntimeUnavailable;
    return mcp.callFeatureForModel(arena, request, options);
}

fn activeMcp(ctx: *AcpContext) ?*mcp_runtime.McpRuntime {
    const session = if (ctx.state.active_session) |*active| active else return null;
    return session.mcp;
}

fn onBackgroundUrlReady(_: *anyopaque, _: u64, _: []const u8) void {}

pub fn mapToolKind(tool_name: []const u8) acp_types.ToolCallKind {
    if (std.mem.eql(u8, tool_name, "glob_files")) return .read;
    if (std.mem.eql(u8, tool_name, "grep_files")) return .search;
    if (std.mem.eql(u8, tool_name, "read_file")) return .read;
    if (std.mem.eql(u8, tool_name, "web_fetch")) return .read;
    if (std.mem.eql(u8, tool_name, "web_search")) return .search;
    if (std.mem.eql(u8, tool_name, "write_file")) return .edit;
    if (std.mem.eql(u8, tool_name, "edit_file")) return .edit;
    if (std.mem.eql(u8, tool_name, "exec_command")) return .execute;
    if (std.mem.eql(u8, tool_name, "write_stdin")) return .execute;
    if (std.mem.eql(u8, tool_name, "skill")) return .other;
    if (std.mem.eql(u8, tool_name, "install_skill")) return .other;
    return .other;
}

fn describeToolTitle(registry: tool_dispatch.Registry, arena: Allocator, call: ToolCall) ![]const u8 {
    if (registry.lookup(call.name)) |spec| {
        if (spec.executor_kind == .exec_command or spec.executor_kind == .write_stdin) {
            return tool_presentation.formatPlainAction(arena, .{
                .tool_registry = registry,
                .call = call,
            });
        }
    }
    if (tool_dispatch.toolCallPresentation(arena, registry, call)) |presentation| {
        return std.fmt.allocPrint(arena, "{s}", .{presentation.action_label});
    }
    return std.fmt.allocPrint(arena, "{s}", .{call.name});
}

test "ACP lifecycle action preserves dynamic MCP availability boundaries" {
    const Fixture = struct {
        calls: usize = 0,
        available: bool = false,

        fn hasTool(raw_ctx: *anyopaque, _: []const u8, _: tool_mcp_runtime.Access) bool {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx));
            self.calls += 1;
            return self.available;
        }
    };
    const alloc = std.testing.allocator;
    const advertised = [_][]const u8{"mcp_lookup"};
    var fixture = Fixture{};

    const missing = dynamicMcpToolAvailable(builtin_tools.registry, "mcp_lookup", &advertised, @ptrCast(&fixture), Fixture.hasTool, .unrestricted);
    try std.testing.expect(!missing);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    const missing_label = try tool_presentation.formatPlainAction(alloc, .{
        .tool_registry = builtin_tools.registry,
        .call = .{ .id = "missing", .name = "mcp_lookup", .arguments_json = "{}" },
        .is_available_dynamic_mcp_tool = missing,
    });
    defer alloc.free(missing_label);
    try std.testing.expectEqualStrings("Working: mcp_lookup", missing_label);

    const builtin = dynamicMcpToolAvailable(builtin_tools.registry, "unknown_tool", &.{"unknown_tool"}, @ptrCast(&fixture), Fixture.hasTool, .unrestricted);
    try std.testing.expect(!builtin);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
}

test "ACP lifecycle resolves dynamic MCP availability through session context" {
    const alloc = std.testing.allocator;
    var state = try initTestAcpState(alloc, "/tmp/workspace", .auto);
    defer state.deinit();

    const runtime = try alloc.create(mcp_runtime.McpRuntime);
    runtime.* = mcp_runtime.McpRuntime.init(alloc);
    var runtime_owned = true;
    defer if (runtime_owned) {
        runtime.deinit();
        alloc.destroy(runtime);
    };
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "fixture"),
    });
    const mcp_server = &runtime.servers.items[0];
    mcp_server.state = .ready;
    try mcp_server.tool_catalog.tools.append(alloc, .{
        .original_name = try alloc.dupe(u8, "echo"),
        .prefixed_name = try alloc.dupe(u8, "mcp_fixture_echo"),
        .description = try alloc.dupe(u8, "Echo input"),
        .input_schema_json = try alloc.dupe(u8, "{\"type\":\"object\"}"),
        .tags = &.{},
    });
    state.active_session.?.mcp = runtime;
    runtime_owned = false;

    var ctx = AcpContext{
        .alloc = alloc,
        .state = &state,
        .session_id = "session_1",
    };
    try std.testing.expect(lifecycleDynamicMcpToolAvailable(
        &ctx,
        "mcp_fixture_echo",
        &.{"mcp_fixture_echo"},
    ));
    try std.testing.expect(!lifecycleDynamicMcpToolAvailable(
        &ctx,
        "mcp_fixture_echo",
        &.{},
    ));
    try std.testing.expect(!lifecycleDynamicMcpToolAvailable(
        &ctx,
        "mcp_missing",
        &.{"mcp_missing"},
    ));
}

test "mapToolKind maps common tools" {
    try std.testing.expectEqual(acp_types.ToolCallKind.read, mapToolKind("read_file"));
    try std.testing.expectEqual(acp_types.ToolCallKind.edit, mapToolKind("write_file"));
    try std.testing.expectEqual(acp_types.ToolCallKind.edit, mapToolKind("edit_file"));
    try std.testing.expectEqual(acp_types.ToolCallKind.search, mapToolKind("grep_files"));
    try std.testing.expectEqual(acp_types.ToolCallKind.execute, mapToolKind("exec_command"));
    try std.testing.expectEqual(acp_types.ToolCallKind.execute, mapToolKind("write_stdin"));
    try std.testing.expectEqual(acp_types.ToolCallKind.other, mapToolKind("unknown_tool"));
}

test "ACP usage checkpoints honor the active session write boundary" {
    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var snapshot = try usage.snapshot(alloc);
    defer snapshot.deinit(alloc);

    var active: server.ActiveSessionState = undefined;
    active.session_id = @constCast("session-test");
    active.writable = null;
    active.session_write_mutex = .init;
    var state: server.ServerState = undefined;
    state.active_session = active;
    var ctx = AcpContext{
        .alloc = alloc,
        .state = &state,
        .session_id = "session-test",
    };

    const Worker = struct {
        ctx: *AcpContext,
        snapshot: session_usage.Snapshot,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.started.store(true, .seq_cst);
            persistUsageCheckpoint(
                @ptrCast(self.ctx),
                self.snapshot,
            ) catch |err| {
                self.failure = err;
            };
            self.done.store(true, .seq_cst);
        }
    };
    var worker = Worker{
        .ctx = &ctx,
        .snapshot = snapshot,
    };
    state.active_session.?.session_write_mutex.lockUncancelable(io_mod.getIo());
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    while (!worker.started.load(.seq_cst)) std.Thread.yield() catch {};
    for (0..100) |_| std.Thread.yield() catch {};
    const blocked_at_boundary = !worker.done.load(.seq_cst);
    state.active_session.?.session_write_mutex.unlock(io_mod.getIo());
    thread.join();

    try std.testing.expect(blocked_at_boundary);
    try std.testing.expect(worker.done.load(.seq_cst));
    try std.testing.expectEqual(
        error.SessionPersistenceUnavailable,
        worker.failure.?,
    );
}

test "ACP usage checkpoints maintain the profile recovery marker" {
    const alloc = std.testing.allocator;
    const PublicationSink = struct {
        fn publish(_: *anyopaque, _: session_usage.usage_report.ProfileEvent) !void {}
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io_mod.getIo(), "workspace", .default_dir);
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace",
    );
    defer alloc.free(workspace);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    var store_owned = true;
    defer if (store_owned) store.deinit(alloc);
    const history = try alloc.alloc(types.HistoryTurn, 0);
    var history_owned = true;
    defer if (history_owned) alloc.free(history);
    var initial = session_codec.DurableSessionState{
        .id = try alloc.dupe(u8, "acp-usage-recovery"),
        .origin_workspace_root = try alloc.dupe(u8, workspace),
        .workspace_root = try alloc.dupe(u8, workspace),
        .created_at_ms = 1000,
        .updated_at_ms = 1000,
        .conversation_language = session_runtime.ConversationLanguage.default(),
        .preferences = .{
            .model = try alloc.dupe(u8, "provider/model"),
            .effort = types.ReasoningEffort.literal("high"),
            .fast_mode = false,
        },
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    history_owned = false;
    defer initial.deinit(alloc);
    var writable = try store.startWritableSession(alloc, initial);
    var writable_owned = true;
    defer if (writable_owned) writable.deinit(alloc);

    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    const observation = try session_usage.InvocationObservation.begin(&usage);
    try observation.completeDirect(
        alloc,
        "provider/model",
        .{ .input_tokens = 10, .output_tokens = 2, .cached_input_tokens = 1, .reasoning_output_tokens = 1 },
        .{ .http_ok = true, .terminal_finish_reason = .stop },
    );
    var pending = try usage.snapshot(alloc);
    defer pending.deinit(alloc);

    var active: server.ActiveSessionState = undefined;
    active.session_id = writable.active_id;
    active.store = store;
    active.writable = writable;
    active.session_write_mutex = .init;
    var state: server.ServerState = undefined;
    state.active_session = active;
    store_owned = false;
    writable_owned = false;
    defer {
        if (state.active_session) |*session| {
            if (session.writable) |*active_writable| {
                active_writable.deinit(alloc);
            }
            if (session.store) |*active_store| active_store.deinit(alloc);
            state.active_session = null;
        }
    }
    var ctx = AcpContext{
        .alloc = alloc,
        .state = &state,
        .session_id = writable.active_id,
    };

    try persistUsageCheckpoint(@ptrCast(&ctx), pending);
    var marked = try store.listUsageRecoverySessions(alloc);
    defer {
        for (marked.items) |*entry| entry.deinit(alloc);
        marked.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), marked.items.len);
    try std.testing.expectEqualStrings(writable.active_id, marked.items[0].id);
    var recovered = try usage_recovery.collectFromHome(alloc, home);
    defer recovered.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), recovered.facts.len);

    var publication_context: u8 = 0;
    usage.configurePublicationSink(.{
        .context = &publication_context,
        .allocator = alloc,
        .publish = PublicationSink.publish,
    });
    var settled = try usage.snapshot(alloc);
    defer settled.deinit(alloc);
    try persistUsageCheckpoint(@ptrCast(&ctx), settled);

    var cleared = try store.listUsageRecoverySessions(alloc);
    defer {
        for (cleared.items) |*entry| entry.deinit(alloc);
        cleared.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 0), cleared.items.len);
    var after_settlement = try usage_recovery.collectFromHome(alloc, home);
    defer after_settlement.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), after_settlement.facts.len);
}

test "parsePromptInput extracts text blocks" {
    const alloc = std.testing.allocator;
    const params = "{\"sessionId\":\"s1\",\"prompt\":[{\"type\":\"text\",\"text\":\"Hello world\"}]}";
    var result = try parsePromptInput(alloc, params);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("Hello world", result.text);
}

test "parsePromptInput accepts fx steer input blocks" {
    const alloc = std.testing.allocator;
    var result = try parsePromptInput(
        alloc,
        "{\"input\":[{\"type\":\"text\",\"text\":\"steer now\"}]}",
    );
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("steer now", result.text);
}

test "ACP recognizes the exact local process status command" {
    const alloc = std.testing.allocator;
    try std.testing.expect(try isProcessStatusPrompt(
        alloc,
        "{\"prompt\":[{\"type\":\"text\",\"text\":\" /ps \"}]}",
    ));
    try std.testing.expect(!(try isProcessStatusPrompt(
        alloc,
        "{\"prompt\":[{\"type\":\"text\",\"text\":\"/ps now\"}]}",
    )));
}

test "parsePromptInput handles multiple text blocks" {
    const alloc = std.testing.allocator;
    const params = "{\"sessionId\":\"s1\",\"prompt\":[{\"type\":\"text\",\"text\":\"Hello\"},{\"type\":\"text\",\"text\":\"World\"}]}";
    var result = try parsePromptInput(alloc, params);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("Hello\nWorld", result.text);
}

test "parsePromptInput returns empty for missing prompt" {
    const alloc = std.testing.allocator;
    var result = try parsePromptInput(alloc, "{\"sessionId\":\"s1\"}");
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), result.text.len);
}

test "parsePromptInput handles empty prompt array" {
    const alloc = std.testing.allocator;
    var result = try parsePromptInput(alloc, "{\"sessionId\":\"s1\",\"prompt\":[]}");
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), result.text.len);
}

test "parsePromptInput accepts explicit recovery continuation metadata" {
    const alloc = std.testing.allocator;
    const params =
        "{\"sessionId\":\"s1\",\"prompt\":[],\"_meta\":{\"fx\":{\"continueRecovery\":true}}}";
    var result = try parsePromptInput(alloc, params);
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), result.text.len);
    try std.testing.expect(result.continue_recovery);
}

test "parsePromptInput accepts image blocks" {
    const alloc = std.testing.allocator;
    const params = "{\"sessionId\":\"s1\",\"prompt\":[{\"type\":\"text\",\"text\":\"Only text\"},{\"type\":\"image\",\"data\":\"aGVsbG8=\",\"mimeType\":\"image/png\"}]}";
    var result = try parsePromptInput(alloc, params);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("Only text", result.text);
    try std.testing.expectEqual(@as(usize, 1), result.images.len);
    try std.testing.expectEqualStrings("hello", result.images[0].data);
    try std.testing.expectEqualStrings("image/png", result.images[0].media_type.?);
}

test "parsePromptInput preserves resource text and accepts only local absolute file targets" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "Fx Project/src");
    var file = try tmp.dir.createFile(std.testing.io, "Fx Project/src/main.zig", .{});
    file.close(std.testing.io);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const expected_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "Fx Project/src/main.zig");
    defer alloc.free(expected_path);
    const local_uri = try std.fmt.allocPrint(alloc, "file://{s}/Fx%20Project/src/main.zig", .{root});
    defer alloc.free(local_uri);
    const remote_uri = "https://example.test/reference.txt";
    const params = try std.fmt.allocPrint(
        alloc,
        "{{\"sessionId\":\"s1\",\"prompt\":[" ++
            "{{\"type\":\"resource\",\"resource\":{{\"uri\":\"{s}\",\"text\":\"local body\"}}}}," ++
            "{{\"type\":\"resource\",\"resource\":{{\"uri\":\"{s}\",\"text\":\"remote body\"}}}}]}}",
        .{ local_uri, remote_uri },
    );
    defer alloc.free(params);

    var parsed = try parsePromptInput(alloc, params);
    defer parsed.deinit(alloc);

    const expected_text = try std.fmt.allocPrint(
        alloc,
        "File: {s}\nlocal body\nFile: {s}\nremote body",
        .{ local_uri, remote_uri },
    );
    defer alloc.free(expected_text);
    try std.testing.expectEqualStrings(
        expected_text,
        parsed.text,
    );
    try std.testing.expectEqual(@as(usize, 1), parsed.targets.len);
    try std.testing.expectEqual(context_contract.TargetKind.file, parsed.targets[0].kind);
    try std.testing.expectEqualStrings(expected_path, parsed.targets[0].path);
    try std.testing.expectEqual(@as(usize, 1), parsed.omissions.len);
    try std.testing.expectEqualStrings(remote_uri, parsed.omissions[0].source);
    try std.testing.expectEqual(context_contract.OmissionReason.unsafe_target, parsed.omissions[0].reason);
}

test "parsePromptInput rejects unsafe file URI targeting without losing embedded text" {
    const alloc = std.testing.allocator;
    const uris = [_][]const u8{
        "file://remote.example/tmp/file.txt",
        "file:relative.txt",
        "file:///tmp/../secret.txt",
        "file:///tmp/%00secret.txt",
        "file:///tmp/file.txt?revision=1",
        "file:///tmp/file.txt#fragment",
    };

    for (uris) |uri| {
        const params = try std.fmt.allocPrint(
            alloc,
            "{{\"sessionId\":\"s1\",\"prompt\":[{{\"type\":\"resource\",\"resource\":{{\"uri\":\"{s}\",\"text\":\"embedded text\"}}}}]}}",
            .{uri},
        );
        defer alloc.free(params);

        var parsed = try parsePromptInput(alloc, params);
        defer parsed.deinit(alloc);

        try std.testing.expect(std.mem.endsWith(u8, parsed.text, "embedded text"));
        try std.testing.expectEqual(@as(usize, 0), parsed.targets.len);
        try std.testing.expectEqual(@as(usize, 1), parsed.omissions.len);
        try std.testing.expectEqualStrings(uri, parsed.omissions[0].source);
        try std.testing.expectEqual(context_contract.OmissionReason.unsafe_target, parsed.omissions[0].reason);
    }
}

test "parsePromptInput bounds remote resource omissions with a stable summary" {
    const alloc = std.testing.allocator;
    var params: std.Io.Writer.Allocating = .init(alloc);
    defer params.deinit();
    try params.writer.writeAll("{\"sessionId\":\"s1\",\"prompt\":[{\"type\":\"text\",\"text\":\"hello\"}");
    for (0..128) |index| {
        try params.writer.print(
            ",{{\"type\":\"resource\",\"resource\":{{\"uri\":\"https://example.test/resource/{d}\"}}}}",
            .{index},
        );
    }
    try params.writer.writeAll("]}");

    var parsed = try parsePromptInput(alloc, params.written());
    defer parsed.deinit(alloc);

    try std.testing.expectEqual(context_contract.Limits.project_omission_records, parsed.omissions.len);
    try std.testing.expectEqualStrings("https://example.test/resource/0", parsed.omissions[0].source);
    try std.testing.expect(std.mem.find(u8, parsed.omissions[parsed.omissions.len - 1].source, "/31") != null);
    const summary = parsed.omission_summary orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 96), summary.omitted_count);
    try std.testing.expectEqual(@as(usize, 96), summary.reason_counts[@intFromEnum(context_contract.OmissionReason.unsafe_target)]);
    const zero_digest = [_]u8{0} ** std.crypto.hash.sha2.Sha256.digest_length;
    try std.testing.expect(!std.mem.eql(u8, &summary.digest, &zero_digest));
}

test "localFileTargetPath canonicalizes a local symlink target" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.testing.io, "real.txt", .{});
    file.close(std.testing.io);
    try createSymlinkOrSkip(tmp.dir, "real.txt", "alias.txt");

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const alias_path = try std.fs.path.join(alloc, &.{ root, "alias.txt" });
    defer alloc.free(alias_path);
    const expected = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "real.txt");
    defer alloc.free(expected);
    const uri = try std.fmt.allocPrint(alloc, "file://{s}", .{alias_path});
    defer alloc.free(uri);

    const actual = (try localFileTargetPath(alloc, uri)) orelse
        return error.TestExpectedEqual;
    defer alloc.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "parsePromptInput releases partial resource state across allocation failures" {
    const backing = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "local.txt", .{});
    file.close(std.testing.io);
    const local_path = try io_mod.dirRealpathAlloc(backing, tmp.dir, "local.txt");
    defer backing.free(local_path);
    const params = try std.fmt.allocPrint(
        backing,
        "{{\"sessionId\":\"s1\",\"prompt\":[" ++
            "{{\"type\":\"resource\",\"resource\":{{\"uri\":\"file://{s}\",\"text\":\"local body\"}}}}," ++
            "{{\"type\":\"resource\",\"resource\":{{\"uri\":\"https://example.test/reference.txt\",\"text\":\"remote body\"}}}}]}}",
        .{local_path},
    );
    defer backing.free(params);

    var probe = std.testing.FailingAllocator.init(backing, .{});
    var parsed = try parsePromptInput(probe.allocator(), params);
    parsed.deinit(probe.allocator());
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    for (0..probe.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        if (parsePromptInput(failing.allocator(), params)) |input| {
            var owned = input;
            owned.deinit(failing.allocator());
        } else |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "mapToolKind maps surviving tools" {
    try std.testing.expectEqual(acp_types.ToolCallKind.read, mapToolKind("glob_files"));
    try std.testing.expectEqual(acp_types.ToolCallKind.other, mapToolKind("skill"));
    try std.testing.expectEqual(acp_types.ToolCallKind.other, mapToolKind("install_skill"));
}

test "ACP permission arguments are validated and reserialized before emission" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeValidatedToolArguments(alloc, &out.writer, " { \"path\" : \"README.md\" } ");
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", out.written());

    var malformed: std.Io.Writer.Allocating = .init(alloc);
    defer malformed.deinit();
    try std.testing.expectError(
        error.InvalidToolArgumentsJson,
        writeValidatedToolArguments(alloc, &malformed.writer, "{\"path\":}"),
    );
    try std.testing.expectEqual(@as(usize, 0), malformed.written().len);
}

test "acp exposes web_search progress updates" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeWebSearchProgressUpdate(alloc, &out.writer, "call_search", .{ .results_received = .{
        .query = "current news",
        .result_count = 4,
    } });

    try std.testing.expect(std.mem.find(u8, out.written(), "\"toolCallId\":\"call_search\"") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "\"status\":\"in_progress\"") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "Found 4 web results for current news") != null);
    try std.testing.expectEqual(acp_types.ToolCallKind.search, mapToolKind("web_search"));
}

test "ACP command output preview repairs split and invalid UTF-8" {
    const alloc = std.testing.allocator;
    var preview = AcpCommandOutputPreview{};
    defer preview.deinit(alloc);

    const partial = try preview.decode(alloc, .stdout, "\xe4\xb8");
    defer alloc.free(partial);
    try std.testing.expectEqual(@as(usize, 0), partial.len);

    const completed = try preview.decode(alloc, .stdout, "\xad\xff");
    defer alloc.free(completed);
    try std.testing.expectEqualStrings("中\\xff", completed);
    try std.testing.expect(std.unicode.utf8ValidateSlice(completed));
    try preview.appendVisible(alloc, completed);
    var notification: std.Io.Writer.Allocating = .init(alloc);
    defer notification.deinit();
    try acp_types.writeCommandOutputUpdate(
        &notification.writer,
        "call_utf8",
        "stdout",
        completed,
        preview.bytes.items,
        preview.truncated,
    );
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        notification.written(),
        .{},
    );
    defer parsed.deinit();

    const trailing = try preview.decode(alloc, .stderr, "\xe4");
    defer alloc.free(trailing);
    try std.testing.expectEqual(@as(usize, 0), trailing.len);
    const flushed = try preview.finishDecoder(alloc, .stderr);
    defer alloc.free(flushed);
    try std.testing.expectEqualStrings("\\xe4", flushed);
    try std.testing.expect(std.unicode.utf8ValidateSlice(flushed));
}

test "ACP command output preview truncates only at UTF-8 boundaries" {
    const alloc = std.testing.allocator;
    var preview = AcpCommandOutputPreview{};
    defer preview.deinit(alloc);
    const repeated_len = ((max_acp_command_preview_bytes / 3) + 2) * 3;
    const repeated = try alloc.alloc(u8, repeated_len);
    defer alloc.free(repeated);
    var index: usize = 0;
    while (index < repeated.len) : (index += 3) {
        @memcpy(repeated[index .. index + 3], "中");
    }
    try preview.appendVisible(alloc, repeated);
    try std.testing.expect(preview.truncated);
    try std.testing.expect(preview.bytes.items.len <= max_acp_command_preview_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(preview.bytes.items));
}

test "ACP tool notifications preserve UTF-8 for clipped and unsafe output" {
    const alloc = std.testing.allocator;
    var model_output: [202]u8 = undefined;
    @memset(model_output[0..199], 'x');
    model_output[199] = 0xc3;
    model_output[200] = 0xa9;
    model_output[201] = 'z';

    const preview = toolUpdateContentText(.{
        .status = .failure,
        .model_output = model_output[0..],
    });
    try std.testing.expectEqual(@as(usize, 199), preview.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(preview));

    const unsafe_preview = toolUpdateContentText(.{
        .status = .success,
        .model_output = "command output: \xff",
    });
    try std.testing.expectEqualStrings(
        "binary or non-utf8 tool output omitted",
        unsafe_preview,
    );
    try std.testing.expect(std.unicode.utf8ValidateSlice(unsafe_preview));

    for ([_][]const u8{ preview, unsafe_preview }, 0..) |content, index| {
        var update: std.Io.Writer.Allocating = .init(alloc);
        defer update.deinit();
        try acp_types.writeToolCallUpdate(
            &update.writer,
            if (index == 0) "call_clipped" else "call_unsafe",
            if (index == 0) .failed else .completed,
            content,
        );

        var params: std.Io.Writer.Allocating = .init(alloc);
        defer params.deinit();
        try acp_types.writeSessionUpdate(
            &params.writer,
            "session_1",
            update.written(),
        );

        var notification: std.Io.Writer.Allocating = .init(alloc);
        defer notification.deinit();
        try notification.writer.writeAll(
            "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":",
        );
        try notification.writer.writeAll(params.written());
        try notification.writer.writeByte('}');

        try std.testing.expect(std.unicode.utf8ValidateSlice(notification.written()));
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            alloc,
            notification.written(),
            .{},
        );
        defer parsed.deinit();
    }
}

test "ACP stream adapter forwards raw Markdown and suppresses rendered duplicates and writer failure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const source_spans = [_][]const u8{
        "# Heading\n\n- **bold** item\n",
        "| A | B |\n| - | - |\n| 1 | 2 |\n",
        "```zig\nconst x = 1;\n```\n",
    };
    const rendered_spans = [_][]const u8{
        "Heading\n\nbold item\n",
        "A  B\n1  2\n",
        "\xe2\x94\x82 const x = 1;\n",
    };
    const expected_spans = [_][]const u8{
        source_spans[0],
        source_spans[1],
        source_spans[2],
        "status\n[docs](https://example.com)\n",
    };
    const operational_span =
        "\x1b[1mstatus\x1b[22m\n" ++
        "\x1b]8;id=fx-1;https://example.com\x1b\\docs\x1b]8;;\x1b\\\n";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var capture = try tmp.dir.createFile(
        io_mod.getIo(),
        "acp-stream.jsonl",
        .{ .read = true },
    );
    defer capture.close(io_mod.getIo());
    {
        var state = try initTestAcpState(alloc, "/tmp/workspace", .ask);
        defer state.deinit();
        state.writer = .{ .stdout = capture };
        var ctx = AcpContext{
            .alloc = alloc,
            .state = &state,
            .session_id = "session_1",
        };
        const deps = agentRuntimeDeps(&ctx);

        for (source_spans, rendered_spans) |source, rendered| {
            try deps.push_text(deps.ctx, .{ .assistant_source = source });
            try deps.push_text(deps.ctx, .{ .assistant_rendered = rendered });
        }
        try deps.push_text(deps.ctx, .{ .assistant_source = "" });
        try deps.push_text(deps.ctx, .{ .operational = operational_span });
        try capture.sync(io_mod.getIo());
    }

    var captured_file = try tmp.dir.openFile(io_mod.getIo(), "acp-stream.jsonl", .{});
    defer captured_file.close(io_mod.getIo());
    const captured = try io_mod.readFileToEnd(alloc, &captured_file, 64 * 1024);
    defer alloc.free(captured);

    var notifications = std.mem.splitScalar(u8, captured, '\n');
    var notification_count: usize = 0;
    while (notifications.next()) |line| {
        if (line.len == 0) continue;

        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer parsed.deinit();

        try std.testing.expectEqualStrings("session/update", parsed.value.object.get("method").?.string);
        const params = parsed.value.object.get("params").?.object;
        try std.testing.expectEqualStrings("session_1", params.get("sessionId").?.string);
        const update = params.get("update").?.object;
        try std.testing.expectEqualStrings("agent_message_chunk", update.get("sessionUpdate").?.string);
        const content = update.get("content").?.object;
        try std.testing.expectEqualStrings("text", content.get("type").?.string);
        try std.testing.expectEqualStrings(expected_spans[notification_count], content.get("text").?.string);
        try std.testing.expect(std.mem.find(u8, content.get("text").?.string, "\x1b") == null);

        notification_count += 1;
    }
    try std.testing.expectEqual(expected_spans.len, notification_count);

    var failed_output = try tmp.dir.createFile(io_mod.getIo(), "acp-stream-failure.jsonl", .{});
    failed_output.close(io_mod.getIo());
    var failed_state = try initTestAcpState(alloc, "/tmp/workspace", .ask);
    defer failed_state.deinit();
    failed_state.writer = .{ .stdout = failed_output };
    var failed_ctx = AcpContext{
        .alloc = alloc,
        .state = &failed_state,
        .session_id = "session_1",
    };

    var writer_failed = false;
    failed_ctx.sendAgentText("writer failure probe") catch {
        writer_failed = true;
    };
    try std.testing.expect(writer_failed);

    const failed_deps = agentRuntimeDeps(&failed_ctx);
    try failed_deps.push_text(failed_deps.ctx, .{ .assistant_source = "writer failure remains suppressed" });
}

test "ACP auth failure emits a valid detail-free JSON-RPC notification" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var capture = try tmp.dir.createFile(io_mod.getIo(), "acp-auth-failure.jsonl", .{ .read = true });
    defer capture.close(io_mod.getIo());
    var state = try initTestAcpState(alloc, "/tmp/workspace", .ask);
    defer state.deinit();
    state.writer = .{ .stdout = capture };
    state.active_session.?.credential_source = .openai_api_key;
    var ctx = AcpContext{
        .alloc = alloc,
        .state = &state,
        .session_id = "session_1",
    };
    try std.testing.expectEqual(
        types.CredentialSource.openai_api_key,
        ctx.toolContext().credential_source.?,
    );

    const deps = agentRuntimeDeps(&ctx);
    try deps.push_http_error(
        deps.ctx,
        .unauthorized,
        "provider rejected access-token-secret",
        state.active_session.?.credential_source,
    );
    try capture.sync(io_mod.getIo());

    var captured_file = try tmp.dir.openFile(io_mod.getIo(), "acp-auth-failure.jsonl", .{});
    defer captured_file.close(io_mod.getIo());
    const captured = try io_mod.readFileToEnd(alloc, &captured_file, 16 * 1024);
    defer alloc.free(captured);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, captured, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("2.0", parsed.value.object.get("jsonrpc").?.string);
    try std.testing.expectEqualStrings("session/update", parsed.value.object.get("method").?.string);
    const update = parsed.value.object.get("params").?.object.get("update").?.object;
    const content = update.get("content").?.object;
    try std.testing.expectEqualStrings(
        "OPENAI_API_KEY authentication failed · HTTP 401",
        content.get("text").?.string,
    );
    try std.testing.expect(std.mem.find(u8, captured, "access-token-secret") == null);
    try std.testing.expect(std.mem.find(u8, captured, "provider rejected") == null);
    try std.testing.expect(std.mem.find(u8, captured, "\x1b") == null);
}

test "ACP tool updates preserve typed permission failures without truncation" {
    const alloc = std.testing.allocator;
    const payload = try tool_result_errors.toolPermissionDeniedJson(alloc, "run_command", .permission_required);
    defer alloc.free(payload);

    const output_text = toolUpdateContentText(.{
        .status = .failure,
        .model_output = payload,
    });

    try std.testing.expectEqualStrings(payload, output_text);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, output_text, .{});
    defer parsed.deinit();
    const error_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings("tool_permission_denied", error_obj.get("type").?.string);
    try std.testing.expectEqualStrings("run_command", error_obj.get("tool_name").?.string);
    try std.testing.expectEqualStrings("permission_required", error_obj.get("reason").?.string);
    try std.testing.expect(error_obj.get("denied").?.bool);
}

test "ACP plan mode validates registered tools against mode policy" {
    const alloc = std.testing.allocator;
    var state = try initTestAcpState(alloc, "/tmp/fx-acp-plan-mode", .ask);
    defer state.deinit();
    state.active_session.?.mode = "plan";
    var ctx = AcpContext{
        .alloc = alloc,
        .state = &state,
        .session_id = state.active_session.?.session_id,
    };

    const allowed = try validateToolCall(&ctx, alloc, .{
        .id = "call_read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"README.md\"}",
    });
    switch (allowed) {
        .valid => {},
        else => return error.TestExpectedEqual,
    }

    const denied = try validateToolCall(&ctx, alloc, .{
        .id = "call_write",
        .name = "write_file",
        .arguments_json = "{}",
    });
    switch (denied) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(std.mem.find(u8, body, "\"tool_name\":\"write_file\"") != null);
            try std.testing.expect(std.mem.find(u8, body, "Plan mode only allows read-only workspace inspection tools.") != null);
        },
        else => return error.TestExpectedEqual,
    }
}

const AcpContextRegistryFixture = struct {
    var gather_calls: usize = 0;
    var gather_error: ?context_contract.ProviderError = null;
    var static_context: ?[]const u8 = null;
    var transient_calls: usize = 0;
    var transient_permission_mode: ?PermissionMode = null;

    fn reset() void {
        gather_calls = 0;
        gather_error = null;
        static_context = null;
        transient_calls = 0;
        transient_permission_mode = null;
    }

    fn gather(alloc: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
        gather_calls += 1;
        if (gather_error) |err| return err;
        return .{ .content = try std.fmt.allocPrint(alloc, "ACP registry context {d}", .{gather_calls}) };
    }

    fn appendStatic(input: context_contract.StaticContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
        static_context = input.project_context;
        try messages.append(alloc, .{ .role = .system, .content = input.project_context });
    }

    fn appendTransient(input: context_contract.TransientContextInput, alloc: Allocator, messages: *std.ArrayList(ChatMessage)) context_contract.ProviderError!void {
        transient_calls += 1;
        transient_permission_mode = input.permission_mode;
        try messages.append(alloc, .{ .role = .system, .content = "ACP registry transient" });
    }
};

const test_acp_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.acp_context",
    .gather_project_context_fn = AcpContextRegistryFixture.gather,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = AcpContextRegistryFixture.appendStatic,
    .append_transient_fn = AcpContextRegistryFixture.appendTransient,
} };

const test_acp_modes = [_]mode_registry.ModeSpec{
    .{ .id = "normal", .name = "Normal" },
    .{
        .id = "plan",
        .name = "Plan",
        .permission_mode = .ask,
        .tool_policy = .read_only,
        .tool_policy_denial_message = "Plan mode only allows read-only workspace inspection tools.",
    },
};

const test_acp_mode_registry = mode_registry.Registry{
    .default_mode_id = "normal",
    .modes = test_acp_modes[0..],
};

fn testModelPromptOverlay(model: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, model, "test-model")) "ACP test model overlay" else null;
}

fn testServerConfig() server.Config {
    return .{
        .default_model = "test-model",
        .default_agent_step_limit = 4,
        .gateway_retry_count = 0,
        .gateway_chat_url = "http://127.0.0.1",
        .gateway_models_path = "/models",
        .gateway_provider = test_builtin_gateway.provider,
        .provider_set = provider_set.gateway_only(test_builtin_gateway.provider_bundle),
        .secret_store = host.unavailable_secret_store,
        .prompt_policy = .{
            .system_prompt = "test",
            .model_prompt_overlay_fn = testModelPromptOverlay,
        },
        .ignored_list_entries = &.{},
        .max_list_entries = 32,
        .max_read_file_bytes = 1024 * 1024,
        .max_read_file_lines = 1000,
        .max_read_file_line_len = 4096,
        .max_command_output_bytes = 1024 * 1024,
        .max_tool_result_bytes = 1024 * 1024,
        .max_history_turns = 8,
        .context_registry = test_acp_context_registry,
        .mode_registry = test_acp_mode_registry,
    };
}

fn initTestAcpState(alloc: Allocator, workspace_root: []const u8, mode: PermissionMode) !server.ServerState {
    const owned_workspace = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(owned_workspace);
    const session_id = try alloc.dupe(u8, "session_1");
    errdefer alloc.free(session_id);
    const model = try alloc.dupe(u8, "test-model");
    errdefer alloc.free(model);
    const api_key = try alloc.dupe(u8, "test-api-key");
    errdefer alloc.free(api_key);

    const cfg = testServerConfig();
    return .{
        .alloc = alloc,
        .cfg = cfg,
        .writer = jsonrpc.Writer.init(),
        .workspace_root = owned_workspace,
        .api_key = api_key,
        .credential_source = .openai_api_key,
        .web_search_runtime = @import("../core/tooling/web_search_runtime.zig").Runtime.init(.{}),
        .active_session = .{
            .session_id = session_id,
            .model = model,
            .mode = "normal",
            .workspace_root = owned_workspace,
            .api_key = api_key,
            .credential_source = .openai_api_key,
            .agent_step_limit = 4,
            .max_tool_result_bytes = 1024 * 1024,
            .fast_mode = false,
            .effort = .auto,
            .first_call_tool_choice = .auto,
            .permission_mode = mode,
            .permission_rules = .{},
            .session_rt = .{ .max_history_turns = 8 },
            .cancel_flag = std.atomic.Value(bool).init(false),
            .pending_prompt_id = null,
        },
    };
}

test "ACP recognizes only the exact compact slash command" {
    try std.testing.expect(isCompactCommand("/compact"));
    try std.testing.expect(isCompactCommand("  /compact\n"));
    try std.testing.expect(!isCompactCommand("/compact now"));
    try std.testing.expect(!isCompactCommand("explain /compact"));
}

test "stripAnsiAlloc returns the original slice for clean text and strips escapes" {
    const alloc = std.testing.allocator;
    const clean = "plain **markdown** text\n";
    const untouched = try stripAnsiAlloc(alloc, clean);
    try std.testing.expect(untouched.ptr == clean.ptr);

    const stripped = try stripAnsiAlloc(alloc, "\x1b[31mred\x1b[0m and \x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\");
    defer alloc.free(stripped);
    try std.testing.expectEqualStrings("red and [link](https://example.com)", stripped);
    try std.testing.expect(std.mem.find(u8, stripped, "\x1b") == null);
}

test "stripAnsiAlloc converts OSC-8 hyperlinks with params and BEL terminators" {
    const alloc = std.testing.allocator;
    const with_params = try stripAnsiAlloc(alloc, "\x1b]8;id=fx-1;https://ziglang.org/download/\x1b\\Zig downloads\x1b]8;;\x1b\\ ready");
    defer alloc.free(with_params);
    try std.testing.expectEqualStrings("[Zig downloads](https://ziglang.org/download/) ready", with_params);

    const bel_terminated = try stripAnsiAlloc(alloc, "\x1b]8;;https://example.com\x07docs\x1b]8;;\x07");
    defer alloc.free(bel_terminated);
    try std.testing.expectEqualStrings("[docs](https://example.com)", bel_terminated);

    const unterminated = try stripAnsiAlloc(alloc, "\x1b]8;;https://example.com\x1b\\split chunk");
    defer alloc.free(unterminated);
    try std.testing.expectEqualStrings("[split chunk](https://example.com)", unterminated);
}

test "ACP pending tool_call updates keep provider ids stable and dedupe" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var capture = try tmp.dir.createFile(io_mod.getIo(), "acp-tool-call.jsonl", .{ .read = true });
    defer capture.close(io_mod.getIo());
    var state = try initTestAcpState(alloc, "/tmp/workspace", .ask);
    defer state.deinit();
    state.writer = .{ .stdout = capture };
    var ctx = AcpContext{
        .alloc = alloc,
        .state = &state,
        .session_id = "session_1",
    };
    defer ctx.deinitPublishedToolCalls();

    const call = ToolCall{
        .id = "provider_call_7",
        .name = "exec_command",
        .arguments_json = "{\"cmd\":\"ls\"}",
    };
    const first = try ctx.sendToolCallPending(alloc, call);
    const second = try ctx.sendToolCallPending(alloc, call);
    try std.testing.expectEqualStrings("provider_call_7", first);
    try std.testing.expect(first.ptr == second.ptr);
    try capture.sync(io_mod.getIo());

    var captured_file = try tmp.dir.openFile(io_mod.getIo(), "acp-tool-call.jsonl", .{});
    defer captured_file.close(io_mod.getIo());
    const captured = try io_mod.readFileToEnd(alloc, &captured_file, 64 * 1024);
    var lines = std.mem.splitScalar(u8, captured, '\n');
    var pending_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(std.mem.find(u8, line, "\"toolCallId\":\"provider_call_7\"") != null);
        try std.testing.expect(std.mem.find(u8, line, "\"sessionUpdate\":\"tool_call\"") != null);
        pending_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), pending_count);
}

test "ACP terminal lifecycle replaces Running command title with Ran" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var capture = try tmp.dir.createFile(io_mod.getIo(), "acp-command-lifecycle.jsonl", .{ .read = true });
    defer capture.close(io_mod.getIo());
    var state = try initTestAcpState(alloc, "/tmp/workspace", .ask);
    defer state.deinit();
    state.writer = .{ .stdout = capture };
    var ctx = AcpContext{
        .alloc = alloc,
        .state = &state,
        .session_id = "session_1",
    };
    defer ctx.deinitPublishedToolCalls();

    _ = try ctx.sendToolCallPending(alloc, .{
        .id = "call_exec",
        .name = "exec_command",
        .arguments_json = "{\"cmd\":\"zig build\"}",
    });
    try pushToolLifecycle(&ctx, .{ .terminal = .{
        .id = .{ .turn_id = 1, .call_id = "call_exec" },
        .outcome = .{ .kind = .completed, .summary = "Ran zig build" },
    } });
    try ctx.sendToolCallCompletedWithCommandResult(
        "call_exec",
        "build succeeded",
        "{\"kind\":\"foreground\",\"exit_code\":0}",
    );
    try capture.sync(io_mod.getIo());

    var captured_file = try tmp.dir.openFile(io_mod.getIo(), "acp-command-lifecycle.jsonl", .{});
    defer captured_file.close(io_mod.getIo());
    const captured = try io_mod.readFileToEnd(alloc, &captured_file, 64 * 1024);
    try std.testing.expect(std.mem.find(u8, captured, "\"title\":\"Running zig build\"") != null);
    try std.testing.expect(std.mem.find(u8, captured, "\"sessionUpdate\":\"tool_call_update\"") != null);
    try std.testing.expect(std.mem.find(u8, captured, "\"title\":\"Ran zig build\"") != null);
    try std.testing.expect(std.mem.find(u8, captured, "\"status\":\"completed\"") != null);
    try std.testing.expect(std.mem.find(u8, captured, "build succeeded") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, captured, "\"status\":\"completed\""));
}

test "ACP propagateGrant stores deduped runtime session grants" {
    const alloc = std.testing.allocator;
    var state = try initTestAcpState(alloc, "/tmp/workspace", .ask);
    defer state.deinit();
    var ctx = AcpContext{
        .alloc = alloc,
        .state = &state,
        .session_id = "session_1",
    };

    try retainAcpGrant(&ctx, "run_command", "git status*");
    try retainAcpGrant(&ctx, "run_command", "git status*");
    try retainAcpGrant(&ctx, "write_file", "/tmp/workspace/**");

    const session = &state.active_session.?;
    try std.testing.expectEqual(@as(usize, 2), session.session_grants.len);
    try std.testing.expectEqualStrings("run_command", session.session_grants[0].tool_name);
    try std.testing.expectEqualStrings("git status*", session.session_grants[0].target_path);
    try std.testing.expectEqualStrings("write_file", session.session_grants[1].tool_name);

    const tool_ctx = ctx.toolContext();
    try std.testing.expectEqual(session.session_grants.len, tool_ctx.permission_grants.len);
    try std.testing.expect(tool_ctx.permission_grants.ptr == session.session_grants.ptr);
}

test "ACP refreshes typed registry context and propagates enabled gathering errors" {
    const alloc = std.testing.allocator;
    AcpContextRegistryFixture.reset();

    var state = try initTestAcpState(alloc, "/tmp/workspace", .ask);
    defer state.deinit();

    try refreshProjectContext(&state, alloc, &.{}, &.{}, null);
    try std.testing.expectEqual(@as(usize, 1), AcpContextRegistryFixture.gather_calls);
    var contribution = state.context_snapshot.contribution orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("test.acp_context", contribution.provider_id);
    try std.testing.expectEqualStrings("ACP registry context 1", contribution.content);

    try refreshProjectContext(&state, alloc, &.{}, &.{}, null);
    try std.testing.expectEqual(@as(usize, 2), AcpContextRegistryFixture.gather_calls);
    contribution = state.context_snapshot.contribution orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("ACP registry context 2", contribution.content);

    state.context_enabled = false;
    try refreshProjectContext(&state, alloc, &.{}, &.{}, null);
    try std.testing.expectEqual(@as(usize, 2), AcpContextRegistryFixture.gather_calls);
    try std.testing.expect(state.context_snapshot.contribution == null);

    state.context_enabled = true;
    AcpContextRegistryFixture.gather_error = error.WriteFailed;
    try std.testing.expectError(
        error.WriteFailed,
        refreshProjectContext(&state, alloc, &.{}, &.{}, null),
    );
    try std.testing.expectEqual(@as(usize, 3), AcpContextRegistryFixture.gather_calls);
    try std.testing.expect(state.context_snapshot.contribution == null);
}

test "ACP prompt propagates context provider errors before pending prompt state" {
    const alloc = std.testing.allocator;
    var state = try initTestAcpState(alloc, "/tmp/workspace", .ask);
    defer state.deinit();
    var msg = jsonrpc.Message{
        .id = .{ .integer = 7 },
        .method = "session/prompt",
        .params_raw = "{\"sessionId\":\"session_1\",\"prompt\":[{\"type\":\"text\",\"text\":\"hello\"}]}",
    };
    const errors = [_]context_contract.ProviderError{
        error.OutOfMemory,
        error.NoSpaceLeft,
        error.WriteFailed,
    };

    for (errors) |expected_error| {
        AcpContextRegistryFixture.reset();
        AcpContextRegistryFixture.gather_error = expected_error;
        try std.testing.expectError(
            expected_error,
            handlePrompt(&state, alloc, &msg, "code", .ask, false),
        );
        try std.testing.expectEqual(@as(usize, 1), AcpContextRegistryFixture.gather_calls);
        try std.testing.expect(state.active_session.?.pending_prompt_id == null);
        try std.testing.expect(state.context_snapshot.contribution == null);
    }
}

test "ACP registry callbacks preserve snapshot bytes before transient context" {
    const alloc = std.testing.allocator;
    AcpContextRegistryFixture.reset();

    var state = try initTestAcpState(alloc, "/tmp/workspace", .ask);
    defer state.deinit();
    try refreshProjectContext(&state, alloc, &.{}, &.{}, null);

    var ctx = AcpContext{
        .alloc = alloc,
        .state = &state,
        .session_id = state.active_session.?.session_id,
        .captured_permission_mode = .auto,
    };
    state.active_session.?.permission_mode = .ask;
    const deps = agentRuntimeDeps(&ctx);
    try std.testing.expect(deps.context_enabled);
    try std.testing.expectEqualStrings(
        "test.acp_context",
        deps.context_registry.?.defaultProvider().id,
    );
    try std.testing.expect(deps.request_prepared_file_mutation_permission != null);
    try std.testing.expect(deps.prepare_parent_turn_context != null);
    try std.testing.expect(deps.acknowledge_parent_turn_context != null);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages: std.ArrayList(ChatMessage) = .empty;
    defer messages.deinit(arena);
    try messages.append(arena, .{ .role = .system, .content = "base system" });

    try deps.append_static_context.?(deps.ctx, arena, &messages);
    try deps.append_runtime_context(deps.ctx, arena, &messages);

    try std.testing.expectEqual(@as(usize, 4), messages.items.len);
    try std.testing.expectEqualStrings("base system", messages.items[0].content.?);
    try std.testing.expectEqualStrings("ACP registry context 1", messages.items[1].content.?);
    try std.testing.expect(std.mem.find(u8, messages.items[2].content.?, "<mcp_servers>") != null);
    try std.testing.expectEqualStrings("ACP registry transient", messages.items[3].content.?);
    try std.testing.expectEqualStrings("ACP registry context 1", AcpContextRegistryFixture.static_context.?);
    try std.testing.expectEqual(@as(usize, 1), AcpContextRegistryFixture.transient_calls);
    try std.testing.expectEqual(
        PermissionMode.auto,
        AcpContextRegistryFixture.transient_permission_mode orelse return error.TestExpectedEqual,
    );

    const tool_context = ctx.toolContext();
    try std.testing.expectEqual(PermissionMode.auto, tool_context.permission_mode);
    try std.testing.expectEqualStrings("test.acp_context", tool_context.context_registry.defaultProvider().id);

    state.context_enabled = false;
    try std.testing.expectEqualStrings("", ctx.modelVisibleProjectContext());
    try std.testing.expect(!ctx.toolContext().context_enabled);
    try std.testing.expect(!agentRuntimeDeps(&ctx).context_enabled);
}

fn testPermissionRuleSet(alloc: Allocator, permission: []const u8, pattern: []const u8, action: types.PermissionAction) !types.PermissionRuleSet {
    var rules = types.PermissionRuleSet{
        .rules = try alloc.alloc(types.PermissionRule, 1),
    };
    errdefer alloc.free(rules.rules);

    const owned_permission = try alloc.dupe(u8, permission);
    errdefer alloc.free(owned_permission);

    const owned_pattern = try alloc.dupe(u8, pattern);
    rules.rules[0] = .{
        .permission = owned_permission,
        .pattern = owned_pattern,
        .action = action,
    };
    return rules;
}

fn writeArgsJson(alloc: Allocator, path: []const u8, content: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"path\":");
    try std.json.Stringify.value(path, .{}, &out.writer);
    try out.writer.writeAll(",\"content\":");
    try std.json.Stringify.value(content, .{}, &out.writer);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn createSymlinkOrSkip(dir: std.Io.Dir, target_path: []const u8, link_path: []const u8) !void {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    dir.symLink(std.testing.io, target_path, link_path, .{ .is_directory = false }) catch |err| {
        if (err == error.AccessDenied or std.mem.eql(u8, @errorName(err), "Permission" ++ "Denied")) {
            return error.SkipZigTest;
        }
        return err;
    };
}

test "ACP deps validate malformed registered calls" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try initTestAcpState(alloc, "/tmp/workspace", .ask);
    defer state.deinit();
    var ctx = AcpContext{ .alloc = alloc, .state = &state, .session_id = "session_1" };

    const deps = agentRuntimeDeps(&ctx);
    try deps.finalize_turn(deps.ctx, 8, .completed, null);
    const validate = deps.validate_tool_call orelse return error.TestExpectedEqual;
    const result = try validate(deps.ctx, arena, .{
        .id = "fetch",
        .name = "web_fetch",
        .arguments_json = "{\"url\":1}",
    });
    try std.testing.expectEqualStrings("web_fetch field \"url\" must be a string", result.failure);
}

test "ACP finalization maps failed turns and provider length" {
    const cases = [_]struct {
        outcome: types.TurnPresentationOutcome,
        disposition: ?types.ProviderCompletionDisposition,
        expected: acp_types.StopReason,
    }{
        .{ .outcome = .completed, .disposition = .length_limited, .expected = .max_output_tokens },
        .{ .outcome = .failed, .disposition = .length_limited, .expected = .max_output_tokens },
        .{ .outcome = .failed, .disposition = null, .expected = .refused },
    };

    for (cases) |case| {
        const alloc = std.testing.allocator;
        var state = try initTestAcpState(alloc, "/tmp/workspace", .ask);
        defer state.deinit();
        var ctx = AcpContext{ .alloc = alloc, .state = &state, .session_id = "session_1" };
        const deps = agentRuntimeDeps(&ctx);

        try deps.finalize_turn(deps.ctx, 8, case.outcome, case.disposition);

        try std.testing.expectEqual(case.expected, ctx.stop_reason);
    }
}

test "ACP deps reject malformed native web_search calls" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try initTestAcpState(alloc, "/tmp/workspace", .ask);
    defer state.deinit();
    var ctx = AcpContext{ .alloc = alloc, .state = &state, .session_id = "session_1" };

    const deps = agentRuntimeDeps(&ctx);
    const validate = deps.validate_tool_call orelse return error.TestExpectedEqual;
    const result = try validate(deps.ctx, arena, .{
        .id = "search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"x\"}",
    });
    try std.testing.expectEqualStrings("web_search field \"query\" must contain at least two characters", result.failure);
}

test "ACP default user commands require configured authority or review" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try initTestAcpState(alloc, "/tmp/workspace", .ask);
    defer state.deinit();
    var ctx = AcpContext{ .alloc = alloc, .state = &state, .session_id = "session_1" };

    const direct = (try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "direct",
        .name = "exec_command",
        .arguments_json = "{\"cmd\":\"pwd\"}",
    }, .ask, &.{}, &.{}));
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, direct.decision);
    try std.testing.expect(direct.execution_authority == null);

    const blocked = (try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "blocked",
        .name = "exec_command",
        .arguments_json = "{\"cmd\":\"touch blocked.txt\"}",
    }, .ask, &.{}, &.{}));
    try std.testing.expectEqual(ToolPermissionDecision.permission_required, blocked.decision);
    try std.testing.expect(blocked.execution_authority == null);

    state.active_session.?.permission_rules = try testPermissionRuleSet(alloc, "bash", "touch *", .allow);
    const configured = (try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "configured",
        .name = "exec_command",
        .arguments_json = "{\"cmd\":\"touch configured.txt\"}",
    }, .ask, &.{}, &.{}));
    switch ((configured.execution_authority orelse return error.TestExpectedEqual).command) {
        .direct_only => return error.TestExpectedShellAllowed,
        .shell_allowed => |authority| try std.testing.expectEqual(command_admission.ShellAuthorizationSource.configured_rule, authority.source),
    }

    state.active_session.?.permission_rules.deinit(alloc);
    state.active_session.?.permission_rules = .{};
    const automatic = (try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "automatic",
        .name = "exec_command",
        .arguments_json = "{\"cmd\":\"touch automatic.txt\"}",
    }, .auto, &.{}, &.{}));
    try std.testing.expectEqual(ToolPermissionDecision.deny, automatic.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.review_unavailable, automatic.denial_reason.?);
    try std.testing.expect(automatic.execution_authority == null);
}

test "ACP auto mode uses automatic review clear and caution without prompting" {
    const FakeClassifier = struct {
        calls: usize = 0,
        decision: permission_auto_classifier.Decision = .clear,
        root_text: []const u8 = "",

        fn classify(
            raw_ctx: *anyopaque,
            alloc: Allocator,
            request: permission_auto_classifier.ReviewRequest,
        ) anyerror!permission_auto_classifier.ParseOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx));
            self.calls += 1;
            self.root_text = request.review_turn.current_root_request;
            return .{ .valid = .{
                .risk = if (self.decision == .clear) .low else .high,
                .decision = self.decision,
                .rationale = try alloc.dupe(u8, "test reviewer rationale"),
            } };
        }
    };

    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try initTestAcpState(alloc, "/tmp/workspace", .ask);
    defer state.deinit();
    var fake = FakeClassifier{ .decision = .clear };
    var ctx = AcpContext{
        .alloc = alloc,
        .state = &state,
        .session_id = "session_1",
        .auto_classifier = permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeClassifier.classify,
        ),
    };

    const direct_call: ToolCall = .{
        .id = "direct",
        .name = "exec_command",
        .arguments_json = "{\"cmd\":\"pwd\"}",
    };
    var direct_review = TestReviewTurn.init("Inspect the workspace.", direct_call);
    const direct = try requestToolPermissionOutcomeWithRequest(
        &ctx,
        arena,
        direct_call,
        direct_review.context(),
        .auto,
        &.{},
        null,
        null,
        &.{},
    );
    try std.testing.expectEqual(
        command_admission.ShellAuthorizationSource.auto_classifier,
        direct.execution_authority.?.command.shell_allowed.source,
    );
    try std.testing.expectEqual(@as(usize, 1), fake.calls);

    const accepted_call: ToolCall = .{
        .id = "accepted",
        .name = "exec_command",
        .arguments_json = "{\"cmd\":\"touch accepted.txt\"}",
    };
    var accepted_review = TestReviewTurn.init("Create accepted.txt.", accepted_call);
    const accepted = try requestToolPermissionOutcomeWithRequest(&ctx, arena, accepted_call, accepted_review.context(), .auto, &.{}, null, null, &.{});
    switch ((accepted.execution_authority orelse return error.TestExpectedEqual).command) {
        .direct_only => return error.TestExpectedShellAllowed,
        .shell_allowed => |authority| try std.testing.expectEqual(
            command_admission.ShellAuthorizationSource.auto_classifier,
            authority.source,
        ),
    }
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expectEqualStrings(
        "Create accepted.txt.",
        fake.root_text,
    );

    fake.decision = .caution;
    const blocked_call: ToolCall = .{
        .id = "check",
        .name = "exec_command",
        .arguments_json = "{\"cmd\":\"touch check.txt\"}",
    };
    var blocked_review = TestReviewTurn.init("Check whether this is allowed.", blocked_call);
    const blocked = try requestToolPermissionOutcomeWithRequest(&ctx, arena, blocked_call, blocked_review.context(), .auto, &.{}, null, null, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.deny, blocked.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.review_caution, blocked.denial_reason.?);
    try std.testing.expect(blocked.execution_authority == null);
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    const blocked_classifier = blocked.auto_review_result orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(permission_auto_classifier.Decision.caution, blocked_classifier.decision);
    try std.testing.expectEqualStrings("test reviewer rationale", blocked_classifier.rationale);
}

test "ACP auto mode automatic review clears or cautions prepared external file mutation" {
    const FakeClassifier = struct {
        calls: usize = 0,
        decision: permission_auto_classifier.Decision = .clear,
        root_text: []const u8 = "",
        saw_file_mutation_context: bool = false,

        fn classify(
            raw_ctx: *anyopaque,
            alloc: Allocator,
            request: permission_auto_classifier.ReviewRequest,
        ) anyerror!permission_auto_classifier.ParseOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx));
            self.calls += 1;
            self.root_text = request.review_turn.current_root_request;
            self.saw_file_mutation_context = std.meta.activeTag(request.action) == .file_mutation;
            return .{ .valid = .{
                .risk = if (self.decision == .clear) .low else .high,
                .decision = self.decision,
                .rationale = try alloc.dupe(u8, "test reviewer rationale"),
            } };
        }
    };

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "external");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external");
    defer alloc.free(external);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try initTestAcpState(alloc, workspace, .auto);
    defer state.deinit();
    var fake = FakeClassifier{ .decision = .clear };
    var ctx = AcpContext{
        .alloc = alloc,
        .state = &state,
        .session_id = "session_1",
        .auto_classifier = permission_auto_classifier.Classifier.withOverride(
            @ptrCast(&fake),
            FakeClassifier.classify,
        ),
    };

    const target_path = try std.fs.path.join(arena, &.{ external, "desktop-test.txt" });
    const arguments_json = try std.fmt.allocPrint(
        arena,
        "{{\"path\":\"{s}\",\"content\":\"hello\\n\"}}",
        .{target_path},
    );
    const accepted_call: ToolCall = .{
        .id = "external-write",
        .name = "write_file",
        .arguments_json = arguments_json,
    };
    var accepted_review = TestReviewTurn.init("Create desktop-test.txt with hello.", accepted_call);
    const accepted = try requestToolPermissionOutcomeWithRequest(&ctx, arena, accepted_call, accepted_review.context(), .auto, &.{}, null, null, &.{});

    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expect(!fake.saw_file_mutation_context);
    try std.testing.expectEqualStrings("", fake.root_text);
    try std.testing.expectEqual(ToolPermissionDecision.once, accepted.decision);
    const authorization = switch (accepted.execution_authority orelse return error.TestExpectedEqual) {
        .file_mutation => |authorization| authorization,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expect(authorization.prepared != null);
    try std.testing.expectEqualStrings(target_path, authorization.input.path());

    {
        var existing = try tmp.dir.createFile(
            io_mod.getIo(),
            "external/desktop-test.txt",
            .{ .truncate = true },
        );
        defer existing.close(io_mod.getIo());
        try existing.writeStreamingAll(io_mod.getIo(), "existing\n");
    }
    fake.decision = .caution;
    const blocked_call: ToolCall = .{
        .id = "external-write-check",
        .name = "write_file",
        .arguments_json = arguments_json,
    };
    var blocked_review = TestReviewTurn.init("Create desktop-test.txt with hello.", blocked_call);
    const blocked = try requestToolPermissionOutcomeWithRequest(&ctx, arena, blocked_call, blocked_review.context(), .auto, &.{}, null, null, &.{});
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqual(ToolPermissionDecision.deny, blocked.decision);
    try std.testing.expectEqual(types.ToolPermissionDenialReason.review_caution, blocked.denial_reason.?);
    try std.testing.expect(blocked.execution_authority == null);
    const blocked_classifier = blocked.auto_review_result orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(permission_auto_classifier.Decision.caution, blocked_classifier.decision);
    try std.testing.expectEqualStrings("test reviewer rationale", blocked_classifier.rationale);
}

test "ACP web_fetch ignores configured ask and deny rules" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try initTestAcpState(alloc, "/tmp/workspace", .auto);
    defer state.deinit();
    var ctx = AcpContext{ .alloc = alloc, .state = &state, .session_id = "session_1" };

    const call: ToolCall = .{
        .id = "fetch",
        .name = "web_fetch",
        .arguments_json = "{\"url\":\"https://example.com/docs\"}",
    };
    const default_outcome = try requestToolPermissionOutcome(&ctx, arena, call, .auto, &.{}, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, default_outcome.decision);
    try std.testing.expect(default_outcome.execution_authority != null);

    state.active_session.?.permission_rules = try testPermissionRuleSet(alloc, "web_fetch", "*", .ask);
    const asked_outcome = try requestToolPermissionOutcome(&ctx, arena, call, .auto, &.{}, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, asked_outcome.decision);

    state.active_session.?.permission_rules.deinit(alloc);
    state.active_session.?.permission_rules = try testPermissionRuleSet(alloc, "web_fetch", "*", .deny);
    const denied_outcome = try requestToolPermissionOutcome(&ctx, arena, call, .auto, &.{}, &.{});
    try std.testing.expectEqual(ToolPermissionDecision.once, denied_outcome.decision);
    state.active_session.?.permission_rules.deinit(alloc);
    state.active_session.?.permission_rules = .{};
}

test "ACP admits default-safe web_search before execution" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try initTestAcpState(alloc, "/tmp/workspace", .auto);
    defer state.deinit();
    var ctx = AcpContext{ .alloc = alloc, .state = &state, .session_id = "session_1" };

    const decision = (try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "search",
        .name = "web_search",
        .arguments_json = "{\"query\":\"current news\"}",
    }, .auto, &.{}, &.{})).decision;

    try std.testing.expectEqual(ToolPermissionDecision.once, decision);
}

test "ACP admits unrestricted web_fetch before execution" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try initTestAcpState(alloc, "/tmp/workspace", .auto);
    defer state.deinit();
    var ctx = AcpContext{ .alloc = alloc, .state = &state, .session_id = "session_1" };

    const decision = (try requestToolPermissionOutcome(&ctx, arena, .{
        .id = "fetch",
        .name = "web_fetch",
        .arguments_json = "{\"url\":\"https://example.com/docs\"}",
    }, .auto, &.{}, &.{})).decision;

    try std.testing.expectEqual(ToolPermissionDecision.once, decision);
}

test "ACP prompt agent config carries request options from active session" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var state = try initTestAcpState(alloc, workspace, .auto);
    defer state.deinit();
    state.context_limits.project_instruction_file_bytes = .{
        .value = .{ .bytes = 17 },
        .source = .command_line,
    };
    state.active_session.?.fast_mode = true;
    state.active_session.?.effort = types.ReasoningEffort.literal("high");

    const session = &state.active_session.?;
    const config = buildAgentConfig(&state, session, .{
        .skills_prompt_section = "",
        .explicit_skills_prompt_section = "",
        .advertised_tool_names = &.{"read_file"},
        .advertised_functions = &.{builtin_tools.read_file.model_schema},
        .custom_tool_guidance = "acp custom tool guidance",
    });

    try std.testing.expect(config.fast_mode);
    try std.testing.expectEqual(types.ReasoningEffort.literal("high"), config.effort);
    try std.testing.expectEqual(@as(usize, 17), config.context_limits.project_instruction_file_bytes.effectiveBytes());
    try std.testing.expectEqual(config_runtime.context_limits.Source.command_line, config.context_limits.project_instruction_file_bytes.source);
    try std.testing.expect(tool_projection_mod.containsName(config.advertised_tool_names, "read_file"));
    try std.testing.expectEqualStrings("acp custom tool guidance", config.custom_tool_guidance);
    try std.testing.expectEqualStrings("ACP test model overlay", config.model_prompt_overlay.?);
    var ctx = AcpContext{ .alloc = alloc, .state = &state, .session_id = "session_1" };
    const tool_ctx = ctx.toolContext();
    try std.testing.expect(!tool_ctx.web_search_runtime_ready);
    try std.testing.expect(tool_ctx.web_search_backend == null);
    try std.testing.expect(state.web_search_runtime.provider == null);
    try std.testing.expect(tool_ctx.web_fetch_runtime.? == &state.web_fetch_runtime);
    try std.testing.expectEqualStrings("/models", tool_ctx.gateway_models_path);
}
