const std = @import("std");
const mcp = @import("mcp_test_exports");

const Allocator = std.mem.Allocator;

const Worker = struct {
    dispatcher: *mcp.StdioDispatcher,
    owner: []const u8,
    request_id: ?u64 = null,
    response: ?[]u8 = null,
    progress_owner_matched: bool = false,
    err: ?anyerror = null,

    fn run(self: *Worker) void {
        const alloc = std.heap.c_allocator;
        const request_id = self.dispatcher.reserveRequestId() catch |err| {
            self.err = err;
            return;
        };
        self.request_id = request_id;
        var body_writer: std.Io.Writer.Allocating = .init(alloc);
        defer body_writer.deinit();
        std.json.Stringify.value(.{
            .jsonrpc = "2.0",
            .id = request_id,
            .method = "fixture/call",
            .params = .{
                .owner = self.owner,
                ._meta = .{ .progressToken = request_id },
            },
        }, .{}, &body_writer.writer) catch |err| {
            self.err = err;
            return;
        };
        const body = body_writer.toOwnedSlice() catch |err| {
            self.err = err;
            return;
        };
        defer alloc.free(body);

        self.response = self.dispatcher.request(
            alloc,
            request_id,
            body,
            4096,
            .{
                .timeout_ms = 2_000,
                .progress = .{
                    .context = @ptrCast(self),
                    .callback = acceptProgress,
                },
            },
        ) catch |err| {
            self.err = err;
            return;
        };
    }

    fn acceptProgress(raw: *anyopaque, progress: @import("mcp_test_exports").Progress) void {
        const self: *Worker = @ptrCast(@alignCast(raw));
        var expected_buf: [64]u8 = undefined;
        const expected = std.fmt.bufPrint(
            &expected_buf,
            "progress:{s}",
            .{self.owner},
        ) catch return;
        self.progress_owner_matched = std.mem.eql(
            u8,
            progress.message orelse "",
            expected,
        );
    }
};

const RuntimeCall = struct {
    io: std.Io,
    runtime: *mcp.McpRuntime,
    tool_name: []const u8,
    arguments_json: []const u8,
    alloc: Allocator = std.heap.c_allocator,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    started: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    response: ?[]const u8 = null,
    elapsed_ms: i64 = 0,
    err: ?anyerror = null,

    fn run(self: *RuntimeCall) void {
        const started_ms = milliTimestamp(self.io);
        defer self.finished.store(true, .release);
        self.started.store(true, .release);
        var result = (self.runtime.callToolByNameWithOptions(
            self.alloc,
            self.tool_name,
            self.arguments_json,
            1024 * 1024,
            .{ .cancel_flag = self.cancel_flag },
        ) catch |err| {
            self.err = err;
            self.elapsed_ms = milliTimestamp(self.io) - started_ms;
            return;
        }) orelse null;
        if (result) |*value| self.response = value.takeModelOutput(self.alloc);
        self.elapsed_ms = milliTimestamp(self.io) - started_ms;
    }
};

const SnapshotBarrierAllocator = struct {
    io: std.Io,
    base: Allocator,
    target_allocation: usize,
    allocation_count: std.atomic.Value(usize) = .init(0),
    waiting: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),

    fn allocator(self: *SnapshotBarrierAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocate,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn allocate(
        raw: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *SnapshotBarrierAllocator = @ptrCast(@alignCast(raw));
        const allocation = self.allocation_count.fetchAdd(1, .acq_rel) + 1;
        if (allocation == self.target_allocation) {
            self.waiting.store(true, .release);
            while (!self.released.load(.acquire)) sleep(self.io, std.time.ns_per_ms);
        }
        return self.base.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *SnapshotBarrierAllocator = @ptrCast(@alignCast(raw));
        return self.base.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *SnapshotBarrierAllocator = @ptrCast(@alignCast(raw));
        return self.base.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *SnapshotBarrierAllocator = @ptrCast(@alignCast(raw));
        self.base.rawFree(memory, alignment, return_address);
    }
};

pub fn main(init: std.process.Init) !void {
    mcp.setIo(init.io);
    mcp.setEnvironMap(init.environ_map);
    const alloc = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 3 and std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "runtime-http-mrtr")) {
        return runRuntimeHttpMrtr(
            init.io,
            alloc,
            std.mem.sliceTo(args[2], 0),
        );
    }
    if (args.len == 5 and std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "runtime-scoped-http-auth")) {
        return runRuntimeScopedHttpAuth(
            init.io,
            alloc,
            std.mem.sliceTo(args[2], 0),
            std.mem.sliceTo(args[3], 0),
            std.mem.sliceTo(args[4], 0),
        );
    }
    if (args.len == 5 and std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "runtime-legacy-refresh-locks")) {
        return runRuntimeLegacyRefreshLocks(
            init.io,
            alloc,
            std.mem.sliceTo(args[2], 0),
            std.mem.sliceTo(args[3], 0),
            std.mem.sliceTo(args[4], 0),
        );
    }
    if (args.len == 6 and std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "runtime-logout-refresh-race")) {
        return runRuntimeLogoutRefreshRace(
            init.io,
            alloc,
            std.mem.sliceTo(args[2], 0),
            std.mem.sliceTo(args[3], 0),
            std.mem.sliceTo(args[4], 0),
            std.mem.sliceTo(args[5], 0),
        );
    }
    if (args.len == 5 and std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "runtime-interactive-auth-locks")) {
        return runRuntimeInteractiveAuthLocks(
            init.io,
            alloc,
            std.mem.sliceTo(args[2], 0),
            std.mem.sliceTo(args[3], 0),
            std.mem.sliceTo(args[4], 0),
        );
    }
    if (args.len == 4 and std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "runtime-interactive-auth-retirement")) {
        return runRuntimeInteractiveAuthRetirement(
            init.io,
            alloc,
            std.mem.sliceTo(args[2], 0),
            std.mem.sliceTo(args[3], 0),
        );
    }
    if (args.len == 5 and std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "runtime-mrtr-guards")) {
        return runRuntimeMrtrGuards(
            init.io,
            alloc,
            std.mem.sliceTo(args[2], 0),
            std.mem.sliceTo(args[3], 0),
            std.mem.sliceTo(args[4], 0),
        );
    }
    if (args.len == 6 and std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "runtime-catalog-control")) {
        return runRuntimeCatalogControl(
            init.io,
            alloc,
            std.mem.sliceTo(args[2], 0),
            std.mem.sliceTo(args[3], 0),
            std.mem.sliceTo(args[4], 0),
            std.mem.sliceTo(args[5], 0),
        );
    }
    if (args.len == 6 and std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "runtime-recovery-control")) {
        return runRuntimeRecoveryControl(
            init.io,
            alloc,
            std.mem.sliceTo(args[2], 0),
            std.mem.sliceTo(args[3], 0),
            std.mem.sliceTo(args[4], 0),
            std.mem.sliceTo(args[5], 0),
        );
    }
    if (args.len == 6 and std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "runtime-scoped-recovery")) {
        return runRuntimeScopedRecovery(
            init.io,
            alloc,
            std.mem.sliceTo(args[2], 0),
            std.mem.sliceTo(args[3], 0),
            std.mem.sliceTo(args[4], 0),
            std.mem.sliceTo(args[5], 0),
        );
    }
    if (args.len == 5 and std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "runtime-recovery-collision")) {
        return runRuntimeRecoveryCollision(
            init.io,
            alloc,
            std.mem.sliceTo(args[2], 0),
            std.mem.sliceTo(args[3], 0),
            std.mem.sliceTo(args[4], 0),
        );
    }
    if (args.len == 5 and std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "runtime-recovery-budget")) {
        return runRuntimeRecoveryBudget(
            init.io,
            alloc,
            std.mem.sliceTo(args[2], 0),
            std.mem.sliceTo(args[3], 0),
            std.mem.sliceTo(args[4], 0),
        );
    }
    if (args.len == 5 and std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "runtime-stale-recovery")) {
        return runRuntimeStaleRecovery(
            init.io,
            alloc,
            std.mem.sliceTo(args[2], 0),
            std.mem.sliceTo(args[3], 0),
            std.mem.sliceTo(args[4], 0),
        );
    }
    if (args.len == 5 and std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "runtime-recovery")) {
        return runRuntimeRecovery(
            init.io,
            alloc,
            std.mem.sliceTo(args[2], 0),
            std.mem.sliceTo(args[3], 0),
            std.mem.sliceTo(args[4], 0),
        );
    }
    if (args.len == 4 and std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "blocked-write")) {
        return runBlockedWrite(
            init.io,
            alloc,
            std.mem.sliceTo(args[2], 0),
            std.mem.sliceTo(args[3], 0),
        );
    }
    if (args.len != 3) return error.ExpectedRuntimeAndFixturePaths;
    const runtime = std.mem.sliceTo(args[1], 0);
    const fixture = std.mem.sliceTo(args[2], 0);

    const child = try std.process.spawn(init.io, .{
        .argv = &.{ runtime, fixture },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
        .pgid = if (@import("builtin").os.tag == .windows) null else 0,
    });
    const child_id = child.id.?;
    const dispatcher = try mcp.StdioDispatcher.create(
        alloc,
        std.heap.c_allocator,
        child,
        1,
        4096,
    );
    defer dispatcher.deinit();

    var first = Worker{ .dispatcher = dispatcher, .owner = "first" };
    var second = Worker{ .dispatcher = dispatcher, .owner = "second" };
    const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&second});
    first_thread.join();
    second_thread.join();

    try validateWorker(alloc, &first);
    try validateWorker(alloc, &second);
    dispatcher.shutdown();

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    try stdout.interface.print(
        "{{\"child_pid\":{any},\"first_id\":{d},\"second_id\":{d},\"progress\":true,\"reader_joined\":true}}\n",
        .{ child_id, first.request_id.?, second.request_id.? },
    );
    try stdout.interface.flush();
}

fn runRuntimeHttpMrtr(io: std.Io, alloc: Allocator, server_url: []const u8) !void {
    var runtime = mcp.McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "conformance"),
        .transport = .http,
        .url = try alloc.dupe(u8, server_url),
        .operation_timeout_ms = 10_000,
    });
    runtime.connectAll(.{});

    const tool_names = [_][]const u8{
        "mcp_conformance_test_mrtr_echo_state",
        "mcp_conformance_test_mrtr_unrelated",
        "mcp_conformance_test_mrtr_no_state",
        "mcp_conformance_test_mrtr_no_result_type",
    };
    for (tool_names) |tool_name| {
        var result = (try runtime.callToolByNameWithOptions(
            alloc,
            tool_name,
            "{}",
            1024 * 1024,
            .{ .input_responder = .{
                .context = @ptrCast(&runtime),
                .callback = deterministicMrtrResponse,
            } },
        )) orelse return error.MissingMrtrTool;
        result.deinit(alloc);
    }

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.writeAll("{\"mrtr_fixture\":true,\"calls\":4}\n");
    try stdout.interface.flush();
}

const ScopedAuthLiveProvider = struct {
    io: std.Io,
    captured: *const mcp.AccessView,
    revoked: *const mcp.AccessView,
    marker_path: []const u8,
    resolutions: usize = 0,

    fn resolve(raw: *anyopaque, alloc: Allocator) !mcp.ResolvedLiveView {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.resolutions += 1;
        const source = if (markerExists(self.io, self.marker_path))
            self.revoked
        else
            self.captured;
        const view = try source.clone(alloc);
        return .{
            .authority_generation = mcp.authorityGeneration(view),
            .view = view,
        };
    }
};

fn runRuntimeScopedHttpAuth(
    io: std.Io,
    alloc: Allocator,
    server_url: []const u8,
    marker_path: []const u8,
    mode: []const u8,
) !void {
    const expired = std.mem.eql(u8, mode, "expired");
    const challenge = std.mem.eql(u8, mode, "challenge");
    if (!expired and !challenge) return error.InvalidScopedAuthMode;

    var runtime = mcp.McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "fixture"),
        .transport = .http,
        .url = try alloc.dupe(u8, server_url),
        .allow_stored_credentials = true,
        .operation_timeout_ms = 10_000,
    });
    runtime.connectAll(.{});
    if (runtime.servers.items.len != 1 or runtime.servers.items[0].state.load(.acquire) != .ready) {
        if (runtime.servers.items.len == 1) {
            var stderr_buf: [1024]u8 = undefined;
            var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
            try stderr.interface.print(
                "scoped auth connect failed state={s} error={s}\n",
                .{
                    @tagName(runtime.servers.items[0].state.load(.acquire)),
                    runtime.servers.items[0].last_error orelse "none",
                },
            );
            try stderr.interface.flush();
        }
        return error.ScopedAuthServerDidNotConnect;
    }
    const server = runtime.servers.items[0];
    if (expired) {
        server.auth_lock.lockUncancelable(io);
        if (server.auth_credentials) |*credentials| {
            credentials.expires_at_ms = 0;
        } else {
            server.auth_lock.unlock(io);
            return error.ScopedAuthCredentialsMissing;
        }
        server.auth_lock.unlock(io);
    }

    const initial_auth_generation = server.auth_generation.load(.acquire);
    const initial_token = initial_token: {
        server.auth_lock.lockUncancelable(io);
        defer server.auth_lock.unlock(io);
        const credentials = server.auth_credentials orelse
            return error.ScopedAuthCredentialsMissing;
        break :initial_token try alloc.dupe(u8, credentials.access_token);
    };
    defer alloc.free(initial_token);
    var captured = try runtime.snapshotAccessView(alloc, "child", "parent", .{}, true);
    defer captured.deinit(alloc);
    var revoked = try captured.clone(alloc);
    defer revoked.deinit(alloc);
    revoked.servers[0].auth_generation += 1;
    var provider = ScopedAuthLiveProvider{
        .io = io,
        .captured = &captured,
        .revoked = &revoked,
        .marker_path = marker_path,
    };
    const access = mcp.Access{ .scoped = .{
        .captured = &captured,
        .admission_authority_generation = mcp.authorityGeneration(captured),
        .live = .{
            .context = @ptrCast(&provider),
            .resolve_fn = ScopedAuthLiveProvider.resolve,
        },
    } };

    var call_error: ?anyerror = null;
    if (runtime.callToolByNameWithOptions(
        alloc,
        "mcp_fixture_echo",
        "{\"text\":\"scoped\"}",
        1024 * 1024,
        .{ .access = access },
    )) |maybe_result| {
        if (maybe_result) |result_value| {
            var result = result_value;
            result.deinit(alloc);
        }
        return error.ScopedAuthCallUnexpectedlySucceeded;
    } else |err| {
        call_error = err;
    }

    const expected_error: anyerror = if (expired)
        error.McpAuthenticationRequired
    else
        error.McpAuthorityChanged;
    if (call_error.? != expected_error) return call_error.?;
    if (server.auth_generation.load(.acquire) != initial_auth_generation) {
        return error.ScopedAuthGenerationChanged;
    }
    if (server.auth_challenge_present.load(.acquire)) {
        return error.ScopedAuthChallengePublished;
    }
    server.auth_lock.lockUncancelable(io);
    const final_token_matches = if (server.auth_credentials) |credentials|
        std.mem.eql(u8, credentials.access_token, initial_token)
    else
        false;
    server.auth_lock.unlock(io);
    if (!final_token_matches) return error.ScopedAuthCredentialsChanged;

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print(
        "{{\"mode\":\"{s}\",\"error\":\"{s}\",\"auth_generation\":{d},\"challenge_present\":false,\"resolutions\":{d}}}\n",
        .{ mode, @errorName(call_error.?), initial_auth_generation, provider.resolutions },
    );
    try stdout.interface.flush();
}

fn runRuntimeLegacyRefreshLocks(
    io: std.Io,
    alloc: Allocator,
    server_url: []const u8,
    refresh_started_path: []const u8,
    refresh_release_path: []const u8,
) !void {
    var runtime = mcp.McpRuntime.init(alloc);
    defer runtime.deinit();
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "fixture"),
        .transport = .http,
        .url = try alloc.dupe(u8, server_url),
        .allow_stored_credentials = true,
        .operation_timeout_ms = 10_000,
    });
    runtime.connectAll(.{});
    if (runtime.servers.items.len != 1 or
        runtime.servers.items[0].state.load(.acquire) != .ready or
        runtime.servers.items[0].legacy_http == null)
    {
        return error.LegacyRefreshServerDidNotConnect;
    }
    const server = runtime.servers.items[0];
    server.auth_lock.lockUncancelable(io);
    if (server.auth_credentials) |*credentials| {
        credentials.expires_at_ms = 0;
    } else {
        server.auth_lock.unlock(io);
        return error.LegacyRefreshCredentialsMissing;
    }
    server.auth_lock.unlock(io);
    const initial_auth_generation = server.auth_generation.load(.acquire);

    var call = RuntimeCall{
        .io = io,
        .runtime = &runtime,
        .tool_name = "mcp_fixture_echo",
        .arguments_json = "{\"text\":\"lock-boundary\"}",
    };
    const call_thread = try std.Thread.spawn(.{}, RuntimeCall.run, .{&call});
    var call_joined = false;
    defer if (!call_joined) {
        createSignalFile(io, refresh_release_path) catch {};
        call_thread.join();
    };

    try waitForPath(io, refresh_started_path, 5_000);
    const auth_lock_available = server.auth_lock.tryLock();
    if (auth_lock_available) server.auth_lock.unlock(io);
    const connection_lock_available = server.connection_lock.tryLock(io);
    if (connection_lock_available) server.connection_lock.unlock(io);
    try createSignalFile(io, refresh_release_path);
    call_thread.join();
    call_joined = true;

    if (!auth_lock_available) return error.LegacyRefreshHeldAuthLock;
    if (!connection_lock_available) return error.LegacyRefreshHeldConnectionLock;
    if (call.err) |err| return err;
    const response = call.response orelse return error.LegacyRefreshCallMissingResponse;
    defer alloc.free(response);
    const final_auth_generation = server.auth_generation.load(.acquire);
    if (final_auth_generation != initial_auth_generation + 1) {
        return error.LegacyRefreshGenerationDidNotAdvance;
    }

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print(
        "{{\"auth_lock_available\":true,\"connection_lock_available\":true,\"initial_auth_generation\":{d},\"final_auth_generation\":{d}}}\n",
        .{ initial_auth_generation, final_auth_generation },
    );
    try stdout.interface.flush();
}

const RuntimeLogout = struct {
    runtime: *mcp.McpRuntime,
    started: std.atomic.Value(bool) = .init(false),
    removed: bool = false,
    err: ?anyerror = null,

    fn run(self: *RuntimeLogout) void {
        self.started.store(true, .release);
        const result = self.runtime.logoutServer("fixture") catch |err| {
            self.err = err;
            return;
        };
        self.removed = result.removed;
    }
};

fn runRuntimeLogoutRefreshRace(
    io: std.Io,
    alloc: Allocator,
    server_url: []const u8,
    refresh_started_path: []const u8,
    refresh_release_path: []const u8,
    credential_store_path: []const u8,
) !void {
    var store_present_while_auth_locked = false;
    {
        var runtime = mcp.McpRuntime.init(alloc);
        defer runtime.deinit();
        try runtime.addServer(.{
            .name = try alloc.dupe(u8, "fixture"),
            .transport = .http,
            .url = try alloc.dupe(u8, server_url),
            .allow_stored_credentials = true,
            .operation_timeout_ms = 10_000,
        });
        runtime.connectAll(.{});
        if (runtime.servers.items.len != 1 or
            runtime.servers.items[0].state.load(.acquire) != .ready or
            runtime.servers.items[0].legacy_http == null)
        {
            return error.LogoutRefreshServerDidNotConnect;
        }
        const server = runtime.servers.items[0];
        server.auth_lock.lockUncancelable(io);
        if (server.auth_credentials) |*credentials| {
            credentials.expires_at_ms = 0;
        } else {
            server.auth_lock.unlock(io);
            return error.LogoutRefreshCredentialsMissing;
        }
        server.auth_lock.unlock(io);

        var call = RuntimeCall{
            .io = io,
            .runtime = &runtime,
            .tool_name = "mcp_fixture_echo",
            .arguments_json = "{\"text\":\"logout-refresh-race\"}",
        };
        const call_thread = try std.Thread.spawn(.{}, RuntimeCall.run, .{&call});
        var call_joined = false;
        defer if (!call_joined) {
            createSignalFile(io, refresh_release_path) catch {};
            call_thread.join();
        };

        try waitForPath(io, refresh_started_path, 5_000);
        server.auth_lock.lockUncancelable(io);
        var auth_locked = true;
        defer if (auth_locked) server.auth_lock.unlock(io);
        try createSignalFile(io, refresh_release_path);
        sleep(io, 100 * std.time.ns_per_ms);

        var logout = RuntimeLogout{ .runtime = &runtime };
        const logout_thread = try std.Thread.spawn(.{}, RuntimeLogout.run, .{&logout});
        var logout_joined = false;
        defer if (!logout_joined) logout_thread.join();
        try waitForAtomicFlag(io, &logout.started, 1_000);
        store_present_while_auth_locked = !waitForPathMissing(
            io,
            credential_store_path,
            500,
        );
        server.auth_lock.unlock(io);
        auth_locked = false;

        logout_thread.join();
        logout_joined = true;
        call_thread.join();
        call_joined = true;
        if (call.response) |response| alloc.free(response);
        if (logout.err) |err| return err;
        if (!logout.removed) return error.LogoutRefreshCredentialsNotRemoved;
    }

    var restarted = mcp.McpRuntime.init(alloc);
    defer restarted.deinit();
    try restarted.addServer(.{
        .name = try alloc.dupe(u8, "fixture"),
        .transport = .http,
        .url = try alloc.dupe(u8, server_url),
        .allow_stored_credentials = true,
        .operation_timeout_ms = 10_000,
    });
    restarted.connectAll(.{});
    if (restarted.servers.items.len != 1) return error.LogoutRefreshRestartServerMissing;
    const credentials_reloaded = restarted.servers.items[0].auth_credentials_present.load(.acquire);

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print(
        "{{\"logout_removed\":true,\"store_present_while_auth_locked\":{s},\"credentials_reloaded_after_restart\":{s}}}\n",
        .{
            if (store_present_while_auth_locked) "true" else "false",
            if (credentials_reloaded) "true" else "false",
        },
    );
    try stdout.interface.flush();
}

const InteractiveAuthOpener = struct {
    io: std.Io,
    started_path: []const u8,
    release_path: ?[]const u8 = null,

    fn open(
        raw: ?*anyopaque,
        _: Allocator,
        _: []const u8,
    ) anyerror!bool {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        try createSignalFile(self.io, self.started_path);
        if (self.release_path) |path| {
            try waitForPath(self.io, path, 5_000);
            return false;
        }
        return true;
    }
};

const InteractiveAuthAttempt = struct {
    runtime: *mcp.McpRuntime,
    opener: *InteractiveAuthOpener,
    acquire_lease: bool = false,
    err: ?anyerror = null,

    fn run(self: *InteractiveAuthAttempt) void {
        if (self.acquire_lease and !self.runtime.acquireUse()) {
            self.err = error.McpRuntimeUnavailable;
            return;
        }
        defer if (self.acquire_lease) self.runtime.releaseUse();
        var result = self.runtime.authenticateServer(
            "fixture",
            @ptrCast(self.opener),
            InteractiveAuthOpener.open,
        ) catch |err| {
            self.err = err;
            return;
        };
        result.deinit();
    }
};

fn addInteractiveAuthServer(
    runtime: *mcp.McpRuntime,
    alloc: Allocator,
    server_url: []const u8,
) !void {
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "fixture"),
        .transport = .http,
        .url = try alloc.dupe(u8, server_url),
        .auth = .{
            .client_id = try alloc.dupe(u8, "fx-mcp-auth-test"),
        },
        .operation_timeout_ms = 10_000,
    });
    runtime.connectAll(.{});
    if (runtime.servers.items.len != 1) return error.InteractiveAuthServerMissing;
}

fn runRuntimeInteractiveAuthLocks(
    io: std.Io,
    alloc: Allocator,
    server_url: []const u8,
    auth_started_path: []const u8,
    auth_release_path: []const u8,
) !void {
    var runtime = mcp.McpRuntime.init(alloc);
    defer runtime.deinit();
    try addInteractiveAuthServer(&runtime, alloc, server_url);
    const server = runtime.servers.items[0];
    var opener = InteractiveAuthOpener{
        .io = io,
        .started_path = auth_started_path,
        .release_path = auth_release_path,
    };
    var auth = InteractiveAuthAttempt{ .runtime = &runtime, .opener = &opener };
    const auth_thread = try std.Thread.spawn(.{}, InteractiveAuthAttempt.run, .{&auth});
    var auth_joined = false;
    defer if (!auth_joined) {
        createSignalFile(io, auth_release_path) catch {};
        auth_thread.join();
    };

    try waitForPath(io, auth_started_path, 5_000);
    const auth_lock_available = server.auth_lock.tryLock();
    if (auth_lock_available) server.auth_lock.unlock(io);
    const catalog_lock_available = runtime.catalog_mutex.tryLock(io);
    if (catalog_lock_available) runtime.catalog_mutex.unlock(io);
    try createSignalFile(io, auth_release_path);
    auth_thread.join();
    auth_joined = true;

    if (!auth_lock_available) return error.InteractiveAuthHeldAuthLock;
    if (!catalog_lock_available) return error.InteractiveAuthHeldCatalogLock;
    if (auth.err) |err| {
        if (err != error.McpAuthorizationBrowserOpenFailed) return err;
    } else return error.InteractiveAuthUnexpectedlySucceeded;
    if (server.auth_credentials_present.load(.acquire)) {
        return error.InteractiveAuthCredentialsPublished;
    }

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.writeAll(
        "{\"auth_lock_available\":true,\"catalog_lock_available\":true,\"credentials_published\":false}\n",
    );
    try stdout.interface.flush();
}

fn runRuntimeInteractiveAuthRetirement(
    io: std.Io,
    alloc: Allocator,
    server_url: []const u8,
    auth_started_path: []const u8,
) !void {
    var runtime = mcp.McpRuntime.init(alloc);
    defer runtime.deinit();
    try addInteractiveAuthServer(&runtime, alloc, server_url);
    const server = runtime.servers.items[0];
    var opener = InteractiveAuthOpener{
        .io = io,
        .started_path = auth_started_path,
    };
    var auth = InteractiveAuthAttempt{
        .runtime = &runtime,
        .opener = &opener,
        .acquire_lease = true,
    };
    const auth_thread = try std.Thread.spawn(.{}, InteractiveAuthAttempt.run, .{&auth});
    var auth_joined = false;
    defer if (!auth_joined) auth_thread.join();

    try waitForPath(io, auth_started_path, 5_000);
    const started_ms = milliTimestamp(io);
    runtime.retireAndWait();
    const elapsed_ms = milliTimestamp(io) - started_ms;
    auth_thread.join();
    auth_joined = true;

    if (auth.err) |err| {
        if (err != error.Cancelled) return err;
    } else return error.InteractiveAuthUnexpectedlySucceeded;
    if (elapsed_ms >= 1_000) return error.InteractiveAuthRetirementTimedOut;
    if (server.auth_credentials_present.load(.acquire)) {
        return error.InteractiveAuthCredentialsPublished;
    }

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print(
        "{{\"error\":\"Cancelled\",\"elapsed_ms\":{d},\"credentials_published\":false}}\n",
        .{elapsed_ms},
    );
    try stdout.interface.flush();
}

fn runRuntimeScopedRecovery(
    io: std.Io,
    alloc: Allocator,
    runtime_path: []const u8,
    fixture_path: []const u8,
    root: []const u8,
    child_mode: []const u8,
) !void {
    if (!std.mem.eql(u8, child_mode, "one_off") and
        !std.mem.eql(u8, child_mode, "persistent"))
    {
        return error.InvalidScopedRecoveryChildMode;
    }
    const marker_path = try std.fs.path.join(alloc, &.{ root, "mcp-crashed" });
    defer alloc.free(marker_path);
    const wire_log_path = try std.fs.path.join(alloc, &.{ root, "mcp-wire.jsonl" });
    defer alloc.free(wire_log_path);
    const pid_path = try std.fs.path.join(alloc, &.{ root, "mcp.pid" });
    defer alloc.free(pid_path);
    const unused_ready = try std.fs.path.join(alloc, &.{ root, "unused-ready" });
    defer alloc.free(unused_ready);
    const unused_release = try std.fs.path.join(alloc, &.{ root, "unused-release" });
    defer alloc.free(unused_release);

    var runtime = mcp.McpRuntime.init(alloc);
    defer runtime.deinit();
    try addRecoveryTestServer(
        &runtime,
        alloc,
        runtime_path,
        fixture_path,
        "fixture",
        "crash_once",
        marker_path,
        wire_log_path,
        pid_path,
        unused_ready,
        unused_release,
        "echo",
        "echo",
        "SCOPED_RECOVERY",
        2_000,
        2_000,
        1,
    );
    runtime.connectAll(.{});
    if (runtime.servers.items.len != 1 or runtime.servers.items[0].state.load(.acquire) != .ready) {
        return error.ScopedRecoveryServerDidNotConnect;
    }
    const owner_id = try std.fmt.allocPrint(alloc, "{s}-child", .{child_mode});
    defer alloc.free(owner_id);
    var captured = try runtime.snapshotAccessView(
        alloc,
        owner_id,
        "parent",
        .{},
        true,
    );
    defer captured.deinit(alloc);
    var revoked = try captured.clone(alloc);
    defer revoked.deinit(alloc);
    revoked.servers[0].connection_generation += 1;
    var provider = ScopedAuthLiveProvider{
        .io = io,
        .captured = &captured,
        .revoked = &revoked,
        .marker_path = marker_path,
    };
    const access = mcp.Access{ .scoped = .{
        .captured = &captured,
        .admission_authority_generation = mcp.authorityGeneration(captured),
        .live = .{
            .context = @ptrCast(&provider),
            .resolve_fn = ScopedAuthLiveProvider.resolve,
        },
    } };

    if (runtime.callToolByNameWithOptions(
        alloc,
        "mcp_fixture_echo",
        "{\"text\":\"crash\"}",
        1024 * 1024,
        .{ .access = access },
    )) |maybe_result| {
        if (maybe_result) |result_value| {
            var result = result_value;
            result.deinit(alloc);
        }
        return error.ScopedRecoveryUnexpectedlySucceeded;
    } else |err| {
        if (err != error.McpAuthorityChanged) return err;
    }
    if (runtime.servers.items[0].restart_attempts != 0) {
        return error.ScopedRecoveryRestarted;
    }
    if (runtime.servers.items[0].last_recovery_generation != 0) {
        return error.ScopedRecoveryRepublished;
    }

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print(
        "{{\"child_mode\":\"{s}\",\"error\":\"McpAuthorityChanged\",\"restart_attempts\":0,\"last_recovery_generation\":0,\"resolutions\":{d}}}\n",
        .{ child_mode, provider.resolutions },
    );
    try stdout.interface.flush();
}

fn markerExists(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn deterministicMrtrResponse(
    _: *anyopaque,
    alloc: Allocator,
    _: mcp.InputOrigin,
    required: mcp.InputRequired,
) anyerror![]const u8 {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        required.input_requests_json,
        .{},
    );
    defer parsed.deinit();
    if (parsed.value != .object) return error.McpInvalidInputRequired;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('{');
    var iterator = parsed.value.object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(entry.key_ptr.*, .{}, &out.writer);
        try out.writer.writeAll(":{\"action\":\"accept\",\"content\":{\"confirmed\":true}}");
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

const MrtrGuardAction = enum {
    stale_catalog,
    cancel,
    invalid_response,
    callback_failure,
    allocation_failure,
};

const MrtrGuardResponder = struct {
    runtime: *mcp.McpRuntime,
    cancel_flag: *std.atomic.Value(bool),
    action: MrtrGuardAction,

    fn respond(
        raw: *anyopaque,
        alloc: Allocator,
        _: mcp.InputOrigin,
        _: mcp.InputRequired,
    ) anyerror![]const u8 {
        const self: *MrtrGuardResponder = @ptrCast(@alignCast(raw));
        switch (self.action) {
            .stale_catalog => self.runtime.servers.items[0].catalog_generation += 1,
            .cancel => self.cancel_flag.store(true, .release),
            .invalid_response => return try alloc.dupe(
                u8,
                "{\"unrelated\":{\"action\":\"accept\",\"content\":{\"confirmed\":true}}}",
            ),
            .callback_failure => return error.MrtrFixtureCallbackFailed,
            .allocation_failure => return error.OutOfMemory,
        }
        return try alloc.dupe(
            u8,
            "{\"confirm\":{\"action\":\"accept\",\"content\":{\"confirmed\":true}}}",
        );
    }
};

fn runRuntimeMrtrGuards(
    io: std.Io,
    alloc: Allocator,
    runtime_path: []const u8,
    fixture_path: []const u8,
    root: []const u8,
) !void {
    const marker_path = try std.fs.path.join(alloc, &.{ root, "mrtr-marker" });
    defer alloc.free(marker_path);
    const wire_log_path = try std.fs.path.join(alloc, &.{ root, "mcp-wire.jsonl" });
    defer alloc.free(wire_log_path);
    const pid_path = try std.fs.path.join(alloc, &.{ root, "mcp.pid" });
    defer alloc.free(pid_path);
    const unused_ready = try std.fs.path.join(alloc, &.{ root, "unused-ready" });
    defer alloc.free(unused_ready);
    const unused_release = try std.fs.path.join(alloc, &.{ root, "unused-release" });
    defer alloc.free(unused_release);

    var runtime = mcp.McpRuntime.init(alloc);
    defer runtime.deinit();
    try addRecoveryTestServer(
        &runtime,
        alloc,
        runtime_path,
        fixture_path,
        "guard",
        "mrtr_input_required",
        marker_path,
        wire_log_path,
        pid_path,
        unused_ready,
        unused_release,
        "echo",
        "echo",
        "MRTR_GUARD",
        2_000,
        2_000,
        0,
    );
    runtime.connectAll(.{});
    if (runtime.servers.items.len != 1 or runtime.servers.items[0].state.load(.acquire) != .ready) {
        return error.MrtrGuardServerDidNotConnect;
    }

    var cancel_flag = std.atomic.Value(bool).init(false);
    const cases = [_]struct {
        action: MrtrGuardAction,
        expected_error: anyerror,
    }{
        .{ .action = .stale_catalog, .expected_error = error.McpToolCatalogChanged },
        .{ .action = .cancel, .expected_error = error.Cancelled },
        .{ .action = .invalid_response, .expected_error = error.McpInvalidInputResponses },
        .{ .action = .callback_failure, .expected_error = error.MrtrFixtureCallbackFailed },
        .{ .action = .allocation_failure, .expected_error = error.OutOfMemory },
    };
    for (cases, 1..) |case, expected_call_count| {
        cancel_flag.store(false, .release);
        const catalog_generation = runtime.servers.items[0].catalog_generation;
        var responder = MrtrGuardResponder{
            .runtime = &runtime,
            .cancel_flag = &cancel_flag,
            .action = case.action,
        };
        if (runtime.callToolByNameWithOptions(
            alloc,
            "mcp_guard_echo",
            "{\"text\":\"guard\"}",
            1024 * 1024,
            .{
                .cancel_flag = &cancel_flag,
                .input_responder = .{
                    .context = @ptrCast(&responder),
                    .callback = MrtrGuardResponder.respond,
                },
            },
        )) |optional_result| {
            if (optional_result) |value| {
                var result = value;
                result.deinit(alloc);
            }
            return error.MrtrGuardUnexpectedSuccess;
        } else |err| {
            if (err != case.expected_error) return err;
        }
        runtime.servers.items[0].catalog_generation = catalog_generation;
        const actual_call_count = try countWireMethod(io, alloc, wire_log_path, "tools/call");
        if (actual_call_count != expected_call_count) return error.MrtrGuardWroteContinuation;
    }

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.writeAll(
        "{\"mrtr_guards\":true,\"initial_calls\":5,\"continuation_calls\":0}\n",
    );
    try stdout.interface.flush();
}

fn countWireMethod(
    io: std.Io,
    alloc: Allocator,
    path: []const u8,
    method: []const u8,
) !usize {
    const contents = try std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io,
        path,
        alloc,
        .limited(1024 * 1024),
    );
    defer alloc.free(contents);
    const needle = try std.fmt.allocPrint(alloc, "\"method\":\"{s}\"", .{method});
    defer alloc.free(needle);
    return std.mem.count(u8, contents, needle);
}

fn runRuntimeRecovery(
    io: std.Io,
    alloc: Allocator,
    runtime_path: []const u8,
    fixture_path: []const u8,
    root: []const u8,
) !void {
    const marker_path = try std.fs.path.join(alloc, &.{ root, "blocked-write-marker" });
    defer alloc.free(marker_path);
    const wire_log_path = try std.fs.path.join(alloc, &.{ root, "mcp-wire.jsonl" });
    defer alloc.free(wire_log_path);
    const pid_path = try std.fs.path.join(alloc, &.{ root, "mcp.pid" });
    defer alloc.free(pid_path);

    const config_args = try alloc.alloc([]const u8, 1);
    config_args[0] = try alloc.dupe(u8, fixture_path);
    const config_env = try alloc.alloc(mcp.McpEnvVar, 5);
    config_env[0] = .{
        .key = try alloc.dupe(u8, "FX_MCP_MODE"),
        .value = try alloc.dupe(u8, "block_operation_write_once"),
    };
    config_env[1] = .{
        .key = try alloc.dupe(u8, "FX_MCP_CRASH_MARKER"),
        .value = try alloc.dupe(u8, marker_path),
    };
    config_env[2] = .{
        .key = try alloc.dupe(u8, "FX_MCP_WIRE_LOG"),
        .value = try alloc.dupe(u8, wire_log_path),
    };
    config_env[3] = .{
        .key = try alloc.dupe(u8, "FX_MCP_PID_PATH"),
        .value = try alloc.dupe(u8, pid_path),
    };

    config_env[4] = .{
        .key = try alloc.dupe(u8, "FX_MCP_PROTOCOL_VERSION"),
        .value = try alloc.dupe(u8, "2026-07-28"),
    };

    var runtime = mcp.McpRuntime.init(alloc);
    var runtime_active = true;
    defer if (runtime_active) runtime.deinit();
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, "fixture"),
        .command = try alloc.dupe(u8, runtime_path),
        .args = config_args,
        .env = config_env,
        .operation_timeout_ms = 2_000,
        .restart_limit = 1,
    });
    runtime.connectAll(.{});

    const timeout_elapsed_ms = try breakDispatcherWithBlockedWrite(
        io,
        alloc,
        runtime.servers.items[0].dispatcher orelse
            return error.MissingRuntimeDispatcher,
    );

    var recovered = (try runtime.callToolByName(
        alloc,
        "mcp_fixture_echo",
        "{\"text\":\"second\"}",
        1024 * 1024,
    )) orelse return error.MissingRecoveredTool;
    defer recovered.deinit(alloc);
    if (std.mem.find(u8, recovered.model_output, "MODERN_MCP_TOOL_RESULT:second") == null) {
        return error.RecoveredToolReturnedWrongResult;
    }

    runtime.deinit();
    runtime_active = false;

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print(
        "{{\"timeout_elapsed_ms\":{d},\"recovered\":true,\"reader_joined\":true}}\n",
        .{timeout_elapsed_ms},
    );
    try stdout.interface.flush();
}

fn runRuntimeRecoveryBudget(
    io: std.Io,
    alloc: Allocator,
    runtime_path: []const u8,
    fixture_path: []const u8,
    root: []const u8,
) !void {
    const marker_path = try std.fs.path.join(alloc, &.{ root, "recovery-budget-marker" });
    defer alloc.free(marker_path);
    const wire_log_path = try std.fs.path.join(alloc, &.{ root, "mcp-wire.jsonl" });
    defer alloc.free(wire_log_path);
    const pid_path = try std.fs.path.join(alloc, &.{ root, "mcp.pid" });
    defer alloc.free(pid_path);

    var runtime = mcp.McpRuntime.init(alloc);
    var runtime_active = true;
    defer if (runtime_active) runtime.deinit();
    try addRecoveryTestServer(
        &runtime,
        alloc,
        runtime_path,
        fixture_path,
        "fixture",
        "crash_then_fail_recovery_once",
        marker_path,
        wire_log_path,
        pid_path,
        "",
        "",
        "echo",
        "echo",
        "RECOVERY_BUDGET",
        1_000,
        3_000,
        2,
    );
    runtime.connectAll(.{});

    if (runtime.callToolByName(
        alloc,
        "mcp_fixture_echo",
        "{\"text\":\"first\"}",
        1024 * 1024,
    ) catch null) |response_value| {
        var response = response_value;
        response.deinit(alloc);
        return error.ExpectedInitialRecoveryFailure;
    }
    if (runtime.servers.items[0].restart_attempts != 1 or
        runtime.servers.items[0].tool_catalog.tools.items.len != 1 or
        !runtime.hasTool("mcp_fixture_echo"))
    {
        return error.RecoveryRouteWasNotRetained;
    }

    var recovered = (try runtime.callToolByName(
        alloc,
        "mcp_fixture_echo",
        "{\"text\":\"second\"}",
        1024 * 1024,
    )) orelse return error.MissingSecondRecoveryResult;
    defer recovered.deinit(alloc);
    if (std.mem.find(u8, recovered.model_output, "RECOVERY_BUDGET:second") == null) {
        return error.SecondRecoveryReturnedWrongResult;
    }
    if (runtime.servers.items[0].restart_attempts != 2) {
        return error.RemainingRecoveryBudgetWasNotSpent;
    }

    runtime.deinit();
    runtime_active = false;

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print(
        "{{\"restart_attempts\":2,\"second_recovery_succeeded\":true,\"reader_joined\":true}}\n",
        .{},
    );
    try stdout.interface.flush();
}

fn runRuntimeStaleRecovery(
    io: std.Io,
    alloc: Allocator,
    runtime_path: []const u8,
    fixture_path: []const u8,
    root: []const u8,
) !void {
    const marker_path = try std.fs.path.join(alloc, &.{ root, "stale-recovery-marker" });
    defer alloc.free(marker_path);
    const wire_log_path = try std.fs.path.join(alloc, &.{ root, "mcp-wire.jsonl" });
    defer alloc.free(wire_log_path);
    const pid_path = try std.fs.path.join(alloc, &.{ root, "mcp.pid" });
    defer alloc.free(pid_path);
    const ready_path = try std.fs.path.join(alloc, &.{ root, "recovery-ready" });
    defer alloc.free(ready_path);
    const release_path = try std.fs.path.join(alloc, &.{ root, "recovery-release" });
    defer alloc.free(release_path);

    var runtime = mcp.McpRuntime.init(alloc);
    var runtime_active = true;
    defer if (runtime_active) runtime.deinit();
    try addRecoveryTestServer(
        &runtime,
        alloc,
        runtime_path,
        fixture_path,
        "fixture",
        "crash_once_new_tool",
        marker_path,
        wire_log_path,
        pid_path,
        ready_path,
        release_path,
        "old",
        "new",
        "STALE_RECOVERY",
        1_000,
        3_000,
        1,
    );
    runtime.connectAll(.{});

    var barrier = SnapshotBarrierAllocator{
        .io = io,
        .base = alloc,
        .target_allocation = 3,
    };
    var queued = RuntimeCall{
        .io = io,
        .runtime = &runtime,
        .tool_name = "mcp_fixture_old",
        .arguments_json = "{\"text\":\"queued\"}",
        .alloc = barrier.allocator(),
    };
    const queued_thread = try std.Thread.spawn(.{}, RuntimeCall.run, .{&queued});
    var queued_joined = false;
    defer if (!queued_joined) {
        barrier.released.store(true, .release);
        createSignalFile(io, release_path) catch {};
        queued_thread.join();
    };
    try waitForAtomicFlag(io, &barrier.waiting, 2_000);

    runtime.servers.items[0].connection_lock.lockUncancelable(io);
    var connection_locked = true;
    defer if (connection_locked) {
        runtime.servers.items[0].connection_lock.unlock(io);
    };
    try createSignalFile(io, marker_path);
    const dispatcher = runtime.servers.items[0].dispatcher orelse
        return error.MissingRuntimeDispatcher;
    dispatcher.shutdown();
    barrier.released.store(true, .release);
    runtime.catalog_mutex.lockUncancelable(io);
    runtime.catalog_mutex.unlock(io);
    runtime.servers.items[0].connection_lock.unlock(io);
    connection_locked = false;

    try waitForReadyCount(io, alloc, ready_path, 1, 2_000);
    try createSignalFile(io, release_path);

    queued_thread.join();
    queued_joined = true;
    defer if (queued.response) |response| queued.alloc.free(response);
    if (queued.err == null or
        queued.err.? != error.McpToolCatalogChanged or
        queued.response != null)
    {
        return error.StaleToolCrossedRecoveryGeneration;
    }

    if (runtime.servers.items[0].tool_catalog.tools.items.len != 1) {
        return error.MissingRecoveredTool;
    }
    const current_tool = try alloc.dupe(
        u8,
        runtime.servers.items[0].tool_catalog.tools.items[0].prefixed_name,
    );
    defer alloc.free(current_tool);
    if (!std.mem.eql(u8, current_tool, "mcp_fixture_new")) {
        return error.WrongRecoveredTool;
    }
    var recovered = (try runtime.callToolByName(
        alloc,
        current_tool,
        "{\"text\":\"fresh\"}",
        1024 * 1024,
    )) orelse return error.MissingRecoveredToolResult;
    defer recovered.deinit(alloc);
    if (std.mem.find(u8, recovered.model_output, "STALE_RECOVERY:fresh") == null) {
        return error.RecoveredToolReturnedWrongResult;
    }
    const recovered_subscription = runtime.servers.items[0].tool_subscription orelse
        return error.MissingRecoveredSubscription;
    if (recovered_subscription.startupState() != .committed) {
        return error.RecoveredSubscriptionNotCommitted;
    }
    const listen_count = try countWireMethod(
        io,
        alloc,
        wire_log_path,
        "subscriptions/listen",
    );
    if (listen_count != 2) return error.RecoveredSubscriptionNotCommitted;
    const recovered_dispatcher = runtime.servers.items[0].dispatcher orelse
        return error.MissingRuntimeDispatcher;
    const pending_before_shutdown = recovered_dispatcher.pendingRequestCount();
    if (pending_before_shutdown != 1) return error.UnexpectedPendingRequestCount;

    runtime.deinit();
    runtime_active = false;

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print(
        "{{\"current_tool\":\"{s}\",\"queued_unavailable\":true,\"subscription_committed\":true,\"pending_before_shutdown\":{d},\"reader_joined\":true}}\n",
        .{ current_tool, pending_before_shutdown },
    );
    try stdout.interface.flush();
}

fn runRuntimeCatalogControl(
    io: std.Io,
    alloc: Allocator,
    runtime_path: []const u8,
    fixture_path: []const u8,
    root: []const u8,
    control: []const u8,
) !void {
    const marker_path = try std.fs.path.join(alloc, &.{ root, "catalog-marker" });
    defer alloc.free(marker_path);
    const wire_log_path = try std.fs.path.join(alloc, &.{ root, "mcp-wire.jsonl" });
    defer alloc.free(wire_log_path);
    const pid_path = try std.fs.path.join(alloc, &.{ root, "mcp.pid" });
    defer alloc.free(pid_path);

    const cancel_control = std.mem.eql(u8, control, "cancel");
    if (!cancel_control and !std.mem.eql(u8, control, "timeout")) {
        return error.ExpectedCatalogControl;
    }

    var runtime = mcp.McpRuntime.init(alloc);
    var runtime_active = true;
    defer if (runtime_active) runtime.deinit();
    try addRecoveryTestServer(
        &runtime,
        alloc,
        runtime_path,
        fixture_path,
        "fixture",
        "normal",
        marker_path,
        wire_log_path,
        pid_path,
        "",
        "",
        "echo",
        "echo",
        "CATALOG_CONTROL",
        1_000,
        if (cancel_control) 2_000 else 100,
        1,
    );
    runtime.connectAll(.{});

    var cancel = std.atomic.Value(bool).init(false);
    var call = RuntimeCall{
        .io = io,
        .runtime = &runtime,
        .tool_name = "mcp_fixture_echo",
        .arguments_json = "{\"text\":\"control\"}",
        .cancel_flag = if (cancel_control) &cancel else null,
    };

    runtime.catalog_mutex.lockUncancelable(io);
    var catalog_locked = true;
    defer if (catalog_locked) runtime.catalog_mutex.unlock(io);
    const call_thread = try std.Thread.spawn(.{}, RuntimeCall.run, .{&call});
    while (!call.started.load(.acquire)) sleep(io, std.time.ns_per_ms);
    if (cancel_control) {
        sleep(io, 25 * std.time.ns_per_ms);
        cancel.store(true, .release);
    }
    const finish_deadline = milliTimestamp(io) + 750;
    while (!call.finished.load(.acquire) and milliTimestamp(io) < finish_deadline) {
        sleep(io, 5 * std.time.ns_per_ms);
    }
    const finished_while_locked = call.finished.load(.acquire);
    runtime.catalog_mutex.unlock(io);
    catalog_locked = false;
    call_thread.join();
    defer if (call.response) |response| alloc.free(response);

    if (!finished_while_locked) return error.CatalogControlWasLate;
    const expected_error: anyerror = if (cancel_control)
        error.Cancelled
    else
        error.McpRequestTimedOut;
    if (call.err == null or call.err.? != expected_error) {
        return error.WrongCatalogControlError;
    }
    if (call.elapsed_ms >= 750) return error.CatalogControlWasLate;

    runtime.deinit();
    runtime_active = false;

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print(
        "{{\"control\":\"{s}\",\"elapsed_ms\":{d},\"finished_while_locked\":true,\"reader_joined\":true}}\n",
        .{ control, call.elapsed_ms },
    );
    try stdout.interface.flush();
}

fn runRuntimeRecoveryControl(
    io: std.Io,
    alloc: Allocator,
    runtime_path: []const u8,
    fixture_path: []const u8,
    root: []const u8,
    control: []const u8,
) !void {
    const marker_path = try std.fs.path.join(alloc, &.{ root, "blocked-write-marker" });
    defer alloc.free(marker_path);
    const wire_log_path = try std.fs.path.join(alloc, &.{ root, "mcp-wire.jsonl" });
    defer alloc.free(wire_log_path);
    const pid_path = try std.fs.path.join(alloc, &.{ root, "mcp.pid" });
    defer alloc.free(pid_path);
    const ready_path = try std.fs.path.join(alloc, &.{ root, "recovery-ready" });
    defer alloc.free(ready_path);

    var runtime = mcp.McpRuntime.init(alloc);
    var runtime_active = true;
    defer if (runtime_active) runtime.deinit();
    try addRecoveryTestServer(
        &runtime,
        alloc,
        runtime_path,
        fixture_path,
        "fixture",
        "block_then_stall_recovery",
        marker_path,
        wire_log_path,
        pid_path,
        ready_path,
        "",
        "echo",
        "echo",
        "RECOVERY_CONTROL",
        2_000,
        2_000,
        1,
    );
    runtime.connectAll(.{});
    if (runtime.servers.items[0].state.load(.acquire) != .ready) {
        return error.RuntimeRecoveryControlServerDidNotConnect;
    }
    runtime.servers.items[0].config.startup_timeout_ms = if (std.mem.eql(u8, control, "cancel"))
        2_000
    else
        500;
    _ = try breakDispatcherWithBlockedWrite(
        io,
        alloc,
        runtime.servers.items[0].dispatcher orelse
            return error.MissingRuntimeDispatcher,
    );

    var cancel = std.atomic.Value(bool).init(false);
    var call = RuntimeCall{
        .io = io,
        .runtime = &runtime,
        .tool_name = "mcp_fixture_echo",
        .arguments_json = "{\"text\":\"control\"}",
        .cancel_flag = if (std.mem.eql(u8, control, "cancel")) &cancel else null,
    };
    const call_thread = try std.Thread.spawn(.{}, RuntimeCall.run, .{&call});
    var call_joined = false;
    defer if (!call_joined) {
        cancel.store(true, .release);
        call_thread.join();
    };
    while (!call.started.load(.acquire)) sleep(io, std.time.ns_per_ms);
    var control_started_ms: ?i64 = null;
    if (std.mem.eql(u8, control, "cancel")) {
        try waitForPath(io, ready_path, 5_000);
        control_started_ms = milliTimestamp(io);
        cancel.store(true, .release);
    } else if (!std.mem.eql(u8, control, "timeout")) {
        return error.ExpectedRecoveryControl;
    }
    call_thread.join();
    call_joined = true;
    defer if (call.response) |response| alloc.free(response);

    const expected_error: anyerror = if (std.mem.eql(u8, control, "cancel"))
        error.Cancelled
    else
        error.McpRequestTimedOut;
    if (call.err == null or call.err.? != expected_error) {
        return error.WrongRecoveryControlError;
    }
    const control_elapsed_ms = if (control_started_ms) |started_ms|
        milliTimestamp(io) - started_ms
    else
        call.elapsed_ms;
    const control_deadline_ms: i64 = if (std.mem.eql(u8, control, "cancel")) 750 else 1_500;
    if (control_elapsed_ms >= control_deadline_ms) return error.RecoveryControlWasLate;

    runtime.deinit();
    runtime_active = false;

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print(
        "{{\"control\":\"{s}\",\"elapsed_ms\":{d},\"reader_joined\":true}}\n",
        .{ control, control_elapsed_ms },
    );
    try stdout.interface.flush();
}

fn runRuntimeRecoveryCollision(
    io: std.Io,
    alloc: Allocator,
    runtime_path: []const u8,
    fixture_path: []const u8,
    root: []const u8,
) !void {
    const wire_log_path = try std.fs.path.join(alloc, &.{ root, "mcp-wire.jsonl" });
    defer alloc.free(wire_log_path);
    const first_marker = try std.fs.path.join(alloc, &.{ root, "first-marker" });
    defer alloc.free(first_marker);
    const second_marker = try std.fs.path.join(alloc, &.{ root, "second-marker" });
    defer alloc.free(second_marker);
    const first_pid = try std.fs.path.join(alloc, &.{ root, "first.pid" });
    defer alloc.free(first_pid);
    const second_pid = try std.fs.path.join(alloc, &.{ root, "second.pid" });
    defer alloc.free(second_pid);
    const recovery_ready = try std.fs.path.join(alloc, &.{ root, "recovery-ready" });
    defer alloc.free(recovery_ready);
    const recovery_release = try std.fs.path.join(alloc, &.{ root, "recovery-release" });
    defer alloc.free(recovery_release);

    var runtime = mcp.McpRuntime.init(alloc);
    var runtime_active = true;
    defer if (runtime_active) runtime.deinit();
    try addRecoveryTestServer(
        &runtime,
        alloc,
        runtime_path,
        fixture_path,
        "a b",
        "crash_once_new_tool",
        first_marker,
        wire_log_path,
        first_pid,
        recovery_ready,
        recovery_release,
        "first",
        "echo",
        "FIRST",
        1_000,
        3_000,
        1,
    );
    try addRecoveryTestServer(
        &runtime,
        alloc,
        runtime_path,
        fixture_path,
        "a/b",
        "crash_once_new_tool",
        second_marker,
        wire_log_path,
        second_pid,
        recovery_ready,
        recovery_release,
        "second",
        "echo",
        "SECOND",
        1_000,
        3_000,
        1,
    );
    runtime.connectAll(.{});

    var first_call = RuntimeCall{
        .io = io,
        .runtime = &runtime,
        .tool_name = "mcp_a_b_first",
        .arguments_json = "{\"text\":\"crash\"}",
    };
    var second_call = RuntimeCall{
        .io = io,
        .runtime = &runtime,
        .tool_name = "mcp_a_b_second",
        .arguments_json = "{\"text\":\"crash\"}",
    };
    const first_thread = try std.Thread.spawn(.{}, RuntimeCall.run, .{&first_call});
    const second_thread = try std.Thread.spawn(.{}, RuntimeCall.run, .{&second_call});
    waitForReadyCount(io, alloc, recovery_ready, 2, 2_000) catch |err| {
        try createSignalFile(io, recovery_release);
        first_thread.join();
        second_thread.join();
        return err;
    };
    const ready_before_release = try readyCount(io, alloc, recovery_ready);
    try createSignalFile(io, recovery_release);
    first_thread.join();
    second_thread.join();
    defer if (first_call.response) |response| alloc.free(response);
    defer if (second_call.response) |response| alloc.free(response);
    if (first_call.err == null or second_call.err == null) {
        return error.MissingRecoveryTriggerError;
    }
    if (ready_before_release != 2) return error.UnrelatedRecoveryWasBlocked;
    const ready_after_release = try readyCount(io, alloc, recovery_ready);
    if (ready_after_release != 2) return error.MissingSecondRecovery;

    const first_tool = try alloc.dupe(u8, runtime.servers.items[0].tool_catalog.tools.items[0].prefixed_name);
    defer alloc.free(first_tool);
    const second_tool = try alloc.dupe(u8, runtime.servers.items[1].tool_catalog.tools.items[0].prefixed_name);
    defer alloc.free(second_tool);
    if (std.mem.eql(u8, first_tool, second_tool)) return error.DuplicateRecoveredToolName;

    var first_result = (try runtime.callToolByName(
        alloc,
        first_tool,
        "{\"text\":\"one\"}",
        1024 * 1024,
    )) orelse return error.MissingFirstRecoveredTool;
    defer first_result.deinit(alloc);
    if (std.mem.find(u8, first_result.model_output, "FIRST:one") == null) {
        return error.FirstRecoveredToolMisrouted;
    }
    var second_result = (try runtime.callToolByName(
        alloc,
        second_tool,
        "{\"text\":\"two\"}",
        1024 * 1024,
    )) orelse return error.MissingSecondRecoveredTool;
    defer second_result.deinit(alloc);
    if (std.mem.find(u8, second_result.model_output, "SECOND:two") == null) {
        return error.SecondRecoveredToolMisrouted;
    }

    runtime.deinit();
    runtime_active = false;

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print(
        "{{\"first_tool\":\"{s}\",\"second_tool\":\"{s}\",\"ready_before_release\":{d},\"ready_after_release\":{d},\"reader_joined\":true}}\n",
        .{ first_tool, second_tool, ready_before_release, ready_after_release },
    );
    try stdout.interface.flush();
}

fn addRecoveryTestServer(
    runtime: *mcp.McpRuntime,
    alloc: Allocator,
    runtime_path: []const u8,
    fixture_path: []const u8,
    name: []const u8,
    mode: []const u8,
    marker_path: []const u8,
    wire_log_path: []const u8,
    pid_path: []const u8,
    ready_path: []const u8,
    release_path: []const u8,
    initial_tool_name: []const u8,
    recovered_tool_name: []const u8,
    result_text: []const u8,
    startup_timeout_ms: u32,
    operation_timeout_ms: u32,
    restart_limit: u8,
) !void {
    const config_args = try alloc.alloc([]const u8, 1);
    config_args[0] = try alloc.dupe(u8, fixture_path);
    const config_env = try alloc.alloc(mcp.McpEnvVar, 10);
    const entries = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "FX_MCP_PROTOCOL_VERSION", .value = "2026-07-28" },
        .{ .key = "FX_MCP_MODE", .value = mode },
        .{ .key = "FX_MCP_CRASH_MARKER", .value = marker_path },
        .{ .key = "FX_MCP_WIRE_LOG", .value = wire_log_path },
        .{ .key = "FX_MCP_PID_PATH", .value = pid_path },
        .{ .key = "FX_MCP_RECOVERY_READY_PATH", .value = ready_path },
        .{ .key = "FX_MCP_RECOVERY_RELEASE_PATH", .value = release_path },
        .{ .key = "FX_MCP_INITIAL_TOOL_NAME", .value = initial_tool_name },
        .{ .key = "FX_MCP_RECOVERED_TOOL_NAME", .value = recovered_tool_name },
        .{ .key = "FX_MCP_RESULT_TEXT", .value = result_text },
    };
    for (entries, 0..) |entry, index| {
        config_env[index] = .{
            .key = try alloc.dupe(u8, entry.key),
            .value = try alloc.dupe(u8, entry.value),
        };
    }
    try runtime.addServer(.{
        .name = try alloc.dupe(u8, name),
        .command = try alloc.dupe(u8, runtime_path),
        .args = config_args,
        .env = config_env,
        .startup_timeout_ms = startup_timeout_ms,
        .operation_timeout_ms = operation_timeout_ms,
        .restart_limit = restart_limit,
    });
}

fn breakDispatcherWithBlockedWrite(
    io: std.Io,
    alloc: Allocator,
    dispatcher: *mcp.StdioDispatcher,
) !i64 {
    const request_id = try dispatcher.reserveRequestId();
    const blocked_body = try alloc.alloc(u8, 8 * 1024 * 1024);
    defer alloc.free(blocked_body);
    @memset(blocked_body, 'x');
    const started_ms = milliTimestamp(io);
    if (dispatcher.request(
        alloc,
        request_id,
        blocked_body,
        4096,
        .{ .timeout_ms = 500 },
    )) |response| {
        alloc.free(response);
        return error.MissingWriteTimeout;
    } else |err| {
        if (err != error.McpRequestTimedOut) return err;
    }
    const elapsed_ms = milliTimestamp(io) - started_ms;
    if (elapsed_ms >= 1_500) return error.BlockedWriteTimeoutWasLate;
    if (dispatcher.isRunning()) return error.BlockedWriteDidNotTaintConnection;
    return elapsed_ms;
}

fn readyCount(io: std.Io, alloc: Allocator, path: []const u8) !usize {
    const contents = std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io,
        path,
        alloc,
        .limited(4096),
    ) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer alloc.free(contents);

    var count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines.next()) |_| count += 1;
    return count;
}

fn waitForReadyCount(
    io: std.Io,
    alloc: Allocator,
    path: []const u8,
    expected: usize,
    timeout_ms: i64,
) !void {
    const deadline_ms = milliTimestamp(io) + timeout_ms;
    while (milliTimestamp(io) < deadline_ms) {
        if (try readyCount(io, alloc, path) >= expected) return;
        sleep(io, 5 * std.time.ns_per_ms);
    }
    return error.RecoveryBarrierTimedOut;
}

fn waitForAtomicFlag(
    io: std.Io,
    flag: *std.atomic.Value(bool),
    timeout_ms: i64,
) !void {
    const deadline_ms = milliTimestamp(io) + timeout_ms;
    while (milliTimestamp(io) < deadline_ms) {
        if (flag.load(.acquire)) return;
        sleep(io, std.time.ns_per_ms);
    }
    return error.AtomicBarrierTimedOut;
}

fn createSignalFile(io: std.Io, path: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, "release");
}

fn waitForPath(io: std.Io, path: []const u8, timeout_ms: i64) !void {
    const deadline_ms = milliTimestamp(io) + timeout_ms;
    while (milliTimestamp(io) < deadline_ms) {
        var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
            sleep(io, 5 * std.time.ns_per_ms);
            continue;
        };
        file.close(io);
        return;
    }
    return error.RecoveryDidNotStart;
}

fn waitForPathMissing(io: std.Io, path: []const u8, timeout_ms: i64) bool {
    const deadline_ms = milliTimestamp(io) + timeout_ms;
    while (milliTimestamp(io) < deadline_ms) {
        var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return true;
        file.close(io);
        sleep(io, 5 * std.time.ns_per_ms);
    }
    return false;
}

const BlockedWrite = struct {
    io: std.Io,
    dispatcher: *mcp.StdioDispatcher,
    body: []const u8,
    started: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    elapsed_ms: i64 = 0,
    err: ?anyerror = null,

    fn run(self: *BlockedWrite) void {
        const request_id = self.dispatcher.reserveRequestId() catch |err| {
            self.err = err;
            self.done.store(true, .release);
            return;
        };
        const started_ms = milliTimestamp(self.io);
        self.started.store(true, .release);
        const response = self.dispatcher.request(
            std.heap.c_allocator,
            request_id,
            self.body,
            4096,
            .{ .timeout_ms = 50 },
        ) catch |err| {
            self.err = err;
            self.elapsed_ms = milliTimestamp(self.io) - started_ms;
            self.done.store(true, .release);
            return;
        };
        std.heap.c_allocator.free(response);
        self.elapsed_ms = milliTimestamp(self.io) - started_ms;
        self.done.store(true, .release);
    }
};

fn runBlockedWrite(
    io: std.Io,
    alloc: Allocator,
    runtime: []const u8,
    fixture: []const u8,
) !void {
    const child = try std.process.spawn(io, .{
        .argv = &.{ runtime, fixture },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
        .pgid = if (@import("builtin").os.tag == .windows) null else 0,
    });
    const child_id = child.id.?;
    const dispatcher = try mcp.StdioDispatcher.create(
        alloc,
        std.heap.c_allocator,
        child,
        1,
        4096,
    );
    defer dispatcher.deinit();

    const body = try alloc.alloc(u8, 8 * 1024 * 1024);
    defer alloc.free(body);
    @memset(body, 'x');

    var blocked = BlockedWrite{ .io = io, .dispatcher = dispatcher, .body = body };
    const request_thread = try std.Thread.spawn(.{}, BlockedWrite.run, .{&blocked});
    while (!blocked.started.load(.acquire)) sleep(io, std.time.ns_per_ms);

    const watchdog_deadline = milliTimestamp(io) + 1_000;
    while (!blocked.done.load(.acquire) and milliTimestamp(io) < watchdog_deadline) {
        sleep(io, 5 * std.time.ns_per_ms);
    }
    const exceeded_deadline = !blocked.done.load(.acquire);
    if (exceeded_deadline) {
        if (@import("builtin").os.tag == .windows) {
            return error.SkipZigTest;
        }
        std.posix.kill(-child_id, .KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => return err,
        };
    }
    request_thread.join();
    dispatcher.shutdown();

    if (exceeded_deadline) return error.BlockedWriteExceededTimeout;
    if (blocked.err) |err| {
        if (err != error.McpRequestTimedOut) return err;
    } else {
        return error.MissingWriteTimeout;
    }
    if (blocked.elapsed_ms >= 500) return error.BlockedWriteTimeoutWasLate;

    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout.interface.print(
        "{{\"child_pid\":{any},\"elapsed_ms\":{d},\"reader_joined\":true}}\n",
        .{ child_id, blocked.elapsed_ms },
    );
    try stdout.interface.flush();
}

fn milliTimestamp(io: std.Io) i64 {
    const timestamp = std.Io.Timestamp.now(io, .real);
    return @intCast(@divFloor(timestamp.nanoseconds, std.time.ns_per_ms));
}

fn sleep(io: std.Io, ns: u64) void {
    io.sleep(.{ .nanoseconds = @intCast(ns) }, .real) catch {};
}

fn validateWorker(alloc: Allocator, worker: *const Worker) !void {
    if (worker.err) |err| return err;
    const response = worker.response orelse return error.MissingResponse;
    defer alloc.free(response);
    var expected_buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "\"owner\":\"{s}\"",
        .{worker.owner},
    );
    if (std.mem.find(u8, response, expected) == null) {
        return error.ResponseCrossedRequests;
    }
    if (!worker.progress_owner_matched) return error.ProgressCrossedRequests;
}
