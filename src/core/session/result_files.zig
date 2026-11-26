//! Per-session bash tool output store (`$FX_OUT`, `tests/tla/bash_tool/ResultStore.tla`):
//! numbered result files `N.txt` and `index.tsv` written atomically with size caps.
const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

/// Per-file size limit (16 MiB). Outputs larger than this keep their first and
/// last `cut_keep_bytes` with a cut marker line between them (S4-5).
pub const max_file_bytes: usize = 16 * 1024 * 1024;
pub const cut_keep_bytes: usize = max_file_bytes / 2;

/// Per-folder size limit across all `N.txt` files (256 MiB, S4-5).
pub const max_folder_bytes: u64 = 256 * 1024 * 1024;

/// Maximum UTF-8 byte length of the `command` column in `index.tsv` (S4-7).
pub const max_command_bytes: usize = 200;

pub const index_file_name = "index.tsv";
pub const index_header = "n\texit\tbytes\tlines\tcommand\n";

pub const Limits = struct {
    max_file_bytes: usize = max_file_bytes,
    max_folder_bytes: u64 = max_folder_bytes,
};

pub const Exit = union(enum) {
    code: i32,
    signal: i32,
    stopped,
    lost,
    unknown,
};

pub const IndexRow = struct {
    n: u64,
    exit: Exit,
    bytes: u64,
    lines: u64,
    command: []const u8,
};

pub const SaveOutcome = union(enum) {
    saved: struct {
        original_bytes: u64,
        written_bytes: usize,
        cut_bytes: u64,
    },
    full: struct {
        used_bytes: u64,
        needed_bytes: usize,
    },
};

pub const ResultFolder = struct {
    alloc: Allocator,
    path: []u8,
    dir: io_mod.VerifiedDir,
    limits: Limits = .{},

    /// Opens or creates a plain result folder at `dir_path` (the `--no-save`
    /// path, e.g. `out/` inside a temp folder) with `0700` permissions.
    pub fn init(alloc: Allocator, dir_path: []const u8) !ResultFolder {
        return initWithLimits(alloc, dir_path, .{});
    }

    pub fn initWithLimits(alloc: Allocator, dir_path: []const u8, limits: Limits) !ResultFolder {
        if (dir_path.len == 0 or limits.max_file_bytes < 2) return error.InvalidArgument;
        const io = io_mod.getIo();
        const trimmed = std.mem.trimEnd(u8, dir_path, "/");
        if (trimmed.len == 0) return error.DurablePathUnsafe;
        const leaf = std.Io.Dir.path.basename(trimmed);
        if (leaf.len == 0 or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..")) {
            return error.DurablePathUnsafe;
        }
        const parent_path = std.Io.Dir.path.dirname(trimmed) orelse ".";
        var parent_dir = if (std.Io.Dir.path.isAbsolute(parent_path))
            try std.Io.Dir.openDirAbsolute(io, parent_path, .{ .iterate = true, .follow_symlinks = false })
        else
            try std.Io.Dir.cwd().openDir(io, parent_path, .{ .iterate = true, .follow_symlinks = false });
        defer parent_dir.close(io);

        var dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(parent_dir, leaf);
        errdefer dir.close();
        const abs_path = try io_mod.dirRealpathAlloc(alloc, dir.dir, ".");
        return fromVerifiedDir(alloc, abs_path, dir, limits);
    }

    /// Adopts an already-opened private directory (used by `session_adapter`).
    pub fn fromVerifiedDir(alloc: Allocator, path: []u8, dir: io_mod.VerifiedDir, limits: Limits) ResultFolder {
        return .{
            .alloc = alloc,
            .path = path,
            .dir = dir,
            .limits = limits,
        };
    }

    pub fn deinit(self: *ResultFolder) void {
        self.dir.close();
        self.alloc.free(self.path);
        self.* = undefined;
    }

    /// Returns 1 + the highest number among `N.txt` files and `index.tsv` rows.
    /// Temp files and unrelated names are ignored (`ResultStore.tla` `NoReuse`).
    pub fn nextNumber(self: *ResultFolder) !u64 {
        const io = io_mod.getIo();
        var max_n: u64 = 0;

        var it = self.dir.dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (parseResultFileNumber(entry.name)) |n| {
                max_n = @max(max_n, n);
            }
        }

        const maybe_index = self.dir.dir.openFile(io, index_file_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (maybe_index) |index_file| {
            var file = index_file;
            defer file.close(io);
            const stat = try file.stat(io);
            if (stat.kind != .file) return error.DurablePathUnsafe;

            var read_buf: [4096]u8 = undefined;
            var reader = file.reader(io, &read_buf);
            max_n = @max(max_n, try maxNumberInIndex(&reader.interface));
        }

        return std.math.add(u64, max_n, 1);
    }

    /// Total byte size across all `N.txt` files in this folder (`S4-5`).
    pub fn folderUsageBytes(self: *ResultFolder) !u64 {
        const io = io_mod.getIo();
        var total: u64 = 0;
        var it = self.dir.dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (parseResultFileNumber(entry.name) == null) continue;
            const stat = try self.dir.dir.statFile(io, entry.name, .{ .follow_symlinks = false });
            total = try std.math.add(u64, total, @intCast(stat.size));
        }
        return total;
    }

    /// Streams `source` and atomically writes `N.txt`, enforcing the per-file
    /// and per-folder caps (`S4-5`, `S4-6`, `ResultStore.tla` `File`, `FullNoticed`).
    pub fn save(self: *ResultFolder, n: u64, source: *std.Io.Reader) !SaveOutcome {
        if (n == 0) return error.InvalidArgument;
        const used_bytes = try self.folderUsageBytes();

        const max_file = self.limits.max_file_bytes;
        const keep_head = max_file / 2;
        const keep_tail = max_file - keep_head;

        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(self.alloc);
        var tail: std.ArrayList(u8) = .empty;
        defer tail.deinit(self.alloc);

        var total_bytes: u64 = 0;
        var tail_pos: usize = 0;
        var cut = false;
        var chunk_buf: [64 * 1024]u8 = undefined;

        while (true) {
            const n_read = try source.readSliceShort(&chunk_buf);
            if (n_read == 0) break;
            total_bytes = try std.math.add(u64, total_bytes, n_read);
            var rest: []const u8 = chunk_buf[0..n_read];

            if (head.items.len < keep_head) {
                const take = @min(rest.len, keep_head - head.items.len);
                try head.appendSlice(self.alloc, rest[0..take]);
                rest = rest[take..];
            }
            if (rest.len == 0) continue;

            if (!cut and tail.items.len + rest.len <= keep_tail) {
                try tail.appendSlice(self.alloc, rest);
                continue;
            }

            if (!cut) {
                cut = true;
                const old_len = tail.items.len;
                try tail.resize(self.alloc, keep_tail);
                tail_pos = if (old_len == keep_tail) 0 else old_len;
            }
            if (rest.len >= keep_tail) {
                const start = rest.len - keep_tail;
                @memcpy(tail.items, rest[start..]);
                tail_pos = 0;
            } else {
                const first = @min(rest.len, keep_tail - tail_pos);
                @memcpy(tail.items[tail_pos .. tail_pos + first], rest[0..first]);
                if (first < rest.len) {
                    const rem = rest.len - first;
                    @memcpy(tail.items[0..rem], rest[first..]);
                    tail_pos = rem;
                } else {
                    tail_pos = (tail_pos + first) % keep_tail;
                }
            }
        }

        var name_buf: [64]u8 = undefined;
        const file_name = try std.mem.print(&name_buf, "{d}.txt", .{n});

        if (!cut) {
            const written_bytes = head.items.len + tail.items.len;
            if (try std.math.add(u64, used_bytes, written_bytes) > self.limits.max_folder_bytes) {
                return .{ .full = .{ .used_bytes = used_bytes, .needed_bytes = written_bytes } };
            }
            const slices = [_][]const u8{ head.items, tail.items };
            try writeSlicesAtomic(self.alloc, &self.dir, file_name, &slices);
            return .{ .saved = .{
                .original_bytes = total_bytes,
                .written_bytes = written_bytes,
                .cut_bytes = 0,
            } };
        }

        const kept_bytes: u64 = @as(u64, head.items.len) + @as(u64, keep_tail);
        const cut_bytes = total_bytes - kept_bytes;
        var marker_buf: [96]u8 = undefined;
        const needs_nl = head.items.len > 0 and head.items[head.items.len - 1] != '\n';
        const marker = try std.mem.print(&marker_buf, "{s}[... {d} bytes cut ...]\n", .{
            if (needs_nl) "\n" else "",
            cut_bytes,
        });
        const written_bytes = head.items.len + marker.len + keep_tail;
        if (try std.math.add(u64, used_bytes, written_bytes) > self.limits.max_folder_bytes) {
            return .{ .full = .{ .used_bytes = used_bytes, .needed_bytes = written_bytes } };
        }
        const slices = [_][]const u8{
            head.items,
            marker,
            tail.items[tail_pos..],
            tail.items[0..tail_pos],
        };
        try writeSlicesAtomic(self.alloc, &self.dir, file_name, &slices);
        return .{ .saved = .{
            .original_bytes = total_bytes,
            .written_bytes = written_bytes,
            .cut_bytes = cut_bytes,
        } };
    }

    /// Appends one row to `index.tsv`, keeping existing rows byte for byte and
    /// rewriting via a temp file and atomic rename (`ResultStore.tla` `StoreAppendOnly`).
    pub fn appendIndex(self: *ResultFolder, row: IndexRow) !void {
        const io = io_mod.getIo();
        var existing: ?[]u8 = null;
        defer if (existing) |bytes| self.alloc.free(bytes);

        const maybe_file = self.dir.dir.openFile(io, index_file_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (maybe_file) |opened| {
            var file = opened;
            defer file.close(io);
            const stat = try file.stat(io);
            if (stat.kind != .file) return error.DurablePathUnsafe;
            var read_buf: [4096]u8 = undefined;
            var reader = file.reader(io, &read_buf);
            existing = try reader.interface.allocRemaining(self.alloc, .unlimited);
        }

        var row_out: std.Io.Writer.Allocating = .init(self.alloc);
        defer row_out.deinit();
        try formatIndexRow(self.alloc, &row_out.writer, row);

        const prefix: []const u8 = if (existing) |bytes|
            if (bytes.len == 0) index_header else bytes
        else
            index_header;
        const needs_nl = prefix.len > 0 and prefix[prefix.len - 1] != '\n';
        const slices = [_][]const u8{
            prefix,
            if (needs_nl) "\n" else "",
            row_out.written(),
        };
        try writeSlicesAtomic(self.alloc, &self.dir, index_file_name, &slices);
    }

    /// Rewrites the entire `index.tsv` from `rows` via a temp file and atomic rename.
    pub fn writeIndex(self: *ResultFolder, rows: []const IndexRow) !void {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try out.writer.writeAll(index_header);
        for (rows) |row| {
            try formatIndexRow(self.alloc, &out.writer, row);
        }
        const slices = [_][]const u8{out.written()};
        try writeSlicesAtomic(self.alloc, &self.dir, index_file_name, &slices);
    }
};

/// Formats the `command` column: first line of `program`, tabs and line ends
/// replaced by spaces, truncated to at most `max_command_bytes` on a UTF-8 boundary.
/// Caller owns the returned slice.
pub fn formatCommandColumn(alloc: Allocator, program: []const u8) Allocator.Error![]u8 {
    const first_line = if (std.mem.findScalar(u8, program, '\n')) |nl|
        if (nl > 0 and program[nl - 1] == '\r') program[0 .. nl - 1] else program[0..nl]
    else
        program;
    const bounded = text_utils.utf8PrefixByBytes(first_line, max_command_bytes);
    const copy = try alloc.dupe(u8, bounded);
    for (copy) |*byte| {
        if (byte.* == '\t' or byte.* == '\r' or byte.* == '\n') byte.* = ' ';
    }
    return copy;
}

fn formatIndexRow(alloc: Allocator, w: *std.Io.Writer, row: IndexRow) !void {
    const command = try formatCommandColumn(alloc, row.command);
    defer alloc.free(command);
    try w.print("{d}\t", .{row.n});
    switch (row.exit) {
        .code => |code| try w.print("{d}", .{code}),
        .signal => |sig| try w.print("signal:{d}", .{sig}),
        .stopped => try w.writeAll("stopped"),
        .lost => try w.writeAll("lost"),
        .unknown => try w.writeAll("-"),
    }
    try w.print("\t{d}\t{d}\t{s}\n", .{ row.bytes, row.lines, command });
}

fn maxNumberInIndex(reader: *std.Io.Reader) !u64 {
    var max_n: u64 = 0;
    var at_line_start = true;
    var num_buf: [32]u8 = undefined;
    var num_len: usize = 0;
    var num_overflow = false;
    var reading_first_field = true;

    while (true) {
        var chunk: [4096]u8 = undefined;
        const n_read = try reader.readSliceShort(&chunk);
        if (n_read == 0) break;
        for (chunk[0..n_read]) |byte| {
            if (byte == '\n') {
                at_line_start = true;
                num_len = 0;
                num_overflow = false;
                reading_first_field = true;
                continue;
            }
            if (at_line_start) {
                at_line_start = false;
            }
            if (!reading_first_field) continue;
            if (byte == '\t') {
                reading_first_field = false;
                if (!num_overflow and num_len > 0) {
                    if (parseCanonicalPositive(num_buf[0..num_len])) |n| {
                        max_n = @max(max_n, n);
                    }
                }
                continue;
            }
            if (num_len < num_buf.len) {
                num_buf[num_len] = byte;
                num_len += 1;
            } else {
                num_overflow = true;
            }
        }
    }
    return max_n;
}

fn parseCanonicalPositive(text: []const u8) ?u64 {
    if (text.len == 0 or text[0] < '1' or text[0] > '9') return null;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return null;
    }
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// Parses `"<n>.txt"` where `<n>` is a canonical positive decimal integer.
fn parseResultFileNumber(name: []const u8) ?u64 {
    if (!std.mem.endsWith(u8, name, ".txt")) return null;
    return parseCanonicalPositive(name[0 .. name.len - ".txt".len]);
}

/// Writes `slices` into `target_name` inside `dir` via an exclusive private temp
/// file, `fsync`, atomic rename, and directory sync. Every error is returned; any
/// temp file left behind on failure is removed and any removal failure is logged
/// with `debug_trace`.
fn writeSlicesAtomic(
    alloc: Allocator,
    dir: *io_mod.VerifiedDir,
    target_name: []const u8,
    slices: []const []const u8,
) !void {
    const io = io_mod.getIo();
    if (target_name.len == 0 or std.mem.eql(u8, target_name, ".") or std.mem.eql(u8, target_name, "..") or
        std.mem.findAny(u8, target_name, "/\\") != null)
    {
        return error.DurablePathUnsafe;
    }

    const existing_stat = dir.dir.statFile(io, target_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        error.SymLinkLoop, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    if (existing_stat) |stat| {
        if (stat.kind != .file or stat.nlink != 1) return error.DurablePathUnsafe;
    }

    var random_bytes: [16]u8 = undefined;
    io.random(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);
    const temp_name = try alloc.print(".{s}.tmp.{s}", .{ target_name, suffix });
    defer alloc.free(temp_name);

    var file = try dir.dir.createFile(io, temp_name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = .fromMode(0o600),
        .resolve_beneath = true,
    });
    var file_open = true;
    var temp_exists = true;
    errdefer {
        if (file_open) file.close(io);
        if (temp_exists) {
            dir.dir.deleteFile(io, temp_name) catch |cleanup_err| {
                debug_trace.logf(
                    "session",
                    "event=result_files_temp_dropped target={s} temp={s} err={s}",
                    .{ target_name, temp_name, @errorName(cleanup_err) },
                );
            };
        }
    }

    for (slices) |slice| {
        if (slice.len == 0) continue;
        try file.writeStreamingAll(io, slice);
    }
    try file.sync(io);
    file.close(io);
    file_open = false;

    try dir.dir.rename(temp_name, dir.dir, target_name, io);
    temp_exists = false;
    try io_mod.syncVerifiedDir(dir.dir);
}

fn writeTestBytes(dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
    try dir.writeFile(io_mod.getIo(), .{
        .sub_path = name,
        .data = data,
        .flags = .{ .permissions = .fromMode(0o600) },
    });
}

fn readTestBytes(alloc: Allocator, dir: std.Io.Dir, name: []const u8, max_bytes: usize) ![]u8 {
    return dir.readFileAlloc(io_mod.getIo(), name, alloc, .limited(max_bytes));
}

fn expectNoTempFiles(dir: std.Io.Dir) !void {
    var it = dir.iterate();
    while (try it.next(io_mod.getIo())) |entry| {
        if (std.mem.find(u8, entry.name, ".tmp.") != null or std.mem.endsWith(u8, entry.name, ".tmp")) {
            return error.TestUnexpectedTempFile;
        }
    }
}

test "nextNumber numbers from files only, index only, and skips orphan files above index while ignoring temps" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    // Files only.
    const files_only_path = try std.Io.Dir.path.join(alloc, &.{ root, "files-only" });
    defer alloc.free(files_only_path);
    var files_only = try ResultFolder.init(alloc, files_only_path);
    defer files_only.deinit();
    try std.testing.expectEqual(@as(u64, 1), try files_only.nextNumber());
    try writeTestBytes(files_only.dir.dir, "1.txt", "a");
    try writeTestBytes(files_only.dir.dir, "5.txt", "b");
    try writeTestBytes(files_only.dir.dir, ".99.txt.tmp.abcd", "tmp");
    try writeTestBytes(files_only.dir.dir, "99.txt.tmp", "tmp");
    try writeTestBytes(files_only.dir.dir, "0.txt", "zero");
    try writeTestBytes(files_only.dir.dir, "01.txt", "leading-zero");
    try writeTestBytes(files_only.dir.dir, "notes.txt", "other");
    try std.testing.expectEqual(@as(u64, 6), try files_only.nextNumber());

    // Index only.
    const index_only_path = try std.Io.Dir.path.join(alloc, &.{ root, "index-only" });
    defer alloc.free(index_only_path);
    var index_only = try ResultFolder.init(alloc, index_only_path);
    defer index_only.deinit();
    try writeTestBytes(index_only.dir.dir, index_file_name, index_header ++ "1\t0\t1\t1\techo 1\n3\t0\t1\t1\techo 3\n");
    try std.testing.expectEqual(@as(u64, 4), try index_only.nextNumber());

    // Both, with an orphan file above the index (`ResultStore.tla` NoReuse).
    const both_path = try std.Io.Dir.path.join(alloc, &.{ root, "both-orphan" });
    defer alloc.free(both_path);
    var both = try ResultFolder.init(alloc, both_path);
    defer both.deinit();
    try writeTestBytes(both.dir.dir, index_file_name, index_header ++ "1\t0\t1\t1\techo 1\n2\t0\t1\t1\techo 2\n");
    try writeTestBytes(both.dir.dir, "1.txt", "one");
    try writeTestBytes(both.dir.dir, "2.txt", "two");
    try writeTestBytes(both.dir.dir, "3.txt", "orphan-crash-before-index");
    try std.testing.expectEqual(@as(u64, 4), try both.nextNumber());
}

test "save writes atomically with no temp file left behind and respects folder permissions" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const out_path = try std.Io.Dir.path.join(alloc, &.{ root, "out" });
    defer alloc.free(out_path);

    var folder = try ResultFolder.init(alloc, out_path);
    defer folder.deinit();

    const stat = try folder.dir.dir.stat(io_mod.getIo());
    try std.testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));

    var reader: std.Io.Reader = .fixed("hello world\n");
    const outcome = try folder.save(1, &reader);
    switch (outcome) {
        .saved => |s| {
            try std.testing.expectEqual(@as(u64, 12), s.original_bytes);
            try std.testing.expectEqual(@as(usize, 12), s.written_bytes);
            try std.testing.expectEqual(@as(u64, 0), s.cut_bytes);
        },
        .full => return error.TestUnexpectedFull,
    }
    try expectNoTempFiles(folder.dir.dir);
    const got = try readTestBytes(alloc, folder.dir.dir, "1.txt", 1024);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("hello world\n", got);
}

test "save enforces the 16 MiB per-file cap with exact first and last 8 MiB and one cut line" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const out_path = try std.Io.Dir.path.join(alloc, &.{ root, "file-cap" });
    defer alloc.free(out_path);

    var folder = try ResultFolder.init(alloc, out_path);
    defer folder.deinit();

    const extra: usize = 512 * 1024;
    const total: usize = max_file_bytes + extra;
    const big = try alloc.alloc(u8, total);
    defer alloc.free(big);
    @memset(big[0..cut_keep_bytes], 'H');
    @memset(big[cut_keep_bytes .. cut_keep_bytes + extra], 'M');
    @memset(big[cut_keep_bytes + extra ..], 'T');

    var reader: std.Io.Reader = .fixed(big);
    const outcome = try folder.save(1, &reader);
    const saved = switch (outcome) {
        .saved => |s| s,
        .full => return error.TestUnexpectedFull,
    };
    try std.testing.expectEqual(@as(u64, total), saved.original_bytes);
    try std.testing.expectEqual(@as(u64, extra), saved.cut_bytes);
    try expectNoTempFiles(folder.dir.dir);

    const written = try readTestBytes(alloc, folder.dir.dir, "1.txt", max_file_bytes + 4096);
    defer alloc.free(written);
    try std.testing.expectEqual(saved.written_bytes, written.len);
    try std.testing.expectEqualSlices(u8, big[0..cut_keep_bytes], written[0..cut_keep_bytes]);
    try std.testing.expectEqualSlices(u8, big[total - cut_keep_bytes ..], written[written.len - cut_keep_bytes ..]);
    const middle = written[cut_keep_bytes .. written.len - cut_keep_bytes];
    try std.testing.expect(std.mem.find(u8, middle, "524288 bytes cut") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, middle, "\n") - 1);
}

test "save enforces the per-folder cap and writes nothing when full" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const out_path = try std.Io.Dir.path.join(alloc, &.{ root, "folder-cap" });
    defer alloc.free(out_path);

    // Check default constant values and test exact boundary behavior with bounded test limits.
    try std.testing.expectEqual(@as(u64, 256 * 1024 * 1024), max_folder_bytes);
    var folder = try ResultFolder.initWithLimits(alloc, out_path, .{
        .max_file_bytes = 64,
        .max_folder_bytes = 100,
    });
    defer folder.deinit();

    // Non-result files (such as index.tsv) do not count toward the N.txt folder cap.
    try writeTestBytes(folder.dir.dir, index_file_name, "n\texit\tbytes\tlines\tcommand\n" ++ text_utils.repeat("x", 200) ++ "\n");

    var r1: std.Io.Reader = .fixed(text_utils.repeat("a", 60));
    try std.testing.expect((try folder.save(1, &r1)) == .saved);

    // 60 + 41 = 101 > 100 -> full, writes nothing.
    var r2_over: std.Io.Reader = .fixed(text_utils.repeat("b", 41));
    const full_outcome = try folder.save(2, &r2_over);
    switch (full_outcome) {
        .full => |f| {
            try std.testing.expectEqual(@as(u64, 60), f.used_bytes);
            try std.testing.expectEqual(@as(usize, 41), f.needed_bytes);
        },
        .saved => return error.TestExpectedFull,
    }
    try std.testing.expectError(error.FileNotFound, folder.dir.dir.access(io_mod.getIo(), "2.txt", .{}));
    try expectNoTempFiles(folder.dir.dir);

    // 60 + 40 = 100 <= 100 -> exact boundary succeeds.
    var r2_exact: std.Io.Reader = .fixed(text_utils.repeat("b", 40));
    try std.testing.expect((try folder.save(2, &r2_exact)) == .saved);
}

test "appendIndex and writeIndex rewrite atomically and appendIndex preserves earlier rows byte for byte" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const out_path = try std.Io.Dir.path.join(alloc, &.{ root, "idx" });
    defer alloc.free(out_path);

    var folder = try ResultFolder.init(alloc, out_path);
    defer folder.deinit();

    try folder.appendIndex(.{ .n = 1, .exit = .{ .code = 0 }, .bytes = 12, .lines = 1, .command = "echo hi\necho bye" });
    const after_first = try readTestBytes(alloc, folder.dir.dir, index_file_name, 4096);
    defer alloc.free(after_first);
    try std.testing.expectEqualStrings("n\texit\tbytes\tlines\tcommand\n1\t0\t12\t1\techo hi\n", after_first);
    try expectNoTempFiles(folder.dir.dir);

    try folder.appendIndex(.{ .n = 2, .exit = .{ .signal = 9 }, .bytes = 0, .lines = 0, .command = "sleep\t30" });
    const after_second = try readTestBytes(alloc, folder.dir.dir, index_file_name, 4096);
    defer alloc.free(after_second);
    try std.testing.expect(std.mem.startsWith(u8, after_second, after_first));
    try std.testing.expectEqualStrings(
        "n\texit\tbytes\tlines\tcommand\n1\t0\t12\t1\techo hi\n2\tsignal:9\t0\t0\tsleep 30\n",
        after_second,
    );
    try expectNoTempFiles(folder.dir.dir);

    try folder.writeIndex(&.{
        .{ .n = 1, .exit = .{ .code = 2 }, .bytes = 5, .lines = 1, .command = "false" },
    });
    const after_write = try readTestBytes(alloc, folder.dir.dir, index_file_name, 4096);
    defer alloc.free(after_write);
    try std.testing.expectEqualStrings("n\texit\tbytes\tlines\tcommand\n1\t2\t5\t1\tfalse\n", after_write);
    try expectNoTempFiles(folder.dir.dir);
}

test "formatCommandColumn takes first line, maps tabs and line ends to spaces, and cuts at 200 bytes on a UTF-8 boundary" {
    const alloc = std.testing.allocator;

    const multi = try formatCommandColumn(alloc, "echo\t'a'\r\recho 'b'\necho 'c'");
    defer alloc.free(multi);
    try std.testing.expectEqualStrings("echo 'a'  echo 'b'", multi);

    const crlf = try formatCommandColumn(alloc, "ls -la\r\npwd");
    defer alloc.free(crlf);
    try std.testing.expectEqualStrings("ls -la", crlf);

    // 199 ASCII bytes + 2-byte UTF-8 character 'é' (0xC3 0xA9) = 201 bytes -> cut to 199.
    const long = text_utils.repeat("a", 199) ++ "é" ++ "tail";
    const cut = try formatCommandColumn(alloc, long);
    defer alloc.free(cut);
    try std.testing.expectEqual(@as(usize, 199), cut.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
    try std.testing.expectEqualStrings(text_utils.repeat("a", 199), cut);
}

test "failed write cleans up its temp file and returns the underlying error" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const out_path = try std.Io.Dir.path.join(alloc, &.{ root, "fail-target" });
    defer alloc.free(out_path);

    var folder = try ResultFolder.init(alloc, out_path);
    defer folder.deinit();

    // Replacing 1.txt with a symlink refuses the replace and cleans up the temp file.
    try folder.dir.dir.symLink(io_mod.getIo(), "/etc/hosts", "1.txt", .{});
    var reader: std.Io.Reader = .fixed("blocked\n");
    try std.testing.expectError(error.DurablePathUnsafe, folder.save(1, &reader));
    try expectNoTempFiles(folder.dir.dir);
}
