const std = @import("std");
const io_mod = @import("../shared/io.zig");
const session_codec = @import("session_codec.zig");
const session_event = @import("session_event.zig");
const session_projection = @import("session_projection.zig");

const Allocator = std.mem.Allocator;
const Identifier = session_event.Identifier;

pub const CommitPosition = struct {
    log_generation: Identifier,
    through_seq: u64,
    through_event_id: Identifier,
    through_event_log_bytes: u64,
};

pub const RecoveryValidation = enum {
    valid,
    invalid,
};

pub const LineRead = struct {
    bytes: []u8,
    next_offset: u64,
};

pub fn readLineAt(
    alloc: Allocator,
    file: std.Io.File,
    offset: u64,
    max_end: u64,
) !?LineRead {
    return readLineAtWithCancellation(alloc, file, offset, max_end, null);
}

pub fn readLineAtCancellable(
    alloc: Allocator,
    file: std.Io.File,
    offset: u64,
    max_end: u64,
    cancelled: *const std.atomic.Value(bool),
) !?LineRead {
    return readLineAtWithCancellation(alloc, file, offset, max_end, cancelled);
}

fn readLineAtWithCancellation(
    alloc: Allocator,
    file: std.Io.File,
    offset: u64,
    max_end: u64,
    cancelled: ?*const std.atomic.Value(bool),
) !?LineRead {
    if (cancelled) |stop| {
        if (stop.load(.acquire)) return error.Cancelled;
    }
    if (offset >= max_end) return null;
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(alloc);
    var cursor = offset;
    var chunk: [8192]u8 = undefined;
    while (cursor < max_end) {
        if (cancelled) |stop| {
            if (stop.load(.acquire)) return error.Cancelled;
        }
        const limit = @min(@as(u64, chunk.len), max_end - cursor);
        const count = try file.readPositionalAll(
            io_mod.getIo(),
            chunk[0..@intCast(limit)],
            cursor,
        );
        if (count == 0) {
            if (line.items.len == 0) return null;
            return error.TruncatedEventFrame;
        }
        if (std.mem.findScalar(u8, chunk[0..count], '\n')) |newline| {
            try line.appendSlice(alloc, chunk[0 .. newline + 1]);
            cursor += newline + 1;
            if (line.items.len > session_event.event_frame_max_bytes) {
                return error.EventFrameTooLarge;
            }
            return .{
                .bytes = try line.toOwnedSlice(alloc),
                .next_offset = cursor,
            };
        }
        try line.appendSlice(alloc, chunk[0..count]);
        if (line.items.len > session_event.event_frame_max_bytes) {
            return error.EventFrameTooLarge;
        }
        cursor += count;
    }
    return error.TruncatedEventFrame;
}

pub fn readFirstGeneration(alloc: Allocator, file: std.Io.File) !Identifier {
    var envelope = try readSessionStarted(alloc, file);
    defer envelope.deinit(alloc);
    return envelope.log_generation;
}

test "cancelled event reads release work before reading another frame" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "events.jsonl", .{ .read = true });
    defer file.close(std.testing.io);
    const bytes = "{\"event\":1}\n";
    try file.writeStreamingAll(std.testing.io, bytes);
    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, readLineAtCancellable(alloc, file, 0, bytes.len, &cancelled));
    cancelled.store(false, .release);
    const line = (try readLineAtCancellable(alloc, file, 0, bytes.len, &cancelled)).?;
    defer alloc.free(line.bytes);
    try std.testing.expectEqualStrings(bytes, line.bytes);
    try std.testing.expectEqual(@as(u64, bytes.len), line.next_offset);
}

pub fn readSubagentChildIdentity(alloc: Allocator, file: std.Io.File) !bool {
    var envelope = try readSessionStarted(alloc, file);
    defer envelope.deinit(alloc);
    return envelope.event.session_started.subagent_child;
}

fn readSessionStarted(alloc: Allocator, file: std.Io.File) !session_event.Envelope {
    const length = try file.length(io_mod.getIo());
    const first = try readLineAt(alloc, file, 0, length) orelse
        return error.InvalidSessionFormat;
    defer alloc.free(first.bytes);
    var envelope = session_event.decodeFrame(alloc, first.bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedEventSchema => return error.UnsupportedSessionSchema,
        else => return error.InvalidSessionFormat,
    };
    errdefer envelope.deinit(alloc);
    if (envelope.seq != 1 or envelope.kind() != .session_started) {
        return error.InvalidSessionFormat;
    }
    return envelope;
}

pub fn scanCommitPosition(
    alloc: Allocator,
    file: std.Io.File,
    position: CommitPosition,
) !session_projection.EventBoundary {
    var state = try replayBoundary(alloc, file, position);
    state.deinit(alloc);
    return eventBoundary(position);
}

pub fn validateCommitPositionForRecovery(
    alloc: Allocator,
    file: std.Io.File,
    position: CommitPosition,
) !RecoveryValidation {
    var state = replayBoundaryRaw(alloc, file, position) catch |err| switch (err) {
        error.UnsupportedEventSchema => return error.UnsupportedSessionSchema,
        error.OutOfMemory, error.ReadFailed => return err,
        else => return .invalid,
    };
    state.deinit(alloc);
    return .valid;
}

pub fn replayBoundary(
    alloc: Allocator,
    file: std.Io.File,
    position: CommitPosition,
) !session_codec.DurableSessionState {
    return replayBoundaryRaw(alloc, file, position) catch |err| switch (err) {
        error.OutOfMemory, error.ReadFailed => return err,
        error.UnsupportedEventSchema => return error.UnsupportedSessionSchema,
        else => return error.InvalidSessionFormat,
    };
}

/// Replays one caller-supplied durable boundary without consulting a commit
/// watermark. It never searches for or selects a different prefix.
pub fn replayExactBoundary(
    alloc: Allocator,
    file: std.Io.File,
    expected_generation: Identifier,
    expected_seq: u64,
    expected_bytes: u64,
) !session_codec.DurableSessionState {
    var replayed = try replayExactPosition(
        alloc,
        file,
        expected_generation,
        expected_seq,
        expected_bytes,
    );
    return replayed.takeState();
}

/// Owns `state`; callers must call `deinit` or transfer it with `takeState`.
pub const ExactReplay = struct {
    state: session_codec.DurableSessionState,
    position: CommitPosition,

    pub fn deinit(self: *ExactReplay, alloc: Allocator) void {
        self.state.deinit(alloc);
        self.* = undefined;
    }

    pub fn takeState(self: *ExactReplay) session_codec.DurableSessionState {
        const state = self.state;
        self.* = undefined;
        return state;
    }
};

inline fn failExactReplay(err: anytype) @TypeOf(err)!ExactReplay {
    return @errorCast(failExactReplayDynamic(err));
}

noinline fn failExactReplayDynamic(err: anyerror) anyerror!ExactReplay {
    return err;
}

test "exact replay failures preserve exact error types and identities" {
    const invalid = failExactReplay(error.InvalidSessionFormat);
    try std.testing.expect(
        @TypeOf(invalid) == error{InvalidSessionFormat}!ExactReplay,
    );
    try std.testing.expectError(error.InvalidSessionFormat, invalid);
    try std.testing.expectError(
        error.UnsupportedSessionSchema,
        failExactReplay(error.UnsupportedSessionSchema),
    );
}

pub fn replayExactPosition(
    alloc: Allocator,
    file: std.Io.File,
    expected_generation: Identifier,
    expected_seq: u64,
    expected_bytes: u64,
) !ExactReplay {
    return replayPosition(
        alloc,
        file,
        expected_generation,
        expected_seq,
        expected_bytes,
        true,
    );
}

/// Replays an explicitly committed prefix while ignoring later bytes. This is
/// used only by the read-only legacy importer; current sessions never need a
/// watermark or a generation boundary.
pub fn replayCommittedPrefix(
    alloc: Allocator,
    file: std.Io.File,
    expected_generation: Identifier,
    expected_seq: u64,
    expected_bytes: u64,
) !ExactReplay {
    return replayPosition(
        alloc,
        file,
        expected_generation,
        expected_seq,
        expected_bytes,
        false,
    );
}

fn replayPosition(
    alloc: Allocator,
    file: std.Io.File,
    expected_generation: Identifier,
    expected_seq: u64,
    expected_bytes: u64,
    require_exact_length: bool,
) !ExactReplay {
    const file_bytes = try file.length(io_mod.getIo());
    if (expected_bytes == 0 or file_bytes < expected_bytes or
        (require_exact_length and file_bytes != expected_bytes))
    {
        return failExactReplay(error.InvalidSessionFormat);
    }
    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(io_mod.getIo(), &file_buffer);
    var limit_buffer: [4096]u8 = undefined;
    var limited = file_reader.interface.limited(
        .limited64(expected_bytes),
        &limit_buffer,
    );
    var reduction = session_event.reduceJsonl(
        alloc,
        &limited.interface,
        null,
    ) catch |err| switch (err) {
        error.OutOfMemory, error.ReadFailed => return err,
        error.UnsupportedEventSchema => return failExactReplay(error.UnsupportedSessionSchema),
        else => return failExactReplay(error.InvalidSessionFormat),
    };
    errdefer reduction.deinit(alloc);
    const through = reduction.through orelse return failExactReplay(error.InvalidSessionFormat);
    if (reduction.truncate_from != null or
        reduction.bytes_consumed != expected_bytes or
        through.byte_offset != expected_bytes or
        through.seq != expected_seq or
        !std.mem.eql(u8, &through.log_generation, &expected_generation))
    {
        return failExactReplay(error.InvalidSessionFormat);
    }
    const state = reduction.state;
    reduction.state = undefined;
    return .{
        .state = state,
        .position = .{
            .log_generation = through.log_generation,
            .through_seq = through.seq,
            .through_event_id = through.event_id,
            .through_event_log_bytes = through.byte_offset,
        },
    };
}

pub fn replayFromCheckpoint(
    alloc: Allocator,
    file: std.Io.File,
    checkpoint: CommitPosition,
    state: session_codec.DurableSessionState,
    position: CommitPosition,
) !session_codec.DurableSessionState {
    return replayRangeRaw(
        alloc,
        file,
        checkpoint,
        state,
        position,
    ) catch |err| switch (err) {
        error.OutOfMemory, error.ReadFailed => return err,
        error.UnsupportedEventSchema => return error.UnsupportedSessionSchema,
        else => return error.InvalidSessionFormat,
    };
}

fn replayBoundaryRaw(
    alloc: Allocator,
    file: std.Io.File,
    position: CommitPosition,
) !session_codec.DurableSessionState {
    return replayRangeRaw(alloc, file, null, null, position);
}

fn replayRangeRaw(
    alloc: Allocator,
    file: std.Io.File,
    checkpoint: ?CommitPosition,
    initial: ?session_codec.DurableSessionState,
    position: CommitPosition,
) !session_codec.DurableSessionState {
    var owned_initial = initial;
    errdefer if (owned_initial) |*state| state.deinit(alloc);
    if ((checkpoint == null) != (owned_initial == null) or
        position.through_event_log_bytes == 0)
    {
        return error.InvalidSessionFormat;
    }
    const start_bytes: u64 = if (checkpoint) |start| start.through_event_log_bytes else 0;
    if (checkpoint) |start| {
        if (!std.mem.eql(u8, &start.log_generation, &position.log_generation) or
            start.through_seq > position.through_seq or
            start.through_event_log_bytes > position.through_event_log_bytes)
        {
            return error.InvalidSessionFormat;
        }
        if (start.through_seq == position.through_seq) {
            if (start.through_event_log_bytes != position.through_event_log_bytes or
                !std.mem.eql(u8, &start.through_event_id, &position.through_event_id))
            {
                return error.InvalidSessionFormat;
            }
            const state = owned_initial.?;
            owned_initial = null;
            return state;
        }
    }
    const length = try file.length(io_mod.getIo());
    if (length < position.through_event_log_bytes) return error.InvalidSessionFormat;

    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(io_mod.getIo(), &file_buffer);
    if (start_bytes > 0) try file_reader.seekTo(start_bytes);
    var limit_buffer: [4096]u8 = undefined;
    var limited = file_reader.interface.limited(
        .limited64(position.through_event_log_bytes - start_bytes),
        &limit_buffer,
    );
    const start = if (checkpoint) |boundary|
        session_event.ReductionStart{
            .generation = boundary.log_generation,
            .next_seq = std.math.add(u64, boundary.through_seq, 1) catch
                return error.InvalidSessionFormat,
        }
    else
        session_event.ReductionStart{};
    const moved_initial = owned_initial;
    owned_initial = null;
    var reduction = try session_event.reduceJsonlFrom(
        alloc,
        &limited.interface,
        moved_initial,
        start,
    );
    errdefer reduction.deinit(alloc);
    if (reduction.truncate_from != null or
        reduction.bytes_consumed != position.through_event_log_bytes - start_bytes)
    {
        return error.InvalidSessionFormat;
    }
    const through = if (reduction.through) |boundary|
        session_projection.EventBoundary{
            .log_generation = boundary.log_generation,
            .seq = boundary.seq,
            .event_id = boundary.event_id,
            .event_log_bytes = start_bytes + boundary.byte_offset,
            .semantic = true,
        }
    else if (checkpoint) |boundary|
        eventBoundary(boundary)
    else
        return error.InvalidSessionFormat;
    if (through.seq != position.through_seq or
        through.event_log_bytes != position.through_event_log_bytes or
        !std.mem.eql(u8, &through.log_generation, &position.log_generation) or
        !std.mem.eql(u8, &through.event_id, &position.through_event_id))
    {
        return error.InvalidSessionFormat;
    }
    const state = reduction.state;
    reduction.state = undefined;
    return state;
}

fn reduceBoundaryReader(
    alloc: Allocator,
    source: *std.Io.Reader,
) !session_codec.DurableSessionState {
    var reduction = try session_event.reduceJsonl(alloc, source, null);
    errdefer reduction.deinit(alloc);
    if (reduction.truncate_from != null) return error.InvalidSessionFormat;
    const state = reduction.state;
    reduction.state = undefined;
    return state;
}

fn eventBoundary(position: CommitPosition) session_projection.EventBoundary {
    return .{
        .log_generation = position.log_generation,
        .seq = position.through_seq,
        .event_id = position.through_event_id,
        .event_log_bytes = position.through_event_log_bytes,
        .semantic = true,
    };
}

fn checkRecoveryValidationAllocationFailures(
    alloc: Allocator,
    path: []const u8,
    position: CommitPosition,
) !void {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    try std.testing.expectEqual(
        RecoveryValidation.valid,
        try validateCommitPositionForRecovery(alloc, file, position),
    );
}

test "recovery replay preserves reader failure identity" {
    const FailingReader = struct {
        buffer: [1]u8 = undefined,
        interface: std.Io.Reader = undefined,

        fn init(self: *@This()) void {
            self.* = .{};
            self.interface = .{
                .vtable = &.{
                    .stream = stream,
                    .readVec = readVec,
                },
                .buffer = &self.buffer,
                .seek = 0,
                .end = 0,
            };
        }

        fn readVec(_: *std.Io.Reader, _: [][]u8) std.Io.Reader.Error!usize {
            return error.ReadFailed;
        }

        fn stream(
            _: *std.Io.Reader,
            _: *std.Io.Writer,
            _: std.Io.Limit,
        ) std.Io.Reader.StreamError!usize {
            return error.ReadFailed;
        }
    };

    var source: FailingReader = undefined;
    source.init();
    try std.testing.expectError(
        error.ReadFailed,
        reduceBoundaryReader(std.testing.allocator, &source.interface),
    );
}

test "session replay parser honors exact copied boundary" {
    const alloc = std.testing.allocator;
    const generation: Identifier = .{0x10} ** 16;
    const first_id: Identifier = .{0x20} ** 16;
    const second_id: Identifier = .{0x30} ** 16;
    const first = try session_event.encodeLegacyFixtureFrame(alloc, .{
        .log_generation = generation,
        .seq = 1,
        .event_id = first_id,
        .timestamp_ms = 10,
        .event = .{ .session_started = .{
            .id = @constCast("replay-boundary"),
            .created_at_ms = 10,
            .origin_workspace_root = @constCast("/tmp/origin"),
            .workspace_root = @constCast("/tmp/current"),
            .conversation_language = .literal("en"),
            .preferences = .{
                .model = @constCast("model-a"),
                .effort = .auto,
                .fast_mode = false,
            },
        } },
    });
    defer alloc.free(first);
    const second = try session_event.encodeLegacyFixtureFrame(alloc, .{
        .log_generation = generation,
        .seq = 2,
        .event_id = second_id,
        .timestamp_ms = 20,
        .event = .{ .preferences_changed = .{ .fast_mode = true } },
    });
    defer alloc.free(second);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var output = try tmp.dir.createFile(io_mod.getIo(), "events.jsonl", .{ .truncate = true });
        defer output.close(io_mod.getIo());
        try output.writeStreamingAll(io_mod.getIo(), first);
        try output.writeStreamingAll(io_mod.getIo(), second);
        try output.sync(io_mod.getIo());
    }
    var file = try tmp.dir.openFile(io_mod.getIo(), "events.jsonl", .{});
    defer file.close(io_mod.getIo());
    const copied = CommitPosition{
        .log_generation = generation,
        .through_seq = 1,
        .through_event_id = first_id,
        .through_event_log_bytes = first.len,
    };

    const boundary = try scanCommitPosition(alloc, file, copied);
    try std.testing.expectEqual(@as(u64, 1), boundary.seq);
    var state = try replayBoundary(alloc, file, copied);
    defer state.deinit(alloc);
    try std.testing.expectEqualStrings("replay-boundary", state.id);
    try std.testing.expect(!state.preferences.fast_mode);
    try std.testing.expectError(
        error.InvalidSessionFormat,
        replayExactPosition(
            alloc,
            file,
            generation,
            copied.through_seq,
            copied.through_event_log_bytes,
        ),
    );
    var imported = try replayCommittedPrefix(
        alloc,
        file,
        generation,
        copied.through_seq,
        copied.through_event_log_bytes,
    );
    defer imported.deinit(alloc);
    try std.testing.expectEqualStrings("replay-boundary", imported.state.id);
    try std.testing.expect(!imported.state.preferences.fast_mode);

    const complete = CommitPosition{
        .log_generation = generation,
        .through_seq = 2,
        .through_event_id = second_id,
        .through_event_log_bytes = first.len + second.len,
    };
    const checkpoint_state = try replayBoundary(alloc, file, copied);
    var resumed = try replayFromCheckpoint(
        alloc,
        file,
        copied,
        checkpoint_state,
        complete,
    );
    defer resumed.deinit(alloc);
    try std.testing.expect(resumed.preferences.fast_mode);

    const exact_state = try replayBoundary(alloc, file, copied);
    var exact = try replayFromCheckpoint(
        alloc,
        file,
        copied,
        exact_state,
        copied,
    );
    defer exact.deinit(alloc);
    try std.testing.expect(!exact.preferences.fast_mode);

    var mismatched = complete;
    mismatched.through_event_id = .{0xff} ** 16;
    const rejected_state = try replayBoundary(alloc, file, copied);
    try std.testing.expectError(
        error.InvalidSessionFormat,
        replayFromCheckpoint(
            alloc,
            file,
            copied,
            rejected_state,
            mismatched,
        ),
    );

    var unreadable = try tmp.dir.openFile(
        io_mod.getIo(),
        "events.jsonl",
        .{ .mode = .write_only },
    );
    defer unreadable.close(io_mod.getIo());
    try std.testing.expectError(
        error.ReadFailed,
        replayBoundary(alloc, unreadable, complete),
    );
    const read_failure_state = try replayBoundary(alloc, file, copied);
    try std.testing.expectError(
        error.ReadFailed,
        replayFromCheckpoint(
            alloc,
            unreadable,
            copied,
            read_failure_state,
            complete,
        ),
    );

    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "events.jsonl");
    defer alloc.free(path);
    try std.testing.checkAllAllocationFailures(
        alloc,
        checkRecoveryValidationAllocationFailures,
        .{ path, copied },
    );
}

test "session replay parser rejects malformed or truncated bounded input" {
    const alloc = std.testing.allocator;
    const generation: Identifier = .{0x40} ** 16;
    const event_id: Identifier = .{0x50} ** 16;
    const malformed = "{not-json}\n";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var output = try tmp.dir.createFile(io_mod.getIo(), "events.jsonl", .{ .truncate = true });
        defer output.close(io_mod.getIo());
        try output.writeStreamingAll(io_mod.getIo(), malformed);
        try output.sync(io_mod.getIo());
    }
    var file = try tmp.dir.openFile(io_mod.getIo(), "events.jsonl", .{});
    defer file.close(io_mod.getIo());
    const copied = CommitPosition{
        .log_generation = generation,
        .through_seq = 1,
        .through_event_id = event_id,
        .through_event_log_bytes = malformed.len,
    };

    try std.testing.expectError(error.InvalidSessionFormat, replayBoundary(alloc, file, copied));
    try std.testing.expectError(error.InvalidSessionFormat, scanCommitPosition(alloc, file, copied));
    try std.testing.expectError(error.TruncatedEventFrame, readLineAt(alloc, file, 0, malformed.len - 1));
}

test "session replay parser rejects oversized bounded frame" {
    const alloc = std.testing.allocator;
    const generation: Identifier = .{0x60} ** 16;
    const event_id: Identifier = .{0x70} ** 16;
    const oversized = try alloc.alloc(u8, session_event.event_frame_max_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    oversized[oversized.len - 1] = '\n';

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var output = try tmp.dir.createFile(io_mod.getIo(), "events.jsonl", .{ .truncate = true });
        defer output.close(io_mod.getIo());
        try output.writeStreamingAll(io_mod.getIo(), oversized);
        try output.sync(io_mod.getIo());
    }
    var file = try tmp.dir.openFile(io_mod.getIo(), "events.jsonl", .{});
    defer file.close(io_mod.getIo());
    const copied = CommitPosition{
        .log_generation = generation,
        .through_seq = 1,
        .through_event_id = event_id,
        .through_event_log_bytes = oversized.len,
    };

    try std.testing.expectError(
        error.EventFrameTooLarge,
        readLineAt(alloc, file, 0, copied.through_event_log_bytes),
    );
}

test "session replay parser frees line allocation on every caller path" {
    const alloc = std.testing.allocator;
    const generation: Identifier = .{0x80} ** 16;
    const event_id: Identifier = .{0x90} ** 16;
    const frame = try session_event.encodeLegacyFixtureFrame(alloc, .{
        .log_generation = generation,
        .seq = 1,
        .event_id = event_id,
        .timestamp_ms = 10,
        .event = .{ .session_started = .{
            .id = @constCast("replay-ownership"),
            .created_at_ms = 10,
            .origin_workspace_root = @constCast("/tmp/origin"),
            .workspace_root = @constCast("/tmp/current"),
            .conversation_language = .literal("en"),
            .preferences = .{
                .model = @constCast("model-a"),
                .effort = .auto,
                .fast_mode = false,
            },
        } },
    });
    defer alloc.free(frame);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var output = try tmp.dir.createFile(io_mod.getIo(), "events.jsonl", .{ .truncate = true });
        defer output.close(io_mod.getIo());
        try output.writeStreamingAll(io_mod.getIo(), frame);
        try output.sync(io_mod.getIo());
    }
    var file = try tmp.dir.openFile(io_mod.getIo(), "events.jsonl", .{});
    defer file.close(io_mod.getIo());
    const copied = CommitPosition{
        .log_generation = generation,
        .through_seq = 1,
        .through_event_id = event_id,
        .through_event_log_bytes = frame.len,
    };

    const line = try readLineAt(alloc, file, 0, copied.through_event_log_bytes);
    defer alloc.free(line.?.bytes);
    _ = try readFirstGeneration(alloc, file);
    _ = try scanCommitPosition(alloc, file, copied);
}
