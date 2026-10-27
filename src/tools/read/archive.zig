//! Archives read_file opens natively through std: zip (and jar, whl), tar
//! and gzipped tar list their members or return one member's bytes, and a
//! single-stream `.gz` returns its decompressed bytes. Nothing is written to
//! disk.
const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Format = enum { zip, tar, tar_gz };

/// Members past this many are counted, not listed.
const max_listed: usize = 500;

pub fn formatFor(path: []const u8) Format {
    if (endsWith(path, ".tar.gz") or endsWith(path, ".tgz")) return .tar_gz;
    if (endsWith(path, ".tar")) return .tar;
    return .zip;
}

fn endsWith(text: []const u8, suffix: []const u8) bool {
    return text.len >= suffix.len and std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

pub const Member = struct {
    name: []const u8,
    size: u64,
    directory: bool,
};

/// Lists the members under `prefix` (all when empty) as text. `label` names
/// the archive in the output. Caller owns the result.
pub fn list(alloc: Allocator, path: []const u8, label: []const u8, prefix: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var members: std.ArrayList(Member) = .empty;
    try walk(arena, path, .{ .collect = &members });

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    var shown: usize = 0;
    var matched: usize = 0;
    var total_bytes: u64 = 0;
    for (members.items) |member| {
        if (!std.mem.startsWith(u8, member.name, prefix)) continue;
        matched += 1;
        total_bytes += member.size;
        if (shown == max_listed) continue;
        shown += 1;
        if (member.directory) {
            try w.print("{s:>10}  {s}\n", .{ "dir", member.name });
        } else {
            var size_buf: [16]u8 = undefined;
            try w.print("{s:>10}  {s}\n", .{ humanSize(&size_buf, member.size), member.name });
        }
    }
    if (matched > shown) try w.print("… {d} more members\n", .{matched - shown});
    var size_buf: [16]u8 = undefined;
    const body = try out.toOwnedSlice();
    defer alloc.free(body);
    const scope = if (prefix.len > 0) try arena.print(" under {s}", .{prefix}) else "";
    return alloc.print("Archive {s}{s} · {d} {s} · {s}\n{s}Read a member as {s}:<member>.", .{
        label,
        scope,
        matched,
        if (matched == 1) "member" else "members",
        humanSize(&size_buf, total_bytes),
        body,
        label,
    });
}

pub const ReadError = error{ MemberNotFound, MemberTooLarge, MemberIsDirectory } || anyerror;

/// The bytes of member `name`, at most `max_bytes`. Caller owns them.
pub fn readMember(alloc: Allocator, path: []const u8, name: []const u8, max_bytes: usize) ![]u8 {
    var found: ?[]u8 = null;
    errdefer if (found) |bytes| alloc.free(bytes);
    var state: Wanted = .{ .alloc = alloc, .name = name, .max_bytes = max_bytes, .found = &found };
    try walk(alloc, path, .{ .want = &state });
    if (state.directory) return error.MemberIsDirectory;
    return found orelse error.MemberNotFound;
}

/// The decompressed bytes of a single-stream gzip file. Caller owns them.
pub fn readGzip(alloc: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const io = io_mod.getIo();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buf: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&reader.interface, .gzip, &window);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    _ = decompress.reader.streamRemaining(&out.writer) catch |err| switch (err) {
        error.ReadFailed => return decompress.err orelse error.ReadFailed,
        else => return err,
    };
    if (out.written().len > max_bytes) {
        out.shrinkRetainingCapacity(max_bytes);
    }
    return out.toOwnedSlice();
}

const Wanted = struct {
    alloc: Allocator,
    name: []const u8,
    max_bytes: usize,
    found: *?[]u8,
    directory: bool = false,
};

const Visit = union(enum) {
    collect: *std.ArrayList(Member),
    want: *Wanted,
};

fn walk(alloc: Allocator, path: []const u8, visit: Visit) !void {
    const io = io_mod.getIo();
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buf: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    switch (formatFor(path)) {
        .zip => try walkZip(alloc, &reader, visit),
        .tar => try walkTar(alloc, &reader.interface, visit),
        .tar_gz => {
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress: std.compress.flate.Decompress = .init(&reader.interface, .gzip, &window);
            try walkTar(alloc, &decompress.reader, visit);
        },
    }
}

fn walkZip(alloc: Allocator, reader: *std.Io.File.Reader, visit: Visit) !void {
    var iterator = try std.zip.Iterator.init(reader);
    var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    while (try iterator.next()) |entry| {
        const name = entry.getFilename(reader, &name_buf, .{ .allow_backslashes = true }) catch continue;
        const directory = name.len > 0 and name[name.len - 1] == '/';
        switch (visit) {
            .collect => |members| try members.append(alloc, .{
                .name = try alloc.dupe(u8, name),
                .size = entry.uncompressed_size,
                .directory = directory,
            }),
            .want => |wanted| {
                if (!sameMember(name, wanted.name)) continue;
                if (directory) {
                    wanted.directory = true;
                    return;
                }
                if (entry.uncompressed_size > wanted.max_bytes) return error.MemberTooLarge;
                var out: std.Io.Writer.Allocating = .init(wanted.alloc);
                errdefer out.deinit();
                try entry.extractTo(reader, &out.writer);
                wanted.found.* = try out.toOwnedSlice();
                return;
            },
        }
    }
}

fn walkTar(alloc: Allocator, reader: *std.Io.Reader, visit: Visit) !void {
    var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var iterator: std.tar.Iterator = .init(reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    while (try iterator.next()) |entry| {
        if (entry.kind == .sym_link) continue;
        const directory = entry.kind == .directory;
        switch (visit) {
            .collect => |members| try members.append(alloc, .{
                .name = if (directory and !std.mem.endsWith(u8, entry.name, "/"))
                    try alloc.print("{s}/", .{entry.name})
                else
                    try alloc.dupe(u8, entry.name),
                .size = entry.size,
                .directory = directory,
            }),
            .want => |wanted| {
                if (!sameMember(entry.name, wanted.name)) continue;
                if (directory) {
                    wanted.directory = true;
                    return;
                }
                if (entry.size > wanted.max_bytes) return error.MemberTooLarge;
                var out: std.Io.Writer.Allocating = .init(wanted.alloc);
                errdefer out.deinit();
                try iterator.streamRemaining(entry, &out.writer);
                wanted.found.* = try out.toOwnedSlice();
                return;
            },
        }
    }
}

/// Members match with or without a leading `./` or a trailing `/`.
fn sameMember(stored: []const u8, wanted: []const u8) bool {
    const a = std.mem.trimEnd(u8, if (std.mem.startsWith(u8, stored, "./")) stored[2..] else stored, "/");
    const b = std.mem.trimEnd(u8, if (std.mem.startsWith(u8, wanted, "./")) wanted[2..] else wanted, "/");
    return std.mem.eql(u8, a, b);
}

pub fn humanSize(buf: []u8, bytes: u64) []const u8 {
    if (bytes < 1024) return std.mem.print(buf, "{d} B", .{bytes}) catch "";
    const kib = @as(f64, @floatFromInt(bytes)) / 1024.0;
    if (kib < 1024) return std.mem.print(buf, "{d:.1} KB", .{kib}) catch "";
    return std.mem.print(buf, "{d:.1} MB", .{kib / 1024.0}) catch "";
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

/// A stored (uncompressed) zip with the given members, built by hand so
/// tests need no fixture files.
pub fn buildStoredZip(alloc: Allocator, members: []const [2][]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    var offsets: [16]u32 = undefined;
    for (members, 0..) |member, i| {
        offsets[i] = @intCast(out.written().len);
        const crc = std.hash.Crc32.hash(member[1]);
        try w.writeAll("PK\x03\x04");
        try w.writeInt(u16, 10, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, @intCast(member[1].len), .little);
        try w.writeInt(u32, @intCast(member[1].len), .little);
        try w.writeInt(u16, @intCast(member[0].len), .little);
        try w.writeInt(u16, 0, .little);
        try w.writeAll(member[0]);
        try w.writeAll(member[1]);
    }
    const cd_start: u32 = @intCast(out.written().len);
    for (members, 0..) |member, i| {
        const crc = std.hash.Crc32.hash(member[1]);
        try w.writeAll("PK\x01\x02");
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 10, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, @intCast(member[1].len), .little);
        try w.writeInt(u32, @intCast(member[1].len), .little);
        try w.writeInt(u16, @intCast(member[0].len), .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u32, 0, .little);
        try w.writeInt(u32, offsets[i], .little);
        try w.writeAll(member[0]);
    }
    const cd_size: u32 = @as(u32, @intCast(out.written().len)) - cd_start;
    try w.writeAll("PK\x05\x06");
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, @intCast(members.len), .little);
    try w.writeInt(u16, @intCast(members.len), .little);
    try w.writeInt(u32, cd_size, .little);
    try w.writeInt(u32, cd_start, .little);
    try w.writeInt(u16, 0, .little);
    return out.toOwnedSlice();
}

/// A ustar archive with the given regular files.
pub fn buildTar(alloc: Allocator, members: []const [2][]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (members) |member| {
        var header: [512]u8 = @splat(0);
        @memcpy(header[0..member[0].len], member[0]);
        _ = try std.mem.print(header[100..108], "0000644\x00", .{});
        _ = try std.mem.print(header[108..116], "0000000\x00", .{});
        _ = try std.mem.print(header[116..124], "0000000\x00", .{});
        _ = try std.mem.print(header[124..136], "{o:0>11}\x00", .{member[1].len});
        _ = try std.mem.print(header[136..148], "00000000000\x00", .{});
        header[156] = '0';
        @memcpy(header[257..263], "ustar\x00");
        @memcpy(header[263..265], "00");
        @memset(header[148..156], ' ');
        var sum: u32 = 0;
        for (header) |byte| sum += byte;
        _ = try std.mem.print(header[148..156], "{o:0>6}\x00 ", .{sum});
        try out.writer.writeAll(&header);
        try out.writer.writeAll(member[1]);
        const pad = (512 - member[1].len % 512) % 512;
        try out.writer.splatByteAll(0, pad);
    }
    try out.writer.splatByteAll(0, 1024);
    return out.toOwnedSlice();
}

fn tmpFile(alloc: Allocator, tmp: std.testing.TmpDir, name: []const u8, data: []const u8) ![]u8 {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data });
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, name);
}

test "zip archives list members and read one" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try buildStoredZip(alloc, &.{ .{ "src/a.txt", "alpha\nbeta\n" }, .{ "README.md", "# Hi\n" } });
    defer alloc.free(bytes);
    const path = try tmpFile(alloc, tmp, "bundle.zip", bytes);
    defer alloc.free(path);

    const listing = try list(alloc, path, "bundle.zip", "");
    defer alloc.free(listing);
    try testing.expect(std.mem.find(u8, listing, "2 members") != null);
    try testing.expect(std.mem.find(u8, listing, "src/a.txt") != null);

    const member = try readMember(alloc, path, "src/a.txt", 1024);
    defer alloc.free(member);
    try testing.expectEqualStrings("alpha\nbeta\n", member);
    try testing.expectError(error.MemberNotFound, readMember(alloc, path, "nope", 1024));
    try testing.expectError(error.MemberTooLarge, readMember(alloc, path, "src/a.txt", 3));
}

test "tar archives list members and read one" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try buildTar(alloc, &.{ .{ "logs/app.log", "one\ntwo\n" }, .{ "notes.txt", "n\n" } });
    defer alloc.free(bytes);
    const path = try tmpFile(alloc, tmp, "logs.tar", bytes);
    defer alloc.free(path);

    const listing = try list(alloc, path, "logs.tar", "logs/");
    defer alloc.free(listing);
    try testing.expect(std.mem.find(u8, listing, "1 member") != null);
    try testing.expect(std.mem.find(u8, listing, "notes.txt") == null);

    const member = try readMember(alloc, path, "./logs/app.log", 1024);
    defer alloc.free(member);
    try testing.expectEqualStrings("one\ntwo\n", member);
}

/// `data` gzipped with stored blocks.
pub fn buildGzip(alloc: Allocator, data: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var buf: [std.compress.flate.max_window_len]u8 = undefined;
    var raw = try std.compress.flate.Compress.Raw.init(&out.writer, &buf, .gzip);
    try raw.writer.writeAll(data);
    try raw.finish();
    return out.toOwnedSlice();
}

test "gzipped tar archives and single gzip streams decompress" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tar_bytes = try buildTar(alloc, &.{.{ "pkg/index.js", "export {};\n" }});
    defer alloc.free(tar_bytes);
    const tgz = try buildGzip(alloc, tar_bytes);
    defer alloc.free(tgz);
    const path = try tmpFile(alloc, tmp, "pkg.tgz", tgz);
    defer alloc.free(path);
    const member = try readMember(alloc, path, "pkg/index.js", 1024);
    defer alloc.free(member);
    try testing.expectEqualStrings("export {};\n", member);

    const log_gz = try buildGzip(alloc, "line 1\nline 2\n");
    defer alloc.free(log_gz);
    const log_path = try tmpFile(alloc, tmp, "server.log.gz", log_gz);
    defer alloc.free(log_path);
    const text = try readGzip(alloc, log_path, 1024);
    defer alloc.free(text);
    try testing.expectEqualStrings("line 1\nline 2\n", text);
}
