//! The push of the built-in runner (spec V2, V5): the lock, the listing through the
//! indexer and the `include` walk, the diff against `manifest.json`, the tar.gz bodies
//! sent by `fs/write`, the deletion list, and the manifest, which is written only after
//! the push succeeds. Outside code imports `vercel.zig`, not this file.

const std = @import("std");
const io_mod = @import("../../shared/io.zig");
const indexer = @import("../../indexer/indexer.zig");
const config_write = @import("../config_write.zig");
const sandbox = @import("sandbox.zig");
const attempt = @import("attempt.zig");

const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// The most file bytes one push may send (N2).
pub const max_push_bytes: u64 = 512 * 1024 * 1024;
/// The file bytes one tar.gz body holds before the next body begins (V5: one per 32 MiB).
pub const max_chunk_input_bytes: u64 = 32 * 1024 * 1024;
/// The most entries one `include` walk visits (V5).
pub const max_include_entries: usize = 10_000;
/// The time one `include` walk may take, in milliseconds (V5).
pub const include_budget_ms: i64 = 5_000;

const io_buffer_bytes: usize = 64 * 1024;
pub const lock_name = "lock";
const chunk_name = "push.chunk.tmp";
const max_run_id_bytes: usize = 64;
pub const busy_detail = "another remote run in this repository did not finish its file sync within 60 s";

pub const Options = struct {
    /// Names the deletion list, `.git/fx-delete-{run_id}`. Letters, digits, `-` and `_` only.
    run_id: []const u8,
    /// Repository paths sent even when git ignores them (V5). Isolated runs pass none.
    include: []const []const u8 = &.{},
    /// The bring-back roots (V9). The list reaches the sandbox as `.git/fx-bring-back` when it changes.
    bring_back: []const []const u8 = &.{},
    lock_wait_ms: u64 = config_write.lock_wait_ms,
    push_cap_bytes: u64 = max_push_bytes,
    chunk_input_bytes: u64 = max_chunk_input_bytes,
    include_entries: usize = max_include_entries,
    include_budget_ms: i64 = include_budget_ms,
};

pub const Result = struct {
    sent_files: usize,
    deleted_files: usize,
    /// False when a listing was cut short. A short listing deletes nothing remotely (V5).
    scan_complete: bool,
    /// `include` paths that were missing or unsafe (N17).
    missing_include: []const []const u8,
    /// Whether the sandbox was set up again during this call.
    generation_reset: bool,
    /// The session the push ran in, after any recovery (V3). The exec that follows uses it (V6, V12).
    session: sandbox.Session,
    /// The size change this call made or failed to make (V3, N18). Printed once per run.
    size_note: sandbox.SizeNote,
};

/// Runs V2 (the lock, held through V3 to V5), V3 through the sandbox, and V5.
pub fn push(ctx: *sandbox.Context, options: Options) sandbox.Outcome(Result) {
    return sandbox.settle(Result, ctx, pushInner(ctx, options));
}

fn pushInner(ctx: *sandbox.Context, options: Options) sandbox.Error!Result {
    if (!validRunId(options.run_id)) return sandbox.refuse(ctx, "push", 0, "the run id is not valid");
    var lock = io_mod.acquireTimedAdvisoryLockCancellable(ctx.state_dir, lock_name, options.lock_wait_ms, ctx.cancel) catch |err| return switch (err) {
        error.LockBusy => sandbox.refuse(ctx, "lock", 0, busy_detail),
        error.Cancelled => sandbox.refuse(ctx, "lock", 0, "Cancelled"),
        else => sandbox.refuseError(ctx, "lock", err),
    };
    defer lock.release();
    removeChunk(ctx, chunk_name);
    config_write.removeStaleTemps(ctx.state_dir, sandbox.manifest_temp_prefix, @divFloor(io_mod.milliTimestamp(), 1000));
    var session = try sandbox.establish(ctx);
    return pushAttempts(ctx, options, &session);
}

/// An isolated push (I3): the lock, then every listed file into a sandbox this run created. No sync
/// record is read or written.
pub fn pushIsolated(ctx: *sandbox.Context, options: Options, session: *sandbox.Session) sandbox.Outcome(Result) {
    return sandbox.settle(Result, ctx, pushIsolatedInner(ctx, options, session));
}

/// An isolated push takes no lock: it shares no manifest, pending record or sandbox with the
/// persistent path, and its staged chunk has a name of its own (see `pushAttempt`).
fn pushIsolatedInner(ctx: *sandbox.Context, options: Options, session: *sandbox.Session) sandbox.Error!Result {
    if (!validRunId(options.run_id)) return sandbox.refuse(ctx, "push", 0, "the run id is not valid");
    return pushAttempts(ctx, options, session);
}

/// Runs the push. Each answer that is not ok goes through `attempt.plan`, which allows one repair of a
/// missing R (V5) and one recovery of an ended session (V3). An isolated push never recovers (I3).
fn pushAttempts(ctx: *sandbox.Context, options: Options, session: *sandbox.Session) sandbox.Error!Result {
    while (true) {
        switch (try pushAttempt(ctx, options, session)) {
            .done => |result| return result,
            .refused => |outcome| switch (attempt.plan(.push, ctx.mode, outcome, ctx.used)) {
                .repair => {
                    ctx.used.repaired = true;
                    switch (ctx.mode) {
                        .remote => try sandbox.repairRoot(ctx, session),
                        .isolated => try sandbox.prepareIsolatedRoot(ctx, session),
                    }
                },
                .resume_session => {
                    ctx.used.recovered = true;
                    try sandbox.recover(ctx, session);
                },
                .refuse => |reason| return refusePush(ctx, reason, outcome),
                .done => unreachable,
            },
        }
    }
}

fn refusePush(ctx: *sandbox.Context, reason: attempt.Refusal, outcome: attempt.Outcome) sandbox.Error {
    return switch (reason) {
        .folder_missing => sandbox.refuse(ctx, "push", 400, "the sandbox folder is still missing"),
        .session_ended => sandbox.refuse(ctx, "push", goneStatusOf(outcome), "the sandbox session ended"),
        .not_sent, .failed => sandbox.refuse(ctx, "push", 0, "the push was refused"),
    };
}

fn goneStatusOf(outcome: attempt.Outcome) u16 {
    return switch (outcome) {
        .gone => |status| status,
        else => 0,
    };
}

const Answer = union(enum) {
    done: Result,
    /// The push's answer was not ok. `attempt.plan` decides what happens next.
    refused: attempt.Outcome,
};

fn pushAttempt(ctx: *sandbox.Context, options: Options, session: *sandbox.Session) sandbox.Error!Answer {
    const mode = ctx.mode;
    const io = io_mod.getIo();
    var root = io_mod.openDirAbsoluteNoFollow(ctx.repo_root, .{ .iterate = true }) catch |err| return sandbox.refuseError(ctx, "scan", err);
    defer root.close(io);
    const chunk = if (mode == .isolated) try ctx.alloc.print(".fx-chunk-{s}", .{options.run_id}) else chunk_name;
    const repo: Repo = .{ .ctx = ctx, .root = root, .chunk = chunk };
    var manifest = if (mode == .isolated) sandbox.emptyManifest() else try sandbox.readManifest(ctx);
    const listing = try listTree(repo, options);
    var candidates: std.ArrayList(Candidate) = .empty;
    try planChanges(repo, &manifest, &listing, &candidates);
    const deletions = try deletionsOf(ctx.alloc, &manifest, &listing);
    const excludes = try excludesFor(ctx.alloc, &manifest, &listing);
    const roots = try rootsFor(ctx.alloc, &manifest, options.bring_back);
    const pending = if (mode == .remote) try pendingFor(ctx.alloc, &manifest, session.generation == .reset) else PendingNames{ .write = null, .hex = null };
    const pending_range = mode == .remote and (manifest.pending_back.len > 0 or mayHavePending(ctx));
    const sent: ?[]const u8 = if (pending_range and candidates.items.len > 0) try sentNames(ctx.alloc, candidates.items) else null;
    if (candidates.items.len == 0 and deletions.len == 0 and excludes.write == null and roots.write == null and pending.write == null) return .{ .done = resultOf(0, 0, &listing, session) };

    var total: u64 = 0;
    for (candidates.items) |candidate| total += candidate.node.size;
    if (total > options.push_cap_bytes) {
        const detail = try ctx.alloc.print("more than {d} bytes in one push", .{options.push_cap_bytes});
        return sandbox.refuse(ctx, "push", 0, detail);
    }

    const generation: ?[]const u8 = if (candidates.items.len > 0 and mode == .remote) try sandbox.freshGeneration(ctx) else null;
    var next = try nextFiles(ctx.alloc, &manifest, candidates.items, deletions);
    const list_changed = deletions.len > 0 or addsFiles(&manifest, candidates.items);
    var metadata = try metadataFor(ctx, options.run_id, deletions, &next, list_changed, generation, excludes.write, roots.write);
    metadata.pending_back = pending.write;
    metadata.sent = sent;
    metadata.sent_name = try ctx.alloc.print(".git/fx-sent-{s}", .{options.run_id});

    if (mode == .remote) try refuseUnreadableRecord(ctx, &manifest, next, excludes.hex, roots.hex, generation orelse manifest.generation orelse "");

    var start: usize = 0;
    while (true) {
        var end = start;
        var bytes: u64 = 0;
        while (end < candidates.items.len) : (end += 1) {
            const size = candidates.items[end].node.size;
            if (end > start and bytes + size > options.chunk_input_bytes) break;
            bytes += size;
        }
        const last = end == candidates.items.len;
        switch (try sendChunk(repo, session, candidates.items[start..end], if (last) metadata else null)) {
            .ok => {},
            else => |outcome| return .{ .refused = outcome },
        }
        if (last) break;
        start = end;
    }

    if (mode == .isolated) return .{ .done = resultOf(candidates.items.len, deletions.len, &listing, session) };
    const committed = generation orelse manifest.generation orelse return sandbox.refuse(ctx, "manifest", 0, "the manifest has no generation");
    const committed_manifest: sandbox.Manifest = .{
        .generation = committed,
        .files = next,
        .excludes = excludes.hex,
        .pending_back = manifest.pending_back,
        .brought = manifest.brought,
        .skipped = manifest.skipped,
        .bring_back_roots = roots.hex,
        .pending_sha = pending.hex,
    };
    try sandbox.commitManifest(ctx, &committed_manifest);
    return .{ .done = resultOf(candidates.items.len, deletions.len, &listing, session) };
}

/// V5: a sync record the reader would not accept is refused before anything is sent (N2), so
/// the runner never writes a record it cannot read back.
fn refuseUnreadableRecord(ctx: *sandbox.Context, manifest: *const sandbox.Manifest, files: sandbox.FileMap, excludes: ?[]const u8, roots: ?[]const u8, generation: []const u8) sandbox.Error!void {
    const record: sandbox.Manifest = .{
        .generation = generation,
        .files = files,
        .excludes = excludes,
        .pending_back = manifest.pending_back,
        .brought = manifest.brought,
        .skipped = manifest.skipped,
        .bring_back_roots = roots,
    };
    const detail = (try sandbox.sizeRefusal(ctx.alloc, &record)) orelse return;
    return sandbox.refuse(ctx, "push", 0, detail);
}

fn resultOf(sent: usize, deleted: usize, listing: *const Listing, session: *const sandbox.Session) Result {
    return .{
        .sent_files = sent,
        .deleted_files = deleted,
        .scan_complete = listing.complete,
        .missing_include = listing.missing,
        .generation_reset = session.generation == .reset,
        .session = session.*,
        .size_note = session.size_note,
    };
}

const Repo = struct {
    ctx: *sandbox.Context,
    root: std.Io.Dir,
    /// The staged chunk's name in the state folder: one per push, so two pushes never share it.
    chunk: []const u8 = chunk_name,
};

const Node = struct {
    link: bool,
    size: u64,
    mtime_ns: i64,
    mode: u32,
};

const NodeMap = std.array_hash_map.String(Node);

const Listing = struct {
    nodes: NodeMap,
    missing: []const []const u8,
    complete: bool,
    /// The ignore sources outside the tree, read as data (V5).
    excludes: indexer.IgnoreFiles,
};

const Candidate = struct {
    rel: []const u8,
    node: Node,
    sha256: []const u8,
    /// The link target of a symbolic link; empty for a file.
    target: []const u8,
};

const Digest = struct {
    sha256: []const u8,
    target: []const u8,
};

/// The listing: the indexer's files (git's ignore rules read as data), then the `include`
/// paths. A short listing is marked incomplete, and an incomplete one deletes nothing.
fn listTree(repo: Repo, options: Options) sandbox.Error!Listing {
    const ctx = repo.ctx;
    var scanned = indexer.scan(ctx.alloc, ctx.repo_root, .{}, ctx.cancel) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => sandbox.refuse(ctx, "scan", 0, "Cancelled"),
        error.RootUnavailable => sandbox.refuse(ctx, "scan", 0, "the repository folder is unavailable"),
    };
    defer scanned.deinit();
    var listing: Listing = .{
        .nodes = .empty,
        .missing = &.{},
        .complete = !(scanned.tree.incomplete or scanned.tree.cap_reached),
        .excludes = try indexer.ignoreFiles(ctx.alloc, ctx.repo_root),
    };
    listing.complete = listing.complete and !listing.excludes.unavailable;
    for (scanned.tree.entries) |entry| {
        if (entry.kind != .file) continue;
        try addPath(repo, &listing.nodes, entry.path);
    }
    var missing: std.ArrayList([]const u8) = .empty;
    var walk: Walk = .{
        .started_ms = io_mod.milliTimestamp(),
        .budget_ms = options.include_budget_ms,
        .limit = options.include_entries,
    };
    for (options.include) |path| try addInclude(repo, &listing.nodes, &missing, &walk, path);
    listing.missing = try missing.toOwnedSlice(ctx.alloc);
    listing.complete = listing.complete and !walk.incomplete;
    return listing;
}

/// A file the indexer listed. It was read as a folder entry, so it is re-read without following links.
fn addPath(repo: Repo, nodes: *NodeMap, rel: []const u8) sandbox.Error!void {
    if (!safeRelative(rel)) return sandbox.refuse(repo.ctx, "scan", 0, "a listed path is not a safe relative path");
    const stat = statNoFollow(repo.root, rel) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return pathFailure(repo.ctx, "scan", err),
    };
    switch (stat.kind) {
        .file, .sym_link => {},
        else => return,
    }
    try addNode(repo, nodes, rel, stat);
}

fn addNode(repo: Repo, nodes: *NodeMap, rel: []const u8, stat: std.Io.File.Stat) sandbox.Error!void {
    const ctx = repo.ctx;
    try nodes.put(ctx.alloc, try ctx.alloc.dupe(u8, rel), .{
        .link = stat.kind == .sym_link,
        .size = stat.size,
        .mtime_ns = mtimeNs(stat),
        .mode = stat.permissions.toMode() & 0o7777,
    });
}

/// One `include` path (V5). A missing or unsafe path is reported (N17). A folder is walked
/// without following links, skipping nested `.git` folders, within the entry and time limits.
fn addInclude(repo: Repo, nodes: *NodeMap, missing: *std.ArrayList([]const u8), walk: *Walk, path: []const u8) sandbox.Error!void {
    const ctx = repo.ctx;
    if (!safeRelative(path)) return markMissing(ctx, missing, path);
    const stat = statNoFollow(repo.root, path) catch |err| switch (err) {
        error.FileNotFound, error.Unsafe => return markMissing(ctx, missing, path),
        else => return pathFailure(ctx, "include", err),
    };
    switch (stat.kind) {
        .file, .sym_link => try addNode(repo, nodes, path, stat),
        .directory => {
            var dir = openDirNoFollow(repo.root, path) catch |err| switch (err) {
                error.FileNotFound, error.Unsafe => return markMissing(ctx, missing, path),
                else => return pathFailure(ctx, "include", err),
            };
            defer dir.close(io_mod.getIo());
            try walkDir(repo, nodes, dir, path, walk);
        },
        else => return markMissing(ctx, missing, path),
    }
}

fn markMissing(ctx: *sandbox.Context, missing: *std.ArrayList([]const u8), path: []const u8) sandbox.Error!void {
    try missing.append(ctx.alloc, try ctx.alloc.dupe(u8, path));
}

fn walkDir(repo: Repo, nodes: *NodeMap, dir: std.Io.Dir, prefix: []const u8, walk: *Walk) sandbox.Error!void {
    const ctx = repo.ctx;
    const io = io_mod.getIo();
    var iterator = dir.iterate();
    while (true) {
        const entry = (iterator.next(io) catch |err| return sandbox.refuseError(ctx, "include", err)) orelse break;
        if (walk.exhausted()) return;
        walk.visited += 1;
        const rel = try ctx.alloc.print("{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => {
                if (std.mem.eql(u8, entry.name, ".git")) continue;
                var child = dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch |err| return sandbox.refuseError(ctx, "include", err);
                defer child.close(io);
                try walkDir(repo, nodes, child, rel, walk);
            },
            .file, .sym_link => {
                const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| return sandbox.refuseError(ctx, "include", err);
                try addNode(repo, nodes, rel, stat);
            },
            else => {},
        }
    }
}

/// The entry and time limits of the `include` walks, shared by every path in one push.
const Walk = struct {
    started_ms: i64,
    budget_ms: i64,
    limit: usize,
    visited: usize = 0,
    incomplete: bool = false,

    fn exhausted(self: *Walk) bool {
        if (self.visited < self.limit and io_mod.milliTimestamp() - self.started_ms <= self.budget_ms) return false;
        self.incomplete = true;
        return true;
    }
};

/// The listing against `manifest.json` (V5). A file goes in when its size or mtime differs,
/// and then only when its SHA-256 differs too.
fn planChanges(repo: Repo, manifest: *const sandbox.Manifest, listing: *const Listing, candidates: *std.ArrayList(Candidate)) sandbox.Error!void {
    var entries = listing.nodes.iterator();
    while (entries.next()) |entry| {
        const rel = entry.key_ptr.*;
        const node = entry.value_ptr.*;
        const record = manifest.files.get(rel);
        if (record) |found| {
            if (found.size == node.size and found.mtime_ns == node.mtime_ns) continue;
        }
        const digest = try digestOf(repo, rel, node);
        if (record) |found| {
            if (std.mem.eql(u8, found.sha256, digest.sha256)) continue;
        }
        try candidates.append(repo.ctx.alloc, .{ .rel = rel, .node = node, .sha256 = digest.sha256, .target = digest.target });
    }
}

fn digestOf(repo: Repo, rel: []const u8, node: Node) sandbox.Error!Digest {
    const ctx = repo.ctx;
    if (node.link) {
        const target = readLinkNoFollow(ctx.alloc, repo.root, rel) catch |err| return pathFailure(ctx, "push", err);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(target, &digest, .{});
        return .{ .sha256 = try hexOf(ctx.alloc, digest), .target = target };
    }
    return .{ .sha256 = try hashFile(repo, rel), .target = "" };
}

fn hashFile(repo: Repo, rel: []const u8) sandbox.Error![]const u8 {
    const ctx = repo.ctx;
    const io = io_mod.getIo();
    var file = openNoFollow(repo.root, rel) catch |err| return pathFailure(ctx, "push", err);
    defer file.close(io);
    var buffer: [io_buffer_bytes]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [io_buffer_bytes]u8 = undefined;
    while (true) {
        const count = reader.interface.readSliceShort(&chunk) catch |err| return sandbox.refuseError(ctx, "push", err);
        if (count == 0) break;
        hasher.update(chunk[0..count]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return hexOf(ctx.alloc, digest);
}

fn deletionsOf(alloc: Allocator, manifest: *const sandbox.Manifest, listing: *const Listing) Allocator.Error![]const []const u8 {
    if (!listing.complete) return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    var entries = manifest.files.iterator();
    while (entries.next()) |entry| {
        if (!listing.nodes.contains(entry.key_ptr.*)) try list.append(alloc, entry.key_ptr.*);
    }
    return list.toOwnedSlice(alloc);
}

fn addsFiles(manifest: *const sandbox.Manifest, candidates: []const Candidate) bool {
    for (candidates) |candidate| {
        if (!manifest.files.contains(candidate.rel)) return true;
    }
    return false;
}

/// The manifest as it will be once this push succeeds.
fn nextFiles(alloc: Allocator, manifest: *const sandbox.Manifest, candidates: []const Candidate, deletions: []const []const u8) Allocator.Error!sandbox.FileMap {
    var next: sandbox.FileMap = .empty;
    var entries = manifest.files.iterator();
    while (entries.next()) |entry| try next.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    for (deletions) |rel| _ = next.swapRemove(rel);
    for (candidates) |candidate| {
        try next.put(alloc, candidate.rel, .{
            .size = candidate.node.size,
            .mtime_ns = candidate.node.mtime_ns,
            .sha256 = candidate.sha256,
        });
    }
    return next;
}

/// What the last body of a push carries besides files (V5). The lists are NUL-terminated.
const Metadata = struct {
    delete_name: []const u8,
    deletions: []const u8,
    /// The manifest's paths after the push, when that list changed; otherwise null.
    pushed: ?[]const u8,
    /// The new marker, when files were sent.
    generation: ?[]const u8,
    /// The ignore rules for `R/.git/info/exclude`, when they changed; otherwise null.
    excludes: ?[]const u8,
    /// The bring-back roots for `.git/fx-bring-back`, when they changed; otherwise null (V9).
    bring_back_roots: ?[]const u8 = null,
    /// The pending names for `.git/fx-pending-back`, when they changed; otherwise null (V9).
    pending_back: ?[]const u8 = null,
    /// The paths this push sent, written as `sent_name` when a pending range exists (V9).
    sent: ?[]const u8 = null,
    sent_name: []const u8 = "",
    now_s: u64,
};

/// The pending names the sandbox should hold (V9), NUL-terminated, and the hash to keep once they
/// are written. `write` is set when they differ from the stored hash, or when the session was set up
/// again, so a list left in the sandbox by an earlier generation is never used.
const PendingNames = struct {
    write: ?[]const u8,
    hex: ?[]const u8,
};

fn pendingFor(alloc: Allocator, manifest: *const sandbox.Manifest, forced: bool) Allocator.Error!PendingNames {
    const bytes = try nulTerminated(alloc, manifest.pending_back);
    const hex = try sha256Hex(alloc, bytes);
    const stored = manifest.pending_sha orelse try sha256Hex(alloc, "");
    if (!forced and std.mem.eql(u8, stored, hex)) return .{ .write = null, .hex = hex };
    return .{ .write = bytes, .hex = hex };
}

/// Whether the sandbox may hold pending runs (V9). A pending folder that cannot be read counts as
/// present: the sent list is then written, which costs bytes and never drops a file wrongly.
fn mayHavePending(ctx: *sandbox.Context) bool {
    const found = sandbox.readPending(ctx.alloc, ctx) catch return true;
    return found.len > 0;
}

/// The paths this push sent, NUL-terminated, for `.git/fx-sent-{run_id}` (V9). The script drops them
/// from the pending range, because the sandbox now holds the Mac's version of each of them.
fn sentNames(alloc: Allocator, candidates: []const Candidate) Allocator.Error![]const u8 {
    const rels = try alloc.alloc([]const u8, candidates.len);
    for (candidates, rels) |candidate, *rel| rel.* = candidate.rel;
    return nulTerminated(alloc, rels);
}

fn metadataFor(ctx: *sandbox.Context, run_id: []const u8, deletions: []const []const u8, next: *const sandbox.FileMap, list_changed: bool, generation: ?[]const u8, excludes: ?[]const u8, roots: ?[]const u8) Allocator.Error!Metadata {
    return .{
        .delete_name = try ctx.alloc.print(".git/fx-delete-{s}", .{run_id}),
        .deletions = if (deletions.len > 0) try nulTerminated(ctx.alloc, deletions) else "",
        .pushed = if (list_changed) try nulTerminatedKeys(ctx.alloc, next) else null,
        .generation = generation,
        .excludes = excludes,
        .bring_back_roots = roots,
        .now_s = nowSeconds(),
    };
}

/// The bring-back roots the sandbox should hold (V9), as NUL-terminated paths, and the hash to
/// keep once they are written. `write` is set only when they differ from the stored hash.
const Roots = struct {
    write: ?[]const u8,
    hex: ?[]const u8,
};

fn rootsFor(alloc: Allocator, manifest: *const sandbox.Manifest, roots: []const []const u8) Allocator.Error!Roots {
    const bytes = try nulTerminated(alloc, roots);
    const hex = try sha256Hex(alloc, bytes);
    const stored = manifest.bring_back_roots orelse try sha256Hex(alloc, "");
    if (std.mem.eql(u8, stored, hex)) return .{ .write = null, .hex = hex };
    return .{ .write = bytes, .hex = hex };
}

/// The size and mtime of each file under the bring-back roots, read at run start (V9). The walk is
/// the `include` walk, with its entry and time limits, so a large root is cut short, not read whole.
/// A cut walk leaves files out of the baseline, and a file out of it counts as changed.
pub fn bringBackBaseline(ctx: *sandbox.Context, roots: []const []const u8) sandbox.Error![]const sandbox.BringBackFile {
    if (roots.len == 0) return &.{};
    const io = io_mod.getIo();
    var root = io_mod.openDirAbsoluteNoFollow(ctx.repo_root, .{ .iterate = true }) catch |err| return sandbox.refuseError(ctx, "scan", err);
    defer root.close(io);
    const repo: Repo = .{ .ctx = ctx, .root = root };
    var nodes: NodeMap = .empty;
    var missing: std.ArrayList([]const u8) = .empty;
    var walk: Walk = .{ .started_ms = io_mod.milliTimestamp(), .budget_ms = include_budget_ms, .limit = max_include_entries };
    for (roots) |path| try addInclude(repo, &nodes, &missing, &walk, path);
    var files: std.ArrayList(sandbox.BringBackFile) = .empty;
    var entries = nodes.iterator();
    while (entries.next()) |entry| {
        try files.append(ctx.alloc, .{ .rel = entry.key_ptr.*, .size = entry.value_ptr.size, .mtime_ns = entry.value_ptr.mtime_ns });
    }
    return files.toOwnedSlice(ctx.alloc);
}

/// The ignore rules the sandbox should hold (V5), and the hash to keep once they are written.
/// `write` is set only when they differ from the hash the manifest holds. When a source
/// could not be read, nothing is written and the stored hash stays.
const Excludes = struct {
    write: ?[]const u8,
    hex: ?[]const u8,
};

fn excludesFor(alloc: Allocator, manifest: *const sandbox.Manifest, listing: *const Listing) Allocator.Error!Excludes {
    if (listing.excludes.unavailable) return .{ .write = null, .hex = manifest.excludes };
    const bytes = try combinedExcludes(alloc, listing.excludes);
    const hex = try sha256Hex(alloc, bytes);
    const stored = manifest.excludes orelse try sha256Hex(alloc, "");
    if (std.mem.eql(u8, stored, hex)) return .{ .write = null, .hex = hex };
    return .{ .write = bytes, .hex = hex };
}

/// The excludes file, then the repository's `info/exclude`, each ended by a newline, so git's
/// later source wins as it does on the Mac.
fn combinedExcludes(alloc: Allocator, ignores: indexer.IgnoreFiles) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    for ([_]?[]const u8{ ignores.excludes_file, ignores.info_exclude }) |part| {
        const text = part orelse continue;
        out.writer.writeAll(text) catch return error.OutOfMemory;
        if (text.len > 0 and text[text.len - 1] != '\n') out.writer.writeByte('\n') catch return error.OutOfMemory;
    }
    return out.written();
}

fn sha256Hex(alloc: Allocator, bytes: []const u8) Allocator.Error![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return hexOf(alloc, digest);
}

fn nulTerminated(alloc: Allocator, paths: []const []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    for (paths) |path| {
        out.writer.writeAll(path) catch return error.OutOfMemory;
        out.writer.writeByte(0) catch return error.OutOfMemory;
    }
    return out.written();
}

fn nulTerminatedKeys(alloc: Allocator, files: *const sandbox.FileMap) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    var entries = files.iterator();
    while (entries.next()) |entry| {
        out.writer.writeAll(entry.key_ptr.*) catch return error.OutOfMemory;
        out.writer.writeByte(0) catch return error.OutOfMemory;
    }
    return out.written();
}

/// Sends one tar.gz body (V5). It is built into a temporary file in the state folder, so its
/// length is known and memory stays bounded. The answer is ok, R missing, or a 404 or 410.
fn sendChunk(repo: Repo, session: *sandbox.Session, batch: []const Candidate, metadata: ?Metadata) sandbox.Error!attempt.Outcome {
    const ctx = repo.ctx;
    const io = io_mod.getIo();
    var file = openChunk(ctx, repo.chunk) catch |err| return sandbox.refuseError(ctx, "push", err);
    defer file.close(io);
    defer removeChunk(ctx, repo.chunk);
    writeChunk(repo, file, batch, metadata) catch |err| return sandbox.refuseError(ctx, "push", err);
    const length = (file.stat(io) catch |err| return sandbox.refuseError(ctx, "push", err)).size;
    var buffer: [io_buffer_bytes]u8 = undefined;
    var reader = file.reader(io, &buffer);
    reader.seekTo(0) catch |err| return sandbox.refuseError(ctx, "push", err);
    const response = try sandbox.writeArchive(ctx, session, length, &reader.interface);
    if (response.status >= 200 and response.status < 300) return .ok;
    if (sandbox.cannotOpen(ctx.alloc, response)) return .cannot_open;
    switch (attempt.statusOutcome(response.status)) {
        .gone => |status| {
            sandbox.markGone(ctx);
            return .{ .gone = status };
        },
        else => return sandbox.refuseStatus(ctx, "push", response),
    }
}

/// The staged chunk is a private file in S, created only under the V2 lock, so `exclusive` holds.
fn openChunk(ctx: *sandbox.Context, name: []const u8) anyerror!std.Io.File {
    return ctx.state_dir.dir.createFile(io_mod.getIo(), name, .{
        .read = true,
        .exclusive = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
}

/// The temporary chunk is always removed. A missing one is the normal case, so the error is ignored.
fn removeChunk(ctx: *sandbox.Context, name: []const u8) void {
    // A chunk that stays is removed by the next push before any request (V5), so the error is not kept.
    ctx.state_dir.dir.deleteFile(io_mod.getIo(), name) catch {};
}

fn writeChunk(repo: Repo, file: std.Io.File, batch: []const Candidate, metadata: ?Metadata) anyerror!void {
    const io = io_mod.getIo();
    var out_buffer: [io_buffer_bytes]u8 = undefined;
    var out = file.writer(io, &out_buffer);
    var window: [flate.max_window_len]u8 = undefined;
    var compressor = try flate.Compress.init(&out.interface, &window, .gzip, flate.Compress.Options.default);
    var tar: std.tar.Writer = .{ .underlying_writer = &compressor.writer };
    for (batch) |candidate| try writeCandidate(repo, &tar, candidate);
    if (metadata) |found| try writeMetadata(&tar, found);
    try tar.finishPedantically();
    try compressor.finish();
    try out.interface.flush();
}

fn writeCandidate(repo: Repo, tar: *std.tar.Writer, candidate: Candidate) anyerror!void {
    if (repo.ctx.cancel.load(.seq_cst)) return error.Canceled;
    const options: std.tar.Writer.Options = .{
        .mode = candidate.node.mode,
        .mtime = secondsOf(candidate.node.mtime_ns),
    };
    if (candidate.node.link) return tar.writeLink(candidate.rel, candidate.target, options);
    const io = io_mod.getIo();
    var file = try openNoFollow(repo.root, candidate.rel);
    defer file.close(io);
    var buffer: [io_buffer_bytes]u8 = undefined;
    var reader = file.reader(io, &buffer);
    try tar.writeFileStream(candidate.rel, candidate.node.size, &reader.interface, options);
}

fn writeMetadata(tar: *std.tar.Writer, metadata: Metadata) anyerror!void {
    const options: std.tar.Writer.Options = .{ .mode = 0o644, .mtime = metadata.now_s };
    if (metadata.deletions.len > 0) try tar.writeFileBytes(metadata.delete_name, metadata.deletions, options);
    if (metadata.pushed) |pushed| try tar.writeFileBytes(".git/fx-pushed", pushed, options);
    if (metadata.generation) |generation| try tar.writeFileBytes(".git/fx-generation", generation, options);
    if (metadata.excludes) |excludes| try tar.writeFileBytes(".git/info/exclude", excludes, options);
    if (metadata.bring_back_roots) |roots| try tar.writeFileBytes(".git/fx-bring-back", roots, options);
    if (metadata.pending_back) |names| try tar.writeFileBytes(".git/fx-pending-back", names, options);
    if (metadata.sent) |sent| try tar.writeFileBytes(metadata.sent_name, sent, options);
}

/// A path under the repository root, opened or stat-ed without following any link on the way.
const Parent = struct {
    dir: std.Io.Dir,
    owned: bool,
    base: []const u8,
};

/// Opens the folder that holds `rel`, one component at a time. A symbolic link on the way is
/// `error.Unsafe`, and a missing folder is `error.FileNotFound`.
fn openParent(root: std.Io.Dir, rel: []const u8) anyerror!Parent {
    const io = io_mod.getIo();
    const slash = std.mem.findScalarLast(u8, rel, '/') orelse return .{ .dir = root, .owned = false, .base = rel };
    var dir = root;
    var owned = false;
    var parts = std.mem.splitScalar(u8, rel[0..slash], '/');
    while (parts.next()) |part| {
        const next = dir.openDir(io, part, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
            if (owned) dir.close(io);
            return if (err == error.FileNotFound) error.FileNotFound else error.Unsafe;
        };
        if (owned) dir.close(io);
        dir = next;
        owned = true;
    }
    return .{ .dir = dir, .owned = owned, .base = rel[slash + 1 ..] };
}

fn statNoFollow(root: std.Io.Dir, rel: []const u8) anyerror!std.Io.File.Stat {
    const io = io_mod.getIo();
    const parent = try openParent(root, rel);
    defer if (parent.owned) parent.dir.close(io);
    return parent.dir.statFile(io, parent.base, .{ .follow_symlinks = false });
}

fn openNoFollow(root: std.Io.Dir, rel: []const u8) anyerror!std.Io.File {
    const io = io_mod.getIo();
    const parent = try openParent(root, rel);
    defer if (parent.owned) parent.dir.close(io);
    return io_mod.openExistingReadOnlyRegularFile(parent.dir, parent.base, .no_follow);
}

fn openDirNoFollow(root: std.Io.Dir, rel: []const u8) anyerror!std.Io.Dir {
    const io = io_mod.getIo();
    const parent = try openParent(root, rel);
    defer if (parent.owned) parent.dir.close(io);
    return parent.dir.openDir(io, parent.base, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
        return if (err == error.FileNotFound) error.FileNotFound else error.Unsafe;
    };
}

fn readLinkNoFollow(alloc: Allocator, root: std.Io.Dir, rel: []const u8) anyerror![]u8 {
    const io = io_mod.getIo();
    const parent = try openParent(root, rel);
    defer if (parent.owned) parent.dir.close(io);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try parent.dir.readLink(io, parent.base, &buffer);
    return alloc.dupe(u8, buffer[0..length]);
}

/// A failure while reading a path, named for the user. A path that crosses a link is said so.
fn pathFailure(ctx: *sandbox.Context, step: []const u8, err: anyerror) sandbox.Error {
    if (err == error.Unsafe) return sandbox.refuse(ctx, step, 0, "a path crosses a symbolic link");
    return sandbox.refuseError(ctx, step, err);
}

/// A path that stays inside the root: relative, no empty, `.` or `..` part, no NUL byte.
fn safeRelative(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return false;
    if (std.mem.findScalar(u8, path, 0) != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn validRunId(run_id: []const u8) bool {
    if (run_id.len == 0 or run_id.len > max_run_id_bytes) return false;
    for (run_id) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

fn hexOf(alloc: Allocator, digest: [32]u8) Allocator.Error![]const u8 {
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, &hex);
}

pub fn mtimeNs(stat: std.Io.File.Stat) i64 {
    return std.math.cast(i64, stat.mtime.nanoseconds) orelse 0;
}

/// The whole seconds of a time in nanoseconds, never negative (tar stores seconds).
fn secondsOf(ns: i64) u64 {
    return @intCast(@divFloor(@max(ns, 0), std.time.ns_per_s));
}

fn nowSeconds() u64 {
    return @intCast(@max(@divFloor(io_mod.milliTimestamp(), 1000), 0));
}

const testing = std.testing;
const credentials = @import("credentials.zig");
const transport = @import("transport.zig");
const test_server = @import("test_server.zig");

const test_token = "fx-test-token";
const repo_name = "repo";
const old_generation = "old-generation";
const fresh_generation = "fresh-generation";
const seed_sandbox =
    "{\"name\":\"fx-test\",\"session_id\":\"sess_1\",\"expires_at_ms\":9999999999999,\"vcpus\":4,\"vcpus_requested\":null}";
const write_ok = "{}";
const user_out = "{\"stream\":\"stdout\",\"data\":\"fx\\n\"}\n{\"command\":{\"id\":\"cmd_1\",\"exitCode\":0}}\n";
const exit_zero = "{\"command\":{\"id\":\"cmd_2\",\"exitCode\":0}}\n";
const cannot_open_body = "{\"error\":{\"code\":\"bad_request\",\"message\":\"The submitted tarball could not be extracted\",\"stderr\":\"tar: /x: Cannot open: No such file or directory\\n\"}}";

fn baseFor(buffer: []u8, port: u16) !transport.BaseUrl {
    return transport.resolveBaseUrl(try std.mem.print(buffer, "http://127.0.0.1:{d}", .{port}));
}

fn contextFor(
    arena: Allocator,
    cancel: *std.atomic.Value(bool),
    base: transport.BaseUrl,
    capture: *credentials.CaptureTrace,
    state_dir: *io_mod.VerifiedDir,
    repo_root: []const u8,
) sandbox.Context {
    return .{
        .alloc = arena,
        .cancel = cancel,
        .base = base,
        .token = .{ .value = test_token },
        .trace = capture.trace(),
        .team_id = "team_fake",
        .project_id = "prj_fake",
        .name = "fx-test",
        .repo_root = repo_root,
        .state_dir = state_dir,
        .generation_override = fresh_generation,
    };
}

fn seedSandbox(state_dir: *io_mod.VerifiedDir) !void {
    try io_mod.durableReplaceVerified(testing.allocator, state_dir, "sandbox.json", seed_sandbox);
}

/// A manifest with the given generation and (path, content) files, each recorded as the content was.
fn seedManifest(arena: Allocator, state_dir: *io_mod.VerifiedDir, generation: []const u8, files: []const [2][]const u8) !void {
    var map: sandbox.FileMap = .empty;
    for (files) |pair| {
        try map.put(arena, pair[0], .{ .size = pair[1].len, .mtime_ns = 0, .sha256 = try shaHex(arena, pair[1]) });
    }
    const seeded: sandbox.Manifest = .{
        .generation = generation,
        .files = map,
        .excludes = null,
        .pending_back = &.{},
        .brought = .empty,
        .skipped = &.{},
        .bring_back_roots = null,
    };
    const bytes = try sandbox.encodeManifest(arena, &seeded);
    try io_mod.durableReplaceVerified(arena, state_dir, "manifest.json", bytes);
}

fn shaHex(arena: Allocator, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return hexOf(arena, digest);
}

fn writeRepoFile(tmp: *testing.TmpDir, name: []const u8, data: []const u8) !void {
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = name, .data = data });
}

/// A complete git folder for the repository (its HEAD, objects and refs), so the indexer
/// finds this repository and not an outer one. `exclude` is `info/exclude`.
fn makeGitDir(tmp: *testing.TmpDir, exclude: []const u8) !void {
    const io = io_mod.getIo();
    try tmp.dir.createDirPath(io, "repo/.git/info");
    try tmp.dir.createDirPath(io, "repo/.git/objects");
    try tmp.dir.createDirPath(io, "repo/.git/refs");
    try writeRepoFile(tmp, "repo/.git/HEAD", "ref: refs/heads/main\n");
    try writeRepoFile(tmp, "repo/.git/info/exclude", exclude);
}

/// One entry of a tar.gz body the test server kept.
const Entry = struct {
    name: []const u8,
    kind: std.tar.FileKind,
    link: []const u8,
    content: []const u8,
};

fn archiveEntries(arena: Allocator, gz: []const u8) ![]Entry {
    var input = std.Io.Reader.fixed(gz);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress = flate.Decompress.init(&input, .gzip, &window);
    var name_buffer: [1024]u8 = undefined;
    var link_buffer: [1024]u8 = undefined;
    var iterator = std.tar.Iterator.init(&decompress.reader, .{ .file_name_buffer = &name_buffer, .link_name_buffer = &link_buffer });
    var list: std.ArrayList(Entry) = .empty;
    while (try iterator.next()) |file| {
        const content = if (file.kind == .file) try readContent(arena, &iterator, file) else "";
        try list.append(arena, .{
            .name = try arena.dupe(u8, file.name),
            .kind = file.kind,
            .link = try arena.dupe(u8, file.link_name),
            .content = content,
        });
    }
    return list.toOwnedSlice(arena);
}

fn readContent(arena: Allocator, iterator: *std.tar.Iterator, file: std.tar.Iterator.File) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try iterator.streamRemaining(file, &out.writer);
    return out.written();
}

fn findEntry(entries: []const Entry, name: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn expectPushed(outcome: sandbox.Outcome(Result)) !Result {
    return switch (outcome) {
        .ok => |result| result,
        .failed => error.UnexpectedFailure,
    };
}

fn expectFailed(outcome: sandbox.Outcome(Result)) !sandbox.Failure {
    return switch (outcome) {
        .ok => error.UnexpectedSuccess,
        .failed => |failure| failure,
    };
}

test "a new file is sent in a tar.gz, and the manifest records it only after the push succeeds (V5)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), repo_name);
    try writeRepoFile(&tmp, "repo/a.txt", "hello");
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    try seedManifest(arena, &state_dir, old_generation, &.{});
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{.{ .body = write_ok }}, .keep_body = true };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    const result = try expectPushed(push(&ctx, .{ .run_id = "run1" }));
    try testing.expectEqual(@as(usize, 1), result.sent_files);
    try testing.expect(result.scan_complete);
    server.close();
    try testing.expectEqual(@as(usize, 1), server.servedCount());
    try testing.expect(std.mem.find(u8, server.head(0), "POST /v2/sandboxes/sessions/sess_1/fs/write?teamId=team_fake HTTP/1.1") != null);
    try testing.expect(std.mem.find(u8, server.head(0), "x-cwd: ") != null);
    try testing.expect(std.ascii.findIgnoreCase(server.head(0), "content-type: application/gzip") != null);
    try testing.expect(std.ascii.findIgnoreCase(server.head(0), "content-length: ") != null);
    const entries = try archiveEntries(arena, server.kept[0..server.kept_len]);
    try testing.expectEqualStrings("hello", findEntry(entries, "a.txt").?.content);
    try testing.expectEqualStrings("a.txt\x00", findEntry(entries, ".git/fx-pushed").?.content);
    try testing.expectEqualStrings(fresh_generation, findEntry(entries, ".git/fx-generation").?.content);
    const manifest = try sandbox.readManifest(&ctx);
    try testing.expectEqualStrings(fresh_generation, manifest.generation.?);
    try testing.expectEqual(@as(u64, 5), manifest.files.get("a.txt").?.size);
}

test "a changed file is sent, and a file whose mtime changed but whose SHA-256 did not is not (V5)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), repo_name);
    try writeRepoFile(&tmp, "repo/a.txt", "new!");
    try writeRepoFile(&tmp, "repo/b.txt", "same");
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    try seedManifest(arena, &state_dir, old_generation, &.{ .{ "a.txt", "old" }, .{ "b.txt", "same" } });
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{.{ .body = write_ok }}, .keep_body = true };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    const result = try expectPushed(push(&ctx, .{ .run_id = "run1" }));
    try testing.expectEqual(@as(usize, 1), result.sent_files);
    server.close();
    const entries = try archiveEntries(arena, server.kept[0..server.kept_len]);
    try testing.expectEqualStrings("new!", findEntry(entries, "a.txt").?.content);
    try testing.expect(findEntry(entries, "b.txt") == null);
    try testing.expect(findEntry(entries, ".git/fx-pushed") == null);
}

test "a deleted file travels in a NUL-separated delete list, and leaves the manifest (V5)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), repo_name);
    try writeRepoFile(&tmp, "repo/a.txt", "hello");
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    try seedManifest(arena, &state_dir, old_generation, &.{.{ "gone.txt", "bye" }});
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{.{ .body = write_ok }}, .keep_body = true };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    const result = try expectPushed(push(&ctx, .{ .run_id = "run1" }));
    try testing.expectEqual(@as(usize, 1), result.deleted_files);
    server.close();
    const entries = try archiveEntries(arena, server.kept[0..server.kept_len]);
    try testing.expectEqualStrings("gone.txt\x00", findEntry(entries, ".git/fx-delete-run1").?.content);
    try testing.expectEqualStrings("a.txt\x00", findEntry(entries, ".git/fx-pushed").?.content);
    const manifest = try sandbox.readManifest(&ctx);
    try testing.expect(manifest.files.get("gone.txt") == null);
    try testing.expect(manifest.files.get("a.txt") != null);
}

test "a deletion alone is sent in one request, and the generation marker does not change (V5)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), repo_name);
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    try seedManifest(arena, &state_dir, old_generation, &.{.{ "gone.txt", "bye" }});
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{.{ .body = write_ok }}, .keep_body = true };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    const result = try expectPushed(push(&ctx, .{ .run_id = "run1" }));
    try testing.expectEqual(@as(usize, 0), result.sent_files);
    try testing.expectEqual(@as(usize, 1), result.deleted_files);
    server.close();
    try testing.expectEqual(@as(usize, 1), server.servedCount());
    const entries = try archiveEntries(arena, server.kept[0..server.kept_len]);
    try testing.expect(findEntry(entries, ".git/fx-delete-run1") != null);
    try testing.expect(findEntry(entries, ".git/fx-generation") == null);
    const manifest = try sandbox.readManifest(&ctx);
    try testing.expectEqualStrings(old_generation, manifest.generation.?);
}

test "an include path that is missing or unsafe is reported as missing, and one that exists is sent (V5, N17)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();
    try tmp.dir.createDirPath(io, repo_name ++ "/conf");
    try writeRepoFile(&tmp, "repo/secret.env", "TOKEN=1");
    try writeRepoFile(&tmp, "repo/conf/x.txt", "x");
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{.{ .body = write_ok }}, .keep_body = true };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    const include = [_][]const u8{ "missing.txt", "secret.env", "../x", "/abs", "conf" };
    const result = try expectPushed(push(&ctx, .{ .run_id = "run1", .include = &include }));
    try testing.expectEqual(@as(usize, 3), result.missing_include.len);
    try testing.expectEqualStrings("missing.txt", result.missing_include[0]);
    try testing.expectEqualStrings("../x", result.missing_include[1]);
    try testing.expectEqualStrings("/abs", result.missing_include[2]);
    server.close();
    const entries = try archiveEntries(arena, server.kept[0..server.kept_len]);
    try testing.expectEqualStrings("TOKEN=1", findEntry(entries, "secret.env").?.content);
    try testing.expectEqualStrings("x", findEntry(entries, "conf/x.txt").?.content);
}

test "a symbolic link in the repository is sent as a link (V5)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();
    try tmp.dir.createDirPath(io, repo_name);
    try writeRepoFile(&tmp, "repo/a.txt", "hello");
    try tmp.dir.symLink(io, "a.txt", "repo/link", .{});
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{.{ .body = write_ok }}, .keep_body = true };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    _ = try expectPushed(push(&ctx, .{ .run_id = "run1" }));
    server.close();
    const entries = try archiveEntries(arena, server.kept[0..server.kept_len]);
    const link = findEntry(entries, "link").?;
    try testing.expectEqual(std.tar.FileKind.sym_link, link.kind);
    try testing.expectEqualStrings("a.txt", link.link);
}

test "a symbolic link is sent as a link with its own target text, and nothing reads through it (V5)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/secret.txt", .data = "SECRET-MARKER" });
    try tmp.dir.createDirPath(io, repo_name);
    try tmp.dir.symLink(io, "../outside/secret.txt", "repo/escape", .{});
    try tmp.dir.symLink(io, "/etc/passwd", "repo/absolute", .{});
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{.{ .body = write_ok }}, .keep_body = true };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    const result = try expectPushed(push(&ctx, .{ .run_id = "run1" }));
    try testing.expectEqual(@as(usize, 2), result.sent_files);
    server.close();
    const gz = server.kept[0..server.kept_len];
    const entries = try archiveEntries(arena, gz);
    const escape = findEntry(entries, "escape").?;
    try testing.expect(escape.kind == .sym_link);
    try testing.expectEqualStrings("../outside/secret.txt", escape.link);
    try testing.expectEqualStrings("/etc/passwd", findEntry(entries, "absolute").?.link);
    const raw = try decompressed(arena, gz);
    try testing.expect(std.mem.find(u8, raw, "SECRET-MARKER") == null);
}

fn decompressed(arena: Allocator, gz: []const u8) ![]u8 {
    var input = std.Io.Reader.fixed(gz);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress = flate.Decompress.init(&input, .gzip, &window);
    var out: std.Io.Writer.Allocating = .init(arena);
    _ = try decompress.reader.streamRemaining(&out.writer);
    return out.written();
}

/// Walks the raw tar headers. It fails on any PAX extended header (typeflag `x` or `g`), and
/// returns how many GNU long-name or long-link headers (`L` or `K`) it found (V5).
fn countGnuHeaders(raw: []const u8) !usize {
    var offset: usize = 0;
    var count: usize = 0;
    while (offset + 512 <= raw.len) {
        const header = raw[offset..][0..512];
        if (std.mem.allEqual(u8, header, 0)) return count;
        const kind = header[156];
        try testing.expect(kind != 'x' and kind != 'g');
        if (kind == 'L' or kind == 'K') count += 1;
        const size = try std.fmt.parseInt(usize, std.mem.trim(u8, header[124..136], " \x00"), 8);
        offset += 512 + std.mem.alignForward(usize, size, 512);
    }
    return count;
}

test "a path and a link target over the ustar limit use GNU long-name headers, never PAX (V5)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();
    const long_dir = try arena.alloc(u8, 200);
    @memset(long_dir, 'a');
    const long_name = try arena.alloc(u8, 39);
    @memset(long_name, 'b');
    const long_path = try arena.print("{s}/{s}", .{ long_dir, long_name });
    const long_target = try arena.alloc(u8, 150);
    @memset(long_target, 'x');
    try tmp.dir.createDirPath(io, try arena.print("{s}/{s}", .{ repo_name, long_dir }));
    try writeRepoFile(&tmp, try arena.print("{s}/{s}", .{ repo_name, long_path }), "long");
    try tmp.dir.symLink(io, long_target, try arena.print("{s}/lnk", .{repo_name}), .{});
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{.{ .body = write_ok }}, .keep_body = true };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    const result = try expectPushed(push(&ctx, .{ .run_id = "run1" }));
    try testing.expectEqual(@as(usize, 2), result.sent_files);
    server.close();
    const gz = server.kept[0..server.kept_len];
    const entries = try archiveEntries(arena, gz);
    try testing.expectEqualStrings("long", findEntry(entries, long_path).?.content);
    try testing.expectEqualStrings(long_target, findEntry(entries, "lnk").?.link);
    const raw = try decompressed(arena, gz);
    try testing.expectEqual(@as(usize, 2), try countGnuHeaders(raw));
}

test "an include path through a symbolic link to a folder is missing, and nothing is followed (V5)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();
    try tmp.dir.createDirPath(io, repo_name ++ "/sub");
    try writeRepoFile(&tmp, "repo/sub/x.txt", "inside");
    try tmp.dir.symLink(io, "sub", "repo/linkdir", .{ .is_directory = true });
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{.{ .body = write_ok }}, .keep_body = true };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    const include = [_][]const u8{"linkdir/x.txt"};
    const result = try expectPushed(push(&ctx, .{ .run_id = "run1", .include = &include }));
    try testing.expectEqual(@as(usize, 1), result.missing_include.len);
    try testing.expectEqualStrings("linkdir/x.txt", result.missing_include[0]);
    server.close();
    const entries = try archiveEntries(arena, server.kept[0..server.kept_len]);
    try testing.expect(findEntry(entries, "linkdir/x.txt") == null);
    try testing.expectEqualStrings("inside", findEntry(entries, "sub/x.txt").?.content);
}

test "an include walk cut at its entry limit pushes what it found, deletes nothing, and does not refuse (V5)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();
    try tmp.dir.createDirPath(io, repo_name ++ "/conf");
    try writeRepoFile(&tmp, "repo/conf/1.txt", "1");
    try writeRepoFile(&tmp, "repo/conf/2.txt", "2");
    try writeRepoFile(&tmp, "repo/conf/3.txt", "3");
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    try seedManifest(arena, &state_dir, old_generation, &.{.{ "gone.txt", "bye" }});
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{.{ .body = write_ok }}, .keep_body = true };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    const include = [_][]const u8{"conf"};
    const result = try expectPushed(push(&ctx, .{ .run_id = "run1", .include = &include, .include_entries = 2 }));
    try testing.expect(!result.scan_complete);
    try testing.expectEqual(@as(usize, 0), result.deleted_files);
    server.close();
    const entries = try archiveEntries(arena, server.kept[0..server.kept_len]);
    try testing.expect(findEntry(entries, ".git/fx-delete-run1") == null);
    try testing.expectEqualStrings("1", findEntry(entries, "conf/1.txt").?.content);
}

test "a push over its byte limit is refused before any request (N2)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), repo_name);
    try writeRepoFile(&tmp, "repo/a.txt", "hello");
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{.{ .body = write_ok }} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    const failure = try expectFailed(push(&ctx, .{ .run_id = "run1", .push_cap_bytes = 4 }));
    try testing.expectEqualStrings("push", failure.step);
    server.close();
    try testing.expectEqual(@as(usize, 0), server.servedCount());
}

test "a lock held past the wait refuses the push as N16, and sends nothing (V2)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), repo_name);
    try writeRepoFile(&tmp, "repo/a.txt", "hello");
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);
    var held = try io_mod.acquireTimedAdvisoryLock(&state_dir, lock_name, 1000);
    defer held.release();

    var server: test_server.Server = .{ .replies = &.{.{ .body = write_ok }} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    const failure = try expectFailed(push(&ctx, .{ .run_id = "run1", .lock_wait_ms = 20 }));
    try testing.expectEqualStrings("lock", failure.step);
    try testing.expectEqualStrings(busy_detail, failure.detail);
    server.close();
    try testing.expectEqual(@as(usize, 0), server.servedCount());
}

test "a fs/write answer of Cannot open repairs the root once and sends the push again (V5, V4)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), repo_name);
    try writeRepoFile(&tmp, "repo/a.txt", "hello");
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    try seedManifest(arena, &state_dir, old_generation, &.{});
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{
        .{ .status = "400 Bad Request", .body = cannot_open_body },
        .{ .mode = .lines_then_close, .body = user_out },
        .{ .mode = .lines_then_close, .body = exit_zero },
        .{ .mode = .lines_then_close, .body = exit_zero },
        .{ .body = write_ok },
    }, .keep_body = true };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    const result = try expectPushed(push(&ctx, .{ .run_id = "run1" }));
    try testing.expectEqual(@as(usize, 1), result.sent_files);
    try testing.expect(result.generation_reset);
    server.close();
    try testing.expectEqual(@as(usize, 5), server.servedCount());
    const entries = try archiveEntries(arena, server.kept[0..server.kept_len]);
    try testing.expectEqualStrings("hello", findEntry(entries, "a.txt").?.content);
}

test "a push answered 410 marks the record at once, even when the resume after it fails (V3)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), repo_name);
    try writeRepoFile(&tmp, "repo/a.txt", "hello");
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    try seedManifest(arena, &state_dir, old_generation, &.{});
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{
        .{ .status = "410 Gone", .body = "{\"error\":{\"code\":\"sandbox_stopped\",\"message\":\"the session has stopped\"}}" },
        .{ .status = "500 Internal Server Error", .body = "{}" },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    _ = try expectFailed(push(&ctx, .{ .run_id = "run1" }));
    server.close();
    var file = try io_mod.openExistingReadOnlyRegularFile(state_dir.dir, "sandbox.json", .no_follow);
    defer file.close(io_mod.getIo());
    const text = try io_mod.readFileToEnd(arena, &file, 64 * 1024);
    try testing.expect(std.mem.find(u8, text, "\"expires_at_ms\":0") != null);
}

test "a fs/write that fails leaves the manifest as it was (V5)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), repo_name);
    try writeRepoFile(&tmp, "repo/a.txt", "hello");
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    try seedManifest(arena, &state_dir, old_generation, &.{});
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{
        .{ .status = "500 Internal Server Error", .body = "{\"error\":{\"message\":\"boom\"}}" },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    const failure = try expectFailed(push(&ctx, .{ .run_id = "run1" }));
    try testing.expectEqualStrings("push", failure.step);
    try testing.expectEqual(@as(u16, 500), failure.status);
    try expectNoChunk(&state_dir);
    server.close();
    const manifest = try sandbox.readManifest(&ctx);
    try testing.expectEqualStrings(old_generation, manifest.generation.?);
    try testing.expectEqual(@as(usize, 0), manifest.files.count());
}

fn expectNoChunk(state_dir: *io_mod.VerifiedDir) !void {
    _ = state_dir.dir.statFile(io_mod.getIo(), chunk_name, .{ .follow_symlinks = false }) catch |err| {
        try testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.ChunkLeftBehind;
}

test "a staged chunk is created private, mode 0600 (V5)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();
    try tmp.dir.createDirPath(io, repo_name);
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, 1);
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    var file = try openChunk(&ctx, chunk_name);
    defer file.close(io);
    const stat = try file.stat(io);
    try testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
}

test "a chunk left by a crash is removed at the next push, before any request (V5)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();
    try makeGitDir(&tmp, "");
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    try state_dir.dir.writeFile(io, .{ .sub_path = chunk_name, .data = "leftover" });
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{.{ .body = write_ok }} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    _ = try expectPushed(push(&ctx, .{ .run_id = "run1" }));
    try expectNoChunk(&state_dir);
}

test "a cancel during the push ends it as Cancelled, and the upload does not hang (R2.4)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), repo_name);
    const big = try arena.alloc(u8, 8 * 1024 * 1024);
    var seed: u64 = 0x9e3779b97f4a7c15;
    for (big) |*byte| {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        byte.* = @truncate(seed);
    }
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = repo_name ++ "/big.bin", .data = big });
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{.{ .body = write_ok }}, .stall_upload = true };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    var canceller = try std.Thread.spawn(.{}, cancelWhenServed, .{ &server, &cancel });
    defer canceller.join();
    const failure = try expectFailed(push(&ctx, .{ .run_id = "run1" }));
    try testing.expectEqualStrings("Cancelled", failure.detail);
    try expectNoChunk(&state_dir);
}

/// Cancels once the test server has counted the stalled upload's request, so the cancel lands
/// while the push waits on the upload.
fn cancelWhenServed(server: *test_server.Server, cancel: *std.atomic.Value(bool)) void {
    // A missing request still cancels: the push then ends, and the test fails on its own expectation.
    server.waitServed(1) catch {};
    cancel.store(true, .seq_cst);
}

test "a symbolic sandbox.json refuses the push before any request (V3, 5c)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();
    try tmp.dir.createDirPath(io, repo_name);
    try writeRepoFile(&tmp, "repo/a.txt", "hello");
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try state_dir.dir.symLink(io, "elsewhere.json", "sandbox.json", .{});
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{.{ .body = write_ok }} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    const failure = try expectFailed(push(&ctx, .{ .run_id = "run1" }));
    try testing.expectEqualStrings("state", failure.step);
    server.close();
    try testing.expectEqual(@as(usize, 0), server.servedCount());
}

test "info/exclude is sent when it changes, and not sent again when it does not (V5)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();
    try makeGitDir(&tmp, "secret.local\n");
    try writeRepoFile(&tmp, "repo/a.txt", "hello");
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{ .{ .body = write_ok }, .{ .body = write_ok } }, .keep_body = true };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    _ = try expectPushed(push(&ctx, .{ .run_id = "run1" }));
    try testing.expectEqual(@as(usize, 1), server.servedCount());
    const first = try archiveEntries(arena, server.kept[0..server.kept_len]);
    try testing.expectEqualStrings("secret.local\n", findEntry(first, ".git/info/exclude").?.content);

    _ = try expectPushed(push(&ctx, .{ .run_id = "run2" }));
    try testing.expectEqual(@as(usize, 1), server.servedCount());

    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/info/exclude", .data = "secret.local\nother.local\n" });
    _ = try expectPushed(push(&ctx, .{ .run_id = "run3" }));
    try testing.expectEqual(@as(usize, 2), server.servedCount());
    const third = try archiveEntries(arena, server.kept[0..server.kept_len]);
    try testing.expectEqualStrings("secret.local\nother.local\n", findEntry(third, ".git/info/exclude").?.content);
}

test "a stale manifest temp file is removed at the next push, and a fresh one is kept (V5)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();
    try makeGitDir(&tmp, "");
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedSandbox(&state_dir);
    const stale = sandbox.manifest_temp_prefix ++ "0123456789abcdef0123456789abcdef";
    const fresh = sandbox.manifest_temp_prefix ++ "fedcba9876543210fedcba9876543210";
    const now_s = @divFloor(io_mod.milliTimestamp(), 1000);
    try state_dir.dir.writeFile(io, .{ .sub_path = stale, .data = "old" });
    try state_dir.dir.writeFile(io, .{ .sub_path = fresh, .data = "new" });
    try state_dir.dir.setTimestamps(io, stale, .{
        .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, now_s - 2 * 60 * 60) * std.time.ns_per_s } },
    });
    try state_dir.dir.setTimestamps(io, fresh, .{
        .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, now_s - 10 * 60) * std.time.ns_per_s } },
    });
    const repo_root = try io_mod.dirRealpathAlloc(arena, tmp.dir, repo_name);

    var server: test_server.Server = .{ .replies = &.{.{ .body = write_ok }} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, repo_root);

    _ = try expectPushed(push(&ctx, .{ .run_id = "run1" }));
    try testing.expectError(error.FileNotFound, state_dir.dir.statFile(io, stale, .{}));
    _ = try state_dir.dir.statFile(io, fresh, .{});
}

test "a run id that is not a plain name is refused before the lock (V5)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, 1);
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir, "/tmp");

    const failure = try expectFailed(push(&ctx, .{ .run_id = "../x" }));
    try testing.expectEqualStrings("the run id is not valid", failure.detail);
}
