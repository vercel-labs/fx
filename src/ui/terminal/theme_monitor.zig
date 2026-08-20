const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const theme_protocol = @import("theme_protocol.zig");

// OSC 11 shares Escape's prefix: allow fragmented replies without imposing
// the cursor probe's full 100 ms delay on a standalone Escape key.
pub const response_idle_timeout_ms: i64 = 75;
pub const background_response_timeout_ms: i64 = 200;

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

    pub fn start(self: *Monitor) void {
        self.enabled = true;
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

    pub fn feed(self: *Monitor, byte: u8, now_ms: i64) FeedResult {
        if (!self.enabled) return forwardByte(byte);
        if (self.candidate_len == 0 and byte != 0x1b) return forwardByte(byte);
        if (self.candidate_len == 1 and byte == 0x1b) {
            self.candidate_deadline_ms = addMillis(now_ms, response_idle_timeout_ms);
            return forwardByte(byte);
        }
        if (self.candidate_len == self.candidate.len) return self.forwardCandidateWith(byte);

        self.candidate[self.candidate_len] = byte;
        self.candidate_len += 1;
        self.candidate_deadline_ms = addMillis(now_ms, response_idle_timeout_ms);

        const candidate = self.candidate[0..self.candidate_len];
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

        switch (classifyPrimaryDeviceAttributes(candidate)) {
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
                    .awaiting_response_fence = addMillis(now_ms, background_response_timeout_ms),
                };
                return .response_fence;
            },
            .background_ready => {
                self.theme_dirty = false;
                self.query_state = .{ .awaiting_background = .{
                    .deadline_ms = addMillis(now_ms, background_response_timeout_ms),
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
const primary_device_attributes_prefix = "\x1b[?";
const osc11_prefix = "\x1b]11;rgb:";

const ResponseStatus = enum { invalid, pending, complete };

fn classifyPrimaryDeviceAttributes(bytes: []const u8) ResponseStatus {
    if (std.mem.startsWith(u8, primary_device_attributes_prefix, bytes)) return .pending;
    if (!std.mem.startsWith(u8, bytes, primary_device_attributes_prefix)) return .invalid;

    const parameters = bytes[primary_device_attributes_prefix.len..];
    var expect_digit = true;
    for (parameters, 0..) |byte, index| {
        if (std.ascii.isDigit(byte)) {
            expect_digit = false;
            continue;
        }
        if (byte == ';' and !expect_digit) {
            expect_digit = true;
            continue;
        }
        if (byte == 'c') {
            return if (!expect_digit and index + 1 == parameters.len)
                .complete
            else
                .invalid;
        }
        return .invalid;
    }
    return .pending;
}

fn addMillis(now_ms: i64, duration_ms: i64) i64 {
    return std.math.add(i64, now_ms, duration_ms) catch std.math.maxInt(i64);
}

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
            .forward => false,
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
            .forward => false,
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
        .consumed => return error.TestExpectedForward,
    };

    try std.testing.expectEqualStrings("\x1b[?;c", forwarded[0..forwarded_len]);
}

test "theme monitor discards incomplete OSC 11 on idle timeout with one trace" {
    const alloc = std.testing.allocator;
    const io_mod = @import("../../core/shared/io.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "theme-osc11-idle.log" });
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
    const needle = try std.fmt.allocPrint(
        alloc,
        "theme osc11 candidate dropped bytes={d} reason=osc11_idle_timeout",
        .{incomplete.len},
    );
    defer alloc.free(needle);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, needle));
    try std.testing.expect(std.mem.find(u8, trace, "ffff") == null);
}

test "theme monitor idle discard does not swallow CSI partials" {
    const alloc = std.testing.allocator;
    const io_mod = @import("../../core/shared/io.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "theme-csi-idle.log" });
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
    const io_mod = @import("../../core/shared/io.zig");
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
            .consumed, .forward => false,
        });
    }

    const forwarded = switch (monitor.feed('y', 1)) {
        .forward => |bytes| bytes,
        .pending, .consumed => return error.TestExpectedForward,
    };
    try std.testing.expectEqual(@as(usize, max_candidate_bytes + 1), forwarded.slice().len);
    try std.testing.expectEqual(@as(u8, 'y'), forwarded.slice()[max_candidate_bytes]);
}
