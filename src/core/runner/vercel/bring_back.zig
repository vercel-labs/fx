//! The bring-back of a run (V9): after the command ends, or after a run that stopped, the
//! sandbox's changed files come back to the Mac under the write rules. The sandbox runs one fixed
//! script (`script`) under the lock. The host decodes its base64 output in fixed steps, reads the
//! gzip tar as a stream, and writes each file through a temp file and a rename. Outside code
//! imports only `vercel.zig`.

const std = @import("std");
const config_write = @import("../config_write.zig");
const display_width = @import("../../shared/display_width.zig");
const exec = @import("exec.zig");
const io_mod = @import("../../shared/io.zig");
const credentials = @import("credentials.zig");
const journal = @import("journal.zig");
const sandbox = @import("sandbox.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const stream = @import("stream.zig");
const sync = @import("sync.zig");
const transport = @import("transport.zig");

const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const Sha256 = std.crypto.hash.sha2.Sha256;
const BaselineMap = std.array_hash_map.String(sandbox.BringBackFile);

/// The most files one run writes. The script applies the same limit before it streams (V9).
pub const max_files_per_run: usize = sandbox.max_back_files;
/// The most bytes one run writes (V9).
pub const max_bytes_per_run: u64 = sandbox.max_back_bytes;
/// A file over this size is never brought back (V9, the script's size test).
pub const max_file_bytes: u64 = sandbox.max_back_file_bytes;
/// The tar reader's name buffers. A longer name is refused by the reader.
const tar_name_bytes: usize = 4096;
const io_buffer_bytes: usize = 64 * 1024;
/// The decoded bytes produced per step. A multiple of 3, the size of one base64 group.
const decode_bytes: usize = 768;
const temp_prefix = ".fx-bring-back.";
const temp_suffix = ".tmp";
const word_root = "root ";
const word_missing = "missing ";
const word_covered = "covered ";
const word_skipped = "skipped ";
const word_dropped = "dropped ";
const word_linked = "linked ";
const word_deferred = "deferred ";

/// The sandbox side of V9. `$1` is this run's stamp name, `$2` the number of pending stamp names
/// that follow, each marked `b` when its run carries a baseline and `n` when not. The pending paths
/// are read from `.git/fx-pending-back`, never passed as arguments. The files to bring back are taken
/// in this order, without repeats: the files newer than this run's stamp, then the older pending
/// range, then the pending paths. The paths this run's push sent, in `.git/fx-sent-{run}`, are
/// dropped from the pending range only. The script takes files while they fit `max_back_files` and
/// `max_back_bytes` by size, and stdout is the base64 of a gzip tar of those. A file that does not
/// fit, and every file after it, is printed on stderr as `deferred <escaped path>`, where a backslash
/// is written twice, a line feed as backslash n and a carriage return as backslash r. Other stderr
/// notes are `root <stamp>`, `missing <stamp>` and `covered <stamp>` for each pending stamp,
/// `skipped <size> <mtime>` for each file over the size limit, and `dropped <n>` for the ignored
/// files that were not pushed, and `linked <n>` for the pending names whose folder in the sandbox is
/// a link, which count as not regular files (N8).
pub const script = fillLimits(script_source);

fn fillLimits(comptime text: []const u8) []const u8 {
    comptime {
        var out = replaceAll(text, "@@MAX_FILES@@", std.fmt.comptimePrint("{d}", .{sandbox.max_back_files}));
        out = replaceAll(out, "@@MAX_BYTES@@", std.fmt.comptimePrint("{d}", .{sandbox.max_back_bytes}));
        out = replaceAll(out, "@@MAX_FILE_BYTES@@", std.fmt.comptimePrint("{d}", .{sandbox.max_back_file_bytes}));
        return out;
    }
}

fn replaceAll(comptime text: []const u8, comptime needle: []const u8, comptime with: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var out: []const u8 = "";
        var rest: []const u8 = text;
        while (std.mem.find(u8, rest, needle)) |at| {
            out = out ++ rest[0..at] ++ with;
            rest = rest[at + needle.len ..];
        }
        return out ++ rest;
    }
}

const script_source =
    \\set -u
    \\own=$1
    \\n=$2
    \\m=$3
    \\shift 3
    \\for ((i = 0; i < m; i++)); do
    \\  rm -f -- ".git/$1"
    \\  shift
    \\done
    \\work=$(mktemp -d) || exit 1
    \\trap 'rm -rf "$work"' EXIT
    \\main=""
    \\root=""
    \\: > "$work/covered"
    \\for ((i = 0; i < n; i++)); do
    \\  arg=$1
    \\  shift
    \\  kind=${arg:0:1}
    \\  name=${arg:1}
    \\  if [ -e ".git/$name" ]; then
    \\    [ -n "$main" ] || main=$name
    \\    if [ "$kind" = b ] && [ -z "$root" ]; then root=$name; fi
    \\    printf '%s\0' "$name" >> "$work/covered"
    \\  else
    \\    printf 'missing %s\n' "$name" >&2
    \\  fi
    \\done
    \\[ -n "$main" ] || main=$own
    \\[ -n "$root" ] || root=$own
    \\printf 'root %s\n' "$root" >&2
    \\roots=()
    \\if [ -s .git/fx-bring-back ]; then mapfile -t -d '' roots < .git/fx-bring-back; fi
    \\under_root() {
    \\  local r
    \\  for r in "${roots[@]}"; do
    \\    case "$1" in "$r"|"$r"/*) return 0 ;; esac
    \\  done
    \\  return 1
    \\}
    \\declare -A ignored=() pushed=() seen=() sent=()
    \\sent_file=".git/fx-sent-${own#fx-stamp-}"
    \\if [ -s "$sent_file" ]; then
    \\  mapfile -d '' -t sent_list < "$sent_file"
    \\  for p in "${sent_list[@]}"; do sent[${p#./}]=1; done
    \\fi
    \\newer_own=( \( -newer ".git/$own" -o -cnewer ".git/$own" \) )
    \\newer_main=( \( -newer ".git/$main" -o -cnewer ".git/$main" \) )
    \\newer_root=( \( -newer ".git/$root" -o -cnewer ".git/$root" \) )
    \\files=( \( -type f -o -type l \) )
    \\find . "${newer_own[@]}" "${files[@]}" ! -path '*/.git/*' -printf '%s\t%T@\t%p\0' > "$work/own_main" 2> /dev/null
    \\find . "${newer_main[@]}" ! "${newer_own[@]}" "${files[@]}" ! -path '*/.git/*' -printf '%s\t%T@\t%p\0' > "$work/range_main" 2> /dev/null
    \\: > "$work/own_root"
    \\: > "$work/range_root"
    \\if [ -s .git/fx-bring-back ]; then
    \\  xargs -0 -I{} find ./{} "${newer_own[@]}" "${files[@]}" -printf '%s\t%T@\t%p\0' < .git/fx-bring-back > "$work/own_root" 2> /dev/null || true
    \\  xargs -0 -I{} find ./{} "${newer_root[@]}" ! "${newer_own[@]}" "${files[@]}" -printf '%s\t%T@\t%p\0' < .git/fx-bring-back > "$work/range_root" 2> /dev/null || true
    \\fi
    \\: > "$work/args"
    \\if [ -s .git/fx-pending-back ]; then
    \\  physroot=$(pwd -P)
    \\  : > "$work/pkept"
    \\  xargs -0 -r dirname -z -- < .git/fx-pending-back > "$work/pdirs" 2> /dev/null || true
    \\  xargs -0 -r realpath -m -z --relative-to="$physroot" -- < "$work/pdirs" > "$work/prel" 2> /dev/null || true
    \\  if cmp -s "$work/pdirs" "$work/prel"; then
    \\    cp .git/fx-pending-back "$work/pkept"
    \\  else
    \\    mapfile -d '' -t pending < .git/fx-pending-back
    \\    mapfile -d '' -t pdir_list < "$work/pdirs"
    \\    mapfile -d '' -t prel_list < "$work/prel"
    \\    kept=()
    \\    if [ "${#prel_list[@]}" -eq "${#pdir_list[@]}" ] && [ "${#pdir_list[@]}" -eq "${#pending[@]}" ]; then
    \\      for i in "${!pending[@]}"; do
    \\        if [ "${prel_list[$i]}" = "${pdir_list[$i]}" ]; then kept+=("${pending[$i]}"); fi
    \\      done
    \\    fi
    \\    if [ "${#kept[@]}" -gt 0 ]; then printf '%s\0' "${kept[@]}" > "$work/pkept"; fi
    \\    linked=$(( ${#pending[@]} - ${#kept[@]} ))
    \\    if [ "$linked" -gt 0 ]; then printf 'linked %s\n' "$linked" >&2; fi
    \\  fi
    \\  if [ -s "$work/pkept" ]; then
    \\    find -files0-from "$work/pkept" -maxdepth 0 "${files[@]}" -printf '%s\t%T@\t%p\0' > "$work/args" 2> /dev/null || true
    \\  fi
    \\fi
    \\check_list=()
    \\check_group() {
    \\  local rec rest size mtime path
    \\  local -a recs
    \\  mapfile -d '' -t recs < "$2"
    \\  for rec in "${recs[@]}"; do
    \\    size=${rec%%$'\t'*}
    \\    rest=${rec#*$'\t'}
    \\    mtime=${rest%%$'\t'*}
    \\    path=${rest#*$'\t'}
    \\    if [ "$size" -gt @@MAX_FILE_BYTES@@ ]; then continue; fi
    \\    check_list+=("${path#./}")
    \\  done
    \\}
    \\check_group o "$work/own_main"
    \\check_group m "$work/range_main"
    \\check_group a "$work/args"
    \\: > "$work/check"
    \\if [ "${#check_list[@]}" -gt 0 ]; then printf '%s\0' "${check_list[@]}" > "$work/check"; fi
    \\git check-ignore --no-index --stdin -z < "$work/check" > "$work/ignored" 2> /dev/null || true
    \\mapfile -d '' -t ignored_list < "$work/ignored"
    \\for p in "${ignored_list[@]}"; do ignored[${p#./}]=1; done
    \\if [ -s .git/fx-pushed ]; then
    \\  mapfile -d '' -t pushed_list < .git/fx-pushed
    \\  for p in "${pushed_list[@]}"; do pushed[$p]=1; done
    \\fi
    \\keep=()
    \\count=0
    \\bytes=0
    \\full=0
    \\dropped=0
    \\take_group() {
    \\  local origin=$1 rec rest size mtime path key esc
    \\  local -a recs
    \\  mapfile -d '' -t recs < "$2"
    \\  for rec in "${recs[@]}"; do
    \\    size=${rec%%$'\t'*}
    \\    rest=${rec#*$'\t'}
    \\    mtime=${rest%%$'\t'*}
    \\    path=${rest#*$'\t'}
    \\    key=${path#./}
    \\    if [ "$origin" = o ] || [ "$origin" = m ]; then
    \\      if [ "${#roots[@]}" -gt 0 ] && under_root "$key"; then continue; fi
    \\    fi
    \\    if [ "$origin" = m ] || [ "$origin" = r ] || [ "$origin" = a ]; then
    \\      if [ -n "${sent[$key]:-}" ]; then continue; fi
    \\    fi
    \\    if [ -n "${seen[$key]:-}" ]; then continue; fi
    \\    seen[$key]=1
    \\    if [ "$size" -gt @@MAX_FILE_BYTES@@ ]; then printf 'skipped %s %s\n' "$size" "$mtime" >&2; continue; fi
    \\    if [ -n "${ignored[$key]:-}" ] && [ -z "${pushed[$key]:-}" ] && { [ "${#roots[@]}" -eq 0 ] || ! under_root "$key"; }; then
    \\      dropped=$((dropped + 1))
    \\      continue
    \\    fi
    \\    if [ "$full" -eq 0 ] && [ $((count + 1)) -le @@MAX_FILES@@ ] && [ $((bytes + size)) -le @@MAX_BYTES@@ ]; then
    \\      keep+=("$path")
    \\      count=$((count + 1))
    \\      bytes=$((bytes + size))
    \\    else
    \\      full=1
    \\      esc=${key//'\'/'\\'}
    \\      esc=${esc//$'\n'/'\n'}
    \\      esc=${esc//$'\r'/'\r'}
    \\      printf 'deferred %s\n' "$esc" >&2
    \\    fi
    \\  done
    \\}
    \\take_group o "$work/own_main"
    \\take_group R "$work/own_root"
    \\take_group m "$work/range_main"
    \\take_group r "$work/range_root"
    \\take_group a "$work/args"
    \\: > "$work/keep"
    \\if [ "${#keep[@]}" -gt 0 ]; then printf '%s\0' "${keep[@]}" > "$work/keep"; fi
    \\printf 'dropped %s\n' "$dropped" >&2
    \\tar -cz --no-recursion --null -T - < "$work/keep" | base64
    \\status=$?
    \\rm -f -- "$sent_file"
    \\while IFS= read -r -d '' name; do printf 'covered %s\n' "$name" >&2; done < "$work/covered"
    \\exit $status
;

/// What the bring-back did with the sandbox's files. Each count feeds one note (N8, N9, N14).
pub const Counts = struct {
    written: usize = 0,
    /// Changed on this Mac during the run, so the Mac's version stays (N9).
    kept: usize = 0,
    skipped_kind: usize = 0,
    skipped_path: usize = 0,
    skipped_git: usize = 0,
    skipped_case: usize = 0,
    skipped_folder: usize = 0,
    /// A file over 64 MiB that N8 had not counted yet, with this size and mtime (V9 `skipped`).
    skipped_big: usize = 0,
    /// Past the run's file or byte cap and kept as pending for the next run (N8). An isolated run
    /// counts every file past the cap here, because it has no next run.
    over_cap: usize = 0,
    /// Past the cap and past `sandbox.max_pending_names`, so no later run is told about them (N8).
    over_untracked: usize = 0,
    /// Files git ignores and that were not pushed. The script counts them; no note shows them.
    dropped: usize = 0,
};

pub const Report = struct {
    counts: Counts,
    /// The paths past the caps, which the next run brings back (`manifest.pending_back`).
    pending: []const []const u8,
};

pub const Result = union(enum) {
    done: Report,
    /// The bring-back did not finish. The detail is terminal-safe text for the note.
    failed: []const u8,
};

/// What a run hands its bring-back: its run id, the bring-back roots, and its own baseline, the
/// size and mtime of each root file at run start (V9).
pub const Input = struct {
    run_id: []const u8,
    roots: []const []const u8,
    own_baseline: []const sandbox.BringBackFile,
    /// How long the lock may be waited for. Tests shorten it.
    lock_wait_ms: u64 = config_write.lock_wait_ms,
    /// The lock's clock and try, which tests replace to hold the lock busy.
    lock_ops: io_mod.LockOps = .{},
};

/// Runs the bring-back of one run (V9). It holds the lock from the first request to the last
/// write. Pending runs are read first; the oldest one whose stamp still exists sets the walk.
pub fn run(arena: Allocator, ctx: *sandbox.Context, session_id: []const u8, input: Input) Result {
    const io = io_mod.getIo();
    var lock = io_mod.acquireTimedAdvisoryLockCancellableWithOps(ctx.state_dir, sync.lock_name, input.lock_wait_ms, ctx.cancel, input.lock_ops) catch |err| return .{ .failed = switch (err) {
        error.LockBusy => sync.busy_detail,
        error.Cancelled => "the run was cancelled",
        else => @errorName(err),
    } };
    defer lock.release();

    sandbox.foldJournal(ctx) catch return .{ .failed = "the manifest journal could not be folded" };
    var manifest = sandbox.readManifest(ctx) catch return .{ .failed = "the manifest could not be read" };
    if (manifest.generation == null) return .{ .failed = "the sandbox has no generation" };
    var root = io_mod.openDirAbsoluteNoFollow(ctx.repo_root, .{ .iterate = true }) catch return .{ .failed = "the repository folder could not be opened" };
    defer root.close(io);

    const found = sandbox.readPending(arena, ctx) catch return .{ .failed = "the pending runs could not be read" };
    const ordered = arena.dupe(sandbox.Pending, found) catch return .{ .failed = "out of memory" };
    sortOldestFirst(ordered);
    const own_stamp = sandbox.stampName(arena, input.run_id) catch return .{ .failed = "out of memory" };

    var baselines: std.array_hash_map.String(BaselineMap) = .empty;
    var args: std.ArrayList([]const u8) = .empty;
    buildArgs(arena, &baselines, &args, own_stamp, input, ordered, manifest.spent_stamps) catch return .{ .failed = "out of memory" };
    const request = encodeRequest(arena, ctx.repo_root, args.items) catch return .{ .failed = "out of memory" };

    var counts: Counts = .{};
    var overflow: std.ArrayList([]const u8) = .empty;
    var notes: Notes = .{ .alloc = arena };
    var apply: Apply = .{
        .arena = arena,
        .root = root,
        .manifest = &manifest,
        .counts = &counts,
        .overflow = &overflow,
        .ctx = ctx,
        .roots = input.roots,
        .baselines = &baselines,
        .notes = &notes,
        .max_files = max_files_per_run,
        .max_bytes = max_bytes_per_run,
    };
    if (fetch(arena, ctx, session_id, request, &apply, &notes)) |detail| return .{ .failed = detail };

    counts.dropped = notes.dropped;
    counts.skipped_kind += notes.linked;
    countSkipped(arena, &manifest, &notes, &counts) catch return .{ .failed = "out of memory" };
    const deferred = deferredBack(arena, &notes, &counts) catch return .{ .failed = "out of memory" };
    const pending = pendingBack(arena, overflow.items, deferred) catch return .{ .failed = "out of memory" };
    counts.over_cap = pending.names.len;
    counts.over_untracked = pending.untracked;
    const spent = spentStamps(arena, own_stamp, notes.covered.items) catch return .{ .failed = "out of memory" };
    if (commitRun(ctx, &apply, &manifest, pending.names, ordered, &notes, spent)) |detail| return .{ .failed = detail };
    return .{ .done = .{ .counts = counts, .pending = pending.names } };
}

/// The end of a bring-back (V9, N8): the manifest gets the over-cap names and the spent stamps, and then the pending records whose
/// stamps were covered or missing are removed. The records go only after the manifest is written, so a failed
/// write, or a crash before the removal, leaves each record for the next run, which walks it again and writes
/// nothing twice. Returns the failure detail, or null.
fn commitRun(
    ctx: *sandbox.Context,
    apply: *Apply,
    manifest: *sandbox.Manifest,
    pending_names: []const []const u8,
    ordered: []const sandbox.Pending,
    notes: *const Notes,
    spent: []const []const u8,
) ?[]const u8 {
    manifest.pending_back = pending_names;
    manifest.spent_stamps = spent;
    apply.finish() catch |err| return switch (err) {
        error.JournalNotRemoved => "the journal could not be removed",
        else => "the manifest could not be written",
    };
    for (ordered) |entry| {
        if (!listed(notes.covered.items, entry.stamp) and !listed(notes.missing.items, entry.stamp)) continue;
        sandbox.removePending(ctx, entry.run_id) catch return "the pending runs could not be removed";
    }
    return null;
}

/// The stamps a committed bring-back spends (V9): this run's own stamp, then each pending stamp it covered.
/// Only stamp names are kept, each once, and at most `sandbox.max_spent_stamps`. A stamp past the cap stays
/// in the sandbox unrecorded, and nothing reads it again.
fn spentStamps(arena: Allocator, own_stamp: []const u8, covered: []const []const u8) Allocator.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    try addSpent(arena, &names, own_stamp);
    for (covered) |name| try addSpent(arena, &names, name);
    return names.items;
}

fn addSpent(arena: Allocator, names: *std.ArrayList([]const u8), name: []const u8) Allocator.Error!void {
    if (names.items.len == sandbox.max_spent_stamps or !sandbox.validStampName(name) or listed(names.items, name)) return;
    try names.append(arena, name);
}

/// The script's arguments (see `script`): this run's stamp, the count of pending stamps, the count of spent
/// stamps and the spent stamps, then the pending stamps oldest first. The pending names are not arguments: they reach the sandbox in
/// `.git/fx-pending-back`. Each pending run's baseline is indexed by its stamp for the root the
/// script reports back.
fn buildArgs(
    arena: Allocator,
    baselines: *std.array_hash_map.String(BaselineMap),
    args: *std.ArrayList([]const u8),
    own_stamp: []const u8,
    input: Input,
    ordered: []const sandbox.Pending,
    spent: []const []const u8,
) !void {
    try baselines.put(arena, own_stamp, try baselineMapOf(arena, input.own_baseline));
    for (ordered) |entry| {
        if (entry.baseline) |files| try baselines.put(arena, entry.stamp, try baselineMapOf(arena, files));
    }
    try args.append(arena, own_stamp);
    try args.append(arena, try arena.print("{d}", .{ordered.len}));
    try args.append(arena, try arena.print("{d}", .{spent.len}));
    for (spent) |name| try args.append(arena, name);
    for (ordered) |entry| {
        const mark: []const u8 = if (entry.baseline != null) "b" else "n";
        try args.append(arena, try arena.print("{s}{s}", .{ mark, entry.stamp }));
    }
}

fn baselineMapOf(arena: Allocator, files: []const sandbox.BringBackFile) Allocator.Error!BaselineMap {
    var map: BaselineMap = .empty;
    for (files) |file| try map.put(arena, file.rel, file);
    return map;
}

/// Oldest first by start time. A run has one pending entry, so the list is short.
fn sortOldestFirst(items: []sandbox.Pending) void {
    var index: usize = 1;
    while (index < items.len) : (index += 1) {
        var at = index;
        while (at > 0 and items[at - 1].started_ms > items[at].started_ms) : (at -= 1) {
            std.mem.swap(sandbox.Pending, &items[at - 1], &items[at]);
        }
    }
}

/// A source that hands the fuzzed text over as one chunk, then ends.
const OneChunk = struct {
    bytes: []const u8,
    given: bool = false,

    fn next(context: *anyopaque) anyerror!?[]const u8 {
        const self: *OneChunk = @ptrCast(@alignCast(context));
        if (self.given) return null;
        self.given = true;
        return self.bytes;
    }
};

/// The script's stdout as fuzzed bytes: base64 of a gzip tar, decoded and applied through the real
/// write rules into a temporary folder (V9). Each file it writes is one whose name passes the path
/// rules, and each is recorded once.
fn fuzzBackArchive(_: void, smith: *std.testing.Smith) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = try arena.alloc(u8, 64 * 1024);
    const len = smith.slice(raw);
    var one: OneChunk = .{ .bytes = raw[0..len] };
    var feed: Feed = undefined;
    feed.init(.{ .context = &one, .next_fn = OneChunk.next });
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var manifest = sandbox.emptyManifest();
    var counts: Counts = .{};
    var overflow: std.ArrayList([]const u8) = .empty;
    var baselines: std.array_hash_map.String(BaselineMap) = .empty;
    var notes: Notes = .{ .alloc = arena };
    var apply = testApply(arena, tmp.dir, &manifest, &counts, &overflow, &baselines, &notes, &.{}, max_files_per_run);
    applyArchive(&feed.reader, &apply) catch |err| {
        if (err == error.OutOfMemory) return err;
        return;
    };
    for (manifest.brought.keys()) |rel| {
        switch (checkPath(rel)) {
            .ok => |clean| try testing.expectEqualStrings(rel, clean),
            .refused => return error.TestUnexpectedResult,
        }
    }
    try testing.expectEqual(counts.written, manifest.brought.count());
}

/// The inverse of `unescapeName`, used only to check that a deferred path survives the round trip.
fn escapeForTest(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |byte| switch (byte) {
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        else => try out.append(arena, byte),
    };
    return out.items;
}

/// The text the script prints on stderr, and a name the path rules accept (V9). A deferred line that
/// unescapes escapes back to the same text, and an accepted name has no empty, dot, or `.git` part.
fn fuzzBackText(_: void, smith: *std.testing.Smith) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = try arena.alloc(u8, 64 * 1024);
    const len = smith.slice(raw);
    const bytes = raw[0..len];
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        switch (parseNote(line)) {
            .deferred => |escaped| {
                const path = unescapeName(arena, escaped) catch |err| switch (err) {
                    error.BadEscape => continue,
                    error.OutOfMemory => return err,
                };
                try testing.expectEqualStrings(escaped, try escapeForTest(arena, path));
            },
            else => {},
        }
    }
    switch (checkPath(bytes)) {
        .ok => |clean| {
            var parts = std.mem.splitScalar(u8, clean, '/');
            while (parts.next()) |part| {
                try testing.expect(part.len > 0 and !std.mem.eql(u8, part, ".") and !std.mem.eql(u8, part, ".."));
                try testing.expect(!isGitName(part));
            }
        },
        .refused => {},
    }
}

test "the bring-back archive decodes and writes only files whose names pass the path rules, on fuzzed bytes" {
    try testing.fuzz({}, fuzzBackArchive, .{
        .corpus = &@import("fuzz_corpus").vercel_back_archive.*,
    });
}

test "a stderr note and a deferred path parse or are ignored, a deferred path survives its escaping, and an accepted name is clean, on fuzzed bytes" {
    try testing.fuzz({}, fuzzBackText, .{
        .corpus = &@import("fuzz_corpus").vercel_back_text.*,
    });
}

test "a deferred path unescapes exactly, and a bad escape is refused (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("a\\b\nc\rd", try unescapeName(arena, "a\\\\b\\nc\\rd"));
    try testing.expectError(error.BadEscape, unescapeName(arena, "a\\x"));
    try testing.expectError(error.BadEscape, unescapeName(arena, "a\\"));
}

test "the note parser reads a deferred line as its escaped path, and an empty one as nothing (V9)" {
    switch (parseNote("deferred x\\ny")) {
        .deferred => |text| try testing.expectEqualStrings("x\\ny", text),
        else => return error.TestUnexpectedResult,
    }
    switch (parseNote("deferred ")) {
        .other => {},
        else => return error.TestUnexpectedResult,
    }
}

test "a linked-folder count is read as its number, and a bad one is ignored (V9)" {
    switch (parseNote("linked 3")) {
        .linked => |count| try testing.expectEqual(@as(usize, 3), count),
        else => return error.TestUnexpectedResult,
    }
    switch (parseNote("linked x")) {
        .other => {},
        else => return error.TestUnexpectedResult,
    }
}

test "a deferred path the archive rules refuse is counted, and a good one is kept (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var notes: Notes = .{ .alloc = arena };
    try notes.note("deferred ../escape");
    try notes.note("deferred dir/a\\nb");
    var counts: Counts = .{};
    const names = try deferredBack(arena, &notes, &counts);
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("dir/a\nb", names[0]);
    try testing.expectEqual(@as(usize, 1), counts.skipped_path);
}

test "pending names keep their order, drop repeats, and come after this run's over-cap names (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const overflow = [_][]const u8{ "a", "b" };
    const deferred = [_][]const u8{ "b", "c" };
    const pending = try pendingBack(arena, &overflow, &deferred);
    try testing.expectEqual(@as(usize, 3), pending.names.len);
    try testing.expectEqual(@as(usize, 0), pending.untracked);
    try testing.expectEqualStrings("a", pending.names[0]);
    try testing.expectEqualStrings("c", pending.names[2]);
}

test "pending names past the cap are counted as untracked, once each (N8)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var names: [sandbox.max_pending_names + 2][]const u8 = undefined;
    for (&names, 0..) |*name, index| name.* = try std.fmt.allocPrint(arena, "dir/file-{d}", .{index});
    const overflow = names[0..sandbox.max_pending_names];
    const deferred = [_][]const u8{ names[sandbox.max_pending_names], names[sandbox.max_pending_names], names[sandbox.max_pending_names + 1] };
    const pending = try pendingBack(arena, overflow, &deferred);
    try testing.expectEqual(sandbox.max_pending_names, pending.names.len);
    try testing.expectEqual(@as(usize, 2), pending.untracked);
}

test "pending runs sort oldest first, and an empty list is left alone (V9)" {
    var none: [0]sandbox.Pending = .{};
    sortOldestFirst(&none);
    var items = [_]sandbox.Pending{
        .{ .run_id = "bbbbbbbbbbbbbbbb", .stamp = "fx-stamp-bbbbbbbbbbbbbbbb", .started_ms = 5, .baseline = null },
        .{ .run_id = "aaaaaaaaaaaaaaaa", .stamp = "fx-stamp-aaaaaaaaaaaaaaaa", .started_ms = 2, .baseline = null },
    };
    sortOldestFirst(&items);
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaa", items[0].run_id);
    try testing.expectEqualStrings("bbbbbbbbbbbbbbbb", items[1].run_id);
}

fn listed(names: []const []const u8, stamp: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, stamp)) return true;
    }
    return false;
}

/// True when `rel` is one of the roots or is inside one (V9).
fn underRoot(roots: []const []const u8, rel: []const u8) bool {
    for (roots) |root| {
        if (std.mem.eql(u8, rel, root)) return true;
        if (rel.len > root.len and std.mem.startsWith(u8, rel, root) and rel[root.len] == '/') return true;
    }
    return false;
}

/// A run that ends without a bring-back leaves a pending record (V9). A stop or an unknown result
/// always does, without a baseline. A finished command does only when its bring-back failed, and
/// then with its baseline. A command that was not sent never ran, so it leaves nothing.
pub fn notePending(context: *sandbox.Context, run_id: []const u8, started_ms: i64, baseline: []const sandbox.BringBackFile, outcome: exec.Outcome, brought_failed: bool) sandbox.Error!void {
    const write: sandbox.PendingWrite = switch (outcome) {
        .stopped, .stopped_unsent, .unknown, .gone => .{ .run_id = run_id, .started_ms = started_ms, .baseline = null },
        .exited => if (brought_failed) .{ .run_id = run_id, .started_ms = started_ms, .baseline = baseline } else return,
        .not_sent, .refused_by_wrapper, .sandbox_refused => return,
    };
    try sandbox.writePending(context, write);
}

/// I3: the bring-back of an isolated run, into `destination` (`{S}/runs/{run_id}/`). It holds no
/// lock, reads and writes no manifest or pending record, and tests no Mac file, because the folder is
/// new. The V9 path and name rules and the caps still apply.
pub fn runIsolated(arena: Allocator, ctx: *sandbox.Context, session_id: []const u8, input: Input, destination: std.Io.Dir) Result {
    var manifest = sandbox.emptyManifest();
    var baselines: std.array_hash_map.String(BaselineMap) = .empty;
    var args: std.ArrayList([]const u8) = .empty;
    const own_stamp = sandbox.stampName(arena, input.run_id) catch return .{ .failed = "out of memory" };
    buildArgs(arena, &baselines, &args, own_stamp, input, &.{}, &.{}) catch return .{ .failed = "out of memory" };
    const request = encodeRequest(arena, ctx.repo_root, args.items) catch return .{ .failed = "out of memory" };

    var counts: Counts = .{};
    var overflow: std.ArrayList([]const u8) = .empty;
    var notes: Notes = .{ .alloc = arena };
    var apply: Apply = .{
        .arena = arena,
        .root = destination,
        .manifest = &manifest,
        .counts = &counts,
        .overflow = &overflow,
        .ctx = null,
        .roots = input.roots,
        .baselines = &baselines,
        .notes = &notes,
        .max_files = max_files_per_run,
        .max_bytes = max_bytes_per_run,
    };
    if (fetch(arena, ctx, session_id, request, &apply, &notes)) |detail| return .{ .failed = detail };
    counts.dropped = notes.dropped;
    counts.skipped_kind += notes.linked;
    countSkipped(arena, &manifest, &notes, &counts) catch return .{ .failed = "out of memory" };
    const deferred = deferredBack(arena, &notes, &counts) catch return .{ .failed = "out of memory" };
    counts.over_cap += deferred.len;
    return .{ .done = .{ .counts = counts, .pending = &.{} } };
}

/// Sends the script and applies its archive. Null means it finished; otherwise the detail.
fn fetch(arena: Allocator, ctx: *sandbox.Context, session_id: []const u8, request: []const u8, apply: *Apply, notes: *Notes) ?[]const u8 {
    const path = sandbox.commandPath(ctx, session_id) catch return "out of memory";
    var body: std.Io.Reader = .fixed(request);
    const opened = stream.open(arena, ctx.cancel, ctx.base, ctx.token, ctx.trace, .{
        .step = "bring_back",
        .method = .POST,
        .path = path,
        .body = .{ .sized = .{ .len = request.len, .source = &body } },
        .limits = stream.bring_back_limits,
    }) catch |err| return @errorName(err);
    defer opened.close();
    if (opened.status != 200) return "the sandbox did not accept the bring-back";

    var source: LineSource = .{ .opened = opened, .scratch = std.heap.ArenaAllocator.init(arena), .notes = notes };
    defer source.scratch.deinit();
    var feed: Feed = undefined;
    const text = source.source();
    feed.init(text);
    applyArchive(&feed.reader, apply) catch |err| return @errorName(err);
    while (text.next() catch return "the stream from the sandbox broke") |_| {}
    const code = source.exit_code orelse return "the sandbox did not report an exit code";
    if (code != 0) return "the bring-back script failed";
    return null;
}

/// Reads the gzip tar that `reader` holds, one entry at a time, and applies each one.
fn applyArchive(reader: *std.Io.Reader, apply: *Apply) !void {
    var window: [flate.max_window_len]u8 = undefined;
    var decompress = flate.Decompress.init(reader, .gzip, &window);
    var name_buffer: [tar_name_bytes]u8 = undefined;
    var link_buffer: [tar_name_bytes]u8 = undefined;
    var iterator = std.tar.Iterator.init(&decompress.reader, .{ .file_name_buffer = &name_buffer, .link_name_buffer = &link_buffer });
    while (try iterator.next()) |file| try apply.entry(file, &iterator);
}

/// The request body: the script as one argument, then its arguments (see `script`).
fn encodeRequest(arena: Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    var all: std.ArrayList([]const u8) = .empty;
    try all.appendSlice(arena, &.{ "-c", script, "fx" });
    try all.appendSlice(arena, args);
    return sandbox.encodeJsonOmitNulls(arena, sandbox.CommandBody{
        .command = "bash",
        .args = all.items,
        .cwd = cwd,
    });
}

const PathResult = union(enum) {
    ok: []const u8,
    refused: Refusal,
};

const Refusal = enum { path, git };

/// The path rules for one archive name (V9). The name is relative, has no `..`, no empty
/// part and no `.` part, and no part that is `.git` in the sense of `isGitName`.
fn checkPath(name: []const u8) PathResult {
    var clean = name;
    if (std.mem.startsWith(u8, clean, "./")) clean = clean[2..];
    if (clean.len == 0 or clean.len > sandbox.max_repo_path_bytes or clean[0] == '/') return .{ .refused = .path };
    var parts = std.mem.splitScalar(u8, clean, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return .{ .refused = .path };
        if (isGitName(part)) return .{ .refused = .git };
    }
    return .{ .ok = clean };
}

/// The code points that git's HFS+ check ignores in a name (CVE-2014-9390): on HFS+ the
/// name ".g" + U+200C + "it" is ".git". The list is fixed: U+200C to U+200F, U+202A to
/// U+202E, U+206A to U+206F, and U+FEFF.
fn isHfsIgnored(code_point: u21) bool {
    return switch (code_point) {
        0x200C...0x200F, 0x202A...0x202E, 0x206A...0x206F, 0xFEFF => true,
        else => false,
    };
}

/// True when one name component is `.git` in any case, once the HFS+ ignored code points
/// are removed. U+0131 (dotless i) uppercases to I, so it counts as i. ASCII comparison
/// gives the Unicode answer for this word: no other non-ASCII code point folds to g, i or t.
fn isGitName(part: []const u8) bool {
    const word = ".git";
    var matched: usize = 0;
    var index: usize = 0;
    while (index < part.len) {
        const length = std.unicode.utf8ByteSequenceLength(part[index]) catch return false;
        if (index + length > part.len) return false;
        const code_point = display_width.decodeUtf8Sequence(part[index .. index + length]) catch return false;
        index += length;
        if (isHfsIgnored(code_point)) continue;
        const letter: u8 = if (code_point == 0x131) 'i' else if (code_point < 0x80) std.ascii.toLower(@intCast(code_point)) else return false;
        if (matched == word.len or letter != word[matched]) return false;
        matched += 1;
    }
    return matched == word.len;
}

/// One note line from the script's stderr (V9). The text parts point into the line.
pub const Note = union(enum) {
    root: []const u8,
    missing: []const u8,
    covered: []const u8,
    /// `size mtime` of one file over the size limit.
    skipped: []const u8,
    dropped: usize,
    linked: usize,
    /// A path the script deferred, still escaped (`\\`, `\n`, `\r`). `deferredBack` unescapes it.
    deferred: []const u8,
    other,
};

/// Parses one stderr line of the script. A line that is not one of its notes is `other`.
pub fn parseNote(line: []const u8) Note {
    if (wordOf(line, word_root)) |name| return if (sandbox.validStampName(name)) .{ .root = name } else .other;
    if (wordOf(line, word_missing)) |name| return if (sandbox.validStampName(name)) .{ .missing = name } else .other;
    if (wordOf(line, word_covered)) |name| return if (sandbox.validStampName(name)) .{ .covered = name } else .other;
    if (wordOf(line, word_dropped)) |text| {
        const count = std.fmt.parseInt(usize, text, 10) catch return .other;
        return .{ .dropped = count };
    }
    if (wordOf(line, word_linked)) |text| {
        const count = std.fmt.parseInt(usize, text, 10) catch return .other;
        return .{ .linked = count };
    }
    if (wordOf(line, word_deferred)) |text| return if (text.len > 0) .{ .deferred = text } else .other;
    if (wordOf(line, word_skipped)) |text| return if (isSkippedText(text)) .{ .skipped = text } else .other;
    return .other;
}

fn wordOf(line: []const u8, word: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, line, word)) line[word.len..] else null;
}

/// `size mtime`: a decimal size, then a non-empty time, and nothing more.
fn isSkippedText(text: []const u8) bool {
    var fields = std.mem.splitScalar(u8, text, ' ');
    const size = fields.next() orelse return false;
    const mtime = fields.next() orelse return false;
    if (fields.next() != null or mtime.len == 0) return false;
    _ = std.fmt.parseInt(u64, size, 10) catch return false;
    return true;
}

/// The script's stderr notes, copied out of the stream, so they outlive each line.
const Notes = struct {
    alloc: Allocator,
    root: ?[]const u8 = null,
    dropped: usize = 0,
    linked: usize = 0,
    skipped: std.ArrayList([]const u8) = .empty,
    missing: std.ArrayList([]const u8) = .empty,
    covered: std.ArrayList([]const u8) = .empty,
    deferred: std.ArrayList([]const u8) = .empty,

    fn note(self: *Notes, line: []const u8) !void {
        switch (parseNote(line)) {
            .root => |name| self.root = try self.alloc.dupe(u8, name),
            .missing => |name| try self.missing.append(self.alloc, try self.alloc.dupe(u8, name)),
            .covered => |name| try self.covered.append(self.alloc, try self.alloc.dupe(u8, name)),
            .skipped => |text| try self.skipped.append(self.alloc, try self.alloc.dupe(u8, text)),
            .dropped => |count| self.dropped = count,
            .linked => |count| self.linked = count,
            .deferred => |text| try self.deferred.append(self.alloc, try self.alloc.dupe(u8, text)),
            .other => {},
        }
    }
};

const BadEscape = error{BadEscape};

/// Reverses the script's escaping of a deferred path: `\\` is a backslash, `\n` a line feed and
/// `\r` a carriage return. Any other backslash, or a trailing one, is malformed.
fn unescapeName(arena: Allocator, escaped: []const u8) (Allocator.Error || BadEscape)![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < escaped.len) : (index += 1) {
        if (escaped[index] == '\r' or escaped[index] == '\n') return error.BadEscape;
        if (escaped[index] != '\\') {
            try out.append(arena, escaped[index]);
            continue;
        }
        index += 1;
        if (index >= escaped.len) return error.BadEscape;
        switch (escaped[index]) {
            '\\' => try out.append(arena, '\\'),
            'n' => try out.append(arena, '\n'),
            'r' => try out.append(arena, '\r'),
            else => return error.BadEscape,
        }
    }
    return out.items;
}

/// The paths the script deferred, unescaped and checked by the archive's path rules (V9). A
/// malformed or refused path is counted with the other refusals and is not kept.
fn deferredBack(arena: Allocator, notes: *const Notes, counts: *Counts) Allocator.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (notes.deferred.items) |escaped| {
        const path = unescapeName(arena, escaped) catch |err| switch (err) {
            error.BadEscape => {
                counts.skipped_path += 1;
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        switch (checkPath(path)) {
            .ok => |clean| try names.append(arena, try arena.dupe(u8, clean)),
            .refused => |reason| switch (reason) {
                .path => counts.skipped_path += 1,
                .git => counts.skipped_git += 1,
            },
        }
    }
    return names.items;
}

/// The pending names of a run (V9): `names` is `manifest.pending_back`, this run's over-cap names
/// then the deferred ones, without repeats, at most `sandbox.max_pending_names`. `untracked` counts
/// the unique names past that limit: their files are only counted (N8).
pub const PendingBack = struct {
    names: []const []const u8,
    untracked: usize,
};

fn pendingBack(arena: Allocator, overflow: []const []const u8, deferred: []const []const u8) Allocator.Error!PendingBack {
    var seen: std.array_hash_map.String(void) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var untracked: usize = 0;
    for ([_][]const []const u8{ overflow, deferred }) |list| {
        for (list) |name| {
            if (seen.contains(name)) continue;
            try seen.put(arena, name, {});
            if (names.items.len == sandbox.max_pending_names) {
                untracked += 1;
                continue;
            }
            try names.append(arena, name);
        }
    }
    return .{ .names = names.items, .untracked = untracked };
}

/// Each `skipped` size and mtime counts once, until it changes (V9). A file that is counted is
/// not brought back, and its pair is kept in the manifest.
fn countSkipped(arena: Allocator, manifest: *sandbox.Manifest, notes: *const Notes, counts: *Counts) Allocator.Error!void {
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(arena, manifest.skipped);
    for (notes.skipped.items) |text| {
        if (listed(list.items, text)) continue;
        try list.append(arena, text);
        counts.skipped_big += 1;
    }
    manifest.skipped = list.items;
}

/// The base64 text of the script's stdout, as bytes. It holds one decoded step at a time.
const Feed = struct {
    reader: std.Io.Reader,
    source: Source,
    io_buffer: [io_buffer_bytes]u8,
    decoded: [decode_bytes]u8,
    /// Decoded bytes not yet given to the reader.
    pending: []const u8,
    /// Base64 text not yet decoded.
    chunk: []const u8,
    /// Base64 characters of a group that is not complete yet.
    carry: [4]u8,
    carry_len: usize,

    const vtable: std.Io.Reader.VTable = .{ .stream = streamFeed };

    /// Sets the feed up in place. The reader keeps a pointer to this feed, so it never moves.
    fn init(self: *Feed, source: Source) void {
        self.source = source;
        self.pending = &.{};
        self.chunk = &.{};
        self.carry_len = 0;
        self.reader = .{ .vtable = &vtable, .buffer = &self.io_buffer, .seek = 0, .end = 0 };
    }

    fn streamFeed(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Feed = @fieldParentPtr("reader", reader);
        while (self.pending.len == 0) {
            const more = self.decodeStep() catch return error.ReadFailed;
            if (!more) return error.EndOfStream;
        }
        const take = limit.minInt(self.pending.len);
        writer.writeAll(self.pending[0..take]) catch return error.WriteFailed;
        self.pending = self.pending[take..];
        return take;
    }

    /// Decodes the next base64 characters into `decoded`. False at the end of the text.
    fn decodeStep(self: *Feed) !bool {
        if (self.chunk.len == 0) {
            const next = try self.source.next();
            if (next == null) {
                if (self.carry_len != 0) return error.BadBase64;
                return false;
            }
            self.chunk = next.?;
        }
        const decoder = &std.base64.standard.Decoder;
        var count: usize = 0;
        while (self.chunk.len > 0 and count + 3 <= decode_bytes) {
            const byte = self.chunk[0];
            self.chunk = self.chunk[1..];
            if (byte == '\n' or byte == '\r') continue;
            self.carry[self.carry_len] = byte;
            self.carry_len += 1;
            if (self.carry_len < 4) continue;
            const size = try decoder.calcSizeForSlice(&self.carry);
            try decoder.decode(self.decoded[count..][0..size], &self.carry);
            count += size;
            self.carry_len = 0;
        }
        self.pending = self.decoded[0..count];
        return true;
    }
};

/// Where the feed's base64 text comes from: the next stdout chunk, or null at the end.
const Source = struct {
    context: *anyopaque,
    next_fn: *const fn (context: *anyopaque) anyerror!?[]const u8,

    fn next(self: Source) anyerror!?[]const u8 {
        return self.next_fn(self.context);
    }
};

/// The open stream as a `Source`. Stdout lines are base64 text. Stderr lines are the script's
/// notes. The exit line ends the text.
const LineSource = struct {
    opened: *stream.Stream,
    /// Holds one parsed line at a time. It is reset before each read.
    scratch: std.heap.ArenaAllocator,
    notes: *Notes,
    exit_code: ?i64 = null,

    fn source(self: *LineSource) Source {
        return .{ .context = self, .next_fn = next };
    }

    fn next(context: *anyopaque) anyerror!?[]const u8 {
        const self: *LineSource = @ptrCast(@alignCast(context));
        while (true) {
            _ = self.scratch.reset(.retain_capacity);
            const text = (try self.opened.nextLine()) orelse return null;
            switch (try exec.parseLine(self.scratch.allocator(), text)) {
                .output => |chunk| {
                    if (std.mem.eql(u8, chunk.stream, "stdout")) return chunk.data;
                    var lines = std.mem.splitScalar(u8, chunk.data, '\n');
                    while (lines.next()) |line| try self.notes.note(line);
                },
                .started => {},
                .exited => |exit| {
                    self.exit_code = exit.code;
                    return null;
                },
            }
        }
    }
};

/// The write rules (V9) for each file the archive holds.
const Apply = struct {
    arena: Allocator,
    root: std.Io.Dir,
    manifest: *sandbox.Manifest,
    counts: *Counts,
    overflow: *std.ArrayList([]const u8),
    /// Null in unit tests, where no manifest is written.
    ctx: ?*sandbox.Context,
    roots: []const []const u8,
    /// Each stamp's baseline, keyed by the stamp name the script reports as its root.
    baselines: *std.array_hash_map.String(BaselineMap),
    notes: *const Notes,
    /// Each name the archive has listed, so a repeated path is dropped (V9).
    seen: std.array_hash_map.String(void) = .empty,
    max_files: usize,
    max_bytes: u64,
    manifest_writes: usize = 0,
    written_files: usize = 0,
    written_bytes: u64 = 0,

    const Target = enum { same, kept, case, overflow, write };

    fn entry(self: *Apply, file: std.tar.Iterator.File, iterator: *std.tar.Iterator) !void {
        const key = if (std.mem.startsWith(u8, file.name, "./")) file.name[2..] else file.name;
        if (self.seen.contains(key)) return;
        try self.seen.put(self.arena, try self.arena.dupe(u8, key), {});
        if (file.kind != .file) {
            self.counts.skipped_kind += 1;
            return;
        }
        const rel = switch (checkPath(file.name)) {
            .ok => |clean| try self.arena.dupe(u8, clean),
            .refused => |reason| {
                switch (reason) {
                    .path => self.counts.skipped_path += 1,
                    .git => self.counts.skipped_git += 1,
                }
                return;
            },
        };
        if (file.size > max_file_bytes) {
            self.counts.skipped_big += 1;
            return;
        }
        try self.write(rel, file, iterator);
    }

    fn write(self: *Apply, rel: []const u8, file: std.tar.Iterator.File, iterator: *std.tar.Iterator) !void {
        const io = io_mod.getIo();
        const slash = std.mem.findScalarLast(u8, rel, '/');
        const parent_path = if (slash) |index| rel[0..index] else "";
        const base = if (slash) |index| rel[index + 1 ..] else rel;

        var opened: std.ArrayList(std.Io.Dir) = .empty;
        defer {
            for (opened.items) |dir| dir.close(io);
        }
        const parent = (try self.openParent(parent_path, &opened)) orelse return;
        const temp_name = try self.tempName();
        const mode: std.posix.mode_t = if (file.mode & 0o111 != 0) 0o755 else 0o644;
        var renamed = false;
        defer if (!renamed) parent.deleteFile(io, temp_name) catch |err| debug_trace.logf("remote run", "event=temp_cleanup_failed reason={s}", .{@errorName(err)});
        try writeTemp(parent, temp_name, mode, file, iterator);

        const new_sha = try hashNamed(parent, temp_name);
        switch (try self.decide(parent, base, rel, &new_sha, file.size)) {
            .same => {},
            .kept => self.counts.kept += 1,
            .case => self.counts.skipped_case += 1,
            .overflow => {
                self.counts.over_cap += 1;
                try self.overflow.append(self.arena, rel);
            },
            .write => {
                try parent.rename(temp_name, parent, base, io);
                renamed = true;
                try self.recordWritten(rel, parent, base, file.size, &new_sha);
                self.written_files += 1;
                self.written_bytes += file.size;
                self.counts.written += 1;
            },
        }
    }

    /// Opens the folder that holds the file, one level at a time, without following links
    /// (V9). A missing folder is created. A link, a file, or a name spelled differently from
    /// the Mac's entry refuses the path. Null means it was refused and counted.
    fn openParent(self: *Apply, parent_path: []const u8, opened: *std.ArrayList(std.Io.Dir)) !?std.Io.Dir {
        const io = io_mod.getIo();
        var dir = self.root;
        var parts = std.mem.splitScalar(u8, parent_path, '/');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            if (dir.statFile(io, part, .{ .follow_symlinks = false })) |stat| {
                if (stat.kind != .directory) {
                    self.counts.skipped_folder += 1;
                    return null;
                }
                if (!try hasExactName(dir, part)) {
                    self.counts.skipped_case += 1;
                    return null;
                }
            } else |err| switch (err) {
                error.FileNotFound => try dir.createDir(io, part, .default_dir),
                else => return err,
            }
            const next = try dir.openDir(io, part, .{ .iterate = true, .follow_symlinks = false });
            try opened.append(self.arena, next);
            dir = next;
        }
        return dir;
    }

    /// The decision for one file whose content is already in its temp file (V9). Content equal
    /// to the manifest's `files` record or to the Mac's file is dropped. A tracked file is written
    /// only when the Mac file still matches its record. Any other file is written when the Mac file
    /// is unchanged since the run started (a root file only), or matches the `brought` record, or
    /// when neither file exists. Then the caps apply.
    fn decide(self: *Apply, parent: std.Io.Dir, base: []const u8, rel: []const u8, new_sha: []const u8, size: u64) !Target {
        const io = io_mod.getIo();
        const tracked = self.manifest.files.get(rel);
        if (tracked) |found| {
            if (std.mem.eql(u8, found.sha256, new_sha)) return .same;
        }
        const was = if (self.underRootOf(rel)) self.baselineOf(rel) else null;
        const mac = parent.statFile(io, base, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return self.missingTarget(tracked != null, was, size),
            else => return err,
        };
        if (!try hasExactName(parent, base)) return .case;
        if (mac.kind != .file) return .kept;
        const mac_sha = try hashNamed(parent, base);
        if (std.mem.eql(u8, &mac_sha, new_sha)) return .same;
        if (tracked) |found| {
            if (!std.mem.eql(u8, &mac_sha, found.sha256)) return .kept;
            return self.fits(size);
        }
        if (was) |start| {
            if (start.size == mac.size and start.mtime_ns == sync.mtimeNs(mac)) return self.fits(size);
        }
        if (self.manifest.brought.get(rel)) |record| {
            if (std.mem.eql(u8, &mac_sha, record.sha256)) return self.fits(size);
        }
        return .kept;
    }

    /// The Mac file is missing. A tracked file the user deleted stays deleted, and so does a root
    /// file that existed at run start. Any other file is written.
    fn missingTarget(self: *const Apply, tracked: bool, was: ?sandbox.BringBackFile, size: u64) Target {
        if (tracked or was != null) return .kept;
        return self.fits(size);
    }

    fn fits(self: *const Apply, size: u64) Target {
        if (self.written_files >= self.max_files or self.written_bytes + size > self.max_bytes) return .overflow;
        return .write;
    }

    fn underRootOf(self: *const Apply, rel: []const u8) bool {
        return underRoot(self.roots, rel);
    }

    /// The baseline entry of `rel` under the root the script reported, or null.
    fn baselineOf(self: *const Apply, rel: []const u8) ?sandbox.BringBackFile {
        const name = self.notes.root orelse return null;
        const map = self.baselines.getPtr(name) orelse return null;
        return map.get(rel);
    }

    /// Records a written file before the next one is written (V9). The record goes to the manifest
    /// in memory, and to the journal under the lock, fsynced. The manifest is rewritten once, in finish.
    fn recordWritten(self: *Apply, rel: []const u8, parent: std.Io.Dir, base: []const u8, size: u64, sha: []const u8) !void {
        const stat = try parent.statFile(io_mod.getIo(), base, .{ .follow_symlinks = false });
        const record: journal.Record = .{
            .kind = if (self.manifest.files.contains(rel)) .files else .brought,
            .rel = rel,
            .size = size,
            .mtime_ns = sync.mtimeNs(stat),
            .sha256 = sha,
        };
        try sandbox.applyBackRecord(self.arena, self.manifest, record);
        if (self.ctx) |ctx| try journal.append(self.arena, ctx.state_dir, record);
    }

    /// Writes the manifest once, from the records this bring-back applied (V9), then removes the
    /// journal they were in. If the write fails, the journal stays for the next run's fold.
    fn finish(self: *Apply) !void {
        self.manifest_writes += 1;
        const ctx = self.ctx orelse return;
        try sandbox.commitManifest(ctx, self.manifest);
        journal.remove(ctx.state_dir) catch return error.JournalNotRemoved;
    }

    fn tempName(self: *Apply) ![]const u8 {
        var bytes: [8]u8 = undefined;
        io_mod.getIo().random(&bytes);
        const hex = std.fmt.bytesToHex(bytes, .lower);
        return self.arena.print("{s}{s}{s}", .{ temp_prefix, hex[0..], temp_suffix });
    }
};

/// Writes the archive's content to a new temp file in `parent`, with the mode V9 gives.
fn writeTemp(parent: std.Io.Dir, name: []const u8, mode: std.posix.mode_t, file: std.tar.Iterator.File, iterator: *std.tar.Iterator) !void {
    const io = io_mod.getIo();
    var temp = try parent.createFile(io, name, .{
        .exclusive = true,
        .permissions = std.Io.File.Permissions.fromMode(mode),
    });
    defer temp.close(io);
    var buffer: [io_buffer_bytes]u8 = undefined;
    var writer = temp.writer(io, &buffer);
    try iterator.streamRemaining(file, &writer.interface);
    try writer.interface.flush();
}

/// True when the folder holds an entry spelled exactly `name`. A case-insensitive file
/// system finds a file under any case, so the spelling is checked here (V9).
fn hasExactName(dir: std.Io.Dir, name: []const u8) !bool {
    const io = io_mod.getIo();
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

/// The SHA-256 of a file's content, as lowercase hex, read in steps.
fn hashNamed(parent: std.Io.Dir, name: []const u8) ![64]u8 {
    const io = io_mod.getIo();
    var file = try parent.openFile(io, name, .{});
    defer file.close(io);
    var buffer: [io_buffer_bytes]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var hasher = Sha256.init(.{});
    var chunk: [io_buffer_bytes]u8 = undefined;
    while (true) {
        const count = try reader.interface.readSliceShort(&chunk);
        if (count == 0) break;
        hasher.update(chunk[0..count]);
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

const testing = std.testing;

test "the bring-back script is pinned byte for byte (V9)" {
    try testing.expectEqualStrings(
        \\set -u
        \\own=$1
        \\n=$2
        \\m=$3
        \\shift 3
        \\for ((i = 0; i < m; i++)); do
        \\  rm -f -- ".git/$1"
        \\  shift
        \\done
        \\work=$(mktemp -d) || exit 1
        \\trap 'rm -rf "$work"' EXIT
        \\main=""
        \\root=""
        \\: > "$work/covered"
        \\for ((i = 0; i < n; i++)); do
        \\  arg=$1
        \\  shift
        \\  kind=${arg:0:1}
        \\  name=${arg:1}
        \\  if [ -e ".git/$name" ]; then
        \\    [ -n "$main" ] || main=$name
        \\    if [ "$kind" = b ] && [ -z "$root" ]; then root=$name; fi
        \\    printf '%s\0' "$name" >> "$work/covered"
        \\  else
        \\    printf 'missing %s\n' "$name" >&2
        \\  fi
        \\done
        \\[ -n "$main" ] || main=$own
        \\[ -n "$root" ] || root=$own
        \\printf 'root %s\n' "$root" >&2
        \\roots=()
        \\if [ -s .git/fx-bring-back ]; then mapfile -t -d '' roots < .git/fx-bring-back; fi
        \\under_root() {
        \\  local r
        \\  for r in "${roots[@]}"; do
        \\    case "$1" in "$r"|"$r"/*) return 0 ;; esac
        \\  done
        \\  return 1
        \\}
        \\declare -A ignored=() pushed=() seen=() sent=()
        \\sent_file=".git/fx-sent-${own#fx-stamp-}"
        \\if [ -s "$sent_file" ]; then
        \\  mapfile -d '' -t sent_list < "$sent_file"
        \\  for p in "${sent_list[@]}"; do sent[${p#./}]=1; done
        \\fi
        \\newer_own=( \( -newer ".git/$own" -o -cnewer ".git/$own" \) )
        \\newer_main=( \( -newer ".git/$main" -o -cnewer ".git/$main" \) )
        \\newer_root=( \( -newer ".git/$root" -o -cnewer ".git/$root" \) )
        \\files=( \( -type f -o -type l \) )
        \\find . "${newer_own[@]}" "${files[@]}" ! -path '*/.git/*' -printf '%s\t%T@\t%p\0' > "$work/own_main" 2> /dev/null
        \\find . "${newer_main[@]}" ! "${newer_own[@]}" "${files[@]}" ! -path '*/.git/*' -printf '%s\t%T@\t%p\0' > "$work/range_main" 2> /dev/null
        \\: > "$work/own_root"
        \\: > "$work/range_root"
        \\if [ -s .git/fx-bring-back ]; then
        \\  xargs -0 -I{} find ./{} "${newer_own[@]}" "${files[@]}" -printf '%s\t%T@\t%p\0' < .git/fx-bring-back > "$work/own_root" 2> /dev/null || true
        \\  xargs -0 -I{} find ./{} "${newer_root[@]}" ! "${newer_own[@]}" "${files[@]}" -printf '%s\t%T@\t%p\0' < .git/fx-bring-back > "$work/range_root" 2> /dev/null || true
        \\fi
        \\: > "$work/args"
        \\if [ -s .git/fx-pending-back ]; then
        \\  physroot=$(pwd -P)
        \\  : > "$work/pkept"
        \\  xargs -0 -r dirname -z -- < .git/fx-pending-back > "$work/pdirs" 2> /dev/null || true
        \\  xargs -0 -r realpath -m -z --relative-to="$physroot" -- < "$work/pdirs" > "$work/prel" 2> /dev/null || true
        \\  if cmp -s "$work/pdirs" "$work/prel"; then
        \\    cp .git/fx-pending-back "$work/pkept"
        \\  else
        \\    mapfile -d '' -t pending < .git/fx-pending-back
        \\    mapfile -d '' -t pdir_list < "$work/pdirs"
        \\    mapfile -d '' -t prel_list < "$work/prel"
        \\    kept=()
        \\    if [ "${#prel_list[@]}" -eq "${#pdir_list[@]}" ] && [ "${#pdir_list[@]}" -eq "${#pending[@]}" ]; then
        \\      for i in "${!pending[@]}"; do
        \\        if [ "${prel_list[$i]}" = "${pdir_list[$i]}" ]; then kept+=("${pending[$i]}"); fi
        \\      done
        \\    fi
        \\    if [ "${#kept[@]}" -gt 0 ]; then printf '%s\0' "${kept[@]}" > "$work/pkept"; fi
        \\    linked=$(( ${#pending[@]} - ${#kept[@]} ))
        \\    if [ "$linked" -gt 0 ]; then printf 'linked %s\n' "$linked" >&2; fi
        \\  fi
        \\  if [ -s "$work/pkept" ]; then
        \\    find -files0-from "$work/pkept" -maxdepth 0 "${files[@]}" -printf '%s\t%T@\t%p\0' > "$work/args" 2> /dev/null || true
        \\  fi
        \\fi
        \\check_list=()
        \\check_group() {
        \\  local rec rest size mtime path
        \\  local -a recs
        \\  mapfile -d '' -t recs < "$2"
        \\  for rec in "${recs[@]}"; do
        \\    size=${rec%%$'\t'*}
        \\    rest=${rec#*$'\t'}
        \\    mtime=${rest%%$'\t'*}
        \\    path=${rest#*$'\t'}
        \\    if [ "$size" -gt 67108864 ]; then continue; fi
        \\    check_list+=("${path#./}")
        \\  done
        \\}
        \\check_group o "$work/own_main"
        \\check_group m "$work/range_main"
        \\check_group a "$work/args"
        \\: > "$work/check"
        \\if [ "${#check_list[@]}" -gt 0 ]; then printf '%s\0' "${check_list[@]}" > "$work/check"; fi
        \\git check-ignore --no-index --stdin -z < "$work/check" > "$work/ignored" 2> /dev/null || true
        \\mapfile -d '' -t ignored_list < "$work/ignored"
        \\for p in "${ignored_list[@]}"; do ignored[${p#./}]=1; done
        \\if [ -s .git/fx-pushed ]; then
        \\  mapfile -d '' -t pushed_list < .git/fx-pushed
        \\  for p in "${pushed_list[@]}"; do pushed[$p]=1; done
        \\fi
        \\keep=()
        \\count=0
        \\bytes=0
        \\full=0
        \\dropped=0
        \\take_group() {
        \\  local origin=$1 rec rest size mtime path key esc
        \\  local -a recs
        \\  mapfile -d '' -t recs < "$2"
        \\  for rec in "${recs[@]}"; do
        \\    size=${rec%%$'\t'*}
        \\    rest=${rec#*$'\t'}
        \\    mtime=${rest%%$'\t'*}
        \\    path=${rest#*$'\t'}
        \\    key=${path#./}
        \\    if [ "$origin" = o ] || [ "$origin" = m ]; then
        \\      if [ "${#roots[@]}" -gt 0 ] && under_root "$key"; then continue; fi
        \\    fi
        \\    if [ "$origin" = m ] || [ "$origin" = r ] || [ "$origin" = a ]; then
        \\      if [ -n "${sent[$key]:-}" ]; then continue; fi
        \\    fi
        \\    if [ -n "${seen[$key]:-}" ]; then continue; fi
        \\    seen[$key]=1
        \\    if [ "$size" -gt 67108864 ]; then printf 'skipped %s %s\n' "$size" "$mtime" >&2; continue; fi
        \\    if [ -n "${ignored[$key]:-}" ] && [ -z "${pushed[$key]:-}" ] && { [ "${#roots[@]}" -eq 0 ] || ! under_root "$key"; }; then
        \\      dropped=$((dropped + 1))
        \\      continue
        \\    fi
        \\    if [ "$full" -eq 0 ] && [ $((count + 1)) -le 2000 ] && [ $((bytes + size)) -le 67108864 ]; then
        \\      keep+=("$path")
        \\      count=$((count + 1))
        \\      bytes=$((bytes + size))
        \\    else
        \\      full=1
        \\      esc=${key//'\'/'\\'}
        \\      esc=${esc//$'\n'/'\n'}
        \\      esc=${esc//$'\r'/'\r'}
        \\      printf 'deferred %s\n' "$esc" >&2
        \\    fi
        \\  done
        \\}
        \\take_group o "$work/own_main"
        \\take_group R "$work/own_root"
        \\take_group m "$work/range_main"
        \\take_group r "$work/range_root"
        \\take_group a "$work/args"
        \\: > "$work/keep"
        \\if [ "${#keep[@]}" -gt 0 ]; then printf '%s\0' "${keep[@]}" > "$work/keep"; fi
        \\printf 'dropped %s\n' "$dropped" >&2
        \\tar -cz --no-recursion --null -T - < "$work/keep" | base64
        \\status=$?
        \\rm -f -- "$sent_file"
        \\while IFS= read -r -d '' name; do printf 'covered %s\n' "$name" >&2; done < "$work/covered"
        \\exit $status
    , script);
}

test "a path is checked before any byte is written (V9)" {
    const cases = [_]struct { name: []const u8, want: ?[]const u8, refusal: ?Refusal }{
        .{ .name = "a/b.txt", .want = "a/b.txt", .refusal = null },
        .{ .name = "./a/b.txt", .want = "a/b.txt", .refusal = null },
        .{ .name = "../x", .want = null, .refusal = .path },
        .{ .name = "/abs", .want = null, .refusal = .path },
        .{ .name = "a/../b", .want = null, .refusal = .path },
        .{ .name = "a//b", .want = null, .refusal = .path },
        .{ .name = "a/./b", .want = null, .refusal = .path },
        .{ .name = "", .want = null, .refusal = .path },
        .{ .name = ".git", .want = null, .refusal = .git },
        .{ .name = ".git/config", .want = null, .refusal = .git },
        .{ .name = ".GIT/config", .want = null, .refusal = .git },
        .{ .name = "x/.Git/y", .want = null, .refusal = .git },
    };
    for (cases) |case| switch (checkPath(case.name)) {
        .ok => |clean| {
            try testing.expect(case.refusal == null);
            try testing.expectEqualStrings(case.want.?, clean);
        },
        .refused => |reason| {
            try testing.expectEqual(case.refusal.?, reason);
        },
    };
}

test "a name that is .git after HFS+ ignores and case folding is refused, and .github is not (V9)" {
    const refused = [_][]const u8{
        ".g\u{200C}it/config",
        ".GIT\u{FEFF}/x",
        ".g\u{0131}t/x",
        "sub/.g\u{200D}it/hooks/y",
    };
    const allowed = [_][]const u8{ ".github/x", ".gitignore" };
    for (refused) |name| {
        const result = checkPath(name);
        try testing.expect(std.meta.activeTag(result) == .refused);
        try testing.expectEqual(Refusal.git, result.refused);
    }
    for (allowed) |name| try testing.expect(std.meta.activeTag(checkPath(name)) == .ok);
}

test "base64 text decodes across lines and steps (V9)" {
    const Fixed = struct {
        parts: []const []const u8,
        index: usize = 0,

        fn next(context: *anyopaque) anyerror!?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.index == self.parts.len) return null;
            defer self.index += 1;
            return self.parts[self.index];
        }
    };
    var fixed: Fixed = .{ .parts = &.{ "aGVs", "bG8g\nd29y", "bGQ=" } };
    var feed: Feed = undefined;
    feed.init(.{ .context = &fixed, .next_fn = Fixed.next });
    var out: [32]u8 = undefined;
    const count = try feed.reader.readSliceShort(&out);
    try testing.expectEqualStrings("hello world", out[0..count]);
}

test "each stderr note of the script is read as its own kind (V9)" {
    try testing.expectEqualStrings("fx-stamp-0123456789abcdef", parseNote("root fx-stamp-0123456789abcdef").root);
    try testing.expectEqualStrings("fx-stamp-0123456789abcdef", parseNote("missing fx-stamp-0123456789abcdef").missing);
    try testing.expectEqualStrings("fx-stamp-0123456789abcdef", parseNote("covered fx-stamp-0123456789abcdef").covered);
    try testing.expectEqualStrings("70000000 1700000000.5", parseNote("skipped 70000000 1700000000.5").skipped);
    try testing.expectEqual(@as(usize, 3), parseNote("dropped 3").dropped);
    try testing.expect(std.meta.activeTag(parseNote("root fx-stamp-../../x")) == .other);
    try testing.expect(std.meta.activeTag(parseNote("missing fx-stamp-XYZ")) == .other);
    try testing.expect(std.meta.activeTag(parseNote("skipped x 1")) == .other);
    try testing.expect(std.meta.activeTag(parseNote("skipped 5")) == .other);
    try testing.expect(std.meta.activeTag(parseNote("skipped 5 1 extra")) == .other);
    try testing.expect(std.meta.activeTag(parseNote("dropped many")) == .other);
    try testing.expect(std.meta.activeTag(parseNote("noise here")) == .other);
}

test "a name is matched to the Mac's spelling exactly (V9)" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();
    try tmp.dir.writeFile(io, .{ .sub_path = "case.txt", .data = "x" });
    try testing.expect(try hasExactName(tmp.dir, "case.txt"));
    try testing.expect(!try hasExactName(tmp.dir, "Case.txt"));
}

const TestEntry = struct {
    name: []const u8,
    data: []const u8 = "",
    mode: u32 = 0o644,
    link: bool = false,
};

fn buildArchive(arena: Allocator, entries: []const TestEntry) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(arena, 4096);
    var window: [flate.max_window_len]u8 = undefined;
    var compressor = try flate.Compress.init(&out.writer, &window, .gzip, flate.Compress.Options.default);
    var tar: std.tar.Writer = .{ .underlying_writer = &compressor.writer };
    for (entries) |entry| {
        if (entry.link) {
            try tar.writeLink(entry.name, entry.data, .{ .mode = 0o777 });
        } else {
            try tar.writeFileBytes(entry.name, entry.data, .{ .mode = entry.mode });
        }
    }
    try tar.finishPedantically();
    try compressor.finish();
    return out.written();
}

fn testManifest(arena: Allocator, files: []const struct { path: []const u8, sha: []const u8 }) !sandbox.Manifest {
    var map: sandbox.FileMap = .empty;
    for (files) |file| try map.put(arena, file.path, .{ .size = 0, .mtime_ns = 0, .sha256 = file.sha });
    return .{
        .generation = "generation-1",
        .files = map,
        .excludes = null,
        .pending_back = &.{},
        .brought = .empty,
        .skipped = &.{},
        .bring_back_roots = null,
    };
}

/// An `Apply` for a test: no roots, no baseline, no manifest on disk.
fn testApply(arena: Allocator, root: std.Io.Dir, manifest: *sandbox.Manifest, counts: *Counts, overflow: *std.ArrayList([]const u8), baselines: *std.array_hash_map.String(BaselineMap), notes: *const Notes, roots: []const []const u8, max_files: usize) Apply {
    return .{
        .arena = arena,
        .root = root,
        .manifest = manifest,
        .counts = counts,
        .overflow = overflow,
        .ctx = null,
        .roots = roots,
        .baselines = baselines,
        .notes = notes,
        .max_files = max_files,
        .max_bytes = max_bytes_per_run,
    };
}

fn shaHex(text: []const u8) [64]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(text, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn readBack(arena: Allocator, dir: std.Io.Dir, name: []const u8) ![]u8 {
    var file = try dir.openFile(io_mod.getIo(), name, .{});
    defer file.close(io_mod.getIo());
    var buffer: [256]u8 = undefined;
    var reader = file.reader(io_mod.getIo(), &buffer);
    return reader.interface.allocRemaining(arena, .unlimited);
}

test "the write rules write, keep, drop and refuse each file (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();

    try tmp.dir.writeFile(io, .{ .sub_path = "kept.txt", .data = "mac-edit" });
    try tmp.dir.writeFile(io, .{ .sub_path = "same.txt", .data = "manifest" });

    const archive = try buildArchive(arena, &.{
        .{ .name = "new/fresh.txt", .data = "fresh" },
        .{ .name = "bin/tool", .data = "run", .mode = 0o755 },
        .{ .name = "kept.txt", .data = "sandbox-edit" },
        .{ .name = "same.txt", .data = "manifest" },
        .{ .name = "link", .data = "fresh.txt", .link = true },
        .{ .name = "../escape", .data = "x" },
        .{ .name = ".git/hooks/pre", .data = "x" },
    });
    const kept_sha = shaHex("manifest-kept");
    const same_sha = shaHex("manifest");
    var manifest = try testManifest(arena, &.{
        .{ .path = "kept.txt", .sha = &kept_sha },
        .{ .path = "same.txt", .sha = &same_sha },
    });
    var counts: Counts = .{};
    var overflow: std.ArrayList([]const u8) = .empty;
    var baselines: std.array_hash_map.String(BaselineMap) = .empty;
    var notes: Notes = .{ .alloc = arena };
    var apply = testApply(arena, tmp.dir, &manifest, &counts, &overflow, &baselines, &notes, &.{}, max_files_per_run);
    var input: std.Io.Reader = .fixed(archive);
    try applyArchive(&input, &apply);

    try testing.expectEqualStrings("fresh", try readBack(arena, tmp.dir, "new/fresh.txt"));
    try testing.expectEqualStrings("run", try readBack(arena, tmp.dir, "bin/tool"));
    try testing.expectEqualStrings("mac-edit", try readBack(arena, tmp.dir, "kept.txt"));
    try testing.expectEqualStrings("manifest", try readBack(arena, tmp.dir, "same.txt"));
    try testing.expectEqual(@as(usize, 2), counts.written);
    try testing.expectEqual(@as(usize, 1), counts.kept);
    try testing.expectEqual(@as(usize, 1), counts.skipped_kind);
    try testing.expectEqual(@as(usize, 1), counts.skipped_path);
    try testing.expectEqual(@as(usize, 1), counts.skipped_git);
    try testing.expectEqual(@as(usize, 0), overflow.items.len);
}

test "fifty files written by one bring-back rewrite the manifest once, at its end (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const entries = try arena.alloc(TestEntry, 50);
    for (entries, 0..) |*entry, index| {
        entry.* = .{ .name = try std.fmt.allocPrint(arena, "batch/file-{d:0>2}.txt", .{index}), .data = "fresh" };
    }
    const archive = try buildArchive(arena, entries);
    var manifest = try testManifest(arena, &.{});
    var counts: Counts = .{};
    var overflow: std.ArrayList([]const u8) = .empty;
    var baselines: std.array_hash_map.String(BaselineMap) = .empty;
    var notes: Notes = .{ .alloc = arena };
    var apply = testApply(arena, tmp.dir, &manifest, &counts, &overflow, &baselines, &notes, &.{}, max_files_per_run);
    var input: std.Io.Reader = .fixed(archive);
    try applyArchive(&input, &apply);

    try testing.expectEqual(@as(usize, 50), counts.written);
    try testing.expectEqual(@as(usize, 0), apply.manifest_writes);
    try apply.finish();
    try testing.expectEqual(@as(usize, 1), apply.manifest_writes);
}

test "a file written but never journaled counts as changed on this machine when the Mac copy then differs (N9)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();

    // The bring-back wrote "written" and crashed before its journal line. The Mac copy changed after that.
    try tmp.dir.writeFile(io, .{ .sub_path = "unjournaled.txt", .data = "mac-edit" });
    var manifest = try testManifest(arena, &.{});
    const archive = try buildArchive(arena, &.{.{ .name = "unjournaled.txt", .data = "written" }});
    var counts: Counts = .{};
    var overflow: std.ArrayList([]const u8) = .empty;
    var baselines: std.array_hash_map.String(BaselineMap) = .empty;
    var notes: Notes = .{ .alloc = arena };
    var apply = testApply(arena, tmp.dir, &manifest, &counts, &overflow, &baselines, &notes, &.{}, max_files_per_run);
    var input: std.Io.Reader = .fixed(archive);
    try applyArchive(&input, &apply);

    try testing.expectEqualStrings("mac-edit", try readBack(arena, tmp.dir, "unjournaled.txt"));
    try testing.expectEqual(@as(usize, 1), counts.kept);
    try testing.expectEqual(@as(usize, 0), counts.written);
}

test "a journal that cannot be removed after the manifest is written is reported as such (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var context: sandbox.Context = .{
        .alloc = arena,
        .cancel = &cancel,
        .base = transport.resolveBaseUrl(null),
        .token = .{ .value = "fx-test-token" },
        .trace = capture.trace(),
        .team_id = "team_1",
        .project_id = "prj_1",
        .name = "fx-repo",
        .repo_root = "/vercel/sandbox/repo",
        .state_dir = &state_dir,
    };
    var manifest = try testManifest(arena, &.{});
    manifest.generation = "generation-1";
    var counts: Counts = .{};
    var overflow: std.ArrayList([]const u8) = .empty;
    var baselines: std.array_hash_map.String(BaselineMap) = .empty;
    var notes: Notes = .{ .alloc = arena };
    var apply = testApply(arena, tmp.dir, &manifest, &counts, &overflow, &baselines, &notes, &.{}, max_files_per_run);
    apply.ctx = &context;

    // A folder where the journal file belongs cannot be removed as a file.
    try state_dir.dir.createDir(io, journal.file_name, std.Io.File.Permissions.fromMode(0o700));
    try testing.expectError(error.JournalNotRemoved, apply.finish());
}

test "a failed manifest write keeps every covered pending record for the next run (N8)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var context: sandbox.Context = .{
        .alloc = arena,
        .cancel = &cancel,
        .base = transport.resolveBaseUrl(null),
        .token = .{ .value = "fx-test-token" },
        .trace = capture.trace(),
        .team_id = "team_1",
        .project_id = "prj_1",
        .name = "fx-repo",
        .repo_root = "/vercel/sandbox/repo",
        .state_dir = &state_dir,
    };
    const baseline = [_]sandbox.BringBackFile{.{ .rel = "out/app", .size = 7, .mtime_ns = 9 }};
    try notePending(&context, "0123456789abcdef", 42, &baseline, .{ .exited = 0 }, true);
    // A folder where manifest.json belongs makes the manifest write fail.
    try state_dir.dir.createDir(io, "manifest.json", std.Io.File.Permissions.fromMode(0o700));
    const ordered = try sandbox.readPending(arena, &context);
    var manifest = try testManifest(arena, &.{});
    var counts: Counts = .{};
    var overflow: std.ArrayList([]const u8) = .empty;
    var baselines: std.array_hash_map.String(BaselineMap) = .empty;
    var notes: Notes = .{ .alloc = arena };
    try notes.covered.append(arena, ordered[0].stamp);
    var apply = testApply(arena, tmp.dir, &manifest, &counts, &overflow, &baselines, &notes, &.{}, max_files_per_run);
    apply.ctx = &context;

    const detail = commitRun(&context, &apply, &manifest, &.{"zig-out/bin/over-cap.txt"}, ordered, &notes, &.{});
    try testing.expectEqualStrings("the manifest could not be written", detail.?);
    // The record stays, so the next run walks the stamp again and rebuilds the over-cap names.
    const pending = try sandbox.readPending(arena, &context);
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqualStrings("0123456789abcdef", pending[0].run_id);
}

test "a pending record that outlives a committed bring-back is walked again, and no file is brought back twice (N8)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var context: sandbox.Context = .{
        .alloc = arena,
        .cancel = &cancel,
        .base = transport.resolveBaseUrl(null),
        .token = .{ .value = "fx-test-token" },
        .trace = capture.trace(),
        .team_id = "team_1",
        .project_id = "prj_1",
        .name = "fx-repo",
        .repo_root = "/vercel/sandbox/repo",
        .state_dir = &state_dir,
    };
    const baseline = [_]sandbox.BringBackFile{.{ .rel = "out/app", .size = 7, .mtime_ns = 9 }};
    try notePending(&context, "0123456789abcdef", 42, &baseline, .{ .exited = 0 }, true);
    const archive = try buildArchive(arena, &.{
        .{ .name = "one.txt", .data = "1" },
        .{ .name = "two.txt", .data = "2" },
    });

    // The first run writes one.txt, leaves two.txt past its cap, and commits the manifest.
    var manifest = try testManifest(arena, &.{});
    var counts: Counts = .{};
    var overflow: std.ArrayList([]const u8) = .empty;
    var baselines: std.array_hash_map.String(BaselineMap) = .empty;
    var notes: Notes = .{ .alloc = arena };
    var apply = testApply(arena, tmp.dir, &manifest, &counts, &overflow, &baselines, &notes, &.{}, 1);
    apply.ctx = &context;
    var first_input: std.Io.Reader = .fixed(archive);
    try applyArchive(&first_input, &apply);
    try apply.finish();
    try testing.expectEqual(@as(usize, 1), counts.written);

    // A crash after the commit and before the pending record is removed leaves the record. The next run
    // reads the manifest from disk and walks the same archive again.
    var next_manifest = try sandbox.readManifest(&context);
    var next_counts: Counts = .{};
    var next_overflow: std.ArrayList([]const u8) = .empty;
    var next_baselines: std.array_hash_map.String(BaselineMap) = .empty;
    var next_notes: Notes = .{ .alloc = arena };
    var next = testApply(arena, tmp.dir, &next_manifest, &next_counts, &next_overflow, &next_baselines, &next_notes, &.{}, 1);
    next.ctx = &context;
    var again: std.Io.Reader = .fixed(archive);
    try applyArchive(&again, &next);
    try testing.expectEqual(@as(usize, 1), next_counts.written);
    try testing.expectEqual(@as(usize, 0), next_overflow.items.len);
    try testing.expectEqual(@as(usize, 2), next_manifest.brought.count());

    // The next run commits, and its covered record is removed.
    const pending = try sandbox.readPending(arena, &context);
    try testing.expectEqual(@as(usize, 1), pending.len);
    try next_notes.covered.append(arena, pending[0].stamp);
    try testing.expect(commitRun(&context, &next, &next_manifest, &.{}, pending, &next_notes, &.{}) == null);
    try testing.expectEqual(@as(usize, 0), (try sandbox.readPending(arena, &context)).len);
}

test "a committed bring-back records its own and covered stamps as spent, replacing the old list (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var context: sandbox.Context = .{
        .alloc = arena,
        .cancel = &cancel,
        .base = transport.resolveBaseUrl(null),
        .token = .{ .value = "fx-test-token" },
        .trace = capture.trace(),
        .team_id = "team_1",
        .project_id = "prj_1",
        .name = "fx-repo",
        .repo_root = "/vercel/sandbox/repo",
        .state_dir = &state_dir,
    };
    var manifest = try testManifest(arena, &.{});
    manifest.spent_stamps = &.{"fx-stamp-00000000000000aa"};
    var counts: Counts = .{};
    var overflow: std.ArrayList([]const u8) = .empty;
    var baselines: std.array_hash_map.String(BaselineMap) = .empty;
    var notes: Notes = .{ .alloc = arena };
    var apply = testApply(arena, tmp.dir, &manifest, &counts, &overflow, &baselines, &notes, &.{}, max_files_per_run);
    apply.ctx = &context;
    const spent = [_][]const u8{ "fx-stamp-0123456789abcdef", "fx-stamp-00000000000000bb" };
    try testing.expect(commitRun(&context, &apply, &manifest, &.{}, &.{}, &notes, &spent) == null);

    const back = try sandbox.readManifest(&context);
    try testing.expectEqual(@as(usize, 2), back.spent_stamps.len);
    try testing.expectEqualStrings("fx-stamp-0123456789abcdef", back.spent_stamps[0]);
    try testing.expectEqualStrings("fx-stamp-00000000000000bb", back.spent_stamps[1]);
}

test "the bring-back script takes the spent stamps after the entry count, so it deletes them first (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var baselines: std.array_hash_map.String(BaselineMap) = .empty;
    var args: std.ArrayList([]const u8) = .empty;
    const input: Input = .{ .run_id = "0123456789abcdef", .roots = &.{}, .own_baseline = &.{} };
    const spent = [_][]const u8{"fx-stamp-00000000000000aa"};
    try buildArgs(arena, &baselines, &args, "fx-stamp-0123456789abcdef", input, &.{}, &spent);

    try testing.expectEqual(@as(usize, 4), args.items.len);
    try testing.expectEqualStrings("fx-stamp-0123456789abcdef", args.items[0]);
    try testing.expectEqualStrings("0", args.items[1]);
    try testing.expectEqualStrings("1", args.items[2]);
    try testing.expectEqualStrings("fx-stamp-00000000000000aa", args.items[3]);
}

test "an untracked file the bring-back wrote is written again only while the Mac still matches it (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();

    try tmp.dir.writeFile(io, .{ .sub_path = "made.txt", .data = "v1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "edited.txt", .data = "user" });
    const v1_sha = shaHex("v1");
    var manifest = try testManifest(arena, &.{});
    try manifest.brought.put(arena, "made.txt", .{ .size = 2, .mtime_ns = 0, .sha256 = &v1_sha });
    try manifest.brought.put(arena, "edited.txt", .{ .size = 2, .mtime_ns = 0, .sha256 = &v1_sha });

    const archive = try buildArchive(arena, &.{
        .{ .name = "made.txt", .data = "v2" },
        .{ .name = "edited.txt", .data = "v2" },
    });
    var counts: Counts = .{};
    var overflow: std.ArrayList([]const u8) = .empty;
    var baselines: std.array_hash_map.String(BaselineMap) = .empty;
    var notes: Notes = .{ .alloc = arena };
    var apply = testApply(arena, tmp.dir, &manifest, &counts, &overflow, &baselines, &notes, &.{}, max_files_per_run);
    var input: std.Io.Reader = .fixed(archive);
    try applyArchive(&input, &apply);

    try testing.expectEqualStrings("v2", try readBack(arena, tmp.dir, "made.txt"));
    try testing.expectEqualStrings("user", try readBack(arena, tmp.dir, "edited.txt"));
    try testing.expectEqual(@as(usize, 1), counts.written);
    try testing.expectEqual(@as(usize, 1), counts.kept);
}

test "a root file is written when the Mac file is unchanged since run start, and kept when it changed (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();

    try tmp.dir.createDir(io, "out", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "out/same", .data = "old" });
    try tmp.dir.writeFile(io, .{ .sub_path = "out/changed", .data = "old" });
    const same_stat = try tmp.dir.statFile(io, "out/same", .{ .follow_symlinks = false });
    const same_mtime = sync.mtimeNs(same_stat);
    var baseline_files = [_]sandbox.BringBackFile{
        .{ .rel = "out/same", .size = same_stat.size, .mtime_ns = same_mtime },
        .{ .rel = "out/changed", .size = 3, .mtime_ns = 1 },
    };
    var baselines: std.array_hash_map.String(BaselineMap) = .empty;
    try baselines.put(arena, "fx-stamp-0123456789abcdef", try baselineMapOf(arena, &baseline_files));
    var notes: Notes = .{ .alloc = arena, .root = "fx-stamp-0123456789abcdef" };

    const archive = try buildArchive(arena, &.{
        .{ .name = "out/same", .data = "new" },
        .{ .name = "out/changed", .data = "new" },
    });
    var manifest = try testManifest(arena, &.{});
    var counts: Counts = .{};
    var overflow: std.ArrayList([]const u8) = .empty;
    const roots = [_][]const u8{"out"};
    var apply = testApply(arena, tmp.dir, &manifest, &counts, &overflow, &baselines, &notes, &roots, max_files_per_run);
    var input: std.Io.Reader = .fixed(archive);
    try applyArchive(&input, &apply);

    try testing.expectEqualStrings("new", try readBack(arena, tmp.dir, "out/same"));
    try testing.expectEqualStrings("old", try readBack(arena, tmp.dir, "out/changed"));
    try testing.expectEqual(@as(usize, 1), counts.written);
    try testing.expectEqual(@as(usize, 1), counts.kept);
}

test "the caps leave the rest pending for the next run (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const archive = try buildArchive(arena, &.{
        .{ .name = "one.txt", .data = "1" },
        .{ .name = "two.txt", .data = "2" },
        .{ .name = "three.txt", .data = "3" },
    });
    var manifest = try testManifest(arena, &.{});
    var counts: Counts = .{};
    var overflow: std.ArrayList([]const u8) = .empty;
    var baselines: std.array_hash_map.String(BaselineMap) = .empty;
    var notes: Notes = .{ .alloc = arena };
    var apply = testApply(arena, tmp.dir, &manifest, &counts, &overflow, &baselines, &notes, &.{}, 1);
    var input: std.Io.Reader = .fixed(archive);
    try applyArchive(&input, &apply);

    try testing.expectEqual(@as(usize, 1), counts.written);
    try testing.expectEqual(@as(usize, 2), counts.over_cap);
    try testing.expectEqualStrings("two.txt", overflow.items[0]);
    try testing.expectEqualStrings("three.txt", overflow.items[1]);
}

test "a written file the manifest tracks updates its record and gets no brought entry (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();

    try tmp.dir.writeFile(io, .{ .sub_path = "tracked.txt", .data = "old" });
    const old_sha = shaHex("old");
    var manifest = try testManifest(arena, &.{.{ .path = "tracked.txt", .sha = &old_sha }});
    const archive = try buildArchive(arena, &.{.{ .name = "tracked.txt", .data = "new" }});
    var counts: Counts = .{};
    var overflow: std.ArrayList([]const u8) = .empty;
    var baselines: std.array_hash_map.String(BaselineMap) = .empty;
    var notes: Notes = .{ .alloc = arena };
    var apply = testApply(arena, tmp.dir, &manifest, &counts, &overflow, &baselines, &notes, &.{}, max_files_per_run);
    var input: std.Io.Reader = .fixed(archive);
    try applyArchive(&input, &apply);

    try testing.expectEqualStrings("new", try readBack(arena, tmp.dir, "tracked.txt"));
    try testing.expectEqual(@as(usize, 0), manifest.brought.count());
    const new_sha = shaHex("new");
    const record = manifest.files.get("tracked.txt").?;
    try testing.expectEqualStrings(&new_sha, record.sha256);
}

test "brought keeps the newest 20,000 records and drops the oldest first (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var map: sandbox.FileMap = .empty;
    const sha = shaHex("x");
    for (0..sandbox.max_brought_entries + 3) |index| {
        const rel = try arena.print("out/{d}", .{index});
        try map.put(arena, rel, .{ .size = 1, .mtime_ns = 1, .sha256 = &sha });
    }
    sandbox.trimBrought(&map);
    try testing.expectEqual(sandbox.max_brought_entries, map.count());
    try testing.expectEqualStrings("out/3", map.keys()[0]);
}

fn alwaysBusy(context: ?*anyopaque, file: std.Io.File) anyerror!bool {
    _ = context;
    _ = file;
    return false;
}

test "a lock timeout ends the bring-back with its busy detail, and the pending record keeps the baseline (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var context: sandbox.Context = .{
        .alloc = arena,
        .cancel = &cancel,
        .base = transport.resolveBaseUrl(null),
        .token = .{ .value = "fx-test-token" },
        .trace = capture.trace(),
        .team_id = "team_1",
        .project_id = "prj_1",
        .name = "fx-repo",
        .repo_root = "/vercel/sandbox/repo",
        .state_dir = &state_dir,
    };
    const baseline = [_]sandbox.BringBackFile{.{ .rel = "out/app", .size = 7, .mtime_ns = 9 }};
    const result = run(arena, &context, "sess_1", .{
        .run_id = "0123456789abcdef",
        .roots = &.{"out"},
        .own_baseline = &baseline,
        .lock_wait_ms = 20,
        .lock_ops = .{ .try_lock = alwaysBusy },
    });
    try testing.expectEqualStrings(sync.busy_detail, result.failed);
    try notePending(&context, "0123456789abcdef", 42, &baseline, .{ .exited = 0 }, true);
    const pending = try sandbox.readPending(arena, &context);
    try testing.expectEqual(@as(usize, 1), pending.len);
    try testing.expectEqualStrings("out/app", pending[0].baseline.?[0].rel);
}
