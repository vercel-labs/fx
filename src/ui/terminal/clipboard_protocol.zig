//! Reads a clipboard image through the terminal with the kitty clipboard
//! protocol, OSC 5522: https://sw.kovidgoyal.net/kitty/clipboard/
//!
//! fx reads the clipboard itself only in a local macOS session. Over SSH, and
//! on Linux, only the terminal can reach the user's clipboard, so fx asks it
//! for `image/png` and decodes the reply from the input stream. A DECRQM query
//! for mode 5522 goes first, so a terminal that lacks the protocol says so at
//! once instead of leaving fx to wait for a reply that never comes.
//!
//! `theme_monitor.Monitor` sees every terminal reply first and reports where a
//! clipboard reply starts. `Reader` then owns the packet bytes that follow and
//! the state of the one outstanding request.
//!
//! The input stream keeps its order, so a network stall inside a reply delays
//! the keys typed after it too; nothing lands inside a reply. The theme
//! monitor holds a reply start through a stall of up to
//! `packet_idle_timeout_ms`, then drops it with its rest (`holdsReplyStart`):
//! a start that can only be a clipboard reply, and, while a request is open,
//! any start of two bytes or more. A stall right after a reply's ESC, or after
//! `ESC [`, which start the Escape and arrow keys, is handled like any other
//! partial terminal reply: after the monitor's short timeout those bytes reach
//! fx as keys.

const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const io_mod = @import("../../core/shared/io.zig");

const Allocator = std.mem.Allocator;

/// `image/png` in base64, the encoding the protocol uses for MIME types.
const png_mime_base64 = "aW1hZ2UvcG5n";
const mode_query = "\x1b[?5522$p";
const packet_prefix = "\x1b]5522;";
const mode_report_prefix = "\x1b[?5522;";

/// The bytes fx writes to ask the terminal for the clipboard image.
pub const image_read_request = mode_query ++ packet_prefix ++ "type=read;" ++ png_mime_base64 ++ "\x1b\\";

/// How long fx waits for the answer to its mode query: one round trip, which
/// over SSH can take a while. A terminal that ignores DECRQM, such as tmux,
/// is reported unsupported when it ends.
pub const mode_report_timeout_ms: i64 = 2_000;
/// How long fx waits for the reply once the terminal reports the protocol.
/// The terminal may first ask the user to allow the read.
pub const reply_timeout_ms: i64 = 60_000;
/// The longest pause between two packets of one transfer.
pub const transfer_idle_timeout_ms: i64 = 5_000;
/// The longest pause inside one packet. The reader owns all input until the
/// packet ends, so this bounds how long a broken reply can hold the keyboard.
pub const packet_idle_timeout_ms: i64 = 1_000;
/// A DATA packet carries at most 4096 decoded bytes, 5464 in base64, and a
/// short metadata section.
const max_packet_bytes: usize = 8 * 1024;

pub const ModeSupport = enum { supported, unsupported };

const ReplyStart = union(enum) {
    /// Not a clipboard reply.
    none,
    /// May still become a clipboard reply.
    pending,
    /// A packet starts. Its body and terminator follow.
    packet,
    /// The terminal answered the mode query.
    mode: ModeSupport,
};

/// Classifies terminal input that starts with ESC, as it grows one byte at a
/// time.
pub fn classifyReplyStart(candidate: []const u8) ReplyStart {
    if (std.mem.startsWith(u8, packet_prefix, candidate)) {
        return if (candidate.len == packet_prefix.len) .packet else .pending;
    }
    if (std.mem.startsWith(u8, mode_report_prefix, candidate)) return .pending;
    if (!std.mem.startsWith(u8, candidate, mode_report_prefix)) return .none;

    // DECRPM is `CSI ? 5522 ; Ps $ y`. A Ps of 0 or 4 means the terminal
    // does not have the mode.
    const rest = candidate[mode_report_prefix.len..];
    if (!std.ascii.isDigit(rest[0])) return .none;
    if (rest.len == 1) return .pending;
    if (rest[1] != '$') return .none;
    if (rest.len == 2) return .pending;
    if (rest.len != 3 or rest[2] != 'y') return .none;
    return .{ .mode = switch (rest[0]) {
        '1', '2', '3' => .supported,
        else => .unsupported,
    } };
}

/// Whether a candidate that `classifyReplyStart` holds as pending can only be
/// a clipboard reply: `ESC ] 55` or `ESC [ ? 55` and on. A shorter start may
/// still be a key, such as Escape or Alt+], or another reply, such as OSC 52
/// or the primary device attributes, so the theme monitor treats it like any
/// other partial reply.
pub fn replyStartIsCertain(candidate: []const u8) bool {
    if (candidate.len >= 4 and std.mem.startsWith(u8, packet_prefix, candidate[0..4])) return true;
    return candidate.len >= 5 and std.mem.startsWith(u8, mode_report_prefix, candidate[0..5]);
}

/// Whether the theme monitor holds a partial clipboard reply through a stall
/// of up to `packet_idle_timeout_ms`, then drops it, instead of typing it
/// after its short timeout. A certain start is always held. While a request
/// is open, `ESC ]`, `ESC [ ?`, and longer starts are held too, so Alt+]
/// pressed then is lost. A lone ESC and `ESC [`, which start the Escape and
/// arrow keys, are never held.
pub fn holdsReplyStart(candidate: []const u8, request_open: bool) bool {
    if (classifyReplyStart(candidate) != .pending) return false;
    if (replyStartIsCertain(candidate)) return true;
    return request_open and candidate.len >= 2 and !std.mem.eql(u8, candidate, "\x1b[");
}

pub const Outcome = union(enum) {
    /// The PNG bytes the terminal sent.
    image: std.ArrayList(u8),
    /// The clipboard holds no PNG.
    no_image,
    /// The terminal cannot read the clipboard for fx.
    unsupported,
    /// The user or the system refused the read.
    denied,
    /// The terminal was busy, for example with another client.
    busy,
    /// The terminal reported the protocol but sent no complete reply in time.
    timed_out,
    /// The image is larger than the reader's limit, or than fx could hold.
    too_large,
    /// The reply broke the protocol.
    malformed,

    pub fn deinit(self: *Outcome, alloc: Allocator) void {
        switch (self.*) {
            .image => |*bytes| bytes.deinit(alloc),
            else => {},
        }
        self.* = undefined;
    }
};

const Phase = union(enum) {
    idle,
    /// The request is out and the mode report has not come. Holds the deadline.
    awaiting_mode: i64,
    /// The terminal reports the protocol; its status packet has not come.
    awaiting_reply: i64,
    /// The terminal sent `OK`. DATA packets follow until `DONE`.
    receiving: i64,
    /// The transfer failed and its outcome is set; later packets of it are
    /// consumed until it ends.
    discarding: i64,
};

/// Who takes input bytes before the theme monitor and the composer.
const InputOwner = enum {
    none,
    /// A packet started; every byte up to its terminator is the reader's.
    packet,
    /// A packet, or the start of a reply, timed out. Bytes that can be its
    /// late rest are dropped until its terminator, a byte that cannot be
    /// reply text, or the packet size. It has no timer: the rest comes
    /// whenever the network delivers it, and a timer would let a longer stall
    /// type it into the composer
    /// (`tests/tla/clipboard_protocol/ClipboardRead.tla`, mutation
    /// `resync_timeout`).
    resync,
};

const Packet = struct {
    kind: []const u8,
    status: []const u8,
    mime: ?[]const u8,
    payload: []const u8,
};

/// Owns one clipboard request at a time. The App's input runtime holds it;
/// call `poll` on every loop turn and take the outcome when it is set.
pub const Reader = struct {
    phase: Phase = .idle,
    max_image_bytes: usize = 0,
    image: std.ArrayList(u8) = .empty,
    packet: std.ArrayList(u8) = .empty,
    owner: InputOwner = .none,
    /// When a packet that owns input gives it up for lack of bytes.
    owner_deadline_ms: i64 = 0,
    packet_escape: bool = false,
    packet_invalid: bool = false,
    resync_dropped_bytes: usize = 0,
    outcome: ?Outcome = null,

    pub fn deinit(self: *Reader, alloc: Allocator) void {
        if (self.image.items.len > 0) {
            debug_trace.logf("clipboard", "clipboard image dropped bytes={d} reason=shutdown", .{self.image.items.len});
        }
        self.image.deinit(alloc);
        self.packet.deinit(alloc);
        if (self.outcome) |*outcome| outcome.deinit(alloc);
        self.* = .{};
    }

    /// Whether a request is outstanding, its outcome is unread, or the rest
    /// of a failed transfer is still arriving.
    pub fn pending(self: *const Reader) bool {
        return self.phase != .idle or self.outcome != null;
    }

    /// Starts a request. The caller then writes `image_read_request`.
    pub fn begin(self: *Reader, now_ms: i64, max_image_bytes: usize) error{RequestPending}!void {
        if (self.pending()) return error.RequestPending;
        self.max_image_bytes = max_image_bytes;
        self.phase = .{ .awaiting_mode = io_mod.addMillis(now_ms, mode_report_timeout_ms) };
    }

    /// Ends a request whose bytes could not be written.
    pub fn cancel(self: *Reader) void {
        std.debug.assert(self.phase == .awaiting_mode);
        self.phase = .idle;
    }

    pub fn noteModeReport(self: *Reader, alloc: Allocator, support: ModeSupport, now_ms: i64) void {
        switch (self.phase) {
            .awaiting_mode => switch (support) {
                .supported => self.phase = .{ .awaiting_reply = io_mod.addMillis(now_ms, reply_timeout_ms) },
                .unsupported => self.finish(alloc, .unsupported),
            },
            else => debug_trace.logf(
                "clipboard",
                "clipboard mode report ignored support={s} phase={s}",
                .{ @tagName(support), @tagName(self.phase) },
            ),
        }
    }

    /// Whether the reader takes input bytes before anything else: a packet has
    /// started and not ended, or the late rest of a timed-out packet may still
    /// come. No byte of a reply after its first few reaches the composer
    /// (`tests/tla/clipboard_protocol/ClipboardRead.tla` NoReplyInComposer).
    pub fn ownsInput(self: *const Reader) bool {
        return self.owner != .none;
    }

    /// The theme monitor dropped the start of a reply that stalled for
    /// `packet_idle_timeout_ms` (`replyStartIsCertain`). Its rest may still
    /// come, so it is dropped like the rest of a stalled packet, and the open
    /// request ends (`tests/tla/clipboard_protocol/ClipboardRead.tla`
    /// StartTimeout).
    pub fn dropReplyStart(self: *Reader, alloc: Allocator, now_ms: i64) void {
        if (self.owner != .none) return;
        self.owner = .resync;
        self.resync_dropped_bytes = 0;
        self.fail(alloc, .timed_out, now_ms);
    }

    /// Starts a packet after its prefix, which the theme monitor consumed.
    pub fn beginPacket(self: *Reader, alloc: Allocator, now_ms: i64) void {
        std.debug.assert(self.owner == .none);
        self.owner = .packet;
        self.packet_escape = false;
        self.packet_invalid = false;
        self.packet.clearRetainingCapacity();
        self.packet.ensureTotalCapacity(alloc, max_packet_bytes) catch {
            debug_trace.logf("clipboard", "clipboard packet buffer unavailable reason=out_of_memory", .{});
            self.packet_invalid = true;
        };
        self.owner_deadline_ms = io_mod.addMillis(now_ms, packet_idle_timeout_ms);
    }

    /// Takes one input byte while `ownsInput`. Returns false when the byte is
    /// not the reader's, which ends a resync; the caller then routes it as
    /// ordinary input.
    pub fn feedOwnedByte(self: *Reader, alloc: Allocator, byte: u8, now_ms: i64) bool {
        switch (self.owner) {
            .none => unreachable,
            .packet => {
                self.feedPacketByte(alloc, byte, now_ms);
                return true;
            },
            .resync => return self.feedResyncByte(byte),
        }
    }

    /// Applies the deadlines.
    pub fn poll(self: *Reader, alloc: Allocator, now_ms: i64) void {
        switch (self.owner) {
            .none => {},
            .packet => {
                if (now_ms < self.owner_deadline_ms) return;
                debug_trace.logf(
                    "clipboard",
                    "clipboard packet dropped bytes={d} reason=idle_timeout",
                    .{self.packet.items.len},
                );
                self.packet.clearRetainingCapacity();
                // The terminal writes a packet in one piece, so its rest may
                // still come after a network stall
                // (`tests/tla/clipboard_protocol/ClipboardRead.tla` PacketTimeout).
                self.owner = .resync;
                self.resync_dropped_bytes = 0;
                self.fail(alloc, .timed_out, now_ms);
                return;
            },
            .resync => {},
        }
        switch (self.phase) {
            .idle => {},
            .awaiting_mode => |deadline_ms| if (now_ms >= deadline_ms) {
                debug_trace.logf("clipboard", "clipboard mode report missing", .{});
                self.finish(alloc, .unsupported);
            },
            .awaiting_reply => |deadline_ms| if (now_ms >= deadline_ms) {
                self.finish(alloc, .timed_out);
            },
            // The rest of a stalled transfer may still come; `fail` consumes
            // it until it ends.
            .receiving => |deadline_ms| if (now_ms >= deadline_ms) {
                self.fail(alloc, .timed_out, now_ms);
            },
            .discarding => |deadline_ms| if (now_ms >= deadline_ms) {
                self.phase = .idle;
            },
        }
    }

    pub fn takeOutcome(self: *Reader) ?Outcome {
        const outcome = self.outcome orelse return null;
        self.outcome = null;
        return outcome;
    }

    /// Takes one byte of the current packet. BEL or `ESC \` ends it.
    fn feedPacketByte(self: *Reader, alloc: Allocator, byte: u8, now_ms: i64) void {
        self.owner_deadline_ms = io_mod.addMillis(now_ms, packet_idle_timeout_ms);
        if (self.packet_escape) {
            self.packet_escape = false;
            if (byte != '\\') {
                debug_trace.logf(
                    "clipboard",
                    "clipboard packet ended byte=0x{x:0>2} reason=escape_inside_packet",
                    .{byte},
                );
                self.packet_invalid = true;
            }
            return self.endPacket(alloc, now_ms);
        }
        switch (byte) {
            0x1b => self.packet_escape = true,
            0x07 => self.endPacket(alloc, now_ms),
            else => {
                if (self.packet_invalid) return;
                if (self.packet.items.len == max_packet_bytes) {
                    debug_trace.logf("clipboard", "clipboard packet too long limit={d}", .{max_packet_bytes});
                    self.packet_invalid = true;
                    return;
                }
                self.packet.appendAssumeCapacity(byte);
            },
        }
    }

    /// Drops a byte that can be the late rest of a timed-out reply. A BEL
    /// ends the packet and is dropped too. Any other byte, ESC included, ends
    /// the resync and stays ordinary input: the decoder ignores a bare `ESC \`.
    fn feedResyncByte(self: *Reader, byte: u8) bool {
        if (byte == 0x07) {
            self.resync_dropped_bytes += 1;
            self.endResync("terminator");
            return true;
        }
        if (!isReplyTextByte(byte)) {
            self.endResync("other_byte");
            return false;
        }
        self.resync_dropped_bytes += 1;
        if (self.resync_dropped_bytes == max_packet_bytes) self.endResync("packet_size");
        return true;
    }

    fn endResync(self: *Reader, reason: []const u8) void {
        std.debug.assert(self.owner == .resync);
        debug_trace.logf(
            "clipboard",
            "clipboard resync ended dropped_bytes={d} reason={s}",
            .{ self.resync_dropped_bytes, reason },
        );
        self.owner = .none;
        self.resync_dropped_bytes = 0;
    }

    fn endPacket(self: *Reader, alloc: Allocator, now_ms: i64) void {
        self.owner = .none;
        defer self.packet.clearRetainingCapacity();
        if (self.packet_invalid) return self.fail(alloc, .malformed, now_ms);
        const packet = parsePacket(self.packet.items) orelse {
            debug_trace.logf("clipboard", "clipboard packet unreadable bytes={d}", .{self.packet.items.len});
            return self.fail(alloc, .malformed, now_ms);
        };
        if (!std.mem.eql(u8, packet.kind, "read")) {
            debug_trace.logf("clipboard", "clipboard packet ignored reason=not_a_read_reply", .{});
            return;
        }
        self.applyReadPacket(alloc, packet, now_ms);
    }

    fn applyReadPacket(self: *Reader, alloc: Allocator, packet: Packet, now_ms: i64) void {
        const status = packet.status;
        const continues = std.mem.eql(u8, status, "OK") or std.mem.eql(u8, status, "DATA");
        switch (self.phase) {
            .idle => {
                debug_trace.logf(
                    "clipboard",
                    "clipboard packet dropped status={s} reason=no_request",
                    .{traceStatus(status)},
                );
                return;
            },
            .discarding => {
                self.phase = if (continues) .{ .discarding = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) } else .idle;
                return;
            },
            .awaiting_mode, .awaiting_reply, .receiving => {},
        }

        if (std.mem.eql(u8, status, "OK")) {
            if (self.phase == .receiving) return self.fail(alloc, .malformed, now_ms);
            self.phase = .{ .receiving = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) };
        } else if (std.mem.eql(u8, status, "DATA")) {
            if (self.phase != .receiving) return self.fail(alloc, .malformed, now_ms);
            self.phase = .{ .receiving = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) };
            // fx asks only for PNG; a terminal may still send other types.
            const mime = packet.mime orelse return;
            if (!std.mem.eql(u8, mime, png_mime_base64)) return;
            self.appendData(alloc, packet.payload, now_ms);
        } else if (std.mem.eql(u8, status, "DONE")) {
            if (self.image.items.len == 0) return self.finish(alloc, .no_image);
            const image = self.image;
            self.image = .empty;
            self.finish(alloc, .{ .image = image });
        } else if (std.mem.eql(u8, status, "EPERM")) {
            self.finish(alloc, .denied);
        } else if (std.mem.eql(u8, status, "EBUSY")) {
            self.finish(alloc, .busy);
        } else if (std.mem.eql(u8, status, "ENOSYS")) {
            self.finish(alloc, .unsupported);
        } else {
            debug_trace.logf("clipboard", "clipboard packet unknown status_bytes={d}", .{status.len});
            self.fail(alloc, .malformed, now_ms);
        }
    }

    fn appendData(self: *Reader, alloc: Allocator, payload: []const u8, now_ms: i64) void {
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(payload) catch return self.fail(alloc, .malformed, now_ms);
        if (size > self.max_image_bytes - self.image.items.len) return self.fail(alloc, .too_large, now_ms);
        self.image.ensureUnusedCapacity(alloc, size) catch {
            debug_trace.logf("clipboard", "clipboard image buffer unavailable bytes={d} reason=out_of_memory", .{size});
            return self.fail(alloc, .too_large, now_ms);
        };
        const start = self.image.items.len;
        decoder.decode(self.image.unusedCapacitySlice()[0..size], payload) catch {
            return self.fail(alloc, .malformed, now_ms);
        };
        self.image.items.len = start + size;
    }

    /// Ends a request that has no more packets to come.
    fn finish(self: *Reader, alloc: Allocator, outcome: Outcome) void {
        std.debug.assert(self.outcome == null);
        self.phase = .idle;
        self.image.clearAndFree(alloc);
        self.packet.clearAndFree(alloc);
        self.outcome = outcome;
    }

    /// Ends a request in the middle of its transfer. Later packets of the
    /// transfer are consumed until it ends.
    fn fail(self: *Reader, alloc: Allocator, outcome: Outcome, now_ms: i64) void {
        switch (self.phase) {
            .idle, .discarding => return,
            .awaiting_mode, .awaiting_reply, .receiving => {},
        }
        if (self.image.items.len > 0) {
            debug_trace.logf(
                "clipboard",
                "clipboard image dropped bytes={d} reason={s}",
                .{ self.image.items.len, @tagName(outcome) },
            );
        }
        self.finish(alloc, outcome);
        self.phase = .{ .discarding = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) };
    }
};

/// Parses a packet body, the bytes between the prefix and the terminator:
/// colon-separated `key=value` metadata, then `;` and the payload.
fn parsePacket(body: []const u8) ?Packet {
    const split = std.mem.findScalar(u8, body, ';');
    const metadata = if (split) |index| body[0..index] else body;
    var kind: ?[]const u8 = null;
    var status: []const u8 = "";
    var mime: ?[]const u8 = null;
    var fields = std.mem.splitScalar(u8, metadata, ':');
    while (fields.next()) |field| {
        const equals = std.mem.findScalar(u8, field, '=') orelse return null;
        const key = field[0..equals];
        const value = field[equals + 1 ..];
        if (std.mem.eql(u8, key, "type")) {
            kind = value;
        } else if (std.mem.eql(u8, key, "status")) {
            status = value;
        } else if (std.mem.eql(u8, key, "mime")) {
            mime = value;
        }
    }
    return .{
        .kind = kind orelse return null,
        .status = status,
        .mime = mime,
        .payload = if (split) |index| body[index + 1 ..] else "",
    };
}

/// Whether `byte` can appear in the rest of a reply: a packet body's base64
/// and `key=value` metadata, or a mode report's `5522;2$y`.
fn isReplyTextByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '+', '/', '=', ':', ';', '_', '-', '$' => true,
        else => false,
    };
}

/// The statuses the protocol defines. The terminal sends the status, so a
/// trace line names only one of these, never the raw bytes.
const known_statuses = [_][]const u8{ "OK", "DATA", "DONE", "EPERM", "EBUSY", "ENOSYS" };

fn traceStatus(status: []const u8) []const u8 {
    for (known_statuses) |known| {
        if (std.mem.eql(u8, status, known)) return known;
    }
    return "unknown";
}

const testing = std.testing;
const testing_allocator = @import("../../core/shared/testing_allocator.zig");
const test_png = "\x89PNG\r\n\x1a\n" ++ "clipboard image bytes";

/// Classifies `bytes` the way the theme monitor does: one byte at a time,
/// stopping at the first prefix that is no longer pending.
fn classifyAll(bytes: []const u8) ReplyStart {
    for (1..bytes.len) |len| {
        const partial = classifyReplyStart(bytes[0..len]);
        if (partial != .pending) return partial;
    }
    return classifyReplyStart(bytes);
}

/// Delivers one packet the way the input loop does: the prefix goes to the
/// theme monitor, and the body and terminator to the reader.
fn deliverPacket(reader: *Reader, body: []const u8, terminator: []const u8, now_ms: i64) void {
    reader.beginPacket(testing.allocator, now_ms);
    // A packet takes every byte, so the result is always true here.
    for (body) |byte| _ = reader.feedOwnedByte(testing.allocator, byte, now_ms);
    for (terminator) |byte| _ = reader.feedOwnedByte(testing.allocator, byte, now_ms);
}

fn deliverData(reader: *Reader, chunk: []const u8, now_ms: i64) !void {
    var encoded: [256]u8 = undefined;
    const payload = std.base64.standard.Encoder.encode(&encoded, chunk);
    var body: [320]u8 = undefined;
    const text = try std.mem.print(&body, "type=read:status=DATA:mime={s};{s}", .{ png_mime_base64, payload });
    deliverPacket(reader, text, "\x1b\\", now_ms);
}

fn expectOutcome(reader: *Reader, expected: std.meta.Tag(Outcome)) !void {
    var outcome = reader.takeOutcome() orelse return error.TestExpectedOutcome;
    defer outcome.deinit(testing.allocator);
    try testing.expectEqual(expected, std.meta.activeTag(outcome));
}

test "classifyReplyStart recognizes packets and mode reports one byte at a time" {
    try testing.expectEqual(ReplyStart.packet, classifyAll(packet_prefix));
    try testing.expectEqual(ReplyStart{ .mode = .supported }, classifyAll("\x1b[?5522;2$y"));
    try testing.expectEqual(ReplyStart{ .mode = .supported }, classifyAll("\x1b[?5522;1$y"));
    try testing.expectEqual(ReplyStart{ .mode = .supported }, classifyAll("\x1b[?5522;3$y"));
    try testing.expectEqual(ReplyStart{ .mode = .unsupported }, classifyAll("\x1b[?5522;0$y"));
    try testing.expectEqual(ReplyStart{ .mode = .unsupported }, classifyAll("\x1b[?5522;4$y"));
}

test "classifyReplyStart leaves other terminal input alone" {
    const others = [_][]const u8{
        "\x1b[?62;22;52c",
        "\x1b]11;rgb:ffff/ffff/ffff\x07",
        "\x1b]52;c;dGV4dA==\x07",
        "\x1b[?5522;22$y",
        "\x1b[?5522;2$x",
        "\x1b[?5522;x",
        "\x1b[A",
    };
    for (others) |bytes| {
        try testing.expectEqual(ReplyStart.none, classifyAll(bytes));
    }
}

test "only a reply start that no key or other reply shares is certain" {
    for ([_][]const u8{ "\x1b]55", "\x1b]5522", "\x1b[?55", "\x1b[?5522;2$" }) |start| {
        try testing.expect(replyStartIsCertain(start));
    }
    for ([_][]const u8{ "\x1b", "\x1b]", "\x1b]5", "\x1b[", "\x1b[?", "\x1b[?5" }) |start| {
        try testing.expect(!replyStartIsCertain(start));
    }
}

test "a clipboard reply start is held while a request is open, unless a key starts it" {
    try testing.expect(holdsReplyStart("\x1b]55", false));
    try testing.expect(!holdsReplyStart("\x1b]5", false));
    for ([_][]const u8{ "\x1b]", "\x1b]5", "\x1b[?", "\x1b[?5", "\x1b]55" }) |start| {
        try testing.expect(holdsReplyStart(start, true));
    }
    for ([_][]const u8{ "\x1b", "\x1b[", "\x1b[A", "\x1b[?6" }) |start| {
        try testing.expect(!holdsReplyStart(start, true));
    }
}

test "the image read request asks for the mode and for image/png" {
    try testing.expectEqualStrings("\x1b[?5522$p\x1b]5522;type=read;aW1hZ2UvcG5n\x1b\\", image_read_request);
    var decoded: [16]u8 = undefined;
    const size = try std.base64.standard.Decoder.calcSizeForSlice(png_mime_base64);
    try std.base64.standard.Decoder.decode(decoded[0..size], png_mime_base64);
    try testing.expectEqualStrings("image/png", decoded[0..size]);
}

test "reader assembles a chunked image and releases input after each packet" {
    var reader: Reader = .{};
    defer reader.deinit(testing.allocator);
    try reader.begin(0, 1024);
    reader.noteModeReport(testing.allocator, .supported, 5);

    reader.beginPacket(testing.allocator, 10);
    for ("type=read:status=OK") |byte| {
        try testing.expect(reader.ownsInput());
        try testing.expect(reader.feedOwnedByte(testing.allocator, byte, 10));
    }
    try testing.expect(reader.feedOwnedByte(testing.allocator, 0x07, 11));
    try testing.expect(!reader.ownsInput());
    try testing.expect(reader.pending());

    try deliverData(&reader, test_png[0..7], 12);
    try deliverData(&reader, test_png[7..], 13);
    deliverPacket(&reader, "type=read:status=DONE", "\x07", 14);

    var outcome = reader.takeOutcome().?;
    defer outcome.deinit(testing.allocator);
    try testing.expectEqualStrings(test_png, outcome.image.items);
    try testing.expect(!reader.pending());
}

test "reader maps empty and refused replies to their outcomes" {
    const cases = [_]struct { status: []const u8, outcome: std.meta.Tag(Outcome), ok_first: bool }{
        .{ .status = "DONE", .outcome = .no_image, .ok_first = true },
        .{ .status = "EPERM", .outcome = .denied, .ok_first = false },
        .{ .status = "EBUSY", .outcome = .busy, .ok_first = false },
        .{ .status = "ENOSYS", .outcome = .unsupported, .ok_first = false },
    };
    for (cases) |case| {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        try reader.begin(0, 1024);
        reader.noteModeReport(testing.allocator, .supported, 1);
        if (case.ok_first) deliverPacket(&reader, "type=read:status=OK", "\x1b\\", 2);
        var body: [64]u8 = undefined;
        deliverPacket(&reader, try std.mem.print(&body, "type=read:status={s}", .{case.status}), "\x1b\\", 3);
        try expectOutcome(&reader, case.outcome);
        try testing.expect(!reader.pending());
    }
}

test "reader reports a terminal without the protocol" {
    var refused: Reader = .{};
    defer refused.deinit(testing.allocator);
    try refused.begin(0, 1024);
    refused.noteModeReport(testing.allocator, .unsupported, 1);
    try expectOutcome(&refused, .unsupported);

    var silent: Reader = .{};
    defer silent.deinit(testing.allocator);
    try silent.begin(0, 1024);
    silent.poll(testing.allocator, mode_report_timeout_ms - 1);
    try testing.expect(silent.takeOutcome() == null);
    silent.poll(testing.allocator, mode_report_timeout_ms);
    try expectOutcome(&silent, .unsupported);
}

test "reader waits for a permission prompt and then times out" {
    var reader: Reader = .{};
    defer reader.deinit(testing.allocator);
    try reader.begin(0, 1024);
    reader.noteModeReport(testing.allocator, .supported, 100);
    reader.poll(testing.allocator, 100 + reply_timeout_ms - 1);
    try testing.expect(reader.takeOutcome() == null);
    reader.poll(testing.allocator, 100 + reply_timeout_ms);
    try expectOutcome(&reader, .timed_out);
}

test "reader allows one request at a time" {
    var reader: Reader = .{};
    defer reader.deinit(testing.allocator);
    try reader.begin(0, 1024);
    try testing.expectError(error.RequestPending, reader.begin(1, 1024));
    reader.noteModeReport(testing.allocator, .unsupported, 2);
    try testing.expectError(error.RequestPending, reader.begin(3, 1024));
    try expectOutcome(&reader, .unsupported);
    try reader.begin(4, 1024);
    reader.cancel();
    try testing.expect(!reader.pending());
}

test "reader rejects an image over its limit and consumes the rest of the transfer" {
    var reader: Reader = .{};
    defer reader.deinit(testing.allocator);
    try reader.begin(0, 8);
    reader.noteModeReport(testing.allocator, .supported, 1);
    deliverPacket(&reader, "type=read:status=OK", "\x1b\\", 2);
    try deliverData(&reader, test_png[0..6], 3);
    try deliverData(&reader, test_png[6..12], 4);
    try expectOutcome(&reader, .too_large);

    // The rest of the transfer is consumed without a second outcome.
    try deliverData(&reader, test_png[12..], 5);
    try testing.expect(reader.pending());
    deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 6);
    try testing.expect(reader.takeOutcome() == null);
    try testing.expect(!reader.pending());
}

test "reader reports broken replies as malformed" {
    const bodies = [_][]const u8{
        "type=read:status=DATA:mime=" ++ png_mime_base64 ++ ";not base64!",
        "type=read:status=WHAT",
        "type=read:status",
        "status=OK",
    };
    for (bodies) |body| {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        try reader.begin(0, 1024);
        reader.noteModeReport(testing.allocator, .supported, 1);
        deliverPacket(&reader, "type=read:status=OK", "\x1b\\", 2);
        deliverPacket(&reader, body, "\x1b\\", 3);
        try expectOutcome(&reader, .malformed);
        reader.poll(testing.allocator, 3 + transfer_idle_timeout_ms);
        try testing.expect(!reader.pending());
    }
}

test "reader ends a packet at a stray escape and keeps the packet bounded" {
    var stray: Reader = .{};
    defer stray.deinit(testing.allocator);
    try stray.begin(0, 1024);
    stray.noteModeReport(testing.allocator, .supported, 1);
    stray.beginPacket(testing.allocator, 2);
    for ("type=read:status=OK\x1b[") |byte| try testing.expect(stray.feedOwnedByte(testing.allocator, byte, 2));
    try testing.expect(!stray.ownsInput());
    try expectOutcome(&stray, .malformed);

    var long: Reader = .{};
    defer long.deinit(testing.allocator);
    try long.begin(0, 1024 * 1024);
    long.noteModeReport(testing.allocator, .supported, 1);
    long.beginPacket(testing.allocator, 2);
    for (0..max_packet_bytes * 2) |_| try testing.expect(long.feedOwnedByte(testing.allocator, 'A', 2));
    try testing.expect(long.ownsInput());
    try testing.expectEqual(max_packet_bytes, long.packet.items.len);
    try testing.expect(long.feedOwnedByte(testing.allocator, 0x07, 3));
    try testing.expect(!long.ownsInput());
    try expectOutcome(&long, .malformed);
}

/// Starts a transfer and stops one DATA packet halfway, as a network stall
/// over SSH does, then lets the packet time out.
fn stallMidPacket(reader: *Reader) !void {
    try reader.begin(0, 1024);
    reader.noteModeReport(testing.allocator, .supported, 1);
    deliverPacket(reader, "type=read:status=OK", "\x1b\\", 2);
    reader.beginPacket(testing.allocator, 3);
    for ("type=read:status=DA") |byte| try testing.expect(reader.feedOwnedByte(testing.allocator, byte, 3));
    reader.poll(testing.allocator, 3 + packet_idle_timeout_ms - 1);
    try testing.expect(reader.ownsInput());
    reader.poll(testing.allocator, 3 + packet_idle_timeout_ms);
    try expectOutcome(reader, .timed_out);
}

test "the late rest of a stalled packet never reaches the composer" {
    var reader: Reader = .{};
    defer reader.deinit(testing.allocator);
    try stallMidPacket(&reader);

    const now = 3 + packet_idle_timeout_ms + 1;
    for ("TA:mime=" ++ png_mime_base64 ++ ";iVBORw0KGgo=") |byte| {
        try testing.expect(reader.feedOwnedByte(testing.allocator, byte, now));
    }
    try testing.expect(reader.feedOwnedByte(testing.allocator, 0x07, now));
    try testing.expect(!reader.ownsInput());
}

test "a stalled packet gives up input at the first byte that is not packet text" {
    var reader: Reader = .{};
    defer reader.deinit(testing.allocator);
    try stallMidPacket(&reader);

    const now = 3 + packet_idle_timeout_ms + 1;
    // ESC starts either the packet's `ESC \` or a key; both stay ordinary input.
    try testing.expect(!reader.feedOwnedByte(testing.allocator, 0x1b, now));
    try testing.expect(!reader.ownsInput());
}

test "the rest of a stalled packet is dropped however late it comes" {
    var reader: Reader = .{};
    defer reader.deinit(testing.allocator);
    try stallMidPacket(&reader);

    const much_later = 3 + packet_idle_timeout_ms + reply_timeout_ms * 10;
    reader.poll(testing.allocator, much_later);
    try testing.expect(reader.ownsInput());
    for ("TA;iVBORw0KGgo=") |byte| try testing.expect(reader.feedOwnedByte(testing.allocator, byte, much_later));
    try testing.expect(reader.feedOwnedByte(testing.allocator, 0x07, much_later));
    try testing.expect(!reader.ownsInput());
}

test "a stalled packet drops at most one packet of late bytes" {
    var reader: Reader = .{};
    defer reader.deinit(testing.allocator);
    try stallMidPacket(&reader);

    const now = 3 + packet_idle_timeout_ms + 1;
    for (0..max_packet_bytes) |_| try testing.expect(reader.feedOwnedByte(testing.allocator, 'A', now));
    try testing.expect(!reader.ownsInput());
}

test "a dropped reply start ends the request and drops the rest of its packet" {
    var reader: Reader = .{};
    defer reader.deinit(testing.allocator);
    try reader.begin(0, 1024);
    reader.noteModeReport(testing.allocator, .supported, 1);
    reader.dropReplyStart(testing.allocator, 1 + packet_idle_timeout_ms);
    try expectOutcome(&reader, .timed_out);

    const now = 2 + packet_idle_timeout_ms;
    for ("22;type=read:status=OK") |byte| try testing.expect(reader.feedOwnedByte(testing.allocator, byte, now));
    try testing.expect(!reader.feedOwnedByte(testing.allocator, 0x1b, now));
    try testing.expect(!reader.ownsInput());

    // The later packets of the transfer give no second outcome.
    try deliverData(&reader, test_png, now + 1);
    deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", now + 2);
    try testing.expect(reader.takeOutcome() == null);
    try testing.expect(!reader.pending());
}

test "a dropped mode report start drops the rest of the report" {
    var reader: Reader = .{};
    defer reader.deinit(testing.allocator);
    try reader.begin(0, 1024);
    reader.dropReplyStart(testing.allocator, packet_idle_timeout_ms);
    try expectOutcome(&reader, .timed_out);
    for ("22;2$y") |byte| try testing.expect(reader.feedOwnedByte(testing.allocator, byte, packet_idle_timeout_ms + 1));
    try testing.expect(!reader.feedOwnedByte(testing.allocator, '\r', packet_idle_timeout_ms + 2));
    try testing.expect(!reader.ownsInput());
}

test "a transfer that stalls between packets consumes its late packets" {
    var reader: Reader = .{};
    defer reader.deinit(testing.allocator);
    try reader.begin(0, 1024);
    reader.noteModeReport(testing.allocator, .supported, 1);
    deliverPacket(&reader, "type=read:status=OK", "\x1b\\", 2);
    reader.poll(testing.allocator, 2 + transfer_idle_timeout_ms);
    try expectOutcome(&reader, .timed_out);

    // A new request waits for the old transfer, whose late packets give no
    // outcome.
    const late = 3 + transfer_idle_timeout_ms;
    try testing.expectError(error.RequestPending, reader.begin(late, 1024));
    try deliverData(&reader, test_png, late + 1);
    deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", late + 2);
    try testing.expect(reader.takeOutcome() == null);
    try testing.expect(!reader.pending());
}

test "reader consumes a reply that arrives without a request" {
    var reader: Reader = .{};
    defer reader.deinit(testing.allocator);
    deliverPacket(&reader, "type=read:status=OK", "\x1b\\", 0);
    try deliverData(&reader, test_png, 1);
    deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 2);
    reader.noteModeReport(testing.allocator, .supported, 3);
    try testing.expect(!reader.ownsInput());
    try testing.expect(!reader.pending());
}

test "reader skips data of a type it did not ask for" {
    var reader: Reader = .{};
    defer reader.deinit(testing.allocator);
    try reader.begin(0, 1024);
    reader.noteModeReport(testing.allocator, .supported, 1);
    deliverPacket(&reader, "type=read:status=OK", "\x1b\\", 2);
    deliverPacket(&reader, "type=read:status=DATA:mime=dGV4dC9wbGFpbg==;aGVsbG8=", "\x1b\\", 3);
    deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 4);
    try expectOutcome(&reader, .no_image);
}

test "reader reports allocation failure without leaking" {
    // The packet buffer is allocation 0; the image buffer is allocation 1.
    var failing = std.testing.FailingAllocator.init(testing_allocator.no_resize, .{ .fail_index = 1 });
    const alloc = failing.allocator();
    var reader: Reader = .{};
    defer reader.deinit(alloc);
    try reader.begin(0, 1024);
    reader.noteModeReport(alloc, .supported, 1);
    reader.beginPacket(alloc, 2);
    for ("type=read:status=OK") |byte| try testing.expect(reader.feedOwnedByte(alloc, byte, 2));
    try testing.expect(reader.feedOwnedByte(alloc, 0x07, 2));

    var encoded: [64]u8 = undefined;
    const payload = std.base64.standard.Encoder.encode(&encoded, test_png);
    reader.beginPacket(alloc, 3);
    for ("type=read:status=DATA:mime=" ++ png_mime_base64 ++ ";") |byte| try testing.expect(reader.feedOwnedByte(alloc, byte, 3));
    for (payload) |byte| try testing.expect(reader.feedOwnedByte(alloc, byte, 3));
    try testing.expect(reader.feedOwnedByte(alloc, 0x07, 3));

    var outcome = reader.takeOutcome().?;
    defer outcome.deinit(alloc);
    try testing.expectEqual(Outcome.too_large, std.meta.activeTag(outcome));
}

test "the clipboard reader stays bounded and gives one outcome per request on fuzzed terminal input" {
    try std.testing.fuzz({}, fuzzReaderOnTerminalInput, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "\x1b[?5522;2$y\x1b]5522;type=read:status=OK\x1b\\\x1b]5522;type=read:status=DATA:mime=" ++
                png_mime_base64 ++ ";iVBORw0KGgo=\x1b\\\x1b]5522;type=read:status=DONE\x1b\\",
            "\x1b[?5522;0$y",
            "\x1b[?5522;2$y\x1b]5522;type=read:status=EPERM\x07",
            "\x1b[?5522;2$y\x1b]5522;type=read:status=OK\x07\x1b]5522;type=read:status=DA\x00TA;AAAA\x07abc",
            "\x16\x1b]5522;type=read:status=DATA:mime=" ++ png_mime_base64 ++ ";!!!!\x1b\\\x16",
            "\x1b]5522;\x1b[A\x00\x1b[?5522;2$y\x16",
            "\x1b[?5522;2$y\x1b]55\x0022;type=read:status=OK\x1b\\abc\x16\x1b[?55\x0022;2$y\r",
            "\x1b[?5522;2$y\x1b]5\x00522;type=read:status=OK\x1b\\\x1b]\x005522;\x07\x1b[?\x00\r",
        }) ++ @import("fuzz_corpus").terminal_clipboard_reply.*),
    });
}

/// The bytes that reach fx while one request is open. A NUL stands for a
/// pause longer than every deadline, and Ctrl+V asks again when no request
/// is pending, as the input loop does.
fn fuzzReaderOnTerminalInput(_: void, smith: *std.testing.Smith) !void {
    var input: [2048]u8 = undefined;
    const len: usize = smith.slice(&input);
    const max_image_bytes = 64;
    var drive: FuzzDrive = .{ .max_image_bytes = max_image_bytes };
    defer drive.reader.deinit(testing.allocator);
    try drive.reader.begin(drive.now_ms, max_image_bytes);
    drive.requests = 1;

    for (input[0..len]) |byte| {
        if (byte == 0) {
            drive.pause();
            drive.now_ms += reply_timeout_ms + 1;
        } else {
            drive.now_ms += 1;
            try drive.route(byte);
        }
        try drive.settle();
    }
    // A long silence ends every request. A packet that timed out leaves a
    // resync, which the next key that cannot be packet text ends.
    for (0..3) |_| {
        drive.pause();
        drive.now_ms += reply_timeout_ms + 1;
        try drive.settle();
    }
    if (drive.reader.ownsInput()) {
        try testing.expectEqual(InputOwner.resync, drive.reader.owner);
        try testing.expect(!drive.reader.feedOwnedByte(testing.allocator, ' ', drive.now_ms));
    }
    try testing.expect(!drive.reader.ownsInput());
    try testing.expect(!drive.reader.pending());
    try testing.expectEqual(drive.requests, drive.outcomes);
}

/// Routes input as `App.loopHandleByte` does: the reader first while it owns
/// input, then the theme monitor's prefix match, then the composer.
const FuzzDrive = struct {
    reader: Reader = .{},
    max_image_bytes: usize,
    now_ms: i64 = 0,
    requests: usize = 0,
    outcomes: usize = 0,
    candidate: [16]u8 = undefined,
    candidate_len: usize = 0,
    /// The theme monitor holds the candidate through a stall
    /// (`holdsReplyStart`), decided as each byte arrives.
    candidate_held: bool = false,

    fn route(self: *FuzzDrive, byte: u8) !void {
        if (self.reader.ownsInput() and self.reader.feedOwnedByte(testing.allocator, byte, self.now_ms)) return;
        if (self.candidate_len == 0 and byte != 0x1b) return self.typed(byte);
        const clipboard_start = replyStartIsCertain(self.candidate[0..self.candidate_len]);
        self.candidate[self.candidate_len] = byte;
        self.candidate_len += 1;
        self.candidate_held = holdsReplyStart(self.candidate[0..self.candidate_len], self.reader.pending());
        switch (classifyReplyStart(self.candidate[0..self.candidate_len])) {
            .pending => if (self.candidate_len == self.candidate.len) self.flushCandidate(),
            .packet => {
                self.candidate_len = 0;
                self.reader.beginPacket(testing.allocator, self.now_ms);
            },
            .mode => |support| {
                self.candidate_len = 0;
                self.reader.noteModeReport(testing.allocator, support, self.now_ms);
            },
            .none => {
                self.flushCandidate();
                // The theme monitor drops a broken clipboard reply start and
                // reads the byte on its own.
                if (!clipboard_start) return;
                if (byte != 0x1b) return self.typed(byte);
                self.candidate[0] = byte;
                self.candidate_len = 1;
                self.candidate_held = false;
            },
        }
    }

    fn typed(self: *FuzzDrive, byte: u8) !void {
        if (byte != 0x16 or self.reader.pending()) return;
        try self.reader.begin(self.now_ms, self.max_image_bytes);
        self.requests += 1;
    }

    /// The theme monitor hands a partial reply on as keys when it stops
    /// matching.
    fn flushCandidate(self: *FuzzDrive) void {
        self.candidate_len = 0;
    }

    /// A pause past every deadline. The theme monitor drops a held reply
    /// start, and the reader then drops its rest; it types any other start.
    fn pause(self: *FuzzDrive) void {
        if (self.candidate_len > 0 and self.candidate_held) {
            self.reader.dropReplyStart(testing.allocator, self.now_ms + packet_idle_timeout_ms);
        }
        self.candidate_len = 0;
    }

    fn settle(self: *FuzzDrive) !void {
        self.reader.poll(testing.allocator, self.now_ms);
        if (self.reader.takeOutcome()) |taken| {
            var outcome = taken;
            outcome.deinit(testing.allocator);
            self.outcomes += 1;
        }
        try testing.expect(self.outcomes <= self.requests);
        try testing.expect(self.requests <= self.outcomes + 1);
        try testing.expect(self.reader.image.items.len <= self.max_image_bytes);
        try testing.expect(self.reader.packet.items.len <= max_packet_bytes);
        try testing.expect(self.reader.resync_dropped_bytes < max_packet_bytes);
    }
};
