const std = @import("std");
const auth_transition = @import("auth_transition.zig");
const credentials = @import("credentials.zig");
const host = @import("../hosts/host.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const model_provider = @import("../config/model_provider.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");
const io_mod = @import("../shared/io.zig");
const gateway_session = @import("gateway_session.zig");

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
    gateway_configure_base_url: ?[]const u8 = null,
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
    gateway_configure_base_url: ?[]u8 = null,

    pub fn deinit(self: *Completion, alloc: Allocator) void {
        self.outcome.deinit(alloc);
        if (self.gateway_configure_base_url) |value| alloc.free(value);
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
    if (cancel_flag.load(.seq_cst)) {
        model_catalog.freeModelCatalog(alloc, &catalog);
        credential.deinit(alloc);
        return .{ .failed = .cancelled };
    }
    if (request.gateway_configure_base_url) |base_url| {
        gateway_session.saveNewSession(alloc, .{
            .base_url = @constCast(base_url),
            .api_key = credential.token,
        }) catch |err| {
            model_catalog.freeModelCatalog(alloc, &catalog);
            credential.deinit(alloc);
            return .{ .failed = .{ .credential = err } };
        };
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
        gateway_configure_base_url: ?[]u8,

        fn init(alloc: Allocator, request: Request) !OwnedRequest {
            const endpoint = try alloc.dupe(u8, request.endpoint);
            errdefer alloc.free(endpoint);
            var credential_override = if (request.credential_override) |credential|
                try cloneCredential(alloc, credential.*)
            else
                null;
            errdefer if (credential_override) |*credential| credential.deinit(alloc);
            const gateway_configure_base_url = if (request.gateway_configure_base_url) |value|
                try alloc.dupe(u8, value)
            else
                null;
            errdefer if (gateway_configure_base_url) |value| alloc.free(value);
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
                    .gateway_configure_base_url = gateway_configure_base_url,
                },
                .endpoint = endpoint,
                .credential_override = credential_override,
                .gateway_configure_base_url = gateway_configure_base_url,
            };
        }

        fn deinit(self: *OwnedRequest, alloc: Allocator) void {
            if (self.credential_override) |*credential| credential.deinit(alloc);
            if (self.gateway_configure_base_url) |value| alloc.free(value);
            alloc.free(self.endpoint);
            self.* = undefined;
        }
    };

    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    running: bool = false,
    completion: ?Completion = null,
    pending_target: ?model_provider.ProviderId = null,
    discard_completion: bool = false,
    cancel_requested: std.atomic.Value(bool) = .init(false),

    pub fn init(alloc: Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        self.cancelAndDrain();
    }

    /// Blocking teardown for process shutdown. Event-loop callers use cancel()
    /// and let takeCompletion() reap the worker after it has stopped.
    pub fn cancelAndDrain(self: *Self) void {
        self.cancel();
        const thread = self.detachThread();
        if (thread) |handle| handle.join();
        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.completion) |*completion| completion.deinit(self.alloc);
        self.completion = null;
        self.pending_target = null;
        self.running = false;
        self.discard_completion = false;
        self.mutex.unlock(io_mod.getIo());
    }

    /// Invalidates a pending provider activation without joining its worker.
    /// The event loop later reaps the handle after the worker has stopped, so
    /// a slow network operation cannot block logout or any other UI action.
    pub fn cancel(self: *Self) void {
        _ = self.cancelMatching(null);
    }

    /// Invalidates only an activation for `target`. Logging out of one
    /// subscription provider must not discard an unrelated provider switch.
    pub fn cancelTarget(self: *Self, target: model_provider.ProviderId) bool {
        return self.cancelMatching(target);
    }

    fn cancelMatching(self: *Self, target: ?model_provider.ProviderId) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const pending_target = self.pending_target orelse return false;
        if (target) |expected| {
            if (pending_target != expected) return false;
        }
        self.cancel_requested.store(true, .seq_cst);
        self.discard_completion = true;
        if (self.completion) |*completion| completion.deinit(self.alloc);
        self.completion = null;
        self.pending_target = null;
        return true;
    }

    pub fn start(self: *Self, request: Request) !bool {
        self.reapFinished();
        var owned = try OwnedRequest.init(self.alloc, request);
        errdefer owned.deinit(self.alloc);

        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.running or self.completion != null or self.thread != null) {
            self.mutex.unlock(io_mod.getIo());
            owned.deinit(self.alloc);
            return false;
        }
        self.discard_completion = false;
        self.cancel_requested.store(false, .seq_cst);
        self.running = true;
        self.pending_target = request.target;
        const thread = std.Thread.spawn(.{}, threadMain, .{ self, owned }) catch |err| {
            self.running = false;
            self.pending_target = null;
            self.mutex.unlock(io_mod.getIo());
            return err;
        };
        owned = undefined;
        // Publish the handle before the worker can publish completion. The
        // worker takes this same mutex at the end of threadMain.
        self.thread = thread;
        self.mutex.unlock(io_mod.getIo());
        return true;
    }

    pub fn isRunning(self: *Self) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.running;
    }

    pub fn isBusy(self: *Self) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.running or self.completion != null or self.thread != null;
    }

    pub fn takeCompletion(self: *Self) ?Completion {
        self.mutex.lockUncancelable(io_mod.getIo());
        const completion = self.completion orelse {
            const thread = if (!self.running) self.thread else null;
            if (thread != null) {
                self.thread = null;
                self.discard_completion = false;
                self.pending_target = null;
            }
            self.mutex.unlock(io_mod.getIo());
            if (thread) |handle| handle.join();
            return null;
        };
        self.completion = null;
        const thread = self.thread;
        self.thread = null;
        self.discard_completion = false;
        self.pending_target = null;
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
        var completion = Completion{
            .target = request.target,
            .intent = request.intent,
            .allow_login = request.allow_login,
            .outcome = prepare(self.alloc, request, &self.cancel_requested),
            .gateway_configure_base_url = owned.gateway_configure_base_url,
        };
        owned.gateway_configure_base_url = null;
        self.mutex.lockUncancelable(io_mod.getIo());
        const discard = self.discard_completion;
        if (!discard) self.completion = completion;
        self.running = false;
        self.mutex.unlock(io_mod.getIo());
        if (discard) completion.deinit(self.alloc);
    }

    fn reapFinished(self: *Self) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        const thread = if (!self.running) self.thread else null;
        if (thread != null) {
            self.thread = null;
            self.discard_completion = false;
        }
        self.mutex.unlock(io_mod.getIo());
        if (thread) |handle| handle.join();
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

test "provider activation cancellation discards a prepared credential" {
    const FakeCatalog = struct {
        entered: std.atomic.Value(bool) = .init(false),

        fn fetch(
            raw: ?*anyopaque,
            _: Allocator,
            input: model_catalog.FetchInput,
        ) Allocator.Error!model_catalog.ProviderResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.entered.store(true, .release);
            const cancel = input.cancel_flag orelse unreachable;
            while (!cancel.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
            return .{ .failure = .{ .category = .cancellation } };
        }
    };

    var fake = FakeCatalog{};
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const credential = credentials.Credential{
        .token = @constCast("test-key"),
        .source = .openai_api_key,
    };
    const request = Request{
        .target = .gateway,
        .oauth_transport = oauth_transport.unavailable_provider,
        .secret_store = host.unavailable_secret_store,
        .catalog_provider = .{ .context = &fake, .fetch_fn = FakeCatalog.fetch },
        .endpoint = "https://example.test/v1/models",
        .credential_override = &credential,
    };
    try std.testing.expect(try runtime.start(request));
    while (!fake.entered.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
    try std.testing.expect(!(try runtime.start(request)));

    runtime.cancel();
    while (runtime.isRunning()) io_mod.sleep(std.time.ns_per_ms);

    try std.testing.expect(!runtime.isRunning());
    try std.testing.expect(runtime.takeCompletion() == null);
}

test "provider activation cancellation never joins a stalled worker" {
    const FakeCatalog = struct {
        entered: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),

        fn fetch(
            raw: ?*anyopaque,
            _: Allocator,
            _: model_catalog.FetchInput,
        ) Allocator.Error!model_catalog.ProviderResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.entered.store(true, .release);
            while (!self.release.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
            return .{ .failure = .{ .category = .cancellation } };
        }
    };

    var fake = FakeCatalog{};
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const credential = credentials.Credential{
        .token = @constCast("test-key"),
        .source = .openai_api_key,
    };
    try std.testing.expect(try runtime.start(.{
        .target = .gateway,
        .oauth_transport = oauth_transport.unavailable_provider,
        .secret_store = host.unavailable_secret_store,
        .catalog_provider = .{ .context = &fake, .fetch_fn = FakeCatalog.fetch },
        .endpoint = "https://example.test/v1/models",
        .credential_override = &credential,
    }));
    while (!fake.entered.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);

    runtime.cancel();
    // A synchronous join would never reach these assertions because this fake
    // provider intentionally ignores the cooperative cancellation flag.
    try std.testing.expect(runtime.isRunning());
    try std.testing.expect(runtime.takeCompletion() == null);

    fake.release.store(true, .release);
    while (runtime.isRunning()) io_mod.sleep(std.time.ns_per_ms);
    try std.testing.expect(runtime.takeCompletion() == null);
}

test "provider activation cancellation ignores a different provider" {
    const FakeCatalog = struct {
        entered: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),

        fn fetch(
            raw: ?*anyopaque,
            _: Allocator,
            _: model_catalog.FetchInput,
        ) Allocator.Error!model_catalog.ProviderResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.entered.store(true, .release);
            while (!self.release.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
            return .{ .failure = .{ .category = .cancellation } };
        }
    };

    var fake = FakeCatalog{};
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const credential = credentials.Credential{
        .token = @constCast("grok-key"),
        .source = .grok_subscription,
    };
    try std.testing.expect(try runtime.start(.{
        .target = .grok,
        .oauth_transport = oauth_transport.unavailable_provider,
        .secret_store = host.unavailable_secret_store,
        .catalog_provider = .{ .context = &fake, .fetch_fn = FakeCatalog.fetch },
        .endpoint = "https://example.test/models",
        .credential_override = &credential,
    }));
    while (!fake.entered.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);

    try std.testing.expect(!runtime.cancelTarget(.codex));
    try std.testing.expect(runtime.isRunning());

    fake.release.store(true, .release);
    while (runtime.isRunning()) io_mod.sleep(std.time.ns_per_ms);
    var completion = runtime.takeCompletion() orelse return error.TestExpectedEqual;
    defer completion.deinit(std.testing.allocator);
    try std.testing.expectEqual(model_provider.ProviderId.grok, completion.target);
}
