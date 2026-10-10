const std = @import("std");
const diff_mod = @import("../output/diff.zig");
const types = @import("../shared/types.zig");

pub const max_file_target_components: usize = 256;
pub const max_file_target_proof_bytes: usize = 32 * 1024;
pub const max_external_scope_tail_bytes: usize = 4 * 1024;

pub const PermissionTargetKind = enum {
    target,
    parent,
};

pub const FileTargetDisposition = enum {
    target_entry,
    existing_parent,
    create_parent,
};

pub const FileIdentity = struct {
    device: u64,
    inode: u64,
    kind: std.Io.File.Kind,
};

pub const PathSpan = struct {
    start: usize,
    end: usize,
};

pub const VerifiedTraversalAnchor = struct {
    scope: enum { workspace, external },
    path_end: usize,
    identity: FileIdentity,
    relative_components: []const PathSpan,
};

pub const TraversalDirectoryState = union(enum) {
    existing: FileIdentity,
    create: struct {
        permission_target_index: usize,
    },
};

pub const TraversalDirectory = struct {
    component_index: usize,
    path_end: usize,
    state: TraversalDirectoryState,
};

pub const EvaluatedPermissionTarget = struct {
    kind: PermissionTargetKind,
    disposition: FileTargetDisposition,
    path_end: usize,
    expected_identity: ?FileIdentity,
    rule: types.RuleDecision,
    session_grant_allowed: bool,
};

pub const ResolvedPermissionTarget = struct {
    kind: PermissionTargetKind,
    disposition: FileTargetDisposition,
    path_end: usize,
    expected_identity: ?FileIdentity,
};

/// Owns the policy-neutral canonical target and filesystem identity proof for
/// one decoded write_file or edit_file call.
pub const ResolvedFileMutationTargets = struct {
    canonical_target_path: []const u8,
    anchor: VerifiedTraversalAnchor,
    traversal_directories: []const TraversalDirectory,
    items: []const ResolvedPermissionTarget,
    owns_memory: bool = true,

    pub fn deinit(self: *ResolvedFileMutationTargets, alloc: std.mem.Allocator) void {
        if (!self.owns_memory) return;
        alloc.free(@constCast(self.canonical_target_path));
        alloc.free(@constCast(self.anchor.relative_components));
        alloc.free(@constCast(self.traversal_directories));
        alloc.free(@constCast(self.items));
        self.owns_memory = false;
    }

    pub fn relinquish(self: *ResolvedFileMutationTargets) void {
        self.owns_memory = false;
    }

    pub fn anchorPath(self: ResolvedFileMutationTargets) []const u8 {
        return self.canonical_target_path[0..self.anchor.path_end];
    }

    pub fn component(self: ResolvedFileMutationTargets, span: PathSpan) []const u8 {
        return self.canonical_target_path[span.start..span.end];
    }

    pub fn traversalPath(self: ResolvedFileMutationTargets, entry: TraversalDirectory) []const u8 {
        return self.canonical_target_path[0..entry.path_end];
    }

    pub fn permissionPath(self: ResolvedFileMutationTargets, item: ResolvedPermissionTarget) []const u8 {
        return self.canonical_target_path[0..item.path_end];
    }

    pub fn proofValid(self: ResolvedFileMutationTargets) bool {
        const canonical = self.canonical_target_path;
        const components = self.anchor.relative_components;
        const items = self.items;
        if (!targetPathShapeValid(self, canonical, components)) return false;
        if (!permissionTargetsValid(self, components, items)) return false;
        const charge = proofCharge(
            canonical.len,
            components.len,
            self.traversal_directories.len,
            items.len,
        ) orelse return false;
        return charge <= max_file_target_proof_bytes;
    }
};

pub const PolicyEvaluatedFileTargets = struct {
    canonical_target_path: []const u8,
    anchor: VerifiedTraversalAnchor,
    traversal_directories: []const TraversalDirectory,
    items: []const EvaluatedPermissionTarget,
    prompt_required: bool,

    pub fn deinitOwned(self: *PolicyEvaluatedFileTargets, alloc: std.mem.Allocator) void {
        alloc.free(@constCast(self.canonical_target_path));
        alloc.free(@constCast(self.anchor.relative_components));
        alloc.free(@constCast(self.traversal_directories));
        alloc.free(@constCast(self.items));
        self.* = undefined;
    }

    pub fn anchorPath(self: PolicyEvaluatedFileTargets) []const u8 {
        return self.canonical_target_path[0..self.anchor.path_end];
    }

    pub fn component(self: PolicyEvaluatedFileTargets, span: PathSpan) []const u8 {
        return self.canonical_target_path[span.start..span.end];
    }

    pub fn traversalPath(self: PolicyEvaluatedFileTargets, entry: TraversalDirectory) []const u8 {
        return self.canonical_target_path[0..entry.path_end];
    }

    pub fn permissionPath(self: PolicyEvaluatedFileTargets, item: EvaluatedPermissionTarget) []const u8 {
        return self.canonical_target_path[0..item.path_end];
    }

    pub fn authorizationEql(
        a: PolicyEvaluatedFileTargets,
        b: PolicyEvaluatedFileTargets,
    ) bool {
        if (!std.mem.eql(u8, a.canonical_target_path, b.canonical_target_path)) return false;
        if (a.anchor.scope != b.anchor.scope) return false;
        if (a.anchor.path_end != b.anchor.path_end) return false;
        if (!std.meta.eql(a.anchor.identity, b.anchor.identity)) return false;
        if (!sliceEql(PathSpan, a.anchor.relative_components, b.anchor.relative_components)) return false;
        if (!sliceEql(TraversalDirectory, a.traversal_directories, b.traversal_directories)) return false;
        if (!sliceEql(EvaluatedPermissionTarget, a.items, b.items)) return false;
        return a.prompt_required == b.prompt_required;
    }

    pub fn proofValid(self: PolicyEvaluatedFileTargets) bool {
        const canonical = self.canonical_target_path;
        const components = self.anchor.relative_components;
        const items = self.items;
        if (!targetPathShapeValid(self, canonical, components)) return false;
        if (!permissionTargetsValid(self, components, items)) return false;
        const charge = proofCharge(
            canonical.len,
            components.len,
            self.traversal_directories.len,
            items.len,
        ) orelse return false;
        return charge <= max_file_target_proof_bytes;
    }
};

pub fn proofCharge(
    canonical_path_len: usize,
    component_count: usize,
    traversal_count: usize,
    item_count: usize,
) ?usize {
    var total = canonical_path_len;
    total = checkedProofCharge(total, component_count, @sizeOf(PathSpan)) orelse
        return null;
    total = checkedProofCharge(total, traversal_count, @sizeOf(TraversalDirectory)) orelse
        return null;
    return checkedProofCharge(
        total,
        item_count,
        @sizeOf(EvaluatedPermissionTarget),
    );
}

fn targetPathShapeValid(
    targets: anytype,
    canonical: []const u8,
    components: []const PathSpan,
) bool {
    if (canonical.len == 0 or canonical.len > std.Io.Dir.max_path_bytes) return false;
    if (!std.Io.Dir.path.isAbsolute(canonical)) return false;
    if (targets.anchor.path_end == 0 or targets.anchor.path_end > canonical.len) return false;
    if (targets.anchor.identity.kind != .directory) return false;

    if (components.len == 0 or components.len > max_file_target_components) {
        return false;
    }
    if (targets.traversal_directories.len != components.len - 1) return false;

    var expected_start = targets.anchor.path_end;
    if (expected_start < canonical.len and std.Io.Dir.path.isSep(canonical[expected_start])) {
        expected_start += 1;
    }
    for (components) |component| {
        if (component.start != expected_start) return false;
        if (component.end <= component.start or component.end > canonical.len) return false;
        expected_start = component.end;
        if (expected_start < canonical.len and std.Io.Dir.path.isSep(canonical[expected_start])) {
            expected_start += 1;
        }
    }
    return components[components.len - 1].end == canonical.len;
}

fn permissionTargetsValid(
    targets: anytype,
    components: []const PathSpan,
    items: anytype,
) bool {
    if (components.len == 0) return false;
    if (targets.traversal_directories.len != components.len - 1) return false;
    if (items.len < 2 or items.len > max_file_target_components + 1) {
        return false;
    }
    if (!permissionItemMatches(
        items[0],
        .target,
        .target_entry,
        targets.canonical_target_path.len,
        items[0].expected_identity,
    )) return false;

    var used_items: [max_file_target_components + 1]bool = @splat(false);
    used_items[0] = true;
    used_items[1] = true;

    var create_seen = false;
    for (targets.traversal_directories, 0..) |entry, index| {
        if (entry.component_index != index) return false;
        if (entry.path_end != components[index].end) return false;
        switch (entry.state) {
            .existing => |identity| {
                if (create_seen or identity.kind != .directory) return false;
            },
            .create => |create| {
                create_seen = true;
                if (create.permission_target_index >= items.len) return false;
                if (used_items[create.permission_target_index] and
                    create.permission_target_index != 1)
                {
                    return false;
                }
                const item = items[create.permission_target_index];
                if (!permissionItemMatches(
                    item,
                    .parent,
                    .create_parent,
                    entry.path_end,
                    null,
                )) return false;
                used_items[create.permission_target_index] = true;
            },
        }
    }

    if (targets.traversal_directories.len == 0) {
        if (!permissionItemMatches(
            items[1],
            .parent,
            .existing_parent,
            targets.anchor.path_end,
            targets.anchor.identity,
        )) return false;
    } else {
        const parent = targets.traversal_directories[targets.traversal_directories.len - 1];
        switch (parent.state) {
            .existing => |identity| {
                if (!permissionItemMatches(
                    items[1],
                    .parent,
                    .existing_parent,
                    parent.path_end,
                    identity,
                )) return false;
            },
            .create => |create| {
                if (create.permission_target_index != 1) return false;
                if (!permissionItemMatches(
                    items[1],
                    .parent,
                    .create_parent,
                    parent.path_end,
                    null,
                )) return false;
            },
        }
    }
    for (used_items[0..items.len]) |used| {
        if (!used) return false;
    }
    return true;
}

fn permissionItemMatches(
    item: anytype,
    kind: PermissionTargetKind,
    disposition: FileTargetDisposition,
    path_end: usize,
    expected_identity: ?FileIdentity,
) bool {
    return item.kind == kind and
        item.disposition == disposition and
        item.path_end == path_end and
        optionalIdentityEql(item.expected_identity, expected_identity);
}

fn checkedProofCharge(base: usize, count: usize, item_size: usize) ?usize {
    const bytes = std.math.mul(usize, count, item_size) catch return null;
    return std.math.add(usize, base, bytes) catch null;
}

fn optionalIdentityEql(a: ?FileIdentity, b: ?FileIdentity) bool {
    if (a) |actual| {
        const expected = b orelse return false;
        return std.meta.eql(actual, expected);
    }
    return b == null;
}

test "policy target proof validation accepts and rejects owned target shapes" {
    const canonical = if (std.Io.Dir.path.sep == '\\')
        "C:\\workspace\\parent\\note.txt"
    else
        "/workspace/parent/note.txt";
    const anchor_end = if (std.Io.Dir.path.sep == '\\')
        "C:\\workspace".len
    else
        "/workspace".len;
    const parent_start = anchor_end + 1;
    const parent_end = parent_start + "parent".len;
    const target_start = parent_end + 1;
    const target_end = target_start + "note.txt".len;

    const anchor_identity: FileIdentity = .{
        .device = 1,
        .inode = 10,
        .kind = .directory,
    };
    const parent_identity: FileIdentity = .{
        .device = 1,
        .inode = 11,
        .kind = .directory,
    };
    const target_identity: FileIdentity = .{
        .device = 1,
        .inode = 12,
        .kind = .file,
    };
    const components = [_]PathSpan{
        .{ .start = parent_start, .end = parent_end },
        .{ .start = target_start, .end = target_end },
    };
    const traversal = [_]TraversalDirectory{
        .{
            .component_index = 0,
            .path_end = parent_end,
            .state = .{ .existing = parent_identity },
        },
    };
    const items = [_]EvaluatedPermissionTarget{
        .{
            .kind = .target,
            .disposition = .target_entry,
            .path_end = canonical.len,
            .expected_identity = target_identity,
            .rule = .allow,
            .session_grant_allowed = false,
        },
        .{
            .kind = .parent,
            .disposition = .existing_parent,
            .path_end = parent_end,
            .expected_identity = parent_identity,
            .rule = .allow,
            .session_grant_allowed = false,
        },
    };
    const policy: PolicyEvaluatedFileTargets = .{
        .canonical_target_path = canonical,
        .anchor = .{
            .scope = .workspace,
            .path_end = anchor_end,
            .identity = anchor_identity,
            .relative_components = &components,
        },
        .traversal_directories = &traversal,
        .items = &items,
        .prompt_required = false,
    };

    try std.testing.expect(policy.proofValid());

    var corrupted_components = components;
    corrupted_components[0].start = anchor_end;
    var corrupted_policy = policy;
    corrupted_policy.anchor.relative_components = &corrupted_components;
    try std.testing.expect(!corrupted_policy.proofValid());

    const unused_items = [_]EvaluatedPermissionTarget{
        items[0],
        items[1],
        items[0],
    };
    var unused_item_policy = policy;
    unused_item_policy.items = &unused_items;
    try std.testing.expect(!unused_item_policy.proofValid());
}

test "file target proof charge rejects arithmetic overflow" {
    try std.testing.expect(proofCharge(std.math.maxInt(usize), 1, 0, 0) == null);
}

pub const FileTargetPolicyResult = union(enum) {
    target_resolution_failure: FileTargetResolutionFailure,
    policy_denied: struct { target_index: usize },
    evaluated: PolicyEvaluatedFileTargets,
};

pub const FileTargetPreparationResult = union(enum) {
    target_resolution_failure: FileTargetResolutionFailure,
    prepared: ResolvedFileMutationTargets,
};

pub const FileTargetResolutionFailure = enum {
    path_outside_workspace,
    file_not_found,
    home_not_set,
    invalid_path,
    workspace_unavailable,
    too_many_path_components,
    policy_proof_too_large,
    access_denied,
    not_directory,
    symlink_loop,
    name_too_long,
    bad_path_name,
    path_state_changed,
    unsupported_path_operation,
    filesystem_unavailable,
};

pub const Kind = enum {
    write,
    edit,
};

pub const FileApprovalIntent = enum {
    mutation,
    equality_disclosure,
};

pub const FileApprovalScope = union(enum) {
    workspace_files,
    external_tree: []const u8,
};

pub const FileGrantOffer = struct {
    grants: []const types.PermissionGrant,
    scope: FileApprovalScope,
};

pub fn isToolName(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "edit_file");
}

pub fn resultIsNoop(tool_name: []const u8, output: []const u8) bool {
    return isToolName(tool_name) and
        std.mem.startsWith(u8, output, "No changes to ");
}

test "persisted result no-op requires a file mutation tool and canonical output" {
    try std.testing.expect(resultIsNoop("write_file", "No changes to note.txt"));
    try std.testing.expect(resultIsNoop("edit_file", "No changes to note.txt"));
    try std.testing.expect(!resultIsNoop("read_file", "No changes to note.txt"));
    try std.testing.expect(!resultIsNoop("write_file", "Wrote note.txt"));
}

pub const WriteInput = struct {
    path: []u8,
    content: []u8,
};

pub const EditInput = struct {
    path: []u8,
    old_string: []u8,
    new_string: []u8,
};

pub const FileMutationInput = union(Kind) {
    write: WriteInput,
    edit: EditInput,

    pub fn path(self: FileMutationInput) []const u8 {
        return switch (self) {
            inline else => |input| input.path,
        };
    }

    pub fn deinit(self: *FileMutationInput, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .write => |write| {
                alloc.free(write.path);
                alloc.free(write.content);
            },
            .edit => |edit| {
                alloc.free(edit.path);
                alloc.free(edit.old_string);
                alloc.free(edit.new_string);
            },
        }
        self.* = undefined;
    }
};

test "file mutation input owns write and edit fields" {
    const write_path = "note.txt";
    const write_content = "hello\n";
    var write_input: FileMutationInput = .{ .write = .{
        .path = try std.testing.allocator.dupe(u8, write_path),
        .content = try std.testing.allocator.dupe(u8, write_content),
    } };
    try std.testing.expectEqualStrings(write_path, write_input.path());
    try std.testing.expectEqualStrings(write_content, write_input.write.content);
    try std.testing.expect(write_input.write.path.ptr != write_path.ptr);
    try std.testing.expect(write_input.write.content.ptr != write_content.ptr);
    write_input.deinit(std.testing.allocator);

    const edit_path = "note.txt";
    const old_string = "hello";
    const new_string = "goodbye";
    var edit_input: FileMutationInput = .{ .edit = .{
        .path = try std.testing.allocator.dupe(u8, edit_path),
        .old_string = try std.testing.allocator.dupe(u8, old_string),
        .new_string = try std.testing.allocator.dupe(u8, new_string),
    } };
    try std.testing.expectEqualStrings(edit_path, edit_input.path());
    try std.testing.expectEqualStrings(old_string, edit_input.edit.old_string);
    try std.testing.expectEqualStrings(new_string, edit_input.edit.new_string);
    try std.testing.expect(edit_input.edit.path.ptr != edit_path.ptr);
    try std.testing.expect(edit_input.edit.old_string.ptr != old_string.ptr);
    try std.testing.expect(edit_input.edit.new_string.ptr != new_string.ptr);
    edit_input.deinit(std.testing.allocator);
}

pub const Preimage = union(enum) {
    absent,
    present: struct {
        content: []const u8,
        content_hash: types.ContentHash,
    },
};

pub const PreparedFileMutation = struct {
    call_id: []const u8,
    tool_name: []const u8,
    arguments_hash: types.ContentHash,
    target_path: []const u8,
    display_path: []const u8,
    policy_targets: PolicyEvaluatedFileTargets,
    kind: Kind,
    preimage: Preimage,
    after_content: []const u8,
    preview: diff_mod.FileChangePreview,
    review: diff_mod.FileReview,
    commit_token: *anyopaque,
};

pub fn preparedMutationIsNoop(prepared: PreparedFileMutation) bool {
    return switch (prepared.preimage) {
        .absent => false,
        .present => |present| std.mem.eql(
            u8,
            present.content,
            prepared.after_content,
        ),
    };
}

pub const PrepareResult = union(enum) {
    prepared: PreparedFileMutation,
    semantic_failure: []const u8,
};

pub const FileExecutionAuthorization = struct {
    input: FileMutationInput,
    policy_targets: PolicyEvaluatedFileTargets,
    prepared: ?PreparedFileMutation = null,
    grant_offer: ?FileGrantOffer = null,
    approval_intent: ?FileApprovalIntent = null,
    read_disclosure_required: bool = false,
};

fn sliceEql(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_item, b_item| {
        if (!std.meta.eql(a_item, b_item)) return false;
    }
    return true;
}
