const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const app_lifecycle = @import("../app/app_lifecycle.zig");
const chatgpt_oauth = @import("../auth/chatgpt_oauth.zig");
const grok_oauth = @import("../auth/grok_oauth.zig");
const gateway_session = @import("../auth/gateway_session.zig");
const provider_setup = @import("../auth/provider_setup.zig");
const acp_runner = @import("acp_runner.zig");
const cli_ask = @import("cli_ask.zig");
const cli_replay = @import("cli_replay.zig");
const command_specs = @import("../slash_commands/command_specs.zig");
const collections = @import("../shared/collections.zig");
const config_runtime = @import("../config/config_runtime.zig");
const credentials = @import("../auth/credentials.zig");
const model_provider = @import("../config/model_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const doctor_runtime = @import("doctor_runtime.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const provider_route = @import("../gateway/provider_route.zig");
const provider_set = @import("../gateway/provider_set.zig");
const background_process_provider = @import(
    "../execution/background_process_provider.zig",
);
const github_publish = @import("../github/github_publish.zig");
const github_workflows = @import("../github/github_workflows.zig");
const host = @import("../hosts/host.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const provider_catalog = @import("../auth/provider_catalog.zig");
const output_contracts = @import("../output/output_contracts.zig");
const prompt_policy = @import("../config/prompt_policy.zig");
const session_store = @import("../session/session_store.zig");
const usage_report = @import("../session/usage_report.zig");
const skill_contract = @import("../skills/skill_contract.zig");
const types = @import("../shared/types.zig");
const test_builtin_gateway = if (builtin.is_test)
    @import("../../builtins/responses.zig")
else
    struct {};
const context_contract = @import("../workspace/context_contract.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const workspace_access = @import("../workspace/workspace_access.zig");
const workspace_commands = @import("../workspace/workspace_commands.zig");
const usage_cli_runtime = @import("usage_cli_runtime.zig");

const Allocator = std.mem.Allocator;
const CommandCatalog = command_specs.TopLevelRegistry;
const TopLevelKind = command_specs.TopLevelKind;

pub const Command = union(enum) {
    interactive,
    help,
    ask: []const [:0]const u8,
    acp: []const [:0]const u8,
    pr: []const [:0]const u8,
    issue: []const [:0]const u8,
    setup: []const [:0]const u8,
    login: []const [:0]const u8,
    logout: []const [:0]const u8,
    status: []const [:0]const u8,
    permissions: []const [:0]const u8,
    models: []const [:0]const u8,
    provider: []const [:0]const u8,
    doctor: []const [:0]const u8,
    session: []const [:0]const u8,
    sessions: []const [:0]const u8,
    resume_session: ResumeInvocation,
    usage: []const [:0]const u8,
    replay: []const [:0]const u8,
    workspace: []const [:0]const u8,
    unknown: []const u8,
};

const ResumeInvocation = struct {
    args: []const [:0]const u8,
    top_level_alias: bool = false,
};

const resume_id_alias_prefix = "--resume-";

// The one resume alias that asks which session to open. Every other spelling
// names its target, so it resumes without a prompt.
const resume_picker_alias = "-r";

pub const ResumeTarget = union(enum) {
    pick,
    last,
    id: []u8,

    pub fn deinit(self: *ResumeTarget, alloc: Allocator) void {
        switch (self.*) {
            .pick, .last => {},
            .id => |value| alloc.free(value),
        }
        self.* = undefined;
    }
};

pub const LaunchModifiers = struct {
    context_limit_overrides: []config_runtime.context_limits.Override = &.{},
    additional_directories: [][]u8 = &.{},
    saved_directories_suppressed: bool = false,

    pub fn deinit(self: *LaunchModifiers, alloc: Allocator) void {
        if (self.context_limit_overrides.len > 0) alloc.free(self.context_limit_overrides);
        for (self.additional_directories) |path| alloc.free(path);
        if (self.additional_directories.len > 0) alloc.free(self.additional_directories);
        self.* = .{};
    }

    pub fn hasWorkspaceModifiers(self: LaunchModifiers) bool {
        return self.additional_directories.len > 0 or self.saved_directories_suppressed;
    }
};

pub const InteractiveLaunch = struct {
    requested_resume: ?ResumeTarget = null,
    modifiers: LaunchModifiers = .{},

    pub fn deinit(self: *InteractiveLaunch, alloc: Allocator) void {
        if (self.requested_resume) |*target| target.deinit(alloc);
        self.modifiers.deinit(alloc);
        self.* = undefined;
    }
};

pub const RunResult = union(enum) {
    interactive: InteractiveLaunch,
    handled_success,
    handled_failure,
    handled_exit: u8,
};

const version_usage = "usage: fx --version\n";

pub const Config = struct {
    version: []const u8 = "",
    revision: []const u8 = "",
    command_catalog: CommandCatalog,
    default_model: []const u8,
    default_agent_step_limit: usize,
    models_path: []const u8,
    gateway_retry_count: usize,
    gateway_chat_url: []const u8,
    gateway_provider: gateway_provider.Provider,
    provider_set: provider_set.Set,
    background_process_provider: background_process_provider.Provider =
        background_process_provider.unavailable_provider,
    url_opener: host.UrlOpener,
    secret_store: host.SecretStore,
    prompt_policy: prompt_policy.Policy,
    skill_root_policy: skill_contract.RootPolicy,
    ignored_list_entries: []const []const u8,
    max_list_entries: usize,
    max_read_file_bytes: usize,
    max_read_file_lines: usize,
    max_read_file_line_len: usize,
    max_command_output_bytes: usize,
    max_tool_result_bytes: usize,
    max_history_turns: usize,
    context_registry: context_contract.Registry,
    mode_registry: mode_registry.Registry,
    tool_set: tool_set_contract.ToolSet,
    acp_runner: acp_runner.Runner,
};

const LocalSurfaceOptions = struct {
    format: output_contracts.OutputFormat = .text,
};

fn parseLoginProvider(rest: []const [:0]const u8) !model_provider.ProviderId {
    if (rest.len != 1) return error.InvalidLoginProviderArgs;
    const provider = provider_catalog.parse(rest[0]) orelse return error.InvalidLoginProviderArgs;
    if (provider == .gateway) return error.InvalidLoginProviderArgs;
    return provider;
}

fn parseLogoutProvider(rest: []const [:0]const u8) !model_provider.ProviderId {
    if (rest.len != 1) return error.InvalidLoginProviderArgs;
    return provider_catalog.parse(rest[0]) orelse error.InvalidLoginProviderArgs;
}

fn joinArgWords(alloc: Allocator, words: []const [:0]const u8) ![]u8 {
    if (words.len == 1) return alloc.dupe(u8, words[0]);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (words, 0..) |word, index| {
        if (index != 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(word);
    }
    return out.toOwnedSlice();
}

fn configureGatewayProvider(
    alloc: Allocator,
    cfg: Config,
    deps: RunDeps,
    base_url: []const u8,
    api_key: []const u8,
) !bool {
    gateway_session.validate(base_url, api_key) catch {
        try writeProviderActivationError(alloc, deps, .provider_command, "invalid Gateway base URL or API key");
        return false;
    };
    const models_url = provider_route.appendModelsEndpointAlloc(alloc, base_url) catch |err| {
        debug_trace.logf("provider", "gateway configure endpoint failed err={s}", .{@errorName(err)});
        try writeProviderActivationError(alloc, deps, .provider_command, "invalid Gateway base URL");
        return false;
    };
    defer alloc.free(models_url);
    var credential = credentials.Credential{
        .token = try alloc.dupe(u8, api_key),
        .source = .openai_api_key,
    };
    defer credential.deinit(alloc);
    const catalog_provider = cfg.provider_set.select(.gateway).model_catalog orelse {
        try writeProviderActivationError(alloc, deps, .provider_command, "Gateway model catalog is unavailable");
        return false;
    };
    const fetch_result = model_catalog.fetchCatalog(catalog_provider, alloc, .{
        .access = credentials.catalogAccessAt(credential, io_mod.milliTimestamp()),
        .endpoint = models_url,
        .view = .picker,
    });
    var loaded = switch (fetch_result) {
        .loaded => |loaded| loaded,
        .failed => |failure| {
            debug_trace.logf("catalog", "gateway configure catalog failed category={s}", .{@tagName(failure.failure.category)});
            try writeProviderActivationError(alloc, deps, .provider_command, "could not load the Gateway model catalog");
            return false;
        },
    };
    defer model_catalog.freeModelCatalog(alloc, &loaded.catalog);
    if (loaded.catalog.items.len == 0) {
        try writeProviderActivationError(alloc, deps, .provider_command, "Gateway model catalog is empty");
        return false;
    }
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace_root);
    var settings = try config_runtime.loadMergedSettings(alloc, workspace_root);
    defer settings.deinit(alloc);
    const selected_model = selectCatalogModel(loaded.catalog.items, settings.models.get(.gateway)).?;
    gateway_session.saveAndActivate(alloc, base_url, api_key) catch |err| {
        debug_trace.logf("provider", "gateway binding persist failed err={s}", .{@errorName(err)});
        try writeProviderActivationError(alloc, deps, .provider_command, "failed to save Gateway URL and API key");
        return false;
    };
    // The catalog above belongs to the new binding. The startup Config still
    // contains the old endpoint, and an already-selected Gateway may have a
    // model that the replacement catalog does not support.
    var preference = config_runtime.attemptUserPreferences(alloc, .{
        .provider = .gateway,
        .model_preference = .{ .provider = .gateway, .model = selected_model },
    });
    defer preference.deinit(alloc);
    switch (preference) {
        .outcome => {},
        .failure => {
            try writeProviderActivationError(alloc, deps, .provider_command, "Gateway binding saved, but provider selection could not be saved");
            return false;
        },
    }
    try writeStdout(deps, "Gateway URL and API key saved.\n");
    return true;
}

fn selectCatalogModel(
    entries: []const model_catalog.ModelCatalogEntry,
    saved: ?[]const u8,
) ?[]const u8 {
    if (saved) |candidate| {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.id, candidate)) return entry.id;
        }
    }
    return if (entries.len > 0) entries[0].id else null;
}

const SessionListOptions = struct {
    format: output_contracts.OutputFormat = .text,
    scope: session_store.SessionListScope = .current_workspace,
    limit: usize = session_store.session_list_default_limit,
    continuation: ?session_store.ResumableSessionContinuation = null,
};

const UsageOptions = struct {
    format: output_contracts.OutputFormat = .text,
    scope: usage_report.Scope = .days_30,
    codex_account: bool = false,
};

const WorkspaceOptions = struct {
    format: output_contracts.OutputFormat = .text,
    action: ?workspace_commands.Action = null,
};

// `fx session` reads one saved session, so it names its target and never
// reaches for the picker that `ResumeTarget` carries.
const SessionDetailTarget = union(enum) {
    last,
    id: []u8,

    fn deinit(self: *SessionDetailTarget, alloc: Allocator) void {
        switch (self.*) {
            .last => {},
            .id => |value| alloc.free(value),
        }
        self.* = undefined;
    }
};

const SessionDetailOptions = struct {
    format: output_contracts.OutputFormat = .text,
    target: ?SessionDetailTarget = null,

    fn deinit(self: *SessionDetailOptions, alloc: Allocator) void {
        if (self.target) |*target| target.deinit(alloc);
        self.* = undefined;
    }
};

const SessionMigrationOptions = struct {
    format: output_contracts.OutputFormat = .text,
    session_id: []u8,
    allow_large: bool = false,

    fn deinit(self: *SessionMigrationOptions, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

const SessionRecoveryOptions = struct {
    format: output_contracts.OutputFormat = .text,
    session_id: []u8,

    fn deinit(self: *SessionRecoveryOptions, alloc: Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

const AcpOptions = struct {
    model: ?[]const u8 = null,
    log_file: ?[]const u8 = null,
};

const WorkflowOptions = struct {
    auto_permission: bool,
    create: bool,
    context: []u8,

    fn deinit(self: WorkflowOptions, alloc: Allocator) void {
        alloc.free(self.context);
    }
};

const WriteFn = *const fn (?*anyopaque, []const u8) anyerror!void;
const LoadStartupStateFn = *const fn (Allocator, oauth_transport.Provider, host.SecretStore, []const u8, usize) anyerror!app_lifecycle.StartupState;
const LoadCatalogStartupStateFn = *const fn (Allocator, host.SecretStore, []const u8, usize) anyerror!app_lifecycle.StartupState;
const LoadStartupStateWithoutCredentialsFn = *const fn (Allocator, []const u8, usize) anyerror!app_lifecycle.StartupState;
const LoadStartupStatusFn = *const fn (Allocator, host.SecretStore, []const u8, usize) anyerror!app_lifecycle.StartupStatus;
const GetenvFn = *const fn (?*anyopaque, []const u8) ?[]const u8;
const EnvironMapFn = *const fn (?*anyopaque) ?*const std.process.Environ.Map;
const SelfExePathFn = *const fn (?*anyopaque, Allocator) anyerror![]u8;
const RunDeps = struct {
    stdout_ctx: ?*anyopaque = null,
    stderr_ctx: ?*anyopaque = null,
    env_ctx: ?*anyopaque = null,
    self_exe_ctx: ?*anyopaque = null,
    write_stdout: WriteFn = writeRealStdout,
    write_stderr: WriteFn = writeRealStderr,
    load_startup_state: LoadStartupStateFn = app_lifecycle.loadStartupState,
    load_catalog_startup_state: LoadCatalogStartupStateFn = app_lifecycle.loadCatalogStartupState,
    load_startup_state_without_credentials: LoadStartupStateWithoutCredentialsFn = app_lifecycle.loadStartupStateWithoutCredentials,
    load_startup_status: LoadStartupStatusFn = app_lifecycle.loadStartupStatus,
    getenv: GetenvFn = getenvDefault,
    environ_map: EnvironMapFn = environMapDefault,
    self_exe_path: SelfExePathFn = selfExePathDefault,
};

const GlobalLaunchArgs = struct {
    remaining: []const [:0]const u8,
    modifiers: LaunchModifiers = .{},

    fn deinit(self: *GlobalLaunchArgs, alloc: Allocator) void {
        self.modifiers.deinit(alloc);
        self.* = undefined;
    }

    fn takeModifiers(self: *GlobalLaunchArgs) LaunchModifiers {
        const result = self.modifiers;
        self.modifiers = .{};
        return result;
    }
};

fn parseGlobalLaunchArgs(
    alloc: Allocator,
    args: []const [:0]const u8,
) !GlobalLaunchArgs {
    var overrides: std.ArrayList(config_runtime.context_limits.Override) = .empty;
    errdefer overrides.deinit(alloc);
    var directories: std.ArrayList([]u8) = .empty;
    errdefer {
        for (directories.items) |path| alloc.free(path);
        directories.deinit(alloc);
    }
    var suppress_saved = false;

    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--context-limit")) {
            index += 1;
            if (index >= args.len) return error.MissingContextLimitValue;
            try overrides.append(alloc, try config_runtime.context_limits.parseOverride(args[index]));
        } else if (std.mem.startsWith(u8, arg, "--context-limit=")) {
            try overrides.append(alloc, try config_runtime.context_limits.parseOverride(arg["--context-limit=".len..]));
        } else if (std.mem.eql(u8, arg, "--add-dir")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return error.MissingAddDirectoryValue;
            try directories.append(alloc, try alloc.dupe(u8, args[index]));
        } else if (std.mem.startsWith(u8, arg, "--add-dir=")) {
            const value = arg["--add-dir=".len..];
            if (value.len == 0) return error.MissingAddDirectoryValue;
            try directories.append(alloc, try alloc.dupe(u8, value));
        } else if (std.mem.eql(u8, arg, "--no-additional-dirs")) {
            if (suppress_saved) return error.DuplicateAdditionalDirectorySuppression;
            suppress_saved = true;
        } else {
            break;
        }
        index += 1;
    }

    const override_slice = try overrides.toOwnedSlice(alloc);
    errdefer if (override_slice.len > 0) alloc.free(override_slice);
    const directory_slice = try directories.toOwnedSlice(alloc);
    return .{
        .remaining = args[index..],
        .modifiers = .{
            .context_limit_overrides = override_slice,
            .additional_directories = directory_slice,
            .saved_directories_suppressed = suppress_saved,
        },
    };
}

/// Returns the command that follows the supported global launch modifiers.
/// Startup uses this same surface to select the full runtime configuration
/// before the allocating parser runs.
pub fn commandAfterGlobalLaunchArgs(args: []const [:0]const u8) ?[]const u8 {
    const remaining = argsAfterGlobalLaunchArgs(args);
    return if (remaining.len > 0) remaining[0] else null;
}

pub fn argsAfterGlobalLaunchArgs(args: []const [:0]const u8) []const [:0]const u8 {
    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--context-limit") or std.mem.eql(u8, arg, "--add-dir")) {
            index += 1;
            if (index >= args.len) return &.{};
        } else if (!std.mem.startsWith(u8, arg, "--context-limit=") and
            !std.mem.startsWith(u8, arg, "--add-dir=") and
            !std.mem.eql(u8, arg, "--no-additional-dirs"))
        {
            return args[index..];
        }
        index += 1;
    }
    return &.{};
}

pub fn parse(command_catalog: CommandCatalog, args: []const [:0]const u8) Command {
    @setRuntimeSafety(false);
    if (args.len == 0) return .interactive;

    const command = args[0];
    if (command.len == 0) return .{ .unknown = command };
    switch (command[0]) {
        '-', 'h' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .help)) return .help;
            if (command_specs.matchesTopLevel(command_catalog, command, .@"resume") or
                std.mem.startsWith(u8, command, resume_id_alias_prefix))
            {
                return .{ .resume_session = .{
                    .args = args,
                    .top_level_alias = true,
                } };
            }
        },
        'a' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .ask)) return .{ .ask = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .acp)) return .{ .acp = args[1..] };
        },
        'b' => {},
        'c' => {},
        'd' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .doctor)) return .{ .doctor = args[1..] };
        },
        'i' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .issue)) return .{ .issue = args[1..] };
        },
        'l' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .login)) return .{ .login = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .logout)) return .{ .logout = args[1..] };
        },
        'm' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .models)) return .{ .models = args[1..] };
        },
        'p' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .pr)) return .{ .pr = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .permissions)) return .{ .permissions = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .provider)) return .{ .provider = args[1..] };
        },
        'r' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .@"resume")) return .{ .resume_session = .{ .args = args[1..] } };
            if (command_specs.matchesTopLevel(command_catalog, command, .replay)) return .{ .replay = args[1..] };
        },
        's' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .setup)) return .{ .setup = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .status)) return .{ .status = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .sessions)) return .{ .sessions = args[1..] };
            if (command_specs.matchesTopLevel(command_catalog, command, .session)) {
                if (args.len > 1 and std.mem.eql(u8, args[1], "resume")) {
                    return .{ .resume_session = .{ .args = args[2..] } };
                }
                return .{ .session = args[1..] };
            }
        },
        'u' => if (command_specs.matchesTopLevel(command_catalog, command, .usage)) return .{ .usage = args[1..] },
        'w' => {
            if (command_specs.matchesTopLevel(command_catalog, command, .workspace)) return .{ .workspace = args[1..] };
        },
        else => {},
    }
    return .{ .unknown = command };
}

pub const NonInteractiveLaunch = struct {
    global_args: GlobalLaunchArgs,
    effective_args: []const [:0]const u8,
    command: Command,

    pub fn deinit(self: *NonInteractiveLaunch, alloc: Allocator) void {
        self.global_args.deinit(alloc);
        self.* = undefined;
    }
};

pub const InteractiveLaunchParseResult = union(enum) {
    interactive: InteractiveLaunch,
    noninteractive: NonInteractiveLaunch,
};

/// Parses the shared interactive launch language without dispatching commands.
/// Returned launch values own their allocations and must be deinitialized.
pub fn parseInteractiveLaunch(
    alloc: Allocator,
    args: []const [:0]const u8,
    command_catalog: CommandCatalog,
) !InteractiveLaunchParseResult {
    var global_args = try parseGlobalLaunchArgs(alloc, args);
    errdefer global_args.deinit(alloc);
    const effective_args = global_args.remaining;

    if (effective_args.len == 0) {
        return .{ .interactive = .{ .modifiers = global_args.takeModifiers() } };
    }

    const command = parse(command_catalog, effective_args);
    if (topLevelHelpRequest(command_catalog, effective_args) != null) {
        return .{ .noninteractive = .{
            .global_args = global_args,
            .effective_args = effective_args,
            .command = command,
        } };
    }
    switch (command) {
        .interactive => return .{ .interactive = .{
            .modifiers = global_args.takeModifiers(),
        } },
        .resume_session => |invocation| {
            const target = try parseResumeArgs(
                alloc,
                command_catalog,
                invocation.args,
                invocation.top_level_alias,
            );
            return .{ .interactive = .{
                .requested_resume = target,
                .modifiers = global_args.takeModifiers(),
            } };
        },
        else => return .{ .noninteractive = .{
            .global_args = global_args,
            .effective_args = effective_args,
            .command = command,
        } },
    }
}

/// Detects `fx <subcommand> --help` / `-h` and returns the subcommand kind so the
/// caller can render command-specific help. Top-level `fx --help`/`fx help` are
/// handled separately and intentionally excluded here.
fn topLevelHelpRequest(command_catalog: CommandCatalog, args: []const [:0]const u8) ?TopLevelKind {
    if (args.len < 2) return null;
    const kind = command_specs.topLevelKindFromToken(command_catalog, args[0]) orelse return null;
    if (kind == .help) return null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return kind;
    }
    return null;
}

pub fn runIfRequested(alloc: Allocator, args: []const [:0]const u8, cfg: Config) !RunResult {
    return runIfRequestedWithDeps(alloc, args, cfg, .{});
}

pub fn runNoConfigIfRequested(alloc: Allocator, args: []const [:0]const u8, version: []const u8, command_catalog: CommandCatalog) !bool {
    return runNoConfigIfRequestedWithDeps(alloc, args, version, command_catalog, .{});
}

fn runNoConfigIfRequestedWithDeps(
    alloc: Allocator,
    args: []const [:0]const u8,
    version: []const u8,
    command_catalog: CommandCatalog,
    deps: RunDeps,
) !bool {
    if (args.len != 1 or !command_specs.matchesTopLevel(command_catalog, args[0], .help)) {
        return false;
    }
    try writeTopLevelHelp(alloc, command_catalog, deps, version, .stdout);
    return true;
}

const ProviderActivationCaller = enum {
    provider_command,
    provider_login,
};

fn writeProviderActivationError(
    alloc: Allocator,
    deps: RunDeps,
    caller: ProviderActivationCaller,
    detail: []const u8,
) !void {
    const message = try std.fmt.allocPrint(
        alloc,
        "{s}: {s}\n",
        .{ if (caller == .provider_login) "fx login" else "fx provider", detail },
    );
    defer alloc.free(message);
    try writeStderr(deps, message);
}

fn activateProviderSelection(
    alloc: Allocator,
    cfg: Config,
    deps: RunDeps,
    target: model_provider.ProviderId,
    caller: ProviderActivationCaller,
) !bool {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    defer alloc.free(workspace_root);
    var settings = config_runtime.loadMergedSettings(alloc, workspace_root) catch |err| {
        try writeProviderActivationError(alloc, deps, caller, "could not load settings");
        debug_trace.logf("config", "provider selection settings load failed err={s}", .{@errorName(err)});
        return false;
    };
    defer settings.deinit(alloc);

    var resolution = try credentials.resolveForProvider(
        alloc,
        cfg.gateway_provider.oauth_transport,
        cfg.secret_store,
        .refresh_if_needed,
        target,
        settings.credential_source,
    );
    defer if (resolution.credential) |*credential| credential.deinit(alloc);

    const already_selected = (settings.provider orelse .gateway) == target;
    if (caller == .provider_command and already_selected and resolution.credential != null) {
        try writeStdout(deps, switch (target) {
            .gateway => "Gateway is already selected.\n",
            .codex => "Codex is already selected.\n",
            .grok => "Grok is already selected.\n",
        });
        return true;
    }

    var performed_login: ?model_provider.ProviderId = null;
    if (resolution.credential == null and target == .codex and caller == .provider_command) {
        chatgpt_oauth.runLogin(alloc, cfg.gateway_provider.oauth_transport, cfg.url_opener) catch |err| {
            debug_trace.logf("auth", "provider selection Codex login failed err={s}", .{@errorName(err)});
            try writeProviderActivationError(alloc, deps, caller, "Codex login failed");
            return false;
        };
        performed_login = .codex;
        resolution = try credentials.resolveForProvider(
            alloc,
            cfg.gateway_provider.oauth_transport,
            cfg.secret_store,
            .refresh_if_needed,
            target,
            settings.credential_source,
        );
    }
    if (resolution.credential == null and target == .grok and caller == .provider_command) {
        grok_oauth.runLogin(alloc, cfg.gateway_provider.oauth_transport, cfg.url_opener) catch |err| {
            debug_trace.logf("auth", "provider selection Grok login failed err={s}", .{@errorName(err)});
            try writeProviderActivationError(alloc, deps, caller, "Grok login failed");
            return false;
        };
        performed_login = .grok;
        resolution = try credentials.resolveForProvider(
            alloc,
            cfg.gateway_provider.oauth_transport,
            cfg.secret_store,
            .refresh_if_needed,
            target,
            settings.credential_source,
        );
    }

    const credential = if (resolution.credential) |*value| value else {
        try writeProviderActivationError(
            alloc,
            deps,
            caller,
            switch (target) {
                .codex => "Codex credential is unavailable",
                .grok => "Grok credential is unavailable",
                .gateway => "configure a Gateway credential first",
            },
        );
        return false;
    };
    const catalog_provider = cfg.provider_set.select(target).model_catalog orelse {
        try writeProviderActivationError(alloc, deps, caller, switch (target) {
            .codex => "Codex model catalog is unavailable",
            .grok => "Grok model catalog is unavailable",
            .gateway => "Gateway model catalog is unavailable",
        });
        return false;
    };
    const fetch_result = model_catalog.fetchCatalog(catalog_provider, alloc, .{
        .access = credentials.catalogAccessAt(credential.*, io_mod.milliTimestamp()),
        .endpoint = cfg.models_path,
        .view = .picker,
    });
    var loaded = switch (fetch_result) {
        .loaded => |loaded| loaded,
        .failed => |failure| {
            debug_trace.logf("catalog", "provider selection catalog failed provider={s} category={s}", .{ @tagName(target), @tagName(failure.failure.category) });
            const detail = try std.fmt.allocPrint(
                alloc,
                "could not load the target model catalog ({s})",
                .{@tagName(failure.failure.category)},
            );
            defer alloc.free(detail);
            try writeProviderActivationError(alloc, deps, caller, detail);
            return false;
        },
    };
    defer model_catalog.freeModelCatalog(alloc, &loaded.catalog);
    const saved_model = settings.models.get(target);
    const selected_model = selectCatalogModel(loaded.catalog.items, saved_model) orelse {
        try writeProviderActivationError(alloc, deps, caller, "target model catalog is empty");
        return false;
    };
    var attempt = config_runtime.attemptUserPreferences(alloc, .{
        .provider = target,
        .model_preference = .{ .provider = target, .model = selected_model },
    });
    defer attempt.deinit(alloc);
    switch (attempt) {
        .failure => |failure| {
            debug_trace.logf("config", "provider selection persistence failed err={s}", .{@errorName(failure.err)});
            try writeProviderActivationError(alloc, deps, caller, "failed to save provider selection");
            return false;
        },
        .outcome => {},
    }
    if (performed_login) |provider| switch (provider) {
        .codex => try writeStdout(deps, "Signed in with Codex.\n"),
        .grok => try writeStdout(deps, "Signed in with Grok.\n"),
        .gateway => unreachable,
    };
    if (caller == .provider_command) {
        try writeStdout(deps, switch (target) {
            .gateway => "Provider set to Gateway.\n",
            .codex => "Provider set to Codex.\n",
            .grok => "Provider set to Grok.\n",
        });
    }
    return true;
}

fn runIfRequestedWithDeps(alloc: Allocator, args: []const [:0]const u8, cfg: Config, deps: RunDeps) !RunResult {
    const parsed_launch = parseInteractiveLaunch(alloc, args, cfg.command_catalog) catch |err| {
        if (err == error.InvalidResumeArgs) {
            try writeTopLevelUsage(cfg.command_catalog, deps, .@"resume");
            return .handled_failure;
        }
        var writer: std.Io.Writer.Allocating = .init(alloc);
        defer writer.deinit();
        if (globalLaunchErrorMessage(err)) |message| {
            try writer.writer.print("fx: {s}\n", .{message});
        } else {
            try writer.writer.print("fx: invalid global launch option: {s}\n", .{@errorName(err)});
        }
        try writer.writer.writeAll("usage: fx [--context-limit NAME=BYTES|off] [--add-dir PATH]... [--no-additional-dirs] <command>\n");
        try writeStderr(deps, writer.written());
        return .handled_failure;
    };
    switch (parsed_launch) {
        .interactive => |launch| return .{ .interactive = launch },
        .noninteractive => |value| {
            var noninteractive = value;
            defer noninteractive.deinit(alloc);
            return runNonInteractiveWithDeps(alloc, &noninteractive, cfg, deps);
        },
    }
}

fn runNonInteractiveWithDeps(
    alloc: Allocator,
    parsed_launch: *NonInteractiveLaunch,
    cfg: Config,
    deps: RunDeps,
) !RunResult {
    const global_args = &parsed_launch.global_args;
    const effective_args = parsed_launch.effective_args;
    const parsed_command = parsed_launch.command;

    if (global_args.modifiers.hasWorkspaceModifiers() and
        !commandSupportsWorkspaceModifiers(parsed_command))
    {
        try writeWorkspaceModifierUsage(deps);
        return .handled_failure;
    }

    if (isVersionFlag(effective_args[0])) {
        if (effective_args.len != 1) {
            try writeStderr(deps, version_usage);
            return .handled_failure;
        }
        try writeStdout(deps, cfg.version);
        try writeStdout(deps, "\n");
        return .handled_success;
    }

    if (topLevelHelpRequest(cfg.command_catalog, effective_args)) |kind| {
        const text = try command_specs.renderTopLevelCommandHelp(alloc, cfg.command_catalog, kind);
        defer alloc.free(text);
        try writeStdout(deps, text);
        return .handled_success;
    }

    switch (parsed_command) {
        .interactive, .resume_session => unreachable,
        .help => {
            try writeTopLevelHelp(alloc, cfg.command_catalog, deps, cfg.version, .stdout);
            return .handled_success;
        },
        .ask => |rest| {
            const exit_code = try cli_ask.run(alloc, rest, workflowConfigWithLaunchModifiers(cfg, global_args.modifiers), cfg.context_registry, cfg.tool_set);
            return if (exit_code == 0) .handled_success else .handled_failure;
        },
        .acp => |rest| {
            const acp_opts = parseAcpArgs(rest) catch {
                try writeStderr(deps, "usage: fx acp [--model <id>] [--log-file <path>]\n");
                return .handled_failure;
            };
            try cfg.acp_runner.run(alloc, .{
                .default_model = cfg.default_model,
                .default_agent_step_limit = cfg.default_agent_step_limit,
                .gateway_retry_count = cfg.gateway_retry_count,
                .gateway_chat_url = cfg.gateway_provider.chat_url.resolve(cfg.gateway_chat_url),
                .gateway_models_path = cfg.models_path,
                .gateway_provider = cfg.gateway_provider,
                .provider_set = cfg.provider_set,
                .background_process_provider = cfg.background_process_provider,
                .secret_store = cfg.secret_store,
                .prompt_policy = cfg.prompt_policy,
                .ignored_list_entries = cfg.ignored_list_entries,
                .max_list_entries = cfg.max_list_entries,
                .max_read_file_bytes = cfg.max_read_file_bytes,
                .max_read_file_lines = cfg.max_read_file_lines,
                .max_read_file_line_len = cfg.max_read_file_line_len,
                .max_command_output_bytes = cfg.max_command_output_bytes,
                .max_tool_result_bytes = cfg.max_tool_result_bytes,
                .max_history_turns = cfg.max_history_turns,
                .context_registry = cfg.context_registry,
                .mode_registry = cfg.mode_registry,
                .context_limit_overrides = global_args.modifiers.context_limit_overrides,
                .additional_directories = global_args.modifiers.additional_directories,
                .saved_directories_suppressed = global_args.modifiers.saved_directories_suppressed,
                .model_override = acp_opts.model,
                .log_file = acp_opts.log_file,
            });
            return .handled_success;
        },
        .pr => |rest| return runGithubWorkflow(alloc, rest, cfg, global_args.modifiers, deps, .pull_request),
        .issue => |rest| return runGithubWorkflow(alloc, rest, cfg, global_args.modifiers, deps, .issue),
        .setup => |rest| {
            var json = false;
            for (rest) |arg| {
                if (std.mem.eql(u8, arg, "--json") and !json) {
                    json = true;
                } else {
                    try writeTopLevelUsage(cfg.command_catalog, deps, .setup);
                    return .handled_failure;
                }
            }
            const report = provider_setup.run(alloc) catch |err| {
                debug_trace.logf("auth", "provider setup failed err={s}", .{@errorName(err)});
                try writeStderr(deps, "fx setup: provider credential import failed\n");
                return .handled_failure;
            };
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            if (json) try report.writeJson(&out.writer) else try report.writeText(&out.writer);
            try writeStdout(deps, out.written());
            return .handled_success;
        },
        .login => |rest| {
            const login_provider = parseLoginProvider(rest) catch {
                try writeStderr(deps, "usage: fx login <codex|grok>\n");
                return .handled_failure;
            };
            switch (login_provider) {
                .codex => {
                    chatgpt_oauth.runLogin(
                        alloc,
                        cfg.gateway_provider.oauth_transport,
                        cfg.url_opener,
                    ) catch |err| {
                        const message = switch (err) {
                            error.ChatGptLoginTimedOut => "fx login: Codex authorization expired; run fx login codex again\n",
                            error.ChatGptAuthorizationFailed => "fx login: Codex authorization denied\n",
                            else => "fx login: failed to sign in with Codex\n",
                        };
                        try writeStderr(deps, message);
                        return .handled_failure;
                    };
                    if (!try activateProviderSelection(alloc, cfg, deps, .codex, .provider_login)) {
                        return .handled_failure;
                    }
                    try writeStdout(deps, "Signed in with Codex.\n");
                },
                .grok => {
                    grok_oauth.runLogin(
                        alloc,
                        cfg.gateway_provider.oauth_transport,
                        cfg.url_opener,
                    ) catch |err| {
                        debug_trace.logf("auth", "Grok login failed err={s}", .{@errorName(err)});
                        try writeStderr(deps, "fx login: failed to sign in with Grok\n");
                        return .handled_failure;
                    };
                    if (!try activateProviderSelection(alloc, cfg, deps, .grok, .provider_login)) {
                        return .handled_failure;
                    }
                    try writeStdout(deps, "Signed in with Grok.\n");
                },
                .gateway => unreachable,
            }
            return .handled_success;
        },
        .logout => |rest| {
            const login_provider = parseLogoutProvider(rest) catch {
                try writeStderr(deps, "usage: fx logout <codex|grok|gateway>\n");
                return .handled_failure;
            };
            if (login_provider == .codex) {
                const outcome = chatgpt_oauth.logout() catch {
                    try writeStderr(deps, "fx logout: failed to durably remove saved Codex login\n");
                    return .handled_failure;
                };
                return switch (outcome) {
                    .deleted => result: {
                        try writeStdout(deps, "Signed out of Codex.\n");
                        break :result .handled_success;
                    },
                    .missing => result: {
                        try writeStdout(deps, "No Codex login session found.\n");
                        break :result .handled_success;
                    },
                    .deleted_not_durable => result: {
                        try writeStderr(deps, "fx logout: failed to durably remove saved Codex login\n");
                        break :result .handled_failure;
                    },
                };
            }
            if (login_provider == .grok) {
                const outcome = grok_oauth.logout(alloc, cfg.gateway_provider.oauth_transport) catch {
                    try writeStderr(deps, "fx logout: failed to durably remove saved Grok login\n");
                    return .handled_failure;
                };
                if (outcome.revocation_failed) {
                    try writeStderr(deps, "fx logout: local Grok session removed, but remote revocation could not be confirmed\n");
                }
                return switch (outcome.deletion) {
                    .deleted => result: {
                        try writeStdout(deps, "Signed out of Grok.\n");
                        break :result .handled_success;
                    },
                    .missing => result: {
                        try writeStdout(deps, "No Grok login session found.\n");
                        break :result .handled_success;
                    },
                    .deleted_not_durable => result: {
                        try writeStderr(deps, "fx logout: failed to durably remove saved Grok login\n");
                        break :result .handled_failure;
                    },
                };
            }
            if (login_provider == .gateway) {
                const outcome = gateway_session.deleteStoredSession() catch {
                    try writeStderr(deps, "fx logout: failed to remove saved Gateway URL and API key\n");
                    return .handled_failure;
                };
                return switch (outcome) {
                    .deleted => result: {
                        try writeStdout(deps, "Removed the saved Gateway URL and API key.\n");
                        break :result .handled_success;
                    },
                    .missing => result: {
                        try writeStdout(deps, "No saved Gateway URL and API key found.\n");
                        break :result .handled_success;
                    },
                    .deleted_not_durable => result: {
                        try writeStderr(deps, "fx logout: failed to durably remove saved Gateway URL and API key\n");
                        break :result .handled_failure;
                    },
                };
            }
            unreachable;
        },
        .provider => |rest| {
            if (rest.len == 1) {
                const target = model_provider.parse(rest[0]) orelse {
                    try writeStderr(deps, "fx provider: expected gateway, codex, or grok\n");
                    return .handled_failure;
                };
                return if (try activateProviderSelection(alloc, cfg, deps, target, .provider_command))
                    .handled_success
                else
                    .handled_failure;
            }
            if (rest.len >= 3) {
                const target = model_provider.parse(rest[0]) orelse {
                    try writeStderr(deps, "usage: fx provider <gateway|codex|grok> [base-url api-key]\n");
                    return .handled_failure;
                };
                if (target != .gateway) {
                    try writeStderr(deps, "usage: fx provider gateway <base-url> <api-key>\n");
                    return .handled_failure;
                }
                const api_key = joinArgWords(alloc, rest[2..]) catch {
                    try writeStderr(deps, "fx provider: failed to read API key\n");
                    return .handled_failure;
                };
                defer alloc.free(api_key);
                return if (try configureGatewayProvider(alloc, cfg, deps, rest[1], api_key))
                    .handled_success
                else
                    .handled_failure;
            }
            try writeStderr(deps, "usage: fx provider <gateway|codex|grok> [base-url api-key]\n");
            return .handled_failure;
        },
        .status => |rest| {
            const opts = parseLocalSurfaceArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .status, "status", err, rest);
                return .handled_failure;
            };
            var startup = try deps.load_startup_status(
                alloc,
                cfg.secret_store,
                cfg.default_model,
                cfg.default_agent_step_limit,
            );
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);
            const snapshot = statusSnapshotFromStartup(startup);
            if (opts.format == .json) {
                try writeStatusJsonLine(alloc, deps, snapshot);
                return .handled_success;
            }

            const text = try snapshot.render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .permissions => |rest| {
            const opts = parseLocalSurfaceArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .permissions, "permissions", err, rest);
                return .handled_failure;
            };
            var startup = try deps.load_startup_state_without_credentials(alloc, cfg.default_model, cfg.default_agent_step_limit);
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);
            const rules = try permissionRulesForSnapshot(alloc, startup.permission_rules);
            defer if (rules.rules.len > 0) alloc.free(rules.rules);

            const text = try (output_contracts.PermissionsSnapshot{
                .workspace_root = startup.workspace_root,
                .mode = permissionModeForSnapshot(startup.permission_mode),
                .grants = &.{},
                .rules = rules,
                .runtime_grants_available = false,
            }).render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .models => |rest| {
            const opts = parseLocalSurfaceArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .models, "models", err, rest);
                return .handled_failure;
            };

            var startup = try deps.load_catalog_startup_state(
                alloc,
                cfg.secret_store,
                cfg.default_model,
                cfg.default_agent_step_limit,
            );
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);

            const catalog_access = startup.modelCatalogAccess();
            const catalog_provider = cfg.provider_set.select(startup.provider).cli_model_catalog orelse {
                try writeStderr(deps, switch (startup.provider) {
                    .gateway => "fx models: Gateway model catalog is unavailable\n",
                    .codex => "fx models: Codex model catalog is unavailable\n",
                    .grok => "fx models: Grok model catalog is unavailable\n",
                });
                return .handled_failure;
            };
            const loaded = switch (catalog_provider.fetch(alloc, .{
                .access = catalog_access,
                .endpoint = cfg.models_path,
            })) {
                .loaded => |loaded| loaded,
                .failure => |failure| {
                    const error_name = @errorName(failure.failure.asError());
                    const message = try std.fmt.allocPrint(
                        alloc,
                        "could not list models: {s}",
                        .{catalogFailureDetail(failure.failure)},
                    );
                    defer alloc.free(message);
                    if (opts.format == .json) {
                        try writeJsonCommandFailureCode(
                            alloc,
                            deps,
                            "models",
                            error_name,
                            message,
                        );
                    } else {
                        try writeStderr(deps, "fx models: ");
                        try writeStderr(deps, message);
                        try writeStderr(deps, "\n");
                    }
                    return .handled_failure;
                },
            };
            var ids = loaded.ids;
            defer collections.freeStringList(alloc, &ids);

            const text = try (output_contracts.ModelListSnapshot{
                .ids = ids.items,
                .provider = startup.provider,
                .private_models_hidden = loaded.provenance.access.private_models_may_be_hidden,
                .public_only_reason = loaded.provenance.access.public_only_reason,
            }).render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .doctor => |rest| {
            const opts = parseLocalSurfaceArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .doctor, "doctor", err, rest);
                return .handled_failure;
            };

            var snapshot = try doctor_runtime.collect(
                alloc,
                cfg.secret_store,
                cfg.default_model,
                cfg.default_agent_step_limit,
            );
            defer snapshot.deinit(alloc);

            const output_snapshot = doctorSnapshotFromRuntime(snapshot);
            if (opts.format == .json) {
                try writeDoctorJsonLine(alloc, deps, output_snapshot);
                return .handled_success;
            }

            const text = try output_snapshot.render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .session => |rest| {
            if (rest.len > 0 and std.mem.eql(u8, rest[0], "recover")) {
                var recovery = parseSessionRecoveryArgs(
                    alloc,
                    rest[1..],
                ) catch |err| {
                    try writeUsageOrJsonError(
                        alloc,
                        cfg.command_catalog,
                        deps,
                        .session,
                        "session",
                        err,
                        rest[1..],
                    );
                    return .handled_failure;
                };
                defer recovery.deinit(alloc);

                const workspace_root = try io_mod.realpathAlloc(alloc, ".");
                defer alloc.free(workspace_root);
                var store = session_store.Store.init(
                    alloc,
                    workspace_root,
                ) catch |err| {
                    try writeLookupFailure(
                        alloc,
                        deps,
                        "session",
                        err,
                        recovery.format,
                    );
                    return .handled_failure;
                };
                defer store.deinit(alloc);
                var result = store.recoverSessionCopy(
                    alloc,
                    recovery.session_id,
                    .{},
                ) catch |err| {
                    try writeLookupFailure(
                        alloc,
                        deps,
                        "session",
                        err,
                        recovery.format,
                    );
                    return .handled_failure;
                };
                defer result.deinit(alloc);

                const text = try (output_contracts.SessionRecoverySnapshot{
                    .result = result,
                }).render(alloc, recovery.format);
                defer alloc.free(text);
                try writeFormattedOutput(deps, text, recovery.format);
                return if (result.status == .recovered)
                    .handled_success
                else
                    .handled_failure;
            }

            if (rest.len > 0 and std.mem.eql(u8, rest[0], "migrate")) {
                var migration = parseSessionMigrationArgs(alloc, rest[1..]) catch |err| {
                    try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .session, "session", err, rest[1..]);
                    return .handled_failure;
                };
                defer migration.deinit(alloc);

                const workspace_root = try io_mod.realpathAlloc(alloc, ".");
                defer alloc.free(workspace_root);

                var store = session_store.Store.init(alloc, workspace_root) catch |err| {
                    try writeLookupFailure(alloc, deps, "session", err, migration.format);
                    return .handled_failure;
                };
                defer store.deinit(alloc);
                var result = store.migrateLegacyStorageOnly(
                    alloc,
                    migration.session_id,
                    .{ .allow_large = migration.allow_large },
                ) catch |err| {
                    try writeLookupFailure(alloc, deps, "session", err, migration.format);
                    return .handled_failure;
                };
                defer result.deinit(alloc);

                const text = try (output_contracts.SessionMigrationSnapshot{
                    .result = result,
                }).render(alloc, migration.format);
                defer alloc.free(text);
                try writeFormattedOutput(deps, text, migration.format);
                return .handled_success;
            }

            var opts = parseSessionDetailArgs(alloc, rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .session, "session", err, rest);
                return .handled_failure;
            };
            defer opts.deinit(alloc);

            const target = opts.target orelse {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .session, "session", error.InvalidSessionDetailArgs, rest);
                return .handled_failure;
            };

            const workspace_root = try io_mod.realpathAlloc(alloc, ".");
            defer alloc.free(workspace_root);

            var store = session_store.Store.initReadOnly(alloc, workspace_root) catch |err| {
                try writeLookupFailure(alloc, deps, "session", err, opts.format);
                return .handled_failure;
            };
            defer store.deinit(alloc);

            switch (target) {
                .last => {
                    var summary = store.latestReadOnlyWorkspaceSummary(alloc) catch |err| {
                        try writeLookupFailure(alloc, deps, "session", err, opts.format);
                        return .handled_failure;
                    };
                    defer summary.deinit(alloc);

                    const text = try (output_contracts.SessionSummarySnapshot{
                        .summary = summary,
                    }).render(alloc, opts.format);
                    defer alloc.free(text);
                    try writeFormattedOutput(deps, text, opts.format);
                    return .handled_success;
                },
                .id => |id| {
                    var detail = store.loadReadOnlyDetail(
                        alloc,
                        id,
                        .{},
                    ) catch |err| {
                        try writeSessionDetailFailure(
                            alloc,
                            deps,
                            id,
                            err,
                            opts.format,
                        );
                        return .handled_failure;
                    };
                    defer detail.deinit(alloc);

                    const text = try (output_contracts.SessionDetailSnapshot{
                        .detail = detail,
                    }).render(alloc, opts.format);
                    defer alloc.free(text);
                    try writeFormattedOutput(deps, text, opts.format);
                    return .handled_success;
                },
            }
        },
        .sessions => |rest| {
            const opts = parseSessionListArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .sessions, "sessions", err, rest);
                return .handled_failure;
            };

            const workspace_root = try io_mod.realpathAlloc(alloc, ".");
            defer alloc.free(workspace_root);

            var store = session_store.Store.initReadOnly(alloc, workspace_root) catch |err| {
                try writeLookupFailure(alloc, deps, "sessions", err, opts.format);
                return .handled_failure;
            };
            defer store.deinit(alloc);

            var page = store.listSessionPage(
                alloc,
                opts.scope,
                opts.continuation,
                opts.limit,
            ) catch |err| return err;
            defer page.deinit(alloc);
            const next_cursor = if (page.has_more and page.summaries.items.len > 0)
                try formatSessionListCursor(
                    alloc,
                    page.summaries.items[page.summaries.items.len - 1],
                )
            else
                null;
            defer if (next_cursor) |cursor| alloc.free(cursor);

            const text = try (output_contracts.SessionListSnapshot{
                .sessions = page.summaries.items,
                .has_more = page.has_more,
                .next_cursor = next_cursor,
                .skipped_invalid = page.skipped_invalid,
                .all_workspaces = opts.scope == .all_workspaces,
            }).render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .workspace => |rest| {
            const opts = parseWorkspaceArgs(rest) catch |err| {
                try writeWorkspaceCommandError(alloc, cfg.command_catalog, deps, rest, err);
                return .handled_failure;
            };
            var startup = deps.load_startup_state_without_credentials(
                alloc,
                cfg.default_model,
                cfg.default_agent_step_limit,
            ) catch |err| {
                try writeWorkspaceCommandError(alloc, cfg.command_catalog, deps, rest, err);
                return .handled_failure;
            };
            defer startup.deinit(alloc);
            try writeConfigDiagnostics(alloc, deps, startup.config_diagnostics);

            if (opts.action == null) {
                const snapshot = output_contracts.WorkspaceSnapshot.fromAccess(
                    startup.workspace_root,
                    &startup.workspace_access,
                );
                const text = try snapshot.render(alloc, opts.format);
                defer alloc.free(text);
                try writeFormattedOutput(deps, text, opts.format);
                return .handled_success;
            }

            var failure_phase: workspace_commands.FailurePhase = .stage;
            var result = workspace_commands.execute(
                alloc,
                startup.workspace_root,
                &startup.workspace_access,
                opts.action.?,
                &failure_phase,
            ) catch |err| {
                try writeWorkspaceCommandError(alloc, cfg.command_catalog, deps, rest, err);
                return .handled_failure;
            };
            defer result.deinit(alloc);

            switch (result) {
                .updated => |updated| {
                    var snapshot = output_contracts.WorkspaceSnapshot.fromAccess(startup.workspace_root, &updated.access);
                    snapshot.mutation = updated.mutation;
                    const text = try snapshot.render(alloc, opts.format);
                    defer alloc.free(text);
                    try writeFormattedOutput(deps, text, opts.format);
                    return .handled_success;
                },
                .indeterminate => |reconciliation| {
                    try writeWorkspaceIndeterminateError(alloc, deps, rest, reconciliation);
                    return .handled_failure;
                },
            }
        },
        .usage => |rest| {
            const opts = parseUsageArgs(rest) catch |err| {
                try writeUsageOrJsonError(alloc, cfg.command_catalog, deps, .usage, "usage", err, rest);
                return .handled_failure;
            };
            if (opts.codex_account) {
                const account_usage = cfg.provider_set.codex.account_usage orelse {
                    try writeUsageCommandFailure(alloc, deps, error.AccountUsageUnavailable, opts.format);
                    return .handled_failure;
                };
                var resolution = credentials.resolveForProvider(
                    alloc,
                    cfg.gateway_provider.oauth_transport,
                    cfg.secret_store,
                    .refresh_if_needed,
                    .codex,
                    .chatgpt_subscription,
                ) catch |err| {
                    try writeUsageCommandFailure(alloc, deps, err, opts.format);
                    return .handled_failure;
                };
                defer if (resolution.credential) |*credential| credential.deinit(alloc);
                const credential = if (resolution.credential) |*value| value else null;
                var snapshot = account_usage.fetch(alloc, .{
                    .credential = if (credential) |value| value.token else null,
                    .account_id = if (credential) |value| value.accountId() else null,
                    .credential_source = if (credential) |value| value.source else null,
                    .oauth_transport = cfg.gateway_provider.oauth_transport,
                });
                defer snapshot.deinit(alloc);
                const rendered = try snapshot.render(alloc, opts.format);
                defer alloc.free(rendered);
                if (snapshot.failure != null) {
                    if (opts.format == .json) {
                        try writeFormattedOutput(deps, rendered, opts.format);
                    } else {
                        try writeStderr(deps, rendered);
                    }
                    return .handled_failure;
                }
                try writeFormattedOutput(deps, rendered, opts.format);
                return .handled_success;
            }
            const home = deps.getenv(deps.env_ctx, "HOME") orelse {
                try writeUsageCommandFailure(
                    alloc,
                    deps,
                    error.HomeNotSet,
                    opts.format,
                );
                return .handled_failure;
            };
            var report = usage_cli_runtime.collect(
                alloc,
                home,
                opts.scope,
                @max(io_mod.milliTimestamp(), 0),
            ) catch |err| {
                try writeUsageCommandFailure(alloc, deps, err, opts.format);
                return .handled_failure;
            };
            defer report.deinit(alloc);
            const text = try (output_contracts.UsageSnapshot{
                .report = &report,
            }).render(alloc, opts.format);
            defer alloc.free(text);
            try writeFormattedOutput(deps, text, opts.format);
            return .handled_success;
        },
        .replay => |rest| {
            const exit_code = try cli_replay.run(alloc, rest);
            return if (exit_code == 0) .handled_success else .handled_failure;
        },
        .unknown => |command| {
            try writeStderr(deps, "fx: unknown subcommand: ");
            try writeStderr(deps, command);
            try writeStderr(deps, "\n\n");
            try writeTopLevelHelp(alloc, cfg.command_catalog, deps, cfg.version, .stderr);
            return error.UnknownCliCommand;
        },
    }
}

const TopLevelHelpDestination = enum { stdout, stderr };

fn writeTopLevelHelp(
    alloc: Allocator,
    command_catalog: CommandCatalog,
    deps: RunDeps,
    version: []const u8,
    destination: TopLevelHelpDestination,
) !void {
    const text = try command_specs.renderTopLevelHelp(
        alloc,
        command_catalog,
        command_specs.top_level_help_default_width,
        version,
    );
    defer alloc.free(text);
    switch (destination) {
        .stdout => try writeStdout(deps, text),
        .stderr => try writeStderr(deps, text),
    }
}

fn runGithubWorkflow(
    alloc: Allocator,
    args: []const [:0]const u8,
    cfg: Config,
    launch_modifiers: LaunchModifiers,
    deps: RunDeps,
    workflow: github_workflows.Workflow,
) !RunResult {
    const opts = try parseWorkflowArgs(alloc, args);
    defer opts.deinit(alloc);

    const prompt = switch (workflow) {
        .pull_request => github_workflows.buildPrompt(alloc, workflow, workflowLanguagePlaceholder(), opts.context) catch |err| switch (err) {
            error.NotGitRepository => {
                try writeStderr(deps, "fx pr: requires running inside a git repository\n");
                return .handled_failure;
            },
            else => return err,
        },
        .issue => try github_workflows.buildPrompt(alloc, workflow, workflowLanguagePlaceholder(), opts.context),
    };
    defer alloc.free(prompt);

    const workflow_cfg = workflowConfigWithLaunchModifiers(cfg, launch_modifiers);
    if (!opts.create) {
        const exit_code = try cli_ask.runPrompt(alloc, prompt, opts.auto_permission, workflow_cfg, cfg.context_registry, cfg.tool_set);
        return if (exit_code == 0) .handled_success else .handled_failure;
    }

    const run_result = try cli_ask.runPromptCapture(alloc, prompt, opts.auto_permission, workflow_cfg, cfg.context_registry, cfg.tool_set);
    defer run_result.deinit(alloc);
    if (run_result.exit_code != 0) return .handled_failure;

    const draft = github_publish.parseDraft(alloc, run_result.assistant_output) catch {
        try writeStderr(deps, switch (workflow) {
            .pull_request => "fx pr: failed to parse drafted PR title/body\n",
            .issue => "fx issue: failed to parse drafted issue title/body\n",
        });
        return .handled_failure;
    };
    defer draft.deinit(alloc);

    const published = try github_publish.publish(alloc, switch (workflow) {
        .pull_request => .pull_request,
        .issue => .issue,
    }, draft);
    defer published.deinit(alloc);
    if (!published.ok) {
        try writeStderr(deps, switch (workflow) {
            .pull_request => "fx pr: ",
            .issue => "fx issue: ",
        });
        try writeStderr(deps, published.text);
        try writeStderr(deps, "\n");
        return .handled_failure;
    }
    try writeStdout(deps, published.text);
    try writeStdout(deps, "\n");
    return .handled_success;
}

fn writeStdout(deps: RunDeps, text: []const u8) !void {
    try deps.write_stdout(deps.stdout_ctx, text);
}

fn writeStderr(deps: RunDeps, text: []const u8) !void {
    try deps.write_stderr(deps.stderr_ctx, text);
}

fn writeConfigDiagnostics(
    alloc: Allocator,
    deps: RunDeps,
    diagnostics: []const config_runtime.ConfigDiagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        if (!diagnostic.reportAtStartup()) continue;
        var notice_writer: std.Io.Writer.Allocating = .init(alloc);
        defer notice_writer.deinit();
        try notice_writer.writer.print(
            "fx: config {s}: {s}",
            .{ @tagName(diagnostic.layer), @tagName(diagnostic.cause) },
        );
        try config_runtime.writeDiagnosticMetadata(&notice_writer.writer, diagnostic);
        try notice_writer.writer.writeByte('\n');
        const notice = try notice_writer.toOwnedSlice();
        defer alloc.free(notice);
        try writeStderr(deps, notice);
    }
}

fn writeFormattedOutput(deps: RunDeps, text: []const u8, format: output_contracts.OutputFormat) !void {
    switch (format) {
        .text => try writeStdout(deps, text),
        .json => try writeJsonLine(deps, text),
    }
}

fn writeJsonLine(deps: RunDeps, text: []const u8) !void {
    @setRuntimeSafety(false);
    var buf: [4096]u8 = undefined;
    if (text.len < buf.len) {
        @memcpy(buf[0..text.len], text);
        buf[text.len] = '\n';
        return writeStdout(deps, buf[0 .. text.len + 1]);
    }

    try writeStdout(deps, text);
    try writeStdout(deps, "\n");
}

const JsonLinePayload = union(enum) {
    status: output_contracts.StatusSnapshot,
    doctor: output_contracts.DoctorSnapshot,
};

fn writeRenderedJsonLine(alloc: Allocator, deps: RunDeps, fixed_buffer: []u8, payload: JsonLinePayload) !void {
    var writer: std.Io.Writer = .fixed(fixed_buffer);
    renderJsonLinePayload(&writer, payload) catch |err| switch (err) {
        error.WriteFailed => {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try renderJsonLinePayload(&out.writer, payload);
            return writeJsonLine(deps, out.writer.buffered());
        },
    };
    try writeJsonLine(deps, writer.buffered());
}

fn renderJsonLinePayload(writer: *std.Io.Writer, payload: JsonLinePayload) std.Io.Writer.Error!void {
    switch (payload) {
        .status => |snapshot| try snapshot.writeJson(writer),
        .doctor => |snapshot| try snapshot.writeJson(writer),
    }
}

fn writeStatusJsonLine(alloc: Allocator, deps: RunDeps, snapshot: output_contracts.StatusSnapshot) !void {
    var buf: [1024]u8 = undefined;
    try writeRenderedJsonLine(alloc, deps, buf[0..], .{ .status = snapshot });
}

fn statusSnapshotFromStartup(startup: app_lifecycle.StartupStatus) output_contracts.StatusSnapshot {
    return .{
        .model = startup.selected_model,
        .provider = startup.provider,
        .auth = startup.auth,
        .auth_help = startup.auth.missingHelp(.cli),
        .permission_mode = permissionModeForSnapshot(startup.permission_mode),
        .workspace_root = startup.workspace_root,
        .history_turns = 0,
        .session_permission_grants = 0,
        .agent_step_limit = startup.agent_step_limit,
    };
}

fn writeDoctorJsonLine(alloc: Allocator, deps: RunDeps, snapshot: output_contracts.DoctorSnapshot) !void {
    var buf: [4096]u8 = undefined;
    try writeRenderedJsonLine(alloc, deps, buf[0..], .{ .doctor = snapshot });
}

fn doctorSnapshotFromRuntime(snapshot: doctor_runtime.Snapshot) output_contracts.DoctorSnapshot {
    return .{
        .workspace_root = snapshot.workspace_root,
        .model = snapshot.model,
        .provider = snapshot.provider,
        .auth = snapshot.auth,
        .permission_mode = permissionModeForSnapshot(snapshot.permission_mode),
        .agent_step_limit = snapshot.agent_step_limit,
        .checks = snapshot.checks,
    };
}

fn writeRealStdout(_: ?*anyopaque, text: []const u8) !void {
    if (comptime builtin.os.tag != .windows) {
        return writeFdAll(std.posix.STDOUT_FILENO, text);
    }
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

fn writeRealStderr(_: ?*anyopaque, text: []const u8) !void {
    if (comptime builtin.os.tag != .windows) {
        return writeFdAll(std.posix.STDERR_FILENO, text);
    }
    try std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), text);
}

fn writeFdAll(fd: std.posix.fd_t, text: []const u8) !void {
    @setRuntimeSafety(false);
    var remaining = text;
    while (remaining.len > 0) {
        const written = std.c.write(fd, remaining.ptr, remaining.len);
        if (written <= 0) return error.WriteFailed;
        remaining = remaining[@intCast(written)..];
    }
}

fn getenvDefault(_: ?*anyopaque, key: []const u8) ?[]const u8 {
    return io_mod.getenv(key);
}

fn environMapDefault(_: ?*anyopaque) ?*const std.process.Environ.Map {
    return io_mod.environMap();
}

fn selfExePathDefault(_: ?*anyopaque, alloc: Allocator) ![]u8 {
    const path_z = try std.process.executablePathAlloc(io_mod.getIo(), alloc);
    defer alloc.free(path_z);
    return alloc.dupe(u8, path_z);
}

fn writeTopLevelUsage(command_catalog: CommandCatalog, deps: RunDeps, kind: TopLevelKind) !void {
    try writeStderr(deps, "usage: fx ");
    try writeStderr(deps, command_specs.topLevelUsage(command_catalog, kind));
    try writeStderr(deps, "\n");
}

fn writeUsageOrJsonError(
    alloc: Allocator,
    command_catalog: CommandCatalog,
    deps: RunDeps,
    usage_kind: TopLevelKind,
    output_kind: []const u8,
    err: anyerror,
    args: anytype,
) !void {
    if (argsContainJson(args)) {
        try writeCommandFailure(alloc, deps, output_kind, err, .json);
    } else {
        try writeTopLevelUsage(command_catalog, deps, usage_kind);
    }
}

fn writeUsageCommandFailure(
    alloc: Allocator,
    deps: RunDeps,
    err: anyerror,
    format: output_contracts.OutputFormat,
) !void {
    const message = usageFailureMessage(err);
    if (format == .json) {
        return writeJsonCommandFailure(
            alloc,
            deps,
            "usage",
            err,
            message,
        );
    }
    try writeStderr(deps, "fx usage: ");
    try writeStderr(deps, message);
    try writeStderr(deps, "\n");
}

fn usageFailureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.HomeNotSet => "HOME is not set",
        error.DurablePathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => "local usage storage is unsafe",
        else => "local usage data is unavailable",
    };
}

fn writeWorkspaceCommandError(
    alloc: Allocator,
    command_catalog: CommandCatalog,
    deps: RunDeps,
    args: []const [:0]const u8,
    err: anyerror,
) !void {
    if (!argsContainJson(args)) {
        if (output_contracts.workspaceErrorMessage(err)) |message| {
            try writeStderr(deps, "fx workspace: ");
            try writeStderr(deps, message);
            try writeStderr(deps, "\n");
            return;
        }
        try writeTopLevelUsage(command_catalog, deps, .workspace);
        return;
    }

    const message = output_contracts.workspaceErrorMessage(err) orelse "invalid arguments";
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"kind\":\"workspace\",\"error\":");
    try std.json.Stringify.value(message, .{}, &out.writer);
    try out.writer.writeAll(",\"code\":");
    try std.json.Stringify.value(@errorName(err), .{}, &out.writer);
    try out.writer.writeByte('}');
    try writeJsonLine(deps, out.writer.buffered());
}

fn writeWorkspaceIndeterminateError(
    alloc: Allocator,
    deps: RunDeps,
    args: []const [:0]const u8,
    reconciliation: workspace_commands.Reconciliation,
) !void {
    const message = switch (reconciliation) {
        .intended => "settings durability is uncertain; reloaded settings match the requested update",
        .previous => "settings durability is uncertain; reloaded settings match the previous state, so the update was not applied",
        .unconfirmed => "settings durability is uncertain; reloaded settings match neither the requested nor previous state",
    };
    if (!argsContainJson(args)) {
        try writeStderr(deps, "fx workspace: ");
        try writeStderr(deps, message);
        try writeStderr(deps, "\n");
        return;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"kind\":\"workspace\",\"error\":");
    try std.json.Stringify.value(message, .{}, &out.writer);
    try out.writer.writeAll(",\"code\":\"SettingsCommitIndeterminate\"}");
    try writeJsonLine(deps, out.writer.buffered());
}

fn argsContainJson(args: anytype) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}

fn workflowLanguagePlaceholder() types.ConversationLanguage {
    return types.ConversationLanguage.default();
}

fn permissionModeForSnapshot(mode: anytype) types.PermissionMode {
    return switch (mode) {
        .ask => .ask,
        .auto => .auto,
        .yolo => .yolo,
    };
}

fn permissionModeLabel(mode: anytype) []const u8 {
    return switch (mode) {
        .ask => "ask",
        .auto => "auto",
        .yolo => "yolo",
    };
}

fn permissionRulesForSnapshot(alloc: Allocator, active_rules: anytype) !types.PermissionRuleSet {
    if (active_rules.rules.len == 0) return .{};
    const rules = try alloc.alloc(types.PermissionRule, active_rules.rules.len);
    for (active_rules.rules, 0..) |rule, i| {
        rules[i] = .{
            .permission = rule.permission,
            .pattern = rule.pattern,
            .action = switch (rule.action) {
                .allow => .allow,
                .ask => .ask,
                .deny => .deny,
            },
        };
    }
    return .{ .rules = rules };
}

fn loadLatestWorkspaceSessionDetail(
    alloc: Allocator,
    store: session_store.Store,
) !session_store.ReadOnlyDetail {
    var summary = try store.latestReadOnlyWorkspaceSummary(alloc);
    defer summary.deinit(alloc);
    return store.loadReadOnlyDetail(alloc, summary.id, .{});
}

fn loadLatestWorkspaceSessionSummary(
    alloc: Allocator,
    store: session_store.Store,
) !session_store.SessionSummary {
    return store.latestReadOnlyWorkspaceSummary(alloc);
}

fn catalogFailureDetail(failure: model_catalog.Failure) []const u8 {
    return switch (failure.category) {
        .authentication => "AuthenticationRejected",
        .cancellation => "the request was cancelled",
        .malformed_response => "MalformedResponse",
        .resource_exhausted => "OutOfMemory",
        .rate_limited, .gateway_unavailable, .transport, .http_status, .runtime => "Unavailable",
    };
}

fn writeCommandFailure(
    alloc: Allocator,
    deps: RunDeps,
    kind: []const u8,
    err: anyerror,
    format: output_contracts.OutputFormat,
) !void {
    if (format != .json) return err;
    const message = commandFailureMessage(err) orelse return err;
    return writeJsonCommandFailure(alloc, deps, kind, err, message);
}

fn writeJsonCommandFailure(
    alloc: Allocator,
    deps: RunDeps,
    kind: []const u8,
    err: anyerror,
    message: []const u8,
) !void {
    return writeJsonCommandFailureCode(
        alloc,
        deps,
        kind,
        @errorName(err),
        message,
    );
}

fn writeJsonCommandFailureCode(
    alloc: Allocator,
    deps: RunDeps,
    kind: []const u8,
    code: []const u8,
    message: []const u8,
) !void {
    const json = try (output_contracts.CommandFailureSnapshot{
        .kind = kind,
        .message = message,
        .code = code,
    }).renderJson(alloc);
    defer alloc.free(json);
    try writeJsonLine(deps, json);
}

fn writeLookupFailure(
    alloc: Allocator,
    deps: RunDeps,
    kind: []const u8,
    err: anyerror,
    format: output_contracts.OutputFormat,
) !void {
    if (format == .json) {
        return writeCommandFailure(alloc, deps, kind, err, format);
    }

    switch (err) {
        error.NoSavedSessions => {
            try writeStderr(deps, "fx session: no saved sessions for this workspace\n");
        },
        error.NoReadableSessions => {
            try writeStderr(deps, "fx session: saved sessions are unreadable; run `fx doctor` for recovery guidance\n");
        },
        error.SessionNotFound => {
            try writeStderr(deps, "fx session: record not found\n");
        },
        error.InvalidSessionFormat => {
            try writeStderr(
                deps,
                "fx session: record is corrupt; run `fx doctor` for recovery guidance\n",
            );
        },
        error.UnsupportedSessionSchema => {
            try writeStderr(
                deps,
                "fx session: record uses an unsupported session version\n",
            );
        },
        error.InvalidSessionId => {
            try writeStderr(deps, "fx session: invalid session id\n");
        },
        error.LegacySessionTooLarge => {
            try writeStderr(
                deps,
                "fx session: legacy session is too large for automatic loading; run `fx session migrate <id> --allow-large`\n",
            );
        },
        error.LegacySessionReadResourceExhausted => {
            try writeStderr(
                deps,
                "fx session: legacy session could not be loaded with available resources\n",
            );
        },
        error.LegacySessionMigrationResourceExhausted => {
            try writeStderr(
                deps,
                "fx session: migration did not complete because resources were exhausted; the original session remains authoritative\n",
            );
        },
        error.LegacySessionMigrationFailed, error.LegacySessionChanged => {
            try writeStderr(
                deps,
                "fx session: migration did not complete; the original session remains authoritative\n",
            );
        },
        error.LegacySessionMigrationIndeterminate => {
            try writeStderr(
                deps,
                "fx session: migration outcome is indeterminate and will be resolved by the next exact writable load\n",
            );
        },
        error.SessionRecoveryNotNeeded => {
            try writeStderr(
                deps,
                "fx session: recovery was refused because the session has a valid commit boundary; resume it normally\n",
            );
        },
        error.SessionRecoveryRequiresCurrentSchema => {
            try writeStderr(
                deps,
                "fx session: recovery only applies to current schema-v3 sessions; migrate legacy sessions first\n",
            );
        },
        error.SessionRecoveryUnsupportedSchema => {
            try writeStderr(
                deps,
                "fx session: recovery is unavailable for this unsupported session version\n",
            );
        },
        error.SessionRecoveryBoundaryInvalid => {
            try writeStderr(
                deps,
                "fx session: no exact trustworthy recovery boundary was found; the source was left unchanged\n",
            );
        },
        error.SessionRecoveryIndeterminate => {
            try writeStderr(
                deps,
                "fx session: the recovery copy could not be confirmed; the source was left unchanged\n",
            );
        },
        error.SessionAuthorityBoundaryUnavailable,
        error.SessionCommitBoundaryUnavailable,
        => {
            try writeStderr(
                deps,
                "fx session: session authority is temporarily unavailable while an incomplete commit is resolved\n",
            );
        },
        error.SessionAuthorityIntentCleanupPending => {
            try writeStderr(
                deps,
                "fx session: session authority is confirmed but transition cleanup is still pending\n",
            );
        },
        error.SessionBusy, error.SessionLockUnsupported => {
            try writeStderr(
                deps,
                "fx session: session is busy or the filesystem cannot provide the required lock\n",
            );
        },
        error.SessionPathUnsafe,
        error.DurablePathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => {
            try writeStderr(
                deps,
                "fx session: durable session storage is unsafe or does not support required private permissions\n",
            );
        },
        error.DurableLayoutFailed, error.SessionStoreUnavailable => {
            try writeStderr(deps, "fx session: durable session store is unavailable\n");
        },
        error.HomeNotSet => {
            try writeStderr(deps, "fx ");
            try writeStderr(deps, kind);
            try writeStderr(deps, ": HOME is not set\n");
        },
        else => return err,
    }
}

fn writeSessionDetailFailure(
    alloc: Allocator,
    deps: RunDeps,
    session_id: []const u8,
    err: anyerror,
    format: output_contracts.OutputFormat,
) !void {
    const message = switch (err) {
        error.InvalidSessionFormat => try std.fmt.allocPrint(
            alloc,
            "session {s} is corrupt; run `fx session recover {s}`",
            .{ session_id, session_id },
        ),
        error.UnsupportedSessionSchema => try std.fmt.allocPrint(
            alloc,
            "session {s} uses an unsupported session version",
            .{session_id},
        ),
        else => return writeLookupFailure(
            alloc,
            deps,
            "session",
            err,
            format,
        ),
    };
    defer alloc.free(message);
    if (format == .json) {
        return writeJsonCommandFailure(
            alloc,
            deps,
            "session",
            err,
            message,
        );
    }
    try writeStderr(deps, "fx session: ");
    try writeStderr(deps, message);
    try writeStderr(deps, "\n");
}

fn commandFailureMessage(err: anyerror) ?[]const u8 {
    if (lookupFailureMessage(err)) |message| return message;
    return switch (err) {
        error.InvalidLocalSurfaceArgs,
        error.InvalidUsageArgs,
        error.InvalidSessionDetailArgs,
        error.InvalidSessionMigrationArgs,
        error.InvalidSessionRecoveryArgs,
        error.InvalidResumeArgs,
        => "invalid arguments",
        else => null,
    };
}

fn lookupFailureMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NoSavedSessions => "no saved sessions for this workspace",
        error.NoReadableSessions => "saved sessions are unreadable; run `fx doctor` for recovery guidance",
        error.SessionNotFound => "record not found",
        error.InvalidSessionFormat => "record is corrupt; run `fx doctor` for recovery guidance",
        error.UnsupportedSessionSchema => "record uses an unsupported session version",
        error.InvalidSessionId => "invalid session id",
        error.LegacySessionTooLarge => "legacy session is too large for automatic loading; run `fx session migrate <id> --allow-large`",
        error.LegacySessionReadResourceExhausted => "legacy session could not be loaded with available resources",
        error.LegacySessionMigrationResourceExhausted => "migration did not complete because resources were exhausted; the original session remains authoritative",
        error.LegacySessionMigrationFailed, error.LegacySessionChanged => "migration did not complete; the original session remains authoritative",
        error.LegacySessionMigrationIndeterminate => "migration outcome is indeterminate and will be resolved by the next exact writable load",
        error.SessionRecoveryNotNeeded => "recovery was refused because the session has a valid commit boundary; resume it normally",
        error.SessionRecoveryRequiresCurrentSchema => "recovery only applies to current schema-v3 sessions; migrate legacy sessions first",
        error.SessionRecoveryUnsupportedSchema => "recovery is unavailable for this unsupported session version",
        error.SessionRecoveryBoundaryInvalid => "no exact trustworthy recovery boundary was found; the source was left unchanged",
        error.SessionRecoveryIndeterminate => "the recovery copy could not be confirmed; the source was left unchanged",
        error.SessionAuthorityBoundaryUnavailable,
        error.SessionCommitBoundaryUnavailable,
        => "session authority is temporarily unavailable while an incomplete commit is resolved",
        error.SessionAuthorityIntentCleanupPending => "session authority is confirmed but transition cleanup is still pending",
        error.SessionBusy, error.SessionLockUnsupported => "session is busy or the filesystem cannot provide the required lock",
        error.SessionPathUnsafe,
        error.DurablePathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => "durable session storage is unsafe or does not support required private permissions",
        error.DurableLayoutFailed, error.SessionStoreUnavailable => "durable session store is unavailable",
        error.HomeNotSet => "HOME is not set",
        else => null,
    };
}

test "session detail failures separate corruption from unsupported schema" {
    var corrupt_text = CaptureOutput.init(std.testing.allocator);
    defer corrupt_text.deinit();
    try writeSessionDetailFailure(
        std.testing.allocator,
        corrupt_text.deps(),
        "broken-session",
        error.InvalidSessionFormat,
        .text,
    );
    try std.testing.expectEqualStrings("", corrupt_text.stdout.written());
    try std.testing.expectEqualStrings(
        "fx session: session broken-session is corrupt; run `fx session recover broken-session`\n",
        corrupt_text.stderr.written(),
    );

    var corrupt_json = CaptureOutput.init(std.testing.allocator);
    defer corrupt_json.deinit();
    try writeSessionDetailFailure(
        std.testing.allocator,
        corrupt_json.deps(),
        "broken-session",
        error.InvalidSessionFormat,
        .json,
    );
    try std.testing.expectEqualStrings("", corrupt_json.stderr.written());
    try std.testing.expect(
        std.mem.find(
            u8,
            corrupt_json.stdout.written(),
            "\"error\":\"session broken-session is corrupt; run `fx session recover broken-session`\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.find(
            u8,
            corrupt_json.stdout.written(),
            "\"code\":\"InvalidSessionFormat\"",
        ) != null,
    );

    var unsupported_text = CaptureOutput.init(std.testing.allocator);
    defer unsupported_text.deinit();
    try writeSessionDetailFailure(
        std.testing.allocator,
        unsupported_text.deps(),
        "future-session",
        error.UnsupportedSessionSchema,
        .text,
    );
    try std.testing.expectEqualStrings("", unsupported_text.stdout.written());
    try std.testing.expectEqualStrings(
        "fx session: session future-session uses an unsupported session version\n",
        unsupported_text.stderr.written(),
    );
}

test "session recovery boundary failures keep stable text and json guidance" {
    var text_output = CaptureOutput.init(std.testing.allocator);
    defer text_output.deinit();
    try writeLookupFailure(
        std.testing.allocator,
        text_output.deps(),
        "session",
        error.SessionRecoveryBoundaryInvalid,
        .text,
    );
    try std.testing.expectEqualStrings("", text_output.stdout.written());
    try std.testing.expectEqualStrings(
        "fx session: no exact trustworthy recovery boundary was found; the source was left unchanged\n",
        text_output.stderr.written(),
    );

    var json_output = CaptureOutput.init(std.testing.allocator);
    defer json_output.deinit();
    try writeLookupFailure(
        std.testing.allocator,
        json_output.deps(),
        "session",
        error.SessionRecoveryBoundaryInvalid,
        .json,
    );
    try std.testing.expectEqualStrings("", json_output.stderr.written());
    try std.testing.expect(
        std.mem.find(
            u8,
            json_output.stdout.written(),
            "\"code\":\"SessionRecoveryBoundaryInvalid\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.find(
            u8,
            json_output.stdout.written(),
            "\"error\":\"no exact trustworthy recovery boundary was found; the source was left unchanged\"",
        ) != null,
    );
}

fn workflowConfig(cfg: Config) @import("cli_ask.zig").Config {
    return .{
        .command_usage = command_specs.topLevelUsage(cfg.command_catalog, .ask),
        .default_model = cfg.default_model,
        .default_agent_step_limit = cfg.default_agent_step_limit,
        .gateway_retry_count = cfg.gateway_retry_count,
        .gateway_chat_url = cfg.gateway_provider.chat_url.resolve(cfg.gateway_chat_url),
        .gateway_models_path = cfg.models_path,
        .gateway_provider = cfg.gateway_provider,
        .provider_set = cfg.provider_set,
        .background_process_provider = cfg.background_process_provider,
        .secret_store = cfg.secret_store,
        .prompt_policy = cfg.prompt_policy,
        .skill_root_policy = cfg.skill_root_policy,
        .ignored_list_entries = cfg.ignored_list_entries,
        .max_list_entries = cfg.max_list_entries,
        .max_read_file_bytes = cfg.max_read_file_bytes,
        .max_read_file_lines = cfg.max_read_file_lines,
        .max_read_file_line_len = cfg.max_read_file_line_len,
        .max_command_output_bytes = cfg.max_command_output_bytes,
        .max_tool_result_bytes = cfg.max_tool_result_bytes,
        .max_history_turns = cfg.max_history_turns,
        .mode_registry = cfg.mode_registry,
    };
}

fn workflowConfigWithLaunchModifiers(
    cfg: Config,
    modifiers: LaunchModifiers,
) @import("cli_ask.zig").Config {
    var result = workflowConfig(cfg);
    result.context_limit_overrides = modifiers.context_limit_overrides;
    result.additional_directories = modifiers.additional_directories;
    result.saved_directories_suppressed = modifiers.saved_directories_suppressed;
    return result;
}

fn commandSupportsWorkspaceModifiers(command: Command) bool {
    return switch (command) {
        .interactive, .ask, .acp, .pr, .issue, .resume_session => true,
        else => false,
    };
}

fn writeWorkspaceModifierUsage(deps: RunDeps) !void {
    try writeStderr(
        deps,
        "fx: --add-dir and --no-additional-dirs are only supported for interactive, resume, ask, ACP, PR, and issue launches\n",
    );
}

fn globalLaunchErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.MissingAddDirectoryValue => "--add-dir requires a directory path",
        error.DuplicateAdditionalDirectorySuppression => "--no-additional-dirs may only be specified once",
        else => null,
    };
}

fn parseAcpArgs(args: []const [:0]const u8) !AcpOptions {
    var opts = AcpOptions{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--model")) {
            if (opts.model != null or i + 1 >= args.len) return error.InvalidAcpArgs;
            i += 1;
            opts.model = args[i];
        } else if (std.mem.eql(u8, args[i], "--log-file")) {
            if (opts.log_file != null or i + 1 >= args.len) return error.InvalidAcpArgs;
            i += 1;
            opts.log_file = args[i];
        } else {
            return error.InvalidAcpArgs;
        }
    }
    return opts;
}

fn parseLocalSurfaceArgs(args: []const [:0]const u8) !LocalSurfaceOptions {
    var options = LocalSurfaceOptions{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
            continue;
        }
        return error.InvalidLocalSurfaceArgs;
    }
    return options;
}

fn parseSessionListArgs(args: []const [:0]const u8) !SessionListOptions {
    var options = SessionListOptions{};
    var format_seen = false;
    var limit_seen = false;
    var cursor_seen = false;
    var scope_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (format_seen) return error.InvalidLocalSurfaceArgs;
            format_seen = true;
            options.format = .json;
            continue;
        }
        if (std.mem.eql(u8, arg, "--all")) {
            if (scope_seen) return error.InvalidLocalSurfaceArgs;
            scope_seen = true;
            options.scope = .all_workspaces;
            continue;
        }
        if (std.mem.eql(u8, arg, "--limit")) {
            if (limit_seen or index + 1 >= args.len) return error.InvalidLocalSurfaceArgs;
            limit_seen = true;
            index += 1;
            options.limit = std.fmt.parseUnsigned(usize, args[index], 10) catch
                return error.InvalidLocalSurfaceArgs;
            if (options.limit == 0 or
                options.limit > session_store.session_list_max_limit)
            {
                return error.InvalidLocalSurfaceArgs;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--cursor")) {
            if (cursor_seen or index + 1 >= args.len) return error.InvalidLocalSurfaceArgs;
            cursor_seen = true;
            index += 1;
            options.continuation = try parseSessionListCursor(args[index]);
            continue;
        }
        return error.InvalidLocalSurfaceArgs;
    }
    return options;
}

fn parseUsageArgs(args: []const [:0]const u8) !UsageOptions {
    var options = UsageOptions{};
    var period_seen = false;
    var codex_seen = false;
    var json_seen = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--json")) {
            if (json_seen) return error.InvalidUsageArgs;
            json_seen = true;
            options.format = .json;
            continue;
        }
        if (std.mem.eql(u8, arg, "--codex")) {
            if (codex_seen) return error.InvalidUsageArgs;
            codex_seen = true;
            options.codex_account = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--period")) {
            if (period_seen or index + 1 >= args.len) return error.InvalidUsageArgs;
            period_seen = true;
            index += 1;
            options.scope = if (std.mem.eql(u8, args[index], "24h"))
                .hours_24
            else if (std.mem.eql(u8, args[index], "7d"))
                .days_7
            else if (std.mem.eql(u8, args[index], "30d"))
                .days_30
            else
                return error.InvalidUsageArgs;
            continue;
        }
        return error.InvalidUsageArgs;
    }
    if (options.codex_account and period_seen) return error.InvalidUsageArgs;
    return options;
}

fn parseSessionListCursor(raw: []const u8) !session_store.ResumableSessionContinuation {
    if (raw.len == 0 or raw.len > 320) return error.InvalidLocalSurfaceArgs;
    var fields = std.mem.splitScalar(u8, raw, ':');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidLocalSurfaceArgs, "v1")) {
        return error.InvalidLocalSurfaceArgs;
    }
    const updated_text = fields.next() orelse return error.InvalidLocalSurfaceArgs;
    const id = fields.next() orelse return error.InvalidLocalSurfaceArgs;
    if (fields.next() != null) return error.InvalidLocalSurfaceArgs;
    session_store.validateSessionId(id) catch return error.InvalidLocalSurfaceArgs;
    const updated_at_ms = std.fmt.parseInt(i64, updated_text, 10) catch
        return error.InvalidLocalSurfaceArgs;
    var canonical: [320]u8 = undefined;
    const encoded = std.fmt.bufPrint(
        &canonical,
        "v1:{d}:{s}",
        .{ updated_at_ms, id },
    ) catch return error.InvalidLocalSurfaceArgs;
    if (!std.mem.eql(u8, encoded, raw)) return error.InvalidLocalSurfaceArgs;
    return .{ .updated_at_ms = updated_at_ms, .id = id };
}

fn formatSessionListCursor(
    alloc: Allocator,
    summary: session_store.SessionSummary,
) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "v1:{d}:{s}",
        .{ summary.updated_at_ms, summary.id },
    );
}

fn parseWorkspaceArgs(args: []const [:0]const u8) !WorkspaceOptions {
    var positional: [2][]const u8 = undefined;
    var positional_len: usize = 0;
    var options = WorkspaceOptions{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            if (options.format == .json) return error.InvalidWorkspaceArgs;
            options.format = .json;
            continue;
        }
        if (positional_len >= positional.len) return error.InvalidWorkspaceArgs;
        positional[positional_len] = arg;
        positional_len += 1;
    }

    if (positional_len == 0) return options;
    if (std.mem.eql(u8, positional[0], "list")) {
        if (positional_len != 1) return error.InvalidWorkspaceArgs;
        return options;
    }
    if (std.mem.eql(u8, positional[0], "clear")) {
        if (positional_len != 1) return error.InvalidWorkspaceArgs;
        options.action = .clear;
        return options;
    }
    if (std.mem.eql(u8, positional[0], "add")) {
        if (positional_len != 2 or positional[1].len == 0) return error.InvalidWorkspaceArgs;
        options.action = .{ .add = positional[1] };
        return options;
    }
    if (std.mem.eql(u8, positional[0], "remove")) {
        if (positional_len != 2 or positional[1].len == 0) return error.InvalidWorkspaceArgs;
        options.action = .{ .remove = positional[1] };
        return options;
    }
    return error.InvalidWorkspaceArgs;
}

fn parseSessionDetailArgs(alloc: Allocator, args: []const [:0]const u8) !SessionDetailOptions {
    var options = SessionDetailOptions{};
    errdefer options.deinit(alloc);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
            continue;
        }

        if (options.target != null) return error.InvalidSessionDetailArgs;

        const exact_id = std.mem.eql(u8, arg, "--id");
        if (exact_id) {
            i += 1;
            if (i >= args.len) return error.InvalidSessionDetailArgs;
        }

        const trimmed = std.mem.trim(u8, args[i], " \t\r\n");
        if (trimmed.len == 0) return error.InvalidSessionDetailArgs;
        if (!exact_id and std.mem.eql(u8, trimmed, "last")) {
            options.target = .last;
            continue;
        }

        options.target = .{ .id = try alloc.dupe(u8, trimmed) };
    }

    return options;
}

fn parseSessionMigrationArgs(alloc: Allocator, args: []const [:0]const u8) !SessionMigrationOptions {
    var format: output_contracts.OutputFormat = .text;
    var allow_large = false;
    var session_id: ?[]u8 = null;
    errdefer if (session_id) |id| alloc.free(id);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            format = .json;
            continue;
        }
        if (std.mem.eql(u8, arg, "--allow-large")) {
            allow_large = true;
            continue;
        }
        if (session_id != null) return error.InvalidSessionMigrationArgs;

        const exact_id = std.mem.eql(u8, arg, "--id");
        if (exact_id) {
            i += 1;
            if (i >= args.len) return error.InvalidSessionMigrationArgs;
        }

        const trimmed = std.mem.trim(u8, args[i], " \t\r\n");
        if (trimmed.len == 0) return error.InvalidSessionMigrationArgs;
        session_id = try alloc.dupe(u8, trimmed);
    }

    return .{
        .format = format,
        .session_id = session_id orelse return error.InvalidSessionMigrationArgs,
        .allow_large = allow_large,
    };
}

fn parseSessionRecoveryArgs(
    alloc: Allocator,
    args: []const [:0]const u8,
) !SessionRecoveryOptions {
    var format: output_contracts.OutputFormat = .text;
    var session_id: ?[]u8 = null;
    errdefer if (session_id) |id| alloc.free(id);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            format = .json;
            continue;
        }
        if (session_id != null) return error.InvalidSessionRecoveryArgs;
        const exact_id = std.mem.eql(u8, arg, "--id");
        if (exact_id) {
            i += 1;
            if (i >= args.len) return error.InvalidSessionRecoveryArgs;
        }
        const trimmed = std.mem.trim(u8, args[i], " \t\r\n");
        if (trimmed.len == 0) return error.InvalidSessionRecoveryArgs;
        session_id = try alloc.dupe(u8, trimmed);
    }
    return .{
        .format = format,
        .session_id = session_id orelse return error.InvalidSessionRecoveryArgs,
    };
}

fn parseResumeArgs(
    alloc: Allocator,
    command_catalog: CommandCatalog,
    args: []const [:0]const u8,
    top_level_alias: bool,
) !ResumeTarget {
    if (args.len == 0) return .last;

    if (top_level_alias) {
        if (std.mem.eql(u8, args[0], "--resume")) {
            if (args.len == 1) return .last;
            if (args.len != 2) return error.InvalidResumeArgs;
            const id = std.mem.trim(u8, args[1], " \t\r\n");
            if (id.len == 0) return error.InvalidResumeArgs;
            if (std.mem.eql(u8, id, "last")) return .last;
            return .{ .id = try alloc.dupe(u8, id) };
        }
        if (args.len != 1) return error.InvalidResumeArgs;
        if (std.mem.eql(u8, args[0], resume_picker_alias)) return .pick;
        if (command_specs.matchesTopLevel(command_catalog, args[0], .@"resume")) return .last;
        if (!std.mem.startsWith(u8, args[0], resume_id_alias_prefix)) return error.InvalidResumeArgs;
        const id = args[0][resume_id_alias_prefix.len..];
        if (id.len == 0) return error.InvalidResumeArgs;
        return .{ .id = try alloc.dupe(u8, id) };
    }

    if (std.mem.eql(u8, args[0], "--resume")) {
        if (args.len == 2 and std.mem.eql(u8, args[1], "--last")) return .last;
        return error.InvalidResumeArgs;
    }

    const exact_id = std.mem.eql(u8, args[0], "--id");
    const operand_index: usize = if (exact_id) 1 else 0;
    if (args.len != operand_index + 1) return error.InvalidResumeArgs;

    const trimmed = std.mem.trim(u8, args[operand_index], " \t\r\n");
    if (trimmed.len == 0) return error.InvalidResumeArgs;
    if (!exact_id and std.mem.eql(u8, trimmed, "last")) return .last;
    return .{ .id = try alloc.dupe(u8, trimmed) };
}

fn parseWorkflowArgs(alloc: Allocator, args: []const [:0]const u8) !WorkflowOptions {
    var auto_permission = false;
    var create = false;
    var start_index: usize = 0;
    while (start_index < args.len) : (start_index += 1) {
        if (std.mem.eql(u8, args[start_index], "--auto")) {
            auto_permission = true;
            continue;
        }
        if (std.mem.eql(u8, args[start_index], "--create")) {
            create = true;
            continue;
        }
        break;
    }

    return .{
        .auto_permission = auto_permission,
        .create = create,
        .context = try joinArgs(alloc, args[start_index..]),
    };
}

fn joinArgs(alloc: Allocator, args: []const [:0]const u8) ![]u8 {
    if (args.len == 0) return alloc.dupe(u8, "");

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (args, 0..) |arg, i| {
        if (i > 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(arg);
    }
    return try out.toOwnedSlice();
}

fn isVersionFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v");
}

fn testCommandCatalog() CommandCatalog {
    const builtin_commands = @import("../../builtins/commands.zig");
    return builtin_commands.top_level_registry;
}

test "parse recognizes every top-level command and preserves unknown commands" {
    const command_catalog = testCommandCatalog();
    try std.testing.expectEqual(Command.interactive, parse(command_catalog, &.{}));
    try std.testing.expectEqual(Command.help, parse(command_catalog, &.{@constCast("help")}));

    switch (parse(command_catalog, &.{ @constCast("ask"), @constCast("hello") })) {
        .ask => |rest| try std.testing.expectEqual(@as(usize, 1), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("acp"), @constCast("--model"), @constCast("m") })) {
        .acp => |rest| try std.testing.expectEqual(@as(usize, 2), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("pr"), @constCast("ready") })) {
        .pr => |rest| try std.testing.expectEqual(@as(usize, 1), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("issue"), @constCast("flaky") })) {
        .issue => |rest| try std.testing.expectEqual(@as(usize, 1), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("status"), @constCast("--json") })) {
        .status => |rest| try std.testing.expectEqual(@as(usize, 1), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{@constCast("permissions")})) {
        .permissions => |rest| try std.testing.expectEqual(@as(usize, 0), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("models"), @constCast("--json") })) {
        .models => |rest| try std.testing.expectEqual(@as(usize, 1), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{@constCast("doctor")})) {
        .doctor => |rest| try std.testing.expectEqual(@as(usize, 0), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{@constCast("background")})) {
        .unknown => |value| try std.testing.expectEqualStrings("background", value),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("session"), @constCast("last") })) {
        .session => |rest| try std.testing.expectEqual(@as(usize, 1), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("session"), @constCast("resume"), @constCast("last") })) {
        .resume_session => |invocation| try std.testing.expectEqual(@as(usize, 1), invocation.args.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("sessions"), @constCast("--json") })) {
        .sessions => |rest| try std.testing.expectEqual(@as(usize, 1), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("resume"), @constCast("last") })) {
        .resume_session => |invocation| try std.testing.expectEqual(@as(usize, 1), invocation.args.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("usage"), @constCast("--period"), @constCast("24h") })) {
        .usage => |rest| try std.testing.expectEqual(@as(usize, 2), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{ @constCast("replay"), @constCast("tape") })) {
        .replay => |rest| try std.testing.expectEqual(@as(usize, 1), rest.len),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{@constCast("wat")})) {
        .unknown => |value| try std.testing.expectEqualStrings("wat", value),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{@constCast("task")})) {
        .unknown => |value| try std.testing.expectEqualStrings("task", value),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{@constCast("tasks")})) {
        .unknown => |value| try std.testing.expectEqualStrings("tasks", value),
        else => return error.TestExpectedEqual,
    }
    switch (parse(command_catalog, &.{@constCast("--record")})) {
        .unknown => |value| try std.testing.expectEqualStrings("--record", value),
        else => return error.TestExpectedEqual,
    }
}

test "help aliases route to help" {
    const command_catalog = testCommandCatalog();
    try std.testing.expectEqual(Command.help, parse(command_catalog, &.{@constCast("--help")}));
    try std.testing.expectEqual(Command.help, parse(command_catalog, &.{@constCast("-h")}));
}

test "usage arguments select local windows or Codex account usage" {
    const defaults = try parseUsageArgs(&.{});
    try std.testing.expectEqual(usage_report.Scope.days_30, defaults.scope);
    try std.testing.expectEqual(output_contracts.OutputFormat.text, defaults.format);

    const selected = try parseUsageArgs(&.{
        @constCast("--json"),
        @constCast("--period"),
        @constCast("7d"),
    });
    try std.testing.expectEqual(usage_report.Scope.days_7, selected.scope);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, selected.format);

    const codex = try parseUsageArgs(&.{ @constCast("--codex"), @constCast("--json") });
    try std.testing.expect(codex.codex_account);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, codex.format);

    for ([_][]const [:0]const u8{
        &.{@constCast("--period")},
        &.{ @constCast("--period"), @constCast("session") },
        &.{ @constCast("--period"), @constCast("24h"), @constCast("--period"), @constCast("7d") },
        &.{ @constCast("--json"), @constCast("--json") },
        &.{ @constCast("--codex"), @constCast("--codex") },
        &.{ @constCast("--codex"), @constCast("--period"), @constCast("7d") },
        &.{@constCast("30d")},
    }) |invalid| {
        try std.testing.expectError(error.InvalidUsageArgs, parseUsageArgs(invalid));
    }
}

test "global launch modifiers preserve repeatable context limits before the command" {
    var parsed = try parseGlobalLaunchArgs(std.testing.allocator, &.{
        @constCast("--context-limit"),
        @constCast("skill_chunk_bytes=4096"),
        @constCast("--context-limit=project_instruction_file_bytes=off"),
        @constCast("ask"),
        @constCast("hello"),
    });
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.modifiers.context_limit_overrides.len);
    try std.testing.expectEqual(config_runtime.context_limits.Name.skill_chunk_bytes, parsed.modifiers.context_limit_overrides[0].name);
    try std.testing.expectEqual(@as(usize, 4096), parsed.modifiers.context_limit_overrides[0].value.bytes);
    try std.testing.expectEqual(config_runtime.context_limits.Name.project_instruction_file_bytes, parsed.modifiers.context_limit_overrides[1].name);
    try std.testing.expect(parsed.modifiers.context_limit_overrides[1].value == .off);
    try std.testing.expectEqualStrings("ask", parsed.remaining[0]);
    try std.testing.expectEqualStrings("hello", parsed.remaining[1]);
}

test "global context limits reject missing values and stop at the command" {
    try std.testing.expectError(
        error.MissingContextLimitValue,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--context-limit")}),
    );
    var parsed = try parseGlobalLaunchArgs(std.testing.allocator, &.{
        @constCast("ask"),
        @constCast("--context-limit"),
        @constCast("skill_chunk_bytes=1"),
    });
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), parsed.modifiers.context_limit_overrides.len);
    try std.testing.expectEqual(@as(usize, 3), parsed.remaining.len);
}

test "global launch modifiers own repeatable additional directories and suppression" {
    var parsed = try parseGlobalLaunchArgs(std.testing.allocator, &.{
        @constCast("--add-dir"),
        @constCast("/tmp/shared one"),
        @constCast("--context-limit=skill_chunk_bytes=2048"),
        @constCast("--add-dir=/tmp/shared-two"),
        @constCast("--no-additional-dirs"),
        @constCast("ask"),
        @constCast("inspect"),
    });
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.modifiers.additional_directories.len);
    try std.testing.expectEqualStrings("/tmp/shared one", parsed.modifiers.additional_directories[0]);
    try std.testing.expectEqualStrings("/tmp/shared-two", parsed.modifiers.additional_directories[1]);
    try std.testing.expect(parsed.modifiers.saved_directories_suppressed);
    try std.testing.expectEqualStrings("ask", parsed.remaining[0]);
}

test "additional directory flags fail closed when malformed" {
    try std.testing.expectError(
        error.MissingAddDirectoryValue,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--add-dir")}),
    );
    try std.testing.expectError(
        error.MissingAddDirectoryValue,
        parseGlobalLaunchArgs(std.testing.allocator, &.{@constCast("--add-dir=")}),
    );
    try std.testing.expectError(
        error.DuplicateAdditionalDirectorySuppression,
        parseGlobalLaunchArgs(std.testing.allocator, &.{ @constCast("--no-additional-dirs"), @constCast("--no-additional-dirs") }),
    );
}

test "parse acp args extracts known flags and rejects invalid arguments" {
    const opts = try parseAcpArgs(&.{
        @constCast("--model"),
        @constCast("openai/gpt-4o"),
        @constCast("--log-file"),
        @constCast("/tmp/fx.log"),
    });
    try std.testing.expectEqualStrings("openai/gpt-4o", opts.model.?);
    try std.testing.expectEqualStrings("/tmp/fx.log", opts.log_file.?);

    try std.testing.expectError(error.InvalidAcpArgs, parseAcpArgs(&.{@constCast("--unknown")}));
    try std.testing.expectError(error.InvalidAcpArgs, parseAcpArgs(&.{@constCast("--model")}));
    try std.testing.expectError(error.InvalidAcpArgs, parseAcpArgs(&.{@constCast("--log-file")}));
    try std.testing.expectError(
        error.InvalidAcpArgs,
        parseAcpArgs(&.{ @constCast("--model"), @constCast("first"), @constCast("--model"), @constCast("second") }),
    );
}

test "ACP command routes parsed options and launch config through the injected runner" {
    const Capture = struct {
        expected: Config,
        calls: usize = 0,
        config_matches: bool = false,
        launch_matches: bool = false,

        fn run(raw: ?*anyopaque, _: Allocator, cfg: acp_runner.Config) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            const expected = self.expected;
            self.config_matches =
                std.mem.eql(u8, cfg.default_model, expected.default_model) and
                cfg.default_agent_step_limit == expected.default_agent_step_limit and
                cfg.gateway_retry_count == expected.gateway_retry_count and
                std.mem.eql(
                    u8,
                    cfg.gateway_chat_url,
                    expected.gateway_provider.chat_url.resolve(expected.gateway_chat_url),
                ) and
                std.mem.eql(u8, cfg.gateway_models_path, expected.models_path) and
                cfg.gateway_provider.chat_url.resolve_fn == expected.gateway_provider.chat_url.resolve_fn and
                std.mem.eql(u8, cfg.prompt_policy.system_prompt, expected.prompt_policy.system_prompt) and
                cfg.ignored_list_entries.len == expected.ignored_list_entries.len and
                cfg.max_list_entries == expected.max_list_entries and
                cfg.max_read_file_bytes == expected.max_read_file_bytes and
                cfg.max_read_file_lines == expected.max_read_file_lines and
                cfg.max_read_file_line_len == expected.max_read_file_line_len and
                cfg.max_command_output_bytes == expected.max_command_output_bytes and
                cfg.max_tool_result_bytes == expected.max_tool_result_bytes and
                cfg.max_history_turns == expected.max_history_turns and
                std.mem.eql(
                    u8,
                    cfg.context_registry.defaultProvider().id,
                    expected.context_registry.defaultProvider().id,
                ) and
                std.mem.eql(u8, cfg.mode_registry.default_mode_id, expected.mode_registry.default_mode_id) and
                cfg.provider_set.gateway.permission_reviewer.?.review_fn == expected.provider_set.gateway.permission_reviewer.?.review_fn;

            const limit_matches = cfg.context_limit_overrides.len == 1 and
                cfg.context_limit_overrides[0].name == .project_instructions_total_bytes and
                switch (cfg.context_limit_overrides[0].value) {
                    .bytes => |bytes| bytes == 1234,
                    .off => false,
                };
            self.launch_matches =
                limit_matches and
                cfg.additional_directories.len == 1 and
                std.mem.eql(u8, cfg.additional_directories[0], "/tmp/acp-extra") and
                cfg.saved_directories_suppressed and
                std.mem.eql(u8, cfg.model_override.?, "model-override") and
                std.mem.eql(u8, cfg.log_file.?, "/tmp/acp.log");
        }
    };

    var cfg = testConfig();
    cfg.provider_set.gateway.permission_reviewer = test_builtin_gateway.permission_reviewer.provider;
    var capture = Capture{ .expected = cfg };
    cfg.acp_runner = .{ .context = &capture, .run_fn = Capture.run };
    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{
            @constCast("--context-limit"),
            @constCast("project_instructions_total_bytes=1234"),
            @constCast("--add-dir"),
            @constCast("/tmp/acp-extra"),
            @constCast("--no-additional-dirs"),
            @constCast("acp"),
            @constCast("--model"),
            @constCast("model-override"),
            @constCast("--log-file"),
            @constCast("/tmp/acp.log"),
        },
        cfg,
        .{},
    );

    try std.testing.expectEqual(RunResult.handled_success, result);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.config_matches);
    try std.testing.expect(capture.launch_matches);
}

test "ACP runner errors preserve their identity" {
    const Fixture = struct {
        fn run(_: ?*anyopaque, _: Allocator, _: acp_runner.Config) anyerror!void {
            return error.TestAcpRunnerFailed;
        }
    };

    var cfg = testConfig();
    cfg.acp_runner = .{ .run_fn = Fixture.run };
    try std.testing.expectError(
        error.TestAcpRunnerFailed,
        runIfRequested(std.testing.allocator, &.{@constCast("acp")}, cfg),
    );
}

test "parse local surface args accepts only json" {
    const empty = try parseLocalSurfaceArgs(&.{});
    try std.testing.expectEqual(output_contracts.OutputFormat.text, empty.format);

    const opts = try parseLocalSurfaceArgs(&.{@constCast("--json")});
    try std.testing.expectEqual(output_contracts.OutputFormat.json, opts.format);

    try std.testing.expectError(error.InvalidLocalSurfaceArgs, parseLocalSurfaceArgs(&.{@constCast("--wat")}));
}

test "parse session list args supports bounded canonical pagination" {
    const empty = try parseSessionListArgs(&.{});
    try std.testing.expectEqual(output_contracts.OutputFormat.text, empty.format);
    try std.testing.expectEqual(session_store.session_list_default_limit, empty.limit);
    try std.testing.expect(empty.continuation == null);

    const paged = try parseSessionListArgs(&.{
        @constCast("--json"),
        @constCast("--all"),
        @constCast("--limit"),
        @constCast("2"),
        @constCast("--cursor"),
        @constCast("v1:20:session-a"),
    });
    try std.testing.expectEqual(output_contracts.OutputFormat.json, paged.format);
    try std.testing.expectEqual(session_store.SessionListScope.all_workspaces, paged.scope);
    try std.testing.expectEqual(@as(usize, 2), paged.limit);
    try std.testing.expectEqual(@as(i64, 20), paged.continuation.?.updated_at_ms);
    try std.testing.expectEqualStrings("session-a", paged.continuation.?.id);

    try std.testing.expectError(
        error.InvalidLocalSurfaceArgs,
        parseSessionListArgs(&.{ @constCast("--all"), @constCast("--all") }),
    );
    try std.testing.expectError(
        error.InvalidLocalSurfaceArgs,
        parseSessionListArgs(&.{ @constCast("--limit"), @constCast("0") }),
    );
    try std.testing.expectError(
        error.InvalidLocalSurfaceArgs,
        parseSessionListArgs(&.{ @constCast("--limit"), @constCast("101") }),
    );
    try std.testing.expectError(
        error.InvalidLocalSurfaceArgs,
        parseSessionListArgs(&.{ @constCast("--limit"), @constCast("2"), @constCast("--limit"), @constCast("3") }),
    );
    try std.testing.expectError(
        error.InvalidLocalSurfaceArgs,
        parseSessionListArgs(&.{@constCast("--cursor")}),
    );
    try std.testing.expectError(
        error.InvalidLocalSurfaceArgs,
        parseSessionListArgs(&.{ @constCast("--cursor"), @constCast("v1:020:session-a") }),
    );
    try std.testing.expectError(
        error.InvalidLocalSurfaceArgs,
        parseSessionListArgs(&.{ @constCast("--cursor"), @constCast("v2:20:session-a") }),
    );
    try std.testing.expectError(
        error.InvalidLocalSurfaceArgs,
        parseSessionListArgs(&.{ @constCast("--cursor"), @constCast("v1:20:../unsafe") }),
    );
}

test "parse session detail args owns string ids and frees through deinit" {
    var latest = try parseSessionDetailArgs(std.testing.allocator, &.{ @constCast("last"), @constCast("--json") });
    defer latest.deinit(std.testing.allocator);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, latest.format);
    try std.testing.expectEqual(SessionDetailTarget.last, latest.target.?);

    var specific = try parseSessionDetailArgs(std.testing.allocator, &.{@constCast(" sess-1 ")});
    defer specific.deinit(std.testing.allocator);
    switch (specific.target.?) {
        .id => |value| try std.testing.expectEqualStrings("sess-1", value),
        else => return error.TestExpectedEqual,
    }

    try std.testing.expectError(error.InvalidSessionDetailArgs, parseSessionDetailArgs(std.testing.allocator, &.{ @constCast("a"), @constCast("b") }));
    try std.testing.expectError(error.InvalidSessionDetailArgs, parseSessionDetailArgs(std.testing.allocator, &.{@constCast("")}));
}

test "parse session detail args accepts explicit id flag" {
    var specific = try parseSessionDetailArgs(std.testing.allocator, &.{
        @constCast("--id"),
        @constCast("release.2026.06"),
        @constCast("--json"),
    });
    defer specific.deinit(std.testing.allocator);

    try std.testing.expectEqual(output_contracts.OutputFormat.json, specific.format);
    switch (specific.target.?) {
        .last => return error.TestExpectedExactResumeId,
        .id => |id| try std.testing.expectEqualStrings("release.2026.06", id),
    }
}

test "parse session detail args treats last after id flag as exact id" {
    var specific = try parseSessionDetailArgs(std.testing.allocator, &.{
        @constCast("--id"),
        @constCast("last"),
    });
    defer specific.deinit(std.testing.allocator);

    switch (specific.target.?) {
        .last => return error.TestExpectedExactResumeId,
        .id => |id| try std.testing.expectEqualStrings("last", id),
    }
}

test "parse session migration args accepts positional and exact ids" {
    var positional = try parseSessionMigrationArgs(std.testing.allocator, &.{
        @constCast("session.v2"),
        @constCast("--allow-large"),
        @constCast("--json"),
    });
    defer positional.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("session.v2", positional.session_id);
    try std.testing.expect(positional.allow_large);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, positional.format);

    var exact = try parseSessionMigrationArgs(std.testing.allocator, &.{
        @constCast("--id"),
        @constCast("--allow-large"),
        @constCast("--json"),
    });
    defer exact.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("--allow-large", exact.session_id);
    try std.testing.expect(!exact.allow_large);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, exact.format);
}

test "parse session migration args rejects missing repeated and mixed targets" {
    try std.testing.expectError(
        error.InvalidSessionMigrationArgs,
        parseSessionMigrationArgs(std.testing.allocator, &.{@constCast("--id")}),
    );
    try std.testing.expectError(
        error.InvalidSessionMigrationArgs,
        parseSessionMigrationArgs(std.testing.allocator, &.{
            @constCast("session.v2"),
            @constCast("--id"),
            @constCast("session.v3"),
        }),
    );
    try std.testing.expectError(
        error.InvalidSessionMigrationArgs,
        parseSessionMigrationArgs(std.testing.allocator, &.{
            @constCast("session.v2"),
            @constCast("session.v3"),
        }),
    );
}

test "parse session recovery args accepts exact ids and rejects ambiguity" {
    var positional = try parseSessionRecoveryArgs(
        std.testing.allocator,
        &.{
            @constCast("session.v3"),
            @constCast("--json"),
        },
    );
    defer positional.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("session.v3", positional.session_id);
    try std.testing.expectEqual(
        output_contracts.OutputFormat.json,
        positional.format,
    );

    var exact = try parseSessionRecoveryArgs(
        std.testing.allocator,
        &.{
            @constCast("--id"),
            @constCast("last"),
        },
    );
    defer exact.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("last", exact.session_id);

    try std.testing.expectError(
        error.InvalidSessionRecoveryArgs,
        parseSessionRecoveryArgs(
            std.testing.allocator,
            &.{@constCast("--id")},
        ),
    );
    try std.testing.expectError(
        error.InvalidSessionRecoveryArgs,
        parseSessionRecoveryArgs(
            std.testing.allocator,
            &.{
                @constCast("first"),
                @constCast("second"),
            },
        ),
    );
}

test "parse resume args defaults to last owns ids and rejects invalid input" {
    const command_catalog = testCommandCatalog();
    const implicit = try parseResumeArgs(std.testing.allocator, command_catalog, &.{}, false);
    try std.testing.expectEqual(ResumeTarget.last, implicit);

    const explicit = try parseResumeArgs(std.testing.allocator, command_catalog, &.{@constCast("last")}, false);
    try std.testing.expectEqual(ResumeTarget.last, explicit);

    var target = try parseResumeArgs(std.testing.allocator, command_catalog, &.{@constCast(" session-123 ")}, false);
    defer target.deinit(std.testing.allocator);
    switch (target) {
        .id => |value| try std.testing.expectEqualStrings("session-123", value),
        else => return error.TestExpectedEqual,
    }

    try std.testing.expectError(error.InvalidResumeArgs, parseResumeArgs(std.testing.allocator, command_catalog, &.{ @constCast("a"), @constCast("b") }, false));
    try std.testing.expectError(error.InvalidResumeArgs, parseResumeArgs(std.testing.allocator, command_catalog, &.{@constCast("   ")}, false));
}

test "parse resume args accepts explicit id flag" {
    const command_catalog = testCommandCatalog();
    var target = try parseResumeArgs(std.testing.allocator, command_catalog, &.{
        @constCast("--id"),
        @constCast("release.2026.06"),
    }, false);
    defer target.deinit(std.testing.allocator);

    switch (target) {
        .pick, .last => return error.TestExpectedExactResumeId,
        .id => |id| try std.testing.expectEqualStrings("release.2026.06", id),
    }
}

test "parse resume args accepts an operand on the top-level resume flag" {
    const command_catalog = testCommandCatalog();
    var target = try parseResumeArgs(std.testing.allocator, command_catalog, &.{
        @constCast("--resume"),
        @constCast("session-123"),
    }, true);
    defer target.deinit(std.testing.allocator);

    switch (target) {
        .pick, .last => return error.TestExpectedExactResumeId,
        .id => |id| try std.testing.expectEqualStrings("session-123", id),
    }

    const latest = try parseResumeArgs(std.testing.allocator, command_catalog, &.{
        @constCast("--resume"),
        @constCast("last"),
    }, true);
    try std.testing.expectEqual(ResumeTarget.last, latest);
}

test "parse resume args treats last after id flag as exact id" {
    const command_catalog = testCommandCatalog();
    var target = try parseResumeArgs(std.testing.allocator, command_catalog, &.{
        @constCast("--id"),
        @constCast("last"),
    }, false);
    defer target.deinit(std.testing.allocator);

    switch (target) {
        .pick, .last => return error.TestExpectedExactResumeId,
        .id => |id| try std.testing.expectEqualStrings("last", id),
    }
}

test "parseInteractiveLaunch shares native resume grammar" {
    const alloc = std.testing.allocator;
    const command_catalog = testCommandCatalog();
    const cases = [_]struct {
        args: []const [:0]const u8,
        expected_id: ?[]const u8,
    }{
        .{ .args = &.{@constCast("--resume")}, .expected_id = null },
        .{ .args = &.{ @constCast("--resume"), @constCast("last") }, .expected_id = null },
        .{ .args = &.{ @constCast("--resume"), @constCast("session-123") }, .expected_id = "session-123" },
        .{ .args = &.{ @constCast("session"), @constCast("resume"), @constCast("last") }, .expected_id = null },
        .{ .args = &.{ @constCast("session"), @constCast("resume"), @constCast("--id"), @constCast("session.v3") }, .expected_id = "session.v3" },
    };
    for (cases) |case| {
        const parsed = try parseInteractiveLaunch(alloc, case.args, command_catalog);
        switch (parsed) {
            .interactive => |value| {
                var launch = value;
                defer launch.deinit(alloc);
                const target = launch.requested_resume orelse return error.TestExpectedResumeTarget;
                if (case.expected_id) |expected_id| switch (target) {
                    .id => |id| try std.testing.expectEqualStrings(expected_id, id),
                    .pick, .last => return error.TestExpectedExactResumeId,
                } else try std.testing.expectEqual(ResumeTarget.last, target);
            },
            .noninteractive => |value| {
                var noninteractive = value;
                defer noninteractive.deinit(alloc);
                return error.TestExpectedInteractiveLaunch;
            },
        }
    }

    try std.testing.expectError(
        error.InvalidResumeArgs,
        parseInteractiveLaunch(
            alloc,
            &.{ @constCast("--resume"), @constCast("one"), @constCast("two") },
            command_catalog,
        ),
    );
    try std.testing.expectError(
        error.MissingAddDirectoryValue,
        parseInteractiveLaunch(alloc, &.{@constCast("--add-dir")}, command_catalog),
    );
}

test "parse workflow args consumes leading flags and joins remaining context exactly" {
    var opts = try parseWorkflowArgs(std.testing.allocator, &.{
        @constCast("--auto"),
        @constCast("--create"),
        @constCast("ready"),
        @constCast("for"),
        @constCast("review"),
    });
    defer opts.deinit(std.testing.allocator);
    try std.testing.expect(opts.auto_permission);
    try std.testing.expect(opts.create);
    try std.testing.expectEqualStrings("ready for review", opts.context);

    var later_flag = try parseWorkflowArgs(std.testing.allocator, &.{
        @constCast("context"),
        @constCast("--auto"),
    });
    defer later_flag.deinit(std.testing.allocator);
    try std.testing.expect(!later_flag.auto_permission);
    try std.testing.expect(!later_flag.create);
    try std.testing.expectEqualStrings("context --auto", later_flag.context);

    var empty = try parseWorkflowArgs(std.testing.allocator, &.{});
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", empty.context);
}

test "runIfRequested help writes top-level help" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{@constCast("help")}, testConfig(), capture.deps());
    try std.testing.expectEqual(RunResult.handled_success, result);
    try std.testing.expect(std.mem.startsWith(u8, capture.stdout.written(), "𝒇x v0.0.0\nFast, native coding agent for the terminal."));
    try std.testing.expect(std.mem.find(u8, capture.stdout.written(), testConfig().version) != null);
    try std.testing.expectEqualStrings("", capture.stderr.written());
}

test "workspace launch modifiers preserve supported command help" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    const deps = capture.deps();

    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("--add-dir"), @constCast("/tmp/shared"), @constCast("ask"), @constCast("--help") },
        testConfig(),
        deps,
    );
    try std.testing.expectEqual(RunResult.handled_success, result);
    try std.testing.expect(std.mem.startsWith(u8, capture.stdout.written(), "fx ask\n\n"));
    try std.testing.expectEqualStrings("", capture.stderr.written());
}

test "workspace launch modifiers still reject unsupported local command help" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    const deps = capture.deps();

    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("--add-dir"), @constCast("/tmp/shared"), @constCast("status"), @constCast("--help") },
        testConfig(),
        deps,
    );
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings("", capture.stdout.written());
    try std.testing.expect(std.mem.find(u8, capture.stderr.written(), "only supported for interactive, resume, ask, ACP, PR, and issue launches") != null);
}

test "global workspace launch option errors use user-facing copy" {
    const cases = [_]struct {
        args: []const [:0]const u8,
        expected: []const u8,
    }{
        .{
            .args = &.{@constCast("--add-dir")},
            .expected = "fx: --add-dir requires a directory path\n",
        },
        .{
            .args = &.{ @constCast("--no-additional-dirs"), @constCast("--no-additional-dirs") },
            .expected = "fx: --no-additional-dirs may only be specified once\n",
        },
    };

    for (cases) |case| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();
        const deps = capture.deps();

        const result = try runIfRequestedWithDeps(std.testing.allocator, case.args, testConfig(), deps);
        try std.testing.expectEqual(RunResult.handled_failure, result);
        try std.testing.expectEqualStrings("", capture.stdout.written());
        try std.testing.expect(std.mem.startsWith(u8, capture.stderr.written(), case.expected));
        try std.testing.expect(std.mem.endsWith(u8, capture.stderr.written(), "<command>\n"));
    }
}

test "runIfRequested version flags write configured version" {
    const cases = [_][]const [:0]const u8{
        &.{@constCast("--version")},
        &.{@constCast("-v")},
    };

    for (cases) |args| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();

        const result = try runIfRequestedWithDeps(std.testing.allocator, args, testConfig(), capture.deps());
        try std.testing.expectEqual(RunResult.handled_success, result);
        try std.testing.expectEqualStrings("0.0.0\n", capture.stdout.written());
        try std.testing.expectEqualStrings("", capture.stderr.written());
    }
}

test "runIfRequested version flags reject extra args" {
    const cases = [_][]const [:0]const u8{
        &.{ @constCast("--version"), @constCast("extra") },
        &.{ @constCast("-v"), @constCast("extra") },
    };

    for (cases) |args| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();

        const result = try runIfRequestedWithDeps(std.testing.allocator, args, testConfig(), capture.deps());
        try std.testing.expectEqual(RunResult.handled_failure, result);
        try std.testing.expectEqualStrings("", capture.stdout.written());
        try std.testing.expectEqualStrings("usage: fx --version\n", capture.stderr.written());
    }
}

test "workspace indeterminate errors report the reconciled durable state" {
    const cases = [_]struct {
        reconciliation: workspace_commands.Reconciliation,
        expected: []const u8,
    }{
        .{
            .reconciliation = .{ .intended = .{} },
            .expected = "reloaded settings match the requested update",
        },
        .{
            .reconciliation = .{ .previous = .{} },
            .expected = "reloaded settings match the previous state",
        },
        .{
            .reconciliation = .unconfirmed,
            .expected = "reloaded settings match neither the requested nor previous state",
        },
    };

    for (cases) |case| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();
        try writeWorkspaceIndeterminateError(
            std.testing.allocator,
            capture.deps(),
            &.{@constCast("--json")},
            case.reconciliation,
        );
        try std.testing.expect(std.mem.find(u8, capture.stdout.written(), case.expected) != null);
        try std.testing.expect(std.mem.find(u8, capture.stdout.written(), "\"code\":\"SettingsCommitIndeterminate\"") != null);
        try std.testing.expectEqualStrings("", capture.stderr.written());
    }
}

test "workspace json errors keep stable codes with shared user-facing copy" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    try writeWorkspaceCommandError(
        std.testing.allocator,
        testCommandCatalog(),
        capture.deps(),
        &.{@constCast("--json")},
        error.PrimaryDirectory,
    );
    try std.testing.expect(std.mem.find(u8, capture.stdout.written(), "\"error\":\"the primary workspace cannot be added or removed\"") != null);
    try std.testing.expect(std.mem.find(u8, capture.stdout.written(), "\"code\":\"PrimaryDirectory\"") != null);
    try std.testing.expectEqualStrings("", capture.stderr.written());
}

test "workspace unknown directory errors keep stable json codes" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    try writeWorkspaceCommandError(
        std.testing.allocator,
        testCommandCatalog(),
        capture.deps(),
        &.{@constCast("--json")},
        error.UnknownAdditionalDirectory,
    );
    try std.testing.expect(std.mem.find(u8, capture.stdout.written(), "\"error\":\"directory is not configured as an additional workspace\"") != null);
    try std.testing.expect(std.mem.find(u8, capture.stdout.written(), "\"code\":\"UnknownAdditionalDirectory\"") != null);
    try std.testing.expectEqualStrings("", capture.stderr.written());
}

test "runNoConfigIfRequested handles help without config" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    try std.testing.expect(try runNoConfigIfRequestedWithDeps(
        std.testing.allocator,
        &.{@constCast("help")},
        "0.0.0",
        testCommandCatalog(),
        capture.deps(),
    ));
    try std.testing.expect(std.mem.startsWith(u8, capture.stdout.written(), "𝒇x v0.0.0\nFast, native coding agent for the terminal."));
    try std.testing.expectEqualStrings("", capture.stderr.written());

    try std.testing.expect(!try runNoConfigIfRequestedWithDeps(
        std.testing.allocator,
        &.{@constCast("status")},
        "0.0.0",
        testCommandCatalog(),
        capture.deps(),
    ));
}

test "CLI surface uses the supplied command catalog for parsing usage and help" {
    const specs = [_]command_specs.TopLevelSpec{
        .{
            .kind = .help,
            .token = "guide",
            .aliases = &.{"-?"},
            .usage = "guide",
            .summary = "Show injected help",
        },
        .{
            .kind = .status,
            .token = "start",
            .usage = "start",
            .summary = "Show injected status",
        },
    };
    const help_groups = [_]command_specs.TopLevelHelpGroup{
        .{ .entries = &.{
            .{ .kind = .status, .usage = "start" },
            .{ .kind = .help, .usage = "guide" },
        } },
    };
    const command_catalog = CommandCatalog{
        .specs = &specs,
        .description = "Injected command catalog.",
        .interactive_hint = "Injected interactive hint.",
        .help_groups = &help_groups,
    };

    try std.testing.expectEqual(Command.help, parse(command_catalog, &.{@constCast("-?")}));
    switch (parse(command_catalog, &.{@constCast("start")})) {
        .status => {},
        else => return error.TestExpectedEqual,
    }

    var help_capture = CaptureOutput.init(std.testing.allocator);
    defer help_capture.deinit();
    try std.testing.expect(try runNoConfigIfRequestedWithDeps(
        std.testing.allocator,
        &.{@constCast("guide")},
        "1.2.3",
        command_catalog,
        help_capture.deps(),
    ));
    try std.testing.expect(std.mem.find(u8, help_capture.stdout.written(), "Injected command catalog.") != null);

    var usage_capture = CaptureOutput.init(std.testing.allocator);
    defer usage_capture.deinit();
    var cfg = testConfig();
    cfg.command_catalog = command_catalog;
    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("start"), @constCast("unexpected") },
        cfg,
        usage_capture.deps(),
    );
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings("usage: fx start\n", usage_capture.stderr.written());
}

test "workflow config does not carry placeholder gateway tools" {
    const skill_roots = [_]skill_contract.RootSpec{
        .{ .source = .workspace_shared, .path = "skills" },
    };
    var chat_url_probe = ChatUrlProbe{};
    var surface_cfg = testConfig();
    surface_cfg.skill_root_policy.workspace_roots = &skill_roots;
    surface_cfg.gateway_provider.chat_url = chat_url_probe.provider();
    const cfg = workflowConfig(surface_cfg);
    try std.testing.expect(!@hasField(@TypeOf(cfg), "gateway_tools_json"));
    try std.testing.expect(!@hasField(@TypeOf(cfg), "context_registry"));
    try std.testing.expectEqualStrings("test-model", cfg.default_model);
    try std.testing.expectEqualStrings("http://127.0.0.1:43123/chat", cfg.gateway_chat_url);
    try std.testing.expect(chat_url_probe.called);
    try std.testing.expectEqualStrings("surface", cfg.mode_registry.default_mode_id);
    try std.testing.expectEqualStrings("skills", cfg.skill_root_policy.workspace_roots[0].path);
}
test "runIfRequested invalid local flags write usage" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("status"), @constCast("--wat") }, testConfig(), capture.deps());
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings("", capture.stdout.written());
    try std.testing.expectEqualStrings("usage: fx status [--json]\n", capture.stderr.written());
}

test "runIfRequested invalid json local flags write json error" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("status"), @constCast("--json"), @constCast("--wat") }, testConfig(), capture.deps());
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings("", capture.stderr.written());
    try std.testing.expect(std.mem.find(u8, capture.stdout.written(), "\"kind\":\"status\"") != null);
    try std.testing.expect(std.mem.find(u8, capture.stdout.written(), "\"code\":\"InvalidLocalSurfaceArgs\"") != null);
}

test "runIfRequested resume no args returns last target" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{@constCast("resume")}, testConfig(), capture.deps());
    switch (result) {
        .interactive => |launch| try std.testing.expectEqual(ResumeTarget.last, launch.requested_resume.?),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqualStrings("", capture.stderr.written());
}

test "runIfRequested -r asks which session to resume" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{@constCast("-r")},
        testConfig(),
        capture.deps(),
    );
    switch (result) {
        .interactive => |launch| try std.testing.expectEqual(ResumeTarget.pick, launch.requested_resume.?),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqualStrings("", capture.stdout.written());
    try std.testing.expectEqualStrings("", capture.stderr.written());

    var extra_capture = CaptureOutput.init(std.testing.allocator);
    defer extra_capture.deinit();
    const extra = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("-r"), @constCast("session.123") },
        testConfig(),
        extra_capture.deps(),
    );
    try std.testing.expectEqual(RunResult.handled_failure, extra);
}

test "runIfRequested top-level resume aliases return the existing target" {
    const aliases = [_][]const [:0]const u8{
        &.{@constCast("--resume")},
        &.{@constCast("--resume-last")},
        &.{@constCast("--continue")},
        &.{@constCast("-c")},
    };
    for (aliases) |args| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();

        const result = try runIfRequestedWithDeps(
            std.testing.allocator,
            args,
            testConfig(),
            capture.deps(),
        );
        switch (result) {
            .interactive => |launch| try std.testing.expectEqual(ResumeTarget.last, launch.requested_resume.?),
            else => return error.TestExpectedEqual,
        }
        try std.testing.expectEqualStrings("", capture.stdout.written());
        try std.testing.expectEqualStrings("", capture.stderr.written());
    }

    var operand_capture = CaptureOutput.init(std.testing.allocator);
    defer operand_capture.deinit();

    const operand = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("--resume"), @constCast("session.123") },
        testConfig(),
        operand_capture.deps(),
    );
    switch (operand) {
        .interactive => |launch_value| {
            var launch = launch_value;
            defer launch.deinit(std.testing.allocator);
            switch (launch.requested_resume.?) {
                .id => |id| try std.testing.expectEqualStrings("session.123", id),
                .pick, .last => return error.TestExpectedExactResumeId,
            }
        },
        else => return error.TestExpectedEqual,
    }

    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const exact = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{@constCast("--resume-session.123")},
        testConfig(),
        capture.deps(),
    );
    switch (exact) {
        .interactive => |launch_value| {
            var launch = launch_value;
            defer launch.deinit(std.testing.allocator);
            switch (launch.requested_resume.?) {
                .id => |id| try std.testing.expectEqualStrings("session.123", id),
                .pick, .last => return error.TestExpectedExactResumeId,
            }
        },
        else => return error.TestExpectedEqual,
    }

    const nested = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("resume"), @constCast("--resume"), @constCast("--last") },
        testConfig(),
        capture.deps(),
    );
    switch (nested) {
        .interactive => |launch| try std.testing.expectEqual(ResumeTarget.last, launch.requested_resume.?),
        else => return error.TestExpectedEqual,
    }
}

test "runIfRequested rejects malformed resume aliases with canonical usage" {
    const cases = [_][]const [:0]const u8{
        &.{@constCast("--resume-")},
        &.{ @constCast("--resume-last"), @constCast("unexpected") },
        &.{ @constCast("--continue"), @constCast("unexpected") },
        &.{ @constCast("--resume"), @constCast("   ") },
        &.{ @constCast("resume"), @constCast("--resume") },
    };
    for (cases) |args| {
        var capture = CaptureOutput.init(std.testing.allocator);
        defer capture.deinit();

        const result = try runIfRequestedWithDeps(
            std.testing.allocator,
            args,
            testConfig(),
            capture.deps(),
        );
        try std.testing.expectEqual(RunResult.handled_failure, result);
        try std.testing.expectEqualStrings(
            "usage: fx session resume [last|<id>] | session resume --id <id> | --resume [last|<id>] | resume [last|<id>] | resume --id <id> | --resume-last | --continue | -c | -r | --resume-<id>\n",
            capture.stderr.written(),
        );
    }
}

test "runIfRequested resume id returns owned id" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("resume"), @constCast("abc123") }, testConfig(), capture.deps());
    switch (result) {
        .interactive => |launch_value| {
            var launch = launch_value;
            defer launch.deinit(std.testing.allocator);
            switch (launch.requested_resume.?) {
                .id => |value| try std.testing.expectEqualStrings("abc123", value),
                else => return error.TestExpectedEqual,
            }
        },
        else => return error.TestExpectedEqual,
    }
}

test "runIfRequested invalid resume writes usage" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("resume"), @constCast("a"), @constCast("b") }, testConfig(), capture.deps());
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings(
        "usage: fx session resume [last|<id>] | session resume --id <id> | --resume [last|<id>] | resume [last|<id>] | resume --id <id> | --resume-last | --continue | -c | -r | --resume-<id>\n",
        capture.stderr.written(),
    );
}

test "runIfRequested unknown command writes header and help" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    try std.testing.expectError(
        error.UnknownCliCommand,
        runIfRequestedWithDeps(std.testing.allocator, &.{@constCast("wat")}, testConfig(), capture.deps()),
    );
    try std.testing.expect(std.mem.startsWith(u8, capture.stderr.written(), "fx: unknown subcommand: wat\n\n𝒇x v0.0.0\nFast, native coding agent for the terminal.\n"));
}

test "runIfRequested bare version subcommand remains unknown" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    try std.testing.expectError(
        error.UnknownCliCommand,
        runIfRequestedWithDeps(std.testing.allocator, &.{@constCast("version")}, testConfig(), capture.deps()),
    );
    try std.testing.expect(std.mem.startsWith(u8, capture.stderr.written(), "fx: unknown subcommand: version\n\n𝒇x v0.0.0\nFast, native coding agent for the terminal.\n"));
}

test "runIfRequested provider usage includes gateway URL and key" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{@constCast("provider")},
        testConfig(),
        capture.deps(),
    );
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expect(std.mem.find(u8, capture.stderr.written(), "usage: fx provider <gateway|codex|grok> [base-url api-key]") != null);
}

test "runIfRequested logout usage includes gateway" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{@constCast("logout")},
        testConfig(),
        capture.deps(),
    );
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expect(std.mem.find(u8, capture.stderr.written(), "usage: fx logout <codex|grok|gateway>") != null);
}

test "runIfRequested model fetch failure is handled" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    var probe = ModelFetchProbe{ .outcome = .failure };
    var cfg = testConfig();
    cfg.provider_set.gateway.cli_model_catalog = probe.provider();

    var deps = capture.deps();
    deps.load_startup_state = failingStartupState;
    deps.load_catalog_startup_state = stubLoadCatalogStartupState;

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{@constCast("models")}, cfg, deps);
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings(
        "fx models: could not list models: Unavailable\n",
        capture.stderr.written(),
    );
}

test "runIfRequested model fetch failure preserves json output" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    var probe = ModelFetchProbe{ .outcome = .failure };
    var cfg = testConfig();
    cfg.provider_set.gateway.cli_model_catalog = probe.provider();

    var deps = capture.deps();
    deps.load_catalog_startup_state = stubLoadCatalogStartupState;

    const result = try runIfRequestedWithDeps(
        std.testing.allocator,
        &.{ @constCast("models"), @constCast("--json") },
        cfg,
        deps,
    );
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"models\",\"error\":\"could not list models: Unavailable\",\"code\":\"Unavailable\"}\n",
        capture.stdout.written(),
    );
    try std.testing.expectEqualStrings("", capture.stderr.written());
}

test "runIfRequested model provider cancellation is handled" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    var probe = ModelFetchProbe{ .outcome = .cancelled };
    var cfg = testConfig();
    cfg.provider_set.gateway.cli_model_catalog = probe.provider();

    var deps = capture.deps();
    deps.load_catalog_startup_state = stubLoadCatalogStartupState;

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{@constCast("models")}, cfg, deps);
    try std.testing.expectEqual(RunResult.handled_failure, result);
    try std.testing.expectEqualStrings(
        "fx models: could not list models: the request was cancelled\n",
        capture.stderr.written(),
    );
}

test "runIfRequested models passes startup team to fetch seam" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();
    var probe = ModelFetchProbe{};
    var cfg = testConfig();
    cfg.provider_set.gateway.cli_model_catalog = probe.provider();

    var deps = capture.deps();
    deps.load_catalog_startup_state = stubLoadCatalogStartupState;

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("models"), @constCast("--json") }, cfg, deps);
    try std.testing.expectEqual(RunResult.handled_success, result);
    try std.testing.expect(probe.called);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"models\",\"count\":1,\"shown_count\":1,\"more_count\":0,\"private_models_hidden\":false,\"ids\":[\"private/blue-hornbill\"]}\n",
        capture.stdout.written(),
    );
}

test "runIfRequested local json success appends exactly one newline" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    var deps = capture.deps();
    deps.load_startup_status = stubLoadStartupStatus;

    const result = try runIfRequestedWithDeps(std.testing.allocator, &.{ @constCast("status"), @constCast("--json") }, testConfig(), deps);
    try std.testing.expectEqual(RunResult.handled_success, result);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"status\",\"model\":\"test-model\",\"auth\":\"missing\",\"auth_refreshable\":false,\"auth_help\":\"Fx needs a model credential. Set OPENAI_API_KEY for a Responses API, use fx login codex for ChatGPT Codex, or use fx login grok for Grok.\",\"permission_mode\":\"auto\",\"workspace\":\"/tmp/fx\",\"history_turns\":0,\"session_permission_grants\":0,\"agent_step_limit\":42}\n",
        capture.stdout.written(),
    );
    try std.testing.expect(!std.mem.endsWith(u8, capture.stdout.written(), "\n\n"));
}

test "writeRenderedJsonLine falls back to heap and appends exactly one newline" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    var tiny_buf: [8]u8 = undefined;
    const startup = app_lifecycle.StartupStatus{
        .workspace_root = @constCast("/tmp/fx"),
        .selected_model = "test-model",
        .permission_mode = .ask,
        .agent_step_limit = 42,
    };

    try writeRenderedJsonLine(
        std.testing.allocator,
        capture.deps(),
        tiny_buf[0..],
        .{ .status = statusSnapshotFromStartup(startup) },
    );

    try std.testing.expectEqualStrings(
        "{\"kind\":\"status\",\"model\":\"test-model\",\"auth\":\"missing\",\"auth_refreshable\":false,\"auth_help\":\"Fx needs a model credential. Set OPENAI_API_KEY for a Responses API, use fx login codex for ChatGPT Codex, or use fx login grok for Grok.\",\"permission_mode\":\"ask\",\"workspace\":\"/tmp/fx\",\"history_turns\":0,\"session_permission_grants\":0,\"agent_step_limit\":42}\n",
        capture.stdout.written(),
    );
}

test "writeRenderedJsonLine renders doctor json through output contract" {
    var capture = CaptureOutput.init(std.testing.allocator);
    defer capture.deinit();

    var checks = [_]doctor_runtime.Check{
        .{ .name = "auth", .status = .ok, .detail = "OPENAI_API_KEY is configured" },
        .{ .name = "gh", .status = .warn, .detail = "GitHub CLI not found in PATH" },
    };
    const snapshot = doctor_runtime.Snapshot{
        .workspace_root = @constCast("/tmp/fx"),
        .model = "test-model",
        .auth = .{ .active_source = .openai_api_key },
        .permission_mode = .auto,
        .agent_step_limit = 42,
        .checks = checks[0..],
    };

    var tiny_buf: [8]u8 = undefined;
    try writeRenderedJsonLine(
        std.testing.allocator,
        capture.deps(),
        tiny_buf[0..],
        .{ .doctor = doctorSnapshotFromRuntime(snapshot) },
    );

    try std.testing.expectEqualStrings(
        "{\"kind\":\"doctor\",\"ok_count\":1,\"warn_count\":1,\"fail_count\":0,\"workspace\":\"/tmp/fx\",\"model\":\"test-model\",\"auth\":\"OPENAI_API_KEY\",\"auth_refreshable\":false,\"permission_mode\":\"auto\",\"agent_step_limit\":42,\"checks\":[{\"name\":\"auth\",\"status\":\"ok\",\"detail\":\"OPENAI_API_KEY is configured\"},{\"name\":\"gh\",\"status\":\"warn\",\"detail\":\"GitHub CLI not found in PATH\"}]}\n",
        capture.stdout.written(),
    );
}

const CaptureOutput = struct {
    stdout: std.Io.Writer.Allocating,
    stderr: std.Io.Writer.Allocating,

    fn init(alloc: Allocator) CaptureOutput {
        return .{
            .stdout = .init(alloc),
            .stderr = .init(alloc),
        };
    }

    fn deinit(self: *@This()) void {
        self.stdout.deinit();
        self.stderr.deinit();
    }

    fn deps(self: *@This()) RunDeps {
        return .{
            .stdout_ctx = self,
            .stderr_ctx = self,
            .write_stdout = captureStdout,
            .write_stderr = captureStderr,
        };
    }
};

fn captureStdout(ctx: ?*anyopaque, text: []const u8) !void {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    try capture.stdout.writer.writeAll(text);
}

fn captureStderr(ctx: ?*anyopaque, text: []const u8) !void {
    const capture: *CaptureOutput = @ptrCast(@alignCast(ctx.?));
    try capture.stderr.writer.writeAll(text);
}

fn gatherNoopContextForTest(_: Allocator, _: context_contract.InitialContextInput) context_contract.ProviderError!context_contract.ProviderContext {
    return .{};
}

fn appendNoopStaticContextForTest(_: context_contract.StaticContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) context_contract.ProviderError!void {}

fn appendNoopTransientContextForTest(_: context_contract.TransientContextInput, _: Allocator, _: *std.ArrayList(types.ChatMessage)) context_contract.ProviderError!void {}

const test_surface_context_registry = context_contract.Registry{ .default_provider = .{
    .id = "test.surface_context",
    .gather_project_context_fn = gatherNoopContextForTest,
    .select_applicable_project_context_fn = context_contract.selectNoApplicableProjectContext,
    .append_static_fn = appendNoopStaticContextForTest,
    .append_transient_fn = appendNoopTransientContextForTest,
} };

var stable_cli_test_environ: ?*std.process.Environ.Map = null;

fn stableCliTestEnviron() !*const std.process.Environ.Map {
    if (stable_cli_test_environ) |map| return map;

    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_cli_test_environ = map;
    return map;
}

fn unexpectedAcpRunForTest(_: ?*anyopaque, _: Allocator, _: acp_runner.Config) anyerror!void {
    return error.TestUnexpectedAcpRun;
}

fn testConfig() Config {
    return .{
        .version = "0.0.0",
        .command_catalog = testCommandCatalog(),
        .default_model = "test-model",
        .default_agent_step_limit = 42,
        .models_path = "/v1/models",
        .gateway_retry_count = 1,
        .gateway_chat_url = "https://example.test/chat",
        .gateway_provider = test_builtin_gateway.provider,
        .provider_set = provider_set.gateway_only(test_builtin_gateway.provider_bundle),
        .url_opener = host.unavailable_url_opener,
        .secret_store = host.unavailable_secret_store,
        .prompt_policy = .{ .system_prompt = "system" },
        .skill_root_policy = .{ .managed_root_source = .global_fx },
        .ignored_list_entries = &.{},
        .max_list_entries = 10,
        .max_read_file_bytes = 1024,
        .max_read_file_lines = 100,
        .max_read_file_line_len = 200,
        .max_command_output_bytes = 4096,
        .max_tool_result_bytes = 4096,
        .max_history_turns = 8,
        .context_registry = test_surface_context_registry,
        .mode_registry = .{ .default_mode_id = "surface" },
        .acp_runner = .{ .run_fn = unexpectedAcpRunForTest },
        .tool_set = .{
            .registry = .{ .tools = &.{} },
            .order = &.{},
            .read_only_tool_names = &.{},
        },
    };
}

fn stubLoadStartupState(
    alloc: Allocator,
    _: oauth_transport.Provider,
    _: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !app_lifecycle.StartupState {
    var state = app_lifecycle.StartupState{ .agent_step_limit = default_agent_step_limit };
    errdefer state.deinit(alloc);
    state.workspace_root = try alloc.dupe(u8, "/tmp/fx");
    state.selected_model = try alloc.dupe(u8, default_model);
    state.credential = .{
        .token = try alloc.dupe(u8, "test-key"),
        .source = .openai_api_key,
    };
    return state;
}

fn stubLoadCatalogStartupState(
    alloc: Allocator,
    secret_store: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !app_lifecycle.StartupState {
    return stubLoadStartupState(alloc, oauth_transport.unavailable_provider, secret_store, default_model, default_agent_step_limit);
}

fn stubLoadStartupStatus(
    alloc: Allocator,
    _: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
) !app_lifecycle.StartupStatus {
    const workspace_root = try alloc.dupe(u8, "/tmp/fx");
    errdefer alloc.free(workspace_root);
    const selected_model = try alloc.dupe(u8, default_model);
    errdefer alloc.free(selected_model);
    return .{
        .workspace_root = workspace_root,
        .selected_model = selected_model,
        .owned_selected_model = selected_model,
        .permission_mode = config_runtime.default_permission_mode,
        .agent_step_limit = default_agent_step_limit,
    };
}

fn failingStartupState(
    _: Allocator,
    _: oauth_transport.Provider,
    _: host.SecretStore,
    _: []const u8,
    _: usize,
) !app_lifecycle.StartupState {
    return error.StartupShouldNotRun;
}

const ModelFetchProbe = struct {
    const Outcome = enum {
        success,
        failure,
        cancelled,
    };

    called: bool = false,
    outcome: Outcome = .success,

    fn provider(self: *ModelFetchProbe) gateway_provider.CliModelCatalogProvider {
        return .{
            .context = self,
            .fetch_fn = fetch,
        };
    }

    fn failure(
        input: gateway_provider.CliModelCatalogInput,
        category: model_catalog.FailureCategory,
    ) gateway_provider.CliModelCatalogResult {
        return .{ .failure = .{
            .access = .init(input.access),
            .failure = .{ .category = category },
        } };
    }

    fn fetch(
        raw: ?*anyopaque,
        alloc: Allocator,
        input: gateway_provider.CliModelCatalogInput,
    ) gateway_provider.CliModelCatalogResult {
        const self: *ModelFetchProbe = @ptrCast(@alignCast(raw.?));
        self.called = true;
        if (!std.mem.eql(u8, input.access.authorizationCredential() orelse "", "test-key") or
            input.access.credentialSource() != .openai_api_key or
            !std.mem.eql(u8, input.endpoint, "/v1/models") or
            input.cancel_flag != null)
        {
            return failure(input, .runtime);
        }

        switch (self.outcome) {
            .failure => return failure(input, .runtime),
            .cancelled => return failure(input, .cancellation),
            .success => {},
        }

        var ids: std.ArrayList([]u8) = .empty;
        const id = alloc.dupe(u8, "private/blue-hornbill") catch {
            return failure(input, .resource_exhausted);
        };
        ids.append(alloc, id) catch {
            alloc.free(id);
            return failure(input, .resource_exhausted);
        };
        return .{ .loaded = .{
            .ids = ids,
            .provenance = .{ .access = .init(input.access) },
        } };
    }
};

const ChatUrlProbe = struct {
    called: bool = false,

    fn provider(self: *ChatUrlProbe) gateway_provider.ChatUrlProvider {
        return .{
            .context = self,
            .resolve_fn = resolve,
        };
    }

    fn resolve(raw: ?*anyopaque, fallback: []const u8) []const u8 {
        const self: *ChatUrlProbe = @ptrCast(@alignCast(raw.?));
        self.called = std.mem.eql(u8, fallback, "https://example.test/chat");
        return "http://127.0.0.1:43123/chat";
    }
};
