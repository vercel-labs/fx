//! Diagnostics (D14): every repair or drop the manager makes is reported
//! once through one optional callback, like SQLite's log callback. The
//! adapter forwards events to fx's `debug_trace`; the driver captures them.
//! With no callback the cost is one null check.

const std = @import("std");

pub const Kind = enum {
    /// A torn or bad-checksum final line was cut on open. `count`: bytes cut.
    torn_tail_cut,
    /// A damaged line before the final one, or a newer format version: the
    /// session is readable only up to `offset`.
    opened_read_only,
    /// A session closed before its first turn: `count` held lines were never
    /// written, by design (D2).
    held_lines_dropped,
    /// The index named a session whose folder is gone; the entry was removed.
    index_healed,
    /// Rebuild removed `count` leftover `.tmp` or `.trash` entries.
    rebuild_swept,
    /// An index write failed after the session change it records had
    /// succeeded; the entry is stale until the next change or a rebuild.
    index_stale,
    /// The folded state did not fit in one line, so no snapshot was written;
    /// resume folds from the previous one. `count`: the encoded state bytes.
    snapshot_skipped,
};

pub const Event = struct {
    kind: Kind,
    /// Borrowed for the duration of the callback; empty for root-wide events.
    session_id: []const u8,
    count: u64 = 0,
    offset: u64 = 0,
};

pub const Sink = struct {
    context: ?*anyopaque,
    emit: *const fn (context: ?*anyopaque, event: Event) void,
};

pub fn report(sink: ?Sink, event: Event) void {
    const s = sink orelse return;
    s.emit(s.context, event);
}

/// A test sink that records every event.
pub const Recorder = struct {
    gpa: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    kinds: std.ArrayList(Kind) = .empty,

    pub fn sink(r: *Recorder) Sink {
        return .{ .context = r, .emit = record };
    }

    fn record(context: ?*anyopaque, event: Event) void {
        const r: *Recorder = @ptrCast(@alignCast(context.?));
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.kinds.append(r.gpa, event.kind) catch {};
    }

    pub fn count(r: *Recorder, kind: Kind) usize {
        var n: usize = 0;
        for (r.kinds.items) |k| {
            if (k == kind) n += 1;
        }
        return n;
    }

    pub fn deinit(r: *Recorder) void {
        r.kinds.deinit(r.gpa);
    }
};
