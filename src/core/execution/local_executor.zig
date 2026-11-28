const std = @import("std");
const self_exe = @import("../shared/self_exe.zig");

const command_admission = @import("../permissions/command_admission.zig");
const direct_command = @import("../permissions/direct_command.zig");
const command_runner = @import("../execution/command_runner.zig");
const command_effect = @import("../shell_command/command_effect.zig");
const launch = @import("../runner/runner.zig");

pub const RouteKind = enum {
    direct_read_only,
    approved_shell,
};

/// An admitted foreground command prepared for local execution.
///
/// The direct plan and a placed command's `run_command` own their allocations.
/// The caller must call `deinit`.
pub const PreparedCommand = union(enum) {
    direct_read_only: command_effect.DirectReadOnlyPlan,
    approved_shell: struct {
        command_ctx: command_admission.CommandContext,
        reason: command_effect.ApprovalReason,
        /// The shell grant that admitted the command. Null for a direct-only
        /// grant, which has no shell authority.
        source: ?command_admission.ShellAuthorizationSource = null,
        grant_epoch: ?u64 = null,
        /// The text the runner executes instead of the user's command, such as
        /// a sandbox provider invocation. The result still names the user's
        /// command. Null runs the user's command.
        run_command: ?[]const u8 = null,
        /// How long a stop waits after SIGTERM. Null keeps the runner's grace.
        termination_grace_ms: ?i64 = null,
    },

    pub fn deinit(self: *PreparedCommand, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .direct_read_only => |*plan| plan.deinit(alloc),
            .approved_shell => |shell| if (shell.run_command) |text| alloc.free(text),
        }
        self.* = undefined;
    }
};

pub const CommandResult = struct {
    route: RouteKind,
    result: command_runner.CommandExecutionResult,
};

/// Upper bound for raw callback bytes that can still be represented by the
/// command's ordinary foreground result. Above this bound execution either
/// rejects output or promotes it to an unordered command artifact.
pub fn foregroundResultComparisonLimit(
    command: PreparedCommand,
    approved_shell_limit: usize,
) usize {
    return switch (command) {
        .direct_read_only => direct_command.direct_output_limit_bytes,
        .approved_shell => approved_shell_limit,
    };
}

fn shellConfig(
    cfg: command_runner.Config,
    grant_epoch: ?u64,
    termination_grace_ms: ?i64,
) command_runner.Config {
    var bound = cfg;
    bound.shell_grant_epoch = grant_epoch;
    bound.termination_grace_ms = termination_grace_ms;
    return bound;
}

/// Executes a prepared foreground command without taking ownership of it.
pub fn executePreparedCommand(
    cfg: command_runner.Config,
    alloc: std.mem.Allocator,
    command: PreparedCommand,
) !CommandResult {
    return switch (command) {
        .direct_read_only => |plan| .{
            .route = .direct_read_only,
            .result = try direct_command.executeDirectReadOnly(cfg, alloc, plan),
        },
        .approved_shell => |shell| blk: {
            var result = if (shell.run_command) |launch_text|
                // A placed command starts its runner as a local command (spec L3).
                try command_runner.executeRunnerLaunch(
                    shellConfig(cfg, shell.grant_epoch, shell.termination_grace_ms),
                    alloc,
                    launch_text,
                    shell.command_ctx.resolved_cwd,
                )
            else
                try command_runner.executeCommandInEnvironment(
                    shellConfig(cfg, shell.grant_epoch, shell.termination_grace_ms),
                    alloc,
                    shell.command_ctx.command,
                    shell.command_ctx.resolved_cwd,
                    shell.command_ctx.environment,
                );
            // The runner records the text it executed. A placed command reports
            // the command the user asked for, not its launch text.
            if (shell.run_command != null) {
                if (result.command_result) |*foreground| foreground.command = shell.command_ctx.command;
            }
            break :blk CommandResult{ .route = .approved_shell, .result = result };
        },
    };
}

test "local executor keeps route-specific foreground result limits" {
    const direct = PreparedCommand{ .direct_read_only = .{
        .command = "",
        .cwd = "",
        .stages = &.{},
    } };
    try std.testing.expectEqual(
        direct_command.direct_output_limit_bytes,
        foregroundResultComparisonLimit(direct, 1),
    );

    const approved = PreparedCommand{ .approved_shell = .{
        .command_ctx = .{
            .command = "",
            .resolved_cwd = "",
            .target_os = @import("builtin").target.os.tag,
        },
        .reason = .process_or_system,
        .source = .interactive_once,
    } };
    try std.testing.expectEqual(
        @as(usize, 1024),
        foregroundResultComparisonLimit(approved, 1024),
    );
}

test "local executor runs an approved shell command with its admitted context" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const command = PreparedCommand{ .approved_shell = .{
        .command_ctx = .{
            .command = "printf local-executor",
            .resolved_cwd = "/tmp",
            .target_os = @import("builtin").target.os.tag,
        },
        .reason = .process_or_system,
        .source = .interactive_once,
    } };
    const executed = try executePreparedCommand(.{
        .max_command_output_bytes = 1024,
    }, arena, command);

    try std.testing.expectEqual(RouteKind.approved_shell, executed.route);
    try std.testing.expect(std.mem.find(
        u8,
        executed.result.output,
        "<stdout>\nlocal-executor\n</stdout>",
    ) != null);
    const foreground = executed.result.command_result.?;
    try std.testing.expectEqualStrings(command.approved_shell.command_ctx.command, foreground.command);
    try std.testing.expectEqualStrings(command.approved_shell.command_ctx.resolved_cwd, foreground.cwd);
    try std.testing.expectEqual(@as(?i64, 0), foreground.exit_code);
}

test "local executor runs a placed command through its provider and names the user command" {
    try self_exe.requireInstalledForTest();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The provider is /bin/echo, so the "provider" prints the argv it was given.
    const provider = [_][]const u8{"/bin/echo"};
    const sandbox: launch.Launch = .{
        .provider = &provider,
        .state_dir = "/tmp/fx-state",
        .workspace_root = "/tmp",
        .grace_ms = 1500,
    };
    const user_command = "printf local-executor";
    // The test allocator fails the test if the invocation leaks.
    const run_command = try launch.invocation(std.testing.allocator, &sandbox, user_command, "/tmp", .remote, null, null);
    defer std.testing.allocator.free(run_command);
    const command = PreparedCommand{ .approved_shell = .{
        .command_ctx = .{
            .command = user_command,
            .resolved_cwd = "/tmp",
            .target_os = @import("builtin").target.os.tag,
            .placement = .remote,
            .sandbox = &sandbox,
        },
        .reason = .dynamic_shell,
        .run_command = run_command,
        .termination_grace_ms = 1500,
    } };
    const executed = try executePreparedCommand(.{
        .max_command_output_bytes = 4096,
    }, arena, command);

    try std.testing.expectEqual(RouteKind.approved_shell, executed.route);
    try std.testing.expect(std.mem.find(
        u8,
        executed.result.output,
        "run --mode remote --root /tmp --cwd /tmp --state /tmp/fx-state -- printf local-executor",
    ) != null);
    const foreground = executed.result.command_result.?;
    try std.testing.expectEqualStrings(user_command, foreground.command);
    try std.testing.expectEqual(@as(?i64, 0), foreground.exit_code);
}

test "approved shell hands its termination grace to the runner config" {
    const bound = shellConfig(.{ .max_command_output_bytes = 1 }, 7, 1500);
    try std.testing.expectEqual(@as(?u64, 7), bound.shell_grant_epoch);
    try std.testing.expectEqual(@as(?i64, 1500), bound.termination_grace_ms);
}
