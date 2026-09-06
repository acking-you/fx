//! One native engine owner. Its private ACP control channel lives as long as
//! the engine, independently of any SDK or external ACP attachment.
const std = @import("std");
const builtin = @import("builtin");
const acp = @import("../../acp/server.zig");
const jsonrpc = @import("../../acp/jsonrpc.zig");
const io_mod = @import("../shared/io.zig");
const environment_scope = @import("../shared/environment_scope.zig");
const byte_queue = @import("byte_queue.zig");
const providers = @import("../../builtins/providers.zig");
const responses = @import("../../builtins/responses.zig");
const context = @import("../../builtins/context.zig");
const modes = @import("../../builtins/modes.zig");
const host = @import("../hosts/host.zig");
const model_provider = @import("../config/model_provider.zig");
const host_tools = @import("host_tools.zig");

const queue_limit = 8 * 1024 * 1024;
const max_config_bytes = 1024 * 1024;

pub const EnvironmentEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const Config = struct {
    home: []const u8,
    workspace_root: []const u8,
    model: ?[]const u8 = null,
    provider: model_provider.ProviderId = .gateway,
    api_key: ?[]const u8 = null,
    responses_base_url: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    native_tools: bool = false,
    inherit_provider_environment: bool = false,
    environment: []const EnvironmentEntry = &.{},
    tools: []const host_tools.Spec = &.{},
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(Config),
    environment: *environment_scope.Environment,
    tools: host_tools.Registry,
    input: byte_queue.Queue,
    output: byte_queue.Queue,
    thread: ?std.Thread = null,
    exit_code: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),

    /// Returns an owned runtime. `destroy` joins its worker before freeing it.
    /// The allocator must be thread-safe and remain valid until destruction.
    /// Host callers must finish concurrent read/write calls before destruction.
    pub fn create(allocator: std.mem.Allocator, bytes: []const u8) !*Runtime {
        if (bytes.len == 0 or bytes.len > max_config_bytes) return error.InvalidConfigSize;
        ensureIo();
        const parsed = try std.json.parseFromSlice(Config, allocator, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        const config = parsed.value;
        if (!validPath(config.home) or !validPath(config.workspace_root)) return error.InvalidPath;
        if (config.instructions) |value| if (value.len > 256 * 1024) return error.InstructionsTooLong;
        if (config.model) |value| if (value.len == 0 or value.len > 1024) return error.InvalidModel;
        if (config.environment.len > 256) return error.TooManyEnvironmentEntries;
        var environment = try io_mod.cloneEnvironMap(allocator);
        errdefer environment.deinit();
        if (!config.inherit_provider_environment) {
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(allocator);
            var iterator = environment.iterator();
            while (iterator.next()) |entry| {
                const name = entry.key_ptr.*;
                if (std.mem.startsWith(u8, name, "FX_") or std.mem.startsWith(u8, name, "OPENAI_") or
                    std.mem.startsWith(u8, name, "GROK_") or std.mem.startsWith(u8, name, "CODEX_"))
                    try names.append(allocator, name);
            }
            for (names.items) |name| {
                _ = environment.swapRemove(name);
            }
        }
        for (config.environment) |entry| {
            if (entry.key.len == 0 or entry.key.len > 256 or entry.value.len > 64 * 1024 or
                std.mem.findScalar(u8, entry.key, '=') != null or
                std.mem.findScalar(u8, entry.key, 0) != null or std.mem.findScalar(u8, entry.value, 0) != null)
                return error.InvalidEnvironmentEntry;
            try environment.put(entry.key, entry.value);
        }
        try environment.put("HOME", config.home);
        try environment.put("FX_EMBEDDED_RUNTIME", "1");
        if (config.api_key) |key| {
            if (key.len == 0 or key.len > 64 * 1024) return error.InvalidApiKey;
            try environment.put("OPENAI_API_KEY", key);
        }
        if (config.responses_base_url) |url| {
            if (url.len == 0 or url.len > 16 * 1024) return error.InvalidBaseUrl;
            try environment.put("FX_RESPONSES_BASE_URL", url);
        }
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        var tools = try host_tools.Registry.init(allocator, config.tools, config.native_tools);
        errdefer tools.deinit();
        const owned_environment = try environment_scope.Environment.create(allocator, environment);
        // Ownership of the map transfers here. On spawn failure release the
        // wrapper without running the map's earlier error defer twice.
        self.* = .{
            .allocator = allocator,
            .parsed = parsed,
            .environment = owned_environment,
            .tools = tools,
            .input = byte_queue.Queue.init(allocator, queue_limit),
            .output = byte_queue.Queue.init(allocator, queue_limit),
        };
        self.thread = io_mod.spawn(.{}, run, .{self}) catch |err| {
            allocator.destroy(owned_environment);
            return err;
        };
        return self;
    }

    pub fn close(self: *Runtime) void {
        self.stopping.store(true, .release);
        self.input.abort();
    }

    pub fn destroy(self: *Runtime) void {
        const allocator = self.allocator;
        self.close();
        if (self.thread) |thread| thread.join();
        self.input.deinit();
        self.output.deinit();
        self.environment.release();
        self.tools.deinit();
        self.parsed.deinit();
        allocator.destroy(self);
    }

    fn run(self: *Runtime) void {
        const allocator = self.allocator;
        const guard = environment_scope.enter(self.environment);
        defer guard.leave();
        defer self.output.close();
        const config = self.parsed.value;
        acp.runWithTransport(allocator, .{
            .default_model = responses.default_model,
            .default_agent_step_limit = 64,
            .gateway_retry_count = 0,
            .gateway_chat_url = responses.default_chat_url,
            .gateway_models_path = responses.models_path,
            .gateway_provider = responses.provider,
            .provider_set = providers.native,
            .secret_store = host.unavailable_secret_store,
            .prompt_policy = .{ .system_prompt = config.instructions orelse context.gateway_system_prompt },
            .ignored_list_entries = &.{ ".git", ".zig-cache", "target", "node_modules" },
            .max_list_entries = 100,
            .max_read_file_bytes = 512 * 1024,
            .max_read_file_lines = 2000,
            .max_read_file_line_len = 2000,
            .max_command_output_bytes = 64 * 1024,
            .max_tool_result_bytes = 64 * 1024,
            .max_history_turns = 100,
            .context_registry = .{ .default_provider = context.provider },
            .mode_registry = modes.registry,
            .provider_override = config.provider,
            .model_override = config.model,
            .home_override = config.home,
            .workspace_root_override = config.workspace_root,
            .allow_native_tools = config.native_tools,
            .tool_set_override = self.tools.value,
            .stop_flag = &self.stopping,
        }, jsonrpc.Reader.initCallback(self, readInput), jsonrpc.Writer.initCallback(self, writeOutput)) catch {
            self.exit_code.store(1, .release);
        };
    }

    fn readInput(raw: ?*anyopaque, buffer: []u8) usize {
        const self: *Runtime = @ptrCast(@alignCast(raw.?));
        return self.input.read(buffer) catch 0;
    }

    fn writeOutput(raw: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *Runtime = @ptrCast(@alignCast(raw.?));
        self.output.write(bytes) catch |err| {
            self.exit_code.store(1, .release);
            self.input.abort();
            self.output.close();
            return err;
        };
    }
};

fn validPath(path: []const u8) bool {
    return path.len > 0 and path.len <= 16 * 1024 and std.fs.path.isAbsolute(path) and
        std.mem.findScalar(u8, path, 0) == null;
}

var threaded_io: ?std.Io.Threaded = null;
var io_state: std.atomic.Value(u8) = .init(0);

fn ensureIo() void {
    if (io_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        // This process-wide driver outlives every instance allocator.
        threaded_io = std.Io.Threaded.init(std.heap.c_allocator, .{});
        io_mod.setIo(threaded_io.?.io());
        io_mod.setEmbeddedIo(environment_scope.wrapIo(io_mod.getIo()));
        if (comptime builtin.os.tag == .windows) {
            io_mod.setEnvironBlock(.global);
        } else {
            io_mod.setRawEnviron(@ptrCast(std.c.environ));
        }
        io_state.store(2, .release);
        return;
    }
    while (io_state.load(.acquire) != 2) std.atomic.spinLoopHint();
}

test {
    _ = byte_queue;
    _ = environment_scope;
    _ = host_tools;
}
