//! Lists the files and folders under a root. Inside a git repository the list
//! is what git shows: files from the index, untracked files no ignore rule
//! excludes, and git's folder rules (a folder with no tracked files whose
//! contents are all ignored is hidden; an ignored folder with tracked files is
//! shown). Outside a repository, and below a root that is itself ignored,
//! `.gitignore` files and a fixed set of folder names decide. Symlinks are
//! listed and never followed; submodules and nested repositories are listed
//! and never entered. Folders are read by a bounded pool of worker threads,
//! all joined before `scan` returns, and the output is sorted, so it does not
//! depend on scheduling.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const git_config = @import("git_config.zig");
const git_index = @import("git_index.zig");
const ignore = @import("ignore.zig");
const layout_mod = @import("layout.zig");
const sources = @import("sources.zig");
const tree_mod = @import("tree.zig");

const Allocator = std.mem.Allocator;

pub const default_skipped_names = [_][]const u8{ ".git", ".zig-cache", "zig-out", "node_modules", ".next", "dist", "build", "coverage" };

pub const Kind = tree_mod.Kind;
pub const Entry = tree_mod.Entry;

pub const Options = struct {
    /// D7: at most this many entries are returned.
    candidate_cap: usize = 100_000,
    max_path_bytes: usize = 2048,
    /// Folder and file names skipped outside repositories and below an
    /// ignored root (D4, U3). Never applied inside a repository.
    skipped_names: []const []const u8 = &default_skipped_names,
    max_workers: usize = 8,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    tree: tree_mod.Tree,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Error = error{ OutOfMemory, Canceled, RootUnavailable };

/// Workers stop reading folders past this many collected entries, so a huge
/// tree cannot exhaust memory. Below it, the cap keeps a sorted prefix.
const collect_factor: usize = 4;
/// Helper threads start only once this many folders are waiting.
const parallel_threshold: usize = 16;

const Rules = struct {
    repository: bool,
    fold_case: bool,
    /// Worktree-relative path of the scan root: empty, or `a/b`.
    prefix: []const u8,
    /// Worktree-relative paths of tracked files, of every folder above a
    /// tracked path, and of gitlinks.
    tracked_files: std.StringHashMapUnmanaged(void) = .empty,
    tracked_dirs: std.StringHashMapUnmanaged(void) = .empty,
    gitlinks: std.StringHashMapUnmanaged(void) = .empty,
    skipped_names: []const []const u8,
    max_path_bytes: usize,
    /// Files the rules read or looked for, stamped once the walk ends.
    sources: std.ArrayList(SourceRequest) = .empty,

    fn skipped(self: *const Rules, name: []const u8) bool {
        for (self.skipped_names) |skip| if (std.mem.eql(u8, skip, name)) return true;
        return false;
    }
};

const SourceRequest = struct { path: []const u8, identity_only: bool };

const Job = struct {
    /// Relative to the scan root.
    rel: []const u8,
    /// Path the ignore rules see: worktree-relative in a repository,
    /// root-relative otherwise.
    rule_path: []const u8,
    lists: []const *const ignore.PatternList,
    excluded: bool,
    tracked: bool,
};

const ChildState = enum { boundary, entered };

const Child = struct { rel: []const u8, state: ChildState };

const Listing = struct {
    rel: []const u8,
    tracked: bool,
    excluded: bool,
    /// An untracked folder that turned out to be a nested repository.
    boundary: bool = false,
    has_entries: bool = false,
    /// Holds content that is not ignored but was not listed (over the path
    /// limit), which keeps the folder visible.
    unlisted: bool = false,
    stamp: ?tree_mod.FolderStamp = null,
    /// Absolute path of the folder's `.gitignore`, when it has one.
    ignore_file: ?[]const u8 = null,
    files: []const []const u8 = &.{},
    children: []const Child = &.{},
};

const Worker = struct {
    arena: std.heap.ArenaAllocator,
    listings: std.ArrayList(Listing) = .empty,
    thread: ?std.Thread = null,
};

const Shared = struct {
    alloc: Allocator,
    root_dir: std.Io.Dir,
    root_abs: []const u8,
    rules: *const Rules,
    stop: ?*std.atomic.Value(bool),
    collect_limit: usize,
    scan_started_ns: i64,

    lock: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    queue: std.ArrayList(Job) = .empty,
    /// Queued plus running jobs.
    outstanding: usize = 0,
    failure: ?Error = null,

    collected: std.atomic.Value(usize) = .init(0),
    incomplete: std.atomic.Value(bool) = .init(false),
    limit_reached: std.atomic.Value(bool) = .init(false),
    overlong: std.atomic.Value(usize) = .init(0),

    fn canceled(self: *Shared) bool {
        return if (self.stop) |flag| flag.load(.acquire) else false;
    }

    fn fail(self: *Shared, err: Error) void {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        if (self.failure == null) self.failure = err;
        self.wake.broadcast(io);
    }

    /// Takes the next job, or null when the walk is finished or failed.
    fn take(self: *Shared) ?Job {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        while (true) {
            if (self.failure != null) return null;
            if (self.queue.pop()) |job| return job;
            if (self.outstanding == 0) return null;
            self.wake.waitUncancelable(io, &self.lock);
        }
    }

    fn finish(self: *Shared, children: []const Job) Allocator.Error!void {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        try self.queue.appendSlice(self.alloc, children);
        self.outstanding = self.outstanding + children.len - 1;
        self.wake.broadcast(io);
    }

    fn queued(self: *Shared) usize {
        const io = io_mod.getIo();
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        return self.queue.items.len;
    }
};

/// Lists `root` (absolute). `alloc` must be safe to use from several threads;
/// the result owns its memory.
pub fn scan(alloc: Allocator, root: []const u8, options: Options, stop: ?*std.atomic.Value(bool)) Error!Result {
    // Taken before anything is read: a stamp is reusable only if its times
    // are older than this by the granularity margin.
    const scan_started_ns = tree_mod.nowNs();
    var result_arena = std.heap.ArenaAllocator.init(alloc);
    errdefer result_arena.deinit();
    const arena = result_arena.allocator();
    if (!std.fs.path.isAbsolute(root)) return error.RootUnavailable;
    const io = io_mod.getIo();
    var root_dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch return error.RootUnavailable;
    defer root_dir.close(io);
    const root_stat = root_dir.stat(io) catch return error.RootUnavailable;

    var rules: Rules = .{
        .repository = false,
        .fold_case = false,
        .prefix = "",
        .skipped_names = options.skipped_names,
        .max_path_bytes = options.max_path_bytes,
    };
    var incomplete = false;
    var root_lists: []const *const ignore.PatternList = &.{};
    if (try repositoryRules(arena, root, &rules, &incomplete)) |lists| root_lists = lists;

    var shared: Shared = .{
        .alloc = alloc,
        .root_dir = root_dir,
        .root_abs = root,
        .rules = &rules,
        .stop = stop,
        .collect_limit = std.math.mul(usize, options.candidate_cap, collect_factor) catch std.math.maxInt(usize),
        .scan_started_ns = scan_started_ns,
    };
    defer shared.queue.deinit(alloc);
    try shared.queue.append(alloc, .{
        .rel = "",
        .rule_path = rules.prefix,
        .lists = root_lists,
        .excluded = false,
        .tracked = true,
    });
    shared.outstanding = 1;

    const worker_count = @max(1, @min(options.max_workers, std.Thread.getCpuCount() catch 1));
    const workers = try alloc.alloc(Worker, worker_count);
    defer alloc.free(workers);
    for (workers) |*worker| worker.* = .{ .arena = std.heap.ArenaAllocator.init(alloc) };
    defer for (workers) |*worker| worker.arena.deinit();

    runMain(&shared, workers);
    if (shared.failure) |err| return err;
    if (shared.canceled()) return error.Canceled;

    var listing_count: usize = 0;
    for (workers) |*worker| listing_count += worker.listings.items.len;
    const listings = try arena.alloc(*const Listing, listing_count);
    var cursor: usize = 0;
    for (workers) |*worker| {
        for (worker.listings.items) |*listing| {
            listings[cursor] = listing;
            cursor += 1;
        }
    }

    var entries: std.ArrayList(Entry) = .empty;
    try assemble(arena, listings, rules.repository, &entries);
    std.mem.sortUnstable(Entry, entries.items, {}, entryLessThan);
    var cap_reached = false;
    if (entries.items.len > options.candidate_cap) {
        entries.shrinkRetainingCapacity(options.candidate_cap);
        cap_reached = true;
    }
    if (shared.limit_reached.load(.acquire)) cap_reached = true;
    incomplete = incomplete or shared.limit_reached.load(.acquire) or shared.incomplete.load(.acquire);

    var folders: std.ArrayList(tree_mod.FolderStamp) = .empty;
    for (listings) |listing| {
        const stamp = listing.stamp orelse continue;
        try folders.append(arena, .{ .rel = try arena.dupe(u8, stamp.rel), .inode = stamp.inode, .mtime_ns = stamp.mtime_ns, .ctime_ns = stamp.ctime_ns, .reusable = stamp.reusable, .boundary = listing.boundary, .excluded = listing.excluded });
        if (listing.ignore_file) |path| try rules.sources.append(arena, .{ .path = try arena.dupe(u8, path), .identity_only = false });
    }
    const stamps = try arena.alloc(tree_mod.SourceStamp, rules.sources.items.len);
    for (rules.sources.items, stamps) |request, *stamp| stamp.* = tree_mod.sourceStamp(request.path, request.identity_only, scan_started_ns);
    const skipped_names = try arena.alloc([]const u8, options.skipped_names.len);
    for (options.skipped_names, skipped_names) |name, *copy| copy.* = try arena.dupe(u8, name);

    return .{
        .arena = result_arena,
        .tree = .{
            .root = try arena.dupe(u8, root),
            .root_inode = @intCast(root_stat.inode),
            .scan_started_ns = scan_started_ns,
            .repository = rules.repository,
            .incomplete = incomplete,
            .cap_reached = cap_reached,
            .skipped_overlong = shared.overlong.load(.acquire),
            .skipped_names = skipped_names,
            .entries = entries.items,
            .folders = folders.items,
            .sources = stamps,
        },
    };
}

/// Fills in repository rules when `root` is inside a repository and is not
/// itself ignored, and returns the ignore lists that apply above the root.
fn repositoryRules(arena: Allocator, root: []const u8, rules: *Rules, incomplete: *bool) Allocator.Error!?[]const *const ignore.PatternList {
    const maybe_found = layout_mod.discover(arena, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidGitFile => blk: {
            debug_trace.logf("indexer", "scan uses plain rules reason=invalid_git_file root={s}", .{root});
            break :blk null;
        },
    };
    // A `.git` appearing above the root changes which rules apply. Inside a
    // repository only the folders up to its worktree root matter.
    const top = if (maybe_found) |found| found.worktree_root else "/";
    var ancestor = root;
    while (true) {
        try rules.sources.append(arena, .{ .path = try std.fs.path.join(arena, &.{ ancestor, ".git" }), .identity_only = true });
        if (std.mem.eql(u8, ancestor, top)) break;
        ancestor = std.fs.path.dirname(ancestor) orelse break;
    }
    const found = maybe_found orelse return null;
    const context = try git_config.Context.fromEnvironment(arena, found);
    const loaded = try git_config.loadAll(arena, &context);
    const settings = try git_config.ignoreSettings(arena, loaded, &context);
    if (loaded.unavailable.len > 0 or settings.invalid.len > 0) incomplete.* = true;
    const wide = try sources.loadRepositoryWide(arena, found, settings);
    if (wide.unavailable.len > 0) incomplete.* = true;
    for (loaded.paths) |path| try rules.sources.append(arena, .{ .path = path, .identity_only = false });
    if (settings.excludes_file) |path| try rules.sources.append(arena, .{ .path = path, .identity_only = false });
    for ([_][]const u8{"info/exclude"}) |name| try rules.sources.append(arena, .{ .path = try std.fs.path.join(arena, &.{ found.common_dir, name }), .identity_only = false });
    for ([_][]const u8{ "index", "HEAD", "commondir" }) |name| try rules.sources.append(arena, .{ .path = try std.fs.path.join(arena, &.{ found.git_dir, name }), .identity_only = false });

    var lists: std.ArrayList(*const ignore.PatternList) = .empty;
    try lists.appendSlice(arena, wide.lists);
    // `.gitignore` files above the root, from the worktree root down. The
    // root's own file is read by its job.
    if (found.prefix.len > 0) {
        var ancestors: std.ArrayList([]const u8) = .empty;
        try ancestors.append(arena, "");
        var start: usize = 0;
        while (std.mem.findScalarPos(u8, found.prefix, start, '/')) |slash| : (start = slash + 1) {
            try ancestors.append(arena, found.prefix[0..slash]);
        }
        for (ancestors.items) |rule_dir| {
            const absolute = if (rule_dir.len == 0) found.worktree_root else try std.fs.path.join(arena, &.{ found.worktree_root, rule_dir });
            var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), absolute, .{}) catch {
                incomplete.* = true;
                continue;
            };
            defer dir.close(io_mod.getIo());
            const base = if (rule_dir.len == 0) "" else try std.fmt.allocPrint(arena, "{s}/", .{rule_dir});
            try rules.sources.append(arena, .{ .path = try std.fs.path.join(arena, &.{ absolute, ".gitignore" }), .identity_only = false });
            switch (try sources.loadDirectory(arena, dir, base)) {
                .list => |list| try lists.append(arena, list),
                .absent => {},
                .unavailable => incomplete.* = true,
            }
        }
        // U3: below an ignored root, plain rules apply.
        if (ignore.isPathExcluded(lists.items, found.prefix, true, settings.ignore_case)) {
            debug_trace.logf("indexer", "scan uses plain rules reason=ignored_root root={s}", .{root});
            return null;
        }
    }

    rules.repository = true;
    rules.fold_case = settings.ignore_case;
    rules.prefix = found.prefix;
    const index_path = try std.fs.path.join(arena, &.{ found.git_dir, "index" });
    const hash: git_index.HashFormat = if (settings.object_format == .sha256) .sha256 else .sha1;
    switch (try git_index.read(arena, index_path, hash)) {
        .missing => {},
        .unavailable => |reason| {
            debug_trace.logf("indexer", "scan index unavailable reason={s} root={s}", .{ reason, root });
            incomplete.* = true;
        },
        .index => |index| for (index.entries) |entry| {
            if (entry.gitlink) {
                try rules.gitlinks.put(arena, entry.path, {});
            } else {
                try rules.tracked_files.put(arena, entry.path, {});
            }
            var slash = std.mem.findScalarLast(u8, entry.path, '/');
            while (slash) |end| {
                const parent = entry.path[0..end];
                const slot = try rules.tracked_dirs.getOrPut(arena, parent);
                if (slot.found_existing) break;
                slash = std.mem.findScalarLast(u8, parent, '/');
            }
        },
    }
    return lists.items;
}

fn runMain(shared: *Shared, workers: []Worker) void {
    var started = false;
    while (shared.take()) |job| {
        process(shared, &workers[0], job);
        if (!started and workers.len > 1 and shared.queued() >= parallel_threshold) {
            started = true;
            for (workers[1..]) |*worker| {
                worker.thread = std.Thread.spawn(.{}, runHelper, .{ shared, worker }) catch |err| blk: {
                    debug_trace.logf("indexer", "scan worker not started err={s}", .{@errorName(err)});
                    break :blk null;
                };
            }
        }
    }
    for (workers[1..]) |*worker| if (worker.thread) |thread| thread.join();
}

fn runHelper(shared: *Shared, worker: *Worker) void {
    while (shared.take()) |job| process(shared, worker, job);
}

fn process(shared: *Shared, worker: *Worker, job: Job) void {
    var children: std.ArrayList(Job) = .empty;
    listDirectory(shared, worker, job, &children) catch |err| switch (err) {
        error.OutOfMemory => return shared.fail(error.OutOfMemory),
        error.Canceled => return shared.fail(error.Canceled),
    };
    shared.finish(children.items) catch shared.fail(error.OutOfMemory);
}

fn listDirectory(shared: *Shared, worker: *Worker, job: Job, children: *std.ArrayList(Job)) (Allocator.Error || error{Canceled})!void {
    const arena = worker.arena.allocator();
    const io = io_mod.getIo();
    const rules = shared.rules;
    var listing: Listing = .{ .rel = job.rel, .tracked = job.tracked, .excluded = job.excluded };
    defer worker.listings.append(arena, listing) catch shared.fail(error.OutOfMemory);
    if (shared.canceled()) return error.Canceled;
    if (shared.limit_reached.load(.acquire)) return;

    var dir = shared.root_dir.openDir(io, if (job.rel.len == 0) "." else job.rel, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
        debug_trace.logf("indexer", "scan folder unreadable err={s} bytes={d}", .{ @errorName(err), job.rel.len });
        shared.incomplete.store(true, .release);
        return;
    };
    defer dir.close(io);
    if (dir.stat(io)) |stat| {
        listing.stamp = tree_mod.folderStamp(job.rel, stat, shared.scan_started_ns);
    } else |_| shared.incomplete.store(true, .release);

    var lists = job.lists;
    // Below an excluded folder everything is excluded, as in git, which stops
    // reading `.gitignore` files there.
    if (!job.excluded) {
        const base = if (job.rule_path.len == 0) "" else try std.fmt.allocPrint(arena, "{s}/", .{job.rule_path});
        const loaded = try sources.loadDirectory(arena, dir, base);
        if (loaded != .absent) listing.ignore_file = try std.fs.path.join(arena, &.{ shared.root_abs, job.rel, ".gitignore" });
        switch (loaded) {
            .list => |list| {
                const extended = try arena.alloc(*const ignore.PatternList, lists.len + 1);
                @memcpy(extended[0..lists.len], lists);
                extended[lists.len] = list;
                lists = extended;
            },
            .absent => {},
            .unavailable => |reason| {
                debug_trace.logf("indexer", "scan ignore file unavailable reason={s} bytes={d}", .{ reason, job.rel.len });
                shared.incomplete.store(true, .release);
            },
        }
    }

    var files: std.ArrayList([]const u8) = .empty;
    var child_entries: std.ArrayList(Child) = .empty;
    var saw_dot_git = false;
    var iterator = dir.iterate();
    while (true) {
        if (shared.canceled()) return error.Canceled;
        const entry = iterator.next(io) catch |err| {
            debug_trace.logf("indexer", "scan folder read stopped err={s} bytes={d}", .{ @errorName(err), job.rel.len });
            shared.incomplete.store(true, .release);
            break;
        } orelse break;
        if (std.mem.eql(u8, entry.name, ".git")) {
            saw_dot_git = true;
            continue;
        }
        listing.has_entries = true;
        if (!rules.repository and rules.skipped(entry.name)) continue;

        const rel = try joinPath(arena, job.rel, entry.name);
        const rule_path = if (rules.repository) try joinPath(arena, job.rule_path, entry.name) else rel;
        // A path over the limit is not listed, but it still exists and is not
        // ignored, so its folder stays visible.
        const overlong = rel.len > rules.max_path_bytes;
        var kind = entry.kind;
        if (kind == .unknown) {
            kind = (dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue).kind;
        }
        switch (kind) {
            .file, .sym_link => {
                const tracked = rules.repository and rules.tracked_files.contains(rule_path);
                if (!tracked and (job.excluded or excludedPath(lists, rule_path, false, rules.fold_case))) continue;
                if (overlong) {
                    _ = shared.overlong.fetchAdd(1, .acq_rel);
                    listing.unlisted = true;
                    continue;
                }
                try files.append(arena, rel);
            },
            .directory => {
                const gitlink = rules.repository and rules.gitlinks.contains(rule_path);
                const tracked = rules.repository and rules.tracked_dirs.contains(rule_path);
                const excluded = !gitlink and (job.excluded or excludedPath(lists, rule_path, true, rules.fold_case));
                if (excluded and !tracked) continue;
                if (overlong) {
                    _ = shared.overlong.fetchAdd(1, .acq_rel);
                    listing.unlisted = true;
                    continue;
                }
                if (gitlink) {
                    try child_entries.append(arena, .{ .rel = rel, .state = .boundary });
                    continue;
                }
                try children.append(arena, .{ .rel = rel, .rule_path = rule_path, .lists = lists, .excluded = excluded, .tracked = tracked });
                try child_entries.append(arena, .{ .rel = rel, .state = .entered });
            },
            // FIFOs, sockets and devices are never listed or opened.
            else => {},
        }
    }

    // An untracked folder with its own repository is a boundary, as in git.
    if (rules.repository and saw_dot_git and !job.tracked and job.rel.len > 0) {
        const absolute = try std.fs.path.join(arena, &.{ shared.root_abs, job.rel });
        if (try layout_mod.hasOwnRepository(arena, absolute)) {
            listing.boundary = true;
            children.clearRetainingCapacity();
            return;
        }
    }
    listing.files = files.items;
    listing.children = child_entries.items;
    const total = shared.collected.fetchAdd(files.items.len + child_entries.items.len, .acq_rel) + files.items.len + child_entries.items.len;
    if (total > shared.collect_limit) {
        shared.limit_reached.store(true, .release);
        children.clearRetainingCapacity();
    }
}

fn excludedPath(lists: []const *const ignore.PatternList, path: []const u8, is_dir: bool, fold_case: bool) bool {
    return ignore.decide(lists, path, is_dir, fold_case) == .excluded;
}

fn joinPath(arena: Allocator, parent: []const u8, name: []const u8) Allocator.Error![]const u8 {
    if (parent.len == 0) return arena.dupe(u8, name);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ parent, name });
}

/// Applies git's folder rules bottom-up and gathers the visible entries.
fn assemble(arena: Allocator, listings: []const *const Listing, repository: bool, out: *std.ArrayList(Entry)) Allocator.Error!void {
    var by_path: std.StringHashMapUnmanaged(usize) = .empty;
    try by_path.ensureTotalCapacity(arena, @intCast(listings.len));
    for (listings, 0..) |listing, index| by_path.putAssumeCapacity(listing.rel, index);

    // Deeper folders first, so each folder sees its children's visibility.
    const order = try arena.alloc(usize, listings.len);
    for (order, 0..) |*slot, index| slot.* = index;
    std.mem.sortUnstable(usize, order, listings, struct {
        fn deeper(items: []const *const Listing, a: usize, b: usize) bool {
            return std.mem.count(u8, items[a].rel, "/") > std.mem.count(u8, items[b].rel, "/");
        }
    }.deeper);
    const visible = try arena.alloc(bool, listings.len);
    for (order) |index| {
        const listing = listings[index];
        visible[index] = if (!repository or listing.tracked or listing.boundary or !listing.has_entries) true else blk: {
            if (listing.excluded) break :blk false;
            if (listing.files.len > 0 or listing.unlisted) break :blk true;
            for (listing.children) |child| {
                if (child.state == .boundary) break :blk true;
                // A folder that could not be read counts as visible, as in git.
                const child_index = by_path.get(child.rel) orelse break :blk true;
                if (visible[child_index]) break :blk true;
            }
            break :blk false;
        };
    }

    for (listings, 0..) |listing, index| {
        if (!visible[index]) continue;
        for (listing.files) |path| try out.append(arena, .{ .path = try arena.dupe(u8, path), .kind = .file });
        for (listing.children) |child| {
            const shown = switch (child.state) {
                .boundary => true,
                .entered => if (by_path.get(child.rel)) |child_index| visible[child_index] else true,
            };
            if (shown) try out.append(arena, .{ .path = try arena.dupe(u8, child.rel), .kind = .directory });
        }
    }
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return switch (std.mem.order(u8, a.path, b.path)) {
        .lt => true,
        .gt => false,
        .eq => @intFromEnum(a.kind) < @intFromEnum(b.kind),
    };
}

const TestTree = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,

    fn init(arena: Allocator) !TestTree {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .root = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".") };
    }

    fn file(self: *TestTree, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| try self.tmp.dir.createDirPath(std.testing.io, parent);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }

    fn dir(self: *TestTree, path: []const u8) !void {
        try self.tmp.dir.createDirPath(std.testing.io, path);
    }

    /// A repository whose index tracks `tracked`.
    fn repo(self: *TestTree, arena: Allocator, name: []const u8, tracked: []const git_index.TestEntry) !void {
        try self.file(try std.fmt.allocPrint(arena, "{s}/.git/HEAD", .{name}), "ref: refs/heads/main\n");
        try self.dir(try std.fmt.allocPrint(arena, "{s}/.git/objects", .{name}));
        try self.dir(try std.fmt.allocPrint(arena, "{s}/.git/refs", .{name}));
        try self.file(try std.fmt.allocPrint(arena, "{s}/.git/index", .{name}), try git_index.buildForTest(arena, 2, .sha1, tracked, ""));
    }
};

fn expectEntries(result: Result, expected: []const Entry) !void {
    errdefer for (result.tree.entries) |entry| std.debug.print("  got {s} {s}\n", .{ @tagName(entry.kind), entry.path });
    try std.testing.expectEqual(expected.len, result.tree.entries.len);
    for (expected, result.tree.entries) |want, have| {
        try std.testing.expectEqualStrings(want.path, have.path);
        try std.testing.expectEqual(want.kind, have.kind);
    }
}

test "repository scan follows git: index, ignore rules, folder rules and boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tree = try TestTree.init(arena);
    defer tree.tmp.cleanup();
    try tree.repo(arena, "repo", &.{
        .{ .path = "a.txt" },
        .{ .path = "c.log" },
        .{ .path = "deleted.txt" },
        .{ .path = "dist/keep.txt" },
        .{ .path = "mod", .mode = 0o160000 },
    });
    try tree.file("repo/.gitignore", "*.log\ndist/\n*.tmp\n");
    try tree.file("repo/a.txt", "a");
    try tree.file("repo/b.log", "b");
    try tree.file("repo/c.log", "c");
    try tree.file("repo/dist/keep.txt", "k");
    try tree.file("repo/dist/new.txt", "n");
    try tree.file("repo/dist/sub/deep.txt", "d");
    try tree.file("repo/mod/inner.txt", "i");
    try tree.file("repo/nested/.git/HEAD", "ref: refs/heads/main\n");
    try tree.dir("repo/nested/.git/objects");
    try tree.dir("repo/nested/.git/refs");
    try tree.file("repo/nested/file.txt", "f");
    try tree.file("repo/onlyignored/x.tmp", "x");
    try tree.dir("repo/onlyignored/deeper");
    try tree.file("repo/onlyignored/deeper/y.tmp", "y");
    try tree.dir("repo/empty");
    try tree.file("repo/.hidden/h.txt", "h");
    try tree.tmp.dir.symLink(std.testing.io, "a.txt", "repo/link", .{});
    try tree.tmp.dir.symLink(std.testing.io, "dist", "repo/dirlink", .{});

    var result = try scan(std.testing.allocator, try std.fs.path.join(arena, &.{ tree.root, "repo" }), .{}, null);
    defer result.deinit();
    try std.testing.expect(result.tree.repository);
    try std.testing.expect(!result.tree.incomplete);
    try expectEntries(result, &.{
        .{ .path = ".gitignore", .kind = .file },
        .{ .path = ".hidden", .kind = .directory },
        .{ .path = ".hidden/h.txt", .kind = .file },
        .{ .path = "a.txt", .kind = .file },
        .{ .path = "c.log", .kind = .file },
        .{ .path = "dirlink", .kind = .file },
        .{ .path = "dist", .kind = .directory },
        .{ .path = "dist/keep.txt", .kind = .file },
        .{ .path = "empty", .kind = .directory },
        .{ .path = "link", .kind = .file },
        .{ .path = "mod", .kind = .directory },
        .{ .path = "nested", .kind = .directory },
    });

    // Scanning a subfolder applies the rules above it, with paths relative to it.
    try tree.file("repo/.hidden/skip.log", "s");
    var sub = try scan(std.testing.allocator, try std.fs.path.join(arena, &.{ tree.root, "repo/.hidden" }), .{}, null);
    defer sub.deinit();
    try std.testing.expect(sub.tree.repository);
    try expectEntries(sub, &.{.{ .path = "h.txt", .kind = .file }});

    // U3: a root that is itself ignored is listed with plain rules.
    var ignored_root = try scan(std.testing.allocator, try std.fs.path.join(arena, &.{ tree.root, "repo/dist" }), .{}, null);
    defer ignored_root.deinit();
    try std.testing.expect(!ignored_root.tree.repository);
    try expectEntries(ignored_root, &.{
        .{ .path = "keep.txt", .kind = .file },
        .{ .path = "new.txt", .kind = .file },
        .{ .path = "sub", .kind = .directory },
        .{ .path = "sub/deep.txt", .kind = .file },
    });
}

test "plain scan applies .gitignore files and the skipped names, also below an ignored root" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tree = try TestTree.init(arena);
    defer tree.tmp.cleanup();
    try tree.repo(arena, "repo", &.{.{ .path = "plain/tracked.txt" }});
    try tree.file("repo/.gitignore", "plain/\n");
    try tree.file("repo/plain/.gitignore", "*.log\n");
    try tree.file("repo/plain/tracked.txt", "t");
    try tree.file("repo/plain/a.log", "a");
    try tree.file("repo/plain/src/main.zig", "m");
    try tree.file("repo/plain/node_modules/pkg/index.js", "p");
    try tree.file("repo/plain/build/out.o", "o");
    try tree.file("repo/plain/sub/dist", "named like a skipped folder");

    var result = try scan(std.testing.allocator, try std.fs.path.join(arena, &.{ tree.root, "repo/plain" }), .{}, null);
    defer result.deinit();
    try std.testing.expect(!result.tree.repository);
    try expectEntries(result, &.{
        .{ .path = ".gitignore", .kind = .file },
        .{ .path = "src", .kind = .directory },
        .{ .path = "src/main.zig", .kind = .file },
        .{ .path = "sub", .kind = .directory },
        .{ .path = "tracked.txt", .kind = .file },
    });

    var custom = try scan(std.testing.allocator, try std.fs.path.join(arena, &.{ tree.root, "repo/plain" }), .{ .skipped_names = &.{"src"} }, null);
    defer custom.deinit();
    try expectEntries(custom, &.{
        .{ .path = ".gitignore", .kind = .file },
        .{ .path = "build", .kind = .directory },
        .{ .path = "build/out.o", .kind = .file },
        .{ .path = "node_modules", .kind = .directory },
        .{ .path = "node_modules/pkg", .kind = .directory },
        .{ .path = "node_modules/pkg/index.js", .kind = .file },
        .{ .path = "sub", .kind = .directory },
        .{ .path = "sub/dist", .kind = .file },
        .{ .path = "tracked.txt", .kind = .file },
    });
}

test "scan caps, skips overlong paths, cancels and is the same with one worker or many" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tree = try TestTree.init(arena);
    defer tree.tmp.cleanup();
    try tree.repo(arena, "repo", &.{});
    for (0..60) |i| {
        for (0..3) |j| try tree.file(try std.fmt.allocPrint(arena, "repo/d{d:0>2}/s{d}/f.txt", .{ i, j }), "x");
    }
    const root = try std.fs.path.join(arena, &.{ tree.root, "repo" });

    var serial = try scan(std.testing.allocator, root, .{ .max_workers = 1 }, null);
    defer serial.deinit();
    var parallel = try scan(std.testing.allocator, root, .{ .max_workers = 8 }, null);
    defer parallel.deinit();
    try std.testing.expectEqual(@as(usize, 60 * 7), serial.tree.entries.len);
    try std.testing.expectEqual(serial.tree.entries.len, parallel.tree.entries.len);
    for (serial.tree.entries, parallel.tree.entries) |a, b| {
        try std.testing.expectEqualStrings(a.path, b.path);
        try std.testing.expectEqual(a.kind, b.kind);
    }
    for (serial.tree.entries[1..], serial.tree.entries[0 .. serial.tree.entries.len - 1]) |later, earlier| {
        try std.testing.expect(entryLessThan({}, earlier, later));
    }

    // Within the collection limit the cap keeps the sorted prefix.
    var capped = try scan(std.testing.allocator, root, .{ .candidate_cap = 200 }, null);
    defer capped.deinit();
    // Below it the walk read everything, so only the cap was reached.
    try std.testing.expect(!capped.tree.incomplete and capped.tree.cap_reached);
    try std.testing.expectEqual(@as(usize, 200), capped.tree.entries.len);
    for (capped.tree.entries, serial.tree.entries[0..200]) |a, b| try std.testing.expectEqualStrings(b.path, a.path);
    // Past it, reading stops early: still capped, sorted and incomplete.
    var tiny = try scan(std.testing.allocator, root, .{ .candidate_cap = 10 }, null);
    defer tiny.deinit();
    try std.testing.expect(tiny.tree.incomplete and tiny.tree.cap_reached);
    try std.testing.expectEqual(@as(usize, 10), tiny.tree.entries.len);
    for (tiny.tree.entries[1..], tiny.tree.entries[0 .. tiny.tree.entries.len - 1]) |later, earlier| try std.testing.expect(entryLessThan({}, earlier, later));

    var short = try scan(std.testing.allocator, root, .{ .max_path_bytes = 6 }, null);
    defer short.deinit();
    // Folders whose only files are over the limit stay listed.
    try std.testing.expectEqual(@as(usize, 60 * 4), short.tree.entries.len);
    for (short.tree.entries) |entry| try std.testing.expectEqual(Kind.directory, entry.kind);
    try std.testing.expectEqual(@as(usize, 60 * 3), short.tree.skipped_overlong);

    var stop: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Canceled, scan(std.testing.allocator, root, .{}, &stop));
    try std.testing.expectError(error.RootUnavailable, scan(std.testing.allocator, try std.fs.path.join(arena, &.{ root, "missing" }), .{}, null));
}

test "repository scan reports an unusable index as incomplete and keeps untracked files" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tree = try TestTree.init(arena);
    defer tree.tmp.cleanup();
    try tree.repo(arena, "repo", &.{});
    try tree.file("repo/.git/index", "DIRC garbage");
    try tree.file("repo/.gitignore", "*.log\n");
    try tree.file("repo/kept.txt", "k");
    try tree.file("repo/committed.log", "c");
    var result = try scan(std.testing.allocator, try std.fs.path.join(arena, &.{ tree.root, "repo" }), .{}, null);
    defer result.deinit();
    try std.testing.expect(result.tree.incomplete);
    try expectEntries(result, &.{
        .{ .path = ".gitignore", .kind = .file },
        .{ .path = "kept.txt", .kind = .file },
    });
}

test "refresh trusts an old unchanged tree and rejects every kind of change" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tree = try TestTree.init(arena);
    defer tree.tmp.cleanup();
    const cases = [_][]const u8{ "unchanged", "new_file", "ignore_edit", "index", "config", "replaced", "future" };
    for (cases) |name| {
        try tree.repo(arena, name, &.{.{ .path = "src/a.txt" }});
        try tree.file(try std.fmt.allocPrint(arena, "{s}/.gitignore", .{name}), "*.log\n");
        try tree.file(try std.fmt.allocPrint(arena, "{s}/src/a.txt", .{name}), "a");
        try tree.file(try std.fmt.allocPrint(arena, "{s}/docs/b.md", .{name}), "b");
    }
    const future: std.Io.Timestamp = .{ .nanoseconds = @as(i96, tree_mod.nowNs()) + 3600 * std.time.ns_per_s };
    try tree.tmp.dir.setTimestamps(std.testing.io, "future/docs", .{ .modify_timestamp = .{ .new = future } });

    // A tree scanned right after its files changed is never reused.
    {
        const root = try std.fs.path.join(arena, &.{ tree.root, "unchanged" });
        var racy = try scan(std.testing.allocator, root, .{}, null);
        defer racy.deinit();
        try std.testing.expect(!tree_mod.isCurrent(&racy.tree, root, &default_skipped_names, null));
    }

    io_mod.sleep(@intCast(tree_mod.granularity_margin_ns + std.time.ns_per_s / 2));
    var results: [cases.len]Result = undefined;
    var roots: [cases.len][]const u8 = undefined;
    for (cases, 0..) |name, i| {
        roots[i] = try std.fs.path.join(arena, &.{ tree.root, name });
        results[i] = try scan(std.testing.allocator, roots[i], .{}, null);
    }
    defer for (&results) |*result| result.deinit();

    try std.testing.expect(tree_mod.isCurrent(&results[0].tree, roots[0], &default_skipped_names, null));
    try std.testing.expect(!tree_mod.isCurrent(&results[0].tree, roots[0], &.{"node_modules"}, null));

    try tree.file("new_file/src/c.txt", "c");
    try tree.file("ignore_edit/.gitignore", "*.md\n");
    try tree.file("index/.git/index", try git_index.buildForTest(arena, 2, .sha1, &.{ .{ .path = "src/a.txt" }, .{ .path = "docs/b.md" } }, ""));
    try tree.file("config/.git/config", "[core]\n\tignorecase = true\n");
    try tree.tmp.dir.rename("replaced", tree.tmp.dir, "replaced-old", std.testing.io);
    try tree.repo(arena, "replaced", &.{.{ .path = "src/a.txt" }});

    // A change in `src` leaves a check of `docs` alone.
    try std.testing.expect(tree_mod.isCurrent(&results[1].tree, roots[1], &default_skipped_names, "docs"));
    for (results[1..], roots[1..], cases[1..]) |*result, root, name| {
        if (tree_mod.isCurrent(&result.tree, root, &default_skipped_names, null)) {
            std.debug.print("stale tree reported current: {s}\n", .{name});
            return error.TestExpectedStale;
        }
    }
}
