const std = @import("std");
const session = @import("session.zig");
const session_usage = @import("session_usage.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const types = @import("../shared/types.zig");
const responses_output_items = @import("../shared/responses_output_items.zig");
const responses_compaction = @import("../gateway/responses_compaction.zig");
const responses_compaction_binding = @import("../gateway/responses_compaction_binding.zig");
const captured_command = @import("../tooling/captured_command.zig");
const model_provider = @import("../config/model_provider.zig");
const credential_authority = @import("../auth/credential_authority.zig");
const execution_retention = @import("execution_retention.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const DurableSessionPreferences = struct {
    provider: model_provider.ProviderId = .gateway,
    model: []u8,
    effort: types.ReasoningEffort,
    fast_mode: bool,

    pub fn deinit(self: *DurableSessionPreferences, alloc: Allocator) void {
        alloc.free(self.model);
        self.* = undefined;
    }

    pub fn dupe(self: DurableSessionPreferences, alloc: Allocator) !DurableSessionPreferences {
        return .{
            .provider = self.provider,
            .model = try alloc.dupe(u8, self.model),
            .effort = self.effort,
            .fast_mode = self.fast_mode,
        };
    }
};

pub const RecoveryToolState = enum {
    none,
    proven_unexecuted,
    confirmed,
    uncertain,
};

pub const TurnAuthority = struct {
    provider: model_provider.ProviderId,
    model: []u8,
    credential_source: ?types.CredentialSource = null,
    credential_identity: ?credential_authority.Identity = null,

    pub fn deinit(self: *TurnAuthority, alloc: Allocator) void {
        alloc.free(self.model);
        self.* = undefined;
    }

    pub fn dupe(self: TurnAuthority, alloc: Allocator) !TurnAuthority {
        return .{
            .provider = self.provider,
            .model = try alloc.dupe(u8, self.model),
            .credential_source = self.credential_source,
            .credential_identity = self.credential_identity,
        };
    }
};

pub const RecoveryCheckpoint = struct {
    version: u8 = 2,
    turn_id: u64,
    user: session.UserTurn,
    assistant_source: []u8,
    execution: session.ExecutionMemory = .{},
    cause: types.ModelRecoveryCause,
    action: types.ModelRecoveryAction,
    tool_state: RecoveryToolState = .none,
    authority: TurnAuthority,
    requested_fast_mode: bool,
    fast_mode: bool,
    max_provider_attempts: usize,
    consumed_provider_attempts: usize,
    outstanding_reservation: bool = false,

    pub fn deinit(self: *RecoveryCheckpoint, alloc: Allocator) void {
        session.freeUserTurn(alloc, self.user);
        alloc.free(self.assistant_source);
        session.freeExecutionMemory(alloc, self.execution);
        self.authority.deinit(alloc);
        self.* = undefined;
    }

    pub fn dupe(self: RecoveryCheckpoint, alloc: Allocator) !RecoveryCheckpoint {
        const user = try session.dupeUserTurn(alloc, self.user);
        errdefer session.freeUserTurn(alloc, user);
        const assistant_source = try alloc.dupe(u8, self.assistant_source);
        errdefer alloc.free(assistant_source);
        const execution = try types.dupeExecutionMemory(alloc, self.execution);
        errdefer session.freeExecutionMemory(alloc, execution);
        const authority = try self.authority.dupe(alloc);
        return .{
            .version = self.version,
            .turn_id = self.turn_id,
            .user = user,
            .assistant_source = assistant_source,
            .execution = execution,
            .cause = self.cause,
            .action = self.action,
            .tool_state = self.tool_state,
            .authority = authority,
            .requested_fast_mode = self.requested_fast_mode,
            .fast_mode = self.fast_mode,
            .max_provider_attempts = self.max_provider_attempts,
            .consumed_provider_attempts = self.consumed_provider_attempts,
            .outstanding_reservation = self.outstanding_reservation,
        };
    }
};

pub const DurableSessionState = struct {
    id: []u8,
    origin_workspace_root: []u8,
    workspace_root: []u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    conversation_language: session.ConversationLanguage,
    preferences: DurableSessionPreferences,
    history: []session.HistoryTurn,
    context_history_start: usize = 0,
    total_input_tokens: u64,
    total_output_tokens: u64,
    permission_state: session_permission_state.State = .{},
    /// Last ordinary history commit correlated to durable subagent work. This
    /// control-only marker is not included in model history.
    last_subagent_work_id: ?[]u8 = null,
    /// Null only for sessions written before durable usage accounting.
    usage: ?session_usage.Snapshot = null,
    /// Active control state. It is never projected into model history and a
    /// restored checkpoint requires explicit host authority before any send.
    recovery_checkpoint: ?RecoveryCheckpoint = null,

    pub fn deinit(self: *DurableSessionState, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.origin_workspace_root);
        alloc.free(self.workspace_root);
        self.preferences.deinit(alloc);
        session.freeHistoryTurnSlice(alloc, self.history);
        self.permission_state.deinit(alloc);
        if (self.last_subagent_work_id) |id| alloc.free(id);
        if (self.usage) |*usage| usage.deinit(alloc);
        if (self.recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
        self.* = undefined;
    }

    pub fn dupe(self: DurableSessionState, alloc: Allocator) !DurableSessionState {
        const id = try alloc.dupe(u8, self.id);
        errdefer alloc.free(id);
        const origin_workspace_root = try alloc.dupe(u8, self.origin_workspace_root);
        errdefer alloc.free(origin_workspace_root);
        const workspace_root = try alloc.dupe(u8, self.workspace_root);
        errdefer alloc.free(workspace_root);
        const preferences = try self.preferences.dupe(alloc);
        errdefer {
            var owned_preferences = preferences;
            owned_preferences.deinit(alloc);
        }
        const history = try dupeHistory(alloc, self.history);
        errdefer session.freeHistoryTurnSlice(alloc, history);
        const last_subagent_work_id = if (self.last_subagent_work_id) |work_id|
            try alloc.dupe(u8, work_id)
        else
            null;
        errdefer if (last_subagent_work_id) |work_id| alloc.free(work_id);
        var usage = if (self.usage) |snapshot|
            try session_usage.dupeSnapshotOwned(alloc, snapshot)
        else
            null;
        errdefer if (usage) |*snapshot| snapshot.deinit(alloc);
        const recovery_checkpoint = if (self.recovery_checkpoint) |checkpoint|
            try checkpoint.dupe(alloc)
        else
            null;
        const permission_state = try session_permission_state.dupe(
            alloc,
            self.permission_state,
        );

        return .{
            .id = id,
            .origin_workspace_root = origin_workspace_root,
            .workspace_root = workspace_root,
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = self.updated_at_ms,
            .conversation_language = self.conversation_language,
            .preferences = preferences,
            .history = history,
            .context_history_start = self.context_history_start,
            .total_input_tokens = self.total_input_tokens,
            .total_output_tokens = self.total_output_tokens,
            .permission_state = permission_state,
            .last_subagent_work_id = last_subagent_work_id,
            .usage = usage,
            .recovery_checkpoint = recovery_checkpoint,
        };
    }
};

pub const EncodeSummary = struct {
    encoded_bytes: u64,
    sha256: [Sha256.digest_length]u8,
};

pub const DecodeLimits = struct {
    max_history_turns: usize = std.math.maxInt(usize),
    max_value_bytes: usize = std.math.maxInt(usize) / 2,
};

const CountingSha256 = struct {
    sha256: Sha256 = Sha256.init(.{}),
    bytes: u64 = 0,

    pub fn update(self: *CountingSha256, bytes: []const u8) void {
        self.sha256.update(bytes);
        self.bytes += bytes.len;
    }
};

pub fn writeDurableBytes(writer: *std.Io.Writer, bytes: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(bytes)) {
        return writeJsonString(writer, bytes);
    }

    try writer.writeAll("{\"encoding\":\"base64\",\"data\":\"");
    try std.base64.standard.Encoder.encodeWriter(writer, bytes);
    try writer.writeAll("\"}");
}

pub fn parseDurableBytes(alloc: Allocator, value: std.json.Value) ![]u8 {
    switch (value) {
        .string => |text| return try alloc.dupe(u8, text),
        .object => |object| {
            if (object.count() != 2) return error.InvalidDurableBytes;
            var iterator = object.iterator();
            const encoding_entry = iterator.next() orelse return error.InvalidDurableBytes;
            const data_entry = iterator.next() orelse return error.InvalidDurableBytes;
            if (!std.mem.eql(u8, encoding_entry.key_ptr.*, "encoding") or
                !std.mem.eql(u8, data_entry.key_ptr.*, "data"))
            {
                return error.InvalidDurableBytes;
            }
            if (encoding_entry.value_ptr.* != .string or
                !std.mem.eql(u8, encoding_entry.value_ptr.string, "base64") or
                data_entry.value_ptr.* != .string)
            {
                return error.InvalidDurableBytes;
            }

            const encoded = data_entry.value_ptr.string;
            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch
                return error.InvalidDurableBytes;
            const decoded = try alloc.alloc(u8, decoded_len);
            errdefer alloc.free(decoded);
            std.base64.standard.Decoder.decode(decoded, encoded) catch
                return error.InvalidDurableBytes;
            if (std.unicode.utf8ValidateSlice(decoded)) return error.InvalidDurableBytes;

            const canonical_len = std.base64.standard.Encoder.calcSize(decoded.len);
            const canonical = try alloc.alloc(u8, canonical_len);
            defer alloc.free(canonical);
            const written = std.base64.standard.Encoder.encode(canonical, decoded);
            if (!std.mem.eql(u8, written, encoded)) return error.InvalidDurableBytes;
            return decoded;
        },
        else => return error.InvalidDurableBytes,
    }
}

pub fn encodeState(state: DurableSessionState, writer: *std.Io.Writer) !EncodeSummary {
    try validateState(state);

    var hash_buffer: [4096]u8 = undefined;
    var hashed = std.Io.Writer.hashed(writer, CountingSha256{}, &hash_buffer);
    try writeState(&hashed.writer, state);
    try hashed.writer.flush();

    return .{
        .encoded_bytes = hashed.hasher.bytes,
        .sha256 = hashed.hasher.sha256.finalResult(),
    };
}

pub fn decodeState(alloc: Allocator, source: *std.Io.Reader, limits: DecodeLimits) !DurableSessionState {
    return decodeStateImpl(alloc, source, limits) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidDurableField => return error.InvalidDurableField,
        error.InvalidDurableBytes => return error.InvalidDurableBytes,
        else => return error.InvalidSessionFormat,
    };
}

pub fn writeHistoryTurn(writer: *std.Io.Writer, turn: session.HistoryTurn) !void {
    switch (turn) {
        .compacted_summary => |entry| {
            try writer.writeAll("{\"kind\":\"compacted_summary\",\"summary\":");
            try writeDurableBytes(writer, entry.summary);
            try writer.print(",\"removed_turn_count\":{d},\"compaction_count\":{d}", .{
                entry.removed_turn_count,
                entry.compaction_count,
            });
            if (entry.responses_compaction) |checkpoint| {
                try writer.writeAll(",\"responses_compaction\":{\"credential_source\":");
                try writeJsonString(writer, @tagName(checkpoint.credential_source));
                try writer.writeAll(",\"wire_model\":");
                try writeDurableBytes(writer, checkpoint.wire_model);
                try writer.writeAll(",\"input_json\":");
                try writeDurableBytes(writer, checkpoint.input_json);
                if (checkpoint.provider_binding) |binding| {
                    try writer.writeAll(",\"provider_binding\":");
                    try writeResponsesCompactionProviderBinding(writer, binding.view());
                }
                try writer.writeByte('}');
            }
            try writer.writeByte('}');
        },
        .assistant => |entry| {
            try writer.writeAll("{\"kind\":\"assistant\",\"user\":");
            try writeUserTurn(writer, entry.user);
            try writer.writeAll(",\"assistant\":");
            try writeDurableBytes(writer, entry.assistant);
            if (entry.responses_message_output_index) |output_index| {
                try writer.print(",\"responses_message_output_index\":{d}", .{output_index});
            }
            if (entry.reasoning_items.len > 0 or entry.reasoning != null or entry.reasoning_item_id != null or
                entry.reasoning_encrypted_content != null)
            {
                try writer.writeAll(",\"reasoning\":");
                try writeOptionalDurableBytes(writer, entry.reasoning);
                try writer.writeAll(",\"reasoning_item_id\":");
                try writeOptionalDurableBytes(writer, entry.reasoning_item_id);
                try writer.writeAll(",\"reasoning_encrypted_content\":");
                try writeOptionalDurableBytes(writer, entry.reasoning_encrypted_content);
                if (entry.reasoning_items.len > 0) {
                    try writer.writeAll(",\"reasoning_items\":");
                    try writeResponsesReasoningItems(writer, entry.reasoning_items);
                }
            }
            if (entry.responses_provider_output_items.len > 0 or
                entry.responses_output_sequence_complete)
            {
                try writer.writeAll(",\"responses_provider_output_items\":");
                try writeResponsesProviderOutputItems(
                    writer,
                    entry.responses_provider_output_items,
                );
                try writer.print(",\"responses_output_sequence_complete\":{s}", .{
                    if (entry.responses_output_sequence_complete) "true" else "false",
                });
            }
            try writer.writeAll(",\"execution\":");
            try writeExecutionMemory(writer, entry.execution);
            try writer.writeByte('}');
        },
        .background_command => |entry| {
            const extended = entry.assistant != null or hasDurableExecutionMemory(entry.execution);
            try writer.writeAll("{\"kind\":\"background_command\",\"user\":");
            try writeUserTurn(writer, entry.user);
            try writer.writeAll(",\"log_path\":");
            try writeDurableBytes(writer, entry.log_path);
            try writer.print(",\"expect_url\":{s},\"url\":", .{
                if (entry.expect_url) "true" else "false",
            });
            try writeOptionalDurableBytes(writer, entry.url);
            try writer.writeAll(",\"background_record_id\":");
            if (entry.background_record_id) |record_id| {
                try writeHexString(writer, &record_id);
            } else {
                try writer.writeAll("null");
            }
            if (extended) {
                try writer.writeAll(",\"assistant\":");
                try writeOptionalDurableBytes(writer, entry.assistant);
                try writer.writeAll(",\"execution\":");
                try writeExecutionMemory(writer, entry.execution);
            }
            try writer.writeByte('}');
        },
        .interrupted => |entry| {
            try writer.writeAll("{\"kind\":\"interrupted\",\"user\":");
            try writeUserTurn(writer, entry.user);
            try writer.writeAll(",\"assistant\":");
            try writeOptionalDurableBytes(writer, entry.assistant);
            try writer.writeAll(",\"tool_call\":");
            if (entry.tool_call) |tool_call| {
                try writeToolCall(writer, tool_call);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll(",\"completed_tool_names\":[");
            for (entry.completed_tool_names, 0..) |name, i| {
                if (i > 0) try writer.writeByte(',');
                try writeDurableBytes(writer, name);
            }
            try writer.writeByte(']');
            try writer.writeAll(",\"terminal_reason\":");
            try writeJsonString(writer, @tagName(entry.terminal_reason));
            if (hasDurableExecutionMemory(entry.execution)) {
                try writer.writeAll(",\"execution\":");
                try writeExecutionMemory(writer, entry.execution);
            }
            if (entry.cancelled_command) |presentation| {
                try writer.writeAll(",\"cancelled_command\":");
                try writeCancelledCommandPresentation(writer, presentation);
            }
            try writer.writeByte('}');
        },
    }
}

pub fn parseHistoryTurn(alloc: Allocator, value: std.json.Value) !session.HistoryTurn {
    const kind = try requireString(try requireObject(value), "kind");
    if (std.mem.eql(u8, kind, "compacted_summary")) {
        const raw_object = try requireObject(value);
        const has_root_user_messages = raw_object.get("root_user_messages") != null;
        const has_completeness = raw_object.get("root_user_messages_complete") != null;
        const has_permission_feedback = raw_object.get("permission_feedback") != null;
        const has_feedback_completeness = raw_object.get("permission_feedback_complete") != null;
        const has_responses_compaction = raw_object.get("responses_compaction") != null;
        if (has_permission_feedback != has_feedback_completeness) {
            return error.InvalidSessionFormat;
        }
        const object = try exactCompactedSummaryObject(
            value,
            has_root_user_messages,
            has_completeness,
            has_permission_feedback,
            has_feedback_completeness,
            has_responses_compaction,
        );
        const summary = try parseRequiredDurableBytes(alloc, object, "summary");
        errdefer alloc.free(summary);
        const root_user_messages: [][]u8 = if (has_root_user_messages)
            try parseDurableBytesArray(
                alloc,
                object.get("root_user_messages") orelse return error.InvalidSessionFormat,
            )
        else
            &.{};
        errdefer types.freeCompletedToolNames(alloc, root_user_messages);
        const permission_feedback: [][]u8 = if (has_permission_feedback)
            try parseDurableBytesArray(
                alloc,
                object.get("permission_feedback") orelse return error.InvalidSessionFormat,
            )
        else
            &.{};
        errdefer types.freePermissionFeedback(alloc, permission_feedback);
        const remote_compaction = if (has_responses_compaction)
            try parseResponsesCompactionCheckpoint(
                alloc,
                object.get("responses_compaction") orelse return error.InvalidSessionFormat,
            )
        else
            null;
        errdefer if (remote_compaction) |checkpoint| {
            alloc.free(checkpoint.wire_model);
            alloc.free(checkpoint.input_json);
            if (checkpoint.provider_binding) |binding| {
                types.freeResponsesCompactionProviderBinding(alloc, binding);
            }
        };
        const removed_turn_count = try requireUsize(object, "removed_turn_count");
        return .{ .compacted_summary = .{
            .summary = summary,
            .removed_turn_count = removed_turn_count,
            .compaction_count = try requireUsize(object, "compaction_count"),
            .root_user_messages = root_user_messages,
            .root_user_messages_complete = if (has_completeness)
                try requireBool(object, "root_user_messages_complete")
            else
                has_root_user_messages or removed_turn_count == 0,
            .permission_feedback = permission_feedback,
            .permission_feedback_complete = if (has_feedback_completeness)
                try requireBool(object, "permission_feedback_complete")
            else
                removed_turn_count == 0,
            .responses_compaction = remote_compaction,
        } };
    }
    if (std.mem.eql(u8, kind, "assistant")) {
        const raw_object = try requireObject(value);
        const has_reasoning = raw_object.get("reasoning") != null;
        const has_reasoning_item_id = raw_object.get("reasoning_item_id") != null;
        const has_reasoning_encrypted_content = raw_object.get("reasoning_encrypted_content") != null;
        const has_reasoning_items = raw_object.get("reasoning_items") != null;
        const has_provider_output_items = raw_object.get("responses_provider_output_items") != null;
        const has_output_sequence_complete = raw_object.get("responses_output_sequence_complete") != null;
        const has_message_output_index = raw_object.get("responses_message_output_index") != null;
        if (has_provider_output_items != has_output_sequence_complete) {
            return error.InvalidSessionFormat;
        }
        const has_responses_reasoning = has_reasoning or has_reasoning_item_id or
            has_reasoning_encrypted_content or has_reasoning_items;
        if (has_responses_reasoning and
            (!has_reasoning or !has_reasoning_item_id or !has_reasoning_encrypted_content))
        {
            return error.InvalidSessionFormat;
        }
        const object = try exactAssistantHistoryObject(
            value,
            has_responses_reasoning,
            has_reasoning_items,
            has_provider_output_items,
            has_message_output_index,
        );
        const user = try parseUserTurn(alloc, object.get("user") orelse return error.InvalidSessionFormat);
        errdefer session.freeUserTurn(alloc, user);
        const assistant = try parseRequiredDurableBytes(alloc, object, "assistant");
        errdefer alloc.free(assistant);
        const message_output_index: ?u32 = if (has_message_output_index) blk: {
            const value_index = try requireU64(object, "responses_message_output_index");
            if (value_index > std.math.maxInt(u32)) return error.InvalidSessionFormat;
            break :blk @intCast(value_index);
        } else null;
        const reasoning = if (has_responses_reasoning)
            try parseOptionalDurableBytes(alloc, object.get("reasoning") orelse return error.InvalidSessionFormat)
        else
            null;
        errdefer if (reasoning) |owned| alloc.free(owned);
        const reasoning_item_id = if (has_responses_reasoning)
            try parseOptionalDurableBytes(alloc, object.get("reasoning_item_id") orelse return error.InvalidSessionFormat)
        else
            null;
        errdefer if (reasoning_item_id) |owned| alloc.free(owned);
        const reasoning_encrypted_content = if (has_responses_reasoning)
            try parseOptionalDurableBytes(alloc, object.get("reasoning_encrypted_content") orelse return error.InvalidSessionFormat)
        else
            null;
        errdefer if (reasoning_encrypted_content) |owned| alloc.free(owned);
        const reasoning_items: []types.ResponsesReasoningItem = if (has_reasoning_items)
            try parseResponsesReasoningItems(
                alloc,
                object.get("reasoning_items") orelse return error.InvalidSessionFormat,
            )
        else
            &.{};
        errdefer types.freeResponsesReasoningItems(alloc, reasoning_items);
        const provider_output_items: []types.ResponsesProviderOutputItem = if (has_provider_output_items)
            try parseResponsesProviderOutputItems(
                alloc,
                object.get("responses_provider_output_items") orelse
                    return error.InvalidSessionFormat,
            )
        else
            &.{};
        errdefer types.freeResponsesProviderOutputItems(alloc, provider_output_items);
        const output_sequence_complete = if (has_output_sequence_complete)
            try requireBool(object, "responses_output_sequence_complete")
        else
            false;
        if (output_sequence_complete) {
            responses_output_items.validateComplete(alloc, provider_output_items) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidSessionFormat,
            };
        }
        const execution = try parseExecutionMemory(alloc, object.get("execution") orelse return error.InvalidSessionFormat);
        errdefer session.freeExecutionMemory(alloc, execution);
        return .{ .assistant = .{
            .user = user,
            .assistant = assistant,
            .responses_message_output_index = message_output_index,
            .reasoning = reasoning,
            .reasoning_item_id = reasoning_item_id,
            .reasoning_encrypted_content = reasoning_encrypted_content,
            .reasoning_items = reasoning_items,
            .responses_provider_output_items = provider_output_items,
            .responses_output_sequence_complete = output_sequence_complete,
            .execution = execution,
        } };
    }
    if (std.mem.eql(u8, kind, "background_command")) {
        const shape = try exactVariantObject(
            value,
            &.{ "kind", "user", "log_path", "expect_url", "url", "background_record_id" },
            &.{ "kind", "user", "log_path", "expect_url", "url", "background_record_id", "assistant", "execution" },
        );
        const object = shape.object;
        const user = try parseUserTurn(alloc, object.get("user") orelse return error.InvalidSessionFormat);
        errdefer session.freeUserTurn(alloc, user);
        const assistant = if (shape.extended)
            try parseOptionalDurableBytes(alloc, object.get("assistant") orelse return error.InvalidSessionFormat)
        else
            null;
        errdefer if (assistant) |owned| alloc.free(owned);
        const execution = if (shape.extended)
            try parseExecutionMemory(alloc, object.get("execution") orelse return error.InvalidSessionFormat)
        else
            session.ExecutionMemory{};
        errdefer session.freeExecutionMemory(alloc, execution);
        const log_path = try parseRequiredDurableBytes(alloc, object, "log_path");
        errdefer alloc.free(log_path);
        const url = try parseOptionalDurableBytes(alloc, object.get("url") orelse return error.InvalidSessionFormat);
        errdefer if (url) |owned| alloc.free(owned);
        const background_record_id = try parseOptionalIdentifier(object.get("background_record_id") orelse return error.InvalidSessionFormat);
        return .{ .background_command = .{
            .user = user,
            .assistant = assistant,
            .execution = execution,
            .log_path = log_path,
            .expect_url = try requireBool(object, "expect_url"),
            .url = url,
            .background_record_id = background_record_id,
        } };
    }
    if (std.mem.eql(u8, kind, "interrupted")) {
        const source = try requireObject(value);
        const has_execution = source.get("execution") != null;
        const has_presentation = source.get("cancelled_command") != null;
        const has_terminal_reason = source.get("terminal_reason") != null;
        const object = try exactInterruptedHistoryObject(
            value,
            has_execution,
            has_presentation,
            has_terminal_reason,
        );
        const user = try parseUserTurn(alloc, object.get("user") orelse return error.InvalidSessionFormat);
        errdefer session.freeUserTurn(alloc, user);
        const assistant = try parseOptionalDurableBytes(alloc, object.get("assistant") orelse return error.InvalidSessionFormat);
        errdefer if (assistant) |owned| alloc.free(owned);
        const tool_call = try parseOptionalToolCall(alloc, object.get("tool_call") orelse return error.InvalidSessionFormat);
        errdefer if (tool_call) |call| session.freeToolCall(alloc, call);
        const completed_tool_names = try parseDurableBytesArray(
            alloc,
            object.get("completed_tool_names") orelse return error.InvalidSessionFormat,
        );
        errdefer session.freeCompletedToolNames(alloc, completed_tool_names);
        const terminal_reason = if (has_terminal_reason)
            try parseInterruptedTerminalReason(object, "terminal_reason")
        else
            types.InterruptedTerminalReason.cancelled;
        const execution = if (has_execution)
            try parseExecutionMemory(alloc, object.get("execution") orelse return error.InvalidSessionFormat)
        else
            session.ExecutionMemory{};
        errdefer session.freeExecutionMemory(alloc, execution);
        const cancelled_command = if (has_presentation)
            try parseCancelledCommandPresentation(
                alloc,
                object.get("cancelled_command") orelse return error.InvalidSessionFormat,
            )
        else
            null;
        errdefer if (cancelled_command) |presentation| {
            types.freeCancelledCommandPresentation(alloc, presentation);
        };
        if (cancelled_command != null and
            (terminal_reason != .cancelled or
                tool_call == null or
                !try isCapturedCommandToolCall(alloc, tool_call.?)))
        {
            return error.InvalidSessionFormat;
        }
        return .{ .interrupted = .{
            .user = user,
            .assistant = assistant,
            .tool_call = tool_call,
            .completed_tool_names = completed_tool_names,
            .execution = execution,
            .cancelled_command = cancelled_command,
            .terminal_reason = terminal_reason,
        } };
    }
    return error.InvalidSessionFormat;
}

fn exactAssistantHistoryObject(
    value: std.json.Value,
    has_responses_reasoning: bool,
    has_reasoning_items: bool,
    has_provider_output_items: bool,
    has_message_output_index: bool,
) !std.json.ObjectMap {
    var keys: [11][]const u8 = undefined;
    keys[0] = "kind";
    keys[1] = "user";
    keys[2] = "assistant";
    var len: usize = 3;
    if (has_message_output_index) {
        keys[len] = "responses_message_output_index";
        len += 1;
    }
    if (has_responses_reasoning) {
        keys[len] = "reasoning";
        len += 1;
        keys[len] = "reasoning_item_id";
        len += 1;
        keys[len] = "reasoning_encrypted_content";
        len += 1;
    }
    if (has_reasoning_items) {
        keys[len] = "reasoning_items";
        len += 1;
    }
    if (has_provider_output_items) {
        keys[len] = "responses_provider_output_items";
        len += 1;
        keys[len] = "responses_output_sequence_complete";
        len += 1;
    }
    keys[len] = "execution";
    len += 1;
    return exactObject(value, keys[0..len]);
}

fn exactCompactedSummaryObject(
    value: std.json.Value,
    has_root_user_messages: bool,
    has_root_completeness: bool,
    has_permission_feedback: bool,
    has_feedback_completeness: bool,
    has_responses_compaction: bool,
) !std.json.ObjectMap {
    if ((has_root_completeness and !has_root_user_messages) or
        (has_permission_feedback and (!has_root_user_messages or !has_root_completeness)) or
        has_permission_feedback != has_feedback_completeness)
    {
        return error.InvalidSessionFormat;
    }

    var keys: [9][]const u8 = undefined;
    keys[0] = "kind";
    keys[1] = "summary";
    keys[2] = "removed_turn_count";
    keys[3] = "compaction_count";
    var len: usize = 4;
    if (has_root_user_messages) {
        keys[len] = "root_user_messages";
        len += 1;
    }
    if (has_root_completeness) {
        keys[len] = "root_user_messages_complete";
        len += 1;
    }
    if (has_permission_feedback) {
        keys[len] = "permission_feedback";
        len += 1;
    }
    if (has_feedback_completeness) {
        keys[len] = "permission_feedback_complete";
        len += 1;
    }
    if (has_responses_compaction) {
        keys[len] = "responses_compaction";
        len += 1;
    }
    return exactObject(value, keys[0..len]);
}

fn parseResponsesCompactionCheckpoint(
    alloc: Allocator,
    value: std.json.Value,
) !types.ResponsesCompactionCheckpoint {
    const raw_object = switch (value) {
        .object => |object| object,
        else => return error.InvalidSessionFormat,
    };
    const has_provider_binding = raw_object.get("provider_binding") != null;
    const object = if (has_provider_binding)
        try exactObject(
            value,
            &.{ "credential_source", "wire_model", "input_json", "provider_binding" },
        )
    else
        try exactObject(value, &.{ "credential_source", "wire_model", "input_json" });
    const source_raw = try requireString(object, "credential_source");
    const credential_source = types.parseCredentialSource(source_raw) orelse
        return error.InvalidSessionFormat;
    switch (credential_source) {
        .openai_api_key, .chatgpt_subscription => {},
        else => return error.InvalidSessionFormat,
    }

    const wire_model = try parseRequiredDurableBytes(alloc, object, "wire_model");
    errdefer alloc.free(wire_model);
    validateModel(wire_model) catch return error.InvalidSessionFormat;
    const input_json = try parseRequiredDurableBytes(alloc, object, "input_json");
    errdefer alloc.free(input_json);
    responses_compaction.validateReplayInputJson(alloc, input_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    const provider_binding = if (has_provider_binding)
        try parseResponsesCompactionProviderBinding(
            alloc,
            credential_source,
            object.get("provider_binding") orelse return error.InvalidSessionFormat,
        )
    else
        null;
    return .{
        .credential_source = credential_source,
        .wire_model = wire_model,
        .input_json = input_json,
        .provider_binding = provider_binding,
    };
}

fn writeResponsesCompactionProviderBinding(
    writer: *std.Io.Writer,
    binding: types.ResponsesCompactionProviderBindingView,
) !void {
    try writer.writeAll("{\"normalized_origin\":");
    try writeDurableBytes(writer, binding.normalized_origin);
    try writer.writeAll(",\"account_id\":");
    try writeOptionalDurableBytes(writer, binding.account_id);
    try writer.writeAll(",\"api_key_sha256\":");
    try writeOptionalDurableBytes(writer, binding.api_key_sha256);
    try writer.writeAll(",\"organization\":");
    try writeOptionalDurableBytes(writer, binding.organization);
    try writer.writeAll(",\"project\":");
    try writeOptionalDurableBytes(writer, binding.project);
    try writer.writeByte('}');
}

fn parseResponsesCompactionProviderBinding(
    alloc: Allocator,
    credential_source: types.CredentialSource,
    value: std.json.Value,
) !types.ResponsesCompactionProviderBinding {
    const object = try exactObject(value, &.{
        "normalized_origin",
        "account_id",
        "api_key_sha256",
        "organization",
        "project",
    });
    const normalized_origin = try parseRequiredDurableBytes(alloc, object, "normalized_origin");
    errdefer alloc.free(normalized_origin);
    const account_id = try parseOptionalDurableBytes(
        alloc,
        object.get("account_id") orelse return error.InvalidSessionFormat,
    );
    errdefer if (account_id) |field| alloc.free(field);
    const api_key_sha256 = try parseOptionalDurableBytes(
        alloc,
        object.get("api_key_sha256") orelse return error.InvalidSessionFormat,
    );
    errdefer if (api_key_sha256) |field| alloc.free(field);
    const organization = try parseOptionalDurableBytes(
        alloc,
        object.get("organization") orelse return error.InvalidSessionFormat,
    );
    errdefer if (organization) |field| alloc.free(field);
    const project = try parseOptionalDurableBytes(
        alloc,
        object.get("project") orelse return error.InvalidSessionFormat,
    );
    errdefer if (project) |field| alloc.free(field);
    const binding: types.ResponsesCompactionProviderBinding = .{
        .normalized_origin = normalized_origin,
        .account_id = account_id,
        .api_key_sha256 = api_key_sha256,
        .organization = organization,
        .project = project,
    };
    responses_compaction_binding.validate(credential_source, binding.view()) catch
        return error.InvalidSessionFormat;
    return binding;
}

fn isCapturedCommandToolCall(alloc: Allocator, call: types.ToolCall) !bool {
    return captured_command.isToolCall(alloc, call.name, call.arguments_json);
}

pub fn validateState(state: DurableSessionState) !void {
    return validateStateWithPermissionMigration(state, false);
}

fn validateStateWithPermissionMigration(
    state: DurableSessionState,
    allow_legacy_permission_state: bool,
) !void {
    try validateSessionId(state.id);
    try validateWorkspaceRoot(state.origin_workspace_root);
    try validateWorkspaceRoot(state.workspace_root);
    if (state.created_at_ms < 0 or state.updated_at_ms < 0) return error.InvalidDurableField;
    try validateConversationLanguage(state.conversation_language);
    try validateModel(state.preferences.model);
    if (state.context_history_start > state.history.len) return error.InvalidDurableField;
    if (state.last_subagent_work_id) |id| {
        session.validateWorkId(id) catch return error.InvalidDurableField;
    }
    for (state.history) |turn| {
        if (session.historyTurnWorkId(turn)) |id| {
            session.validateWorkId(id) catch return error.InvalidDurableField;
        }
        if (types.historyTurnSummary(turn)) |summary| {
            if (summary.started_at_ms < 0 or
                summary.completed_at_ms < summary.started_at_ms)
            {
                return error.InvalidDurableField;
            }
        }
    }
    if (state.usage) |usage| try session_usage.validateSnapshot(usage);
    if (allow_legacy_permission_state and state.permission_state.version == 1) {
        session_permission_state.validateSchema(state.permission_state, 1) catch
            return error.InvalidDurableField;
    } else {
        session_permission_state.validate(state.permission_state) catch
            return error.InvalidDurableField;
    }
    if (state.recovery_checkpoint) |checkpoint| {
        if (checkpoint.version != 2 or
            checkpoint.turn_id == 0 or
            checkpoint.max_provider_attempts == 0 or
            checkpoint.consumed_provider_attempts > checkpoint.max_provider_attempts or
            (checkpoint.outstanding_reservation and
                checkpoint.consumed_provider_attempts >= checkpoint.max_provider_attempts))
        {
            return error.InvalidDurableField;
        }
        try validateModel(checkpoint.authority.model);
        if (checkpoint.authority.credential_identity != null and
            checkpoint.authority.credential_source == null)
        {
            return error.InvalidDurableField;
        }
        if (checkpoint.authority.credential_source) |source| {
            if (!model_provider.authorizesCredential(checkpoint.authority.provider, source)) {
                return error.InvalidDurableField;
            }
        }
    }
}

pub fn validateModelPreference(value: []const u8) !void {
    try validateModel(value);
}

pub fn parseConversationLanguage(raw: []const u8) !session.ConversationLanguage {
    try validateConversationLanguageBytes(raw);
    return session.ConversationLanguage.fromSlice(raw) catch error.InvalidDurableField;
}

fn writeState(writer: *std.Io.Writer, state: DurableSessionState) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, state.id);
    try writer.writeAll(",\"origin_workspace_root\":");
    try writeJsonString(writer, state.origin_workspace_root);
    try writer.writeAll(",\"workspace_root\":");
    try writeJsonString(writer, state.workspace_root);
    try writer.print(",\"created_at_ms\":{d},\"updated_at_ms\":{d}", .{
        state.created_at_ms,
        state.updated_at_ms,
    });
    try writer.writeAll(",\"conversation_language\":");
    try writeJsonString(writer, state.conversation_language.view());
    try writer.writeAll(",\"preferences\":{\"model\":");
    try writeJsonString(writer, state.preferences.model);
    try writer.writeAll(",\"effort\":");
    try writeJsonString(writer, state.preferences.effort.label());
    try writer.print(",\"fast_mode\":{s},\"provider\":", .{
        if (state.preferences.fast_mode) "true" else "false",
    });
    try writeJsonString(writer, @tagName(state.preferences.provider));
    try writer.writeAll("},\"history\":[");
    for (state.history, 0..) |turn, i| {
        if (i > 0) try writer.writeByte(',');
        try writeHistoryTurn(writer, turn);
    }
    try writer.print("],\"total_input_tokens\":{d},\"total_output_tokens\":{d},\"context_history_start\":{d}", .{
        state.total_input_tokens,
        state.total_output_tokens,
        state.context_history_start,
    });
    try writer.writeAll(",\"permission_state\":");
    try writePermissionState(writer, state.permission_state);
    if (state.usage) |usage| {
        try writer.writeAll(",\"usage\":");
        try session_usage.writeSnapshot(writer, usage);
    }
    if (state.last_subagent_work_id) |id| {
        try writer.writeAll(",\"last_subagent_work_id\":");
        try writeJsonString(writer, id);
    }
    if (state.recovery_checkpoint) |checkpoint| {
        try writer.writeAll(",\"recovery_checkpoint\":");
        try writeRecoveryCheckpoint(writer, checkpoint);
    }
    try writer.writeByte('}');
}

fn writePermissionState(
    writer: *std.Io.Writer,
    state: session_permission_state.State,
) !void {
    try writer.print("{{\"schema_version\":{d},\"next_generation\":{d},\"rules\":[", .{
        state.version,
        state.next_generation,
    });
    for (state.rules.items, 0..) |rule, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"id\":{d},\"kind\":", .{rule.id.value});
        try writeJsonString(writer, @tagName(rule.key.kind));
        try writer.writeAll(",\"canonical\":");
        try writeDurableBytes(writer, rule.key.canonical);
        try writer.writeAll(",\"display_identity\":");
        try writeDurableBytes(writer, rule.display_identity);
        try writer.writeAll(",\"decision\":");
        try writeJsonString(writer, @tagName(rule.decision));
        try writer.print(",\"generation\":{d}}}", .{rule.generation});
    }
    try writer.writeAll("]}");
}

fn parsePermissionState(
    alloc: Allocator,
    value: std.json.Value,
) !session_permission_state.State {
    const object = try exactObject(value, &.{
        "schema_version",
        "next_generation",
        "rules",
    });
    const version = std.math.cast(
        u8,
        try requireU64(object, "schema_version"),
    ) orelse return error.InvalidDurableField;
    const rules_value = object.get("rules") orelse
        return error.InvalidSessionFormat;
    if (rules_value != .array) return error.InvalidSessionFormat;

    var state: session_permission_state.State = .{
        .version = version,
        .next_generation = try requireU64(object, "next_generation"),
    };
    errdefer state.deinit(alloc);
    try state.rules.ensureTotalCapacity(
        alloc,
        @min(rules_value.array.items.len, session_permission_state.max_rules),
    );
    for (rules_value.array.items) |rule_value| {
        if (state.rules.items.len == session_permission_state.max_rules) {
            return error.InvalidDurableField;
        }
        const rule_object = try exactObject(rule_value, &.{
            "id",
            "kind",
            "canonical",
            "display_identity",
            "decision",
            "generation",
        });
        const kind = std.meta.stringToEnum(
            session_permission_state.RuleKey.Kind,
            try requireString(rule_object, "kind"),
        ) orelse return error.InvalidDurableField;
        const canonical = try parseRequiredDurableBytes(
            alloc,
            rule_object,
            "canonical",
        );
        errdefer alloc.free(canonical);
        const key = session_permission_state.RuleKey.init(
            kind,
            canonical,
        ) catch return error.InvalidDurableField;
        const display_identity = try parseRequiredDurableBytes(
            alloc,
            rule_object,
            "display_identity",
        );
        errdefer alloc.free(display_identity);
        const decision = std.meta.stringToEnum(
            session_permission_state.Decision,
            try requireString(rule_object, "decision"),
        ) orelse return error.InvalidDurableField;
        try state.rules.append(alloc, .{
            .id = .{ .value = try requireU64(rule_object, "id") },
            .key = key,
            .display_identity = display_identity,
            .decision = decision,
            .generation = try requireU64(rule_object, "generation"),
        });
    }
    session_permission_state.validateSchema(state, version) catch
        return error.InvalidDurableField;
    return state;
}

pub fn writeRecoveryCheckpoint(writer: *std.Io.Writer, checkpoint: RecoveryCheckpoint) !void {
    try writer.print("{{\"version\":{d},\"turn_id\":{d},\"user\":", .{
        checkpoint.version,
        checkpoint.turn_id,
    });
    try writeUserTurn(writer, checkpoint.user);
    try writer.writeAll(",\"assistant_source\":");
    try writeDurableBytes(writer, checkpoint.assistant_source);
    try writer.writeAll(",\"execution\":");
    try writeExecutionMemory(writer, checkpoint.execution);
    try writer.writeAll(",\"cause\":");
    try writeJsonString(writer, @tagName(checkpoint.cause));
    try writer.writeAll(",\"action\":");
    try writeJsonString(writer, @tagName(checkpoint.action));
    try writer.writeAll(",\"tool_state\":");
    try writeJsonString(writer, @tagName(checkpoint.tool_state));
    try writer.writeAll(",\"authority\":{\"provider\":");
    try writeJsonString(writer, @tagName(checkpoint.authority.provider));
    try writer.writeAll(",\"model\":");
    try writeDurableBytes(writer, checkpoint.authority.model);
    try writer.writeAll(",\"credential_source\":");
    if (checkpoint.authority.credential_source) |source| {
        try writeJsonString(writer, @tagName(source));
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"credential_identity\":");
    if (checkpoint.authority.credential_identity) |identity| {
        const hex = std.fmt.bytesToHex(identity.bytes, .lower);
        try writeJsonString(writer, &hex);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
    try writer.print(",\"requested_fast_mode\":{s},\"fast_mode\":{s},\"max_provider_attempts\":{d},\"consumed_provider_attempts\":{d},\"outstanding_reservation\":{s}}}", .{
        if (checkpoint.requested_fast_mode) "true" else "false",
        if (checkpoint.fast_mode) "true" else "false",
        checkpoint.max_provider_attempts,
        checkpoint.consumed_provider_attempts,
        if (checkpoint.outstanding_reservation) "true" else "false",
    });
}

fn decodeStateImpl(alloc: Allocator, source: *std.Io.Reader, limits: DecodeLimits) !DurableSessionState {
    var json_reader = std.json.Reader.init(alloc, source);
    defer json_reader.deinit();

    try expectToken(try json_reader.next(), .object_begin);
    try expectKey(&json_reader, alloc, "id");
    const id = try readStringOwned(&json_reader, alloc, 255);
    errdefer alloc.free(id);
    try expectKey(&json_reader, alloc, "origin_workspace_root");
    const origin_workspace_root = try readStringOwned(&json_reader, alloc, std.Io.Dir.max_path_bytes);
    errdefer alloc.free(origin_workspace_root);
    try expectKey(&json_reader, alloc, "workspace_root");
    const workspace_root = try readStringOwned(&json_reader, alloc, std.Io.Dir.max_path_bytes);
    errdefer alloc.free(workspace_root);
    try expectKey(&json_reader, alloc, "created_at_ms");
    const created_at_ms = try readI64(&json_reader, alloc);
    try expectKey(&json_reader, alloc, "updated_at_ms");
    const updated_at_ms = try readI64(&json_reader, alloc);
    try expectKey(&json_reader, alloc, "conversation_language");
    const language_raw = try readStringOwned(&json_reader, alloc, session.ConversationLanguage.max_len);
    defer alloc.free(language_raw);
    const conversation_language = try parseConversationLanguage(language_raw);

    try expectKey(&json_reader, alloc, "preferences");
    try expectToken(try json_reader.next(), .object_begin);
    try expectKey(&json_reader, alloc, "model");
    const model = try readStringOwned(&json_reader, alloc, 1024);
    errdefer alloc.free(model);
    try expectKey(&json_reader, alloc, "effort");
    const effort_raw = try readStringOwned(&json_reader, alloc, types.ReasoningEffort.max_name_bytes);
    defer alloc.free(effort_raw);
    const effort = types.ReasoningEffort.parse(effort_raw) orelse
        return error.InvalidDurableField;
    try expectKey(&json_reader, alloc, "fast_mode");
    const fast_mode = try readBool(&json_reader);
    var provider: model_provider.ProviderId = .gateway;
    if (try json_reader.peekNextTokenType() != .object_end) {
        try expectKey(&json_reader, alloc, "provider");
        const provider_raw = try readStringOwned(&json_reader, alloc, 16);
        defer alloc.free(provider_raw);
        provider = model_provider.parse(provider_raw) orelse return error.InvalidDurableField;
    }
    try expectToken(try json_reader.next(), .object_end);

    try expectKey(&json_reader, alloc, "history");
    try expectToken(try json_reader.next(), .array_begin);
    var history: std.ArrayList(session.HistoryTurn) = .empty;
    errdefer {
        for (history.items) |turn| session.freeHistoryTurn(alloc, turn);
        history.deinit(alloc);
    }
    while (try json_reader.peekNextTokenType() != .array_end) {
        if (history.items.len == limits.max_history_turns) return error.InvalidSessionFormat;
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const value = try std.json.Value.jsonParse(arena.allocator(), &json_reader, .{
            .max_value_len = limits.max_value_bytes,
            .allocate = .alloc_always,
            .parse_numbers = false,
        });
        const turn = try parseHistoryTurn(alloc, value);
        errdefer session.freeHistoryTurn(alloc, turn);
        try history.append(alloc, turn);
    }
    try expectToken(try json_reader.next(), .array_end);

    try expectKey(&json_reader, alloc, "total_input_tokens");
    const total_input_tokens = try readU64(&json_reader, alloc);
    try expectKey(&json_reader, alloc, "total_output_tokens");
    const total_output_tokens = try readU64(&json_reader, alloc);
    var context_history_start: usize = 0;
    var context_seen = false;
    var permission_state: session_permission_state.State = .{};
    errdefer permission_state.deinit(alloc);
    var permission_state_seen = false;
    var usage: ?session_usage.Snapshot = null;
    var usage_seen = false;
    var last_subagent_work_id: ?[]u8 = null;
    errdefer if (last_subagent_work_id) |work_id| alloc.free(work_id);
    var recovery_checkpoint: ?RecoveryCheckpoint = null;
    errdefer if (recovery_checkpoint) |*checkpoint| checkpoint.deinit(alloc);
    while (try json_reader.peekNextTokenType() != .object_end) {
        const key = try readStringOwned(&json_reader, alloc, 64);
        defer alloc.free(key);
        if (std.mem.eql(u8, key, "context_history_start")) {
            if (context_seen or permission_state_seen or usage_seen or last_subagent_work_id != null or recovery_checkpoint != null) {
                return error.InvalidSessionFormat;
            }
            const raw = try readU64(&json_reader, alloc);
            context_history_start = std.math.cast(usize, raw) orelse
                return error.InvalidSessionFormat;
            context_seen = true;
        } else if (std.mem.eql(u8, key, "permission_state")) {
            if (permission_state_seen or usage_seen or last_subagent_work_id != null or recovery_checkpoint != null) {
                return error.InvalidSessionFormat;
            }
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const value = try std.json.Value.jsonParse(arena.allocator(), &json_reader, .{
                .max_value_len = limits.max_value_bytes,
                .allocate = .alloc_always,
                .parse_numbers = false,
            });
            permission_state = try parsePermissionState(alloc, value);
            permission_state_seen = true;
        } else if (std.mem.eql(u8, key, "usage")) {
            if (usage_seen or last_subagent_work_id != null or recovery_checkpoint != null) return error.InvalidSessionFormat;
            const parse_limit = @min(
                limits.max_value_bytes,
                session_usage.max_snapshot_bytes,
            );
            const parse_buffer = try alloc.alloc(u8, parse_limit);
            defer alloc.free(parse_buffer);
            var fixed = std.heap.FixedBufferAllocator.init(parse_buffer);
            const value = try std.json.Value.jsonParse(fixed.allocator(), &json_reader, .{
                .max_value_len = parse_limit,
                .allocate = .alloc_always,
                .parse_numbers = false,
            });
            usage = try session_usage.parseSnapshotValue(alloc, value);
            usage_seen = true;
        } else if (std.mem.eql(u8, key, "last_subagent_work_id")) {
            if (last_subagent_work_id != null or recovery_checkpoint != null) return error.InvalidSessionFormat;
            last_subagent_work_id = try readStringOwned(&json_reader, alloc, 128);
        } else if (std.mem.eql(u8, key, "recovery_checkpoint")) {
            if (recovery_checkpoint != null) return error.InvalidSessionFormat;
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const value = try std.json.Value.jsonParse(arena.allocator(), &json_reader, .{
                .max_value_len = limits.max_value_bytes,
                .allocate = .alloc_always,
                .parse_numbers = false,
            });
            recovery_checkpoint = try parseRecoveryCheckpoint(alloc, value);
        } else return error.InvalidSessionFormat;
    }
    errdefer if (usage) |*snapshot| snapshot.deinit(alloc);
    try expectToken(try json_reader.next(), .object_end);
    try expectToken(try json_reader.next(), .end_of_document);

    const owned_history = try history.toOwnedSlice(alloc);
    errdefer session.freeHistoryTurnSlice(alloc, owned_history);
    const state = DurableSessionState{
        .id = id,
        .origin_workspace_root = origin_workspace_root,
        .workspace_root = workspace_root,
        .created_at_ms = created_at_ms,
        .updated_at_ms = updated_at_ms,
        .conversation_language = conversation_language,
        .preferences = .{
            .provider = provider,
            .model = model,
            .effort = effort,
            .fast_mode = fast_mode,
        },
        .history = owned_history,
        .context_history_start = context_history_start,
        .total_input_tokens = total_input_tokens,
        .total_output_tokens = total_output_tokens,
        .permission_state = permission_state,
        .last_subagent_work_id = last_subagent_work_id,
        .usage = usage,
        .recovery_checkpoint = recovery_checkpoint,
    };
    try validateStateWithPermissionMigration(state, true);
    return state;
}

pub fn parseRecoveryCheckpoint(alloc: Allocator, value: std.json.Value) !RecoveryCheckpoint {
    const raw_object = try requireObject(value);
    const version = try requireU64(raw_object, "version");
    const object = switch (version) {
        1 => if (raw_object.get("route_provider") != null)
            try exactObject(value, &.{
                "version",             "turn_id",   "user",                  "assistant_source",           "execution",
                "cause",               "action",    "tool_state",            "route_model",                "route_provider",
                "requested_fast_mode", "fast_mode", "max_provider_attempts", "consumed_provider_attempts", "outstanding_reservation",
            })
        else
            try exactObject(value, &.{
                "version",   "turn_id",               "user",                       "assistant_source",        "execution",
                "cause",     "action",                "tool_state",                 "route_model",             "requested_fast_mode",
                "fast_mode", "max_provider_attempts", "consumed_provider_attempts", "outstanding_reservation",
            }),
        2 => try exactObject(value, &.{
            "version",   "turn_id",               "user",                       "assistant_source",        "execution",
            "cause",     "action",                "tool_state",                 "authority",               "requested_fast_mode",
            "fast_mode", "max_provider_attempts", "consumed_provider_attempts", "outstanding_reservation",
        }),
        else => return error.InvalidDurableField,
    };
    const user = try parseUserTurn(alloc, object.get("user") orelse return error.InvalidSessionFormat);
    errdefer session.freeUserTurn(alloc, user);
    const assistant_source = try parseDurableBytes(alloc, object.get("assistant_source") orelse return error.InvalidSessionFormat);
    errdefer alloc.free(assistant_source);
    const execution = try parseExecutionMemory(alloc, object.get("execution") orelse return error.InvalidSessionFormat);
    errdefer session.freeExecutionMemory(alloc, execution);
    const authority = if (version == 1) legacy: {
        const model = try parseDurableBytes(alloc, object.get("route_model") orelse return error.InvalidSessionFormat);
        break :legacy TurnAuthority{
            .provider = if (object.get("route_provider")) |provider_value| blk: {
                if (provider_value != .string) return error.InvalidDurableField;
                break :blk model_provider.parse(provider_value.string) orelse return error.InvalidDurableField;
            } else .gateway,
            .model = model,
        };
    } else try parseTurnAuthority(alloc, object.get("authority") orelse return error.InvalidSessionFormat);
    errdefer {
        var owned_authority = authority;
        owned_authority.deinit(alloc);
    }
    const max_provider_attempts = std.math.cast(usize, try requireU64(object, "max_provider_attempts")) orelse
        return error.InvalidDurableField;
    const consumed_provider_attempts = std.math.cast(usize, try requireU64(object, "consumed_provider_attempts")) orelse
        return error.InvalidDurableField;
    return .{
        .version = 2,
        .turn_id = try requireU64(object, "turn_id"),
        .user = user,
        .assistant_source = assistant_source,
        .execution = execution,
        .cause = std.meta.stringToEnum(types.ModelRecoveryCause, try requireString(object, "cause")) orelse
            return error.InvalidDurableField,
        .action = std.meta.stringToEnum(types.ModelRecoveryAction, try requireString(object, "action")) orelse
            return error.InvalidDurableField,
        .tool_state = std.meta.stringToEnum(RecoveryToolState, try requireString(object, "tool_state")) orelse
            return error.InvalidDurableField,
        .authority = authority,
        .requested_fast_mode = try requireBool(object, "requested_fast_mode"),
        .fast_mode = try requireBool(object, "fast_mode"),
        .max_provider_attempts = max_provider_attempts,
        .consumed_provider_attempts = consumed_provider_attempts,
        .outstanding_reservation = try requireBool(object, "outstanding_reservation"),
    };
}

fn parseTurnAuthority(alloc: Allocator, value: std.json.Value) !TurnAuthority {
    const object = try exactObject(value, &.{
        "provider",
        "model",
        "credential_source",
        "credential_identity",
    });
    const provider = model_provider.parse(try requireString(object, "provider")) orelse
        return error.InvalidDurableField;
    const model = try parseDurableBytes(alloc, object.get("model") orelse return error.InvalidSessionFormat);
    errdefer alloc.free(model);
    const credential_source = if (object.get("credential_source")) |source| switch (source) {
        .null => null,
        .string => |text| types.parseCredentialSource(text) orelse return error.InvalidDurableField,
        else => return error.InvalidDurableField,
    } else return error.InvalidSessionFormat;
    const credential_identity = if (object.get("credential_identity")) |identity| switch (identity) {
        .null => null,
        .string => |hex| identity: {
            var bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            _ = std.fmt.hexToBytes(&bytes, hex) catch return error.InvalidDurableField;
            const canonical = std.fmt.bytesToHex(bytes, .lower);
            if (!std.mem.eql(u8, &canonical, hex)) return error.InvalidDurableField;
            break :identity credential_authority.Identity{ .bytes = bytes };
        },
        else => return error.InvalidDurableField,
    } else return error.InvalidSessionFormat;
    if (credential_identity != null and credential_source == null) {
        return error.InvalidDurableField;
    }
    return .{
        .provider = provider,
        .model = model,
        .credential_source = credential_source,
        .credential_identity = credential_identity,
    };
}

fn writeUserTurn(writer: *std.Io.Writer, user: session.UserTurn) !void {
    try writer.writeAll("{\"text\":");
    try writeDurableBytes(writer, user.text);
    try writer.writeAll(",\"images\":[");
    for (user.images, 0..) |image, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"id\":{d},\"path\":", .{image.id});
        try writeDurableBytes(writer, image.path);
        try writer.writeAll(",\"media_type\":");
        try writeDurableBytes(writer, image.media_type);
        try writer.writeAll(",\"snapshot_path\":");
        try writeSnapshotLocator(writer, image.snapshot_path);
        try writer.writeAll(",\"snapshot_sha256\":");
        try writeOptionalDurableBytes(writer, image.snapshot_sha256);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
    if (!user.proven_root) try writer.writeAll(",\"proven_root\":false");
    if (user.work_id) |work_id| {
        try writer.writeAll(",\"work_id\":");
        try writeJsonString(writer, work_id);
    }
    try writer.writeByte('}');
}

fn writeSnapshotLocator(writer: *std.Io.Writer, value: ?[]const u8) !void {
    const path = value orelse {
        try writer.writeAll("null");
        return;
    };
    var locator_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const locator = try session.projectSnapshotLocator(&locator_buffer, path);
    try writeDurableBytes(writer, locator);
}

fn writeExecutionMemory(writer: *std.Io.Writer, execution: session.ExecutionMemory) !void {
    const schema_version: u8 = blk: {
        for (execution.tool_steps) |step| {
            if (step.responses_message_output_index != null or
                step.responses_provider_output_items.len > 0 or
                step.responses_output_sequence_complete) break :blk 7;
            if (step.reasoning_items.len > 0) break :blk 7;
            if (step.reasoning != null or step.reasoning_item_id != null or
                step.reasoning_encrypted_content != null)
            {
                break :blk 7;
            }
        }
        break :blk 7;
    };
    try writer.print("{{\"schema_version\":{d},\"tool_steps\":[", .{schema_version});
    for (execution.tool_steps, 0..) |step, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"assistant\":");
        try writeOptionalDurableBytes(writer, step.assistant);
        if (schema_version >= 4) {
            try writer.writeAll(",\"reasoning\":");
            try writeOptionalDurableBytes(writer, step.reasoning);
            try writer.writeAll(",\"reasoning_item_id\":");
            try writeOptionalDurableBytes(writer, step.reasoning_item_id);
            try writer.writeAll(",\"reasoning_encrypted_content\":");
            try writeOptionalDurableBytes(writer, step.reasoning_encrypted_content);
            if (schema_version >= 5) {
                try writer.writeAll(",\"reasoning_items\":");
                try writeResponsesReasoningItems(writer, step.reasoning_items);
            }
            if (schema_version >= 6) {
                try writer.writeAll(",\"responses_message_output_index\":");
                try writeOptionalU32(writer, step.responses_message_output_index);
                try writer.writeAll(",\"responses_provider_output_items\":");
                try writeResponsesProviderOutputItems(
                    writer,
                    step.responses_provider_output_items,
                );
                try writer.print(",\"responses_output_sequence_complete\":{s}", .{
                    if (step.responses_output_sequence_complete) "true" else "false",
                });
            }
        }
        try writer.writeAll(",\"tool_calls\":[");
        for (step.tool_calls, 0..) |tool_call, call_index| {
            if (call_index > 0) try writer.writeByte(',');
            try writeToolCall(writer, tool_call);
        }
        try writer.writeAll("],\"tool_results\":[");
        for (step.tool_results, 0..) |result, result_index| {
            if (result_index > 0) try writer.writeByte(',');
            try writePersistedToolResult(writer, result);
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("],\"files\":[");
    for (execution.files, 0..) |file, i| {
        if (i > 0) try writer.writeByte(',');
        try writeFileEvidence(writer, file);
    }
    try writer.writeByte(']');
    if (execution.user_inputs.len > 0) {
        try writer.writeAll(",\"user_inputs\":[");
        for (execution.user_inputs, 0..) |user, i| {
            if (i > 0) try writer.writeByte(',');
            try writeUserTurn(writer, user);
        }
        try writer.writeByte(']');
    }
    try writer.writeAll(",\"turn_summary\":");
    if (execution.turn_summary) |summary| {
        try writeTurnSummary(writer, summary);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

fn hasDurableExecutionMemory(execution: session.ExecutionMemory) bool {
    return !execution.isEmpty() or execution.turn_summary != null;
}

fn writeTurnSummary(writer: *std.Io.Writer, summary: types.TurnSummary) !void {
    try writer.print(
        "{{\"started_at_ms\":{d},\"completed_at_ms\":{d},\"thinking_duration_ms\":{d},\"turn_duration_ms\":{d},\"token_progress\":{{\"input_tokens\":{d},\"output_tokens\":{d},\"input_exact\":{s},\"output_exact\":{s}}}}}",
        .{
            summary.started_at_ms,
            summary.completed_at_ms,
            summary.thinking_duration_ms,
            summary.turn_duration_ms,
            summary.token_progress.input_tokens,
            summary.token_progress.output_tokens,
            if (summary.token_progress.input_exact) "true" else "false",
            if (summary.token_progress.output_exact) "true" else "false",
        },
    );
}

fn writeToolCall(writer: *std.Io.Writer, tool_call: session.ToolCall) !void {
    try writer.writeAll("{\"id\":");
    try writeDurableBytes(writer, tool_call.id);
    try writer.writeAll(",\"name\":");
    try writeDurableBytes(writer, tool_call.name);
    try writer.writeAll(",\"arguments_json\":");
    try writeDurableBytes(writer, tool_call.arguments_json);
    try writer.writeAll(",\"provider_result\":");
    try writeOptionalDurableBytes(writer, tool_call.provider_result);
    if (tool_call.responses_item_id) |item_id| {
        try writer.writeAll(",\"responses_item_id\":");
        try writeDurableBytes(writer, item_id);
    }
    if (tool_call.responses_output_index) |output_index| {
        try writer.print(",\"responses_output_index\":{d}", .{output_index});
    }
    try writer.writeByte('}');
}

fn writePersistedToolResult(writer: *std.Io.Writer, result: session.PersistedToolResult) !void {
    try writer.writeAll("{\"tool_call_id\":");
    try writeDurableBytes(writer, result.tool_call_id);
    try writer.writeAll(",\"tool_name\":");
    try writeDurableBytes(writer, result.tool_name);
    try writer.writeAll(",\"status\":");
    try writeJsonString(writer, @tagName(result.status));
    try writer.writeAll(",\"output\":");
    try writeDurableBytes(writer, result.output);
    try writer.writeAll(",\"output_handle\":");
    try writeOptionalDurableBytes(writer, result.output_handle);
    try writer.writeAll(",\"preview\":");
    try writeOptionalDurableBytes(writer, result.preview);
    try writer.print(
        ",\"output_bytes\":{d},\"stored_output_bytes\":{d},\"truncated\":{s},\"provider_native\":{s},\"created_at_ms\":{d}",
        .{
            result.output_bytes,
            result.stored_output_bytes,
            if (result.truncated) "true" else "false",
            if (result.provider_native) "true" else "false",
            result.created_at_ms,
        },
    );
    try writer.writeAll(",\"permission_feedback\":[");
    for (result.permission_feedback, 0..) |feedback, i| {
        if (i > 0) try writer.writeByte(',');
        try writeDurableBytes(writer, feedback);
    }
    try writer.writeAll("],\"committed_file_presentation\":");
    if (result.committed_file_presentation) |presentation| {
        try writeCommittedFilePresentation(writer, presentation);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"command_output_replay\":");
    try writeOptionalCommandOutputReplay(writer, result.command_output_replay);
    if (result.command_artifact_handle) |handle| {
        try writer.writeAll(",\"command_artifact_handle\":");
        try writeDurableBytes(writer, handle);
    }
    try writer.writeAll(",\"command_process_presentation\":");
    try writeOptionalCommandProcessPresentation(
        writer,
        result.command_process_presentation,
    );
    try writer.writeByte('}');
}

fn writeCancelledCommandPresentation(
    writer: *std.Io.Writer,
    presentation: session.CancelledCommandPresentation,
) !void {
    try writer.writeAll("{\"output_replay\":");
    try writeOptionalCommandOutputReplay(writer, presentation.output_replay);
    try writer.writeAll(",\"command_artifact_handle\":");
    try writeOptionalDurableBytes(writer, presentation.command_artifact_handle);
    try writer.writeByte('}');
}

fn parseCancelledCommandPresentation(
    alloc: Allocator,
    value: std.json.Value,
) !session.CancelledCommandPresentation {
    const object = try exactObject(value, &.{
        "output_replay",
        "command_artifact_handle",
    });
    const output_replay = try parseOptionalCommandOutputReplay(
        alloc,
        object.get("output_replay") orelse return error.InvalidSessionFormat,
    );
    errdefer if (output_replay) |replay| types.freeCommandOutputReplay(alloc, replay);
    return .{
        .output_replay = output_replay,
        .command_artifact_handle = try parseOptionalDurableBytes(
            alloc,
            object.get("command_artifact_handle") orelse return error.InvalidSessionFormat,
        ),
    };
}

fn writeOptionalCommandOutputReplay(
    writer: *std.Io.Writer,
    replay: ?types.CommandOutputReplay,
) !void {
    const value = replay orelse {
        try writer.writeAll("null");
        return;
    };
    switch (value) {
        .available => |descriptor| {
            try writer.writeAll("{\"kind\":\"available\",\"handle\":");
            try writeDurableBytes(writer, descriptor.handle);
            try writer.print(",\"framed_bytes\":{d}}}", .{descriptor.framed_bytes});
        },
        .unavailable => try writer.writeAll("{\"kind\":\"unavailable\"}"),
    }
}

fn writeOptionalCommandProcessPresentation(
    writer: *std.Io.Writer,
    presentation: ?types.CommandProcessPresentation,
) !void {
    const value = presentation orelse {
        try writer.writeAll("null");
        return;
    };
    switch (value) {
        .exit_code => |exit_code| try writer.print(
            "{{\"kind\":\"exit_code\",\"value\":{d}}}",
            .{exit_code},
        ),
        .signal => |signal| try writer.print(
            "{{\"kind\":\"signal\",\"value\":{d}}}",
            .{signal},
        ),
        .timed_out => try writer.writeAll("{\"kind\":\"timed_out\",\"value\":null}"),
        .output_capture_failed => try writer.writeAll("{\"kind\":\"output_capture_failed\",\"value\":null}"),
    }
}

fn writeCommittedFilePresentation(
    writer: *std.Io.Writer,
    presentation: types.CommittedFilePresentation,
) !void {
    try writer.writeAll("{\"path\":");
    try writeDurableBytes(writer, presentation.path);
    try writer.writeAll(",\"kind\":");
    try writeJsonString(writer, @tagName(presentation.kind));
    try writer.writeAll(",\"lines\":[");
    for (presentation.lines, 0..) |line, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"kind\":");
        try writeJsonString(writer, @tagName(line.kind));
        try writer.writeAll(",\"old_line\":");
        try writeOptionalU32(writer, line.old_line);
        try writer.writeAll(",\"new_line\":");
        try writeOptionalU32(writer, line.new_line);
        try writer.writeAll(",\"text\":");
        try writeDurableBytes(writer, line.text);
        try writer.writeByte('}');
    }
    try writer.print(
        "],\"additions\":{d},\"deletions\":{d},\"truncated\":{s},\"previous_content\":",
        .{
            presentation.additions,
            presentation.deletions,
            if (presentation.truncated) "true" else "false",
        },
    );
    try writeOptionalDurableBytes(writer, presentation.previous_content);
    try writer.writeAll(",\"after_content\":");
    try writeOptionalDurableBytes(writer, presentation.after_content);
    try writer.writeAll(",\"lifecycle_id\":");
    if (presentation.lifecycle_id) |lifecycle_id| {
        try writer.print("{{\"turn_id\":{d},\"call_id\":", .{lifecycle_id.turn_id});
        try writeDurableBytes(writer, lifecycle_id.call_id);
        try writer.writeByte('}');
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

fn writeFileEvidence(writer: *std.Io.Writer, file: session.FileEvidence) !void {
    try writer.writeAll("{\"path\":");
    try writeDurableBytes(writer, file.path);
    try writer.writeAll(",\"new_path\":");
    try writeOptionalDurableBytes(writer, file.new_path);
    try writer.writeAll(",\"tool_call_id\":");
    try writeDurableBytes(writer, file.tool_call_id);
    try writer.writeAll(",\"tool_name\":");
    try writeDurableBytes(writer, file.tool_name);
    try writer.writeAll(",\"action\":");
    try writeJsonString(writer, @tagName(file.action));
    try writer.writeAll(",\"status\":");
    try writeJsonString(writer, @tagName(file.status));
    try writer.print(",\"model_view_covers_full_file\":{s},\"stale\":{s}", .{
        if (file.model_view_covers_full_file) "true" else "false",
        if (file.stale) "true" else "false",
    });
    try writer.writeByte('}');
}

fn parseUserTurn(alloc: Allocator, value: std.json.Value) !session.UserTurn {
    const source = try requireObject(value);
    const has_proven_root = source.get("proven_root") != null;
    const has_work_id = source.get("work_id") != null;
    const object = if (has_proven_root and has_work_id)
        try exactObject(value, &.{ "text", "images", "proven_root", "work_id" })
    else if (has_proven_root)
        try exactObject(value, &.{ "text", "images", "proven_root" })
    else if (has_work_id)
        try exactObject(value, &.{ "text", "images", "work_id" })
    else
        try exactObject(value, &.{ "text", "images" });
    const text = try parseRequiredDurableBytes(alloc, object, "text");
    errdefer alloc.free(text);
    const proven_root = if (object.get("proven_root")) |field| switch (field) {
        .bool => |flag| flag,
        else => return error.InvalidSessionFormat,
    } else true;
    const work_id = if (object.get("work_id")) |_|
        try alloc.dupe(u8, try requireString(object, "work_id"))
    else
        null;
    errdefer if (work_id) |id| alloc.free(id);
    if (work_id) |id| session.validateWorkId(id) catch return error.InvalidSessionFormat;
    const images_value = object.get("images") orelse return error.InvalidSessionFormat;
    if (images_value != .array) return error.InvalidSessionFormat;
    if (images_value.array.items.len == 0) return .{
        .text = text,
        .proven_root = proven_root,
        .work_id = work_id,
    };

    const images = try alloc.alloc(session.ImageAttachment, images_value.array.items.len);
    errdefer alloc.free(images);
    var parsed_count: usize = 0;
    errdefer {
        for (images[0..parsed_count]) |image| {
            types.freeImageAttachment(alloc, image);
        }
    }
    for (images_value.array.items, 0..) |image_value, i| {
        const image = try imageAttachmentObject(image_value);
        const path = try parseRequiredDurableBytes(alloc, image, "path");
        errdefer alloc.free(path);
        const media_type = try parseRequiredDurableBytes(alloc, image, "media_type");
        errdefer alloc.free(media_type);
        const snapshot_path = try parseOptionalDurableBytes(
            alloc,
            image.get("snapshot_path") orelse .null,
        );
        errdefer if (snapshot_path) |path_bytes| alloc.free(path_bytes);
        const snapshot_sha256 = try parseOptionalDurableBytes(
            alloc,
            image.get("snapshot_sha256") orelse .null,
        );
        errdefer if (snapshot_sha256) |sha256_bytes| alloc.free(sha256_bytes);
        if ((snapshot_path == null) != (snapshot_sha256 == null)) return error.InvalidSessionFormat;
        images[i] = .{
            .id = try requireUsize(image, "id"),
            .path = path,
            .media_type = media_type,
            .snapshot_path = snapshot_path,
            .snapshot_sha256 = snapshot_sha256,
        };
        parsed_count += 1;
    }
    return .{
        .text = text,
        .images = images,
        .proven_root = proven_root,
        .work_id = work_id,
    };
}

fn imageAttachmentObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidSessionFormat;
    var has_id = false;
    var has_path = false;
    var has_media_type = false;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "id")) {
            has_id = true;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "path")) {
            has_path = true;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "media_type")) {
            has_media_type = true;
        } else if (std.mem.eql(u8, entry.key_ptr.*, "snapshot_path") or
            std.mem.eql(u8, entry.key_ptr.*, "snapshot_sha256"))
        {
            continue;
        } else {
            return error.InvalidSessionFormat;
        }
    }
    if (!has_id or !has_path or !has_media_type) return error.InvalidSessionFormat;
    return value.object;
}

fn parseExecutionMemory(alloc: Allocator, value: std.json.Value) !session.ExecutionMemory {
    const raw_object = try requireObject(value);
    const has_user_inputs = raw_object.get("user_inputs") != null;
    const has_turn_summary = raw_object.get("turn_summary") != null;
    const object = if (has_user_inputs and has_turn_summary)
        try exactObject(value, &.{ "schema_version", "tool_steps", "files", "user_inputs", "turn_summary" })
    else if (has_user_inputs)
        try exactObject(value, &.{ "schema_version", "tool_steps", "files", "user_inputs" })
    else if (has_turn_summary)
        try exactObject(value, &.{ "schema_version", "tool_steps", "files", "turn_summary" })
    else
        try exactObject(value, &.{ "schema_version", "tool_steps", "files" });
    const schema_version = try requireU64(object, "schema_version");
    if (schema_version != 1 and schema_version != 2 and schema_version != 3 and
        schema_version != 4 and schema_version != 5 and schema_version != 6 and
        schema_version != 7)
    {
        return error.InvalidSessionFormat;
    }
    const tool_steps = try parseToolSteps(
        alloc,
        object.get("tool_steps") orelse return error.InvalidSessionFormat,
        schema_version,
    );
    errdefer session.freeExecutionMemory(alloc, .{ .tool_steps = tool_steps });
    const files = try parseFiles(alloc, object.get("files") orelse return error.InvalidSessionFormat);
    errdefer types.freeFileEvidenceSlice(alloc, files);
    const user_inputs: []session.UserTurn = if (has_user_inputs)
        try parseUserTurnArray(alloc, object.get("user_inputs") orelse return error.InvalidSessionFormat)
    else
        @constCast(&.{});
    errdefer types.freeUserTurnSlice(alloc, user_inputs);
    const turn_summary = if (has_turn_summary)
        try parseOptionalTurnSummary(object.get("turn_summary").?)
    else
        null;
    var execution: session.ExecutionMemory = .{
        .tool_steps = tool_steps,
        .files = files,
        .user_inputs = user_inputs,
        .turn_summary = turn_summary,
    };
    execution_retention.boundFilePresentationBodies(
        alloc,
        &execution,
        execution_retention.durable_file_body_policy,
    );
    return execution;
}

fn parseOptionalTurnSummary(value: std.json.Value) !?types.TurnSummary {
    if (value == .null) return null;
    const object = try exactObject(value, &.{
        "started_at_ms",
        "completed_at_ms",
        "thinking_duration_ms",
        "turn_duration_ms",
        "token_progress",
    });
    const token_progress = try exactObject(
        object.get("token_progress") orelse return error.InvalidSessionFormat,
        &.{ "input_tokens", "output_tokens", "input_exact", "output_exact" },
    );
    const summary = types.TurnSummary{
        .started_at_ms = try requireI64(object, "started_at_ms"),
        .completed_at_ms = try requireI64(object, "completed_at_ms"),
        .thinking_duration_ms = try requireU64(object, "thinking_duration_ms"),
        .turn_duration_ms = try requireU64(object, "turn_duration_ms"),
        .token_progress = .{
            .input_tokens = try requireU64(token_progress, "input_tokens"),
            .output_tokens = try requireU64(token_progress, "output_tokens"),
            .input_exact = try requireBool(token_progress, "input_exact"),
            .output_exact = try requireBool(token_progress, "output_exact"),
        },
    };
    if (summary.started_at_ms < 0 or
        summary.completed_at_ms < summary.started_at_ms)
    {
        return error.InvalidSessionFormat;
    }
    return summary;
}

fn parseUserTurnArray(alloc: Allocator, value: std.json.Value) ![]session.UserTurn {
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const users = try alloc.alloc(session.UserTurn, value.array.items.len);
    var parsed_count: usize = 0;
    errdefer {
        for (users[0..parsed_count]) |user| session.freeUserTurn(alloc, user);
        alloc.free(users);
    }
    for (value.array.items, 0..) |item, i| {
        users[i] = try parseUserTurn(alloc, item);
        parsed_count += 1;
    }
    return users;
}

test "execution memory round-trips active-turn user inputs" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var user_inputs = [_]session.UserTurn{.{ .text = @constCast("continue the original request") }};
    const input = session.ExecutionMemory{
        .user_inputs = user_inputs[0..],
    };
    try writeExecutionMemory(&out.writer, input);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer parsed.deinit();
    const decoded = try parseExecutionMemory(alloc, parsed.value);
    defer session.freeExecutionMemory(alloc, decoded);
    try std.testing.expectEqual(@as(usize, 1), decoded.user_inputs.len);
    try std.testing.expectEqualStrings("continue the original request", decoded.user_inputs[0].text);
}

fn parseToolSteps(
    alloc: Allocator,
    value: std.json.Value,
    schema_version: u64,
) ![]session.ToolExecutionStep {
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const steps = try alloc.alloc(session.ToolExecutionStep, value.array.items.len);
    errdefer alloc.free(steps);
    var parsed_count: usize = 0;
    errdefer for (steps[0..parsed_count]) |step| {
        if (step.assistant) |assistant| alloc.free(assistant);
        if (step.reasoning) |reasoning| alloc.free(reasoning);
        if (step.reasoning_item_id) |item_id| alloc.free(item_id);
        if (step.reasoning_encrypted_content) |content| alloc.free(content);
        types.freeResponsesReasoningItems(alloc, step.reasoning_items);
        types.freeResponsesProviderOutputItems(alloc, step.responses_provider_output_items);
        session.freeToolCallSlice(alloc, step.tool_calls);
        session.freePersistedToolResults(alloc, step.tool_results);
    };
    for (value.array.items, 0..) |step_value, i| {
        const object = if (schema_version >= 6)
            try exactObject(step_value, &.{
                "assistant",
                "reasoning",
                "reasoning_item_id",
                "reasoning_encrypted_content",
                "reasoning_items",
                "responses_message_output_index",
                "responses_provider_output_items",
                "responses_output_sequence_complete",
                "tool_calls",
                "tool_results",
            })
        else if (schema_version >= 5)
            try exactObject(step_value, &.{
                "assistant",
                "reasoning",
                "reasoning_item_id",
                "reasoning_encrypted_content",
                "reasoning_items",
                "tool_calls",
                "tool_results",
            })
        else if (schema_version >= 4)
            try exactObject(step_value, &.{
                "assistant",
                "reasoning",
                "reasoning_item_id",
                "reasoning_encrypted_content",
                "tool_calls",
                "tool_results",
            })
        else
            try exactObject(step_value, &.{ "assistant", "tool_calls", "tool_results" });
        const assistant = try parseOptionalDurableBytes(alloc, object.get("assistant") orelse return error.InvalidSessionFormat);
        errdefer if (assistant) |owned| alloc.free(owned);
        const reasoning = if (schema_version >= 4)
            try parseOptionalDurableBytes(alloc, object.get("reasoning") orelse return error.InvalidSessionFormat)
        else
            null;
        errdefer if (reasoning) |owned| alloc.free(owned);
        const reasoning_item_id = if (schema_version >= 4)
            try parseOptionalDurableBytes(alloc, object.get("reasoning_item_id") orelse return error.InvalidSessionFormat)
        else
            null;
        errdefer if (reasoning_item_id) |owned| alloc.free(owned);
        const reasoning_encrypted_content = if (schema_version >= 4)
            try parseOptionalDurableBytes(alloc, object.get("reasoning_encrypted_content") orelse return error.InvalidSessionFormat)
        else
            null;
        errdefer if (reasoning_encrypted_content) |owned| alloc.free(owned);
        const reasoning_items: []types.ResponsesReasoningItem = if (schema_version >= 5)
            try parseResponsesReasoningItems(
                alloc,
                object.get("reasoning_items") orelse return error.InvalidSessionFormat,
            )
        else
            &.{};
        errdefer types.freeResponsesReasoningItems(alloc, reasoning_items);
        const provider_output_items: []types.ResponsesProviderOutputItem = if (schema_version >= 6)
            try parseResponsesProviderOutputItems(
                alloc,
                object.get("responses_provider_output_items") orelse
                    return error.InvalidSessionFormat,
            )
        else
            &.{};
        errdefer types.freeResponsesProviderOutputItems(alloc, provider_output_items);
        const message_output_index: ?u32 = if (schema_version >= 6)
            try parseOptionalU32(object.get("responses_message_output_index") orelse
                return error.InvalidSessionFormat)
        else
            null;
        const output_sequence_complete = if (schema_version >= 6)
            try requireBool(object, "responses_output_sequence_complete")
        else
            false;
        if (output_sequence_complete) {
            responses_output_items.validateComplete(alloc, provider_output_items) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidSessionFormat,
            };
        }
        const tool_calls = try parseToolCalls(alloc, object.get("tool_calls") orelse return error.InvalidSessionFormat);
        errdefer session.freeToolCallSlice(alloc, tool_calls);
        const tool_results = try parseToolResults(
            alloc,
            object.get("tool_results") orelse return error.InvalidSessionFormat,
            schema_version,
        );
        errdefer session.freePersistedToolResults(alloc, tool_results);
        try session.repairPersistedToolArguments(alloc, tool_calls, tool_results, .schema_v3);
        steps[i] = .{
            .assistant = assistant,
            .responses_message_output_index = message_output_index,
            .reasoning = reasoning,
            .reasoning_item_id = reasoning_item_id,
            .reasoning_encrypted_content = reasoning_encrypted_content,
            .reasoning_items = reasoning_items,
            .responses_provider_output_items = provider_output_items,
            .responses_output_sequence_complete = output_sequence_complete,
            .tool_calls = tool_calls,
            .tool_results = tool_results,
        };
        parsed_count += 1;
    }
    return steps;
}

fn parseToolCalls(alloc: Allocator, value: std.json.Value) ![]session.ToolCall {
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const calls = try alloc.alloc(session.ToolCall, value.array.items.len);
    errdefer alloc.free(calls);
    var parsed_count: usize = 0;
    errdefer for (calls[0..parsed_count]) |call| session.freeToolCall(alloc, call);
    for (value.array.items, 0..) |call_value, i| {
        calls[i] = try parseToolCall(alloc, call_value);
        parsed_count += 1;
    }
    return calls;
}

fn parseToolCall(alloc: Allocator, value: std.json.Value) !session.ToolCall {
    const raw_object = try requireObject(value);
    const has_item_id = raw_object.get("responses_item_id") != null;
    const has_output_index = raw_object.get("responses_output_index") != null;
    const object = if (has_item_id and has_output_index)
        try exactObject(value, &.{
            "id",
            "name",
            "arguments_json",
            "provider_result",
            "responses_item_id",
            "responses_output_index",
        })
    else if (has_item_id)
        try exactObject(value, &.{
            "id",
            "name",
            "arguments_json",
            "provider_result",
            "responses_item_id",
        })
    else if (has_output_index)
        try exactObject(value, &.{
            "id",
            "name",
            "arguments_json",
            "provider_result",
            "responses_output_index",
        })
    else
        try exactObject(value, &.{
            "id",
            "name",
            "arguments_json",
            "provider_result",
        });
    const id = try parseRequiredDurableBytes(alloc, object, "id");
    errdefer alloc.free(id);
    const name = try parseRequiredDurableBytes(alloc, object, "name");
    errdefer alloc.free(name);
    var arguments_json = try parseRequiredDurableBytes(alloc, object, "arguments_json");
    errdefer alloc.free(arguments_json);
    const argument_integrity = try types.ToolArgumentIntegrity.classifySerialized(alloc, arguments_json);
    if (argument_integrity == .malformed_json) {
        const safe_arguments = try alloc.dupe(u8, "{}");
        alloc.free(arguments_json);
        arguments_json = safe_arguments;
    }
    const provider_result = try parseOptionalDurableBytes(
        alloc,
        object.get("provider_result") orelse return error.InvalidSessionFormat,
    );
    errdefer if (provider_result) |owned| alloc.free(owned);
    const responses_item_id = if (has_item_id)
        try parseOptionalDurableBytes(
            alloc,
            object.get("responses_item_id") orelse return error.InvalidSessionFormat,
        )
    else
        null;
    errdefer if (responses_item_id) |owned| alloc.free(owned);
    return .{
        .id = id,
        .name = name,
        .arguments_json = arguments_json,
        .argument_integrity = argument_integrity,
        .provider_result = provider_result,
        .responses_item_id = responses_item_id,
        .responses_output_index = if (has_output_index) blk: {
            const output_index = try requireU64(object, "responses_output_index");
            if (output_index > std.math.maxInt(u32)) return error.InvalidSessionFormat;
            break :blk @intCast(output_index);
        } else null,
    };
}

fn parseOptionalToolCall(alloc: Allocator, value: std.json.Value) !?session.ToolCall {
    return switch (value) {
        .null => null,
        .object => blk: {
            var call = try parseToolCall(alloc, value);
            session.repairPersistedInterruptedToolArguments(&call, .schema_v3);
            break :blk call;
        },
        else => error.InvalidSessionFormat,
    };
}

fn parseToolResults(
    alloc: Allocator,
    value: std.json.Value,
    schema_version: u64,
) ![]session.PersistedToolResult {
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const results = try alloc.alloc(session.PersistedToolResult, value.array.items.len);
    errdefer alloc.free(results);
    var parsed_count: usize = 0;
    errdefer for (results[0..parsed_count]) |result| {
        alloc.free(result.tool_call_id);
        alloc.free(result.tool_name);
        alloc.free(result.output);
        if (result.output_handle) |handle| alloc.free(handle);
        if (result.preview) |preview| alloc.free(preview);
        types.freePermissionFeedback(alloc, result.permission_feedback);
        if (result.committed_file_presentation) |presentation| {
            types.freeCommittedFilePresentation(alloc, presentation);
        }
        if (result.command_output_replay) |replay| {
            types.freeCommandOutputReplay(alloc, replay);
        }
    };
    for (value.array.items, 0..) |result_value, i| {
        results[i] = try parseToolResult(alloc, result_value, schema_version);
        parsed_count += 1;
    }
    return results;
}

fn parseToolResult(
    alloc: Allocator,
    value: std.json.Value,
    schema_version: u64,
) !session.PersistedToolResult {
    const v1_keys = &.{
        "tool_call_id",
        "tool_name",
        "status",
        "output",
        "output_handle",
        "preview",
        "output_bytes",
        "stored_output_bytes",
        "truncated",
        "provider_native",
        "created_at_ms",
    };
    const v2_keys = &.{
        "tool_call_id",
        "tool_name",
        "status",
        "output",
        "output_handle",
        "preview",
        "output_bytes",
        "stored_output_bytes",
        "truncated",
        "provider_native",
        "created_at_ms",
        "permission_feedback",
    };
    const v2_extended_keys = &.{
        "tool_call_id",
        "tool_name",
        "status",
        "output",
        "output_handle",
        "preview",
        "output_bytes",
        "stored_output_bytes",
        "truncated",
        "provider_native",
        "created_at_ms",
        "permission_feedback",
        "committed_file_presentation",
    };
    const v3_keys = &.{
        "tool_call_id",
        "tool_name",
        "status",
        "output",
        "output_handle",
        "preview",
        "output_bytes",
        "stored_output_bytes",
        "truncated",
        "provider_native",
        "created_at_ms",
        "permission_feedback",
        "committed_file_presentation",
        "command_output_replay",
        "command_process_presentation",
    };
    const v4_keys = &.{
        "tool_call_id",
        "tool_name",
        "status",
        "output",
        "output_handle",
        "preview",
        "output_bytes",
        "stored_output_bytes",
        "truncated",
        "provider_native",
        "created_at_ms",
        "permission_feedback",
        "committed_file_presentation",
        "command_output_replay",
        "command_process_presentation",
    };
    const v4_artifact_keys = &.{
        "tool_call_id",
        "tool_name",
        "status",
        "output",
        "output_handle",
        "preview",
        "output_bytes",
        "stored_output_bytes",
        "truncated",
        "provider_native",
        "created_at_ms",
        "permission_feedback",
        "committed_file_presentation",
        "command_output_replay",
        "command_artifact_handle",
        "command_process_presentation",
    };
    const result_shape: ExactVariantObject = switch (schema_version) {
        1 => .{ .object = try exactObject(value, v1_keys), .extended = false },
        2 => try exactVariantObject(value, v2_keys, v2_extended_keys),
        3 => .{ .object = try exactObject(value, v3_keys), .extended = true },
        4, 5, 6 => try exactVariantObject(value, v3_keys, v4_keys),
        7 => blk: {
            const shape = try exactVariantObject(value, v4_keys, v4_artifact_keys);
            break :blk .{ .object = shape.object, .extended = true };
        },
        else => return error.InvalidSessionFormat,
    };
    const object = result_shape.object;
    const tool_call_id = try parseRequiredDurableBytes(alloc, object, "tool_call_id");
    errdefer alloc.free(tool_call_id);
    const tool_name = try parseRequiredDurableBytes(alloc, object, "tool_name");
    errdefer alloc.free(tool_name);
    const output = try parseRequiredDurableBytes(alloc, object, "output");
    errdefer alloc.free(output);
    const output_handle = try parseOptionalDurableBytes(
        alloc,
        object.get("output_handle") orelse return error.InvalidSessionFormat,
    );
    errdefer if (output_handle) |owned| alloc.free(owned);
    const preview = try parseOptionalDurableBytes(
        alloc,
        object.get("preview") orelse return error.InvalidSessionFormat,
    );
    errdefer if (preview) |owned| alloc.free(owned);
    const permission_feedback: [][]u8 = if (schema_version == 1)
        &.{}
    else
        try parseDurableBytesArray(
            alloc,
            object.get("permission_feedback") orelse return error.InvalidSessionFormat,
        );
    errdefer types.freePermissionFeedback(alloc, permission_feedback);
    const committed_file_presentation = if (result_shape.extended)
        try parseOptionalCommittedFilePresentation(
            alloc,
            object.get("committed_file_presentation") orelse return error.InvalidSessionFormat,
        )
    else
        null;
    errdefer if (committed_file_presentation) |presentation| {
        types.freeCommittedFilePresentation(alloc, presentation);
    };
    const command_output_replay = if (schema_version >= 3)
        try parseOptionalCommandOutputReplay(
            alloc,
            object.get("command_output_replay") orelse return error.InvalidSessionFormat,
        )
    else
        null;
    errdefer if (command_output_replay) |replay| {
        types.freeCommandOutputReplay(alloc, replay);
    };
    const command_artifact_handle = if (schema_version >= 7)
        try parseOptionalDurableBytes(
            alloc,
            object.get("command_artifact_handle") orelse .null,
        )
    else
        null;
    errdefer if (command_artifact_handle) |handle| alloc.free(handle);
    const command_process_presentation = if (schema_version >= 3)
        try parseOptionalCommandProcessPresentation(
            object.get("command_process_presentation") orelse return error.InvalidSessionFormat,
        )
    else
        null;
    return .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .status = std.meta.stringToEnum(
            session.PersistedToolStatus,
            try requireString(object, "status"),
        ) orelse return error.InvalidSessionFormat,
        .output = output,
        .output_handle = output_handle,
        .preview = preview,
        .output_bytes = try requireUsize(object, "output_bytes"),
        .stored_output_bytes = try requireUsize(object, "stored_output_bytes"),
        .truncated = try requireBool(object, "truncated"),
        .provider_native = try requireBool(object, "provider_native"),
        .created_at_ms = try requireI64(object, "created_at_ms"),
        .permission_feedback = permission_feedback,
        .committed_file_presentation = committed_file_presentation,
        .command_output_replay = command_output_replay,
        .command_artifact_handle = command_artifact_handle,
        .command_process_presentation = command_process_presentation,
    };
}

fn parseOptionalCommandOutputReplay(
    alloc: Allocator,
    value: std.json.Value,
) !?types.CommandOutputReplay {
    if (value == .null) return null;
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidSessionFormat,
    };
    const kind = try requireString(object, "kind");
    if (std.mem.eql(u8, kind, "unavailable")) {
        _ = try exactObject(value, &.{"kind"});
        return .unavailable;
    }
    if (!std.mem.eql(u8, kind, "available")) return error.InvalidSessionFormat;
    const exact = try exactObject(value, &.{ "kind", "handle", "framed_bytes" });
    const handle = try parseRequiredDurableBytes(alloc, exact, "handle");
    errdefer alloc.free(handle);
    return .{ .available = .{
        .handle = handle,
        .framed_bytes = try requireUsize(exact, "framed_bytes"),
    } };
}

fn parseOptionalCommandProcessPresentation(
    value: std.json.Value,
) !?types.CommandProcessPresentation {
    if (value == .null) return null;
    const object = try exactObject(value, &.{ "kind", "value" });
    const kind = try requireString(object, "kind");
    if (std.mem.eql(u8, kind, "exit_code")) {
        return .{ .exit_code = try requireI64(object, "value") };
    }
    if (std.mem.eql(u8, kind, "signal")) {
        const signal = try requireU64(object, "value");
        return .{ .signal = std.math.cast(u32, signal) orelse
            return error.InvalidSessionFormat };
    }
    if (std.mem.eql(u8, kind, "timed_out")) {
        if (object.get("value").? != .null) return error.InvalidSessionFormat;
        return .timed_out;
    }
    if (std.mem.eql(u8, kind, "output_capture_failed")) {
        if (object.get("value").? != .null) return error.InvalidSessionFormat;
        return .output_capture_failed;
    }
    return error.InvalidSessionFormat;
}

fn parseOptionalCommittedFilePresentation(
    alloc: Allocator,
    value: std.json.Value,
) !?types.CommittedFilePresentation {
    return switch (value) {
        .null => null,
        .object => try parseCommittedFilePresentation(alloc, value),
        else => error.InvalidSessionFormat,
    };
}

fn parseCommittedFilePresentation(
    alloc: Allocator,
    value: std.json.Value,
) !types.CommittedFilePresentation {
    const object = try exactObject(value, &.{
        "path",
        "kind",
        "lines",
        "additions",
        "deletions",
        "truncated",
        "previous_content",
        "after_content",
        "lifecycle_id",
    });
    const path = try parseRequiredDurableBytes(alloc, object, "path");
    errdefer alloc.free(path);
    const lines = try parseCommittedFilePresentationLines(
        alloc,
        object.get("lines") orelse return error.InvalidSessionFormat,
    );
    errdefer freeCommittedFilePresentationLines(alloc, lines);
    const previous_content = try parseOptionalDurableBytes(
        alloc,
        object.get("previous_content") orelse return error.InvalidSessionFormat,
    );
    errdefer if (previous_content) |content| alloc.free(content);
    const after_content = try parseOptionalDurableBytes(
        alloc,
        object.get("after_content") orelse return error.InvalidSessionFormat,
    );
    errdefer if (after_content) |content| alloc.free(content);
    const lifecycle_id = try parseOptionalToolLifecycleId(
        alloc,
        object.get("lifecycle_id") orelse return error.InvalidSessionFormat,
    );
    errdefer if (lifecycle_id) |id| alloc.free(id.call_id);
    return .{
        .path = path,
        .kind = std.meta.stringToEnum(
            types.CommittedFilePresentationKind,
            try requireString(object, "kind"),
        ) orelse return error.InvalidSessionFormat,
        .lines = lines,
        .additions = try requireUsize(object, "additions"),
        .deletions = try requireUsize(object, "deletions"),
        .truncated = try requireBool(object, "truncated"),
        .previous_content = previous_content,
        .after_content = after_content,
        .lifecycle_id = lifecycle_id,
    };
}

fn parseCommittedFilePresentationLines(
    alloc: Allocator,
    value: std.json.Value,
) ![]types.CommittedFilePresentationLine {
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const lines = try alloc.alloc(types.CommittedFilePresentationLine, value.array.items.len);
    var parsed_count: usize = 0;
    errdefer {
        for (lines[0..parsed_count]) |line| alloc.free(@constCast(line.text));
        alloc.free(lines);
    }
    for (value.array.items, 0..) |line_value, index| {
        const object = try exactObject(line_value, &.{ "kind", "old_line", "new_line", "text" });
        const text = try parseRequiredDurableBytes(alloc, object, "text");
        errdefer alloc.free(text);
        lines[index] = .{
            .kind = std.meta.stringToEnum(
                types.CommittedFilePresentationLineKind,
                try requireString(object, "kind"),
            ) orelse return error.InvalidSessionFormat,
            .old_line = try parseOptionalU32(object.get("old_line") orelse return error.InvalidSessionFormat),
            .new_line = try parseOptionalU32(object.get("new_line") orelse return error.InvalidSessionFormat),
            .text = text,
        };
        parsed_count += 1;
    }
    return lines;
}

fn freeCommittedFilePresentationLines(
    alloc: Allocator,
    lines: []const types.CommittedFilePresentationLine,
) void {
    for (lines) |line| alloc.free(@constCast(line.text));
    if (lines.len > 0) alloc.free(@constCast(lines));
}

fn parseOptionalToolLifecycleId(
    alloc: Allocator,
    value: std.json.Value,
) !?types.ToolLifecycleId {
    return switch (value) {
        .null => null,
        .object => {
            const object = try exactObject(value, &.{ "turn_id", "call_id" });
            const call_id = try parseRequiredDurableBytes(alloc, object, "call_id");
            errdefer alloc.free(call_id);
            return .{
                .turn_id = try requireU64(object, "turn_id"),
                .call_id = call_id,
            };
        },
        else => error.InvalidSessionFormat,
    };
}

fn parseFiles(alloc: Allocator, value: std.json.Value) ![]session.FileEvidence {
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const files = try alloc.alloc(session.FileEvidence, value.array.items.len);
    errdefer alloc.free(files);
    var parsed_count: usize = 0;
    errdefer for (files[0..parsed_count]) |file| {
        alloc.free(file.path);
        if (file.new_path) |new_path| alloc.free(new_path);
        alloc.free(file.tool_call_id);
        alloc.free(file.tool_name);
    };
    for (value.array.items, 0..) |file_value, i| {
        files[i] = try parseFile(alloc, file_value);
        parsed_count += 1;
    }
    return files;
}

fn parseFile(alloc: Allocator, value: std.json.Value) !session.FileEvidence {
    const object = try exactObject(value, &.{
        "path",
        "new_path",
        "tool_call_id",
        "tool_name",
        "action",
        "status",
        "model_view_covers_full_file",
        "stale",
    });
    const path = try parseRequiredDurableBytes(alloc, object, "path");
    errdefer alloc.free(path);
    const new_path = try parseOptionalDurableBytes(
        alloc,
        object.get("new_path") orelse return error.InvalidSessionFormat,
    );
    errdefer if (new_path) |owned| alloc.free(owned);
    const tool_call_id = try parseRequiredDurableBytes(alloc, object, "tool_call_id");
    errdefer alloc.free(tool_call_id);
    const tool_name = try parseRequiredDurableBytes(alloc, object, "tool_name");
    errdefer alloc.free(tool_name);
    return .{
        .path = path,
        .new_path = new_path,
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .action = std.meta.stringToEnum(
            session.FileEvidenceAction,
            try requireString(object, "action"),
        ) orelse return error.InvalidSessionFormat,
        .status = std.meta.stringToEnum(
            session.PersistedToolStatus,
            try requireString(object, "status"),
        ) orelse return error.InvalidSessionFormat,
        .model_view_covers_full_file = try requireBool(object, "model_view_covers_full_file"),
        .stale = try requireBool(object, "stale"),
    };
}

fn parseDurableBytesArray(alloc: Allocator, value: std.json.Value) ![][]u8 {
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const items = try alloc.alloc([]u8, value.array.items.len);
    errdefer alloc.free(items);
    var parsed_count: usize = 0;
    errdefer for (items[0..parsed_count]) |item| alloc.free(item);
    for (value.array.items, 0..) |item, i| {
        items[i] = try parseDurableBytes(alloc, item);
        parsed_count += 1;
    }
    return items;
}

noinline fn parseRequiredDurableBytes(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    return parseDurableBytes(alloc, object.get(key) orelse return error.InvalidSessionFormat);
}

noinline fn parseOptionalDurableBytes(alloc: Allocator, value: std.json.Value) !?[]u8 {
    return switch (value) {
        .null => null,
        .string, .object => try parseDurableBytes(alloc, value),
        else => error.InvalidSessionFormat,
    };
}

fn parseResponsesReasoningItems(
    alloc: Allocator,
    value: std.json.Value,
) ![]types.ResponsesReasoningItem {
    if (value != .array) return error.InvalidSessionFormat;
    if (value.array.items.len == 0) return &.{};
    const items = try alloc.alloc(types.ResponsesReasoningItem, value.array.items.len);
    errdefer alloc.free(items);
    var parsed_count: usize = 0;
    errdefer {
        for (items[0..parsed_count]) |item| {
            if (item.id) |owned| alloc.free(@constCast(owned));
            if (item.summary) |owned| alloc.free(@constCast(owned));
            if (item.encrypted_content) |owned| alloc.free(@constCast(owned));
        }
    }
    for (value.array.items, 0..) |item_value, i| {
        const raw_object = try requireObject(item_value);
        const has_output_index = raw_object.get("output_index") != null;
        const object = if (has_output_index)
            try exactObject(item_value, &.{ "output_index", "id", "summary", "encrypted_content" })
        else
            try exactObject(item_value, &.{ "id", "summary", "encrypted_content" });
        const output_index = if (has_output_index)
            try parseOptionalU32(object.get("output_index") orelse return error.InvalidSessionFormat)
        else
            null;
        const id = try parseOptionalDurableBytes(alloc, object.get("id") orelse return error.InvalidSessionFormat);
        errdefer if (id) |owned| alloc.free(owned);
        const summary = try parseOptionalDurableBytes(alloc, object.get("summary") orelse return error.InvalidSessionFormat);
        errdefer if (summary) |owned| alloc.free(owned);
        const encrypted_content = try parseOptionalDurableBytes(
            alloc,
            object.get("encrypted_content") orelse return error.InvalidSessionFormat,
        );
        errdefer if (encrypted_content) |owned| alloc.free(owned);
        items[i] = .{
            .output_index = output_index,
            .id = id,
            .summary = summary,
            .encrypted_content = encrypted_content,
        };
        parsed_count += 1;
    }
    return items;
}

fn parseResponsesProviderOutputItems(
    alloc: Allocator,
    value: std.json.Value,
) ![]types.ResponsesProviderOutputItem {
    if (value != .array or value.array.items.len > responses_output_items.max_items) {
        return error.InvalidSessionFormat;
    }
    if (value.array.items.len == 0) return &.{};

    var items: std.ArrayList(types.ResponsesProviderOutputItem) = .empty;
    errdefer {
        for (items.items) |item| alloc.free(@constCast(item.json));
        items.deinit(alloc);
    }
    var total_bytes: usize = 0;
    for (value.array.items) |item_value| {
        const object = try exactObject(item_value, &.{ "output_index", "json" });
        const output_index = try requireU64(object, "output_index");
        if (output_index > std.math.maxInt(u32)) return error.InvalidSessionFormat;
        const json = parseDurableBytes(
            alloc,
            object.get("json") orelse return error.InvalidSessionFormat,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSessionFormat,
        };
        errdefer alloc.free(json);
        if (json.len == 0 or json.len > responses_output_items.max_item_bytes) {
            return error.InvalidSessionFormat;
        }
        total_bytes = std.math.add(usize, total_bytes, json.len) catch
            return error.InvalidSessionFormat;
        if (total_bytes > responses_output_items.max_total_bytes) {
            return error.InvalidSessionFormat;
        }
        try items.append(alloc, .{
            .output_index = @intCast(output_index),
            .json = json,
        });
    }
    const owned = try items.toOwnedSlice(alloc);
    errdefer types.freeResponsesProviderOutputItems(alloc, owned);
    responses_output_items.validate(alloc, owned) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSessionFormat,
    };
    return owned;
}

fn parseOptionalIdentifier(value: std.json.Value) !?types.StableBackgroundRecordId {
    return switch (value) {
        .null => null,
        .string => |hex| try parseHexIdentifier(hex),
        else => error.InvalidSessionFormat,
    };
}

fn parseHexIdentifier(hex: []const u8) !types.StableBackgroundRecordId {
    if (hex.len != 32) return error.InvalidSessionFormat;
    var result: types.StableBackgroundRecordId = undefined;
    _ = std.fmt.hexToBytes(&result, hex) catch return error.InvalidSessionFormat;
    const canonical = std.fmt.bytesToHex(result, .lower);
    if (!std.mem.eql(u8, &canonical, hex)) return error.InvalidSessionFormat;
    return result;
}

noinline fn writeOptionalDurableBytes(writer: *std.Io.Writer, value: anytype) !void {
    if (value) |bytes| {
        try writeDurableBytes(writer, bytes);
    } else {
        try writer.writeAll("null");
    }
}

fn writeResponsesReasoningItems(
    writer: *std.Io.Writer,
    items: []const types.ResponsesReasoningItem,
) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"output_index\":");
        try writeOptionalU32(writer, item.output_index);
        try writer.writeAll(",\"id\":");
        try writeOptionalDurableBytes(writer, item.id);
        try writer.writeAll(",\"summary\":");
        try writeOptionalDurableBytes(writer, item.summary);
        try writer.writeAll(",\"encrypted_content\":");
        try writeOptionalDurableBytes(writer, item.encrypted_content);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeResponsesProviderOutputItems(
    writer: *std.Io.Writer,
    items: []const types.ResponsesProviderOutputItem,
) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"output_index\":{d},\"json\":", .{item.output_index});
        try writeDurableBytes(writer, item.json);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeOptionalU32(writer: *std.Io.Writer, value: ?u32) !void {
    if (value) |number| {
        try writer.print("{d}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn writeHexString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');
    const alphabet = "0123456789abcdef";
    for (bytes) |byte| {
        try writer.writeByte(alphabet[byte >> 4]);
        try writer.writeByte(alphabet[byte & 0x0f]);
    }
    try writer.writeByte('"');
}

noinline fn writeJsonString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try std.json.Stringify.value(bytes, .{}, writer);
}

noinline fn validateSessionId(value: []const u8) !void {
    if (value.len == 0 or value.len > 255 or
        std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, ".."))
    {
        return error.InvalidDurableField;
    }
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return error.InvalidDurableField;
        }
    }
}

fn validateWorkspaceRoot(value: []const u8) !void {
    if (value.len == 0 or value.len > std.Io.Dir.max_path_bytes or
        !std.unicode.utf8ValidateSlice(value) or !std.Io.Dir.path.isAbsolute(value))
    {
        return error.InvalidDurableField;
    }
}

fn validateModel(value: []const u8) !void {
    if (value.len == 0 or value.len > 1024 or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidDurableField;
    }
    if (std.ascii.isWhitespace(value[0]) or std.ascii.isWhitespace(value[value.len - 1])) {
        return error.InvalidDurableField;
    }
    for (value) |byte| if (std.ascii.isControl(byte)) return error.InvalidDurableField;
}

fn validateConversationLanguage(language: session.ConversationLanguage) !void {
    try validateConversationLanguageBytes(language.view());
}

fn validateConversationLanguageBytes(value: []const u8) !void {
    if (value.len == 0 or value.len > session.ConversationLanguage.max_len or
        !std.unicode.utf8ValidateSlice(value) or
        !std.mem.eql(u8, value, std.mem.trim(u8, value, " \t\r\n")))
    {
        return error.InvalidDurableField;
    }
    for (value) |byte| if (std.ascii.isControl(byte)) return error.InvalidDurableField;
}

fn dupeHistory(alloc: Allocator, history: []const session.HistoryTurn) ![]session.HistoryTurn {
    if (history.len == 0) return &.{};
    const copy = try alloc.alloc(session.HistoryTurn, history.len);
    errdefer alloc.free(copy);
    var copied: usize = 0;
    errdefer for (copy[0..copied]) |turn| session.freeHistoryTurn(alloc, turn);
    for (history, 0..) |turn, i| {
        copy[i] = try session.dupeHistoryTurn(alloc, turn);
        copied += 1;
    }
    return copy;
}

fn expectKey(reader: *std.json.Reader, alloc: Allocator, expected: []const u8) !void {
    const token = try reader.nextAllocMax(alloc, .alloc_if_needed, 64);
    defer freeToken(alloc, token);
    const actual = switch (token) {
        .string => |value| value,
        .allocated_string => |value| value,
        else => return error.InvalidSessionFormat,
    };
    if (!std.mem.eql(u8, actual, expected)) return error.InvalidSessionFormat;
}

fn readStringOwned(reader: *std.json.Reader, alloc: Allocator, max_len: usize) ![]u8 {
    const token = try reader.nextAllocMax(alloc, .alloc_always, max_len);
    return switch (token) {
        .allocated_string => |value| value,
        .string => |value| try alloc.dupe(u8, value),
        else => {
            freeToken(alloc, token);
            return error.InvalidSessionFormat;
        },
    };
}

fn readI64(reader: *std.json.Reader, alloc: Allocator) !i64 {
    const token = try reader.nextAllocMax(alloc, .alloc_if_needed, 32);
    defer freeToken(alloc, token);
    const raw = switch (token) {
        .number => |value| value,
        .allocated_number => |value| value,
        else => return error.InvalidSessionFormat,
    };
    return std.fmt.parseInt(i64, raw, 10) catch error.InvalidSessionFormat;
}

fn readU64(reader: *std.json.Reader, alloc: Allocator) !u64 {
    const token = try reader.nextAllocMax(alloc, .alloc_if_needed, 32);
    defer freeToken(alloc, token);
    const raw = switch (token) {
        .number => |value| value,
        .allocated_number => |value| value,
        else => return error.InvalidSessionFormat,
    };
    return std.fmt.parseUnsigned(u64, raw, 10) catch error.InvalidSessionFormat;
}

fn readBool(reader: *std.json.Reader) !bool {
    return switch (try reader.next()) {
        .true => true,
        .false => false,
        else => error.InvalidSessionFormat,
    };
}

fn freeToken(alloc: Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number => |value| alloc.free(value),
        .allocated_string => |value| alloc.free(value),
        else => {},
    }
}

fn expectToken(actual: std.json.Token, comptime expected: std.meta.Tag(std.json.Token)) !void {
    if (std.meta.activeTag(actual) != expected) return error.InvalidSessionFormat;
}

noinline fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidSessionFormat;
    return value.object;
}

pub fn exactObject(value: std.json.Value, keys: []const []const u8) !std.json.ObjectMap {
    const object = try requireObject(value);
    if (object.count() != keys.len) return error.InvalidSessionFormat;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        for (keys) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                known = true;
                break;
            }
        }
        if (!known) return error.InvalidSessionFormat;
    }
    return object;
}

fn exactInterruptedHistoryObject(
    value: std.json.Value,
    has_execution: bool,
    has_presentation: bool,
    has_terminal_reason: bool,
) !std.json.ObjectMap {
    var keys: [8][]const u8 = undefined;
    keys[0] = "kind";
    keys[1] = "user";
    keys[2] = "assistant";
    keys[3] = "tool_call";
    keys[4] = "completed_tool_names";
    var len: usize = 5;
    if (has_execution) {
        keys[len] = "execution";
        len += 1;
    }
    if (has_presentation) {
        keys[len] = "cancelled_command";
        len += 1;
    }
    if (has_terminal_reason) {
        keys[len] = "terminal_reason";
        len += 1;
    }
    return exactObject(value, keys[0..len]);
}

fn parseInterruptedTerminalReason(
    object: std.json.ObjectMap,
    key: []const u8,
) !types.InterruptedTerminalReason {
    const raw = try requireString(object, key);
    if (std.mem.eql(u8, raw, "cancelled")) return .cancelled;
    if (std.mem.eql(u8, raw, "failed")) return .failed;
    return error.InvalidSessionFormat;
}

const ExactVariantObject = struct {
    object: std.json.ObjectMap,
    extended: bool,
};

fn exactVariantObject(
    value: std.json.Value,
    legacy_keys: []const []const u8,
    extended_keys: []const []const u8,
) !ExactVariantObject {
    const object = try requireObject(value);
    if (object.count() == legacy_keys.len) {
        return .{
            .object = try exactObject(value, legacy_keys),
            .extended = false,
        };
    }
    if (object.count() == extended_keys.len) {
        return .{
            .object = try exactObject(value, extended_keys),
            .extended = true,
        };
    }
    return error.InvalidSessionFormat;
}

pub fn requireString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    if (value != .string) return error.InvalidSessionFormat;
    return value.string;
}

fn requireBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    if (value != .bool) return error.InvalidSessionFormat;
    return value.bool;
}

fn requireI64(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    return switch (value) {
        .integer => |number| number,
        .number_string => |raw| std.fmt.parseInt(i64, raw, 10) catch error.InvalidSessionFormat,
        else => error.InvalidSessionFormat,
    };
}

fn requireU64(object: std.json.ObjectMap, key: []const u8) !u64 {
    const value = object.get(key) orelse return error.InvalidSessionFormat;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else error.InvalidSessionFormat,
        .number_string => |raw| std.fmt.parseUnsigned(u64, raw, 10) catch error.InvalidSessionFormat,
        else => error.InvalidSessionFormat,
    };
}

noinline fn requireUsize(object: std.json.ObjectMap, key: []const u8) !usize {
    const number = try requireU64(object, key);
    if (number > std.math.maxInt(usize)) return error.InvalidSessionFormat;
    return @intCast(number);
}

fn parseOptionalU32(value: std.json.Value) !?u32 {
    const number: u64 = switch (value) {
        .null => return null,
        .integer => |integer| if (integer >= 0) @intCast(integer) else return error.InvalidSessionFormat,
        .number_string => |raw| std.fmt.parseUnsigned(u64, raw, 10) catch return error.InvalidSessionFormat,
        else => return error.InvalidSessionFormat,
    };
    if (number > std.math.maxInt(u32)) return error.InvalidSessionFormat;
    return @intCast(number);
}

test "durable byte fields use canonical string or padded base64 representation" {
    const alloc = std.testing.allocator;

    var utf8_out: std.Io.Writer.Allocating = .init(alloc);
    defer utf8_out.deinit();
    try writeDurableBytes(&utf8_out.writer, "hello\nworld");
    try std.testing.expectEqualStrings("\"hello\\nworld\"", utf8_out.written());

    const invalid = [_]u8{ 0xff, 0x00 };
    var binary_out: std.Io.Writer.Allocating = .init(alloc);
    defer binary_out.deinit();
    try writeDurableBytes(&binary_out.writer, &invalid);
    try std.testing.expectEqualStrings("{\"encoding\":\"base64\",\"data\":\"/wA=\"}", binary_out.written());

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, binary_out.written(), .{});
    defer parsed.deinit();
    const decoded = try parseDurableBytes(alloc, parsed.value);
    defer alloc.free(decoded);
    try std.testing.expectEqualSlices(u8, &invalid, decoded);

    const invalid_values = [_][]const u8{
        "{\"encoding\":\"base64\",\"data\":\"/wA\"}",
        "{\"encoding\":\"base64\",\"data\":\"***=\"}",
        "{\"encoding\":\"base64\",\"data\":\"aGk=\"}",
        "{\"data\":\"/wA=\",\"encoding\":\"base64\"}",
        "{\"encoding\":\"base64\",\"data\":\"/wA=\",\"extra\":true}",
    };
    for (invalid_values) |json_text| {
        var bad = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
        defer bad.deinit();
        try std.testing.expectError(error.InvalidDurableBytes, parseDurableBytes(alloc, bad.value));
    }
}

test "durable state round trips live history while discarding legacy authority" {
    const alloc = std.testing.allocator;
    const invalid_a = [_]u8{ 'a', 0xff };
    const invalid_b = [_]u8{ 0xfe, 'b', 0x00 };
    const invalid_c = [_]u8{ 'c', 0xf8 };
    const exact_arguments = " \n{\"number\":1e+02}\t";
    const record_id: types.StableBackgroundRecordId = .{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    };

    var images = [_]session.ImageAttachment{.{
        .id = 7,
        .path = @constCast(invalid_a[0..]),
        .media_type = @constCast(invalid_b[0..]),
        .snapshot_path = @constCast(invalid_c[0..]),
        .snapshot_sha256 = @constCast(invalid_a[0..]),
    }};
    var tool_calls = [_]session.ToolCall{.{
        .id = invalid_a[0..],
        .name = invalid_b[0..],
        .arguments_json = @constCast(exact_arguments),
        .provider_result = invalid_a[0..],
    }};
    var tool_results = [_]session.PersistedToolResult{.{
        .tool_call_id = @constCast(invalid_a[0..]),
        .tool_name = @constCast(invalid_b[0..]),
        .status = .failure,
        .output = @constCast(invalid_c[0..]),
        .output_handle = @constCast(invalid_a[0..]),
        .preview = @constCast(invalid_b[0..]),
        .output_bytes = 99,
        .stored_output_bytes = 42,
        .truncated = true,
        .provider_native = true,
        .created_at_ms = 123,
    }};
    var tool_steps = [_]session.ToolExecutionStep{.{
        .assistant = @constCast(invalid_c[0..]),
        .tool_calls = tool_calls[0..],
        .tool_results = tool_results[0..],
    }};
    var files = [_]session.FileEvidence{.{
        .path = @constCast(invalid_a[0..]),
        .new_path = @constCast(invalid_b[0..]),
        .tool_call_id = @constCast(invalid_c[0..]),
        .tool_name = @constCast(invalid_a[0..]),
        .action = .rename,
        .status = .failure,
        .model_view_covers_full_file = true,
        .stale = true,
    }};
    var completed_tool_names = [_][]u8{
        @constCast(invalid_a[0..]),
        @constCast(invalid_b[0..]),
    };
    const history = [_]session.HistoryTurn{
        .{ .assistant = .{
            .user = .{
                .text = @constCast(invalid_a[0..]),
                .images = images[0..],
                .proven_root = false,
                .work_id = @constCast("work-assistant"),
            },
            .assistant = @constCast(invalid_b[0..]),
            .execution = .{
                .tool_steps = tool_steps[0..],
                .files = files[0..],
            },
        } },
        .{ .background_command = .{
            .user = .{
                .text = @constCast(invalid_b[0..]),
                .work_id = @constCast("work-background"),
            },
            .assistant = @constCast(invalid_a[0..]),
            .execution = .{
                .tool_steps = tool_steps[0..],
                .files = files[0..],
            },
            .log_path = @constCast(invalid_c[0..]),
            .expect_url = true,
            .url = @constCast(invalid_a[0..]),
            .background_record_id = record_id,
        } },
        .{ .interrupted = .{
            .user = .{
                .text = @constCast(invalid_c[0..]),
                .work_id = @constCast("work-interrupted"),
            },
            .assistant = @constCast(invalid_a[0..]),
            .tool_call = tool_calls[0],
            .completed_tool_names = completed_tool_names[0..],
            .execution = .{
                .tool_steps = tool_steps[0..],
                .files = files[0..],
            },
        } },
        .{ .compacted_summary = .{
            .summary = @constCast(invalid_b[0..]),
            .removed_turn_count = 3,
            .compaction_count = 2,
            .root_user_messages = completed_tool_names[0..],
        } },
    };
    var usage_runtime = session_usage.Usage.initFresh();
    defer usage_runtime.deinit(alloc);
    const usage_observation = try session_usage.InvocationObservation.begin(&usage_runtime);
    try usage_observation.completeDirect(
        alloc,
        "provider/model",
        .{ .input_tokens = 1, .output_tokens = 1 },
        .{ .http_ok = true, .terminal_finish_reason = .stop },
    );
    var usage = try usage_runtime.snapshot(alloc);
    defer usage.deinit(alloc);
    const state = DurableSessionState{
        .id = @constCast("1700000000000-42-session"),
        .origin_workspace_root = @constCast("/tmp/origin"),
        .workspace_root = @constCast("/tmp/current"),
        .created_at_ms = 100,
        .updated_at_ms = 90,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = @constCast("openai/gpt-test"),
            .effort = types.ReasoningEffort.literal("future-tier"),
            .fast_mode = true,
        },
        .history = @constCast(history[0..]),
        .context_history_start = 3,
        .total_input_tokens = 1234,
        .total_output_tokens = 567,
        .last_subagent_work_id = @constCast("work-17"),
        .usage = usage,
    };

    var first: std.Io.Writer.Allocating = .init(alloc);
    defer first.deinit();
    const first_summary = try encodeState(state, &first.writer);
    try std.testing.expectEqual(@as(u64, first.written().len), first_summary.encoded_bytes);
    try std.testing.expect(first.written().len > 0);
    try std.testing.expect(first.written()[first.written().len - 1] != '\n');

    var second: std.Io.Writer.Allocating = .init(alloc);
    defer second.deinit();
    _ = try encodeState(state, &second.writer);
    try std.testing.expectEqualStrings(first.written(), second.written());

    var source = std.Io.Reader.fixed(first.written());
    var decoded = try decodeState(alloc, &source, .{});
    defer decoded.deinit(alloc);
    try expectStateEqual(state, decoded);
}

test "durable state repairs duplicate-key execution and interrupted tool arguments" {
    const message_history = @import("../gateway/message_history.zig");
    const alloc = std.testing.allocator;
    const duplicate_arguments = "{\"depth\":1,\"depth\":2}";

    var calls = [_]session.ToolCall{.{
        .id = "call_bad",
        .name = "read_file",
        .arguments_json = duplicate_arguments,
    }};
    var results = [_]session.PersistedToolResult{.{
        .tool_call_id = @constCast("call_bad"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("stale success"),
        .output_bytes = 13,
        .stored_output_bytes = 13,
        .truncated = false,
        .provider_native = false,
        .created_at_ms = 1,
    }};
    var steps = [_]session.ToolExecutionStep{.{
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    const history = [_]session.HistoryTurn{
        .{ .assistant = .{
            .user = .{ .text = @constCast("inspect") },
            .assistant = @constCast("failed"),
            .execution = .{ .tool_steps = steps[0..] },
        } },
        .{ .interrupted = .{
            .user = .{ .text = @constCast("continue") },
            .tool_call = .{
                .id = "call_interrupted",
                .name = "list_files",
                .arguments_json = duplicate_arguments,
            },
        } },
    };
    const state = DurableSessionState{
        .id = @constCast("session-1"),
        .origin_workspace_root = @constCast("/tmp/origin"),
        .workspace_root = @constCast("/tmp/current"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = @constCast("openai/gpt-test"),
            .effort = .auto,
            .fast_mode = false,
        },
        .history = @constCast(history[0..]),
        .total_input_tokens = 3,
        .total_output_tokens = 4,
    };

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    _ = try encodeState(state, &encoded.writer);

    var source = std.Io.Reader.fixed(encoded.written());
    var decoded = try decodeState(alloc, &source, .{});
    defer decoded.deinit(alloc);

    const decoded_step = decoded.history[0].assistant.execution.tool_steps[0];
    try std.testing.expectEqualStrings("{}", decoded_step.tool_calls[0].arguments_json);
    try std.testing.expectEqual(types.ToolArgumentIntegrity.valid, decoded_step.tool_calls[0].argument_integrity);
    try std.testing.expectEqual(session.PersistedToolStatus.failure, decoded_step.tool_results[0].status);
    try std.testing.expect(std.mem.find(u8, decoded_step.tool_results[0].output, "tool_execution_failed") != null);
    try std.testing.expect(std.mem.find(u8, decoded_step.tool_results[0].output, duplicate_arguments) == null);

    const interrupted = decoded.history[1].interrupted.tool_call.?;
    try std.testing.expectEqualStrings("{}", interrupted.arguments_json);
    try std.testing.expectEqual(types.ToolArgumentIntegrity.valid, interrupted.argument_integrity);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages: std.ArrayList(types.ChatMessage) = .empty;
    try session.appendHistoryChatMessages(arena, &messages, decoded.history);
    try message_history.validateToolMessageHistory(arena, messages.items);
}

test "current history decode rejects ambiguous malformed tool result pairings" {
    var duplicate_calls = [_]session.ToolCall{
        .{ .id = "call_bad", .name = "read_file", .arguments_json = "{]" },
        .{ .id = "call_bad", .name = "read_file", .arguments_json = "{]" },
    };
    var one_result = [_]session.PersistedToolResult{persistedResultForTest("call_bad", "read_file")};
    try expectMalformedPairRejected(duplicate_calls[0..], one_result[0..]);

    var missing_call = [_]session.ToolCall{
        .{ .id = "call_bad", .name = "read_file", .arguments_json = "{]" },
    };
    var no_results = [_]session.PersistedToolResult{};
    try expectMalformedPairRejected(missing_call[0..], no_results[0..]);

    var multiple_call = [_]session.ToolCall{
        .{ .id = "call_bad", .name = "read_file", .arguments_json = "{]" },
    };
    var multiple_results = [_]session.PersistedToolResult{
        persistedResultForTest("call_bad", "read_file"),
        persistedResultForTest("call_bad", "read_file"),
    };
    try expectMalformedPairRejected(multiple_call[0..], multiple_results[0..]);

    var mismatched_call = [_]session.ToolCall{
        .{ .id = "call_bad", .name = "read_file", .arguments_json = "{]" },
    };
    var mismatched_result = [_]session.PersistedToolResult{persistedResultForTest("call_bad", "list_files")};
    try expectMalformedPairRejected(mismatched_call[0..], mismatched_result[0..]);
}

test "current history duplicate-key repair preserves allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCurrentToolArgumentRepairAllocationFailures,
        .{},
    );
}

test "legacy durable state defaults context history start to zero" {
    const alloc = std.testing.allocator;
    const legacy =
        "{\"id\":\"legacy\",\"origin_workspace_root\":\"/tmp/origin\",\"workspace_root\":\"/tmp/current\"," ++
        "\"created_at_ms\":1,\"updated_at_ms\":2,\"conversation_language\":\"en\"," ++
        "\"preferences\":{\"model\":\"model\",\"effort\":\"auto\",\"fast_mode\":false}," ++
        "\"history\":[],\"total_input_tokens\":0,\"total_output_tokens\":0}";
    var source = std.Io.Reader.fixed(legacy);
    var decoded = try decodeState(alloc, &source, .{});
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), decoded.context_history_start);

    const invalid =
        "{\"id\":\"invalid\",\"origin_workspace_root\":\"/tmp/origin\",\"workspace_root\":\"/tmp/current\"," ++
        "\"created_at_ms\":1,\"updated_at_ms\":2,\"conversation_language\":\"en\"," ++
        "\"preferences\":{\"model\":\"model\",\"effort\":\"auto\",\"fast_mode\":false}," ++
        "\"history\":[],\"total_input_tokens\":0,\"total_output_tokens\":0,\"context_history_start\":1}";
    var invalid_source = std.Io.Reader.fixed(invalid);
    try std.testing.expectError(
        error.InvalidDurableField,
        decodeState(alloc, &invalid_source, .{}),
    );
}

test "per-turn work provenance is strict and ordinary state omits it" {
    const alloc = std.testing.allocator;
    const ordinary =
        "{\"id\":\"session\",\"origin_workspace_root\":\"/tmp/origin\",\"workspace_root\":\"/tmp/current\",\"created_at_ms\":1,\"updated_at_ms\":1,\"conversation_language\":\"en\",\"preferences\":{\"model\":\"test/model\",\"effort\":\"auto\",\"fast_mode\":false},\"history\":[{\"kind\":\"assistant\",\"user\":{\"text\":\"hello\",\"images\":[]},\"assistant\":\"world\",\"execution\":{\"schema_version\":3,\"tool_steps\":[],\"files\":[]}}],\"total_input_tokens\":0,\"total_output_tokens\":0}";
    var ordinary_source = std.Io.Reader.fixed(ordinary);
    var state = try decodeState(alloc, &ordinary_source, .{});
    defer state.deinit(alloc);
    try std.testing.expect(state.history[0].assistant.user.work_id == null);
    try std.testing.expect(state.history[0].assistant.user.proven_root);

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    _ = try encodeState(state, &encoded.writer);
    try std.testing.expect(std.mem.find(u8, encoded.written(), "work_id") == null);
    try std.testing.expect(std.mem.find(u8, encoded.written(), "proven_root") == null);

    const invalid = [_][]const u8{
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"hello\",\"images\":[],\"work_id\":\"\"},\"assistant\":\"world\",\"execution\":{\"schema_version\":3,\"tool_steps\":[],\"files\":[]}}",
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"hello\",\"images\":[],\"work_id\":null},\"assistant\":\"world\",\"execution\":{\"schema_version\":3,\"tool_steps\":[],\"files\":[]}}",
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"hello\",\"images\":[],\"work_id\":\"bad\\u0000id\"},\"assistant\":\"world\",\"execution\":{\"schema_version\":3,\"tool_steps\":[],\"files\":[]}}",
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"hello\",\"images\":[],\"proven_root\":null},\"assistant\":\"world\",\"execution\":{\"schema_version\":3,\"tool_steps\":[],\"files\":[]}}",
    };
    for (invalid) |json| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        try std.testing.expectError(
            error.InvalidSessionFormat,
            parseHistoryTurn(alloc, parsed.value),
        );
    }

    var too_long: [session.max_work_id_bytes + 1]u8 = undefined;
    @memset(&too_long, 'x');
    state.history[0].assistant.user.work_id = &too_long;
    try std.testing.expectError(error.InvalidDurableField, validateState(state));
    state.history[0].assistant.user.work_id = null;
}

test "durable session IDs accept safe opaque basenames" {
    const valid_ids = [_][]const u8{
        "session.v3",
        ".hidden-session",
        "session..branch",
    };
    for (valid_ids) |id| try validateSessionId(id);

    var max_id: [255]u8 = undefined;
    @memset(&max_id, 'a');
    try validateSessionId(&max_id);

    const state = DurableSessionState{
        .id = max_id[0..],
        .origin_workspace_root = @constCast("/tmp/origin"),
        .workspace_root = @constCast("/tmp/current"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = @constCast("model"),
            .effort = .auto,
            .fast_mode = false,
        },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    _ = try encodeState(state, &encoded.writer);

    var source = std.Io.Reader.fixed(encoded.written());
    var decoded = try decodeState(std.testing.allocator, &source, .{});
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &max_id, decoded.id);
}

test "durable session IDs reject unsafe basenames" {
    const invalid_ids = [_][]const u8{
        "",
        ".",
        "..",
        "path/session",
        "path\\session",
        "session:name",
        "session name",
    };
    for (invalid_ids) |id| {
        try std.testing.expectError(error.InvalidDurableField, validateSessionId(id));
    }

    const unsupported = [_]u8{ 0xff, 'a' };
    try std.testing.expectError(error.InvalidDurableField, validateSessionId(&unsupported));

    var too_long: [256]u8 = undefined;
    @memset(&too_long, 'a');
    try std.testing.expectError(error.InvalidDurableField, validateSessionId(&too_long));
}

test "durable state rejects invalid metadata fields before returning" {
    const alloc = std.testing.allocator;
    const invalid_documents = [_][]const u8{
        "{\"id\":\"../bad\",\"origin_workspace_root\":\"/tmp/a\",\"workspace_root\":\"/tmp/a\",\"created_at_ms\":1,\"updated_at_ms\":1,\"conversation_language\":\"en\",\"preferences\":{\"model\":\"m\",\"effort\":\"auto\",\"fast_mode\":false},\"history\":[],\"total_input_tokens\":0,\"total_output_tokens\":0}",
        "{\"id\":\"good\",\"origin_workspace_root\":\"relative\",\"workspace_root\":\"/tmp/a\",\"created_at_ms\":1,\"updated_at_ms\":1,\"conversation_language\":\"en\",\"preferences\":{\"model\":\"m\",\"effort\":\"auto\",\"fast_mode\":false},\"history\":[],\"total_input_tokens\":0,\"total_output_tokens\":0}",
        "{\"id\":\"good\",\"origin_workspace_root\":\"/tmp/a\",\"workspace_root\":\"/tmp/a\",\"created_at_ms\":1,\"updated_at_ms\":1,\"conversation_language\":\" en \",\"preferences\":{\"model\":\"m\",\"effort\":\"auto\",\"fast_mode\":false},\"history\":[],\"total_input_tokens\":0,\"total_output_tokens\":0}",
        "{\"id\":\"good\",\"origin_workspace_root\":\"/tmp/a\",\"workspace_root\":\"/tmp/a\",\"created_at_ms\":1,\"updated_at_ms\":1,\"conversation_language\":\"en\",\"preferences\":{\"model\":\"m\",\"effort\":\"not valid\",\"fast_mode\":false},\"history\":[],\"total_input_tokens\":0,\"total_output_tokens\":0}",
        "{\"id\":\"good\",\"origin_workspace_root\":\"/tmp/a\",\"workspace_root\":\"/tmp/a\",\"created_at_ms\":1,\"updated_at_ms\":1,\"conversation_language\":\"en\",\"preferences\":{\"model\":\" m\",\"effort\":\"auto\",\"fast_mode\":false},\"history\":[],\"total_input_tokens\":0,\"total_output_tokens\":0}",
    };

    for (invalid_documents) |document| {
        var source = std.Io.Reader.fixed(document);
        try std.testing.expectError(error.InvalidDurableField, decodeState(alloc, &source, .{}));
    }
}

test "durable state rejects invalid turn summary chronology" {
    var history = [_]session.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("inspect") },
        .assistant = @constCast("done"),
        .execution = .{ .turn_summary = .{
            .started_at_ms = 200,
            .completed_at_ms = 100,
        } },
    } }};
    const state = DurableSessionState{
        .id = @constCast("summary-validation"),
        .origin_workspace_root = @constCast("/tmp/workspace"),
        .workspace_root = @constCast("/tmp/workspace"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = @constCast("model"),
            .effort = .auto,
            .fast_mode = false,
        },
        .history = &history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
    try std.testing.expectError(error.InvalidDurableField, validateState(state));
}

test "execution memory codec preserves feedback and reads v1 results without it" {
    const alloc = std.testing.allocator;
    var feedback = [_][]u8{@constCast("read it after writing")};
    const presentation_lines = [_]types.CommittedFilePresentationLine{
        .{ .kind = .addition, .new_line = 1, .text = "persisted line" },
        .{ .kind = .notice, .text = "… 118 lines omitted" },
    };
    var calls = [_]session.ToolCall{.{
        .id = @constCast("call_feedback"),
        .name = @constCast("write_file"),
        .arguments_json = @constCast("{\"path\":\"note.txt\"}"),
    }};
    var results = [_]session.PersistedToolResult{.{
        .tool_call_id = @constCast("call_feedback"),
        .tool_name = @constCast("write_file"),
        .status = .success,
        .output = @constCast("wrote note.txt"),
        .output_bytes = 15,
        .stored_output_bytes = 15,
        .permission_feedback = feedback[0..],
        .committed_file_presentation = .{
            .path = "note.txt",
            .kind = .added,
            .lines = presentation_lines[0..],
            .additions = 120,
            .deletions = 0,
            .truncated = true,
            .after_content = "persisted line\n",
            .lifecycle_id = .{
                .turn_id = 9,
                .call_id = "call_feedback",
            },
        },
        .command_output_replay = .{ .available = .{
            .handle = "fx-command-replay-private.bin",
            .framed_bytes = 321,
        } },
        .command_artifact_handle = @constCast("fx-command-output.log"),
        .command_process_presentation = .{ .exit_code = 7 },
    }};
    var steps = [_]session.ToolExecutionStep{.{
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    const turn: session.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("write a note") },
        .assistant = @constCast("done"),
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
    } };

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try writeHistoryTurn(&encoded.writer, turn);
    try std.testing.expect(std.mem.find(u8, encoded.written(), "\"schema_version\":7") != null);
    try std.testing.expect(std.mem.find(u8, encoded.written(), "\"permission_feedback\"") != null);
    try std.testing.expect(std.mem.find(u8, encoded.written(), "\"committed_file_presentation\"") != null);
    try std.testing.expect(std.mem.find(u8, encoded.written(), "\"command_output_replay\"") != null);
    try std.testing.expect(std.mem.find(u8, encoded.written(), "fx-command-replay-private.bin") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded.written(), .{});
    defer parsed.deinit();
    const decoded = try parseHistoryTurn(alloc, parsed.value);
    defer session.freeHistoryTurn(alloc, decoded);
    const decoded_result = decoded.assistant.execution.tool_steps[0].tool_results[0];
    try std.testing.expectEqual(
        turn.assistant.execution.turn_summary,
        decoded.assistant.execution.turn_summary,
    );
    try std.testing.expectEqual(@as(usize, 1), decoded_result.permission_feedback.len);
    try std.testing.expectEqualStrings("read it after writing", decoded_result.permission_feedback[0]);
    const presentation = decoded_result.committed_file_presentation orelse return error.TestExpectedPresentation;
    try std.testing.expectEqualStrings("note.txt", presentation.path);
    try std.testing.expectEqual(types.CommittedFilePresentationKind.added, presentation.kind);
    try std.testing.expectEqual(@as(usize, 2), presentation.lines.len);
    try std.testing.expectEqual(types.CommittedFilePresentationLineKind.notice, presentation.lines[1].kind);
    try std.testing.expectEqualStrings("… 118 lines omitted", presentation.lines[1].text);
    try std.testing.expectEqual(@as(usize, 120), presentation.additions);
    try std.testing.expectEqualStrings("persisted line\n", presentation.after_content.?);
    try std.testing.expectEqual(@as(u64, 9), presentation.lifecycle_id.?.turn_id);
    try std.testing.expectEqualStrings("call_feedback", presentation.lifecycle_id.?.call_id);
    const replay = decoded_result.command_output_replay orelse return error.TestExpectedReplay;
    const descriptor = switch (replay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedReplay,
    };
    try std.testing.expectEqualStrings("fx-command-replay-private.bin", descriptor.handle);
    try std.testing.expectEqual(@as(usize, 321), descriptor.framed_bytes);
    try std.testing.expectEqualStrings(
        "fx-command-output.log",
        decoded_result.command_artifact_handle.?,
    );
    try std.testing.expectEqual(
        types.CommandProcessPresentation{ .exit_code = 7 },
        decoded_result.command_process_presentation.?,
    );

    const v1 =
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"write a note\",\"images\":[]},\"assistant\":\"done\",\"execution\":{\"schema_version\":1,\"tool_steps\":[{\"assistant\":null,\"tool_calls\":[{\"id\":\"call_feedback\",\"name\":\"write_file\",\"arguments_json\":\"{\\\"path\\\":\\\"note.txt\\\"}\",\"provider_result\":null}],\"tool_results\":[{\"tool_call_id\":\"call_feedback\",\"tool_name\":\"write_file\",\"status\":\"success\",\"output\":\"wrote note.txt\",\"output_handle\":null,\"preview\":null,\"output_bytes\":15,\"stored_output_bytes\":15,\"truncated\":false,\"provider_native\":false,\"created_at_ms\":1}]}],\"files\":[]}}";
    var v1_parsed = try std.json.parseFromSlice(std.json.Value, alloc, v1, .{});
    defer v1_parsed.deinit();
    const v1_decoded = try parseHistoryTurn(alloc, v1_parsed.value);
    defer session.freeHistoryTurn(alloc, v1_decoded);
    try std.testing.expectEqual(
        @as(usize, 0),
        v1_decoded.assistant.execution.tool_steps[0].tool_results[0].permission_feedback.len,
    );
    try std.testing.expect(v1_decoded.assistant.execution.tool_steps[0].tool_results[0].command_output_replay == null);
    try std.testing.expect(v1_decoded.assistant.execution.tool_steps[0].tool_results[0].command_process_presentation == null);

    const v2 =
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"write a note\",\"images\":[]},\"assistant\":\"done\",\"execution\":{\"schema_version\":2,\"tool_steps\":[{\"assistant\":null,\"tool_calls\":[{\"id\":\"call_feedback\",\"name\":\"write_file\",\"arguments_json\":\"{\\\"path\\\":\\\"note.txt\\\"}\",\"provider_result\":null}],\"tool_results\":[{\"tool_call_id\":\"call_feedback\",\"tool_name\":\"write_file\",\"status\":\"success\",\"output\":\"wrote note.txt\",\"output_handle\":null,\"preview\":null,\"output_bytes\":15,\"stored_output_bytes\":15,\"truncated\":false,\"provider_native\":false,\"created_at_ms\":1,\"permission_feedback\":[]}]}],\"files\":[]}}";
    var v2_parsed = try std.json.parseFromSlice(std.json.Value, alloc, v2, .{});
    defer v2_parsed.deinit();
    const v2_decoded = try parseHistoryTurn(alloc, v2_parsed.value);
    defer session.freeHistoryTurn(alloc, v2_decoded);
    try std.testing.expect(v2_decoded.assistant.execution.tool_steps[0].tool_results[0].committed_file_presentation == null);
    try std.testing.expect(v2_decoded.assistant.execution.tool_steps[0].tool_results[0].command_output_replay == null);
    try std.testing.expect(v2_decoded.assistant.execution.tool_steps[0].tool_results[0].command_process_presentation == null);
}

test "private codec preserves summary-only specialized turns" {
    const alloc = std.testing.allocator;
    const summary = types.TurnSummary{
        .started_at_ms = 100,
        .completed_at_ms = 250,
        .thinking_duration_ms = 40,
        .turn_duration_ms = 150,
        .token_progress = .{ .input_tokens = 12, .output_tokens = 34 },
    };

    const turns = [_]session.HistoryTurn{
        .{ .background_command = .{
            .user = .{ .text = @constCast("start server") },
            .execution = .{ .turn_summary = summary },
            .log_path = @constCast("/tmp/server.log"),
            .expect_url = false,
        } },
        .{ .interrupted = .{
            .user = .{ .text = @constCast("inspect repository") },
            .execution = .{ .turn_summary = summary },
        } },
    };

    for (turns) |turn| {
        var encoded: std.Io.Writer.Allocating = .init(alloc);
        defer encoded.deinit();
        try writeHistoryTurn(&encoded.writer, turn);

        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded.written(), .{});
        defer parsed.deinit();
        const decoded = try parseHistoryTurn(alloc, parsed.value);
        defer session.freeHistoryTurn(alloc, decoded);
        try std.testing.expectEqual(summary, types.historyTurnSummary(decoded).?);
    }
}

test "execution memory codec drops oversized durable file bodies but keeps preview" {
    const alloc = std.testing.allocator;
    const oversized = try alloc.alloc(
        u8,
        execution_retention.durable_file_body_policy.max_presentation_bytes + 1,
    );
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    const presentation_lines = [_]types.CommittedFilePresentationLine{.{
        .kind = .notice,
        .text = "bounded preview",
    }};
    var results = [_]session.PersistedToolResult{.{
        .tool_call_id = @constCast("call_large_edit"),
        .tool_name = @constCast("edit_file"),
        .status = .success,
        .output = @constCast("edited"),
        .output_bytes = 6,
        .stored_output_bytes = 6,
        .committed_file_presentation = .{
            .path = "large.txt",
            .kind = .edited,
            .lines = &presentation_lines,
            .additions = 1,
            .deletions = 1,
            .truncated = true,
            .previous_content = oversized,
        },
    }};
    var steps = [_]session.ToolExecutionStep{.{ .tool_results = &results }};
    const turn: session.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("edit the large file") },
        .assistant = @constCast("done"),
        .execution = .{ .tool_steps = &steps },
    } };

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try writeHistoryTurn(&encoded.writer, turn);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded.written(), .{});
    defer parsed.deinit();
    const decoded = try parseHistoryTurn(alloc, parsed.value);
    defer session.freeHistoryTurn(alloc, decoded);

    const presentation = decoded.assistant.execution.tool_steps[0].tool_results[0]
        .committed_file_presentation orelse return error.TestExpectedPresentation;
    try std.testing.expect(presentation.previous_content == null);
    try std.testing.expect(presentation.after_content == null);
    try std.testing.expectEqualStrings("bounded preview", presentation.lines[0].text);
}

test "assistant history codec round trips Responses reasoning identity and accepts legacy turns" {
    const alloc = std.testing.allocator;
    var tool_reasoning_items = [_]types.ResponsesReasoningItem{
        .{ .output_index = 0, .id = "rs_tool_1", .summary = "tool first", .encrypted_content = "tool opaque 1" },
        .{ .output_index = 2, .id = "rs_tool_2", .summary = "tool second", .encrypted_content = "tool opaque 2" },
    };
    var terminal_reasoning_items = [_]types.ResponsesReasoningItem{
        .{ .output_index = 0, .id = "rs_terminal_1", .summary = "terminal first", .encrypted_content = "terminal opaque 1" },
        .{ .output_index = 1, .id = "rs_terminal_2", .summary = "terminal second", .encrypted_content = "terminal opaque 2" },
    };
    var tool_output_items = [_]types.ResponsesProviderOutputItem{
        .{ .output_index = 0, .json = "{\"type\":\"reasoning\",\"id\":\"rs_tool_1\"}" },
        .{ .output_index = 1, .json = "{\"type\":\"web_search_call\",\"id\":\"ws_tool\",\"status\":\"completed\"}" },
        .{ .output_index = 2, .json = "{\"type\":\"reasoning\",\"id\":\"rs_tool_2\"}" },
        .{ .output_index = 3, .json = "{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}" },
    };
    var terminal_output_items = [_]types.ResponsesProviderOutputItem{
        .{ .output_index = 0, .json = "{\"type\":\"reasoning\",\"id\":\"rs_terminal_1\"}" },
        .{ .output_index = 1, .json = "{\"type\":\"reasoning\",\"id\":\"rs_terminal_2\"}" },
        .{ .output_index = 2, .json = "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}" },
    };
    var calls = [_]session.ToolCall{.{
        .id = @constCast("call_1"),
        .name = @constCast("read_file"),
        .arguments_json = @constCast("{\"path\":\"a.txt\"}"),
        .responses_item_id = @constCast("fc_call_1"),
        .responses_output_index = 3,
    }};
    var results = [_]session.PersistedToolResult{.{
        .tool_call_id = @constCast("call_1"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("contents"),
        .output_bytes = 8,
        .stored_output_bytes = 8,
    }};
    var steps = [_]session.ToolExecutionStep{.{
        .reasoning = @constCast("tool reasoning"),
        .reasoning_items = &tool_reasoning_items,
        .responses_provider_output_items = &tool_output_items,
        .responses_output_sequence_complete = true,
        .tool_calls = &calls,
        .tool_results = &results,
    }};
    const turn: session.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("inspect") },
        .assistant = @constCast("done"),
        .responses_message_output_index = 2,
        .reasoning = @constCast("checked the repository"),
        .reasoning_items = &terminal_reasoning_items,
        .responses_provider_output_items = &terminal_output_items,
        .responses_output_sequence_complete = true,
        .execution = .{ .tool_steps = &steps },
    } };

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try writeHistoryTurn(&encoded.writer, turn);
    try std.testing.expect(std.mem.find(u8, encoded.written(), "\"schema_version\":7") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded.written(), .{});
    defer parsed.deinit();
    const decoded = try parseHistoryTurn(alloc, parsed.value);
    defer session.freeHistoryTurn(alloc, decoded);
    try expectHistoryTurnEqual(turn, decoded);

    var legacy = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"old\",\"images\":[]},\"assistant\":\"reply\",\"execution\":{\"schema_version\":3,\"tool_steps\":[],\"files\":[]}}",
        .{},
    );
    defer legacy.deinit();
    const legacy_turn = try parseHistoryTurn(alloc, legacy.value);
    defer session.freeHistoryTurn(alloc, legacy_turn);
    try std.testing.expect(legacy_turn.assistant.reasoning == null);
    try std.testing.expect(legacy_turn.assistant.reasoning_item_id == null);
    try std.testing.expect(legacy_turn.assistant.reasoning_encrypted_content == null);
    try std.testing.expectEqual(@as(usize, 0), legacy_turn.assistant.reasoning_items.len);
    try std.testing.expect(legacy_turn.assistant.responses_message_output_index == null);
    try std.testing.expectEqual(@as(usize, 0), legacy_turn.assistant.responses_provider_output_items.len);
    try std.testing.expect(!legacy_turn.assistant.responses_output_sequence_complete);
}

test "compacted history codec round trips a bound opaque Responses checkpoint" {
    const alloc = std.testing.allocator;
    const replay_json =
        "[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}," ++
        "{\"type\":\"compaction\",\"encrypted_content\":\"opaque\"}]";
    const turn = session.HistoryTurn{ .compacted_summary = .{
        .summary = @constCast("portable local summary"),
        .removed_turn_count = 4,
        .compaction_count = 2,
        .responses_compaction = .{
            .credential_source = .chatgpt_subscription,
            .wire_model = @constCast("gpt-5.6-sol"),
            .input_json = @constCast(replay_json),
            .provider_binding = .{
                .normalized_origin = @constCast("https://chatgpt.com/backend-api/codex/responses"),
                .account_id = @constCast("account-a"),
            },
        },
    } };

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try writeHistoryTurn(&encoded.writer, turn);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        encoded.written(),
        .{},
    );
    defer parsed.deinit();
    const restored = try parseHistoryTurn(alloc, parsed.value);
    defer session.freeHistoryTurn(alloc, restored);
    const checkpoint = restored.compacted_summary.responses_compaction.?;
    try std.testing.expectEqual(types.CredentialSource.chatgpt_subscription, checkpoint.credential_source);
    try std.testing.expectEqualStrings("gpt-5.6-sol", checkpoint.wire_model);
    try std.testing.expectEqualStrings(replay_json, checkpoint.input_json);
    try std.testing.expectEqualStrings(
        "https://chatgpt.com/backend-api/codex/responses",
        checkpoint.provider_binding.?.normalized_origin,
    );
    try std.testing.expectEqualStrings("account-a", checkpoint.provider_binding.?.account_id.?);

    const legacy_without_binding =
        "{\"kind\":\"compacted_summary\",\"summary\":\"summary\",\"removed_turn_count\":1," ++
        "\"compaction_count\":1,\"responses_compaction\":{\"credential_source\":\"chatgpt_subscription\"," ++
        "\"wire_model\":\"gpt-5.6-sol\",\"input_json\":\"[{\\\"type\\\":\\\"compaction\\\",\\\"encrypted_content\\\":\\\"opaque\\\"}]\"}}";
    var legacy = try std.json.parseFromSlice(std.json.Value, alloc, legacy_without_binding, .{});
    defer legacy.deinit();
    const legacy_turn = try parseHistoryTurn(alloc, legacy.value);
    defer session.freeHistoryTurn(alloc, legacy_turn);
    try std.testing.expect(legacy_turn.compacted_summary.responses_compaction.?.provider_binding == null);

    const wrong_source =
        "{\"kind\":\"compacted_summary\",\"summary\":\"summary\",\"removed_turn_count\":1," ++
        "\"compaction_count\":1,\"responses_compaction\":{\"credential_source\":\"stored_key\"," ++
        "\"wire_model\":\"gpt-5.6-sol\",\"input_json\":\"[{\\\"type\\\":\\\"compaction\\\",\\\"encrypted_content\\\":\\\"opaque\\\"}]\"}}";
    var invalid = try std.json.parseFromSlice(std.json.Value, alloc, wrong_source, .{});
    defer invalid.deinit();
    try std.testing.expectError(
        error.InvalidSessionFormat,
        parseHistoryTurn(alloc, invalid.value),
    );
}

test "command process presentation codec preserves every terminal cause" {
    const alloc = std.testing.allocator;
    const cases = [_]types.CommandProcessPresentation{
        .{ .exit_code = 7 },
        .{ .signal = 9 },
        .timed_out,
        .output_capture_failed,
    };
    for (cases) |case| {
        var encoded: std.Io.Writer.Allocating = .init(alloc);
        defer encoded.deinit();
        try writeOptionalCommandProcessPresentation(&encoded.writer, case);

        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded.written(), .{});
        defer parsed.deinit();
        try std.testing.expectEqual(
            case,
            (try parseOptionalCommandProcessPresentation(parsed.value)).?,
        );
    }
}

test "durable history rejects unknown fields instead of silently dropping bytes" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"kind\":\"compacted_summary\",\"summary\":\"kept\",\"removed_turn_count\":1,\"compaction_count\":1,\"future_bytes\":\"lost\"}",
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectError(
        error.InvalidSessionFormat,
        parseHistoryTurn(alloc, parsed.value),
    );
}

test "legacy compacted authority absence remains incomplete across durable reload" {
    const alloc = std.testing.allocator;
    var legacy_parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"kind\":\"compacted_summary\",\"summary\":\"legacy\",\"removed_turn_count\":2,\"compaction_count\":1}",
        .{},
    );
    defer legacy_parsed.deinit();
    const legacy = try parseHistoryTurn(alloc, legacy_parsed.value);
    defer session.freeHistoryTurn(alloc, legacy);
    try std.testing.expect(!legacy.compacted_summary.root_user_messages_complete);
    try std.testing.expect(!legacy.compacted_summary.permission_feedback_complete);

    var known_messages = [_][]u8{@constCast("newer exact request")};
    const incomplete: session.HistoryTurn = .{ .compacted_summary = .{
        .summary = @constCast("legacy plus newer context"),
        .removed_turn_count = 3,
        .compaction_count = 2,
        .root_user_messages = &known_messages,
        .root_user_messages_complete = false,
        .permission_feedback = &known_messages,
        .permission_feedback_complete = false,
    } };
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try writeHistoryTurn(&encoded.writer, incomplete);
    var reloaded_parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        encoded.written(),
        .{},
    );
    defer reloaded_parsed.deinit();
    const reloaded = try parseHistoryTurn(alloc, reloaded_parsed.value);
    defer session.freeHistoryTurn(alloc, reloaded);
    try std.testing.expect(!reloaded.compacted_summary.root_user_messages_complete);
    try std.testing.expect(!reloaded.compacted_summary.permission_feedback_complete);
    try std.testing.expectEqual(@as(usize, 0), reloaded.compacted_summary.root_user_messages.len);

    var first_generation_parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"kind\":\"compacted_summary\",\"summary\":\"first generation\",\"removed_turn_count\":2,\"compaction_count\":1,\"root_user_messages\":[\"original request\"]}",
        .{},
    );
    defer first_generation_parsed.deinit();
    const first_generation = try parseHistoryTurn(alloc, first_generation_parsed.value);
    defer session.freeHistoryTurn(alloc, first_generation);
    try std.testing.expect(first_generation.compacted_summary.root_user_messages_complete);
    try std.testing.expect(!first_generation.compacted_summary.permission_feedback_complete);
    try std.testing.expectEqualStrings(
        "original request",
        first_generation.compacted_summary.root_user_messages[0],
    );
}

fn persistedResultForTest(call_id: []const u8, tool_name: []const u8) session.PersistedToolResult {
    return .{
        .tool_call_id = @constCast(call_id),
        .tool_name = @constCast(tool_name),
        .status = .success,
        .output = @constCast("stale"),
        .output_bytes = 5,
        .stored_output_bytes = 5,
        .truncated = false,
        .provider_native = false,
        .created_at_ms = 1,
    };
}

fn expectMalformedPairRejected(
    calls: []session.ToolCall,
    results: []session.PersistedToolResult,
) !void {
    var steps = [_]session.ToolExecutionStep{.{
        .tool_calls = calls,
        .tool_results = results,
    }};
    const turn: session.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("inspect") },
        .assistant = @constCast("failed"),
        .execution = .{ .tool_steps = steps[0..] },
    } };

    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try writeHistoryTurn(&encoded.writer, turn);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded.written(), .{});
    defer parsed.deinit();
    try std.testing.expectError(
        error.InvalidSessionFormat,
        parseHistoryTurn(std.testing.allocator, parsed.value),
    );
}

fn checkCurrentToolArgumentRepairAllocationFailures(alloc: Allocator) !void {
    var feedback = [_][]u8{@constCast("read the repaired file")};
    var calls = [_]session.ToolCall{.{
        .id = @constCast("call_bad"),
        .name = @constCast("read_file"),
        .arguments_json = @constCast("{\"depth\":1,\"depth\":2}"),
    }};
    var results = [_]session.PersistedToolResult{persistedResultForTest("call_bad", "read_file")};
    results[0].permission_feedback = feedback[0..];
    var steps = [_]session.ToolExecutionStep{.{
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    const turn: session.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("inspect") },
        .assistant = @constCast("failed"),
        .execution = .{ .tool_steps = steps[0..] },
    } };

    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try writeHistoryTurn(&encoded.writer, turn);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        encoded.written(),
        .{},
    );
    defer parsed.deinit();

    const decoded = try parseHistoryTurn(alloc, parsed.value);
    defer session.freeHistoryTurn(alloc, decoded);
    const step = decoded.assistant.execution.tool_steps[0];
    try std.testing.expectEqualStrings("{}", step.tool_calls[0].arguments_json);
    try std.testing.expectEqual(session.PersistedToolStatus.failure, step.tool_results[0].status);
    try std.testing.expectEqual(@as(usize, 1), step.tool_results[0].permission_feedback.len);
}

test "durable specialized history accepts only legacy or complete extended shapes" {
    const alloc = std.testing.allocator;
    const empty_execution = "{\"schema_version\":1,\"tool_steps\":[],\"files\":[]}";
    const cases = [_]struct {
        json: []const u8,
        expected: enum { background_legacy, background_extended, interrupted_legacy, interrupted_extended },
    }{
        .{
            .json = "{\"kind\":\"background_command\",\"user\":{\"text\":\"run\",\"images\":[]},\"log_path\":\"/tmp/log\",\"expect_url\":false,\"url\":null,\"background_record_id\":null}",
            .expected = .background_legacy,
        },
        .{
            .json = "{\"kind\":\"background_command\",\"user\":{\"text\":\"run\",\"images\":[]},\"log_path\":\"/tmp/log\",\"expect_url\":false,\"url\":null,\"background_record_id\":null,\"assistant\":\"candidate\",\"execution\":" ++ empty_execution ++ "}",
            .expected = .background_extended,
        },
        .{
            .json = "{\"kind\":\"interrupted\",\"user\":{\"text\":\"stop\",\"images\":[]},\"assistant\":null,\"tool_call\":null,\"completed_tool_names\":[]}",
            .expected = .interrupted_legacy,
        },
        .{
            .json = "{\"kind\":\"interrupted\",\"user\":{\"text\":\"stop\",\"images\":[]},\"assistant\":\"candidate\",\"tool_call\":null,\"completed_tool_names\":[],\"execution\":" ++ empty_execution ++ "}",
            .expected = .interrupted_extended,
        },
    };

    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, case.json, .{});
        defer parsed.deinit();
        const turn = try parseHistoryTurn(alloc, parsed.value);
        defer session.freeHistoryTurn(alloc, turn);
        switch (case.expected) {
            .background_legacy => {
                try std.testing.expect(turn.background_command.assistant == null);
                try std.testing.expect(turn.background_command.execution.isEmpty());
            },
            .background_extended => {
                try std.testing.expectEqualStrings("candidate", turn.background_command.assistant.?);
                try std.testing.expect(turn.background_command.execution.isEmpty());
            },
            .interrupted_legacy => try std.testing.expect(turn.interrupted.execution.isEmpty()),
            .interrupted_extended => {
                try std.testing.expectEqualStrings("candidate", turn.interrupted.assistant.?);
                try std.testing.expect(turn.interrupted.execution.isEmpty());
            },
        }
    }

    const invalid = [_][]const u8{
        "{\"kind\":\"background_command\",\"user\":{\"text\":\"run\",\"images\":[]},\"log_path\":\"/tmp/log\",\"expect_url\":false,\"url\":null,\"background_record_id\":null,\"assistant\":\"partial\"}",
        "{\"kind\":\"background_command\",\"user\":{\"text\":\"run\",\"images\":[]},\"log_path\":\"/tmp/log\",\"expect_url\":false,\"url\":null,\"background_record_id\":null,\"assistant\":\"candidate\",\"execution\":" ++ empty_execution ++ ",\"future\":true}",
        "{\"kind\":\"interrupted\",\"user\":{\"text\":\"stop\",\"images\":[]},\"assistant\":null,\"tool_call\":null,\"completed_tool_names\":[],\"future\":true}",
    };
    for (invalid) |json| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidSessionFormat, parseHistoryTurn(alloc, parsed.value));
    }

    const legacy_background = session.HistoryTurn{ .background_command = .{
        .user = .{ .text = @constCast("run") },
        .log_path = @constCast("/tmp/log"),
        .expect_url = false,
    } };
    var legacy_encoded: std.Io.Writer.Allocating = .init(alloc);
    defer legacy_encoded.deinit();
    try writeHistoryTurn(&legacy_encoded.writer, legacy_background);
    try std.testing.expect(std.mem.find(u8, legacy_encoded.written(), "\"assistant\"") == null);
    try std.testing.expect(std.mem.find(u8, legacy_encoded.written(), "\"execution\"") == null);

    const extended_background = session.HistoryTurn{ .background_command = .{
        .user = .{ .text = @constCast("run") },
        .assistant = @constCast("candidate"),
        .log_path = @constCast("/tmp/log"),
        .expect_url = false,
    } };
    var extended_encoded: std.Io.Writer.Allocating = .init(alloc);
    defer extended_encoded.deinit();
    try writeHistoryTurn(&extended_encoded.writer, extended_background);
    try std.testing.expect(std.mem.find(u8, extended_encoded.written(), "\"assistant\"") != null);
    try std.testing.expect(std.mem.find(u8, extended_encoded.written(), "\"execution\"") != null);
}

test "interrupted command presentation is strict and round trips" {
    const alloc = std.testing.allocator;
    const turn: session.HistoryTurn = .{ .interrupted = .{
        .user = .{ .text = @constCast("stop") },
        .tool_call = .{
            .id = "call-command",
            .name = "run_command",
            .arguments_json = "{\"command\":\"slow\"}",
        },
        .cancelled_command = .{
            .output_replay = .{ .available = .{
                .handle = "fx-command-replay.bin",
                .framed_bytes = 42,
            } },
            .command_artifact_handle = "fx-command.log",
        },
    } };
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try writeHistoryTurn(&encoded.writer, turn);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded.written(), .{});
    defer parsed.deinit();
    const decoded = try parseHistoryTurn(alloc, parsed.value);
    defer session.freeHistoryTurn(alloc, decoded);
    const presentation = decoded.interrupted.cancelled_command.?;
    const descriptor = switch (presentation.output_replay.?) {
        .available => |value| value,
        .unavailable => return error.TestExpectedReplay,
    };
    try std.testing.expectEqualStrings("fx-command-replay.bin", descriptor.handle);
    try std.testing.expectEqual(@as(usize, 42), descriptor.framed_bytes);
    try std.testing.expectEqualStrings("fx-command.log", presentation.command_artifact_handle.?);
    try std.testing.expectEqual(types.InterruptedTerminalReason.cancelled, decoded.interrupted.terminal_reason);

    const failed_turn: session.HistoryTurn = .{ .interrupted = .{
        .user = .{ .text = @constCast("stream") },
        .assistant = @constCast("partial"),
        .terminal_reason = .failed,
    } };
    var failed_encoded: std.Io.Writer.Allocating = .init(alloc);
    defer failed_encoded.deinit();
    try writeHistoryTurn(&failed_encoded.writer, failed_turn);
    try std.testing.expect(std.mem.find(u8, failed_encoded.written(), "\"terminal_reason\":\"failed\"") != null);
    var failed_parsed = try std.json.parseFromSlice(std.json.Value, alloc, failed_encoded.written(), .{});
    defer failed_parsed.deinit();
    const failed_decoded = try parseHistoryTurn(alloc, failed_parsed.value);
    defer session.freeHistoryTurn(alloc, failed_decoded);
    try std.testing.expectEqual(types.InterruptedTerminalReason.failed, failed_decoded.interrupted.terminal_reason);

    const zero_output =
        "{\"kind\":\"interrupted\",\"user\":{\"text\":\"stop\",\"images\":[]}," ++
        "\"assistant\":null,\"tool_call\":{\"id\":\"call\",\"name\":\"run_command\"," ++
        "\"arguments_json\":\"{}\",\"provider_result\":null},\"completed_tool_names\":[]," ++
        "\"cancelled_command\":{\"output_replay\":null,\"command_artifact_handle\":null}}";
    var zero_parsed = try std.json.parseFromSlice(std.json.Value, alloc, zero_output, .{});
    defer zero_parsed.deinit();
    const zero_turn = try parseHistoryTurn(alloc, zero_parsed.value);
    defer session.freeHistoryTurn(alloc, zero_turn);
    try std.testing.expect(zero_turn.interrupted.cancelled_command != null);
    try std.testing.expectEqual(types.InterruptedTerminalReason.cancelled, zero_turn.interrupted.terminal_reason);

    const invalid = [_][]const u8{
        "{\"kind\":\"interrupted\",\"user\":{\"text\":\"stop\",\"images\":[]},\"assistant\":null,\"tool_call\":null,\"completed_tool_names\":[],\"cancelled_command\":{\"output_replay\":null,\"command_artifact_handle\":null}}",
        "{\"kind\":\"interrupted\",\"user\":{\"text\":\"stop\",\"images\":[]},\"assistant\":null,\"tool_call\":{\"id\":\"call\",\"name\":\"read_file\",\"arguments_json\":\"{}\",\"provider_result\":null},\"completed_tool_names\":[],\"cancelled_command\":{\"output_replay\":null,\"command_artifact_handle\":null}}",
        "{\"kind\":\"interrupted\",\"user\":{\"text\":\"stop\",\"images\":[]},\"assistant\":null,\"tool_call\":{\"id\":\"call\",\"name\":\"run_command\",\"arguments_json\":\"{}\",\"provider_result\":null},\"completed_tool_names\":[],\"cancelled_command\":{\"output_replay\":null,\"command_artifact_handle\":null,\"future\":true}}",
        "{\"kind\":\"interrupted\",\"user\":{\"text\":\"stop\",\"images\":[]},\"assistant\":null,\"tool_call\":{\"id\":\"call\",\"name\":\"run_command\",\"arguments_json\":\"{}\",\"provider_result\":null},\"completed_tool_names\":[],\"terminal_reason\":\"failed\",\"cancelled_command\":{\"output_replay\":null,\"command_artifact_handle\":null}}",
        "{\"kind\":\"interrupted\",\"user\":{\"text\":\"stop\",\"images\":[]},\"assistant\":null,\"tool_call\":null,\"completed_tool_names\":[],\"terminal_reason\":\"future\"}",
    };
    for (invalid) |json| {
        var invalid_parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer invalid_parsed.deinit();
        try std.testing.expectError(
            error.InvalidSessionFormat,
            parseHistoryTurn(alloc, invalid_parsed.value),
        );
    }
}

fn expectStateEqual(expected: DurableSessionState, actual: DurableSessionState) !void {
    try std.testing.expectEqualStrings(expected.id, actual.id);
    try std.testing.expectEqualStrings(expected.origin_workspace_root, actual.origin_workspace_root);
    try std.testing.expectEqualStrings(expected.workspace_root, actual.workspace_root);
    try std.testing.expectEqual(expected.created_at_ms, actual.created_at_ms);
    try std.testing.expectEqual(expected.updated_at_ms, actual.updated_at_ms);
    try std.testing.expectEqualStrings(expected.conversation_language.view(), actual.conversation_language.view());
    try std.testing.expectEqualStrings(expected.preferences.model, actual.preferences.model);
    try std.testing.expectEqual(expected.preferences.provider, actual.preferences.provider);
    try std.testing.expectEqual(expected.preferences.effort, actual.preferences.effort);
    try std.testing.expectEqual(expected.preferences.fast_mode, actual.preferences.fast_mode);
    try std.testing.expectEqual(expected.context_history_start, actual.context_history_start);
    try std.testing.expectEqual(expected.total_input_tokens, actual.total_input_tokens);
    try std.testing.expectEqual(expected.total_output_tokens, actual.total_output_tokens);
    try expectPermissionStateEqual(expected.permission_state, actual.permission_state);
    try std.testing.expectEqual(expected.last_subagent_work_id != null, actual.last_subagent_work_id != null);
    if (expected.last_subagent_work_id) |work_id| {
        try std.testing.expectEqualStrings(work_id, actual.last_subagent_work_id.?);
    }
    try std.testing.expectEqual(expected.usage != null, actual.usage != null);
    if (expected.usage) |expected_usage| {
        var expected_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer expected_json.deinit();
        try session_usage.writeSnapshot(&expected_json.writer, expected_usage);
        var actual_json: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer actual_json.deinit();
        try session_usage.writeSnapshot(&actual_json.writer, actual.usage.?);
        try std.testing.expectEqualStrings(expected_json.written(), actual_json.written());
    }
    try std.testing.expectEqual(expected.history.len, actual.history.len);
    for (expected.history, actual.history) |expected_turn, actual_turn| {
        try expectHistoryTurnEqual(expected_turn, actual_turn);
    }
}

fn expectPermissionStateEqual(
    expected: session_permission_state.State,
    actual: session_permission_state.State,
) !void {
    try std.testing.expectEqual(expected.version, actual.version);
    try std.testing.expectEqual(expected.next_generation, actual.next_generation);
    try std.testing.expectEqual(expected.rules.items.len, actual.rules.items.len);
    for (expected.rules.items, actual.rules.items) |expected_rule, actual_rule| {
        try std.testing.expectEqual(expected_rule.id, actual_rule.id);
        try std.testing.expectEqual(expected_rule.key.kind, actual_rule.key.kind);
        try std.testing.expectEqualSlices(u8, &expected_rule.key.digest, &actual_rule.key.digest);
        try std.testing.expectEqualSlices(u8, expected_rule.key.canonical, actual_rule.key.canonical);
        try std.testing.expectEqualStrings(expected_rule.display_identity, actual_rule.display_identity);
        try std.testing.expectEqual(expected_rule.decision, actual_rule.decision);
        try std.testing.expectEqual(expected_rule.generation, actual_rule.generation);
    }
}

fn expectHistoryTurnEqual(expected: session.HistoryTurn, actual: session.HistoryTurn) !void {
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .compacted_summary => |entry| {
            try std.testing.expectEqualSlices(u8, entry.summary, actual.compacted_summary.summary);
            try std.testing.expectEqual(entry.removed_turn_count, actual.compacted_summary.removed_turn_count);
            try std.testing.expectEqual(entry.compaction_count, actual.compacted_summary.compaction_count);
            try std.testing.expect(!actual.compacted_summary.root_user_messages_complete);
            try std.testing.expectEqual(
                @as(usize, 0),
                actual.compacted_summary.root_user_messages.len,
            );
            try std.testing.expect(!actual.compacted_summary.permission_feedback_complete);
            try std.testing.expectEqual(
                @as(usize, 0),
                actual.compacted_summary.permission_feedback.len,
            );
        },
        .assistant => |entry| {
            const got = actual.assistant;
            try expectUserTurnEqual(entry.user, got.user);
            try std.testing.expectEqualSlices(u8, entry.assistant, got.assistant);
            try std.testing.expectEqual(
                entry.responses_message_output_index,
                got.responses_message_output_index,
            );
            try expectOptionalBytesEqual(entry.reasoning, got.reasoning);
            try expectOptionalBytesEqual(entry.reasoning_item_id, got.reasoning_item_id);
            try expectOptionalBytesEqual(
                entry.reasoning_encrypted_content,
                got.reasoning_encrypted_content,
            );
            try expectResponsesReasoningItemsEqual(entry.reasoning_items, got.reasoning_items);
            try expectResponsesProviderOutputItemsEqual(
                entry.responses_provider_output_items,
                got.responses_provider_output_items,
            );
            try std.testing.expectEqual(
                entry.responses_output_sequence_complete,
                got.responses_output_sequence_complete,
            );
            try expectExecutionMemoryEqual(entry.execution, got.execution);
        },
        .background_command => |entry| {
            const got = actual.background_command;
            try expectUserTurnEqual(entry.user, got.user);
            try expectOptionalBytesEqual(entry.assistant, got.assistant);
            try expectExecutionMemoryEqual(entry.execution, got.execution);
            try std.testing.expectEqualSlices(u8, entry.log_path, got.log_path);
            try std.testing.expectEqual(entry.expect_url, got.expect_url);
            try expectOptionalBytesEqual(entry.url, got.url);
            try std.testing.expectEqual(entry.background_record_id != null, got.background_record_id != null);
            if (entry.background_record_id) |record_id| {
                try std.testing.expectEqualSlices(u8, &record_id, &got.background_record_id.?);
            }
        },
        .interrupted => |entry| {
            const got = actual.interrupted;
            try expectUserTurnEqual(entry.user, got.user);
            try expectOptionalBytesEqual(entry.assistant, got.assistant);
            try std.testing.expectEqual(entry.tool_call != null, got.tool_call != null);
            if (entry.tool_call) |call| try expectToolCallEqual(call, got.tool_call.?);
            try std.testing.expectEqual(entry.completed_tool_names.len, got.completed_tool_names.len);
            for (entry.completed_tool_names, got.completed_tool_names) |name, got_name| {
                try std.testing.expectEqualSlices(u8, name, got_name);
            }
            try expectExecutionMemoryEqual(entry.execution, got.execution);
            try std.testing.expectEqualDeep(entry.cancelled_command, got.cancelled_command);
            try std.testing.expectEqual(entry.terminal_reason, got.terminal_reason);
        },
    }
}

fn expectExecutionMemoryEqual(expected: session.ExecutionMemory, actual: session.ExecutionMemory) !void {
    try std.testing.expectEqual(expected.turn_summary, actual.turn_summary);
    try std.testing.expectEqual(expected.tool_steps.len, actual.tool_steps.len);
    for (expected.tool_steps, actual.tool_steps) |step, got_step| {
        try expectOptionalBytesEqual(step.assistant, got_step.assistant);
        try std.testing.expectEqual(
            step.responses_message_output_index,
            got_step.responses_message_output_index,
        );
        try expectOptionalBytesEqual(step.reasoning, got_step.reasoning);
        try expectOptionalBytesEqual(step.reasoning_item_id, got_step.reasoning_item_id);
        try expectOptionalBytesEqual(
            step.reasoning_encrypted_content,
            got_step.reasoning_encrypted_content,
        );
        try expectResponsesReasoningItemsEqual(step.reasoning_items, got_step.reasoning_items);
        try expectResponsesProviderOutputItemsEqual(
            step.responses_provider_output_items,
            got_step.responses_provider_output_items,
        );
        try std.testing.expectEqual(
            step.responses_output_sequence_complete,
            got_step.responses_output_sequence_complete,
        );
        try std.testing.expectEqual(step.tool_calls.len, got_step.tool_calls.len);
        for (step.tool_calls, got_step.tool_calls) |call, got_call| try expectToolCallEqual(call, got_call);
        try std.testing.expectEqual(step.tool_results.len, got_step.tool_results.len);
        for (step.tool_results, got_step.tool_results) |result, got_result| {
            try std.testing.expectEqualSlices(u8, result.tool_call_id, got_result.tool_call_id);
            try std.testing.expectEqualSlices(u8, result.tool_name, got_result.tool_name);
            try std.testing.expectEqual(result.status, got_result.status);
            try std.testing.expectEqualSlices(u8, result.output, got_result.output);
            try expectOptionalBytesEqual(result.output_handle, got_result.output_handle);
            try expectOptionalBytesEqual(result.preview, got_result.preview);
            try std.testing.expectEqual(result.output_bytes, got_result.output_bytes);
            try std.testing.expectEqual(result.stored_output_bytes, got_result.stored_output_bytes);
            try std.testing.expectEqual(result.truncated, got_result.truncated);
            try std.testing.expectEqual(result.provider_native, got_result.provider_native);
            try std.testing.expectEqual(result.created_at_ms, got_result.created_at_ms);
        }
    }
    try std.testing.expectEqual(expected.files.len, actual.files.len);
    for (expected.files, actual.files) |file, got_file| {
        try std.testing.expectEqualSlices(u8, file.path, got_file.path);
        try expectOptionalBytesEqual(file.new_path, got_file.new_path);
        try std.testing.expectEqualSlices(u8, file.tool_call_id, got_file.tool_call_id);
        try std.testing.expectEqualSlices(u8, file.tool_name, got_file.tool_name);
        try std.testing.expectEqual(file.action, got_file.action);
        try std.testing.expectEqual(file.status, got_file.status);
        try std.testing.expectEqual(file.model_view_covers_full_file, got_file.model_view_covers_full_file);
        try std.testing.expectEqual(file.stale, got_file.stale);
    }
}

fn expectResponsesReasoningItemsEqual(
    expected: []const types.ResponsesReasoningItem,
    actual: []const types.ResponsesReasoningItem,
) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |item, got| {
        try std.testing.expectEqual(item.output_index, got.output_index);
        try expectOptionalBytesEqual(item.id, got.id);
        try expectOptionalBytesEqual(item.summary, got.summary);
        try expectOptionalBytesEqual(item.encrypted_content, got.encrypted_content);
    }
}

fn expectResponsesProviderOutputItemsEqual(
    expected: []const types.ResponsesProviderOutputItem,
    actual: []const types.ResponsesProviderOutputItem,
) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |item, got| {
        try std.testing.expectEqual(item.output_index, got.output_index);
        try std.testing.expectEqualSlices(u8, item.json, got.json);
    }
}

fn expectUserTurnEqual(expected: session.UserTurn, actual: session.UserTurn) !void {
    try std.testing.expectEqualSlices(u8, expected.text, actual.text);
    try std.testing.expectEqual(expected.proven_root, actual.proven_root);
    try expectOptionalBytesEqual(expected.work_id, actual.work_id);
    try std.testing.expectEqual(expected.images.len, actual.images.len);
    for (expected.images, actual.images) |image, got| {
        try std.testing.expectEqual(image.id, got.id);
        try std.testing.expectEqualSlices(u8, image.path, got.path);
        try std.testing.expectEqualSlices(u8, image.media_type, got.media_type);
        try expectOptionalBytesEqual(image.snapshot_path, got.snapshot_path);
        try expectOptionalBytesEqual(image.snapshot_sha256, got.snapshot_sha256);
    }
}

fn expectToolCallEqual(expected: session.ToolCall, actual: session.ToolCall) !void {
    try std.testing.expectEqualSlices(u8, expected.id, actual.id);
    try std.testing.expectEqualSlices(u8, expected.name, actual.name);
    try std.testing.expectEqualSlices(u8, expected.arguments_json, actual.arguments_json);
    try expectOptionalBytesEqual(expected.provider_result, actual.provider_result);
    try expectOptionalBytesEqual(expected.responses_item_id, actual.responses_item_id);
    try std.testing.expectEqual(expected.responses_output_index, actual.responses_output_index);
}

fn expectOptionalBytesEqual(expected: anytype, actual: @TypeOf(expected)) !void {
    try std.testing.expectEqual(expected != null, actual != null);
    if (expected) |bytes| try std.testing.expectEqualSlices(u8, bytes, actual.?);
}

test "durable image snapshots serialize as session-relative locators" {
    const alloc = std.testing.allocator;
    var images = [_]session.ImageAttachment{.{
        .id = 1,
        .path = @constCast("/Users/private/source.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast("/tmp/fx/sessions/session-id/images/image-1-deadbeef.bin"),
        .snapshot_sha256 = @constCast("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
    }};
    const turn: session.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("[Image #1]"), .images = &images },
        .assistant = @constCast("done"),
    } };
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();

    try writeHistoryTurn(&encoded.writer, turn);

    try std.testing.expect(std.mem.find(
        u8,
        encoded.written(),
        "/tmp/fx/sessions/session-id/images",
    ) == null);
    try std.testing.expect(std.mem.find(
        u8,
        encoded.written(),
        "\"snapshot_path\":\"images/image-1-deadbeef.bin\"",
    ) != null);
}

test "codec structural helpers enforce exact objects and required strings" {
    const alloc = std.testing.allocator;

    var unknown_key = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"known\":\"value\",\"unexpected\":true}",
        .{},
    );
    defer unknown_key.deinit();
    try std.testing.expectError(
        error.InvalidSessionFormat,
        exactObject(unknown_key.value, &.{"known"}),
    );

    var non_string = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"known\":1}",
        .{},
    );
    defer non_string.deinit();
    const non_string_object = try exactObject(non_string.value, &.{"known"});
    try std.testing.expectError(
        error.InvalidSessionFormat,
        requireString(non_string_object, "known"),
    );

    var valid = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"known\":\"value\"}",
        .{},
    );
    defer valid.deinit();
    const valid_object = try exactObject(valid.value, &.{"known"});
    try std.testing.expectEqualStrings("value", try requireString(valid_object, "known"));
}

test "recovery checkpoint round trips while legacy state stays absent" {
    const alloc = std.testing.allocator;
    const checkpoint = RecoveryCheckpoint{
        .turn_id = 42,
        .user = .{
            .text = @constCast("keep working"),
            .proven_root = false,
        },
        .assistant_source = @constCast("partial answer"),
        .cause = .response_interrupted,
        .action = .continuing_response,
        .tool_state = .confirmed,
        .authority = .{
            .provider = .codex,
            .model = @constCast("gpt-5.4-mini"),
            .credential_source = .chatgpt_subscription,
            .credential_identity = credential_authority.derive(
                .chatgpt_subscription,
                "acct-codex",
            ),
        },
        .requested_fast_mode = true,
        .fast_mode = true,
        .max_provider_attempts = 10,
        .consumed_provider_attempts = 4,
        .outstanding_reservation = true,
    };
    const state = DurableSessionState{
        .id = @constCast("session-recovery"),
        .origin_workspace_root = @constCast("/tmp/origin"),
        .workspace_root = @constCast("/tmp/current"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .provider = .codex,
            .model = @constCast("gpt-5.4-mini"),
            .effort = .auto,
            .fast_mode = false,
        },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .recovery_checkpoint = checkpoint,
    };

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    _ = try encodeState(state, &encoded.writer);
    var source = std.Io.Reader.fixed(encoded.written());
    var decoded = try decodeState(alloc, &source, .{});
    defer decoded.deinit(alloc);

    const restored = decoded.recovery_checkpoint.?;
    try std.testing.expectEqual(@as(u64, 42), restored.turn_id);
    try std.testing.expectEqualStrings("keep working", restored.user.text);
    try std.testing.expect(!restored.user.proven_root);
    try std.testing.expectEqualStrings("partial answer", restored.assistant_source);
    try std.testing.expectEqual(types.ModelRecoveryCause.response_interrupted, restored.cause);
    try std.testing.expectEqual(types.ModelRecoveryAction.continuing_response, restored.action);
    try std.testing.expectEqual(RecoveryToolState.confirmed, restored.tool_state);
    try std.testing.expectEqual(model_provider.ProviderId.codex, restored.authority.provider);
    try std.testing.expectEqualStrings("gpt-5.4-mini", restored.authority.model);
    try std.testing.expectEqual(
        types.CredentialSource.chatgpt_subscription,
        restored.authority.credential_source.?,
    );
    try std.testing.expectEqual(model_provider.ProviderId.codex, decoded.preferences.provider);
    try std.testing.expect(restored.requested_fast_mode);
    try std.testing.expect(restored.fast_mode);
    try std.testing.expectEqual(@as(usize, 4), restored.consumed_provider_attempts);
    try std.testing.expect(restored.outstanding_reservation);

    const legacy =
        "{\"id\":\"legacy\",\"origin_workspace_root\":\"/tmp/origin\",\"workspace_root\":\"/tmp/current\",\"created_at_ms\":1,\"updated_at_ms\":2,\"conversation_language\":\"en\",\"preferences\":{\"model\":\"openai/gpt-test\",\"effort\":\"auto\",\"fast_mode\":false},\"history\":[],\"total_input_tokens\":0,\"total_output_tokens\":0}";
    var legacy_source = std.Io.Reader.fixed(legacy);
    var legacy_state = try decodeState(alloc, &legacy_source, .{});
    defer legacy_state.deinit(alloc);
    try std.testing.expectEqual(model_provider.ProviderId.gateway, legacy_state.preferences.provider);
    try std.testing.expectEqual(@as(?RecoveryCheckpoint, null), legacy_state.recovery_checkpoint);
}

test "session permission state round trips while legacy state stays empty" {
    const alloc = std.testing.allocator;
    const key = try session_permission_state.RuleKey.init(
        .command,
        "command\x00/workspace\x00git status",
    );
    var empty_permission_state: session_permission_state.State = .{};
    defer empty_permission_state.deinit(alloc);
    var applied = try session_permission_state.apply(
        alloc,
        empty_permission_state,
        .{ .set = .{
            .key = key,
            .display_identity = "git status in /workspace",
            .decision = .deny,
            .expected_generation = null,
        } },
    );
    var permission_state = applied.takeApplied() orelse
        return error.TestExpectedAppliedState;
    defer permission_state.deinit(alloc);

    const state = DurableSessionState{
        .id = @constCast("session-permission-state"),
        .origin_workspace_root = @constCast("/tmp/origin"),
        .workspace_root = @constCast("/tmp/current"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = @constCast("openai/gpt-test"),
            .effort = .auto,
            .fast_mode = false,
        },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .permission_state = permission_state,
    };
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    _ = try encodeState(state, &encoded.writer);
    var source = std.Io.Reader.fixed(encoded.written());
    var decoded = try decodeState(alloc, &source, .{});
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(
        session_permission_state.StateDecision.deny,
        session_permission_state.decide(decoded.permission_state, key),
    );

    const legacy =
        "{\"id\":\"legacy-permission-state\",\"origin_workspace_root\":\"/tmp/origin\",\"workspace_root\":\"/tmp/current\",\"created_at_ms\":1,\"updated_at_ms\":2,\"conversation_language\":\"en\",\"preferences\":{\"model\":\"openai/gpt-test\",\"effort\":\"auto\",\"fast_mode\":false},\"history\":[],\"total_input_tokens\":0,\"total_output_tokens\":0}";
    var legacy_source = std.Io.Reader.fixed(legacy);
    var legacy_state = try decodeState(alloc, &legacy_source, .{});
    defer legacy_state.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), legacy_state.permission_state.rules.items.len);
}

test "recovery checkpoint rejects an outstanding attempt beyond its budget" {
    const invalid = DurableSessionState{
        .id = @constCast("session-recovery"),
        .origin_workspace_root = @constCast("/tmp/origin"),
        .workspace_root = @constCast("/tmp/current"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = @constCast("openai/gpt-test"),
            .effort = .auto,
            .fast_mode = false,
        },
        .history = &.{},
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .recovery_checkpoint = .{
            .turn_id = 1,
            .user = .{ .text = @constCast("prompt") },
            .assistant_source = @constCast(""),
            .cause = .network_interrupted,
            .action = .retrying_request,
            .authority = .{
                .provider = .gateway,
                .model = @constCast("openai/gpt-test"),
                .credential_source = .openai_api_key,
                .credential_identity = credential_authority.derive(
                    .openai_api_key,
                    null,
                ),
            },
            .requested_fast_mode = false,
            .fast_mode = false,
            .max_provider_attempts = 1,
            .consumed_provider_attempts = 1,
            .outstanding_reservation = true,
        },
    };
    try std.testing.expectError(error.InvalidDurableField, validateState(invalid));
}

test "permission state schema two round trips before activation" {
    const alloc = std.testing.allocator;
    var state: session_permission_state.State = .{
        .version = session_permission_state.schema_version,
        .next_generation = 2,
    };
    defer state.deinit(alloc);
    const key = try session_permission_state.commandKeyV2(
        alloc,
        "git status",
        "/workspace",
        "foreground",
        "macos",
    );
    try state.rules.append(alloc, .{
        .id = .{ .value = 1 },
        .key = key,
        .display_identity = try alloc.dupe(u8, "git status"),
        .decision = .deny,
        .generation = 1,
    });

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try writePermissionState(&encoded.writer, state);
    var json = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        encoded.written(),
        .{},
    );
    defer json.deinit();
    var decoded = try parsePermissionState(alloc, json.value);
    defer decoded.deinit(alloc);

    try std.testing.expectEqual(session_permission_state.schema_version, decoded.version);
    try std.testing.expectEqual(@as(usize, 1), decoded.rules.items.len);
    try std.testing.expectEqual(session_permission_state.StateDecision.deny, session_permission_state.decide(decoded, key));
}

test "durable session optional fields handle fuzzed ownership paths" {
    try std.testing.fuzz({}, fuzzDurableSessionOptionalFields, .{ .corpus = &.{
        "{\"id\":\"session\",\"origin_workspace_root\":\"/tmp/origin\",\"workspace_root\":\"/tmp/current\",\"created_at_ms\":1,\"updated_at_ms\":1,\"conversation_language\":\"en\",\"preferences\":{\"model\":\"test/model\",\"effort\":\"auto\",\"fast_mode\":false},\"history\":[],\"total_input_tokens\":0,\"total_output_tokens\":0}",
        "{\"id\":\"session\",\"origin_workspace_root\":\"/tmp/origin\",\"workspace_root\":\"/tmp/current\",\"created_at_ms\":1,\"updated_at_ms\":1,\"conversation_language\":\"en\",\"preferences\":{\"model\":\"test/model\",\"effort\":\"auto\",\"fast_mode\":false},\"history\":[],\"total_input_tokens\":0,\"total_output_tokens\":0,\"context_history_start\":0,\"last_subagent_work_id\":\"work\"}",
        "{\"id\":\"session\",\"origin_workspace_root\":\"/tmp/origin\",\"workspace_root\":\"/tmp/current\",\"created_at_ms\":1,\"updated_at_ms\":1,\"conversation_language\":\"en\",\"preferences\":{\"model\":\"test/model\",\"effort\":\"auto\",\"fast_mode\":false},\"history\":[],\"total_input_tokens\":0,\"total_output_tokens\":0,\"last_subagent_work_id\":\"work\",\"context_history_start\":0}",
        "",
        "{}",
        "{\"last_subagent_work_id\":null}",
        "{\"usage\":null,\"last_subagent_work_id\":\"work\"}",
        "{\"last_subagent_work_id\":\"work\",\"usage\":null}",
    } });
}

test "per-turn work provenance parser handles fuzzed ownership paths" {
    try std.testing.fuzz({}, fuzzWorkProvenanceHistoryTurn, .{ .corpus = &.{
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"prompt\",\"images\":[],\"work_id\":\"work-1\"},\"assistant\":\"reply\",\"execution\":{\"schema_version\":3,\"tool_steps\":[],\"files\":[]}}",
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"prompt\",\"images\":[]},\"assistant\":\"reply\",\"execution\":{\"schema_version\":3,\"tool_steps\":[],\"files\":[]}}",
        "{\"kind\":\"assistant\",\"user\":{\"text\":\"prompt\",\"images\":[],\"work_id\":\"\"}}",
        "",
        "{}",
    } });
}

fn fuzzWorkProvenanceHistoryTurn(_: void, smith: *std.testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        buffer[0..len],
        .{ .allocate = .alloc_always },
    ) catch return;
    defer parsed.deinit();
    const turn = parseHistoryTurn(std.testing.allocator, parsed.value) catch return;
    session.freeHistoryTurn(std.testing.allocator, turn);
}

fn fuzzDurableSessionOptionalFields(_: void, smith: *std.testing.Smith) !void {
    var buffer: [8192]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    var source = std.Io.Reader.fixed(buffer[0..len]);
    var state = decodeState(std.testing.allocator, &source, .{
        .max_history_turns = 8,
        .max_value_bytes = buffer.len,
    }) catch return;
    state.deinit(std.testing.allocator);
}
