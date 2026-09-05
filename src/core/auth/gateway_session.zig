const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("secret.zig");
const provider_route = @import("../gateway/provider_route.zig");
const session_presence = @import("session_presence.zig");

const Allocator = std.mem.Allocator;
const schema_version: i64 = 1;
const max_auth_file_bytes: usize = 64 * 1024;
const max_base_url_bytes: usize = 2048;
const max_api_key_bytes: usize = 8192;
const mutation_lock_file_name = "gateway-auth.lock";
const mutation_lock_deadline_ms: u64 = 2000;
const overlay_alloc = std.heap.c_allocator;

const auth_file_name = profile_paths.gateway_auth_file_name;

var overlay_mutex: std.Io.Mutex = .init;
var process_binding: ?Session = null;

pub const Session = struct {
    base_url: []u8,
    api_key: []u8,

    pub fn deinit(self: *Session, alloc: Allocator) void {
        alloc.free(self.base_url);
        secret.zeroAndFree(alloc, self.api_key);
        self.* = undefined;
    }
};

pub const DeleteOutcome = enum {
    deleted,
    missing,
    deleted_not_durable,
};

pub const ConfigureArgs = struct {
    base_url: []const u8,
    api_key: []const u8,
};

pub fn validate(base_url: []const u8, api_key: []const u8) !void {
    if (!validBaseUrl(base_url) or !validApiKey(api_key)) return error.InvalidGatewayAuthSession;
}

pub fn presence() host.SecretStorePresence {
    if (hasProcessBinding()) return .present;
    return session_presence.profileFile(auth_file_name, max_auth_file_bytes);
}

pub fn hasStoredBinding() bool {
    if (hasProcessBinding()) return true;
    return presence() == .present;
}

pub fn hasProcessBinding() bool {
    overlay_mutex.lockUncancelable(io_mod.getIo());
    defer overlay_mutex.unlock(io_mod.getIo());
    return process_binding != null;
}

pub fn copyProcessBaseUrlAlloc(alloc: Allocator) !?[]u8 {
    overlay_mutex.lockUncancelable(io_mod.getIo());
    defer overlay_mutex.unlock(io_mod.getIo());
    const binding = process_binding orelse return null;
    return try alloc.dupe(u8, binding.base_url);
}

pub fn copyProcessApiKeyAlloc(alloc: Allocator) !?[]u8 {
    overlay_mutex.lockUncancelable(io_mod.getIo());
    defer overlay_mutex.unlock(io_mod.getIo());
    const binding = process_binding orelse return null;
    return try alloc.dupe(u8, binding.api_key);
}

pub fn copyProcessBinding(alloc: Allocator) !?Session {
    overlay_mutex.lockUncancelable(io_mod.getIo());
    defer overlay_mutex.unlock(io_mod.getIo());
    const binding = process_binding orelse return null;
    return try cloneSession(alloc, binding);
}

pub fn copyStoredBaseUrlAlloc(alloc: Allocator) !?[]u8 {
    var session = (try copyStoredBinding(alloc)) orelse return null;
    defer session.deinit(alloc);
    return try alloc.dupe(u8, session.base_url);
}

pub fn copyStoredApiKeyAlloc(alloc: Allocator) !?[]u8 {
    var session = (try copyStoredBinding(alloc)) orelse return null;
    defer session.deinit(alloc);
    return try alloc.dupe(u8, session.api_key);
}

pub fn copyStoredBinding(alloc: Allocator) !?Session {
    overlay_mutex.lockUncancelable(io_mod.getIo());
    defer overlay_mutex.unlock(io_mod.getIo());
    if (process_binding) |binding| return try cloneSession(alloc, binding);
    var session = (try load(alloc)) orelse {
        if (session_presence.profileFile(auth_file_name, max_auth_file_bytes) == .present)
            return error.InvalidGatewayAuthSession;
        return null;
    };
    errdefer session.deinit(alloc);
    // Pin both halves from the same disk read. Temporary provider switches and
    // later endpoint resolution reuse this snapshot, even if another process
    // replaces the profile file in the meantime.
    process_binding = try cloneSession(overlay_alloc, session);
    return session;
}

pub fn setProcessBinding(session: Session) !void {
    const owned = try cloneSession(overlay_alloc, session);
    overlay_mutex.lockUncancelable(io_mod.getIo());
    defer overlay_mutex.unlock(io_mod.getIo());
    replaceProcessBindingLocked(owned);
}

pub fn clearProcessBinding() void {
    overlay_mutex.lockUncancelable(io_mod.getIo());
    defer overlay_mutex.unlock(io_mod.getIo());
    replaceProcessBindingLocked(null);
}

pub fn saveAndActivate(alloc: Allocator, base_url: []const u8, api_key: []const u8) !void {
    var session = try ownedSession(alloc, base_url, api_key);
    defer session.deinit(alloc);
    // Allocate the next process snapshot before committing the disk binding.
    // A failed save must leave the running route untouched.
    var owned = try cloneSession(overlay_alloc, session);
    errdefer owned.deinit(overlay_alloc);
    try saveNewSession(alloc, session);
    overlay_mutex.lockUncancelable(io_mod.getIo());
    defer overlay_mutex.unlock(io_mod.getIo());
    replaceProcessBindingLocked(owned);
}

pub fn deleteStoredSession() !DeleteOutcome {
    if (comptime host_target.is_wasm) return error.GatewayAuthUnavailable;
    var mutation = (try beginExistingMutation()) orelse {
        clearProcessBinding();
        return .missing;
    };
    defer mutation.deinit();
    const outcome = try mutation.delete();
    clearProcessBinding();
    return outcome;
}

pub fn parseConfigureArgs(text: []const u8) ?ConfigureArgs {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    const split = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return null;
    const base_url = std.mem.trim(u8, trimmed[0..split], " \t");
    const api_key = std.mem.trim(u8, trimmed[split + 1 ..], " \t\r\n");
    if (!validBaseUrl(base_url) or !validApiKey(api_key)) return null;
    return .{ .base_url = base_url, .api_key = api_key };
}

pub const Mutation = struct {
    fx_dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,

    pub fn deinit(self: *Mutation) void {
        self.lock.release();
        self.fx_dir.close();
        self.* = undefined;
    }

    pub fn load(self: *Mutation, alloc: Allocator) !?Session {
        return loadFromDir(alloc, &self.fx_dir.dir, true);
    }

    pub fn save(self: *Mutation, alloc: Allocator, session: Session) !void {
        const text = try stringify(alloc, session);
        defer secret.zeroAndFree(alloc, text);
        try io_mod.durableReplaceVerified(alloc, &self.fx_dir, auth_file_name, text);
    }

    pub fn hasAuthFile(self: *Mutation) !bool {
        var file = self.fx_dir.dir.openFile(io_mod.getIo(), auth_file_name, .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        file.close(io_mod.getIo());
        return true;
    }

    pub fn delete(self: *Mutation) !DeleteOutcome {
        self.fx_dir.dir.deleteFile(io_mod.getIo(), auth_file_name) catch |err| switch (err) {
            error.FileNotFound => return .missing,
            else => return err,
        };
        const durable: io_mod.DurableOps = .{};
        durable.sync_dir(durable.ctx, self.fx_dir.dir) catch return .deleted_not_durable;
        return .deleted;
    }
};

pub fn load(alloc: Allocator) !?Session {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.getenv("HOME") orelse return null;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return null;
        debug_trace.logf("auth", "Gateway session load failed step=open_home err={s}", .{@errorName(err)});
        return err;
    };
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| {
        if (err != error.FileNotFound) {
            debug_trace.logf("auth", "Gateway session load failed step=open_profile err={s}", .{@errorName(err)});
            return err;
        }
        return null;
    };
    defer fx_dir.close(io_mod.getIo());
    return loadFromDir(alloc, &fx_dir, false);
}

fn loadFromDir(alloc: Allocator, fx_dir: *std.Io.Dir, _: bool) !?Session {
    var file = fx_dir.openFile(io_mod.getIo(), auth_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("auth", "Gateway session load failed step=open_file err={s}", .{@errorName(err)});
            return err;
        },
    };
    defer file.close(io_mod.getIo());

    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1 or !io_mod.permissionsPrivateFile(stat.permissions)) {
        debug_trace.logf("auth", "Gateway session load failed step=permissions err=InsecureAuthFile", .{});
        return error.InvalidGatewayAuthSession;
    }

    const bytes = try io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes);
    defer secret.zeroAndFree(alloc, bytes);
    return parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "Gateway session load failed step=parse err={s}", .{@errorName(err)});
            return null;
        },
    };
}

pub fn saveNewSession(alloc: Allocator, session: Session) !void {
    if (comptime host_target.is_wasm) return error.GatewayAuthUnavailable;
    try validate(session.base_url, session.api_key);
    var mutation = try beginMutation();
    defer mutation.deinit();
    try mutation.save(alloc, session);
}

pub fn beginExistingMutation() !?Mutation {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();

    const fx_dir = openExistingPrivateFxDir(&home_dir) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try lockMutation(fx_dir);
}

fn beginMutation() !Mutation {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();

    const fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name);
    return lockMutation(fx_dir);
}

fn lockMutation(open_fx_dir: io_mod.VerifiedDir) !Mutation {
    var fx_dir = open_fx_dir;
    errdefer fx_dir.close();
    var lock = try io_mod.acquireTimedAdvisoryLock(
        &fx_dir,
        mutation_lock_file_name,
        mutation_lock_deadline_ms,
    );
    errdefer lock.release();
    return .{ .fx_dir = fx_dir, .lock = lock };
}

fn openExistingPrivateFxDir(home_dir: *io_mod.VerifiedDir) !io_mod.VerifiedDir {
    var dir = try home_dir.dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    errdefer dir.close(io_mod.getIo());

    const initial_stat = try dir.stat(io_mod.getIo());
    if (initial_stat.kind != .directory) return error.DurablePathUnsafe;
    if (!io_mod.permissionsWritable(initial_stat.permissions)) return error.PrivateStatePermissionsUnsupported;
    io_mod.setDirPermissions(dir, io_mod.permissionsFromMode(0o700)) catch {
        return error.PrivateStatePermissionsUnsupported;
    };
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory or !io_mod.permissionsPrivateDir(stat.permissions)) {
        return error.PrivateStatePermissionsUnsupported;
    }
    return .{ .dir = dir };
}

pub fn parse(alloc: Allocator, bytes: []const u8) !Session {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGatewayAuthSession;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidGatewayAuthSession;
    if (version != .integer or version.integer != schema_version) return error.InvalidGatewayAuthSession;

    const base_url = try dupeRequiredString(alloc, object, "base_url");
    errdefer alloc.free(base_url);
    if (!validBaseUrl(base_url)) return error.InvalidGatewayAuthSession;
    const api_key = try dupeRequiredString(alloc, object, "api_key");
    errdefer secret.zeroAndFree(alloc, api_key);
    if (!validApiKey(api_key)) return error.InvalidGatewayAuthSession;
    return .{
        .base_url = base_url,
        .api_key = api_key,
    };
}

pub fn stringify(alloc: Allocator, session: Session) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"version\":1,\"base_url\":");
    try std.json.Stringify.value(session.base_url, .{}, &out.writer);
    try out.writer.writeAll(",\"api_key\":");
    try std.json.Stringify.value(session.api_key, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn replaceProcessBindingLocked(next: ?Session) void {
    if (process_binding) |*current| current.deinit(overlay_alloc);
    process_binding = next;
}

fn cloneSession(alloc: Allocator, session: Session) !Session {
    return ownedSession(alloc, session.base_url, session.api_key);
}

fn ownedSession(alloc: Allocator, base_url: []const u8, api_key: []const u8) !Session {
    const owned_url = try alloc.dupe(u8, base_url);
    errdefer alloc.free(owned_url);
    const owned_key = try alloc.dupe(u8, api_key);
    return .{
        .base_url = owned_url,
        .api_key = owned_key,
    };
}

fn dupeRequiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidGatewayAuthSession;
    if (value != .string or value.string.len == 0) return error.InvalidGatewayAuthSession;
    return alloc.dupe(u8, value.string);
}

fn validBaseUrl(value: []const u8) bool {
    if (value.len == 0 or value.len > max_base_url_bytes) return false;
    for (value) |byte| {
        if (std.ascii.isWhitespace(byte) or std.ascii.isControl(byte)) return false;
    }
    provider_route.validateBaseUrl(value) catch return false;
    return true;
}

fn validApiKey(value: []const u8) bool {
    if (value.len == 0 or value.len > max_api_key_bytes) return false;
    for (value) |byte| {
        if (std.ascii.isControl(byte)) return false;
    }
    return true;
}

pub fn resetProcessBindingForTests() void {
    overlay_mutex.lockUncancelable(io_mod.getIo());
    defer overlay_mutex.unlock(io_mod.getIo());
    replaceProcessBindingLocked(null);
}

test "Gateway auth session round trips without exposing the key to structure" {
    const alloc = std.testing.allocator;
    var session = Session{
        .base_url = try alloc.dupe(u8, "https://gateway.example.test/v1"),
        .api_key = try alloc.dupe(u8, "sk-test"),
    };
    defer session.deinit(alloc);

    const encoded = try stringify(alloc, session);
    defer secret.zeroAndFree(alloc, encoded);
    var decoded = try parse(alloc, encoded);
    defer decoded.deinit(alloc);

    try std.testing.expectEqualStrings(session.base_url, decoded.base_url);
    try std.testing.expectEqualStrings(session.api_key, decoded.api_key);
}

test "Gateway configure args split URL and remaining key" {
    const parsed = parseConfigureArgs("https://gateway.example.test/v1 sk test key") orelse
        return error.TestExpectedConfigureArgs;
    try std.testing.expectEqualStrings("https://gateway.example.test/v1", parsed.base_url);
    try std.testing.expectEqualStrings("sk test key", parsed.api_key);
    try std.testing.expect(parseConfigureArgs("https://gateway.example.test/v1") == null);
    try std.testing.expect(parseConfigureArgs("") == null);
}

test "Gateway process binding is copied under lock and cleared for tests" {
    const alloc = std.testing.allocator;
    resetProcessBindingForTests();
    defer resetProcessBindingForTests();

    var session = Session{
        .base_url = try alloc.dupe(u8, "https://overlay.example.test/v1"),
        .api_key = try alloc.dupe(u8, "overlay-key"),
    };
    defer session.deinit(alloc);
    try setProcessBinding(session);

    const url = (try copyProcessBaseUrlAlloc(alloc)).?;
    defer alloc.free(url);
    const key = (try copyProcessApiKeyAlloc(alloc)).?;
    defer secret.zeroAndFree(alloc, key);
    try std.testing.expectEqualStrings("https://overlay.example.test/v1", url);
    try std.testing.expectEqualStrings("overlay-key", key);
    try std.testing.expect(hasStoredBinding());
}

var stable_gateway_test_environ: ?*std.process.Environ.Map = null;

fn stableGatewayTestEnviron() !*const std.process.Environ.Map {
    if (stable_gateway_test_environ) |map| return map;
    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_gateway_test_environ = map;
    return map;
}

const GatewayTestEnv = struct {
    alloc: std.mem.Allocator,
    map: std.process.Environ.Map,
    tmp: std.testing.TmpDir,
    home: []u8,

    fn install(alloc: std.mem.Allocator) !*GatewayTestEnv {
        _ = try stableGatewayTestEnviron();
        const self = try alloc.create(GatewayTestEnv);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
            .tmp = std.testing.tmpDir(.{}),
            .home = undefined,
        };
        errdefer self.map.deinit();
        errdefer self.tmp.cleanup();
        self.home = try io_mod.dirRealpathAlloc(alloc, self.tmp.dir, ".");
        errdefer alloc.free(self.home);
        try self.map.put("HOME", self.home);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *GatewayTestEnv) void {
        resetProcessBindingForTests();
        if (stable_gateway_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        self.alloc.free(self.home);
        self.tmp.cleanup();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

test "Gateway session persists URL and key to the profile directory" {
    if (comptime host_target.is_wasm) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    resetProcessBindingForTests();
    defer resetProcessBindingForTests();
    const env = try GatewayTestEnv.install(alloc);
    defer env.deinit();

    try saveAndActivate(alloc, "https://gateway.example.test/v1", "sk-persist");
    resetProcessBindingForTests();

    const url = (try copyStoredBaseUrlAlloc(alloc)).?;
    defer alloc.free(url);
    const key = (try copyStoredApiKeyAlloc(alloc)).?;
    defer secret.zeroAndFree(alloc, key);
    try std.testing.expectEqualStrings("https://gateway.example.test/v1", url);
    try std.testing.expectEqualStrings("sk-persist", key);
    try std.testing.expect(hasStoredBinding());
    try std.testing.expectEqual(host.SecretStorePresence.present, presence());
}

test "Gateway session overlay wins over the persisted profile binding" {
    if (comptime host_target.is_wasm) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    resetProcessBindingForTests();
    defer resetProcessBindingForTests();
    const env = try GatewayTestEnv.install(alloc);
    defer env.deinit();

    try saveAndActivate(alloc, "https://disk.example.test/v1", "disk-key");
    var overlay = Session{
        .base_url = try alloc.dupe(u8, "https://overlay.example.test/v1"),
        .api_key = try alloc.dupe(u8, "overlay-key"),
    };
    defer overlay.deinit(alloc);
    try setProcessBinding(overlay);

    const url = (try copyStoredBaseUrlAlloc(alloc)).?;
    defer alloc.free(url);
    const key = (try copyStoredApiKeyAlloc(alloc)).?;
    defer secret.zeroAndFree(alloc, key);
    try std.testing.expectEqualStrings("https://overlay.example.test/v1", url);
    try std.testing.expectEqualStrings("overlay-key", key);
}

test "Gateway session delete removes the persisted profile binding" {
    if (comptime host_target.is_wasm) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    resetProcessBindingForTests();
    defer resetProcessBindingForTests();
    const env = try GatewayTestEnv.install(alloc);
    defer env.deinit();

    try saveAndActivate(alloc, "https://gateway.example.test/v1", "sk-persist");
    try std.testing.expectEqual(DeleteOutcome.deleted, try deleteStoredSession());
    try std.testing.expect(!hasStoredBinding());
    try std.testing.expect((try copyStoredApiKeyAlloc(alloc)) == null);
    try std.testing.expectEqual(DeleteOutcome.missing, try deleteStoredSession());
}

test "Gateway failed save or delete preserves the active binding" {
    if (comptime host_target.is_wasm) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const env = try GatewayTestEnv.install(alloc);
    defer env.deinit();
    try saveAndActivate(alloc, "https://old.example.test/v1", "old-key");
    try env.tmp.dir.deleteFile(io_mod.getIo(), ".fx/gateway-auth.json");
    try env.tmp.dir.createDirPath(io_mod.getIo(), ".fx/gateway-auth.json");
    if (saveAndActivate(alloc, "https://new.example.test/v1", "new-key")) |_| {
        return error.TestExpectedError;
    } else |_| {}
    if (deleteStoredSession()) |_| {
        return error.TestExpectedError;
    } else |_| {}
    var binding = (try copyStoredBinding(alloc)).?;
    defer binding.deinit(alloc);
    try std.testing.expectEqualStrings("https://old.example.test/v1", binding.base_url);
    try std.testing.expectEqualStrings("old-key", binding.api_key);
}
