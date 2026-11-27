const std = @import("std");
const builtin = @import("builtin");
const clipboard_protocol = @import("clipboard_protocol.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const io_mod = @import("../../core/shared/io.zig");
const mode_rearm = @import("mode_rearm.zig");
const theme_protocol = @import("theme_protocol.zig");

// OSC 11 shares Escape's prefix: allow fragmented replies without imposing
// the cursor probe's full 100 ms delay on a standalone Escape key.
pub const response_idle_timeout_ms: i64 = 75;
pub const background_response_timeout_ms: i64 = 200;
/// The WebAssembly hosts never ask the terminal for the clipboard, so their
/// monitor does not look for its replies.
const clipboard_replies = builtin.target.os.tag != .wasi;

const max_candidate_bytes = 64;

pub const ThemeUpdate = struct {
    light: bool,
    rgb: ?theme_protocol.Rgb = null,
};

pub const ForwardBytes = struct {
    storage: [max_candidate_bytes + 1]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const ForwardBytes) []const u8 {
        return self.storage[0..self.len];
    }
};

pub const FeedResult = union(enum) {
    pending,
    consumed,
    forward: ForwardBytes,
    /// A clipboard reply packet starts (`clipboard_protocol`). Its body and
    /// terminator follow and belong to the clipboard reader.
    clipboard_packet,
    /// The terminal answered the clipboard protocol's mode query.
    clipboard_mode: clipboard_protocol.ModeSupport,
};

pub const QueryRequest = enum {
    response_fence,
    background,
};

const BackgroundQuery = struct {
    deadline_ms: i64,
    background: ?ThemeUpdate = null,
};

const QueryState = union(enum) {
    idle,
    awaiting_response_fence: i64,
    background_ready,
    awaiting_background: BackgroundQuery,
};

pub const Monitor = struct {
    enabled: bool = false,
    candidate: [max_candidate_bytes]u8 = undefined,
    candidate_len: u8 = 0,
    candidate_deadline_ms: i64 = 0,
    deferred: [max_candidate_bytes]u8 = undefined,
    deferred_start: u8 = 0,
    deferred_len: u8 = 0,
    deferred_input_in_flight: bool = false,
    query_state: QueryState = .idle,
    theme_dirty: bool = false,
    notification_light: ?bool = null,
    settled_update: ?ThemeUpdate = null,
    /// When fx next turns theme notifications (DEC mode 2031) on again.
    rearm: mode_rearm.Schedule = .{},
    /// `poll` dropped the start of a clipboard reply that stalled; the
    /// clipboard reader must drop its rest (`takeDroppedClipboardStart`).
    dropped_clipboard_start: bool = false,
    /// A clipboard request is open, so more reply starts are held
    /// (`clipboard_protocol.holdsReplyStart`). The input loop sets it before
    /// each byte (`expectClipboardReply`).
    clipboard_reply_expected: bool = false,
    /// The candidate is a clipboard reply start that `poll` drops, not types,
    /// when it stalls.
    candidate_holds_clipboard: bool = false,

    pub fn start(self: *Monitor) void {
        self.enabled = true;
    }

    /// Makes the next `takeRearmRequest` due at once, such as after a
    /// job-control resume, whose terminal restore turned mode 2031 off.
    pub fn requestRearm(self: *Monitor) void {
        self.rearm.requestNow();
    }

    /// Returns true when fx should turn theme notifications on again and ask
    /// for the color scheme. A theme change fx missed while the mode was off
    /// then settles; when nothing changed, the answer settles to the current
    /// theme and fx redraws nothing. It waits while a theme query is in flight
    /// or a notification still waits for its query, because that refresh
    /// already reads the current theme.
    pub fn takeRearmRequest(self: *Monitor, now_ms: i64) bool {
        if (!self.enabled) return false;
        if (!self.rearm.due(now_ms)) return false;
        if (self.theme_dirty or self.query_state != .idle) return false;
        self.rearm.schedule(now_ms);
        return true;
    }

    pub fn hasPendingInput(self: *const Monitor) bool {
        return self.candidate_len > 0 or
            self.deferred_start < self.deferred_len or
            self.deferred_input_in_flight;
    }

    pub fn ownsInput(self: *const Monitor) bool {
        if (!self.enabled) return false;
        if (self.hasPendingInput()) return true;
        return switch (self.query_state) {
            .awaiting_response_fence, .awaiting_background => true,
            .idle, .background_ready => false,
        };
    }

    pub fn expectClipboardReply(self: *Monitor, expected: bool) void {
        self.clipboard_reply_expected = expected;
    }

    pub fn feed(self: *Monitor, byte: u8, now_ms: i64) FeedResult {
        if (!self.enabled) return forwardByte(byte);
        if (self.candidate_len == 0 and byte != 0x1b) return forwardByte(byte);
        if (self.candidate_len == 1 and byte == 0x1b) {
            self.candidate_deadline_ms = io_mod.addMillis(now_ms, response_idle_timeout_ms);
            return forwardByte(byte);
        }
        if (self.candidate_len == self.candidate.len) return self.forwardCandidateWith(byte);

        const clipboard_start = clipboard_replies and
            clipboard_protocol.replyStartIsCertain(self.candidate[0..self.candidate_len]);
        self.candidate[self.candidate_len] = byte;
        self.candidate_len += 1;
        const candidate = self.candidate[0..self.candidate_len];
        // The rest of a reply comes before any later key, so a held clipboard
        // reply start waits through a stall instead of being typed.
        self.candidate_holds_clipboard = clipboard_replies and
            clipboard_protocol.holdsReplyStart(candidate, self.clipboard_reply_expected);
        self.candidate_deadline_ms = io_mod.addMillis(now_ms, if (self.candidate_holds_clipboard)
            clipboard_protocol.packet_idle_timeout_ms
        else
            response_idle_timeout_ms);
        if (std.mem.eql(u8, candidate, dark_response)) {
            self.candidate_len = 0;
            self.queueRefresh(false);
            return .consumed;
        }
        if (std.mem.eql(u8, candidate, light_response)) {
            self.candidate_len = 0;
            self.queueRefresh(true);
            return .consumed;
        }
        if (std.mem.startsWith(u8, dark_response, candidate) or
            std.mem.startsWith(u8, light_response, candidate))
        {
            return .pending;
        }

        // Clipboard replies share the ESC prefix with every other terminal
        // reply, so the monitor that sees replies first hands them off.
        if (comptime clipboard_replies) {
            switch (clipboard_protocol.classifyReplyStart(candidate)) {
                .none => if (clipboard_start) return self.dropBrokenClipboardStart(byte, now_ms),
                .pending => return .pending,
                .packet => {
                    self.candidate_len = 0;
                    self.candidate_deadline_ms = 0;
                    return .clipboard_packet;
                },
                .mode => |support| {
                    self.candidate_len = 0;
                    self.candidate_deadline_ms = 0;
                    return .{ .clipboard_mode = support };
                },
            }
        }

        switch (theme_protocol.classifyPrimaryDeviceAttributes(candidate)) {
            .pending => return .pending,
            .complete => {
                self.candidate_len = 0;
                self.candidate_deadline_ms = 0;
                self.finishResponseFence();
                return .consumed;
            },
            .invalid => {},
        }

        // While enabled, own complete parseable OSC 11 replies. Retain only
        // samples bracketed by response fences; discard every other reply.
        if (std.mem.startsWith(u8, osc11_prefix, candidate)) return .pending;
        if (std.mem.startsWith(u8, candidate, osc11_prefix)) {
            if (!std.mem.endsWith(u8, candidate, "\x07") and
                !std.mem.endsWith(u8, candidate, "\x1b\\"))
            {
                return .pending;
            }
            if (theme_protocol.parseOsc11Response(candidate)) |background| {
                self.candidate_len = 0;
                self.candidate_deadline_ms = 0;
                switch (self.query_state) {
                    .awaiting_background => |*query| {
                        query.background = .{
                            .light = background.light,
                            .rgb = background.rgb,
                        };
                    },
                    else => {},
                }
                return .consumed;
            }
        }
        return self.forwardCandidate();
    }

    pub fn poll(self: *Monitor, now_ms: i64) void {
        if (self.candidate_len > 0 and now_ms >= self.candidate_deadline_ms) {
            const candidate = self.candidate[0..self.candidate_len];
            if (std.mem.startsWith(u8, candidate, osc11_prefix)) {
                debug_trace.logf(
                    "theme",
                    "theme osc11 candidate dropped bytes={d} reason=osc11_idle_timeout",
                    .{self.candidate_len},
                );
                self.candidate_len = 0;
                self.candidate_deadline_ms = 0;
            } else if (self.candidate_holds_clipboard) {
                // The clipboard reader drops the rest when it comes.
                debug_trace.logf(
                    "theme",
                    "theme clipboard reply start dropped bytes={d} reason=idle_timeout",
                    .{self.candidate_len},
                );
                self.candidate_len = 0;
                self.candidate_deadline_ms = 0;
                self.dropped_clipboard_start = true;
            } else {
                self.deferCandidate();
            }
        }
        const query_deadline = switch (self.query_state) {
            .awaiting_response_fence => |deadline_ms| deadline_ms,
            .awaiting_background => |query| query.deadline_ms,
            .idle, .background_ready => return,
        };
        if (now_ms >= query_deadline) {
            debug_trace.logf("theme", "theme_query_timeout phase={s}", .{@tagName(self.query_state)});
            self.settleNotificationFallback();
        }
    }

    pub fn takeQueryRequest(self: *Monitor, now_ms: i64) ?QueryRequest {
        switch (self.query_state) {
            .idle => {
                if (!self.theme_dirty) return null;
                self.query_state = .{
                    .awaiting_response_fence = io_mod.addMillis(now_ms, background_response_timeout_ms),
                };
                return .response_fence;
            },
            .background_ready => {
                self.theme_dirty = false;
                self.query_state = .{ .awaiting_background = .{
                    .deadline_ms = io_mod.addMillis(now_ms, background_response_timeout_ms),
                } };
                return .background;
            },
            .awaiting_response_fence, .awaiting_background => return null,
        }
    }

    pub fn failQuery(self: *Monitor, now_ms: i64) void {
        _ = now_ms;
        if (self.query_state == .idle) return;
        self.settleNotificationFallback();
    }

    /// Whether `poll` dropped the start of a clipboard reply since the last
    /// call. The caller then calls `clipboard_protocol.Reader.dropReplyStart`
    /// before it reads more input.
    pub fn takeDroppedClipboardStart(self: *Monitor) bool {
        const dropped = self.dropped_clipboard_start;
        self.dropped_clipboard_start = false;
        return dropped;
    }

    pub fn takeSettledUpdate(self: *Monitor) ?ThemeUpdate {
        const update = self.settled_update;
        self.settled_update = null;
        return update;
    }

    pub fn takeDeferredByte(self: *Monitor) ?u8 {
        std.debug.assert(!self.deferred_input_in_flight);
        if (self.deferred_start >= self.deferred_len) return null;
        const byte = self.deferred[self.deferred_start];
        self.deferred_start += 1;
        if (self.deferred_start == self.deferred_len) {
            self.deferred_start = 0;
            self.deferred_len = 0;
        }
        self.deferred_input_in_flight = true;
        return byte;
    }

    pub fn consumeDeferredInputDispatch(self: *Monitor) bool {
        const in_flight = self.deferred_input_in_flight;
        self.deferred_input_in_flight = false;
        return in_flight;
    }

    fn queueRefresh(self: *Monitor, light: bool) void {
        if (self.settled_update != null) {
            debug_trace.logf("theme", "theme_update_dropped reason=newer_notification", .{});
            self.settled_update = null;
        }
        self.notification_light = light;
        self.theme_dirty = true;
    }

    fn finishResponseFence(self: *Monitor) void {
        switch (self.query_state) {
            .awaiting_response_fence => self.query_state = .background_ready,
            .awaiting_background => |query| {
                const update = query.background orelse return;
                self.query_state = .idle;
                if (self.theme_dirty) {
                    debug_trace.logf("theme", "theme_sample_dropped reason=newer_notification", .{});
                    return;
                }
                self.notification_light = null;
                self.settled_update = update;
            },
            .idle, .background_ready => {},
        }
    }

    fn settleNotificationFallback(self: *Monitor) void {
        self.query_state = .idle;
        self.theme_dirty = false;
        const light = self.notification_light orelse return;
        self.notification_light = null;
        self.settled_update = .{ .light = light };
    }

    /// A clipboard reply start that stops matching is a broken reply, not
    /// keys: its bytes are dropped, and `byte`, which broke it, is read on
    /// its own.
    fn dropBrokenClipboardStart(self: *Monitor, byte: u8, now_ms: i64) FeedResult {
        debug_trace.logf(
            "theme",
            "theme clipboard reply start dropped bytes={d} reason=broken_reply",
            .{self.candidate_len - 1},
        );
        self.candidate_len = 0;
        self.candidate_deadline_ms = 0;
        return self.feed(byte, now_ms);
    }

    fn deferCandidate(self: *Monitor) void {
        if (self.candidate_len == 0) return;
        std.debug.assert(self.deferred_start == self.deferred_len);
        @memcpy(self.deferred[0..self.candidate_len], self.candidate[0..self.candidate_len]);
        self.deferred_start = 0;
        self.deferred_len = self.candidate_len;
        self.candidate_len = 0;
        self.candidate_deadline_ms = 0;
    }

    fn forwardCandidate(self: *Monitor) FeedResult {
        var forwarded = ForwardBytes{};
        @memcpy(forwarded.storage[0..self.candidate_len], self.candidate[0..self.candidate_len]);
        forwarded.len = self.candidate_len;
        self.candidate_len = 0;
        self.candidate_deadline_ms = 0;
        return .{ .forward = forwarded };
    }

    fn forwardCandidateWith(self: *Monitor, byte: u8) FeedResult {
        var forwarded = self.forwardCandidate().forward;
        forwarded.storage[forwarded.len] = byte;
        forwarded.len += 1;
        return .{ .forward = forwarded };
    }
};

const dark_response = "\x1b[?997;1n";
const light_response = "\x1b[?997;2n";
const response_fence = "\x1b[?1;2c";
const osc11_prefix = "\x1b]11;rgb:";

fn forwardByte(byte: u8) FeedResult {
    var forwarded = ForwardBytes{};
    forwarded.storage[0] = byte;
    forwarded.len = 1;
    return .{ .forward = forwarded };
}

fn beginBackgroundSampleForTest(monitor: *Monitor, now_ms: i64) !void {
    try std.testing.expectEqual(QueryRequest.response_fence, monitor.takeQueryRequest(now_ms).?);
    for (response_fence) |byte| _ = monitor.feed(byte, now_ms + 1);
    try std.testing.expectEqual(QueryRequest.background, monitor.takeQueryRequest(now_ms + 2).?);
}

test "theme monitor queues a fenced background sample for a theme notification" {
    var monitor = Monitor{};
    monitor.start();

    for (dark_response) |byte| {
        _ = monitor.feed(byte, 0);
    }

    try std.testing.expectEqual(QueryRequest.response_fence, monitor.takeQueryRequest(0).?);
    try std.testing.expect(monitor.takeQueryRequest(0) == null);
    for (response_fence) |byte| _ = monitor.feed(byte, 1);
    try std.testing.expectEqual(QueryRequest.background, monitor.takeQueryRequest(2).?);
    try std.testing.expect(monitor.takeQueryRequest(2) == null);
}

test "theme monitor settles a strict OSC 11 response" {
    var monitor = Monitor{};
    monitor.start();
    for (light_response) |byte| _ = monitor.feed(byte, 0);
    try beginBackgroundSampleForTest(&monitor, 0);

    for ("\x1b]11;rgb:ffff/ffff/ffff\x1b\\") |byte| _ = monitor.feed(byte, 3);
    for (response_fence) |byte| _ = monitor.feed(byte, 4);

    const update = monitor.takeSettledUpdate().?;
    try std.testing.expect(update.light);
    try std.testing.expectEqual(@as(u8, 0xff), update.rgb.?.r);
}

test "theme monitor trusts terminal background over OS preference" {
    var monitor = Monitor{};
    monitor.start();
    for (light_response) |byte| _ = monitor.feed(byte, 0);
    try beginBackgroundSampleForTest(&monitor, 0);

    for ("\x1b]11;rgb:1c1c/1c1c/1c1c\x1b\\") |byte| _ = monitor.feed(byte, 3);
    for (response_fence) |byte| _ = monitor.feed(byte, 4);

    const update = monitor.takeSettledUpdate().?;
    try std.testing.expect(!update.light);
    try std.testing.expectEqual(@as(u8, 0x1c), update.rgb.?.r);
}

test "theme monitor uses the last background before the response fence" {
    var monitor = Monitor{};
    monitor.start();
    for (light_response) |byte| _ = monitor.feed(byte, 0);
    try beginBackgroundSampleForTest(&monitor, 0);

    for ("\x1b]11;rgb:1c1c/1c1c/1c1c\x1b\\") |byte| _ = monitor.feed(byte, 3);
    for ("\x1b]11;rgb:ffff/ffff/ffff\x1b\\") |byte| _ = monitor.feed(byte, 4);
    for (response_fence) |byte| _ = monitor.feed(byte, 5);

    const update = monitor.takeSettledUpdate().?;
    try std.testing.expect(update.light);
    try std.testing.expectEqual(@as(u8, 0xff), update.rgb.?.r);
}

test "theme monitor drains stale backgrounds before sampling" {
    var monitor = Monitor{};
    monitor.start();
    for (light_response) |byte| _ = monitor.feed(byte, 0);
    try std.testing.expectEqual(QueryRequest.response_fence, monitor.takeQueryRequest(0).?);

    for ("\x1b]11;rgb:1c1c/1c1c/1c1c\x1b\\") |byte| _ = monitor.feed(byte, 1);
    for (response_fence) |byte| _ = monitor.feed(byte, 2);
    try std.testing.expect(monitor.takeSettledUpdate() == null);

    try std.testing.expectEqual(QueryRequest.background, monitor.takeQueryRequest(3).?);
    for (response_fence) |byte| _ = monitor.feed(byte, 4);
    try std.testing.expect(monitor.takeSettledUpdate() == null);
    for ("\x1b]11;rgb:ffff/ffff/ffff\x1b\\") |byte| _ = monitor.feed(byte, 4);
    for (response_fence) |byte| _ = monitor.feed(byte, 5);

    const update = monitor.takeSettledUpdate().?;
    try std.testing.expect(update.light);
    try std.testing.expectEqual(@as(u8, 0xff), update.rgb.?.r);
}

test "theme monitor settles the notification after a background query timeout" {
    var monitor = Monitor{};
    monitor.start();
    for (light_response) |byte| _ = monitor.feed(byte, 0);
    try beginBackgroundSampleForTest(&monitor, 0);

    const timed_out_ms = background_response_timeout_ms + 2;
    monitor.poll(timed_out_ms);
    const fallback = monitor.takeSettledUpdate().?;
    try std.testing.expect(fallback.light);
    try std.testing.expect(fallback.rgb == null);

    for ("\x1b]11;rgb:ffff/ffff/ffff\x1b\\") |byte| {
        try std.testing.expect(switch (monitor.feed(byte, background_response_timeout_ms + 1)) {
            .pending, .consumed => true,
            .forward, .clipboard_packet, .clipboard_mode => false,
        });
    }
    try std.testing.expect(monitor.takeSettledUpdate() == null);
    try std.testing.expect(monitor.takeQueryRequest(timed_out_ms) == null);
    try std.testing.expect(monitor.takeQueryRequest(timed_out_ms + 10_000) == null);
}

test "theme monitor settles the notification after a query write failure" {
    var monitor = Monitor{};
    monitor.start();
    for (light_response) |byte| _ = monitor.feed(byte, 0);
    _ = monitor.takeQueryRequest(0).?;

    monitor.failQuery(1);
    const fallback = monitor.takeSettledUpdate().?;
    try std.testing.expect(fallback.light);
    try std.testing.expect(fallback.rgb == null);
    try std.testing.expect(monitor.takeQueryRequest(10_000) == null);
}

test "theme monitor consumes OSC 11 long after query timeout without forwarding" {
    var monitor = Monitor{};
    monitor.start();
    for (dark_response) |byte| _ = monitor.feed(byte, 0);
    try beginBackgroundSampleForTest(&monitor, 0);

    monitor.poll(background_response_timeout_ms + 2);
    try std.testing.expect(!monitor.takeSettledUpdate().?.light);

    // Far past any former late-ownership window; still must not forward.
    const late_ms = background_response_timeout_ms * 5;
    for ("\x1b]11;rgb:0000/0000/0000\x07") |byte| {
        try std.testing.expect(switch (monitor.feed(byte, late_ms)) {
            .pending, .consumed => true,
            .forward, .clipboard_packet, .clipboard_mode => false,
        });
    }
    try std.testing.expect(monitor.takeSettledUpdate() == null);
}

test "theme monitor forwards a timed out partial candidate exactly once" {
    var monitor = Monitor{};
    monitor.start();
    for ("\x1b[") |byte| _ = monitor.feed(byte, 0);
    try std.testing.expect(monitor.hasPendingInput());

    monitor.poll(response_idle_timeout_ms);
    var forwarded: [2]u8 = undefined;
    for (&forwarded) |*byte| {
        byte.* = monitor.takeDeferredByte().?;
        try std.testing.expect(monitor.hasPendingInput());
        try std.testing.expect(monitor.consumeDeferredInputDispatch());
    }
    try std.testing.expectEqualStrings("\x1b[", &forwarded);
    try std.testing.expect(monitor.takeDeferredByte() == null);
    try std.testing.expect(!monitor.hasPendingInput());
}

test "theme monitor separates user escape from an adjacent terminal response" {
    var monitor = Monitor{};
    monitor.start();
    for (dark_response) |byte| _ = monitor.feed(byte, 0);
    try std.testing.expectEqual(QueryRequest.response_fence, monitor.takeQueryRequest(0).?);

    try std.testing.expect(monitor.feed(0x1b, 1) == .pending);
    const forwarded = monitor.feed(response_fence[0], 1).forward;
    try std.testing.expectEqualStrings("\x1b", forwarded.slice());
    for (response_fence[1..]) |byte| _ = monitor.feed(byte, 1);

    try std.testing.expectEqual(QueryRequest.background, monitor.takeQueryRequest(2).?);
}

test "theme monitor forwards malformed primary device attributes" {
    var monitor = Monitor{};
    monitor.start();

    var forwarded: [5]u8 = undefined;
    var forwarded_len: usize = 0;
    for ("\x1b[?;c") |byte| switch (monitor.feed(byte, 0)) {
        .forward => |bytes| {
            @memcpy(forwarded[forwarded_len..][0..bytes.len], bytes.slice());
            forwarded_len += bytes.len;
        },
        .pending => {},
        .consumed, .clipboard_packet, .clipboard_mode => return error.TestExpectedForward,
    };

    try std.testing.expectEqualStrings("\x1b[?;c", forwarded[0..forwarded_len]);
}

test "theme monitor discards incomplete OSC 11 on idle timeout with one trace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ root, "theme-osc11-idle.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "theme");

    var monitor = Monitor{};
    monitor.start();
    const incomplete = "\x1b]11;rgb:ffff";
    for (incomplete) |byte| _ = monitor.feed(byte, 0);

    monitor.poll(response_idle_timeout_ms);
    try std.testing.expect(monitor.takeDeferredByte() == null);
    try std.testing.expectEqual(@as(u8, 0), monitor.candidate_len);

    debug_trace.shutdown();
    const trace = try readTraceFileForTest(alloc, trace_path);
    defer alloc.free(trace);
    const needle = try alloc.print(
        "theme osc11 candidate dropped bytes={d} reason=osc11_idle_timeout",
        .{incomplete.len},
    );
    defer alloc.free(needle);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, needle));
    try std.testing.expect(std.mem.find(u8, trace, "ffff") == null);
}

test "theme monitor idle discard does not swallow CSI partials" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ root, "theme-csi-idle.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "theme");

    var monitor = Monitor{};
    monitor.start();
    for ("\x1b[") |byte| _ = monitor.feed(byte, 0);
    monitor.poll(response_idle_timeout_ms);

    try std.testing.expect(monitor.takeDeferredByte() != null);
    _ = monitor.consumeDeferredInputDispatch();
    try std.testing.expect(monitor.takeDeferredByte() != null);
    _ = monitor.consumeDeferredInputDispatch();

    debug_trace.shutdown();
    const trace = try readTraceFileForTest(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "osc11_idle_timeout") == null);
}

fn readTraceFileForTest(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return try io_mod.readFileToEnd(alloc, &file, 8192);
}

test "theme monitor coalesces a notification during a background sample" {
    var monitor = Monitor{};
    monitor.start();
    for (dark_response) |byte| _ = monitor.feed(byte, 0);
    try beginBackgroundSampleForTest(&monitor, 0);

    for (light_response) |byte| _ = monitor.feed(byte, 3);
    try std.testing.expect(monitor.takeQueryRequest(3) == null);

    for ("\x1b]11;rgb:0000/0000/0000\x07") |byte| _ = monitor.feed(byte, 4);
    for (response_fence) |byte| _ = monitor.feed(byte, 5);
    try std.testing.expect(monitor.takeSettledUpdate() == null);

    try beginBackgroundSampleForTest(&monitor, 6);
    for ("\x1b]11;rgb:ffff/ffff/ffff\x07") |byte| _ = monitor.feed(byte, 9);
    for (response_fence) |byte| _ = monitor.feed(byte, 10);
    try std.testing.expect(monitor.takeSettledUpdate().?.light);
}

test "theme monitor remains idle without a theme notification" {
    var monitor = Monitor{};
    monitor.start();

    try std.testing.expect(monitor.takeQueryRequest(0) == null);
    try std.testing.expect(monitor.takeQueryRequest(1000) == null);
    try std.testing.expect(monitor.takeQueryRequest(60_000) == null);
}

test "theme monitor forwards a full malformed OSC candidate without dropping its next byte" {
    var monitor = Monitor{};
    monitor.start();
    for (dark_response) |byte| _ = monitor.feed(byte, 0);
    try std.testing.expectEqual(QueryRequest.response_fence, monitor.takeQueryRequest(0).?);

    var candidate: [max_candidate_bytes]u8 = undefined;
    @memcpy(candidate[0..osc11_prefix.len], osc11_prefix);
    @memset(candidate[osc11_prefix.len..], 'x');
    for (candidate) |byte| {
        try std.testing.expect(switch (monitor.feed(byte, 1)) {
            .pending => true,
            .consumed, .forward, .clipboard_packet, .clipboard_mode => false,
        });
    }

    const forwarded = switch (monitor.feed('y', 1)) {
        .forward => |bytes| bytes,
        .pending, .consumed, .clipboard_packet, .clipboard_mode => return error.TestExpectedForward,
    };
    try std.testing.expectEqual(@as(usize, max_candidate_bytes + 1), forwarded.slice().len);
    try std.testing.expectEqual(@as(u8, 'y'), forwarded.slice()[max_candidate_bytes]);
}

test "theme monitor rearms notifications once per interval after startup" {
    var monitor = Monitor{};
    try std.testing.expect(!monitor.takeRearmRequest(0));

    monitor.start();
    // Startup has just turned notifications on, so the first check only
    // schedules the next rearm.
    try std.testing.expect(!monitor.takeRearmRequest(1_000));
    try std.testing.expect(!monitor.takeRearmRequest(1_000 + mode_rearm.interval_ms - 1));
    try std.testing.expect(monitor.takeRearmRequest(1_000 + mode_rearm.interval_ms));
    try std.testing.expect(!monitor.takeRearmRequest(1_000 + mode_rearm.interval_ms + 1));
}

test "theme monitor rearms at once on request" {
    var monitor = Monitor{};
    monitor.start();
    try std.testing.expect(!monitor.takeRearmRequest(0));

    monitor.requestRearm();
    try std.testing.expect(monitor.takeRearmRequest(1));
    try std.testing.expect(!monitor.takeRearmRequest(2));
    try std.testing.expect(monitor.takeRearmRequest(1 + mode_rearm.interval_ms));
}

test "theme monitor waits for a running theme refresh before it rearms" {
    var monitor = Monitor{};
    monitor.start();
    monitor.requestRearm();

    for (light_response) |byte| _ = monitor.feed(byte, 0);
    try std.testing.expect(!monitor.takeRearmRequest(0));
    try std.testing.expectEqual(QueryRequest.response_fence, monitor.takeQueryRequest(0).?);
    try std.testing.expect(!monitor.takeRearmRequest(1));

    monitor.poll(background_response_timeout_ms);
    try std.testing.expect(monitor.takeSettledUpdate().?.light);
    try std.testing.expect(monitor.takeRearmRequest(background_response_timeout_ms));
}

test "theme monitor settles a rearm answer for an unchanged theme" {
    var monitor = Monitor{};
    monitor.start();
    monitor.requestRearm();
    try std.testing.expect(monitor.takeRearmRequest(0));

    // The color scheme answer starts the same fenced background sample as a
    // notification, and settles to the terminal's current colors.
    for (dark_response) |byte| _ = monitor.feed(byte, 1);
    try beginBackgroundSampleForTest(&monitor, 1);
    for ("\x1b]11;rgb:1c1c/1c1c/1c1c\x1b\\") |byte| _ = monitor.feed(byte, 4);
    for (response_fence) |byte| _ = monitor.feed(byte, 5);

    const update = monitor.takeSettledUpdate().?;
    try std.testing.expect(!update.light);
    try std.testing.expectEqual(@as(u8, 0x1c), update.rgb.?.r);
    try std.testing.expect(monitor.takeQueryRequest(6) == null);
}

test "theme monitor hands clipboard replies to the clipboard reader" {
    var monitor = Monitor{};
    monitor.start();

    const packet_prefix = "\x1b]5522;";
    for (packet_prefix[0 .. packet_prefix.len - 1]) |byte| {
        try std.testing.expect(monitor.feed(byte, 0) == .pending);
    }
    try std.testing.expect(monitor.feed(packet_prefix[packet_prefix.len - 1], 0) == .clipboard_packet);
    try std.testing.expect(!monitor.hasPendingInput());

    const mode_report = "\x1b[?5522;2$y";
    for (mode_report[0 .. mode_report.len - 1]) |byte| {
        try std.testing.expect(monitor.feed(byte, 1) == .pending);
    }
    try std.testing.expectEqual(
        FeedResult{ .clipboard_mode = .supported },
        monitor.feed(mode_report[mode_report.len - 1], 1),
    );
    try std.testing.expect(!monitor.hasPendingInput());
}

test "theme monitor keeps forwarding OSC 52 and fencing beside clipboard replies" {
    var monitor = Monitor{};
    monitor.start();
    for (dark_response) |byte| _ = monitor.feed(byte, 0);
    try std.testing.expectEqual(QueryRequest.response_fence, monitor.takeQueryRequest(0).?);

    for ("\x1b[?5522;0$y") |byte| _ = monitor.feed(byte, 1);
    for (response_fence) |byte| _ = monitor.feed(byte, 2);
    try std.testing.expectEqual(QueryRequest.background, monitor.takeQueryRequest(3).?);

    const osc52 = "\x1b]52;c;dGV4dA==\x07";
    var forwarded: [osc52.len]u8 = undefined;
    var forwarded_len: usize = 0;
    for (osc52) |byte| switch (monitor.feed(byte, 4)) {
        .forward => |bytes| {
            @memcpy(forwarded[forwarded_len..][0..bytes.len], bytes.slice());
            forwarded_len += bytes.len;
        },
        .pending => {},
        .consumed, .clipboard_packet, .clipboard_mode => return error.TestExpectedForward,
    };
    try std.testing.expectEqualStrings(osc52, forwarded[0..forwarded_len]);
}

test "theme monitor holds a stalled clipboard reply start, then drops it" {
    var monitor = Monitor{};
    monitor.start();

    // Past the short reply timeout the start is still held, not typed, and
    // its late rest completes the packet.
    for ("\x1b]55") |byte| try std.testing.expect(monitor.feed(byte, 0) == .pending);
    monitor.poll(response_idle_timeout_ms + 1);
    try std.testing.expect(monitor.hasPendingInput());
    try std.testing.expect(monitor.takeDeferredByte() == null);
    for ("22") |byte| try std.testing.expect(monitor.feed(byte, 500) == .pending);
    try std.testing.expect(monitor.feed(';', 500) == .clipboard_packet);
    try std.testing.expect(!monitor.takeDroppedClipboardStart());

    // A start that stalls for the whole packet timeout is dropped, not typed.
    for ("\x1b[?55") |byte| try std.testing.expect(monitor.feed(byte, 1000) == .pending);
    monitor.poll(1000 + clipboard_protocol.packet_idle_timeout_ms - 1);
    try std.testing.expect(monitor.hasPendingInput());
    monitor.poll(1000 + clipboard_protocol.packet_idle_timeout_ms);
    try std.testing.expect(!monitor.hasPendingInput());
    try std.testing.expect(monitor.takeDeferredByte() == null);
    try std.testing.expect(monitor.takeDroppedClipboardStart());
    try std.testing.expect(!monitor.takeDroppedClipboardStart());
}

test "theme monitor drops a broken clipboard reply start and reads the next byte" {
    var monitor = Monitor{};
    monitor.start();
    for ("\x1b]55") |byte| try std.testing.expect(monitor.feed(byte, 0) == .pending);
    const forwarded = switch (monitor.feed('a', 1)) {
        .forward => |bytes| bytes,
        .pending, .consumed, .clipboard_packet, .clipboard_mode => return error.TestExpectedForward,
    };
    try std.testing.expectEqualStrings("a", forwarded.slice());
    try std.testing.expect(!monitor.hasPendingInput());

    for ("\x1b[?5522;2$") |byte| try std.testing.expect(monitor.feed(byte, 2) == .pending);
    try std.testing.expect(monitor.feed(0x1b, 3) == .pending);
    try std.testing.expectEqual(@as(u8, 1), monitor.candidate_len);
}

test "theme monitor types a short start that may be a key when no clipboard request is open" {
    const starts = [_][]const u8{ "\x1b", "\x1b]", "\x1b]5", "\x1b[?", "\x1b[?5" };
    for (starts) |start| {
        var monitor = Monitor{};
        monitor.start();
        for (start) |byte| try std.testing.expect(monitor.feed(byte, 0) == .pending);
        monitor.poll(response_idle_timeout_ms);
        try std.testing.expect(!monitor.takeDroppedClipboardStart());
        var typed: usize = 0;
        while (monitor.takeDeferredByte()) |_| {
            typed += 1;
            try std.testing.expect(monitor.consumeDeferredInputDispatch());
        }
        try std.testing.expectEqual(start.len, typed);
    }
}

test "theme monitor passes an Escape key right before a clipboard reply on once" {
    var monitor = Monitor{};
    monitor.start();
    try std.testing.expect(monitor.feed(0x1b, 0) == .pending);
    // The reply's ESC comes before the key's timeout: one ESC goes on as the
    // key, and the other starts the reply.
    const forwarded = switch (monitor.feed(0x1b, 10)) {
        .forward => |bytes| bytes,
        .pending, .consumed, .clipboard_packet, .clipboard_mode => return error.TestExpectedForward,
    };
    try std.testing.expectEqualStrings("\x1b", forwarded.slice());
    for ("]5522") |byte| try std.testing.expect(monitor.feed(byte, 10) == .pending);
    try std.testing.expect(monitor.feed(';', 10) == .clipboard_packet);
}

test "theme monitor holds clipboard reply starts but ESC and ESC [ while a request is open" {
    const held = [_][]const u8{ "\x1b]", "\x1b]5", "\x1b[?", "\x1b[?5" };
    for (held) |start| {
        var monitor = Monitor{};
        monitor.start();
        monitor.expectClipboardReply(true);
        for (start) |byte| try std.testing.expect(monitor.feed(byte, 0) == .pending);
        monitor.poll(response_idle_timeout_ms + 1);
        try std.testing.expect(monitor.hasPendingInput());
        monitor.poll(clipboard_protocol.packet_idle_timeout_ms);
        try std.testing.expect(!monitor.hasPendingInput());
        try std.testing.expect(monitor.takeDeferredByte() == null);
        try std.testing.expect(monitor.takeDroppedClipboardStart());
    }

    // These start the Escape and arrow keys, so they are typed as before.
    const keys = [_][]const u8{ "\x1b", "\x1b[" };
    for (keys) |start| {
        var monitor = Monitor{};
        monitor.start();
        monitor.expectClipboardReply(true);
        for (start) |byte| try std.testing.expect(monitor.feed(byte, 0) == .pending);
        monitor.poll(response_idle_timeout_ms);
        try std.testing.expect(!monitor.takeDroppedClipboardStart());
        var typed: usize = 0;
        while (monitor.takeDeferredByte()) |_| {
            typed += 1;
            try std.testing.expect(monitor.consumeDeferredInputDispatch());
        }
        try std.testing.expectEqual(start.len, typed);
    }
}

test "theme monitor still reads device attributes while a clipboard request is open" {
    var monitor = Monitor{};
    monitor.start();
    monitor.expectClipboardReply(true);
    for ("\x1b[?") |byte| try std.testing.expect(monitor.feed(byte, 0) == .pending);
    monitor.poll(500);
    try std.testing.expect(monitor.hasPendingInput());
    const rest = "62;22;52c";
    for (rest[0 .. rest.len - 1]) |byte| try std.testing.expect(monitor.feed(byte, 500) == .pending);
    try std.testing.expect(monitor.feed(rest[rest.len - 1], 500) == .consumed);
    try std.testing.expect(!monitor.takeDroppedClipboardStart());
}
