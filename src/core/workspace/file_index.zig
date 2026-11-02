//! Background workspace file index for the @-mention picker.
//!
//! Each generation owns immutable parallel buffers. The loader publishes complete
//! prefixes with release stores; readers acquire `ready_count` before scanning.
//! Replacement generations remain private until the main thread adopts them.
//! Search uses pre-lowercased paths and a per-path ASCII bitmap to reject
//! impossible subsequence matches before scoring. Each remaining path is
//! ranked by its best query placement (`alignBest`), and highlights show that
//! same placement.

const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const file_picker_path = @import("../input/file_picker_path.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const display_width = @import("../shared/display_width.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const unicode_simple_fold = @import("unicode_simple_fold.zig");
const pathing = @import("pathing.zig");
const workspace_access = @import("workspace_access.zig");
const indexer = @import("../indexer/indexer.zig");

const Allocator = std.mem.Allocator;

pub const max_indexed_files: usize = 100_000;
pub const max_path_len: u32 = 2048;

const sha256_digest_len = std.crypto.hash.sha2.Sha256.digest_length;

fn rootsDigest(roots: []const []const u8) [sha256_digest_len]u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    for (roots) |root| {
        digest.update(root);
        digest.update(&.{0});
    }
    var sum: [sha256_digest_len]u8 = undefined;
    digest.final(&sum);
    return sum;
}

pub const CandidateKind = enum(u8) {
    file,
    directory,
};

pub const Candidate = struct {
    path: []const u8,
    kind: CandidateKind,
};

pub const MatchSpan = struct {
    byte_start: u16,
    byte_end: u16,
};

pub const SearchResult = struct {
    path: []const u8,
    kind: CandidateKind,
    matched_spans: []const MatchSpan,
};

pub const SearchError = error{ NoSpaceLeft, InvalidIndexData };

pub const State = enum(u8) {
    idle = 0,
    loading = 1,
    ready = 2,
    failed = 3,
};

const GenerationState = enum(u8) {
    loading,
    ready,
    failed,
    canceled,
};

const LoaderFailureStage = enum {
    discovery,
    storage,
};

const LoaderFailure = struct {
    stage: LoaderFailureStage,
    err: anyerror,
};

const LoaderOutcome = union(enum) {
    ready,
    failed: LoaderFailure,
    canceled,

    fn terminalState(self: LoaderOutcome) GenerationState {
        return switch (self) {
            .ready => .ready,
            .failed => .failed,
            .canceled => .canceled,
        };
    }
};

/// Value-only identity of one readable prefix; it grants no borrowed lifetime.
pub const ReadableRevision = struct {
    scope_epoch: u64 = 0,
    generation: usize = 0,
    count: usize = 0,
    state: State = .idle,
};

const Generation = struct {
    id: usize,
    scope_epoch: u64 = 0,
    /// Cache-sourced generations publish fast from the persisted index and
    /// always trigger one real scan behind them.
    from_cache: bool = false,
    paths_buf: []u8 = &.{},
    lower_buf: []u8 = &.{},
    offsets: []u32 = &.{},
    basename_starts: []u32 = &.{},
    kinds: []CandidateKind = &.{},
    /// One `u32` per path; bit `n` is set iff the lower-cased path contains
    /// the letter `'a' + n`. Used as an O(1) reject: a query mask can only
    /// match if `(path_mask & query_mask) == query_mask`, since every letter
    /// in the query must appear somewhere in the path for a subsequence match.
    char_masks: []u32 = &.{},
    /// The loader publishes an immutable prefix with release stores after
    /// every parallel-buffer entry is complete. Search pairs this with an
    /// acquire load before reading that prefix.
    ready_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// A release store publishes the terminal outcome after all generation
    /// writes. The main thread performs an acquire load before deciding
    /// whether joining and adoption are permitted.
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@backingInt(GenerationState.loading)),

    fn create(alloc: Allocator, id: usize) !*Generation {
        const generation = try alloc.create(Generation);
        generation.* = .{ .id = id };
        return generation;
    }

    fn destroy(self: *Generation, alloc: Allocator) void {
        self.freeBuffers(alloc);
        alloc.destroy(self);
    }

    fn currentState(self: *const Generation) GenerationState {
        return @fromBackingInt(@intCast(self.state.load(.acquire)));
    }

    fn finish(self: *Generation, state: GenerationState) void {
        self.state.store(@backingInt(state), .release);
    }

    fn count(self: *const Generation) usize {
        return self.ready_count.load(.acquire);
    }

    fn pathAt(self: *const Generation, index: usize) []const u8 {
        const start = self.offsets[index];
        const end = self.offsets[index + 1];
        return self.paths_buf[start..end];
    }

    fn kindAt(self: *const Generation, index: usize) CandidateKind {
        return self.kinds[index];
    }

    fn lowerPathAt(self: *const Generation, index: u32) []const u8 {
        const start = self.offsets[index];
        const end = self.offsets[index + 1];
        return self.lower_buf[start..end];
    }

    /// Allocates this generation's complete storage before publishing any
    /// entry. Cancellation retains the published prefix until the main thread
    /// discards the generation after its loader reaches a terminal state.
    fn fillProgressive(
        self: *Generation,
        alloc: Allocator,
        source: CandidateSource,
        stop_requested: ?*std.atomic.Value(bool),
    ) !void {
        if (isStopRequested(stop_requested)) return error.Canceled;

        const totals = countAndSize(source);

        try self.allocateBuffers(alloc, totals);
        if (totals.n == 0) return;

        self.offsets[0] = 0;

        var iterator = source.iterator();
        var candidate_index: u32 = 0;
        var buffer_position: u32 = 0;
        while (iterator.next()) |candidate| {
            if (isStopRequested(stop_requested)) return error.Canceled;
            if (candidate_index >= totals.n) break;
            const accepted = acceptedCandidate(candidate) orelse continue;
            const path = accepted.path;

            const start = buffer_position;
            const len: u32 = @intCast(path.len);
            @memcpy(self.paths_buf[start .. start + len], path);

            var mask: u32 = 0;
            var contains_non_ascii = false;
            for (path, 0..) |byte, byte_index| {
                const lower = asciiToLower(byte);
                self.lower_buf[start + @as(u32, @intCast(byte_index))] = lower;
                if (byte >= 0x80) contains_non_ascii = true;
                if (lower >= 'a' and lower <= 'z') {
                    mask |= @as(u32, 1) << @intCast(lower - 'a');
                }
            }

            const slash = std.mem.findScalarLast(u8, path, '/');
            self.basename_starts[candidate_index] = if (slash) |index|
                start + @as(u32, @intCast(index + 1))
            else
                start;
            if (contains_non_ascii) mask |= non_ascii_mask;
            self.char_masks[candidate_index] = mask;
            self.kinds[candidate_index] = accepted.kind;
            buffer_position += len;
            self.offsets[candidate_index + 1] = buffer_position;

            self.ready_count.store(candidate_index + 1, .release);
            candidate_index += 1;
        }

        if (isStopRequested(stop_requested)) return error.Canceled;
    }

    /// Transfers complete parallel-buffer ownership only after every
    /// allocation succeeds. Later population failure leaves cleanup with the
    /// generation rather than the allocation errdefers in this scope.
    fn allocateBuffers(self: *Generation, alloc: Allocator, totals: RawTotals) !void {
        const paths_buf = try alloc.alloc(u8, totals.bytes);
        errdefer alloc.free(paths_buf);
        const lower_buf = try alloc.alloc(u8, totals.bytes);
        errdefer alloc.free(lower_buf);
        const offsets = try alloc.alloc(u32, totals.n + 1);
        errdefer alloc.free(offsets);
        const basename_starts = try alloc.alloc(u32, totals.n);
        errdefer alloc.free(basename_starts);
        const char_masks = try alloc.alloc(u32, totals.n);
        errdefer alloc.free(char_masks);
        const kinds = try alloc.alloc(CandidateKind, totals.n);
        errdefer alloc.free(kinds);

        self.paths_buf = paths_buf;
        self.lower_buf = lower_buf;
        self.offsets = offsets;
        self.basename_starts = basename_starts;
        self.char_masks = char_masks;
        self.kinds = kinds;
    }

    fn freeBuffers(self: *Generation, alloc: Allocator) void {
        if (self.paths_buf.len > 0) alloc.free(self.paths_buf);
        if (self.lower_buf.len > 0) alloc.free(self.lower_buf);
        if (self.offsets.len > 0) alloc.free(self.offsets);
        if (self.basename_starts.len > 0) alloc.free(self.basename_starts);
        if (self.char_masks.len > 0) alloc.free(self.char_masks);
        if (self.kinds.len > 0) alloc.free(self.kinds);
        self.paths_buf = &.{};
        self.lower_buf = &.{};
        self.offsets = &.{};
        self.basename_starts = &.{};
        self.char_masks = &.{};
        self.kinds = &.{};
        self.ready_count.store(0, .release);
    }
};

pub const FileIndex = struct {
    const PendingScope = struct { roots: [][]u8, epoch: u64 };

    /// The main thread is the sole owner allowed to replace or reclaim these
    /// generation pointers. The loader writes only `loading_generation`.
    active_generation: ?*Generation = null,
    loading_generation: ?*Generation = null,
    /// Owned roots for the current generation. The primary root is first;
    /// active additional roots follow in configured order.
    roots: [][]u8 = &.{},
    scope_epoch: u64 = 0,
    /// Roots and their installed-scope identity transfer together.
    pending_scope: ?PendingScope = null,

    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    generation: usize = 0,
    initial_failed: bool = false,
    /// Digest of the roots whose persisted cache this process already consumed.
    /// A scope switch to different roots may load its own cache.
    cache_attempted_digest: ?[sha256_digest_len]u8 = null,

    pub fn requestStop(self: *FileIndex) void {
        self.stop_requested.store(true, .seq_cst);
        debug_trace.logf("core", "file index shutdown requested generation={d} loader={s} active={} loading={} queued={}", .{
            self.generation,
            if (self.thread == null) "none" else "owned",
            self.active_generation != null,
            self.loading_generation != null,
            self.pending_scope != null,
        });
    }

    pub fn deinit(self: *FileIndex, alloc: Allocator) void {
        self.requestStop();
        if (self.thread) |handle| {
            handle.join();
            self.thread = null;
            debug_trace.logf("core", "file index shutdown joined generation={d}", .{self.generation});
        }
        if (self.loading_generation) |generation| {
            debug_trace.logf("core", "file index generation discarded generation={d} state={s}", .{ generation.id, @tagName(generation.currentState()) });
            generation.destroy(alloc);
        }
        self.loading_generation = null;
        if (self.active_generation) |generation| {
            debug_trace.logf("core", "file index shutdown reclaiming generation={d}", .{generation.id});
            generation.destroy(alloc);
        }
        self.active_generation = null;
        freeRoots(alloc, self.roots);
        self.roots = &.{};
        if (self.pending_scope) |pending| freeRoots(alloc, pending.roots);
        self.pending_scope = null;
        debug_trace.logf("core", "file index shutdown complete generation={d}", .{self.generation});
    }

    pub fn currentState(self: *const FileIndex) State {
        if (self.active_generation != null) return .ready;
        const loading = self.loading_generation orelse return if (self.initial_failed) .failed else .idle;
        return switch (loading.currentState()) {
            .loading => .loading,
            .ready => .ready,
            .failed, .canceled => .failed,
        };
    }

    /// Number of path entries currently searchable. During load this grows
    /// as the loader thread publishes more entries; once the build finishes
    /// it holds steady at the final count.
    pub fn count(self: *const FileIndex) usize {
        const generation = self.searchableGeneration() orelse return 0;
        return generation.count();
    }

    /// Kick off one background generation from an immutable access scope.
    pub fn ensureScope(self: *FileIndex, alloc: Allocator, scope: workspace_access.AccessScope) void {
        self.ensureScopeEpoch(alloc, scope, 0);
    }

    pub fn ensureScopeEpoch(self: *FileIndex, alloc: Allocator, scope: workspace_access.AccessScope, epoch: u64) void {
        if (self.currentState() != .idle) return;
        if (scope.primary_directory.len == 0) return;

        self.roots = activeRootsAlloc(alloc, scope) catch return;
        self.scope_epoch = epoch;
        _ = self.startLoad(alloc);
    }

    fn startLoad(self: *FileIndex, alloc: Allocator) bool {
        if (self.roots.len == 0 or
            self.thread != null or
            self.loading_generation != null or
            self.stop_requested.load(.seq_cst)) return false;

        // The persisted cache is consumed at most once per scope: the first
        // generation paints from disk, then a real scan replaces it.
        const roots_digest = rootsDigest(self.roots);
        const allow_cache = if (self.cache_attempted_digest) |attempted|
            !std.mem.eql(u8, &attempted, &roots_digest)
        else
            true;
        if (allow_cache) self.cache_attempted_digest = roots_digest;

        const generation_id = self.generation + 1;
        const loading = Generation.create(alloc, generation_id) catch |err| {
            if (self.active_generation == null) self.initial_failed = true;
            debug_trace.logf("core", "file index generation allocation failed generation={d} err={s}", .{ generation_id, @errorName(err) });
            return false;
        };
        loading.scope_epoch = self.scope_epoch;
        self.loading_generation = loading;
        self.generation = generation_id;
        self.initial_failed = false;
        self.thread = std.Thread.spawn(.{}, loaderThreadMain, .{
            loading,
            alloc,
            self.roots,
            &self.stop_requested,
            allow_cache,
        }) catch |err| {
            self.loading_generation = null;
            loading.destroy(alloc);
            if (self.active_generation == null) self.initial_failed = true;
            debug_trace.logf("core", "file index generation spawn failed generation={d} err={s}", .{ generation_id, @errorName(err) });
            return false;
        };
        debug_trace.logf("core", "file index generation started generation={d} caller_thread={d} from_cache={}", .{ generation_id, std.Thread.getCurrentId(), allow_cache });
        return true;
    }

    /// Reaps one terminal loader without waiting for incomplete work. Returns
    /// whether candidate or initial-status facts changed and need rendering.
    pub fn joinThreadIfDone(self: *FileIndex, alloc: Allocator) bool {
        const handle = self.thread orelse return false;
        const loading = self.loading_generation orelse return false;
        const terminal_state = loading.currentState();
        if (terminal_state == .loading) return false;

        handle.join();
        self.thread = null;
        debug_trace.logf("core", "file index generation joined generation={d} state={s}", .{ loading.id, @tagName(terminal_state) });

        var visible_changed = false;
        const adopted_from_cache = terminal_state == .ready and loading.from_cache;
        switch (terminal_state) {
            .loading => unreachable,
            .ready => {
                const previous = self.active_generation;
                self.active_generation = loading;
                self.loading_generation = null;
                self.initial_failed = false;
                debug_trace.logf("core", "file index generation adopted generation={d} count={d} from_cache={}", .{ loading.id, loading.count(), loading.from_cache });
                if (previous) |generation| generation.destroy(alloc);
                visible_changed = true;
            },
            .failed, .canceled => {
                self.loading_generation = null;
                if (self.active_generation == null and terminal_state == .failed) {
                    self.initial_failed = true;
                    visible_changed = true;
                }
                debug_trace.logf("core", "file index generation discarded generation={d} state={s}", .{ loading.id, @tagName(terminal_state) });
                loading.destroy(alloc);
            },
        }

        if (!self.stop_requested.load(.seq_cst)) {
            if (self.pending_scope) |pending| {
                self.pending_scope = null;
                freeRoots(alloc, self.roots);
                self.roots = pending.roots;
                self.scope_epoch = pending.epoch;
                _ = self.startLoad(alloc);
            }
        }
        // A cache-painted generation is a preview only: one real scan follows
        // it and replaces it, unless a pending scope already started that load.
        if (adopted_from_cache and
            !self.stop_requested.load(.seq_cst) and
            self.thread == null)
        {
            _ = self.startLoad(alloc);
        }
        return visible_changed;
    }

    /// Requests one replacement generation. A current loader retains its
    /// immutable scope and coalesces only the latest owned replacement scope.
    pub fn refresh(self: *FileIndex, alloc: Allocator) void {
        const epoch = if (self.pending_scope) |pending| pending.epoch else self.scope_epoch;
        const roots = cloneRoots(alloc, if (self.pending_scope) |pending| pending.roots else self.roots) catch |err| {
            debug_trace.logf("core", "file index refresh snapshot failed generation={d} err={s}", .{ self.generation, @errorName(err) });
            return;
        };
        self.refreshOwnedRoots(alloc, roots, epoch);
    }

    /// Refreshes from the latest active scope. A loading generation keeps its
    /// immutable roots and receives one owned, coalesced replacement snapshot.
    pub fn refreshScope(self: *FileIndex, alloc: Allocator, scope: workspace_access.AccessScope) void {
        self.refreshScopeEpoch(alloc, scope, 0);
    }

    pub fn refreshScopeEpoch(self: *FileIndex, alloc: Allocator, scope: workspace_access.AccessScope, epoch: u64) void {
        const roots = activeRootsAlloc(alloc, scope) catch |err| {
            debug_trace.logf("core", "file index scope snapshot failed generation={d} err={s}", .{ self.generation, @errorName(err) });
            return;
        };
        self.refreshOwnedRoots(alloc, roots, epoch);
    }

    fn refreshOwnedRoots(self: *FileIndex, alloc: Allocator, roots: [][]u8, epoch: u64) void {
        if (self.stop_requested.load(.seq_cst)) {
            freeRoots(alloc, roots);
            debug_trace.logf("core", "file index refresh discarded during shutdown generation={d}", .{self.generation});
            return;
        }
        if (self.thread != null) {
            self.replacePendingRoots(alloc, roots, epoch);
            return;
        }

        if (self.loading_generation != null) {
            freeRoots(alloc, roots);
            debug_trace.logf("core", "file index refresh discarded with unowned loading generation={d}", .{self.generation});
            return;
        }
        freeRoots(alloc, self.roots);
        self.roots = roots;
        self.scope_epoch = epoch;
        const started = self.startLoad(alloc);
        if (!started) debug_trace.logf("core", "file index refresh not started generation={d}", .{self.generation});
    }

    fn replacePendingRoots(self: *FileIndex, alloc: Allocator, roots: [][]u8, epoch: u64) void {
        if (self.pending_scope) |pending| {
            if (pending.epoch == epoch and rootsEqual(pending.roots, roots)) {
                freeRoots(alloc, roots);
                debug_trace.logf("core", "file index refresh coalesced generation={d} identical=true", .{self.generation});
                return;
            }
            freeRoots(alloc, pending.roots);
            debug_trace.logf("core", "file index pending refresh superseded generation={d}", .{self.generation});
        }
        self.pending_scope = .{ .roots = roots, .epoch = epoch };
        debug_trace.logf("core", "file index refresh coalesced generation={d} identical=false", .{self.generation});
    }

    pub fn isCurrentCandidateKind(self: *const FileIndex, path: []const u8, expected_kind: CandidateKind) bool {
        const current_roots = if (self.pending_scope) |pending| pending.roots else self.roots;
        if (!text_utils.isTerminalSafe(path) or current_roots.len == 0) return false;
        const root_path, const relative = if (std.Io.Dir.path.isAbsolute(path)) resolved: {
            for (current_roots) |root| {
                if (!pathing.pathInside(root, path)) continue;
                const rel = pathing.workspaceRelativePath(std.heap.c_allocator, root, path) catch return false;
                break :resolved .{ root, rel };
            }
            return false;
        } else .{ current_roots[0], path };
        defer if (std.Io.Dir.path.isAbsolute(path)) std.heap.c_allocator.free(relative);
        var root = std.Io.Dir.openDirAbsolute(io_mod.getIo(), root_path, .{}) catch return false;
        defer root.close(io_mod.getIo());
        const stat = root.statFile(io_mod.getIo(), relative, .{ .follow_symlinks = false }) catch return false;
        return candidateKindMatchesStat(expected_kind, stat.kind);
    }

    /// Builds a ready index synchronously from NUL- or newline-delimited paths.
    pub fn buildFromRaw(self: *FileIndex, alloc: Allocator, raw_list: []const u8) !void {
        try self.buildFromSource(alloc, .{ .file_raw = raw_list });
    }

    /// Build synchronously from typed candidates. Candidate paths are
    /// borrowed for this call and copied into the index. Repeated path-kind
    /// identities are retained once in their first input position.
    pub fn buildFromCandidates(self: *FileIndex, alloc: Allocator, candidates: []const Candidate) !void {
        const indices = try candidateIndicesAlloc(alloc, candidates);
        defer if (indices.len > 0) alloc.free(indices);
        try self.buildFromSource(alloc, .{ .typed = .{
            .candidates = candidates,
            .indices = indices,
        } });
    }

    /// Writes typed, ranked results into caller-owned output. Path bytes
    /// borrow this index generation; result records and `matched_spans` borrow
    /// the caller's buffers. Callers must disregard output after an error.
    pub fn searchTyped(
        self: *const FileIndex,
        query: []const u8,
        out: []SearchResult,
        match_spans: []MatchSpan,
    ) SearchError!usize {
        return self.searchAtRevision(self.readableRevision(), query, out, match_spans);
    }

    pub fn readableRevision(self: *const FileIndex) ReadableRevision {
        const generation = self.searchableGeneration() orelse return .{
            .scope_epoch = self.scope_epoch,
            .state = self.currentState(),
        };
        return .{
            .scope_epoch = generation.scope_epoch,
            .generation = generation.id,
            .count = generation.count(),
            .state = self.currentState(),
        };
    }

    /// Main-thread-only search of the captured prefix. Results retain the same
    /// borrowing contract as searchTyped; this revision is not a generation lease.
    pub fn searchAtRevision(
        self: *const FileIndex,
        revision: ReadableRevision,
        query: []const u8,
        out: []SearchResult,
        match_spans: []MatchSpan,
    ) SearchError!usize {
        if (out.len == 0 or revision.count == 0) return 0;
        const generation = self.searchableGeneration() orelse return error.InvalidIndexData;
        if (generation.id != revision.generation or generation.scope_epoch != revision.scope_epoch or
            revision.count > generation.kinds.len) return error.InvalidIndexData;
        const total = revision.count;
        if (query.len > max_path_len) return 0;

        if (query.len == 0) {
            const result_count = @min(total, out.len);
            for (out[0..result_count], 0..) |*result, index| {
                result.* = .{
                    .path = generation.pathAt(index),
                    .kind = generation.kindAt(index),
                    .matched_spans = match_spans[0..0],
                };
            }
            return result_count;
        }

        var query_scratch: QueryScratch = undefined;
        const prepared = prepareQuery(query, &query_scratch) orelse return 0;
        var indices: [max_search_results]u32 = undefined;
        var align_scratch: AlignScratch = undefined;
        const result_count = rankTopN(generation, total, prepared, indices[0..@min(out.len, max_search_results)], &align_scratch);

        var path_scratch: FoldedPathScratch = undefined;
        var matched_offsets: [max_path_len]u16 = undefined;
        var span_scratch: [max_path_len]MatchSpan = undefined;
        var spans_used: usize = 0;
        for (indices[0..result_count], 0..) |index, result_index| {
            const path = generation.pathAt(index);
            const base_start = generation.basename_starts[index] - generation.offsets[index];
            const span_count = reconstructMatchSpans(
                path,
                base_start,
                prepared.folded,
                &path_scratch,
                &align_scratch,
                &matched_offsets,
                &span_scratch,
            ) orelse return error.InvalidIndexData;
            if (span_count > match_spans.len -| spans_used) return error.NoSpaceLeft;
            @memcpy(match_spans[spans_used..][0..span_count], span_scratch[0..span_count]);
            out[result_index] = .{
                .path = path,
                .kind = generation.kindAt(index),
                .matched_spans = match_spans[spans_used..][0..span_count],
            };
            spans_used += span_count;
        }
        return result_count;
    }

    fn searchableGeneration(self: *const FileIndex) ?*const Generation {
        if (self.active_generation) |active| return active;
        const loading = self.loading_generation orelse return null;
        return switch (loading.currentState()) {
            .loading, .ready => loading,
            .failed, .canceled => null,
        };
    }

    fn pathAt(self: *const FileIndex, i: usize) []const u8 {
        return self.searchableGeneration().?.pathAt(i);
    }

    fn kindAt(self: *const FileIndex, i: usize) CandidateKind {
        return self.searchableGeneration().?.kindAt(i);
    }

    fn lowerPathAt(self: *const FileIndex, i: u32) []const u8 {
        return self.searchableGeneration().?.lowerPathAt(i);
    }

    fn buildFromSource(self: *FileIndex, alloc: Allocator, source: CandidateSource) !void {
        if (self.thread != null or self.loading_generation != null) return error.LoadInProgress;
        const generation_id = self.generation + 1;
        const generation = try Generation.create(alloc, generation_id);
        errdefer generation.destroy(alloc);
        try generation.fillProgressive(alloc, source, null);
        generation.finish(.ready);

        const previous = self.active_generation;
        self.active_generation = generation;
        self.generation = generation_id;
        self.initial_failed = false;
        if (previous) |active| active.destroy(alloc);
    }
};

const TypedCandidateSource = struct {
    candidates: []const Candidate,
    indices: ?[]const usize,
};

const CandidateSource = union(enum) {
    file_raw: []const u8,
    typed: TypedCandidateSource,

    fn iterator(self: CandidateSource) CandidateIterator {
        return switch (self) {
            .file_raw => |raw_list| .{ .file_raw = .{
                .separator = rawPathSeparator(raw_list),
                .iterator = std.mem.splitScalar(u8, raw_list, rawPathSeparator(raw_list)),
            } },
            .typed => |typed| .{ .typed = .{
                .candidates = typed.candidates,
                .indices = typed.indices,
            } },
        };
    }
};

const RawFileCandidateIterator = struct {
    separator: u8,
    iterator: std.mem.SplitIterator(u8, .scalar),

    fn next(self: *RawFileCandidateIterator) ?Candidate {
        while (self.iterator.next()) |raw| {
            const path = acceptedRawPath(self.separator, raw) orelse continue;
            return .{ .path = path, .kind = .file };
        }
        return null;
    }
};

const TypedCandidateIterator = struct {
    candidates: []const Candidate,
    indices: ?[]const usize,
    position: usize = 0,

    fn next(self: *TypedCandidateIterator) ?Candidate {
        const candidate_index = if (self.indices) |indices| index: {
            if (self.position >= indices.len) return null;
            break :index indices[self.position];
        } else index: {
            if (self.position >= self.candidates.len) return null;
            break :index self.position;
        };
        const candidate = self.candidates[candidate_index];
        self.position += 1;
        return candidate;
    }
};

const CandidateIterator = union(enum) {
    file_raw: RawFileCandidateIterator,
    typed: TypedCandidateIterator,

    fn next(self: *CandidateIterator) ?Candidate {
        return switch (self.*) {
            .file_raw => |*iterator| iterator.next(),
            .typed => |*iterator| iterator.next(),
        };
    }
};

fn candidateIndicesAlloc(alloc: Allocator, candidates: []const Candidate) ![]usize {
    var indices: std.ArrayList(usize) = .empty;
    errdefer indices.deinit(alloc);
    var seen: std.StringHashMapUnmanaged(u2) = .empty;
    defer seen.deinit(alloc);

    for (candidates, 0..) |candidate, index| {
        if (acceptedCandidate(candidate) == null) continue;
        if (indices.items.len >= max_indexed_files) break;

        const kind_mask: u2 = switch (candidate.kind) {
            .file => 0b01,
            .directory => 0b10,
        };
        const entry = try seen.getOrPut(alloc, candidate.path);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        if ((entry.value_ptr.* & kind_mask) != 0) continue;
        entry.value_ptr.* |= kind_mask;
        try indices.append(alloc, index);
    }

    return indices.toOwnedSlice(alloc);
}

fn candidateKindMatchesStat(expected: CandidateKind, actual: std.Io.File.Kind) bool {
    return switch (expected) {
        .file => actual == .file or actual == .sym_link,
        .directory => actual == .directory,
    };
}

fn loaderThreadMain(
    generation: *Generation,
    alloc: Allocator,
    roots: []const []const u8,
    stop_requested: *std.atomic.Value(bool),
    allow_cache: bool,
) void {
    debug_trace.logf("core", "file index loader entered generation={d} worker_thread={d}", .{ generation.id, std.Thread.getCurrentId() });
    const outcome = loadGeneration(generation, alloc, roots, stop_requested, allow_cache);
    publishLoaderOutcomeAfterCleanup(generation, outcome);
}

fn loadGeneration(
    generation: *Generation,
    alloc: Allocator,
    roots: []const []const u8,
    stop_requested: *std.atomic.Value(bool),
    allow_cache: bool,
) LoaderOutcome {
    if (isStopRequested(stop_requested)) return .canceled;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const snapshot_path = snapshotPath(arena, roots) catch |err| return .{ .failed = .{ .stage = .discovery, .err = err } };
    var previous = if (snapshot_path) |path|
        indexer.loadSnapshot(alloc, path, roots) catch |err| return .{ .failed = .{ .stage = .discovery, .err = err } }
    else
        null;
    defer if (previous) |*snapshot| snapshot.deinit();

    if (allow_cache) {
        if (previous) |*snapshot| {
            const candidates = candidatesFromTrees(arena, roots, snapshot.trees, stop_requested) catch |err| {
                if (err == error.Canceled or isStopRequested(stop_requested)) return .canceled;
                return .{ .failed = .{ .stage = .discovery, .err = err } };
            };
            generation.from_cache = true;
            generation.fillProgressive(alloc, .{ .typed = .{
                .candidates = candidates,
                .indices = null,
            } }, stop_requested) catch |err| {
                if (err == error.Canceled or isStopRequested(stop_requested)) return .canceled;
                return .{ .failed = .{ .stage = .storage, .err = err } };
            };
            if (isStopRequested(stop_requested)) return .canceled;
            debug_trace.logf("core", "file index cache painted generation={d} count={d}", .{ generation.id, generation.count() });
            return .ready;
        }
    }

    var refreshed = refreshTrees(alloc, roots, if (previous) |*snapshot| snapshot.trees else &.{}, stop_requested) catch |err| {
        if (err == error.Canceled or isStopRequested(stop_requested)) return .canceled;
        return .{ .failed = .{ .stage = .discovery, .err = err } };
    };
    defer refreshed.deinit(alloc);

    // Persist before the fill so even a canceled publish leaves a warm
    // snapshot. A scope with an unavailable root is not saved, so its next
    // load scans again.
    if (snapshot_path) |path| {
        if (refreshed.scans.len > 0 and refreshed.trees.len == roots.len) {
            indexer.saveSnapshot(arena, path, refreshed.trees) catch |err| {
                debug_trace.logf("core", "file index cache not saved generation={d} err={s}", .{ generation.id, @errorName(err) });
            };
        }
    }

    const candidates = candidatesFromTrees(arena, roots, refreshed.trees, stop_requested) catch |err| {
        if (err == error.Canceled or isStopRequested(stop_requested)) return .canceled;
        return .{ .failed = .{ .stage = .discovery, .err = err } };
    };
    generation.fillProgressive(alloc, .{ .typed = .{
        .candidates = candidates,
        .indices = null,
    } }, stop_requested) catch |err| {
        if (err == error.Canceled or isStopRequested(stop_requested)) return .canceled;
        return .{ .failed = .{ .stage = .storage, .err = err } };
    };
    if (isStopRequested(stop_requested)) return .canceled;
    return .ready;
}

/// `<home>/.fx/file-index/<sha256>.idx`, or null without an absolute home
/// directory. The digest covers the roots and every variable that locates git
/// config, so a listing built under one config is never reused under another.
pub fn snapshotPath(alloc: Allocator, roots: []const []const u8) Allocator.Error!?[]const u8 {
    const home = io_mod.homeDir() orelse return null;
    if (!std.Io.Dir.path.isAbsolute(home)) return null;
    var config_environment: [indexer.config_environment_names.len]?[]const u8 = undefined;
    for (indexer.config_environment_names, &config_environment) |name, *value| value.* = io_mod.getenv(name);
    return try snapshotPathIn(alloc, home, roots, &config_environment);
}

fn snapshotPathIn(
    alloc: Allocator,
    home: []const u8,
    roots: []const []const u8,
    config_environment: []const ?[]const u8,
) Allocator.Error![]const u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update(&rootsDigest(roots));
    for (config_environment) |value| {
        if (value) |bytes| {
            digest.update(&.{1});
            digest.update(bytes);
            digest.update(&.{0});
        } else digest.update(&.{0});
    }
    var sum: [sha256_digest_len]u8 = undefined;
    digest.final(&sum);
    const hex = std.fmt.bytesToHex(sum, .lower);
    return alloc.print("{s}/.fx/file-index/{s}.idx", .{ home, &hex });
}

/// The trees for the available roots of a scope, in root order. Trees reused
/// from a snapshot borrow its memory; `scans` owns the rest.
const RefreshedTrees = struct {
    trees: []indexer.Tree,
    scans: []indexer.ScanResult,

    fn deinit(self: *RefreshedTrees, alloc: Allocator) void {
        for (self.scans) |*result| result.deinit();
        alloc.free(self.scans);
        alloc.free(self.trees);
        self.* = undefined;
    }
};

/// Reuses each saved tree that is still current and scans every other root.
/// `previous` is empty or holds one tree per root in order. An unavailable
/// root is left out; a scope with no available root fails.
fn refreshTrees(
    alloc: Allocator,
    roots: []const []const u8,
    previous: []const indexer.Tree,
    stop_requested: *std.atomic.Value(bool),
) (indexer.ScanError || error{FileNotFound})!RefreshedTrees {
    std.debug.assert(previous.len == 0 or previous.len == roots.len);
    var trees: std.ArrayList(indexer.Tree) = .empty;
    defer trees.deinit(alloc);
    var scans: std.ArrayList(indexer.ScanResult) = .empty;
    defer {
        for (scans.items) |*result| result.deinit();
        scans.deinit(alloc);
    }
    try trees.ensureTotalCapacity(alloc, roots.len);
    try scans.ensureTotalCapacity(alloc, roots.len);

    for (roots, 0..) |root, root_index| {
        if (isStopRequested(stop_requested)) return error.Canceled;
        if (previous.len > 0 and indexer.isCurrent(&previous[root_index], root, &indexer.default_skipped_names, null)) {
            debug_trace.logf("core", "file index root reused root={d} entries={d} thread={d}", .{ root_index, previous[root_index].entries.len, std.Thread.getCurrentId() });
            trees.appendAssumeCapacity(previous[root_index]);
            continue;
        }
        const result = indexer.scan(alloc, root, .{ .candidate_cap = max_indexed_files }, stop_requested) catch |err| switch (err) {
            error.RootUnavailable => {
                debug_trace.logf("core", "file index root discovery omitted root={d} err={s}", .{ root_index, @errorName(err) });
                continue;
            },
            else => |e| return e,
        };
        scans.appendAssumeCapacity(result);
        trees.appendAssumeCapacity(result.tree);
        debug_trace.logf("core", "file index root scanned root={d} entries={d} incomplete={} thread={d}", .{ root_index, result.tree.entries.len, result.tree.incomplete, std.Thread.getCurrentId() });
    }
    if (trees.items.len == 0 and roots.len > 0) return error.FileNotFound;

    const owned_trees = try trees.toOwnedSlice(alloc);
    errdefer alloc.free(owned_trees);
    return .{ .trees = owned_trees, .scans = try scans.toOwnedSlice(alloc) };
}

/// Converts trees into candidates in root order: primary-root paths stay
/// relative, added-root paths become absolute, overlapping roots appear once,
/// and at most `max_indexed_files` are kept. Paths may borrow tree memory.
fn candidatesFromTrees(
    arena: Allocator,
    roots: []const []const u8,
    trees: []const indexer.Tree,
    stop_requested: *std.atomic.Value(bool),
) (Allocator.Error || error{Canceled})![]const Candidate {
    if (trees.len == 1 and roots.len > 0 and std.mem.eql(u8, trees[0].root, roots[0])) {
        return primaryTreeCandidates(arena, &trees[0], stop_requested);
    }
    var candidates: std.ArrayList(Candidate) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (trees) |*tree| {
        const root_index: usize = if (roots.len > 0 and std.mem.eql(u8, tree.root, roots[0])) 0 else 1;
        for (tree.entries) |entry| {
            if (isStopRequested(stop_requested)) return error.Canceled;
            if (candidates.items.len >= max_indexed_files) return candidates.toOwnedSlice(arena);
            if (!isPlainRelativePath(entry.path)) continue;
            if (!text_utils.isTerminalSafe(entry.path)) {
                debug_trace.logf("core", "file index omitted unsafe candidate bytes={d} kind={s}", .{ entry.path.len, @tagName(entry.kind) });
                continue;
            }
            const kind: CandidateKind = switch (entry.kind) {
                .file => .file,
                .directory => .directory,
            };
            _ = try appendDiscoveredCandidate(arena, &candidates, &seen, tree.root, root_index, entry.path, kind);
        }
    }
    return candidates.toOwnedSlice(arena);
}

/// The primary root alone: its entries are unique and already relative, so
/// each one is checked once and kept as is, with no absolute path or
/// overlap check per entry. This runs on every `@` paint.
fn primaryTreeCandidates(
    arena: Allocator,
    tree: *const indexer.Tree,
    stop_requested: *std.atomic.Value(bool),
) (Allocator.Error || error{Canceled})![]const Candidate {
    var candidates: std.ArrayList(Candidate) = .empty;
    try candidates.ensureTotalCapacity(arena, @min(tree.entries.len, max_indexed_files));
    for (tree.entries) |entry| {
        if (isStopRequested(stop_requested)) return error.Canceled;
        if (candidates.items.len >= max_indexed_files) break;
        if (!isPlainRelativePath(entry.path)) continue;
        if (!text_utils.isTerminalSafe(entry.path)) {
            debug_trace.logf("core", "file index omitted unsafe candidate bytes={d} kind={s}", .{ entry.path.len, @tagName(entry.kind) });
            continue;
        }
        const kind: CandidateKind = switch (entry.kind) {
            .file => .file,
            .directory => .directory,
        };
        const accepted = acceptedSafeCandidate(.{ .path = entry.path, .kind = kind }) orelse continue;
        candidates.appendAssumeCapacity(accepted);
    }
    return candidates.toOwnedSlice(arena);
}

/// A relative `/`-separated path that stays inside its root and avoids
/// `.git`: no empty, `.`, `..` or `.git` component.
fn isPlainRelativePath(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".git")) return false;
    }
    return true;
}

/// Publishes the loader's terminal outcome only after its caller has released
/// every worker-owned temporary. The release store is deliberately the final
/// action so an acquire observer may join without waiting for worker cleanup.
fn publishLoaderOutcomeAfterCleanup(generation: *Generation, outcome: LoaderOutcome) void {
    switch (outcome) {
        .ready => debug_trace.logf("core", "file index generation ready generation={d} count={d} worker_cleanup=complete", .{ generation.id, generation.count() }),
        .failed => |failure| debug_trace.logf("core", "file index generation failed generation={d} stage={s} err={s} worker_cleanup=complete", .{ generation.id, @tagName(failure.stage), @errorName(failure.err) }),
        .canceled => debug_trace.logf("core", "file index generation canceled generation={d} worker_cleanup=complete", .{generation.id}),
    }
    generation.finish(outcome.terminalState());
}

fn activeRootsAlloc(alloc: Allocator, scope: workspace_access.AccessScope) ![][]u8 {
    var roots: std.ArrayList([]u8) = .empty;
    errdefer {
        for (roots.items) |root| alloc.free(root);
        roots.deinit(alloc);
    }

    try roots.append(alloc, try alloc.dupe(u8, scope.primary_directory));
    for (scope.additional_directories) |entry| {
        if (!entry.active) continue;
        var duplicate = false;
        for (roots.items) |root| {
            if (std.mem.eql(u8, root, entry.path)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) try roots.append(alloc, try alloc.dupe(u8, entry.path));
    }
    return roots.toOwnedSlice(alloc);
}

fn cloneRoots(alloc: Allocator, source: []const []const u8) ![][]u8 {
    var roots: std.ArrayList([]u8) = .empty;
    errdefer {
        for (roots.items) |root| alloc.free(root);
        roots.deinit(alloc);
    }
    for (source) |root| try roots.append(alloc, try alloc.dupe(u8, root));
    return roots.toOwnedSlice(alloc);
}

fn freeRoots(alloc: Allocator, roots: []const []u8) void {
    for (roots) |root| alloc.free(root);
    if (roots.len > 0) alloc.free(roots);
}

fn rootsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn appendDiscoveredCandidate(
    alloc: Allocator,
    candidates: *std.ArrayList(Candidate),
    seen: *std.StringHashMapUnmanaged(void),
    root_path: []const u8,
    root_index: usize,
    relative: []const u8,
    kind: CandidateKind,
) !bool {
    const absolute = try std.Io.Dir.path.resolveAlloc(alloc, &.{ root_path, relative });
    if (!pathing.pathInside(root_path, absolute)) return false;

    const display = if (root_index == 0) relative else absolute;
    if (acceptedCandidate(.{ .path = display, .kind = kind }) == null) return false;

    const seen_entry = try seen.getOrPut(alloc, absolute);
    if (seen_entry.found_existing) return false;
    try candidates.append(alloc, .{ .path = display, .kind = kind });
    return true;
}

fn isStopRequested(stop_requested: ?*std.atomic.Value(bool)) bool {
    return if (stop_requested) |flag| flag.load(.seq_cst) else false;
}

const RawTotals = struct {
    /// Number of entries in `raw_list` that pass the filters and fit under
    /// `max_indexed_files`.
    n: u32,
    /// Sum of byte lengths of every kept path. The loader pre-allocates
    /// `paths_buf` and `lower_buf` to exactly this size.
    bytes: u32,
};

fn rawPathSeparator(raw_list: []const u8) u8 {
    return if (std.mem.findScalar(u8, raw_list, 0) != null) 0 else '\n';
}

fn acceptedRawPath(sep: u8, raw: []const u8) ?[]const u8 {
    const path = if (sep == '\n') std.mem.trimEnd(u8, raw, "\r") else raw;
    if (path.len == 0) return null;
    if (path.len > max_path_len) return null;
    if (!text_utils.isTerminalSafe(path)) return null;
    return path;
}

fn acceptedCandidate(candidate: Candidate) ?Candidate {
    if (!text_utils.isTerminalSafe(candidate.path)) return null;
    return acceptedSafeCandidate(candidate);
}

/// `acceptedCandidate` for a path already known to be terminal-safe.
fn acceptedSafeCandidate(candidate: Candidate) ?Candidate {
    if (candidate.path.len == 0) return null;
    if (candidate.path.len > max_path_len) return null;
    if (!file_picker_path.isRepresentable(candidate.path)) return null;
    if (candidate.kind == .directory and std.Io.Dir.path.isSep(candidate.path[candidate.path.len - 1])) return null;
    return candidate;
}

/// Applies fill-pass filters to size generation buffers before publication.
fn countAndSize(source: CandidateSource) RawTotals {
    var n: u32 = 0;
    var bytes: u32 = 0;

    var iter = source.iterator();
    while (iter.next()) |candidate| {
        const accepted = acceptedCandidate(candidate) orelse continue;
        if (n >= max_indexed_files) break;

        n += 1;
        bytes += @intCast(accepted.path.len);
    }

    return .{ .n = n, .bytes = bytes };
}

/// Returns an a-z presence bitmap. Non-ASCII input cannot cause false rejection.
fn alphaMask(bytes: []const u8) u32 {
    var m: u32 = 0;
    for (bytes) |b| {
        const lower = asciiToLower(b);
        if (lower >= 'a' and lower <= 'z') {
            m |= @as(u32, 1) << @intCast(lower - 'a');
        }
    }
    return m;
}

const non_ascii_mask: u32 = @as(u32, 1) << 31;
pub const max_search_results: usize = 64;

fn asciiToLower(b: u8) u8 {
    return if (b >= 'A' and b <= 'Z') b + 32 else b;
}

fn foldUtf8Into(bytes: []const u8, out: []u21) ?[]const u21 {
    var byte_index: usize = 0;
    var scalar_index: usize = 0;
    while (byte_index < bytes.len) {
        if (scalar_index >= out.len) return null;
        const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[byte_index]) catch return null;
        const end = byte_index + sequence_len;
        if (end > bytes.len) return null;
        const codepoint = display_width.decodeUtf8Sequence(bytes[byte_index..end]) catch return null;
        out[scalar_index] = unicode_simple_fold.fold(codepoint);
        scalar_index += 1;
        byte_index = end;
    }
    return out[0..scalar_index];
}

const QueryScratch = struct {
    folded: [max_path_len]u21,
    ascii: [max_path_len]u8,
};

const PreparedQuery = struct {
    folded: []const u21,
    ascii: ?[]const u8,
};

fn prepareQuery(query: []const u8, scratch: *QueryScratch) ?PreparedQuery {
    const folded = foldUtf8Into(query, &scratch.folded) orelse return null;
    for (folded, 0..) |scalar, index| {
        if (scalar > 0x7f) return .{ .folded = folded, .ascii = null };
        scratch.ascii[index] = @intCast(scalar);
    }
    return .{ .folded = folded, .ascii = scratch.ascii[0..folded.len] };
}

const FoldedPathScratch = struct {
    scalars: [max_path_len]u21,
    byte_offsets: [max_path_len + 1]u16,
};

const DecodedFoldedPath = struct {
    scalar_count: usize,
    basename_scalar_start: usize,
};

fn decodeFoldedPath(
    path: []const u8,
    basename_byte_start: usize,
    scratch: *FoldedPathScratch,
) ?DecodedFoldedPath {
    var byte_index: usize = 0;
    var scalar_index: usize = 0;
    var basename_scalar_start: ?usize = null;
    while (byte_index < path.len) {
        if (byte_index == basename_byte_start) basename_scalar_start = scalar_index;
        const sequence_len = std.unicode.utf8ByteSequenceLength(path[byte_index]) catch return null;
        const end = byte_index + sequence_len;
        if (end > path.len or scalar_index >= scratch.scalars.len) return null;
        const codepoint = display_width.decodeUtf8Sequence(path[byte_index..end]) catch return null;
        scratch.byte_offsets[scalar_index] = std.math.cast(u16, byte_index) orelse return null;
        scratch.scalars[scalar_index] = unicode_simple_fold.fold(codepoint);
        scalar_index += 1;
        byte_index = end;
    }
    if (byte_index == basename_byte_start) basename_scalar_start = scalar_index;
    scratch.byte_offsets[scalar_index] = std.math.cast(u16, path.len) orelse return null;
    return .{
        .scalar_count = scalar_index,
        .basename_scalar_start = basename_scalar_start orelse return null,
    };
}

const MatchScore = struct {
    exact_fit: bool,
    /// The scored placement ends in the file or folder name rather than in a
    /// parent folder.
    name_fit: bool,
    /// Additive score of the chosen placement, including `name_bonus` when it
    /// lies inside the name.
    quality: i32,
    /// Scalar index of the first matched character, relative to the scored range.
    first_position: u32,
};

/// Owns its prepared query without interior pointers. Names are borrowed only
/// during each call; scoring and highlighting share the indexed-search rules.
pub const NameQuery = struct {
    scratch: QueryScratch,
    len: usize,
    ascii: bool,
    ascii_mask: u32,

    pub const Score = MatchScore;

    pub fn init(query: []const u8) ?NameQuery {
        if (query.len > max_path_len) return null;
        var result: NameQuery = undefined;
        const prepared = prepareQuery(query, &result.scratch) orelse return null;
        result.len = prepared.folded.len;
        result.ascii = prepared.ascii != null;
        result.ascii_mask = if (prepared.ascii) |bytes| alphaMask(bytes) else 0;
        return result;
    }

    pub fn score(self: *const NameQuery, name: []const u8) ?Score {
        if (name.len == 0 or name.len > max_path_len) return null;
        if (self.len == 0) return .{ .exact_fit = false, .name_fit = false, .quality = 0, .first_position = 0 };
        var align_scratch: AlignScratch = undefined;
        for (name) |byte| {
            if (byte >= 0x80) {
                var scratch: FoldedPathScratch = undefined;
                return scoreFoldedMatchWith(&align_scratch, name, 0, self.scratch.folded[0..self.len], &scratch, .{});
            }
        }
        if (!self.ascii or alphaMask(name) & self.ascii_mask != self.ascii_mask) return null;
        var lower: [max_path_len]u8 = undefined;
        for (name, lower[0..name.len]) |byte, *folded| folded.* = asciiToLower(byte);
        return scoreAsciiMatchWith(&align_scratch, name, lower[0..name.len], 0, self.scratch.ascii[0..self.len], .{});
    }

    pub fn better(self: *const NameQuery, left: Score, left_path: []const u8, right: Score, right_path: []const u8) bool {
        if (self.len > 0) {
            if (scoreBetter(left, right)) return true;
            if (scoreBetter(right, left)) return false;
            if (left_path.len != right_path.len) return left_path.len < right_path.len;
        }
        return std.mem.order(u8, left_path, right_path) == .lt;
    }

    /// Writes name-relative byte spans into caller-owned storage.
    pub fn match_spans(self: *const NameQuery, name: []const u8, out: []MatchSpan) SearchError!usize {
        if (self.len == 0) return 0;
        var scratch: FoldedPathScratch = undefined;
        var align_scratch: AlignScratch = undefined;
        var offsets: [max_path_len]u16 = undefined;
        var spans: [max_path_len]MatchSpan = undefined;
        const count = reconstructMatchSpans(name, 0, self.scratch.folded[0..self.len], &scratch, &align_scratch, &offsets, &spans) orelse return error.InvalidIndexData;
        if (count > out.len) return error.NoSpaceLeft;
        @memcpy(out[0..count], spans[0..count]);
        return count;
    }
};

const RankedCandidate = struct {
    score: MatchScore,
    index: u32,
};

fn rankTopN(generation: *const Generation, total: usize, query: PreparedQuery, out: []u32, align_scratch: *AlignScratch) usize {
    const top_cap = @min(out.len, max_search_results);
    if (top_cap == 0) return 0;

    var ranked: [max_search_results]RankedCandidate = undefined;
    var filled: usize = 0;
    var worst_slot: usize = 0;

    const query_ascii = query.ascii;
    const query_mask = if (query_ascii) |ascii| alphaMask(ascii) else 0;
    const max_crossing = maxCrossingQuality(u21, query.folded);
    const max_name = maxNameQuality(query.folded.len);
    var scalar_scratch: FoldedPathScratch = undefined;

    var candidate_index: u32 = 0;
    while (candidate_index < total) : (candidate_index += 1) {
        const path_mask = generation.char_masks[candidate_index];
        const base_start = generation.basename_starts[candidate_index] - generation.offsets[candidate_index];
        // Once the worst kept result has the best score a non-exact match can
        // reach, only an exact match or a shorter path can still enter, so
        // longer paths are not scored. Once every kept result is exact, only
        // exact matches can enter.
        const length_limit: ?usize = if (filled < top_cap) null else limit: {
            const worst = ranked[worst_slot];
            if (worst.score.exact_fit) break :limit 0;
            if (worst.score.name_fit and worst.score.quality == max_name and worst.score.first_position == 0) {
                break :limit generation.pathAt(worst.index).len;
            }
            break :limit null;
        };
        // Skip the placements that can no longer enter the kept results; the
        // results stay those of scoring every path.
        const needed: Needed = if (filled < top_cap) .{} else needed: {
            const worst = ranked[worst_slot].score;
            break :needed .{
                // A placement ending in a folder ranks below every name match.
                .folder = !(worst.exact_fit or worst.name_fit),
                // A placement starting in a folder scores at most `max_crossing`.
                .crossing = !(worst.exact_fit or (worst.name_fit and worst.quality > max_crossing)),
            };
        };
        const score = if ((path_mask & non_ascii_mask) == 0) ascii_path: {
            const ascii = query_ascii orelse continue;
            if ((path_mask & query_mask) != query_mask) continue;
            if (length_limit) |limit| {
                const path_lower = generation.lowerPathAt(candidate_index);
                if (path_lower.len > limit and !exactFit(u8, path_lower, path_lower[base_start..], ascii)) continue;
            }
            break :ascii_path scoreAsciiMatchWith(
                align_scratch,
                generation.pathAt(candidate_index),
                generation.lowerPathAt(candidate_index),
                base_start,
                ascii,
                needed,
            );
        } else scoreFoldedMatchWith(align_scratch, generation.pathAt(candidate_index), base_start, query.folded, &scalar_scratch, needed);
        const match_score = score orelse continue;
        const candidate: RankedCandidate = .{ .score = match_score, .index = candidate_index };

        if (filled < top_cap) {
            ranked[filled] = candidate;
            filled += 1;
            if (filled == top_cap) worst_slot = findWorstSlot(generation, ranked[0..filled]);
        } else if (rankedCandidateBetter(generation, candidate, ranked[worst_slot])) {
            ranked[worst_slot] = candidate;
            worst_slot = findWorstSlot(generation, ranked[0..filled]);
        }
    }

    sortRanked(generation, ranked[0..filled]);
    for (ranked[0..filled], 0..) |candidate, result_index| out[result_index] = candidate.index;
    return filled;
}

// Best-alignment scoring with fzf's v2 path-scheme score. A placement's score
// is defined by `scoreAlignment`; `alignBest` returns the placement with the
// highest score and, among those, the earliest first position. The dynamic
// program is exact because its state carries the run bonus that fzf's
// consecutive rule depends on, normalized to one of four values.
const max_align_cells: usize = 4096;
const run_slot_count: usize = 4;
const run_slot_bonus = [run_slot_count]i32{ 4, 7, 8, 9 };
const score_match: i32 = 16;
const score_gap_start: i32 = -3;
const score_gap_extension: i32 = -1;
const bonus_boundary: i32 = score_match / 2;
const bonus_non_word: i32 = score_match / 2;
const bonus_camel_123: i32 = bonus_boundary + score_gap_extension;
const bonus_consecutive: i32 = -(score_gap_start + score_gap_extension);
const bonus_first_char_multiplier: i32 = 2;
const bonus_boundary_white: i32 = bonus_boundary;
const bonus_boundary_delimiter: i32 = bonus_boundary + 1;
const invalid_score: i32 = std.math.minInt(i32);

/// One search's alignment workspace. Callers create it once and reuse it for
/// every candidate; nothing in it survives between calls.
const AlignScratch = struct {
    scores: [max_align_cells * run_slot_count]i32,
    starts: [max_align_cells * run_slot_count]u16,
    pred_entries: [max_align_cells * run_slot_count]u16,
    pred_slots: [max_align_cells * run_slot_count]u8,
    /// Text position of each sparse cell, row by row.
    columns: [max_align_cells]u16,
    row_offsets: [max_path_len + 1]u16,
    forward: [max_path_len]u16,
    backward: [max_path_len]u16,
    positions: [max_path_len]u16,
};

const Alignment = struct {
    quality: i32,
    first_position: u32,
};

const CharClass = enum { white, non_word, delimiter, lower, upper, letter, number };

fn charClassOf(byte: u8) CharClass {
    return switch (byte) {
        'a'...'z' => .lower,
        'A'...'Z' => .upper,
        '0'...'9' => .number,
        ' ', '\t', '\n', '\r' => .white,
        '/' => .delimiter,
        0x80...0xff => .letter,
        else => .non_word,
    };
}

fn bonusFor(prev: CharClass, class: CharClass) i32 {
    switch (class) {
        .lower, .upper, .letter, .number => switch (prev) {
            .white => return bonus_boundary_white,
            .delimiter => return bonus_boundary_delimiter,
            .non_word => return bonus_boundary,
            else => {},
        },
        else => {},
    }
    if ((prev == .lower and class == .upper) or (prev != .number and class == .number)) return bonus_camel_123;
    return switch (class) {
        .non_word, .delimiter => bonus_non_word,
        .white => bonus_boundary_white,
        else => 0,
    };
}

fn bonusAt(path: []const u8, byte_offsets: ?[]const u16, position: usize) i32 {
    const byte_index: usize = if (byte_offsets) |offsets| offsets[position] else position;
    const prev: CharClass = if (byte_index == 0) .delimiter else charClassOf(path[byte_index - 1]);
    return bonusFor(prev, charClassOf(path[byte_index]));
}

fn runSlot(run_bonus: i32) usize {
    return switch (@max(run_bonus, bonus_consecutive)) {
        4 => 0,
        7 => 1,
        8 => 2,
        9 => 3,
        else => unreachable,
    };
}

fn consecutiveBonus(bonus: i32, run_bonus: i32) struct { bonus: i32, run: i32 } {
    if (bonus >= bonus_boundary and bonus > run_bonus) return .{ .bonus = bonus, .run = bonus };
    return .{ .bonus = @max(bonus, @max(run_bonus, bonus_consecutive)), .run = run_bonus };
}

/// Pure: the score of one fixed placement. This defines the ranking score.
fn scoreAlignment(path: []const u8, byte_offsets: ?[]const u16, range_start: usize, positions: []const u16) Alignment {
    var total: i32 = 0;
    var run: i32 = 0;
    for (positions, 0..) |position, index| {
        const bonus = bonusAt(path, byte_offsets, position);
        if (index == 0) {
            total = score_match + bonus * bonus_first_char_multiplier;
            run = bonus;
            continue;
        }
        const previous = positions[index - 1];
        if (position == previous + 1) {
            const step = consecutiveBonus(bonus, run);
            total += score_match + step.bonus;
            run = step.run;
        } else {
            const gap: i32 = @intCast(position - previous - 1);
            total += score_match + bonus + score_gap_start + (gap - 1) * score_gap_extension;
            run = bonus;
        }
    }
    return .{ .quality = total, .first_position = @intCast(positions[0] - range_start) };
}

inline fn betterCandidate(score: i32, start: u16, best_score: i32, best_start: u16) bool {
    return score > best_score or (score == best_score and start < best_start);
}

/// Pure: finds the best placement of `query` in `text[range_start..]` whose
/// last letter lands at or after `end_min`, and writes its text positions to
/// `scratch.positions[0..query.len]`. When the search would need more than
/// `max_align_cells` cells, the leftmost greedy such placement is scored
/// instead.
fn alignBest(
    comptime T: type,
    text: []const T,
    path: []const u8,
    byte_offsets: ?[]const u16,
    range_start: usize,
    end_min: usize,
    query: []const T,
    scratch: *AlignScratch,
) ?Alignment {
    const m = query.len;
    if (m == 0 or range_start > text.len or m > text.len - range_start) return null;
    std.debug.assert(end_min >= range_start);

    if (m == 1 and text.len - end_min <= max_align_cells) {
        // The earliest occurrence with the highest bonus, in one scan: the
        // window fits the cell budget, and no bonus beats the one after `/`.
        var best_position: ?usize = null;
        var best_bonus: i32 = 0;
        var j = end_min;
        while (j < text.len) : (j += 1) {
            if (text[j] != query[0]) continue;
            const bonus = bonusAt(path, byte_offsets, j);
            if (best_position == null or bonus > best_bonus) {
                best_position = j;
                best_bonus = bonus;
                if (bonus == bonus_boundary_delimiter) break;
            }
        }
        const only = best_position orelse return null;
        scratch.positions[0] = @intCast(only);
        return .{ .quality = score_match + best_bonus * bonus_first_char_multiplier, .first_position = @intCast(only - range_start) };
    }

    var query_index: usize = 0;
    var position = range_start;
    while (position < text.len and query_index < m) : (position += 1) {
        if (text[position] != query[query_index]) continue;
        scratch.forward[query_index] = @intCast(position);
        query_index += 1;
    }
    if (query_index < m) return null;

    var back_index: usize = m;
    var back_position: usize = text.len;
    while (back_index > 0) {
        back_position -= 1;
        if (text[back_position] != query[back_index - 1]) continue;
        back_index -= 1;
        scratch.backward[back_index] = @intCast(back_position);
    }
    if (scratch.backward[m - 1] < end_min) return null;
    if (scratch.forward[m - 1] < end_min) {
        // Still after forward[m - 2], which lies before the old forward[m - 1].
        var last = end_min;
        while (text[last] != query[m - 1]) last += 1;
        scratch.forward[m - 1] = @intCast(last);
    }

    // Both greedy scans agree only when a single placement exists.
    if (std.mem.eql(u16, scratch.forward[0..m], scratch.backward[0..m])) {
        @memcpy(scratch.positions[0..m], scratch.forward[0..m]);
        return scoreAlignment(path, byte_offsets, range_start, scratch.positions[0..m]);
    }

    // Row r may only place query[r] in forward[r]..backward[r]. The cell budget
    // is defined on those window widths.
    var cells: usize = 0;
    for (scratch.forward[0..m], scratch.backward[0..m]) |first, last| cells += @as(usize, last) - first + 1;
    if (cells > max_align_cells) {
        @memcpy(scratch.positions[0..m], scratch.forward[0..m]);
        return scoreAlignment(path, byte_offsets, range_start, scratch.positions[0..m]);
    }

    // Sparse rows: one cell per position where query[r] matches inside its window.
    var entries: usize = 0;
    for (0..m) |row| {
        scratch.row_offsets[row] = @intCast(entries);
        var j: usize = scratch.forward[row];
        while (j <= scratch.backward[row]) : (j += 1) {
            if (text[j] != query[row]) continue;
            scratch.columns[entries] = @intCast(j);
            entries += 1;
        }
    }
    scratch.row_offsets[m] = @intCast(entries);

    for (0..m) |row| {
        const row_begin: usize = scratch.row_offsets[row];
        const row_end: usize = scratch.row_offsets[row + 1];
        const prev_begin: usize = if (row > 0) scratch.row_offsets[row - 1] else 0;
        const prev_end: usize = if (row > 0) scratch.row_offsets[row] else 0;
        var best_gap: i32 = invalid_score;
        var best_gap_start: u16 = 0;
        var best_gap_entry: u16 = 0;
        var best_gap_slot: u8 = 0;
        var next_gap = prev_begin;
        var diag = prev_begin;

        for (row_begin..row_end) |entry| {
            const j: usize = scratch.columns[entry];
            const cell = entry * run_slot_count;
            @memset(scratch.scores[cell..][0..run_slot_count], invalid_score);
            const bonus = bonusAt(path, byte_offsets, j);
            if (row == 0) {
                const slot = runSlot(bonus);
                scratch.scores[cell + slot] = score_match + bonus * bonus_first_char_multiplier;
                scratch.starts[cell + slot] = @intCast(j);
                continue;
            }
            // Fold in every predecessor at least two positions back.
            while (next_gap < prev_end and @as(usize, scratch.columns[next_gap]) + 2 <= j) : (next_gap += 1) {
                const prev_cell = next_gap * run_slot_count;
                const shift: i32 = scratch.columns[next_gap];
                for (0..run_slot_count) |slot| {
                    const value = scratch.scores[prev_cell + slot];
                    if (value == invalid_score) continue;
                    const start = scratch.starts[prev_cell + slot];
                    if (betterCandidate(value + shift, start, best_gap, best_gap_start)) {
                        best_gap = value + shift;
                        best_gap_start = start;
                        best_gap_entry = @intCast(next_gap);
                        best_gap_slot = @intCast(slot);
                    }
                }
            }
            while (diag < prev_end and @as(usize, scratch.columns[diag]) + 1 < j) diag += 1;
            if (diag < prev_end and @as(usize, scratch.columns[diag]) + 1 == j) {
                const prev_cell = diag * run_slot_count;
                for (0..run_slot_count) |prev_slot| {
                    const value = scratch.scores[prev_cell + prev_slot];
                    if (value == invalid_score) continue;
                    const step = consecutiveBonus(bonus, run_slot_bonus[prev_slot]);
                    const slot = runSlot(step.run);
                    const candidate = value + score_match + step.bonus;
                    const start = scratch.starts[prev_cell + prev_slot];
                    if (betterCandidate(candidate, start, scratch.scores[cell + slot], scratch.starts[cell + slot])) {
                        scratch.scores[cell + slot] = candidate;
                        scratch.starts[cell + slot] = start;
                        scratch.pred_entries[cell + slot] = @intCast(diag);
                        scratch.pred_slots[cell + slot] = @intCast(prev_slot);
                    }
                }
            }
            if (best_gap != invalid_score) {
                const slot = runSlot(bonus);
                const candidate = best_gap - @as(i32, @intCast(j)) - 1 + score_match + bonus;
                if (betterCandidate(candidate, best_gap_start, scratch.scores[cell + slot], scratch.starts[cell + slot])) {
                    scratch.scores[cell + slot] = candidate;
                    scratch.starts[cell + slot] = best_gap_start;
                    scratch.pred_entries[cell + slot] = best_gap_entry;
                    scratch.pred_slots[cell + slot] = best_gap_slot;
                }
            }
        }
    }

    var best_score: i32 = invalid_score;
    var best_start: u16 = 0;
    var best_entry: usize = 0;
    var best_slot: usize = 0;
    for (scratch.row_offsets[m - 1]..scratch.row_offsets[m]) |entry| {
        for (0..run_slot_count) |slot| {
            const value = scratch.scores[entry * run_slot_count + slot];
            if (value == invalid_score) continue;
            if (betterCandidate(value, scratch.starts[entry * run_slot_count + slot], best_score, best_start)) {
                best_score = value;
                best_start = scratch.starts[entry * run_slot_count + slot];
                best_entry = entry;
                best_slot = slot;
            }
        }
    }
    if (best_score == invalid_score) return null;

    var row = m - 1;
    var entry = best_entry;
    var slot = best_slot;
    while (true) {
        scratch.positions[row] = scratch.columns[entry];
        if (row == 0) break;
        const cell = entry * run_slot_count + slot;
        entry = scratch.pred_entries[cell];
        slot = scratch.pred_slots[cell];
        row -= 1;
    }
    std.debug.assert(scratch.positions[0] == best_start);
    return .{ .quality = best_score, .first_position = @intCast(@as(usize, best_start) - range_start) };
}

/// Points a placement inside the file or folder name earns over one that
/// starts in the folder holding the name. A close call favors the name, so
/// for `abcd`, `src/x/ab-cd.ts` stays above `src/ab/cd.ts`, while a clean
/// folder-plus-name match such as `vercle` for `vercel-json/clean-urls.mdx`
/// can still beat letters scattered through a name.
const name_bonus: i32 = 4;

comptime {
    // `maxCrossingQuality` assumes no character earns more than this bonus.
    for ([_]i32{ bonus_boundary, bonus_non_word, bonus_camel_123, bonus_consecutive, bonus_boundary_white }) |bonus| {
        std.debug.assert(bonus <= bonus_boundary_delimiter);
    }
}

/// The highest score of a placement that starts in a parent folder and ends
/// in the name. Without a `/` in the query such a placement skips the `/`
/// before the name, which costs at least one gap.
fn maxCrossingQuality(comptime T: type, query: []const T) i32 {
    const m: i32 = @intCast(query.len);
    const ceiling = score_match * m + bonus_boundary_delimiter * (m + 1);
    return if (std.mem.findScalar(T, query, '/') == null) ceiling + score_gap_start else ceiling;
}

/// The highest score a non-exact match can reach: the query as a run at the
/// start of the name, right after its `/`, plus `name_bonus`. Its first
/// position is 0, because only the first letter of a name follows a `/`.
fn maxNameQuality(query_len: usize) i32 {
    const m: i32 = @intCast(query_len);
    return score_match * m + bonus_boundary_delimiter * (m + 1) + name_bonus;
}

/// A query that spells the whole path, the name, or the name up to a dot,
/// such as `main` for `main.zig`, is an exact match.
fn exactFit(comptime T: type, whole: []const T, name: []const T, query: []const T) bool {
    return std.mem.eql(T, whole, query) or std.mem.eql(T, name, query) or
        (name.len > query.len and std.mem.startsWith(T, name, query) and name[query.len] == '.');
}

/// Which placements a candidate may still need. Ranking turns a kind off only
/// once it can no longer enter the kept results.
const Needed = struct {
    /// Placements that end in a parent folder.
    folder: bool = true,
    /// Placements that start in the folder holding the name and end in the name.
    crossing: bool = true,
};

const Placement = struct {
    name_fit: bool,
    alignment: Alignment,
    range_start: usize,
    end_min: usize,
};

/// Pure: picks the placement that defines a candidate's score. A placement
/// ending in the file or folder name ranks above one ending in a parent
/// folder. Among those, the best placement inside the name, plus
/// `name_bonus`, competes with the best one that starts in the folder that
/// holds the name, as in `vercle` for `vercel-json/clean-urls.mdx`. Crossing
/// placements start no higher than that folder, so their search covers only
/// the folder and the name.
fn choosePlacement(
    comptime T: type,
    text: []const T,
    path: []const u8,
    byte_offsets: ?[]const u16,
    base_start: usize,
    query: []const T,
    scratch: *AlignScratch,
    needed: Needed,
) ?Placement {
    var best: ?Placement = null;
    if (alignBest(T, text, path, byte_offsets, base_start, base_start, query, scratch)) |inside| {
        best = .{
            .name_fit = true,
            .alignment = .{ .quality = inside.quality + name_bonus, .first_position = inside.first_position },
            .range_start = base_start,
            .end_min = base_start,
        };
    }
    // Without a placement in the name, a path that does not hold the letters
    // in order has no other placement either; one scan settles it.
    if (best == null and query.len > 1 and !isSubsequence(T, text, query)) return null;
    const crossing_can_win = if (best) |inside| inside.alignment.quality < maxCrossingQuality(T, query) else true;
    if (needed.crossing and base_start > 0 and query.len > 1 and crossing_can_win) {
        // text[base_start - 1] is the `/` before the name.
        const folder_start = if (std.mem.findScalarLast(T, text[0 .. base_start - 1], '/')) |slash| slash + 1 else 0;
        if (alignBest(T, text, path, byte_offsets, folder_start, base_start, query, scratch)) |crossing| {
            if (best == null or crossing.quality > best.?.alignment.quality) {
                best = .{ .name_fit = true, .alignment = crossing, .range_start = folder_start, .end_min = base_start };
            }
        }
    }
    if (best != null) return best;
    if (!needed.folder) return null;
    const anywhere = alignBest(T, text, path, byte_offsets, 0, 0, query, scratch) orelse return null;
    return .{ .name_fit = false, .alignment = anywhere, .range_start = 0, .end_min = 0 };
}

fn isSubsequence(comptime T: type, text: []const T, query: []const T) bool {
    var query_index: usize = 0;
    for (text) |item| {
        if (item != query[query_index]) continue;
        query_index += 1;
        if (query_index == query.len) return true;
    }
    return false;
}

fn scoreOf(exact_fit: bool, placement: Placement) MatchScore {
    return .{
        .exact_fit = exact_fit,
        .name_fit = placement.name_fit,
        .quality = placement.alignment.quality,
        .first_position = placement.alignment.first_position,
    };
}

fn scoreAsciiMatch(
    path: []const u8,
    path_lower: []const u8,
    basename_start: u32,
    query: []const u8,
) ?MatchScore {
    var scratch: AlignScratch = undefined;
    return scoreAsciiMatchWith(&scratch, path, path_lower, basename_start, query, .{});
}

fn scoreAsciiMatchWith(
    scratch: *AlignScratch,
    path: []const u8,
    path_lower: []const u8,
    basename_start: u32,
    query: []const u8,
    needed: Needed,
) ?MatchScore {
    if (query.len == 0 or path.len == 0) return null;
    const base_start: usize = basename_start;
    const exact_fit = exactFit(u8, path_lower, path_lower[base_start..], query);
    // An exact match always enters, so it is always scored in full.
    const placement = choosePlacement(u8, path_lower, path, null, base_start, query, scratch, if (exact_fit) .{} else needed) orelse return null;
    return scoreOf(exact_fit, placement);
}

fn scoreFoldedMatchWith(
    align_scratch: *AlignScratch,
    path: []const u8,
    basename_byte_start: u32,
    query: []const u21,
    scratch: *FoldedPathScratch,
    needed: Needed,
) ?MatchScore {
    if (query.len == 0 or path.len == 0) return null;
    const base_start: usize = basename_byte_start;
    const decoded = decodeFoldedPath(path, base_start, scratch) orelse return null;
    const scalars = scratch.scalars[0..decoded.scalar_count];
    const exact_fit = exactFit(u21, scalars, scalars[decoded.basename_scalar_start..], query);
    const byte_offsets = scratch.byte_offsets[0 .. decoded.scalar_count + 1];
    const placement = choosePlacement(u21, scalars, path, byte_offsets, decoded.basename_scalar_start, query, align_scratch, if (exact_fit) .{} else needed) orelse return null;
    return scoreOf(exact_fit, placement);
}

inline fn scoreBetter(left: MatchScore, right: MatchScore) bool {
    if (left.exact_fit != right.exact_fit) return left.exact_fit;
    if (left.name_fit != right.name_fit) return left.name_fit;
    if (left.quality != right.quality) return left.quality > right.quality;
    if (left.first_position != right.first_position) return left.first_position < right.first_position;
    return false;
}

fn rankedCandidateBetter(generation: *const Generation, left: RankedCandidate, right: RankedCandidate) bool {
    if (scoreBetter(left.score, right.score)) return true;
    if (scoreBetter(right.score, left.score)) return false;
    const left_path = generation.pathAt(left.index);
    const right_path = generation.pathAt(right.index);
    if (left_path.len != right_path.len) return left_path.len < right_path.len;
    return std.mem.order(u8, left_path, right_path) == .lt;
}

fn findWorstSlot(generation: *const Generation, ranked: []const RankedCandidate) usize {
    var worst_slot: usize = 0;
    for (ranked[1..], 1..) |candidate, candidate_index| {
        if (rankedCandidateBetter(generation, ranked[worst_slot], candidate)) worst_slot = candidate_index;
    }
    return worst_slot;
}

fn sortRanked(generation: *const Generation, ranked: []RankedCandidate) void {
    var candidate_index: usize = 1;
    while (candidate_index < ranked.len) : (candidate_index += 1) {
        const candidate = ranked[candidate_index];
        var insertion_index = candidate_index;
        while (insertion_index > 0 and rankedCandidateBetter(generation, candidate, ranked[insertion_index - 1])) : (insertion_index -= 1) {
            ranked[insertion_index] = ranked[insertion_index - 1];
        }
        ranked[insertion_index] = candidate;
    }
}

fn reconstructMatchSpans(
    path: []const u8,
    basename_byte_start: u32,
    query: []const u21,
    path_scratch: *FoldedPathScratch,
    align_scratch: *AlignScratch,
    matched_offsets: *[max_path_len]u16,
    span_scratch: *[max_path_len]MatchSpan,
) ?usize {
    const decoded = decodeFoldedPath(path, basename_byte_start, path_scratch) orelse return null;
    const scalars = path_scratch.scalars[0..decoded.scalar_count];
    const byte_offsets = path_scratch.byte_offsets[0 .. decoded.scalar_count + 1];
    const placement = choosePlacement(u21, scalars, path, byte_offsets, decoded.basename_scalar_start, query, align_scratch, .{}) orelse return null;
    // Rerun the chosen search: a later search in the choice reuses the positions.
    _ = alignBest(u21, scalars, path, byte_offsets, placement.range_start, placement.end_min, query, align_scratch) orelse return null;
    for (align_scratch.positions[0..query.len], matched_offsets[0..query.len]) |position, *offset| {
        offset.* = byte_offsets[position];
    }
    return spansFromMatchedOffsets(path, matched_offsets[0..query.len], span_scratch);
}

fn spansFromMatchedOffsets(
    path: []const u8,
    matched_offsets: []const u16,
    out: *[max_path_len]MatchSpan,
) ?usize {
    var matched_index: usize = 0;
    var span_count: usize = 0;
    var cursor: usize = 0;
    while (cursor < path.len and matched_index < matched_offsets.len) {
        const cluster_start = cursor;
        const first = display_width.displayUnitAt(path, cursor);
        if (first.byte_len == 0) return null;
        cursor += first.byte_len;
        while (cursor < path.len) {
            const continuation = display_width.displayUnitAt(path, cursor);
            if (continuation.byte_len == 0) return null;
            if (continuation.cell_width != 0) break;
            cursor += continuation.byte_len;
        }
        const cluster_end = cursor;

        var cluster_matched = false;
        while (matched_index < matched_offsets.len and matched_offsets[matched_index] < cluster_end) {
            if (matched_offsets[matched_index] < cluster_start) return null;
            cluster_matched = true;
            matched_index += 1;
        }
        if (!cluster_matched) continue;

        if (span_count > 0 and out[span_count - 1].byte_end == cluster_start) {
            out[span_count - 1].byte_end = std.math.cast(u16, cluster_end) orelse return null;
            continue;
        }
        out[span_count] = .{
            .byte_start = std.math.cast(u16, cluster_start) orelse return null,
            .byte_end = std.math.cast(u16, cluster_end) orelse return null,
        };
        span_count += 1;
    }
    if (matched_index != matched_offsets.len) return null;
    return span_count;
}

test "filename fuzzy matcher shares indexed ordering and Unicode highlight spans" {
    const alloc = std.testing.allocator;
    const names = [_][]const u8{ "Desktop", "desktop-tools", "myDesktop", "Desk top", "dusk-top", "Ärger-file.txt", "Kelvin", "cafe\u{301}.txt" };
    var candidates: [names.len]Candidate = undefined;
    for (names, &candidates) |name, *candidate| candidate.* = .{ .path = name, .kind = .file };
    var index: FileIndex = .{};
    defer index.deinit(alloc);
    try index.buildFromCandidates(alloc, &candidates);
    const RankedName = struct { name: []const u8, score: NameQuery.Score };
    for ([_][]const u8{ "ktop", "dsktp", "desk", "ärf", "klv", "ce", "nomatch" }) |query| {
        const matcher = NameQuery.init(query).?;
        var results: [names.len]SearchResult = undefined;
        var spans: [names.len * max_path_len]MatchSpan = undefined;
        const count = try index.searchTyped(query, &results, &spans);
        var ranked: [names.len]RankedName = undefined;
        var matched: usize = 0;
        for (names) |name| {
            if (matcher.score(name)) |score| {
                ranked[matched] = .{ .name = name, .score = score };
                matched += 1;
            }
        }
        std.mem.sort(RankedName, ranked[0..matched], &matcher, struct {
            fn less(ctx: *const NameQuery, left: RankedName, right: RankedName) bool {
                return ctx.better(left.score, left.name, right.score, right.name);
            }
        }.less);
        try std.testing.expectEqual(count, matched);
        for (ranked[0..matched], results[0..count]) |name, result| {
            try std.testing.expectEqualStrings(result.path, name.name);
            var name_spans: [max_path_len]MatchSpan = undefined;
            const span_count = try matcher.match_spans(name.name, &name_spans);
            try std.testing.expectEqualSlices(MatchSpan, result.matched_spans, name_spans[0..span_count]);
        }
    }
}

fn expectValidSearchSpans(result: SearchResult) !void {
    var previous_end: usize = 0;
    for (result.matched_spans) |span| {
        try std.testing.expect(span.byte_start < span.byte_end);
        try std.testing.expect(span.byte_start >= previous_end);
        try std.testing.expect(span.byte_end <= result.path.len);
        try std.testing.expect(std.unicode.utf8ValidateSlice(result.path[span.byte_start..span.byte_end]));
        previous_end = span.byte_end;
    }
}

fn TestSearchBuffer(comptime capacity: usize) type {
    return struct {
        results: [capacity]SearchResult = undefined,
        spans: [capacity * max_path_len]MatchSpan = undefined,

        fn run(self: *@This(), index: *const FileIndex, query: []const u8) SearchError![]const SearchResult {
            const count = try index.searchTyped(query, &self.results, &self.spans);
            return self.results[0..count];
        }
    };
}

fn expectFirstSearchPath(raw: []const u8, query: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, raw);

    var search: TestSearchBuffer(8) = .{};
    const results = try search.run(&index, query);
    try std.testing.expect(results.len > 0);
    try std.testing.expectEqualStrings(expected, results[0].path);
}

fn containsCandidate(candidates: []const Candidate, path: []const u8, kind: CandidateKind) bool {
    for (candidates) |candidate| {
        if (candidate.kind == kind and std.mem.eql(u8, candidate.path, path)) return true;
    }
    return false;
}

fn runGitForFileIndexTest(alloc: Allocator, cwd: []const u8, argv: []const []const u8) !void {
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        .signal, .stopped, .unknown => return error.TestUnexpectedResult,
    }
}

test "buildFromRaw parses newline-separated list" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);

    try index.buildFromRaw(alloc, "src/main.zig\nsrc/core/shared/io.zig\nREADME.md\n");

    try std.testing.expectEqual(@as(usize, 3), index.count());
    try std.testing.expectEqualStrings("src/main.zig", index.pathAt(0));
    try std.testing.expectEqualStrings("src/core/shared/io.zig", index.pathAt(1));
    try std.testing.expectEqualStrings("README.md", index.pathAt(2));
}

test "buildFromRaw parses nul-separated list from git ls-files -z" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);

    try index.buildFromRaw(alloc, "a/b.zig\x00CAMEL.md\x00");

    try std.testing.expectEqual(@as(usize, 2), index.count());
    try std.testing.expectEqualStrings("a/b.zig", index.pathAt(0));
    try std.testing.expectEqualStrings("CAMEL.md", index.pathAt(1));
    try std.testing.expectEqualStrings("camel.md", index.lowerPathAt(1));
}

test "buildFromRaw precomputes basename starts" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);

    try index.buildFromRaw(alloc, "a/b/c.txt\nroot.txt\n");

    const generation = index.active_generation.?;
    const first_base = generation.paths_buf[generation.basename_starts[0]..generation.offsets[1]];
    const second_base = generation.paths_buf[generation.basename_starts[1]..generation.offsets[2]];
    try std.testing.expectEqualStrings("c.txt", first_base);
    try std.testing.expectEqualStrings("root.txt", second_base);
}

test "buildFromRaw precomputes a-z char masks" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);

    try index.buildFromRaw(alloc, "src/Main.zig\nREADME.md\n");

    const generation = index.active_generation.?;
    try std.testing.expectEqual(alphaMask("src/main.zig"), generation.char_masks[0]);
    try std.testing.expectEqual(alphaMask("readme.md"), generation.char_masks[1]);
}

test "countAndSize applies the same filters as the fill pass" {
    const long_path = text_utils.repeat("a", max_path_len + 1);
    const raw = "ok.zig\n" ++ long_path ++ "\n\nother.md\n";
    const totals = countAndSize(.{ .file_raw = raw });
    // "ok.zig" + "" (empty) + long_path (too long) + "other.md" -> 2 kept.
    try std.testing.expectEqual(@as(u32, 2), totals.n);
    try std.testing.expectEqual(@as(u32, "ok.zig".len + "other.md".len), totals.bytes);
}

test "buildFromCandidates stores one mixed typed inventory in input order" {
    const alloc = std.testing.allocator;
    const candidates = [_]Candidate{
        .{ .path = "src", .kind = .directory },
        .{ .path = "src", .kind = .directory },
        .{ .path = "src", .kind = .file },
        .{ .path = "src/main.zig", .kind = .file },
        .{ .path = "docs", .kind = .directory },
    };

    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromCandidates(alloc, &candidates);

    try std.testing.expectEqual(@as(usize, 4), index.count());
    try std.testing.expectEqualStrings("src", index.pathAt(0));
    try std.testing.expectEqual(CandidateKind.directory, index.kindAt(0));
    try std.testing.expectEqualStrings("src", index.pathAt(1));
    try std.testing.expectEqual(CandidateKind.file, index.kindAt(1));
    try std.testing.expectEqualStrings("src/main.zig", index.pathAt(2));
    try std.testing.expectEqual(CandidateKind.file, index.kindAt(2));
    try std.testing.expectEqualStrings("docs", index.pathAt(3));
    try std.testing.expectEqual(CandidateKind.directory, index.kindAt(3));
}

test "buildFromCandidates handles empty and rejected typed candidates" {
    const alloc = std.testing.allocator;

    var empty = FileIndex{};
    defer empty.deinit(alloc);
    try empty.buildFromCandidates(alloc, &.{});
    try std.testing.expectEqual(@as(usize, 0), empty.count());

    const long_path = text_utils.repeat("a", max_path_len + 1);
    const candidates = [_]Candidate{
        .{ .path = "src/", .kind = .directory },
        .{ .path = "escape-\x1b[2J", .kind = .directory },
        .{ .path = "space \" dir", .kind = .directory },
        .{ .path = long_path, .kind = .file },
        .{ .path = "src", .kind = .directory },
        .{ .path = "README.md", .kind = .file },
    };

    var filtered = FileIndex{};
    defer filtered.deinit(alloc);
    try filtered.buildFromCandidates(alloc, &candidates);
    try std.testing.expectEqual(@as(usize, 3), filtered.count());
    try std.testing.expectEqualStrings("space \" dir", filtered.pathAt(0));
    try std.testing.expectEqual(CandidateKind.directory, filtered.kindAt(0));
    try std.testing.expectEqualStrings("src", filtered.pathAt(1));
    try std.testing.expectEqual(CandidateKind.directory, filtered.kindAt(1));
    try std.testing.expectEqualStrings("README.md", filtered.pathAt(2));
    try std.testing.expectEqual(CandidateKind.file, filtered.kindAt(2));
}

test "typed candidate publication exposes matching immutable kinds" {
    const alloc = std.testing.allocator;
    const candidates = [_]Candidate{
        .{ .path = "src", .kind = .directory },
        .{ .path = "src/main.zig", .kind = .file },
        .{ .path = "docs", .kind = .directory },
    };

    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromCandidates(alloc, &candidates);

    const generation = index.active_generation.?;
    index.active_generation = null;
    index.loading_generation = generation;
    generation.state.store(@backingInt(GenerationState.loading), .release);
    generation.ready_count.store(2, .release);
    try std.testing.expectEqual(@as(usize, 2), index.count());
    try std.testing.expectEqual(CandidateKind.directory, index.kindAt(0));
    try std.testing.expectEqual(CandidateKind.file, index.kindAt(1));

    var search: TestSearchBuffer(3) = .{};
    const results = try search.run(&index, "");
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("src", results[0].path);
    try std.testing.expectEqualStrings("src/main.zig", results[1].path);

    generation.ready_count.store(3, .release);
    try std.testing.expectEqual(CandidateKind.directory, index.kindAt(2));
}

test "typed candidate cap is shared across files and directories" {
    const alloc = std.testing.allocator;
    const candidate_count = max_indexed_files + 1;
    const path_stride: usize = 32;
    const path_storage_len = try std.math.mul(usize, candidate_count, path_stride);
    const path_storage = try alloc.alloc(u8, path_storage_len);
    defer alloc.free(path_storage);
    const candidates = try alloc.alloc(Candidate, candidate_count);
    defer alloc.free(candidates);

    for (candidates, 0..) |*candidate, index| {
        const slot = path_storage[index * path_stride ..][0..path_stride];
        candidate.* = .{
            .path = try std.mem.print(slot, "candidate-{d:0>6}", .{index}),
            .kind = if (index % 2 == 0) .file else .directory,
        };
    }

    var file_index = FileIndex{};
    defer file_index.deinit(alloc);
    try file_index.buildFromCandidates(alloc, candidates);

    try std.testing.expectEqual(max_indexed_files, file_index.count());
    try std.testing.expectEqualStrings("candidate-099999", file_index.pathAt(max_indexed_files - 1));
    try std.testing.expectEqual(CandidateKind.directory, file_index.kindAt(max_indexed_files - 1));
}

test "tree candidates keep a sorted directory at the exact shared cap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = try arena.alloc(indexer.Entry, max_indexed_files + 1);
    entries[0] = .{ .path = "a-empty-directory", .kind = .directory };
    for (entries[1..], 0..) |*entry, index| {
        entry.* = .{ .path = try arena.print("z-file-{d:0>6}", .{index}), .kind = .file };
    }
    const tree: indexer.Tree = .{
        .root = "/workspace",
        .root_inode = 1,
        .scan_started_ns = 0,
        .repository = false,
        .incomplete = false,
        .cap_reached = false,
        .skipped_overlong = 0,
        .skipped_names = &.{},
        .entries = entries,
        .folders = &.{},
        .sources = &.{},
    };
    var stop_requested = std.atomic.Value(bool).init(false);
    const candidates = try candidatesFromTrees(arena, &.{"/workspace"}, &.{tree}, &stop_requested);
    try std.testing.expectEqual(max_indexed_files, candidates.len);
    try std.testing.expectEqual(CandidateKind.directory, candidates[0].kind);
    try std.testing.expectEqualStrings("z-file-099998", candidates[max_indexed_files - 1].path);
}

test "added-root candidates drop the same paths as primary-root ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const primary = [_]indexer.Entry{.{ .path = "main.zig", .kind = .file }};
    // Only a damaged snapshot holds such paths; a scan never produces them.
    const added = [_]indexer.Entry{
        .{ .path = ".git/config", .kind = .file },
        .{ .path = "a/../../outside", .kind = .file },
        .{ .path = "a//b", .kind = .file },
        .{ .path = "./a", .kind = .file },
        .{ .path = "ok.txt", .kind = .file },
    };
    var trees: [2]indexer.Tree = undefined;
    for (&trees, [_][]const u8{ "/workspace", "/extra" }, [_][]const indexer.Entry{ &primary, &added }) |*tree, root, entries| {
        tree.* = .{
            .root = root,
            .root_inode = 1,
            .scan_started_ns = 0,
            .repository = true,
            .incomplete = false,
            .cap_reached = false,
            .skipped_overlong = 0,
            .skipped_names = &.{},
            .entries = entries,
            .folders = &.{},
            .sources = &.{},
        };
    }
    var stop_requested = std.atomic.Value(bool).init(false);
    const candidates = try candidatesFromTrees(arena, &.{ "/workspace", "/extra" }, &trees, &stop_requested);
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqualStrings("main.zig", candidates[0].path);
    try std.testing.expectEqualStrings("/extra/ok.txt", candidates[1].path);
}

test "primary tree candidates keep plain paths and drop git, escaping and unsafe ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = [_]indexer.Entry{
        .{ .path = ".git/config", .kind = .file },
        .{ .path = "a/../../outside", .kind = .file },
        .{ .path = "/absolute", .kind = .file },
        .{ .path = "a//b", .kind = .file },
        .{ .path = "./a", .kind = .file },
        .{ .path = "bad-\x1b[2J", .kind = .file },
        .{ .path = "src", .kind = .directory },
        .{ .path = "src/.gitignore", .kind = .file },
        .{ .path = "src/main.zig", .kind = .file },
    };
    const tree: indexer.Tree = .{
        .root = "/workspace",
        .root_inode = 1,
        .scan_started_ns = 0,
        .repository = true,
        .incomplete = false,
        .cap_reached = false,
        .skipped_overlong = 0,
        .skipped_names = &.{},
        .entries = &entries,
        .folders = &.{},
        .sources = &.{},
    };
    var stop_requested = std.atomic.Value(bool).init(false);
    const candidates = try candidatesFromTrees(arena, &.{"/workspace"}, &.{tree}, &stop_requested);
    try std.testing.expectEqual(@as(usize, 3), candidates.len);
    try std.testing.expectEqualStrings("src", candidates[0].path);
    try std.testing.expectEqual(CandidateKind.directory, candidates[0].kind);
    try std.testing.expectEqualStrings("src/.gitignore", candidates[1].path);
    try std.testing.expectEqualStrings("src/main.zig", candidates[2].path);
}

/// Scans `roots` without a snapshot and keeps the trees alive while the
/// caller inspects candidates that borrow their memory.
const TestScope = struct {
    refreshed: RefreshedTrees,
    candidates: []const Candidate,

    fn init(arena: Allocator, roots: []const []const u8) !TestScope {
        var stop_requested = std.atomic.Value(bool).init(false);
        var refreshed = try refreshTrees(std.testing.allocator, roots, &.{}, &stop_requested);
        errdefer refreshed.deinit(std.testing.allocator);
        return .{ .refreshed = refreshed, .candidates = try candidatesFromTrees(arena, roots, refreshed.trees, &stop_requested) };
    }

    fn deinit(self: *TestScope) void {
        self.refreshed.deinit(std.testing.allocator);
    }
};

test "subsequence scoring prefers basename prefix over mid-path match" {
    const path_a = "src/main.zig";
    const path_b = "src/wasm_term_main.zig";

    const a = scoreAsciiMatch(path_a, path_a, 4, "main").?;
    const b = scoreAsciiMatch(path_b, path_b, 4, "main").?;
    try std.testing.expect(scoreBetter(a, b));
}

test "subsequence scoring prefers earlier match position" {
    const path = "src/main.zig";
    const early = scoreAsciiMatch(path, path, 4, "main").?;
    const late_path = "foo/bar/baz-main.zig";
    const late = scoreAsciiMatch(late_path, late_path, 8, "main").?;
    try std.testing.expect(scoreBetter(early, late));
}

test "subsequence scoring returns no match when query is absent" {
    const path = "src/main.zig";
    try std.testing.expect(scoreAsciiMatch(path, path, 4, "xyz") == null);
}

test "subsequence scoring accepts longer query than basename via full path" {
    const path = "src/main.zig";
    try std.testing.expect(scoreAsciiMatch(path, path, 4, "src/main") != null);
}

test "search returns best matches first" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);

    const raw = "src/wasm_term_main.zig\nsrc/main.zig\nREADME.md\nsrc/core/shared/io.zig\nbenchmarks/startup.sh\n";
    try index.buildFromRaw(alloc, raw);

    var search: TestSearchBuffer(8) = .{};
    const results = try search.run(&index, "main");
    try std.testing.expect(results.len >= 2);
    try std.testing.expectEqualStrings("src/main.zig", results[0].path);
    try std.testing.expectEqualStrings("src/wasm_term_main.zig", results[1].path);
}

test "typed search supports abbreviated subsequences and caller-owned spans" {
    const alloc = std.testing.allocator;
    const candidates = [_]Candidate{
        .{ .path = "src/core/workspace", .kind = .directory },
        .{ .path = "src/core/workspace/file_index.zig", .kind = .file },
        .{ .path = "src/core/workspace/workspace_files.zig", .kind = .file },
    };
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromCandidates(alloc, &candidates);

    var results: [4]SearchResult = undefined;
    var spans: [32]MatchSpan = undefined;
    const result_count = try index.searchTyped("FIIDX", &results, &spans);
    try std.testing.expectEqual(@as(usize, 1), result_count);
    try std.testing.expectEqualStrings("src/core/workspace/file_index.zig", results[0].path);
    try std.testing.expectEqual(CandidateKind.file, results[0].kind);
    try expectValidSearchSpans(results[0]);

    var matched_bytes: [16]u8 = undefined;
    var matched_len: usize = 0;
    for (results[0].matched_spans) |span| {
        const bytes = results[0].path[span.byte_start..span.byte_end];
        @memcpy(matched_bytes[matched_len..][0..bytes.len], bytes);
        matched_len += bytes.len;
    }
    try std.testing.expectEqualStrings("fiidx", matched_bytes[0..matched_len]);
}

test "ranking signals follow the accepted descending influence" {
    const cases = [_]struct {
        name: []const u8,
        raw: []const u8,
        query: []const u8,
        expected: []const u8,
    }{
        .{
            .name = "exact full path",
            .raw = "other/src/core/main.zig\nsrc/core/main.zig\n",
            .query = "src/core/main.zig",
            .expected = "src/core/main.zig",
        },
        .{
            .name = "exact basename",
            .raw = "src/main.zig.backup\nsrc/main.zig\n",
            .query = "main.zig",
            .expected = "src/main.zig",
        },
        .{
            .name = "basename",
            .raw = "core/guide.txt\ndocs/core-guide.txt\n",
            .query = "core",
            .expected = "docs/core-guide.txt",
        },
        .{
            .name = "contiguous segment start over spread segment starts",
            .raw = "src/core/main.zig\nmisc/scattered/memo.zig\n",
            .query = "scm",
            .expected = "misc/scattered/memo.zig",
        },
        .{
            .name = "basename prefix",
            .raw = "src/xwidget.zig\nsrc/widgetx.zig\n",
            .query = "wid",
            .expected = "src/widgetx.zig",
        },
        .{
            .name = "adjacent segment starts over a wider gap",
            .raw = "a/x/b\nx/a/b\n",
            .query = "ab",
            .expected = "x/a/b",
        },
        .{
            .name = "earlier position",
            .raw = "src/xxidxx.zig\nsrc/xidxxx.zig\n",
            .query = "id",
            .expected = "src/xidxxx.zig",
        },
        .{
            .name = "consecutive run",
            .raw = "src/axbyc.zig\nsrc/abczz.zig\n",
            .query = "abc",
            .expected = "src/abczz.zig",
        },
        .{
            .name = "smaller gaps",
            .raw = "src/axxxbxc.zig\nsrc/axbxczz.zig\n",
            .query = "abc",
            .expected = "src/axbxczz.zig",
        },
        .{
            .name = "shorter path",
            .raw = "src/abc-long-name.txt\nsrc/abc.txt\n",
            .query = "abc",
            .expected = "src/abc.txt",
        },
    };

    for (cases) |case| {
        try expectFirstSearchPath(case.raw, case.query, case.expected);
    }
}

test "ranking is independent of discovery order and resolves ties bytewise" {
    try expectFirstSearchPath(
        "src/zeta.txt\nsrc/beta.txt\n",
        "ta",
        "src/beta.txt",
    );
    try expectFirstSearchPath(
        "src/beta.txt\nsrc/zeta.txt\n",
        "ta",
        "src/beta.txt",
    );
}

test "score comparison ranks tiers before alignment quality and position" {
    const base: MatchScore = .{ .exact_fit = false, .name_fit = false, .quality = 10, .first_position = 5 };
    var exact = base;
    exact.exact_fit = true;
    exact.quality = 0;
    var name_match = base;
    name_match.name_fit = true;
    name_match.quality = 0;
    var stronger = base;
    stronger.quality = 11;
    stronger.first_position = 9;
    var earlier = base;
    earlier.first_position = 4;
    try std.testing.expect(scoreBetter(exact, name_match));
    try std.testing.expect(scoreBetter(name_match, stronger));
    try std.testing.expect(scoreBetter(stronger, earlier));
    try std.testing.expect(scoreBetter(earlier, base));
    try std.testing.expect(!scoreBetter(base, base));
}

test "a contiguous name prefix ranks above letters scattered across word breaks" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "spikes/noisy/clusters-a.toml\nspikes/noisy/results/conn-storm-pro-activity.csv\n" ++
        "spikes/noisy/results/conn-storm-free-activity.csv\nSTATUS.md\ncontracts/fixtures/stats_response.json\n");
    var search: TestSearchBuffer(8) = .{};
    const results = try search.run(&index, "stat");
    try std.testing.expectEqual(@as(usize, 5), results.len);
    try std.testing.expectEqualStrings("STATUS.md", results[0].path);
    try std.testing.expectEqualStrings("contracts/fixtures/stats_response.json", results[1].path);
}

test "a whole word inside a name ranks above scattered letters" {
    try expectFirstSearchPath("scripts/test-matrix.ts\nsrc/test-stat.zig\n", "stat", "src/test-stat.zig");
    try expectFirstSearchPath("src/ui/inline_dex_view.zig\nsrc/core/workspace/file_index.zig\n", "index", "src/core/workspace/file_index.zig");
}

test "a query equal to a file name before an extension is an exact match" {
    try expectFirstSearchPath("bench/file_index_bench.zig\nsrc/core/workspace/file_index.zig\n", "file_index", "src/core/workspace/file_index.zig");
}

test "a match across the file's folder and its name ranks above letters scattered through a name" {
    try expectFirstSearchPath("packages/vercel-error.ts\ndocs/vercel-json/clean-urls.mdx\n", "vercle", "docs/vercel-json/clean-urls.mdx");
}

test "a name match beats a match of the same shape through the folder" {
    // Without name_bonus, `ab/cd` scores two points above `ab-cd`.
    try expectFirstSearchPath("src/ab/cd.ts\nsrc/x/ab-cd.ts\n", "abcd", "src/x/ab-cd.ts");
}

test "a match that ends in a folder ranks below every name match" {
    try expectFirstSearchPath("src/components/card.tsx\nsrc/use-comparison.ts\n", "comp", "src/use-comparison.ts");
}

test "a match may start in the file's own folder but not further up" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "ab/x/cd.ts\nzz/x-a-b-c-d.ts\n");
    var search: TestSearchBuffer(4) = .{};
    const results = try search.run(&index, "abcd");
    try std.testing.expectEqual(@as(usize, 2), results.len);
    // `ab/x/cd.ts` scores higher, but only by crossing from its grandparent,
    // so it ranks as a folder match below a scattered name match.
    try std.testing.expectEqualStrings("zz/x-a-b-c-d.ts", results[0].path);
}

test "highlights of a folder-and-name match cover both parts" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "docs/vercel-json/clean-urls.mdx\n");
    var search: TestSearchBuffer(1) = .{};
    const results = try search.run(&index, "vercle");
    try std.testing.expectEqual(@as(usize, 1), results.len);
    const spans = results[0].matched_spans;
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqual(@as(u16, 5), spans[0].byte_start);
    try std.testing.expectEqual(@as(u16, 8), spans[0].byte_end);
    try std.testing.expectEqual(@as(u16, 17), spans[1].byte_start);
    try std.testing.expectEqual(@as(u16, 20), spans[1].byte_end);
}

test "highlights mark the placement that was scored" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "src/test-stat.zig\nSTATUS.md\n");
    var search: TestSearchBuffer(4) = .{};
    const results = try search.run(&index, "stat");
    try std.testing.expectEqual(@as(usize, 2), results.len);
    for (results) |result| {
        try std.testing.expectEqual(@as(usize, 1), result.matched_spans.len);
        const expected_start: u16 = if (std.mem.eql(u8, result.path, "STATUS.md")) 0 else 9;
        try std.testing.expectEqual(expected_start, result.matched_spans[0].byte_start);
        try std.testing.expectEqual(expected_start + 4, result.matched_spans[0].byte_end);
    }
}

const BruteForce = struct {
    best: ?Alignment = null,
    /// Highest score among placements that start before `end_min`.
    crossing_peak: ?i32 = null,
};

fn bruteForceAlignment(path: []const u8, lower: []const u8, range_start: usize, end_min: usize, query: []const u8) BruteForce {
    var positions: [8]u16 = undefined;
    var result: BruteForce = .{};
    bruteForceVisit(path, lower, range_start, end_min, query, 0, range_start, &positions, &result);
    return result;
}

fn bruteForceVisit(
    path: []const u8,
    lower: []const u8,
    range_start: usize,
    end_min: usize,
    query: []const u8,
    depth: usize,
    from: usize,
    positions: *[8]u16,
    result: *BruteForce,
) void {
    if (depth == query.len) {
        if (positions[query.len - 1] < end_min) return;
        const alignment = scoreAlignment(path, null, range_start, positions[0..query.len]);
        if (positions[0] < end_min) result.crossing_peak = @max(result.crossing_peak orelse alignment.quality, alignment.quality);
        if (result.best) |current| {
            if (alignment.quality < current.quality or
                (alignment.quality == current.quality and alignment.first_position >= current.first_position)) return;
        }
        result.best = alignment;
        return;
    }
    var position = from;
    while (position < lower.len) : (position += 1) {
        if (lower[position] != query[depth]) continue;
        positions[depth] = @intCast(position);
        bruteForceVisit(path, lower, range_start, end_min, query, depth + 1, position + 1, positions, result);
    }
}

test "best alignment equals a brute-force search over a small alphabet" {
    const alphabet = "aAb/-1";
    const query_alphabet = "ab/-1";
    const scratch = try std.testing.allocator.create(AlignScratch);
    defer std.testing.allocator.destroy(scratch);
    var text: [4]u8 = undefined;
    var lower: [4]u8 = undefined;
    var query: [3]u8 = undefined;
    var checked: usize = 0;
    for (1..text.len + 1) |text_len| {
        var text_code: usize = 0;
        while (text_code < std.math.pow(usize, alphabet.len, text_len)) : (text_code += 1) {
            var code = text_code;
            for (text[0..text_len], lower[0..text_len]) |*byte, *folded| {
                byte.* = alphabet[code % alphabet.len];
                folded.* = asciiToLower(byte.*);
                code /= alphabet.len;
            }
            const basename_start = if (std.mem.findScalarLast(u8, text[0..text_len], '/')) |slash| slash + 1 else 0;
            const ranges = [_][2]usize{ .{ 0, 0 }, .{ basename_start, basename_start }, .{ 0, basename_start } };
            for (ranges) |range| {
                const range_start = range[0];
                const end_min = range[1];
                for (1..query.len + 1) |query_len| {
                    var query_code: usize = 0;
                    while (query_code < std.math.pow(usize, query_alphabet.len, query_len)) : (query_code += 1) {
                        var q = query_code;
                        for (query[0..query_len]) |*byte| {
                            byte.* = query_alphabet[q % query_alphabet.len];
                            q /= query_alphabet.len;
                        }
                        const brute = bruteForceAlignment(text[0..text_len], lower[0..text_len], range_start, end_min, query[0..query_len]);
                        // The pruning bound holds for every placement that crosses into the name.
                        if (brute.crossing_peak) |peak| try std.testing.expect(peak <= maxCrossingQuality(u8, query[0..query_len]));
                        const expected = brute.best;
                        const actual = alignBest(u8, lower[0..text_len], text[0..text_len], null, range_start, end_min, query[0..query_len], scratch);
                        checked += 1;
                        if (expected == null) {
                            try std.testing.expect(actual == null);
                            continue;
                        }
                        try std.testing.expectEqual(expected.?.quality, actual.?.quality);
                        try std.testing.expectEqual(expected.?.first_position, actual.?.first_position);
                        try std.testing.expect(scratch.positions[query_len - 1] >= end_min);
                        const placed = scoreAlignment(text[0..text_len], null, range_start, scratch.positions[0..query_len]);
                        try std.testing.expectEqual(actual.?.quality, placed.quality);
                        for (scratch.positions[0..query_len], query[0..query_len]) |position, byte| {
                            try std.testing.expectEqual(byte, lower[position]);
                        }
                    }
                }
            }
        }
    }
    try std.testing.expect(checked > 600_000);
}

test "alignment scores the greedy placement beyond the cell budget" {
    const path: [2000]u8 = @splat('a');
    const query: [100]u8 = @splat('a');
    const scratch = try std.testing.allocator.create(AlignScratch);
    defer std.testing.allocator.destroy(scratch);
    const alignment = alignBest(u8, &path, &path, null, 0, 0, &query, scratch).?;
    for (scratch.positions[0..query.len], 0..) |position, index| try std.testing.expectEqual(@as(u16, @intCast(index)), position);
    try std.testing.expectEqual(scoreAlignment(&path, null, 0, scratch.positions[0..query.len]).quality, alignment.quality);
}

fn expectPrunedRankingMatchesFullScoring(raw: []const u8, query: []const u8) ![]const u8 {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, raw);
    var search: TestSearchBuffer(max_search_results) = .{};
    const results = try search.run(&index, query);

    const Scored = struct { path: []const u8, score: MatchScore };
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(alloc);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |path| {
        if (path.len == 0) continue;
        var lower: [max_path_len]u8 = undefined;
        for (path, lower[0..path.len]) |byte, *folded| folded.* = asciiToLower(byte);
        const basename_start: u32 = if (std.mem.findScalarLast(u8, path, '/')) |slash| @intCast(slash + 1) else 0;
        if (scoreAsciiMatch(path, lower[0..path.len], basename_start, query)) |score| try scored.append(alloc, .{ .path = path, .score = score });
    }
    std.mem.sort(Scored, scored.items, {}, struct {
        fn less(_: void, left: Scored, right: Scored) bool {
            if (scoreBetter(left.score, right.score)) return true;
            if (scoreBetter(right.score, left.score)) return false;
            if (left.path.len != right.path.len) return left.path.len < right.path.len;
            return std.mem.order(u8, left.path, right.path) == .lt;
        }
    }.less);
    try std.testing.expectEqual(@min(scored.items.len, max_search_results), results.len);
    for (results, scored.items[0..results.len]) |result, expected| try std.testing.expectEqualStrings(expected.path, result.path);
    // The first result's path lives in `raw`, which the caller owns.
    const first = scored.items[0].path;
    return first;
}

test "pruned ranking keeps the results of scoring every path" {
    const alloc = std.testing.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    for (0..12) |i| try raw.print(alloc, "src/tools/alpha/tango/x{d}.zig\n", .{i});
    for (0..80) |i| try raw.print(alloc, "pkg/{d}/st-at{d}.zig\n", .{ i, i });
    for (0..70) |i| try raw.print(alloc, "src/tools/alpha/tango/y{d}.zig\n", .{i});
    try raw.appendSlice(alloc, "docs/stat.md\nstat\nsrc/STATUS.md\n");
    try std.testing.expectEqualStrings("stat", try expectPrunedRankingMatchesFullScoring(raw.items, "stat"));
}

test "pruned ranking keeps short queries over crowded names" {
    const alloc = std.testing.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    // More than 64 names at the top score for `s` and `st`, at many path
    // lengths and with equal-length ties, then shorter and exact paths that
    // arrive after the kept results are full.
    for (0..90) |i| try raw.print(alloc, "pkg/{d}/st{d}.zig\n", .{ i % 7, i });
    for (0..40) |i| try raw.print(alloc, "deep/nested/folder/{d}/stage{d}.md\n", .{ i, i });
    for (0..30) |i| try raw.print(alloc, "a/sx{d}.ts\nb/ts{d}.ts\n", .{ i, i });
    try raw.appendSlice(alloc, "zz/st.md\nq/s\nst\nx/s.zig\npkg/0/st0.zig\nw/st1.zi\n");
    _ = try expectPrunedRankingMatchesFullScoring(raw.items, "s");
    try std.testing.expectEqualStrings("st", try expectPrunedRankingMatchesFullScoring(raw.items, "st"));
}

test "pruned ranking keeps exact matches once the kept results are all exact" {
    const alloc = std.testing.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    for (0..70) |i| try raw.print(alloc, "service/{d}/main.zig\n", .{i});
    for (0..30) |i| try raw.print(alloc, "x/mainframe{d}.zig\n", .{i});
    try raw.appendSlice(alloc, "src/main.zig\nmain.zig\n");
    try std.testing.expectEqualStrings("main.zig", try expectPrunedRankingMatchesFullScoring(raw.items, "main"));
}

test "pruned ranking keeps folder-and-name matches" {
    const alloc = std.testing.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    // Name matches of every strength, matches through the own folder, matches
    // that only end in a folder, and perfect names that end the crossing search.
    for (0..40) |i| try raw.print(alloc, "pkg/{d}/vercel-error{d}.ts\n", .{ i, i });
    for (0..30) |i| try raw.print(alloc, "docs/{d}/vercel-json/clean{d}.mdx\n", .{ i, i });
    for (0..30) |i| try raw.print(alloc, "vercel/cle/x{d}/z.md\n", .{i});
    for (0..20) |i| try raw.print(alloc, "v/e/r/c/l/e{d}.txt\n", .{i});
    for (0..70) |i| try raw.print(alloc, "lib/{d}/vercle{d}.ts\n", .{ i, i });
    try raw.appendSlice(alloc, "apps/vercle.ts\n");
    try std.testing.expectEqualStrings("apps/vercle.ts", try expectPrunedRankingMatchesFullScoring(raw.items, "vercle"));
    // Without the perfect names the crossing search is never skipped by rank.
    const cut = std.mem.find(u8, raw.items, "lib/0/").?;
    _ = try expectPrunedRankingMatchesFullScoring(raw.items[0..cut], "vercle");
}

test "file and directory candidates have no ranking priority" {
    const alloc = std.testing.allocator;
    const first_kinds = [_]Candidate{
        .{ .path = "src/zeta.txt", .kind = .file },
        .{ .path = "src/beta.txt", .kind = .directory },
    };
    const reversed_kinds = [_]Candidate{
        .{ .path = "src/zeta.txt", .kind = .directory },
        .{ .path = "src/beta.txt", .kind = .file },
    };

    for ([_][]const Candidate{ &first_kinds, &reversed_kinds }) |candidates| {
        var index = FileIndex{};
        defer index.deinit(alloc);
        try index.buildFromCandidates(alloc, candidates);
        var results: [2]SearchResult = undefined;
        var spans: [8]MatchSpan = undefined;
        try std.testing.expectEqual(@as(usize, 2), try index.searchTyped("ta", &results, &spans));
        try std.testing.expectEqualStrings("src/beta.txt", results[0].path);
        try std.testing.expectEqualStrings("src/zeta.txt", results[1].path);
    }
}

test "typed empty search preserves mixed inventory order without spans" {
    const alloc = std.testing.allocator;
    const candidates = [_]Candidate{
        .{ .path = "src", .kind = .directory },
        .{ .path = "src/main.zig", .kind = .file },
        .{ .path = "docs", .kind = .directory },
    };
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromCandidates(alloc, &candidates);

    var results: [2]SearchResult = undefined;
    try std.testing.expectEqual(@as(usize, 2), try index.searchTyped("", &results, &.{}));
    try std.testing.expectEqualStrings("src", results[0].path);
    try std.testing.expectEqual(CandidateKind.directory, results[0].kind);
    try std.testing.expectEqual(@as(usize, 0), results[0].matched_spans.len);
    try std.testing.expectEqualStrings("src/main.zig", results[1].path);
    try std.testing.expectEqual(CandidateKind.file, results[1].kind);
}

test "punctuation remains matchable under case-insensitive subsequence search" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "src/API-route.ts\nsrc/api_handler.ts\n");

    var results: [4]SearchResult = undefined;
    var spans: [16]MatchSpan = undefined;
    try std.testing.expectEqual(@as(usize, 1), try index.searchTyped("api-rt", &results, &spans));
    try std.testing.expectEqualStrings("src/API-route.ts", results[0].path);
    try expectValidSearchSpans(results[0]);
}

test "search is case-insensitive" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);

    const raw = "README.md\nsrc/Main.zig\n";
    try index.buildFromRaw(alloc, raw);

    var readme_search: TestSearchBuffer(4) = .{};
    const readme_results = try readme_search.run(&index, "README");
    try std.testing.expect(readme_results.len >= 1);
    try std.testing.expectEqualStrings("README.md", readme_results[0].path);

    var lowercase_search: TestSearchBuffer(4) = .{};
    const lowercase_results = try lowercase_search.run(&index, "readme");
    try std.testing.expect(lowercase_results.len >= 1);
    try std.testing.expectEqualStrings("README.md", lowercase_results[0].path);

    var main_search: TestSearchBuffer(4) = .{};
    const main_results = try main_search.run(&index, "main");
    try std.testing.expect(main_results.len >= 1);
    try std.testing.expectEqualStrings("src/Main.zig", main_results[0].path);
}

test "search uses Unicode 17 simple folding and preserves raw spelling" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);

    try index.buildFromRaw(alloc, "docs/Ärger-file.txt\x00docs/Σigma.txt\x00docs/ςigma-final.txt\x00docs/Kelvin.txt\x00docs/kettle.txt\x00");

    var search: TestSearchBuffer(8) = .{};
    const arger_results = try search.run(&index, "ärger");
    try std.testing.expectEqual(@as(usize, 1), arger_results.len);
    try std.testing.expectEqualStrings("docs/Ärger-file.txt", arger_results[0].path);

    const sigma_results = try search.run(&index, "σigma");
    try std.testing.expectEqual(@as(usize, 2), sigma_results.len);
    try std.testing.expectEqualStrings("docs/Σigma.txt", sigma_results[0].path);

    const kelvin_results = try search.run(&index, "kelvin");
    try std.testing.expect(kelvin_results.len >= 1);
    try std.testing.expectEqualStrings("docs/Kelvin.txt", kelvin_results[0].path);

    const ascii_k_results = try search.run(&index, "k");
    try std.testing.expect(ascii_k_results.len >= 2);
    var saw_kelvin = false;
    for (ascii_k_results) |result| {
        if (std.mem.eql(u8, result.path, "docs/Kelvin.txt")) saw_kelvin = true;
    }
    try std.testing.expect(saw_kelvin);

    const kelvin_query_results = try search.run(&index, "K");
    try std.testing.expect(kelvin_query_results.len >= 2);
    var saw_ascii_k = false;
    for (kelvin_query_results) |result| {
        if (std.mem.eql(u8, result.path, "docs/kettle.txt")) saw_ascii_k = true;
    }
    try std.testing.expect(saw_ascii_k);
}

test "Unicode search keeps normalization and full folding out of scope" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "Ärger.txt\x00Fuß.txt\x00");

    var search: TestSearchBuffer(4) = .{};
    try std.testing.expectEqual(@as(usize, 0), (try search.run(&index, "A\u{0308}rger")).len);
    try std.testing.expectEqual(@as(usize, 0), (try search.run(&index, "Fuss")).len);
}

test "Unicode search rejects invalid and truncated UTF-8 queries" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "Ärger.txt\x00");

    var search: TestSearchBuffer(4) = .{};
    try std.testing.expectEqual(@as(usize, 0), (try search.run(&index, "\xff")).len);
    try std.testing.expectEqual(@as(usize, 0), (try search.run(&index, "\xc3")).len);
}

test "typed Unicode subsequences preserve simple-fold spelling and scalar spans" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "docs/Ärger-Kelvin.txt\x00docs/kettle.txt\x00");

    var results: [4]SearchResult = undefined;
    var spans: [32]MatchSpan = undefined;
    try std.testing.expectEqual(@as(usize, 1), try index.searchTyped("ärgk", &results, &spans));
    try std.testing.expectEqualStrings("docs/Ärger-Kelvin.txt", results[0].path);
    try expectValidSearchSpans(results[0]);

    const kelvin_count = try index.searchTyped("kelvin", &results, &spans);
    try std.testing.expect(kelvin_count >= 1);
    try std.testing.expectEqualStrings("docs/Ärger-Kelvin.txt", results[0].path);
    try std.testing.expect(std.mem.find(u8, results[0].path, "Kelvin") != null);
}

test "typed spans keep combining display sequences intact" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "docs/Cafe\u{0301}-note.txt\x00");

    var results: [2]SearchResult = undefined;
    var spans: [16]MatchSpan = undefined;
    try std.testing.expectEqual(@as(usize, 1), try index.searchTyped("e\u{0301}n", &results, &spans));
    try std.testing.expectEqualStrings("docs/Cafe\u{0301}-note.txt", results[0].path);
    try expectValidSearchSpans(results[0]);
    try std.testing.expect(results[0].matched_spans.len >= 1);
    const first = results[0].matched_spans[0];
    try std.testing.expectEqualStrings("e\u{0301}", results[0].path[first.byte_start..first.byte_end]);

    try std.testing.expectEqual(@as(usize, 1), try index.searchTyped("\u{0301}", &results, &spans));
    try std.testing.expectEqual(@as(usize, 1), results[0].matched_spans.len);
    const combining = results[0].matched_spans[0];
    try std.testing.expectEqualStrings("e\u{0301}", results[0].path[combining.byte_start..combining.byte_end]);
}

test "typed search handles repeated query scalars" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "src/axaya.zig\x00src/alpha.zig\x00");

    var results: [4]SearchResult = undefined;
    var spans: [16]MatchSpan = undefined;
    try std.testing.expectEqual(@as(usize, 1), try index.searchTyped("aaa", &results, &spans));
    try std.testing.expectEqualStrings("src/axaya.zig", results[0].path);
    try expectValidSearchSpans(results[0]);
}

test "typed invalid UTF-8 and no-match queries return no results" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "docs/Ärger.txt\x00");

    var results: [4]SearchResult = undefined;
    var spans: [16]MatchSpan = undefined;
    try std.testing.expectEqual(@as(usize, 0), try index.searchTyped("\xff", &results, &spans));
    try std.testing.expectEqual(@as(usize, 0), try index.searchTyped("\xc3", &results, &spans));
    try std.testing.expectEqual(@as(usize, 0), try index.searchTyped("not-present", &results, &spans));
}

test "interleaved typed searches keep generation and prior caller metadata stable" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "src/main.zig\x00docs/Ärger.txt\x00src/core/file_index.zig\x00");

    const generation = index.active_generation.?;
    const paths_before = try alloc.dupe(u8, generation.paths_buf);
    defer alloc.free(paths_before);
    const lower_before = try alloc.dupe(u8, generation.lower_buf);
    defer alloc.free(lower_before);

    var first_results: [4]SearchResult = undefined;
    var first_spans: [16]MatchSpan = undefined;
    const first_count = try index.searchTyped("mn", &first_results, &first_spans);
    try std.testing.expect(first_count >= 1);
    const first_path = first_results[0].path;
    const first_span_count = first_results[0].matched_spans.len;

    var repeated_results: [4]SearchResult = undefined;
    var repeated_spans: [16]MatchSpan = undefined;
    const repeated_count = try index.searchTyped("mn", &repeated_results, &repeated_spans);
    try std.testing.expectEqual(first_count, repeated_count);
    for (first_results[0..first_count], repeated_results[0..repeated_count]) |first_result, repeated_result| {
        try std.testing.expectEqualStrings(first_result.path, repeated_result.path);
        try std.testing.expectEqualSlices(MatchSpan, first_result.matched_spans, repeated_result.matched_spans);
    }

    var second_results: [4]SearchResult = undefined;
    var second_spans: [16]MatchSpan = undefined;
    try std.testing.expectEqual(@as(usize, 1), try index.searchTyped("är", &second_results, &second_spans));
    try std.testing.expectEqualStrings("docs/Ärger.txt", second_results[0].path);

    try std.testing.expectEqualStrings(first_path, first_results[0].path);
    try std.testing.expectEqual(first_span_count, first_results[0].matched_spans.len);
    try expectValidSearchSpans(first_results[0]);
    try std.testing.expectEqualSlices(u8, paths_before, generation.paths_buf);
    try std.testing.expectEqualSlices(u8, lower_before, generation.lower_buf);
}

test "typed search sustains one thousand alternating ASCII and Unicode queries without mutating its generation" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(
        alloc,
        "src/main.zig\x00docs/Cafe\u{0301}-note.txt\x00docs/Ärger-Kelvin.txt\x00src/core/workspace/file_index.zig\x00",
    );

    const generation = index.active_generation.?;
    const paths_before = try alloc.dupe(u8, generation.paths_buf);
    defer alloc.free(paths_before);
    const lower_before = try alloc.dupe(u8, generation.lower_buf);
    defer alloc.free(lower_before);
    const offsets_before = try alloc.dupe(u32, generation.offsets);
    defer alloc.free(offsets_before);
    const kinds_before = try alloc.dupe(CandidateKind, generation.kinds);
    defer alloc.free(kinds_before);

    const queries = [_][]const u8{ "mn", "e\u{0301}n", "ärgk", "scwfi", "zzz" };
    var checksum: usize = 0;
    for (0..1_000) |iteration| {
        var results: [8]SearchResult = undefined;
        var spans: [64]MatchSpan = undefined;
        const query = queries[iteration % queries.len];
        const count = try index.searchTyped(query, &results, &spans);
        checksum +%= count;
        for (results[0..count]) |result| {
            try expectValidSearchSpans(result);
            checksum +%= result.path.len + result.matched_spans.len;
        }
    }

    try std.testing.expect(checksum > 0);
    try std.testing.expectEqualSlices(u8, paths_before, generation.paths_buf);
    try std.testing.expectEqualSlices(u8, lower_before, generation.lower_buf);
    try std.testing.expectEqualSlices(u32, offsets_before, generation.offsets);
    try std.testing.expectEqualSlices(CandidateKind, kinds_before, generation.kinds);
}

test "typed search reports insufficient caller span storage" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "src/axbyc.zig\x00");

    var results: [1]SearchResult = undefined;
    var spans: [2]MatchSpan = undefined;
    try std.testing.expectError(error.NoSpaceLeft, index.searchTyped("abc", &results, &spans));
}

test "Unicode search compares mixed basename and full-path scores" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "docs/Ärger.txt\x00Ärger/docs.txt\x00");

    var search: TestSearchBuffer(4) = .{};
    const results = try search.run(&index, "ärger");
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("docs/Ärger.txt", results[0].path);
    try std.testing.expectEqualStrings("Ärger/docs.txt", results[1].path);
}

test "search with empty query returns files in index order" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);

    const raw = "a.zig\nb.zig\nc.zig\n";
    try index.buildFromRaw(alloc, raw);

    var search: TestSearchBuffer(2) = .{};
    const results = try search.run(&index, "");
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("a.zig", results[0].path);
    try std.testing.expectEqualStrings("b.zig", results[1].path);
}

test "bitmap prefilter does not reject when query has no a-z letters" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);

    const raw = "docs/123.md\nsrc/main.zig\n";
    try index.buildFromRaw(alloc, raw);

    var search: TestSearchBuffer(4) = .{};
    const results = try search.run(&index, "123");
    try std.testing.expect(results.len >= 1);
    try std.testing.expectEqualStrings("docs/123.md", results[0].path);
}

test "bitmap prefilter rejects when required letter is absent" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);

    const raw = "docs/readme.md\nsrc/main.zig\n";
    try index.buildFromRaw(alloc, raw);

    var search: TestSearchBuffer(4) = .{};
    try std.testing.expectEqual(@as(usize, 0), (try search.run(&index, "xyz")).len);
}

test "search returns zero when index is not ready" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    var search: TestSearchBuffer(4) = .{};
    try std.testing.expectEqual(@as(usize, 0), (try search.run(&index, "x")).len);
}

test "search returns zero when the index has failed" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    index.initial_failed = true;

    var search: TestSearchBuffer(4) = .{};
    try std.testing.expectEqual(@as(usize, 0), (try search.run(&index, "main")).len);
}

test "search returns partial results while ready_count is below total" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);

    try index.buildFromRaw(alloc, "src/wasm_term_main.zig\nsrc/main.zig\nREADME.md\nsrc/core/shared/io.zig\n");
    try std.testing.expectEqual(@as(usize, 4), index.count());

    const generation = index.active_generation.?;
    index.active_generation = null;
    index.loading_generation = generation;
    generation.state.store(@backingInt(GenerationState.loading), .release);
    generation.ready_count.store(2, .release);
    try std.testing.expectEqual(@as(usize, 2), index.count());

    var search: TestSearchBuffer(4) = .{};
    const results = try search.run(&index, "main");
    try std.testing.expectEqual(@as(usize, 2), results.len);
    for (results) |result| {
        try std.testing.expect(std.mem.find(u8, result.path, "main") != null);
    }

    generation.ready_count.store(4, .release);
    try std.testing.expectEqual(@as(usize, 2), (try search.run(&index, "main")).len);

    const readme_results = try search.run(&index, "README");
    try std.testing.expectEqual(@as(usize, 1), readme_results.len);
    try std.testing.expectEqualStrings("README.md", readme_results[0].path);
}

test "search caps ranked results at 64 even with larger output" {
    const alloc = std.testing.allocator;
    var raw_builder: std.Io.Writer.Allocating = .init(alloc);
    errdefer raw_builder.deinit();

    var i: usize = 0;
    while (i < 80) : (i += 1) {
        try raw_builder.writer.print("src/match-{d:0>3}.zig\n", .{i});
    }

    const raw = try raw_builder.toOwnedSlice();
    defer alloc.free(raw);

    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, raw);

    var search: TestSearchBuffer(80) = .{};
    const results = try search.run(&index, "match");
    try std.testing.expectEqual(@as(usize, 64), results.len);

    const generation = index.active_generation.?;
    const paths_start = @intFromPtr(generation.paths_buf.ptr);
    const paths_end = paths_start + generation.paths_buf.len;

    i = 0;
    while (i < results.len) : (i += 1) {
        const ptr = @intFromPtr(results[i].path.ptr);
        try std.testing.expect(ptr >= paths_start);
        try std.testing.expect(ptr + results[i].path.len <= paths_end);

        var expected_buf: [32]u8 = undefined;
        const expected = try std.mem.print(&expected_buf, "src/match-{d:0>3}.zig", .{i});
        try std.testing.expectEqualStrings(expected, results[i].path);
        try std.testing.expectEqual(CandidateKind.file, results[i].kind);
        try expectValidSearchSpans(results[i]);
    }
}

test "search rejects queries longer than max_path_len" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);

    const path = text_utils.repeat("a", max_path_len);
    const query = text_utils.repeat("a", max_path_len) ++ "b";
    try index.buildFromRaw(alloc, path);

    var search: TestSearchBuffer(1) = .{};
    try std.testing.expectEqual(@as(usize, 0), (try search.run(&index, query)).len);
}

test "persisted file index paints a stale preview and the real scan replaces it" {
    const alloc = std.testing.allocator;
    // The tree must live outside this repository: repo-contained temp dirs
    // become git-authoritative, and a git failure would replace the walk.
    var random_suffix: [8]u8 = undefined;
    io_mod.getIo().random(&random_suffix);
    const base = try alloc.print("/tmp/fx-fileidx-{s}", .{std.fmt.bytesToHex(random_suffix, .lower)});
    defer alloc.free(base);
    const zio = io_mod.getIo();
    var base_dir = try std.Io.Dir.openDirAbsolute(zio, "/", .{});
    defer base_dir.close(zio);
    const base_rel = std.mem.trimStart(u8, base, "/");
    const home_rel = try alloc.print("{s}/home", .{base_rel});
    defer alloc.free(home_rel);
    const work_rel = try alloc.print("{s}/work", .{base_rel});
    defer alloc.free(work_rel);
    try base_dir.createDirPath(zio, home_rel);
    defer base_dir.deleteTree(zio, base_rel) catch {};
    try base_dir.createDirPath(zio, work_rel);

    const home_joined = try std.Io.Dir.path.join(alloc, &.{ base, "home" });
    defer alloc.free(home_joined);
    const work_joined = try std.Io.Dir.path.join(alloc, &.{ base, "work" });
    defer alloc.free(work_joined);
    const home = try io_mod.realpathAlloc(alloc, home_joined);
    defer alloc.free(home);
    const root = try io_mod.realpathAlloc(alloc, work_joined);
    defer alloc.free(root);

    var work_dir = try std.Io.Dir.openDirAbsolute(zio, root, .{});
    defer work_dir.close(zio);
    for ([_][]const u8{ "main.zig", "lib.zig" }) |name| {
        var file = try work_dir.createFile(zio, name, .{ .truncate = true });
        file.close(zio);
    }

    var home_map = std.process.Environ.Map.init(alloc);
    defer home_map.deinit();
    try home_map.put("HOME", home);
    io_mod.setEnvironMap(&home_map);
    defer io_mod.resetEnvironForTest();

    const scope = workspace_access.AccessScope.primaryOnly(root);
    const roots = [_][]const u8{root};

    // First launch: real scan, no cache yet.
    var first = FileIndex{};
    defer first.deinit(alloc);
    first.ensureScopeEpoch(alloc, scope, 1);
    var adoptions: usize = 0;
    var deadline = io_mod.milliTimestamp() + 5000;
    while (io_mod.milliTimestamp() < deadline) {
        if (first.joinThreadIfDone(alloc)) adoptions += 1;
        if (first.currentState() == .ready and first.thread == null) break;
        sleepBlocking(1);
    }
    const scanned_count = first.count();
    try std.testing.expectEqual(@as(usize, 1), adoptions);
    try std.testing.expect(scanned_count >= 2);
    const snapshot_file = (try snapshotPath(alloc, &roots)).?;
    defer alloc.free(snapshot_file);
    var cached = (try indexer.loadSnapshot(alloc, snapshot_file, &roots)).?;
    defer cached.deinit();
    try std.testing.expect(cached.trees[0].entries.len > 0);

    // The tree changes between launches.
    {
        var file = try work_dir.createFile(zio, "added.zig", .{ .truncate = true });
        file.close(zio);
    }

    // Second launch: the cache paints one preview generation, then the real
    // scan replaces it with the added file.
    var second = FileIndex{};
    defer second.deinit(alloc);
    second.ensureScopeEpoch(alloc, scope, 2);
    adoptions = 0;
    var counts: [2]usize = .{ 0, 0 };
    deadline = io_mod.milliTimestamp() + 5000;
    while (io_mod.milliTimestamp() < deadline and adoptions < 2) {
        if (second.joinThreadIfDone(alloc)) {
            counts[adoptions] = second.count();
            adoptions += 1;
        }
        if (adoptions == 2) break;
        sleepBlocking(1);
    }
    try std.testing.expectEqual(@as(usize, 2), adoptions);
    try std.testing.expectEqual(scanned_count, counts[0]);
    try std.testing.expectEqual(scanned_count + 1, counts[1]);
    try std.testing.expectEqual(.ready, second.currentState());
}

test "buildFromRaw omits unsafe controls and preserves neighboring safe paths" {
    const alloc = std.testing.allocator;

    var newline_index = FileIndex{};
    defer newline_index.deinit(alloc);
    try newline_index.buildFromRaw(alloc, "safe-before\nnewline-path\r\nsafe-after\n");
    try std.testing.expectEqual(@as(usize, 3), newline_index.count());
    try std.testing.expectEqualStrings("newline-path", newline_index.pathAt(1));

    var nul_index = FileIndex{};
    defer nul_index.deinit(alloc);
    try nul_index.buildFromRaw(alloc, "safe.txt\x00escape-\x1b[2J.txt\x00cr-path\r\x00invalid-\xff\x00other.txt\x00");
    try std.testing.expectEqual(@as(usize, 2), nul_index.count());
    try std.testing.expectEqualStrings("safe.txt", nul_index.pathAt(0));
    try std.testing.expectEqualStrings("other.txt", nul_index.pathAt(1));
}

test "scope discovery emits primary-relative and added-absolute paths in root order" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "primary");
    try tmp.dir.createDirPath(io_mod.getIo(), "shared/nested");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "primary/main.zig", .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "shared/nested/lib.zig", .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const shared = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "shared");
    defer alloc.free(shared);
    const shared_file = try std.Io.Dir.path.join(alloc, &.{ shared, "nested/lib.zig" });
    defer alloc.free(shared_file);
    const shared_directory = try std.Io.Dir.path.join(alloc, &.{ shared, "nested" });
    defer alloc.free(shared_directory);
    const roots = [_][]const u8{ primary, shared };
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var scope = try TestScope.init(arena_state.allocator(), &roots);
    defer scope.deinit();
    const candidates = scope.candidates;

    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromCandidates(alloc, candidates);
    try std.testing.expectEqual(@as(usize, 3), index.count());
    try std.testing.expectEqualStrings("main.zig", index.pathAt(0));
    try std.testing.expectEqual(CandidateKind.file, index.kindAt(0));
    try std.testing.expectEqualStrings(shared_directory, index.pathAt(1));
    try std.testing.expectEqual(CandidateKind.directory, index.kindAt(1));
    try std.testing.expectEqualStrings(shared_file, index.pathAt(2));
    try std.testing.expectEqual(CandidateKind.file, index.kindAt(2));
}

test "production scope admits tracked untracked hidden and direct directory candidates" {
    if (comptime @import("builtin").target.os.tag == .windows or @import("builtin").target.os.tag == .wasi) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "root/.hidden");
    try tmp.dir.createDirPath(io_mod.getIo(), "root/nested/deep");
    try tmp.dir.createDirPath(io_mod.getIo(), "root/ignored-dir");
    try tmp.dir.createDirPath(io_mod.getIo(), "root/empty-dir");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "root/.gitignore", .{ .truncate = true });
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "ignored.txt\nignored-dir/\n");
    }
    const file_paths = [_][]const u8{
        "root/tracked.txt",
        "root/untracked.txt",
        "root/.hidden/tracked.txt",
        "root/.hidden/untracked.txt",
        "root/nested/deep/item.txt",
        "root/ignored.txt",
        "root/ignored-dir/item.txt",
    };
    for (file_paths) |path| {
        var file = try tmp.dir.createFile(io_mod.getIo(), path, .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    for (0..40) |index| {
        var path_storage: [64]u8 = undefined;
        const path = try std.mem.print(&path_storage, "root/z-file-{d:0>2}.txt", .{index});
        var file = try tmp.dir.createFile(io_mod.getIo(), path, .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    if (comptime @import("builtin").target.os.tag != .windows) {
        try tmp.dir.symLink(std.testing.io, "nested", "root/linked-dir", .{ .is_directory = true });
    }

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "root");
    defer alloc.free(root);
    try runGitForFileIndexTest(alloc, root, &.{ "git", "init", "--quiet" });
    try runGitForFileIndexTest(alloc, root, &.{ "git", "add", ".gitignore", "tracked.txt", ".hidden/tracked.txt" });

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var scope = try TestScope.init(arena_state.allocator(), &.{root});
    defer scope.deinit();
    const candidates = scope.candidates;

    try std.testing.expect(containsCandidate(candidates, "tracked.txt", .file));
    try std.testing.expect(containsCandidate(candidates, "untracked.txt", .file));
    try std.testing.expect(containsCandidate(candidates, ".hidden/tracked.txt", .file));
    try std.testing.expect(containsCandidate(candidates, ".hidden/untracked.txt", .file));
    try std.testing.expect(containsCandidate(candidates, ".hidden", .directory));
    try std.testing.expect(containsCandidate(candidates, "nested/deep/item.txt", .file));
    try std.testing.expect(containsCandidate(candidates, "nested/deep", .directory));
    try std.testing.expect(containsCandidate(candidates, "nested", .directory));
    try std.testing.expect(containsCandidate(candidates, "linked-dir", .file));
    try std.testing.expect(!containsCandidate(candidates, "linked-dir", .directory));
    try std.testing.expect(!containsCandidate(candidates, "ignored.txt", .file));
    try std.testing.expect(!containsCandidate(candidates, "ignored-dir", .directory));
    try std.testing.expect(containsCandidate(candidates, "empty-dir", .directory));
    for (candidates) |candidate| {
        try std.testing.expect(isPlainRelativePath(candidate.path));
    }

    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromCandidates(alloc, candidates);
    var search: TestSearchBuffer(32) = .{};
    const empty_results = try search.run(&index, "");
    var includes_directory = false;
    for (empty_results) |result| includes_directory = includes_directory or result.kind == .directory;
    try std.testing.expect(includes_directory);
}

test "scope discovery deduplicates overlapping roots and tolerates one failed root" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "primary/nested");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "primary/nested/item.txt", .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const nested = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary/nested");
    defer alloc.free(nested);
    const missing = try std.Io.Dir.path.join(alloc, &.{ primary, "missing" });
    defer alloc.free(missing);
    const roots = [_][]const u8{ primary, nested, missing };
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var scope = try TestScope.init(arena_state.allocator(), &roots);
    defer scope.deinit();
    const candidates = scope.candidates;

    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromCandidates(alloc, candidates);
    try std.testing.expectEqual(@as(usize, 2), index.count());
    try std.testing.expectEqualStrings("nested", index.pathAt(0));
    try std.testing.expectEqual(CandidateKind.directory, index.kindAt(0));
    try std.testing.expectEqualStrings("nested/item.txt", index.pathAt(1));
    try std.testing.expectEqual(CandidateKind.file, index.kindAt(1));
}

test "typed current candidate validation rejects missing and changed kinds" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "primary/folder");
    try tmp.dir.createDirPath(io_mod.getIo(), "primary/directory-to-file");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "primary/file.txt", .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "primary/file-to-directory", .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);

    var index = FileIndex{};
    defer index.deinit(alloc);
    index.roots = try cloneRoots(alloc, &.{primary});

    try std.testing.expect(index.isCurrentCandidateKind("file.txt", .file));
    try std.testing.expect(!index.isCurrentCandidateKind("file.txt", .directory));
    try std.testing.expect(index.isCurrentCandidateKind("folder", .directory));
    try std.testing.expect(!index.isCurrentCandidateKind("folder", .file));
    try std.testing.expect(!index.isCurrentCandidateKind("missing", .file));
    try std.testing.expect(!index.isCurrentCandidateKind("unsafe\x1b", .file));

    try tmp.dir.deleteFile(io_mod.getIo(), "primary/file-to-directory");
    try tmp.dir.createDir(io_mod.getIo(), "primary/file-to-directory", .default_dir);
    try std.testing.expect(!index.isCurrentCandidateKind("file-to-directory", .file));
    try std.testing.expect(index.isCurrentCandidateKind("file-to-directory", .directory));

    try tmp.dir.deleteDir(io_mod.getIo(), "primary/directory-to-file");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "primary/directory-to-file", .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    try std.testing.expect(!index.isCurrentCandidateKind("directory-to-file", .directory));
    try std.testing.expect(index.isCurrentCandidateKind("directory-to-file", .file));
}

test "typed current candidate validation keeps symlinks as file references" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "primary/target-dir");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "primary/target.txt", .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    try tmp.dir.symLink(std.testing.io, "target.txt", "primary/file-link", .{ .is_directory = false });
    try tmp.dir.symLink(std.testing.io, "target-dir", "primary/directory-link", .{ .is_directory = true });
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);

    var index = FileIndex{};
    defer index.deinit(alloc);
    index.roots = try cloneRoots(alloc, &.{primary});

    try std.testing.expect(index.isCurrentCandidateKind("file-link", .file));
    try std.testing.expect(!index.isCurrentCandidateKind("file-link", .directory));
    try std.testing.expect(index.isCurrentCandidateKind("directory-link", .file));
    try std.testing.expect(!index.isCurrentCandidateKind("directory-link", .directory));
}

test "current candidate rejects an added-root selection after scope removal" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "primary");
    try tmp.dir.createDirPath(io_mod.getIo(), "shared");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "shared/item.txt", .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const shared = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "shared");
    defer alloc.free(shared);
    const shared_file = try std.Io.Dir.path.join(alloc, &.{ shared, "item.txt" });
    defer alloc.free(shared_file);
    const entries = [_]workspace_access.Entry{.{
        .path = @constCast(shared),
        .saved = true,
        .command_line = false,
        .available = true,
        .active = true,
    }};

    var index = FileIndex{};
    defer index.deinit(alloc);
    index.roots = try activeRootsAlloc(alloc, .{
        .primary_directory = primary,
        .additional_directories = &entries,
    });
    try std.testing.expect(index.isCurrentCandidateKind(shared_file, .file));
    try std.testing.expect(index.isCurrentCandidateKind(shared_file, .file));

    freeRoots(alloc, index.roots);
    index.roots = try activeRootsAlloc(alloc, workspace_access.AccessScope.primaryOnly(primary));
    try std.testing.expect(!index.isCurrentCandidateKind(shared_file, .file));
}

const TestLoaderGate = struct {
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cleanup_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cleanup_release: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    cleanup_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    publish_count: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    outcome: GenerationState,
};

fn testLoaderThread(generation: *Generation, gate: *TestLoaderGate) void {
    gate.started.store(true, .release);
    while (!gate.release.load(.acquire)) std.atomic.spinLoopHint();
    gate.cleanup_started.store(true, .release);
    while (!gate.cleanup_release.load(.acquire)) std.atomic.spinLoopHint();
    gate.cleanup_finished.store(true, .release);
    _ = gate.publish_count.fetchAdd(1, .seq_cst);
    const outcome: LoaderOutcome = switch (gate.outcome) {
        .loading => unreachable,
        .ready => .ready,
        .failed => .{ .failed = .{ .stage = .storage, .err = error.TestLoaderFailure } },
        .canceled => .canceled,
    };
    publishLoaderOutcomeAfterCleanup(generation, outcome);
}

fn waitForTestFlag(flag: *const std.atomic.Value(bool)) !void {
    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    while (!flag.load(.acquire)) {
        if (started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds() > 5000) {
            return error.TestUnexpectedResult;
        }
        sleepBlocking(1);
    }
}

fn waitForGenerationState(generation: *const Generation, expected: GenerationState) !void {
    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    while (generation.currentState() != expected) {
        if (started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds() > 5000) {
            return error.TestUnexpectedResult;
        }
        sleepBlocking(1);
    }
}

const TestReapAttempt = struct {
    index: *FileIndex,
    alloc: Allocator,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    visible_changed: bool = false,
};

fn testReapThread(attempt: *TestReapAttempt) void {
    attempt.started.store(true, .release);
    attempt.visible_changed = attempt.index.joinThreadIfDone(attempt.alloc);
    attempt.finished.store(true, .release);
}

fn expectReapReturnsDuringCleanup(index: *FileIndex, alloc: Allocator, gate: *TestLoaderGate) !void {
    var attempt: TestReapAttempt = .{ .index = index, .alloc = alloc };
    const thread = try std.Thread.spawn(.{}, testReapThread, .{&attempt});
    waitForTestFlag(&attempt.started) catch |err| {
        gate.cleanup_release.store(true, .release);
        thread.join();
        return err;
    };
    waitForTestFlag(&attempt.finished) catch |err| {
        gate.cleanup_release.store(true, .release);
        thread.join();
        return err;
    };
    thread.join();
    try std.testing.expect(!attempt.visible_changed);
    try std.testing.expect(!gate.cleanup_release.load(.acquire));
}

fn installTestLoader(
    index: *FileIndex,
    alloc: Allocator,
    raw_list: []const u8,
    gate: *TestLoaderGate,
) !*Generation {
    const generation_id = index.generation + 1;
    const generation = try Generation.create(alloc, generation_id);
    errdefer generation.destroy(alloc);
    try generation.fillProgressive(alloc, .{ .file_raw = raw_list }, null);

    index.loading_generation = generation;
    index.generation = generation_id;
    index.thread = std.Thread.spawn(.{}, testLoaderThread, .{ generation, gate }) catch |err| {
        index.loading_generation = null;
        return err;
    };
    waitForTestFlag(&gate.started) catch |err| {
        gate.release.store(true, .release);
        index.thread.?.join();
        index.thread = null;
        index.loading_generation = null;
        return err;
    };
    return generation;
}

test "current candidate uses pending scope while refresh is coalesced" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "primary");
    try tmp.dir.createDirPath(io_mod.getIo(), "shared");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "shared/item.txt", .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    const primary = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "primary");
    defer alloc.free(primary);
    const shared = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "shared");
    defer alloc.free(shared);
    const shared_file = try std.Io.Dir.path.join(alloc, &.{ shared, "item.txt" });
    defer alloc.free(shared_file);

    var index = FileIndex{};
    defer index.deinit(alloc);
    index.roots = try cloneRoots(alloc, &.{ primary, shared });
    var gate: TestLoaderGate = .{ .outcome = .canceled };
    _ = try installTestLoader(&index, alloc, "item.txt\x00", &gate);
    try std.testing.expect(index.isCurrentCandidateKind(shared_file, .file));
    try std.testing.expect(index.isCurrentCandidateKind(shared_file, .file));

    index.refreshScope(alloc, workspace_access.AccessScope.primaryOnly(primary));

    try std.testing.expect(!index.isCurrentCandidateKind(shared_file, .file));
    index.requestStop();
    gate.release.store(true, .release);
    try waitForGenerationState(index.loading_generation.?, .canceled);
    try std.testing.expect(!index.joinThreadIfDone(alloc));
}

test "refresh during a coalesced scope change keeps the latest roots" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    index.roots = try cloneRoots(alloc, &.{"/primary"});
    index.pending_scope = .{ .roots = try cloneRoots(alloc, &.{ "/primary", "/shared" }), .epoch = 0 };
    var gate: TestLoaderGate = .{ .outcome = .canceled };
    _ = try installTestLoader(&index, alloc, "item.txt\x00", &gate);

    index.refresh(alloc);

    const pending = (index.pending_scope orelse return error.TestExpectedEqual).roots;
    try std.testing.expectEqual(@as(usize, 2), pending.len);
    try std.testing.expectEqualStrings("/shared", pending[1]);
    index.requestStop();
    gate.release.store(true, .release);
    try waitForGenerationState(index.loading_generation.?, .canceled);
    try std.testing.expect(!index.joinThreadIfDone(alloc));
}

fn checkBuildFromRawAllocationFailures(alloc: Allocator) !void {
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "one.txt\x00two.txt\x00");
}

fn checkBuildFromCandidatesAllocationFailures(alloc: Allocator) !void {
    const candidates = [_]Candidate{
        .{ .path = "src", .kind = .directory },
        .{ .path = "src/main.zig", .kind = .file },
        .{ .path = "src", .kind = .directory },
    };
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromCandidates(alloc, &candidates);
}

test "file-only builder frees partial buffers across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkBuildFromRawAllocationFailures,
        .{},
    );
}

test "typed builder frees dedupe state and partial buffers across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkBuildFromCandidatesAllocationFailures,
        .{},
    );
}

test "kind buffer allocation failure retains the existing index" {
    const alloc = testing_allocator.no_resize;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "existing.txt\x00");

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 6 });
    try std.testing.expectError(
        error.OutOfMemory,
        index.buildFromRaw(failing.allocator(), "replacement.txt\x00other.txt\x00"),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), index.count());
    try std.testing.expectEqualStrings("existing.txt", index.pathAt(0));
    try std.testing.expectEqual(CandidateKind.file, index.kindAt(0));
}

test "refresh traces snapshot allocation failures and retains roots" {
    const alloc = testing_allocator.no_resize;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ root, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "core");

    var index = FileIndex{};
    defer index.deinit(alloc);
    index.roots = try cloneRoots(alloc, &.{ "/primary", "/shared" });

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    index.refreshScope(failing.allocator(), workspace_access.AccessScope.primaryOnly("/primary"));
    try std.testing.expect(failing.has_induced_failure);

    var refresh_failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    index.refresh(refresh_failing.allocator());
    try std.testing.expect(refresh_failing.has_induced_failure);

    try std.testing.expectEqual(@as(usize, 2), index.roots.len);
    try std.testing.expectEqualStrings("/shared", index.roots[1]);

    var trace_file = try std.Io.Dir.openFileAbsolute(std.testing.io, trace_path, .{});
    defer trace_file.close(std.testing.io);
    var read_buf: [1024]u8 = undefined;
    var reader = trace_file.reader(std.testing.io, &read_buf);
    const trace = try reader.interface.allocRemaining(alloc, std.Io.Limit.limited(4096));
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "file index scope snapshot failed") != null);
    try std.testing.expect(std.mem.find(u8, trace, "file index refresh snapshot failed") != null);
}

test "ensureScope with empty workspace root stays idle" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);

    index.ensureScope(alloc, workspace_access.AccessScope.primaryOnly(""));

    try std.testing.expectEqual(State.idle, index.currentState());
    try std.testing.expect(index.thread == null);
    try std.testing.expectEqual(@as(usize, 0), index.roots.len);
}

test "terminal publication follows worker cleanup before ready and failed reap" {
    const alloc = std.testing.allocator;

    {
        var index = FileIndex{};
        defer index.deinit(alloc);
        try index.buildFromRaw(alloc, "stable.txt\x00");
        const previous = index.active_generation.?;

        var gate: TestLoaderGate = .{ .outcome = .ready };
        gate.cleanup_release.store(false, .release);
        const replacement = try installTestLoader(&index, alloc, "replacement.txt\x00", &gate);
        gate.release.store(true, .release);
        try waitForTestFlag(&gate.cleanup_started);

        try std.testing.expect(!gate.cleanup_finished.load(.acquire));
        try std.testing.expectEqual(GenerationState.loading, replacement.currentState());
        try expectReapReturnsDuringCleanup(&index, alloc, &gate);
        try std.testing.expect(index.thread != null);
        try std.testing.expect(index.active_generation.? == previous);

        gate.cleanup_release.store(true, .release);
        try waitForGenerationState(replacement, .ready);
        try std.testing.expect(gate.cleanup_finished.load(.acquire));
        try std.testing.expectEqual(@as(u8, 1), gate.publish_count.load(.seq_cst));
        try std.testing.expect(index.joinThreadIfDone(alloc));
        try std.testing.expect(index.thread == null);
        try std.testing.expect(index.loading_generation == null);
        try std.testing.expect(index.active_generation.? == replacement);
        try std.testing.expect(!index.joinThreadIfDone(alloc));
    }

    {
        var index = FileIndex{};
        defer index.deinit(alloc);
        try index.buildFromRaw(alloc, "stable.txt\x00");
        const active = index.active_generation.?;

        var gate: TestLoaderGate = .{ .outcome = .failed };
        gate.cleanup_release.store(false, .release);
        const replacement = try installTestLoader(&index, alloc, "discarded.txt\x00", &gate);
        gate.release.store(true, .release);
        try waitForTestFlag(&gate.cleanup_started);

        try std.testing.expect(!gate.cleanup_finished.load(.acquire));
        try std.testing.expectEqual(GenerationState.loading, replacement.currentState());
        try expectReapReturnsDuringCleanup(&index, alloc, &gate);
        try std.testing.expect(index.thread != null);
        try std.testing.expect(index.active_generation.? == active);

        gate.cleanup_release.store(true, .release);
        try waitForGenerationState(replacement, .failed);
        try std.testing.expect(gate.cleanup_finished.load(.acquire));
        try std.testing.expectEqual(@as(u8, 1), gate.publish_count.load(.seq_cst));
        try std.testing.expect(!index.joinThreadIfDone(alloc));
        try std.testing.expect(index.thread == null);
        try std.testing.expect(index.loading_generation == null);
        try std.testing.expect(index.active_generation.? == active);
        try std.testing.expect(!index.joinThreadIfDone(alloc));
    }
}

test "active generation remains exclusive while replacement loads and is adopted once" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "old-one.txt\x00old-two.txt\x00");
    const old_generation = index.active_generation.?;

    var gate: TestLoaderGate = .{ .outcome = .ready };
    const replacement = try installTestLoader(&index, alloc, "new-one.txt\x00new-two.txt\x00", &gate);
    replacement.ready_count.store(1, .release);

    var search: TestSearchBuffer(4) = .{};
    var results = try search.run(&index, "");
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("old-one.txt", results[0].path);
    try std.testing.expectEqualStrings("old-two.txt", results[1].path);
    const borrowed_path = results[0].path;
    try std.testing.expect(!index.joinThreadIfDone(alloc));
    try std.testing.expectEqualStrings("old-one.txt", borrowed_path);
    try std.testing.expect(index.active_generation.? == old_generation);

    replacement.ready_count.store(2, .release);
    gate.release.store(true, .release);
    try waitForGenerationState(replacement, .ready);
    results = try search.run(&index, "");
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("old-one.txt", results[0].path);
    try std.testing.expect(index.joinThreadIfDone(alloc));
    try std.testing.expect(index.thread == null);
    try std.testing.expect(index.active_generation.? == replacement);
    try std.testing.expect(index.active_generation.? != old_generation);
    results = try search.run(&index, "");
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("new-one.txt", results[0].path);
    try std.testing.expectEqualStrings("new-two.txt", results[1].path);
    try std.testing.expect(!index.joinThreadIfDone(alloc));
}

test "failed replacement retains active results count and render facts" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "stable.txt\x00");
    const active = index.active_generation.?;

    var gate: TestLoaderGate = .{ .outcome = .failed };
    const replacement = try installTestLoader(&index, alloc, "replacement.txt\x00", &gate);
    try std.testing.expectEqual(State.ready, index.currentState());
    try std.testing.expectEqual(@as(usize, 1), index.count());

    gate.release.store(true, .release);
    try waitForGenerationState(replacement, .failed);
    try std.testing.expect(!index.joinThreadIfDone(alloc));
    try std.testing.expect(index.active_generation.? == active);
    try std.testing.expectEqual(State.ready, index.currentState());
    try std.testing.expectEqual(@as(usize, 1), index.count());
    var search: TestSearchBuffer(1) = .{};
    const results = try search.run(&index, "stable");
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("stable.txt", results[0].path);
}

test "replacement generation allocation failure retains active results" {
    const alloc = testing_allocator.no_resize;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "stable.txt\x00");
    index.roots = try cloneRoots(alloc, &.{"/primary"});
    const active = index.active_generation.?;

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expect(!index.startLoad(failing.allocator()));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(index.active_generation.? == active);
    try std.testing.expect(index.loading_generation == null);
    try std.testing.expectEqual(State.ready, index.currentState());
    try std.testing.expectEqual(@as(usize, 1), index.count());
}

test "initial allocation failure reports failure and a later load retries" {
    const alloc = testing_allocator.no_resize;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "retry.txt", .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    var index = FileIndex{};
    defer index.deinit(alloc);
    index.roots = try cloneRoots(alloc, &.{root});

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expect(!index.startLoad(failing.allocator()));
    try std.testing.expectEqual(State.failed, index.currentState());
    try std.testing.expectEqual(@as(usize, 0), index.count());

    try std.testing.expect(index.startLoad(alloc));
    const loading = index.loading_generation.?;
    const retry_started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    while (loading.currentState() == .loading) {
        if (retry_started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds() > 5000) {
            return error.TestUnexpectedResult;
        }
        sleepBlocking(1);
    }
    try std.testing.expectEqual(GenerationState.ready, loading.currentState());
    try std.testing.expect(index.joinThreadIfDone(alloc));
    try std.testing.expectEqual(State.ready, index.currentState());
    try std.testing.expectEqual(@as(usize, 1), index.count());
    try std.testing.expectEqualStrings("retry.txt", index.pathAt(0));
}

test "latest and identical refresh roots coalesce without a second loader" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    index.roots = try cloneRoots(alloc, &.{"/primary"});

    var gate: TestLoaderGate = .{ .outcome = .canceled };
    _ = try installTestLoader(&index, alloc, "item.txt\x00", &gate);
    index.refreshScope(alloc, .{
        .primary_directory = "/primary",
        .additional_directories = &.{.{
            .path = @constCast("/shared"),
            .saved = true,
            .command_line = false,
            .available = true,
            .active = true,
        }},
    });
    const first_pending = index.pending_scope.?.roots;
    index.refreshScope(alloc, .{
        .primary_directory = "/primary",
        .additional_directories = &.{.{
            .path = @constCast("/shared"),
            .saved = true,
            .command_line = false,
            .available = true,
            .active = true,
        }},
    });
    try std.testing.expect(index.pending_scope.?.roots.ptr == first_pending.ptr);

    index.refreshScope(alloc, .{
        .primary_directory = "/primary",
        .additional_directories = &.{.{
            .path = @constCast("/latest"),
            .saved = true,
            .command_line = false,
            .available = true,
            .active = true,
        }},
    });
    try std.testing.expectEqualStrings("/latest", index.pending_scope.?.roots[1]);
    try std.testing.expectEqual(@as(usize, 1), index.generation);

    index.requestStop();
    gate.release.store(true, .release);
    try waitForGenerationState(index.loading_generation.?, .canceled);
    try std.testing.expect(!index.joinThreadIfDone(alloc));
    try std.testing.expect(index.thread == null);
}

test "failed generation starts one queued refresh after reap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "queued.txt", .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "stable.txt\x00");
    index.roots = try cloneRoots(alloc, &.{root});

    var gate: TestLoaderGate = .{ .outcome = .failed };
    const failed = try installTestLoader(&index, alloc, "discarded.txt\x00", &gate);
    const previous_active = index.active_generation.?;
    index.refresh(alloc);
    gate.release.store(true, .release);
    try waitForGenerationState(failed, .failed);
    try std.testing.expect(!index.joinThreadIfDone(alloc));
    try std.testing.expectEqual(@as(usize, 3), index.generation);
    try std.testing.expect(index.thread != null);

    const queued = index.loading_generation.?;
    const queued_started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    while (queued.currentState() == .loading) {
        if (queued_started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds() > 5000) {
            return error.TestUnexpectedResult;
        }
        sleepBlocking(1);
    }
    try std.testing.expectEqual(GenerationState.ready, queued.currentState());
    try std.testing.expect(index.joinThreadIfDone(alloc));
    try std.testing.expect(index.active_generation.? != previous_active);
    try std.testing.expectEqual(@as(usize, 1), index.count());
    try std.testing.expectEqualStrings("queued.txt", index.pathAt(0));
}

test "stop before and after completion suppresses queued work" {
    const alloc = std.testing.allocator;

    {
        var index = FileIndex{};
        defer index.deinit(alloc);
        index.roots = try cloneRoots(alloc, &.{"/primary"});
        var gate: TestLoaderGate = .{ .outcome = .canceled };
        const loading = try installTestLoader(&index, alloc, "partial.txt\x00", &gate);
        index.refresh(alloc);
        index.requestStop();
        gate.release.store(true, .release);
        try waitForGenerationState(loading, .canceled);
        try std.testing.expect(!index.joinThreadIfDone(alloc));
        try std.testing.expect(index.thread == null);
        try std.testing.expectEqual(@as(usize, 1), index.generation);
        try std.testing.expect(index.pending_scope != null);
    }

    {
        var index = FileIndex{};
        defer index.deinit(alloc);
        index.roots = try cloneRoots(alloc, &.{"/primary"});
        var gate: TestLoaderGate = .{ .outcome = .ready };
        const loading = try installTestLoader(&index, alloc, "finished.txt\x00", &gate);
        index.refresh(alloc);
        gate.release.store(true, .release);
        try waitForGenerationState(loading, .ready);
        index.requestStop();
        try std.testing.expect(index.joinThreadIfDone(alloc));
        try std.testing.expectEqual(@as(usize, 1), index.generation);
        try std.testing.expectEqualStrings("finished.txt", index.pathAt(0));
    }
}

test "deinit cancels and joins one loader while suppressing queued refresh" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    index.roots = try cloneRoots(alloc, &.{"/primary"});
    index.pending_scope = .{ .roots = try cloneRoots(alloc, &.{ "/primary", "/queued" }), .epoch = 0 };
    const loading = try Generation.create(alloc, 1);
    index.loading_generation = loading;
    index.generation = 1;

    var observed_stop = std.atomic.Value(bool).init(false);
    const WaitForStop = struct {
        fn run(
            generation: *Generation,
            stop_requested: *std.atomic.Value(bool),
            observed: *std.atomic.Value(bool),
        ) void {
            while (!stop_requested.load(.seq_cst)) std.atomic.spinLoopHint();
            observed.store(true, .release);
            generation.finish(.canceled);
        }
    };
    index.thread = try std.Thread.spawn(.{}, WaitForStop.run, .{ loading, &index.stop_requested, &observed_stop });

    index.deinit(alloc);

    try std.testing.expect(observed_stop.load(.acquire));
    try std.testing.expect(index.stop_requested.load(.seq_cst));
    try std.testing.expect(index.thread == null);
    try std.testing.expect(index.loading_generation == null);
    try std.testing.expect(index.active_generation == null);
    try std.testing.expect(index.pending_scope == null);
}

test "file index raw-list and Unicode query bytes remain bounded" {
    try std.testing.fuzz({}, fuzzRawListAndQuery, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "safe.txt\x00ärger",
            "escape-\x1b[2J.txt\x00\xff",
            "Ärger-file.txt\x00ärger",
            "docs/Kelvin.txt\x00k",
            "src/core/file_index.zig\x00fiidx",
            "docs/Cafe\u{0301}.txt\x00e\u{0301}",
            "src/axaya.zig\x00aaa",
            "truncated.txt\x00\xc3",
        }) ++ @import("fuzz_corpus").file_index.*),
    });
}

fn fuzzRawListAndQuery(_: void, smith: *std.testing.Smith) !void {
    var bytes: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&bytes));
    const split = len / 2;

    var index = FileIndex{};
    defer index.deinit(std.testing.allocator);
    try index.buildFromRaw(std.testing.allocator, bytes[0..split]);

    var typed_results: [8]SearchResult = undefined;
    var span_storage: [8 * max_path_len]MatchSpan = undefined;
    const typed_count = try index.searchTyped(bytes[split..len], &typed_results, &span_storage);
    for (typed_results[0..typed_count]) |typed| {
        try std.testing.expect(typed.path.len <= max_path_len);
        try std.testing.expect(text_utils.isTerminalSafe(typed.path));
        try std.testing.expectEqual(CandidateKind.file, typed.kind);
        try expectValidSearchSpans(typed);
    }
}

test "file picker readable revision captures one prefix and survives equal count replacement" {
    const alloc = std.testing.allocator;
    var index: FileIndex = .{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "a.txt\x00b.txt\x00c.txt\x00");
    const first = index.active_generation.?;
    first.scope_epoch = 7;
    first.ready_count.store(1, .release);
    const revision = index.readableRevision();
    first.ready_count.store(3, .release);
    var results: [4]SearchResult = undefined;
    var spans: [16]MatchSpan = undefined;
    try std.testing.expectEqual(@as(usize, 1), try index.searchAtRevision(revision, "txt", &results, &spans));
    try std.testing.expectEqualStrings("a.txt", results[0].path);
    try std.testing.expectEqual(@as(u64, 7), revision.scope_epoch);
    try std.testing.expectEqual(@as(usize, 3), index.readableRevision().count);
    try index.buildFromRaw(alloc, "d.txt\x00e.txt\x00f.txt\x00");
    try std.testing.expect(index.readableRevision().generation != revision.generation);
    try std.testing.expectError(error.InvalidIndexData, index.searchAtRevision(revision, "txt", &results, &spans));
}

test "file picker pending scope coalesces epochs through A B A and failed refresh" {
    const alloc = testing_allocator.no_resize;
    var index: FileIndex = .{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "stable.txt\x00");
    index.active_generation.?.scope_epoch = 1;
    index.scope_epoch = 1;
    index.roots = try cloneRoots(alloc, &.{"/A"});
    index.replacePendingRoots(alloc, try cloneRoots(alloc, &.{"/A"}), 1);
    index.replacePendingRoots(alloc, try cloneRoots(alloc, &.{"/B"}), 2);
    index.replacePendingRoots(alloc, try cloneRoots(alloc, &.{"/A"}), 3);
    try std.testing.expectEqual(@as(u64, 3), index.pending_scope.?.epoch);
    index.replacePendingRoots(alloc, try cloneRoots(alloc, &.{"/A"}), 4);
    try std.testing.expectEqual(@as(u64, 4), index.pending_scope.?.epoch);
    const pending = index.pending_scope.?.roots.ptr;
    index.replacePendingRoots(alloc, try cloneRoots(alloc, &.{"/A"}), 4);
    try std.testing.expectEqual(pending, index.pending_scope.?.roots.ptr);
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    index.refreshScopeEpoch(failing.allocator(), workspace_access.AccessScope.primaryOnly("/C"), 5);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 1), index.readableRevision().scope_epoch);
    try std.testing.expectEqual(@as(u64, 4), index.pending_scope.?.epoch);
    try std.testing.expectEqualStrings("/A", index.pending_scope.?.roots[0]);
}

fn sleepBlocking(milliseconds: u64) void {
    var sleep_io_backend: std.Io.Threaded = .init_single_threaded;
    sleep_io_backend.io().sleep(.fromMilliseconds(@intCast(milliseconds)), .real) catch {};
}

test "snapshot path changes with where git config is located" {
    const alloc = std.testing.allocator;
    const roots = [_][]const u8{"/work"};
    const cases = [_][indexer.config_environment_names.len]?[]const u8{
        .{ "/home/u", null, null, null, null },
        .{ "/home/u", "/home/u/.xdg", null, null, null },
        .{ "/home/u", "/home/u/.other", null, null, null },
        .{ "/home/u", null, "/home/u/gitconfig", null, null },
    };
    var paths: [cases.len][]const u8 = undefined;
    for (cases, &paths) |case, *path| path.* = try snapshotPathIn(alloc, "/home/u", &roots, &case);
    defer for (paths) |path| alloc.free(path);
    for (paths, 0..) |a, i| for (paths[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a, b));

    const again = try snapshotPathIn(alloc, "/home/u", &roots, &cases[1]);
    defer alloc.free(again);
    try std.testing.expectEqualStrings(paths[1], again);
    try std.testing.expect(std.mem.startsWith(u8, again, "/home/u/.fx/file-index/"));
}
