//! L1: one append-only log file.
//!
//! Owns the line format's frame (the CRC32C field), the seq check, the batch
//! append, the torn-tail cut on open, and bounded forward and backward reads.
//! It knows nothing of event meanings beyond `v`, `seq`, `kind` and `crc`.
//!
//! The pure core is `appendLine`, `checkLine` and `Scanner`: bytes in, values
//! out, no I/O. `Log`, `ForwardReader` and `BackwardReader` are the thin
//! effectful shell over L0.

const std = @import("std");
const schema = @import("schema.zig");
const storage = @import("storage.zig");
const trace = if (storage.hooks) @import("trace.zig") else struct {};

const hooks = storage.hooks;

/// The hard cap on one line, newline included. The adapter moves large
/// bodies into blobs well below it.
pub const max_line_bytes: usize = 4 << 20;

/// Reads move through a file in blocks of this size.
const block_bytes: usize = 64 << 10;

const crc_field = ",\"crc\":\"";
/// `,"crc":"` plus 8 hex digits plus `"}` plus the newline.
const crc_suffix_len = crc_field.len + 8 + "\"}\n".len;

/// CRC32C (Castagnoli, reflected, polynomial 0x82F63B78), the same values
/// as `std.hash.crc.Crc32Iscsi`, computed eight bytes per step with eight
/// tables instead of one byte per step ("slicing by 8"). Every line of a
/// resume and every page read is checked, so this is on the hot path.
pub fn crc32c(bytes: []const u8) u32 {
    const t = &crc_tables;
    var c: u32 = 0xFFFF_FFFF;
    var i: usize = 0;
    while (i + 8 <= bytes.len) : (i += 8) {
        const lo = std.mem.readInt(u32, bytes[i..][0..4], .little) ^ c;
        const hi = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
        c = t[7][lo & 0xff] ^ t[6][(lo >> 8) & 0xff] ^ t[5][(lo >> 16) & 0xff] ^ t[4][lo >> 24] ^
            t[3][hi & 0xff] ^ t[2][(hi >> 8) & 0xff] ^ t[1][(hi >> 16) & 0xff] ^ t[0][hi >> 24];
    }
    for (bytes[i..]) |byte| c = t[0][(c ^ byte) & 0xff] ^ (c >> 8);
    return ~c;
}

/// `crc_tables[0]` is the byte-at-a-time table; table k advances a byte
/// through k more zero bytes.
const crc_tables: [8][256]u32 = blk: {
    @setEvalBranchQuota(20_000);
    var tables: [8][256]u32 = undefined;
    for (&tables[0], 0..) |*entry, i| {
        var c: u32 = i;
        for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ 0x82F6_3B78 else c >> 1;
        entry.* = c;
    }
    for (1..8) |k| {
        for (&tables[k], tables[k - 1]) |*entry, previous| {
            entry.* = (previous >> 8) ^ tables[0][previous & 0xff];
        }
    }
    break :blk tables;
};

// ---------------------------------------------------------------------------
// Pure core: framing

pub const FrameError = error{ OutOfMemory, TooLarge };

/// Appends one complete line to `out`: the header, `body`, the checksum and
/// the newline. `body` is empty or JSON fields that each start with `,`.
/// On error, `out` is left as it was.
pub fn appendLine(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    seq: u64,
    ts_ms: u64,
    kind: schema.Kind,
    body: []const u8,
) FrameError!void {
    std.debug.assert(body.len == 0 or body[0] == ',');
    const start = out.items.len;
    errdefer out.shrinkRetainingCapacity(start);
    try schema.appendHeader(gpa, out, seq, ts_ms, kind);
    try out.appendSlice(gpa, body);
    try sealFrame(gpa, out, start);
}

/// Appends any checksummed line: `payload` is a JSON object without its
/// closing brace. The index uses this frame for its own records.
pub fn appendFramed(gpa: std.mem.Allocator, out: *std.ArrayList(u8), payload: []const u8) FrameError!void {
    std.debug.assert(payload.len > 0 and payload[0] == '{');
    const start = out.items.len;
    errdefer out.shrinkRetainingCapacity(start);
    try out.appendSlice(gpa, payload);
    try sealFrame(gpa, out, start);
}

fn sealFrame(gpa: std.mem.Allocator, out: *std.ArrayList(u8), start: usize) FrameError!void {
    const crc = crc32c(out.items[start..]);
    try out.print(gpa, ",\"crc\":\"{x:0>8}\"}}\n", .{crc});
    if (out.items.len - start > max_line_bytes) return error.TooLarge;
}

/// Checks one line, newline included: size, frame, checksum and header.
/// A line passes only if every check passes.
pub fn checkLine(line: []const u8) error{BadLine}!schema.Header {
    const payload = try checkFrame(line);
    const header = schema.parseHeader(payload) catch return error.BadLine;
    const fields = payload[header.len..];
    if (fields.len > 0 and fields[0] != ',') return error.BadLine;
    return header;
}

/// Checks the frame of any line, newline included: size, the checksum field
/// and the checksum. Returns the payload, the bytes before `,"crc":"`.
pub fn checkFrame(line: []const u8) error{BadLine}![]const u8 {
    if (line.len < crc_suffix_len or line.len > max_line_bytes) return error.BadLine;
    const payload_len = line.len - crc_suffix_len;
    const suffix = line[payload_len..];
    if (!std.mem.startsWith(u8, suffix, crc_field)) return error.BadLine;
    if (!std.mem.eql(u8, suffix[crc_field.len + 8 ..], "\"}\n")) return error.BadLine;
    const stored = parseHex32(suffix[crc_field.len..][0..8]) orelse return error.BadLine;
    if (crc32c(line[0..payload_len]) != stored) return error.BadLine;
    return line[0..payload_len];
}

/// The kind fields of a checked line: between the header and the checksum.
pub fn lineBody(line: []const u8, header: schema.Header) []const u8 {
    return line[header.len .. line.len - crc_suffix_len];
}

fn parseHex32(digits: *const [8]u8) ?u32 {
    var value: u32 = 0;
    for (digits) |c| {
        const nibble: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            else => return null,
        };
        value = (value << 4) | nibble;
    }
    return value;
}

// ---------------------------------------------------------------------------
// Pure core: scanning

pub const Verdict = union(enum) {
    /// Every line is good and the file ends with a newline.
    clean,
    /// The final line is incomplete or fails a check. It never counted:
    /// a writable open cuts the file at `cut_at`.
    torn: struct { cut_at: u64 },
    /// A bad line, or a seq gap, before the final line. The session is
    /// readable only up to the last good line, and nothing is skipped.
    corrupt: struct { at: u64 },
    /// A line from a newer format version. The session opens read-only.
    newer_version: struct { at: u64, v: u32 },
};

/// Feed complete lines in file order, then `finish` with the length of any
/// bytes after the last newline. This is the one place that decides torn
/// versus corrupt.
pub const Scanner = struct {
    /// Expected seq of the next line; null until the first good line when
    /// the scan starts in the middle of a file.
    next_seq: ?u64,
    /// Offset just past the last good line.
    good_end: u64,
    /// Seq of the last good line; 0 before the first.
    last_seq: u64 = 0,
    good_lines: u64 = 0,
    /// A complete line that failed its checks: torn if nothing follows it.
    suspect: ?u64 = null,
    stopped: ?Verdict = null,

    pub fn init(offset: u64, next_seq: ?u64) Scanner {
        return .{ .next_seq = next_seq, .good_end = offset };
    }

    /// Returns false once a verdict is reached; later lines are ignored.
    pub fn line(sc: *Scanner, bytes: []const u8, offset: u64) bool {
        if (sc.stopped != null) return false;
        if (sc.suspect) |at| {
            sc.stopped = .{ .corrupt = .{ .at = at } };
            return false;
        }
        const header = checkLine(bytes) catch {
            sc.suspect = offset;
            return true;
        };
        if (header.v > schema.version) {
            sc.stopped = .{ .newer_version = .{ .at = offset, .v = header.v } };
            return false;
        }
        if (sc.next_seq) |expected| if (header.seq != expected) {
            sc.stopped = .{ .corrupt = .{ .at = offset } };
            return false;
        };
        sc.next_seq = header.seq + 1;
        sc.last_seq = header.seq;
        sc.good_lines += 1;
        sc.good_end = offset + bytes.len;
        return true;
    }

    pub fn finish(sc: *const Scanner, trailing_bytes: u64) Verdict {
        if (sc.stopped) |verdict| return verdict;
        if (sc.suspect) |at| {
            return if (trailing_bytes == 0) .{ .torn = .{ .cut_at = at } } else .{ .corrupt = .{ .at = at } };
        }
        if (trailing_bytes > 0) return .{ .torn = .{ .cut_at = sc.good_end } };
        return .clean;
    }
};

/// Pure: scans a whole byte range that starts at a line boundary.
pub fn scanBytes(bytes: []const u8, base_offset: u64, next_seq: ?u64) struct { scanner: Scanner, verdict: Verdict } {
    var sc: Scanner = .init(base_offset, next_seq);
    var at: usize = 0;
    while (std.mem.findScalarPos(u8, bytes, at, '\n')) |nl| {
        if (!sc.line(bytes[at .. nl + 1], base_offset + at)) break;
        at = nl + 1;
    } else {}
    const last_nl = if (std.mem.findScalarLast(u8, bytes, '\n')) |nl| nl + 1 else 0;
    return .{ .scanner = sc, .verdict = sc.finish(bytes.len - last_nl) };
}

// ---------------------------------------------------------------------------
// Effectful shell: the log

pub const Status = enum { open, writing, down };

/// Test hooks, compiled only with `-Dhooks=true`.
pub const Hook = if (hooks) struct {
    tracer: ?*trace.SessionLogTracer = null,
    planted: trace.Planted = .none,
} else struct {};

pub const OpenError = storage.Error || error{OutOfMemory};
pub const AppendError = storage.Error || error{NotWritable};

pub const Opened = struct {
    log: Log,
    verdict: Verdict,
    /// Bytes cut from a torn tail, when a writable open cut one.
    cut_bytes: u64,
};

pub const Log = struct {
    s: storage.Storage,
    file: storage.File,
    access: storage.Access,
    /// Offset just past the last good line; the next append goes here.
    end: u64,
    /// Seq of the next line. Seq equals the line's position, so this is
    /// also the line count plus one.
    next_seq: u64,
    /// Lines covered by the last completed sync.
    synced_lines: u64,
    status: Status,
    hook: Hook = .{},

    /// Creates an empty log. Nothing is synced until the caller syncs.
    pub fn create(s: storage.Storage, dir: storage.Dir, name: []const u8, hook: Hook) storage.Error!Log {
        const file = try s.createFile(dir, name);
        return .{
            .s = s,
            .file = file,
            .access = .read_write,
            .end = 0,
            .next_seq = 1,
            .synced_lines = 0,
            .status = .open,
            .hook = hook,
        };
    }

    /// Opens an existing log. It checks only the last lines, so its cost
    /// does not grow with the log. A writable open cuts a torn tail and
    /// syncs, which makes everything kept durable (`SessionLog.tla`
    /// `Recover`). A corrupt tail or a newer version opens read-only.
    pub fn open(
        gpa: std.mem.Allocator,
        s: storage.Storage,
        dir: storage.Dir,
        name: []const u8,
        access: storage.Access,
        hook: Hook,
    ) OpenError!Opened {
        const file = try s.openFile(dir, name, access);
        errdefer s.closeFile(file);
        const len = try s.length(file);
        const tail = try inspectTail(gpa, s, file, len);
        var effective = access;
        var cut_bytes: u64 = 0;
        const keep_torn_tail = if (hooks) hook.planted == .keep_torn_tail else false;
        switch (tail.verdict) {
            .clean => {},
            .torn => |torn| if (access == .read_write) {
                if (!keep_torn_tail) try s.setLength(file, torn.cut_at);
                cut_bytes = len - torn.cut_at;
            },
            .corrupt, .newer_version => effective = .read_only,
        }
        if (effective == .read_write) try s.sync(file);
        var log: Log = .{
            .s = s,
            .file = file,
            .access = effective,
            .end = tail.scanner.good_end,
            .next_seq = tail.scanner.last_seq + 1,
            .synced_lines = if (effective == .read_write) tail.scanner.last_seq else 0,
            .status = .open,
            .hook = hook,
        };
        if (effective == .read_write) log.emit("Recover");
        return .{ .log = log, .verdict = tail.verdict, .cut_bytes = cut_bytes };
    }

    /// Appends a batch of complete lines framed by `appendLine`, with seqs
    /// starting at `next_seq`. Release builds write the batch with one call.
    /// A failed write leaves the log down: the next open repairs the tail.
    pub fn append(log: *Log, batch: []const u8, line_count: u64) AppendError!void {
        if (log.status != .open or log.access != .read_write) return error.NotWritable;
        std.debug.assert(batch.len > 0 and batch[batch.len - 1] == '\n');
        if (std.debug.runtime_safety) log.assertSeqs(batch, line_count);
        const traced = if (hooks) log.hook.tracer != null else false;
        if (traced) {
            try log.appendTraced(batch);
        } else {
            log.s.writeAt(log.file, batch, log.end) catch |err| {
                log.status = .down;
                return err;
            };
        }
        log.end += batch.len;
        log.next_seq += line_count;
    }

    /// A durability point: every line appended so far survives a crash.
    pub fn sync(log: *Log) AppendError!void {
        if (log.status != .open or log.access != .read_write) return error.NotWritable;
        log.s.sync(log.file) catch |err| {
            log.status = .down;
            return err;
        };
        log.synced_lines = log.next_seq - 1;
        log.emit("Fsync");
    }

    /// Lines in the log (seq equals position).
    pub fn lineCount(log: *const Log) u64 {
        return log.next_seq - 1;
    }

    pub fn close(log: *Log) void {
        log.s.closeFile(log.file);
        log.status = .down;
    }

    /// Hooks only: writes line by line and each line in two halves, so the
    /// trace can observe `BeginWrite` and `FinishWrite` on disk.
    fn appendTraced(log: *Log, batch: []const u8) AppendError!void {
        var at: usize = 0;
        while (at < batch.len) {
            const nl = std.mem.findScalarPos(u8, batch, at, '\n').?;
            const line = batch[at .. nl + 1];
            const half = line.len / 2;
            log.s.writeAt(log.file, line[0..half], log.end + at) catch |err| {
                log.status = .down;
                return err;
            };
            log.status = .writing;
            log.emit("BeginWrite");
            log.s.writeAt(log.file, line[half..], log.end + at + half) catch |err| {
                log.status = .down;
                return err;
            };
            log.status = .open;
            log.emit("FinishWrite");
            at = nl + 1;
        }
    }

    fn emit(log: *Log, event: []const u8) void {
        if (hooks) {
            const tracer = log.hook.tracer orelse return;
            tracer.step(event, log.synced_lines, switch (log.status) {
                .open => .open,
                .writing => .writing,
                .down => .down,
            });
        }
    }

    fn assertSeqs(log: *const Log, batch: []const u8, line_count: u64) void {
        var expected = log.next_seq;
        var at: usize = 0;
        while (std.mem.findScalarPos(u8, batch, at, '\n')) |nl| : (at = nl + 1) {
            const header = checkLine(batch[at .. nl + 1]) catch unreachable;
            std.debug.assert(header.seq == expected);
            expected += 1;
        }
        std.debug.assert(expected - log.next_seq == line_count);
    }
};

const Tail = struct { scanner: Scanner, verdict: Verdict };

/// Reads backward from the end until the window holds the last two complete
/// lines (or the whole file), then lets the `Scanner` judge them.
fn inspectTail(gpa: std.mem.Allocator, s: storage.Storage, file: storage.File, len: u64) OpenError!Tail {
    const bound = 3 * max_line_bytes + block_bytes;
    var window: std.ArrayList(u8) = .empty;
    defer window.deinit(gpa);
    var start = len;
    var newlines: usize = 0;
    while (start > 0 and newlines < 3) {
        if (window.items.len >= bound) {
            // Lines longer than the cap: nothing here can be trusted.
            return .{ .scanner = .init(start, null), .verdict = .{ .corrupt = .{ .at = start } } };
        }
        const step: usize = @intCast(@min(start, block_bytes));
        start -= step;
        const old_len = window.items.len;
        try window.resize(gpa, old_len + step);
        std.mem.copyBackwards(u8, window.items[step..], window.items[0..old_len]);
        const n = try s.readAt(file, window.items[0..step], start);
        if (n != step) return error.Io; // the file shrank under us
        newlines += std.mem.count(u8, window.items[0..step], "\n");
    }
    // Begin just after the third newline from the end: a line boundary.
    var skip: usize = 0;
    if (newlines >= 3) {
        var seen: usize = 0;
        var i = window.items.len;
        while (i > 0) {
            i -= 1;
            if (window.items[i] == '\n') {
                seen += 1;
                if (seen == 3) {
                    skip = i + 1;
                    break;
                }
            }
        }
    }
    const scan = scanBytes(window.items[skip..], start + skip, null);
    return .{ .scanner = scan.scanner, .verdict = scan.verdict };
}

/// The offset just past the last newline at or before `len`: where the
/// complete lines end, even while a writer is in the middle of a line.
pub fn lastLineEnd(s: storage.Storage, file: storage.File, len: u64) ReadError!u64 {
    var buffer: [4096]u8 = undefined;
    var end = len;
    var scanned: u64 = 0;
    while (end > 0) {
        if (scanned > max_line_bytes + block_bytes) return error.Corrupt;
        const start = end -| buffer.len;
        const n: usize = @intCast(end - start);
        if (try s.readAt(file, buffer[0..n], start) != n) return error.Io;
        if (std.mem.findScalarLast(u8, buffer[0..n], '\n')) |at| return start + at + 1;
        scanned += n;
        end = start;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Effectful shell: readers (lock-free; they never change the file)

pub const ReadError = storage.Error || error{ OutOfMemory, Corrupt };

pub const Line = struct {
    offset: u64,
    header: schema.Header,
    /// The whole line, newline included. Borrowed until the next `next`.
    bytes: []const u8,

    pub fn body(l: Line) []const u8 {
        return lineBody(l.bytes, l.header);
    }
};

/// Reads lines in file order from a line boundary up to `limit`. It stops
/// quietly at an incomplete or bad final line (a torn tail), and returns
/// Corrupt for a bad line or seq gap with lines after it.
/// The block buffer of a reader. Its memory is allocated raw: a checked
/// build fills every new allocation with 0xaa one byte at a time, and here
/// each block is overwritten by the read at once, so the fill only cost
/// time (a third of a full read). Every byte in `items` was read.
const ReadBuffer = struct {
    items: []u8 = &.{},
    capacity: usize = 0,

    fn resize(b: *ReadBuffer, gpa: std.mem.Allocator, new_len: usize) error{OutOfMemory}!void {
        if (new_len > b.capacity) {
            const capacity = @max(new_len, b.capacity *| 2);
            const memory = gpa.rawAlloc(capacity, .@"1", @returnAddress()) orelse return error.OutOfMemory;
            @memcpy(memory[0..b.items.len], b.items);
            b.release(gpa);
            b.items.ptr = memory;
            b.capacity = capacity;
        }
        b.items.len = new_len;
    }

    fn shrinkRetainingCapacity(b: *ReadBuffer, new_len: usize) void {
        std.debug.assert(new_len <= b.items.len);
        b.items.len = new_len;
    }

    fn release(b: *ReadBuffer, gpa: std.mem.Allocator) void {
        if (b.capacity > 0) gpa.rawFree(b.items.ptr[0..b.capacity], .@"1", @returnAddress());
    }

    fn deinit(b: *ReadBuffer, gpa: std.mem.Allocator) void {
        b.release(gpa);
        b.* = .{};
    }
};

pub const ForwardReader = struct {
    gpa: std.mem.Allocator,
    s: storage.Storage,
    file: storage.File,
    limit: u64,
    buf: ReadBuffer = .{},
    /// File offset of `buf.items[0]`.
    buf_offset: u64,
    pos: usize = 0,
    expected_seq: ?u64,
    /// Offset of the damaged line when `next` returned Corrupt.
    damaged_at: ?u64 = null,

    pub fn init(gpa: std.mem.Allocator, s: storage.Storage, file: storage.File, offset: u64, limit: u64, expected_seq: ?u64) ForwardReader {
        return .{ .gpa = gpa, .s = s, .file = file, .limit = limit, .buf_offset = offset, .expected_seq = expected_seq };
    }

    pub fn deinit(r: *ForwardReader) void {
        r.buf.deinit(r.gpa);
    }

    pub fn next(r: *ForwardReader) ReadError!?Line {
        while (true) {
            if (std.mem.findScalarPos(u8, r.buf.items, r.pos, '\n')) |nl| {
                const bytes = r.buf.items[r.pos .. nl + 1];
                const offset = r.buf_offset + r.pos;
                r.pos = nl + 1;
                const header = checkLine(bytes) catch {
                    if (offset + bytes.len >= r.limit) return null;
                    r.damaged_at = offset;
                    return error.Corrupt;
                };
                if (r.expected_seq) |expected| if (header.seq != expected) {
                    r.damaged_at = offset;
                    return error.Corrupt;
                };
                r.expected_seq = header.seq + 1;
                return .{ .offset = offset, .header = header, .bytes = bytes };
            }
            const have_end = r.buf_offset + r.buf.items.len;
            if (have_end >= r.limit) return null;
            if (r.buf.items.len - r.pos > max_line_bytes) {
                r.damaged_at = r.buf_offset + r.pos;
                return error.Corrupt;
            }
            // Drop consumed bytes, then read the next block.
            const unread = r.buf.items.len - r.pos;
            std.mem.copyForwards(u8, r.buf.items[0..unread], r.buf.items[r.pos..]);
            r.buf.shrinkRetainingCapacity(unread);
            r.buf_offset += r.pos;
            r.pos = 0;
            const want: usize = @intCast(@min(block_bytes, r.limit - have_end));
            const old_len = r.buf.items.len;
            try r.buf.resize(r.gpa, old_len + want);
            const n = try r.s.readAt(r.file, r.buf.items[old_len..], have_end);
            r.buf.shrinkRetainingCapacity(old_len + n);
            if (n == 0) return null;
        }
    }
};

/// Reads lines newest first, from `end` (a line boundary) toward line 1.
/// Every line is checked, and seqs must count down by one.
pub const BackwardReader = struct {
    gpa: std.mem.Allocator,
    s: storage.Storage,
    file: storage.File,
    /// Offset just past the next line to return.
    pos: u64,
    /// Holds the file bytes [buf_offset, pos).
    buf: ReadBuffer = .{},
    buf_offset: u64,
    expected_seq: ?u64 = null,
    /// Offset just past the damaged line when `next` returned Corrupt.
    damaged_at: ?u64 = null,

    pub fn init(gpa: std.mem.Allocator, s: storage.Storage, file: storage.File, end: u64) BackwardReader {
        return .{ .gpa = gpa, .s = s, .file = file, .pos = end, .buf_offset = end };
    }

    pub fn deinit(r: *BackwardReader) void {
        r.buf.deinit(r.gpa);
    }

    pub fn next(r: *BackwardReader) ReadError!?Line {
        if (r.pos == 0) return null;
        // Forget the line returned last time: memory stays one line plus a block.
        r.buf.shrinkRetainingCapacity(@intCast(r.pos - r.buf_offset));
        while (true) {
            const have = r.buf.items[0..@intCast(r.pos - r.buf_offset)];
            if (have.len > 0 and have[have.len - 1] != '\n') {
                r.damaged_at = r.pos;
                return error.Corrupt;
            }
            const search = if (have.len > 0) have[0 .. have.len - 1] else have;
            const start: ?usize = if (std.mem.findScalarLast(u8, search, '\n')) |nl|
                nl + 1
            else if (r.buf_offset == 0 and have.len > 0)
                0
            else
                null;
            if (start) |line_start| {
                const bytes = have[line_start..];
                const header = checkLine(bytes) catch {
                    r.damaged_at = r.pos;
                    return error.Corrupt;
                };
                if (r.expected_seq) |expected| if (header.seq != expected) {
                    r.damaged_at = r.pos;
                    return error.Corrupt;
                };
                r.expected_seq = header.seq - 1;
                r.pos = r.buf_offset + line_start;
                return .{ .offset = r.pos, .header = header, .bytes = bytes };
            }
            if (have.len > max_line_bytes) {
                r.damaged_at = r.pos;
                return error.Corrupt;
            }
            // Prepend the previous block.
            const want: usize = @intCast(@min(block_bytes, r.buf_offset));
            try r.buf.resize(r.gpa, have.len + want);
            std.mem.copyBackwards(u8, r.buf.items[want..], r.buf.items[0..have.len]);
            r.buf_offset -= want;
            const n = try r.s.readAt(r.file, r.buf.items[0..want], r.buf_offset);
            if (n != want) return error.Io;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Fault = storage.Fault;

fn frameOne(out: *std.ArrayList(u8), seq: u64, kind: schema.Kind, body: []const u8) !void {
    try appendLine(testing.allocator, out, seq, 1000 + seq, kind, body);
}

fn validLog(out: *std.ArrayList(u8), lines: u64) !void {
    var seq: u64 = 1;
    while (seq <= lines) : (seq += 1) try frameOne(out, seq, .item, ",\"turn\":1,\"data\":{\"t\":\"x\"}");
}

test "CRC32C matches the standard check value" {
    try testing.expectEqual(@as(u32, 0xe3069283), crc32c("123456789"));
}

test "a framed line checks, and its body comes back" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try frameOne(&out, 3, .turn_committed, ",\"turn\":2");
    const h = try checkLine(out.items);
    try testing.expectEqual(@as(u64, 3), h.seq);
    try testing.expectEqualStrings(",\"turn\":2", lineBody(out.items, h));
    try testing.expect(std.mem.endsWith(u8, out.items, "\"}\n"));
    // The line is still valid JSON.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.items, .{});
    parsed.deinit();
}

test "flipping any single bit of a line is detected" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try frameOne(&out, 9, .set, ",\"key\":\"title\",\"value\":\"fx\"");
    const line = try testing.allocator.dupe(u8, out.items);
    defer testing.allocator.free(line);
    for (0..line.len) |i| {
        for (0..8) |bit| {
            line[i] ^= @as(u8, 1) << @intCast(bit);
            try testing.expectError(error.BadLine, checkLine(line));
            line[i] ^= @as(u8, 1) << @intCast(bit);
        }
    }
    _ = try checkLine(line);
}

test "a line over the cap is refused when framed" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const big = try testing.allocator.alloc(u8, max_line_bytes);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    big[0] = ',';
    try testing.expectError(error.TooLarge, appendLine(testing.allocator, &out, 1, 0, .item, big));
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "scanner verdicts" {
    var good: std.ArrayList(u8) = .empty;
    defer good.deinit(testing.allocator);
    try validLog(&good, 3);
    const l1_end = std.mem.findScalar(u8, good.items, '\n').? + 1;
    const l2_end = std.mem.findScalarPos(u8, good.items, l1_end, '\n').? + 1;

    // Clean.
    const clean = scanBytes(good.items, 0, 1);
    try testing.expectEqual(Verdict.clean, clean.verdict);
    try testing.expectEqual(@as(u64, 3), clean.scanner.last_seq);

    // Incomplete final line: torn, cut at the last boundary.
    const partial = scanBytes(good.items[0 .. good.items.len - 5], 0, 1);
    try testing.expectEqual(@as(u64, l2_end), partial.verdict.torn.cut_at);

    var damaged = try testing.allocator.dupe(u8, good.items);
    defer testing.allocator.free(damaged);

    // Bad final complete line with nothing after it: torn.
    damaged[good.items.len - 20] ^= 1;
    try testing.expectEqual(@as(u64, l2_end), scanBytes(damaged, 0, 1).verdict.torn.cut_at);
    damaged[good.items.len - 20] ^= 1;

    // Bad line before the final one: corrupt, good up to line 1.
    damaged[l1_end + 3] ^= 1;
    const mid = scanBytes(damaged, 0, 1);
    try testing.expectEqual(@as(u64, l1_end), mid.verdict.corrupt.at);
    try testing.expectEqual(@as(u64, l1_end), mid.scanner.good_end);
    damaged[l1_end + 3] ^= 1;

    // Seq gap: corrupt.
    var gap: std.ArrayList(u8) = .empty;
    defer gap.deinit(testing.allocator);
    try frameOne(&gap, 1, .item, "");
    try frameOne(&gap, 3, .item, "");
    try testing.expect(scanBytes(gap.items, 0, 1).verdict == .corrupt);
}

test "any prefix of a valid log scans to its last complete line" {
    var good: std.ArrayList(u8) = .empty;
    defer good.deinit(testing.allocator);
    try validLog(&good, 5);
    for (0..good.items.len + 1) |p| {
        const prefix = good.items[0..p];
        const result = scanBytes(prefix, 0, 1);
        const boundary = if (std.mem.findScalarLast(u8, prefix, '\n')) |nl| nl + 1 else 0;
        try testing.expectEqual(@as(u64, boundary), result.scanner.good_end);
        try testing.expectEqual(@as(u64, std.mem.count(u8, prefix, "\n")), result.scanner.last_seq);
        if (boundary == p) {
            try testing.expectEqual(Verdict.clean, result.verdict);
        } else {
            try testing.expectEqual(@as(u64, boundary), result.verdict.torn.cut_at);
        }
    }
}

test "scanning never panics on arbitrary bytes" {
    try testing.fuzz({}, fuzzScan, .{ .corpus = &.{
        "{\"v\":1,\"seq\":1,\"ts\":0,\"kind\":\"item\",\"crc\":\"00000000\"}\n",
        "\n\n\n",
    } });
}

fn fuzzScan(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [512]u8 = undefined;
    const len = smith.slice(&buffer);
    const result = scanBytes(buffer[0..len], 0, 1);
    try testing.expect(result.scanner.good_end <= len);
}

/// A log folder for tests. With hooks, the storage goes through the fault
/// layer (idle unless a test arms it); without hooks, straight to L0.
const TestLog = struct {
    tmp: testing.TmpDir,
    fault: if (hooks) Fault else void,

    fn init(seed: u64) TestLog {
        return .{
            .tmp = testing.tmpDir(.{ .iterate = true }),
            .fault = if (hooks) .init(testing.allocator, testing.io, seed) else {},
        };
    }

    /// Borrows `t.fault`; `t` must not move while the Storage is in use.
    fn storageFor(t: *TestLog) storage.Storage {
        return if (hooks) .{ .io = testing.io, .fault = &t.fault } else .{ .io = testing.io };
    }

    fn dir(t: *TestLog) storage.Dir {
        return .{ .handle = t.tmp.dir };
    }

    fn deinit(t: *TestLog) void {
        if (hooks) t.fault.deinit();
        t.tmp.cleanup();
    }
};

fn appendItems(log: *Log, count: u64) !void {
    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(testing.allocator);
    var i: u64 = 0;
    while (i < count) : (i += 1) try frameOne(&batch, log.next_seq + i, .item, ",\"turn\":1");
    try log.append(batch.items, count);
}

test "append, sync and reopen continue the seq" {
    var t = TestLog.init(1);
    defer t.deinit();
    const s = t.storageFor();
    var log = try Log.create(s, t.dir(), "log.jsonl", .{});
    try appendItems(&log, 3);
    try log.sync();
    log.close();
    var opened = try Log.open(testing.allocator, s, t.dir(), "log.jsonl", .read_write, .{});
    defer opened.log.close();
    try testing.expectEqual(Verdict.clean, opened.verdict);
    try testing.expectEqual(@as(u64, 4), opened.log.next_seq);
    try appendItems(&opened.log, 2);
    try opened.log.sync();
    try testing.expectEqual(@as(u64, 5), opened.log.lineCount());
}

test "a writable open cuts a torn tail and reports the bytes" {
    var t = TestLog.init(2);
    defer t.deinit();
    const s = t.storageFor();
    var log = try Log.create(s, t.dir(), "log.jsonl", .{});
    try appendItems(&log, 2);
    try log.sync();
    const good_end = log.end;
    const torn = "{\"v\":1,\"seq\":3,\"ts\"";
    try s.writeAt(log.file, torn, log.end);
    log.close();
    var opened = try Log.open(testing.allocator, s, t.dir(), "log.jsonl", .read_write, .{});
    defer opened.log.close();
    try testing.expectEqual(@as(u64, torn.len), opened.cut_bytes);
    try testing.expectEqual(good_end, try s.length(opened.log.file));
    try testing.expectEqual(@as(u64, 3), opened.log.next_seq);
}

test "a bad middle line opens read-only and keeps every byte" {
    if (!hooks) return error.SkipZigTest;
    var t = TestLog.init(3);
    defer t.deinit();
    const s = t.storageFor();
    var log = try Log.create(s, t.dir(), "log.jsonl", .{});
    try appendItems(&log, 4);
    try log.sync();
    const len = log.end;
    log.close();
    // Damage line 3 of 4.
    const bytes = try t.tmp.dir.readFileAlloc(testing.io, "log.jsonl", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(bytes);
    const line2_end = std.mem.findScalarPos(u8, bytes, std.mem.findScalar(u8, bytes, '\n').? + 1, '\n').? + 1;
    try @import("storage_fault.zig").flipBit(testing.io, t.dir(), "log.jsonl", line2_end + 5, 2);
    var opened = try Log.open(testing.allocator, s, t.dir(), "log.jsonl", .read_write, .{});
    defer opened.log.close();
    try testing.expect(opened.verdict == .corrupt);
    try testing.expectEqual(storage.Access.read_only, opened.log.access);
    try testing.expectError(error.NotWritable, appendItems(&opened.log, 1));
    try testing.expectEqual(len, try s.length(opened.log.file));
}

test "forward and backward readers agree and stop before a torn tail" {
    var t = TestLog.init(4);
    defer t.deinit();
    const s = t.storageFor();
    var log = try Log.create(s, t.dir(), "log.jsonl", .{});
    defer log.close();
    try appendItems(&log, 40);
    try log.sync();
    try s.writeAt(log.file, "{\"v\":1,\"se", log.end);
    const len = try s.length(log.file);

    var forward = ForwardReader.init(testing.allocator, s, log.file, 0, len, 1);
    defer forward.deinit();
    var seqs: std.ArrayList(u64) = .empty;
    defer seqs.deinit(testing.allocator);
    while (try forward.next()) |line| try seqs.append(testing.allocator, line.header.seq);
    try testing.expectEqual(@as(usize, 40), seqs.items.len);

    var backward = BackwardReader.init(testing.allocator, s, log.file, log.end);
    defer backward.deinit();
    var i: usize = seqs.items.len;
    while (try backward.next()) |line| {
        i -= 1;
        try testing.expectEqual(seqs.items[i], line.header.seq);
    }
    try testing.expectEqual(@as(usize, 0), i);
}

test "readers report a damaged middle line" {
    if (!hooks) return error.SkipZigTest;
    var t = TestLog.init(5);
    defer t.deinit();
    const s = t.storageFor();
    var log = try Log.create(s, t.dir(), "log.jsonl", .{});
    defer log.close();
    try appendItems(&log, 3);
    try log.sync();
    try @import("storage_fault.zig").flipBit(testing.io, t.dir(), "log.jsonl", 10, 0);
    var forward = ForwardReader.init(testing.allocator, s, log.file, 0, log.end, 1);
    defer forward.deinit();
    try testing.expectError(error.Corrupt, forward.next());
    var backward = BackwardReader.init(testing.allocator, s, log.file, log.end);
    defer backward.deinit();
    _ = try backward.next();
    _ = try backward.next();
    try testing.expectError(error.Corrupt, backward.next());
}

test "crc32c equals std's byte-at-a-time CRC32C at every length and alignment" {
    var prng = std.Random.DefaultPrng.init(0xc5c);
    var buffer: [320]u8 = undefined;
    prng.random().bytes(&buffer);
    for (0..300) |len| {
        for (0..8) |start| {
            const slice = buffer[start..][0..len];
            try testing.expectEqual(std.hash.crc.Crc32Iscsi.hash(slice), crc32c(slice));
        }
    }
}

const log_model_tests = struct {
    //! L1 against `tla/SessionLog.tla`: random schedules of appends, syncs,
    //! process crashes (including in the middle of a write), machine crashes and
    //! recoveries. After every step the four spec invariants are checked on the
    //! real file, and selected runs write a trace for TLC (`zig build traces`).

    const log_mod = @import("log.zig");

    const gpa = testing.allocator;
    const io = testing.io;

    const name = "log.jsonl";
    /// `SessionLogTrace.cfg` sets MaxLines to 64; stay under it.
    const max_lines = 48;

    const Harness = struct {
        tmp: testing.TmpDir,
        fault: Fault,
        log: ?Log = null,
        /// Every byte this harness wrote, in file order. After recovery the file
        /// must equal a prefix of it.
        history: std.ArrayList(u8) = .empty,
        /// Byte length and line count acknowledged durable (ghost state).
        acked_bytes: usize = 0,
        acked_lines: u64 = 0,
        /// Durable lines of the last open log: survives a crash, like the spec's
        /// `durable`, until the next recovery sets it.
        durable: u64 = 0,
        tracer: ?*trace.SessionLogTracer = null,
        planted: trace.Planted = .none,

        fn init(seed: u64) Harness {
            return .{ .tmp = testing.tmpDir(.{ .iterate = true }), .fault = .init(gpa, io, seed) };
        }

        fn deinit(h: *Harness) void {
            if (h.log) |*log| log.close();
            h.history.deinit(gpa);
            h.fault.deinit();
            h.tmp.cleanup();
        }

        fn storageFor(h: *Harness) storage.Storage {
            return .{ .io = io, .fault = &h.fault };
        }

        fn dir(h: *Harness) storage.Dir {
            return .{ .handle = h.tmp.dir };
        }

        fn hook(h: *Harness) log_mod.Hook {
            return .{ .tracer = h.tracer, .planted = h.planted };
        }

        fn create(h: *Harness) !void {
            h.log = try Log.create(h.storageFor(), h.dir(), name, h.hook());
            // The name is made durable, as the first-turn publish does.
            try h.storageFor().syncDir(h.dir());
        }

        fn lines(h: *Harness) u64 {
            return std.mem.count(u8, h.history.items, "\n");
        }

        fn append(h: *Harness, count: u64) !void {
            const log = &h.log.?;
            var batch: std.ArrayList(u8) = .empty;
            defer batch.deinit(gpa);
            var i: u64 = 0;
            while (i < count) : (i += 1) {
                try log_mod.appendLine(gpa, &batch, log.next_seq + i, 1, .item, ",\"turn\":1,\"data\":{}");
            }
            // Recorded first: after a death part of the batch may be on disk,
            // and recovery checks the file against a prefix of the history.
            try h.history.appendSlice(gpa, batch.items);
            log.append(batch.items, count) catch |err| switch (err) {
                // An injected death: the harness records the crash.
                error.Io => return h.crashed(),
                else => return err,
            };
        }

        fn sync(h: *Harness) !void {
            const log = &h.log.?;
            log.sync() catch |err| switch (err) {
                error.Io => return h.crashed(),
                else => return err,
            };
            h.durable = log.synced_lines;
            h.acked_lines = log.synced_lines;
            h.acked_bytes = h.history.items.len;
        }

        /// The process died (a kill, or an injected failure that stops the writer).
        fn crashed(h: *Harness) !void {
            if (h.log) |*log| {
                h.durable = log.synced_lines;
                log.close();
            }
            h.log = null;
            if (h.tracer) |t| t.step("ProcessCrash", h.durable, .down);
            try h.checkDown();
        }

        fn kill(h: *Harness) !void {
            h.fault.kill();
            try h.crashed();
            h.fault.restart();
        }

        /// Dies between the two halves of the next line (trace mode), or after
        /// part of the next batch (plain mode).
        fn planMidWriteDeath(h: *Harness, random: std.Random) void {
            h.fault.next_write = if (h.tracer != null)
                .{ .after_calls = 1, .keep = 0, .then = .die }
            else
                .{ .keep = random.uintLessThan(usize, 200), .then = .die };
        }

        fn powerLoss(h: *Harness) !void {
            if (h.log) |*log| {
                h.durable = log.synced_lines;
                log.close();
            }
            h.log = null;
            _ = h.fault.powerLoss();
            if (h.tracer) |t| t.step("PowerLoss", h.durable, .down);
            h.fault.reboot();
            try h.checkDown();
        }

        fn recover(h: *Harness) !void {
            std.debug.assert(h.log == null);
            h.fault.restart();
            const opened = try Log.open(gpa, h.storageFor(), h.dir(), name, .read_write, h.hook());
            h.log = opened.log;
            h.durable = opened.log.synced_lines;
            // The file must now be exactly a prefix of what was written.
            const bytes = try h.readFile();
            defer gpa.free(bytes);
            try testing.expect(std.mem.startsWith(u8, h.history.items, bytes));
            h.history.shrinkRetainingCapacity(bytes.len);
            if (h.planted == .none) try h.checkOpen();
        }

        fn readFile(h: *Harness) ![]u8 {
            return h.tmp.dir.readFileAlloc(io, name, gpa, .limited(1 << 20));
        }

        /// `SeqContiguous`, `OnlyTailTorn` and `AckedSurvive` hold at every step.
        fn checkDown(h: *Harness) !void {
            const bytes = try h.readFile();
            defer gpa.free(bytes);
            const scan = log_mod.scanBytes(bytes, 0, 1);
            switch (scan.verdict) {
                .clean, .torn => {},
                .corrupt, .newer_version => return error.InvariantViolated,
            }
            // Every acknowledged line is present and unchanged.
            try testing.expect(bytes.len >= h.acked_bytes);
            try testing.expectEqualSlices(u8, h.history.items[0..h.acked_bytes], bytes[0..h.acked_bytes]);
            try testing.expect(scan.scanner.last_seq >= h.acked_lines);
            try testing.expect(h.acked_lines <= h.durable);
        }

        /// Plus `OpenIsClean` while the log is open.
        fn checkOpen(h: *Harness) !void {
            try h.checkDown();
            const bytes = try h.readFile();
            defer gpa.free(bytes);
            try testing.expectEqual(log_mod.Verdict.clean, log_mod.scanBytes(bytes, 0, 1).verdict);
            try testing.expectEqual(h.log.?.lineCount(), std.mem.count(u8, bytes, "\n"));
        }
    };

    /// One random schedule. Returns the number of recoveries it exercised.
    fn runSchedule(seed: u64, tracer: ?*trace.SessionLogTracer) !usize {
        var h = Harness.init(seed);
        defer h.deinit();
        h.tracer = tracer;
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        try h.create();
        var recoveries: usize = 0;
        var steps: usize = 0;
        while (steps < 40) : (steps += 1) {
            if (h.log == null) {
                try h.recover();
                recoveries += 1;
                continue;
            }
            const room = max_lines -| h.lines();
            switch (random.uintLessThan(u8, 10)) {
                0...3 => if (room >= 3) try h.append(random.intRangeAtMost(u64, 1, 3)),
                4, 5 => try h.sync(),
                6 => try h.kill(),
                7 => if (room >= 3) {
                    h.planMidWriteDeath(random);
                    try h.append(random.intRangeAtMost(u64, 1, 3));
                },
                8 => try h.powerLoss(),
                else => {
                    h.fault.fail_next_sync = true;
                    try h.sync();
                },
            }
            if (h.log != null) try h.checkOpen();
        }
        return recoveries;
    }

    test "SessionLog invariants hold under random fault schedules" {
        var recoveries: usize = 0;
        var seed: u64 = 0;
        while (seed < 300) : (seed += 1) recoveries += try runSchedule(seed, null);
        // The schedules really exercised recovery.
        try testing.expect(recoveries > 300);
    }

    fn tracedSchedule(seed: u64) !void {
        var case_buffer: [64]u8 = undefined;
        const case = try std.fmt.bufPrint(&case_buffer, "fault-schedule-seed-{d}", .{seed});
        try runTraced(seed, case, .none);
    }

    fn runTraced(seed: u64, case: []const u8, planted: trace.Planted) !void {
        var h = Harness.init(seed);
        defer h.deinit();
        var tracer: trace.SessionLogTracer = .{
            .trace = try trace.Trace.create(gpa, io, "SessionLog", case),
            .dir = h.tmp.dir,
            .name = name,
        };
        h.tracer = &tracer;
        h.planted = planted;
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        try h.create();
        if (planted == .keep_torn_tail) {
            // A torn tail must exist at the next recovery.
            try h.append(2);
            try h.sync();
            h.planMidWriteDeath(random);
            try h.append(1);
            try h.recover();
            // The in-process check sees the bug too: the open log ends torn,
            // which `OpenIsClean` forbids.
            const bytes = try h.readFile();
            defer gpa.free(bytes);
            try testing.expect(log_mod.scanBytes(bytes, 0, 1).verdict == .torn);
        } else {
            var steps: usize = 0;
            while (steps < 30) : (steps += 1) {
                if (h.log == null) {
                    try h.recover();
                    continue;
                }
                const room = max_lines -| h.lines();
                switch (random.uintLessThan(u8, 9)) {
                    0...3 => if (room >= 3) try h.append(random.intRangeAtMost(u64, 1, 3)),
                    4, 5 => try h.sync(),
                    6 => try h.kill(),
                    7 => if (room >= 3) {
                        h.planMidWriteDeath(random);
                        try h.append(1);
                    },
                    else => try h.powerLoss(),
                }
            }
        }
        try tracer.finish();
    }

    test "SessionLog traces: fault schedules" {
        for ([_]u64{ 1, 2, 3, 4, 5, 6 }) |seed| try tracedSchedule(seed);
    }

    test "SessionLog traces: crash in the middle of a write, then a torn machine crash" {
        var h = Harness.init(99);
        defer h.deinit();
        var tracer: trace.SessionLogTracer = .{
            .trace = try trace.Trace.create(gpa, io, "SessionLog", "crash-mid-write"),
            .dir = h.tmp.dir,
            .name = name,
        };
        h.tracer = &tracer;
        var prng = std.Random.DefaultPrng.init(99);
        try h.create();
        try h.append(2);
        try h.sync();
        h.planMidWriteDeath(prng.random());
        try h.append(1);
        try h.recover();
        try h.append(1);
        try h.powerLoss();
        try h.recover();
        try h.append(1);
        try h.sync();
        try tracer.finish();
    }

    test "SessionLog traces: planted bug, recovery keeps the torn tail" {
        try runTraced(7, "planted-keep_torn_tail", .keep_torn_tail);
    }
};

test {
    if (@import("storage.zig").hooks) _ = log_model_tests;
}
