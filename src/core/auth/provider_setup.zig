const std = @import("std");
const builtin = @import("builtin");
const chatgpt_oauth = @import("chatgpt_oauth.zig");
const chatgpt_session = @import("chatgpt_session.zig");
const grok_session = @import("grok_session.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;
const max_source_auth_bytes: usize = 64 * 1024;
const grok_issuer = "https://auth.x.ai";
const grok_client_id = "b1a00492-073a-47ea-816f-4c329264a828";
const grok_scope = grok_issuer ++ "::" ++ grok_client_id;

pub const Source = enum {
    codex_cli,
    grok_build,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .codex_cli => "Codex CLI",
            .grok_build => "Grok Build",
        };
    }

    pub fn jsonName(self: Source) []const u8 {
        return switch (self) {
            .codex_cli => "codex_cli",
            .grok_build => "grok_build",
        };
    }
};

pub const Disposition = enum {
    imported,
    already_configured,
    not_found,
    incompatible,
    invalid,
    unavailable,

    pub fn jsonName(self: Disposition) []const u8 {
        return @tagName(self);
    }
};

pub const ProviderResult = struct {
    source: Source,
    disposition: Disposition,
};

pub const Report = struct {
    codex: ProviderResult,
    grok: ProviderResult,

    pub fn writeText(self: Report, writer: *std.Io.Writer) !void {
        try writer.writeAll("Provider setup finished.\n");
        try writeProviderText(writer, "Codex", self.codex);
        try writeProviderText(writer, "Grok", self.grok);
    }

    pub fn writeJson(self: Report, writer: *std.Io.Writer) !void {
        try self.writeJsonValue(writer);
        try writer.writeByte('\n');
    }

    pub fn writeJsonValue(self: Report, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"codex\":");
        try writeProviderJson(writer, self.codex);
        try writer.writeAll(",\"grok\":");
        try writeProviderJson(writer, self.grok);
        try writer.writeByte('}');
    }
};

fn writeProviderText(writer: *std.Io.Writer, provider: []const u8, result: ProviderResult) !void {
    const detail = switch (result.disposition) {
        .imported => "imported",
        .already_configured => "kept the existing fx login",
        .not_found => "no reusable login found",
        .incompatible => "login is not compatible with fx",
        .invalid => "credential file is invalid or insecure",
        .unavailable => "credential file could not be read",
    };
    try writer.print("{s}: {s} from {s}.\n", .{ provider, detail, result.source.label() });
}

fn writeProviderJson(writer: *std.Io.Writer, result: ProviderResult) !void {
    try writer.writeAll("{\"source\":");
    try std.json.Stringify.value(result.source.jsonName(), .{}, writer);
    try writer.writeAll(",\"status\":");
    try std.json.Stringify.value(result.disposition.jsonName(), .{}, writer);
    try writer.writeByte('}');
}

pub fn run(alloc: Allocator) !Report {
    if (comptime host_target.is_wasm) return error.ProviderSetupUnavailable;
    return .{
        .codex = try importCodex(alloc),
        .grok = try importGrok(alloc),
    };
}

fn importCodex(alloc: Allocator) !ProviderResult {
    const result = ProviderResult{ .source = .codex_cli, .disposition = .already_configured };
    const already_configured = chatgpt_oauth.sourceExists(alloc) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .source = .codex_cli, .disposition = .unavailable },
    };
    if (already_configured) return result;

    const bytes = readSourceAuth(alloc, "CODEX_HOME", ".codex") catch |err| {
        return .{ .source = .codex_cli, .disposition = sourceReadDisposition(err) };
    } orelse return .{ .source = .codex_cli, .disposition = .not_found };
    defer secret.zeroAndFree(alloc, bytes);

    var session = parseCodexCliSession(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.IncompatibleProviderCredential => return .{ .source = .codex_cli, .disposition = .incompatible },
        else => return .{ .source = .codex_cli, .disposition = .invalid },
    };
    defer session.deinit(alloc);
    const saved = chatgpt_session.saveImportedSessionIfAbsent(alloc, session) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .source = .codex_cli, .disposition = .unavailable },
    };
    return .{ .source = .codex_cli, .disposition = switch (saved) {
        .saved => .imported,
        .already_configured => .already_configured,
        .existing_invalid => .invalid,
    } };
}

fn importGrok(alloc: Allocator) !ProviderResult {
    const result = ProviderResult{ .source = .grok_build, .disposition = .already_configured };
    const already_configured = grokSourceExists(alloc) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .source = .grok_build, .disposition = .unavailable },
    };
    if (already_configured) return result;

    const bytes = readSourceAuth(alloc, "GROK_HOME", ".grok") catch |err| {
        return .{ .source = .grok_build, .disposition = sourceReadDisposition(err) };
    } orelse return .{ .source = .grok_build, .disposition = .not_found };
    defer secret.zeroAndFree(alloc, bytes);

    var session = parseGrokBuildSession(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.IncompatibleProviderCredential => return .{ .source = .grok_build, .disposition = .incompatible },
        else => return .{ .source = .grok_build, .disposition = .invalid },
    };
    defer session.deinit(alloc);
    const saved = grok_session.saveImportedSessionIfAbsent(alloc, session) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .source = .grok_build, .disposition = .unavailable },
    };
    return .{ .source = .grok_build, .disposition = switch (saved) {
        .saved => .imported,
        .already_configured => .already_configured,
        .existing_invalid => .invalid,
    } };
}

fn grokSourceExists(alloc: Allocator) !bool {
    var session = (try grok_session.load(alloc)) orelse return false;
    session.deinit(alloc);
    return true;
}

fn sourceReadDisposition(err: anyerror) Disposition {
    return switch (err) {
        error.FileNotFound => .not_found,
        error.InvalidSourceCredentialPath,
        error.InsecureSourceCredential,
        error.StreamTooLong,
        => .invalid,
        else => .unavailable,
    };
}

fn readSourceAuth(
    alloc: Allocator,
    home_env: []const u8,
    fallback_dir_name: []const u8,
) !?[]u8 {
    var source_dir = if (io_mod.getenv(home_env)) |configured| configured: {
        if (!std.fs.path.isAbsolute(configured)) return error.InvalidSourceCredentialPath;
        break :configured try io_mod.openDirAbsoluteNoFollow(configured, .{});
    } else fallback: {
        const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
        var home_dir = try io_mod.openDirAbsoluteNoFollow(home, .{});
        defer home_dir.close(io_mod.getIo());
        break :fallback home_dir.openDir(io_mod.getIo(), fallback_dir_name, .{
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
    };
    defer source_dir.close(io_mod.getIo());

    var file = source_dir.openFile(io_mod.getIo(), "auth.json", .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or !io_mod.permissionsPrivateFile(stat.permissions)) {
        return error.InsecureSourceCredential;
    }
    return try io_mod.readFileToEnd(alloc, &file, max_source_auth_bytes);
}

pub fn parseCodexCliSession(alloc: Allocator, bytes: []const u8) !chatgpt_session.Session {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidProviderCredential;
    const root = parsed.value.object;
    if (root.get("auth_mode")) |mode| {
        if (mode != .string or !std.ascii.eqlIgnoreCase(mode.string, "chatgpt")) {
            return error.IncompatibleProviderCredential;
        }
    }
    const tokens_value = root.get("tokens") orelse return error.InvalidProviderCredential;
    if (tokens_value != .object) return error.InvalidProviderCredential;
    const tokens = tokens_value.object;
    const access_token = try dupeRequiredString(alloc, tokens, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeRequiredString(alloc, tokens, "refresh_token");
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const account_id = try chatgpt_oauth.extractAccountId(alloc, access_token);
    errdefer alloc.free(account_id);
    if (!validHeaderValue(account_id)) return error.InvalidProviderCredential;
    if (tokens.get("account_id")) |stored| {
        if (stored != .string or !std.mem.eql(u8, stored.string, account_id)) {
            return error.InvalidProviderCredential;
        }
    }
    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = try chatgpt_oauth.accessTokenExpiresAtMs(alloc, access_token),
        .account_id = account_id,
    };
}

pub fn parseGrokBuildSession(alloc: Allocator, bytes: []const u8) !grok_session.Session {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidProviderCredential;
    const entry = findGrokBuildEntry(parsed.value.object) orelse
        return error.IncompatibleProviderCredential;
    const access_token = try dupeRequiredString(alloc, entry, "key");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeRequiredString(alloc, entry, "refresh_token");
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const account_id = try dupeRequiredString(alloc, entry, "user_id");
    errdefer alloc.free(account_id);
    if (!grok_session.validAccountId(account_id)) return error.InvalidProviderCredential;
    const principal_type = try dupeOptionalString(alloc, entry, "principal_type");
    errdefer if (principal_type) |value| alloc.free(value);
    const principal_id = try dupeOptionalString(alloc, entry, "principal_id");
    errdefer if (principal_id) |value| alloc.free(value);
    if ((principal_type == null) != (principal_id == null)) return error.InvalidProviderCredential;
    if (principal_type) |value| if (!validHeaderValue(value)) return error.InvalidProviderCredential;
    if (principal_id) |value| if (!validHeaderValue(value)) return error.InvalidProviderCredential;
    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = try jwtExpiryMs(alloc, access_token),
        .account_id = account_id,
        .principal_type = principal_type,
        .principal_id = principal_id,
    };
}

fn findGrokBuildEntry(root: std.json.ObjectMap) ?std.json.ObjectMap {
    if (root.get(grok_scope)) |value| {
        if (compatibleGrokEntry(value)) |entry| return entry;
    }
    var iterator = root.iterator();
    while (iterator.next()) |candidate| {
        if (compatibleGrokEntry(candidate.value_ptr.*)) |entry| return entry;
    }
    return null;
}

fn compatibleGrokEntry(value: std.json.Value) ?std.json.ObjectMap {
    if (value != .object) return null;
    const object = value.object;
    const mode = object.get("auth_mode") orelse return null;
    if (mode != .string or !std.ascii.eqlIgnoreCase(mode.string, "oidc")) return null;
    const issuer = object.get("oidc_issuer") orelse return null;
    if (issuer != .string or !std.mem.eql(u8, issuer.string, grok_issuer)) return null;
    const client = object.get("oidc_client_id") orelse return null;
    if (client != .string or !std.mem.eql(u8, client.string, grok_client_id)) return null;
    return object;
}

fn jwtExpiryMs(alloc: Allocator, token: []const u8) !i64 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return error.InvalidProviderCredential;
    const payload = parts.next() orelse return error.InvalidProviderCredential;
    _ = parts.next() orelse return error.InvalidProviderCredential;
    if (parts.next() != null) return error.InvalidProviderCredential;
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload) catch
        return error.InvalidProviderCredential;
    const decoded = try alloc.alloc(u8, decoded_len);
    defer alloc.free(decoded);
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload) catch
        return error.InvalidProviderCredential;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, decoded, .{}) catch
        return error.InvalidProviderCredential;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidProviderCredential;
    const exp = parsed.value.object.get("exp") orelse return error.InvalidProviderCredential;
    if (exp != .integer or exp.integer <= 0) return error.InvalidProviderCredential;
    return std.math.mul(i64, exp.integer, std.time.ms_per_s) catch
        return error.InvalidProviderCredential;
}

fn dupeRequiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidProviderCredential;
    if (value != .string or value.string.len == 0) return error.InvalidProviderCredential;
    return alloc.dupe(u8, value.string);
}

fn dupeOptionalString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string or value.string.len == 0) return error.InvalidProviderCredential;
    return try alloc.dupe(u8, value.string);
}

fn validHeaderValue(value: []const u8) bool {
    if (value.len == 0 or value.len > 1024) return false;
    for (value) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

pub const Outcome = union(enum) {
    report: Report,
    failed: anyerror,
};

pub const Poll = union(enum) {
    idle,
    running,
    completed: Outcome,
};

const Operation = struct {
    context: ?*anyopaque = null,
    run_fn: *const fn (?*anyopaque, Allocator) anyerror!Report = runOperation,

    fn execute(self: Operation, alloc: Allocator) Outcome {
        return .{ .report = self.run_fn(self.context, alloc) catch |err| return .{ .failed = err } };
    }
};

fn runOperation(_: ?*anyopaque, alloc: Allocator) !Report {
    return run(alloc);
}

/// Imports provider credentials on a worker so TUI and ACP event loops never
/// wait on filesystem or durable-write locks.
pub const Runtime = struct {
    const Self = @This();

    alloc: Allocator,
    operation: Operation = .{},
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    running: bool = false,
    completion: ?Outcome = null,

    pub fn init(alloc: Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        const thread = self.detachThread();
        if (thread) |handle| handle.join();
        self.mutex.lockUncancelable(io_mod.getIo());
        self.running = false;
        self.completion = null;
        self.mutex.unlock(io_mod.getIo());
    }

    pub fn start(self: *Self) !bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.running or self.completion != null or self.thread != null) {
            self.mutex.unlock(io_mod.getIo());
            return false;
        }
        self.running = true;
        if (comptime builtin.single_threaded) {
            self.mutex.unlock(io_mod.getIo());
            self.threadMain();
            return true;
        }
        const thread = std.Thread.spawn(.{}, threadMain, .{self}) catch |err| {
            self.running = false;
            self.mutex.unlock(io_mod.getIo());
            return err;
        };
        self.thread = thread;
        self.mutex.unlock(io_mod.getIo());
        return true;
    }

    pub fn isRunning(self: *Self) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.running;
    }

    pub fn takeCompletion(self: *Self) ?Outcome {
        return switch (self.poll()) {
            .completed => |outcome| outcome,
            .idle, .running => null,
        };
    }

    /// Returns one coherent runtime state. In particular, completion cannot
    /// race a separate running check and briefly appear as idle.
    pub fn poll(self: *Self) Poll {
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.completion) |completion| {
            self.completion = null;
            const thread = self.thread;
            self.thread = null;
            self.mutex.unlock(io_mod.getIo());
            if (thread) |handle| handle.join();
            return .{ .completed = completion };
        }
        if (self.running) {
            self.mutex.unlock(io_mod.getIo());
            return .running;
        }
        const thread = self.thread;
        if (thread != null) self.thread = null;
        self.mutex.unlock(io_mod.getIo());
        if (thread) |handle| handle.join();
        return .idle;
    }

    fn threadMain(self: *Self) void {
        const completion = self.operation.execute(self.alloc);
        self.mutex.lockUncancelable(io_mod.getIo());
        self.completion = completion;
        self.running = false;
        self.mutex.unlock(io_mod.getIo());
    }

    fn detachThread(self: *Self) ?std.Thread {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const thread = self.thread;
        self.thread = null;
        return thread;
    }
};

fn testJwt(alloc: Allocator, payload: []const u8) ![]u8 {
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(payload.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, payload);
    return std.fmt.allocPrint(alloc, "header.{s}.signature", .{encoded});
}

test "Codex CLI parser validates the account bound to the access token" {
    const alloc = std.testing.allocator;
    const token = try testJwt(alloc, "{\"exp\":4102444800,\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_setup\"}}");
    defer alloc.free(token);
    const text = try std.fmt.allocPrint(
        alloc,
        "{{\"auth_mode\":\"chatgpt\",\"tokens\":{{\"access_token\":\"{s}\",\"refresh_token\":\"refresh\",\"account_id\":\"acct_setup\"}}}}",
        .{token},
    );
    defer secret.zeroAndFree(alloc, text);
    var session = try parseCodexCliSession(alloc, text);
    defer session.deinit(alloc);
    try std.testing.expectEqualStrings("acct_setup", session.account_id);
    try std.testing.expectEqual(@as(i64, 4_102_444_800_000), session.expires_at_ms);
}

test "Grok Build parser preserves team refresh identity" {
    const alloc = std.testing.allocator;
    const token = try testJwt(alloc, "{\"exp\":4102444800,\"sub\":\"user_setup\",\"principal_type\":\"Team\",\"principal_id\":\"team_setup\"}");
    defer alloc.free(token);
    const text = try std.fmt.allocPrint(
        alloc,
        "{{\"{s}\":{{\"key\":\"{s}\",\"auth_mode\":\"oidc\",\"user_id\":\"team_setup\",\"refresh_token\":\"refresh\",\"oidc_issuer\":\"{s}\",\"oidc_client_id\":\"{s}\",\"principal_type\":\"Team\",\"principal_id\":\"team_setup\"}}}}",
        .{ grok_scope, token, grok_issuer, grok_client_id },
    );
    defer secret.zeroAndFree(alloc, text);
    var session = try parseGrokBuildSession(alloc, text);
    defer session.deinit(alloc);
    try std.testing.expectEqualStrings("team_setup", session.account_id);
    try std.testing.expectEqualStrings("Team", session.principal_type.?);
    try std.testing.expectEqualStrings("team_setup", session.principal_id.?);
}

test "Grok Build parser rejects API keys and other OAuth clients" {
    const api_key =
        \\{"xai::api_key":{"key":"xai-test","auth_mode":"api_key","user_id":"user"}}
    ;
    try std.testing.expectError(
        error.IncompatibleProviderCredential,
        parseGrokBuildSession(std.testing.allocator, api_key),
    );
}

test "provider setup JSON never contains credentials" {
    const report = Report{
        .codex = .{ .source = .codex_cli, .disposition = .imported },
        .grok = .{ .source = .grok_build, .disposition = .not_found },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try report.writeJson(&out.writer);
    try std.testing.expectEqualStrings(
        "{\"codex\":{\"source\":\"codex_cli\",\"status\":\"imported\"},\"grok\":{\"source\":\"grok_build\",\"status\":\"not_found\"}}\n",
        out.written(),
    );
}

fn testImmediateSetupOperation(_: ?*anyopaque, _: Allocator) !Report {
    return .{
        .codex = .{ .source = .codex_cli, .disposition = .not_found },
        .grok = .{ .source = .grok_build, .disposition = .not_found },
    };
}

test "provider setup poll does not expose the completion transition as idle" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.operation = .{ .run_fn = testImmediateSetupOperation };
    try std.testing.expect(try runtime.start());

    var attempts: usize = 0;
    while (attempts < 10_000) : (attempts += 1) {
        switch (runtime.poll()) {
            .running => std.Thread.yield() catch {},
            .completed => |outcome| {
                switch (outcome) {
                    .report => {},
                    .failed => |err| return err,
                }
                try std.testing.expectEqual(Poll.idle, runtime.poll());
                return;
            },
            .idle => return error.UnexpectedIdleSetupState,
        }
    }
    return error.SetupDidNotComplete;
}
