//! Binary replay cache for a session's conversation event log.
//!
//! Replaying `events.jsonl` costs a full JSON decode of every frame on every
//! resume. This module mirrors the log one-to-one into `history-cache.bin` —
//! the same frames in a compact binary encoding — so resume validates and
//! replays from the cache at memcpy speed instead of parsing JSON.
//!
//! Contract:
//! * The log is always the authority. The cache is a disposable derivation.
//! * Every frame is length-prefixed and CRC32-checked, so a torn or partial
//!   write degrades to a shorter *valid prefix* instead of an error.
//! * The cache binds to the log by watermark: the last frame records the log
//!   byte range and CRC of the log line it was written from. A load verifies
//!   the covered length and the final covered line against the real log; a
//!   mismatch (rewritten, truncated, or replaced log) discards the cache. An
//!   in-place, length-preserving rewrite of a middle log line is deliberately
//!   invisible to the watermark (see the middle-rewrite pin test); the log
//!   format never rewrites middle lines, so the binding targets real edits.
//! * A log that grew since the cache was written is fine: the cache covers a
//!   prefix and the caller replays the suffix from the log.
//! * The binary schema binds to `conversation_schema_version` (the log's own
//!   schema contract) plus a cache format version; a bump of either
//!   invalidates older caches instead of misparsing them. Payload edits that
//!   keep the log schema must bump the cache format version.
//! * The cache is written only by the open-time scan tee on writable session
//!   opens; nothing appends at commit time. Read-only loads use it but never
//!   create it.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const session_event = @import("session_event.zig");
const debug_trace = @import("../shared/debug_trace.zig");

const Allocator = std.mem.Allocator;

const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);

pub const file_name = "history-cache.bin";

const magic = "fx-history-cache\x1a\n"; // 18 bytes; all offsets use magic.len
// Version 2: ConversationToolResult carries CommittedFilePresentation
// .content_handle (spilled diff snapshots). The schema binding on
// conversation_schema_version already discards version-1 caches.
const format_version: u16 = 2;
/// Frames carry 32-bit lengths; a single log line can be large (embedded tool
/// output), so the cap stays generous. Anything larger is a corrupt cache.
const max_frame_bytes: u32 = 1024 * 1024 * 1024;
/// Bounds the in-memory frame index built while verifying.
const max_frames: usize = 4 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Generic binary codec
//
// Handles the exact shapes used by session events: integers, bools, enums,
// optionals, byte strings, slices of structs/strings, structs, and tagged
// unions. Anything else fails to compile, so the codec can never silently
// mis-encode a newly introduced field type.
// ---------------------------------------------------------------------------

const EncodeError = error{ OutOfMemory, PayloadTooLarge };
const DecodeError = error{ InvalidCache, OutOfMemory };

fn encodeAny(out: *std.ArrayList(u8), alloc: Allocator, value: anytype) EncodeError!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => try out.append(alloc, @intFromBool(value)),
        .int => |info| {
            if (info.bits > 64) @compileError("snapshot codec: integer too wide: " ++ @typeName(T));
            const wide: u64 = if (info.signedness == .signed)
                @bitCast(@as(i64, value))
            else
                std.math.cast(u64, value) orelse return error.PayloadTooLarge;
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, wide, .little);
            try out.appendSlice(alloc, &buf);
        },
        .@"enum" => |info| {
            if (@bitSizeOf(info.tag_type) > 8) @compileError("snapshot codec: enum tag too wide: " ++ @typeName(T));
            try out.append(alloc, std.math.cast(u8, @intFromEnum(value)) orelse return error.PayloadTooLarge);
        },
        .optional => {
            if (value) |inner| {
                try out.append(alloc, 1);
                try encodeAny(out, alloc, inner);
            } else {
                try out.append(alloc, 0);
            }
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                const len: u32 = std.math.cast(u32, value.len) orelse return error.PayloadTooLarge;
                try encodeAny(out, alloc, len);
                if (info.child == u8) {
                    try out.appendSlice(alloc, value);
                } else {
                    for (value) |item| try encodeAny(out, alloc, item);
                }
            },
            else => @compileError("snapshot codec: unsupported pointer: " ++ @typeName(T)),
        },
        .array => |info| {
            if (info.child == u8) {
                try out.appendSlice(alloc, &value);
            } else {
                for (value) |item| try encodeAny(out, alloc, item);
            }
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                try encodeAny(out, alloc, @field(value, field.name));
            }
        },
        .@"union" => |info| {
            const tag_info = @typeInfo(info.tag_type orelse
                @compileError("snapshot codec: untagged union: " ++ @typeName(T))).@"enum";
            if (@bitSizeOf(tag_info.tag_type) > 8) @compileError("snapshot codec: union tag too wide: " ++ @typeName(T));
            const active = std.meta.activeTag(value);
            try out.append(alloc, std.math.cast(u8, @intFromEnum(active)) orelse return error.PayloadTooLarge);
            switch (value) {
                inline else => |payload| try encodeAny(out, alloc, payload),
            }
        },
        .void => {},
        else => @compileError("snapshot codec: unsupported type: " ++ @typeName(T)),
    }
}

const ByteCursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *ByteCursor, count: usize) DecodeError![]const u8 {
        if (count > self.bytes.len - self.pos) return error.InvalidCache;
        const slice = self.bytes[self.pos..][0..count];
        self.pos += count;
        return slice;
    }

    fn takeInt(self: *ByteCursor) DecodeError!u64 {
        const raw = try self.take(8);
        return std.mem.readInt(u64, raw[0..8], .little);
    }
};

fn decodeAny(comptime T: type, alloc: Allocator, cur: *ByteCursor) DecodeError!T {
    switch (@typeInfo(T)) {
        .bool => return switch ((try cur.take(1))[0]) {
            0 => false,
            1 => true,
            else => error.InvalidCache,
        },
        .int => |info| {
            if (info.bits > 64) @compileError("snapshot codec: integer too wide: " ++ @typeName(T));
            const wide = try cur.takeInt();
            if (info.signedness == .signed) {
                const signed: i64 = @bitCast(wide);
                return std.math.cast(T, signed) orelse error.InvalidCache;
            }
            return std.math.cast(T, wide) orelse error.InvalidCache;
        },
        .@"enum" => |info| {
            const tag = (try cur.take(1))[0];
            const raw = std.math.cast(info.tag_type, tag) orelse return error.InvalidCache;
            inline for (@typeInfo(T).@"enum".fields) |field| {
                if (field.value == raw) return @enumFromInt(raw);
            }
            return error.InvalidCache;
        },
        .optional => {
            return switch ((try cur.take(1))[0]) {
                0 => null,
                1 => try decodeAny(std.meta.Child(T), alloc, cur),
                else => error.InvalidCache,
            };
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                const len = try decodeAny(u32, alloc, cur);
                if (info.child == u8) {
                    const bytes = try alloc.alloc(u8, len);
                    errdefer alloc.free(bytes);
                    @memcpy(bytes, try cur.take(len));
                    return bytes;
                }
                const items = try alloc.alloc(info.child, len);
                var initialized: usize = 0;
                errdefer {
                    for (items[0..initialized]) |item| freeAny(alloc, info.child, item);
                    alloc.free(items);
                }
                for (items) |*item| {
                    item.* = try decodeAny(info.child, alloc, cur);
                    initialized += 1;
                }
                return items;
            },
            else => @compileError("snapshot codec: unsupported pointer: " ++ @typeName(T)),
        },
        .array => |info| {
            var value: T = undefined;
            if (info.child == u8) {
                @memcpy(&value, try cur.take(info.len));
            } else {
                for (&value) |*item| item.* = try decodeAny(info.child, alloc, cur);
            }
            return value;
        },
        .@"struct" => |info| {
            var value: T = undefined;
            inline for (info.fields) |field| {
                @field(value, field.name) = try decodeAny(field.type, alloc, cur);
            }
            return value;
        },
        .@"union" => |info| {
            const tag_type = info.tag_type orelse
                @compileError("snapshot codec: untagged union: " ++ @typeName(T));
            const raw = (try cur.take(1))[0];
            _ = tag_type;
            const tag: std.meta.Tag(T) = tagblk: {
                const fields = @typeInfo(T).@"union".fields;
                inline for (fields) |field| {
                    const candidate = @field(std.meta.Tag(T), field.name);
                    if (@as(u64, @intFromEnum(candidate)) == raw) break :tagblk candidate;
                }
                return error.InvalidCache;
            };
            switch (tag) {
                inline else => |field_tag| {
                    const Payload = @TypeOf(@field(@as(T, undefined), @tagName(field_tag)));
                    const payload = try decodeAny(Payload, alloc, cur);
                    return @unionInit(T, @tagName(field_tag), payload);
                },
            }
        },
        .void => return {},
        else => @compileError("snapshot codec: unsupported type: " ++ @typeName(T)),
    }
}

/// Frees a decoded value tree. Only needed when decoding without an arena.
fn freeAny(alloc: Allocator, comptime T: type, value: T) void {
    switch (@typeInfo(T)) {
        .optional => if (value) |inner| freeAny(alloc, std.meta.Child(T), inner),
        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child != u8) {
                    for (value) |item| freeAny(alloc, info.child, item);
                }
                alloc.free(value);
            },
            else => unreachable,
        },
        .@"struct" => |info| inline for (info.fields) |field| {
            freeAny(alloc, field.type, @field(value, field.name));
        },
        .@"union" => switch (value) {
            inline else => |payload| freeAny(alloc, @TypeOf(payload), payload),
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Frame layout
//
// header: magic ++ u64 cache format version ++ u64 conversation schema
//         version ++ u64 session id length ++ session id bytes
// frame:  u32 frame_len (bytes of crc ++ payload that follow)
//         u32 crc32(payload)
//         payload: u64 log_offset ++ u32 log_bytes ++ u32 line_crc32 ++
//                  encoded ConversationEnvelope
// ---------------------------------------------------------------------------

pub const FrameMeta = struct {
    /// Offset of this frame inside the cache file.
    file_offset: u64,
    /// Offset of the corresponding line inside events.jsonl.
    log_offset: u64,
    /// Byte length of the corresponding log line.
    log_bytes: u32,
    /// CRC32 of the corresponding log line bytes.
    line_crc: u32,
};

fn encodeFramePayload(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    envelope: session_event.ConversationEnvelope,
    log_offset: u64,
    log_bytes: u32,
    line_crc: u32,
) EncodeError!void {
    try encodeAny(out, alloc, log_offset);
    try encodeAny(out, alloc, log_bytes);
    try encodeAny(out, alloc, line_crc);
    try encodeAny(out, alloc, envelope);
}

fn headerBytes(out: *std.ArrayList(u8), alloc: Allocator, session_id: []const u8) EncodeError!void {
    try out.appendSlice(alloc, magic);
    try encodeAny(out, alloc, format_version);
    try encodeAny(out, alloc, session_event.conversation_schema_version);
    const id_len: u32 = std.math.cast(u32, session_id.len) orelse return error.PayloadTooLarge;
    try encodeAny(out, alloc, id_len);
    try out.appendSlice(alloc, session_id);
}

// The codec normalizes every integer to an 8-byte little-endian value, so the
// header is magic ++ u64 version ++ u64 fingerprint ++ u64 id length.
const header_len_min = magic.len + 8 + 8 + 8;
/// Byte offset of `seq` inside a frame payload: log_offset, log_bytes and
/// line_crc (8 bytes each, codec-normalized) precede the envelope, whose own
/// schema_version u64 precedes seq.
const envelope_seq_offset = 24 + 8;

// ---------------------------------------------------------------------------
// Writer
//
// Appends frames next to the log commit path. Never fails its caller: any
// error marks the writer broken, and finalize/discard removes the file so the
// next open rebuilds from scratch.
// ---------------------------------------------------------------------------

pub const Writer = struct {
    alloc: Allocator,
    /// Borrowed for deletion of a broken cache at finalize. Valid because the
    /// writer is finalized at session-open time, before the owning session
    /// struct can move.
    dir: *io_mod.VerifiedDir,
    file: ?std.Io.File,
    len: u64 = 0,
    broken: bool = false,

    /// Creates a fresh cache, replacing any existing file.
    pub fn beginReplace(alloc: Allocator, dir: *io_mod.VerifiedDir, session_id: []const u8) !Writer {
        io_mod.e2eFailIfDurableMutationAttempted();
        deleteCacheFile(dir);
        var header: std.ArrayList(u8) = .empty;
        defer header.deinit(alloc);
        try headerBytes(&header, alloc, session_id);
        const file = createCacheFile(dir) catch |err| {
            debug_trace.logf("session", "history cache create failed err={s}", .{@errorName(err)});
            return err;
        };
        errdefer file.close(io_mod.getIo());
        try file.writePositionalAll(io_mod.getIo(), header.items, 0);
        return .{ .alloc = alloc, .dir = dir, .file = file, .len = header.items.len };
    }

    /// Opens an existing verified cache to append after its valid prefix.
    pub fn beginAppend(alloc: Allocator, dir: *io_mod.VerifiedDir, prefix_file_bytes: u64) !Writer {
        io_mod.e2eFailIfDurableMutationAttempted();
        var file = try openCacheFile(dir, .read_write);
        errdefer file.close(io_mod.getIo());
        try file.setLength(io_mod.getIo(), prefix_file_bytes);
        return .{ .alloc = alloc, .dir = dir, .file = file, .len = prefix_file_bytes };
    }

    /// Appends one frame mirroring a committed log line. `log_offset` and
    /// `log_bytes` locate the line in events.jsonl and `line_crc` is its CRC32.
    /// Cache failures never propagate: the writer marks itself broken and the
    /// file is deleted at finalize.
    pub fn append(
        self: *Writer,
        envelope: session_event.ConversationEnvelope,
        log_offset: u64,
        log_bytes: u32,
        line_crc: u32,
    ) void {
        self.appendFailing(envelope, log_offset, log_bytes, line_crc) catch |err| {
            self.broken = true;
            debug_trace.logf("session", "history cache append failed offset={d} err={s}", .{ log_offset, @errorName(err) });
        };
    }

    fn appendFailing(
        self: *Writer,
        envelope: session_event.ConversationEnvelope,
        log_offset: u64,
        log_bytes: u32,
        line_crc: u32,
    ) !void {
        if (self.broken) return;
        const file = self.file orelse return;
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.alloc);
        try encodeFramePayload(&payload, self.alloc, envelope, log_offset, log_bytes, line_crc);
        const payload_len: u32 = std.math.cast(u32, payload.items.len) orelse return error.PayloadTooLarge;
        var head: [8]u8 = undefined;
        std.mem.writeInt(u32, head[0..4], payload_len + 4, .little);
        std.mem.writeInt(u32, head[4..8], std.hash.Crc32.hash(payload.items), .little);
        try file.writePositionalAll(io_mod.getIo(), &head, self.len);
        try file.writePositionalAll(io_mod.getIo(), payload.items, self.len + 8);
        self.len += 8 + payload.items.len;
    }

    /// Truncates the cache to a prefix after a log-side rollback or torn-tail
    /// truncation made later frames stale.
    pub fn truncateTo(self: *Writer, file_offset: u64) void {
        const file = self.file orelse return;
        if (self.broken) return;
        file.setLength(io_mod.getIo(), file_offset) catch |err| {
            self.broken = true;
            debug_trace.logf("session", "history cache truncate failed err={s}", .{@errorName(err)});
            return;
        };
        self.len = file_offset;
    }

    /// Syncs and closes the cache. A broken writer deletes the file so the next
    /// open rebuilds from the log; deletion goes through the directory the
    /// writer was created with, which outlives the writer by construction.
    pub fn finalize(self: *Writer) void {
        const alloc = self.alloc;
        const dir = self.dir;
        const file = self.file orelse {
            self.* = .{ .alloc = alloc, .dir = dir, .file = null };
            return;
        };
        if (self.broken) {
            file.close(io_mod.getIo());
            deleteCacheFile(dir);
        } else {
            file.sync(io_mod.getIo()) catch |err| {
                debug_trace.logf("session", "history cache sync failed err={s}", .{@errorName(err)});
            };
            file.close(io_mod.getIo());
        }
        self.* = .{ .alloc = alloc, .dir = dir, .file = null };
    }
};

// ---------------------------------------------------------------------------
// Verification
//
// verify() reads the header and every frame once, CRC-checking as it goes. A
// torn or corrupt tail ends the valid prefix instead of failing. The result
// carries the frame index used by Cursor for random access.
// ---------------------------------------------------------------------------

pub const Verified = struct {
    file: std.Io.File,
    frames: []FrameMeta,
    /// Log bytes covered by the cache prefix.
    covered_log_bytes: u64,
    /// Cache file bytes belonging to the valid prefix.
    prefix_file_bytes: u64,
    last_seq: u64,

    pub fn deinit(self: *Verified, alloc: Allocator) void {
        alloc.free(self.frames);
        self.file.close(io_mod.getIo());
        self.* = undefined;
    }
};

/// Opens and verifies the cache for `session_id` against the already-open log
/// file. Returns null when the cache is absent, structurally invalid, belongs
/// to another session or schema, or its watermark does not match the log. Pure
/// read: callers on read-only paths can use this; only writable callers should
/// delete or rebuild.
pub fn openAndVerify(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    log_file: std.Io.File,
    log_len: u64,
) !?Verified {
    var file = openCacheFile(dir, .read_only) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var keep_file = false;
    defer if (!keep_file) file.close(io_mod.getIo());

    var frames: std.ArrayList(FrameMeta) = .empty;
    defer frames.deinit(alloc); // no-op after a successful toOwnedSlice

    var header: [header_len_min]u8 = undefined;
    const header_read = file.readPositionalAll(io_mod.getIo(), &header, 0) catch return null;
    if (header_read != header.len) return null;
    if (!std.mem.eql(u8, header[0..magic.len], magic)) return null;
    if (std.mem.readInt(u64, header[magic.len..][0..8], .little) != format_version) return null;
    if (std.mem.readInt(u64, header[magic.len + 8 ..][0..8], .little) != session_event.conversation_schema_version) return null;
    const id_len_wide = std.mem.readInt(u64, header[magic.len + 16 ..][0..8], .little);
    const id_len = std.math.cast(u32, id_len_wide) orelse return null;
    if (id_len != session_id.len) return null;
    const id_buf = alloc.alloc(u8, id_len) catch return error.OutOfMemory;
    defer alloc.free(id_buf);
    const id_read = file.readPositionalAll(io_mod.getIo(), id_buf, header_len_min) catch return null;
    if (id_read != id_len) return null;
    if (!std.mem.eql(u8, id_buf, session_id)) return null;

    var file_offset: u64 = header_len_min + @as(u64, id_len);
    var expected_seq: u64 = 1;
    var covered_log_bytes: u64 = 0;
    var tail_crc: u32 = 0;
    while (frames.items.len < max_frames) {
        var head: [8]u8 = undefined;
        const head_read = file.readPositionalAll(io_mod.getIo(), &head, file_offset) catch |err| return err;
        if (head_read != head.len) break;
        const frame_len = std.mem.readInt(u32, head[0..4], .little);
        if (frame_len < 4 or frame_len > max_frame_bytes) break;
        const want_crc = std.mem.readInt(u32, head[4..8], .little);
        const payload = alloc.alloc(u8, frame_len - 4) catch return error.OutOfMemory;
        defer alloc.free(payload);
        const read = file.readPositionalAll(io_mod.getIo(), payload, file_offset + 8) catch |err| return err;
        if (read != payload.len) break; // torn tail: valid prefix ends here
        if (std.hash.Crc32.hash(payload) != want_crc) break;
        if (payload.len < envelope_seq_offset + 8) break;
        const log_offset = std.mem.readInt(u64, payload[0..8], .little);
        const log_bytes_wide = std.mem.readInt(u64, payload[8..16], .little);
        const line_crc_wide = std.mem.readInt(u64, payload[16..24], .little);
        const log_bytes = std.math.cast(u32, log_bytes_wide) orelse break;
        const line_crc = std.math.cast(u32, line_crc_wide) orelse break;
        // The envelope prefix is schema_version (u64) then seq (u64); reading
        // seq directly avoids a full decode in the verify pass.
        const seq = std.mem.readInt(u64, payload[envelope_seq_offset..][0..8], .little);
        if (seq != expected_seq) break;
        if (log_offset != covered_log_bytes) break; // frames must mirror the log prefix exactly
        try frames.append(alloc, .{
            .file_offset = file_offset,
            .log_offset = log_offset,
            .log_bytes = log_bytes,
            .line_crc = line_crc,
        });
        covered_log_bytes += log_bytes;
        tail_crc = line_crc;
        expected_seq += 1;
        file_offset += 8 + payload.len;
    }
    if (frames.items.len == 0) return null;
    if (covered_log_bytes > log_len) return null;

    // Authority check: the last covered log line must still hash to the CRC
    // recorded when the cache frame was written.
    const tail = frames.items[frames.items.len - 1];
    const tail_bytes = alloc.alloc(u8, tail.log_bytes) catch return error.OutOfMemory;
    defer alloc.free(tail_bytes);
    const tail_read = log_file.readPositionalAll(io_mod.getIo(), tail_bytes, tail.log_offset) catch return null;
    if (tail_read != tail_bytes.len) return null;
    if (std.hash.Crc32.hash(tail_bytes) != tail_crc) return null;

    const owned = try frames.toOwnedSlice(alloc);
    keep_file = true;
    return .{
        .file = file,
        .frames = owned,
        .covered_log_bytes = covered_log_bytes,
        .prefix_file_bytes = file_offset,
        .last_seq = expected_seq - 1,
    };
}

// ---------------------------------------------------------------------------
// Cursor
//
// Sequential and random access over a verified cache. next() decodes frames in
// order; seekLogOffset() positions the cursor at the frame whose log offset
// matches, mirroring how the replay seeks into events.jsonl.
// ---------------------------------------------------------------------------

pub const Cursor = struct {
    file: std.Io.File,
    frames: []const FrameMeta,
    index: usize = 0,

    pub fn reset(self: *Cursor) void {
        self.index = 0;
    }

    /// Positions the cursor at the frame covering `log_offset`.
    pub fn seekLogOffset(self: *Cursor, log_offset: u64) DecodeError!void {
        var lo: usize = 0;
        var hi: usize = self.frames.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.frames[mid].log_offset < log_offset) lo = mid + 1 else hi = mid;
        }
        if (lo >= self.frames.len or self.frames[lo].log_offset != log_offset) return error.InvalidCache;
        self.index = lo;
    }

    /// Decodes the next frame into memory owned by `arena`.
    pub fn next(self: *Cursor, arena: Allocator) DecodeError!?session_event.ConversationEnvelope {
        if (self.index >= self.frames.len) return null;
        const meta = self.frames[self.index];
        var head: [8]u8 = undefined;
        _ = self.file.readPositionalAll(io_mod.getIo(), &head, meta.file_offset) catch return error.InvalidCache;
        const frame_len = std.mem.readInt(u32, head[0..4], .little);
        if (frame_len < 4 or frame_len > max_frame_bytes) return error.InvalidCache;
        const payload = arena.alloc(u8, frame_len - 4) catch return error.OutOfMemory;
        const read = self.file.readPositionalAll(io_mod.getIo(), payload, meta.file_offset + 8) catch return error.InvalidCache;
        if (read != payload.len) return error.InvalidCache;
        var cursor = ByteCursor{ .bytes = payload };
        _ = cursor.takeInt() catch return error.InvalidCache; // log_offset
        _ = cursor.takeInt() catch return error.InvalidCache; // log_bytes
        _ = cursor.takeInt() catch return error.InvalidCache; // line_crc
        const envelope = try decodeAny(session_event.ConversationEnvelope, arena, &cursor);
        if (cursor.pos != cursor.bytes.len) return error.InvalidCache;
        self.index += 1;
        return envelope;
    }
};

/// Opens the cache without waiting on a special file such as a FIFO; any
/// target that is not one regular file is unsafe, and callers rebuild from
/// the log.
fn openCacheFile(dir: *io_mod.VerifiedDir, mode: std.Io.Dir.OpenFileOptions.Mode) !std.Io.File {
    var file = io_mod.openExistingRegularFile(dir.dir, file_name, mode) catch |err| switch (err) {
        error.DurablePathUnsafe => return error.HistoryCacheUnsafe,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.HistoryCacheUnsafe;
    if (mode == .read_write and stat.permissions.toMode() & 0o777 != 0o600)
        return error.HistoryCachePermissionsUnsupported;
    return file;
}

fn createCacheFile(dir: *io_mod.VerifiedDir) !std.Io.File {
    var file = try dir.dir.createFile(io_mod.getIo(), file_name, .{
        .read = true,
        .truncate = true,
        .exclusive = false,
        .permissions = private_file_permissions,
        .resolve_beneath = true,
    });
    errdefer file.close(io_mod.getIo());
    file.setPermissions(io_mod.getIo(), private_file_permissions) catch return error.HistoryCachePermissionsUnsupported;
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.HistoryCacheUnsafe;
    if (stat.permissions.toMode() & 0o777 != 0o600) return error.HistoryCachePermissionsUnsupported;
    return file;
}

fn deleteCacheFile(dir: *io_mod.VerifiedDir) void {
    dir.dir.deleteFile(io_mod.getIo(), file_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => debug_trace.logf("session", "history cache delete failed err={s}", .{@errorName(err)}),
    };
}

/// Deletes the cache after a cache-backed load was rejected, so the retry and
/// later opens rebuild from the authoritative log. Writable paths only.
pub fn deleteForRebuild(dir: *io_mod.VerifiedDir) void {
    deleteCacheFile(dir);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn sampleEnvelope(seq: u64) session_event.ConversationEnvelope {
    return .{
        .seq = seq,
        .timestamp_ms = 1726000000000,
        .event = .{ .steering = .{ .text = "keep going" } },
    };
}

fn encodeDecodeRoundtrip(alloc: Allocator, envelope: session_event.ConversationEnvelope) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    try encodeFramePayload(&payload, alloc, envelope, 42, 128, 0xdeadbeef);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var cursor = ByteCursor{ .bytes = payload.items };
    try std.testing.expectEqual(@as(u64, 42), try cursor.takeInt());
    try std.testing.expectEqual(@as(u64, 128), try cursor.takeInt());
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), try cursor.takeInt());
    const decoded = try decodeAny(session_event.ConversationEnvelope, arena.allocator(), &cursor);
    try std.testing.expectEqual(payload.items.len, cursor.pos);
    // Canonical re-encode proves field fidelity without a field-by-field diff.
    var again: std.ArrayList(u8) = .empty;
    defer again.deinit(alloc);
    try encodeFramePayload(&again, alloc, decoded, 42, 128, 0xdeadbeef);
    try std.testing.expectEqualSlices(u8, payload.items, again.items);
}

test "the history cache is never opened when it is a FIFO" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ root, file_name });
    if (mkfifo(path, 0o600) != 0) return error.SkipZigTest;
    var dir = io_mod.VerifiedDir{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .follow_symlinks = false }) };
    defer dir.close();
    // A blocking open of the FIFO would wait for a writer that never comes;
    // an unsafe cache is rebuilt from the log instead.
    for ([_]std.Io.Dir.OpenFileOptions.Mode{ .read_only, .read_write }) |mode| {
        try std.testing.expectError(error.HistoryCacheUnsafe, openCacheFile(&dir, mode));
    }
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "history snapshot codec round trips every event kind" {
    const alloc = std.testing.allocator;
    const model_provider = @import("../config/model_provider.zig");

    try encodeDecodeRoundtrip(alloc, .{
        .seq = 1,
        .timestamp_ms = 1,
        .event = .{ .user = .{
            .text = "hello world",
            .images = &.{},
            .work_id = "work-1",
        } },
    });
    try encodeDecodeRoundtrip(alloc, .{
        .seq = 2,
        .timestamp_ms = 2,
        .event = .{ .user = .{
            .text = "with image",
            .images = &.{.{
                .id = 3,
                .path = @constCast("/tmp/a.png"),
                .media_type = @constCast("image/png"),
                .snapshot_path = @constCast("/tmp/s.png"),
                .snapshot_sha256 = @constCast("abc123"),
            }},
            .work_id = null,
        } },
    });
    try encodeDecodeRoundtrip(alloc, .{
        .seq = 3,
        .timestamp_ms = 3,
        .event = .{ .assistant = .{
            .text = "answer",
            .provider_replay = .{
                .source = .{ .provider = model_provider.parse("gateway").?, .model = "kimi-k3" },
                .parts_json = "[{\"type\":\"text\"}]",
            },
            .standalone_response = true,
        } },
    });
    try encodeDecodeRoundtrip(alloc, .{
        .seq = 4,
        .timestamp_ms = 4,
        .event = .{ .tool_call = .{
            .call_id = "c1",
            .tool_name = "shell",
            .arguments_json = "{\"command\":\"ls\"}",
            .argument_integrity = .valid,
            .provisional_id = "p1",
            .provider_result = "{\"ok\":true}",
            .final_identity = .valid,
            .provenance = .fx_local,
        } },
    });
    try encodeDecodeRoundtrip(alloc, .{
        .seq = 5,
        .timestamp_ms = 5,
        .event = .{ .tool_result = .{
            .call_id = "c1",
            .tool_name = "shell",
            .status = .success,
            .artifact_ref = "tool-results/abc",
            .tool_image_handle = "img-handle",
            .output_bytes = 1024,
            .stored_bytes = 512,
            .completeness = .partial,
            .preview = "first bytes",
            .provider_native = true,
            .review_feedback = true,
            .created_at_ms = 42,
            .permission_feedback = &.{ "allowed once", "denied earlier" },
            .committed_file_presentation = .{
                .path = "src/main.zig",
                .kind = .edited,
                .lines = &.{.{ .kind = .addition, .old_line = null, .new_line = 7, .text = "+hello" }},
                .additions = 1,
                .deletions = 0,
                .truncated = false,
                .previous_content = "before",
                .after_content = "after",
                .lifecycle_id = .{ .turn_id = 9, .call_id = "c1" },
            },
            .command_replay_ref = "cmd-handle",
            .command_replay_bytes = 2048,
            .command_process_presentation = .{ .exit_code = 0 },
            .terminal_action_presentation = .{ .returned = .{ .exited = 0 } },
        } },
    });
    try encodeDecodeRoundtrip(alloc, .{
        .seq = 6,
        .timestamp_ms = 6,
        .event = .{ .turn_completed = .{
            .files = &.{.{
                .path = @constCast("src/a.zig"),
                .new_path = @constCast("src/b.zig"),
                .tool_call_id = @constCast("c1"),
                .tool_name = @constCast("edit"),
                .action = .edit,
                .status = .success,
                .model_view_covers_full_file = true,
                .stale = false,
            }},
            .turn_summary = .{
                .started_at_ms = 10,
                .completed_at_ms = 20,
                .thinking_duration_ms = 3,
                .turn_duration_ms = 10,
                .token_progress = .{
                    .input_tokens = 100,
                    .output_tokens = 50,
                    .input_exact = true,
                    .output_exact = false,
                },
            },
        } },
    });
    try encodeDecodeRoundtrip(alloc, .{
        .seq = 7,
        .timestamp_ms = 7,
        .event = .{ .interrupted = .{
            .reason = .cancelled,
            .partial_text = "partial",
            .command_replay_ref = "h",
            .command_replay_bytes = 7,
            .command_artifact_ref = "a",
            .files = &.{},
            .turn_summary = null,
            .cancellation_origin = .compaction,
        } },
    });
    try encodeDecodeRoundtrip(alloc, .{
        .seq = 8,
        .timestamp_ms = 8,
        .event = .{ .context_checkpoint = .{
            .covers_through_seq = 7,
            .summary = "summary text",
        } },
    });
    try encodeDecodeRoundtrip(alloc, sampleEnvelope(9));
}

test "history snapshot codec rejects truncated and corrupt payloads" {
    const alloc = std.testing.allocator;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    try encodeFramePayload(&payload, alloc, sampleEnvelope(1), 0, 10, 7);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var cursor = ByteCursor{ .bytes = payload.items[0 .. payload.items.len - 3] };
    try std.testing.expectError(error.InvalidCache, decodeAny(session_event.ConversationEnvelope, arena.allocator(), &cursor));

    cursor = .{ .bytes = payload.items };
    _ = try cursor.takeInt();
    _ = try cursor.takeInt();
    _ = try cursor.takeInt();
    const decoded = try decodeAny(session_event.ConversationEnvelope, arena.allocator(), &cursor);
    try std.testing.expectEqual(@as(u64, 1), decoded.seq);
}

test "history snapshot verify, cursor, and watermark authority" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var verified_dir: io_mod.VerifiedDir = .{ .dir = tmp.dir };

    // Two steering events at log offsets 0 and 10.
    const line1 = "{\"seq\":1}\n";
    const line2 = "{\"seq\":2}\n";
    {
        var file = try tmp.dir.createFile(std.testing.io, "events.jsonl", .{ .read = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, line1);
        try file.writeStreamingAll(std.testing.io, line2);
    }
    var log_file = try tmp.dir.openFile(std.testing.io, "events.jsonl", .{});
    defer log_file.close(std.testing.io);
    const log_len = try log_file.length(std.testing.io);

    var writer = try Writer.beginReplace(alloc, &verified_dir, "sess-1");
    writer.append(sampleEnvelope(1), 0, line1.len, std.hash.Crc32.hash(line1));
    writer.append(sampleEnvelope(2), line1.len, line2.len, std.hash.Crc32.hash(line2));
    writer.finalize();

    var verified = (try openAndVerify(alloc, &verified_dir, "sess-1", log_file, log_len)).?;
    defer verified.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 2), verified.last_seq);
    try std.testing.expectEqual(log_len, verified.covered_log_bytes);

    var cursor = Cursor{ .file = verified.file, .frames = verified.frames };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const first = (try cursor.next(arena.allocator())).?;
    try std.testing.expectEqual(@as(u64, 1), first.seq);
    try std.testing.expectEqualStrings("keep going", first.event.steering.text);
    try cursor.seekLogOffset(line1.len);
    const second = (try cursor.next(arena.allocator())).?;
    try std.testing.expectEqual(@as(u64, 2), second.seq);
    try std.testing.expect((try cursor.next(arena.allocator())) == null);

    // Wrong session id, a shrunk log, and a rewritten tail all invalidate.
    try std.testing.expect((try openAndVerify(alloc, &verified_dir, "sess-2", log_file, log_len)) == null);
    try std.testing.expect((try openAndVerify(alloc, &verified_dir, "sess-1", log_file, log_len - 1)) == null);
    {
        var mutable = try tmp.dir.openFile(std.testing.io, "events.jsonl", .{ .mode = .read_write });
        defer mutable.close(std.testing.io);
        try mutable.writePositionalAll(std.testing.io, "X", log_len - 2);
    }
    try std.testing.expect((try openAndVerify(alloc, &verified_dir, "sess-1", log_file, log_len)) == null);
}

test "history snapshot verification tolerates a torn tail as a shorter prefix" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var verified_dir: io_mod.VerifiedDir = .{ .dir = tmp.dir };

    const line1 = "{\"seq\":1}\n";
    {
        var file = try tmp.dir.createFile(std.testing.io, "events.jsonl", .{ .read = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, line1);
    }
    var log_file = try tmp.dir.openFile(std.testing.io, "events.jsonl", .{});
    defer log_file.close(std.testing.io);
    const log_len = try log_file.length(std.testing.io);

    var writer = try Writer.beginReplace(alloc, &verified_dir, "sess-1");
    writer.append(sampleEnvelope(1), 0, line1.len, std.hash.Crc32.hash(line1));
    // Simulate a torn second frame: a plausible frame header with no payload.
    const fake: [8]u8 = .{ 0, 64, 0, 0, 1, 2, 3, 4 };
    const file = writer.file.?;
    try file.writePositionalAll(std.testing.io, &fake, writer.len);
    writer.finalize();

    var verified = (try openAndVerify(alloc, &verified_dir, "sess-1", log_file, log_len)).?;
    defer verified.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), verified.frames.len);
    try std.testing.expectEqual(@as(u64, 1), verified.last_seq);
}
