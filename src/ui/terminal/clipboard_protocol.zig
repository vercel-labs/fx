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
const text_utf8_mime_base64 = "dGV4dC9wbGFpbjtjaGFyc2V0PXV0Zi04";
const text_mime_base64 = "dGV4dC9wbGFpbg==";
const listing_mime_base64 = "Lg==";
const paste_event_name_base64 = "UGFzdGUgZXZlbnQ=";
const mode_query = "\x1b[?5522$p";
const packet_prefix = "\x1b]5522;";
const mode_report_prefix = "\x1b[?5522;";

/// Maximum decoded password bytes accepted on a paste-event listing.
pub const max_paste_password_bytes: usize = 128;
/// Maximum decoded MIME-list bytes accepted on a paste-event listing.
pub const max_paste_mime_list_bytes: usize = 4096;

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

pub const PasteLocation = enum {
    clipboard,
    primary,
};

pub const PasteMime = enum {
    png,
    text_utf8,
    text,
};

fn mimeBase64(mime: PasteMime) []const u8 {
    return switch (mime) {
        .png => png_mime_base64,
        .text_utf8 => text_utf8_mime_base64,
        .text => text_mime_base64,
    };
}

/// Picks the preferred MIME type from an ASCII-whitespace-separated list:
/// `text/plain;charset=utf-8`, then `text/plain`, then `image/png` only when
/// `image_allowed` is true.
pub fn pickPasteMime(mimes: []const u8, image_allowed: bool) ?PasteMime {
    var has_png = false;
    var has_text_utf8 = false;
    var has_text = false;
    var index: usize = 0;
    while (index < mimes.len) {
        while (index < mimes.len and std.ascii.isWhitespace(mimes[index])) : (index += 1) {}
        if (index == mimes.len) break;
        const start = index;
        while (index < mimes.len and !std.ascii.isWhitespace(mimes[index])) : (index += 1) {}
        const token = mimes[start..index];
        if (std.mem.eql(u8, token, "text/plain;charset=utf-8")) {
            has_text_utf8 = true;
        } else if (std.mem.eql(u8, token, "text/plain")) {
            has_text = true;
        } else if (image_allowed and std.mem.eql(u8, token, "image/png")) {
            has_png = true;
        }
    }
    if (has_text_utf8) return .text_utf8;
    if (has_text) return .text;
    if (has_png) return .png;
    return null;
}

/// Writes an OSC 5522 follow-up read request for a kitty paste event.
pub fn writePasteReadRequest(
    writer: *std.Io.Writer,
    password: []const u8,
    location: PasteLocation,
    mime: PasteMime,
) std.Io.Writer.Error!void {
    try writer.writeAll(packet_prefix);
    try writer.writeAll("type=read");
    if (location == .primary) try writer.writeAll(":loc=primary");
    if (password.len > 0) {
        try writer.writeAll(":pw=");
        const chunk_cap = 3 * 32;
        var b64_buf: [std.base64.standard.Encoder.calcSize(chunk_cap)]u8 = undefined;
        defer std.crypto.secureZero(u8, &b64_buf);
        var raw_offset: usize = 0;
        while (raw_offset < password.len) {
            const chunk_len = @min(chunk_cap, password.len - raw_offset);
            const encoded = std.base64.standard.Encoder.encode(
                &b64_buf,
                password[raw_offset .. raw_offset + chunk_len],
            );
            try writer.writeAll(encoded);
            raw_offset += chunk_len;
        }
    }
    try writer.writeAll(":name=");
    try writer.writeAll(paste_event_name_base64);
    try writer.writeByte(';');
    try writer.writeAll(mimeBase64(mime));
    try writer.writeAll("\x1b\\");
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

/// Decoded metadata from an unsolicited OSC 5522 paste-event listing.
/// Caller owns `password` and `mimes` and must release them with `deinit`.
pub const PasteEvent = struct {
    password: std.ArrayList(u8),
    location: PasteLocation,
    mimes: std.ArrayList(u8),

    pub fn deinit(self: *PasteEvent, alloc: Allocator) void {
        if (self.password.capacity > 0) {
            std.crypto.secureZero(u8, self.password.allocatedSlice());
        }
        self.password.deinit(alloc);
        self.mimes.deinit(alloc);
        self.* = undefined;
    }
};

pub const PasteEventOutcome = union(enum) {
    paste_event: PasteEvent,
    busy,
    timed_out,
    malformed,

    pub fn deinit(self: *PasteEventOutcome, alloc: Allocator) void {
        switch (self.*) {
            .paste_event => |*event| event.deinit(alloc),
            else => {},
        }
        self.* = undefined;
    }
};

pub const TextOutcome = union(enum) {
    /// The decoded text bytes the terminal sent.
    text: std.ArrayList(u8),
    /// The clipboard holds no text for the requested MIME type.
    no_text,
    /// The terminal cannot read the clipboard for fx.
    unsupported,
    /// The user or the system refused the read.
    denied,
    /// The terminal was busy, for example with another client.
    busy,
    /// The terminal reported the protocol but sent no complete reply in time.
    timed_out,
    /// The text is larger than the reader's limit, or than fx could hold.
    too_large,
    /// The reply broke the protocol.
    malformed,

    pub fn deinit(self: *TextOutcome, alloc: Allocator) void {
        switch (self.*) {
            .text => |*bytes| {
                if (bytes.capacity > 0) {
                    std.crypto.secureZero(u8, bytes.allocatedSlice());
                }
                bytes.deinit(alloc);
            },
            else => {},
        }
        self.* = undefined;
    }
};

const RequestKind = enum {
    image,
    text,
};

const RequestError = enum {
    unsupported,
    denied,
    busy,
    timed_out,
    too_large,
    malformed,

    fn toImageOutcome(self: RequestError) Outcome {
        return switch (self) {
            .unsupported => .unsupported,
            .denied => .denied,
            .busy => .busy,
            .timed_out => .timed_out,
            .too_large => .too_large,
            .malformed => .malformed,
        };
    }

    fn toTextOutcome(self: RequestError) TextOutcome {
        return switch (self) {
            .unsupported => .unsupported,
            .denied => .denied,
            .busy => .busy,
            .timed_out => .timed_out,
            .too_large => .too_large,
            .malformed => .malformed,
        };
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
    /// Unsolicited `OK` arrived while idle; collecting `DATA:mime=Lg==` and `DONE`.
    listing: i64,
    /// The transfer failed and its outcome is set; later packets of it are
    /// consumed until it ends.
    discarding: i64,
};

const BusyListing = union(enum) {
    none,
    /// Bare `OK` arrived during `.receiving`; confirmed as a busy listing if
    /// `DATA:mime=Lg==` follows, or fails the open transfer otherwise.
    tentative: i64,
    /// Listing packets are consumed without disturbing the open request
    /// (`tests/tla/clipboard_protocol/PasteEvents.tla` `OneRequestAtATime`).
    confirmed: i64,
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
    loc: ?[]const u8,
    pw: ?[]const u8,
    payload: []const u8,
};

/// Owns one clipboard request at a time. The App's input runtime holds it;
/// call `poll` on every loop turn and take the outcome when it is set.
pub const Reader = struct {
    phase: Phase = .idle,
    request_kind: RequestKind = .image,
    request_mime: PasteMime = .png,
    max_payload_bytes: usize = 0,
    payload: std.ArrayList(u8) = .empty,
    /// When a bare `OK` arrives in `.awaiting_mode` or `.awaiting_reply`, save
    /// that phase until the first `DATA` reveals whether it is our reply or a
    /// passwordless paste-event listing.
    saved_awaiting_phase: ?Phase = null,
    listing_has_pw: bool = false,
    listing_location: PasteLocation = .clipboard,
    listing_loc_invalid: bool = false,
    listing_saw_mime_list: bool = false,
    listing_password: std.ArrayList(u8) = .empty,
    listing_mimes: std.ArrayList(u8) = .empty,
    busy_listing: BusyListing = .none,
    packet: std.ArrayList(u8) = .empty,
    owner: InputOwner = .none,
    /// When a packet that owns input gives it up for lack of bytes.
    owner_deadline_ms: i64 = 0,
    packet_escape: bool = false,
    packet_invalid: bool = false,
    resync_dropped_bytes: usize = 0,
    outcome: ?Outcome = null,
    text_outcome: ?TextOutcome = null,
    paste_event_outcome: ?PasteEventOutcome = null,

    pub fn deinit(self: *Reader, alloc: Allocator) void {
        if (self.payload.items.len > 0) {
            debug_trace.logf(
                "clipboard",
                "clipboard payload dropped bytes={d} kind={s} reason=shutdown",
                .{ self.payload.items.len, @tagName(self.request_kind) },
            );
        }
        zeroAndDeinitList(&self.payload, alloc);
        zeroAndDeinitList(&self.listing_password, alloc);
        self.listing_mimes.deinit(alloc);
        zeroAndDeinitList(&self.packet, alloc);
        if (self.outcome) |*outcome| outcome.deinit(alloc);
        if (self.text_outcome) |*outcome| outcome.deinit(alloc);
        if (self.paste_event_outcome) |*outcome| outcome.deinit(alloc);
        self.* = .{};
    }

    /// Whether a request is outstanding, an outcome is unread, or the rest of
    /// a failed transfer is still arriving.
    pub fn pending(self: *const Reader) bool {
        return self.phase != .idle or
            self.outcome != null or
            self.text_outcome != null or
            self.paste_event_outcome != null or
            self.busy_listing != .none;
    }

    /// Starts an image read request. The caller then writes `image_read_request`.
    pub fn begin(self: *Reader, now_ms: i64, max_image_bytes: usize) error{RequestPending}!void {
        if (self.pending()) return error.RequestPending;
        self.request_kind = .image;
        self.request_mime = .png;
        self.max_payload_bytes = max_image_bytes;
        self.saved_awaiting_phase = null;
        self.phase = .{ .awaiting_mode = io_mod.addMillis(now_ms, mode_report_timeout_ms) };
    }

    /// Starts an image read request for a paste-event follow-up read, skipping
    /// the DECRQM mode query because the listing already proved mode 5522 is on.
    pub fn beginPasteImage(self: *Reader, now_ms: i64, max_image_bytes: usize) error{RequestPending}!void {
        if (self.pending()) return error.RequestPending;
        self.request_kind = .image;
        self.request_mime = .png;
        self.max_payload_bytes = max_image_bytes;
        self.saved_awaiting_phase = null;
        self.phase = .{ .awaiting_reply = io_mod.addMillis(now_ms, reply_timeout_ms) };
    }

    /// Starts a text read request (such as a paste-event follow-up read, which
    /// skips the DECRQM mode query and waits directly for the reply).
    pub fn beginText(self: *Reader, now_ms: i64, max_text_bytes: usize, mime: PasteMime) error{RequestPending}!void {
        std.debug.assert(mime != .png);
        if (self.pending()) return error.RequestPending;
        self.request_kind = .text;
        self.request_mime = mime;
        self.max_payload_bytes = max_text_bytes;
        self.saved_awaiting_phase = null;
        self.phase = .{ .awaiting_reply = io_mod.addMillis(now_ms, reply_timeout_ms) };
    }

    /// Ends a request whose bytes could not be written.
    pub fn cancel(self: *Reader) void {
        std.debug.assert(self.phase == .awaiting_mode or self.phase == .awaiting_reply);
        self.phase = .idle;
        self.saved_awaiting_phase = null;
        self.request_kind = .image;
        self.request_mime = .png;
        self.max_payload_bytes = 0;
    }

    pub fn noteModeReport(self: *Reader, alloc: Allocator, support: ModeSupport, now_ms: i64) void {
        switch (self.phase) {
            .awaiting_mode => switch (support) {
                .supported => self.phase = .{ .awaiting_reply = io_mod.addMillis(now_ms, reply_timeout_ms) },
                .unsupported => self.finishRequestError(alloc, .unsupported),
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
        self.failCurrent(alloc, .timed_out, now_ms);
    }

    /// Starts a packet after its prefix, which the theme monitor consumed.
    pub fn beginPacket(self: *Reader, alloc: Allocator, now_ms: i64) void {
        std.debug.assert(self.owner == .none);
        self.owner = .packet;
        self.packet_escape = false;
        self.packet_invalid = false;
        zeroAndClearList(&self.packet);
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
                zeroAndClearList(&self.packet);
                // The terminal writes a packet in one piece, so its rest may
                // still come after a network stall
                // (`tests/tla/clipboard_protocol/ClipboardRead.tla` PacketTimeout).
                self.owner = .resync;
                self.resync_dropped_bytes = 0;
                self.failCurrent(alloc, .timed_out, now_ms);
                return;
            },
            .resync => {},
        }
        switch (self.busy_listing) {
            .none => {},
            .tentative => |deadline_ms| if (now_ms >= deadline_ms) {
                self.busy_listing = .none;
            },
            .confirmed => |deadline_ms| if (now_ms >= deadline_ms) {
                self.busy_listing = .none;
                self.finishPasteEvent(alloc, .busy);
            },
        }
        switch (self.phase) {
            .idle => {},
            .awaiting_mode => |deadline_ms| if (now_ms >= deadline_ms) {
                debug_trace.logf("clipboard", "clipboard mode report missing", .{});
                self.finishRequestError(alloc, .unsupported);
            },
            .awaiting_reply => |deadline_ms| if (now_ms >= deadline_ms) {
                self.finishRequestError(alloc, .timed_out);
            },
            // The rest of a stalled transfer may still come; `failRequest`
            // consumes it until it ends.
            .receiving => |deadline_ms| if (now_ms >= deadline_ms) {
                self.failRequest(alloc, .timed_out, now_ms);
            },
            .listing => |deadline_ms| if (now_ms >= deadline_ms) {
                if (self.listing_has_pw or self.listing_saw_mime_list) {
                    self.failListing(alloc, .timed_out, now_ms);
                } else {
                    debug_trace.logf("clipboard", "clipboard packet dropped status=OK reason=no_request", .{});
                    self.resetListingState(alloc);
                    self.phase = .idle;
                }
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

    pub fn takeTextOutcome(self: *Reader) ?TextOutcome {
        const outcome = self.text_outcome orelse return null;
        self.text_outcome = null;
        return outcome;
    }

    pub fn takePasteEventOutcome(self: *Reader) ?PasteEventOutcome {
        const outcome = self.paste_event_outcome orelse return null;
        self.paste_event_outcome = null;
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
        defer zeroAndClearList(&self.packet);
        if (self.packet_invalid) return self.failCurrent(alloc, .malformed, now_ms);
        const packet = parsePacket(self.packet.items) orelse {
            debug_trace.logf("clipboard", "clipboard packet unreadable bytes={d}", .{self.packet.items.len});
            return self.failCurrent(alloc, .malformed, now_ms);
        };
        if (!std.mem.eql(u8, packet.kind, "read")) {
            debug_trace.logf("clipboard", "clipboard packet ignored reason=not_a_read_reply", .{});
            return;
        }
        self.applyReadPacket(alloc, packet, now_ms);
    }

    fn applyReadPacket(self: *Reader, alloc: Allocator, packet: Packet, now_ms: i64) void {
        const status = packet.status;
        if (self.consumeBusyListingPacket(alloc, packet, now_ms)) return;

        const continues = std.mem.eql(u8, status, "OK") or std.mem.eql(u8, status, "DATA");
        switch (self.phase) {
            .idle => {
                if (std.mem.eql(u8, status, "OK")) {
                    self.startListingFromIdle(alloc, packet, now_ms);
                    return;
                }
                debug_trace.logf(
                    "clipboard",
                    "clipboard packet dropped status={s} reason=no_request",
                    .{traceStatus(status)},
                );
                return;
            },
            .listing => {
                self.applyListingPacket(alloc, packet, continues, now_ms);
                return;
            },
            .discarding => {
                if (std.mem.eql(u8, status, "OK") and isExplicitListingStart(packet)) {
                    self.busy_listing = .{ .confirmed = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) };
                    return;
                }
                self.phase = if (continues) .{ .discarding = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) } else .idle;
                return;
            },
            .awaiting_mode, .awaiting_reply, .receiving => {},
        }

        if (std.mem.eql(u8, status, "OK")) {
            // An `OK` with `pw` or `loc` cannot be a Ctrl+V read reply, so treat
            // it as an incoming listing without disturbing the open request
            // (`tests/tla/clipboard_protocol/PasteEvents.tla` `OneRequestAtATime`).
            if (isExplicitListingStart(packet)) {
                self.busy_listing = .{ .confirmed = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) };
                return;
            }
            if (self.phase == .receiving) {
                self.busy_listing = .{ .tentative = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) };
                return;
            }
            self.saved_awaiting_phase = self.phase;
            self.phase = .{ .receiving = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) };
        } else if (std.mem.eql(u8, status, "DATA")) {
            if (self.phase != .receiving) {
                self.saved_awaiting_phase = null;
                return self.failRequest(alloc, .malformed, now_ms);
            }
            if (isListingData(packet) and self.saved_awaiting_phase != null and self.payload.items.len == 0) {
                // The preceding bare `OK` belonged to a passwordless listing;
                // restore the open request's phase and drop the listing as busy.
                self.phase = self.saved_awaiting_phase.?;
                self.saved_awaiting_phase = null;
                self.busy_listing = .{ .confirmed = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) };
                return;
            }
            self.saved_awaiting_phase = null;
            self.phase = .{ .receiving = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) };
            // fx asks only for one MIME; a terminal may still send other types.
            const mime = packet.mime orelse return;
            if (!std.mem.eql(u8, mime, mimeBase64(self.request_mime))) return;
            self.appendData(alloc, packet.payload, now_ms);
        } else if (std.mem.eql(u8, status, "DONE")) {
            self.saved_awaiting_phase = null;
            self.finishRequestDone(alloc);
        } else if (std.mem.eql(u8, status, "EPERM")) {
            self.finishRequestError(alloc, .denied);
        } else if (std.mem.eql(u8, status, "EBUSY")) {
            self.finishRequestError(alloc, .busy);
        } else if (std.mem.eql(u8, status, "ENOSYS")) {
            self.finishRequestError(alloc, .unsupported);
        } else {
            debug_trace.logf("clipboard", "clipboard packet unknown status_bytes={d}", .{status.len});
            self.failRequest(alloc, .malformed, now_ms);
        }
    }

    fn consumeBusyListingPacket(self: *Reader, alloc: Allocator, packet: Packet, now_ms: i64) bool {
        switch (self.busy_listing) {
            .none => return false,
            .tentative => {
                if (isListingData(packet)) {
                    self.busy_listing = .{ .confirmed = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) };
                    return true;
                }
                self.busy_listing = .none;
                self.failRequest(alloc, .malformed, now_ms);
                return true;
            },
            .confirmed => {
                if (isListingData(packet)) {
                    self.busy_listing = .{ .confirmed = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) };
                    return true;
                }
                if (std.mem.eql(u8, packet.status, "DONE")) {
                    self.busy_listing = .none;
                    self.finishPasteEvent(alloc, .busy);
                    return true;
                }
                return false;
            },
        }
    }

    fn startListingFromIdle(self: *Reader, alloc: Allocator, packet: Packet, now_ms: i64) void {
        self.resetListingState(alloc);
        const location = parsePasteLocation(packet.loc);
        if (packet.pw) |pw_b64| {
            self.listing_has_pw = true;
            const loc = location orelse {
                self.failListing(alloc, .malformed, now_ms);
                return;
            };
            self.listing_location = loc;
            var pw_buf: [max_paste_password_bytes]u8 = undefined;
            defer std.crypto.secureZero(u8, &pw_buf);
            const pw_len = decodeBoundedBase64(&pw_buf, pw_b64) orelse {
                self.failListing(alloc, .malformed, now_ms);
                return;
            };
            self.listing_password.appendSlice(alloc, pw_buf[0..pw_len]) catch {
                debug_trace.logf("clipboard", "paste password buffer unavailable reason=out_of_memory", .{});
                self.failListing(alloc, .malformed, now_ms);
                return;
            };
        } else {
            self.listing_has_pw = false;
            if (location) |loc| {
                self.listing_location = loc;
            } else {
                self.listing_loc_invalid = true;
            }
        }
        self.phase = .{ .listing = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) };
    }

    fn applyListingPacket(self: *Reader, alloc: Allocator, packet: Packet, continues: bool, now_ms: i64) void {
        const status = packet.status;
        if (packet.pw) |pw_b64| {
            if (!self.listingMatchesPassword(pw_b64)) {
                if (continues) {
                    self.failListing(alloc, .malformed, now_ms);
                } else {
                    self.finishListing(alloc, .malformed);
                }
                return;
            }
        }

        if (std.mem.eql(u8, status, "OK")) {
            if (isExplicitListingStart(packet)) {
                self.busy_listing = .{ .confirmed = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) };
                return;
            }
            if (!self.listing_has_pw and !self.listing_saw_mime_list) {
                debug_trace.logf("clipboard", "clipboard packet dropped status=OK reason=no_request", .{});
                self.resetListingState(alloc);
                self.phase = .idle;
                self.startListingFromIdle(alloc, packet, now_ms);
                return;
            }
            self.failListing(alloc, .malformed, now_ms);
            return;
        }

        if (std.mem.eql(u8, status, "DATA")) {
            if (!isListingData(packet)) {
                if (!self.listing_has_pw and !self.listing_saw_mime_list) {
                    debug_trace.logf("clipboard", "clipboard packet dropped status=OK reason=no_request", .{});
                    debug_trace.logf("clipboard", "clipboard packet dropped status=DATA reason=no_request", .{});
                    self.resetListingState(alloc);
                    self.phase = .idle;
                    return;
                }
                self.phase = .{ .listing = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) };
                return;
            }
            if (self.listing_loc_invalid) {
                self.failListing(alloc, .malformed, now_ms);
                return;
            }
            self.listing_saw_mime_list = true;
            self.phase = .{ .listing = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) };
            self.appendListingMimeData(alloc, packet.payload, now_ms);
            return;
        }

        if (std.mem.eql(u8, status, "DONE")) {
            if (!self.listing_has_pw and !self.listing_saw_mime_list) {
                debug_trace.logf("clipboard", "clipboard packet dropped status=OK reason=no_request", .{});
                debug_trace.logf("clipboard", "clipboard packet dropped status=DONE reason=no_request", .{});
                self.resetListingState(alloc);
                self.phase = .idle;
                return;
            }
            if (!self.listing_saw_mime_list) {
                self.finishListing(alloc, .malformed);
                return;
            }
            const password = self.listing_password;
            self.listing_password = .empty;
            const mimes = self.listing_mimes;
            self.listing_mimes = .empty;
            const location = self.listing_location;
            self.finishListing(alloc, .{ .paste_event = .{
                .password = password,
                .location = location,
                .mimes = mimes,
            } });
            return;
        }

        if (!self.listing_has_pw and !self.listing_saw_mime_list) {
            debug_trace.logf("clipboard", "clipboard packet dropped status=OK reason=no_request", .{});
            debug_trace.logf(
                "clipboard",
                "clipboard packet dropped status={s} reason=no_request",
                .{traceStatus(status)},
            );
            self.resetListingState(alloc);
            self.phase = .idle;
            return;
        }
        self.finishListing(alloc, .malformed);
    }

    fn listingMatchesPassword(self: *const Reader, pw_b64: []const u8) bool {
        if (!self.listing_has_pw) return false;
        var pw_buf: [max_paste_password_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &pw_buf);
        const pw_len = decodeBoundedBase64(&pw_buf, pw_b64) orelse return false;
        return std.mem.eql(u8, pw_buf[0..pw_len], self.listing_password.items);
    }

    fn appendListingMimeData(self: *Reader, alloc: Allocator, payload: []const u8, now_ms: i64) void {
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(payload) catch return self.failListing(alloc, .malformed, now_ms);
        if (size > max_paste_mime_list_bytes - self.listing_mimes.items.len) {
            return self.failListing(alloc, .malformed, now_ms);
        }
        self.listing_mimes.ensureUnusedCapacity(alloc, size) catch {
            debug_trace.logf("clipboard", "paste mime list buffer unavailable bytes={d} reason=out_of_memory", .{size});
            return self.failListing(alloc, .malformed, now_ms);
        };
        const start = self.listing_mimes.items.len;
        decoder.decode(self.listing_mimes.unusedCapacitySlice()[0..size], payload) catch {
            return self.failListing(alloc, .malformed, now_ms);
        };
        self.listing_mimes.items.len = start + size;
    }

    fn appendData(self: *Reader, alloc: Allocator, payload: []const u8, now_ms: i64) void {
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(payload) catch return self.failRequest(alloc, .malformed, now_ms);
        if (size > self.max_payload_bytes - self.payload.items.len) return self.failRequest(alloc, .too_large, now_ms);
        self.payload.ensureUnusedCapacity(alloc, size) catch {
            debug_trace.logf(
                "clipboard",
                "clipboard payload buffer unavailable bytes={d} kind={s} reason=out_of_memory",
                .{ size, @tagName(self.request_kind) },
            );
            return self.failRequest(alloc, .too_large, now_ms);
        };
        const start = self.payload.items.len;
        decoder.decode(self.payload.unusedCapacitySlice()[0..size], payload) catch {
            return self.failRequest(alloc, .malformed, now_ms);
        };
        self.payload.items.len = start + size;
    }

    fn finishRequestDone(self: *Reader, alloc: Allocator) void {
        if (self.payload.items.len == 0) {
            self.phase = .idle;
            self.saved_awaiting_phase = null;
            zeroAndFreeList(&self.payload, alloc);
            zeroAndFreeList(&self.packet, alloc);
            switch (self.request_kind) {
                .image => self.storeImageOutcome(alloc, .no_image),
                .text => self.storeTextOutcome(alloc, .no_text),
            }
            return;
        }
        const data = self.payload;
        self.payload = .empty;
        self.phase = .idle;
        self.saved_awaiting_phase = null;
        zeroAndFreeList(&self.packet, alloc);
        switch (self.request_kind) {
            .image => self.storeImageOutcome(alloc, .{ .image = data }),
            .text => self.storeTextOutcome(alloc, .{ .text = data }),
        }
    }

    fn finishRequestError(self: *Reader, alloc: Allocator, err: RequestError) void {
        self.phase = .idle;
        self.saved_awaiting_phase = null;
        zeroAndFreeList(&self.payload, alloc);
        zeroAndFreeList(&self.packet, alloc);
        switch (self.request_kind) {
            .image => self.storeImageOutcome(alloc, err.toImageOutcome()),
            .text => self.storeTextOutcome(alloc, err.toTextOutcome()),
        }
    }

    fn storeImageOutcome(self: *Reader, alloc: Allocator, outcome: Outcome) void {
        if (self.outcome != null) {
            var dropped = outcome;
            dropped.deinit(alloc);
            debug_trace.logf("clipboard", "clipboard outcome dropped reason=outcome_pending", .{});
            return;
        }
        self.outcome = outcome;
    }

    fn storeTextOutcome(self: *Reader, alloc: Allocator, outcome: TextOutcome) void {
        if (self.text_outcome != null) {
            var dropped = outcome;
            dropped.deinit(alloc);
            debug_trace.logf("clipboard", "clipboard text outcome dropped reason=outcome_pending", .{});
            return;
        }
        self.text_outcome = outcome;
    }

    fn failRequest(self: *Reader, alloc: Allocator, err: RequestError, now_ms: i64) void {
        switch (self.phase) {
            .idle, .discarding, .listing => return,
            .awaiting_mode, .awaiting_reply, .receiving => {},
        }
        if (self.payload.items.len > 0) {
            debug_trace.logf(
                "clipboard",
                "clipboard payload dropped bytes={d} kind={s} reason={s}",
                .{ self.payload.items.len, @tagName(self.request_kind), @tagName(err) },
            );
        }
        self.finishRequestError(alloc, err);
        self.phase = .{ .discarding = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) };
    }

    fn resetListingState(self: *Reader, alloc: Allocator) void {
        self.listing_has_pw = false;
        self.listing_location = .clipboard;
        self.listing_loc_invalid = false;
        self.listing_saw_mime_list = false;
        zeroAndFreeList(&self.listing_password, alloc);
        self.listing_mimes.clearAndFree(alloc);
    }

    fn finishPasteEvent(self: *Reader, alloc: Allocator, outcome: PasteEventOutcome) void {
        if (self.paste_event_outcome != null) {
            var dropped = outcome;
            dropped.deinit(alloc);
            debug_trace.logf("clipboard", "paste event outcome dropped reason=outcome_pending", .{});
            return;
        }
        self.paste_event_outcome = outcome;
    }

    fn finishListing(self: *Reader, alloc: Allocator, outcome: PasteEventOutcome) void {
        self.phase = .idle;
        self.resetListingState(alloc);
        zeroAndFreeList(&self.packet, alloc);
        self.finishPasteEvent(alloc, outcome);
    }

    fn failListing(self: *Reader, alloc: Allocator, outcome: PasteEventOutcome, now_ms: i64) void {
        if (self.listing_mimes.items.len > 0) {
            debug_trace.logf(
                "clipboard",
                "paste listing dropped bytes={d} reason={s}",
                .{ self.listing_mimes.items.len, @tagName(outcome) },
            );
        }
        self.finishListing(alloc, outcome);
        self.phase = .{ .discarding = io_mod.addMillis(now_ms, transfer_idle_timeout_ms) };
    }

    fn failCurrent(self: *Reader, alloc: Allocator, err: RequestError, now_ms: i64) void {
        switch (self.phase) {
            .idle, .discarding => {},
            .awaiting_mode, .awaiting_reply, .receiving => {
                if (self.busy_listing == .confirmed) {
                    self.busy_listing = .none;
                    self.finishPasteEvent(alloc, .busy);
                } else {
                    self.busy_listing = .none;
                }
                self.failRequest(alloc, err, now_ms);
            },
            .listing => {
                self.busy_listing = .none;
                if (self.listing_has_pw or self.listing_saw_mime_list) {
                    const paste_err: PasteEventOutcome = switch (err) {
                        .timed_out => .timed_out,
                        else => .malformed,
                    };
                    self.failListing(alloc, paste_err, now_ms);
                } else {
                    debug_trace.logf("clipboard", "clipboard packet dropped status=OK reason=no_request", .{});
                    self.resetListingState(alloc);
                    self.phase = .idle;
                }
            },
        }
    }
};

fn zeroAndClearList(list: *std.ArrayList(u8)) void {
    if (list.items.len > 0) std.crypto.secureZero(u8, list.items);
    list.clearRetainingCapacity();
}

fn zeroAndFreeList(list: *std.ArrayList(u8), alloc: Allocator) void {
    if (list.capacity > 0) std.crypto.secureZero(u8, list.allocatedSlice());
    list.clearAndFree(alloc);
}

fn zeroAndDeinitList(list: *std.ArrayList(u8), alloc: Allocator) void {
    if (list.capacity > 0) std.crypto.secureZero(u8, list.allocatedSlice());
    list.deinit(alloc);
}

fn parsePasteLocation(loc: ?[]const u8) ?PasteLocation {
    const value = loc orelse return .clipboard;
    if (std.mem.eql(u8, value, "primary")) return .primary;
    return null;
}

fn decodeBoundedBase64(out: []u8, encoded: []const u8) ?usize {
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return null;
    if (size > out.len) return null;
    decoder.decode(out[0..size], encoded) catch return null;
    return size;
}

fn isExplicitListingStart(packet: Packet) bool {
    return packet.pw != null or packet.loc != null;
}

fn isListingData(packet: Packet) bool {
    if (!std.mem.eql(u8, packet.status, "DATA")) return false;
    const mime = packet.mime orelse return false;
    return std.mem.eql(u8, mime, listing_mime_base64);
}

/// Parses a packet body, the bytes between the prefix and the terminator:
/// colon-separated `key=value` metadata, then `;` and the payload.
fn parsePacket(body: []const u8) ?Packet {
    const split = std.mem.findScalar(u8, body, ';');
    const metadata = if (split) |index| body[0..index] else body;
    var kind: ?[]const u8 = null;
    var status: []const u8 = "";
    var mime: ?[]const u8 = null;
    var loc: ?[]const u8 = null;
    var pw: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, key, "loc")) {
            loc = value;
        } else if (std.mem.eql(u8, key, "pw")) {
            pw = value;
        }
    }
    return .{
        .kind = kind orelse return null,
        .status = status,
        .mime = mime,
        .loc = loc,
        .pw = pw,
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
    try testing.expectEqual(drive.text_requests, drive.text_outcomes);
}

/// Routes input as `App.loopHandleByte` does: the reader first while it owns
/// input, then the theme monitor's prefix match, then the composer.
const FuzzDrive = struct {
    reader: Reader = .{},
    max_image_bytes: usize,
    max_text_bytes: usize = 128,
    now_ms: i64 = 0,
    requests: usize = 0,
    outcomes: usize = 0,
    text_requests: usize = 0,
    text_outcomes: usize = 0,
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
            defer outcome.deinit(testing.allocator);
            if (outcome == .image) {
                try testing.expect(outcome.image.items.len <= self.max_image_bytes);
            }
            self.outcomes += 1;
        }
        if (self.reader.takeTextOutcome()) |taken| {
            var outcome = taken;
            defer outcome.deinit(testing.allocator);
            if (outcome == .text) {
                try testing.expect(outcome.text.items.len <= self.max_text_bytes);
            }
            self.text_outcomes += 1;
        }
        if (self.reader.takePasteEventOutcome()) |taken| {
            var outcome = taken;
            defer outcome.deinit(testing.allocator);
            if (outcome == .paste_event) {
                const pe = &outcome.paste_event;
                try testing.expect(pe.password.items.len <= max_paste_password_bytes);
                try testing.expect(pe.mimes.items.len <= max_paste_mime_list_bytes);
                if (pickPasteMime(pe.mimes.items, true)) |mime| {
                    var req_buf: [512]u8 = undefined;
                    var w: std.Io.Writer = .fixed(&req_buf);
                    try writePasteReadRequest(&w, pe.password.items, pe.location, mime);
                    if (!self.reader.pending() and mime != .png) {
                        try self.reader.beginText(self.now_ms, self.max_text_bytes, mime);
                        self.text_requests += 1;
                    }
                }
            }
        }
        try testing.expect(self.outcomes <= self.requests);
        try testing.expect(self.requests <= self.outcomes + 1);
        try testing.expect(self.text_outcomes <= self.text_requests);
        try testing.expect(self.text_requests <= self.text_outcomes + 1);
        const max_payload = @max(self.max_image_bytes, self.max_text_bytes);
        try testing.expect(self.reader.payload.items.len <= max_payload);
        try testing.expect(self.reader.listing_mimes.items.len <= max_paste_mime_list_bytes);
        try testing.expect(self.reader.listing_password.items.len <= max_paste_password_bytes);
        try testing.expect(self.reader.packet.items.len <= max_packet_bytes);
        try testing.expect(self.reader.resync_dropped_bytes < max_packet_bytes);
    }
};

fn encodeBase64Alloc(alloc: Allocator, bytes: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(out, bytes);
    return out;
}

fn deliverMimeData(reader: *Reader, mime_b64: []const u8, chunk: []const u8, pw_suffix: []const u8, terminator: []const u8, now_ms: i64) !void {
    const payload = try encodeBase64Alloc(testing.allocator, chunk);
    defer testing.allocator.free(payload);
    const body = try testing.allocator.print(
        "type=read:status=DATA:mime={s}{s};{s}",
        .{ mime_b64, pw_suffix, payload },
    );
    defer testing.allocator.free(body);
    deliverPacket(reader, body, terminator, now_ms);
}

fn expectPasteEventOutcome(reader: *Reader, expected: std.meta.Tag(PasteEventOutcome)) !void {
    var outcome = reader.takePasteEventOutcome() orelse return error.TestExpectedOutcome;
    defer outcome.deinit(testing.allocator);
    try testing.expectEqual(expected, std.meta.activeTag(outcome));
}

fn expectTextOutcome(reader: *Reader, expected: std.meta.Tag(TextOutcome)) !void {
    var outcome = reader.takeTextOutcome() orelse return error.TestExpectedOutcome;
    defer outcome.deinit(testing.allocator);
    try testing.expectEqual(expected, std.meta.activeTag(outcome));
}

test "pickPasteMime selects by priority with exact ASCII whitespace tokens" {
    try testing.expectEqual(@as(?PasteMime, .text_utf8), pickPasteMime("text/plain image/png text/plain;charset=utf-8", true));
    try testing.expectEqual(@as(?PasteMime, .text_utf8), pickPasteMime("text/plain image/png text/plain;charset=utf-8", false));
    try testing.expectEqual(@as(?PasteMime, .text), pickPasteMime("image/png text/plain", true));
    try testing.expectEqual(@as(?PasteMime, .png), pickPasteMime("image/png", true));
    try testing.expectEqual(@as(?PasteMime, null), pickPasteMime("image/png", false));
    try testing.expectEqual(@as(?PasteMime, .text), pickPasteMime("text/html\ttext/plain\r\n", true));
    try testing.expectEqual(@as(?PasteMime, null), pickPasteMime("", true));
    try testing.expectEqual(@as(?PasteMime, null), pickPasteMime("  \t\n\r ", true));
    try testing.expectEqual(@as(?PasteMime, null), pickPasteMime("text/html application/json image/pngx text/plain;charset=utf-8;extra", true));
}

test "writePasteReadRequest matches spec examples" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writePasteReadRequest(&w, "secret123", .clipboard, .text);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:pw=c2VjcmV0MTIz:name=UGFzdGUgZXZlbnQ=;dGV4dC9wbGFpbg==\x1b\\",
        w.buffered(),
    );

    w = .fixed(&buf);
    try writePasteReadRequest(&w, "secret123", .primary, .text);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:loc=primary:pw=c2VjcmV0MTIz:name=UGFzdGUgZXZlbnQ=;dGV4dC9wbGFpbg==\x1b\\",
        w.buffered(),
    );

    w = .fixed(&buf);
    try writePasteReadRequest(&w, "secret123", .clipboard, .text_utf8);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:pw=c2VjcmV0MTIz:name=UGFzdGUgZXZlbnQ=;dGV4dC9wbGFpbjtjaGFyc2V0PXV0Zi04\x1b\\",
        w.buffered(),
    );

    w = .fixed(&buf);
    try writePasteReadRequest(&w, "secret123", .clipboard, .png);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:pw=c2VjcmV0MTIz:name=UGFzdGUgZXZlbnQ=;aW1hZ2UvcG5n\x1b\\",
        w.buffered(),
    );
}

test "reader decodes spec paste event listings with clipboard, primary, image, and BEL" {
    // 1. Plain text from clipboard, BEL terminators, pw repeated in DATA and DONE.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        deliverPacket(&reader, "type=read:status=OK:pw=c2VjcmV0MTIz", "\x07", 0);
        try deliverMimeData(&reader, "Lg==", "text/plain", ":pw=c2VjcmV0MTIz", "\x07", 1);
        deliverPacket(&reader, "type=read:status=DONE:pw=c2VjcmV0MTIz", "\x07", 2);

        var outcome = reader.takePasteEventOutcome().?;
        defer outcome.deinit(testing.allocator);
        try testing.expectEqual(PasteLocation.clipboard, outcome.paste_event.location);
        try testing.expectEqualStrings("secret123", outcome.paste_event.password.items);
        try testing.expectEqualStrings("text/plain", outcome.paste_event.mimes.items);
        try testing.expectEqual(@as(?PasteMime, .text), pickPasteMime(outcome.paste_event.mimes.items, true));
        try testing.expect(!reader.pending());
    }

    // 2. HTML + text from primary, pw not repeated in DATA or DONE.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        deliverPacket(&reader, "type=read:status=OK:loc=primary:pw=c2VjcmV0MTIz", "\x1b\\", 0);
        try deliverMimeData(&reader, "Lg==", "text/html\ntext/plain;charset=utf-8\ntext/plain", "", "\x1b\\", 1);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 2);

        var outcome = reader.takePasteEventOutcome().?;
        defer outcome.deinit(testing.allocator);
        try testing.expectEqual(PasteLocation.primary, outcome.paste_event.location);
        try testing.expectEqualStrings("secret123", outcome.paste_event.password.items);
        try testing.expectEqual(@as(?PasteMime, .text_utf8), pickPasteMime(outcome.paste_event.mimes.items, true));
    }

    // 3. Listing with image/png only, and image/png + text/plain.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        deliverPacket(&reader, "type=read:status=OK:pw=c2VjcmV0MTIz", "\x1b\\", 0);
        try deliverMimeData(&reader, "Lg==", "image/png", "", "\x07", 1);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 2);

        var outcome = reader.takePasteEventOutcome().?;
        defer outcome.deinit(testing.allocator);
        try testing.expectEqual(@as(?PasteMime, .png), pickPasteMime(outcome.paste_event.mimes.items, true));
        try testing.expectEqual(@as(?PasteMime, null), pickPasteMime(outcome.paste_event.mimes.items, false));
    }
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        deliverPacket(&reader, "type=read:status=OK:pw=c2VjcmV0MTIz", "\x1b\\", 0);
        try deliverMimeData(&reader, "Lg==", "image/png text/plain", "", "\x07", 1);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 2);

        var outcome = reader.takePasteEventOutcome().?;
        defer outcome.deinit(testing.allocator);
        try testing.expectEqual(@as(?PasteMime, .text), pickPasteMime(outcome.paste_event.mimes.items, true));
        try testing.expectEqual(@as(?PasteMime, .text), pickPasteMime(outcome.paste_event.mimes.items, false));
    }

    // 4. Listing without pw in OK, DATA:mime=Lg== identifies it as a listing.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        deliverPacket(&reader, "type=read:status=OK", "\x1b\\", 0);
        try deliverMimeData(&reader, "Lg==", "text/plain", "", "\x1b\\", 1);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 2);

        var outcome = reader.takePasteEventOutcome().?;
        defer outcome.deinit(testing.allocator);
        try testing.expectEqualStrings("", outcome.paste_event.password.items);
        try testing.expectEqualStrings("text/plain", outcome.paste_event.mimes.items);
    }
}

test "reader rejects mismatched password, bad loc, and empty/unknown listings appropriately" {
    // Mismatched pw in DATA.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        deliverPacket(&reader, "type=read:status=OK:pw=c2VjcmV0MTIz", "\x1b\\", 0);
        try deliverMimeData(&reader, "Lg==", "text/plain", ":pw=b3RoZXI=", "\x1b\\", 1);
        try expectPasteEventOutcome(&reader, .malformed);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 2);
        try testing.expect(reader.takePasteEventOutcome() == null);
        try testing.expect(!reader.pending());
    }

    // Mismatched pw in DONE.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        deliverPacket(&reader, "type=read:status=OK:pw=c2VjcmV0MTIz", "\x1b\\", 0);
        try deliverMimeData(&reader, "Lg==", "text/plain", "", "\x1b\\", 1);
        deliverPacket(&reader, "type=read:status=DONE:pw=b3RoZXI=", "\x1b\\", 2);
        try expectPasteEventOutcome(&reader, .malformed);
        try testing.expect(!reader.pending());
    }

    // Invalid loc value.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        deliverPacket(&reader, "type=read:status=OK:loc=secondary:pw=c2VjcmV0MTIz", "\x1b\\", 0);
        try expectPasteEventOutcome(&reader, .malformed);
        try deliverMimeData(&reader, "Lg==", "text/plain", "", "\x1b\\", 1);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 2);
        try testing.expect(reader.takePasteEventOutcome() == null);
        try testing.expect(!reader.pending());
    }

    // Empty MIME list.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        deliverPacket(&reader, "type=read:status=OK:pw=c2VjcmV0MTIz", "\x1b\\", 0);
        deliverPacket(&reader, "type=read:status=DATA:mime=Lg==;", "\x1b\\", 1);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 2);
        var outcome = reader.takePasteEventOutcome().?;
        defer outcome.deinit(testing.allocator);
        try testing.expectEqualStrings("", outcome.paste_event.mimes.items);
        try testing.expectEqual(@as(?PasteMime, null), pickPasteMime(outcome.paste_event.mimes.items, true));
    }

    // Only unknown types.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        deliverPacket(&reader, "type=read:status=OK:pw=c2VjcmV0MTIz", "\x1b\\", 0);
        try deliverMimeData(&reader, "Lg==", "text/html application/pdf", "", "\x1b\\", 1);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 2);
        var outcome = reader.takePasteEventOutcome().?;
        defer outcome.deinit(testing.allocator);
        try testing.expectEqual(@as(?PasteMime, null), pickPasteMime(outcome.paste_event.mimes.items, true));
    }
}

test "reader rejects oversize listing password and mime list as malformed" {
    // Password > max_paste_password_bytes.
    {
        var pw_raw: [max_paste_password_bytes + 1]u8 = @splat('p');
        const pw_b64 = try encodeBase64Alloc(testing.allocator, &pw_raw);
        defer testing.allocator.free(pw_b64);
        const ok_body = try testing.allocator.print("type=read:status=OK:pw={s}", .{pw_b64});
        defer testing.allocator.free(ok_body);

        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        deliverPacket(&reader, ok_body, "\x1b\\", 0);
        try expectPasteEventOutcome(&reader, .malformed);
        try deliverMimeData(&reader, "Lg==", "text/plain", "", "\x1b\\", 1);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 2);
        try testing.expect(reader.takePasteEventOutcome() == null);
        try testing.expect(!reader.pending());
    }

    // MIME list > max_paste_mime_list_bytes across chunks.
    {
        var list_raw: [max_paste_mime_list_bytes + 1]u8 = @splat('a');
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        deliverPacket(&reader, "type=read:status=OK:pw=c2VjcmV0MTIz", "\x1b\\", 0);
        try deliverMimeData(&reader, "Lg==", list_raw[0..3000], "", "\x1b\\", 1);
        try deliverMimeData(&reader, "Lg==", list_raw[3000..], "", "\x1b\\", 2);
        try expectPasteEventOutcome(&reader, .malformed);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 3);
        try testing.expect(reader.takePasteEventOutcome() == null);
        try testing.expect(!reader.pending());
    }
}

test "reader reports busy paste event without disturbing an open Ctrl+V request" {
    // Listing arrives while Ctrl+V is waiting for its reply (with pw).
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        try reader.begin(0, 1024);
        reader.noteModeReport(testing.allocator, .supported, 1);

        deliverPacket(&reader, "type=read:status=OK:pw=c2VjcmV0MTIz", "\x1b\\", 2);
        try deliverMimeData(&reader, "Lg==", "text/plain", ":pw=c2VjcmV0MTIz", "\x1b\\", 3);
        deliverPacket(&reader, "type=read:status=DONE:pw=c2VjcmV0MTIz", "\x1b\\", 4);

        try expectPasteEventOutcome(&reader, .busy);
        try testing.expect(reader.takeOutcome() == null);
        try testing.expect(reader.pending());

        deliverPacket(&reader, "type=read:status=OK", "\x1b\\", 5);
        try deliverData(&reader, test_png, 6);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 7);

        var outcome = reader.takeOutcome().?;
        defer outcome.deinit(testing.allocator);
        try testing.expectEqualStrings(test_png, outcome.image.items);
        try testing.expect(!reader.pending());
    }

    // Listing without pw arrives while Ctrl+V is waiting for its reply.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        try reader.begin(0, 1024);
        reader.noteModeReport(testing.allocator, .supported, 1);

        deliverPacket(&reader, "type=read:status=OK", "\x1b\\", 2);
        try deliverMimeData(&reader, "Lg==", "text/plain", "", "\x1b\\", 3);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 4);

        try expectPasteEventOutcome(&reader, .busy);
        try testing.expect(reader.takeOutcome() == null);
        try testing.expect(reader.pending());

        deliverPacket(&reader, "type=read:status=OK", "\x1b\\", 5);
        try deliverData(&reader, test_png, 6);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 7);

        var outcome = reader.takeOutcome().?;
        defer outcome.deinit(testing.allocator);
        try testing.expectEqualStrings(test_png, outcome.image.items);
        try testing.expect(!reader.pending());
    }
}

test "reader assembles chunked text replies, skips non-matching mimes, enforces cap, and handles EPERM" {
    // Chunked text/plain;charset=utf-8 reply with extra text/html skipped.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        try reader.beginText(0, 1024, .text_utf8);
        deliverPacket(&reader, "type=read:status=OK", "\x1b\\", 1);
        try deliverMimeData(&reader, "dGV4dC9odG1s", "<b>ignored</b>", "", "\x1b\\", 2);
        try deliverMimeData(&reader, "dGV4dC9wbGFpbjtjaGFyc2V0PXV0Zi04", "hello ", "", "\x1b\\", 3);
        try deliverMimeData(&reader, "dGV4dC9wbGFpbg==", "plain ignored", "", "\x1b\\", 4);
        try deliverMimeData(&reader, "dGV4dC9wbGFpbjtjaGFyc2V0PXV0Zi04", "world", "", "\x1b\\", 5);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 6);

        var outcome = reader.takeTextOutcome().?;
        defer outcome.deinit(testing.allocator);
        try testing.expectEqualStrings("hello world", outcome.text.items);
        try testing.expect(!reader.pending());
    }

    // Empty text reply.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        try reader.beginText(0, 1024, .text);
        deliverPacket(&reader, "type=read:status=OK", "\x1b\\", 1);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 2);
        try expectTextOutcome(&reader, .no_text);
        try testing.expect(!reader.pending());
    }

    // Text reply over cap.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        try reader.beginText(0, 5, .text);
        deliverPacket(&reader, "type=read:status=OK", "\x1b\\", 1);
        try deliverMimeData(&reader, "dGV4dC9wbGFpbg==", "abc", "", "\x1b\\", 2);
        try deliverMimeData(&reader, "dGV4dC9wbGFpbg==", "def", "", "\x1b\\", 3);
        try expectTextOutcome(&reader, .too_large);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 4);
        try testing.expect(reader.takeTextOutcome() == null);
        try testing.expect(!reader.pending());
    }

    // EPERM on text read.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        try reader.beginText(0, 1024, .text);
        deliverPacket(&reader, "type=read:status=EPERM", "\x1b\\", 1);
        try expectTextOutcome(&reader, .denied);
        try testing.expect(!reader.pending());
    }

    // beginText enforces RequestPending, supports cancel(), and times out at reply_timeout_ms.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        try reader.beginText(0, 1024, .text);
        try testing.expectError(error.RequestPending, reader.begin(1, 1024));
        try testing.expectError(error.RequestPending, reader.beginText(1, 1024, .text_utf8));
        reader.cancel();
        try testing.expect(!reader.pending());

        try reader.beginText(10, 1024, .text);
        reader.poll(testing.allocator, 10 + reply_timeout_ms - 1);
        try testing.expect(reader.takeTextOutcome() == null);
        reader.poll(testing.allocator, 10 + reply_timeout_ms);
        try expectTextOutcome(&reader, .timed_out);
        try testing.expect(!reader.pending());
    }
}

test "reader handles listing stalls, boundary caps, and idle OK without pw or Lg==" {
    // Mid-packet stall during listing uses packet_idle_timeout_ms.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        deliverPacket(&reader, "type=read:status=OK:pw=c2VjcmV0MTIz", "\x1b\\", 0);
        reader.beginPacket(testing.allocator, 1);
        for ("type=read:status=DA") |byte| try testing.expect(reader.feedOwnedByte(testing.allocator, byte, 1));
        reader.poll(testing.allocator, 1 + packet_idle_timeout_ms - 1);
        try testing.expect(reader.takePasteEventOutcome() == null);
        reader.poll(testing.allocator, 1 + packet_idle_timeout_ms);
        try expectPasteEventOutcome(&reader, .timed_out);
        try testing.expect(!reader.feedOwnedByte(testing.allocator, ' ', 2 + packet_idle_timeout_ms));
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 3 + packet_idle_timeout_ms);
        try testing.expect(!reader.pending());
    }

    // Inter-packet stall during listing uses transfer_idle_timeout_ms.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        deliverPacket(&reader, "type=read:status=OK:pw=c2VjcmV0MTIz", "\x1b\\", 0);
        reader.poll(testing.allocator, transfer_idle_timeout_ms - 1);
        try testing.expect(reader.takePasteEventOutcome() == null);
        reader.poll(testing.allocator, transfer_idle_timeout_ms);
        try expectPasteEventOutcome(&reader, .timed_out);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", transfer_idle_timeout_ms + 1);
        try testing.expect(!reader.pending());
    }

    // Exact caps succeed (128-byte password, 4096-byte MIME list).
    {
        var pw_raw: [max_paste_password_bytes]u8 = @splat('p');
        const pw_b64 = try encodeBase64Alloc(testing.allocator, &pw_raw);
        defer testing.allocator.free(pw_b64);
        const ok_body = try testing.allocator.print("type=read:status=OK:pw={s}", .{pw_b64});
        defer testing.allocator.free(ok_body);

        var list_raw: [max_paste_mime_list_bytes]u8 = @splat(' ');
        @memcpy(list_raw[0.."text/plain".len], "text/plain");

        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        deliverPacket(&reader, ok_body, "\x1b\\", 0);
        try deliverMimeData(&reader, "Lg==", list_raw[0..3000], "", "\x1b\\", 1);
        try deliverMimeData(&reader, "Lg==", list_raw[3000..], "", "\x1b\\", 2);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 3);

        var outcome = reader.takePasteEventOutcome().?;
        defer outcome.deinit(testing.allocator);
        try testing.expectEqual(max_paste_password_bytes, outcome.paste_event.password.items.len);
        try testing.expectEqual(max_paste_mime_list_bytes, outcome.paste_event.mimes.items.len);
        try testing.expectEqual(@as(?PasteMime, .text), pickPasteMime(outcome.paste_event.mimes.items, true));
    }

    // Bare OK followed directly by DONE in idle produces no outcome.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        deliverPacket(&reader, "type=read:status=OK", "\x1b\\", 0);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 1);
        try testing.expect(reader.takePasteEventOutcome() == null);
        try testing.expect(!reader.pending());
    }

    // Bare OK without pw followed by DATA with pw is malformed.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        deliverPacket(&reader, "type=read:status=OK", "\x1b\\", 0);
        try deliverMimeData(&reader, "Lg==", "text/plain", ":pw=c2VjcmV0MTIz", "\x1b\\", 1);
        try expectPasteEventOutcome(&reader, .malformed);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 2);
        try testing.expect(!reader.pending());
    }

    // Listing while open Ctrl+V transfer is already receiving chunks.
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        try reader.begin(0, 1024);
        reader.noteModeReport(testing.allocator, .supported, 1);
        deliverPacket(&reader, "type=read:status=OK", "\x1b\\", 2);
        try deliverData(&reader, test_png[0..6], 3);

        deliverPacket(&reader, "type=read:status=OK:pw=c2VjcmV0MTIz", "\x1b\\", 4);
        try deliverMimeData(&reader, "Lg==", "text/plain", ":pw=c2VjcmV0MTIz", "\x1b\\", 5);
        deliverPacket(&reader, "type=read:status=DONE:pw=c2VjcmV0MTIz", "\x1b\\", 6);
        try expectPasteEventOutcome(&reader, .busy);
        try testing.expect(reader.takeOutcome() == null);

        try deliverData(&reader, test_png[6..], 7);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 8);
        var outcome = reader.takeOutcome().?;
        defer outcome.deinit(testing.allocator);
        try testing.expectEqualStrings(test_png, outcome.image.items);
        try testing.expect(!reader.pending());
    }
}

test "reader beginPasteImage skips mode query and reads png or denial" {
    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        try reader.beginPasteImage(0, 1024);
        deliverPacket(&reader, "type=read:status=OK", "\x1b\\", 1);
        try deliverData(&reader, test_png, 2);
        deliverPacket(&reader, "type=read:status=DONE", "\x1b\\", 3);

        var outcome = reader.takeOutcome().?;
        defer outcome.deinit(testing.allocator);
        try testing.expectEqualStrings(test_png, outcome.image.items);
        try testing.expect(!reader.pending());
    }

    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        try reader.beginPasteImage(0, 1024);
        deliverPacket(&reader, "type=read:status=EPERM", "\x1b\\", 1);
        try expectOutcome(&reader, .denied);
        try testing.expect(!reader.pending());
    }

    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        try reader.beginPasteImage(0, 1024);
        reader.poll(testing.allocator, reply_timeout_ms - 1);
        try testing.expect(reader.takeOutcome() == null);
        reader.poll(testing.allocator, reply_timeout_ms);
        try expectOutcome(&reader, .timed_out);
        try testing.expect(!reader.pending());
    }

    {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        try reader.beginPasteImage(0, 1024);
        reader.cancel();
        try testing.expect(!reader.pending());
    }
}
