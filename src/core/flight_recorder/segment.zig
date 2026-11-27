//! OS-backed segment file: O_EXCL creation with mode 0600, real block
//! preallocation before mapping, MAP_SHARED mmap, msync + fsync, seal
//! (.open -> .seg rename + unmap), and unlink.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const format = @import("format.zig");

comptime {
    std.debug.assert(builtin.target.cpu.arch.endian() == .little);
}

pub const name_buf_bytes: usize = 64;

// macOS <sys/fcntl.h>: F_PREALLOCATE = 42 (`std.c.F.PREALLOCATE`),
// F_ALLOCATEALL = 4, F_PEOFPOSMODE = 3, struct fstore.
const f_allocateall: u32 = 4;
const f_peofposmode: c_int = 3;
const fstore_t = extern struct {
    fst_flags: u32,
    fst_posmode: c_int,
    fst_offset: std.c.off_t,
    fst_length: std.c.off_t,
    fst_bytesalloc: std.c.off_t,
};

pub const ParsedName = struct {
    instance: u64,
    index: u64,
};

pub fn openFileName(buf: *[name_buf_bytes]u8, instance: u64, index: u64) []const u8 {
    return std.mem.print(buf, "{x:0>16}-{d:0>8}.open", .{ instance, index }) catch unreachable;
}

pub fn sealedFileName(buf: *[name_buf_bytes]u8, instance: u64, index: u64) []const u8 {
    return std.mem.print(buf, "{x:0>16}-{d:0>8}.seg", .{ instance, index }) catch unreachable;
}

pub fn gapFileName(buf: *[name_buf_bytes]u8, instance: u64, index: u64) []const u8 {
    return std.mem.print(buf, "gap-{x:0>16}-{d:0>8}.json", .{ instance, index }) catch unreachable;
}

pub fn parseSealedName(name: []const u8) ?ParsedName {
    const suffix = ".seg";
    if (!std.mem.endsWith(u8, name, suffix)) return null;
    const stem = name[0 .. name.len - suffix.len];
    const dash = std.mem.findScalar(u8, stem, '-') orelse return null;
    if (dash != 16) return null;
    const instance = std.fmt.parseInt(u64, stem[0..dash], 16) catch return null;
    const index_str = stem[dash + 1 ..];
    if (index_str.len == 0) return null;
    const index = std.fmt.parseInt(u64, index_str, 10) catch return null;
    return .{ .instance = instance, .index = index };
}

pub const CreateError = std.Io.File.OpenError || std.Io.File.SetLengthError || std.posix.MMapError || std.mem.Allocator.Error || error{
    CapacityTooSmall,
    NoSpaceLeft,
    OperationUnsupported,
    PreallocateFailed,
    FileTooBig,
};

pub const SyncError = std.posix.MSyncError || std.Io.File.SyncError;
pub const SealError = SyncError || std.Io.Dir.RenameError;

pub const Segment = struct {
    dir: std.Io.Dir,
    io: std.Io,
    file: std.Io.File,
    memory: []align(std.heap.page_size_min) u8,
    instance: u64,
    index: u64,
    capacity: usize,
    in_flight: std.atomic.Value(u32),

    /// Creates, preallocates, maps, and writes the 64-byte header of a new
    /// `.open` segment file. On any error, no mapping and no file remain.
    pub fn create(
        gpa: std.mem.Allocator,
        dir: std.Io.Dir,
        io: std.Io,
        instance: u64,
        index: u64,
        capacity: usize,
        wall_ms: u64,
        fail_prealloc_for_test: bool,
    ) CreateError!*Segment {
        if (capacity < format.segment_header_bytes) return error.CapacityTooSmall;

        var name_buf: [name_buf_bytes]u8 = undefined;
        const open_name = openFileName(&name_buf, instance, index);

        var file = try dir.createFile(io, open_name, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        // A leftover .open file is harmless: readers treat it as unfinished, and no instance reuses its name.
        errdefer dir.deleteFile(io, open_name) catch {};
        errdefer file.close(io);

        try preallocate(file, io, capacity, fail_prealloc_for_test);

        const memory = try std.posix.mmap(
            null,
            capacity,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
        errdefer std.posix.munmap(memory);

        memory[0..format.segment_header_bytes].* = format.encodeSegmentHeader(.{
            .format_version = format.format_version,
            .header_bytes = format.segment_header_bytes,
            .instance = instance,
            .index = index,
            .created_wall_ms = wall_ms,
            .capacity = capacity,
            .cursor = .{ .offset = format.segment_header_bytes, .count = 0 },
            .overflowed = 0,
            .dropped = 0,
        });

        const seg = try gpa.create(Segment);
        seg.* = .{
            .dir = dir,
            .io = io,
            .file = file,
            .memory = memory,
            .instance = instance,
            .index = index,
            .capacity = capacity,
            .in_flight = .init(0),
        };
        return seg;
    }

    pub fn cursorPtr(self: *Segment) *std.atomic.Value(u64) {
        return @ptrCast(@alignCast(self.memory.ptr + format.segment_cursor_at));
    }

    pub fn overflowedPtr(self: *Segment) *std.atomic.Value(u64) {
        return @ptrCast(@alignCast(self.memory.ptr + format.segment_overflowed_at));
    }

    pub fn droppedPtr(self: *Segment) *std.atomic.Value(u64) {
        return @ptrCast(@alignCast(self.memory.ptr + format.segment_dropped_at));
    }

    pub fn canSeal(self: *const Segment) bool {
        return self.in_flight.load(.acquire) == 0;
    }

    pub fn sync(self: *Segment, written_bytes: usize) SyncError!void {
        const len = @min(written_bytes, self.capacity);
        if (len > 0) {
            try std.posix.msync(self.memory[0..len], std.posix.MSF.SYNC);
        }
        try self.file.sync(self.io);
    }

    /// Syncs the mapped file, renames `.open` to `.seg`, unmaps, closes, and frees `self`.
    pub fn seal(self: *Segment, gpa: std.mem.Allocator) SealError!void {
        const cursor = format.unpackCursor(self.cursorPtr().load(.acquire));
        const written = @min(cursor.offset, self.capacity);
        try self.sync(written);

        var open_buf: [name_buf_bytes]u8 = undefined;
        var sealed_buf: [name_buf_bytes]u8 = undefined;
        const open_name = openFileName(&open_buf, self.instance, self.index);
        const sealed_name = sealedFileName(&sealed_buf, self.instance, self.index);
        try self.dir.rename(open_name, self.dir, sealed_name, self.io);

        self.closeAndUnmap(gpa);
    }

    /// Unmaps, closes, removes the `.open` file, and frees `self`.
    pub fn discardUnsealed(self: *Segment, gpa: std.mem.Allocator) void {
        var open_buf: [name_buf_bytes]u8 = undefined;
        const open_name = openFileName(&open_buf, self.instance, self.index);
        const dir = self.dir;
        const io = self.io;
        self.closeAndUnmap(gpa);
        // A leftover .open file is harmless: readers treat it as unfinished, and no instance reuses its name.
        dir.deleteFile(io, open_name) catch {};
    }

    pub fn closeAndUnmap(self: *Segment, gpa: std.mem.Allocator) void {
        std.posix.munmap(self.memory);
        self.file.close(self.io);
        gpa.destroy(self);
    }
};

pub fn unlink(dir: std.Io.Dir, io: std.Io, name: []const u8) std.Io.Dir.DeleteFileError!void {
    try dir.deleteFile(io, name);
}

fn preallocate(file: std.Io.File, io: std.Io, capacity: usize, fail_for_test: bool) CreateError!void {
    if (fail_for_test) return error.NoSpaceLeft;
    switch (builtin.target.os.tag) {
        .linux => {
            const len = std.math.cast(std.os.linux.off_t, capacity) orelse return error.FileTooBig;
            while (true) {
                const rc = std.os.linux.fallocate(file.handle, 0, 0, len);
                switch (std.os.linux.errno(rc)) {
                    .SUCCESS => break,
                    .INTR => continue,
                    .NOSPC => return error.NoSpaceLeft,
                    .OPNOTSUPP => return error.OperationUnsupported,
                    else => return error.PreallocateFailed,
                }
            }
        },
        .macos => {
            const len = std.math.cast(std.c.off_t, capacity) orelse return error.FileTooBig;
            var fstore: fstore_t = .{
                .fst_flags = f_allocateall,
                .fst_posmode = f_peofposmode,
                .fst_offset = 0,
                .fst_length = len,
                .fst_bytesalloc = 0,
            };
            while (true) {
                const rc = std.c.fcntl(file.handle, std.c.F.PREALLOCATE, &fstore);
                if (rc != -1) break;
                switch (std.c.errno(rc)) {
                    .INTR => continue,
                    .NOSPC => return error.NoSpaceLeft,
                    .OPNOTSUPP, .NOTTY => return error.OperationUnsupported,
                    else => return error.PreallocateFailed,
                }
            }
            try file.setLength(io, capacity);
        },
        else => {
            try file.setLength(io, capacity);
        },
    }
}

test "create preallocates, maps, seals, and unlinks a segment file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const seg = try Segment.create(testing.allocator, tmp.dir, testing.io, 0xABCD, 3, 4096, 12345, false);
    const stat = try tmp.dir.statFile(testing.io, "000000000000abcd-00000003.open", .{});
    try testing.expectEqual(@as(u64, 4096), stat.size);
    try testing.expectEqual(@as(u64, 0o600), stat.permissions.toMode() & 0o777);

    const header = try format.decodeSegmentHeader(seg.memory);
    try testing.expectEqual(@as(u64, 0xABCD), header.instance);
    try testing.expectEqual(@as(u64, 3), header.index);
    try testing.expectEqual(@as(u64, 64), header.cursor.offset);

    try seg.seal(testing.allocator);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "000000000000abcd-00000003.open", .{}));
    const sealed_stat = try tmp.dir.statFile(testing.io, "000000000000abcd-00000003.seg", .{});
    try testing.expectEqual(@as(u64, 4096), sealed_stat.size);

    try unlink(tmp.dir, testing.io, "000000000000abcd-00000003.seg");
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "000000000000abcd-00000003.seg", .{}));
}

test "preallocation failure returns an error and leaves no file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try testing.expectError(
        error.NoSpaceLeft,
        Segment.create(testing.allocator, tmp.dir, testing.io, 0x1, 0, 4096, 0, true),
    );
    var it = tmp.dir.iterate();
    try testing.expect((try it.next(testing.io)) == null);
}
