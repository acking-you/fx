const std = @import("std");
const acp_runner = @import("../core/cli/acp_runner.zig");
const config_runtime = @import("../core/config/config_runtime.zig");
const io_mod = @import("../core/shared/io.zig");
const host_target = @import("../core/hosts/target.zig");
const jsonrpc = @import("jsonrpc.zig");
const acp_types = @import("types.zig");
const sessions = @import("sessions.zig");
const session_test_controls = @import("session_test_controls.zig");
const prompt_handler = @import("prompt.zig");
const prompt_test_controls = @import("prompt_test_controls.zig");
const app_lifecycle = @import("../core/app/app_lifecycle.zig");
const app_runtime_setup = @import("../core/app/app_runtime_setup.zig");
const builtin_skills = @import("../builtins/skills.zig");
const builtin_tools = @import("../builtins/tools.zig");
const credentials = @import("../core/auth/credentials.zig");
const gateway_session = @import("../core/auth/gateway_session.zig");
const provider_oauth = @import("../core/auth/provider_oauth.zig");
const secret = @import("../core/auth/secret.zig");
const auth_runtime = @import("../core/auth/auth_runtime.zig");
const provider_activation = @import("../core/auth/provider_activation.zig");
const provider_setup = @import("../core/auth/provider_setup.zig");
const login_flow = @import("../core/auth/login_flow.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const model_provider = @import("../core/config/model_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const provider_route = @import("../core/gateway/provider_route.zig");
const hooks = @import("../core/hooks/hooks.zig");
const mode_registry = @import("../core/modes/mode_registry.zig");
const skill_runtime = @import("../core/skills/skill_runtime.zig");
const session_codec = @import("../core/session/session_codec.zig");
const session_log = @import("../core/session/session_log.zig");
const session_store = @import("../core/session/session_store.zig");
const session_runtime = @import("../core/session/session.zig");
const session_usage = @import("../core/session/session_usage.zig");
const provider_usage = @import("../core/session/provider_usage.zig");
const account_usage_runtime = @import("../core/app/account_usage_runtime.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const worker_runtime = @import("../core/agent/worker_runtime.zig");
const terminal_client_runtime = @import("../core/terminal/client.zig");
const unified_exec_runtime = @import("../core/execution/unified_exec.zig");
const subagent_tool_host = @import("../core/subagent/tool_host.zig");
const subagent_authority = @import("../core/subagent/authority.zig");
const types = @import("../core/shared/types.zig");
const context_contract = @import("../core/workspace/context_contract.zig");
const workspace_access = @import("../core/workspace/workspace_access.zig");
const web_fetch_runtime = @import("../core/tooling/web_fetch_runtime.zig");
const web_search_runtime = @import("../core/tooling/web_search_runtime.zig");

const Allocator = std.mem.Allocator;
const ErrorCode = jsonrpc.ErrorCode;
const writeJsonStr = jsonrpc.writeJsonStr;

const AcpMethod = enum {
    initialize,
    session_cancel,
    session_new,
    session_load,
    session_resume,
    session_close,
    session_list,
    session_remove,
    session_prompt,
    session_set_config_option,
    session_set_mode,
    fx_turn_steer,
    fx_turn_status,
    fx_background_terminals_list,
    fx_unified_exec_write_stdin,
    fx_unified_exec_kill,
    fx_provider_switch,
    fx_provider_configure,
    fx_provider_setup_start,
    fx_provider_setup_status,
    fx_provider_login_start,
    fx_provider_login_status,
    fx_provider_login_submit_code,
    fx_provider_login_cancel,
    fx_provider_usage,
    fx_tool_mode_set,
    unknown,

    fn parse(method: []const u8) AcpMethod {
        if (std.mem.eql(u8, method, "initialize")) return .initialize;
        if (std.mem.eql(u8, method, "session/cancel")) return .session_cancel;
        if (std.mem.eql(u8, method, "session/new")) return .session_new;
        if (std.mem.eql(u8, method, "session/load")) return .session_load;
        if (std.mem.eql(u8, method, "session/resume")) return .session_resume;
        if (std.mem.eql(u8, method, "session/close")) return .session_close;
        if (std.mem.eql(u8, method, "session/list")) return .session_list;
        if (std.mem.eql(u8, method, "session/remove")) return .session_remove;
        if (std.mem.eql(u8, method, "session/prompt")) return .session_prompt;
        if (std.mem.eql(u8, method, "session/set_config_option")) return .session_set_config_option;
        if (std.mem.eql(u8, method, "session/set_mode")) return .session_set_mode;
        if (std.mem.eql(u8, method, "fx/turn/steer")) return .fx_turn_steer;
        if (std.mem.eql(u8, method, "fx/turn/status")) return .fx_turn_status;
        if (std.mem.eql(u8, method, "fx/backgroundTerminals/list")) return .fx_background_terminals_list;
        if (std.mem.eql(u8, method, "fx/unifiedExec/writeStdin")) return .fx_unified_exec_write_stdin;
        if (std.mem.eql(u8, method, "fx/unifiedExec/kill")) return .fx_unified_exec_kill;
        if (std.mem.eql(u8, method, "fx/provider/switch")) return .fx_provider_switch;
        if (std.mem.eql(u8, method, "fx/provider/configure")) return .fx_provider_configure;
        if (std.mem.eql(u8, method, "fx/provider/setup/start")) return .fx_provider_setup_start;
        if (std.mem.eql(u8, method, "fx/provider/setup/status")) return .fx_provider_setup_status;
        if (std.mem.eql(u8, method, "fx/provider/login/start")) return .fx_provider_login_start;
        if (std.mem.eql(u8, method, "fx/provider/login/status")) return .fx_provider_login_status;
        if (std.mem.eql(u8, method, "fx/provider/login/submitCode")) return .fx_provider_login_submit_code;
        if (std.mem.eql(u8, method, "fx/provider/login/cancel")) return .fx_provider_login_cancel;
        if (std.mem.eql(u8, method, "fx/provider/usage")) return .fx_provider_usage;
        if (std.mem.eql(u8, method, "fx/toolMode/set")) return .fx_tool_mode_set;
        return .unknown;
    }

    fn waitsForActivePrompt(self: AcpMethod) bool {
        return switch (self) {
            .initialize,
            .session_cancel,
            .session_set_mode,
            .session_new,
            .session_load,
            .session_resume,
            .session_close,
            .fx_turn_steer,
            .fx_turn_status,
            .fx_background_terminals_list,
            .fx_unified_exec_write_stdin,
            .fx_unified_exec_kill,
            .fx_provider_login_status,
            .fx_provider_setup_start,
            .fx_provider_setup_status,
            .fx_provider_login_submit_code,
            .fx_provider_login_cancel,
            .fx_provider_usage,
            .fx_tool_mode_set,
            => false,
            .session_list,
            .session_remove,
            .session_prompt,
            .session_set_config_option,
            .fx_provider_switch,
            .fx_provider_configure,
            .fx_provider_login_start,
            .unknown,
            => true,
        };
    }

    fn allowedDuringProviderJob(self: AcpMethod) bool {
        return switch (self) {
            .session_cancel,
            .fx_turn_status,
            .fx_background_terminals_list,
            .fx_unified_exec_write_stdin,
            .fx_unified_exec_kill,
            .fx_provider_login_status,
            .fx_provider_setup_status,
            .fx_provider_login_submit_code,
            .fx_provider_login_cancel,
            .fx_provider_usage,
            .fx_tool_mode_set,
            => true,
            else => false,
        };
    }
};

pub const Config = acp_runner.Config;

pub const OutboundKind = enum {
    permission,
    request,
};

pub const OutboundResponse = struct {
    result_json: ?[]u8 = null,
    error_json: ?[]u8 = null,
    cancelled: bool = false,

    pub fn deinit(self: *OutboundResponse, alloc: Allocator) void {
        if (self.result_json) |value| alloc.free(value);
        if (self.error_json) |value| alloc.free(value);
        self.* = undefined;
    }
};

const PendingOutbound = struct {
    kind: OutboundKind,
    response: ?OutboundResponse = null,
};

const max_pending_outbound = 32;

pub const ActiveSessionState = struct {
    session_id: []u8,
    store: ?session_store.Store = null,
    writable: ?session_store.LoadedWritableSession = null,
    wasm_state: ?session_codec.DurableSessionState = null,
    wasm_revision: ?[]u8 = null,
    session_write_mutex: std.Io.Mutex = .init,
    model: []u8,
    provider: model_provider.ProviderId = .gateway,
    mode: []const u8,
    workspace_root: []const u8,
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]const u8 = null,
    agent_step_limit: usize,
    max_tool_result_bytes: usize,
    fast_mode: bool,
    effort: types.ReasoningEffort,
    first_call_tool_choice: types.ToolChoice,
    permission_mode: types.PermissionMode,
    permission_rules: types.PermissionRuleSet,
    /// Runtime-only "allow for this session" grants. Never persisted to
    /// profile or project configuration.
    session_grants: []types.PermissionGrant = &.{},
    session_rt: session_runtime.SessionRuntime,
    cancel_flag: std.atomic.Value(bool),
    pending_prompt_id: ?jsonrpc.RequestId,
    image_snapshot_temp_dir: ?[]u8 = null,

    pub fn retainGrant(self: *ActiveSessionState, alloc: Allocator, tool_name: []const u8, target_path: []const u8) !void {
        for (self.session_grants) |grant| {
            if (std.mem.eql(u8, grant.tool_name, tool_name) and
                std.mem.eql(u8, grant.target_path, target_path)) return;
        }

        const name_copy = try alloc.dupe(u8, tool_name);
        errdefer alloc.free(name_copy);
        const target_copy = try alloc.dupe(u8, target_path);
        errdefer alloc.free(target_copy);
        const next = try alloc.alloc(types.PermissionGrant, self.session_grants.len + 1);
        errdefer alloc.free(next);
        if (self.session_grants.len > 0) {
            std.mem.copyForwards(types.PermissionGrant, next[0..self.session_grants.len], self.session_grants);
            alloc.free(self.session_grants);
        }
        next[next.len - 1] = .{ .tool_name = name_copy, .target_path = target_copy };
        self.session_grants = next;
    }
};

pub const ActivePrompt = struct {
    const PendingSteer = struct {
        prompt: []u8,

        fn deinit(self: *PendingSteer, alloc: Allocator) void {
            alloc.free(self.prompt);
            self.* = undefined;
        }
    };

    pub const SteerAdmission = enum {
        accepted,
        turn_not_ready,
        turn_mismatch,
        turn_finished,
    };

    pub const Snapshot = struct {
        turn_id: u64,
        accepting_steers: bool,
        pending_steers: usize,
    };

    state: *ServerState,
    alloc: Allocator,
    msg: jsonrpc.Message,
    /// Mode and permission policy captured when the prompt was dispatched.
    /// Mid-turn mode changes apply to the next prompt, never the running one.
    mode: []const u8,
    permission_mode: types.PermissionMode,
    /// Captured with the prompt so a mid-turn toggle applies only to the next turn.
    bash_first: bool = false,
    thread: if (host_target.is_wasm) void else std.Thread = if (host_target.is_wasm) {} else undefined,
    reapable: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    steer_mutex: std.Io.Mutex = .init,
    turn_id: u64 = 0,
    accepting_steers: bool = true,
    pending_steers: std.ArrayListUnmanaged(PendingSteer) = .empty,

    pub fn setTurnId(self: *ActivePrompt, turn_id: u64) void {
        self.steer_mutex.lockUncancelable(io_mod.getIo());
        defer self.steer_mutex.unlock(io_mod.getIo());
        self.turn_id = turn_id;
    }

    pub fn admitSteer(
        self: *ActivePrompt,
        expected_turn_id: u64,
        prompt: []const u8,
    ) !SteerAdmission {
        self.steer_mutex.lockUncancelable(io_mod.getIo());
        defer self.steer_mutex.unlock(io_mod.getIo());
        if (!self.accepting_steers) return .turn_finished;
        if (self.turn_id == 0) return .turn_not_ready;
        if (self.turn_id != expected_turn_id) return .turn_mismatch;
        const owned_prompt = try self.alloc.dupe(u8, prompt);
        errdefer self.alloc.free(owned_prompt);
        try self.pending_steers.append(self.alloc, .{ .prompt = owned_prompt });
        return .accepted;
    }

    pub fn takeSteer(
        self: *ActivePrompt,
        alloc: Allocator,
        turn_id: u64,
        finish_if_empty: bool,
    ) !?worker_runtime.QueuedPrompt {
        self.steer_mutex.lockUncancelable(io_mod.getIo());
        if (!self.accepting_steers or self.turn_id != turn_id) {
            self.steer_mutex.unlock(io_mod.getIo());
            return null;
        }
        if (self.pending_steers.items.len == 0) {
            if (finish_if_empty) self.accepting_steers = false;
            self.steer_mutex.unlock(io_mod.getIo());
            return null;
        }
        var pending = self.pending_steers.orderedRemove(0);
        self.steer_mutex.unlock(io_mod.getIo());
        defer pending.deinit(self.alloc);
        return try worker_runtime.initSteerPrompt(alloc, pending.prompt, &.{});
    }

    pub fn snapshot(self: *ActivePrompt) Snapshot {
        self.steer_mutex.lockUncancelable(io_mod.getIo());
        defer self.steer_mutex.unlock(io_mod.getIo());
        return .{
            .turn_id = self.turn_id,
            .accepting_steers = self.accepting_steers,
            .pending_steers = self.pending_steers.items.len,
        };
    }

    fn finish(self: *ActivePrompt) void {
        self.steer_mutex.lockUncancelable(io_mod.getIo());
        defer self.steer_mutex.unlock(io_mod.getIo());
        self.accepting_steers = false;
    }

    fn deinit(self: *ActivePrompt) void {
        for (self.pending_steers.items) |*pending| pending.deinit(self.alloc);
        self.pending_steers.deinit(self.alloc);
    }
};

pub const ServerState = struct {
    alloc: Allocator,
    cfg: Config,
    writer: jsonrpc.Writer,
    initialized: bool = false,
    client_fs_read: bool = false,
    client_fs_write: bool = false,
    client_terminal: bool = false,
    workspace_root: []u8 = &.{},
    workspace_access: workspace_access.WorkspaceAccess = .{},
    api_key: []u8 = &.{},
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]u8 = null,
    gateway_binding_mutex: std.Io.Mutex = .init,
    gateway_binding: ?GatewayConnectionBinding = null,
    selected_model: []u8 = &.{},
    provider: model_provider.ProviderId = .gateway,
    configured_model: []u8 = &.{},
    process_model_override: bool = false,
    permission_mode: types.PermissionMode = .ask,
    permission_rules: types.PermissionRuleSet = .{},
    agent_step_limit: usize = 0,
    max_tool_result_bytes: usize = 64 * 1024,
    context_limits: config_runtime.context_limits.Values = .{},
    fast_mode: bool = false,
    effort: types.ReasoningEffort = .auto,
    first_call_tool_choice: types.ToolChoice = .auto,
    context_enabled: bool = true,
    /// Connection/session-local tool projection preference.
    bash_first: bool = false,
    active_session: ?ActiveSessionState = null,
    active_prompt: ?*ActivePrompt = null,
    subagent_authority_mutex: std.Io.Mutex = .init,
    skills: skill_runtime.Runtime = .{},
    context_snapshot: context_contract.GatheredContextSnapshot = .{},
    worker: worker_runtime.WorkerRuntime = .{},
    terminal_client: terminal_client_runtime.Runtime = .{},
    unified_exec: unified_exec_runtime.Manager = unified_exec_runtime.Manager.init(std.heap.c_allocator),
    provider_job_thread: ?std.Thread = null,
    provider_job_running: std.atomic.Value(bool) = .init(false),
    provider_job_cancel: std.atomic.Value(bool) = .init(false),
    provider_login: login_flow.SignInRuntime = .{},
    provider_login_provider: ?provider_oauth.Provider = null,
    provider_setup: provider_setup.Runtime = provider_setup.Runtime.init(std.heap.c_allocator),
    subagent_store: ?session_store.Store = null,
    subagent_host: ?*subagent_tool_host.Runtime = null,
    capability_resolver: gateway_provider.CapabilityResolver = .{},
    terminate_connection: std.atomic.Value(bool) = .init(false),
    web_fetch_runtime: web_fetch_runtime.Runtime = web_fetch_runtime.Runtime.init(.{}),
    web_search_runtime: web_search_runtime.Runtime = web_search_runtime.Runtime.init(.{}),
    lifecycle_runtime: hooks.Runtime = hooks.Runtime.init(std.heap.c_allocator),
    lifecycle_view: hooks.RuntimeView = hooks.RuntimeView.empty(),
    outbound_mutex: std.Io.Mutex = .init,
    outbound_cond: std.Io.Condition = .init,
    next_outbound_request_id: u64 = 1,
    pending_outbound: std.AutoHashMapUnmanaged(u64, PendingOutbound) = .empty,
    account_usage: account_usage_runtime.Runtime = account_usage_runtime.Runtime.init(std.heap.c_allocator),

    pub fn deinit(self: *ServerState) void {
        reapActivePrompt(self, true);
        self.provider_job_cancel.store(true, .seq_cst);
        reapProviderJob(self, true);
        self.provider_login.deinit(self.alloc);
        self.provider_setup.deinit();
        self.terminal_client.deinit();
        closeActiveSession(self) catch |err| {
            debug_trace.logf(
                "session",
                "failed to flush ACP session usage during shutdown err={s}",
                .{@errorName(err)},
            );
        };
        self.unified_exec.deinit();
        self.workspace_access.deinit(self.alloc);
        if (self.workspace_root.len > 0) self.alloc.free(self.workspace_root);
        if (self.api_key.len > 0) secret.zeroAndFree(self.alloc, self.api_key);
        if (self.account_id) |account_id| self.alloc.free(account_id);
        self.gateway_binding_mutex.lockUncancelable(io_mod.getIo());
        if (self.gateway_binding) |*binding| binding.deinit(self.alloc);
        self.gateway_binding = null;
        self.gateway_binding_mutex.unlock(io_mod.getIo());
        if (self.selected_model.len > 0) self.alloc.free(self.selected_model);
        if (self.configured_model.len > 0) self.alloc.free(self.configured_model);
        self.permission_rules.deinit(self.alloc);
        self.skills.deinit(self.alloc);
        self.context_snapshot.deinit(self.alloc);
        self.worker.deinit(std.heap.c_allocator);
        self.web_fetch_runtime.deinit(self.alloc);
        self.web_search_runtime.deinit();
        self.lifecycle_runtime.deinit();
        self.capability_resolver.deinit(self.alloc);
        var pending = self.pending_outbound.valueIterator();
        while (pending.next()) |entry| {
            if (entry.response) |*response| response.deinit(self.alloc);
        }
        self.pending_outbound.deinit(self.alloc);
        self.account_usage.deinit();
    }
};

/// One custom Gateway route for this ACP connection. The endpoint pair and key
/// are owned together so switching temporarily to a subscription provider cannot
/// leave a custom origin paired with an unrelated credential. A successful
/// configure also persists that pair to the profile.
const GatewayConnectionBinding = struct {
    chat_url: []u8,
    models_url: []u8,
    credential: credentials.Credential,

    fn deinit(self: *GatewayConnectionBinding, alloc: Allocator) void {
        alloc.free(self.chat_url);
        alloc.free(self.models_url);
        self.credential.deinit(alloc);
        self.* = undefined;
    }
};

/// Turn-owned copy of the connection-scoped Gateway route. Background child
/// turns keep this snapshot until they finish, so reconfiguring the ACP
/// connection cannot free an endpoint or credential that a child still uses.
pub const GatewayRouteSnapshot = struct {
    chat_url: []u8,
    models_url: []u8,
    credential: credentials.Credential,

    pub fn deinit(self: *GatewayRouteSnapshot, alloc: Allocator) void {
        alloc.free(self.chat_url);
        alloc.free(self.models_url);
        self.credential.deinit(alloc);
        self.* = undefined;
    }
};

fn installStoredGatewayBinding(state: *ServerState) !void {
    if (state.gateway_binding != null or state.cfg.credential_override != null) return;
    var session = (if (state.cfg.home_override) |home|
        gateway_session.loadFromHome(state.alloc, home)
    else
        gateway_session.copyStoredBinding(state.alloc)) catch |err| {
        if (err == error.OutOfMemory) return err;
        debug_trace.logf("provider", "stored Gateway binding unavailable err={s}", .{@errorName(err)});
        return;
    } orelse return;
    defer session.deinit(state.alloc);
    const chat_url = provider_route.appendResponsesEndpointAlloc(state.alloc, session.base_url) catch |err| {
        debug_trace.logf("provider", "stored gateway binding chat url failed err={s}", .{@errorName(err)});
        return;
    };
    const models_url = provider_route.appendModelsEndpointAlloc(state.alloc, session.base_url) catch |err| {
        debug_trace.logf("provider", "stored gateway binding models url failed err={s}", .{@errorName(err)});
        state.alloc.free(chat_url);
        return;
    };
    var credential = cloneServerCredential(state.alloc, .{
        .token = session.api_key,
        .source = .openai_api_key,
    }) catch |err| {
        state.alloc.free(chat_url);
        state.alloc.free(models_url);
        return err;
    };
    state.gateway_binding_mutex.lockUncancelable(io_mod.getIo());
    defer state.gateway_binding_mutex.unlock(io_mod.getIo());
    if (state.gateway_binding != null) {
        state.alloc.free(chat_url);
        state.alloc.free(models_url);
        credential.deinit(state.alloc);
        return;
    }
    state.gateway_binding = .{
        .chat_url = chat_url,
        .models_url = models_url,
        .credential = credential,
    };
}

fn persistGatewayBinding(state: *ServerState, base_url: []const u8, api_key: []const u8) !void {
    if (state.cfg.home_override) |home| {
        try gateway_session.saveForHome(state.alloc, home, base_url, api_key);
    } else {
        try gateway_session.saveAndActivate(state.alloc, base_url, api_key);
    }
}

pub fn snapshotGatewayRoute(
    state: *ServerState,
    alloc: Allocator,
) !?GatewayRouteSnapshot {
    state.gateway_binding_mutex.lockUncancelable(io_mod.getIo());
    defer state.gateway_binding_mutex.unlock(io_mod.getIo());
    const binding = state.gateway_binding orelse return null;
    const chat_url = try alloc.dupe(u8, binding.chat_url);
    errdefer alloc.free(chat_url);
    const models_url = try alloc.dupe(u8, binding.models_url);
    errdefer alloc.free(models_url);
    const credential = try cloneServerCredential(alloc, binding.credential);
    return .{
        .chat_url = chat_url,
        .models_url = models_url,
        .credential = credential,
    };
}

pub fn gatewayChatUrl(state: *const ServerState) []const u8 {
    return if (state.gateway_binding) |binding|
        binding.chat_url
    else
        state.cfg.gateway_chat_url;
}

pub fn gatewayModelsPath(state: *const ServerState) []const u8 {
    return if (state.gateway_binding) |binding|
        binding.models_url
    else
        state.cfg.gateway_models_path;
}

pub fn providerEndpointOverride(
    state: *const ServerState,
    provider: model_provider.ProviderId,
) ?[]const u8 {
    if (provider != .gateway) return null;
    return if (state.gateway_binding) |binding| binding.chat_url else null;
}

fn providerCatalogEndpoint(
    state: *const ServerState,
    provider: model_provider.ProviderId,
) []const u8 {
    if (provider == .gateway) return gatewayModelsPath(state);
    return state.cfg.gateway_models_path;
}

fn credentialMatchesProvider(
    source: ?types.CredentialSource,
    provider: model_provider.ProviderId,
) bool {
    return model_provider.authorizesCredential(provider, source);
}

fn borrowedCredentialForProvider(
    state: *ServerState,
    provider: model_provider.ProviderId,
) ?credentials.Credential {
    if (provider == .gateway) {
        if (state.gateway_binding) |*binding| return .{
            .token = binding.credential.token,
            .source = binding.credential.source,
            .account_id = binding.credential.account_id,
        };
    }
    if (state.api_key.len == 0 or
        !credentialMatchesProvider(state.credential_source, provider)) return null;
    return .{
        .token = state.api_key,
        .source = state.credential_source.?,
        .account_id = state.account_id,
    };
}

fn adoptServerCredential(state: *ServerState, credential: *credentials.Credential) void {
    if (state.active_session) |*active| active.api_key = &.{};
    if (state.api_key.len > 0) secret.zeroAndFree(state.alloc, state.api_key);
    if (state.account_id) |account_id| state.alloc.free(account_id);

    state.api_key = credential.token;
    credential.token = &.{};
    state.credential_source = credential.source;
    state.account_id = credential.account_id;
    credential.account_id = null;
    if (state.active_session) |*active| {
        active.api_key = state.api_key;
        active.credential_source = state.credential_source;
        active.account_id = state.account_id;
    }
    startAccountUsageRefresh(state, true);
}

/// Ensures the process and active ACP session use a credential authorized for
/// the final model route. Returns false when that route has no credential.
pub fn selectCredentialForProvider(
    state: *ServerState,
    provider: model_provider.ProviderId,
) !bool {
    if (provider == .gateway and state.gateway_binding != null) {
        var connection_credential = try cloneServerCredential(
            state.alloc,
            state.gateway_binding.?.credential,
        );
        defer connection_credential.deinit(state.alloc);
        adoptServerCredential(state, &connection_credential);
        return true;
    }
    if (state.active_session) |active| {
        if (credentialMatchesProvider(active.credential_source, provider)) return true;
    }
    if (credentialMatchesProvider(state.credential_source, provider) and state.api_key.len > 0) return true;

    var credential = if (provider == .gateway and state.cfg.credential_override != null)
        credentials.Credential{
            .token = try state.alloc.dupe(u8, state.cfg.credential_override.?.token),
            .source = state.cfg.credential_override.?.source,
        }
    else blk: {
        const resolution = try credentials.resolveForProvider(
            state.alloc,
            state.cfg.gateway_provider.oauth_transport,
            state.cfg.secret_store,
            .refresh_if_needed,
            provider,
            state.credential_source,
        );
        break :blk resolution.credential orelse return false;
    };
    defer credential.deinit(state.alloc);
    adoptServerCredential(state, &credential);
    return true;
}

pub fn streamProviderFor(
    state: *const ServerState,
    provider: model_provider.ProviderId,
) @import("../core/agent/stream_provider.zig").Provider {
    return state.cfg.provider_set.select(provider).agent_stream_or_unavailable();
}

pub fn catalogProviderFor(
    state: *const ServerState,
    provider: model_provider.ProviderId,
) ?@import("../core/gateway/model_catalog.zig").Provider {
    return state.cfg.provider_set.select(provider).model_catalog;
}

pub fn refreshModelCredential(
    raw: *anyopaque,
    alloc: Allocator,
    source: types.CredentialSource,
    mode: auth_runtime.CredentialRefreshMode,
    expected_account_id: ?[]const u8,
) !?[]u8 {
    const state: *ServerState = @ptrCast(@alignCast(raw));
    const refreshed = try auth_runtime.refreshCredentialTokenForAccount(
        state.cfg.gateway_provider.oauth_transport,
        alloc,
        source,
        mode,
        expected_account_id,
    ) orelse return null;
    errdefer secret.zeroAndFree(alloc, refreshed);
    if (source == .chatgpt_subscription or source == .grok_subscription) {
        try publishRefreshedSubscriptionToken(state, refreshed, source, expected_account_id);
    }
    return refreshed;
}

fn publishRefreshedSubscriptionToken(
    state: *ServerState,
    refreshed: []const u8,
    source: types.CredentialSource,
    expected_account_id: ?[]const u8,
) !void {
    const expected = expected_account_id orelse return error.ChatGptAccountChanged;
    const state_account = state.account_id orelse return error.ChatGptAccountChanged;
    if (!std.mem.eql(u8, expected, state_account)) return error.ChatGptAccountChanged;
    if (state.active_session) |active| {
        const active_account = active.account_id orelse return error.ChatGptAccountChanged;
        if (!std.mem.eql(u8, expected, active_account)) return error.ChatGptAccountChanged;
    }

    const owned = try state.alloc.dupe(u8, refreshed);
    if (state.active_session) |*active| active.api_key = &.{};
    if (state.api_key.len > 0) secret.zeroAndFree(state.alloc, state.api_key);
    state.api_key = owned;
    state.credential_source = source;
    if (state.active_session) |*active| {
        active.api_key = state.api_key;
        active.credential_source = source;
    }
    startAccountUsageRefresh(state, true);
}

fn startAccountUsageRefresh(state: *ServerState, force: bool) void {
    if (comptime host_target.is_wasm) return;
    const source = state.credential_source orelse {
        state.account_usage.clear();
        return;
    };
    const account_usage = switch (source) {
        .chatgpt_subscription => state.cfg.provider_set.codex.account_usage,
        .grok_subscription => state.cfg.provider_set.grok.account_usage,
        else => {
            state.account_usage.clear();
            return;
        },
    } orelse {
        state.account_usage.clear();
        return;
    };
    if (state.api_key.len == 0) return;
    const account_id = state.account_id orelse return;
    _ = state.account_usage.requestRefresh(
        account_usage,
        state.cfg.gateway_provider.oauth_transport,
        state.api_key,
        account_id,
        source,
        io_mod.milliTimestamp(),
        force,
    ) catch |err| {
        debug_trace.logf("account_usage", "acp refresh start failed err={s}", .{@errorName(err)});
    };
}

pub fn releaseActiveSession(state: *ServerState) !void {
    const active = if (state.active_session) |*session| session else return;
    disableSubagentHost(state);
    if (comptime !host_target.is_wasm) {
        active.session_rt.usage.finishProfilePublicationsBeforeShutdown();
        flushActiveSessionUsage(state) catch |err| return err;
        active.session_rt.usage.configurePublicationSink(null);
        active.session_rt.usage.configureCheckpointSink(null);
    }
    destroyActiveSession(state);
}

fn closeActiveSession(state: *ServerState) !void {
    const active = if (state.active_session) |*session| session else return;
    disableSubagentHost(state);
    if (comptime !host_target.is_wasm) {
        active.session_rt.usage.finishProfilePublicationsBeforeShutdown();
        flushActiveSessionUsage(state) catch |err| {
            destroyActiveSession(state);
            return err;
        };
        active.session_rt.usage.configurePublicationSink(null);
        active.session_rt.usage.configureCheckpointSink(null);
    }
    destroyActiveSession(state);
}

fn destroyActiveSession(state: *ServerState) void {
    const active = if (state.active_session) |*session| session else return;
    // Unified Exec IDs are scoped to the active ACP session. Stop any yielded
    // process before releasing the session so an old client handle cannot
    // reach a process after a session switch.
    state.unified_exec.terminateAll();
    state.alloc.free(active.session_id);
    state.alloc.free(active.model);
    types.freePermissionGrantSlice(state.alloc, active.session_grants);
    active.session_rt.deinit(state.alloc);
    if (active.writable) |*writable| writable.deinit(state.alloc);
    if (active.store) |*store| store.deinit(state.alloc);
    if (active.wasm_state) |*wasm_state| wasm_state.deinit(state.alloc);
    if (active.wasm_revision) |revision| state.alloc.free(revision);
    if (active.image_snapshot_temp_dir) |dir| {
        image_attachments.cleanupSnapshotDir(dir);
        state.alloc.free(dir);
    }
    state.active_session = null;
}

pub fn enableSubagentHost(state: *ServerState) void {
    disableSubagentHost(state);
    const active = if (state.active_session) |*session| session else return;
    if (active.writable == null) return;
    state.subagent_store = session_store.Store.init(state.alloc, state.workspace_root) catch |err| {
        debug_trace.logf("acp", "subagent host store unavailable session={s} err={s}", .{ active.session_id, @errorName(err) });
        return;
    };
    state.subagent_host = subagent_tool_host.Runtime.create(
        state.alloc,
        &state.subagent_store.?,
        active.session_id,
        .{ .context = state, .resolve_fn = resolveSubagentAuthority },
        .{ .context = state, .run_fn = prompt_handler.runSubagentChild },
    ) catch |err| {
        debug_trace.logf("acp", "subagent host unavailable session={s} err={s}", .{ active.session_id, @errorName(err) });
        state.subagent_store.?.deinit(state.alloc);
        state.subagent_store = null;
        return;
    };
    state.subagent_host.?.requestBackgroundRecovery(
        io_mod.milliTimestamp(),
    ) catch |err| {
        debug_trace.logf(
            "subagent",
            "acp background recovery unavailable root_id={s} outcome={s}",
            .{ state.subagent_host.?.root_id, @errorName(err) },
        );
    };
}

fn resolveSubagentAuthority(
    raw: ?*anyopaque,
    alloc: Allocator,
    root_id: []const u8,
) subagent_authority.HostResolveError!subagent_authority.HostAuthority {
    const state: *ServerState = @ptrCast(@alignCast(raw.?));
    const active = if (state.active_session) |*value| value else return error.HostAuthorityUnavailable;
    if (!std.mem.eql(u8, active.session_id, root_id)) {
        return error.HostAuthorityUnavailable;
    }
    state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
    defer state.subagent_authority_mutex.unlock(io_mod.getIo());
    var permission_state = active.session_rt.snapshotPermissionState(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.HostAuthorityUnavailable,
    };
    defer permission_state.deinit(alloc);
    return subagent_tool_host.captureHostAuthorityWithPermissionState(
        alloc,
        .{
            .tool_set = builtin_tools.advertisement_set,
            .mode = .{
                .active = .{
                    .registry = state.cfg.mode_registry,
                    .id = active.mode,
                },
            },
        },
        active.permission_rules,
        active.session_grants,
        permission_state,
    );
}

pub fn disableSubagentHost(state: *ServerState) void {
    if (state.subagent_host) |host| {
        host.deinit();
        state.subagent_host = null;
    }
    if (state.subagent_store) |*store| {
        store.deinit(state.alloc);
        state.subagent_store = null;
    }
}

fn flushActiveSessionUsage(state: *ServerState) !void {
    const active = if (state.active_session) |*session| session else return;
    const writable = if (active.writable) |*value| value else return;
    if (!writable.needsFinalStateReplacement(
        active.session_rt.usage.isDirty(),
    )) return;

    var current = try writable.state.dupe(state.alloc);
    defer current.deinit(state.alloc);
    const history = try active.session_rt.snapshotHistory(state.alloc);
    types.freeHistoryTurnSlice(state.alloc, current.history);
    current.history = history;
    const permission_state = try active.session_rt.snapshotPermissionState(state.alloc);
    current.permission_state.deinit(state.alloc);
    current.permission_state = permission_state;
    current.conversation_language = active.session_rt.languageSnapshot();
    const usage_snapshot = try active.session_rt.usage.snapshot(state.alloc);
    if (current.usage) |*old| old.deinit(state.alloc);
    current.usage = usage_snapshot;
    const store = if (active.store) |*value|
        value
    else
        return error.SessionPersistenceUnavailable;
    const recovery_checkpoint = try store.prepareUsageRecoveryCheckpoint(
        state.alloc,
        writable,
        usage_snapshot,
    );
    current.updated_at_ms = recovery_checkpoint.timestamp_ms;
    _ = try writable.commitStateReplacement(
        state.alloc,
        current,
        .compaction,
        .retry_expected_tail,
        .{},
    );
    try store.finishUsageRecoveryCheckpoint(
        writable.active_id,
        recovery_checkpoint,
    );
    if (current.usage) |usage| {
        active.session_rt.usage.markClean(usage);
    }
}

pub fn run(alloc: Allocator, cfg: Config) !void {
    return runWithTransport(alloc, cfg, jsonrpc.Reader.init(), jsonrpc.Writer.init());
}

pub fn runWithTransport(
    alloc: Allocator,
    cfg: Config,
    reader_value: jsonrpc.Reader,
    writer_value: jsonrpc.Writer,
) !void {
    if (cfg.log_file) |path| {
        try debug_trace.configure(.{ .file_path = path });
    }

    var lifecycle_runtime = hooks.Runtime.init(alloc);
    const lifecycle_view = lifecycle_runtime.freeze();
    var state = ServerState{
        .alloc = alloc,
        .cfg = cfg,
        .writer = writer_value,
        .web_search_runtime = web_search_runtime.Runtime.init(.{}),
        .terminal_client = terminal_client_runtime.Runtime.init(
            cfg.background_process_provider,
        ),
        .lifecycle_runtime = lifecycle_runtime,
        .lifecycle_view = lifecycle_view,
    };
    defer state.deinit();

    var reader = reader_value;
    while (!state.terminate_connection.load(.acquire)) {
        reapActivePrompt(&state, false);
        reapProviderJob(&state, false);
        const line_result = reader.readLine(alloc) catch break;
        if (line_result == null) break;
        const line = switch (line_result.?) {
            .overflow => {
                state.writer.writeError(alloc, null, .{
                    .code = ErrorCode.request_frame_too_large,
                    .message = "Request frame too large",
                }) catch break;
                continue;
            },
            .line => |value| value,
        };
        defer alloc.free(line);
        // A background provider commit can discover an indeterminate durable
        // tail while this thread is blocked in readLine. Discard the wake-up
        // frame instead of dispatching one more request on uncertain state.
        if (state.terminate_connection.load(.acquire)) break;

        var msg = jsonrpc.parseMessage(alloc, line) catch |err| {
            const code = switch (err) {
                error.ParseError => ErrorCode.parse_error,
                else => ErrorCode.invalid_request,
            };
            state.writer.writeError(alloc, null, .{ .code = code, .message = "Parse error" }) catch break;
            continue;
        };
        defer jsonrpc.freeMessage(alloc, &msg);

        if (msg.isResponse()) {
            handleClientResponse(&state, alloc, &msg);
            continue;
        }

        if (!shouldRespondToMessage(&msg)) {
            dispatchNotification(&state, alloc, &msg) catch {};
            if (state.terminate_connection.load(.acquire)) break;
            continue;
        }

        dispatch(&state, alloc, &msg) catch |err| {
            state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.internal_error,
                .message = @errorName(err),
            }) catch break;
        };
        if (state.terminate_connection.load(.acquire)) break;
    }
    // Release any prompt thread parked on a pending approval before
    // state.deinit() joins it, or shutdown deadlocks.
    handleCancel(&state);
}

fn shouldRespondToMessage(msg: *const jsonrpc.Message) bool {
    return !msg.isResponse() and msg.id != null;
}

fn handleClientResponse(state: *ServerState, alloc: Allocator, msg: *const jsonrpc.Message) void {
    const id = msg.id orelse return;
    const numeric_id: u64 = switch (id) {
        .integer => |value| if (value > 0) @intCast(value) else return,
        else => return,
    };
    const result_copy = if (msg.result_raw) |raw| alloc.dupe(u8, raw) catch return else null;
    const error_copy = if (msg.error_raw) |raw| alloc.dupe(u8, raw) catch {
        if (result_copy) |value| alloc.free(value);
        return;
    } else null;

    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    defer state.outbound_mutex.unlock(io_mod.getIo());
    const pending = state.pending_outbound.getPtr(numeric_id) orelse {
        if (result_copy) |value| alloc.free(value);
        if (error_copy) |value| alloc.free(value);
        return;
    };
    if (pending.response != null) {
        if (result_copy) |value| alloc.free(value);
        if (error_copy) |value| alloc.free(value);
        return;
    }
    pending.response = .{
        .result_json = result_copy,
        .error_json = error_copy,
    };
    state.outbound_cond.broadcast(io_mod.getIo());
}

fn parsePermissionDecision(root: std.json.Value) ?types.ToolPermissionDecision {
    if (root != .object) return null;
    const outcome = root.object.get("outcome") orelse return null;
    if (outcome != .object) return null;
    const kind = outcome.object.get("outcome") orelse return null;
    if (kind != .string) return null;
    if (std.mem.eql(u8, kind.string, "cancelled")) return .deny;
    if (!std.mem.eql(u8, kind.string, "selected")) return null;
    const option = outcome.object.get("optionId") orelse return null;
    if (option != .string) return null;
    if (std.mem.eql(u8, option.string, "allow_once")) return .once;
    if (std.mem.eql(u8, option.string, "allow_always")) return .always;
    if (std.mem.eql(u8, option.string, "reject_once")) return .deny;
    return null;
}

pub fn beginOutboundRequest(state: *ServerState, kind: OutboundKind) !?u64 {
    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    defer state.outbound_mutex.unlock(io_mod.getIo());
    if (state.pending_outbound.count() >= max_pending_outbound or
        state.next_outbound_request_id > @as(u64, @intCast(std.math.maxInt(i64))))
    {
        return null;
    }
    const id = state.next_outbound_request_id;
    state.next_outbound_request_id += 1;
    try state.pending_outbound.put(state.alloc, id, .{ .kind = kind });
    return id;
}

pub fn awaitOutboundResponse(state: *ServerState, id: u64, kind: OutboundKind) ?OutboundResponse {
    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    defer state.outbound_mutex.unlock(io_mod.getIo());
    while (true) {
        const pending = state.pending_outbound.getPtr(id) orelse return null;
        if (pending.kind != kind) return null;
        if (pending.response) |response| {
            _ = state.pending_outbound.remove(id);
            return response;
        }
        state.outbound_cond.wait(io_mod.getIo(), &state.outbound_mutex) catch {
            cancelOutboundRequestLocked(state, id);
        };
    }
}

pub fn cancelOutboundRequest(state: *ServerState, id: u64) void {
    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    defer state.outbound_mutex.unlock(io_mod.getIo());
    cancelOutboundRequestLocked(state, id);
}

fn cancelOutboundRequestLocked(state: *ServerState, id: u64) void {
    const pending = state.pending_outbound.getPtr(id) orelse return;
    if (pending.response != null) return;
    pending.response = .{ .cancelled = true };
    state.outbound_cond.broadcast(io_mod.getIo());
}

fn cancelPendingOutbound(state: *ServerState) void {
    state.outbound_mutex.lockUncancelable(io_mod.getIo());
    defer state.outbound_mutex.unlock(io_mod.getIo());
    var pending = state.pending_outbound.valueIterator();
    while (pending.next()) |entry| {
        if (entry.response == null) entry.response = .{ .cancelled = true };
    }
    state.outbound_cond.broadcast(io_mod.getIo());
}

pub fn beginPermissionRequest(state: *ServerState) ?u64 {
    return beginOutboundRequest(state, .permission) catch null;
}

pub fn awaitPermissionDecision(state: *ServerState, id: u64) types.ToolPermissionDecision {
    var response = awaitOutboundResponse(state, id, .permission) orelse return .deny;
    defer response.deinit(state.alloc);
    if (response.cancelled or response.error_json != null) return .deny;
    const raw = response.result_json orelse return .deny;
    const parsed = std.json.parseFromSlice(std.json.Value, state.alloc, raw, .{}) catch return .deny;
    defer parsed.deinit();
    return parsePermissionDecision(parsed.value) orelse .deny;
}

pub fn cancelPermissionRequest(state: *ServerState, id: u64) void {
    cancelOutboundRequest(state, id);
}

fn dispatchNotification(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    _ = alloc;
    reapActivePrompt(state, false);
    if (!state.initialized) return;
    switch (AcpMethod.parse(msg.method)) {
        .session_cancel => handleCancel(state),
        else => {},
    }
}

fn dispatch(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    if (state.terminate_connection.load(.acquire)) return;
    reapActivePrompt(state, false);
    reapProviderJob(state, false);
    const method = AcpMethod.parse(msg.method);

    if (method == .initialize) {
        return handleInitialize(state, alloc, msg);
    }

    if (!state.initialized) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Not initialized. Call initialize first.",
        });
    }

    if (method == .session_cancel) {
        handleCancel(state);
        return state.writer.writeResponse(alloc, msg.id, "null");
    }

    if (state.provider_job_running.load(.seq_cst) and !method.allowedDuringProviderJob()) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Provider operation already in progress",
        });
    }
    if (state.provider_setup.isRunning() and !method.allowedDuringProviderJob()) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Provider setup already in progress",
        });
    }

    if (method == .session_prompt and
        try prompt_handler.isProcessStatusPrompt(alloc, msg.params_raw))
    {
        return prompt_handler.handleProcessStatusPrompt(state, alloc, msg);
    }

    if (method.waitsForActivePrompt() and state.active_prompt != null) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Prompt already in progress",
        });
    }

    if (comptime host_target.is_wasm) {
        return switch (method) {
            .session_new => sessions.handleNewWasmSession(state, alloc, msg),
            .session_load => sessions.handleLoadWasmSession(state, alloc, msg),
            .session_list => sessions.handleListWasmSessions(state, alloc, msg),
            .session_remove => sessions.handleRemoveWasmSession(state, alloc, msg),
            .session_prompt => startPrompt(state, alloc, msg),
            .session_set_config_option => handleSetConfigOption(state, alloc, msg),
            .session_set_mode => handleSetMode(state, alloc, msg),
            .fx_tool_mode_set => handleToolModeSet(state, alloc, msg),
            .fx_turn_status => prompt_handler.handleTurnStatus(state, alloc, msg),
            .fx_background_terminals_list => prompt_handler.handleBackgroundTerminalsList(state, alloc, msg),
            else => state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.method_not_found,
                .message = "Method not available in the web core yet",
            }),
        };
    }

    return switch (method) {
        .session_new => sessions.handleNewSession(state, alloc, msg),
        .session_load => sessions.handleLoadSession(state, alloc, msg),
        .session_resume => sessions.handleResumeSession(state, alloc, msg),
        .session_close => handleCloseSession(state, alloc, msg),
        .session_list => sessions.handleListSessions(state, alloc, msg),
        .session_prompt => startPrompt(state, alloc, msg),
        .session_set_config_option => handleSetConfigOption(state, alloc, msg),
        .session_set_mode => handleSetMode(state, alloc, msg),
        .fx_turn_steer => prompt_handler.handleTurnSteer(state, alloc, msg),
        .fx_turn_status => prompt_handler.handleTurnStatus(state, alloc, msg),
        .fx_background_terminals_list => prompt_handler.handleBackgroundTerminalsList(state, alloc, msg),
        .fx_unified_exec_write_stdin => prompt_handler.handleUnifiedExecWriteStdin(state, alloc, msg),
        .fx_unified_exec_kill => prompt_handler.handleUnifiedExecKill(state, alloc, msg),
        .fx_provider_switch => handleProviderSwitch(state, alloc, msg),
        .fx_provider_configure => handleProviderConfigure(state, alloc, msg),
        .fx_provider_setup_start => handleProviderSetupStart(state, alloc, msg),
        .fx_provider_setup_status => handleProviderSetupStatus(state, alloc, msg),
        .fx_provider_login_start => handleProviderLoginStart(state, alloc, msg),
        .fx_provider_login_status => handleProviderLoginStatus(state, alloc, msg),
        .fx_provider_login_submit_code => handleProviderLoginSubmitCode(state, alloc, msg),
        .fx_provider_login_cancel => handleProviderLoginCancel(state, alloc, msg),
        .fx_provider_usage => handleProviderUsage(state, alloc, msg),
        .fx_tool_mode_set => handleToolModeSet(state, alloc, msg),
        .initialize,
        .session_cancel,
        .session_remove,
        .unknown,
        => state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.method_not_found,
            .message = "Method not found",
        }),
    };
}

fn startPrompt(state: *ServerState, alloc: Allocator, msg: *const jsonrpc.Message) !void {
    const session = if (state.active_session) |*active| active else return state.writer.writeError(alloc, msg.id, prompt_handler.no_active_session_rpc_error);
    const active = try alloc.create(ActivePrompt);
    errdefer alloc.destroy(active);
    active.* = .{
        .state = state,
        .alloc = alloc,
        .msg = try cloneMessage(alloc, msg),
        .mode = session.mode,
        .permission_mode = session.permission_mode,
        .bash_first = state.bash_first,
    };
    errdefer jsonrpc.freeMessage(alloc, &active.msg);

    session.cancel_flag.store(false, .seq_cst);
    if (comptime host_target.is_wasm) {
        promptWorkerMain(active);
        active.deinit();
        jsonrpc.freeMessage(active.alloc, &active.msg);
        active.alloc.destroy(active);
    } else {
        state.active_prompt = active;
        errdefer state.active_prompt = null;
        active.thread = try std.Thread.spawn(.{}, promptWorkerMain, .{active});
    }
}

fn promptWorkerMain(active: *ActivePrompt) void {
    const outcome: prompt_handler.TerminalOutcome = prompt_handler.handlePrompt(
        active.state,
        active.alloc,
        &active.msg,
        active.mode,
        active.permission_mode,
        active.bash_first,
    ) catch |err| .{
        .rpc_error = .{
            .code = ErrorCode.internal_error,
            .message = @errorName(err),
        },
    };
    active.finish();
    active.reapable.store(true, .seq_cst);
    publishPromptOutcome(active, outcome) catch {};
    prompt_test_controls.pauseAfterTerminalWrite();
}

fn publishPromptOutcome(active: *ActivePrompt, outcome: prompt_handler.TerminalOutcome) !void {
    switch (outcome) {
        .stop_reason => |stop_reason| {
            var response: std.Io.Writer.Allocating = .init(active.alloc);
            defer response.deinit();
            try acp_types.writePromptResponse(&response.writer, stop_reason);
            try active.state.writer.writeResponse(active.alloc, active.msg.id, response.writer.buffered());
        },
        .rpc_error => |rpc_error| {
            try active.state.writer.writeError(active.alloc, active.msg.id, rpc_error);
        },
    }
}

fn reapActivePrompt(state: *ServerState, wait: bool) void {
    if (!host_target.is_wasm) {
        const active = state.active_prompt orelse return;
        if (!wait and !active.reapable.load(.seq_cst)) return;
        prompt_test_controls.noteReapBeforeJoin();
        active.thread.join();
        active.deinit();
        jsonrpc.freeMessage(active.alloc, &active.msg);
        active.alloc.destroy(active);
        state.active_prompt = null;
    }
}

fn cloneMessage(alloc: Allocator, msg: *const jsonrpc.Message) !jsonrpc.Message {
    var copy = jsonrpc.Message{
        .method = try alloc.dupe(u8, msg.method),
    };
    errdefer jsonrpc.freeMessage(alloc, &copy);
    if (msg.params_raw) |params| copy.params_raw = try alloc.dupe(u8, params);
    if (msg.id) |id| {
        copy.id = switch (id) {
            .integer => |value| .{ .integer = value },
            .string => |value| .{ .string = try alloc.dupe(u8, value) },
            .null => .null,
        };
    }
    return copy;
}

const InitializeRequest = struct {
    client_fs_read: bool = false,
    client_fs_write: bool = false,
    client_terminal: bool = false,
};

fn parseInitializeRequest(
    alloc: Allocator,
    params: ?[]const u8,
) !InitializeRequest {
    const raw = params orelse return error.InvalidInitializeParams;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch
        return error.InvalidInitializeParams;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidInitializeParams;

    const version = parsed.value.object.get("protocolVersion") orelse
        return error.InvalidInitializeParams;
    if (version != .integer) return error.InvalidInitializeParams;
    if (version.integer < 0 or version.integer > std.math.maxInt(u16))
        return error.InvalidInitializeParams;

    var request = InitializeRequest{};
    const capabilities = parsed.value.object.get("clientCapabilities") orelse
        return request;
    if (capabilities != .object) return request;
    if (capabilities.object.get("fs")) |fs| {
        if (fs == .object) {
            if (fs.object.get("readTextFile")) |value| {
                request.client_fs_read = value == .bool and value.bool;
            }
            if (fs.object.get("writeTextFile")) |value| {
                request.client_fs_write = value == .bool and value.bool;
            }
        }
    }
    if (capabilities.object.get("terminal")) |value| {
        request.client_terminal = value == .bool and value.bool;
    }
    return request;
}

fn loadConfiguredStartupState(state: *const ServerState, alloc: Allocator) !app_lifecycle.StartupState {
    if (state.cfg.home_override) |home_dir| {
        if (state.cfg.workspace_root_override) |workspace_root| {
            return app_lifecycle.loadEmbeddedStartupState(
                alloc,
                home_dir,
                workspace_root,
                state.cfg.default_model,
                state.cfg.default_agent_step_limit,
            );
        }
    }
    return app_lifecycle.loadStartupState(
        alloc,
        state.cfg.gateway_provider.oauth_transport,
        state.cfg.secret_store,
        state.cfg.default_model,
        state.cfg.default_agent_step_limit,
    );
}

fn handleInitialize(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    if (state.initialized) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Already initialized",
        });
    }

    const request = parseInitializeRequest(alloc, msg.params_raw) catch {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid initialize params",
        });
    };

    var startup = loadConfiguredStartupState(state, alloc) catch {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to load startup state",
        });
    };
    defer startup.deinit(alloc);
    try app_lifecycle.applyWorkspaceLaunch(
        &startup,
        alloc,
        state.cfg.additional_directories,
        state.cfg.saved_directories_suppressed,
    );
    for (startup.config_diagnostics) |diagnostic| {
        if (diagnostic.recovery_path != null) {
            debug_trace.logf("config", "acp startup diagnostic layer={s} cause={s} recovery_available=true", .{
                @tagName(diagnostic.layer),
                @tagName(diagnostic.cause),
            });
        } else {
            debug_trace.logf("config", "acp startup diagnostic layer={s} cause={s}", .{
                @tagName(diagnostic.layer),
                @tagName(diagnostic.cause),
            });
        }
    }

    state.workspace_root = startup.takeWorkspaceRoot();
    state.workspace_access = startup.takeWorkspaceAccess();

    if (state.cfg.model_override) |override| {
        state.selected_model = try alloc.dupe(u8, override);
        alloc.free(startup.takeSelectedModel());
        state.process_model_override = true;
    } else {
        state.selected_model = startup.takeSelectedModel();
        state.process_model_override = startup.model_source == .process_override;
    }
    state.provider = state.cfg.provider_override orelse startup.provider;
    state.configured_model = try alloc.dupe(u8, startup.configured_model);
    try installStoredGatewayBinding(state);

    var startup_credential = startup.takeCredential();
    defer if (startup_credential) |*credential| credential.deinit(alloc);
    var routed_credential: ?credentials.Credential = null;
    defer if (routed_credential) |*credential| credential.deinit(alloc);
    const startup_matches_model = if (startup_credential) |credential|
        credentialMatchesProvider(credential.source, state.provider)
    else
        false;
    const credential: ?*credentials.Credential = if (state.provider == .gateway and state.cfg.credential_override != null) override: {
        routed_credential = .{
            .token = try alloc.dupe(u8, state.cfg.credential_override.?.token),
            .source = state.cfg.credential_override.?.source,
        };
        break :override &routed_credential.?;
    } else if (state.provider == .gateway and state.gateway_binding != null) binding: {
        routed_credential = try cloneServerCredential(alloc, state.gateway_binding.?.credential);
        break :binding &routed_credential.?;
    } else if (startup_matches_model)
        &startup_credential.?
    else routed: {
        const preferred = if (startup_credential) |value| value.source else null;
        const resolution = try credentials.resolveForProvider(
            alloc,
            state.cfg.gateway_provider.oauth_transport,
            state.cfg.secret_store,
            .refresh_if_needed,
            state.provider,
            preferred,
        );
        routed_credential = resolution.credential;
        break :routed if (routed_credential != null) &routed_credential.? else null;
    };
    if (credential) |resolved| {
        if (resolved.token.len > 0) adoptServerCredential(state, resolved);
    }

    state.permission_mode = startup.permission_mode;
    state.permission_rules = startup.takePermissionRules();
    state.agent_step_limit = startup.agent_step_limit;
    state.max_tool_result_bytes = startup.max_tool_result_bytes;
    state.context_limits = startup.context_limits;
    state.context_limits.applyCommandLine(state.cfg.context_limit_overrides);
    state.fast_mode = startup.fast_mode and
        (state.cfg.model_override == null or startup.fast_mode_source != .compiled_default);
    state.effort = startup.effort;
    state.first_call_tool_choice = startup.first_call_tool_choice;
    state.context_enabled = startup.context_enabled;

    if (comptime !host_target.is_wasm) {
        var loaded_skills = try app_runtime_setup.loadSkills(alloc, state.workspace_root, builtin_skills.root_policy);
        errdefer loaded_skills.deinit(alloc);
        skill_runtime.traceDiagnostics("acp_startup", loaded_skills.diagnostics);
        try state.skills.replaceLoaded(alloc, loaded_skills.dir, loaded_skills.skills, loaded_skills.diagnostics);
        loaded_skills = .{};
    }

    if (state.api_key.len > 0) {
        var catalog_cancel_flag = std.atomic.Value(bool).init(false);
        const startup_catalog = catalogProviderFor(state, state.provider) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_request,
                .message = "Selected provider is unavailable in this host",
            });
        _ = try state.capability_resolver.resolve(
            state.alloc,
            startup_catalog,
            .{
                .access = credentials.catalogAccessForCredentialAndAccount(
                    state.credential_source,
                    state.api_key,
                    state.account_id,
                ),
                .endpoint = providerCatalogEndpoint(state, state.provider),
                .cancel_flag = &catalog_cancel_flag,
            },
            state.selected_model,
            state.cfg.provider_set.select(state.provider).fallbackModelCapabilities(state.selected_model),
        );
    }

    state.client_fs_read = request.client_fs_read;
    state.client_fs_write = request.client_fs_write;
    state.client_terminal = request.client_terminal;
    state.initialized = true;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try acp_types.writeInitializeResponseWithOptions(
        &out.writer,
        .{
            .image_capable = !host_target.is_wasm,
            .unified_exec_capable = unified_exec_runtime.Manager.supported(),
            .provider_control_capable = !host_target.is_wasm,
        },
    );
    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());
}

fn handleCancel(state: *ServerState) void {
    state.provider_job_cancel.store(true, .seq_cst);
    if (state.active_session) |*session| {
        debug_trace.eventf("interrupt", "cancel_requested", .{}, "source=acp active_tool_known=false", .{});
        session.cancel_flag.store(true, .seq_cst);
    }
    cancelPendingOutbound(state);
}

pub fn cancelAndReapActivePrompt(state: *ServerState) void {
    handleCancel(state);
    reapActivePrompt(state, true);
}

fn handleCloseSession(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid params",
        });
    defer parsed.deinit();
    const requested_id = if (parsed.value == .object)
        if (parsed.value.object.get("sessionId")) |value|
            if (value == .string and value.string.len > 0) value.string else null
        else
            null
    else
        null;
    const session_id = requested_id orelse
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing sessionId",
        });
    const active = if (state.active_session) |*session| session else return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Session is not active",
    });
    if (!std.mem.eql(u8, active.session_id, session_id)) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Session is not active",
        });
    }

    cancelAndReapActivePrompt(state);
    closeActiveSession(state) catch |err| {
        debug_trace.logf(
            "session",
            "failed to flush ACP session usage during close session_id={s} err={s}",
            .{ session_id, @errorName(err) },
        );
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to close session cleanly",
        });
    };
    try state.writer.writeResponse(alloc, msg.id, "{}");
}

fn handleProviderSwitch(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = parseProviderParams(state, alloc, msg, true) catch |err| {
        if (err == error.ResponseWritten) return;
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing or invalid provider switch params",
        });
    };
    defer params.parsed.deinit();
    const target = model_provider.parse(params.provider orelse unreachable) orelse
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "provider must be gateway, codex, or grok",
        });

    var current_credential = borrowedCredentialForProvider(state, target);
    const started = try startProviderJob(
        state,
        msg,
        target,
        .explicit_switch,
        providerCatalogEndpoint(state, target),
        null,
        if (current_credential) |*value| value else null,
        null,
    );
    if (!started) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Provider operation already in progress",
        });
    }
}

fn handleProviderConfigure(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid params",
        });
    defer parsed.deinit();
    if (parsed.value != .object) return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Params must be object",
    });
    validateOptionalProviderSession(state, alloc, msg, parsed.value) catch |err| {
        if (err == error.ResponseWritten) return;
        return err;
    };
    const base_url = requiredProviderString(parsed.value, "baseUrl") orelse
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing baseUrl",
        });
    const api_key = requiredProviderString(parsed.value, "apiKey") orelse
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing apiKey",
        });
    if (api_key.len == 0) return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "apiKey must not be empty",
    });
    gateway_session.validate(base_url, api_key) catch return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Invalid Gateway baseUrl or apiKey",
    });

    const chat_url = provider_route.appendResponsesEndpointAlloc(alloc, base_url) catch |err|
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = switch (err) {
                error.InsecureBaseUrl => "baseUrl must use HTTPS or loopback HTTP with an explicit port",
                else => "Invalid baseUrl",
            },
        });
    defer alloc.free(chat_url);
    const models_url = provider_route.appendModelsEndpointAlloc(alloc, base_url) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid baseUrl",
        });
    defer alloc.free(models_url);
    var credential = credentials.Credential{
        .token = @constCast(api_key),
        .source = .openai_api_key,
    };
    if (!try startProviderJob(
        state,
        msg,
        .gateway,
        .configure_byok,
        models_url,
        chat_url,
        &credential,
        base_url,
    )) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Provider operation already in progress",
        });
    }
}

const ParsedProviderParams = struct {
    parsed: std.json.Parsed(std.json.Value),
    provider: ?[]const u8,
};

fn parseProviderParams(
    state: *ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    provider_required: bool,
) !ParsedProviderParams {
    const params = msg.params_raw orelse return error.MissingParams;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, params, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidParams;
    try validateOptionalProviderSession(state, alloc, msg, parsed.value);
    const provider = requiredProviderString(parsed.value, "provider");
    if (provider_required and provider == null) return error.MissingProvider;
    return .{ .parsed = parsed, .provider = provider };
}

fn validateOptionalProviderSession(
    state: *ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    root: std.json.Value,
) !void {
    const value = root.object.get("sessionId") orelse return;
    if (value != .string or value.string.len == 0) {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "sessionId must be a non-empty string",
        });
        return error.ResponseWritten;
    }
    const active = state.active_session orelse {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Session is not active",
        });
        return error.ResponseWritten;
    };
    if (!std.mem.eql(u8, active.session_id, value.string)) {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Session is not active",
        });
        return error.ResponseWritten;
    }
}

fn requiredProviderString(root: std.json.Value, name: []const u8) ?[]const u8 {
    const value = root.object.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn handleProviderSetupStart(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    if (msg.params_raw) |params| {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Invalid provider setup params",
            });
        defer parsed.deinit();
        if (parsed.value != .object) return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Provider setup params must be an object",
        });
    }
    if (!try state.provider_setup.start()) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Provider setup already in progress or awaiting status",
        });
    }
    try state.writer.writeResponse(alloc, msg.id, "{\"state\":\"running\"}");
}

fn handleProviderSetupStatus(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    switch (state.provider_setup.poll()) {
        .idle => try state.writer.writeResponse(alloc, msg.id, "{\"state\":\"idle\"}"),
        .running => try state.writer.writeResponse(alloc, msg.id, "{\"state\":\"running\"}"),
        .completed => |outcome| {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            switch (outcome) {
                .failed => |err| {
                    try out.writer.writeAll("{\"state\":\"failed\",\"error\":");
                    try writeJsonStr(@errorName(err), &out.writer);
                },
                .report => |report| {
                    try out.writer.writeAll("{\"state\":\"completed\",\"report\":");
                    try report.writeJsonValue(&out.writer);
                },
            }
            try out.writer.writeByte('}');
            try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());
        },
    }
}

fn handleProviderLoginStart(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = parseProviderParams(state, alloc, msg, false) catch |err| {
        if (err == error.ResponseWritten) return;
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing or invalid provider login params",
        });
    };
    defer params.parsed.deinit();
    const auto_provider = params.provider == null;
    var provider = if (params.provider) |value|
        provider_oauth.Provider.parse(value) orelse return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "provider must be codex or grok",
        })
    else
        (provider_oauth.detectStored(alloc) catch null) orelse .codex;
    const started = started_login: {
        break :started_login provider_oauth.startSignIn(
            provider,
            &state.provider_login,
            alloc,
            state.cfg.gateway_provider.oauth_transport,
        ) catch |err| {
            if (!auto_provider or provider != .codex) return err;
            // Browser callback setup can fail locally (for example when the
            // preferred callback port is occupied). In auto mode only, retry
            // the other OAuth implementation before surfacing the error.
            provider = .grok;
            break :started_login provider_oauth.startSignIn(
                provider,
                &state.provider_login,
                alloc,
                state.cfg.gateway_provider.oauth_transport,
            ) catch |fallback_err| return fallback_err;
        };
    };
    if (!started) return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_request,
        .message = "Provider login already in progress",
    });
    state.provider_login_provider = provider;
    try writeProviderLoginSnapshot(state, alloc, msg.id, state.provider_login.snapshot(), null);
}

fn handleProviderLoginStatus(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    switch (state.provider_login.pollTransition(alloc)) {
        .none => try writeProviderLoginSnapshot(state, alloc, msg.id, state.provider_login.snapshot(), null),
        .cancelled => try writeProviderLoginSnapshot(state, alloc, msg.id, .{ .state = .cancelled }, null),
        .failed => |err| try writeProviderLoginSnapshot(state, alloc, msg.id, .{ .state = .failed }, @errorName(err)),
        .succeeded => |completion| {
            var owned = completion;
            defer owned.deinit(alloc);
            try writeProviderLoginSnapshot(state, alloc, msg.id, .{ .state = .succeeded }, null);
        },
    }
}

fn handleProviderLoginSubmitCode(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid params",
        });
    defer parsed.deinit();
    if (parsed.value != .object) return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Params must be object",
    });
    const code = requiredProviderString(parsed.value, "code") orelse
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Missing code",
        });
    if (!try state.provider_login.submitManualCode(alloc, code)) {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "This provider login is not accepting a manual code",
        });
    }
    try state.writer.writeResponse(alloc, msg.id, "{\"accepted\":true}");
}

fn handleProviderLoginCancel(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const cancelled = state.provider_login.cancel(alloc);
    try state.writer.writeResponse(
        alloc,
        msg.id,
        if (cancelled) "{\"cancelled\":true}" else "{\"cancelled\":false}",
    );
}

/// Returns the same provider-neutral usage summary that the TUI footer uses.
/// This endpoint is intentionally local and non-blocking: remote account
/// quota requests stay on the explicit CLI/provider usage path and never hold
/// the ACP read loop while a network request is in flight.
fn handleProviderUsage(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = parseProviderParams(state, alloc, msg, false) catch |err| {
        if (err == error.ResponseWritten) return;
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid provider usage params",
        });
    };
    defer params.parsed.deinit();

    const provider = if (params.provider) |value|
        model_provider.parse(value) orelse return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "provider must be gateway, codex, or grok",
        })
    else
        state.provider;

    var summary = provider_usage.Summary.fromCounters(
        provider,
        state.credential_source,
        state.account_id,
        0,
        0,
        0,
        null,
    );
    if (state.active_session) |*active| {
        var usage = try active.session_rt.usage.snapshot(alloc);
        defer usage.deinit(alloc);
        summary = provider_usage.Summary.fromSession(
            provider,
            active.credential_source,
            active.account_id,
            usage,
            null,
        );
    }
    if (credentialMatchesProvider(state.credential_source, provider)) {
        if (state.account_usage.summary(provider, state.credential_source, state.account_id)) |account| {
            summary.overlayAccountLimits(account);
        }
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"kind\":\"provider_usage\",\"schemaVersion\":1,\"snapshot\":");
    try summary.writeJson(&out.writer);
    try out.writer.writeByte('}');
    try state.writer.writeResponse(alloc, msg.id, out.writer.buffered());
}

fn writeProviderLoginSnapshot(
    state: *ServerState,
    alloc: Allocator,
    id: ?jsonrpc.RequestId,
    snapshot: login_flow.SignInSnapshot,
    failure: ?[]const u8,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"state\":");
    try writeJsonStr(@tagName(snapshot.state), &out.writer);
    if (snapshot.authorization_url.len > 0) {
        try out.writer.writeAll(",\"authorizationUrl\":");
        try writeJsonStr(snapshot.authorization_url, &out.writer);
    }
    if (state.provider_login_provider) |provider| {
        try out.writer.writeAll(",\"provider\":");
        try writeJsonStr(provider.label(), &out.writer);
    }
    try out.writer.print(",\"acceptsManualCode\":{s}", .{
        if (snapshot.accepts_manual_code) "true" else "false",
    });
    if (failure) |value| {
        try out.writer.writeAll(",\"error\":");
        try writeJsonStr(value, &out.writer);
    }
    try out.writer.writeByte('}');
    try state.writer.writeResponse(alloc, id, out.writer.buffered());
}

const ProviderJobKind = enum {
    config_option,
    explicit_switch,
    configure_byok,
};

const ProviderJob = struct {
    state: *ServerState,
    msg: jsonrpc.Message,
    target: model_provider.ProviderId,
    kind: ProviderJobKind,
    models_url: []u8,
    models_url_transferred: bool = false,
    chat_url: ?[]u8 = null,
    credential_override: ?credentials.Credential = null,
    persist_base_url: ?[]u8 = null,

    fn init(
        state: *ServerState,
        msg: *const jsonrpc.Message,
        target: model_provider.ProviderId,
        kind: ProviderJobKind,
        models_url: []const u8,
        chat_url: ?[]const u8,
        credential_override: ?*const credentials.Credential,
        persist_base_url: ?[]const u8,
    ) !ProviderJob {
        const owned_models_url = try state.alloc.dupe(u8, models_url);
        errdefer state.alloc.free(owned_models_url);
        const owned_chat_url = if (chat_url) |value| try state.alloc.dupe(u8, value) else null;
        errdefer if (owned_chat_url) |value| state.alloc.free(value);
        var owned_credential = if (credential_override) |value|
            try cloneServerCredential(state.alloc, value.*)
        else
            null;
        errdefer if (owned_credential) |*value| value.deinit(state.alloc);
        const owned_persist_base_url = if (persist_base_url) |value| try state.alloc.dupe(u8, value) else null;
        errdefer if (owned_persist_base_url) |value| state.alloc.free(value);
        return .{
            .state = state,
            .msg = try cloneMessage(state.alloc, msg),
            .target = target,
            .kind = kind,
            .models_url = owned_models_url,
            .chat_url = owned_chat_url,
            .credential_override = owned_credential,
            .persist_base_url = owned_persist_base_url,
        };
    }

    fn deinit(self: *ProviderJob) void {
        jsonrpc.freeMessage(self.state.alloc, &self.msg);
        if (!self.models_url_transferred) self.state.alloc.free(self.models_url);
        if (self.chat_url) |value| self.state.alloc.free(value);
        if (self.credential_override) |*value| value.deinit(self.state.alloc);
        if (self.persist_base_url) |value| self.state.alloc.free(value);
        self.* = undefined;
    }
};

fn cloneServerCredential(alloc: Allocator, value: credentials.Credential) !credentials.Credential {
    const token = try alloc.dupe(u8, value.token);
    errdefer secret.zeroAndFree(alloc, token);
    const account_id = if (value.account_id) |account_id|
        try alloc.dupe(u8, account_id)
    else
        null;
    return .{
        .token = token,
        .source = value.source,
        .account_id = account_id,
        .refresh_after_ms = value.refresh_after_ms,
    };
}

fn startProviderJob(
    state: *ServerState,
    msg: *const jsonrpc.Message,
    target: model_provider.ProviderId,
    kind: ProviderJobKind,
    models_url: []const u8,
    chat_url: ?[]const u8,
    credential_override: ?*const credentials.Credential,
    persist_base_url: ?[]const u8,
) !bool {
    reapProviderJob(state, false);
    if (state.provider_job_running.load(.seq_cst) or state.provider_job_thread != null) return false;

    const job = try state.alloc.create(ProviderJob);
    errdefer state.alloc.destroy(job);
    job.* = try ProviderJob.init(
        state,
        msg,
        target,
        kind,
        models_url,
        chat_url,
        credential_override,
        persist_base_url,
    );
    errdefer job.deinit();

    state.provider_job_cancel.store(false, .seq_cst);
    state.provider_job_running.store(true, .seq_cst);
    state.provider_job_thread = std.Thread.spawn(.{}, providerJobMain, .{job}) catch |err| {
        state.provider_job_running.store(false, .seq_cst);
        return err;
    };
    return true;
}

fn reapProviderJob(state: *ServerState, wait: bool) void {
    const thread = state.provider_job_thread orelse return;
    if (!wait and state.provider_job_running.load(.seq_cst)) return;
    thread.join();
    state.provider_job_thread = null;
}

fn providerJobMain(job: *ProviderJob) void {
    const state = job.state;
    defer {
        job.deinit();
        state.alloc.destroy(job);
        state.provider_job_running.store(false, .seq_cst);
    }

    const catalog_provider = catalogProviderFor(state, job.target) orelse {
        state.writer.writeError(state.alloc, job.msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Selected provider is unavailable in this host",
        }) catch {};
        return;
    };
    var outcome = provider_activation.prepare(state.alloc, .{
        .target = job.target,
        .oauth_transport = state.cfg.gateway_provider.oauth_transport,
        .secret_store = state.cfg.secret_store,
        .catalog_provider = catalog_provider,
        .endpoint = job.models_url,
        .credential_override = if (job.credential_override) |*value| value else null,
    }, &state.provider_job_cancel);
    defer outcome.deinit(state.alloc);
    var prepared = switch (outcome) {
        .prepared => |*value| value,
        .failed => |failure| {
            writeProviderJobFailure(job, failure);
            return;
        },
    };

    var settings = (if (state.cfg.home_override) |home|
        config_runtime.loadMergedSettingsFromHome(state.alloc, home, state.workspace_root)
    else
        config_runtime.loadMergedSettings(state.alloc, state.workspace_root)) catch |err| {
        debug_trace.logf("provider", "ACP provider settings load failed err={s}", .{@errorName(err)});
        state.writer.writeError(state.alloc, job.msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to load provider settings",
        }) catch {};
        return;
    };
    defer settings.deinit(state.alloc);

    const current_model = if (state.active_session) |*active|
        if (active.provider == job.target) active.model else null
    else if (state.provider == job.target)
        state.selected_model
    else
        null;
    const selected_model = selectProviderModel(
        prepared.catalog.items,
        current_model,
        settings.models.get(job.target),
    ) orelse {
        state.writer.writeError(state.alloc, job.msg.id, .{
            .code = ErrorCode.invalid_request,
            .message = "Provider returned no supported models",
        }) catch {};
        return;
    };

    if (job.persist_base_url) |base_url| {
        persistGatewayBinding(state, base_url, prepared.credential.token) catch |err| {
            debug_trace.logf("provider", "ACP gateway binding persist failed err={s}", .{@errorName(err)});
            state.writer.writeError(state.alloc, job.msg.id, .{
                .code = ErrorCode.internal_error,
                .message = "Failed to save Gateway URL and API key",
            }) catch {};
            return;
        };
    }

    if (state.active_session) |*active| {
        commitActiveSessionProvider(
            state.alloc,
            active,
            job.target,
            selected_model,
            session_test_controls.logOptions(),
        ) catch |err| {
            debug_trace.logf("provider", "ACP provider commit failed err={s}", .{@errorName(err)});
            _ = markIndeterminateCommitTerminal(state, err);
            state.writer.writeError(state.alloc, job.msg.id, .{
                .code = ErrorCode.internal_error,
                .message = "Failed to persist session provider",
            }) catch {};
            return;
        };
    }

    const selected_copy = state.alloc.dupe(u8, selected_model) catch {
        state.writer.writeError(state.alloc, job.msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to activate provider",
        }) catch {};
        return;
    };
    if (state.selected_model.len > 0) state.alloc.free(state.selected_model);
    state.selected_model = selected_copy;
    state.provider = job.target;

    if (job.kind == .configure_byok) {
        const chat_url = job.chat_url orelse unreachable;
        const binding_credential = job.credential_override orelse unreachable;
        state.gateway_binding_mutex.lockUncancelable(io_mod.getIo());
        if (state.gateway_binding) |*binding| binding.deinit(state.alloc);
        state.gateway_binding = .{
            .chat_url = chat_url,
            .models_url = job.models_url,
            .credential = binding_credential,
        };
        state.gateway_binding_mutex.unlock(io_mod.getIo());
        job.chat_url = null;
        job.models_url_transferred = true;
        job.credential_override = null;
    }

    state.capability_resolver.adoptOwnedCatalog(state.alloc, &prepared.catalog);
    adoptServerCredential(state, &prepared.credential);

    switch (job.kind) {
        .config_option => writeConfigOptionsResponse(state, state.alloc, job.msg.id) catch {},
        .explicit_switch, .configure_byok => writeProviderOperationResponse(job, selected_model) catch {},
    }
}

fn selectProviderModel(
    entries: []const model_catalog.ModelCatalogEntry,
    current: ?[]const u8,
    saved: ?[]const u8,
) ?[]const u8 {
    for ([_]?[]const u8{ current, saved }) |candidate_value| {
        const candidate = candidate_value orelse continue;
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.id, candidate)) return entry.id;
        }
    }
    return if (entries.len > 0) entries[0].id else null;
}

fn writeProviderJobFailure(job: *ProviderJob, failure: provider_activation.Failure) void {
    const message = switch (failure) {
        .cancelled => "Provider operation cancelled",
        .missing_credential => if (job.target == .codex)
            credentials.missing_chatgpt_credential_message
        else if (job.target == .grok)
            credentials.missing_grok_credential_message
        else
            credentials.missing_credential_message,
        .unauthorized_credential => "Credential cannot authorize the selected provider",
        .catalog => "Failed to load provider model catalog",
        .empty_catalog => "Provider returned no supported models",
        .credential => |err| message: {
            debug_trace.logf("provider", "ACP provider preparation failed provider={t} err={s}", .{ job.target, @errorName(err) });
            break :message "Failed to prepare provider credential or model catalog";
        },
    };
    job.state.writer.writeError(job.state.alloc, job.msg.id, .{
        .code = ErrorCode.invalid_request,
        .message = message,
    }) catch {};
}

fn writeProviderOperationResponse(job: *ProviderJob, model: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(job.state.alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"provider\":");
    try writeJsonStr(@tagName(job.target), &out.writer);
    try out.writer.writeAll(",\"model\":");
    try writeJsonStr(model, &out.writer);
    if (job.kind == .configure_byok) {
        try out.writer.writeAll(",\"responseUrl\":");
        try writeJsonStr(gatewayChatUrl(job.state), &out.writer);
        try out.writer.writeAll(",\"credentialPersistence\":\"profile\"");
    }
    try out.writer.writeByte('}');
    try job.state.writer.writeResponse(job.state.alloc, job.msg.id, out.writer.buffered());
}

fn handleSetConfigOption(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid params" });
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Params must be object" });

    const config_id = blk: {
        if (root.object.get("configId")) |v| {
            if (v == .string) break :blk v.string;
        }
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing configId" });
    };

    const value = blk: {
        if (root.object.get("value")) |v| {
            if (v == .string) break :blk v.string;
        }
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Missing value" });
    };

    const session = if (state.active_session) |*active| active else return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_request,
        .message = "No active session",
    });

    if (std.mem.eql(u8, config_id, "model")) {
        session_codec.validateModelPreference(value) catch
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Invalid session model",
            });
        if (comptime !host_target.is_wasm) {
            if (session.provider != .gateway) {
                var model_available = false;
                if (state.capability_resolver.catalogEntries()) |entries| {
                    for (entries) |entry| {
                        if (std.mem.eql(u8, entry.id, value)) {
                            model_available = true;
                            break;
                        }
                    }
                }
                if (!model_available) {
                    return state.writer.writeError(alloc, msg.id, .{
                        .code = ErrorCode.invalid_params,
                        .message = "Model is not available for the active provider",
                    });
                }
                if (!try selectCredentialForProvider(state, session.provider)) {
                    return state.writer.writeError(alloc, msg.id, .{
                        .code = ErrorCode.invalid_request,
                        .message = if (session.provider == .codex)
                            credentials.missing_chatgpt_credential_message
                        else
                            credentials.missing_grok_credential_message,
                    });
                }
            }
        }
        const controls = normalizeModelControls(
            session.effort,
            session.fast_mode,
            state.capability_resolver.available(
                value,
                state.cfg.provider_set.select(session.provider).fallbackModelCapabilities(value),
            ),
        );
        if (host_target.is_wasm and session.writable == null) {
            commitWasmSessionPreferences(alloc, session, .{
                .model = value,
                .effort = controls.effort,
                .fast_mode = controls.fast_mode,
            }) catch return writeConfigPersistenceError(state, alloc, msg);
        } else commitActiveSessionPreferences(
            alloc,
            session,
            .{
                .model = value,
                .effort = controls.effort,
                .fast_mode = controls.fast_mode,
            },
            session_test_controls.logOptions(),
        ) catch |err| return writeConfigCommitError(state, alloc, msg, err, "Invalid session model");
    } else if (std.mem.eql(u8, config_id, "provider")) {
        const target = model_provider.parse(value) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Invalid provider",
            });
        if (target != session.provider) {
            if (host_target.is_wasm) {
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = "Subscription provider switching is unavailable in this WASM runtime",
                });
            }
            var current_credential = borrowedCredentialForProvider(state, target);
            if (!try startProviderJob(
                state,
                msg,
                target,
                .config_option,
                providerCatalogEndpoint(state, target),
                null,
                if (current_credential) |*credential| credential else null,
                null,
            )) {
                return state.writer.writeError(alloc, msg.id, .{
                    .code = ErrorCode.invalid_request,
                    .message = "Provider operation already in progress",
                });
            }
            return;
        }
    } else if (std.mem.eql(u8, config_id, "effort")) {
        const effort = parseEffortConfig(value) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Invalid reasoning effort",
            });
        if (!model_capabilities.reasoningEffortSupported(
            state.capability_resolver.available(
                session.model,
                state.cfg.provider_set.select(session.provider).fallbackModelCapabilities(session.model),
            ),
            effort,
        )) return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Reasoning effort is not supported by the selected model",
        });
        if (host_target.is_wasm and session.writable == null) {
            commitWasmSessionPreferences(alloc, session, .{ .effort = effort }) catch
                return writeConfigPersistenceError(state, alloc, msg);
        } else commitActiveSessionPreferences(
            alloc,
            session,
            .{ .effort = effort },
            session_test_controls.logOptions(),
        ) catch |err| return writeConfigCommitError(state, alloc, msg, err, "Invalid reasoning effort");
    } else if (std.mem.eql(u8, config_id, "fast_mode")) {
        const fast_mode = parseFastModeConfig(value) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Invalid Fast mode",
            });
        if (fast_mode and !state.capability_resolver.available(
            session.model,
            state.cfg.provider_set.select(session.provider).fallbackModelCapabilities(session.model),
        ).supports_fast_mode) {
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Fast mode is not supported by the selected model",
            });
        }
        if (host_target.is_wasm and session.writable == null) {
            commitWasmSessionPreferences(alloc, session, .{ .fast_mode = fast_mode }) catch
                return writeConfigPersistenceError(state, alloc, msg);
        } else commitActiveSessionPreferences(
            alloc,
            session,
            .{ .fast_mode = fast_mode },
            session_test_controls.logOptions(),
        ) catch |err| return writeConfigCommitError(state, alloc, msg, err, "Invalid Fast mode");
    } else if (std.mem.eql(u8, config_id, "bash_first")) {
        const bash_first = parseBashFirstConfig(value) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "Invalid bash-first mode",
            });
        state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        state.bash_first = bash_first;
        state.subagent_authority_mutex.unlock(io_mod.getIo());
    } else if (std.mem.eql(u8, config_id, "mode")) {
        if (state.cfg.mode_registry.lookup(value) == null) return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid session mode",
        });
        state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
        defer state.subagent_authority_mutex.unlock(io_mod.getIo());
        applySessionMode(state.cfg.mode_registry, session, value);
    } else {
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Unknown configId",
        });
    }

    try writeConfigOptionsResponse(state, alloc, msg.id);
}

fn writeConfigOptionsResponse(
    state: *ServerState,
    alloc: Allocator,
    id: ?jsonrpc.RequestId,
) !void {
    const session = if (state.active_session) |*active| active else return state.writer.writeError(alloc, id, .{
        .code = ErrorCode.invalid_request,
        .message = "No active session",
    });
    const current_model = session.model;
    const current_mode = session.mode;
    const current_capabilities = state.capability_resolver.available(
        current_model,
        state.cfg.provider_set.select(session.provider).fallbackModelCapabilities(current_model),
    );

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"configOptions\":[");
    if (comptime !host_target.is_wasm) {
        try sessions.writeProviderConfigOption(
            &out.writer,
            session.provider,
        );
        try out.writer.writeAll(",");
    }
    try sessions.writeModelConfigOption(
        &out.writer,
        current_model,
        state.capability_resolver.catalogEntries(),
    );
    try out.writer.writeAll(",");
    try sessions.writeEffortConfigOption(&out.writer, session.effort, current_capabilities);
    try out.writer.writeAll(",");
    try sessions.writeFastModeConfigOption(&out.writer, session.fast_mode, current_capabilities.supports_fast_mode);
    try out.writer.writeAll(",");
    try sessions.writeBashFirstConfigOption(&out.writer, state.bash_first);
    try out.writer.writeAll(",");
    try sessions.writeModeConfigOption(&out.writer, state.cfg.mode_registry, current_mode);
    try out.writer.writeAll("]}");
    try state.writer.writeResponse(alloc, id, out.writer.buffered());
}

const SessionPreferenceUpdate = struct {
    model: ?[]const u8 = null,
    effort: ?types.ReasoningEffort = null,
    fast_mode: ?bool = null,
};

const ModelControls = struct {
    effort: types.ReasoningEffort,
    fast_mode: bool,
};

fn normalizeModelControls(
    effort: types.ReasoningEffort,
    fast_mode: bool,
    capabilities: model_capabilities.Capabilities,
) ModelControls {
    return .{
        .effort = model_capabilities.clampReasoningEffort(capabilities, effort),
        .fast_mode = fast_mode and capabilities.supports_fast_mode,
    };
}

fn parseFastModeConfig(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "normal")) return false;
    if (std.mem.eql(u8, value, "fast")) return true;
    return null;
}

fn parseBashFirstConfig(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "on") or std.mem.eql(u8, value, "bash-first") or std.mem.eql(u8, value, "bash_first")) return true;
    if (std.mem.eql(u8, value, "off") or std.mem.eql(u8, value, "standard") or std.mem.eql(u8, value, "default")) return false;
    return null;
}

fn parseEffortConfig(value: []const u8) ?types.ReasoningEffort {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    const effort = types.ReasoningEffort.parse(value) orelse return null;
    return if (effort.isDefault()) null else effort;
}

fn commitWasmSessionPreferences(
    alloc: Allocator,
    session: *ActiveSessionState,
    update: SessionPreferenceUpdate,
) !void {
    const next_model = if (update.model) |model| try alloc.dupe(u8, model) else null;
    errdefer if (next_model) |model| alloc.free(model);
    const previous_model = session.model;
    const previous_effort = session.effort;
    const previous_fast_mode = session.fast_mode;
    if (next_model) |model| session.model = model;
    if (update.effort) |effort| session.effort = effort;
    if (update.fast_mode) |fast_mode| session.fast_mode = fast_mode;
    sessions.commitWasmSession(alloc, session) catch |err| {
        session.model = previous_model;
        session.effort = previous_effort;
        session.fast_mode = previous_fast_mode;
        return err;
    };
    if (next_model != null) alloc.free(previous_model);
}

fn writeConfigPersistenceError(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.internal_error,
        .message = "Failed to persist session configuration",
    });
}

fn writeConfigCommitError(
    state: *ServerState,
    alloc: Allocator,
    msg: *jsonrpc.Message,
    err: anyerror,
    invalid_message: []const u8,
) !void {
    if (markIndeterminateCommitTerminal(state, err)) {
        try state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.internal_error,
            .message = "Failed to persist session configuration",
        });
        return;
    }
    return state.writer.writeError(alloc, msg.id, .{
        .code = if (err == error.InvalidDurableField) ErrorCode.invalid_params else ErrorCode.internal_error,
        .message = if (err == error.InvalidDurableField) invalid_message else "Failed to persist session configuration",
    });
}

fn commitActiveSessionProvider(
    alloc: Allocator,
    session: *ActiveSessionState,
    provider: model_provider.ProviderId,
    model: []const u8,
    options: session_log.Options,
) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (session.writable) |*active|
        active
    else
        return error.SessionPersistenceUnavailable;
    const staged_model = try alloc.dupe(u8, model);
    errdefer alloc.free(staged_model);
    _ = try writable.appendEvent(
        alloc,
        .{ .preferences_changed = .{
            .provider = provider,
            .model = @constCast(model),
        } },
        io_mod.milliTimestamp(),
        .rollback_before_adapter_continue,
        options,
    );
    alloc.free(session.model);
    session.model = staged_model;
    session.provider = provider;
}

fn commitActiveSessionModel(
    alloc: Allocator,
    session: *ActiveSessionState,
    value: []const u8,
    options: session_log.Options,
) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (session.writable) |*active|
        active
    else
        return error.SessionPersistenceUnavailable;
    try commitSessionModel(
        alloc,
        writable,
        &session.model,
        value,
        options,
    );
}

fn commitActiveSessionPreferences(
    alloc: Allocator,
    session: *ActiveSessionState,
    update: SessionPreferenceUpdate,
    options: session_log.Options,
) !void {
    session.session_write_mutex.lockUncancelable(io_mod.getIo());
    defer session.session_write_mutex.unlock(io_mod.getIo());
    const writable = if (session.writable) |*active|
        active
    else
        return error.SessionPersistenceUnavailable;
    try commitSessionPreferences(alloc, writable, session, update, options);
}

fn commitSessionModel(
    alloc: Allocator,
    writable: *session_store.LoadedWritableSession,
    active_model: *[]u8,
    value: []const u8,
    options: session_log.Options,
) !void {
    const staged_model = try alloc.dupe(u8, value);
    errdefer alloc.free(staged_model);
    _ = try writable.appendEvent(
        alloc,
        .{ .preferences_changed = .{ .model = @constCast(value) } },
        io_mod.milliTimestamp(),
        .rollback_before_adapter_continue,
        options,
    );
    alloc.free(active_model.*);
    active_model.* = staged_model;
}

fn commitSessionPreferences(
    alloc: Allocator,
    writable: *session_store.LoadedWritableSession,
    active: *ActiveSessionState,
    update: SessionPreferenceUpdate,
    options: session_log.Options,
) !void {
    if (update.model == null and update.effort == null and update.fast_mode == null) return;
    const staged_model = if (update.model) |model| try alloc.dupe(u8, model) else null;
    errdefer if (staged_model) |model| alloc.free(model);
    _ = try writable.appendEvent(
        alloc,
        .{ .preferences_changed = .{
            .model = if (update.model) |model| @constCast(model) else null,
            .effort = update.effort,
            .fast_mode = update.fast_mode,
        } },
        io_mod.milliTimestamp(),
        .rollback_before_adapter_continue,
        options,
    );
    if (staged_model) |model| {
        alloc.free(active.model);
        active.model = model;
    }
    if (update.effort) |effort| active.effort = effort;
    if (update.fast_mode) |fast_mode| active.fast_mode = fast_mode;
}

fn modelCommitFailureTerminatesConnection(err: anyerror) bool {
    return err == error.SessionCommitIndeterminate or
        err == error.SessionLogCompactionIndeterminate;
}

fn markIndeterminateCommitTerminal(state: *ServerState, err: anyerror) bool {
    if (!modelCommitFailureTerminatesConnection(err)) return false;
    state.terminate_connection.store(true, .release);
    return true;
}

fn handleSetMode(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{ .code = ErrorCode.invalid_params, .message = "Invalid params" });
    defer parsed.deinit();

    if (parsed.value == .object) {
        if (parsed.value.object.get("modeId")) |v| {
            if (v == .string) {
                if (state.active_session) |*session| {
                    state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
                    defer state.subagent_authority_mutex.unlock(io_mod.getIo());
                    applySessionMode(state.cfg.mode_registry, session, v.string);
                }
            }
        }
    }

    try state.writer.writeResponse(alloc, msg.id, "null");
}

pub fn applySessionMode(registry: mode_registry.Registry, session: *ActiveSessionState, id: []const u8) void {
    const mode = registry.lookup(id) orelse return;
    session.mode = mode.id;
    session.permission_mode = mode.permission_mode;
}

fn handleToolModeSet(state: *ServerState, alloc: Allocator, msg: *jsonrpc.Message) !void {
    const params = msg.params_raw orelse return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Missing params",
    });
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, params, .{}) catch
        return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "Invalid params",
        });
    defer parsed.deinit();
    if (parsed.value != .object) return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Expected an object with mode or bashFirst",
    });

    const enabled: bool = if (parsed.value.object.get("bashFirst")) |value| switch (value) {
        .bool => |flag| flag,
        else => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "bashFirst must be a boolean",
        }),
    } else if (parsed.value.object.get("mode")) |value| switch (value) {
        .string => |mode| parseBashFirstConfig(mode) orelse
            return state.writer.writeError(alloc, msg.id, .{
                .code = ErrorCode.invalid_params,
                .message = "mode must be bash-first or standard",
            }),
        else => return state.writer.writeError(alloc, msg.id, .{
            .code = ErrorCode.invalid_params,
            .message = "mode must be a string",
        }),
    } else return state.writer.writeError(alloc, msg.id, .{
        .code = ErrorCode.invalid_params,
        .message = "Expected mode or bashFirst",
    });

    state.subagent_authority_mutex.lockUncancelable(io_mod.getIo());
    state.bash_first = enabled;
    state.subagent_authority_mutex.unlock(io_mod.getIo());

    var response: std.Io.Writer.Allocating = .init(alloc);
    defer response.deinit();
    try response.writer.writeAll("{\"mode\":");
    try writeJsonStr(if (enabled) "bash-first" else "standard", &response.writer);
    try response.writer.print(",\"bashFirst\":{s}}}", .{if (enabled) "true" else "false"});
    try state.writer.writeResponse(alloc, msg.id, response.writer.buffered());
}

test "applySessionMode uses registered mode policy and ignores unknown modes" {
    const mode_specs = [_]mode_registry.ModeSpec{
        .{ .id = "inspect", .name = "Inspect", .permission_mode = .ask },
        .{ .id = "apply", .name = "Apply", .permission_mode = .auto },
    };
    const registry = mode_registry.Registry{
        .default_mode_id = "inspect",
        .modes = mode_specs[0..],
    };
    var session = ActiveSessionState{
        .session_id = @constCast("session"),
        .model = @constCast("model"),
        .mode = registry.default_mode_id,
        .workspace_root = "/tmp/workspace",
        .api_key = "",
        .agent_step_limit = 0,
        .max_tool_result_bytes = 0,
        .fast_mode = false,
        .effort = .auto,
        .first_call_tool_choice = .auto,
        .permission_mode = .ask,
        .permission_rules = .{},
        .session_rt = .{ .max_history_turns = 0 },
        .cancel_flag = std.atomic.Value(bool).init(false),
        .pending_prompt_id = null,
    };

    applySessionMode(registry, &session, "apply");
    try std.testing.expectEqualStrings("apply", session.mode);
    try std.testing.expectEqual(types.PermissionMode.auto, session.permission_mode);

    applySessionMode(registry, &session, "inspect");
    try std.testing.expectEqualStrings("inspect", session.mode);
    try std.testing.expectEqual(types.PermissionMode.ask, session.permission_mode);

    applySessionMode(registry, &session, "unknown");
    try std.testing.expectEqualStrings("inspect", session.mode);
    try std.testing.expectEqual(types.PermissionMode.ask, session.permission_mode);

    applySessionMode(registry, &session, "apply");
    try std.testing.expectEqual(types.PermissionMode.auto, session.permission_mode);
    applySessionMode(registry, &session, "inspect");
    try std.testing.expectEqual(types.PermissionMode.ask, session.permission_mode);
}

test "ACP notifications with absent id are not response targets" {
    const alloc = std.testing.allocator;
    var notification = try jsonrpc.parseMessage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"method\":\"unknown/notification\",\"params\":{}}",
    );
    defer jsonrpc.freeMessage(alloc, &notification);
    try std.testing.expect(!shouldRespondToMessage(&notification));

    var null_id_request = try jsonrpc.parseMessage(
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"unknown/request\",\"params\":{}}",
    );
    defer jsonrpc.freeMessage(alloc, &null_id_request);
    try std.testing.expect(shouldRespondToMessage(&null_id_request));
}

test "ACP method parser classifies request dispatch methods" {
    try std.testing.expectEqual(AcpMethod.initialize, AcpMethod.parse("initialize"));
    try std.testing.expectEqual(AcpMethod.session_cancel, AcpMethod.parse("session/cancel"));
    try std.testing.expectEqual(AcpMethod.session_new, AcpMethod.parse("session/new"));
    try std.testing.expectEqual(AcpMethod.session_load, AcpMethod.parse("session/load"));
    try std.testing.expectEqual(AcpMethod.session_resume, AcpMethod.parse("session/resume"));
    try std.testing.expectEqual(AcpMethod.session_close, AcpMethod.parse("session/close"));
    try std.testing.expectEqual(AcpMethod.session_list, AcpMethod.parse("session/list"));
    try std.testing.expectEqual(AcpMethod.session_prompt, AcpMethod.parse("session/prompt"));
    try std.testing.expectEqual(AcpMethod.session_set_config_option, AcpMethod.parse("session/set_config_option"));
    try std.testing.expectEqual(AcpMethod.session_set_mode, AcpMethod.parse("session/set_mode"));
    try std.testing.expectEqual(AcpMethod.fx_turn_steer, AcpMethod.parse("fx/turn/steer"));
    try std.testing.expectEqual(AcpMethod.fx_turn_status, AcpMethod.parse("fx/turn/status"));
    try std.testing.expectEqual(AcpMethod.fx_background_terminals_list, AcpMethod.parse("fx/backgroundTerminals/list"));
    try std.testing.expectEqual(AcpMethod.fx_unified_exec_write_stdin, AcpMethod.parse("fx/unifiedExec/writeStdin"));
    try std.testing.expectEqual(AcpMethod.fx_unified_exec_kill, AcpMethod.parse("fx/unifiedExec/kill"));
    try std.testing.expectEqual(AcpMethod.fx_provider_switch, AcpMethod.parse("fx/provider/switch"));
    try std.testing.expectEqual(AcpMethod.fx_provider_configure, AcpMethod.parse("fx/provider/configure"));
    try std.testing.expectEqual(AcpMethod.fx_provider_setup_start, AcpMethod.parse("fx/provider/setup/start"));
    try std.testing.expectEqual(AcpMethod.fx_provider_setup_status, AcpMethod.parse("fx/provider/setup/status"));
    try std.testing.expectEqual(AcpMethod.fx_provider_login_start, AcpMethod.parse("fx/provider/login/start"));
    try std.testing.expectEqual(AcpMethod.fx_provider_login_status, AcpMethod.parse("fx/provider/login/status"));
    try std.testing.expectEqual(AcpMethod.fx_provider_login_submit_code, AcpMethod.parse("fx/provider/login/submitCode"));
    try std.testing.expectEqual(AcpMethod.fx_provider_login_cancel, AcpMethod.parse("fx/provider/login/cancel"));
    try std.testing.expectEqual(AcpMethod.fx_provider_usage, AcpMethod.parse("fx/provider/usage"));
    try std.testing.expectEqual(AcpMethod.fx_tool_mode_set, AcpMethod.parse("fx/toolMode/set"));
    try std.testing.expectEqual(AcpMethod.unknown, AcpMethod.parse("workspace/unknown"));
}

test "ACP prompt gate policy keeps lifecycle interruption responsive" {
    try std.testing.expect(!AcpMethod.initialize.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_cancel.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_new.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_load.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_resume.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_close.waitsForActivePrompt());
    try std.testing.expect(AcpMethod.session_list.waitsForActivePrompt());
    try std.testing.expect(AcpMethod.session_prompt.waitsForActivePrompt());
    try std.testing.expect(AcpMethod.session_set_config_option.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.session_set_mode.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.fx_turn_steer.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.fx_turn_status.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.fx_background_terminals_list.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.fx_unified_exec_write_stdin.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.fx_unified_exec_kill.waitsForActivePrompt());
    try std.testing.expect(AcpMethod.fx_provider_switch.waitsForActivePrompt());
    try std.testing.expect(AcpMethod.fx_provider_configure.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.fx_provider_setup_start.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.fx_provider_setup_status.waitsForActivePrompt());
    try std.testing.expect(AcpMethod.fx_provider_login_start.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.fx_provider_login_status.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.fx_provider_login_submit_code.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.fx_provider_login_cancel.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.fx_provider_usage.waitsForActivePrompt());
    try std.testing.expect(!AcpMethod.fx_tool_mode_set.waitsForActivePrompt());
    try std.testing.expect(AcpMethod.unknown.waitsForActivePrompt());
}

test "ACP provider job gate leaves control-plane methods responsive" {
    try std.testing.expect(AcpMethod.session_cancel.allowedDuringProviderJob());
    try std.testing.expect(AcpMethod.fx_turn_status.allowedDuringProviderJob());
    try std.testing.expect(AcpMethod.fx_unified_exec_write_stdin.allowedDuringProviderJob());
    try std.testing.expect(AcpMethod.fx_unified_exec_kill.allowedDuringProviderJob());
    try std.testing.expect(AcpMethod.fx_provider_login_status.allowedDuringProviderJob());
    try std.testing.expect(AcpMethod.fx_provider_setup_status.allowedDuringProviderJob());
    try std.testing.expect(AcpMethod.fx_provider_login_submit_code.allowedDuringProviderJob());
    try std.testing.expect(AcpMethod.fx_provider_login_cancel.allowedDuringProviderJob());
    try std.testing.expect(AcpMethod.fx_provider_usage.allowedDuringProviderJob());
    try std.testing.expect(AcpMethod.fx_tool_mode_set.allowedDuringProviderJob());
    try std.testing.expect(!AcpMethod.session_prompt.allowedDuringProviderJob());
    try std.testing.expect(!AcpMethod.fx_provider_switch.allowedDuringProviderJob());
}

test "ACP Gateway discovery and persistence honor explicit home without changing process binding" {
    const alloc = std.testing.allocator;
    gateway_session.resetProcessBindingForTests();
    defer gateway_session.resetProcessBindingForTests();
    var process = gateway_session.Session{
        .base_url = try alloc.dupe(u8, "https://process.example.test/v1"),
        .api_key = try alloc.dupe(u8, "process-key"),
    };
    defer process.deinit(alloc);
    try gateway_session.setProcessBinding(process);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var state = ServerState{ .alloc = alloc, .cfg = undefined, .writer = jsonrpc.Writer.init() };
    defer state.deinit();
    state.cfg.home_override = home;
    state.cfg.credential_override = null;
    try persistGatewayBinding(&state, "https://embedded.example.test/v1", "embedded-key");
    try installStoredGatewayBinding(&state);
    try std.testing.expectEqualStrings("https://embedded.example.test/v1/responses", state.gateway_binding.?.chat_url);
    try std.testing.expectEqualStrings("embedded-key", state.gateway_binding.?.credential.token);
    var unchanged = (try gateway_session.copyProcessBinding(alloc)).?;
    defer unchanged.deinit(alloc);
    try std.testing.expectEqualStrings("process-key", unchanged.api_key);
    try std.testing.expectEqualStrings("https://process.example.test/v1", unchanged.base_url);
}

test "ACP custom gateway binding survives subscription credential activation" {
    const alloc = std.testing.allocator;
    var state = ServerState{
        .alloc = alloc,
        .cfg = undefined,
        .writer = jsonrpc.Writer.init(),
    };
    defer state.deinit();
    state.gateway_binding = .{
        .chat_url = try alloc.dupe(u8, "https://custom.example.test/v1/responses"),
        .models_url = try alloc.dupe(u8, "https://custom.example.test/v1/models"),
        .credential = .{
            .token = try alloc.dupe(u8, "custom-key"),
            .source = .openai_api_key,
        },
    };
    state.api_key = try alloc.dupe(u8, "subscription-token");
    state.credential_source = .chatgpt_subscription;

    try std.testing.expectEqualStrings(
        "https://custom.example.test/v1/responses",
        gatewayChatUrl(&state),
    );
    try std.testing.expectEqualStrings(
        "custom-key",
        borrowedCredentialForProvider(&state, .gateway).?.token,
    );
    try std.testing.expectEqualStrings(
        "subscription-token",
        borrowedCredentialForProvider(&state, .codex).?.token,
    );

    try std.testing.expect(try selectCredentialForProvider(&state, .gateway));
    try std.testing.expectEqual(types.CredentialSource.openai_api_key, state.credential_source.?);
    try std.testing.expectEqualStrings("custom-key", state.api_key);

    var snapshot = (try snapshotGatewayRoute(&state, alloc)).?;
    defer snapshot.deinit(alloc);
    var replacement = replacement: {
        const chat_url = try alloc.dupe(u8, "https://replacement.example.test/v1/responses");
        errdefer alloc.free(chat_url);
        const models_url = try alloc.dupe(u8, "https://replacement.example.test/v1/models");
        errdefer alloc.free(models_url);
        const credential = credentials.Credential{
            .token = try alloc.dupe(u8, "replacement-key"),
            .source = .openai_api_key,
        };
        break :replacement GatewayConnectionBinding{
            .chat_url = chat_url,
            .models_url = models_url,
            .credential = credential,
        };
    };
    state.gateway_binding_mutex.lockUncancelable(std.testing.io);
    if (state.gateway_binding) |*binding| binding.deinit(alloc);
    state.gateway_binding = replacement;
    replacement = undefined;
    state.gateway_binding_mutex.unlock(std.testing.io);

    try std.testing.expectEqualStrings("https://custom.example.test/v1/responses", snapshot.chat_url);
    try std.testing.expectEqualStrings("custom-key", snapshot.credential.token);
    try std.testing.expectEqualStrings(
        "https://replacement.example.test/v1/responses",
        gatewayChatUrl(&state),
    );
}

test "ACP active prompt admits and drains only matching turn steers" {
    const alloc = std.testing.allocator;
    var active = ActivePrompt{
        .state = undefined,
        .alloc = alloc,
        .msg = .{},
        .mode = "code",
        .permission_mode = .auto,
    };
    defer active.deinit();

    try std.testing.expectEqual(
        ActivePrompt.SteerAdmission.turn_not_ready,
        try active.admitSteer(41, "first"),
    );
    active.setTurnId(41);
    try std.testing.expectEqual(
        ActivePrompt.SteerAdmission.turn_mismatch,
        try active.admitSteer(42, "wrong"),
    );
    try std.testing.expectEqual(
        ActivePrompt.SteerAdmission.accepted,
        try active.admitSteer(41, "focus the failing test"),
    );
    try std.testing.expectEqual(@as(usize, 1), active.snapshot().pending_steers);

    const steer = (try active.takeSteer(alloc, 41, false)) orelse return error.TestExpectedEqual;
    defer worker_runtime.freeQueuedPrompt(alloc, steer);
    try std.testing.expectEqualStrings("focus the failing test", steer.prompt);
    try std.testing.expectEqual(@as(usize, 0), active.snapshot().pending_steers);

    try std.testing.expect((try active.takeSteer(alloc, 41, true)) == null);
    try std.testing.expect(!active.snapshot().accepting_steers);
    try std.testing.expectEqual(
        ActivePrompt.SteerAdmission.turn_finished,
        try active.admitSteer(41, "late"),
    );
}

test "ACP initialize request validation requires a uint16 protocol version" {
    const alloc = std.testing.allocator;
    const valid = try parseInitializeRequest(
        alloc,
        "{\"protocolVersion\":1,\"clientCapabilities\":{\"fs\":{\"readTextFile\":true},\"terminal\":true}}",
    );
    try std.testing.expect(valid.client_fs_read);
    try std.testing.expect(!valid.client_fs_write);
    try std.testing.expect(valid.client_terminal);

    _ = try parseInitializeRequest(alloc, "{\"protocolVersion\":0}");
    _ = try parseInitializeRequest(alloc, "{\"protocolVersion\":2}");
    _ = try parseInitializeRequest(alloc, "{\"protocolVersion\":65535}");

    const cases = [_]struct {
        params: ?[]const u8,
        expected: anyerror,
    }{
        .{ .params = null, .expected = error.InvalidInitializeParams },
        .{ .params = "{}", .expected = error.InvalidInitializeParams },
        .{ .params = "[]", .expected = error.InvalidInitializeParams },
        .{ .params = "{\"protocolVersion\":\"one\"}", .expected = error.InvalidInitializeParams },
        .{ .params = "{\"protocolVersion\":-1}", .expected = error.InvalidInitializeParams },
        .{ .params = "{\"protocolVersion\":70000}", .expected = error.InvalidInitializeParams },
    };
    for (cases) |case| {
        try std.testing.expectError(
            case.expected,
            parseInitializeRequest(alloc, case.params),
        );
    }
}

test "ACP permission responses map canonical option ids" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { json: []const u8, expected: types.ToolPermissionDecision }{
        .{ .json = "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow_once\"}}", .expected = .once },
        .{ .json = "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow_always\"}}", .expected = .always },
        .{ .json = "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"reject_once\"}}", .expected = .deny },
        .{ .json = "{\"outcome\":{\"outcome\":\"cancelled\"}}", .expected = .deny },
    };
    for (cases) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.expected, parsePermissionDecision(parsed.value).?);
    }
    const malformed_cases = [_][]const u8{
        "{\"outcome\":{\"outcome\":\"selected\"}}",
        "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow_forever\"}}",
        "{\"outcome\":{\"outcome\":\"granted\"}}",
        "{\"outcome\":\"selected\"}",
        "{}",
        "[]",
    };
    for (malformed_cases) |json| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsePermissionDecision(parsed.value) == null);
    }
}

test "ACP outbound waiters resolve to deny on cancellation" {
    var state = ServerState{
        .alloc = std.testing.allocator,
        .cfg = undefined,
        .writer = jsonrpc.Writer.init(),
    };
    defer state.pending_outbound.deinit(state.alloc);

    const id = beginPermissionRequest(&state) orelse return error.TestExpectedEqual;
    const concurrent = beginPermissionRequest(&state) orelse return error.TestExpectedEqual;

    cancelPendingOutbound(&state);
    try std.testing.expectEqual(types.ToolPermissionDecision.deny, awaitPermissionDecision(&state, id));
    try std.testing.expectEqual(types.ToolPermissionDecision.deny, awaitPermissionDecision(&state, concurrent));
    try std.testing.expectEqual(@as(usize, 0), state.pending_outbound.count());

    const second = beginPermissionRequest(&state) orelse return error.TestExpectedEqual;
    try std.testing.expect(second != id);
    cancelPermissionRequest(&state, second);
    try std.testing.expectEqual(types.ToolPermissionDecision.deny, awaitPermissionDecision(&state, second));
}

test "ACP outbound responses correlate out of order and ignore unknown ids" {
    const alloc = std.testing.allocator;
    var state = ServerState{
        .alloc = alloc,
        .cfg = undefined,
        .writer = jsonrpc.Writer.init(),
    };
    defer state.pending_outbound.deinit(alloc);

    const first = (try beginOutboundRequest(&state, .request)).?;
    const second = (try beginOutboundRequest(&state, .request)).?;
    handleClientResponse(&state, alloc, &.{
        .id = .{ .integer = @intCast(second) },
        .result_raw = "{\"action\":\"decline\"}",
    });
    handleClientResponse(&state, alloc, &.{
        .id = .{ .integer = 9999 },
        .result_raw = "{\"action\":\"accept\"}",
    });
    handleClientResponse(&state, alloc, &.{
        .id = .{ .integer = @intCast(first) },
        .result_raw = "{\"action\":\"cancel\"}",
    });

    var second_response = awaitOutboundResponse(&state, second, .request).?;
    defer second_response.deinit(alloc);
    try std.testing.expectEqualStrings("{\"action\":\"decline\"}", second_response.result_json.?);
    var first_response = awaitOutboundResponse(&state, first, .request).?;
    defer first_response.deinit(alloc);
    try std.testing.expectEqualStrings("{\"action\":\"cancel\"}", first_response.result_json.?);
    try std.testing.expectEqual(@as(usize, 0), state.pending_outbound.count());
}

const AcpModelBoundaryFailure = struct {
    target: session_log.Boundary,

    fn hit(raw: ?*anyopaque, point: session_log.Boundary) !void {
        const self: *AcpModelBoundaryFailure = @ptrCast(@alignCast(raw.?));
        if (point == self.target) return error.InjectedBoundaryFailure;
    }

    fn options(self: *AcpModelBoundaryFailure) session_log.Options {
        return .{ .test_controls = .{
            .context = self,
            .boundary_fn = hit,
        } };
    }
};

fn acpModelTestState(
    alloc: Allocator,
    id: []const u8,
    workspace_root: []const u8,
) !session_codec.DurableSessionState {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const origin_workspace_root = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(origin_workspace_root);
    const current_workspace_root = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(current_workspace_root);
    const model = try alloc.dupe(u8, "old-model");
    errdefer alloc.free(model);
    const history = try alloc.alloc(session_runtime.HistoryTurn, 0);
    return .{
        .id = owned_id,
        .origin_workspace_root = origin_workspace_root,
        .workspace_root = current_workspace_root,
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session_runtime.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = model,
            .effort = .auto,
            .fast_mode = false,
        },
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

test "ACP model commit rolls back before later request can succeed" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace",
    );
    defer alloc.free(workspace);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var state = try acpModelTestState(alloc, "acp-model-rollback", workspace);
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    defer writable.deinit(alloc);
    var active_model = try alloc.dupe(u8, "old-model");
    defer alloc.free(active_model);
    var failure = AcpModelBoundaryFailure{ .target = .after_event_sync };

    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        commitSessionModel(
            alloc,
            &writable,
            &active_model,
            "rejected-model",
            failure.options(),
        ),
    );
    try std.testing.expectEqualStrings("old-model", active_model);
    try std.testing.expectEqualStrings(
        "old-model",
        writable.state.preferences.model,
    );
    try std.testing.expect(writable.degradedTail() == null);

    try commitSessionModel(
        alloc,
        &writable,
        &active_model,
        "accepted-model",
        .{},
    );
    try std.testing.expectEqualStrings("accepted-model", active_model);
    try std.testing.expectEqualStrings(
        "accepted-model",
        writable.state.preferences.model,
    );
}

test "ACP effort and Fast preferences commit atomically with the model" {
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
    var state = try acpModelTestState(alloc, "acp-controls-atomic", workspace);
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    defer writable.deinit(alloc);
    var active: ActiveSessionState = undefined;
    active.model = try alloc.dupe(u8, "old-model");
    defer alloc.free(active.model);
    active.effort = .auto;
    active.fast_mode = false;

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        commitSessionPreferences(
            failing.allocator(),
            &writable,
            &active,
            .{
                .model = "oom-model",
                .effort = types.ReasoningEffort.literal("high"),
                .fast_mode = true,
            },
            .{},
        ),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqualStrings("old-model", active.model);
    try std.testing.expect(active.effort.isDefault());
    try std.testing.expect(!active.fast_mode);
    try std.testing.expectEqualStrings("old-model", writable.state.preferences.model);

    var failure = AcpModelBoundaryFailure{ .target = .after_event_sync };
    try std.testing.expectError(
        error.SessionPersistenceDegraded,
        commitSessionPreferences(
            alloc,
            &writable,
            &active,
            .{
                .model = "rejected-model",
                .effort = types.ReasoningEffort.literal("high"),
                .fast_mode = true,
            },
            failure.options(),
        ),
    );
    try std.testing.expectEqualStrings("old-model", active.model);
    try std.testing.expect(active.effort.isDefault());
    try std.testing.expect(!active.fast_mode);
    try std.testing.expectEqualStrings("old-model", writable.state.preferences.model);
    try std.testing.expect(writable.state.preferences.effort.isDefault());
    try std.testing.expect(!writable.state.preferences.fast_mode);
    try std.testing.expect(writable.degradedTail() == null);

    try commitSessionPreferences(
        alloc,
        &writable,
        &active,
        .{
            .model = "accepted-model",
            .effort = types.ReasoningEffort.literal("high"),
            .fast_mode = true,
        },
        .{},
    );
    try std.testing.expectEqualStrings("accepted-model", active.model);
    try std.testing.expect(active.effort.eql(types.ReasoningEffort.literal("high")));
    try std.testing.expect(active.fast_mode);
    try std.testing.expectEqualStrings("accepted-model", writable.state.preferences.model);
    try std.testing.expect(writable.state.preferences.effort.eql(types.ReasoningEffort.literal("high")));
    try std.testing.expect(writable.state.preferences.fast_mode);
}

test "ACP indeterminate model commit leaves staged runtime value unapplied" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace",
    );
    defer alloc.free(workspace);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var state = try acpModelTestState(
        alloc,
        "acp-model-indeterminate",
        workspace,
    );
    defer state.deinit(alloc);
    var writable = try store.startWritableSession(alloc, state);
    defer writable.deinit(alloc);
    var active_model = try alloc.dupe(u8, "old-model");
    defer alloc.free(active_model);
    var failure = AcpModelBoundaryFailure{
        .target = .after_target_namespace_sync,
    };

    const result = commitSessionModel(
        alloc,
        &writable,
        &active_model,
        "uncertain-model",
        failure.options(),
    );
    try std.testing.expectError(error.SessionCommitIndeterminate, result);
    try std.testing.expectEqualStrings("old-model", active_model);
    try std.testing.expect(
        modelCommitFailureTerminatesConnection(
            error.SessionCommitIndeterminate,
        ),
    );
    try std.testing.expect(
        modelCommitFailureTerminatesConnection(
            error.SessionLogCompactionIndeterminate,
        ),
    );

    var server_state = ServerState{
        .alloc = alloc,
        .cfg = undefined,
        .writer = jsonrpc.Writer.init(),
    };
    defer server_state.deinit();
    try std.testing.expect(markIndeterminateCommitTerminal(
        &server_state,
        error.SessionCommitIndeterminate,
    ));
    try std.testing.expect(server_state.terminate_connection.load(.acquire));
}

test "ACP model commits honor the active session write boundary" {
    const alloc = std.testing.allocator;
    var active: ActiveSessionState = undefined;
    active.writable = null;
    active.session_write_mutex = .init;
    active.model = try alloc.dupe(u8, "old-model");
    defer alloc.free(active.model);

    const Worker = struct {
        alloc: Allocator,
        active: *ActiveSessionState,
        started: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.started.store(true, .seq_cst);
            commitActiveSessionModel(
                self.alloc,
                self.active,
                "new-model",
                .{},
            ) catch |err| {
                self.failure = err;
            };
            self.done.store(true, .seq_cst);
        }
    };
    var worker = Worker{
        .alloc = alloc,
        .active = &active,
    };
    active.session_write_mutex.lockUncancelable(io_mod.getIo());
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    while (!worker.started.load(.seq_cst)) std.Thread.yield() catch {};
    for (0..100) |_| std.Thread.yield() catch {};
    const blocked_at_boundary = !worker.done.load(.seq_cst);
    active.session_write_mutex.unlock(io_mod.getIo());
    thread.join();

    try std.testing.expect(blocked_at_boundary);
    try std.testing.expect(worker.done.load(.seq_cst));
    try std.testing.expectEqual(
        error.SessionPersistenceUnavailable,
        worker.failure.?,
    );
}

test "ACP publishes an account-bound refreshed Codex token for later prompts" {
    const alloc = std.testing.allocator;
    var state: ServerState = undefined;
    state.alloc = alloc;
    state.api_key = try alloc.dupe(u8, "stale-token");
    state.account_id = try alloc.dupe(u8, "acct-1");
    state.credential_source = .chatgpt_subscription;
    state.cfg.provider_set = .{ .gateway = .{}, .codex = .{}, .grok = .{} };
    state.account_usage = account_usage_runtime.Runtime.init(alloc);
    var active: ActiveSessionState = undefined;
    active.api_key = state.api_key;
    active.account_id = state.account_id;
    active.credential_source = .chatgpt_subscription;
    state.active_session = active;
    defer {
        state.account_usage.deinit();
        secret.zeroAndFree(alloc, state.api_key);
        alloc.free(state.account_id.?);
    }

    try publishRefreshedSubscriptionToken(&state, "fresh-token", .chatgpt_subscription, "acct-1");

    try std.testing.expectEqualStrings("fresh-token", state.api_key);
    try std.testing.expectEqualStrings("fresh-token", state.active_session.?.api_key);
    try std.testing.expectEqualStrings("acct-1", state.account_id.?);
    try std.testing.expectEqualStrings("acct-1", state.active_session.?.account_id.?);
}

test "ACP rejects refreshed Codex tokens for another account" {
    const alloc = std.testing.allocator;
    var state: ServerState = undefined;
    state.alloc = alloc;
    state.api_key = try alloc.dupe(u8, "stale-token");
    state.account_id = try alloc.dupe(u8, "acct-1");
    state.credential_source = .chatgpt_subscription;
    state.active_session = null;
    defer {
        secret.zeroAndFree(alloc, state.api_key);
        alloc.free(state.account_id.?);
    }

    try std.testing.expectError(
        error.ChatGptAccountChanged,
        publishRefreshedSubscriptionToken(&state, "wrong-token", .chatgpt_subscription, "acct-2"),
    );
    try std.testing.expectEqualStrings("stale-token", state.api_key);
}

test "ACP usage flush preserves snapshot ownership on allocation failure" {
    const alloc = std.testing.allocator;
    var runtime: session_runtime.SessionRuntime = .{ .max_history_turns = 8 };
    var runtime_owned = true;
    defer if (runtime_owned) runtime.deinit(alloc);
    try runtime.appendAssistantHistoryTurn(alloc, "question", "answer");
    const observation = try session_usage.InvocationObservation.begin(&runtime.usage);
    try observation.completeDirect(
        alloc,
        "provider/model",
        .{ .input_tokens = 10, .output_tokens = 2 },
        .{ .http_ok = true, .terminal_finish_reason = .stop },
    );

    var durable = try acpModelTestState(
        alloc,
        "acp-usage-flush",
        "/tmp/workspace",
    );
    var durable_owned = true;
    defer if (durable_owned) durable.deinit(alloc);
    durable.usage = try runtime.usage.snapshot(alloc);

    var writable: session_store.LoadedWritableSession = undefined;
    writable.state = durable;
    durable_owned = false;
    var active: ActiveSessionState = undefined;
    active.writable = writable;
    active.session_rt = runtime;
    runtime_owned = false;
    var state: ServerState = undefined;
    state.active_session = active;
    defer {
        state.active_session.?.session_rt.deinit(alloc);
        state.active_session.?.writable.?.state.deinit(alloc);
    }

    var counting = std.testing.FailingAllocator.init(alloc, .{});
    {
        var current = try state.active_session.?.writable.?.state.dupe(
            counting.allocator(),
        );
        defer current.deinit(counting.allocator());
        const history = try state.active_session.?.session_rt.snapshotHistory(
            counting.allocator(),
        );
        defer types.freeHistoryTurnSlice(counting.allocator(), history);
    }

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = counting.alloc_index },
    );
    state.alloc = failing.allocator();
    try std.testing.expectError(
        error.OutOfMemory,
        flushActiveSessionUsage(&state),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(
        failing.allocated_bytes,
        failing.freed_bytes,
    );
}
