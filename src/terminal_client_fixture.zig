const std = @import("std");
const builtin = @import("builtin");
const shell_process_provider = @import("tools/shell/process_provider.zig");
const process_provider_mod = @import("core/execution/process_provider.zig");
const process_identity = @import("core/execution/process_identity.zig");
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
            .delegate = shell_process_provider.provider,
        };
        const provider = if (io_mod.getenv(
            "FX_TERMINAL_FIXTURE_FAIL_PROCESS_TOKEN",
        ) != null)
            failure_provider.provider()
        else
            shell_process_provider.provider;
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
    try runFixture(process_allocator, shell_process_provider.provider);
}

const CaptureFailureProvider = struct {
    delegate: process_provider_mod.Provider,
    captures: usize = 0,

    fn provider(self: *@This()) process_provider_mod.Provider {
        return .{
            .context = self,
            .capture_token_fn = captureToken,
            .match_token_fn = matchToken,
            .signal_process_fn = signalProcess,
        };
    }

    fn from(raw: ?*anyopaque) *@This() {
        return @ptrCast(@alignCast(raw.?));
    }

    fn captureToken(
        raw: ?*anyopaque,
        alloc: Allocator,
        pid: []const u8,
    ) process_provider_mod.ProviderError!process_identity.ProcessInstanceToken {
        const self = from(raw);
        self.captures += 1;
        if (self.captures > 2) return error.ProcessIdentityUnavailable;
        return self.delegate.captureToken(alloc, pid);
    }

    fn matchToken(
        raw: ?*anyopaque,
        alloc: Allocator,
        pid: []const u8,
        expected: process_identity.ProcessInstanceToken,
    ) process_identity.TokenMatch {
        return from(raw).delegate.matchToken(alloc, pid, expected);
    }

    fn signalProcess(
        raw: ?*anyopaque,
        alloc: Allocator,
        pid: []const u8,
        expected: process_identity.ProcessInstanceToken,
    ) process_provider_mod.ProviderError!void {
        return from(raw).delegate.signalProcess(alloc, pid, expected);
    }
};

fn runFixture(
    alloc: Allocator,
    process_provider_value: process_provider_mod.Provider,
) !void {
    if (io_mod.getenv("FX_TERMINAL_CAPABILITY_FIXTURE")) |mode| {
        if (std.mem.eql(u8, mode, "start")) {
            return runCapabilityStartFixture(alloc, process_provider_value);
        }
        if (std.mem.eql(u8, mode, "force_close")) {
            return runCapabilityForceCloseFixture(alloc, process_provider_value);
        }
        return error.InvalidTerminalCapabilityFixtureMode;
    }
    if (io_mod.getenv("FX_TERMINAL_OUTCOME_FIXTURE")) |mode| {
        if (std.mem.eql(u8, mode, "retention")) {
            return runOutcomeRetentionFixture(alloc, process_provider_value);
        }
        if (std.mem.eql(u8, mode, "failure")) {
            return runOutcomeFailureFixture(alloc, process_provider_value);
        }
        return error.InvalidTerminalOutcomeFixtureMode;
    }
    if (io_mod.getenv("FX_TERMINAL_AUTHORITY_FIXTURE")) |mode| {
        if (std.mem.eql(u8, mode, "start")) {
            return runAuthorityStartFixture(alloc, process_provider_value);
        }
        if (std.mem.eql(u8, mode, "reload")) {
            return runAuthorityReloadFixture(alloc, process_provider_value);
        }
        return error.InvalidTerminalAuthorityFixtureMode;
    }

    var runtime = client.Runtime.init(process_provider_value);
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
    process_provider: process_provider_mod.Provider,
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
    process_provider: process_provider_mod.Provider,
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
    process_provider: process_provider_mod.Provider,
) !void {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    const preparation = fixturePreparation(home);
    var prepared = try operation.prepareStartPersistence(alloc, preparation);
    defer prepared.deinit();
    var runtime = client.Runtime.init(process_provider);
    defer runtime.deinit();
    try runtime.admit(alloc, .{ .value = 1 }, .{ .start = .{
        .cwd = home,
        .command = "printf 'authority-reload-ready\\n'; sleep 30",
        .shell = .{ .executable = .{
            .path = "/bin/bash",
            .clean_start = true,
        } },
        .return_when = .{ .match = fixture_marker },
        .wait_ceiling_ms = 5_000,
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
    process_provider: process_provider_mod.Provider,
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
    process_provider: process_provider_mod.Provider,
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
    process_provider: process_provider_mod.Provider,
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
