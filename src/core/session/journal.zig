//! Shared byte-append/acknowledgement boundary. No storage, codec, allocator,
//! replay policy, or host-specific dependencies. Sequence numbers start at one;
//! byte offsets start at zero. A batch covers a contiguous sequence range.
const std = @import("std");

pub const Cursor = struct {
    seq: u64 = 0,
    committed_bytes: u64 = 0,
};

pub const Append = struct {
    expected: Cursor,
    next: Cursor,
    /// Borrowed only for the synchronous callback. The host must copy bytes it
    /// retains. The caller owns the encoding and its contiguous sequence range.
    bytes: []const u8,
};

pub const Outcome = union(enum) {
    /// The entire exact byte slice is durable at `expected.committed_bytes`.
    /// Acknowledging any cursor other than `next` is an uncertain outcome.
    committed: Cursor,
    /// Definitely no bytes written, with ownership and expected cursor still
    /// valid. Retrying the same range, including corrected bytes, is safe.
    not_written: anyerror,
    /// Bytes may have landed, including a partial write or failed durability
    /// barrier. Never report this as `not_written` just because an I/O errored.
    uncertain: anyerror,
    /// Ownership or the authoritative cursor differs. Never truncate to match.
    conflict,
};

pub const Host = struct {
    /// Borrowed for append's duration; neither pointer nor callback is retained.
    context: *anyopaque,
    /// Must serialize ownership/cursor validation with the append, and only
    /// acknowledge after the host's durability barrier. A host that deduplicates
    /// requests must verify exact content, not just sequence or byte length.
    append_fn: *const fn (context: *anyopaque, request: Append) Outcome,
};

/// Single-owner, synchronous state; not thread-safe. Do not fork by copying an
/// active journal, mutate its fields, or reinitialize from a speculative cursor.
/// This boundary trusts the host's durability/content/ownership assertions; it
/// cannot itself prove disk state or enforce a remote lease.
///
/// After uncertainty, conflict, or an invalid acknowledgement, discard this
/// instance. Reacquire authority, reconcile durable bytes using the owning
/// format's recovery policy, then create a NEW journal from the verified cursor.
/// There is deliberately no reset/retry-uncertain operation or retained payload.
pub const Journal = struct {
    /// Last acknowledged cursor (read-only to callers).
    cursor: Cursor = .{},
    blocked: bool = false,

    pub fn init(authoritative_cursor: Cursor) error{InvalidJournalCursor}!Journal {
        if ((authoritative_cursor.seq == 0) != (authoritative_cursor.committed_bytes == 0)) {
            return error.InvalidJournalCursor;
        }
        return .{ .cursor = authoritative_cursor };
    }

    pub fn ensure_available(self: *const Journal) error{JournalUnavailable}!void {
        if (self.blocked) return error.JournalUnavailable;
    }

    /// Borrows `host` and `bytes` for this call only. Local validation and
    /// confirmed no-write errors leave the cursor unchanged and permit retry.
    /// Already acknowledged ranges are rejected, not silently deduplicated.
    /// `first_seq...last_seq` describes the records encoded in the opaque bytes;
    /// validating the encoding itself is the caller's responsibility.
    pub fn append(self: *Journal, host: Host, first_seq: u64, last_seq: u64, bytes: []const u8) !Cursor {
        try self.ensure_available();
        const expected_first = std.math.add(u64, self.cursor.seq, 1) catch return error.JournalSequenceOverflow;
        if (first_seq != expected_first or last_seq < first_seq) return error.InvalidJournalSequence;
        if (bytes.len == 0) return error.EmptyJournalAppend;
        const next: Cursor = .{
            .seq = last_seq,
            .committed_bytes = std.math.add(u64, self.cursor.committed_bytes, bytes.len) catch return error.JournalSizeOverflow,
        };
        // Fence before crossing the host boundary, including against reentry.
        self.blocked = true;
        switch (host.append_fn(host.context, .{ .expected = self.cursor, .next = next, .bytes = bytes })) {
            .committed => |ack| {
                if (!std.meta.eql(ack, next)) return error.InvalidJournalAcknowledgement;
                self.cursor = ack;
                self.blocked = false;
                return ack;
            },
            .not_written => |err| {
                self.blocked = false;
                return err;
            },
            .uncertain => |err| return err,
            .conflict => return error.JournalConflict,
        }
    }
};

const TestHost = struct {
    mode: enum { commit, pre_write, lost_ack, partial, conflict, bad_ack } = .commit,
    storage: [128]u8 = undefined,
    length: usize = 0,
    cursor: Cursor = .{},
    calls: usize = 0,
    acknowledgement: Cursor = .{},

    fn host(self: *TestHost) Host {
        return .{ .context = self, .append_fn = append };
    }

    fn append(context: *anyopaque, request: Append) Outcome {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.mode == .pre_write) return .{ .not_written = error.BeforeWrite };
        if (self.mode == .conflict or !std.meta.eql(self.cursor, request.expected)) return .conflict;
        const length = if (self.mode == .partial) request.bytes.len / 2 else request.bytes.len;
        @memcpy(self.storage[self.length..][0..length], request.bytes[0..length]);
        self.length += length;
        if (self.mode == .partial) return .{ .uncertain = error.PartialWrite };
        self.cursor = request.next;
        if (self.mode == .lost_ack) return .{ .uncertain = error.AckLost };
        if (self.mode == .bad_ack) return .{ .committed = self.acknowledgement };
        return .{ .committed = self.cursor };
    }
};

test "journal validates ranges and commits single and batch bytes" {
    var host: TestHost = .{};
    var journal = try Journal.init(.{});
    try std.testing.expectError(error.InvalidJournalSequence, journal.append(host.host(), 2, 2, "x"));
    try std.testing.expectError(error.InvalidJournalSequence, journal.append(host.host(), 1, 0, "x"));
    try std.testing.expectError(error.EmptyJournalAppend, journal.append(host.host(), 1, 1, ""));
    try std.testing.expectEqual(@as(usize, 0), host.calls);
    try std.testing.expectEqual(Cursor{ .seq = 1, .committed_bytes = 4 }, try journal.append(host.host(), 1, 1, "one\n"));
    try std.testing.expectEqual(Cursor{ .seq = 3, .committed_bytes = 15 }, try journal.append(host.host(), 2, 3, "two\nthree\n!"));
    try std.testing.expectEqualStrings("one\ntwo\nthree\n!", host.storage[0..host.length]);
    // An acknowledged append is not a retry token, even with identical bytes.
    try std.testing.expectError(error.InvalidJournalSequence, journal.append(host.host(), 2, 3, "two\nthree\n!"));
    try std.testing.expectError(error.InvalidJournalSequence, journal.append(host.host(), 2, 3, "replacement"));
    try std.testing.expectEqual(@as(usize, 2), host.calls);
}

test "journal pre-write failures permit repeated and corrected content retries" {
    var host: TestHost = .{ .mode = .pre_write };
    var journal = try Journal.init(.{});
    for (0..2) |_| try std.testing.expectError(error.BeforeWrite, journal.append(host.host(), 1, 1, "original"));
    try std.testing.expectEqual(Cursor{}, journal.cursor);
    try std.testing.expectEqual(@as(usize, 0), host.length);
    host.mode = .commit;
    _ = try journal.append(host.host(), 1, 1, "corrected");
    try std.testing.expectEqualStrings("corrected", host.storage[0..host.length]);
}

test "journal lost acknowledgement blocks all retries until authoritative recreation" {
    var host: TestHost = .{ .mode = .lost_ack };
    var journal = try Journal.init(.{});
    try std.testing.expectError(error.AckLost, journal.append(host.host(), 1, 2, "one\ntwo\n"));
    try std.testing.expectEqual(Cursor{}, journal.cursor);
    host.mode = .commit;
    try std.testing.expectError(error.JournalUnavailable, journal.append(host.host(), 1, 2, "one\ntwo\n"));
    try std.testing.expectError(error.JournalUnavailable, journal.append(host.host(), 1, 2, "different"));
    try std.testing.expectError(error.JournalUnavailable, journal.append(host.host(), 3, 3, "three\n"));
    try std.testing.expectEqual(@as(usize, 1), host.calls);
    try std.testing.expectEqualStrings("one\ntwo\n", host.storage[0..host.length]);
    // The host has verified the full bytes and their durability, not merely
    // copied the unacknowledged request's proposed cursor.
    var recreated = try Journal.init(host.cursor);
    _ = try recreated.append(host.host(), 3, 3, "three\n");
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", host.storage[0..host.length]);
    try std.testing.expectError(error.JournalUnavailable, journal.append(host.host(), 3, 3, "three\n"));
}

test "journal partial tail requires host repair before recreation and retry" {
    var host: TestHost = .{ .mode = .partial };
    var journal = try Journal.init(.{});
    try std.testing.expectError(error.PartialWrite, journal.append(host.host(), 1, 1, "record\n"));
    try std.testing.expectEqualStrings("rec", host.storage[0..host.length]);
    try std.testing.expectError(error.JournalUnavailable, journal.append(host.host(), 1, 1, "record\n"));
    try std.testing.expectEqual(@as(usize, 1), host.calls);
    // Authoritative recovery owns truncation. The journal never rewinds storage.
    host.length = 0;
    host.mode = .commit;
    var recreated = try Journal.init(host.cursor);
    _ = try recreated.append(host.host(), 1, 1, "record\n");
    try std.testing.expectEqualStrings("record\n", host.storage[0..host.length]);
}

test "journal conflict fences stale owner without touching a longer log" {
    var host: TestHost = .{};
    var stale = try Journal.init(.{});
    var current = try Journal.init(.{});
    _ = try current.append(host.host(), 1, 1, "current owner\n");
    try std.testing.expectError(error.JournalConflict, stale.append(host.host(), 1, 1, "stale\n"));
    try std.testing.expectError(error.JournalUnavailable, stale.append(host.host(), 1, 1, "stale\n"));
    try std.testing.expectEqualStrings("current owner\n", host.storage[0..host.length]);
    try std.testing.expectEqual(@as(usize, 2), host.calls);
}

test "journal rejects malformed acknowledgements and stays fenced" {
    const invalid = [_]Cursor{
        .{},
        .{ .seq = 1, .committed_bytes = 3 },
        .{ .seq = 1, .committed_bytes = 5 },
        .{ .seq = 2, .committed_bytes = 4 },
        .{ .seq = 0, .committed_bytes = 4 },
    };
    for (invalid) |ack| {
        var host: TestHost = .{ .mode = .bad_ack, .acknowledgement = ack };
        var journal = try Journal.init(.{});
        try std.testing.expectError(error.InvalidJournalAcknowledgement, journal.append(host.host(), 1, 1, "one\n"));
        try std.testing.expectEqual(Cursor{}, journal.cursor);
        try std.testing.expectError(error.JournalUnavailable, journal.append(host.host(), 1, 1, "one\n"));
        try std.testing.expectEqual(@as(usize, 1), host.calls);
    }
}

test "journal validates authoritative cursor and overflow before calling host" {
    try std.testing.expectError(error.InvalidJournalCursor, Journal.init(.{ .seq = 0, .committed_bytes = 1 }));
    try std.testing.expectError(error.InvalidJournalCursor, Journal.init(.{ .seq = 1, .committed_bytes = 0 }));
    var host: TestHost = .{};
    var sequence_full = try Journal.init(.{ .seq = std.math.maxInt(u64), .committed_bytes = std.math.maxInt(u64) });
    try std.testing.expectError(error.JournalSequenceOverflow, sequence_full.append(host.host(), 0, 0, "x"));
    var bytes_full = try Journal.init(.{ .seq = 1, .committed_bytes = std.math.maxInt(u64) });
    try std.testing.expectError(error.JournalSizeOverflow, bytes_full.append(host.host(), 2, 2, "x"));
    try std.testing.expectEqual(@as(usize, 0), host.calls);
}

/// Deterministic recovery model for the test host's tiny newline record format.
/// Recovery derives the authoritative cursor from durable bytes, never from the
/// abandoned Journal's speculative request. Only an incomplete tail is removed.
fn recover_test_host(host: *TestHost) !Cursor {
    var offset: usize = 0;
    var seq: u64 = 0;
    while (offset + 2 <= host.length) : (offset += 2) {
        try std.testing.expectEqual(@as(u8, @intCast('1' + seq)), host.storage[offset]);
        try std.testing.expectEqual(@as(u8, '\n'), host.storage[offset + 1]);
        seq += 1;
    }
    host.length = offset;
    host.cursor = .{ .seq = seq, .committed_bytes = offset };
    return host.cursor;
}

test "journal deterministic simulation exhausts four-append crash and acknowledgement schedules" {
    const modes = [_]@TypeOf(@as(TestHost, .{}).mode){
        .commit, .pre_write, .lost_ack, .partial, .conflict, .bad_ack,
    };
    // 6^4 schedules: fail before/after each write, lose an acknowledgement,
    // truncate a partial record on recovery, and recreate even after success.
    // This drives the real Journal against simulated storage, not a duplicate
    // implementation of its state machine. It does not model external effects.
    const schedule_count = modes.len * modes.len * modes.len * modes.len;
    for (0..schedule_count) |schedule| {
        var remaining = schedule;
        var host: TestHost = .{};
        var journal = try Journal.init(.{});
        for (0..4) |index| {
            const mode = modes[remaining % modes.len];
            remaining /= modes.len;
            host.mode = mode;
            const record = [_]u8{ @intCast('1' + index), '\n' };
            const seq: u64 = index + 1;
            const before = journal.cursor;
            if (journal.append(host.host(), seq, seq, &record)) |ack| {
                try std.testing.expectEqual(@as(u64, seq), ack.seq);
                try std.testing.expectEqual(mode, .commit);
            } else |_| {
                try std.testing.expectEqual(before, journal.cursor);
                if (mode == .pre_write) {
                    try std.testing.expect(!journal.blocked);
                } else {
                    const calls = host.calls;
                    try std.testing.expectError(error.JournalUnavailable, journal.append(host.host(), seq, seq, &record));
                    try std.testing.expectEqual(calls, host.calls);
                }
            }
            // Crash loses the old journal instance. Authoritative storage
            // recovery decides whether the failed append actually landed.
            journal = try Journal.init(try recover_test_host(&host));
            host.mode = .commit;
            if (journal.cursor.seq < seq) _ = try journal.append(host.host(), seq, seq, &record);
            try std.testing.expectEqual(seq, journal.cursor.seq);
            try std.testing.expectEqual(seq * 2, journal.cursor.committed_bytes);
            try std.testing.expectEqualStrings("1\n2\n3\n4\n"[0 .. (index + 1) * 2], host.storage[0..host.length]);
        }
        try std.testing.expectEqualStrings("1\n2\n3\n4\n", host.storage[0..host.length]);
    }
}

test "journal callback borrows bytes synchronously and cannot reenter" {
    const Reentrant = struct {
        journal: *Journal,
        calls: usize = 0,
        fn append(context: *anyopaque, request: Append) Outcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            const host: Host = .{ .context = self, .append_fn = append };
            std.testing.expectError(error.JournalUnavailable, self.journal.append(host, 1, 1, "nested")) catch unreachable;
            return .{ .committed = request.next };
        }
    };
    var journal = try Journal.init(.{});
    var host: Reentrant = .{ .journal = &journal };
    _ = try journal.append(.{ .context = &host, .append_fn = Reentrant.append }, 1, 1, "outer");
    try std.testing.expectEqual(@as(usize, 1), host.calls);
}
