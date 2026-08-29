const std = @import("std");
const auth_transition = @import("auth_transition.zig");
const credentials = @import("credentials.zig");
const host = @import("../hosts/host.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const model_provider = @import("../config/model_provider.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Request = struct {
    target: model_provider.ProviderId,
    intent: auth_transition.ProviderSwitchIntent = .manual,
    allow_login: bool = false,
    oauth_transport: oauth_transport.Provider,
    secret_store: host.SecretStore,
    catalog_provider: model_catalog.Provider,
    endpoint: []const u8,
    credential_override: ?*const credentials.Credential = null,
};

pub const Failure = union(enum) {
    cancelled,
    credential: anyerror,
    missing_credential,
    unauthorized_credential,
    catalog: model_catalog.Failure,
    empty_catalog,
};

pub const Prepared = struct {
    credential: credentials.Credential,
    catalog: std.ArrayList(model_catalog.ModelCatalogEntry),

    pub fn deinit(self: *Prepared, alloc: Allocator) void {
        self.credential.deinit(alloc);
        model_catalog.freeModelCatalog(alloc, &self.catalog);
        self.* = undefined;
    }
};

pub const Outcome = union(enum) {
    prepared: Prepared,
    failed: Failure,

    pub fn deinit(self: *Outcome, alloc: Allocator) void {
        switch (self.*) {
            .prepared => |*prepared| prepared.deinit(alloc),
            .failed => {},
        }
        self.* = undefined;
    }
};

pub const Completion = struct {
    target: model_provider.ProviderId,
    intent: auth_transition.ProviderSwitchIntent,
    allow_login: bool,
    outcome: Outcome,

    pub fn deinit(self: *Completion, alloc: Allocator) void {
        self.outcome.deinit(alloc);
        self.* = undefined;
    }
};

pub fn prepare(
    alloc: Allocator,
    request: Request,
    cancel_flag: *std.atomic.Value(bool),
) Outcome {
    if (cancel_flag.load(.seq_cst)) return .{ .failed = .cancelled };

    var credential = if (request.credential_override) |value|
        cloneCredential(alloc, value.*) catch |err| return .{ .failed = .{ .credential = err } }
    else credential: {
        const resolution = credentials.resolveForProvider(
            alloc,
            request.oauth_transport,
            request.secret_store,
            .refresh_if_needed,
            request.target,
            null,
        ) catch |err| return .{ .failed = .{ .credential = err } };
        break :credential resolution.credential orelse
            return .{ .failed = .missing_credential };
    };
    if (cancel_flag.load(.seq_cst)) {
        credential.deinit(alloc);
        return .{ .failed = .cancelled };
    }
    if (!model_provider.authorizesCredential(request.target, credential.source)) {
        credential.deinit(alloc);
        return .{ .failed = .unauthorized_credential };
    }

    const access = credentials.catalogAccessForCredentialAndAccount(
        credential.source,
        credential.token,
        credential.accountId(),
    );
    const fetched = request.catalog_provider.fetch(alloc, .{
        .access = access,
        .endpoint = request.endpoint,
        .cancel_flag = cancel_flag,
        .view = .picker,
    }) catch |err| {
        credential.deinit(alloc);
        return .{ .failed = .{ .credential = err } };
    };
    var catalog = switch (fetched) {
        .catalog => |catalog| catalog,
        .failure => |failure| {
            credential.deinit(alloc);
            return .{ .failed = .{ .catalog = failure } };
        },
    };
    if (catalog.items.len == 0) {
        model_catalog.freeModelCatalog(alloc, &catalog);
        credential.deinit(alloc);
        return .{ .failed = .empty_catalog };
    }
    return .{ .prepared = .{
        .credential = credential,
        .catalog = catalog,
    } };
}

pub const Runtime = struct {
    const Self = @This();

    const OwnedRequest = struct {
        request: Request,
        endpoint: []u8,
        credential_override: ?credentials.Credential,

        fn init(alloc: Allocator, request: Request) !OwnedRequest {
            const endpoint = try alloc.dupe(u8, request.endpoint);
            errdefer alloc.free(endpoint);
            var credential_override = if (request.credential_override) |credential|
                try cloneCredential(alloc, credential.*)
            else
                null;
            errdefer if (credential_override) |*credential| credential.deinit(alloc);
            return .{
                .request = .{
                    .target = request.target,
                    .intent = request.intent,
                    .allow_login = request.allow_login,
                    .oauth_transport = request.oauth_transport,
                    .secret_store = request.secret_store,
                    .catalog_provider = request.catalog_provider,
                    .endpoint = endpoint,
                    // Rebind this pointer in threadMain after OwnedRequest reaches
                    // its final address. Pointing at the local optional here would
                    // leave Request with a dangling stack pointer after the move.
                    .credential_override = null,
                },
                .endpoint = endpoint,
                .credential_override = credential_override,
            };
        }

        fn deinit(self: *OwnedRequest, alloc: Allocator) void {
            if (self.credential_override) |*credential| credential.deinit(alloc);
            alloc.free(self.endpoint);
            self.* = undefined;
        }
    };

    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    running: bool = false,
    completion: ?Completion = null,
    cancel_requested: std.atomic.Value(bool) = .init(false),

    pub fn init(alloc: Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        self.cancel_requested.store(true, .seq_cst);
        const thread = self.detachThread();
        if (thread) |handle| handle.join();
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.completion) |*completion| completion.deinit(self.alloc);
        self.completion = null;
        self.running = false;
        self.mutex.unlock(io_mod.getIo());
    }

    pub fn start(self: *Self, request: Request) !bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        const unavailable = self.running or self.completion != null or self.thread != null;
        self.mutex.unlock(io_mod.getIo());
        if (unavailable) return false;

        var owned = try OwnedRequest.init(self.alloc, request);
        errdefer owned.deinit(self.alloc);
        self.cancel_requested.store(false, .seq_cst);

        self.mutex.lockUncancelable(io_mod.getIo());
        self.running = true;
        self.mutex.unlock(io_mod.getIo());
        const thread = std.Thread.spawn(.{}, threadMain, .{ self, owned }) catch |err| {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.running = false;
            self.mutex.unlock(io_mod.getIo());
            return err;
        };
        owned = undefined;
        self.mutex.lockUncancelable(io_mod.getIo());
        self.thread = thread;
        self.mutex.unlock(io_mod.getIo());
        return true;
    }

    pub fn isRunning(self: *Self) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.running;
    }

    pub fn takeCompletion(self: *Self) ?Completion {
        self.mutex.lockUncancelable(io_mod.getIo());
        const completion = self.completion orelse {
            self.mutex.unlock(io_mod.getIo());
            return null;
        };
        self.completion = null;
        const thread = self.thread;
        self.thread = null;
        self.mutex.unlock(io_mod.getIo());
        if (thread) |handle| handle.join();
        return completion;
    }

    fn threadMain(self: *Self, owned_request: OwnedRequest) void {
        var owned = owned_request;
        defer owned.deinit(self.alloc);
        var request = owned.request;
        request.credential_override = if (owned.credential_override) |*credential|
            credential
        else
            null;
        const outcome = prepare(self.alloc, request, &self.cancel_requested);
        self.mutex.lockUncancelable(io_mod.getIo());
        self.completion = .{
            .target = request.target,
            .intent = request.intent,
            .allow_login = request.allow_login,
            .outcome = outcome,
        };
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

fn cloneCredential(alloc: Allocator, value: credentials.Credential) !credentials.Credential {
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
