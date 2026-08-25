//! Background workspace file index for the @-mention picker.
//!
//! Each generation owns immutable parallel buffers. The loader publishes complete
//! prefixes with release stores; readers acquire `ready_count` before scanning.
//! Replacement generations remain private until the main thread adopts them.
//! Search uses pre-lowercased paths and a per-path ASCII bitmap to reject
//! impossible subsequence matches before scoring.

const std = @import("std");
const file_picker_path = @import("../input/file_picker_path.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const display_width = @import("../shared/display_width.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const unicode_simple_fold = @import("unicode_simple_fold.zig");
const pathing = @import("pathing.zig");
const workspace_access = @import("workspace_access.zig");
const workspace_files = @import("workspace_files.zig");

const Allocator = std.mem.Allocator;

pub const max_indexed_files: usize = 100_000;
pub const max_path_len: u32 = 2048;

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

const Generation = struct {
    id: usize,
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
    /// Presence bitmap for lowered bytes 0x20..0x3f (space, punctuation,
    /// digits). Companion to `char_masks`: lets the search reject entries
    /// missing a non-letter query byte without scanning. Bits only exist
    /// for 0x20..0x3f, so an uncovered byte imposes no constraint.
    punct_masks: []u32 = &.{},
    /// The loader publishes an immutable prefix with release stores after
    /// every parallel-buffer entry is complete. Search pairs this with an
    /// acquire load before reading that prefix.
    ready_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// A release store publishes the terminal outcome after all generation
    /// writes. The main thread performs an acquire load before deciding
    /// whether joining and adoption are permitted.
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(GenerationState.loading)),

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
        return @enumFromInt(self.state.load(.acquire));
    }

    fn finish(self: *Generation, state: GenerationState) void {
        self.state.store(@intFromEnum(state), .release);
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
            var punct_mask: u32 = 0;
            var contains_non_ascii = false;
            for (path, 0..) |byte, byte_index| {
                const lower = asciiToLower(byte);
                self.lower_buf[start + @as(u32, @intCast(byte_index))] = lower;
                if (byte >= 0x80) contains_non_ascii = true;
                if (lower >= 'a' and lower <= 'z') {
                    mask |= @as(u32, 1) << @intCast(lower - 'a');
                }
                if (lower >= 0x20 and lower <= 0x3f) {
                    punct_mask |= @as(u32, 1) << @intCast(lower - 0x20);
                }
            }

            const slash = std.mem.findScalarLast(u8, path, '/');
            self.basename_starts[candidate_index] = if (slash) |index|
                start + @as(u32, @intCast(index + 1))
            else
                start;
            if (contains_non_ascii) mask |= non_ascii_mask;
            self.char_masks[candidate_index] = mask;
            self.punct_masks[candidate_index] = punct_mask;
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
        const punct_masks = try alloc.alloc(u32, totals.n);
        errdefer alloc.free(punct_masks);
        const kinds = try alloc.alloc(CandidateKind, totals.n);
        errdefer alloc.free(kinds);

        self.paths_buf = paths_buf;
        self.lower_buf = lower_buf;
        self.offsets = offsets;
        self.basename_starts = basename_starts;
        self.char_masks = char_masks;
        self.punct_masks = punct_masks;
        self.kinds = kinds;
    }

    fn freeBuffers(self: *Generation, alloc: Allocator) void {
        if (self.paths_buf.len > 0) alloc.free(self.paths_buf);
        if (self.lower_buf.len > 0) alloc.free(self.lower_buf);
        if (self.offsets.len > 0) alloc.free(self.offsets);
        if (self.basename_starts.len > 0) alloc.free(self.basename_starts);
        if (self.char_masks.len > 0) alloc.free(self.char_masks);
        if (self.punct_masks.len > 0) alloc.free(self.punct_masks);
        if (self.kinds.len > 0) alloc.free(self.kinds);
        self.paths_buf = &.{};
        self.lower_buf = &.{};
        self.offsets = &.{};
        self.basename_starts = &.{};
        self.char_masks = &.{};
        self.punct_masks = &.{};
        self.kinds = &.{};
        self.ready_count.store(0, .release);
    }
};

pub const FileIndex = struct {
    /// The main thread is the sole owner allowed to replace or reclaim these
    /// generation pointers. The loader writes only `loading_generation`.
    active_generation: ?*Generation = null,
    loading_generation: ?*Generation = null,
    /// Owned roots for the current generation. The primary root is first;
    /// active additional roots follow in configured order.
    roots: [][]u8 = &.{},
    /// Owned replacement roots for one coalesced refresh while loading.
    pending_roots: ?[][]u8 = null,

    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    generation: usize = 0,
    initial_failed: bool = false,

    pub fn requestStop(self: *FileIndex) void {
        self.stop_requested.store(true, .seq_cst);
        debug_trace.logf("core", "file index shutdown requested generation={d} loader={s} active={} loading={} queued={}", .{
            self.generation,
            if (self.thread == null) "none" else "owned",
            self.active_generation != null,
            self.loading_generation != null,
            self.pending_roots != null,
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
        if (self.pending_roots) |roots| freeRoots(alloc, roots);
        self.pending_roots = null;
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
        if (self.currentState() != .idle) return;
        if (scope.primary_directory.len == 0) return;

        self.roots = activeRootsAlloc(alloc, scope) catch return;
        _ = self.startLoad(alloc);
    }

    fn startLoad(self: *FileIndex, alloc: Allocator) bool {
        if (self.roots.len == 0 or
            self.thread != null or
            self.loading_generation != null or
            self.stop_requested.load(.seq_cst)) return false;

        const generation_id = self.generation + 1;
        const loading = Generation.create(alloc, generation_id) catch |err| {
            if (self.active_generation == null) self.initial_failed = true;
            debug_trace.logf("core", "file index generation allocation failed generation={d} err={s}", .{ generation_id, @errorName(err) });
            return false;
        };
        self.loading_generation = loading;
        self.generation = generation_id;
        self.initial_failed = false;
        self.thread = std.Thread.spawn(.{}, loaderThreadMain, .{
            loading,
            alloc,
            self.roots,
            &self.stop_requested,
        }) catch |err| {
            self.loading_generation = null;
            loading.destroy(alloc);
            if (self.active_generation == null) self.initial_failed = true;
            debug_trace.logf("core", "file index generation spawn failed generation={d} err={s}", .{ generation_id, @errorName(err) });
            return false;
        };
        debug_trace.logf("core", "file index generation started generation={d} caller_thread={d}", .{ generation_id, std.Thread.getCurrentId() });
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
        switch (terminal_state) {
            .loading => unreachable,
            .ready => {
                const previous = self.active_generation;
                self.active_generation = loading;
                self.loading_generation = null;
                self.initial_failed = false;
                debug_trace.logf("core", "file index generation adopted generation={d} count={d}", .{ loading.id, loading.count() });
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
            if (self.pending_roots) |roots| {
                self.pending_roots = null;
                freeRoots(alloc, self.roots);
                self.roots = roots;
                _ = self.startLoad(alloc);
            }
        }
        return visible_changed;
    }

    /// Requests one replacement generation. A current loader retains its
    /// immutable scope and coalesces only the latest owned replacement scope.
    pub fn refresh(self: *FileIndex, alloc: Allocator) void {
        const roots = cloneRoots(alloc, self.pending_roots orelse self.roots) catch |err| {
            debug_trace.logf("core", "file index refresh snapshot failed generation={d} err={s}", .{ self.generation, @errorName(err) });
            return;
        };
        self.refreshOwnedRoots(alloc, roots);
    }

    /// Refreshes from the latest active scope. A loading generation keeps its
    /// immutable roots and receives one owned, coalesced replacement snapshot.
    pub fn refreshScope(self: *FileIndex, alloc: Allocator, scope: workspace_access.AccessScope) void {
        const roots = activeRootsAlloc(alloc, scope) catch |err| {
            debug_trace.logf("core", "file index scope snapshot failed generation={d} err={s}", .{ self.generation, @errorName(err) });
            return;
        };
        self.refreshOwnedRoots(alloc, roots);
    }

    fn refreshOwnedRoots(self: *FileIndex, alloc: Allocator, roots: [][]u8) void {
        if (self.stop_requested.load(.seq_cst)) {
            freeRoots(alloc, roots);
            debug_trace.logf("core", "file index refresh discarded during shutdown generation={d}", .{self.generation});
            return;
        }
        if (self.thread != null) {
            self.replacePendingRoots(alloc, roots);
            return;
        }

        if (self.loading_generation != null) {
            freeRoots(alloc, roots);
            debug_trace.logf("core", "file index refresh discarded with unowned loading generation={d}", .{self.generation});
            return;
        }
        freeRoots(alloc, self.roots);
        self.roots = roots;
        const started = self.startLoad(alloc);
        if (!started) debug_trace.logf("core", "file index refresh not started generation={d}", .{self.generation});
    }

    fn replacePendingRoots(self: *FileIndex, alloc: Allocator, roots: [][]u8) void {
        if (self.pending_roots) |pending| {
            if (rootsEqual(pending, roots)) {
                freeRoots(alloc, roots);
                debug_trace.logf("core", "file index refresh coalesced generation={d} identical=true", .{self.generation});
                return;
            }
            freeRoots(alloc, pending);
            debug_trace.logf("core", "file index pending refresh superseded generation={d}", .{self.generation});
        }
        self.pending_roots = roots;
        debug_trace.logf("core", "file index refresh coalesced generation={d} identical=false", .{self.generation});
    }

    pub fn isCurrentCandidateKind(self: *const FileIndex, path: []const u8, expected_kind: CandidateKind) bool {
        const current_roots = self.pending_roots orelse self.roots;
        if (!text_utils.isTerminalSafe(path) or current_roots.len == 0) return false;
        const root_path, const relative = if (std.fs.path.isAbsolute(path)) resolved: {
            for (current_roots) |root| {
                if (!pathing.pathInside(root, path)) continue;
                const rel = pathing.workspaceRelativePath(std.heap.c_allocator, root, path) catch return false;
                break :resolved .{ root, rel };
            }
            return false;
        } else .{ current_roots[0], path };
        defer if (std.fs.path.isAbsolute(path)) std.heap.c_allocator.free(relative);
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
        if (out.len == 0) return 0;
        const generation = self.searchableGeneration() orelse return 0;
        const total = generation.count();
        if (total == 0 or query.len > max_path_len) return 0;

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
        const result_count = rankTopN(generation, prepared, indices[0..@min(out.len, max_search_results)]);

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
) void {
    debug_trace.logf("core", "file index loader entered generation={d} worker_thread={d}", .{ generation.id, std.Thread.getCurrentId() });
    const outcome = loadGeneration(generation, alloc, roots, stop_requested);
    publishLoaderOutcomeAfterCleanup(generation, outcome);
}

fn loadGeneration(
    generation: *Generation,
    alloc: Allocator,
    roots: []const []const u8,
    stop_requested: *std.atomic.Value(bool),
) LoaderOutcome {
    if (isStopRequested(stop_requested)) return .canceled;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const candidates = discoverScopeCandidates(arena, roots, stop_requested) catch |err| {
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

fn discoverScopeCandidates(
    alloc: Allocator,
    roots: []const []const u8,
    stop_requested: *std.atomic.Value(bool),
) ![]const Candidate {
    return discoverScopeCandidatesWithFallback(alloc, roots, stop_requested, false);
}

fn discoverScopeCandidatesWithFallback(
    alloc: Allocator,
    roots: []const []const u8,
    stop_requested: *std.atomic.Value(bool),
    force_fallback: bool,
) ![]const Candidate {
    if (isStopRequested(stop_requested)) return error.Canceled;

    var candidates: std.ArrayList(Candidate) = .empty;
    errdefer candidates.deinit(alloc);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(alloc);
    var kept: usize = 0;
    var succeeded: usize = 0;

    for (roots, 0..) |root_path, root_index| {
        if (isStopRequested(stop_requested)) return error.Canceled;
        if (kept >= max_indexed_files) break;
        const remaining = max_indexed_files - kept;

        const discovered = workspace_files.discoverCancellable(
            alloc,
            root_path,
            .{
                .candidate_cap = remaining,
                .force_fallback = force_fallback,
                .include_hidden = true,
                .include_untracked = true,
                .sort_paths = true,
                .git_worktree_is_authoritative = true,
            },
            stop_requested,
        ) catch |err| {
            if (err == error.Canceled or isStopRequested(stop_requested)) return error.Canceled;
            debug_trace.logf("core", "file index root discovery omitted root={d} err={s}", .{ root_index, @errorName(err) });
            continue;
        };
        succeeded += 1;

        const discovered_directories: []const []const u8 = directories: {
            const result = workspace_files.discoverDirectoriesCancellable(
                alloc,
                root_path,
                .{
                    .candidate_cap = remaining,
                    .force_fallback = force_fallback,
                    .include_hidden = true,
                    .sort_paths = true,
                    .git_worktree_is_authoritative = true,
                },
                stop_requested,
            ) catch |err| {
                if (err == error.Canceled or isStopRequested(stop_requested)) return error.Canceled;
                debug_trace.logf("core", "file index root directory discovery omitted root={d} err={s}", .{ root_index, @errorName(err) });
                break :directories &.{};
            };
            break :directories result.directories;
        };

        var root = std.Io.Dir.openDirAbsolute(io_mod.getIo(), root_path, .{}) catch |err| {
            debug_trace.logf("core", "file index root admission omitted root={d} err={s}", .{ root_index, @errorName(err) });
            succeeded -= 1;
            continue;
        };
        defer root.close(io_mod.getIo());

        var file_cursor: usize = 0;
        var directory_cursor: usize = 0;
        while (nextSortedDiscoveredCandidate(
            discovered.files,
            discovered_directories,
            &file_cursor,
            &directory_cursor,
        )) |candidate| {
            if (isStopRequested(stop_requested)) return error.Canceled;
            if (kept >= max_indexed_files) break;
            if (workspace_files.pathContainsIgnoredDir(&.{".git"}, candidate.path)) continue;
            if (!text_utils.isTerminalSafe(candidate.path)) {
                debug_trace.logf("core", "file index omitted unsafe candidate bytes={d} kind={s}", .{ candidate.path.len, @tagName(candidate.kind) });
                continue;
            }
            if (candidate.kind == .file) {
                const stat = root.statFile(io_mod.getIo(), candidate.path, .{ .follow_symlinks = false }) catch |err| {
                    debug_trace.logf("core", "file index omitted missing candidate bytes={d} err={s}", .{ candidate.path.len, @errorName(err) });
                    continue;
                };
                if (stat.kind != .file and stat.kind != .sym_link) continue;
            }

            if (try appendDiscoveredCandidate(
                alloc,
                &candidates,
                &seen,
                root_path,
                root_index,
                candidate.path,
                candidate.kind,
            )) kept += 1;
        }
    }

    if (succeeded == 0 and roots.len > 0) return error.FileNotFound;
    return candidates.toOwnedSlice(alloc);
}

fn nextSortedDiscoveredCandidate(
    files: []const []const u8,
    directories: []const []const u8,
    file_cursor: *usize,
    directory_cursor: *usize,
) ?Candidate {
    if (file_cursor.* >= files.len and directory_cursor.* >= directories.len) return null;
    if (directory_cursor.* >= directories.len or
        (file_cursor.* < files.len and std.mem.order(u8, files[file_cursor.*], directories[directory_cursor.*]) != .gt))
    {
        defer file_cursor.* += 1;
        return .{ .path = files[file_cursor.*], .kind = .file };
    }
    defer directory_cursor.* += 1;
    return .{ .path = directories[directory_cursor.*], .kind = .directory };
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
    const absolute = try std.fs.path.resolve(alloc, &.{ root_path, relative });
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
    if (candidate.path.len == 0) return null;
    if (candidate.path.len > max_path_len) return null;
    if (!text_utils.isTerminalSafe(candidate.path)) return null;
    if (!file_picker_path.isRepresentable(candidate.path)) return null;
    if (candidate.kind == .directory and std.fs.path.isSep(candidate.path[candidate.path.len - 1])) return null;
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

/// Returns a presence bitmap for bytes 0x20..0x3f (space through '?':
/// whitespace, most punctuation, digits). Bytes outside that range
/// contribute no bits, so the mask can only under-constrain a query,
/// never falsely reject one.
fn punctMask(bytes: []const u8) u32 {
    var m: u32 = 0;
    for (bytes) |b| {
        const lower = asciiToLower(b);
        if (lower >= 0x20 and lower <= 0x3f) {
            m |= @as(u32, 1) << @intCast(lower - 0x20);
        }
    }
    return m;
}

const non_ascii_mask: u32 = @as(u32, 1) << 31;
const max_search_results: usize = 64;

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
        const codepoint = std.unicode.utf8Decode(bytes[byte_index..end]) catch return null;
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
        const codepoint = std.unicode.utf8Decode(path[byte_index..end]) catch return null;
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
    basename_fit: bool,
    boundary_matches: usize,
    prefix: bool,
    first_position: usize,
    longest_run: usize,
    consecutive_matches: usize,
    gaps: usize,
};

const SubsequenceFacts = struct {
    boundary_matches: usize = 0,
    prefix: bool = false,
    first_position: usize = 0,
    longest_run: usize = 0,
    consecutive_matches: usize = 0,
    gaps: usize = 0,
};

const RankedCandidate = struct {
    score: MatchScore,
    index: u32,
};

fn rankTopN(generation: *const Generation, query: PreparedQuery, out: []u32) usize {
    const top_cap = @min(out.len, max_search_results);
    if (top_cap == 0) return 0;

    var ranked: [max_search_results]RankedCandidate = undefined;
    var filled: usize = 0;
    var worst_slot: usize = 0;

    const query_ascii = query.ascii;
    const query_mask = if (query_ascii) |ascii| alphaMask(ascii) else 0;
    const query_punct_mask = if (query_ascii) |ascii| punctMask(ascii) else 0;
    var scalar_scratch: FoldedPathScratch = undefined;

    const total = generation.count();
    var candidate_index: u32 = 0;
    while (candidate_index < total) : (candidate_index += 1) {
        const path_mask = generation.char_masks[candidate_index];
        const base_start = generation.basename_starts[candidate_index] - generation.offsets[candidate_index];
        const score = if ((path_mask & non_ascii_mask) == 0) ascii_path: {
            const ascii = query_ascii orelse continue;
            if ((path_mask & query_mask) != query_mask) continue;
            if (query_punct_mask != 0) {
                if ((generation.punct_masks[candidate_index] & query_punct_mask) != query_punct_mask) continue;
            }
            break :ascii_path scoreAsciiMatch(
                generation.pathAt(candidate_index),
                generation.lowerPathAt(candidate_index),
                base_start,
                ascii,
            );
        } else scoreFoldedMatch(generation.pathAt(candidate_index), base_start, query.folded, &scalar_scratch);
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

fn scoreAsciiMatch(
    path: []const u8,
    path_lower: []const u8,
    basename_start: u32,
    query: []const u8,
) ?MatchScore {
    if (query.len == 0 or path.len == 0) return null;
    const base_start: usize = basename_start;
    const basename = path_lower[base_start..];
    const exact_fit = std.mem.eql(u8, path_lower, query) or std.mem.eql(u8, basename, query);

    if (scoreAsciiRange(path, path_lower, base_start, query)) |facts| {
        return matchScore(exact_fit, true, facts);
    }
    const facts = scoreAsciiRange(path, path_lower, 0, query) orelse return null;
    return matchScore(exact_fit, false, facts);
}

noinline fn scoreAsciiRange(
    path: []const u8,
    path_lower: []const u8,
    range_start: usize,
    query: []const u8,
) ?SubsequenceFacts {
    if (query.len > path_lower.len - range_start) return null;

    var facts: SubsequenceFacts = .{};
    var query_index: usize = 0;
    var previous_position: usize = 0;
    var run_length: usize = 0;
    var position = range_start;
    if (query.len != 0) {
        if (std.mem.indexOfScalarPos(u8, path_lower, range_start, query[0])) |first_hit| {
            position = first_hit;
        } else return null;
    }
    while (position < path_lower.len and query_index < query.len) : (position += 1) {
        if (path_lower[position] != query[query_index]) {
            position = std.mem.indexOfScalarPos(u8, path_lower, position + 1, query[query_index]) orelse return null;
        }

        if (query_index == 0) {
            facts.first_position = position - range_start;
            facts.prefix = position == range_start;
            run_length = 1;
        } else if (position == previous_position + 1) {
            facts.consecutive_matches += 1;
            run_length += 1;
        } else {
            facts.gaps += position - previous_position - 1;
            run_length = 1;
        }
        facts.longest_run = @max(facts.longest_run, run_length);
        facts.boundary_matches += @intFromBool(isMatchBoundary(path, position));
        previous_position = position;
        query_index += 1;
    }
    return if (query_index == query.len) facts else null;
}

noinline fn scoreFoldedMatch(
    path: []const u8,
    basename_byte_start: u32,
    query: []const u21,
    scratch: *FoldedPathScratch,
) ?MatchScore {
    if (query.len == 0 or path.len == 0) return null;
    const base_start: usize = basename_byte_start;
    const decoded = decodeFoldedPath(path, base_start, scratch) orelse return null;
    const scalars = scratch.scalars[0..decoded.scalar_count];
    const basename_scalars = scalars[decoded.basename_scalar_start..];
    const exact_fit = std.mem.eql(u21, scalars, query) or std.mem.eql(u21, basename_scalars, query);

    if (scoreFoldedRange(path, scalars, scratch.byte_offsets[0 .. decoded.scalar_count + 1], decoded.basename_scalar_start, query)) |facts| {
        return matchScore(exact_fit, true, facts);
    }
    const facts = scoreFoldedRange(path, scalars, scratch.byte_offsets[0 .. decoded.scalar_count + 1], 0, query) orelse return null;
    return matchScore(exact_fit, false, facts);
}

fn scoreFoldedRange(
    path: []const u8,
    scalars: []const u21,
    byte_offsets: []const u16,
    range_start: usize,
    query: []const u21,
) ?SubsequenceFacts {
    if (query.len > scalars.len - range_start) return null;

    var facts: SubsequenceFacts = .{};
    var query_index: usize = 0;
    var previous_position: usize = 0;
    var run_length: usize = 0;
    var position = range_start;
    while (position < scalars.len and query_index < query.len) : (position += 1) {
        if (scalars[position] != query[query_index]) continue;

        if (query_index == 0) {
            facts.first_position = position - range_start;
            facts.prefix = position == range_start;
            run_length = 1;
        } else if (position == previous_position + 1) {
            facts.consecutive_matches += 1;
            run_length += 1;
        } else {
            facts.gaps += position - previous_position - 1;
            run_length = 1;
        }
        facts.longest_run = @max(facts.longest_run, run_length);
        facts.boundary_matches += @intFromBool(isMatchBoundary(path, byte_offsets[position]));
        previous_position = position;
        query_index += 1;
    }
    return if (query_index == query.len) facts else null;
}

fn matchScore(exact_fit: bool, basename_fit: bool, facts: SubsequenceFacts) MatchScore {
    return .{
        .exact_fit = exact_fit,
        .basename_fit = basename_fit,
        .boundary_matches = facts.boundary_matches,
        .prefix = facts.prefix,
        .first_position = facts.first_position,
        .longest_run = facts.longest_run,
        .consecutive_matches = facts.consecutive_matches,
        .gaps = facts.gaps,
    };
}

fn isMatchBoundary(path: []const u8, byte_index: usize) bool {
    if (byte_index == 0) return true;
    const previous = path[byte_index - 1];
    if (std.fs.path.isSep(previous) or previous == '-' or previous == '_' or previous == '.' or previous == ' ') return true;
    if (byte_index >= path.len) return false;
    const current = path[byte_index];
    return previous >= 'a' and previous <= 'z' and current >= 'A' and current <= 'Z';
}

fn scoreBetter(left: MatchScore, right: MatchScore) bool {
    if (left.exact_fit != right.exact_fit) return left.exact_fit;
    if (left.basename_fit != right.basename_fit) return left.basename_fit;
    if (left.boundary_matches != right.boundary_matches) return left.boundary_matches > right.boundary_matches;
    if (left.prefix != right.prefix) return left.prefix;
    if (left.first_position != right.first_position) return left.first_position < right.first_position;
    if (left.longest_run != right.longest_run) return left.longest_run > right.longest_run;
    if (left.consecutive_matches != right.consecutive_matches) return left.consecutive_matches > right.consecutive_matches;
    if (left.gaps != right.gaps) return left.gaps < right.gaps;
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
    matched_offsets: *[max_path_len]u16,
    span_scratch: *[max_path_len]MatchSpan,
) ?usize {
    const decoded = decodeFoldedPath(path, basename_byte_start, path_scratch) orelse return null;
    const scalars = path_scratch.scalars[0..decoded.scalar_count];
    const byte_offsets = path_scratch.byte_offsets[0 .. decoded.scalar_count + 1];
    const matched_count = collectMatchOffsets(
        scalars,
        byte_offsets,
        decoded.basename_scalar_start,
        query,
        matched_offsets,
    ) orelse collectMatchOffsets(scalars, byte_offsets, 0, query, matched_offsets) orelse return null;
    return spansFromMatchedOffsets(path, matched_offsets[0..matched_count], span_scratch);
}

fn collectMatchOffsets(
    scalars: []const u21,
    byte_offsets: []const u16,
    range_start: usize,
    query: []const u21,
    out: *[max_path_len]u16,
) ?usize {
    if (query.len > scalars.len - range_start) return null;
    var query_index: usize = 0;
    var position = range_start;
    while (position < scalars.len and query_index < query.len) : (position += 1) {
        if (scalars[position] != query[query_index]) continue;
        out[query_index] = byte_offsets[position];
        query_index += 1;
    }
    return if (query_index == query.len) query_index else null;
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
    const long_path = "a" ** (max_path_len + 1);
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

    const long_path = "a" ** (max_path_len + 1);
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
    try std.testing.expectEqual(@as(usize, 2), filtered.count());
    try std.testing.expectEqualStrings("src", filtered.pathAt(0));
    try std.testing.expectEqual(CandidateKind.directory, filtered.kindAt(0));
    try std.testing.expectEqualStrings("README.md", filtered.pathAt(1));
    try std.testing.expectEqual(CandidateKind.file, filtered.kindAt(1));
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
    generation.state.store(@intFromEnum(GenerationState.loading), .release);
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
            .path = try std.fmt.bufPrint(slot, "candidate-{d:0>6}", .{index}),
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

test "sorted discovery merge retains directories at the exact shared cap" {
    const files = try std.testing.allocator.alloc([]const u8, max_indexed_files);
    defer std.testing.allocator.free(files);
    @memset(files, "z-file");
    const directories = [_][]const u8{"a-empty-directory"};
    var file_cursor: usize = 0;
    var directory_cursor: usize = 0;
    var count: usize = 0;
    var saw_directory = false;

    while (count < max_indexed_files) : (count += 1) {
        const candidate = nextSortedDiscoveredCandidate(files, &directories, &file_cursor, &directory_cursor).?;
        saw_directory = saw_directory or candidate.kind == .directory;
    }

    try std.testing.expect(saw_directory);
    try std.testing.expectEqual(max_indexed_files - 1, file_cursor);
    try std.testing.expectEqual(@as(usize, 1), directory_cursor);
}

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
            .name = "path segment boundaries",
            .raw = "misc/scattered/memo.zig\nsrc/core/main.zig\n",
            .query = "scm",
            .expected = "src/core/main.zig",
        },
        .{
            .name = "basename prefix",
            .raw = "src/xwidget.zig\nsrc/widgetx.zig\n",
            .query = "wid",
            .expected = "src/widgetx.zig",
        },
        .{
            .name = "path prefix",
            .raw = "x/a/b\na/x/b\n",
            .query = "ab",
            .expected = "a/x/b",
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
    generation.state.store(@intFromEnum(GenerationState.loading), .release);
    generation.ready_count.store(2, .release);
    try std.testing.expectEqual(@as(usize, 2), index.count());

    var search: TestSearchBuffer(4) = .{};
    const results = try search.run(&index, "main");
    try std.testing.expectEqual(@as(usize, 2), results.len);
    for (results) |result| {
        try std.testing.expect(std.mem.indexOf(u8, result.path, "main") != null);
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
        const expected = try std.fmt.bufPrint(&expected_buf, "src/match-{d:0>3}.zig", .{i});
        try std.testing.expectEqualStrings(expected, results[i].path);
        try std.testing.expectEqual(CandidateKind.file, results[i].kind);
        try expectValidSearchSpans(results[i]);
    }
}

test "search rejects queries longer than max_path_len" {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);

    const path = "a" ** max_path_len;
    const query = ("a" ** max_path_len) ++ "b";
    try index.buildFromRaw(alloc, path);

    var search: TestSearchBuffer(1) = .{};
    try std.testing.expectEqual(@as(usize, 0), (try search.run(&index, query)).len);
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
    const shared_file = try std.fs.path.join(alloc, &.{ shared, "nested/lib.zig" });
    defer alloc.free(shared_file);
    const shared_directory = try std.fs.path.join(alloc, &.{ shared, "nested" });
    defer alloc.free(shared_directory);
    const roots = [_][]const u8{ primary, shared };
    var stop_requested = std.atomic.Value(bool).init(false);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const candidates = try discoverScopeCandidatesWithFallback(arena_state.allocator(), &roots, &stop_requested, true);

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
    if (comptime @import("builtin").os.tag == .windows or @import("builtin").os.tag == .wasi) return error.SkipZigTest;

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
        const path = try std.fmt.bufPrint(&path_storage, "root/z-file-{d:0>2}.txt", .{index});
        var file = try tmp.dir.createFile(io_mod.getIo(), path, .{ .truncate = true });
        file.close(io_mod.getIo());
    }
    if (comptime @import("builtin").os.tag != .windows) {
        try tmp.dir.symLink(std.testing.io, "nested", "root/linked-dir", .{ .is_directory = true });
    }

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "root");
    defer alloc.free(root);
    try runGitForFileIndexTest(alloc, root, &.{ "git", "init", "--quiet" });
    try runGitForFileIndexTest(alloc, root, &.{ "git", "add", ".gitignore", "tracked.txt", ".hidden/tracked.txt" });

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var stop_requested = std.atomic.Value(bool).init(false);
    const candidates = try discoverScopeCandidates(arena_state.allocator(), &.{root}, &stop_requested);

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
        try std.testing.expect(!workspace_files.pathContainsIgnoredDir(&.{".git"}, candidate.path));
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
    const missing = try std.fs.path.join(alloc, &.{ primary, "missing" });
    defer alloc.free(missing);
    const roots = [_][]const u8{ primary, nested, missing };
    var stop_requested = std.atomic.Value(bool).init(false);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const candidates = try discoverScopeCandidatesWithFallback(arena_state.allocator(), &roots, &stop_requested, true);

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
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

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
    const shared_file = try std.fs.path.join(alloc, &.{ shared, "item.txt" });
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
    const shared_file = try std.fs.path.join(alloc, &.{ shared, "item.txt" });
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
    index.pending_roots = try cloneRoots(alloc, &.{ "/primary", "/shared" });
    var gate: TestLoaderGate = .{ .outcome = .canceled };
    _ = try installTestLoader(&index, alloc, "item.txt\x00", &gate);

    index.refresh(alloc);

    const pending = index.pending_roots orelse return error.TestExpectedEqual;
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
        std.testing.allocator,
        checkBuildFromRawAllocationFailures,
        .{},
    );
}

test "typed builder frees dedupe state and partial buffers across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkBuildFromCandidatesAllocationFailures,
        .{},
    );
}

test "kind buffer allocation failure retains the existing index" {
    const alloc = std.testing.allocator;
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
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "trace.log" });
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
    const alloc = std.testing.allocator;
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
    const alloc = std.testing.allocator;
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
    try std.testing.expectEqual(@as(usize, 0), index.count());
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
    const first_pending = index.pending_roots.?;
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
    try std.testing.expect(index.pending_roots.?.ptr == first_pending.ptr);

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
    try std.testing.expectEqualStrings("/latest", index.pending_roots.?[1]);
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
    try std.testing.expectEqual(@as(usize, 0), index.count());
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
        try std.testing.expect(index.pending_roots != null);
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
    index.pending_roots = try cloneRoots(alloc, &.{ "/primary", "/queued" });
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
    try std.testing.expect(index.pending_roots == null);
}

test "file index raw-list and Unicode query bytes remain bounded" {
    try std.testing.fuzz({}, fuzzRawListAndQuery, .{
        .corpus = &.{
            "safe.txt\x00ärger",
            "escape-\x1b[2J.txt\x00\xff",
            "Ärger-file.txt\x00ärger",
            "docs/Kelvin.txt\x00k",
            "src/core/file_index.zig\x00fiidx",
            "docs/Cafe\u{0301}.txt\x00e\u{0301}",
            "src/axaya.zig\x00aaa",
            "truncated.txt\x00\xc3",
        },
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

fn sleepBlocking(milliseconds: u64) void {
    var sleep_io_backend: std.Io.Threaded = .init_single_threaded;
    sleep_io_backend.io().sleep(.fromMilliseconds(@intCast(milliseconds)), .real) catch {};
}
