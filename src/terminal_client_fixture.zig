const std = @import("std");
const builtin = @import("builtin");
const background_process = @import("tools/shell/background_process.zig");
const background_process_provider = @import("core/execution/background_process_provider.zig");
const process_supervisor = @import("core/background/process_supervisor.zig");
const client = @import("core/terminal/client.zig");
const contracts = @import("core/terminal/contracts.zig");
const debug_trace = @import("core/shared/debug_trace.zig");
const host = @import("core/terminal/host.zig");
const io_mod = @import("core/shared/io.zig");
const operation = @import("core/terminal/operation.zig");
const policy = @import("core/terminal/host_policy.zig");
const profile_paths = @import("core/shared/profile_paths.zig");
const command_runner = @import("core/execution/command_runner.zig");
const session_child_store = @import("core/session/session_child_store.zig");
const store = @import("core/terminal/store.zig");
const native_session = @import("core/terminal/native_session.zig");

const Allocator = std.mem.Allocator;
const process_allocator = if (builtin.link_libc)
    std.heap.c_allocator
else
    std.heap.page_allocator;
const fixture_owner_session_id = "terminal-fixture-owner";
const fixture_profile_user = "terminal-fixture-profile";
const protocol_fixture_profile_user = "terminal-fixture";
const fixture_marker = "authority-reload-ready";
const fixture_observation_timeout_ms = 120_000;

comptime {
    @export(&main, .{ .name = "main" });
}

pub fn main(
    argc: c_int,
    argv: [*][*:0]c_char,
    environ: [*:null]?[*:0]c_char,
) callconv(.c) c_int {
    mainInner(argc, argv, environ) catch return 1;
    return 0;
}

fn mainInner(
    argc: c_int,
    argv: [*][*:0]c_char,
    environ: [*:null]?[*:0]c_char,
) !void {
    const args: []const [*:0]const u8 = @as(
        [*][*:0]const u8,
        @ptrCast(argv),
    )[0..@intCast(argc)];
    const raw_environ: io_mod.RawEnviron = @ptrCast(environ);
    io_mod.setRawEnviron(raw_environ);
    var environment_count: usize = 0;
    while (raw_environ[environment_count] != null) : (environment_count += 1) {}
    var threaded = std.Io.Threaded.init(process_allocator, .{
        .argv0 = .init(.{ .vector = args }),
        .environ = .{ .block = .{
            .slice = raw_environ[0..environment_count :null],
        } },
    });
    defer threaded.deinit();
    io_mod.setIo(threaded.io());
    defer debug_trace.shutdown();
    debug_trace.configureFromEnv(process_allocator, ".");
    if (native_session.isControlModeRaw(args)) {
        return native_session.runControlMarker(args);
    }
    if (native_session.isLauncherModeRaw(args)) {
        return native_session.runLauncher(process_allocator);
    }
    if (host.isInternalModeRaw(args)) {
        var failure_provider = CaptureFailureProvider{
            .delegate = background_process.provider,
        };
        const provider = if (io_mod.getenv(
            "FX_TERMINAL_FIXTURE_FAIL_PROCESS_TOKEN",
        ) != null)
            failure_provider.provider()
        else
            background_process.provider;
        return host.run(
            process_allocator,
            try host.Config.fromEnvironment(provider),
        );
    }
    var cli_arg_buffer: [64][:0]const u8 = undefined;
    if (args.len - 1 > cli_arg_buffer.len) return error.TooManyArguments;
    for (args[1..], 0..) |arg, index| {
        cli_arg_buffer[index] = std.mem.sliceTo(arg, 0);
    }
    const cli_args = cli_arg_buffer[0 .. args.len - 1];
    if (command_runner.isForegroundSessionInvocation(cli_args)) {
        return command_runner.runForegroundSessionBootstrap(cli_args);
    }
    try runFixture(process_allocator, background_process.provider);
}

const CaptureFailureProvider = struct {
    delegate: background_process_provider.Provider,
    captures: usize = 0,

    fn provider(self: *@This()) background_process_provider.Provider {
        return .{
            .context = self,
            .spawn_prepared_fn = spawnPrepared,
            .capture_token_fn = captureToken,
            .match_token_fn = matchToken,
            .signal_process_fn = signalProcess,
        };
    }

    fn from(raw: ?*anyopaque) *@This() {
        return @ptrCast(@alignCast(raw.?));
    }

    fn spawnPrepared(
        raw: ?*anyopaque,
        alloc: Allocator,
        request: background_process_provider.SpawnRequest,
    ) background_process_provider.ProviderError!background_process_provider.PreparedProcess {
        return from(raw).delegate.spawnPrepared(alloc, request);
    }

    fn captureToken(
        raw: ?*anyopaque,
        alloc: Allocator,
        pid: []const u8,
    ) background_process_provider.ProviderError!process_supervisor.ProcessInstanceToken {
        const self = from(raw);
        self.captures += 1;
        if (self.captures > 2) return error.ProcessIdentityUnavailable;
        return self.delegate.captureToken(alloc, pid);
    }

    fn matchToken(
        raw: ?*anyopaque,
        alloc: Allocator,
        pid: []const u8,
        expected: process_supervisor.ProcessInstanceToken,
    ) process_supervisor.TokenMatch {
        return from(raw).delegate.matchToken(alloc, pid, expected);
    }

    fn signalProcess(
        raw: ?*anyopaque,
        alloc: Allocator,
        pid: []const u8,
        expected: process_supervisor.ProcessInstanceToken,
    ) background_process_provider.ProviderError!void {
        return from(raw).delegate.signalProcess(alloc, pid, expected);
    }
};

fn runFixture(
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
) !void {
    if (io_mod.getenv("FX_TERMINAL_CAPABILITY_FIXTURE")) |mode| {
        if (std.mem.eql(u8, mode, "start")) {
            return runCapabilityStartFixture(alloc, process_provider);
        }
        if (std.mem.eql(u8, mode, "force_close")) {
            return runCapabilityForceCloseFixture(alloc, process_provider);
        }
        return error.InvalidTerminalCapabilityFixtureMode;
    }
    if (io_mod.getenv("FX_TERMINAL_OUTCOME_FIXTURE")) |mode| {
        if (std.mem.eql(u8, mode, "ordering")) {
            return runOutcomeOrderingFixture(alloc, process_provider);
        }
        if (std.mem.eql(u8, mode, "retention")) {
            return runOutcomeRetentionFixture(alloc, process_provider);
        }
        if (std.mem.eql(u8, mode, "failure")) {
            return runOutcomeFailureFixture(alloc, process_provider);
        }
        return error.InvalidTerminalOutcomeFixtureMode;
    }
    if (io_mod.getenv("FX_TERMINAL_AUTHORITY_FIXTURE")) |mode| {
        if (std.mem.eql(u8, mode, "start")) {
            return runAuthorityStartFixture(alloc, process_provider);
        }
        if (std.mem.eql(u8, mode, "reload")) {
            return runAuthorityReloadFixture(alloc, process_provider);
        }
        return error.InvalidTerminalAuthorityFixtureMode;
    }

    var runtime = client.Runtime.init(process_provider);
    defer runtime.deinit();
    const correlation_id = contracts.CorrelationId{ .value = 1 };
    try runtime.admit(
        alloc,
        correlation_id,
        .{ .screen = .{ .session_id = "terminal-fixture" } },
    );
    var completion = try awaitCompletionFor(&runtime, correlation_id);
    defer completion.deinit();
    try writeCompletionJson(alloc, completion);
}

fn runCapabilityStartFixture(
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
) !void {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var runtime = client.Runtime.init(process_provider);
    defer runtime.deinit();
    const correlation_id = contracts.CorrelationId{ .value = 1 };
    try runtime.admit(alloc, correlation_id, .{ .start = .{ .cwd = home } });
    var completion = try awaitCompletionFor(&runtime, correlation_id);
    defer completion.deinit();
    try writeCompletionJson(alloc, completion);
}

fn runCapabilityForceCloseFixture(
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
) !void {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    const terminal_session_id = io_mod.getenv(
        "FX_TERMINAL_AUTHORITY_SESSION_ID",
    ) orelse return error.TerminalAuthorityFixtureSessionMissing;
    var owner = try openFixtureOwnerCapability(alloc, home);
    defer owner.deinit();
    var loaded = try store.reloadAuthorityClaim(alloc, &owner, .{
        .terminal_session_id = terminal_session_id,
        .principal = authorityFixturePrincipal(home),
        .actor = .agent,
        .generation = .{ .value = 1 },
    });
    defer loaded.deinit();

    var runtime = client.Runtime.init(process_provider);
    defer runtime.deinit();
    const correlation_id = contracts.CorrelationId{ .value = 1 };
    try runtime.admit(alloc, correlation_id, .{ .close = .{
        .session_id = terminal_session_id,
        .policy = .force,
        .authority = loaded.view(),
    } });
    var completion = try awaitCompletionFor(&runtime, correlation_id);
    defer completion.deinit();
    try writeCompletionJson(alloc, completion);
}

fn fixturePreparation(home: []const u8) operation.AuthorityPreparation {
    return .{
        .profile_user = fixture_profile_user,
        .durable_session_id = fixture_owner_session_id,
        .workspace_root = home,
        .cwd = home,
        .transport_role = .interactive,
        .backend = .native,
        .actor = .agent,
        .controls = .full(),
        .lifetime = .session,
    };
}

fn fixturePrincipal(home: []const u8) contracts.Principal {
    const input = fixturePreparation(home);
    return .{
        .profile_user = input.profile_user,
        .durable_session_id = input.durable_session_id,
        .workspace_root = input.workspace_root,
        .cwd = input.cwd,
        .transport_role = input.transport_role,
        .backend = input.backend,
        .lifetime = input.lifetime,
    };
}

fn authorityFixturePrincipal(home: []const u8) contracts.Principal {
    var principal = fixturePrincipal(home);
    if (io_mod.getenv("FX_TERMINAL_AUTHORITY_FIXTURE_COMPAT")) |value| {
        if (std.mem.eql(u8, value, "1")) {
            principal.profile_user = protocol_fixture_profile_user;
        }
    }
    return principal;
}

fn runAuthorityStartFixture(
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
) !void {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    const compatibility_fixture = if (io_mod.getenv(
        "FX_TERMINAL_AUTHORITY_FIXTURE_COMPAT",
    )) |value|
        std.mem.eql(u8, value, "1")
    else
        false;
    const repeated_probes = [_]contracts.RepeatedProbeAuthority{.{
        .command = "true",
        .cwd = home,
        .check_schedule = .{ .interval_ms = 25 },
        .notify_schedule = .on_match,
        .lifetime = .until_session_end,
    }};
    var preparation = fixturePreparation(home);
    if (!compatibility_fixture) preparation.repeated_probes = &repeated_probes;
    var prepared = try operation.prepareStartPersistence(alloc, preparation);
    defer prepared.deinit();
    var runtime = client.Runtime.init(process_provider);
    defer runtime.deinit();
    const initial_monitors = [_]contracts.MonitorDefinition{.{
        .condition = .{ .custom_probe = .{
            .command = "true",
            .cwd = home,
        } },
        .check_schedule = .{ .interval_ms = 25 },
        .notify_schedule = .on_match,
        .lifetime = .until_session_end,
    }};
    try runtime.admit(alloc, .{ .value = 1 }, .{ .start = .{
        .cwd = home,
        .command = "printf 'authority-reload-ready\\n'; sleep 30",
        .shell = .{ .executable = .{
            .path = "/bin/bash",
            .clean_start = true,
        } },
        .return_when = .{ .match = fixture_marker },
        .wait_ceiling_ms = 5_000,
        .initial_monitors = if (compatibility_fixture) &.{} else &initial_monitors,
        .persistence = prepared.view(),
    } });
    var completion = try awaitCompletionFor(&runtime, .{ .value = 1 });
    defer completion.deinit();
    const result = try fixtureSuccess(completion, .start);
    const session_id = switch (result) {
        .start => |value| value.session.session_id,
        else => return error.TerminalAuthorityFixtureUnexpectedResult,
    };
    try writeJson(alloc, .{
        .session_id = session_id,
        .generation = prepared.view().grant.generation.value,
        .minted = true,
    });
}

fn runAuthorityReloadFixture(
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
) !void {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    const terminal_session_id = io_mod.getenv(
        "FX_TERMINAL_AUTHORITY_SESSION_ID",
    ) orelse return error.TerminalAuthorityFixtureSessionMissing;
    var owner = try openFixtureOwnerCapability(alloc, home);
    defer owner.deinit();
    var loaded = try store.reloadAuthorityClaim(alloc, &owner, .{
        .terminal_session_id = terminal_session_id,
        .principal = authorityFixturePrincipal(home),
        .actor = .agent,
        .generation = .{ .value = 1 },
    });
    defer loaded.deinit();

    var runtime = client.Runtime.init(process_provider);
    defer runtime.deinit();
    try runtime.admit(alloc, .{ .value = 1 }, .{ .inspect = .{
        .session_id = terminal_session_id,
        .authority = loaded.view(),
    } });
    var inspected = try awaitCompletionFor(&runtime, .{ .value = 1 });
    defer inspected.deinit();
    _ = try fixtureSuccess(inspected, .inspect);

    try runtime.admit(alloc, .{ .value = 2 }, .{ .read = .{
        .session_id = terminal_session_id,
        .cursor = .{ .segment = 1, .offset = 0 },
        .authority = loaded.view(),
    } });
    var read = try awaitCompletionFor(&runtime, .{ .value = 2 });
    defer read.deinit();
    const result = try fixtureSuccess(read, .read);
    const output = switch (result) {
        .read => |value| value.output,
        else => return error.TerminalAuthorityFixtureUnexpectedResult,
    };
    if (std.mem.find(u8, output, fixture_marker) == null) {
        return error.TerminalAuthorityFixtureMarkerMissing;
    }

    try runtime.admit(alloc, .{ .value = 3 }, .{ .close = .{
        .session_id = terminal_session_id,
        .policy = .graceful,
        .authority = loaded.view(),
    } });
    var closed = try awaitCompletionFor(&runtime, .{ .value = 3 });
    defer closed.deinit();
    _ = try fixtureSuccess(closed, .close);
    try writeJson(alloc, .{
        .read = true,
        .inspect = true,
        .closed = true,
    });
}

fn openFixtureOwnerCapability(
    alloc: Allocator,
    home: []const u8,
) !session_child_store.SessionChildCapability {
    const sessions_path = try profile_paths.sessionsDir(alloc, home);
    defer alloc.free(sessions_path);
    const owner_path = try std.fs.path.join(
        alloc,
        &.{ sessions_path, fixture_owner_session_id },
    );
    defer alloc.free(owner_path);
    var owner_dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), owner_path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer owner_dir.close(io_mod.getIo());
    return session_child_store.SessionChildCapability.init(
        alloc,
        owner_dir,
        owner_path,
        .read_only,
    );
}

fn runOutcomeRetentionFixture(
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
) !void {
    var runtime = client.Runtime.init(process_provider);
    defer runtime.deinit();
    for (1..policy.outcome_capacity + 1) |value| {
        const correlation_id = contracts.CorrelationId{ .value = value };
        const deadline = io_mod.milliTimestamp() + 8_000;
        while (true) {
            runtime.admit(
                alloc,
                correlation_id,
                .{ .screen = .{ .session_id = "terminal-retention" } },
            ) catch |err| switch (err) {
                error.QueueFull => {
                    if (io_mod.milliTimestamp() >= deadline) return error.TerminalClientFixtureTimeout;
                    io_mod.sleep(5 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
            break;
        }
        io_mod.sleep(25 * std.time.ns_per_ms);
    }
    const boundary = contracts.CorrelationId{
        .value = policy.outcome_capacity + 1,
    };
    if (runtime.admit(
        alloc,
        boundary,
        .{ .screen = .{ .session_id = "terminal-retention" } },
    )) |_| return error.TerminalOutcomeFixtureExpectedCapacity else |err| if (err != error.QueueFull) return err;

    for (1..policy.outcome_capacity + 1) |value| {
        const correlation_id = contracts.CorrelationId{ .value = value };
        var completion = try awaitCompletionFor(&runtime, correlation_id);
        defer completion.deinit();
        try expectFixtureFailure(completion, .screen, .authority_denied);
        if (runtime.takeCompletionFor(correlation_id)) |duplicate_value| {
            var duplicate = duplicate_value;
            duplicate.deinit();
            return error.TerminalOutcomeFixtureDuplicateCompletion;
        }
    }
    try writeJson(alloc, .{
        .retained = policy.outcome_capacity,
        .consumed = policy.outcome_capacity,
        .boundary_rejected = true,
    });
}

fn runOutcomeFailureFixture(
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
) !void {
    const point = io_mod.getenv("FX_TERMINAL_TEST_HOST_FAILURE_POINT") orelse
        return error.TerminalOutcomeFixtureFailurePointMissing;
    const ordered = std.mem.eql(u8, point, "task_allocation") or
        std.mem.eql(u8, point, "worker_start");
    var runtime = client.Runtime.init(process_provider);
    defer runtime.deinit();
    const first_request: contracts.ActionRequest = if (ordered)
        .{ .write = .{
            .session_id = "terminal-failure",
            .payload = .{ .text = "first" },
        } }
    else
        .{ .screen = .{ .session_id = "terminal-failure" } };
    try runtime.admit(alloc, .{ .value = 1 }, first_request);
    var first = try awaitCompletionFor(&runtime, .{ .value = 1 });
    defer first.deinit();
    if (first.kind != .disconnected) {
        return error.TerminalOutcomeFixtureExpectedDisconnect;
    }

    try runtime.admit(alloc, .{ .value = 2 }, .{ .write = .{
        .session_id = "terminal-failure",
        .payload = .{ .text = "second" },
    } });
    var second = try awaitCompletionFor(&runtime, .{ .value = 2 });
    defer second.deinit();
    try expectFixtureFailure(second, .write, .authority_denied);
    try writeJson(alloc, .{
        .failure = point,
        .first = @tagName(first.kind),
        .later = @tagName(second.kind),
    });
}

fn runOutcomeOrderingFixture(
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
) !void {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    const shell = io_mod.getenv("SHELL") orelse return error.ShellNotSet;
    const initial_monitors = [_]contracts.MonitorDefinition{.{
        .condition = .{ .output_contains = "ordered-event" },
        .notify_schedule = .on_match,
        .lifetime = .until_session_end,
    }};
    var prepared = try operation.prepareStartPersistence(
        alloc,
        fixturePreparation(home),
    );
    defer prepared.deinit();
    const persistence = prepared.view();
    const authority = contracts.AuthorityClaim{
        .principal = persistence.grant.principal,
        .actor = persistence.grant.actor,
        .generation = persistence.grant.generation,
        .proof = persistence.proof,
    };
    var runtime = client.Runtime.init(process_provider);
    defer runtime.deinit();

    try runtime.admit(alloc, .{ .value = 1 }, .{ .start = .{
        .cwd = home,
        .command = "printf 'ordered-event\\n'; IFS= read -r _",
        .shell = .{ .executable = .{ .path = shell, .clean_start = true } },
        .return_when = .{ .match = "ordered-event" },
        .wait_ceiling_ms = fixture_observation_timeout_ms,
        .initial_monitors = &initial_monitors,
        .persistence = persistence,
    } });
    var started = try awaitCompletionFor(&runtime, .{ .value = 1 });
    defer started.deinit();
    const start_result = try fixtureSuccess(started, .start);
    const session_id = switch (start_result) {
        .start => |value| try alloc.dupe(u8, value.session.session_id),
        else => return error.TerminalOutcomeFixtureUnexpectedResult,
    };
    defer alloc.free(session_id);

    try runtime.admit(alloc, .{ .value = 2 }, .{ .inspect = .{
        .session_id = session_id,
        .authority = authority,
    } });
    var before = try awaitCompletionFor(&runtime, .{ .value = 2 });
    defer before.deinit();
    const before_result = try fixtureSuccess(before, .inspect);
    const event_id = switch (before_result) {
        .inspect => |value| if (value.events.len == 0)
            return error.TerminalOutcomeFixtureEventMissing
        else
            value.events[value.events.len - 1].event_id,
        else => return error.TerminalOutcomeFixtureUnexpectedResult,
    };

    try runtime.admit(alloc, .{ .value = 3 }, .{ .write = .{
        .session_id = session_id,
        .lease = .acquire,
        .authority = authority,
    } });
    try awaitOrderingMarker(3, "ready");
    try runtime.admit(alloc, .{ .value = 4 }, .{ .inspect = .{
        .session_id = session_id,
        .after_event_id = event_id,
        .acknowledge_event_id = event_id,
        .authority = authority,
    } });
    try awaitOrderingMarker(4, "admitted");
    if (runtime.takeCompletionFor(.{ .value = 4 }) != null) {
        return error.TerminalOutcomeFixtureOrderingViolation;
    }

    try runtime.admit(alloc, .{ .value = 5 }, .{ .inspect = .{
        .session_id = session_id,
        .authority = authority,
    } });
    var concurrent = try awaitCompletionFor(&runtime, .{ .value = 5 });
    defer concurrent.deinit();
    try expectFixtureEvent(concurrent, event_id, true);
    try createOrderingMarker(3, "release");

    var acquired = try awaitCompletionFor(&runtime, .{ .value = 3 });
    defer acquired.deinit();
    _ = try fixtureSuccess(acquired, .write);
    var acknowledged = try awaitCompletionFor(&runtime, .{ .value = 4 });
    defer acknowledged.deinit();
    _ = try fixtureSuccess(acknowledged, .inspect);

    try runtime.admit(alloc, .{ .value = 6 }, .{ .inspect = .{
        .session_id = session_id,
        .authority = authority,
    } });
    var after = try awaitCompletionFor(&runtime, .{ .value = 6 });
    defer after.deinit();
    try expectFixtureEvent(after, event_id, false);

    try runtime.admit(alloc, .{ .value = 7 }, .{ .write = .{
        .session_id = session_id,
        .lease = .release,
        .authority = authority,
    } });
    try awaitOrderingMarker(7, "ready");
    try runtime.admit(alloc, .{ .value = 8 }, .{ .resize = .{
        .session_id = session_id,
        .dimensions = .{ .rows = 24, .columns = 80 },
        .authority = authority,
    } });
    try awaitOrderingMarker(8, "admitted");
    if (!runtime.cancel(.{ .value = 7 })) {
        return error.TerminalOutcomeFixtureCancellationMissing;
    }
    var cancelled = try awaitCompletionFor(&runtime, .{ .value = 7 });
    defer cancelled.deinit();
    if (cancelled.kind != .cancelled) {
        return error.TerminalOutcomeFixtureExpectedCancellation;
    }
    var resized = try awaitCompletionFor(&runtime, .{ .value = 8 });
    defer resized.deinit();
    _ = try fixtureSuccess(resized, .resize);

    try runtime.admit(alloc, .{ .value = 9 }, .{ .close = .{
        .session_id = session_id,
        .policy = .force,
        .authority = authority,
    } });
    var closed = try awaitCompletionFor(&runtime, .{ .value = 9 });
    defer closed.deinit();
    _ = try fixtureSuccess(closed, .close);
    try writeJson(alloc, .{
        .ordered = true,
        .acknowledged = true,
        .read_only_concurrent = true,
        .cancelled_turn_abandoned = true,
    });
}

fn awaitCompletionFor(
    runtime: *client.Runtime,
    correlation_id: contracts.CorrelationId,
) !client.Completion {
    const started = io_mod.milliTimestamp();
    while (io_mod.milliTimestamp() - started < fixture_observation_timeout_ms) {
        if (runtime.takeCompletionFor(correlation_id)) |completion| {
            return completion;
        }
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
    return error.TerminalClientFixtureTimeout;
}

fn fixtureSuccess(
    completion: client.Completion,
    expected: contracts.Action,
) !contracts.ActionResult {
    const frame = completion.frame orelse
        return error.TerminalOutcomeFixtureUnexpectedResult;
    return switch (frame.message().payload) {
        .response => |response| switch (response) {
            .success => |success| if (success.action() == expected)
                success
            else
                error.TerminalOutcomeFixtureUnexpectedResult,
            .failure => error.TerminalOutcomeFixtureFailed,
        },
        else => error.TerminalOutcomeFixtureUnexpectedResult,
    };
}

fn expectFixtureFailure(
    completion: client.Completion,
    action: contracts.Action,
    code: contracts.StructuredErrorCode,
) !void {
    const frame = completion.frame orelse
        return error.TerminalOutcomeFixtureUnexpectedResult;
    switch (frame.message().payload) {
        .response => |response| switch (response) {
            .failure => |failure| if (failure.action != action or failure.code != code) {
                return error.TerminalOutcomeFixtureUnexpectedResult;
            },
            .success => return error.TerminalOutcomeFixtureUnexpectedResult,
        },
        else => return error.TerminalOutcomeFixtureUnexpectedResult,
    }
}

fn expectFixtureEvent(
    completion: client.Completion,
    event_id: u64,
    present: bool,
) !void {
    const result = try fixtureSuccess(completion, .inspect);
    const events = switch (result) {
        .inspect => |inspect| inspect.events,
        else => return error.TerminalOutcomeFixtureUnexpectedResult,
    };
    const found = for (events) |event| {
        if (event.event_id == event_id) break true;
    } else false;
    if (found != present) return error.TerminalOutcomeFixtureOrderingViolation;
}

fn awaitOrderingMarker(correlation_id: u64, suffix: []const u8) !void {
    const started = io_mod.milliTimestamp();
    while (io_mod.milliTimestamp() - started < fixture_observation_timeout_ms) {
        if (orderingMarkerExists(correlation_id, suffix)) return;
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
    return error.TerminalClientFixtureTimeout;
}

fn createOrderingMarker(correlation_id: u64, suffix: []const u8) !void {
    var path_buffer: [4096]u8 = undefined;
    const path = try orderingMarkerPath(&path_buffer, correlation_id, suffix);
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{});
    file.close(io_mod.getIo());
}

fn orderingMarkerExists(correlation_id: u64, suffix: []const u8) bool {
    var path_buffer: [4096]u8 = undefined;
    const path = orderingMarkerPath(&path_buffer, correlation_id, suffix) catch
        return false;
    std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

fn orderingMarkerPath(
    buffer: []u8,
    correlation_id: u64,
    suffix: []const u8,
) ![]const u8 {
    const prefix = io_mod.getenv("FX_TERMINAL_TEST_ORDER_BARRIER") orelse
        return error.TerminalOutcomeFixtureBarrierMissing;
    return std.fmt.bufPrint(
        buffer,
        "{s}.{d}.{s}",
        .{ prefix, correlation_id, suffix },
    );
}

fn writeCompletionJson(alloc: Allocator, completion: client.Completion) !void {
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    try output.writer.writeAll("{\"kind\":");
    try std.json.Stringify.value(@tagName(completion.kind), .{}, &output.writer);
    try output.writer.writeAll(",\"correlation\":1");
    if (completion.incompatibility) |incompatibility| {
        try output.writer.writeAll(",\"incompatibility\":");
        try std.json.Stringify.value(incompatibility, .{}, &output.writer);
    }
    if (completion.missing_capabilities != 0) {
        try output.writer.print(
            ",\"missing_capabilities\":{d}",
            .{completion.missing_capabilities},
        );
    }
    if (completion.frame) |*frame| {
        switch (frame.message().payload) {
            .response => |response| switch (response) {
                .failure => |failure| {
                    try output.writer.writeAll(",\"code\":");
                    try std.json.Stringify.value(
                        @tagName(failure.code),
                        .{},
                        &output.writer,
                    );
                },
                .success => {},
            },
            else => {},
        }
    }
    try output.writer.writeAll("}\n");
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), output.written());
}

fn writeJson(alloc: Allocator, value: anytype) !void {
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    try std.json.Stringify.value(value, .{}, &output.writer);
    try output.writer.writeByte('\n');
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), output.written());
}
