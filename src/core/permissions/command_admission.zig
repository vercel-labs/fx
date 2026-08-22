const std = @import("std");
const auto_classifier = @import("auto_classifier.zig");
const command_effect = @import("../shell_command/command_effect.zig");
const command_environment = @import("../execution/command_environment.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const types = @import("../shared/types.zig");

pub const CommandContext = struct {
    command: []const u8,
    resolved_cwd: []const u8,
    background: bool,
    target_os: std.Target.Os.Tag,
    environment: command_environment.Environment = .legacy,
};

pub const AdmissionFingerprint = struct {
    command: []const u8,
    resolved_cwd: []const u8,
    background: bool,
    target_os: std.Target.Os.Tag,
    environment: command_environment.Environment = .legacy,

    pub fn init(ctx: CommandContext) AdmissionFingerprint {
        return .{
            .command = ctx.command,
            .resolved_cwd = ctx.resolved_cwd,
            .background = ctx.background,
            .target_os = ctx.target_os,
            .environment = ctx.environment,
        };
    }

    pub fn matches(self: AdmissionFingerprint, ctx: CommandContext) bool {
        return std.mem.eql(u8, self.command, ctx.command) and
            std.mem.eql(u8, self.resolved_cwd, ctx.resolved_cwd) and
            self.background == ctx.background and
            self.target_os == ctx.target_os and
            self.environment.eql(ctx.environment);
    }

    pub fn eql(self: AdmissionFingerprint, other: AdmissionFingerprint) bool {
        return self.matches(.{
            .command = other.command,
            .resolved_cwd = other.resolved_cwd,
            .background = other.background,
            .target_os = other.target_os,
            .environment = other.environment,
        });
    }
};

pub const ShellAuthorizationSource = enum {
    configured_rule,
    session_state,
    session_grant,
    interactive_once,
    interactive_always,
    auto_mode,
    auto_classifier,
    yolo,
    js_host,
};

pub const CommandExecutionAuthority = union(enum) {
    direct_only: AdmissionFingerprint,
    shell_allowed: struct {
        fingerprint: AdmissionFingerprint,
        source: ShellAuthorizationSource,
    },
};

pub const VisionPathExecutionTarget = struct {
    canonical_path: []const u8,
    identity: file_mutation_contract.FileIdentity,
};

pub const VisionPathExecutionAuthority = struct {
    /// The admission allocator owns this slice and every canonical path.
    targets: []const VisionPathExecutionTarget,
};

pub const ToolExecutionAuthority = union(enum) {
    ordinary,
    run_command: CommandExecutionAuthority,
    file_mutation: file_mutation_contract.FileExecutionAuthorization,
    vision_paths: VisionPathExecutionAuthority,
};

pub const HumanApprovalProvenance = enum {
    none,
    once,
    always,
};

pub const PermissionOutcome = struct {
    decision: types.ToolPermissionDecision = .policy_denied,
    execution_authority: ?ToolExecutionAuthority = null,
    human_approval: HumanApprovalProvenance = .none,
    denial_reason: ?types.ToolPermissionDenialReason = null,
    requirement: ?PermissionRequirement = null,
    tool_failure: ?[]const u8 = null,
    feedback: ?[]const u8 = null,
    /// Owned by the allocator passed to the permission request.
    auto_review_result: ?auto_classifier.Result = null,
};

pub const PermissionRequirement = enum {
    configured_rule,
    approval_required,
};

pub const DefaultApproval = union(enum) {
    direct_only: AdmissionFingerprint,
    approval_required: command_effect.ApprovalReason,
};

pub fn defaultForRunCommand(
    alloc: std.mem.Allocator,
    command_ctx: CommandContext,
    permission_mode: types.PermissionMode,
) DefaultApproval {
    const requires_shell_authority = switch (command_ctx.environment) {
        .user => true,
        .clean => permission_mode != .auto,
        .legacy, .workspace_clean => false,
    };
    if (requires_shell_authority) {
        return .{ .approval_required = .dynamic_shell };
    }
    var admission = command_effect.plan(
        alloc,
        command_ctx.command,
        command_ctx.resolved_cwd,
        command_ctx.background,
        command_ctx.target_os,
    ) catch return .{ .approval_required = .planning_failure };
    defer admission.deinit(alloc);

    return switch (admission) {
        .direct_read_only => .{ .direct_only = .init(command_ctx) },
        .approval_required => |reason| .{ .approval_required = reason },
    };
}

test "normalized default emits direct-only only for a direct plan" {
    const direct_ctx = CommandContext{
        .command = "pwd",
        .resolved_cwd = "/workspace",
        .background = false,
        .target_os = .macos,
    };
    const direct = defaultForRunCommand(std.testing.allocator, direct_ctx, .ask);
    switch (direct) {
        .direct_only => |fingerprint| try std.testing.expect(fingerprint.matches(direct_ctx)),
        .approval_required => return error.TestExpectedDirectOnly,
    }

    const write_ctx = CommandContext{
        .command = "touch created.txt",
        .resolved_cwd = "/workspace",
        .background = false,
        .target_os = .macos,
    };
    try std.testing.expectEqual(
        command_effect.ApprovalReason.filesystem_write,
        defaultForRunCommand(std.testing.allocator, write_ctx, .ask).approval_required,
    );
}

test "explicit user environment always requires shell authority" {
    const user_ctx = CommandContext{
        .command = "pwd",
        .resolved_cwd = "/workspace",
        .background = false,
        .target_os = .macos,
        .environment = .{ .user = "/bin/zsh" },
    };
    for ([_]types.PermissionMode{ .auto, .ask }) |permission_mode| {
        try std.testing.expectEqual(
            command_effect.ApprovalReason.dynamic_shell,
            defaultForRunCommand(std.testing.allocator, user_ctx, permission_mode).approval_required,
        );
    }
}

test "explicit clean environment is direct only in automatic mode" {
    const clean_ctx = CommandContext{
        .command = "pwd",
        .resolved_cwd = "/workspace",
        .background = false,
        .target_os = .macos,
        .environment = .{ .clean = "/bin/zsh" },
    };
    const automatic = defaultForRunCommand(std.testing.allocator, clean_ctx, .auto);
    switch (automatic) {
        .direct_only => |fingerprint| try std.testing.expect(fingerprint.matches(clean_ctx)),
        .approval_required => return error.TestExpectedDirectOnly,
    }
    try std.testing.expectEqual(
        command_effect.ApprovalReason.dynamic_shell,
        defaultForRunCommand(std.testing.allocator, clean_ctx, .ask).approval_required,
    );
    var write_ctx = clean_ctx;
    write_ctx.command = "touch created.txt";
    try std.testing.expectEqual(
        command_effect.ApprovalReason.filesystem_write,
        defaultForRunCommand(std.testing.allocator, write_ctx, .auto).approval_required,
    );
}
