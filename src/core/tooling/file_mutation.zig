const std = @import("std");
const builtin = @import("builtin");
const diff_mod = @import("../output/diff.zig");
const file_mutation_contract = @import("file_mutation_contract.zig");
const io_mod = @import("../shared/io.zig");
const pathing = @import("../workspace/pathing.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");

const testing_permissions = if (builtin.is_test)
    @import("../permissions/permissions.zig")
else
    struct {};
const testing_builtin_tools = if (builtin.is_test)
    @import("../../builtins/tools.zig")
else
    struct {};
const testing_write_file = if (builtin.is_test)
    @import("../../tools/filesystem/write_file.zig")
else
    struct {};
const testing_edit_file = if (builtin.is_test)
    @import("../../tools/filesystem/edit_file.zig")
else
    struct {};

const Allocator = std.mem.Allocator;
const PreparedFileMutation = file_mutation_contract.PreparedFileMutation;
const PolicyEvaluatedFileTargets = file_mutation_contract.PolicyEvaluatedFileTargets;

const max_content_bytes: usize = 4 * 1024 * 1024;
const max_total_content_bytes: usize = 8 * 1024 * 1024;

pub const ParentCleanupResidueReason = enum {
    not_empty,
    identity_changed,
    remove_failed,
};

pub const CreatedParentResidue = struct {
    component_index: usize,
    path_end: usize,
    permission_target_index: usize,
    created_identity: file_mutation_contract.FileIdentity,
    observed_identity: ?file_mutation_contract.FileIdentity,
    reason: ParentCleanupResidueReason,
};

pub const ApplyRejectionReason = enum {
    binding_mismatch,
    stale_preimage,
    cancelled,
    traversal_changed,
    staged_source_changed,
    io_failure,
};

pub const ApplyRejection = struct {
    reason: ApplyRejectionReason,
    created_parent_residue: []const CreatedParentResidue,
};

pub const ChangeTrackerHandoff = struct {
    kind: file_mutation_contract.Kind,
    raw_path: []const u8,
    previous_content: ?[]const u8,
    committed_at_ms: i64,
};

pub const FullViewSnapshot = struct {
    after_content: []const u8,
    lifecycle_id: types.ToolLifecycleId,
};

pub const CommittedFileHandoff = struct {
    preview: diff_mod.FileChangePreview,
    tracker: ChangeTrackerHandoff,
    full_view: ?FullViewSnapshot = null,

    pub fn init(
        preview: diff_mod.FileChangePreview,
        tracker: ChangeTrackerHandoff,
    ) CommittedFileHandoff {
        return .{
            .preview = preview,
            .tracker = tracker,
        };
    }

    pub fn deinit(self: CommittedFileHandoff, alloc: Allocator) void {
        alloc.free(@constCast(self.preview.path));
        for (self.preview.lines) |line| alloc.free(@constCast(line.text));
        alloc.free(@constCast(self.preview.lines));
        alloc.free(@constCast(self.tracker.raw_path));
        if (self.tracker.previous_content) |content| {
            alloc.free(@constCast(content));
        }
        if (self.full_view) |full_view| {
            alloc.free(@constCast(full_view.after_content));
            alloc.free(@constCast(full_view.lifecycle_id.call_id));
        }
    }

    pub fn attachFullView(
        self: *CommittedFileHandoff,
        alloc: Allocator,
        after_content: []const u8,
        lifecycle_id: types.ToolLifecycleId,
    ) Allocator.Error!void {
        const owned_after_content = try alloc.dupe(u8, after_content);
        errdefer alloc.free(owned_after_content);
        const owned_call_id = try alloc.dupe(u8, lifecycle_id.call_id);
        errdefer alloc.free(owned_call_id);

        self.full_view = .{
            .after_content = owned_after_content,
            .lifecycle_id = .{
                .turn_id = lifecycle_id.turn_id,
                .call_id = owned_call_id,
            },
        };
    }
};

pub const ApplyResult = union(enum) {
    rejected: ApplyRejection,
    committed: CommittedFileHandoff,
};

const target_mismatch_message =
    "file mutation preparation failed: approved target no longer matches the call";
const identity_changed_message =
    "file mutation preparation failed: approved filesystem identity changed";
const preview_too_large_message =
    "file mutation preparation failed: diff preview exceeds preparation limits";
const total_content_too_large_message =
    "file mutation preparation failed: content proof exceeds the 8 MiB preparation limit";

const FileMutationPrepareError = error{
    OutOfMemory,
    Canceled,
    Unexpected,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
};

const FileMutationApplyError = error{
    OutOfMemory,
    ResultContractViolation,
};

const PreimageResult = union(enum) {
    preimage: file_mutation_contract.Preimage,
    semantic_failure: []const u8,
};

const PostimageResult = union(enum) {
    content: []const u8,
    semantic_failure: []const u8,
};

const PreviewResult = union(enum) {
    preview: diff_mod.FileChangePreview,
    semantic_failure: []const u8,
};

const CommitClaim = struct {
    claimed: std.atomic.Value(bool) = .init(false),
};

var target_resolution_check_count: usize = 0;

pub fn resetTargetResolutionCheckCountForTest() void {
    if (builtin.is_test) target_resolution_check_count = 0;
}

pub fn targetResolutionCheckCountForTest() usize {
    return if (builtin.is_test) target_resolution_check_count else 0;
}

pub fn prepare(
    call_alloc: std.mem.Allocator,
    call: types.ToolCall,
    input: file_mutation_contract.FileMutationInput,
    policy_targets: file_mutation_contract.PolicyEvaluatedFileTargets,
) FileMutationPrepareError!file_mutation_contract.PrepareResult {
    return prepareInternal(call_alloc, call, input, policy_targets, true);
}

/// Prepares a mutation whose decoded input and canonical target proof were
/// produced together by tool admission. Identity, proof, preimage, and diff
/// validation remain unchanged; only duplicate canonical resolution is skipped.
pub fn prepareResolvedTarget(
    call_alloc: std.mem.Allocator,
    call: types.ToolCall,
    input: file_mutation_contract.FileMutationInput,
    policy_targets: file_mutation_contract.PolicyEvaluatedFileTargets,
) FileMutationPrepareError!file_mutation_contract.PrepareResult {
    return prepareInternal(call_alloc, call, input, policy_targets, false);
}

fn prepareInternal(
    call_alloc: std.mem.Allocator,
    call: types.ToolCall,
    input: file_mutation_contract.FileMutationInput,
    policy_targets: file_mutation_contract.PolicyEvaluatedFileTargets,
    verify_target_resolution: bool,
) FileMutationPrepareError!file_mutation_contract.PrepareResult {
    if (policyIdentityBindingMismatch(policy_targets)) {
        return .{ .semantic_failure = identity_changed_message };
    }
    if (!policy_targets.proofValid()) {
        return .{ .semantic_failure = target_mismatch_message };
    }
    if (verify_target_resolution and !try resolvedTargetMatches(input, policy_targets)) {
        return .{ .semantic_failure = target_mismatch_message };
    }

    const preimage_result = try verifyAndReadPreimage(call_alloc, input, policy_targets);
    const preimage = switch (preimage_result) {
        .preimage => |preimage| preimage,
        .semantic_failure => |message| return .{ .semantic_failure = message },
    };

    const postimage_result = try derivePostimage(call_alloc, input, preimage);
    const after_content = switch (postimage_result) {
        .content => |content| content,
        .semantic_failure => |message| return .{ .semantic_failure = message },
    };
    const before_content = switch (preimage) {
        .absent => "",
        .present => |present| present.content,
    };
    const total_content_bytes = std.math.add(
        usize,
        before_content.len,
        after_content.len,
    ) catch return .{ .semantic_failure = total_content_too_large_message };
    if (total_content_bytes > max_total_content_bytes) {
        return .{ .semantic_failure = total_content_too_large_message };
    }

    // External anchors show the resolved target so a symlink redirect cannot look local.
    const approval_path = switch (policy_targets.anchor.scope) {
        .external => policy_targets.canonical_target_path,
        .workspace => input.path(),
    };
    const encoded_path = text_utils.encodeTerminalSafePathTail(
        call_alloc,
        approval_path,
        diff_mod.max_encoded_path_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PathBasenameTooLong => return .{
            .semantic_failure = preview_too_large_message,
        },
    };
    const preview_result = try buildPreview(
        call_alloc,
        encoded_path,
        preimage,
        before_content,
        after_content,
    );
    const preview = switch (preview_result) {
        .preview => |preview| preview,
        .semantic_failure => |message| return .{ .semantic_failure = message },
    };
    const review = diff_mod.FileReview.init(
        call_alloc,
        before_content,
        after_content,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ArithmeticOverflow => return .{
            .semantic_failure = preview_too_large_message,
        },
    };

    var arguments_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    arguments_hasher.update(call.arguments_json);
    const commit_claim = try call_alloc.create(CommitClaim);
    commit_claim.* = .{};
    return .{ .prepared = .{
        .call_id = call.id,
        .tool_name = call.name,
        .arguments_hash = arguments_hasher.finalResult(),
        .target_path = policy_targets.canonical_target_path,
        .display_path = encoded_path.bytes,
        .policy_targets = policy_targets,
        .kind = std.meta.activeTag(input),
        .preimage = preimage,
        .after_content = after_content,
        .preview = preview,
        .review = review,
        .commit_token = commit_claim,
    } };
}

const ApplyTestControls = struct {
    ctx: ?*anyopaque = null,
    after_write_chunk: ?*const fn (?*anyopaque, usize) anyerror!void = null,
    after_stage: ?*const fn (?*anyopaque, std.Io.Dir, []const u8) anyerror!void = null,
    after_final_preimage_read: ?*const fn (?*anyopaque, std.Io.Dir, []const u8) anyerror!void = null,
    after_final_validation: ?*const fn (?*anyopaque) anyerror!void = null,
};

const CreatedParentRecord = struct {
    component_index: usize,
    path_end: usize,
    permission_target_index: usize,
    identity: file_mutation_contract.FileIdentity,
};

const PreimageValidation = union(enum) {
    valid: ?std.Io.File.Permissions,
    stale,
    io_failure,
};

const TraversalValidation = union(enum) {
    parent: std.Io.Dir,
    changed,
    io_failure,
};

const StagedSourceValidation = enum {
    valid,
    changed,
    io_failure,
};

const TargetEntryValidation = enum {
    valid,
    changed,
    io_failure,
};

const StagedWriteError = error{
    Canceled,
    IoFailure,
};

const ApplyResources = struct {
    policy: PolicyEvaluatedFileTargets,
    created: *[file_mutation_contract.max_file_target_components]CreatedParentRecord,
    realized: *[file_mutation_contract.max_file_target_components]file_mutation_contract.FileIdentity,
    residue_storage: []CreatedParentResidue,
    created_count: usize = 0,
    parent: ?std.Io.Dir = null,
    temp_name: ?[]const u8 = null,
    temp_identity: ?file_mutation_contract.FileIdentity = null,

    fn closeParent(self: *ApplyResources) void {
        if (self.parent) |parent| parent.close(io_mod.getIo());
        self.parent = null;
    }

    fn reject(
        self: *ApplyResources,
        reason: ApplyRejectionReason,
    ) ApplyResult {
        self.cleanupTemp();
        self.closeParent();
        const residues = self.cleanupCreatedParents();
        return .{ .rejected = .{
            .reason = reason,
            .created_parent_residue = residues,
        } };
    }

    fn cleanupTemp(self: *ApplyResources) void {
        const parent = self.parent orelse return;
        const temp_name = self.temp_name orelse return;
        const expected_identity = self.temp_identity orelse return;
        const actual_identity = observedFileIdentity(parent, temp_name) orelse return;
        if (!identityEql(actual_identity, expected_identity)) return;
        parent.deleteFile(io_mod.getIo(), temp_name) catch return;
        self.temp_name = null;
        self.temp_identity = null;
    }

    fn cleanupCreatedParents(
        self: *ApplyResources,
    ) []const CreatedParentResidue {
        var residue_count: usize = 0;
        var index = self.created_count;
        while (index > 0) {
            index -= 1;
            const created = self.created[index];
            if (cleanupCreatedParent(self.policy, self.realized, created)) |residue| {
                self.residue_storage[residue_count] = residue;
                residue_count += 1;
            }
        }
        return self.residue_storage[0..residue_count];
    }
};

pub fn apply(
    call_alloc: std.mem.Allocator,
    result_alloc: std.mem.Allocator,
    call: types.ToolCall,
    authorization: file_mutation_contract.FileExecutionAuthorization,
    cancel_flag: *std.atomic.Value(bool),
) FileMutationApplyError!ApplyResult {
    return applyWithTestControls(
        call_alloc,
        result_alloc,
        call,
        authorization,
        cancel_flag,
        .{},
    );
}

fn applyWithTestControls(
    call_alloc: std.mem.Allocator,
    result_alloc: std.mem.Allocator,
    call: types.ToolCall,
    authorization: file_mutation_contract.FileExecutionAuthorization,
    cancel_flag: *std.atomic.Value(bool),
    test_controls: ApplyTestControls,
) FileMutationApplyError!ApplyResult {
    const prepared = authorization.prepared orelse {
        return rejectedWithoutResidue(.binding_mismatch);
    };
    if (!applyBindingValid(call, authorization.policy_targets, prepared)) {
        return rejectedWithoutResidue(.binding_mismatch);
    }
    const commit_claim = preparedCommitClaim(prepared);
    if (commit_claim.claimed.load(.seq_cst)) {
        return error.ResultContractViolation;
    }
    if (cancel_flag.load(.seq_cst)) return rejectedWithoutResidue(.cancelled);

    const residue_storage = try call_alloc.alloc(
        CreatedParentResidue,
        prepared.policy_targets.traversal_directories.len,
    );
    const previous_content = switch (prepared.preimage) {
        .absent => null,
        .present => |present| present.content,
    };
    var handoff = try dupeCommittedFileHandoff(
        result_alloc,
        prepared.preview,
        prepared.kind,
        prepared.target_path,
        previous_content,
    );
    var handoff_owned = true;
    defer if (handoff_owned) handoff.deinit(result_alloc);

    var created: [file_mutation_contract.max_file_target_components]CreatedParentRecord =
        undefined;
    var realized: [file_mutation_contract.max_file_target_components]file_mutation_contract.FileIdentity =
        undefined;
    var resources: ApplyResources = .{
        .policy = prepared.policy_targets,
        .created = &created,
        .realized = &realized,
        .residue_storage = residue_storage,
    };
    defer resources.closeParent();

    io_mod.e2eFailIfDurableMutationAttempted();
    if (realizeTraversal(&resources)) |reason| return resources.reject(reason);
    const parent = resources.parent.?;
    const target_name = prepared.policy_targets.component(
        prepared.policy_targets.anchor.relative_components[
            prepared.policy_targets.anchor.relative_components.len - 1
        ],
    );

    const initial_preimage = validatePreimage(
        parent,
        target_name,
        prepared,
        null,
        null,
        null,
    );
    const destination_permissions = switch (initial_preimage) {
        .valid => |permissions| permissions,
        .stale => return resources.reject(.stale_preimage),
        .io_failure => return resources.reject(.io_failure),
    };

    var random_bytes: [16]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);
    var temp_name_buffer: [".fx-stage-".len + suffix.len]u8 = undefined;
    @memcpy(temp_name_buffer[0..".fx-stage-".len], ".fx-stage-");
    @memcpy(temp_name_buffer[".fx-stage-".len..], suffix[0..]);
    const temp_name = temp_name_buffer[0..];

    var stage = parent.createFile(io_mod.getIo(), temp_name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = destination_permissions orelse .default_file,
        .resolve_beneath = true,
    }) catch return resources.reject(.io_failure);
    resources.temp_name = temp_name;
    defer stage.close(io_mod.getIo());

    const initial_stage_stat = stage.stat(io_mod.getIo()) catch
        return resources.reject(.io_failure);
    if (initial_stage_stat.kind != .file or initial_stage_stat.nlink != 1) {
        return resources.reject(.staged_source_changed);
    }
    resources.temp_identity = pathing.fileIdentity(
        pathing.descriptorDevice(stage.handle) catch return resources.reject(.io_failure),
        initial_stage_stat,
    );
    if (destination_permissions) |permissions| {
        stage.setPermissions(io_mod.getIo(), permissions) catch
            return resources.reject(.io_failure);
    }
    writeStagedContent(
        &stage,
        prepared.after_content,
        cancel_flag,
        test_controls,
    ) catch |err| {
        return resources.reject(switch (err) {
            error.Canceled => .cancelled,
            error.IoFailure => .io_failure,
        });
    };
    stage.sync(io_mod.getIo()) catch return resources.reject(.io_failure);
    if (cancel_flag.load(.seq_cst)) return resources.reject(.cancelled);

    if (test_controls.after_stage) |after_stage| {
        after_stage(test_controls.ctx, parent, temp_name) catch
            return resources.reject(.io_failure);
    }
    if (!applyBindingValid(call, authorization.policy_targets, prepared)) {
        return resources.reject(.binding_mismatch);
    }
    if (cancel_flag.load(.seq_cst)) return resources.reject(.cancelled);

    switch (validatePreimage(
        parent,
        target_name,
        prepared,
        destination_permissions,
        test_controls.ctx,
        test_controls.after_final_preimage_read,
    )) {
        .valid => {},
        .stale => return resources.reject(.stale_preimage),
        .io_failure => return resources.reject(.io_failure),
    }
    switch (validateStagedSource(
        parent,
        temp_name,
        &stage,
        resources.temp_identity.?,
        prepared.after_content,
    )) {
        .valid => {},
        .changed => return resources.reject(.staged_source_changed),
        .io_failure => return resources.reject(.io_failure),
    }
    if (cancel_flag.load(.seq_cst)) return resources.reject(.cancelled);

    const revalidated = revalidateTraversal(&resources);
    var commit_parent = switch (revalidated) {
        .parent => |revalidated_parent| revalidated_parent,
        .changed => return resources.reject(.traversal_changed),
        .io_failure => return resources.reject(.io_failure),
    };
    defer commit_parent.close(io_mod.getIo());

    switch (validateTargetEntry(
        commit_parent,
        target_name,
        prepared.policy_targets.items[0].expected_identity,
    )) {
        .valid => {},
        .changed => return resources.reject(.stale_preimage),
        .io_failure => return resources.reject(.io_failure),
    }
    switch (validateStagedSourceIdentity(
        commit_parent,
        temp_name,
        &stage,
        resources.temp_identity.?,
        prepared.after_content.len,
    )) {
        .valid => {},
        .changed => return resources.reject(.staged_source_changed),
        .io_failure => return resources.reject(.io_failure),
    }
    if (cancel_flag.load(.seq_cst)) return resources.reject(.cancelled);
    if (test_controls.after_final_validation) |after_final_validation| {
        after_final_validation(test_controls.ctx) catch
            return resources.reject(.io_failure);
    }
    if (commit_claim.claimed.cmpxchgStrong(
        false,
        true,
        .seq_cst,
        .seq_cst,
    ) != null) {
        resources.cleanupTemp();
        resources.closeParent();
        _ = resources.cleanupCreatedParents();
        return error.ResultContractViolation;
    }

    // The fresh descriptor binds the final entry checks and rename to the
    // revalidated parent. The platform cannot freeze its namespace after
    // these checks, so a competing move can still win the remaining window.
    commit_parent.rename(
        temp_name,
        commit_parent,
        target_name,
        io_mod.getIo(),
    ) catch return resources.reject(.io_failure);
    resources.temp_name = null;
    resources.temp_identity = null;
    resources.closeParent();

    handoff.tracker.committed_at_ms = io_mod.milliTimestamp();
    handoff_owned = false;
    return .{ .committed = handoff };
}

fn preparedCommitClaim(prepared: PreparedFileMutation) *CommitClaim {
    return @ptrCast(@alignCast(prepared.commit_token));
}

fn dupeCommittedFileHandoff(
    alloc: Allocator,
    preview: diff_mod.FileChangePreview,
    kind: file_mutation_contract.Kind,
    raw_path: []const u8,
    previous_content: ?[]const u8,
) Allocator.Error!CommittedFileHandoff {
    const owned_path = try alloc.dupe(u8, preview.path);
    errdefer alloc.free(owned_path);

    const owned_lines = try alloc.alloc(
        diff_mod.PreviewLine,
        preview.lines.len,
    );
    errdefer alloc.free(owned_lines);
    var initialized_lines: usize = 0;
    errdefer for (owned_lines[0..initialized_lines]) |line| {
        alloc.free(@constCast(line.text));
    };
    for (preview.lines, owned_lines) |source, *destination| {
        destination.* = source;
        destination.text = try alloc.dupe(u8, source.text);
        initialized_lines += 1;
    }

    const owned_raw_path = try alloc.dupe(u8, raw_path);
    errdefer alloc.free(owned_raw_path);
    const owned_previous_content = if (previous_content) |content|
        try alloc.dupe(u8, content)
    else
        null;
    errdefer if (owned_previous_content) |content| alloc.free(content);

    return CommittedFileHandoff.init(
        .{
            .path = owned_path,
            .lines = owned_lines,
            .additions = preview.additions,
            .deletions = preview.deletions,
            .truncated = preview.truncated,
        },
        .{
            .kind = kind,
            .raw_path = owned_raw_path,
            .previous_content = owned_previous_content,
            .committed_at_ms = 0,
        },
    );
}

fn writeStagedContent(
    stage: *std.Io.File,
    content: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    test_controls: ApplyTestControls,
) StagedWriteError!void {
    const chunk_bytes: usize = 64 * 1024;
    var offset: usize = 0;
    while (offset < content.len) {
        if (cancel_flag.load(.seq_cst)) return error.Canceled;
        const end = @min(offset + chunk_bytes, content.len);
        stage.writeStreamingAll(io_mod.getIo(), content[offset..end]) catch
            return error.IoFailure;
        offset = end;
        if (test_controls.after_write_chunk) |after_write_chunk| {
            after_write_chunk(test_controls.ctx, offset) catch return error.IoFailure;
        }
    }
    if (cancel_flag.load(.seq_cst)) return error.Canceled;
}

fn rejectedWithoutResidue(
    reason: ApplyRejectionReason,
) ApplyResult {
    return .{ .rejected = .{
        .reason = reason,
        .created_parent_residue = &.{},
    } };
}

fn validateStagedSource(
    parent: std.Io.Dir,
    temp_name: []const u8,
    stage: *std.Io.File,
    expected_identity: file_mutation_contract.FileIdentity,
    expected_content: []const u8,
) StagedSourceValidation {
    switch (validateStagedSourceIdentity(
        parent,
        temp_name,
        stage,
        expected_identity,
        expected_content.len,
    )) {
        .valid => {},
        .changed => return .changed,
        .io_failure => return .io_failure,
    }

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var reader_buffer: [8192]u8 = undefined;
    var reader = stage.reader(io_mod.getIo(), &reader_buffer);
    reader.seekTo(0) catch return .io_failure;
    var chunk: [8192]u8 = undefined;
    while (true) {
        const bytes_read = reader.interface.readSliceShort(&chunk) catch
            return .io_failure;
        if (bytes_read == 0) break;
        hasher.update(chunk[0..bytes_read]);
    }

    var expected_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    expected_hasher.update(expected_content);
    if (!std.mem.eql(
        u8,
        &hasher.finalResult(),
        &expected_hasher.finalResult(),
    )) return .changed;
    return .valid;
}

fn validateStagedSourceIdentity(
    parent: std.Io.Dir,
    temp_name: []const u8,
    stage: *std.Io.File,
    expected_identity: file_mutation_contract.FileIdentity,
    expected_size: usize,
) StagedSourceValidation {
    const zio = io_mod.getIo();
    const stat = stage.stat(zio) catch return .io_failure;
    if (stat.kind != .file or
        stat.nlink != 1 or
        stat.size != expected_size)
    {
        return .changed;
    }
    const handle_identity = pathing.fileIdentity(
        pathing.descriptorDevice(stage.handle) catch return .io_failure,
        stat,
    );
    if (!identityEql(handle_identity, expected_identity)) return .changed;

    const named_identity = observedFileIdentity(parent, temp_name) orelse
        return .changed;
    if (!identityEql(named_identity, expected_identity)) return .changed;
    return .valid;
}

fn applyBindingValid(
    call: types.ToolCall,
    policy: PolicyEvaluatedFileTargets,
    prepared: PreparedFileMutation,
) bool {
    if (!std.mem.eql(u8, call.id, prepared.call_id)) return false;
    if (!std.mem.eql(u8, call.name, prepared.tool_name)) return false;
    const expected_kind: file_mutation_contract.Kind =
        if (std.mem.eql(u8, call.name, "write_file"))
            .write
        else if (std.mem.eql(u8, call.name, "edit_file"))
            .edit
        else
            return false;
    if (prepared.kind != expected_kind) return false;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(call.arguments_json);
    if (!std.mem.eql(u8, &hasher.finalResult(), &prepared.arguments_hash)) {
        return false;
    }
    if (!PolicyEvaluatedFileTargets.authorizationEql(policy, prepared.policy_targets)) {
        return false;
    }
    if (!policy.proofValid()) return false;
    if (!std.mem.eql(u8, prepared.target_path, policy.canonical_target_path)) {
        return false;
    }
    if (!std.mem.eql(u8, prepared.display_path, prepared.preview.path)) return false;
    prepared.preview.validate() catch return false;
    if (prepared.after_content.len > max_content_bytes) return false;
    switch (prepared.preimage) {
        .absent => {},
        .present => |present| {
            if (present.content.len > max_content_bytes) return false;
            var content_hasher = std.crypto.hash.sha2.Sha256.init(.{});
            content_hasher.update(present.content);
            if (!std.mem.eql(
                u8,
                &content_hasher.finalResult(),
                &present.content_hash,
            )) return false;
        },
    }
    return true;
}

fn realizeTraversal(
    resources: *ApplyResources,
) ?ApplyRejectionReason {
    const zio = io_mod.getIo();
    var current = std.Io.Dir.openDirAbsolute(
        zio,
        resources.policy.anchorPath(),
        .{ .follow_symlinks = false },
    ) catch |err| return if (pathStateChanged(err)) .traversal_changed else .io_failure;

    const anchor_identity = pathing.directoryIdentity(current) catch {
        current.close(zio);
        return .io_failure;
    };
    if (!identityEql(anchor_identity, resources.policy.anchor.identity)) {
        current.close(zio);
        return .traversal_changed;
    }

    for (resources.policy.traversal_directories, 0..) |entry, index| {
        const component = resources.policy.component(
            resources.policy.anchor.relative_components[entry.component_index],
        );
        switch (entry.state) {
            .existing => |expected_identity| {
                const next = current.openDir(
                    zio,
                    component,
                    .{ .follow_symlinks = false },
                ) catch |err| {
                    current.close(zio);
                    return if (pathStateChanged(err)) .traversal_changed else .io_failure;
                };
                const actual_identity = pathing.directoryIdentity(next) catch {
                    next.close(zio);
                    current.close(zio);
                    return .io_failure;
                };
                if (!identityEql(actual_identity, expected_identity)) {
                    next.close(zio);
                    current.close(zio);
                    return .traversal_changed;
                }
                resources.realized[index] = actual_identity;
                current.close(zio);
                current = next;
            },
            .create => |create| {
                current.createDir(zio, component, .default_dir) catch |err| {
                    current.close(zio);
                    return if (pathStateChanged(err) or err == error.PathAlreadyExists)
                        .traversal_changed
                    else
                        .io_failure;
                };
                const next = current.openDir(
                    zio,
                    component,
                    .{ .follow_symlinks = false },
                ) catch {
                    current.deleteDir(zio, component) catch {};
                    current.close(zio);
                    return .io_failure;
                };
                const actual_identity = pathing.directoryIdentity(next) catch {
                    next.close(zio);
                    current.deleteDir(zio, component) catch {};
                    current.close(zio);
                    return .io_failure;
                };
                resources.realized[index] = actual_identity;
                resources.created[resources.created_count] = .{
                    .component_index = entry.component_index,
                    .path_end = entry.path_end,
                    .permission_target_index = create.permission_target_index,
                    .identity = actual_identity,
                };
                resources.created_count += 1;
                current.close(zio);
                current = next;
            },
        }
    }
    resources.parent = current;
    return null;
}

fn revalidateTraversal(resources: *ApplyResources) TraversalValidation {
    const zio = io_mod.getIo();
    var current = std.Io.Dir.openDirAbsolute(
        zio,
        resources.policy.anchorPath(),
        .{ .follow_symlinks = false },
    ) catch |err| return if (pathStateChanged(err)) .changed else .io_failure;

    const anchor_identity = pathing.directoryIdentity(current) catch {
        current.close(zio);
        return .io_failure;
    };
    if (!identityEql(anchor_identity, resources.policy.anchor.identity)) {
        current.close(zio);
        return .changed;
    }

    for (resources.policy.traversal_directories, 0..) |entry, index| {
        const component = resources.policy.component(
            resources.policy.anchor.relative_components[entry.component_index],
        );
        const next = current.openDir(
            zio,
            component,
            .{ .follow_symlinks = false },
        ) catch |err| {
            current.close(zio);
            return if (pathStateChanged(err)) .changed else .io_failure;
        };
        const actual_identity = pathing.directoryIdentity(next) catch {
            next.close(zio);
            current.close(zio);
            return .io_failure;
        };
        if (!identityEql(actual_identity, resources.realized[index])) {
            next.close(zio);
            current.close(zio);
            return .changed;
        }
        current.close(zio);
        current = next;
    }
    return .{ .parent = current };
}

fn validatePreimage(
    parent: std.Io.Dir,
    target_name: []const u8,
    prepared: PreparedFileMutation,
    expected_permissions: ?std.Io.File.Permissions,
    test_control_ctx: ?*anyopaque,
    after_present_read: ?*const fn (?*anyopaque, std.Io.Dir, []const u8) anyerror!void,
) PreimageValidation {
    const zio = io_mod.getIo();
    return switch (prepared.preimage) {
        .absent => blk: {
            _ = parent.statFile(
                zio,
                target_name,
                .{ .follow_symlinks = false },
            ) catch |err| switch (err) {
                error.FileNotFound => break :blk .{ .valid = null },
                else => break :blk if (pathStateChanged(err)) .stale else .io_failure,
            };
            break :blk .stale;
        },
        .present => |expected| blk: {
            var file = parent.openFile(zio, target_name, .{
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            }) catch |err| break :blk if (pathStateChanged(err)) .stale else .io_failure;
            defer file.close(zio);

            const stat = file.stat(zio) catch break :blk .io_failure;
            if (stat.kind != .file or stat.size != expected.content.len) {
                break :blk .stale;
            }
            const actual_identity = pathing.fileIdentity(
                pathing.descriptorDevice(file.handle) catch break :blk .io_failure,
                stat,
            );
            const expected_identity = prepared.policy_targets.items[0].expected_identity orelse
                break :blk .stale;
            if (!identityEql(actual_identity, expected_identity)) break :blk .stale;
            if (!io_mod.permissionsWritable(stat.permissions)) break :blk .io_failure;
            if (expected_permissions) |permissions| {
                if (io_mod.permissionsMode(stat.permissions) != io_mod.permissionsMode(permissions)) break :blk .stale;
            }

            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            var read_buffer: [8192]u8 = undefined;
            var reader = file.reader(zio, &read_buffer);
            var chunk: [8192]u8 = undefined;
            while (true) {
                const bytes_read = reader.interface.readSliceShort(&chunk) catch
                    break :blk .io_failure;
                if (bytes_read == 0) break;
                hasher.update(chunk[0..bytes_read]);
            }
            if (!std.mem.eql(u8, &hasher.finalResult(), &expected.content_hash)) {
                break :blk .stale;
            }
            if (after_present_read) |after_read| {
                after_read(test_control_ctx, parent, target_name) catch
                    break :blk .io_failure;
            }
            switch (validateTargetEntry(parent, target_name, actual_identity)) {
                .valid => {},
                .changed => break :blk .stale,
                .io_failure => break :blk .io_failure,
            }
            break :blk .{ .valid = stat.permissions };
        },
    };
}

fn validateTargetEntry(
    parent: std.Io.Dir,
    name: []const u8,
    expected_identity: ?file_mutation_contract.FileIdentity,
) TargetEntryValidation {
    const zio = io_mod.getIo();
    if (expected_identity == null) {
        _ = parent.statFile(
            zio,
            name,
            .{ .follow_symlinks = false },
        ) catch |err| return switch (err) {
            error.FileNotFound => .valid,
            else => if (pathStateChanged(err)) .changed else .io_failure,
        };
        return .changed;
    }

    var file = parent.openFile(zio, name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .path_only = true,
        .resolve_beneath = true,
    }) catch |err| return if (pathStateChanged(err)) .changed else .io_failure;
    defer file.close(zio);
    const stat = file.stat(zio) catch return .io_failure;
    if (stat.kind != .file) return .changed;
    const actual_identity = pathing.fileIdentity(
        pathing.descriptorDevice(file.handle) catch return .io_failure,
        stat,
    );
    return if (identityEql(actual_identity, expected_identity.?))
        .valid
    else
        .changed;
}

fn observedFileIdentity(
    parent: std.Io.Dir,
    name: []const u8,
) ?file_mutation_contract.FileIdentity {
    var file = parent.openFile(io_mod.getIo(), name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .path_only = true,
        .resolve_beneath = true,
    }) catch return null;
    defer file.close(io_mod.getIo());
    const stat = file.stat(io_mod.getIo()) catch return null;
    if (stat.kind != .file or stat.nlink != 1) return null;
    return pathing.fileIdentity(
        pathing.descriptorDevice(file.handle) catch return null,
        stat,
    );
}

fn cleanupCreatedParent(
    policy: PolicyEvaluatedFileTargets,
    realized: *const [file_mutation_contract.max_file_target_components]file_mutation_contract.FileIdentity,
    created: CreatedParentRecord,
) ?CreatedParentResidue {
    const zio = io_mod.getIo();
    var current = std.Io.Dir.openDirAbsolute(
        zio,
        policy.anchorPath(),
        .{ .follow_symlinks = false },
    ) catch return createdParentResidue(created, null, .identity_changed);

    const anchor_identity = pathing.directoryIdentity(current) catch {
        current.close(zio);
        return createdParentResidue(created, null, .identity_changed);
    };
    if (!identityEql(anchor_identity, policy.anchor.identity)) {
        current.close(zio);
        return createdParentResidue(created, null, .identity_changed);
    }

    for (policy.traversal_directories[0..created.component_index], 0..) |entry, index| {
        const component = policy.component(
            policy.anchor.relative_components[entry.component_index],
        );
        const next = current.openDir(
            zio,
            component,
            .{ .follow_symlinks = false },
        ) catch {
            current.close(zio);
            return createdParentResidue(created, null, .identity_changed);
        };
        const actual_identity = pathing.directoryIdentity(next) catch {
            next.close(zio);
            current.close(zio);
            return createdParentResidue(created, null, .identity_changed);
        };
        if (!identityEql(actual_identity, realized[index])) {
            next.close(zio);
            current.close(zio);
            return createdParentResidue(created, null, .identity_changed);
        }
        current.close(zio);
        current = next;
    }
    defer current.close(zio);

    const component = policy.component(
        policy.anchor.relative_components[created.component_index],
    );
    const child = current.openDir(
        zio,
        component,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return createdParentResidue(created, null, .identity_changed),
    };
    const observed = pathing.directoryIdentity(child) catch {
        child.close(zio);
        return createdParentResidue(created, null, .identity_changed);
    };
    child.close(zio);
    if (!identityEql(observed, created.identity)) {
        return createdParentResidue(created, observed, .identity_changed);
    }

    current.deleteDir(zio, component) catch |err| return createdParentResidue(
        created,
        observed,
        if (err == error.DirNotEmpty) .not_empty else .remove_failed,
    );
    return null;
}

fn createdParentResidue(
    created: CreatedParentRecord,
    observed_identity: ?file_mutation_contract.FileIdentity,
    reason: ParentCleanupResidueReason,
) CreatedParentResidue {
    return .{
        .component_index = created.component_index,
        .path_end = created.path_end,
        .permission_target_index = created.permission_target_index,
        .created_identity = created.identity,
        .observed_identity = observed_identity,
        .reason = reason,
    };
}

fn pathStateChanged(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound,
        error.NotDir,
        error.SymLinkLoop,
        error.PathAlreadyExists,
        error.IsDir,
        => true,
        else => false,
    };
}

fn policyIdentityBindingMismatch(policy: PolicyEvaluatedFileTargets) bool {
    if (policy.items.len < 2) return false;
    const parent_item = policy.items[1];
    if (parent_item.kind != .parent) return false;

    if (policy.traversal_directories.len == 0) {
        if (parent_item.disposition != .existing_parent or
            parent_item.path_end != policy.anchor.path_end)
        {
            return false;
        }
        return !optionalIdentityEql(
            parent_item.expected_identity,
            policy.anchor.identity,
        );
    }

    const parent = policy.traversal_directories[
        policy.traversal_directories.len - 1
    ];
    return switch (parent.state) {
        .existing => |identity| parent_item.disposition == .existing_parent and
            parent_item.path_end == parent.path_end and
            !optionalIdentityEql(parent_item.expected_identity, identity),
        .create => parent_item.disposition == .create_parent and
            parent_item.path_end == parent.path_end and
            parent_item.expected_identity != null,
    };
}

fn checkedCharge(base: usize, count: usize, item_size: usize) ?usize {
    const bytes = std.math.mul(usize, count, item_size) catch return null;
    return std.math.add(usize, base, bytes) catch null;
}

fn resolvedTargetMatches(
    input: file_mutation_contract.FileMutationInput,
    policy: PolicyEvaluatedFileTargets,
) FileMutationPrepareError!bool {
    if (builtin.is_test) target_resolution_check_count += 1;
    var primary_path_scratch: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var secondary_path_scratch: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var component_scratch: [file_mutation_contract.max_file_target_components]pathing.BoundedFileTargetComponent =
        undefined;
    const resolved = pathing.resolveFileMutationTargetBounded(
        policy.anchorPath(),
        input.path(),
        switch (input) {
            .write => .create,
            .edit => .existing,
        },
        &primary_path_scratch,
        &secondary_path_scratch,
        &component_scratch,
    ) catch |err| {
        if (operationalError(err)) |operational| return operational;
        return false;
    };

    if (!std.mem.eql(
        u8,
        resolved.canonical_target_path,
        policy.canonical_target_path,
    )) return false;
    if (resolved.anchor_path_end != policy.anchor.path_end) return false;
    if (resolved.relative_components.len != policy.anchor.relative_components.len) {
        return false;
    }
    for (resolved.relative_components, policy.anchor.relative_components) |actual, expected| {
        if (actual.start != expected.start or actual.end != expected.end) return false;
    }
    return true;
}

fn verifyAndReadPreimage(
    alloc: Allocator,
    input: file_mutation_contract.FileMutationInput,
    policy: PolicyEvaluatedFileTargets,
) FileMutationPrepareError!PreimageResult {
    const zio = io_mod.getIo();
    var current_dir = std.Io.Dir.openDirAbsolute(
        zio,
        policy.anchorPath(),
        .{ .follow_symlinks = false },
    ) catch |err| {
        if (operationalError(err)) |operational| return operational;
        return .{ .semantic_failure = identity_changed_message };
    };
    defer current_dir.close(zio);

    const anchor_identity = pathing.directoryIdentity(current_dir) catch |err| {
        if (operationalError(err)) |operational| return operational;
        return .{ .semantic_failure = identity_changed_message };
    };
    if (!identityEql(anchor_identity, policy.anchor.identity)) {
        return .{ .semantic_failure = identity_changed_message };
    }

    var missing_parent_seen = false;
    for (policy.traversal_directories) |entry| {
        const component = policy.component(
            policy.anchor.relative_components[entry.component_index],
        );
        switch (entry.state) {
            .existing => |expected_identity| {
                if (missing_parent_seen) {
                    return .{ .semantic_failure = identity_changed_message };
                }
                const next_dir = current_dir.openDir(
                    zio,
                    component,
                    .{ .follow_symlinks = false },
                ) catch |err| {
                    if (operationalError(err)) |operational| return operational;
                    return .{ .semantic_failure = identity_changed_message };
                };
                const actual_identity = pathing.directoryIdentity(next_dir) catch |err| {
                    next_dir.close(zio);
                    if (operationalError(err)) |operational| return operational;
                    return .{ .semantic_failure = identity_changed_message };
                };
                if (!identityEql(actual_identity, expected_identity)) {
                    next_dir.close(zio);
                    return .{ .semantic_failure = identity_changed_message };
                }
                current_dir.close(zio);
                current_dir = next_dir;
            },
            .create => {
                if (missing_parent_seen) continue;
                _ = current_dir.statFile(
                    zio,
                    component,
                    .{ .follow_symlinks = false },
                ) catch |err| switch (err) {
                    error.FileNotFound => {
                        missing_parent_seen = true;
                        continue;
                    },
                    else => {
                        if (operationalError(err)) |operational| return operational;
                        return .{ .semantic_failure = identity_changed_message };
                    },
                };
                return .{ .semantic_failure = identity_changed_message };
            },
        }
    }

    const target_span = policy.anchor.relative_components[
        policy.anchor.relative_components.len - 1
    ];
    const target_name = policy.component(target_span);
    const expected_target_identity = policy.items[0].expected_identity;
    if (missing_parent_seen) {
        if (expected_target_identity != null or input != .write) {
            return .{ .semantic_failure = identity_changed_message };
        }
        return .{ .preimage = .absent };
    }

    const path_stat = current_dir.statFile(
        zio,
        target_name,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => {
            if (expected_target_identity != null or input != .write) {
                return .{ .semantic_failure = identity_changed_message };
            }
            return .{ .preimage = .absent };
        },
        else => {
            if (operationalError(err)) |operational| return operational;
            return .{ .semantic_failure = identity_changed_message };
        },
    };
    const expected_identity = expected_target_identity orelse {
        return .{ .semantic_failure = identity_changed_message };
    };
    if (path_stat.kind != .file or expected_identity.kind != .file) {
        return .{ .semantic_failure = "file mutation preparation failed: target is not a regular file" };
    }

    var file = current_dir.openFile(zio, target_name, .{
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| {
        if (operationalError(err)) |operational| return operational;
        return .{ .semantic_failure = identity_changed_message };
    };
    defer file.close(zio);

    const file_stat = file.stat(zio) catch |err| {
        if (operationalError(err)) |operational| return operational;
        return .{ .semantic_failure = identity_changed_message };
    };
    const actual_identity: file_mutation_contract.FileIdentity = .{
        .device = try pathing.descriptorDevice(file.handle),
        .inode = @intCast(file_stat.inode),
        .kind = file_stat.kind,
    };
    if (!identityEql(actual_identity, expected_identity)) {
        return .{ .semantic_failure = identity_changed_message };
    }

    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(zio, &read_buf);
    const content = reader.interface.allocRemaining(
        alloc,
        .limited(max_content_bytes + 1),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return .{ .semantic_failure = "file mutation preparation failed: preimage exceeds the 4 MiB preparation limit" },
        error.ReadFailed => {
            const root = reader.err orelse return error.Unexpected;
            if (operationalError(root)) |operational| return operational;
            return .{ .semantic_failure = "file mutation preparation failed: unable to read the approved preimage" };
        },
    };
    if (content.len > max_content_bytes) {
        return .{ .semantic_failure = "file mutation preparation failed: preimage exceeds the 4 MiB preparation limit" };
    }

    var content_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    content_hasher.update(content);
    return .{ .preimage = .{ .present = .{
        .content = content,
        .content_hash = content_hasher.finalResult(),
    } } };
}

fn derivePostimage(
    alloc: Allocator,
    input: file_mutation_contract.FileMutationInput,
    preimage: file_mutation_contract.Preimage,
) error{OutOfMemory}!PostimageResult {
    return switch (input) {
        .write => |write| .{
            .content = try alloc.dupe(u8, write.content),
        },
        .edit => |edit| blk: {
            if (std.mem.eql(u8, edit.old_string, edit.new_string)) {
                break :blk .{ .semantic_failure = "edit_file failed: old_string and new_string are identical" };
            }
            const before = switch (preimage) {
                .absent => break :blk .{ .semantic_failure = identity_changed_message },
                .present => |present| present.content,
            };
            const occurrence_count = countOccurrences(before, edit.old_string);
            if (occurrence_count == 0) {
                break :blk .{ .semantic_failure = "edit_file failed: old_string not found in file" };
            }
            if (occurrence_count > 1) {
                break :blk .{ .semantic_failure = try std.fmt.allocPrint(
                    alloc,
                    "edit_file failed: old_string is not unique (found {d} occurrences), provide more context",
                    .{occurrence_count},
                ) };
            }

            const match_start = std.mem.find(
                u8,
                before,
                edit.old_string,
            ).?;
            const prefix_len = match_start;
            const suffix_start = match_start + edit.old_string.len;
            var after_len = std.math.add(
                usize,
                prefix_len,
                edit.new_string.len,
            ) catch break :blk .{ .semantic_failure = "edit_file failed: postimage exceeds the 4 MiB preparation limit" };
            after_len = std.math.add(
                usize,
                after_len,
                before.len - suffix_start,
            ) catch break :blk .{ .semantic_failure = "edit_file failed: postimage exceeds the 4 MiB preparation limit" };
            if (after_len > max_content_bytes) {
                break :blk .{ .semantic_failure = "edit_file failed: postimage exceeds the 4 MiB preparation limit" };
            }

            const after = try alloc.alloc(u8, after_len);
            @memcpy(after[0..prefix_len], before[0..prefix_len]);
            const replacement_end = prefix_len + edit.new_string.len;
            @memcpy(after[prefix_len..replacement_end], edit.new_string);
            @memcpy(after[replacement_end..], before[suffix_start..]);
            break :blk .{ .content = after };
        },
    };
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.find(u8, haystack[index..], needle)) |relative| {
        count += 1;
        index += relative + needle.len;
    }
    return count;
}

fn buildPreview(
    alloc: Allocator,
    display_path: text_utils.EncodedPathTail,
    preimage: file_mutation_contract.Preimage,
    before_content: []const u8,
    after_content: []const u8,
) error{OutOfMemory}!PreviewResult {
    var projection = diff_mod.buildBoundedPreview(
        alloc,
        before_content,
        after_content,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPreviewOptions,
        error.PreviewBudgetExceeded,
        error.ArithmeticOverflow,
        => return .{ .semantic_failure = preview_too_large_message },
    };

    const lines = if (projection.additions == 0 and projection.deletions == 0) blk: {
        projection.deinit(alloc);
        const notice = switch (preimage) {
            .absent => if (after_content.len == 0) "empty file" else "no content changes",
            .present => "no content changes",
        };
        const notice_text = try alloc.dupe(u8, notice);
        errdefer alloc.free(notice_text);
        const notice_lines = try alloc.alloc(diff_mod.PreviewLine, 1);
        notice_lines[0] = .{ .op = .notice, .text = notice_text };
        break :blk notice_lines;
    } else blk: {
        const preview_lines = alloc.alloc(
            diff_mod.PreviewLine,
            projection.lines.len,
        ) catch |err| {
            projection.deinit(alloc);
            return err;
        };
        for (projection.lines, preview_lines) |source, *destination| {
            destination.* = .{
                .op = switch (source.op) {
                    .context => .context,
                    .addition => .addition,
                    .deletion => .deletion,
                    .elision => .elision,
                    .notice => .notice,
                },
                .old_line = source.old_line,
                .new_line = source.new_line,
                .text = source.text,
            };
        }
        alloc.free(projection.lines);
        break :blk preview_lines;
    };

    const preview: diff_mod.FileChangePreview = .{
        .path = display_path.bytes,
        .path_basename_start = display_path.basename_start,
        .path_source_truncated = display_path.source_truncated,
        .lines = lines,
        .additions = projection.additions,
        .deletions = projection.deletions,
        .truncated = projection.truncated,
    };
    preview.validate() catch return .{ .semantic_failure = preview_too_large_message };

    var projection_charge = display_path.bytes.len;
    projection_charge = checkedCharge(
        projection_charge,
        lines.len,
        @sizeOf(diff_mod.PreviewLine),
    ) orelse return .{ .semantic_failure = preview_too_large_message };
    for (lines) |line| {
        projection_charge = std.math.add(
            usize,
            projection_charge,
            line.text.len,
        ) catch return .{ .semantic_failure = preview_too_large_message };
    }
    if (projection_charge > diff_mod.max_request_projection_bytes) {
        return .{ .semantic_failure = preview_too_large_message };
    }
    return .{ .preview = preview };
}

fn identityEql(
    a: file_mutation_contract.FileIdentity,
    b: file_mutation_contract.FileIdentity,
) bool {
    return a.device == b.device and a.inode == b.inode and a.kind == b.kind;
}

fn optionalIdentityEql(
    a: ?file_mutation_contract.FileIdentity,
    b: ?file_mutation_contract.FileIdentity,
) bool {
    if (a) |actual| {
        const expected = b orelse return false;
        return identityEql(actual, expected);
    }
    return b == null;
}

fn operationalError(err: anyerror) ?FileMutationPrepareError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.Unexpected => error.Unexpected,
        error.SystemResources => error.SystemResources,
        error.ProcessFdQuotaExceeded => error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemFdQuotaExceeded,
        else => null,
    };
}

fn writeArgumentsJson(
    alloc: Allocator,
    path: []const u8,
    content: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"path\":");
    try std.json.Stringify.value(path, .{}, &out.writer);
    try out.writer.writeAll(",\"content\":");
    try std.json.Stringify.value(content, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn editArgumentsJson(
    alloc: Allocator,
    path: []const u8,
    old_string: []const u8,
    new_string: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"path\":");
    try std.json.Stringify.value(path, .{}, &out.writer);
    try out.writer.writeAll(",\"old_string\":");
    try std.json.Stringify.value(old_string, .{}, &out.writer);
    try out.writer.writeAll(",\"new_string\":");
    try std.json.Stringify.value(new_string, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn workspaceRoot(alloc: Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

fn createFile(
    tmp: *std.testing.TmpDir,
    sub_path: []const u8,
    content: []const u8,
) !void {
    var file = try tmp.dir.createFile(std.testing.io, sub_path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, content);
}

fn evaluatePolicy(
    alloc: Allocator,
    workspace_root: []const u8,
    call: types.ToolCall,
) !PolicyEvaluatedFileTargets {
    const input = try decodeTestMutationInput(alloc, call);
    const result = try testing_permissions.evaluateFileMutationTargets(
        alloc,
        workspace_root,
        input,
        .ask,
        .{},
        &.{},
        &.{},
    );
    return switch (result) {
        .evaluated => |evaluated| evaluated,
        .target_resolution_failure, .policy_denied => error.UnexpectedPolicyFailure,
    };
}

fn expectPrepared(
    alloc: Allocator,
    call: types.ToolCall,
    policy: PolicyEvaluatedFileTargets,
) !PreparedFileMutation {
    const input = try decodeTestMutationInput(alloc, call);
    return switch (try prepare(alloc, call, input, policy)) {
        .prepared => |prepared| prepared,
        .semantic_failure => error.UnexpectedSemanticFailure,
    };
}

fn expectSemanticFailure(
    alloc: Allocator,
    call: types.ToolCall,
    policy: PolicyEvaluatedFileTargets,
) ![]const u8 {
    const input = try decodeTestMutationInput(alloc, call);
    return switch (try prepare(alloc, call, input, policy)) {
        .prepared => error.UnexpectedPreparedMutation,
        .semantic_failure => |message| message,
    };
}

fn decodeTestMutationInput(
    alloc: Allocator,
    call: types.ToolCall,
) !file_mutation_contract.FileMutationInput {
    const kind: file_mutation_contract.Kind =
        if (std.mem.eql(u8, call.name, "write_file"))
            .write
        else if (std.mem.eql(u8, call.name, "edit_file"))
            .edit
        else
            return error.InvalidToolArguments;
    const tool = switch (kind) {
        .write => &testing_builtin_tools.write_file,
        .edit => &testing_builtin_tools.edit_file,
    };
    const decoded = try tool.decode(.{ .allocator = alloc }, call.arguments_json);
    return switch (decoded) {
        .failure => error.InvalidToolArguments,
        .input => |tool_input| blk: {
            break :blk switch (kind) {
                .write => testing_write_file.takeFileMutationInput(
                    tool_input,
                    alloc,
                ),
                .edit => testing_edit_file.takeFileMutationInput(
                    tool_input,
                    alloc,
                ),
            };
        },
    };
}

fn expectTerminalSafe(text: []const u8) !void {
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    try std.testing.expect(std.mem.findScalar(u8, text, 0x1b) == null);
    try std.testing.expect(std.mem.findScalar(u8, text, '\n') == null);
    try std.testing.expect(std.mem.findScalar(u8, text, '\r') == null);
}

fn expectNoStageFiles(root: []const u8) !void {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(std.testing.allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        try std.testing.expect(std.mem.find(u8, entry.path, ".fx-stage-") == null);
    }
}

test "prepare derives a missing write without creating the target" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try workspaceRoot(arena, tmp);
    const arguments = try writeArgumentsJson(
        arena,
        "missing/parents/new.txt",
        "hello\n",
    );
    const call: types.ToolCall = .{
        .id = "write-missing",
        .name = "write_file",
        .arguments_json = arguments,
    };
    const policy = try evaluatePolicy(arena, root, call);

    var input: file_mutation_contract.FileMutationInput = .{ .write = .{
        .path = try arena.dupe(u8, "missing/parents/new.txt"),
        .content = try arena.dupe(u8, "hello\n"),
    } };
    defer input.deinit(arena);
    const prepared = switch (try prepare(arena, call, input, policy)) {
        .prepared => |value| value,
        .semantic_failure => return error.UnexpectedSemanticFailure,
    };

    try std.testing.expectEqual(file_mutation_contract.Kind.write, prepared.kind);
    try std.testing.expect(prepared.preimage == .absent);
    try std.testing.expectEqualStrings("hello\n", prepared.after_content);
    try std.testing.expectEqualStrings("missing/parents/new.txt", prepared.display_path);
    try std.testing.expect(prepared.target_path.ptr == policy.canonical_target_path.ptr);
    try std.testing.expect(PolicyEvaluatedFileTargets.authorizationEql(policy, prepared.policy_targets));
    try std.testing.expectEqual(@as(usize, 1), prepared.preview.additions);
    try std.testing.expectEqual(@as(usize, 0), prepared.preview.deletions);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, "missing", .{}),
    );
}

test "prepare shows the canonical external target when a symlink redirects outside the workspace" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDir(std.testing.io, "workspace", .default_dir);
    try tmp.dir.createDir(std.testing.io, "outside", .default_dir);
    tmp.dir.symLink(io_mod.getIo(), "../outside", "workspace/link", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    const workspace = try io_mod.dirRealpathAlloc(arena, tmp.dir, "workspace");
    const misleading_path = try std.fs.path.join(arena, &.{ workspace, "link/new.txt" });
    const call: types.ToolCall = .{
        .id = "write-symlink-redirect",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(arena, misleading_path, "hello\n"),
    };
    const policy = try evaluatePolicy(arena, workspace, call);
    const prepared = try expectPrepared(arena, call, policy);

    try std.testing.expectEqual(.external, prepared.policy_targets.anchor.scope);
    try std.testing.expectEqualStrings(policy.canonical_target_path, prepared.display_path);
    try std.testing.expectEqualStrings(prepared.display_path, prepared.preview.path);
}

test "prepare retains full review separately from the bounded approval preview" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try workspaceRoot(arena, tmp);

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    for (1..31) |line_number| {
        var line: [32]u8 = undefined;
        try content.appendSlice(
            std.testing.allocator,
            try std.fmt.bufPrint(&line, "line {d}\n", .{line_number}),
        );
    }

    const call: types.ToolCall = .{
        .id = "write-full-review",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(
            arena,
            "full-review.txt",
            content.items,
        ),
    };
    const policy = try evaluatePolicy(arena, root, call);
    var prepared = try expectPrepared(arena, call, policy);

    try std.testing.expect(prepared.preview.lines.len <= diff_mod.max_preview_lines);
    var viewport = try prepared.review.viewport(arena, 24, 6);
    defer viewport.deinit(arena);
    try std.testing.expectEqual(@as(usize, 30), viewport.total_rows);
    try std.testing.expectEqualStrings("line 25", viewport.lines[0].text);
    try std.testing.expectEqualStrings("line 30", viewport.lines[5].text);
}

test "prepare derives an existing write from the exact reviewed preimage" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try createFile(&tmp, "note.txt", "old\n");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try workspaceRoot(arena, tmp);
    const arguments = try writeArgumentsJson(arena, "note.txt", "new\n");
    const call: types.ToolCall = .{
        .id = "write-existing",
        .name = "write_file",
        .arguments_json = arguments,
    };
    const policy = try evaluatePolicy(arena, root, call);

    const prepared = try expectPrepared(arena, call, policy);

    const present = prepared.preimage.present;
    try std.testing.expectEqualStrings("old\n", present.content);
    var expected_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    expected_hasher.update("old\n");
    try std.testing.expectEqualSlices(u8, &expected_hasher.finalResult(), &present.content_hash);
    try std.testing.expectEqualStrings("new\n", prepared.after_content);
    try std.testing.expectEqual(@as(usize, 1), prepared.preview.additions);
    try std.testing.expectEqual(@as(usize, 1), prepared.preview.deletions);

    var file = try tmp.dir.openFile(std.testing.io, "note.txt", .{});
    defer file.close(std.testing.io);
    const unchanged = try io_mod.readFileToEnd(arena, &file, 64);
    try std.testing.expectEqualStrings("old\n", unchanged);
}

test "prepare computes one exact edit occurrence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(&tmp, "note.txt", "alpha\nbeta\ngamma\n");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try workspaceRoot(arena, tmp);
    const arguments = try editArgumentsJson(arena, "note.txt", "beta", "BETA");
    const call: types.ToolCall = .{
        .id = "edit-exact",
        .name = "edit_file",
        .arguments_json = arguments,
    };
    const policy = try evaluatePolicy(arena, root, call);

    const prepared = try expectPrepared(arena, call, policy);

    try std.testing.expectEqual(file_mutation_contract.Kind.edit, prepared.kind);
    try std.testing.expectEqualStrings("alpha\nbeta\ngamma\n", prepared.preimage.present.content);
    try std.testing.expectEqualStrings("alpha\nBETA\ngamma\n", prepared.after_content);
    try std.testing.expectEqual(@as(usize, 1), prepared.preview.additions);
    try std.testing.expectEqual(@as(usize, 1), prepared.preview.deletions);
}

test "prepare preserves exact edit semantic failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(&tmp, "note.txt", "same twice same\n");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try workspaceRoot(arena, tmp);

    const identical_args = try editArgumentsJson(arena, "note.txt", "same", "same");
    const identical_call: types.ToolCall = .{
        .id = "edit-identical",
        .name = "edit_file",
        .arguments_json = identical_args,
    };
    const identical_policy = try evaluatePolicy(arena, root, identical_call);
    try std.testing.expectEqualStrings(
        "edit_file failed: old_string and new_string are identical",
        try expectSemanticFailure(arena, identical_call, identical_policy),
    );

    const missing_args = try editArgumentsJson(arena, "note.txt", "missing", "new");
    const missing_call: types.ToolCall = .{
        .id = "edit-missing",
        .name = "edit_file",
        .arguments_json = missing_args,
    };
    const missing_policy = try evaluatePolicy(arena, root, missing_call);
    try std.testing.expectEqualStrings(
        "edit_file failed: old_string not found in file",
        try expectSemanticFailure(arena, missing_call, missing_policy),
    );

    const duplicate_args = try editArgumentsJson(arena, "note.txt", "same", "new");
    const duplicate_call: types.ToolCall = .{
        .id = "edit-duplicate",
        .name = "edit_file",
        .arguments_json = duplicate_args,
    };
    const duplicate_policy = try evaluatePolicy(arena, root, duplicate_call);
    try std.testing.expectEqualStrings(
        "edit_file failed: old_string is not unique (found 2 occurrences), provide more context",
        try expectSemanticFailure(arena, duplicate_call, duplicate_policy),
    );
}

test "prepare emits explicit empty and no-change notices" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(&tmp, "same.txt", "same\n");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try workspaceRoot(arena, tmp);

    const empty_args = try writeArgumentsJson(arena, "empty.txt", "");
    const empty_call: types.ToolCall = .{
        .id = "write-empty",
        .name = "write_file",
        .arguments_json = empty_args,
    };
    const empty_policy = try evaluatePolicy(arena, root, empty_call);
    const empty = try expectPrepared(arena, empty_call, empty_policy);
    try std.testing.expectEqual(@as(usize, 0), empty.preview.additions);
    try std.testing.expectEqual(@as(usize, 0), empty.preview.deletions);
    try std.testing.expectEqual(@as(usize, 1), empty.preview.lines.len);
    try std.testing.expectEqual(diff_mod.PreviewOp.notice, empty.preview.lines[0].op);
    try std.testing.expectEqualStrings("empty file", empty.preview.lines[0].text);

    const same_args = try writeArgumentsJson(arena, "same.txt", "same\n");
    const same_call: types.ToolCall = .{
        .id = "write-same",
        .name = "write_file",
        .arguments_json = same_args,
    };
    const same_policy = try evaluatePolicy(arena, root, same_call);
    const same = try expectPrepared(arena, same_call, same_policy);
    try std.testing.expectEqual(@as(usize, 0), same.preview.additions);
    try std.testing.expectEqual(@as(usize, 0), same.preview.deletions);
    try std.testing.expectEqualStrings("no content changes", same.preview.lines[0].text);
}

test "prepare terminal-encodes hostile path and preview content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try workspaceRoot(arena, tmp);
    const hostile_path = "name\x1b[31m\nfile.txt";
    const hostile_content = "line\x1b[31mred\x1b[0m\n";
    const arguments = try writeArgumentsJson(arena, hostile_path, hostile_content);
    const call: types.ToolCall = .{
        .id = "write-hostile",
        .name = "write_file",
        .arguments_json = arguments,
    };
    const policy = try evaluatePolicy(arena, root, call);

    const prepared = try expectPrepared(arena, call, policy);

    try expectTerminalSafe(prepared.display_path);
    try std.testing.expect(!std.mem.eql(u8, hostile_path, prepared.display_path));
    for (prepared.preview.lines) |line| try expectTerminalSafe(line.text);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, hostile_path, .{}),
    );
}

test "prepare enforces independent preimage and postimage caps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try workspaceRoot(arena, tmp);

    const oversized_preimage = try arena.alloc(u8, max_content_bytes + 1);
    @memset(oversized_preimage, 'x');
    try createFile(&tmp, "oversized.txt", oversized_preimage);
    const preimage_call: types.ToolCall = .{
        .id = "oversized-preimage",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(arena, "oversized.txt", "new"),
    };
    const preimage_policy = try evaluatePolicy(arena, root, preimage_call);
    try std.testing.expectEqualStrings(
        "file mutation preparation failed: preimage exceeds the 4 MiB preparation limit",
        try expectSemanticFailure(arena, preimage_call, preimage_policy),
    );

    const maximum_preimage = try arena.alloc(u8, max_content_bytes);
    @memset(maximum_preimage, 'x');
    maximum_preimage[0] = 'a';
    try createFile(&tmp, "maximum.txt", maximum_preimage);
    const postimage_call: types.ToolCall = .{
        .id = "oversized-postimage",
        .name = "edit_file",
        .arguments_json = try editArgumentsJson(arena, "maximum.txt", "a", "aa"),
    };
    const postimage_policy = try evaluatePolicy(arena, root, postimage_call);
    try std.testing.expectEqualStrings(
        "edit_file failed: postimage exceeds the 4 MiB preparation limit",
        try expectSemanticFailure(arena, postimage_call, postimage_policy),
    );
}

test "prepare hashes exact raw JSON bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try workspaceRoot(arena, tmp);
    const call_a: types.ToolCall = .{
        .id = "hash-a",
        .name = "write_file",
        .arguments_json = "{\"path\":\"note.txt\",\"content\":\"same\"}",
    };
    const call_b: types.ToolCall = .{
        .id = "hash-b",
        .name = "write_file",
        .arguments_json = "{ \"content\": \"same\", \"path\": \"note.txt\" }",
    };
    const policy_a = try evaluatePolicy(arena, root, call_a);
    const policy_b = try evaluatePolicy(arena, root, call_b);
    const prepared_a = try expectPrepared(arena, call_a, policy_a);
    const prepared_b = try expectPrepared(arena, call_b, policy_b);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(call_a.arguments_json);
    try std.testing.expectEqualSlices(u8, &hasher.finalResult(), &prepared_a.arguments_hash);
    try std.testing.expect(!std.mem.eql(
        u8,
        &prepared_a.arguments_hash,
        &prepared_b.arguments_hash,
    ));
}

test "prepare rejects call target and authority identity mismatches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(&tmp, "a.txt", "a");
    try createFile(&tmp, "b.txt", "b");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try workspaceRoot(arena, tmp);
    const call_a: types.ToolCall = .{
        .id = "target-a",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(arena, "a.txt", "new"),
    };
    const policy_a = try evaluatePolicy(arena, root, call_a);
    const call_b: types.ToolCall = .{
        .id = "target-b",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(arena, "b.txt", "new"),
    };
    try std.testing.expectEqualStrings(
        "file mutation preparation failed: approved target no longer matches the call",
        try expectSemanticFailure(arena, call_b, policy_a),
    );

    var changed_anchor = policy_a;
    changed_anchor.anchor.identity.inode +%= 1;
    try std.testing.expectEqualStrings(
        "file mutation preparation failed: approved filesystem identity changed",
        try expectSemanticFailure(arena, call_a, changed_anchor),
    );

    try createFile(&tmp, "replacement.txt", "replacement");
    try tmp.dir.rename("replacement.txt", tmp.dir, "a.txt", std.testing.io);
    try std.testing.expectEqualStrings(
        "file mutation preparation failed: approved filesystem identity changed",
        try expectSemanticFailure(arena, call_a, policy_a),
    );
}

test "prepare rejects an intermediate-directory retarget" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "approved", .default_dir);
    try tmp.dir.createDir(std.testing.io, "other", .default_dir);
    {
        var approved = try tmp.dir.openDir(std.testing.io, "approved", .{});
        defer approved.close(std.testing.io);
        var file = try approved.createFile(std.testing.io, "note.txt", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "approved");
    }
    {
        var other = try tmp.dir.openDir(std.testing.io, "other", .{});
        defer other.close(std.testing.io);
        var file = try other.createFile(std.testing.io, "note.txt", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "other");
    }

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try workspaceRoot(arena, tmp);
    const call: types.ToolCall = .{
        .id = "retarget",
        .name = "edit_file",
        .arguments_json = try editArgumentsJson(arena, "approved/note.txt", "approved", "new"),
    };
    const policy = try evaluatePolicy(arena, root, call);

    try tmp.dir.rename("approved", tmp.dir, "approved-old", std.testing.io);
    try tmp.dir.symLink(std.testing.io, "other", "approved", .{ .is_directory = true });

    try std.testing.expectEqualStrings(
        "file mutation preparation failed: approved target no longer matches the call",
        try expectSemanticFailure(arena, call, policy),
    );
}

test "prepare rejects a corrupted permission target proof" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try workspaceRoot(arena, tmp);
    const call: types.ToolCall = .{
        .id = "corrupted-proof-prepare",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(arena, "new.txt", "new"),
    };
    const policy = try evaluatePolicy(arena, root, call);

    var corrupted_components = try arena.dupe(
        file_mutation_contract.PathSpan,
        policy.anchor.relative_components,
    );
    corrupted_components[0].start = policy.anchor.path_end;
    var corrupted_policy = policy;
    corrupted_policy.anchor.relative_components = corrupted_components;

    try std.testing.expectEqualStrings(
        target_mismatch_message,
        try expectSemanticFailure(arena, call, corrupted_policy),
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, "new.txt", .{}),
    );
}

const TestPreparedMutation = struct {
    input: file_mutation_contract.FileMutationInput,
    policy: PolicyEvaluatedFileTargets,
    prepared: PreparedFileMutation,
};

fn prepareForApply(
    alloc: Allocator,
    workspace_root: []const u8,
    call: types.ToolCall,
) !TestPreparedMutation {
    const input = try decodeTestMutationInput(alloc, call);
    const result = try testing_permissions.evaluateFileMutationTargets(
        alloc,
        workspace_root,
        input,
        .ask,
        .{},
        &.{},
        &.{},
    );
    const policy = switch (result) {
        .evaluated => |evaluated| evaluated,
        .target_resolution_failure, .policy_denied => return error.UnexpectedPolicyFailure,
    };
    return .{
        .input = input,
        .policy = policy,
        .prepared = switch (try prepare(alloc, call, input, policy)) {
            .prepared => |prepared| prepared,
            .semantic_failure => return error.UnexpectedSemanticFailure,
        },
    };
}

fn executionAuthorization(
    prepared: TestPreparedMutation,
) file_mutation_contract.FileExecutionAuthorization {
    return .{
        .input = prepared.input,
        .policy_targets = prepared.policy,
        .prepared = prepared.prepared,
    };
}

fn expectApplyRejected(
    result: ApplyResult,
    reason: ApplyRejectionReason,
) !ApplyRejection {
    return switch (result) {
        .rejected => |rejected| blk: {
            try std.testing.expectEqual(reason, rejected.reason);
            break :blk rejected;
        },
        .committed => error.UnexpectedCommittedMutation,
    };
}

fn readTestFile(
    alloc: Allocator,
    tmp: *std.testing.TmpDir,
    sub_path: []const u8,
) ![]u8 {
    var file = try tmp.dir.openFile(std.testing.io, sub_path, .{});
    defer file.close(std.testing.io);
    return io_mod.readFileToEnd(alloc, &file, max_content_bytes + 1);
}

test "apply atomically installs reviewed bytes and returns typed commit metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var call_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer call_arena_state.deinit();
    var result_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena_state.deinit();
    const call_alloc = call_arena_state.allocator();
    const result_alloc = result_arena_state.allocator();
    const root = try workspaceRoot(call_alloc, tmp);
    const call: types.ToolCall = .{
        .id = "apply-write",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(call_alloc, "nested/new.txt", "reviewed\n"),
    };
    const prepared = try prepareForApply(call_alloc, root, call);
    var cancel_flag = std.atomic.Value(bool).init(false);

    const result = try apply(
        call_alloc,
        result_alloc,
        call,
        executionAuthorization(prepared),
        &cancel_flag,
    );

    const committed_handoff = switch (result) {
        .committed => |handoff| handoff,
        .rejected => return error.UnexpectedRejectedMutation,
    };
    try std.testing.expectEqualStrings(
        prepared.prepared.target_path,
        committed_handoff.tracker.raw_path,
    );
    try std.testing.expectEqual(
        file_mutation_contract.Kind.write,
        committed_handoff.tracker.kind,
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        committed_handoff.tracker.previous_content,
    );
    try std.testing.expectEqual(
        prepared.prepared.preview.additions,
        committed_handoff.preview.additions,
    );

    const installed = try readTestFile(call_alloc, &tmp, "nested/new.txt");
    try std.testing.expectEqualStrings("reviewed\n", installed);
}

test "apply installs reviewed bytes beneath an authorized external anchor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "workspace", .default_dir);
    try tmp.dir.createDir(std.testing.io, "external", .default_dir);
    var call_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer call_arena_state.deinit();
    var result_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena_state.deinit();
    const call_alloc = call_arena_state.allocator();
    const result_alloc = result_arena_state.allocator();
    const workspace = try io_mod.dirRealpathAlloc(
        call_alloc,
        tmp.dir,
        "workspace",
    );
    const external = try io_mod.dirRealpathAlloc(
        call_alloc,
        tmp.dir,
        "external",
    );
    const target_path = try std.fs.path.join(
        call_alloc,
        &.{ external, "nested/new.txt" },
    );
    const call: types.ToolCall = .{
        .id = "apply-external",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(
            call_alloc,
            target_path,
            "reviewed\n",
        ),
    };
    const prepared = try prepareForApply(call_alloc, workspace, call);
    try std.testing.expectEqual(
        .external,
        prepared.policy.anchor.scope,
    );
    var cancel_flag = std.atomic.Value(bool).init(false);

    const result = try apply(
        call_alloc,
        result_alloc,
        call,
        executionAuthorization(prepared),
        &cancel_flag,
    );

    try std.testing.expect(result == .committed);
    const installed = try readTestFile(
        call_alloc,
        &tmp,
        "external/nested/new.txt",
    );
    try std.testing.expectEqualStrings("reviewed\n", installed);
}

test "apply rejects binding mismatches before allocation or filesystem access" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var owner = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer owner.deinit();
    const owner_alloc = owner.allocator();
    const root = try workspaceRoot(owner_alloc, tmp);
    const call: types.ToolCall = .{
        .id = "binding",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(owner_alloc, "new.txt", "new"),
    };
    const prepared = try prepareForApply(owner_alloc, root, call);

    var failing_call = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    var failing_result = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    const call_alloc = failing_call.allocator();
    const result_alloc = failing_result.allocator();
    var cancel_flag = std.atomic.Value(bool).init(false);
    const authorization: file_mutation_contract.FileExecutionAuthorization = .{
        .input = prepared.input,
        .policy_targets = prepared.policy,
        .prepared = null,
    };

    const rejected = try expectApplyRejected(
        try apply(
            call_alloc,
            result_alloc,
            call,
            authorization,
            &cancel_flag,
        ),
        .binding_mismatch,
    );
    try std.testing.expectEqual(@as(usize, 0), rejected.created_parent_residue.len);
    try std.testing.expectEqual(@as(usize, 0), failing_call.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), failing_result.allocated_bytes);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, "new.txt", .{}),
    );
}

test "apply rejects a corrupted prepared policy proof before mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var call_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer call_arena_state.deinit();
    var result_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena_state.deinit();
    const call_alloc = call_arena_state.allocator();
    const result_alloc = result_arena_state.allocator();
    const root = try workspaceRoot(call_alloc, tmp);
    const call: types.ToolCall = .{
        .id = "corrupted-proof-apply",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(call_alloc, "new.txt", "new"),
    };
    var prepared = try prepareForApply(call_alloc, root, call);
    var corrupted_components = try call_alloc.dupe(
        file_mutation_contract.PathSpan,
        prepared.policy.anchor.relative_components,
    );
    corrupted_components[0].start = prepared.policy.anchor.path_end;
    var corrupted_policy = prepared.policy;
    corrupted_policy.anchor.relative_components = corrupted_components;
    prepared.policy = corrupted_policy;
    prepared.prepared.policy_targets = corrupted_policy;

    var cancel_flag = std.atomic.Value(bool).init(false);
    const rejected = try expectApplyRejected(
        try apply(
            call_alloc,
            result_alloc,
            call,
            executionAuthorization(prepared),
            &cancel_flag,
        ),
        .binding_mismatch,
    );
    try std.testing.expectEqual(@as(usize, 0), rejected.created_parent_residue.len);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, "new.txt", .{}),
    );
}

test "apply allocation failure before rename leaves target unchanged" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try createFile(&tmp, "note.txt", "old");
    var owner = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer owner.deinit();
    const call_alloc = owner.allocator();
    const root = try workspaceRoot(call_alloc, tmp);
    const call: types.ToolCall = .{
        .id = "allocation-failure",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(call_alloc, "note.txt", "new"),
    };
    const prepared = try prepareForApply(call_alloc, root, call);
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 3 },
    );
    var test_state = StageTestState{};
    var cancel_flag = std.atomic.Value(bool).init(false);

    try std.testing.expectError(
        error.OutOfMemory,
        applyWithTestControls(
            call_alloc,
            failing.allocator(),
            call,
            executionAuthorization(prepared),
            &cancel_flag,
            .{ .ctx = &test_state, .after_stage = mutateAfterStage },
        ),
    );
    try std.testing.expect(!test_state.reached);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    const unchanged = try readTestFile(call_alloc, &tmp, "note.txt");
    try std.testing.expectEqualStrings("old", unchanged);
    try expectNoStageFiles(root);
}

test "apply rejects stale absent targets and stale existing preimages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(&tmp, "existing.txt", "old");
    var call_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer call_arena_state.deinit();
    var result_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena_state.deinit();
    const call_alloc = call_arena_state.allocator();
    const result_alloc = result_arena_state.allocator();
    const root = try workspaceRoot(call_alloc, tmp);

    const missing_call: types.ToolCall = .{
        .id = "stale-absent",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(call_alloc, "missing.txt", "new"),
    };
    const missing_prepared = try prepareForApply(call_alloc, root, missing_call);
    try createFile(&tmp, "missing.txt", "raced");
    var cancel_flag = std.atomic.Value(bool).init(false);
    _ = try expectApplyRejected(
        try apply(
            call_alloc,
            result_alloc,
            missing_call,
            executionAuthorization(missing_prepared),
            &cancel_flag,
        ),
        .stale_preimage,
    );
    const raced = try readTestFile(call_alloc, &tmp, "missing.txt");
    try std.testing.expectEqualStrings("raced", raced);

    const existing_call: types.ToolCall = .{
        .id = "stale-existing",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(call_alloc, "existing.txt", "new"),
    };
    const existing_prepared = try prepareForApply(call_alloc, root, existing_call);
    {
        var file = try tmp.dir.openFile(std.testing.io, "existing.txt", .{ .mode = .write_only });
        defer file.close(std.testing.io);
        try file.setLength(std.testing.io, 0);
        try file.writeStreamingAll(std.testing.io, "changed");
    }
    _ = try expectApplyRejected(
        try apply(
            call_alloc,
            result_alloc,
            existing_call,
            executionAuthorization(existing_prepared),
            &cancel_flag,
        ),
        .stale_preimage,
    );
    const changed = try readTestFile(call_alloc, &tmp, "existing.txt");
    try std.testing.expectEqualStrings("changed", changed);
}

test "apply rejects replaced anchors and existing parents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "workspace", .default_dir);
    try tmp.dir.createDir(std.testing.io, "workspace/parent", .default_dir);
    try createFile(&tmp, "workspace/parent/note.txt", "old");
    var call_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer call_arena_state.deinit();
    var result_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena_state.deinit();
    const call_alloc = call_arena_state.allocator();
    const result_alloc = result_arena_state.allocator();
    const workspace = try io_mod.dirRealpathAlloc(call_alloc, tmp.dir, "workspace");
    const call: types.ToolCall = .{
        .id = "replace-anchor",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(call_alloc, "parent/note.txt", "new"),
    };
    const prepared = try prepareForApply(call_alloc, workspace, call);

    try tmp.dir.rename("workspace", tmp.dir, "workspace-old", std.testing.io);
    try tmp.dir.createDir(std.testing.io, "workspace", .default_dir);
    var cancel_flag = std.atomic.Value(bool).init(false);
    _ = try expectApplyRejected(
        try apply(
            call_alloc,
            result_alloc,
            call,
            executionAuthorization(prepared),
            &cancel_flag,
        ),
        .traversal_changed,
    );
    const anchor_unchanged = try readTestFile(call_alloc, &tmp, "workspace-old/parent/note.txt");
    try std.testing.expectEqualStrings("old", anchor_unchanged);

    try tmp.dir.rename("workspace", tmp.dir, "workspace-empty", std.testing.io);
    try tmp.dir.rename("workspace-old", tmp.dir, "workspace", std.testing.io);
    const parent_call: types.ToolCall = .{
        .id = "replace-parent",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(call_alloc, "parent/note.txt", "new"),
    };
    const parent_prepared = try prepareForApply(call_alloc, workspace, parent_call);
    try tmp.dir.rename("workspace/parent", tmp.dir, "workspace/parent-old", std.testing.io);
    try tmp.dir.createDir(std.testing.io, "workspace/parent", .default_dir);
    _ = try expectApplyRejected(
        try apply(
            call_alloc,
            result_alloc,
            parent_call,
            executionAuthorization(parent_prepared),
            &cancel_flag,
        ),
        .traversal_changed,
    );
    const parent_unchanged = try readTestFile(call_alloc, &tmp, "workspace/parent-old/note.txt");
    try std.testing.expectEqualStrings("old", parent_unchanged);
}

const CreatedParentReplacement = enum {
    none,
    shallow,
    deep,
};

const StageTestState = struct {
    reached: bool = false,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    workspace_root: ?[]const u8 = null,
    replace_created_parent: CreatedParentReplacement = .none,
    replace_temp: bool = false,
    mutate_temp: bool = false,
    add_blocker: bool = false,
};

fn mutateAfterStage(
    ctx: ?*anyopaque,
    parent: std.Io.Dir,
    temp_name: []const u8,
) anyerror!void {
    const state: *StageTestState = @ptrCast(@alignCast(ctx.?));
    state.reached = true;
    if (state.replace_created_parent != .none) {
        var root = std.Io.Dir.openDirAbsolute(
            std.testing.io,
            state.workspace_root.?,
            .{},
        ) catch return error.TestControlFailed;
        defer root.close(std.testing.io);
        switch (state.replace_created_parent) {
            .none => unreachable,
            .shallow => {
                root.rename("one", root, "one-original", std.testing.io) catch
                    return error.TestControlFailed;
                root.createDir(std.testing.io, "one", .default_dir) catch
                    return error.TestControlFailed;
            },
            .deep => {
                root.rename("one/two", root, "one/two-original", std.testing.io) catch
                    return error.TestControlFailed;
                root.createDir(std.testing.io, "one/two", .default_dir) catch
                    return error.TestControlFailed;
            },
        }
    }
    if (state.replace_temp) {
        parent.rename(temp_name, parent, ".removed-stage", std.testing.io) catch return error.TestControlFailed;
        parent.deleteFile(std.testing.io, ".removed-stage") catch return error.TestControlFailed;
        var replacement = parent.createFile(std.testing.io, temp_name, .{
            .truncate = false,
            .exclusive = true,
        }) catch return error.TestControlFailed;
        defer replacement.close(std.testing.io);
        replacement.writeStreamingAll(std.testing.io, "foreign") catch return error.TestControlFailed;
    }
    if (state.mutate_temp) {
        var staged = parent.openFile(std.testing.io, temp_name, .{
            .mode = .write_only,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch return error.TestControlFailed;
        defer staged.close(std.testing.io);
        staged.writeStreamingAll(std.testing.io, "tampered") catch return error.TestControlFailed;
        staged.sync(std.testing.io) catch return error.TestControlFailed;
    }
    if (state.add_blocker) {
        var blocker = parent.createFile(std.testing.io, "blocker", .{
            .truncate = false,
            .exclusive = true,
        }) catch return error.TestControlFailed;
        blocker.close(std.testing.io);
    }
    if (state.cancel_flag) |cancel_flag| cancel_flag.store(true, .seq_cst);
}

const StageChunkTestState = struct {
    cancel_flag: *std.atomic.Value(bool),
    chunk_count: usize = 0,
};

fn cancelAfterFirstStageChunk(
    ctx: ?*anyopaque,
    _: usize,
) anyerror!void {
    const state: *StageChunkTestState = @ptrCast(@alignCast(ctx.?));
    state.chunk_count += 1;
    if (state.chunk_count == 1) state.cancel_flag.store(true, .seq_cst);
}

fn replaceTargetAfterFinalPreimageRead(
    _: ?*anyopaque,
    parent: std.Io.Dir,
    target_name: []const u8,
) anyerror!void {
    parent.rename(
        target_name,
        parent,
        "reviewed-target",
        std.testing.io,
    ) catch return error.TestControlFailed;
    var replacement = parent.createFile(std.testing.io, target_name, .{
        .truncate = false,
        .exclusive = true,
    }) catch return error.TestControlFailed;
    defer replacement.close(std.testing.io);
    replacement.writeStreamingAll(std.testing.io, "old") catch
        return error.TestControlFailed;
}

const MoveParentTestState = struct {
    tmp: *std.testing.TmpDir,
    reached: bool = false,
};

fn moveParentForTest(state: *MoveParentTestState) !void {
    state.reached = true;
    state.tmp.dir.rename(
        "parent",
        state.tmp.dir,
        "moved-parent",
        std.testing.io,
    ) catch return error.TestControlFailed;
    state.tmp.dir.createDir(std.testing.io, "parent", .default_dir) catch
        return error.TestControlFailed;
    createFile(state.tmp, "parent/existing.txt", "replacement") catch
        return error.TestControlFailed;
}

fn moveParentAfterFinalPreimageRead(
    ctx: ?*anyopaque,
    _: std.Io.Dir,
    _: []const u8,
) anyerror!void {
    const state: *MoveParentTestState = @ptrCast(@alignCast(ctx.?));
    try moveParentForTest(state);
}

fn moveParentAfterFinalValidation(ctx: ?*anyopaque) anyerror!void {
    const state: *MoveParentTestState = @ptrCast(@alignCast(ctx.?));
    try moveParentForTest(state);
}

test "apply rejects replaced staged sources without deleting foreign replacements" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var call_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer call_arena_state.deinit();
    var result_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena_state.deinit();
    const call_alloc = call_arena_state.allocator();
    const result_alloc = result_arena_state.allocator();
    const root = try workspaceRoot(call_alloc, tmp);
    const call: types.ToolCall = .{
        .id = "replace-stage",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(call_alloc, "new.txt", "reviewed"),
    };
    const prepared = try prepareForApply(call_alloc, root, call);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var test_state = StageTestState{ .replace_temp = true };

    _ = try expectApplyRejected(
        try applyWithTestControls(
            call_alloc,
            result_alloc,
            call,
            executionAuthorization(prepared),
            &cancel_flag,
            .{ .ctx = &test_state, .after_stage = mutateAfterStage },
        ),
        .staged_source_changed,
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, "new.txt", .{}),
    );

    var root_dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer root_dir.close(std.testing.io);
    var iterator = root_dir.iterate();
    var found_foreign = false;
    while (try iterator.next(std.testing.io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".fx-stage-")) {
            const foreign = try readTestFile(call_alloc, &tmp, entry.name);
            try std.testing.expectEqualStrings("foreign", foreign);
            found_foreign = true;
        }
    }
    try std.testing.expect(found_foreign);
}

test "apply rejects in-place staged content changes before rename" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var call_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer call_arena_state.deinit();
    var result_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena_state.deinit();
    const call_alloc = call_arena_state.allocator();
    const result_alloc = result_arena_state.allocator();
    const root = try workspaceRoot(call_alloc, tmp);
    const call: types.ToolCall = .{
        .id = "mutate-stage",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(call_alloc, "new.txt", "reviewed"),
    };
    const prepared = try prepareForApply(call_alloc, root, call);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var test_state = StageTestState{ .mutate_temp = true };

    _ = try expectApplyRejected(
        try applyWithTestControls(
            call_alloc,
            result_alloc,
            call,
            executionAuthorization(prepared),
            &cancel_flag,
            .{ .ctx = &test_state, .after_stage = mutateAfterStage },
        ),
        .staged_source_changed,
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, "new.txt", .{}),
    );

    var root_dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer root_dir.close(std.testing.io);
    var iterator = root_dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".fx-stage-"));
    }
}

test "apply rejects a target pathname replaced during final preimage validation" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try createFile(&tmp, "existing.txt", "old");
    var call_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer call_arena_state.deinit();
    var result_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena_state.deinit();
    const call_alloc = call_arena_state.allocator();
    const result_alloc = result_arena_state.allocator();
    const root = try workspaceRoot(call_alloc, tmp);
    const call: types.ToolCall = .{
        .id = "replace-target-during-read",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(
            call_alloc,
            "existing.txt",
            "new",
        ),
    };
    const prepared = try prepareForApply(call_alloc, root, call);
    var cancel_flag = std.atomic.Value(bool).init(false);

    _ = try expectApplyRejected(
        try applyWithTestControls(
            call_alloc,
            result_alloc,
            call,
            executionAuthorization(prepared),
            &cancel_flag,
            .{ .after_final_preimage_read = replaceTargetAfterFinalPreimageRead },
        ),
        .stale_preimage,
    );

    const replacement = try readTestFile(call_alloc, &tmp, "existing.txt");
    try std.testing.expectEqualStrings("old", replacement);
    const reviewed = try readTestFile(call_alloc, &tmp, "reviewed-target");
    try std.testing.expectEqualStrings("old", reviewed);
    try expectNoStageFiles(root);
}

test "apply rejects a parent moved during final preimage validation" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "parent", .default_dir);
    try createFile(&tmp, "parent/existing.txt", "old");
    var call_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer call_arena_state.deinit();
    var result_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena_state.deinit();
    const call_alloc = call_arena_state.allocator();
    const result_alloc = result_arena_state.allocator();
    const root = try workspaceRoot(call_alloc, tmp);
    const call: types.ToolCall = .{
        .id = "move-parent-during-final-read",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(
            call_alloc,
            "parent/existing.txt",
            "new",
        ),
    };
    const prepared = try prepareForApply(call_alloc, root, call);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var test_state = MoveParentTestState{ .tmp = &tmp };

    _ = try expectApplyRejected(
        try applyWithTestControls(
            call_alloc,
            result_alloc,
            call,
            executionAuthorization(prepared),
            &cancel_flag,
            .{
                .ctx = &test_state,
                .after_final_preimage_read = moveParentAfterFinalPreimageRead,
            },
        ),
        .traversal_changed,
    );

    try std.testing.expect(test_state.reached);
    const canonical = try readTestFile(
        call_alloc,
        &tmp,
        "parent/existing.txt",
    );
    try std.testing.expectEqualStrings("replacement", canonical);
    const moved = try readTestFile(
        call_alloc,
        &tmp,
        "moved-parent/existing.txt",
    );
    try std.testing.expectEqualStrings("old", moved);
    try expectNoStageFiles(root);
}

test "apply commits through a parent moved after final validation" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "parent", .default_dir);
    try createFile(&tmp, "parent/existing.txt", "old");
    var call_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer call_arena_state.deinit();
    var result_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena_state.deinit();
    const call_alloc = call_arena_state.allocator();
    const result_alloc = result_arena_state.allocator();
    const root = try workspaceRoot(call_alloc, tmp);
    const call: types.ToolCall = .{
        .id = "move-parent-after-final-validation",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(
            call_alloc,
            "parent/existing.txt",
            "new",
        ),
    };
    const prepared = try prepareForApply(call_alloc, root, call);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var test_state = MoveParentTestState{ .tmp = &tmp };

    const result = try applyWithTestControls(
        call_alloc,
        result_alloc,
        call,
        executionAuthorization(prepared),
        &cancel_flag,
        .{
            .ctx = &test_state,
            .after_final_validation = moveParentAfterFinalValidation,
        },
    );

    const committed = switch (result) {
        .committed => |handoff| handoff,
        .rejected => return error.UnexpectedRejectedMutation,
    };
    try std.testing.expect(test_state.reached);
    try std.testing.expectEqualStrings(
        "parent/existing.txt",
        committed.preview.path,
    );
    const canonical = try readTestFile(
        call_alloc,
        &tmp,
        "parent/existing.txt",
    );
    try std.testing.expectEqualStrings("replacement", canonical);
    const moved = try readTestFile(
        call_alloc,
        &tmp,
        "moved-parent/existing.txt",
    );
    try std.testing.expectEqualStrings("new", moved);
    try expectNoStageFiles(root);
}

test "apply observes cancellation between bounded stage writes" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var call_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer call_arena_state.deinit();
    var result_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena_state.deinit();
    const call_alloc = call_arena_state.allocator();
    const result_alloc = result_arena_state.allocator();
    const root = try workspaceRoot(call_alloc, tmp);
    const content = try call_alloc.alloc(u8, 128 * 1024);
    @memset(content, 'x');
    const call: types.ToolCall = .{
        .id = "cancel-stage-chunk",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(
            call_alloc,
            "one/two/new.txt",
            content,
        ),
    };
    const prepared = try prepareForApply(call_alloc, root, call);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var test_state = StageChunkTestState{ .cancel_flag = &cancel_flag };

    const rejected = try expectApplyRejected(
        try applyWithTestControls(
            call_alloc,
            result_alloc,
            call,
            executionAuthorization(prepared),
            &cancel_flag,
            .{
                .ctx = &test_state,
                .after_write_chunk = cancelAfterFirstStageChunk,
            },
        ),
        .cancelled,
    );

    try std.testing.expectEqual(@as(usize, 1), test_state.chunk_count);
    try std.testing.expectEqual(@as(usize, 0), rejected.created_parent_residue.len);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, "one", .{}),
    );
    try expectNoStageFiles(root);
}

test "apply rejects replacement of transaction-created parent directories" {
    inline for ([_]CreatedParentReplacement{ .shallow, .deep }) |replacement| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var call_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer call_arena_state.deinit();
        var result_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer result_arena_state.deinit();
        const call_alloc = call_arena_state.allocator();
        const result_alloc = result_arena_state.allocator();
        const root = try workspaceRoot(call_alloc, tmp);
        const call: types.ToolCall = .{
            .id = switch (replacement) {
                .none => unreachable,
                .shallow => "replace-created-shallow",
                .deep => "replace-created-deep",
            },
            .name = "write_file",
            .arguments_json = try writeArgumentsJson(
                call_alloc,
                "one/two/new.txt",
                "reviewed",
            ),
        };
        const prepared = try prepareForApply(call_alloc, root, call);
        var cancel_flag = std.atomic.Value(bool).init(false);
        var test_state = StageTestState{
            .workspace_root = root,
            .replace_created_parent = replacement,
        };

        const rejected = try expectApplyRejected(
            try applyWithTestControls(
                call_alloc,
                result_alloc,
                call,
                executionAuthorization(prepared),
                &cancel_flag,
                .{ .ctx = &test_state, .after_stage = mutateAfterStage },
            ),
            .traversal_changed,
        );

        try std.testing.expectEqual(@as(usize, 2), rejected.created_parent_residue.len);
        try std.testing.expect(
            rejected.created_parent_residue[0].component_index >
                rejected.created_parent_residue[1].component_index,
        );
        try std.testing.expectError(
            error.FileNotFound,
            tmp.dir.statFile(std.testing.io, "one/two/new.txt", .{}),
        );
        const moved_target = switch (replacement) {
            .none => unreachable,
            .shallow => "one-original/two/new.txt",
            .deep => "one/two-original/new.txt",
        };
        try std.testing.expectError(
            error.FileNotFound,
            tmp.dir.statFile(std.testing.io, moved_target, .{}),
        );
        try expectNoStageFiles(root);
    }
}

test "apply cancellation removes its temp and newly created parents" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try createFile(&tmp, "keep.txt", "keep");
    var call_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer call_arena_state.deinit();
    var result_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena_state.deinit();
    const call_alloc = call_arena_state.allocator();
    const result_alloc = result_arena_state.allocator();
    const root = try workspaceRoot(call_alloc, tmp);
    const call: types.ToolCall = .{
        .id = "cancel-clean",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(call_alloc, "one/two/new.txt", "reviewed"),
    };
    const prepared = try prepareForApply(call_alloc, root, call);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var test_state = StageTestState{ .cancel_flag = &cancel_flag };

    const rejected = try expectApplyRejected(
        try applyWithTestControls(
            call_alloc,
            result_alloc,
            call,
            executionAuthorization(prepared),
            &cancel_flag,
            .{ .ctx = &test_state, .after_stage = mutateAfterStage },
        ),
        .cancelled,
    );
    try std.testing.expectEqual(@as(usize, 0), rejected.created_parent_residue.len);
    const keep = try readTestFile(call_alloc, &tmp, "keep.txt");
    try std.testing.expectEqualStrings("keep", keep);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, "one", .{}),
    );
    try expectNoStageFiles(root);
}

test "apply returns deepest-first bounded residue when created parents are not empty" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var call_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer call_arena_state.deinit();
    var result_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena_state.deinit();
    const call_alloc = call_arena_state.allocator();
    const result_alloc = result_arena_state.allocator();
    const root = try workspaceRoot(call_alloc, tmp);
    const call: types.ToolCall = .{
        .id = "cancel-residue",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(call_alloc, "one/two/new.txt", "reviewed"),
    };
    const prepared = try prepareForApply(call_alloc, root, call);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var test_state = StageTestState{
        .cancel_flag = &cancel_flag,
        .add_blocker = true,
    };

    const rejected = try expectApplyRejected(
        try applyWithTestControls(
            call_alloc,
            result_alloc,
            call,
            executionAuthorization(prepared),
            &cancel_flag,
            .{ .ctx = &test_state, .after_stage = mutateAfterStage },
        ),
        .cancelled,
    );
    try std.testing.expectEqual(@as(usize, 2), rejected.created_parent_residue.len);
    try std.testing.expect(
        rejected.created_parent_residue[0].component_index >
            rejected.created_parent_residue[1].component_index,
    );
    for (rejected.created_parent_residue) |residue| {
        try std.testing.expectEqual(
            ParentCleanupResidueReason.not_empty,
            residue.reason,
        );
        try std.testing.expect(residue.observed_identity != null);
    }
    const blocker = try readTestFile(call_alloc, &tmp, "one/two/blocker");
    try std.testing.expectEqualStrings("", blocker);
}

test "apply preserves the existing destination mode" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(&tmp, "mode.txt", "old");
    {
        var file = try tmp.dir.openFile(std.testing.io, "mode.txt", .{});
        defer file.close(std.testing.io);
        try file.setPermissions(
            std.testing.io,
            std.Io.File.Permissions.fromMode(0o640),
        );
    }
    var call_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer call_arena_state.deinit();
    var result_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena_state.deinit();
    const call_alloc = call_arena_state.allocator();
    const result_alloc = result_arena_state.allocator();
    const root = try workspaceRoot(call_alloc, tmp);
    const call: types.ToolCall = .{
        .id = "mode",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(call_alloc, "mode.txt", "new"),
    };
    const prepared = try prepareForApply(call_alloc, root, call);
    var cancel_flag = std.atomic.Value(bool).init(false);

    const result = try apply(
        call_alloc,
        result_alloc,
        call,
        executionAuthorization(prepared),
        &cancel_flag,
    );
    try std.testing.expect(result == .committed);
    const stat = try tmp.dir.statFile(
        std.testing.io,
        "mode.txt",
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0o640),
        stat.permissions.toMode() & 0o777,
    );
}

test "approved mutation cannot apply twice" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var call_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer call_arena_state.deinit();
    var result_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena_state.deinit();
    const call_alloc = call_arena_state.allocator();
    const result_alloc = result_arena_state.allocator();
    const root = try workspaceRoot(call_alloc, tmp);
    const call: types.ToolCall = .{
        .id = "single-use-proof",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(call_alloc, "new.txt", "reviewed"),
    };
    const prepared = try prepareForApply(call_alloc, root, call);
    var cancel_flag = std.atomic.Value(bool).init(false);

    const first = try apply(
        call_alloc,
        result_alloc,
        call,
        executionAuthorization(prepared),
        &cancel_flag,
    );
    try std.testing.expect(first == .committed);
    try std.testing.expectError(
        error.ResultContractViolation,
        apply(
            call_alloc,
            result_alloc,
            call,
            executionAuthorization(prepared),
            &cancel_flag,
        ),
    );
    const installed = try readTestFile(call_alloc, &tmp, "new.txt");
    try std.testing.expectEqualStrings("reviewed", installed);
}

test "apply commit handoff remains valid after the call owner is destroyed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var result_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena_state.deinit();
    const result_alloc = result_arena_state.allocator();
    var call_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    const call_alloc = call_arena_state.allocator();
    const root = try workspaceRoot(call_alloc, tmp);
    const call: types.ToolCall = .{
        .id = "result-lifetime",
        .name = "write_file",
        .arguments_json = try writeArgumentsJson(call_alloc, "new.txt", "reviewed"),
    };
    const prepared = try prepareForApply(call_alloc, root, call);
    var cancel_flag = std.atomic.Value(bool).init(false);
    const result = try apply(
        call_alloc,
        result_alloc,
        call,
        executionAuthorization(prepared),
        &cancel_flag,
    );
    const committed_handoff = switch (result) {
        .committed => |handoff| handoff,
        .rejected => return error.UnexpectedRejectedMutation,
    };

    call_arena_state.deinit();

    try std.testing.expectEqualStrings("new.txt", committed_handoff.preview.path);
    try std.testing.expect(
        std.mem.endsWith(u8, committed_handoff.tracker.raw_path, "new.txt"),
    );
    try std.testing.expectEqual(
        file_mutation_contract.Kind.write,
        committed_handoff.tracker.kind,
    );
}
