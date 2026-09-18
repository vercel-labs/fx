const std = @import("std");
const change_tracker = @import("../../core/workspace/change_tracker.zig");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const permissions = @import("../../core/permissions/permissions.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;
const max_patch_bytes: usize = 4 * 1024 * 1024;
const max_file_bytes: usize = 4 * 1024 * 1024;
const max_operations: usize = 64;
const max_hunks: usize = 256;
const max_context_snippet_bytes: usize = 160;

const Hunk = struct {
    old_text: []u8,
    new_text: []u8,

    fn deinit(self: *Hunk, alloc: Allocator) void {
        alloc.free(self.old_text);
        alloc.free(self.new_text);
        self.* = undefined;
    }
};

const Update = struct {
    path: []u8,
    move_to: ?[]u8 = null,
    hunks: []Hunk,
    anchor_eof: bool = false,

    fn deinit(self: *Update, alloc: Allocator) void {
        alloc.free(self.path);
        if (self.move_to) |move_to| alloc.free(move_to);
        for (self.hunks) |*hunk| hunk.deinit(alloc);
        alloc.free(self.hunks);
        self.* = undefined;
    }
};

const Add = struct {
    path: []u8,
    content: []u8,

    fn deinit(self: *Add, alloc: Allocator) void {
        alloc.free(self.path);
        alloc.free(self.content);
        self.* = undefined;
    }
};

const Delete = struct {
    path: []u8,

    fn deinit(self: *Delete, alloc: Allocator) void {
        alloc.free(self.path);
        self.* = undefined;
    }
};

const Operation = union(enum) {
    update: Update,
    add: Add,
    delete: Delete,

    fn deinit(self: *Operation, alloc: Allocator) void {
        switch (self.*) {
            .update => |*value| value.deinit(alloc),
            .add => |*value| value.deinit(alloc),
            .delete => |*value| value.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub const Input = struct {
    operations: []Operation,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        for (self.operations) |*operation| operation.deinit(alloc);
        alloc.free(self.operations);
        self.* = .{ .operations = &.{} };
    }
};

const Parser = struct {
    alloc: Allocator,
    lines: []const []const u8,
    index: usize = 0,
    reason: []const u8 = "invalid apply_patch input",
    hunk_count: usize = 0,

    const Error = Allocator.Error || std.Io.Writer.Error || error{InvalidPatch};

    fn invalid(self: *Parser, reason: []const u8) Error {
        self.reason = reason;
        return error.InvalidPatch;
    }

    fn current(self: *const Parser) ?[]const u8 {
        if (self.index >= self.lines.len) return null;
        return stripCarriageReturn(self.lines[self.index]);
    }

    fn parse(self: *Parser) Error![]Operation {
        if (!std.mem.eql(u8, self.current() orelse "", "*** Begin Patch")) {
            return self.invalid("apply_patch must start with *** Begin Patch");
        }
        self.index += 1;

        var operations: std.ArrayList(Operation) = .empty;
        var operations_transferred = false;
        defer if (!operations_transferred) {
            for (operations.items) |*operation| operation.deinit(self.alloc);
            operations.deinit(self.alloc);
        };

        while (self.current()) |line| {
            if (std.mem.eql(u8, line, "*** End Patch")) {
                self.index += 1;
                while (self.current()) |remaining| : (self.index += 1) {
                    if (std.mem.trim(u8, remaining, " \t").len != 0) {
                        return self.invalid("apply_patch has content after *** End Patch");
                    }
                }
                if (operations.items.len == 0) {
                    return self.invalid("apply_patch requires at least one file operation");
                }
                const owned = try operations.toOwnedSlice(self.alloc);
                operations_transferred = true;
                return owned;
            }
            if (std.mem.trim(u8, line, " \t").len == 0) {
                self.index += 1;
                continue;
            }
            if (operations.items.len == max_operations) {
                return self.invalid("apply_patch exceeds the 64 file-operation limit");
            }

            var operation = if (std.mem.startsWith(u8, line, "*** Update File: "))
                try self.parseUpdate()
            else if (std.mem.startsWith(u8, line, "*** Add File: "))
                try self.parseAdd()
            else if (std.mem.startsWith(u8, line, "*** Delete File: "))
                try self.parseDelete()
            else
                return self.invalid("apply_patch expected Update File, Add File, Delete File, or End Patch");
            errdefer operation.deinit(self.alloc);
            try operations.append(self.alloc, operation);
        }

        return self.invalid("apply_patch must end with *** End Patch");
    }

    fn parseUpdate(self: *Parser) Error!Operation {
        const path = try self.parseHeaderPath("*** Update File: ");
        errdefer self.alloc.free(path);
        self.index += 1;

        var move_to: ?[]u8 = null;
        errdefer if (move_to) |value| self.alloc.free(value);
        if (self.current()) |line| {
            if (std.mem.startsWith(u8, line, "*** Move to: ")) {
                move_to = try self.parseHeaderPath("*** Move to: ");
                self.index += 1;
            }
        }

        var hunks: std.ArrayList(Hunk) = .empty;
        var hunks_transferred = false;
        defer if (!hunks_transferred) {
            for (hunks.items) |*hunk| hunk.deinit(self.alloc);
            hunks.deinit(self.alloc);
        };
        while (self.current()) |line| {
            if (!std.mem.startsWith(u8, line, "@@")) break;
            if (self.hunk_count == max_hunks) {
                return self.invalid("apply_patch exceeds the 256 hunk limit");
            }
            self.hunk_count += 1;
            self.index += 1;
            var hunk = try self.parseHunk();
            errdefer hunk.deinit(self.alloc);
            try hunks.append(self.alloc, hunk);
        }
        if (hunks.items.len == 0) {
            return self.invalid("apply_patch Update File requires at least one @@ hunk");
        }
        const anchor_eof = if (self.current()) |line|
            std.mem.eql(u8, line, "*** End of File")
        else
            false;
        if (anchor_eof) self.index += 1;

        const owned_hunks = try hunks.toOwnedSlice(self.alloc);
        hunks_transferred = true;
        return .{ .update = .{
            .path = path,
            .move_to = move_to,
            .hunks = owned_hunks,
            .anchor_eof = anchor_eof,
        } };
    }

    fn parseAdd(self: *Parser) Error!Operation {
        const path = try self.parseHeaderPath("*** Add File: ");
        errdefer self.alloc.free(path);
        self.index += 1;

        var content: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer content.deinit();
        var previous_added = false;
        while (self.index < self.lines.len) {
            const raw = self.lines[self.index];
            const line = stripCarriageReturn(raw);
            if (std.mem.startsWith(u8, line, "*** ")) break;
            if (std.mem.eql(u8, line, "\\ No newline at end of file")) {
                if (!previous_added or !removeTrailingLineEnding(&content)) {
                    return self.invalid("apply_patch no-newline marker must follow an added line");
                }
                previous_added = false;
                self.index += 1;
                continue;
            }
            if (line.len == 0 or line[0] != '+') {
                return self.invalid("apply_patch Add File lines require a + prefix");
            }
            try content.writer.writeAll(line[1..]);
            try content.writer.writeByte('\n');
            previous_added = true;
            self.index += 1;
        }

        return .{ .add = .{
            .path = path,
            .content = try content.toOwnedSlice(),
        } };
    }

    fn parseDelete(self: *Parser) Error!Operation {
        const path = try self.parseHeaderPath("*** Delete File: ");
        self.index += 1;
        return .{ .delete = .{ .path = path } };
    }

    fn parseHeaderPath(self: *Parser, prefix: []const u8) Error![]u8 {
        const line = self.current() orelse return self.invalid("apply_patch file header is missing");
        if (!std.mem.startsWith(u8, line, prefix)) {
            return self.invalid("apply_patch file header is malformed");
        }
        const path = std.mem.trim(u8, line[prefix.len..], " \t");
        if (path.len == 0) return self.invalid("apply_patch file path must not be empty");
        if (path.len > std.Io.Dir.max_path_bytes or
            std.mem.findScalar(u8, path, 0) != null)
        {
            return self.invalid("apply_patch file path is invalid");
        }
        return self.alloc.dupe(u8, path);
    }

    fn parseHunk(self: *Parser) Error!Hunk {
        var old_out: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer old_out.deinit();
        var new_out: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer new_out.deinit();
        var previous: ?HunkLineKind = null;

        while (self.index < self.lines.len) {
            const raw = self.lines[self.index];
            const line = stripCarriageReturn(raw);
            if (std.mem.startsWith(u8, line, "@@") or
                std.mem.startsWith(u8, line, "*** "))
            {
                break;
            }
            if (std.mem.eql(u8, line, "\\ No newline at end of file")) {
                const prior = previous orelse
                    return self.invalid("apply_patch no-newline marker must follow a hunk line");
                if ((prior == .context or prior == .removed) and
                    !removeTrailingLineEnding(&old_out))
                {
                    return self.invalid("apply_patch no-newline marker is misplaced");
                }
                if ((prior == .context or prior == .added) and
                    !removeTrailingLineEnding(&new_out))
                {
                    return self.invalid("apply_patch no-newline marker is misplaced");
                }
                previous = null;
                self.index += 1;
                continue;
            }
            if (line.len == 0) {
                return self.invalid("apply_patch hunk lines require a space, +, or - prefix");
            }

            const body = line[1..];
            switch (line[0]) {
                ' ' => {
                    try appendPatchLine(&old_out, body);
                    try appendPatchLine(&new_out, body);
                    previous = .context;
                },
                '-' => {
                    try appendPatchLine(&old_out, body);
                    previous = .removed;
                },
                '+' => {
                    try appendPatchLine(&new_out, body);
                    previous = .added;
                },
                else => return self.invalid("apply_patch hunk lines require a space, +, or - prefix"),
            }
            self.index += 1;
        }

        const old_text = try old_out.toOwnedSlice();
        errdefer self.alloc.free(old_text);
        if (old_text.len == 0) {
            return self.invalid("apply_patch update insertion requires at least one context or removed line");
        }
        return .{
            .old_text = old_text,
            .new_text = try new_out.toOwnedSlice(),
        };
    }
};

const HunkLineKind = enum { context, removed, added };

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    return decodeAlloc(ctx.allocator, args_json);
}

fn decodeAlloc(
    alloc: Allocator,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch {
        return failure(alloc, "apply_patch arguments must be valid JSON");
    };
    defer parsed.deinit();

    const patch = switch (parsed.value) {
        .string => |value| value,
        .object => |object| blk: {
            const value = object.get("patch") orelse object.get("input") orelse
                return failure(alloc, "apply_patch requires string field \"patch\"");
            if (value != .string) {
                return failure(alloc, "apply_patch field \"patch\" must be a string");
            }
            break :blk value.string;
        },
        else => return failure(alloc, "apply_patch arguments must be an object or patch string"),
    };
    if (patch.len > max_patch_bytes) {
        return failure(alloc, "apply_patch patch exceeds the 4 MiB limit");
    }

    const normalized = trimMarkdownFence(patch);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var iterator = std.mem.splitScalar(u8, normalized, '\n');
    while (iterator.next()) |line| try lines.append(alloc, line);

    var parser = Parser{ .alloc = alloc, .lines = lines.items };
    const operations = parser.parse() catch |err| switch (err) {
        error.InvalidPatch => return failure(alloc, parser.reason),
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return failure(alloc, "apply_patch could not buffer the patch"),
    };
    errdefer {
        for (operations) |*operation| operation.deinit(alloc);
        alloc.free(operations);
    }
    const input = try alloc.create(Input);
    input.* = .{ .operations = operations };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

/// Resolves every source and destination before admission so one denied path
/// rejects the complete transactional patch.
pub fn permissionTargets(
    alloc: Allocator,
    workspace_root: []const u8,
    args_json: []const u8,
) anyerror!permissions.PermissionCallTargets {
    if (workspace_root.len == 0) return error.WorkspaceUnavailable;

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const decoded = try decodeAlloc(scratch, args_json);
    const erased = switch (decoded) {
        .input => |input| input,
        .failure => return error.InvalidToolArguments,
    };
    defer erased.deinit(scratch);
    const input = erased.as(Input);

    var targets: std.ArrayList(permissions.PermissionCallTarget) = .empty;
    errdefer {
        for (targets.items) |target| alloc.free(target.path);
        targets.deinit(alloc);
    }
    for (input.operations) |operation| {
        switch (operation) {
            .update => |update| {
                try appendPermissionTarget(
                    alloc,
                    &targets,
                    "update",
                    try resolvePatchPath(scratch, workspace_root, update.path, .existing),
                );
                if (update.move_to) |move_to| {
                    try appendPermissionTarget(
                        alloc,
                        &targets,
                        "move_destination",
                        try resolvePatchPath(scratch, workspace_root, move_to, .create),
                    );
                }
            },
            .add => |add| try appendPermissionTarget(
                alloc,
                &targets,
                "add",
                try resolvePatchPath(scratch, workspace_root, add.path, .create),
            ),
            .delete => |delete| try appendPermissionTarget(
                alloc,
                &targets,
                "delete",
                try resolvePatchPath(scratch, workspace_root, delete.path, .existing),
            ),
        }
    }
    return .{ .items = try targets.toOwnedSlice(alloc) };
}

fn appendPermissionTarget(
    alloc: Allocator,
    targets: *std.ArrayList(permissions.PermissionCallTarget),
    role: []const u8,
    path: []const u8,
) Allocator.Error!void {
    for (targets.items) |target| {
        if (std.mem.eql(u8, target.path, path)) return;
    }
    const owned_path = try alloc.dupe(u8, path);
    errdefer alloc.free(owned_path);
    try targets.append(alloc, .{ .role = role, .path = owned_path });
}

fn failure(alloc: Allocator, reason: []const u8) Allocator.Error!tool_dispatch.DecodeResult {
    return .{ .failure = try alloc.dupe(u8, reason) };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    if (input.operations.len == 0) {
        return try ctx.allocator.dupe(u8, "apply_patch requires at least one file operation");
    }
    return null;
}

const Before = union(enum) {
    absent,
    content: []const u8,
};

const ChangeKind = enum { update, add, delete };

const PreparedChange = struct {
    kind: ChangeKind,
    path: []const u8,
    before: Before,
    after: ?[]const u8,
};

const ContentResult = union(enum) {
    content: []const u8,
    failure: []const u8,
};

const MatchEvidence = struct {
    count: usize = 0,
    first_offset: usize = 0,
    second_offset: usize = 0,
};

const AnchorEvidence = struct {
    line: usize,
    snippet: []const u8,
};

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (ctx.workspace_root.len == 0) {
        return .{ .failure = try ctx.allocator.dupe(u8, "apply_patch requires a workspace") };
    }

    var prepared: std.ArrayList(PreparedChange) = .empty;
    defer prepared.deinit(arena);
    var updated: usize = 0;
    var added: usize = 0;
    var deleted: usize = 0;

    for (input.operations) |operation| {
        switch (operation) {
            .update => |update| {
                const source = resolvePatchPath(arena, ctx.workspace_root, update.path, .existing) catch |err| {
                    return pathFailure(ctx.allocator, update.path, err);
                };
                if (targetAlreadyPrepared(prepared.items, source)) {
                    return duplicateTarget(ctx.allocator, update.path);
                }
                const before = readPatchFile(arena, source) catch |err| {
                    return fileFailure(ctx.allocator, update.path, err);
                };
                const patched = switch (try applyHunks(
                    arena,
                    before,
                    update.hunks,
                    update.anchor_eof,
                )) {
                    .content => |content| content,
                    .failure => |reason| return .{ .failure = try std.fmt.allocPrint(
                        ctx.allocator,
                        "{s}; file={s}",
                        .{ reason, update.path },
                    ) },
                };
                if (std.mem.eql(u8, before, patched) and update.move_to == null) continue;

                if (update.move_to) |move_to| {
                    const destination = resolvePatchPath(arena, ctx.workspace_root, move_to, .create) catch |err| {
                        return pathFailure(ctx.allocator, move_to, err);
                    };
                    if (std.mem.eql(u8, source, destination) or
                        targetAlreadyPrepared(prepared.items, destination))
                    {
                        return duplicateTarget(ctx.allocator, move_to);
                    }
                    if (pathExists(destination) catch |err| {
                        return fileFailure(ctx.allocator, move_to, err);
                    }) {
                        return .{ .failure = try std.fmt.allocPrint(
                            ctx.allocator,
                            "apply_patch failed: move destination already exists: {s}",
                            .{move_to},
                        ) };
                    }
                    try prepared.append(arena, .{
                        .kind = .add,
                        .path = destination,
                        .before = .absent,
                        .after = patched,
                    });
                    try prepared.append(arena, .{
                        .kind = .delete,
                        .path = source,
                        .before = .{ .content = before },
                        .after = null,
                    });
                    added += 1;
                    deleted += 1;
                } else {
                    try prepared.append(arena, .{
                        .kind = .update,
                        .path = source,
                        .before = .{ .content = before },
                        .after = patched,
                    });
                    updated += 1;
                }
            },
            .add => |add| {
                const target = resolvePatchPath(arena, ctx.workspace_root, add.path, .create) catch |err| {
                    return pathFailure(ctx.allocator, add.path, err);
                };
                if (targetAlreadyPrepared(prepared.items, target)) {
                    return duplicateTarget(ctx.allocator, add.path);
                }
                if (pathExists(target) catch |err| {
                    return fileFailure(ctx.allocator, add.path, err);
                }) {
                    return .{ .failure = try std.fmt.allocPrint(
                        ctx.allocator,
                        "apply_patch failed: Add File target already exists: {s}",
                        .{add.path},
                    ) };
                }
                try prepared.append(arena, .{
                    .kind = .add,
                    .path = target,
                    .before = .absent,
                    .after = add.content,
                });
                added += 1;
            },
            .delete => |delete| {
                const target = resolvePatchPath(arena, ctx.workspace_root, delete.path, .existing) catch |err| {
                    return pathFailure(ctx.allocator, delete.path, err);
                };
                if (targetAlreadyPrepared(prepared.items, target)) {
                    return duplicateTarget(ctx.allocator, delete.path);
                }
                const before = readPatchFile(arena, target) catch |err| {
                    return fileFailure(ctx.allocator, delete.path, err);
                };
                try prepared.append(arena, .{
                    .kind = .delete,
                    .path = target,
                    .before = .{ .content = before },
                    .after = null,
                });
                deleted += 1;
            },
        }
    }

    if (prepared.items.len == 0) {
        return .{ .failure = try ctx.allocator.dupe(
            u8,
            "PATCH_NO_CHANGE: no effective additions or removals; inspect current files before retrying",
        ) };
    }

    verifyPreparedState(arena, prepared.items) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(
            ctx.allocator,
            "apply_patch aborted because workspace state changed before commit: {s}",
            .{@errorName(err)},
        ) };
    };

    var applied: usize = 0;
    while (applied < prepared.items.len) : (applied += 1) {
        if (ctx.cancel_flag) |cancel_flag| {
            if (cancel_flag.load(.seq_cst)) {
                const rollback_ok = rollbackChanges(arena, prepared.items[0..applied]);
                if (!rollback_ok) {
                    return .{ .failure = try ctx.allocator.dupe(
                        u8,
                        "apply_patch cancelled and rollback was incomplete",
                    ) };
                }
                return error.Cancelled;
            }
        }
        applyChange(arena, prepared.items[applied]) catch |err| {
            const rollback_ok = rollbackChanges(arena, prepared.items[0..applied]);
            return .{ .failure = try std.fmt.allocPrint(
                ctx.allocator,
                "apply_patch commit failed for {s}: {s}; rollback={s}",
                .{
                    displayPath(arena, ctx.workspace_root, prepared.items[applied].path),
                    @errorName(err),
                    if (rollback_ok) "complete" else "incomplete",
                },
            ) };
        };
    }

    publishUndoOperations(ctx.change_tracker, prepared.items);
    return .{ .success = try std.fmt.allocPrint(
        ctx.allocator,
        "Applied patch: {d} updated, {d} added, {d} deleted",
        .{ updated, added, deleted },
    ) };
}

fn resolvePatchPath(
    arena: Allocator,
    workspace_root: []const u8,
    input_path: []const u8,
    mode: @import("../../core/shared/types.zig").ResolveMode,
) ![]const u8 {
    return permissions.resolveFileToolPath(
        arena,
        workspace_root,
        "apply_patch",
        input_path,
        mode,
    );
}

fn readPatchFile(alloc: Allocator, absolute_path: []const u8) ![]u8 {
    const stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), absolute_path, .{});
    if (stat.kind != .file) return error.NotARegularFile;
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), absolute_path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_file_bytes);
}

fn applyHunks(
    alloc: Allocator,
    original: []const u8,
    hunks: []const Hunk,
    anchor_eof: bool,
) Allocator.Error!ContentResult {
    var current = try alloc.dupe(u8, original);
    var search_start: usize = 0;
    const use_crlf = prefersCrLf(original);

    for (hunks, 0..) |hunk, hunk_index| {
        const old_text = try patchTextForLineEndings(alloc, hunk.old_text, use_crlf);
        const new_text = try patchTextForLineEndings(alloc, hunk.new_text, use_crlf);
        if (std.mem.eql(u8, old_text, new_text)) continue;
        var matched_old_len = old_text.len;
        var replacement_text = new_text;
        const exact_matches = exactMatchEvidence(current, search_start, old_text);
        const match_start = if (exact_matches.count > 0)
            exact_matches.first_offset
        else if (eofMatchWithoutTrailingNewline(current, search_start, old_text)) |start| blk: {
            matched_old_len = current.len - start;
            replacement_text = withoutTrailingLineEnding(new_text) orelse new_text;
            break :blk start;
        } else {
            return .{ .failure = try formatMissingContext(
                alloc,
                current,
                old_text,
                hunk_index + 1,
                false,
            ) };
        };
        if (anchor_eof and hunk_index + 1 == hunks.len and
            match_start + matched_old_len != current.len)
        {
            return .{ .failure = try formatMissingContext(
                alloc,
                current,
                old_text,
                hunk_index + 1,
                true,
            ) };
        }
        if (exact_matches.count > 1) {
            return .{ .failure = try formatAmbiguousContext(
                alloc,
                current,
                hunk_index + 1,
                exact_matches,
            ) };
        }
        const new_len = std.math.add(
            usize,
            current.len - matched_old_len,
            replacement_text.len,
        ) catch {
            return .{ .failure = try alloc.dupe(u8, "apply_patch result is too large") };
        };
        if (new_len > max_file_bytes) {
            return .{ .failure = try alloc.dupe(u8, "apply_patch result exceeds the 4 MiB file limit") };
        }
        const next = try alloc.alloc(u8, new_len);
        @memcpy(next[0..match_start], current[0..match_start]);
        @memcpy(
            next[match_start .. match_start + replacement_text.len],
            replacement_text,
        );
        const suffix_start = match_start + matched_old_len;
        @memcpy(
            next[match_start + replacement_text.len ..],
            current[suffix_start..],
        );
        alloc.free(current);
        current = next;
        search_start = match_start + replacement_text.len;
    }
    return .{ .content = current };
}

fn exactMatchEvidence(content: []const u8, search_start: usize, needle: []const u8) MatchEvidence {
    if (needle.len == 0 or search_start > content.len) return .{};
    var evidence: MatchEvidence = .{};
    var cursor = search_start;
    while (cursor <= content.len) {
        const relative = std.mem.find(u8, content[cursor..], needle) orelse break;
        const offset = cursor + relative;
        evidence.count += 1;
        if (evidence.count == 1) evidence.first_offset = offset;
        if (evidence.count == 2) evidence.second_offset = offset;
        cursor = offset + 1;
    }
    return evidence;
}

fn formatMissingContext(
    alloc: Allocator,
    current: []const u8,
    old_text: []const u8,
    hunk_number: usize,
    expected_eof: bool,
) Allocator.Error![]const u8 {
    const anchor = survivingAnchor(current, old_text);
    if (anchor) |evidence| {
        var encoded = try text_utils.encodeTerminalSafe(
            alloc,
            evidence.snippet,
            max_context_snippet_bytes,
        );
        defer encoded.deinit(alloc);
        return std.fmt.allocPrint(
            alloc,
            "PATCH_CONTEXT_MISSING reason=context_missing hunk={d} matches=0 anchor_line={d} current_snippet={s}; {s}",
            .{
                hunk_number,
                evidence.line,
                encoded.bytes,
                if (expected_eof)
                    "expected end of file; re-read before another mutation"
                else
                    "re-read before another mutation",
            },
        );
    }
    return std.fmt.allocPrint(
        alloc,
        "PATCH_CONTEXT_MISSING reason=context_missing hunk={d} matches=0 anchor_line=none; {s}",
        .{
            hunk_number,
            if (expected_eof)
                "expected end of file; re-read before another mutation"
            else
                "re-read before another mutation",
        },
    );
}

fn formatAmbiguousContext(
    alloc: Allocator,
    current: []const u8,
    hunk_number: usize,
    matches: MatchEvidence,
) Allocator.Error![]const u8 {
    const first_line = lineNumberAt(current, matches.first_offset);
    const second_line = lineNumberAt(current, matches.second_offset);
    const snippet = currentLineSnippet(current, matches.first_offset) orelse "unavailable";
    var encoded = try text_utils.encodeTerminalSafe(alloc, snippet, max_context_snippet_bytes);
    defer encoded.deinit(alloc);
    return std.fmt.allocPrint(
        alloc,
        "PATCH_CONTEXT_AMBIGUOUS reason=context_ambiguous hunk={d} matches={d} candidate_lines={d},{d} current_snippet={s}; retry once with more distinctive unchanged surrounding lines",
        .{ hunk_number, matches.count, first_line, second_line, encoded.bytes },
    );
}

fn survivingAnchor(current: []const u8, old_text: []const u8) ?AnchorEvidence {
    var best_line: []const u8 = "";
    var best_offset: usize = 0;
    var lines = std.mem.splitScalar(u8, old_text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len < 4 or line.len <= best_line.len) continue;
        const offset = std.mem.find(u8, current, line) orelse continue;
        best_line = line;
        best_offset = offset;
    }
    if (best_line.len == 0) return null;
    return .{
        .line = lineNumberAt(current, best_offset),
        .snippet = currentLineSnippet(current, best_offset) orelse return null,
    };
}

fn lineNumberAt(content: []const u8, offset: usize) usize {
    return std.mem.count(u8, content[0..@min(offset, content.len)], "\n") + 1;
}

fn currentLineSnippet(content: []const u8, offset: usize) ?[]const u8 {
    if (offset > content.len) return null;
    const line_start = if (std.mem.lastIndexOfScalar(u8, content[0..offset], '\n')) |newline|
        newline + 1
    else
        0;
    const line_end = if (std.mem.findScalar(u8, content[offset..], '\n')) |relative|
        offset + relative
    else
        content.len;
    const line = std.mem.trimEnd(u8, content[line_start..line_end], "\r");
    return if (line.len == 0) null else line;
}

fn prefersCrLf(content: []const u8) bool {
    var newlines: usize = 0;
    var crlf_newlines: usize = 0;
    for (content, 0..) |byte, index| {
        if (byte != '\n') continue;
        newlines += 1;
        if (index > 0 and content[index - 1] == '\r') crlf_newlines += 1;
    }
    return newlines > 0 and newlines == crlf_newlines;
}

fn patchTextForLineEndings(
    alloc: Allocator,
    text: []const u8,
    use_crlf: bool,
) Allocator.Error![]const u8 {
    if (!use_crlf or std.mem.findScalar(u8, text, '\n') == null) return text;
    var extra: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte == '\n' and (index == 0 or text[index - 1] != '\r')) extra += 1;
    }
    if (extra == 0) return text;
    const converted = try alloc.alloc(u8, text.len + extra);
    var output_index: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte == '\n' and (index == 0 or text[index - 1] != '\r')) {
            converted[output_index] = '\r';
            output_index += 1;
        }
        converted[output_index] = byte;
        output_index += 1;
    }
    return converted;
}

fn eofMatchWithoutTrailingNewline(
    content: []const u8,
    search_start: usize,
    old_text: []const u8,
) ?usize {
    const without_newline = withoutTrailingLineEnding(old_text) orelse return null;
    if (without_newline.len == 0 or without_newline.len > content.len) return null;
    const start = content.len - without_newline.len;
    if (start < search_start or !std.mem.eql(u8, content[start..], without_newline)) return null;
    return start;
}

fn withoutTrailingLineEnding(text: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, text, "\r\n")) return text[0 .. text.len - 2];
    if (std.mem.endsWith(u8, text, "\n")) return text[0 .. text.len - 1];
    return null;
}

fn applyChange(alloc: Allocator, change: PreparedChange) !void {
    if (change.after) |content| {
        try pathing.ensureParentDirectories(change.path);
        try io_mod.writeFileAtomic(alloc, change.path, content);
        return;
    }
    try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), change.path);
}

fn verifyPreparedState(alloc: Allocator, changes: []const PreparedChange) !void {
    for (changes) |change| {
        switch (change.before) {
            .absent => if (try pathExists(change.path)) return error.PathAlreadyExists,
            .content => |expected| {
                const current = try readPatchFile(alloc, change.path);
                if (!std.mem.eql(u8, current, expected)) return error.FileChanged;
            },
        }
    }
}

fn rollbackChanges(alloc: Allocator, changes: []const PreparedChange) bool {
    var ok = true;
    var index = changes.len;
    while (index > 0) {
        index -= 1;
        const change = changes[index];
        switch (change.before) {
            .absent => std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), change.path) catch |err| {
                if (err != error.FileNotFound) ok = false;
            },
            .content => |content| {
                pathing.ensureParentDirectories(change.path) catch {
                    ok = false;
                    continue;
                };
                io_mod.writeFileAtomic(alloc, change.path, content) catch {
                    ok = false;
                };
            },
        }
    }
    return ok;
}

fn publishUndoOperations(
    maybe_tracker: ?*change_tracker.ChangeTracker,
    changes: []const PreparedChange,
) void {
    const tracker = maybe_tracker orelse return;
    const alloc = std.heap.c_allocator;
    for (changes) |change| {
        const owned_path = alloc.dupe(u8, change.path) catch continue;
        const previous_content: ?[]u8 = switch (change.before) {
            .absent => null,
            .content => |content| alloc.dupe(u8, content) catch {
                alloc.free(owned_path);
                continue;
            },
        };
        const operation = change_tracker.FileOperation{
            .kind = switch (change.kind) {
                .update => .edit,
                .add => .write,
                .delete => .edit,
            },
            .path = owned_path,
            .previous_content = previous_content,
            .timestamp_ms = io_mod.milliTimestamp(),
        };
        tracker.pushOperation(alloc, operation) catch {
            alloc.free(owned_path);
            if (previous_content) |content| alloc.free(content);
        };
    }
}

fn targetAlreadyPrepared(changes: []const PreparedChange, path: []const u8) bool {
    for (changes) |change| {
        if (std.mem.eql(u8, change.path, path)) return true;
    }
    return false;
}

fn pathExists(path: []const u8) !bool {
    _ = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{
        .follow_symlinks = false,
    }) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => false,
        else => err,
    };
    return true;
}

fn pathFailure(alloc: Allocator, path: []const u8, err: anyerror) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return .{ .failure = try std.fmt.allocPrint(
        alloc,
        "apply_patch could not resolve {s}: {s}",
        .{ path, @errorName(err) },
    ) };
}

fn fileFailure(alloc: Allocator, path: []const u8, err: anyerror) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return .{ .failure = try std.fmt.allocPrint(
        alloc,
        "apply_patch could not read {s}: {s}",
        .{ path, @errorName(err) },
    ) };
}

fn duplicateTarget(alloc: Allocator, path: []const u8) Allocator.Error!tool_dispatch.ToolResult {
    return .{ .failure = try std.fmt.allocPrint(
        alloc,
        "apply_patch targets {s} more than once; combine its hunks under one file header",
        .{path},
    ) };
}

fn displayPath(arena: Allocator, workspace_root: []const u8, absolute_path: []const u8) []const u8 {
    return pathing.workspaceRelativePath(arena, workspace_root, absolute_path) catch absolute_path;
}

fn appendPatchLine(out: *std.Io.Writer.Allocating, body: []const u8) !void {
    try out.writer.writeAll(body);
    try out.writer.writeByte('\n');
}

fn removeTrailingLineEnding(out: *std.Io.Writer.Allocating) bool {
    if (out.writer.end == 0 or out.writer.buffer[out.writer.end - 1] != '\n') return false;
    out.writer.end -= 1;
    if (out.writer.end > 0 and out.writer.buffer[out.writer.end - 1] == '\r') {
        out.writer.end -= 1;
    }
    return true;
}

fn trimMarkdownFence(patch: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, patch, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "```")) return trimmed;
    const first_line_end = std.mem.findScalar(u8, trimmed, '\n') orelse return trimmed;
    const after_open = trimmed[first_line_end + 1 ..];
    const closing = std.mem.lastIndexOf(u8, after_open, "```") orelse return trimmed;
    if (std.mem.trim(u8, after_open[closing + 3 ..], " \t\r\n").len != 0) return trimmed;
    return std.mem.trim(u8, after_open[0..closing], "\r\n");
}

fn stripCarriageReturn(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return true;
}

fn decodeInput(args_json: []const u8) !tool_dispatch.ToolInput {
    return switch (try decode(.{ .allocator = std.testing.allocator }, args_json)) {
        .input => |input| input,
        .failure => |reason| {
            defer std.testing.allocator.free(reason);
            return error.TestExpectedDecodedInput;
        },
    };
}

fn workspaceRoot(alloc: Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io_mod.getIo(), parent);
    var file = try dir.createFile(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn readTestFile(alloc: Allocator, dir: std.Io.Dir, path: []const u8) ![]u8 {
    var file = try dir.openFile(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_file_bytes);
}

test "apply_patch v3 decodes multiple files and multiple hunks" {
    const input = try decodeInput(
        \\{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n-one\n+ONE\n@@\n-three\n+THREE\n*** Add File: b.txt\n+new\n*** Delete File: c.txt\n*** End Patch"}
    );
    defer input.deinit(std.testing.allocator);
    const patch_input = input.as(Input);
    try std.testing.expectEqual(@as(usize, 3), patch_input.operations.len);
    try std.testing.expectEqual(@as(usize, 2), patch_input.operations[0].update.hunks.len);
}

test "apply_patch resolves every permission target before execution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "update.txt", "old\n");
    try writeTestFile(tmp.dir, "move.txt", "move\n");
    try writeTestFile(tmp.dir, "delete.txt", "delete\n");
    const root = try workspaceRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);

    var targets = try permissionTargets(std.testing.allocator, root,
        \\{"patch":"*** Begin Patch\n*** Update File: update.txt\n@@\n-old\n+new\n*** Update File: move.txt\n*** Move to: moved.txt\n@@\n-move\n+moved\n*** Add File: added.txt\n+added\n*** Delete File: delete.txt\n*** End Patch"}
    );
    defer targets.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), targets.items.len);
    const expected = [_]struct { role: []const u8, path: []const u8 }{
        .{ .role = "update", .path = "update.txt" },
        .{ .role = "update", .path = "move.txt" },
        .{ .role = "move_destination", .path = "moved.txt" },
        .{ .role = "add", .path = "added.txt" },
        .{ .role = "delete", .path = "delete.txt" },
    };
    for (targets.items, expected) |actual, wanted| {
        try std.testing.expectEqualStrings(wanted.role, actual.role);
        const expected_path = try std.fs.path.join(
            std.testing.allocator,
            &.{ root, wanted.path },
        );
        defer std.testing.allocator.free(expected_path);
        try std.testing.expectEqualStrings(expected_path, actual.path);
    }
}

test "apply_patch v3 applies a transactional multi-file patch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "a.txt", "one\ntwo\nthree\n");
    try writeTestFile(tmp.dir, "c.txt", "remove\n");
    const root = try workspaceRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    const input = try decodeInput(
        \\{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n-one\n+ONE\n@@\n-three\n+THREE\n*** Add File: nested/b.txt\n+new\n*** Delete File: c.txt\n*** End Patch"}
    );
    defer input.deinit(std.testing.allocator);
    var cancelled = std.atomic.Value(bool).init(false);
    const result = try call(.{
        .allocator = std.testing.allocator,
        .workspace_root = root,
        .cancel_flag = &cancelled,
    }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(result) == .success);

    const a = try readTestFile(std.testing.allocator, tmp.dir, "a.txt");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("ONE\ntwo\nTHREE\n", a);
    const b = try readTestFile(std.testing.allocator, tmp.dir, "nested/b.txt");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("new\n", b);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.openFile(io_mod.getIo(), "c.txt", .{}),
    );
}

test "apply_patch v3 validates every hunk before writing any file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "a.txt", "one\n");
    try writeTestFile(tmp.dir, "b.txt", "two\n");
    const root = try workspaceRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    const input = try decodeInput(
        \\{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n-one\n+ONE\n*** Update File: b.txt\n@@\n-missing\n+TWO\n*** End Patch"}
    );
    defer input.deinit(std.testing.allocator);
    const result = try call(.{
        .allocator = std.testing.allocator,
        .workspace_root = root,
    }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(result) == .failure);
    try std.testing.expect(std.mem.find(
        u8,
        result.failure,
        "PATCH_CONTEXT_MISSING reason=context_missing hunk=1 matches=0 anchor_line=none",
    ) != null);
    const a = try readTestFile(std.testing.allocator, tmp.dir, "a.txt");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("one\n", a);
}

test "apply_patch v3 reports a surviving exact anchor for missing context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "a.txt", "header\nkeep line\nnew value\nfooter\n");
    const root = try workspaceRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    const input = try decodeInput(
        \\{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n keep line\n-old value\n+NEW VALUE\n footer\n*** End Patch"}
    );
    defer input.deinit(std.testing.allocator);
    const result = try call(.{
        .allocator = std.testing.allocator,
        .workspace_root = root,
    }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(result) == .failure);
    try std.testing.expect(std.mem.find(
        u8,
        result.failure,
        "reason=context_missing hunk=1 matches=0 anchor_line=2 current_snippet=keep line",
    ) != null);
}

test "apply_patch v3 reports exact ambiguous match evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "a.txt", "head\nsame\nvalue\ntail\nsame\nvalue\n");
    const root = try workspaceRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    const input = try decodeInput(
        \\{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n same\n-value\n+VALUE\n*** End Patch"}
    );
    defer input.deinit(std.testing.allocator);
    const result = try call(.{
        .allocator = std.testing.allocator,
        .workspace_root = root,
    }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(result) == .failure);
    try std.testing.expect(std.mem.find(
        u8,
        result.failure,
        "reason=context_ambiguous hunk=1 matches=2 candidate_lines=2,5 current_snippet=same",
    ) != null);
}

test "apply_patch v3 supports the standard end-of-file anchor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "a.txt", "one\ntwo\n");
    const root = try workspaceRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    const input = try decodeInput(
        \\{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n-two\n+TWO\n*** End of File\n*** End Patch"}
    );
    defer input.deinit(std.testing.allocator);
    const result = try call(.{
        .allocator = std.testing.allocator,
        .workspace_root = root,
    }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(result) == .success);
    const actual = try readTestFile(std.testing.allocator, tmp.dir, "a.txt");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("one\nTWO\n", actual);
}

test "apply_patch v3 accepts CRLF patch input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "a.txt", "one\ntwo\n");
    const root = try workspaceRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    const input = try decodeInput(
        \\{"patch":"*** Begin Patch\r\n*** Update File: a.txt\r\n@@\r\n-two\r\n+TWO\r\n*** End Patch"}
    );
    defer input.deinit(std.testing.allocator);
    const result = try call(.{
        .allocator = std.testing.allocator,
        .workspace_root = root,
    }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(result) == .success);
    const actual = try readTestFile(std.testing.allocator, tmp.dir, "a.txt");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("one\nTWO\n", actual);
}

test "apply_patch v3 preserves a CRLF file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "a.txt", "one\r\ntwo\r\n");
    const root = try workspaceRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    const input = try decodeInput(
        \\{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n-two\n+TWO\n*** End Patch"}
    );
    defer input.deinit(std.testing.allocator);
    const result = try call(.{
        .allocator = std.testing.allocator,
        .workspace_root = root,
    }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(result) == .success);
    const actual = try readTestFile(std.testing.allocator, tmp.dir, "a.txt");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("one\r\nTWO\r\n", actual);
}

test "apply_patch v3 ignores context-only hunks when applying real changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "a.txt", "one\ntwo\n");
    const root = try workspaceRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    const input = try decodeInput(
        \\{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n one\n@@\n-two\n+TWO\n*** End Patch"}
    );
    defer input.deinit(std.testing.allocator);
    const result = try call(.{
        .allocator = std.testing.allocator,
        .workspace_root = root,
    }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(result) == .success);
    const actual = try readTestFile(std.testing.allocator, tmp.dir, "a.txt");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("one\nTWO\n", actual);
}

test "apply_patch v3 reports an entirely context-only patch as no change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "a.txt", "one\n");
    const root = try workspaceRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    const input = try decodeInput(
        \\{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n one\n*** End Patch"}
    );
    defer input.deinit(std.testing.allocator);
    const result = try call(.{
        .allocator = std.testing.allocator,
        .workspace_root = root,
    }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(result) == .failure);
    try std.testing.expectEqualStrings(
        "PATCH_NO_CHANGE: no effective additions or removals; inspect current files before retrying",
        result.failure,
    );
    const actual = try readTestFile(std.testing.allocator, tmp.dir, "a.txt");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("one\n", actual);
}

test "apply_patch v3 safely matches an unterminated final line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "a.txt", "one\ntwo");
    const root = try workspaceRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    const input = try decodeInput(
        \\{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n-two\n+TWO\n*** End Patch"}
    );
    defer input.deinit(std.testing.allocator);
    const result = try call(.{
        .allocator = std.testing.allocator,
        .workspace_root = root,
    }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(result) == .success);
    const actual = try readTestFile(std.testing.allocator, tmp.dir, "a.txt");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("one\nTWO", actual);
}

test "apply_patch v3 refuses workspace escapes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try workspaceRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    const input = try decodeInput(
        \\{"patch":"*** Begin Patch\n*** Add File: ../outside.txt\n+nope\n*** End Patch"}
    );
    defer input.deinit(std.testing.allocator);
    const result = try call(.{
        .allocator = std.testing.allocator,
        .workspace_root = root,
    }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(result) == .failure);
}
