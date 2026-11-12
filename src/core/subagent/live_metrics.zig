const std = @import("std");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

/// The most bytes of a call's label that status and the agent list keep.
pub const max_label_bytes = 160;
const max_call_id_bytes = 128;
/// The most bytes of a raw label read before encoding it; a longer one is cut
/// there and shown with an ellipsis.
const max_raw_label_bytes = 512;
const ellipsis = "\u{2026}";

/// What a subagent's running turn reports to its parent while it runs: its
/// token count, and its latest tool call that has not ended, for `status`
/// and its row in the agent list. The child's turn writes it, on its slot
/// thread or, in the interactive app, on the main thread; the parent reads
/// it from any thread.
pub const LiveMetrics = struct {
    input_tokens: std.atomic.Value(u64) = .init(0),
    call_mutex: std.Io.Mutex = .init,
    call: Call = .{},

    pub fn snapshot(self: *const LiveMetrics) Snapshot {
        return .{ .input_tokens = self.input_tokens.load(.monotonic) };
    }

    /// Clears the counts and the call for the slot's next work.
    pub fn reset(self: *LiveMetrics) void {
        self.input_tokens.store(0, .monotonic);
        self.call_mutex.lockUncancelable(io_mod.getIo());
        defer self.call_mutex.unlock(io_mod.getIo());
        self.call = .{};
    }

    /// Records call `call_id` as the subagent's current call, with its
    /// label, such as "Waiting for npm test", from `now_ms`.
    pub fn callStarted(self: *LiveMetrics, call_id: []const u8, label: []const u8, now_ms: i64) void {
        var next: Call = .{ .active = true, .started_ms = now_ms };
        const id = text_utils.utf8PrefixByBytes(call_id, max_call_id_bytes);
        @memcpy(next.id_buf[0..id.len], id);
        next.id_len = @intCast(id.len);
        next.label_len = @intCast(storeLabel(&next.label_buf, label));
        self.call_mutex.lockUncancelable(io_mod.getIo());
        defer self.call_mutex.unlock(io_mod.getIo());
        self.call = next;
    }

    /// Ends call `call_id` if it is the current one. A call that started
    /// later stays current.
    pub fn callEnded(self: *LiveMetrics, call_id: []const u8) void {
        self.call_mutex.lockUncancelable(io_mod.getIo());
        defer self.call_mutex.unlock(io_mod.getIo());
        const id = text_utils.utf8PrefixByBytes(call_id, max_call_id_bytes);
        if (self.call.active and std.mem.eql(u8, self.call.id(), id)) self.call = .{};
    }

    /// The current call, if one runs.
    pub fn currentCall(self: *LiveMetrics) ?Call {
        self.call_mutex.lockUncancelable(io_mod.getIo());
        defer self.call_mutex.unlock(io_mod.getIo());
        return if (self.call.active) self.call else null;
    }
};

pub const Snapshot = struct {
    input_tokens: u64 = 0,
};

/// A subagent's current tool call, copied by value.
pub const Call = struct {
    active: bool = false,
    started_ms: i64 = 0,
    id_buf: [max_call_id_bytes]u8 = undefined,
    id_len: u8 = 0,
    label_buf: [max_label_bytes]u8 = undefined,
    label_len: u8 = 0,

    pub fn id(self: *const Call) []const u8 {
        return self.id_buf[0..self.id_len];
    }

    pub fn label(self: *const Call) []const u8 {
        return self.label_buf[0..self.label_len];
    }

    /// How long the call has run at `now_ms`; 0 for a clock that moved back.
    pub fn runningMs(self: *const Call, now_ms: i64) u64 {
        return if (now_ms > self.started_ms) @intCast(now_ms - self.started_ms) else 0;
    }
};

/// Writes a running or quiet time the way status, the relayed note, and the
/// agent list show it: `45s`, `4m12s`, or `1h3m`.
pub fn writeDuration(writer: *std.Io.Writer, ms: u64) std.Io.Writer.Error!void {
    const seconds = ms / std.time.ms_per_s;
    if (seconds < 60) return writer.print("{d}s", .{seconds});
    if (seconds < 60 * 60) return writer.print("{d}m{d}s", .{ seconds / 60, seconds % 60 });
    return writer.print("{d}h{d}m", .{ seconds / 3600, (seconds % 3600) / 60 });
}

test "durations read in seconds, then minutes, then hours" {
    var buffer: [32]u8 = undefined;
    const cases = [_]struct { ms: u64, text: []const u8 }{
        .{ .ms = 0, .text = "0s" },
        .{ .ms = 1_999, .text = "1s" },
        .{ .ms = 59_999, .text = "59s" },
        .{ .ms = 60_000, .text = "1m0s" },
        .{ .ms = 252_000, .text = "4m12s" },
        .{ .ms = 3_599_999, .text = "59m59s" },
        .{ .ms = 3_600_000, .text = "1h0m" },
        .{ .ms = 3_780_000, .text = "1h3m" },
    };
    for (cases) |case| {
        var writer = std.Io.Writer.fixed(&buffer);
        try writeDuration(&writer, case.ms);
        try std.testing.expectEqualStrings(case.text, writer.buffered());
    }
}

/// Writes `raw` into `out` as one terminal-safe line of at most
/// `max_label_bytes`: whitespace runs become one space, control bytes and
/// invalid UTF-8 get visible escapes, and a cut label ends in an ellipsis.
/// Returns the length written.
pub fn storeLabel(out: *[max_label_bytes]u8, raw: []const u8) usize {
    const head = text_utils.utf8PrefixByBytes(raw, max_raw_label_bytes);
    var scratch: [4 * max_raw_label_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    const encoded = text_utils.encodeTerminalSafeInline(fixed.allocator(), head, max_label_bytes - ellipsis.len) catch {
        const fallback = "tool call";
        @memcpy(out[0..fallback.len], fallback);
        return fallback.len;
    };
    var len = encoded.bytes.len;
    @memcpy(out[0..len], encoded.bytes);
    if (encoded.truncated or head.len < raw.len) {
        @memcpy(out[len..][0..ellipsis.len], ellipsis);
        len += ellipsis.len;
    }
    return len;
}

test "a call's label stays one line, terminal-safe, and bounded" {
    var out: [max_label_bytes]u8 = undefined;
    const plain = out[0..storeLabel(&out, "Waiting for npm test")];
    try std.testing.expectEqualStrings("Waiting for npm test", plain);

    const lines = out[0..storeLabel(&out, "Running printf a\n\n\tb")];
    try std.testing.expectEqualStrings("Running printf a b", lines);

    const escape = out[0..storeLabel(&out, "Running \x1b[2Jclear")];
    try std.testing.expect(std.mem.findScalar(u8, escape, 0x1b) == null);

    const xs: [4000]u8 = @splat('x');
    const long = "Running " ++ xs;
    const cut = out[0..storeLabel(&out, long)];
    try std.testing.expect(cut.len <= max_label_bytes);
    try std.testing.expect(std.mem.endsWith(u8, cut, ellipsis));
}

test "a call ends only itself, and a later call stays current" {
    var metrics: LiveMetrics = .{};
    metrics.callStarted("call-1", "Running a", 1_000);
    metrics.callStarted("call-2", "Running b", 2_000);
    metrics.callEnded("call-1");
    const current = metrics.currentCall().?;
    try std.testing.expectEqualStrings("Running b", current.label());
    try std.testing.expectEqual(@as(u64, 3_000), current.runningMs(5_000));
    try std.testing.expectEqual(@as(u64, 0), current.runningMs(1_000));
    metrics.callEnded("call-2");
    try std.testing.expect(metrics.currentCall() == null);
    metrics.callStarted("call-3", "Running c", 3_000);
    metrics.reset();
    try std.testing.expect(metrics.currentCall() == null);
}

test "a subagent's call label stays bounded, one line, and terminal-safe on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzCallLabel, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "Waiting for npm test",
            "Running sh -c 'printf a; exec sleep 600'\n\n\tnext",
            "Running \x1b[2J\x1b]0;owned\x07\u{9b}31m\xff\xfe\x00\x7f",
            "Waiting for " ++ long_label_seed,
            "a\xed\xa0\x80\r\rb\xc3(",
        }) ++ @import("fuzz_corpus").subagent_call_label.*),
    });
}

/// 200 four-byte characters, past the raw limit, so the cut lands inside one.
const long_label_seed: [800]u8 = blk: {
    var bytes: [800]u8 = undefined;
    for (0..200) |index| @memcpy(bytes[index * 4 ..][0..4], "\u{1F600}");
    break :blk bytes;
};

/// Whatever the bytes, the stored label fits its buffer, is valid UTF-8 with
/// no control bytes, and is the same on a second store.
fn fuzzCallLabel(_: void, smith: *std.testing.Smith) !void {
    var buffer: [2048]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    const input = buffer[0..len];
    var out: [max_label_bytes]u8 = undefined;
    const label = out[0..storeLabel(&out, input)];
    try std.testing.expect(label.len <= max_label_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(label));
    for (label) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
    var again: [max_label_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(label, again[0..storeLabel(&again, input)]);
}
