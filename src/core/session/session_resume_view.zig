const std = @import("std");
const io_mod = @import("../shared/io.zig");
const session_event = @import("session_event.zig");
const session_layout = @import("session_layout.zig");

const Allocator = std.mem.Allocator;

pub const max_text_bytes: usize = 128 * 1024;
const sidecar_file = "resume-view.bin";

const magic = "FXRV";
const schema_version: u8 = 3;
const fixed_header_bytes = magic.len + 1 + 2 + 2 + 2 + 1 + 16 + 8 + 8 + 4;
const max_sidecar_bytes = fixed_header_bytes + 255 + max_text_bytes;

pub const Boundary = struct {
    log_generation: session_event.Identifier,
    seq: u64,
    event_log_bytes: u64,
};

pub const Capture = struct {
    terminal_rows: u16,
    terminal_cols: u16,
    complete: bool,

    pub fn canPaintAt(self: Capture, terminal_rows: u16, terminal_cols: u16) bool {
        return self.complete and
            self.terminal_rows == terminal_rows and
            self.terminal_cols == terminal_cols;
    }
};

pub const View = struct {
    session_id: []u8,
    boundary: Boundary,
    capture: Capture,
    text: []u8,

    pub fn deinit(self: *View, alloc: Allocator) void {
        alloc.free(self.session_id);
        alloc.free(self.text);
        self.* = undefined;
    }
};

pub const LoadOutcome = union(enum) {
    missing,
    invalid,
    stale,
    exact: View,
    older: View,

    pub fn deinit(self: *LoadOutcome, alloc: Allocator) void {
        switch (self.*) {
            .exact, .older => |*view| view.deinit(alloc),
            .missing, .invalid, .stale => {},
        }
        self.* = undefined;
    }
};

fn encode(
    alloc: Allocator,
    session_id: []const u8,
    boundary: Boundary,
    capture: Capture,
    text: []const u8,
) ![]u8 {
    session_layout.validateSessionId(session_id) catch return error.InvalidResumeView;
    if (capture.terminal_rows == 0 or capture.terminal_cols == 0) {
        return error.InvalidResumeView;
    }
    if (text.len > max_text_bytes) return error.ResumeViewTooLarge;
    if (!validVisibleText(text)) return error.InvalidResumeView;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(magic);
    try out.writer.writeByte(schema_version);
    try writeInt(&out.writer, u16, @intCast(session_id.len));
    try writeInt(&out.writer, u16, capture.terminal_rows);
    try writeInt(&out.writer, u16, capture.terminal_cols);
    try out.writer.writeByte(@intFromBool(capture.complete));
    try out.writer.writeAll(&boundary.log_generation);
    try writeInt(&out.writer, u64, boundary.seq);
    try writeInt(&out.writer, u64, boundary.event_log_bytes);
    try writeInt(&out.writer, u32, @intCast(text.len));
    try out.writer.writeAll(session_id);
    try out.writer.writeAll(text);
    return try out.toOwnedSlice();
}

fn decode(alloc: Allocator, bytes: []const u8) !View {
    if (bytes.len < fixed_header_bytes or bytes.len > max_sidecar_bytes) {
        return error.InvalidResumeView;
    }
    var cursor = Cursor{ .bytes = bytes };
    if (!std.mem.eql(u8, try cursor.take(magic.len), magic)) {
        return error.InvalidResumeView;
    }
    if ((try cursor.take(1))[0] != schema_version) return error.InvalidResumeView;
    const session_id_len = try cursor.readInt(u16);
    const terminal_rows = try cursor.readInt(u16);
    const terminal_cols = try cursor.readInt(u16);
    const complete = (try cursor.take(1))[0];
    const generation = try cursor.take(16);
    const seq = try cursor.readInt(u64);
    const event_log_bytes = try cursor.readInt(u64);
    const text_len = try cursor.readInt(u32);
    if (session_id_len == 0 or terminal_rows == 0 or terminal_cols == 0 or
        complete > 1 or text_len > max_text_bytes)
    {
        return error.InvalidResumeView;
    }
    const session_id = try cursor.take(session_id_len);
    const text = try cursor.take(text_len);
    if (cursor.remaining() != 0 or !validVisibleText(text)) return error.InvalidResumeView;
    session_layout.validateSessionId(session_id) catch return error.InvalidResumeView;

    const owned_id = try alloc.dupe(u8, session_id);
    errdefer alloc.free(owned_id);
    return .{
        .session_id = owned_id,
        .boundary = .{
            .log_generation = generation[0..16].*,
            .seq = seq,
            .event_log_bytes = event_log_bytes,
        },
        .capture = .{
            .terminal_rows = terminal_rows,
            .terminal_cols = terminal_cols,
            .complete = complete == 1,
        },
        .text = try alloc.dupe(u8, text),
    };
}

pub fn write(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    boundary: Boundary,
    capture: Capture,
    text: []const u8,
) !void {
    const encoded = try encode(alloc, session_id, boundary, capture, text);
    defer alloc.free(encoded);
    try io_mod.durableReplaceVerified(alloc, session_dir, sidecar_file, encoded);
}

pub fn loadMatching(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    boundary: Boundary,
) !LoadOutcome {
    var file = io_mod.openExistingRegularFile(
        session_dir.dir,
        sidecar_file,
        .read_only,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.FileNotFound) return .missing;
        return .invalid;
    };
    defer file.close(io_mod.getIo());
    const stat = file.stat(io_mod.getIo()) catch return .invalid;
    if (!safeFile(stat) or stat.size == 0 or stat.size > max_sidecar_bytes) {
        return .invalid;
    }
    const bytes = io_mod.readFileToEnd(alloc, &file, max_sidecar_bytes) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .invalid;
    };
    defer alloc.free(bytes);
    var view = decode(alloc, bytes) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .invalid;
    };
    if (!std.mem.eql(u8, view.session_id, session_id) or
        !std.mem.eql(u8, &view.boundary.log_generation, &boundary.log_generation) or
        view.boundary.seq > boundary.seq or
        view.boundary.event_log_bytes > boundary.event_log_bytes)
    {
        view.deinit(alloc);
        return .stale;
    }
    return if (std.meta.eql(view.boundary, boundary))
        .{ .exact = view }
    else
        .{ .older = view };
}

fn safeFile(stat: std.Io.File.Stat) bool {
    return stat.kind == .file and stat.nlink == 1 and
        io_mod.permissionsPrivateFile(stat.permissions);
}

fn validVisibleText(text: []const u8) bool {
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return false;
    var has_content = false;
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == 0x1b) {
            const sequence_len = validSgrSequence(text[index..]) orelse return false;
            index += sequence_len;
            continue;
        }
        if ((byte < ' ' and byte != '\n') or byte == 0x7f) return false;
        if (byte != '\n') has_content = true;
        index += 1;
    }
    return has_content;
}

fn validSgrSequence(text: []const u8) ?usize {
    if (text.len < 4 or text[0] != 0x1b or text[1] != '[') return null;
    const end = std.mem.indexOfScalar(u8, text[2..], 'm') orelse return null;
    const encoded = text[2 .. end + 2];
    var values: [5]u16 = undefined;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, encoded, ';');
    while (parts.next()) |part| {
        if (part.len == 0 or count == values.len) return null;
        values[count] = std.fmt.parseInt(u16, part, 10) catch return null;
        count += 1;
    }
    const safe = switch (count) {
        1 => values[0] == 0 or
            (values[0] >= 1 and values[0] <= 4) or
            values[0] == 7 or values[0] == 9 or
            (values[0] >= 30 and values[0] <= 37) or
            (values[0] >= 40 and values[0] <= 47) or
            (values[0] >= 90 and values[0] <= 97) or
            (values[0] >= 100 and values[0] <= 107),
        3 => (values[0] == 38 or values[0] == 48) and
            values[1] == 5 and values[2] <= 255,
        5 => (values[0] == 38 or values[0] == 48) and
            values[1] == 2 and values[2] <= 255 and
            values[3] <= 255 and values[4] <= 255,
        else => false,
    };
    return if (safe) end + 3 else null;
}

fn writeInt(writer: *std.Io.Writer, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, len: usize) ![]const u8 {
        if (len > self.remaining()) return error.InvalidResumeView;
        defer self.pos += len;
        return self.bytes[self.pos..][0..len];
    }

    fn readInt(self: *Cursor, comptime T: type) !T {
        const raw = try self.take(@sizeOf(T));
        return std.mem.readInt(T, raw[0..@sizeOf(T)], .little);
    }

    fn remaining(self: Cursor) usize {
        return self.bytes.len - self.pos;
    }
};

fn openTestVerifiedDir(dir: std.Io.Dir) !io_mod.VerifiedDir {
    return .{
        .dir = try dir.openDir(
            io_mod.getIo(),
            ".",
            .{ .iterate = true, .follow_symlinks = false },
        ),
    };
}

const test_capture = Capture{
    .terminal_rows = 24,
    .terminal_cols = 80,
    .complete = true,
};

test "resume view codec round trips its durable boundary and visible text" {
    const alloc = std.testing.allocator;
    const boundary = Boundary{
        .log_generation = [_]u8{0x2a} ** 16,
        .seq = 42,
        .event_log_bytes = 4096,
    };
    const encoded = try encode(alloc, "session-1", boundary, test_capture, "restored tail\n● 2 tool calls\n");
    defer alloc.free(encoded);

    var decoded = try decode(alloc, encoded);
    defer decoded.deinit(alloc);

    try std.testing.expectEqualStrings("session-1", decoded.session_id);
    try std.testing.expectEqualSlices(u8, &boundary.log_generation, &decoded.boundary.log_generation);
    try std.testing.expectEqual(boundary.seq, decoded.boundary.seq);
    try std.testing.expectEqual(boundary.event_log_bytes, decoded.boundary.event_log_bytes);
    try std.testing.expectEqual(test_capture, decoded.capture);
    try std.testing.expectEqualStrings("restored tail\n● 2 tool calls\n", decoded.text);
}

test "resume view capture only paints at complete matching geometry" {
    try std.testing.expect(test_capture.canPaintAt(24, 80));
    try std.testing.expect(!test_capture.canPaintAt(23, 80));
    try std.testing.expect(!test_capture.canPaintAt(24, 79));
    try std.testing.expect(!(Capture{
        .terminal_rows = 24,
        .terminal_cols = 80,
        .complete = false,
    }).canPaintAt(24, 80));
}

test "resume view codec round trips safe terminal styling" {
    const alloc = std.testing.allocator;
    const boundary = Boundary{
        .log_generation = [_]u8{0x2a} ** 16,
        .seq = 42,
        .event_log_bytes = 4096,
    };
    const styled = "\x1b[0m\x1b[1m\x1b[3m\x1b[31m\x1b[38;2;1;2;3m" ++
        "\x1b[48;5;245mgray\x1b[0m\n";
    const encoded = try encode(alloc, "session-1", boundary, test_capture, styled);
    defer alloc.free(encoded);

    var decoded = try decode(alloc, encoded);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualStrings(styled, decoded.text);
}

test "resume view codec rejects unsafe or oversized visible text" {
    const alloc = std.testing.allocator;
    const boundary = Boundary{
        .log_generation = [_]u8{0x17} ** 16,
        .seq = 7,
        .event_log_bytes = 512,
    };

    try std.testing.expectError(
        error.InvalidResumeView,
        encode(alloc, "session-1", boundary, test_capture, "unsafe\x1b[2J"),
    );
    try std.testing.expectError(
        error.InvalidResumeView,
        encode(alloc, "session-1", boundary, test_capture, "unsafe\x1b]8;;https://example.com\x1b\\link"),
    );
    try std.testing.expectError(
        error.InvalidResumeView,
        encode(alloc, "session-1", boundary, test_capture, "unsafe\x1b[38;5;999m"),
    );
    try std.testing.expectError(
        error.InvalidResumeView,
        encode(alloc, "session-1", boundary, test_capture, "unsafe\x1b[0;31m"),
    );
    try std.testing.expectError(
        error.InvalidResumeView,
        encode(alloc, "session-1", boundary, test_capture, "\n\n"),
    );
    try std.testing.expectError(
        error.InvalidResumeView,
        encode(alloc, "session-1", boundary, .{
            .terminal_rows = 0,
            .terminal_cols = 80,
            .complete = true,
        }, "visible\n"),
    );

    const oversized = try alloc.alloc(u8, max_text_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(
        error.ResumeViewTooLarge,
        encode(alloc, "session-1", boundary, test_capture, oversized),
    );
}

test "resume view sidecar classifies exact and older durable boundaries" {
    const alloc = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var verified = try openTestVerifiedDir(temp.dir);
    defer verified.close();

    const boundary = Boundary{
        .log_generation = [_]u8{0x31} ** 16,
        .seq = 11,
        .event_log_bytes = 2048,
    };
    try write(alloc, &verified, "session-1", boundary, test_capture, "cached session tail\n");

    var restored = try loadMatching(alloc, &verified, "session-1", boundary);
    defer restored.deinit(alloc);
    try std.testing.expect(restored == .exact);
    try std.testing.expectEqualStrings("cached session tail\n", restored.exact.text);

    const advanced = Boundary{
        .log_generation = boundary.log_generation,
        .seq = boundary.seq + 1,
        .event_log_bytes = boundary.event_log_bytes + 64,
    };
    var older = try loadMatching(alloc, &verified, "session-1", advanced);
    defer older.deinit(alloc);
    try std.testing.expect(older == .older);
    try std.testing.expectEqualStrings("cached session tail\n", older.older.text);
}

test "resume view sidecar rejects forward and cross-generation boundaries" {
    const alloc = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var verified = try openTestVerifiedDir(temp.dir);
    defer verified.close();

    const stored = Boundary{
        .log_generation = [_]u8{0x31} ** 16,
        .seq = 11,
        .event_log_bytes = 2048,
    };
    try write(alloc, &verified, "session-1", stored, test_capture, "cached session tail\n");

    var forward_seq = try loadMatching(alloc, &verified, "session-1", .{
        .log_generation = stored.log_generation,
        .seq = stored.seq - 1,
        .event_log_bytes = stored.event_log_bytes,
    });
    defer forward_seq.deinit(alloc);
    try std.testing.expect(forward_seq == .stale);

    var forward_bytes = try loadMatching(alloc, &verified, "session-1", .{
        .log_generation = stored.log_generation,
        .seq = stored.seq,
        .event_log_bytes = stored.event_log_bytes - 1,
    });
    defer forward_bytes.deinit(alloc);
    try std.testing.expect(forward_bytes == .stale);

    var cross_generation = try loadMatching(alloc, &verified, "session-1", .{
        .log_generation = [_]u8{0x32} ** 16,
        .seq = stored.seq,
        .event_log_bytes = stored.event_log_bytes,
    });
    defer cross_generation.deinit(alloc);
    try std.testing.expect(cross_generation == .stale);
}

test "resume view sidecar treats missing and corrupt cache data as fallback" {
    const alloc = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var verified = try openTestVerifiedDir(temp.dir);
    defer verified.close();
    const boundary = Boundary{
        .log_generation = [_]u8{0x44} ** 16,
        .seq = 3,
        .event_log_bytes = 128,
    };

    var missing = try loadMatching(alloc, &verified, "session-1", boundary);
    defer missing.deinit(alloc);
    try std.testing.expect(missing == .missing);

    try io_mod.durableReplaceVerified(alloc, &verified, sidecar_file, "broken");
    var invalid = try loadMatching(alloc, &verified, "session-1", boundary);
    defer invalid.deinit(alloc);
    try std.testing.expect(invalid == .invalid);

    const encoded = try encode(alloc, "session-1", boundary, test_capture, "cached session tail\n");
    defer alloc.free(encoded);
    encoded[magic.len] = 2;
    try io_mod.durableReplaceVerified(alloc, &verified, sidecar_file, encoded);
    var stale_presentation = try loadMatching(alloc, &verified, "session-1", boundary);
    defer stale_presentation.deinit(alloc);
    try std.testing.expect(stale_presentation == .invalid);

    encoded[magic.len] = 1;
    try io_mod.durableReplaceVerified(alloc, &verified, sidecar_file, encoded);
    var old_schema = try loadMatching(alloc, &verified, "session-1", boundary);
    defer old_schema.deinit(alloc);
    try std.testing.expect(old_schema == .invalid);

    encoded[magic.len] = schema_version;
    const invalid_complete_offset = magic.len + 1 + 2 + 2 + 2;
    encoded[invalid_complete_offset] = 2;
    try io_mod.durableReplaceVerified(alloc, &verified, sidecar_file, encoded);
    var invalid_complete = try loadMatching(alloc, &verified, "session-1", boundary);
    defer invalid_complete.deinit(alloc);
    try std.testing.expect(invalid_complete == .invalid);

    try write(alloc, &verified, "session-1", boundary, test_capture, "cached session tail\n");
    var wrong_session = try loadMatching(alloc, &verified, "session-2", boundary);
    defer wrong_session.deinit(alloc);
    try std.testing.expect(wrong_session == .stale);
}
