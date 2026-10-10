const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const paste_end_marker = "\x1b[201~";

pub const Owner = enum {
    none,
    composer,
    decision_prompt,
    question_freeform,
    approval_amendment,
    auth_code,
};

pub const InputLimits = struct {
    composer_bytes: usize = 8 * 1024 * 1024,
    decision_bytes: usize = 4096,

    pub fn single(max_bytes: usize) InputLimits {
        return .{
            .composer_bytes = max_bytes,
            .decision_bytes = max_bytes,
        };
    }

    pub fn forOwner(self: InputLimits, owner: Owner) usize {
        return switch (owner) {
            .composer => self.composer_bytes,
            .none, .decision_prompt, .question_freeform, .approval_amendment, .auth_code => self.decision_bytes,
        };
    }
};

pub const default_input_limits: InputLimits = .{};

pub const FinalizeFailure = struct {
    owner: Owner,
    error_name: []const u8,
};

pub const ResetReason = union(enum) {
    decision_prompt_active,
    session_reset,
    shutdown,
    finalize_failed: FinalizeFailure,
    input_limit: Owner,
    invalid_utf8,
    new_paste_stale_state,
    unsafe_suffix,
};

pub const BoundaryState = enum {
    capturing,
    end_candidate,
    unsafe,
};

pub const Settlement = enum {
    none,
    finish,
    reject,
};

pub const State = struct {
    owner: Owner = .none,
    boundary: BoundaryState = .capturing,
    unsafe_suffix_bytes: usize = 0,
    end_match_len: usize = 0,
    end_candidate_buffer_len: usize = 0,
    end_candidate_overflow_bytes: usize = 0,
    overflow_bytes: usize = 0,
    buffer_limit: usize = std.math.maxInt(usize),
    decision_bytes: usize = 0,
    buffer: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.resetWithTrace(.shutdown);
        self.buffer.deinit(alloc);
    }

    pub fn active(self: *const State) bool {
        return self.owner != .none;
    }

    pub fn begin(self: *State, owner: Owner, max_buffer_len: usize) void {
        self.resetWithTrace(.new_paste_stale_state);
        self.owner = owner;
        self.buffer_limit = max_buffer_len;
    }

    pub fn consumeByte(
        self: *State,
        alloc: Allocator,
        byte: u8,
    ) Allocator.Error!void {
        switch (self.boundary) {
            .capturing => {},
            .end_candidate => {
                self.boundary = .unsafe;
                self.unsafe_suffix_bytes +|= 1;
                return;
            },
            .unsafe => {
                self.unsafe_suffix_bytes +|= 1;
                return;
            },
        }

        switch (self.owner) {
            .none => return,
            .decision_prompt => self.decision_bytes +|= 1,
            .composer, .question_freeform, .approval_amendment, .auth_code => {
                if (byte == 0x1b) {
                    self.end_candidate_buffer_len = self.buffer.items.len;
                    self.end_candidate_overflow_bytes = self.overflow_bytes;
                }
                const captured_byte: u8 = if (self.owner == .question_freeform and byte == '\t')
                    ' '
                else
                    byte;
                const is_printable = captured_byte >= 32 and captured_byte != 127;
                const accepts_byte = switch (self.owner) {
                    .composer => captured_byte == '\r' or captured_byte == '\n' or captured_byte == '\t' or is_printable,
                    .question_freeform => captured_byte == '\r' or captured_byte == '\n' or is_printable,
                    .approval_amendment => captured_byte == '\r' or captured_byte == '\n' or captured_byte == '\t' or is_printable,
                    .auth_code => is_printable,
                    .none, .decision_prompt => false,
                };
                if (accepts_byte) {
                    if (self.buffer.items.len < self.buffer_limit) {
                        try self.buffer.append(alloc, captured_byte);
                    } else {
                        self.overflow_bytes +|= 1;
                    }
                }
            },
        }

        if (!self.advanceEndMatcher(byte)) return;

        switch (self.owner) {
            .none => {},
            .decision_prompt => self.decision_bytes -|= paste_end_marker.len,
            .composer, .question_freeform, .approval_amendment, .auth_code => {
                self.buffer.items.len = @min(
                    self.buffer.items.len,
                    self.end_candidate_buffer_len,
                );
                self.overflow_bytes = self.end_candidate_overflow_bytes;
            },
        }
        self.end_match_len = 0;
        self.end_candidate_buffer_len = 0;
        self.end_candidate_overflow_bytes = 0;
        self.boundary = .end_candidate;
    }

    pub fn settleDeliveryEpoch(self: *const State) Settlement {
        if (!self.active()) return .none;
        return switch (self.boundary) {
            .capturing => .none,
            .end_candidate => .finish,
            .unsafe => if (self.confirmedOverflowBytes() > 0) .finish else .reject,
        };
    }

    pub fn byteCount(self: *const State) usize {
        return switch (self.owner) {
            .none => 0,
            .decision_prompt => self.decision_bytes,
            .composer, .question_freeform, .approval_amendment, .auth_code => self.buffer.items.len,
        };
    }

    pub fn attemptedBytes(self: *const State) usize {
        return self.buffer.items.len +| self.overflow_bytes;
    }

    pub fn observedBytes(self: *const State) usize {
        return self.attemptedBytes() +|
            self.decision_bytes +|
            self.unsafe_suffix_bytes;
    }

    pub fn confirmedOverflowBytes(self: *const State) usize {
        if (self.end_match_len > 0) return self.end_candidate_overflow_bytes;
        return self.overflow_bytes;
    }

    /// Ends framing while retaining captured bytes for synchronous handling.
    pub fn beginHandling(self: *State) void {
        self.owner = .none;
        self.boundary = .capturing;
        self.unsafe_suffix_bytes = 0;
        self.end_match_len = 0;
        self.end_candidate_buffer_len = 0;
        self.end_candidate_overflow_bytes = 0;
    }

    /// Stops retaining payload bytes while preserving end-marker detection.
    pub fn continueDiscarding(self: *State) void {
        self.owner = .decision_prompt;
        self.decision_bytes = 0;
    }

    /// Clears a capture after its bytes have been handled successfully.
    pub fn finishHandled(self: *State) void {
        self.clearRetainingCapacity();
    }

    pub fn finishSecretHandled(self: *State) void {
        self.clearRetainingCapacity();
        if (self.buffer.capacity > 0) @memset(self.buffer.allocatedSlice(), 0);
    }

    pub fn resetSecretWithTrace(self: *State, reason: ResetReason) void {
        std.debug.assert(self.owner == .auth_code);
        self.resetWithTrace(reason);
    }

    /// Logs any discarded capture before returning to the inactive state.
    pub fn resetWithTrace(self: *State, reason: ResetReason) void {
        const clear_secret = self.owner == .auth_code;
        switch (reason) {
            .finalize_failed => |failure| {
                if (self.buffer.items.len > 0) {
                    debug_trace.logf(
                        "input",
                        "{s} paste dropped bytes={d} reason=finalize_failed error={s}",
                        .{ ownerLabel(failure.owner), self.buffer.items.len, failure.error_name },
                    );
                }
            },
            .input_limit => |owner| {
                const dropped_bytes = if (owner == .composer)
                    self.attemptedBytes()
                else
                    self.buffer.items.len;
                debug_trace.logf(
                    "input",
                    "{s} paste dropped bytes={d} reason=input_limit",
                    .{ ownerLabel(owner), dropped_bytes },
                );
            },
            .invalid_utf8 => {
                if (self.buffer.items.len > 0) {
                    debug_trace.logf(
                        "input",
                        "{s} paste dropped bytes={d} reason=invalid_utf8",
                        .{ ownerLabel(self.owner), self.buffer.items.len },
                    );
                }
            },
            .new_paste_stale_state => {
                if (self.decision_bytes > 0) {
                    debug_trace.logf(
                        "input",
                        "decision prompt paste dropped bytes={d} reason=new_paste_stale_state",
                        .{self.decision_bytes},
                    );
                }
                if (self.buffer.items.len > 0) {
                    debug_trace.logf(
                        "input",
                        "{s} paste dropped bytes={d} reason=new_paste_stale_state",
                        .{ ownerLabel(self.owner), self.buffer.items.len },
                    );
                }
            },
            .unsafe_suffix => debug_trace.logf(
                "input",
                "{s} paste dropped bytes={d} reason=unsafe_suffix",
                .{ ownerLabel(self.owner), self.observedBytes() },
            ),
            .decision_prompt_active, .session_reset, .shutdown => {
                switch (self.owner) {
                    .decision_prompt => debug_trace.logf(
                        "input",
                        "decision prompt paste dropped bytes={d} reason={s}",
                        .{ self.decision_bytes, resetReasonName(reason) },
                    ),
                    .composer, .question_freeform, .approval_amendment, .auth_code => {
                        if (self.buffer.items.len > 0) {
                            debug_trace.logf(
                                "input",
                                "{s} paste dropped bytes={d} reason={s}",
                                .{ ownerLabel(self.owner), self.buffer.items.len, resetReasonName(reason) },
                            );
                        }
                    },
                    .none => {},
                }
            },
        }

        self.clearRetainingCapacity();
        if (clear_secret and self.buffer.capacity > 0) {
            @memset(self.buffer.allocatedSlice(), 0);
        }
    }

    fn clearRetainingCapacity(self: *State) void {
        self.owner = .none;
        self.boundary = .capturing;
        self.unsafe_suffix_bytes = 0;
        self.end_match_len = 0;
        self.end_candidate_buffer_len = 0;
        self.end_candidate_overflow_bytes = 0;
        self.overflow_bytes = 0;
        self.buffer_limit = std.math.maxInt(usize);
        self.decision_bytes = 0;
        self.buffer.clearRetainingCapacity();
    }

    fn advanceEndMatcher(self: *State, byte: u8) bool {
        if (byte == 0x1b) {
            self.end_match_len = 1;
            return false;
        }
        if (self.end_match_len == 0) return false;
        if (byte != paste_end_marker[self.end_match_len]) {
            self.end_match_len = 0;
            return false;
        }

        self.end_match_len += 1;
        return self.end_match_len == paste_end_marker.len;
    }
};

fn resetReasonName(reason: ResetReason) []const u8 {
    return switch (reason) {
        .decision_prompt_active => "decision_prompt_active",
        .session_reset => "session_reset",
        .shutdown => "shutdown",
        .finalize_failed => "finalize_failed",
        .input_limit => "input_limit",
        .invalid_utf8 => "invalid_utf8",
        .new_paste_stale_state => "new_paste_stale_state",
        .unsafe_suffix => "unsafe_suffix",
    };
}

fn ownerLabel(owner: Owner) []const u8 {
    return switch (owner) {
        .none, .composer => "composer",
        .decision_prompt => "decision prompt",
        .question_freeform => "question freeform",
        .approval_amendment => "approval amendment",
        .auth_code => "authorization code",
    };
}

test "authorization code paste zeroes retained capacity after handling and reset" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);

    state.begin(.auth_code, 64);
    for ("temporary-code") |byte| try state.consumeByte(std.testing.allocator, byte);
    try std.testing.expect(state.buffer.capacity > 0);
    try std.testing.expectEqual(@as(u8, 't'), state.buffer.allocatedSlice()[0]);
    state.beginHandling();
    state.finishSecretHandled();
    for (state.buffer.allocatedSlice()) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    state.begin(.auth_code, 64);
    for ("second-code") |byte| try state.consumeByte(std.testing.allocator, byte);
    state.resetSecretWithTrace(.session_reset);
    for (state.buffer.allocatedSlice()) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "decision paste counts content bytes and exact end marker only" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    state.begin(.decision_prompt, std.math.maxInt(usize));

    for ("abc") |byte| {
        try state.consumeByte(std.testing.allocator, byte);
    }
    for (paste_end_marker[0 .. paste_end_marker.len - 1]) |byte| {
        try state.consumeByte(std.testing.allocator, byte);
    }
    try state.consumeByte(std.testing.allocator, paste_end_marker[paste_end_marker.len - 1]);
    try std.testing.expectEqual(@as(usize, 3), state.decision_bytes);
    try std.testing.expectEqual(Owner.decision_prompt, state.owner);
    try std.testing.expectEqual(BoundaryState.end_candidate, state.boundary);
    try std.testing.expectEqual(Settlement.finish, state.settleDeliveryEpoch());
}

test "decision paste treats incomplete and parameterized end candidates as content" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    state.begin(.decision_prompt, std.math.maxInt(usize));

    const payload = "\x1b[20\x1b[201;1~x";
    for (payload) |byte| {
        try state.consumeByte(std.testing.allocator, byte);
    }
    for (paste_end_marker) |byte| {
        try state.consumeByte(std.testing.allocator, byte);
    }
    try std.testing.expectEqual(payload.len, state.decision_bytes);
    try std.testing.expectEqual(Settlement.finish, state.settleDeliveryEpoch());
}

test "composer paste preserves safe bytes and tracks bounded overflow" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    state.begin(.composer, 3);

    for ("abcd\x01") |byte| {
        try state.consumeByte(std.testing.allocator, byte);
    }
    for (paste_end_marker) |byte| {
        try state.consumeByte(std.testing.allocator, byte);
    }
    try std.testing.expectEqualStrings("abc", state.buffer.items);
    try std.testing.expectEqual(@as(usize, 1), state.overflow_bytes);
    try std.testing.expectEqual(@as(usize, 4), state.attemptedBytes());
}

test "composer overflow excludes a possible exact end marker" {
    var exact: State = .{};
    defer exact.deinit(std.testing.allocator);
    exact.begin(.composer, 1);

    try exact.consumeByte(std.testing.allocator, 'x');
    for (paste_end_marker[0 .. paste_end_marker.len - 1]) |byte| {
        try exact.consumeByte(std.testing.allocator, byte);
        try std.testing.expectEqual(@as(usize, 0), exact.confirmedOverflowBytes());
    }
    try exact.consumeByte(std.testing.allocator, paste_end_marker[paste_end_marker.len - 1]);
    try std.testing.expectEqual(@as(usize, 0), exact.confirmedOverflowBytes());

    var mismatch: State = .{};
    defer mismatch.deinit(std.testing.allocator);
    mismatch.begin(.composer, 1);

    try mismatch.consumeByte(std.testing.allocator, 'x');
    for ("\x1b[20x") |byte| {
        try mismatch.consumeByte(std.testing.allocator, byte);
    }
    try std.testing.expect(mismatch.confirmedOverflowBytes() > 0);
}

test "composer overflow rejection takes precedence over an unsafe suffix" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    state.begin(.composer, 1);

    for ("xy") |byte| {
        try state.consumeByte(std.testing.allocator, byte);
    }
    for (paste_end_marker) |byte| {
        try state.consumeByte(std.testing.allocator, byte);
    }
    try state.consumeByte(std.testing.allocator, 'z');

    try std.testing.expectEqual(BoundaryState.unsafe, state.boundary);
    try std.testing.expect(state.confirmedOverflowBytes() > 0);
    try std.testing.expectEqual(Settlement.finish, state.settleDeliveryEpoch());
}

test "discarding remainder preserves buffered bytes and end-marker progress" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    state.begin(.composer, std.math.maxInt(usize));

    try state.consumeByte(std.testing.allocator, 'x');
    try state.consumeByte(std.testing.allocator, 0x1b);
    state.continueDiscarding();
    for (paste_end_marker[1..]) |byte| {
        try state.consumeByte(std.testing.allocator, byte);
    }

    try std.testing.expectEqual(Settlement.finish, state.settleDeliveryEpoch());
    try std.testing.expectEqualStrings("x", state.buffer.items);
    try std.testing.expectEqual(@as(usize, 0), state.decision_bytes);
}

test "begin handling makes framing inactive and retains captured bytes" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    state.begin(.composer, std.math.maxInt(usize));
    try state.buffer.appendSlice(std.testing.allocator, "captured");
    state.end_match_len = 2;

    state.beginHandling();

    try std.testing.expect(!state.active());
    try std.testing.expectEqualStrings("captured", state.buffer.items);
    try std.testing.expectEqual(@as(usize, 0), state.end_match_len);
}

test "question and approval paste keep their owner-specific safe bytes" {
    var question: State = .{};
    defer question.deinit(std.testing.allocator);
    question.begin(.question_freeform, std.math.maxInt(usize));
    for ("one\r\ttwo\x03" ++ paste_end_marker) |byte| {
        try question.consumeByte(std.testing.allocator, byte);
    }
    try std.testing.expectEqualStrings("one\r two", question.buffer.items);

    var amendment: State = .{};
    defer amendment.deinit(std.testing.allocator);
    amendment.begin(.approval_amendment, std.math.maxInt(usize));
    const payload = "pasted amendment marker " ++
        "\\x1b[200~" ++
        "\x1b[200~" ++
        "\x1b[201;1~" ++
        "\t\r\x03";
    for (payload ++ paste_end_marker) |byte| {
        try amendment.consumeByte(std.testing.allocator, byte);
    }
    try std.testing.expectEqualStrings(
        "pasted amendment marker \\x1b[200~[200~[201;1~\t\r",
        amendment.buffer.items,
    );
}

test "capturing remains active when a delivery epoch ends before the marker" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    state.begin(.composer, std.math.maxInt(usize));
    try state.consumeByte(std.testing.allocator, 'x');

    try std.testing.expect(state.active());
    try std.testing.expectEqual(BoundaryState.capturing, state.boundary);
    try std.testing.expectEqual(Settlement.none, state.settleDeliveryEpoch());
}

test "end candidate stays paste owned until delivery epoch settlement" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    state.begin(.composer, std.math.maxInt(usize));
    for ("safe" ++ paste_end_marker) |byte| {
        try state.consumeByte(std.testing.allocator, byte);
    }

    try std.testing.expect(state.active());
    try std.testing.expectEqualStrings("safe", state.buffer.items);
    try std.testing.expectEqual(BoundaryState.end_candidate, state.boundary);
    try std.testing.expectEqual(Settlement.finish, state.settleDeliveryEpoch());
}

test "any same-epoch suffix makes the candidate sticky unsafe" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    state.begin(.composer, std.math.maxInt(usize));
    for ("safe" ++ paste_end_marker) |byte| {
        try state.consumeByte(std.testing.allocator, byte);
    }
    try state.consumeByte(std.testing.allocator, '\r');
    for (paste_end_marker) |byte| {
        try state.consumeByte(std.testing.allocator, byte);
    }

    try std.testing.expect(state.active());
    try std.testing.expectEqualStrings("safe", state.buffer.items);
    try std.testing.expectEqual(BoundaryState.unsafe, state.boundary);
    try std.testing.expectEqual(@as(usize, 1 + paste_end_marker.len), state.unsafe_suffix_bytes);
    try std.testing.expectEqual(Settlement.reject, state.settleDeliveryEpoch());
}

test "traced reset reports dropped captures and clears only paste state" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ root, "paste-reset.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "input");

    var decision: State = .{};
    defer decision.deinit(alloc);
    decision.begin(.decision_prompt, std.math.maxInt(usize));
    decision.resetWithTrace(.session_reset);

    var composer: State = .{};
    defer composer.deinit(alloc);
    composer.begin(.composer, std.math.maxInt(usize));
    try composer.buffer.appendSlice(alloc, "buffered");
    composer.resetWithTrace(.shutdown);

    var stale: State = .{};
    defer stale.deinit(alloc);
    stale.decision_bytes = 3;
    try stale.buffer.appendSlice(alloc, "old");
    stale.resetWithTrace(.new_paste_stale_state);

    var failed: State = .{};
    defer failed.deinit(alloc);
    try failed.buffer.appendSlice(alloc, "pending");
    failed.resetWithTrace(.{ .finalize_failed = .{
        .owner = .composer,
        .error_name = "OutOfMemory",
    } });

    debug_trace.shutdown();
    const trace = try readTraceFileForTest(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "decision prompt paste dropped bytes=0 reason=session_reset") != null);
    try std.testing.expect(std.mem.find(u8, trace, "composer paste dropped bytes=8 reason=shutdown") != null);
    try std.testing.expect(std.mem.find(u8, trace, "decision prompt paste dropped bytes=3 reason=new_paste_stale_state") != null);
    try std.testing.expect(std.mem.find(u8, trace, "composer paste dropped bytes=3 reason=new_paste_stale_state") != null);
    try std.testing.expect(std.mem.find(u8, trace, "composer paste dropped bytes=7 reason=finalize_failed error=OutOfMemory") != null);
}

test "deinit traces an active capture once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ root, "paste-deinit.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "input");

    {
        var decision: State = .{};
        decision.begin(.decision_prompt, std.math.maxInt(usize));
        decision.deinit(alloc);
    }

    {
        var composer: State = .{};
        composer.begin(.composer, std.math.maxInt(usize));
        try composer.buffer.appendSlice(alloc, "pending");
        composer.deinit(alloc);
    }

    debug_trace.shutdown();
    const trace = try readTraceFileForTest(alloc, trace_path);
    defer alloc.free(trace);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "decision prompt paste dropped bytes=0 reason=shutdown"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "composer paste dropped bytes=7 reason=shutdown"));
}

fn readTraceFileForTest(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 8192);
}
