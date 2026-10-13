//! Lazy compaction of a session's conversation event log on writable resume.
//!
//! Logs written before diff snapshots spilled to the result store inline full
//! previous/after file contents inside `committed_file_presentation` tool_result
//! frames, which dominates log bytes on edit-heavy sessions. This module
//! rewrites such a log once, moving each oversized inline snapshot into the
//! same content-addressed result-store artifacts used by new commits, leaving a
//! `content_handle` reference behind. The rewrite is invisible: it runs inside
//! the writer lock before the open scan, and every later resume replays the
//! compact log (or its history cache) instead of the fat original.
//!
//! Contract:
//! * The log is only replaced by an atomic rename after the compacted tmp file
//!   has been fully written, synced, and re-validated frame by frame. A crash
//!   before the rename leaves the original log untouched; a crash after leaves
//!   the complete compacted log. Orphaned tmp or artifact files are harmless.
//! * Frames are copied verbatim from the original log; only frames whose
//!   presentation spills are re-encoded, so unmodified history keeps its exact
//!   bytes. A torn tail (crash mid-write) is dropped the same way the open
//!   scan would truncate it, so compaction never preserves a partial frame.
//! * Pre-rename failure never blocks resume. Mid-pass errors delete the tmp
//!   file and resume proceeds with the original log; OOM propagates. Failure
//!   to sync the directory after rename is persistence-uncertain and blocks a
//!   writable resume rather than appending to a possibly non-durable inode.
//! * A freshness marker records the compacted log's length and tail CRC. A log
//!   unchanged since the last pass is skipped without being parsed; a log that
//!   grew is re-scanned, which is cheap because new commits already write
//!   handle-based frames.
//! * Read-only loads never compact; the writer lock in `resumeForWrite` is the
//!   single entry point.
//!
//! Temporary compatibility machinery: remove this module, its marker sidecar,
//! wiring, and migration tests once the supported upgrade window excludes all
//! builds that wrote inline diff snapshots and format-convergence evidence
//! shows no remaining legacy payloads in active session stores.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const result_store = @import("result_store.zig");
const session_event = @import("session_event.zig");
const session_replay = @import("session_replay.zig");
const types = @import("../shared/types.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

const events_file = "events.jsonl";
const tmp_file = "events.jsonl.compact-tmp";
const pending_file = "events-compaction.pending";
const marker_file = "events-compaction.marker";
const legacy_tmp_files = [_][]const u8{ "events.compact-tmp", "events.jsonl.tmp" };

/// Inline previous/after snapshot bytes above this budget spill to the result
/// store. Mirrors the commit-time budget in session_log.
const inline_budget_bytes: usize = result_store.preview_bytes;
/// A complete log no larger than the inline budget cannot contain a spillable
/// presentation. Every larger log is scanned once so all legacy shapes can
/// converge, including small sessions with one oversized edit.
const min_log_bytes: u64 = inline_budget_bytes + 1;
const marker_max_bytes: usize = 128;
const copy_buffer_bytes: usize = 64 * 1024;
/// The freshness pin hashes this many bytes from the log's tail. Append-only
/// growth changes the length; tail rewrites change the hash. Same-scope
/// middle rewrites stay invisible, the same blind spot the history cache's
/// watermark deliberately accepts.
const tail_pin_bytes: u64 = 64 * 1024;

const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);

pub const Outcome = enum {
    compacted,
    deferred,
    skipped_small_log,
    skipped_fresh,
    no_inline_payloads,
};

pub const TestControls = struct {
    context: ?*anyopaque = null,
    before_rename_fn: ?*const fn (?*anyopaque) anyerror!void = null,
    before_spill_fn: ?*const fn (?*anyopaque, usize) anyerror!void = null,
    sync_dir_fn: ?*const fn (?*anyopaque, std.Io.Dir) anyerror!void = null,

    fn beforeRename(self: TestControls) !void {
        if (self.before_rename_fn) |callback| try callback(self.context);
    }

    fn beforeSpill(self: TestControls, spill_count: usize) !void {
        if (self.before_spill_fn) |callback| try callback(self.context, spill_count);
    }

    fn syncDir(self: TestControls, dir: std.Io.Dir) !void {
        if (self.sync_dir_fn) |callback| return callback(self.context, dir);
        return io_mod.syncVerifiedDir(dir);
    }
};

pub const Options = struct {
    force: bool = false,
    test_controls: TestControls = .{},
};

const Marker = struct {
    log_len: u64,
    tail_crc: u32,
};

const Stats = struct {
    frames_seen: usize = 0,
    frames_reencoded: usize = 0,
    spill_failures: usize = 0,
    intentionally_inline: usize = 0,
    spilled_bytes: usize = 0,
    input_bytes: u64 = 0,
    output_bytes: u64 = 0,
};

const RewriteResult = struct {
    changed: bool,
    unresolved: bool,
};

const LogLine = struct {
    bytes: []u8,
    start_offset: u64,
    next_offset: u64,
};

const SpillCandidate = struct {
    result: session_event.ConversationToolResult,
    presentation: types.CommittedFilePresentation,
    inline_bytes: usize,
};

/// Compacts the session's event log when it holds inline diff snapshots.
/// Runs under the session writer lock during `resumeForWrite`, before the
/// open scan. Pre-rename non-OOM errors degrade to "keep the original log" at
/// the call site. Post-rename sync failure reports persistence uncertainty.
pub fn compactIfNeeded(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    options: Options,
) !Outcome {
    try cleanupStaleArtifacts(dir, session_id);

    const zio = io_mod.getIo();
    var event_file = openRegularFile(dir, events_file, .read_only) catch |err| switch (err) {
        error.FileNotFound => return .no_inline_payloads,
        else => return err,
    };
    defer event_file.close(zio);
    const log_len = try event_file.length(zio);
    if (log_len < min_log_bytes and !options.force) {
        debug_trace.logf("session", "event=session_log_compaction_skipped id={s} reason=small_log bytes={d}", .{ session_id, log_len });
        return .skipped_small_log;
    }

    const tail_crc = try tailPin(alloc, dir, log_len);
    if (!options.force) {
        if (try readMarker(dir)) |marker| {
            if (marker.log_len == log_len and marker.tail_crc == tail_crc) {
                debug_trace.logf("session", "event=session_log_compaction_skipped id={s} reason=fresh_marker bytes={d}", .{ session_id, log_len });
                return .skipped_fresh;
            }
        }
    }

    var stats: Stats = .{};
    const rewrite = try rewriteLog(
        alloc,
        dir,
        session_id,
        event_file,
        log_len,
        options.test_controls,
        &stats,
    );
    var temp_pending = rewrite.changed;
    defer if (temp_pending) deleteIfPresent(dir, tmp_file);
    if (!rewrite.changed) {
        if (rewrite.unresolved) {
            debug_trace.logf("session", "event=session_log_compaction_deferred id={s} spill_failures={d}; retrying on next resume", .{ session_id, stats.spill_failures });
            return .deferred;
        }
        // Nothing spilled: pin the current log so later resumes skip the
        // scan until the log changes.
        try writeMarkerBestEffort(alloc, dir, session_id, .{ .log_len = log_len, .tail_crc = tail_crc });
        debug_trace.logf(
            "session",
            "event=session_log_compaction_skipped id={s} reason={s} frames={d} intentionally_inline={d}",
            .{
                session_id,
                if (stats.intentionally_inline > 0) "no_spillable_payloads" else "no_inline_payloads",
                stats.frames_seen,
                stats.intentionally_inline,
            },
        );
        return .no_inline_payloads;
    }

    try validateCompactedLog(alloc, dir, session_id);

    const renamed_len = stats.output_bytes;
    try options.test_controls.beforeRename();
    try renameCompactedLog(alloc, dir, session_id, options.test_controls);
    temp_pending = false;
    if (!rewrite.unresolved) {
        try writeMarkerBestEffort(
            alloc,
            dir,
            session_id,
            .{ .log_len = renamed_len, .tail_crc = try tailPin(alloc, dir, renamed_len) },
        );
    }
    debug_trace.logf(
        "session",
        "event=session_log_compacted id={s} frames={d} reencoded={d} spill_failures={d} intentionally_inline={d} spilled_bytes={d} before_bytes={d} after_bytes={d}",
        .{ session_id, stats.frames_seen, stats.frames_reencoded, stats.spill_failures, stats.intentionally_inline, stats.spilled_bytes, stats.input_bytes, stats.output_bytes },
    );
    return .compacted;
}

/// Rewrites the log into tmp_file, spilling oversized inline snapshots.
/// Returns false when no frame spilled; the tmp file is removed in that case
/// so a clean log is never swapped for an identical copy.
fn rewriteLog(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    event_file: std.Io.File,
    log_len: u64,
    test_controls: TestControls,
    stats: *Stats,
) !RewriteResult {
    const zio = io_mod.getIo();
    var tmp = try createPrivateTempFile(dir);
    var tmp_open = true;
    var keep_tmp = false;
    defer {
        if (tmp_open) tmp.close(zio);
        if (!keep_tmp) deleteIfPresent(dir, tmp_file);
    }

    var result_dir: ?[]const u8 = null;
    defer if (result_dir) |path| alloc.free(path);
    var spill_path_failed = false;
    var unresolved = false;

    var reader_buffer: [copy_buffer_bytes]u8 = undefined;
    var reader = event_file.reader(zio, &reader_buffer);
    var copy_buffer: [copy_buffer_bytes]u8 = undefined;
    var pending_offset: u64 = 0;
    var complete_end: u64 = 0;
    var tmp_len: u64 = 0;
    var spill_attempts: usize = 0;
    var any_spill = false;

    while (true) {
        const line = readLogLine(alloc, &reader, log_len) catch |err| switch (err) {
            // A torn tail is the open scan's truncation case: stop copying at
            // the last complete frame and let the tmp end there.
            error.TruncatedEventFrame => break,
            else => return err,
        } orelse break;
        defer alloc.free(line.bytes);
        stats.frames_seen += 1;

        var parsed = session_event.decodeConversationFrame(alloc, line.bytes) catch |err| {
            debug_trace.logf("session", "event=session_log_compaction_aborted id={s} err={s}; keeping original log", .{ session_id, @errorName(err) });
            return err;
        };
        defer parsed.deinit();
        // The frame boundary only advances past fully decoded frames; the tmp
        // copy range never includes a torn tail.
        complete_end = line.next_offset;

        const spill = spillablePresentation(parsed.value.event) orelse continue;
        if (spill_path_failed) {
            unresolved = true;
            stats.spill_failures += 1;
            continue;
        }
        if (result_dir == null) {
            const base = io_mod.dirRealpathAlloc(alloc, dir.dir, ".") catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    debug_trace.logf("session", "event=session_log_compaction_spill_unavailable id={s} err={s}; keeping presentations inline", .{ session_id, @errorName(err) });
                    spill_path_failed = true;
                    unresolved = true;
                    stats.spill_failures += 1;
                    continue;
                },
            };
            defer alloc.free(base);
            result_dir = std.Io.Dir.path.join(alloc, &.{ base, "tool-results" }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        spill_attempts += 1;
        test_controls.beforeSpill(spill_attempts) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                debug_trace.logf("session", "event=diff_content_spill_failed call_id={s} err={s}; keeping presentation inline", .{ spill.result.call_id, @errorName(err) });
                unresolved = true;
                stats.spill_failures += 1;
                continue;
            },
        };
        const handle = result_store.storeDiffContent(
            alloc,
            result_dir.?,
            spill.result.call_id,
            spill.presentation.previous_content,
            spill.presentation.after_content,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DiffContentTooLarge => {
                // A valid event frame can exceed the stricter artifact-pack
                // limit. It must remain inline permanently, but it must not
                // force every future resume to retry the impossible spill.
                debug_trace.logf("session", "event=diff_content_spill_skipped call_id={s} reason=artifact_too_large inline_bytes={d}", .{ spill.result.call_id, spill.inline_bytes });
                stats.intentionally_inline += 1;
                continue;
            },
            else => {
                // Store hiccups mirror the commit-time rule: keep this frame
                // inline and continue with the rest of the log. Do not publish
                // a freshness marker: the next resume must retry this spill.
                debug_trace.logf("session", "event=diff_content_spill_failed call_id={s} err={s}; keeping presentation inline", .{ spill.result.call_id, @errorName(err) });
                unresolved = true;
                stats.spill_failures += 1;
                continue;
            },
        };
        defer alloc.free(handle);

        try copyLogRange(event_file, &tmp, &copy_buffer, pending_offset, line.start_offset);
        tmp_len += line.start_offset - pending_offset;
        const frame = try encodeSpilledFrame(alloc, parsed.value, spill, handle);
        defer alloc.free(frame);
        try tmp.writeStreamingAll(zio, frame);
        tmp_len += frame.len;
        stats.frames_reencoded += 1;
        stats.spilled_bytes += spill.inline_bytes;
        pending_offset = line.next_offset;
        any_spill = true;
    }

    if (!any_spill) return .{ .changed = false, .unresolved = unresolved };
    try copyLogRange(event_file, &tmp, &copy_buffer, pending_offset, complete_end);
    tmp_len += complete_end - pending_offset;
    stats.input_bytes = log_len;
    stats.output_bytes = tmp_len;
    try tmp.sync(zio);
    tmp.close(zio);
    tmp_open = false;
    keep_tmp = true;
    return .{ .changed = true, .unresolved = unresolved };
}

fn spillablePresentation(event: session_event.ConversationEvent) ?SpillCandidate {
    const result = switch (event) {
        .tool_result => |value| value,
        else => return null,
    };
    const presentation = result.committed_file_presentation orelse return null;
    if (presentation.content_handle != null) return null;
    const previous_bytes = if (presentation.previous_content) |content| content.len else 0;
    const after_bytes = if (presentation.after_content) |content| content.len else 0;
    const inline_bytes = previous_bytes +| after_bytes;
    if (inline_bytes <= inline_budget_bytes) return null;
    return .{
        .result = result,
        .presentation = presentation,
        .inline_bytes = inline_bytes,
    };
}

fn encodeSpilledFrame(
    alloc: Allocator,
    envelope: session_event.ConversationEnvelope,
    spill: SpillCandidate,
    handle: []const u8,
) ![]u8 {
    var projected_presentation = spill.presentation;
    projected_presentation.previous_content = null;
    projected_presentation.after_content = null;
    projected_presentation.content_handle = handle;
    var projected_result = spill.result;
    projected_result.committed_file_presentation = projected_presentation;
    return session_event.encodeConversationFrame(alloc, .{
        .seq = envelope.seq,
        .timestamp_ms = envelope.timestamp_ms,
        .event = .{ .tool_result = projected_result },
    });
}

/// Adds the starting offset needed by the rewrite to the canonical bounded
/// session-line reader used by discovery and replay.
fn readLogLine(alloc: Allocator, reader: *std.Io.File.Reader, max_end: u64) !?LogLine {
    const start_offset = reader.logicalPos();
    const read = (try session_replay.readBufferedLine(alloc, reader, max_end, null)) orelse
        return null;
    return .{
        .bytes = read.bytes,
        .start_offset = start_offset,
        .next_offset = read.next_offset,
    };
}

/// Streams `source[start..end)` into `dest` in bounded chunks via positional
/// reads, leaving the streaming reader's state untouched.
fn copyLogRange(
    source: std.Io.File,
    dest: *std.Io.File,
    buffer: *[copy_buffer_bytes]u8,
    start: u64,
    end: u64,
) !void {
    const zio = io_mod.getIo();
    var offset = start;
    while (offset < end) {
        const want: usize = @intCast(@min(buffer.len, end - offset));
        const n = try source.readPositional(zio, &.{buffer[0..want]}, offset);
        if (n == 0) return error.UnexpectedEndOfFile;
        try dest.writeStreamingAll(zio, buffer[0..n]);
        offset += n;
    }
}

/// Re-parses the tmp log and replays the open scan's transition validation,
/// proving the rewrite preserved every frame before it can replace the
/// original. A torn tail is accepted: the tmp ends at the last complete frame
/// by construction, but a partial line here would mean the rewrite itself was
/// interrupted, so any truncation error fails validation.
fn validateCompactedLog(alloc: Allocator, dir: *io_mod.VerifiedDir, session_id: []const u8) !void {
    const zio = io_mod.getIo();
    var file = try openRegularFile(dir, tmp_file, .read_only);
    defer file.close(zio);
    const len = try file.length(zio);
    var reader_buffer: [copy_buffer_bytes]u8 = undefined;
    var reader = file.reader(zio, &reader_buffer);
    var last_seq: u64 = 0;
    var latest_checkpoint_coverage: u64 = 0;
    var turn_open = false;
    var pending_tool_calls: std.ArrayList(session_event.PendingToolCall) = .empty;
    defer {
        for (pending_tool_calls.items) |pending| {
            alloc.free(@constCast(pending.call_id));
            alloc.free(@constCast(pending.tool_name));
        }
        pending_tool_calls.deinit(alloc);
    }
    var frames: usize = 0;
    while (true) {
        const line = (try readLogLine(alloc, &reader, len)) orelse break;
        defer alloc.free(line.bytes);
        var parsed = try session_event.decodeConversationFrame(alloc, line.bytes);
        defer parsed.deinit();
        const envelope = parsed.value;
        try session_event.validateConversationTransition(.{
            .last_seq = last_seq,
            .latest_checkpoint_coverage = latest_checkpoint_coverage,
            .pending_tool_calls = pending_tool_calls.items,
        }, envelope);
        switch (envelope.event) {
            .user => {
                if (turn_open) return error.InvalidConversationFrame;
                turn_open = true;
            },
            .turn_completed, .interrupted => {
                if (!turn_open) return error.InvalidConversationFrame;
                turn_open = false;
            },
            .assistant, .tool_call, .tool_result, .steering => {
                if (!turn_open) return error.InvalidConversationFrame;
            },
            .context_checkpoint => {
                latest_checkpoint_coverage = envelope.event.context_checkpoint.covers_through_seq;
            },
        }
        try trackPendingToolCall(alloc, &pending_tool_calls, envelope);
        last_seq = envelope.seq;
        frames += 1;
    }
    debug_trace.logf("session", "event=session_log_compaction_verified id={s} frames={d} bytes={d}", .{ session_id, frames, len });
}

/// Mirrors ConversationWriter's pending-call bookkeeping so validation sees
/// the same tool-call pairing the open scan enforces.
fn trackPendingToolCall(
    alloc: Allocator,
    pending: *std.ArrayList(session_event.PendingToolCall),
    envelope: session_event.ConversationEnvelope,
) !void {
    switch (envelope.event) {
        .tool_call => |call| {
            const call_id = try alloc.dupe(u8, call.call_id);
            errdefer alloc.free(call_id);
            const tool_name = try alloc.dupe(u8, call.tool_name);
            errdefer alloc.free(tool_name);
            try pending.append(alloc, .{ .call_id = call_id, .tool_name = tool_name, .seq = envelope.seq });
        },
        .tool_result => |result| {
            for (pending.items, 0..) |item, index| {
                if (std.mem.eql(u8, item.call_id, result.call_id)) {
                    const removed = pending.orderedRemove(index);
                    alloc.free(@constCast(removed.call_id));
                    alloc.free(@constCast(removed.tool_name));
                    break;
                }
            }
        },
        .interrupted => {
            for (pending.items) |item| {
                alloc.free(@constCast(item.call_id));
                alloc.free(@constCast(item.tool_name));
            }
            pending.clearRetainingCapacity();
        },
        else => {},
    }
}

fn openRegularFile(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) !std.Io.File {
    return io_mod.openExistingRegularFile(dir.dir, name, mode);
}

fn createPrivateTempFile(dir: *io_mod.VerifiedDir) !std.Io.File {
    const zio = io_mod.getIo();
    var file = dir.dir.createFile(zio, tmp_file, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = private_file_permissions,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.IsDir, error.NotDir, error.SymLinkLoop, error.PathAlreadyExists => return error.DurablePathUnsafe,
        else => return err,
    };
    errdefer file.close(zio);
    file.setPermissions(zio, private_file_permissions) catch
        return error.PrivateStatePermissionsUnsupported;
    try io_mod.verifyOpenedRegularFile(try file.stat(zio), .read_write);
    return file;
}

fn renameCompactedLog(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    test_controls: TestControls,
) !void {
    const zio = io_mod.getIo();
    var temp = try openRegularFile(dir, tmp_file, .read_only);
    temp.close(zio);
    var current = try openRegularFile(dir, events_file, .read_only);
    current.close(zio);

    // The durable pending fence survives a post-rename sync failure. A later
    // writer must resolve it before opening events.jsonl, making whichever
    // atomic rename state is visible durable before new events can append.
    try io_mod.durableReplaceVerified(alloc, dir, pending_file, "1\n");
    try dir.dir.rename(tmp_file, dir.dir, events_file, zio);
    test_controls.syncDir(dir.dir) catch |err| {
        debug_trace.logf("session", "event=session_log_compaction_durability_uncertain id={s} err={s}", .{ session_id, @errorName(err) });
        return error.SessionCompactionPersistenceUncertain;
    };
    clearPendingFenceBestEffort(dir, session_id);
}

/// CRC32 over the log's trailing bytes; combined with the length it pins the
/// exact log state a marker refers to, matching the history cache watermark's
/// documented blind spot for in-place middle rewrites.
fn tailPin(alloc: Allocator, dir: *io_mod.VerifiedDir, log_len: u64) !u32 {
    if (log_len == 0) return 0;
    const zio = io_mod.getIo();
    var file = try openRegularFile(dir, events_file, .read_only);
    defer file.close(zio);
    const tail_bytes: u64 = @min(log_len, tail_pin_bytes);
    const start = log_len - tail_bytes;
    const buffer = try alloc.alloc(u8, @intCast(tail_bytes));
    defer alloc.free(buffer);
    var offset: u64 = start;
    while (offset < log_len) {
        const n = try file.readPositional(zio, &.{buffer[@intCast(offset - start)..]}, offset);
        if (n == 0) return error.UnexpectedEndOfFile;
        offset += n;
    }
    return std.hash.Crc32.hash(buffer);
}

fn readMarker(dir: *io_mod.VerifiedDir) !?Marker {
    const zio = io_mod.getIo();
    var file = openRegularFile(dir, marker_file, .read_only) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(zio);
    var buffer: [marker_max_bytes]u8 = undefined;
    const n = try file.readPositional(zio, &.{&buffer}, 0);
    var iterator = std.mem.tokenizeScalar(u8, buffer[0..n], '\n');
    const len_line = iterator.next() orelse return null;
    const crc_line = iterator.next() orelse return null;
    const log_len = std.fmt.parseInt(u64, std.mem.trim(u8, len_line, " \r"), 10) catch return null;
    const tail_crc = std.fmt.parseInt(u32, std.mem.trim(u8, crc_line, " \r"), 10) catch return null;
    return .{ .log_len = log_len, .tail_crc = tail_crc };
}

fn writeMarkerBestEffort(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    marker: Marker,
) !void {
    const text = try alloc.print("{d}\n{d}\n", .{ marker.log_len, marker.tail_crc });
    defer alloc.free(text);
    io_mod.durableReplaceVerified(alloc, dir, marker_file, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => debug_trace.logf("session", "event=session_log_compaction_marker_unavailable id={s} err={s}; future resume will rescan", .{ session_id, @errorName(err) }),
    };
}

fn deleteRegularIfPresent(dir: *io_mod.VerifiedDir, name: []const u8) !bool {
    const stat = dir.dir.statFile(io_mod.getIo(), name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.NotDir, error.SymLinkLoop => return error.DurablePathUnsafe,
        else => return err,
    };
    if (stat.kind != .file or stat.nlink != 1) return error.DurablePathUnsafe;
    try dir.dir.deleteFile(io_mod.getIo(), name);
    return true;
}

fn deleteIfPresent(dir: *io_mod.VerifiedDir, name: []const u8) void {
    _ = deleteRegularIfPresent(dir, name) catch |err| {
        debug_trace.logf("session", "session compaction cleanup failed name={s} err={s}", .{ name, @errorName(err) });
    };
}

fn clearPendingFenceBestEffort(dir: *io_mod.VerifiedDir, session_id: []const u8) void {
    const removed = deleteRegularIfPresent(dir, pending_file) catch |err| {
        debug_trace.logf("session", "event=session_log_compaction_fence_retained id={s} err={s}", .{ session_id, @errorName(err) });
        return;
    };
    if (!removed) return;
    io_mod.syncVerifiedDir(dir.dir) catch |err| {
        debug_trace.logf("session", "event=session_log_compaction_fence_cleanup_uncertain id={s} err={s}", .{ session_id, @errorName(err) });
    };
}

fn recoverPendingReplacement(dir: *io_mod.VerifiedDir, session_id: []const u8) !void {
    const stat = dir.dir.statFile(io_mod.getIo(), pending_file, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            debug_trace.logf("session", "event=session_log_compaction_recovery_uncertain id={s} err={s}", .{ session_id, @errorName(err) });
            return error.SessionCompactionPersistenceUncertain;
        },
    };
    if (stat.kind != .file or stat.nlink != 1) {
        debug_trace.logf("session", "event=session_log_compaction_recovery_uncertain id={s} err=unsafe_pending_fence", .{session_id});
        return error.SessionCompactionPersistenceUncertain;
    }

    // First make the currently visible atomic-rename state durable. Only then
    // may the fence and any pre-rename temp be removed.
    io_mod.syncVerifiedDir(dir.dir) catch |err| {
        debug_trace.logf("session", "event=session_log_compaction_recovery_uncertain id={s} err={s}", .{ session_id, @errorName(err) });
        return error.SessionCompactionPersistenceUncertain;
    };
    _ = deleteRegularIfPresent(dir, tmp_file) catch
        return error.SessionCompactionPersistenceUncertain;
    _ = deleteRegularIfPresent(dir, pending_file) catch
        return error.SessionCompactionPersistenceUncertain;
    io_mod.syncVerifiedDir(dir.dir) catch |err| {
        debug_trace.logf("session", "event=session_log_compaction_recovery_uncertain id={s} err={s}", .{ session_id, @errorName(err) });
        return error.SessionCompactionPersistenceUncertain;
    };
    debug_trace.logf("session", "event=session_log_compaction_recovered id={s}", .{session_id});
}

/// Resolves a post-rename uncertainty fence, then removes tmp files left by an
/// interrupted earlier pass (including names from superseded builds).
fn cleanupStaleArtifacts(dir: *io_mod.VerifiedDir, session_id: []const u8) !void {
    try recoverPendingReplacement(dir, session_id);
    var removed: usize = 0;
    if (try deleteRegularIfPresent(dir, tmp_file)) removed += 1;
    for (legacy_tmp_files) |name| {
        if (try deleteRegularIfPresent(dir, name)) removed += 1;
    }
    if (removed > 0) {
        debug_trace.logf("session", "event=session_log_compaction_cleanup id={s} stale_tmp_files={d}", .{ session_id, removed });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_session_id = "0123456789abcdef0123456789abcdef";

fn openTestDir(tmp: *std.testing.TmpDir) !io_mod.VerifiedDir {
    return .{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{
        .iterate = true,
        .follow_symlinks = false,
    }) };
}

fn failBeforeRename(_: ?*anyopaque) !void {
    return error.TestBeforeRename;
}

fn failDirectorySync(_: ?*anyopaque, _: std.Io.Dir) !void {
    return error.TestDirectorySync;
}

fn failSecondSpill(_: ?*anyopaque, spill_count: usize) !void {
    if (spill_count == 2) return error.TestSpillUnavailable;
}

fn appendFixtureFrame(
    alloc: Allocator,
    file: *std.Io.File,
    seq: u64,
    event: session_event.ConversationEvent,
) !void {
    const frame = try session_event.encodeConversationFrame(alloc, .{
        .seq = seq,
        .timestamp_ms = @intCast(seq),
        .event = event,
    });
    defer alloc.free(frame);
    try file.writeStreamingAll(std.testing.io, frame);
}

fn fixtureFatPresentation(fat: []const u8) types.CommittedFilePresentation {
    return .{
        .path = "src/a.zig",
        .kind = .edited,
        .lines = &.{},
        .additions = 1,
        .deletions = 1,
        .truncated = false,
        .previous_content = fat,
        .after_content = fat,
    };
}

fn writeFatSessionLog(alloc: Allocator, dir: *io_mod.VerifiedDir, fat: []const u8) !void {
    var file = try dir.dir.createFile(std.testing.io, events_file, .{ .truncate = true });
    defer file.close(std.testing.io);
    try appendFixtureFrame(alloc, &file, 1, .{ .user = .{ .text = "seed" } });
    try appendFixtureFrame(alloc, &file, 2, .{ .tool_call = .{
        .call_id = "call-edit",
        .tool_name = "edit_file",
        .arguments_json = "{}",
    } });
    try appendFixtureFrame(alloc, &file, 3, .{ .tool_result = .{
        .call_id = "call-edit",
        .tool_name = "edit_file",
        .status = .success,
        .artifact_ref = "result.txt",
        .stored_bytes = 0,
        .completeness = .complete,
        .committed_file_presentation = fixtureFatPresentation(fat),
    } });
    // A second fat edit so the rewrite crosses multiple spills and the
    // verbatim ranges between them.
    try appendFixtureFrame(alloc, &file, 4, .{ .tool_call = .{
        .call_id = "call-edit-2",
        .tool_name = "edit_file",
        .arguments_json = "{}",
    } });
    try appendFixtureFrame(alloc, &file, 5, .{ .tool_result = .{
        .call_id = "call-edit-2",
        .tool_name = "edit_file",
        .status = .success,
        .artifact_ref = "result-2.txt",
        .stored_bytes = 0,
        .completeness = .complete,
        .committed_file_presentation = fixtureFatPresentation(fat),
    } });
    try appendFixtureFrame(alloc, &file, 6, .{ .assistant = .{ .text = "done" } });
    try appendFixtureFrame(alloc, &file, 7, .{ .turn_completed = .{} });
    try file.sync(std.testing.io);
}

fn writeMixedSizeSessionLog(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    unspillable: []const u8,
    spillable: []const u8,
) !void {
    var file = try dir.dir.createFile(std.testing.io, events_file, .{ .truncate = true });
    defer file.close(std.testing.io);
    try appendFixtureFrame(alloc, &file, 1, .{ .user = .{ .text = "seed" } });
    try appendFixtureFrame(alloc, &file, 2, .{ .tool_call = .{
        .call_id = "call-too-large",
        .tool_name = "edit_file",
        .arguments_json = "{}",
    } });
    try appendFixtureFrame(alloc, &file, 3, .{ .tool_result = .{
        .call_id = "call-too-large",
        .tool_name = "edit_file",
        .status = .success,
        .artifact_ref = "large.txt",
        .stored_bytes = 0,
        .completeness = .complete,
        .committed_file_presentation = fixtureFatPresentation(unspillable),
    } });
    try appendFixtureFrame(alloc, &file, 4, .{ .tool_call = .{
        .call_id = "call-spillable",
        .tool_name = "edit_file",
        .arguments_json = "{}",
    } });
    try appendFixtureFrame(alloc, &file, 5, .{ .tool_result = .{
        .call_id = "call-spillable",
        .tool_name = "edit_file",
        .status = .success,
        .artifact_ref = "small.txt",
        .stored_bytes = 0,
        .completeness = .complete,
        .committed_file_presentation = fixtureFatPresentation(spillable),
    } });
    try appendFixtureFrame(alloc, &file, 6, .{ .assistant = .{ .text = "done" } });
    try appendFixtureFrame(alloc, &file, 7, .{ .turn_completed = .{} });
    try file.sync(std.testing.io);
}

fn readLogText(alloc: Allocator, dir: *io_mod.VerifiedDir) ![]u8 {
    var file = try dir.dir.openFile(std.testing.io, events_file, .{ .mode = .read_only });
    defer file.close(std.testing.io);
    return io_mod.readFileToEnd(alloc, &file, 64 * 1024 * 1024);
}

fn lineAt(text: []const u8, target: usize) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        if (index == target) return line;
    }
    return null;
}

fn fixtureFatContent() []const u8 {
    // ~136 KB per copy: two copies push the fixture log past the 256 KB
    // log-size gate so tests exercise the real (unforced) entry condition.
    return text_utils.repeat("FIXTURE_DIFF_LINE_0123456789abcdef\n", 4000);
}

test "compaction spills inline snapshots and preserves every frame" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try openTestDir(&tmp);
    defer dir.close();

    const fat = fixtureFatContent();
    try writeFatSessionLog(alloc, &dir, fat);
    const before = try readLogText(alloc, &dir);
    defer alloc.free(before);
    try std.testing.expect(std.mem.find(u8, before, "\"content_handle\":\"") == null);

    const outcome = try compactIfNeeded(alloc, &dir, test_session_id, .{});
    try std.testing.expectEqual(Outcome.compacted, outcome);

    const after = try readLogText(alloc, &dir);
    defer alloc.free(after);
    try std.testing.expect(after.len < before.len / 2);
    try std.testing.expect(std.mem.find(u8, after, "FIXTURE_DIFF_LINE") == null);
    try std.testing.expect(std.mem.find(u8, after, "\"content_handle\":\"diff-") != null);
    for ([_]usize{ 0, 1, 3, 5, 6 }) |index| {
        try std.testing.expectEqualStrings(lineAt(before, index).?, lineAt(after, index).?);
    }

    // Every surviving frame decodes and replays in order; only the
    // tool_result frame changed shape, by moving snapshots behind a handle.
    var frames: usize = 0;
    var saw_spilled_result = false;
    var handle_buf: []const u8 = "";
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, after, "\n"), '\n');
    while (lines.next()) |line| {
        const frame_text = try alloc.print("{s}\n", .{line});
        defer alloc.free(frame_text);
        var parsed = try session_event.decodeConversationFrame(alloc, frame_text);
        defer parsed.deinit();
        frames += 1;
        if (parsed.value.event == .tool_result) {
            const presentation = parsed.value.event.tool_result.committed_file_presentation.?;
            try std.testing.expect(presentation.content_handle != null);
            try std.testing.expect(presentation.previous_content == null);
            try std.testing.expect(presentation.after_content == null);
            saw_spilled_result = true;
            if (handle_buf.len > 0) alloc.free(handle_buf);
            handle_buf = try alloc.dupe(u8, presentation.content_handle.?);
        }
    }
    defer alloc.free(handle_buf);
    try std.testing.expectEqual(@as(usize, 7), frames);
    try std.testing.expect(saw_spilled_result);

    // The marker pins the exact post-compaction log state: length and tail
    // CRC must match the file on disk, or the next resume re-scans needlessly.
    const marker = (try readMarker(&dir)).?;
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.testing.io, pending_file, .{}));
    try std.testing.expectEqual(@as(u64, after.len), marker.log_len);
    try std.testing.expectEqual(try tailPin(alloc, &dir, @intCast(after.len)), marker.tail_crc);

    // The spilled artifact holds the exact contents; read it through the same
    // digest-verifying path resume uses.
    const base = try io_mod.dirRealpathAlloc(alloc, dir.dir, ".");
    defer alloc.free(base);
    const result_dir = try std.Io.Dir.path.join(alloc, &.{ base, "tool-results" });
    defer alloc.free(result_dir);
    const artifact = try result_store.readByRange(alloc, result_dir, handle_buf, 0, result_store.diff_content_max_bytes);
    defer alloc.free(artifact);
    try std.testing.expect(std.mem.find(u8, artifact, "FIXTURE_DIFF_LINE") != null);

    // The compacted log is small, so the log-size gate makes a second pass a
    // no-op before the marker is even consulted.
    const second = try compactIfNeeded(alloc, &dir, test_session_id, .{});
    try std.testing.expectEqual(Outcome.skipped_small_log, second);
}

test "compaction migrates small logs that can hold spillable payloads" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try openTestDir(&tmp);
    defer dir.close();

    const small_spill = text_utils.repeat("SMALL_LEGACY_INLINE_PAYLOAD_0123456789abcdef\n", 128);
    try writeFatSessionLog(alloc, &dir, small_spill);
    const before = try readLogText(alloc, &dir);
    defer alloc.free(before);
    try std.testing.expect(before.len < 256 * 1024);
    try std.testing.expect(before.len > inline_budget_bytes);

    try std.testing.expectEqual(
        Outcome.compacted,
        try compactIfNeeded(alloc, &dir, test_session_id, .{}),
    );
    const after = try readLogText(alloc, &dir);
    defer alloc.free(after);
    try std.testing.expect(std.mem.find(u8, after, "SMALL_LEGACY_INLINE_PAYLOAD") == null);
    try std.testing.expect(std.mem.find(u8, after, "\"content_handle\":\"diff-") != null);
}

test "compaction keeps a clean log byte-identical and pins it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try openTestDir(&tmp);
    defer dir.close();

    var file = try dir.dir.createFile(std.testing.io, events_file, .{ .truncate = true });
    {
        defer file.close(std.testing.io);
        try appendFixtureFrame(alloc, &file, 1, .{ .user = .{ .text = "seed" } });
        try appendFixtureFrame(alloc, &file, 2, .{ .assistant = .{ .text = "done" } });
        try appendFixtureFrame(alloc, &file, 3, .{ .turn_completed = .{} });
    }
    const before = try readLogText(alloc, &dir);
    defer alloc.free(before);

    // Force past the log-size gate to prove the no-spill path leaves the file
    // untouched and records the marker.
    const outcome = try compactIfNeeded(alloc, &dir, test_session_id, .{ .force = true });
    try std.testing.expectEqual(Outcome.no_inline_payloads, outcome);
    const after = try readLogText(alloc, &dir);
    defer alloc.free(after);
    try std.testing.expectEqualStrings(before, after);
    const second = try compactIfNeeded(alloc, &dir, test_session_id, .{ .force = false });
    try std.testing.expectEqual(Outcome.skipped_small_log, second);
}

test "compaction keeps the original log when the store cannot spill" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try openTestDir(&tmp);
    defer dir.close();

    const fat = fixtureFatContent();
    try writeFatSessionLog(alloc, &dir, fat);
    const before = try readLogText(alloc, &dir);
    defer alloc.free(before);

    // A regular file named tool-results blocks artifact creation, forcing
    // every spill to fail; the pass must keep the original bytes.
    const blocker = try dir.dir.createFile(std.testing.io, "tool-results", .{});
    blocker.close(std.testing.io);

    const outcome = try compactIfNeeded(alloc, &dir, test_session_id, .{});
    try std.testing.expectEqual(Outcome.deferred, outcome);
    const after = try readLogText(alloc, &dir);
    defer alloc.free(after);
    try std.testing.expectEqualStrings(before, after);
    // No tmp file or freshness marker may survive a failed pass: once the
    // transient blocker disappears, the next resume must retry.
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.testing.io, tmp_file, .{}));
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.testing.io, marker_file, .{}));
    try dir.dir.deleteFile(std.testing.io, "tool-results");
    const retried = try compactIfNeeded(alloc, &dir, test_session_id, .{});
    try std.testing.expectEqual(Outcome.compacted, retried);
}

test "compaction publishes successful spills and retries only unresolved frames" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try openTestDir(&tmp);
    defer dir.close();

    try writeFatSessionLog(alloc, &dir, fixtureFatContent());
    const before = try readLogText(alloc, &dir);
    defer alloc.free(before);
    try std.testing.expectEqual(
        Outcome.compacted,
        try compactIfNeeded(alloc, &dir, test_session_id, .{
            .test_controls = .{ .before_spill_fn = failSecondSpill },
        }),
    );
    const partial = try readLogText(alloc, &dir);
    defer alloc.free(partial);
    try std.testing.expect(partial.len < before.len);
    try std.testing.expect(std.mem.find(u8, partial, "FIXTURE_DIFF_LINE") != null);
    try std.testing.expect(std.mem.find(u8, partial, "\"content_handle\":\"diff-") != null);
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.testing.io, marker_file, .{}));

    try std.testing.expectEqual(
        Outcome.compacted,
        try compactIfNeeded(alloc, &dir, test_session_id, .{}),
    );
    const converged = try readLogText(alloc, &dir);
    defer alloc.free(converged);
    try std.testing.expect(std.mem.find(u8, converged, "FIXTURE_DIFF_LINE") == null);
    try dir.dir.access(std.testing.io, marker_file, .{});
}

test "compaction leaves permanently oversized packs inline without retrying forever" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try openTestDir(&tmp);
    defer dir.close();

    const huge_len = result_store.diff_content_max_bytes / 2 + 4096;
    const huge = try alloc.alloc(u8, huge_len);
    defer alloc.free(huge);
    @memset(huge, 'H');
    try writeMixedSizeSessionLog(alloc, &dir, huge, fixtureFatContent());

    try std.testing.expectEqual(
        Outcome.compacted,
        try compactIfNeeded(alloc, &dir, test_session_id, .{}),
    );
    const after = try readLogText(alloc, &dir);
    defer alloc.free(after);
    try std.testing.expect(after.len > result_store.diff_content_max_bytes);
    try std.testing.expect(std.mem.find(u8, after, "FIXTURE_DIFF_LINE") == null);
    try std.testing.expect(std.mem.find(u8, after, "\"content_handle\":\"diff-") != null);
    try std.testing.expectEqual(
        Outcome.skipped_fresh,
        try compactIfNeeded(alloc, &dir, test_session_id, .{}),
    );
}

test "compaction preserves the original log when interrupted before rename" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try openTestDir(&tmp);
    defer dir.close();

    try writeFatSessionLog(alloc, &dir, fixtureFatContent());
    const before = try readLogText(alloc, &dir);
    defer alloc.free(before);
    try std.testing.expectError(
        error.TestBeforeRename,
        compactIfNeeded(alloc, &dir, test_session_id, .{
            .test_controls = .{ .before_rename_fn = failBeforeRename },
        }),
    );
    const after = try readLogText(alloc, &dir);
    defer alloc.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.testing.io, tmp_file, .{}));
}

test "compaction reports persistence uncertainty after rename sync failure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try openTestDir(&tmp);
    defer dir.close();

    try writeFatSessionLog(alloc, &dir, fixtureFatContent());
    try std.testing.expectError(
        error.SessionCompactionPersistenceUncertain,
        compactIfNeeded(alloc, &dir, test_session_id, .{
            .test_controls = .{ .sync_dir_fn = failDirectorySync },
        }),
    );
    const after = try readLogText(alloc, &dir);
    defer alloc.free(after);
    try std.testing.expect(std.mem.find(u8, after, "FIXTURE_DIFF_LINE") == null);
    try std.testing.expect(std.mem.find(u8, after, "\"content_handle\":\"diff-") != null);
    try dir.dir.access(std.testing.io, pending_file, .{});
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.testing.io, marker_file, .{}));

    // A later writable resume resolves the durable fence before it can skip
    // the now-small log or append any new event.
    try std.testing.expectEqual(
        Outcome.skipped_small_log,
        try compactIfNeeded(alloc, &dir, test_session_id, .{}),
    );
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.testing.io, pending_file, .{}));
}

test "compaction removes a regular stale temp before retrying" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try openTestDir(&tmp);
    defer dir.close();

    try writeFatSessionLog(alloc, &dir, fixtureFatContent());
    var stale = try dir.dir.createFile(std.testing.io, tmp_file, .{});
    try stale.writeStreamingAll(std.testing.io, "stale");
    stale.close(std.testing.io);
    try std.testing.expectEqual(
        Outcome.compacted,
        try compactIfNeeded(alloc, &dir, test_session_id, .{}),
    );
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.testing.io, tmp_file, .{}));
}

test "compaction never follows root session symlinks" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try openTestDir(&tmp);
    defer dir.close();

    var victim = try dir.dir.createFile(std.testing.io, "outside-marker", .{});
    try victim.writeStreamingAll(std.testing.io, "keep-me");
    victim.close(std.testing.io);
    try dir.dir.symLink(std.testing.io, "outside-marker", marker_file, .{});
    try writeMarkerBestEffort(alloc, &dir, test_session_id, .{ .log_len = 1, .tail_crc = 2 });
    var unchanged = try dir.dir.openFile(std.testing.io, "outside-marker", .{ .mode = .read_only });
    defer unchanged.close(std.testing.io);
    const bytes = try io_mod.readFileToEnd(alloc, &unchanged, 16);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("keep-me", bytes);

    try dir.dir.deleteFile(std.testing.io, marker_file);
    try dir.dir.symLink(std.testing.io, "outside-marker", pending_file, .{});
    try std.testing.expectError(
        error.SessionCompactionPersistenceUncertain,
        compactIfNeeded(alloc, &dir, test_session_id, .{}),
    );
    try dir.dir.deleteFile(std.testing.io, pending_file);

    try writeFatSessionLog(alloc, &dir, fixtureFatContent());
    try dir.dir.rename(events_file, dir.dir, "outside-events", std.testing.io);
    try dir.dir.symLink(std.testing.io, "outside-events", events_file, .{});
    try std.testing.expectError(
        error.DurablePathUnsafe,
        compactIfNeeded(alloc, &dir, test_session_id, .{}),
    );
}

test "compaction drops a torn tail the way the open scan truncates it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try openTestDir(&tmp);
    defer dir.close();

    const fat = fixtureFatContent();
    try writeFatSessionLog(alloc, &dir, fat);
    // Append a torn partial frame: the open scan would truncate it, so the
    // compacted log must end at the last complete frame.
    var file = try dir.dir.openFile(std.testing.io, events_file, .{ .mode = .write_only });
    {
        defer file.close(std.testing.io);
        const len = try file.length(std.testing.io);
        try file.writePositionalAll(std.testing.io, "{\"schema_version\":3,\"seq\":8,\"timestamp", len);
    }
    const before = try readLogText(alloc, &dir);
    defer alloc.free(before);

    const outcome = try compactIfNeeded(alloc, &dir, test_session_id, .{});
    try std.testing.expectEqual(Outcome.compacted, outcome);
    const after = try readLogText(alloc, &dir);
    defer alloc.free(after);
    try std.testing.expect(after.len < before.len);
    try std.testing.expect(std.mem.endsWith(u8, after, "\n"));
    try std.testing.expect(std.mem.find(u8, after, "\"seq\":8") == null);
}

test "compaction validation rejects a corrupted rewrite" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try openTestDir(&tmp);
    defer dir.close();

    var file = try dir.dir.createFile(std.testing.io, tmp_file, .{ .truncate = true });
    {
        defer file.close(std.testing.io);
        // seq jumps 1 -> 3, which transition validation must reject.
        try appendFixtureFrame(alloc, &file, 1, .{ .user = .{ .text = "seed" } });
        try appendFixtureFrame(alloc, &file, 3, .{ .assistant = .{ .text = "jump" } });
    }
    try std.testing.expectError(error.OutOfOrderConversationEvent, validateCompactedLog(alloc, &dir, test_session_id));
}

test "compaction skips a fresh log without parsing it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try openTestDir(&tmp);
    defer dir.close();

    // A big but clean log (no spillable payloads) is the case the freshness
    // marker exists for: the first pass scans once, later passes skip.
    var file = try dir.dir.createFile(std.testing.io, events_file, .{ .truncate = true });
    {
        defer file.close(std.testing.io);
        try appendFixtureFrame(alloc, &file, 1, .{ .user = .{ .text = "seed" } });
        var seq: u64 = 2;
        while (seq < 2200) : (seq += 1) {
            try appendFixtureFrame(alloc, &file, seq, .{ .steering = .{
                .text = "STEERING_PAD_LINE_FOR_A_BIG_CLEAN_LOG_0123456789abcdef",
            } });
        }
        try appendFixtureFrame(alloc, &file, seq, .{ .assistant = .{ .text = "done" } });
        try appendFixtureFrame(alloc, &file, seq + 1, .{ .turn_completed = .{} });
        try file.sync(std.testing.io);
    }
    const before = try readLogText(alloc, &dir);
    defer alloc.free(before);
    try std.testing.expect(before.len > min_log_bytes);

    const first = try compactIfNeeded(alloc, &dir, test_session_id, .{});
    try std.testing.expectEqual(Outcome.no_inline_payloads, first);
    const second = try compactIfNeeded(alloc, &dir, test_session_id, .{});
    try std.testing.expectEqual(Outcome.skipped_fresh, second);

    // Corrupt the tail with equal length: the pin must change and the third
    // pass must re-scan rather than trust a stale marker.
    var tampered = try alloc.dupe(u8, before);
    defer alloc.free(tampered);
    const tail_at = std.mem.findLast(u8, tampered, "STEERING_PAD_LINE").?;
    tampered[tail_at] = 'X';
    var rewrite = try dir.dir.createFile(std.testing.io, events_file, .{ .truncate = true });
    {
        defer rewrite.close(std.testing.io);
        try rewrite.writeStreamingAll(std.testing.io, tampered);
    }
    const third = try compactIfNeeded(alloc, &dir, test_session_id, .{});
    try std.testing.expectEqual(Outcome.no_inline_payloads, third);
    const fourth = try compactIfNeeded(alloc, &dir, test_session_id, .{});
    try std.testing.expectEqual(Outcome.skipped_fresh, fourth);
}
