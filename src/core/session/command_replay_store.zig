const std = @import("std");
const command_output_content = @import("../tooling/command_output_content.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const artifact_digest = @import("artifact_digest.zig");
const session_child_store = @import("session_child_store.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Stream = command_output_content.Stream;
const replay_magic = "FXRPLY01";
const frame_header_bytes: usize = 9;
const max_frame_payload_bytes: usize = 1024 * 1024;

const DecodedFrameHeader = struct {
    stream: Stream,
    payload_len: usize,
};

fn decodeFrameHeader(header: []const u8) !DecodedFrameHeader {
    std.debug.assert(header.len == frame_header_bytes);
    const stream: Stream = switch (header[0]) {
        0 => .stdout,
        1 => .stderr,
        else => return error.InvalidReplayStream,
    };
    const payload_len_u64 = std.mem.readInt(u64, header[1..][0..8], .little);
    const payload_len = std.math.cast(usize, payload_len_u64) orelse
        return error.ReplayFrameTooLarge;
    if (payload_len == 0) return error.EmptyReplayFrame;
    if (payload_len > max_frame_payload_bytes) return error.ReplayFrameTooLarge;
    return .{ .stream = stream, .payload_len = payload_len };
}

const OpenSpool = struct {
    file: session_child_store.ManagedFile,
    handle: []u8,
    framed_bytes: usize,
};

const OwnedDescriptor = struct {
    handle: []u8,
    framed_bytes: usize,

    fn view(self: OwnedDescriptor) types.CommandOutputReplayDescriptor {
        return .{
            .handle = self.handle,
            .framed_bytes = self.framed_bytes,
        };
    }
};

const CaptureState = union(enum) {
    buffered: std.ArrayList(u8),
    streaming: OpenSpool,
    sealed_file: OwnedDescriptor,
    unavailable,
    retained: ?OwnedDescriptor,
    consumed,
};

/// Arena-lived single-owner handoff. The pointer may be copied with a tool
/// result, but state transitions consume storage at most once.
pub const Capture = struct {
    inline_limit: usize,
    comparison_limit: usize,
    capability: ?*session_child_store.SessionChildCapability,
    state: CaptureState = .{ .buffered = .empty },
    had_output: bool = false,
    sealed: bool = false,
    content_hasher: Sha256 = Sha256.init(.{}),
    digest_started: bool = false,

    pub fn create(
        alloc: Allocator,
        inline_limit: usize,
        capability: ?*session_child_store.SessionChildCapability,
    ) !*Capture {
        const capture = try alloc.create(Capture);
        capture.* = .{
            .inline_limit = inline_limit,
            .comparison_limit = inline_limit,
            .capability = capability,
        };
        return capture;
    }

    /// Records bytes only after the downstream callback accepted them.
    /// Storage failures degrade replay without changing command execution.
    pub fn appendAccepted(
        self: *Capture,
        alloc: Allocator,
        stream: Stream,
        bytes: []const u8,
    ) void {
        if (bytes.len == 0 or self.sealed) return;
        self.had_output = true;
        self.appendAcceptedFallible(alloc, stream, bytes) catch |err| {
            self.makeUnavailable(alloc, err);
            return;
        };
        if (!self.digest_started) {
            self.content_hasher.update(replay_magic);
            self.digest_started = true;
        }
        var header: [frame_header_bytes]u8 = undefined;
        header[0] = @intFromEnum(stream);
        std.mem.writeInt(u64, header[1..], @intCast(bytes.len), .little);
        self.content_hasher.update(&header);
        self.content_hasher.update(bytes);
    }

    fn appendAcceptedFallible(
        self: *Capture,
        alloc: Allocator,
        stream: Stream,
        bytes: []const u8,
    ) !void {
        var header: [frame_header_bytes]u8 = undefined;
        header[0] = @intFromEnum(stream);
        const payload_len = std.math.cast(u64, bytes.len) orelse
            return error.ReplayFrameTooLarge;
        std.mem.writeInt(u64, header[1..], payload_len, .little);

        switch (self.state) {
            .buffered => |*buffered| {
                const base_len = if (buffered.items.len == 0)
                    replay_magic.len
                else
                    buffered.items.len;
                const with_header = try std.math.add(usize, base_len, header.len);
                const required = try std.math.add(usize, with_header, bytes.len);
                if (required <= self.inline_limit) {
                    try buffered.ensureTotalCapacityPrecise(alloc, required);
                    if (buffered.items.len == 0) buffered.appendSliceAssumeCapacity(replay_magic);
                    buffered.appendSliceAssumeCapacity(&header);
                    buffered.appendSliceAssumeCapacity(bytes);
                    return;
                }
                try self.promoteAndAppend(alloc, buffered, &header, bytes);
            },
            .streaming => |*spool| {
                try spool.file.writeAll(&header);
                try spool.file.writeAll(bytes);
                spool.framed_bytes = try std.math.add(
                    usize,
                    spool.framed_bytes,
                    try std.math.add(usize, header.len, bytes.len),
                );
            },
            .unavailable, .retained, .consumed, .sealed_file => {},
        }
    }

    fn promoteAndAppend(
        self: *Capture,
        alloc: Allocator,
        buffered: *std.ArrayList(u8),
        header: []const u8,
        bytes: []const u8,
    ) !void {
        const capability = self.capability orelse return error.ReplayStoreUnavailable;
        var spool = try createSpool(alloc, capability);
        var transferred = false;
        errdefer if (!transferred) {
            spool.file.deinit();
            self.deleteSpool(spool.handle);
            alloc.free(spool.handle);
        };
        if (buffered.items.len > 0) {
            try spool.file.writeAll(buffered.items);
            spool.framed_bytes = buffered.items.len;
        } else {
            try spool.file.writeAll(replay_magic);
            spool.framed_bytes = replay_magic.len;
        }
        try spool.file.writeAll(header);
        try spool.file.writeAll(bytes);
        spool.framed_bytes = try std.math.add(
            usize,
            spool.framed_bytes,
            try std.math.add(usize, header.len, bytes.len),
        );
        buffered.deinit(alloc);
        self.state = .{ .streaming = spool };
        transferred = true;
    }

    /// Closes and synchronizes any spool before the capture leaves tool runtime.
    pub fn seal(self: *Capture, alloc: Allocator) void {
        if (self.sealed) return;
        self.sealed = true;
        switch (self.state) {
            .streaming => |*spool| {
                spool.file.sync() catch |err| {
                    self.makeUnavailable(alloc, err);
                    return;
                };
                var digest: [Sha256.digest_length]u8 = undefined;
                var hasher = self.content_hasher;
                hasher.final(&digest);
                self.contentAddressSpool(
                    alloc,
                    spool,
                    digest,
                ) catch |err| {
                    self.makeUnavailable(alloc, err);
                    return;
                };
                const descriptor = OwnedDescriptor{
                    .handle = spool.handle,
                    .framed_bytes = spool.framed_bytes,
                };
                spool.file.deinit();
                self.state = .{ .sealed_file = descriptor };
            },
            else => {},
        }
    }

    pub fn hasOutput(self: *const Capture) bool {
        return self.had_output;
    }

    pub fn setComparisonLimit(self: *Capture, limit: usize) void {
        self.comparison_limit = @max(self.inline_limit, limit);
    }

    pub fn comparisonLimit(self: *const Capture) usize {
        return self.comparison_limit;
    }

    /// Returns a canonical comparison view only when accepted payload stays
    /// within the route's bounded ordinary-result limit. Inline capture still
    /// never exceeds `inline_limit`; a route may compare a larger private spool
    /// when its executor can return more bytes in an ordinary exact result.
    pub fn canonicalizeForComparison(
        self: *Capture,
        alloc: Allocator,
    ) !?command_output_content.CanonicalOutput {
        self.seal(alloc);
        if (!self.had_output) {
            var empty: command_output_content.CanonicalOutput = .{};
            try empty.finish(alloc);
            return empty;
        }
        return switch (self.state) {
            .buffered => |*buffered| try canonicalizeFramedBytes(
                alloc,
                buffered.items,
                self.comparison_limit,
            ),
            .sealed_file => |descriptor| try self.canonicalizeSpool(
                alloc,
                descriptor,
                self.comparison_limit,
            ),
            else => null,
        };
    }

    fn canonicalizeSpool(
        self: *Capture,
        alloc: Allocator,
        descriptor: OwnedDescriptor,
        max_payload_bytes: usize,
    ) !command_output_content.CanonicalOutput {
        const capability = self.capability orelse return error.ReplayStoreUnavailable;
        var reader = try Reader.open(alloc, capability, descriptor.view());
        defer reader.deinit();
        var output: command_output_content.CanonicalOutput = .{};
        errdefer output.deinit(alloc);
        var payload_bytes: usize = 0;
        while (try reader.next(alloc)) |frame| {
            defer alloc.free(frame.payload);
            payload_bytes = try std.math.add(usize, payload_bytes, frame.payload.len);
            if (payload_bytes > max_payload_bytes) return error.ReplayComparisonTooLarge;
            try output.append(alloc, frame.stream, frame.payload);
        }
        try output.finish(alloc);
        return output;
    }

    fn canonicalizeFramedBytes(
        alloc: Allocator,
        bytes: []const u8,
        max_payload_bytes: usize,
    ) !command_output_content.CanonicalOutput {
        if (bytes.len < replay_magic.len or
            !std.mem.eql(u8, bytes[0..replay_magic.len], replay_magic))
        {
            return error.InvalidReplayHeader;
        }
        var output: command_output_content.CanonicalOutput = .{};
        errdefer output.deinit(alloc);
        var offset = replay_magic.len;
        var payload_bytes: usize = 0;
        while (offset < bytes.len) {
            if (bytes.len - offset < frame_header_bytes) {
                return error.TruncatedReplayFrame;
            }
            const header = try decodeFrameHeader(
                bytes[offset..][0..frame_header_bytes],
            );
            const payload_start = try std.math.add(usize, offset, frame_header_bytes);
            const next_offset = try std.math.add(
                usize,
                payload_start,
                header.payload_len,
            );
            if (next_offset > bytes.len) return error.TruncatedReplayFrame;
            payload_bytes = try std.math.add(
                usize,
                payload_bytes,
                header.payload_len,
            );
            if (payload_bytes > max_payload_bytes) return error.ReplayComparisonTooLarge;
            try output.append(
                alloc,
                header.stream,
                bytes[payload_start..next_offset],
            );
            offset = next_offset;
        }
        try output.finish(alloc);
        return output;
    }

    /// Stages a durable descriptor in result memory. The capture remains the
    /// cleanup owner until the caller publishes that memory successfully.
    pub fn retain(
        self: *Capture,
        alloc: Allocator,
    ) ?types.CommandOutputReplay {
        self.seal(alloc);
        if (!self.had_output) {
            self.abort(alloc);
            return null;
        }
        return switch (self.state) {
            .buffered => |*buffered| blk: {
                const descriptor = self.materializeInline(alloc, buffered) catch |err| {
                    self.makeUnavailable(alloc, err);
                    self.state = .{ .retained = null };
                    break :blk .unavailable;
                };
                self.state = .{ .retained = descriptor };
                break :blk .{ .available = descriptor.view() };
            },
            .sealed_file => |descriptor| blk: {
                self.state = .{ .retained = descriptor };
                break :blk .{ .available = descriptor.view() };
            },
            .unavailable => blk: {
                self.state = .{ .retained = null };
                break :blk .unavailable;
            },
            .retained => |descriptor| if (descriptor) |value|
                .{ .available = value.view() }
            else
                .unavailable,
            .streaming => unreachable,
            .consumed => null,
        };
    }

    fn materializeInline(
        self: *Capture,
        alloc: Allocator,
        buffered: *std.ArrayList(u8),
    ) !OwnedDescriptor {
        const capability = self.capability orelse return error.ReplayStoreUnavailable;
        var spool = try createSpool(alloc, capability);
        var transferred = false;
        errdefer if (!transferred) {
            spool.file.deinit();
            self.deleteSpool(spool.handle);
            alloc.free(spool.handle);
        };
        const framed_bytes = buffered.items.len;
        try spool.file.writeAll(buffered.items);
        try spool.file.sync();
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(buffered.items, &digest, .{});
        try self.contentAddressSpool(alloc, &spool, digest);
        spool.file.deinit();
        buffered.deinit(alloc);
        transferred = true;
        return .{
            .handle = spool.handle,
            .framed_bytes = framed_bytes,
        };
    }

    fn contentAddressSpool(
        self: *Capture,
        alloc: Allocator,
        spool: *OpenSpool,
        digest: [Sha256.digest_length]u8,
    ) !void {
        const capability = self.capability orelse
            return error.ReplayStoreUnavailable;
        const target_handle = try contentAddressedHandle(
            alloc,
            spool.handle,
            digest,
        );
        capability.rename(
            .command_artifacts,
            spool.handle,
            target_handle,
        ) catch |err| {
            if (capability.hasIndeterminateEntry(
                .command_artifacts,
                target_handle,
            )) {
                alloc.free(spool.handle);
                spool.handle = target_handle;
            } else {
                alloc.free(target_handle);
            }
            return err;
        };
        alloc.free(spool.handle);
        spool.handle = target_handle;
    }

    /// Deletes a capture before result memory is staged. Safe to invoke repeatedly.
    pub fn abort(self: *Capture, alloc: Allocator) void {
        switch (self.state) {
            .buffered => |*buffered| buffered.deinit(alloc),
            .streaming => |*spool| {
                spool.file.deinit();
                self.deleteSpool(spool.handle);
                alloc.free(spool.handle);
            },
            .sealed_file => |descriptor| {
                self.deleteSpool(descriptor.handle);
                alloc.free(descriptor.handle);
            },
            .unavailable => {},
            .retained => {},
            .consumed => return,
        }
        self.state = .consumed;
    }

    /// Deletes a capture even when `retain` already staged its descriptor.
    /// Callers use this to roll back a failed result-memory publication.
    pub fn discard(self: *Capture, alloc: Allocator) void {
        switch (self.state) {
            .retained => |descriptor| {
                if (descriptor) |value| {
                    self.deleteSpool(value.handle);
                    alloc.free(value.handle);
                }
                self.state = .consumed;
            },
            else => self.abort(alloc),
        }
    }

    /// Releases retained descriptor storage after publication or external
    /// rollback without deleting the session-owned sidecar.
    pub fn releaseRetained(self: *Capture, alloc: Allocator) void {
        switch (self.state) {
            .retained => |descriptor| {
                if (descriptor) |value| alloc.free(value.handle);
                self.state = .consumed;
            },
            .consumed => {},
            else => self.abort(alloc),
        }
    }

    fn makeUnavailable(self: *Capture, alloc: Allocator, err: anyerror) void {
        switch (self.state) {
            .buffered => |*buffered| buffered.deinit(alloc),
            .streaming => |*spool| {
                spool.file.deinit();
                self.deleteSpool(spool.handle);
                alloc.free(spool.handle);
            },
            .sealed_file => |descriptor| {
                self.deleteSpool(descriptor.handle);
                alloc.free(descriptor.handle);
            },
            .unavailable, .retained, .consumed => {},
        }
        self.state = .unavailable;
        @import("../shared/debug_trace.zig").logf(
            "session",
            "command replay capture unavailable err={s}",
            .{@errorName(err)},
        );
    }

    fn deleteSpool(self: *Capture, handle: []const u8) void {
        const capability = self.capability orelse return;
        capability.delete(.command_artifacts, handle) catch |err| {
            @import("../shared/debug_trace.zig").logf(
                "session",
                "command replay orphan cleanup failed handle_bytes={d} err={s}",
                .{ handle.len, @errorName(err) },
            );
        };
    }
};

fn createSpool(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
) !OpenSpool {
    var attempt: usize = 0;
    while (attempt < 8) : (attempt += 1) {
        const handle = try std.fmt.allocPrint(
            alloc,
            "fx-command-replay-{d}-{d}-{d}.bin",
            .{ @intFromPtr(std.c.getpid()), io_mod.nanoTimestamp(), attempt },
        );
        const file = capability.createExclusiveFile(
            alloc,
            .command_artifacts,
            handle,
        ) catch |err| {
            alloc.free(handle);
            if (err == error.PathAlreadyExists) continue;
            return err;
        };
        return .{
            .file = file,
            .handle = handle,
            .framed_bytes = 0,
        };
    }
    return error.ReplayNameCollision;
}

fn contentAddressedHandle(
    alloc: Allocator,
    source_handle: []const u8,
    digest: [Sha256.digest_length]u8,
) ![]u8 {
    return artifact_digest.contentAddressedHandle(
        alloc,
        source_handle,
        ".bin",
        digest,
    ) catch |err| switch (err) {
        error.InvalidArtifactHandle => error.InvalidReplayHandle,
        else => return err,
    };
}

pub fn handleMatchesContentDigest(
    handle: []const u8,
    digest: [Sha256.digest_length]u8,
) bool {
    return artifact_digest.handleMatchesContentDigest(
        handle,
        ".bin",
        digest,
    );
}

pub fn hasContentDigest(handle: []const u8) bool {
    return artifact_digest.hasContentDigest(handle, ".bin");
}

pub const Frame = struct {
    stream: Stream,
    payload: []u8,
};

pub const Byte = struct {
    stream: Stream,
    value: u8,
};

pub const Reader = struct {
    file: session_child_store.ManagedFile,
    size: usize,
    offset: usize,
    byte_buffer: [8192]u8 = undefined,
    byte_buffer_index: usize = 0,
    byte_buffer_len: usize = 0,
    byte_stream: Stream = .stdout,
    frame_remaining: usize = 0,

    pub fn open(
        alloc: Allocator,
        capability: *session_child_store.SessionChildCapability,
        descriptor: types.CommandOutputReplayDescriptor,
    ) !Reader {
        var reader: Reader = undefined;
        try openInto(&reader, alloc, capability, descriptor);
        return reader;
    }

    // noinline keeps the comptime-known error returns behind a call
    // boundary; inlined into a `!Reader` result location they each
    // materialize a Reader-sized (~8KB) error-union constant.
    noinline fn openInto(
        reader: *Reader,
        alloc: Allocator,
        capability: *session_child_store.SessionChildCapability,
        descriptor: types.CommandOutputReplayDescriptor,
    ) !void {
        var file = try capability.openFileReadOnly(
            alloc,
            .command_artifacts,
            descriptor.handle,
        );
        errdefer file.deinit();
        const stat = try file.stat();
        const size = std.math.cast(usize, stat.size) orelse
            return error.ReplayTooLarge;
        if (size != descriptor.framed_bytes) return error.ReplaySizeMismatch;
        if (size < replay_magic.len) return error.InvalidReplayHeader;
        const magic = try readExactRange(alloc, &file, 0, replay_magic.len);
        defer alloc.free(magic);
        if (!std.mem.eql(u8, magic, replay_magic)) return error.InvalidReplayHeader;
        reader.* = .{
            .file = file,
            .size = size,
            .offset = replay_magic.len,
        };
    }

    pub fn deinit(self: *Reader) void {
        self.file.deinit();
        self.* = undefined;
    }

    /// Returns one owned callback frame; caller frees `payload`.
    pub fn next(self: *Reader, alloc: Allocator) !?Frame {
        if (self.byte_buffer_index != self.byte_buffer_len or self.frame_remaining != 0) {
            return error.ReplayReaderModeConflict;
        }
        if (self.offset == self.size) return null;
        if (self.size - self.offset < frame_header_bytes) {
            return error.TruncatedReplayFrame;
        }
        const header = try readExactRange(
            alloc,
            &self.file,
            self.offset,
            frame_header_bytes,
        );
        defer alloc.free(header);
        const decoded = try decodeFrameHeader(header);
        const payload_start = try std.math.add(usize, self.offset, frame_header_bytes);
        const next_offset = try std.math.add(
            usize,
            payload_start,
            decoded.payload_len,
        );
        if (next_offset > self.size) return error.TruncatedReplayFrame;
        const payload = try readExactRange(
            alloc,
            &self.file,
            payload_start,
            decoded.payload_len,
        );
        self.offset = next_offset;
        return .{ .stream = decoded.stream, .payload = payload };
    }

    /// Returns one validated callback byte without allocating frame payloads.
    /// The fixed internal page keeps full-transcript replay memory independent
    /// of callback count and frame size.
    pub fn nextByte(self: *Reader) !?Byte {
        while (true) {
            if (self.byte_buffer_index < self.byte_buffer_len) {
                const value = self.byte_buffer[self.byte_buffer_index];
                self.byte_buffer_index += 1;
                return .{ .stream = self.byte_stream, .value = value };
            }
            self.byte_buffer_index = 0;
            self.byte_buffer_len = 0;

            if (self.frame_remaining == 0) {
                if (self.offset == self.size) return null;
                if (self.size - self.offset < frame_header_bytes) {
                    return error.TruncatedReplayFrame;
                }
                var header: [frame_header_bytes]u8 = undefined;
                try readExactInto(&self.file, self.offset, &header);
                const decoded = try decodeFrameHeader(&header);
                self.byte_stream = decoded.stream;
                self.offset = try std.math.add(usize, self.offset, frame_header_bytes);
                const payload_end = try std.math.add(
                    usize,
                    self.offset,
                    decoded.payload_len,
                );
                if (payload_end > self.size) return error.TruncatedReplayFrame;
                self.frame_remaining = decoded.payload_len;
            }

            const read_len = @min(self.byte_buffer.len, self.frame_remaining);
            try readExactInto(
                &self.file,
                self.offset,
                self.byte_buffer[0..read_len],
            );
            self.offset = try std.math.add(usize, self.offset, read_len);
            self.frame_remaining -= read_len;
            self.byte_buffer_len = read_len;
        }
    }
};

fn readExactInto(
    file: *session_child_store.ManagedFile,
    start: usize,
    out: []u8,
) !void {
    const start_u64 = std.math.cast(u64, start) orelse
        return error.ReplayOffsetTooLarge;
    const read_len = try file.readRangeInto(start_u64, out);
    if (read_len != out.len) return error.UnexpectedEndOfReplay;
}

fn readExactRange(
    alloc: Allocator,
    file: *session_child_store.ManagedFile,
    start: usize,
    len: usize,
) ![]u8 {
    const start_u64 = std.math.cast(u64, start) orelse
        return error.ReplayOffsetTooLarge;
    const bytes = try file.readRange(alloc, start_u64, len);
    if (bytes.len != len) {
        alloc.free(bytes);
        return error.UnexpectedEndOfReplay;
    }
    return bytes;
}

test "command replay capture spills without losing callback order" {
    const alloc = std.testing.allocator;
    var capture_arena = std.heap.ArenaAllocator.init(alloc);
    defer capture_arena.deinit();
    const capture_alloc = capture_arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        io_mod.permissionsFromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const display_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(display_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        display_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    const capture = try Capture.create(capture_alloc, 20, &capability);
    defer capture.abort(capture_alloc);
    capture.appendAccepted(capture_alloc, .stdout, "A");
    capture.appendAccepted(capture_alloc, .stderr, "B\n");
    capture.appendAccepted(capture_alloc, .stdout, "C\n");
    capture.seal(capture_alloc);

    const replay = capture.retain(capture_alloc) orelse return error.TestExpectedReplay;
    const descriptor = switch (replay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedReplay,
    };
    const replay_path = try std.fs.path.join(
        alloc,
        &.{ "logs", "commands", descriptor.handle },
    );
    defer alloc.free(replay_path);
    const replay_stat = try session_dir.statFile(
        io_mod.getIo(),
        replay_path,
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(
        @as(u32, 0o600),
        io_mod.permissionsToMode(replay_stat.permissions) & 0o777,
    );
    var reader = try Reader.open(alloc, &capability, descriptor);
    defer reader.deinit();

    const first = (try reader.next(alloc)).?;
    defer alloc.free(first.payload);
    try std.testing.expectEqual(Stream.stdout, first.stream);
    try std.testing.expectEqualStrings("A", first.payload);
    const second = (try reader.next(alloc)).?;
    defer alloc.free(second.payload);
    try std.testing.expectEqual(Stream.stderr, second.stream);
    try std.testing.expectEqualStrings("B\n", second.payload);
    const third = (try reader.next(alloc)).?;
    defer alloc.free(third.payload);
    try std.testing.expectEqual(Stream.stdout, third.stream);
    try std.testing.expectEqualStrings("C\n", third.payload);
    try std.testing.expect((try reader.next(alloc)) == null);

    var byte_reader = try Reader.open(alloc, &capability, descriptor);
    defer byte_reader.deinit();
    const expected = [_]Byte{
        .{ .stream = .stdout, .value = 'A' },
        .{ .stream = .stderr, .value = 'B' },
        .{ .stream = .stderr, .value = '\n' },
        .{ .stream = .stdout, .value = 'C' },
        .{ .stream = .stdout, .value = '\n' },
    };
    for (expected) |expected_byte| {
        const actual = (try byte_reader.nextByte()).?;
        try std.testing.expectEqual(expected_byte.stream, actual.stream);
        try std.testing.expectEqual(expected_byte.value, actual.value);
    }
    try std.testing.expect((try byte_reader.nextByte()) == null);
}

test "command replay reader rejects descriptor and frame corruption" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        io_mod.permissionsFromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const display_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(display_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        display_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    var malformed = try capability.createExclusiveFile(
        alloc,
        .command_artifacts,
        "fx-command-replay-malformed.bin",
    );
    defer malformed.deinit();
    try malformed.writeAll("not-a-replay");
    try malformed.sync();

    try std.testing.expectError(
        error.InvalidReplayHeader,
        Reader.open(alloc, &capability, .{
            .handle = "fx-command-replay-malformed.bin",
            .framed_bytes = "not-a-replay".len,
        }),
    );
    try std.testing.expectError(
        error.ReplaySizeMismatch,
        Reader.open(alloc, &capability, .{
            .handle = "fx-command-replay-malformed.bin",
            .framed_bytes = 1,
        }),
    );

    const empty_handle = "fx-command-replay-empty-frame.bin";
    var empty_replay = [_]u8{0} ** (replay_magic.len + frame_header_bytes);
    @memcpy(empty_replay[0..replay_magic.len], replay_magic);
    var empty_file = try capability.createExclusiveFile(
        alloc,
        .command_artifacts,
        empty_handle,
    );
    defer empty_file.deinit();
    try empty_file.writeAll(&empty_replay);
    try empty_file.sync();
    const empty_descriptor: types.CommandOutputReplayDescriptor = .{
        .handle = empty_handle,
        .framed_bytes = empty_replay.len,
    };

    var frame_reader = try Reader.open(alloc, &capability, empty_descriptor);
    defer frame_reader.deinit();
    try std.testing.expectError(error.EmptyReplayFrame, frame_reader.next(alloc));

    var byte_reader = try Reader.open(alloc, &capability, empty_descriptor);
    defer byte_reader.deinit();
    try std.testing.expectError(error.EmptyReplayFrame, byte_reader.nextByte());

    try std.testing.expectError(
        error.EmptyReplayFrame,
        Capture.canonicalizeFramedBytes(
            alloc,
            &empty_replay,
            max_frame_payload_bytes,
        ),
    );
}

test "command replay cleanup removes tentative and retained spools exactly once" {
    const alloc = std.testing.allocator;
    var capture_arena = std.heap.ArenaAllocator.init(alloc);
    defer capture_arena.deinit();
    const capture_alloc = capture_arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        io_mod.permissionsFromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const display_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(display_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        display_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    const capture = try Capture.create(capture_alloc, 1, &capability);
    capture.appendAccepted(capture_alloc, .stdout, "spilled");
    capture.seal(capture_alloc);
    var before = try capability.iterate(alloc, .command_artifacts);
    defer before.deinit();
    try std.testing.expectEqual(@as(usize, 1), before.names.len);

    capture.abort(capture_alloc);
    capture.abort(capture_alloc);
    var after = try capability.iterate(alloc, .command_artifacts);
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 0), after.names.len);

    const retained_capture = try Capture.create(capture_alloc, 1, &capability);
    retained_capture.appendAccepted(capture_alloc, .stdout, "retained");
    const retained_replay = retained_capture.retain(capture_alloc) orelse
        return error.TestExpectedReplay;
    const retained_descriptor = switch (retained_replay) {
        .available => |descriptor| descriptor,
        .unavailable => return error.TestExpectedReplay,
    };
    try std.testing.expect(hasContentDigest(retained_descriptor.handle));
    var retained = try capability.iterate(alloc, .command_artifacts);
    defer retained.deinit();
    try std.testing.expectEqual(@as(usize, 1), retained.names.len);

    retained_capture.discard(capture_alloc);
    retained_capture.discard(capture_alloc);
    var discarded = try capability.iterate(alloc, .command_artifacts);
    defer discarded.deinit();
    try std.testing.expectEqual(@as(usize, 0), discarded.names.len);
}
