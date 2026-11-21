const std = @import("std");
const auto_classifier = @import("auto_classifier.zig");
const command_effect = @import("../shell_command/command_effect.zig");
const command_environment = @import("../execution/command_environment.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const launch = @import("../sandbox/launch.zig");
const types = @import("../shared/types.zig");

pub const CommandExecutionMode = enum {
    captured,
    tty,
};

pub const CommandContext = struct {
    command: []const u8,
    resolved_cwd: []const u8,
    target_os: std.Target.Os.Tag,
    environment: command_environment.Environment = .legacy,
    execution_mode: CommandExecutionMode = .captured,
    /// Where the command runs. Settings decide it before admission.
    placement: command_environment.Placement = .local,
    /// For `.isolated`, the profile that runs it. Null means the profile named `default`.
    placement_profile: ?[]const u8 = null,
    /// The provider launch for a placed command. It is configuration, not
    /// identity, so `AdmissionFingerprint` leaves it out.
    sandbox: ?*const launch.Launch = null,
};

pub const AdmissionFingerprint = struct {
    command: []const u8,
    resolved_cwd: []const u8,
    target_os: std.Target.Os.Tag,
    environment: command_environment.Environment = .legacy,
    execution_mode: CommandExecutionMode = .captured,
    placement: command_environment.Placement = .local,
    placement_profile: ?[]const u8 = null,

    pub fn init(ctx: CommandContext) AdmissionFingerprint {
        return .{
            .command = ctx.command,
            .resolved_cwd = ctx.resolved_cwd,
            .target_os = ctx.target_os,
            .environment = ctx.environment,
            .execution_mode = ctx.execution_mode,
            .placement = ctx.placement,
            .placement_profile = ctx.placement_profile,
        };
    }

    pub fn matches(self: AdmissionFingerprint, ctx: CommandContext) bool {
        return std.mem.eql(u8, self.command, ctx.command) and
            std.mem.eql(u8, self.resolved_cwd, ctx.resolved_cwd) and
            self.target_os == ctx.target_os and
            self.environment.eql(ctx.environment) and
            self.execution_mode == ctx.execution_mode and
            self.placement == ctx.placement and
            sameProfile(self.placement_profile, ctx.placement_profile);
    }

    pub fn eql(self: AdmissionFingerprint, other: AdmissionFingerprint) bool {
        return self.matches(.{
            .command = other.command,
            .resolved_cwd = other.resolved_cwd,
            .target_os = other.target_os,
            .environment = other.environment,
            .execution_mode = other.execution_mode,
            .placement = other.placement,
            .placement_profile = other.placement_profile,
        });
    }
};

/// A null profile is the profile named `default`, so the two match.
fn sameProfile(a: ?[]const u8, b: ?[]const u8) bool {
    return std.mem.eql(u8, a orelse "default", b orelse "default");
}

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
        /// Shell snapshot epoch of the remembered grant that admitted the
        /// command. Execution under a later epoch is asked again.
        grant_epoch: ?u64 = null,
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
    auto_review_failure: ?auto_classifier.InvalidReason = null,
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
    const requires_shell_authority = command_ctx.execution_mode == .tty or
        switch (command_ctx.environment) {
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
        false,
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

test "admission fingerprint binds the placement" {
    const local: CommandContext = .{ .command = "zig build test", .resolved_cwd = "/repo", .target_os = .linux };
    var workspace = local;
    workspace.placement = .workspace;
    var isolated = local;
    isolated.placement = .isolated;

    const fingerprint = AdmissionFingerprint.init(local);
    try std.testing.expect(fingerprint.matches(local));
    try std.testing.expect(!fingerprint.matches(workspace));
    try std.testing.expect(!fingerprint.matches(isolated));
    try std.testing.expect(!AdmissionFingerprint.init(workspace).eql(AdmissionFingerprint.init(isolated)));

    var media = isolated;
    media.placement_profile = "media";
    var open = isolated;
    open.placement_profile = "open";
    var named_default = isolated;
    named_default.placement_profile = "default";

    const media_fingerprint = AdmissionFingerprint.init(media);
    try std.testing.expect(media_fingerprint.matches(media));
    try std.testing.expect(!media_fingerprint.matches(open));
    try std.testing.expect(!AdmissionFingerprint.init(isolated).matches(media));
    try std.testing.expect(AdmissionFingerprint.init(isolated).matches(named_default));
}
