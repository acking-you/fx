const std = @import("std");
const hooks = @import("../../hooks/hooks.zig");
const types = @import("../../shared/types.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const deps_mod = @import("deps.zig");
const execution_memory = @import("execution_memory.zig");
const durable_execution_memory = @import("../execution_memory.zig");
const lifecycle_runtime = @import("lifecycle.zig");
const telemetry = @import("telemetry.zig");
const worker_runtime = @import("../worker_runtime.zig");

const Allocator = std.mem.Allocator;
const AgentRuntimeDeps = deps_mod.AgentRuntimeDeps;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;
const LifecycleContext = lifecycle_runtime.LifecycleContext;
const QueuedPrompt = worker_runtime.QueuedPrompt;
const TraceContext = debug_trace.TraceContext;
const TurnSummaryAccumulator = telemetry.TurnSummaryAccumulator;

pub const PromptFinishTrace = struct {
    ctx: TraceContext,
    emitted: bool = false,

    pub fn finish(self: *PromptFinishTrace, outcome: []const u8) void {
        if (self.emitted) return;
        self.emitted = true;
        debug_trace.eventf("agent", "prompt_finish", self.ctx, "outcome_kind={s}", .{outcome});
    }
};

pub const TurnFinalizationGuard = struct {
    pub const State = enum {
        open,
        emitted,
        fatal,
    };

    deps: *const AgentRuntimeDeps,
    turn_id: u64,
    lifecycle: LifecycleContext,
    state: State = .open,
    auto_compact_after_finish: bool = false,
    auto_compact_after_finish_local_only: bool = false,

    pub fn init(
        deps: *const AgentRuntimeDeps,
        turn_id: u64,
        lifecycle_context: LifecycleContext,
    ) TurnFinalizationGuard {
        std.debug.assert(turn_id != 0);
        return .{
            .deps = deps,
            .turn_id = turn_id,
            .lifecycle = lifecycle_context,
        };
    }

    pub fn requestAutoCompaction(
        self: *TurnFinalizationGuard,
        local_only: bool,
    ) void {
        self.auto_compact_after_finish = true;
        self.auto_compact_after_finish_local_only =
            self.auto_compact_after_finish_local_only or local_only;
    }

    pub fn deinit(self: *TurnFinalizationGuard) void {
        self.* = undefined;
    }

    pub fn finish(
        self: *TurnFinalizationGuard,
        outcome: types.TurnPresentationOutcome,
        disposition: ?types.ProviderCompletionDisposition,
        finished_prompt: ?types.FinishedPrompt,
    ) !void {
        if (self.state != .open) {
            if (finished_prompt) |finished| {
                types.freeFinishedPrompt(std.heap.c_allocator, finished);
            }
            debug_trace.logf(
                "agent",
                "duplicate turn finalization ignored turn_id={d} state={s}",
                .{ self.turn_id, @tagName(self.state) },
            );
            return;
        }

        self.deps.finalize_turn(self.deps.ctx, self.turn_id, outcome, disposition) catch |err| {
            self.state = .fatal;
            if (finished_prompt) |finished| {
                types.freeFinishedPrompt(std.heap.c_allocator, finished);
            }
            return err;
        };
        self.state = .emitted;

        defer lifecycle_runtime.dispatchPostTurnEndCheckpoint(self.lifecycle, .{
            .turn_id = self.turn_id,
            .outcome = outcome,
            .provider_disposition = disposition,
        });

        if (finished_prompt) |finished| {
            var qualified_finished = finished;
            qualified_finished.terminal_outcome = outcome;
            qualified_finished.auto_compact_after_finish = self.auto_compact_after_finish;
            qualified_finished.auto_compact_after_finish_local_only =
                self.auto_compact_after_finish_local_only;
            try self.deps.push_event(self.deps.ctx, .{ .finish_prompt = qualified_finished });
        }
    }
};

pub fn finishAssistantTerminalWithExecution(
    deps: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    job: QueuedPrompt,
    execution: types.ExecutionMemory,
    summary: *TurnSummaryAccumulator,
    assistant_text: []const u8,
    outcome: types.TurnPresentationOutcome,
    disposition: ?types.ProviderCompletionDisposition,
    finish_trace: *PromptFinishTrace,
    trace_outcome: []const u8,
) !void {
    return finishAssistantTerminalWithExecutionAndReasoning(
        deps,
        finalization,
        job,
        execution,
        summary,
        assistant_text,
        null,
        null,
        null,
        &.{},
        &.{},
        null,
        false,
        outcome,
        disposition,
        finish_trace,
        trace_outcome,
    );
}

pub fn finishAssistantTerminalWithExecutionAndReasoning(
    deps: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    job: QueuedPrompt,
    execution: types.ExecutionMemory,
    summary: *TurnSummaryAccumulator,
    assistant_text: []const u8,
    reasoning: ?[]const u8,
    reasoning_item_id: ?[]const u8,
    reasoning_encrypted_content: ?[]const u8,
    reasoning_items: []const types.ResponsesReasoningItem,
    provider_output_items: []const types.ResponsesProviderOutputItem,
    message_output_index: ?u32,
    output_sequence_complete: bool,
    outcome: types.TurnPresentationOutcome,
    disposition: ?types.ProviderCompletionDisposition,
    finish_trace: *PromptFinishTrace,
    trace_outcome: []const u8,
) !void {
    const maybe_provider_output_items = try durable_execution_memory.dupePersistableResponsesProviderOutputItems(
        std.heap.c_allocator,
        provider_output_items,
    );
    const persisted_provider_output_items = maybe_provider_output_items orelse &.{};
    defer types.freeResponsesProviderOutputItems(
        std.heap.c_allocator,
        persisted_provider_output_items,
    );
    const completed_summary = summary.finish();
    var turn: HistoryTurn = .{ .assistant = .{
        .user = job.historyUser(),
        .assistant = @constCast(assistant_text),
        .responses_message_output_index = message_output_index,
        .reasoning = if (reasoning) |value| @constCast(value) else null,
        .reasoning_item_id = if (reasoning_item_id) |value| @constCast(value) else null,
        .reasoning_encrypted_content = if (reasoning_encrypted_content) |value| @constCast(value) else null,
        .reasoning_items = @constCast(reasoning_items),
        .responses_provider_output_items = @constCast(persisted_provider_output_items),
        .responses_output_sequence_complete = output_sequence_complete and
            maybe_provider_output_items != null,
        .execution = execution,
    } };
    types.setHistoryTurnSummary(&turn, completed_summary);
    const finished = try types.dupeFinishedPrompt(
        std.heap.c_allocator,
        .{
            .turn = turn,
            .summary = completed_summary,
        },
    );

    var propagation_error: ?anyerror = null;
    deps.propagate_history_turn(deps.ctx, turn) catch |err| {
        propagation_error = err;
    };
    try finalization.finish(outcome, disposition, finished);
    finish_trace.finish(trace_outcome);
    if (propagation_error) |err| return err;
}

pub fn finishExecutionOnlyFailureIfNeeded(
    deps: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    arena: Allocator,
    job: QueuedPrompt,
    current_turn_messages: []const ChatMessage,
    summary: *TurnSummaryAccumulator,
    finish_trace: *PromptFinishTrace,
    terminal_materializing: *bool,
    trace_outcome: []const u8,
) !bool {
    const execution = try execution_memory.buildExecutionMemory(
        arena,
        current_turn_messages,
    );
    if (execution.isEmpty()) return false;

    terminal_materializing.* = true;
    try finishAssistantTerminalWithExecution(
        deps,
        finalization,
        job,
        execution,
        summary,
        "",
        .failed,
        null,
        finish_trace,
        trace_outcome,
    );
    return true;
}

pub fn finalizeRetainedCandidateFailure(
    deps: *const AgentRuntimeDeps,
    finalization: *TurnFinalizationGuard,
    arena: Allocator,
    job: QueuedPrompt,
    current_turn_messages: []const ChatMessage,
    summary: *TurnSummaryAccumulator,
    finish_trace: *PromptFinishTrace,
    retained_candidate: ?[]const u8,
    latest_partial: ?[]const u8,
    terminal_materializing: *bool,
) !void {
    terminal_materializing.* = true;
    const assistant_text = try hooks.prompt.joinVisibleSegments(
        arena,
        retained_candidate,
        latest_partial,
    );
    const execution = try execution_memory.buildExecutionMemory(
        arena,
        current_turn_messages,
    );
    try finishAssistantTerminalWithExecution(
        deps,
        finalization,
        job,
        execution,
        summary,
        assistant_text,
        .failed,
        null,
        finish_trace,
        "error",
    );
}
