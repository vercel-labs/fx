const std = @import("std");

const command_admission = @import("../permissions/command_admission.zig");
const direct_command = @import("../permissions/direct_command.zig");
const command_runner = @import("../execution/command_runner.zig");
const command_effect = @import("../shell_command/command_effect.zig");

pub const RouteKind = enum {
    direct_read_only,
    approved_shell,
};

/// An admitted foreground command prepared for local execution.
///
/// The direct plan owns its allocations. The caller must call `deinit`.
pub const PreparedCommand = union(enum) {
    direct_read_only: command_effect.DirectReadOnlyPlan,
    approved_shell: struct {
        command_ctx: command_admission.CommandContext,
        reason: command_effect.ApprovalReason,
        source: command_admission.ShellAuthorizationSource,
    },

    pub fn deinit(self: *PreparedCommand, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .direct_read_only => |*plan| plan.deinit(alloc),
            .approved_shell => {},
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
        .approved_shell => |shell| .{
            .route = .approved_shell,
            .result = try command_runner.executeCommandInEnvironment(
                cfg,
                alloc,
                shell.command_ctx.command,
                shell.command_ctx.resolved_cwd,
                shell.command_ctx.environment,
            ),
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
            .target_os = @import("builtin").os.tag,
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
            .target_os = @import("builtin").os.tag,
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
