const std = @import("std");
const domain = @import("../subagent/domain.zig");

const Allocator = std.mem.Allocator;

pub const header_magic = "FXRELH01";
pub const page_magic = "FXRELP01";
const legacy_schema_version: u32 = 1;
const epoch_schema_version: u32 = 2;
const header_schema_version: u32 = 3;

pub const page_slots: usize = 64;
pub const no_slot: u64 = std.math.maxInt(u64);
pub const max_header_bytes: usize = 1024;
pub const max_page_bytes: usize = 32 * 1024;

pub const Error = Allocator.Error || error{InvalidIndex};

pub const PendingKind = enum(u8) {
    none = 0,
    allocate = 1,
    free = 2,
};

pub const Header = struct {
    storage_epoch: u64 = 0,
    generation: u64 = 0,
    high_watermark: u64 = 0,
    active_count: u64 = 0,
    active_count_known: bool = true,
    free_head: u64 = no_slot,
    delivery_offset: u64 = 0,
    migration_inode: u64 = 0,
    migration_size: u64 = 0,
    migration_mtime_ns: i128 = 0,
    migration_offset: u64 = 0,
    pending_kind: PendingKind = .none,
    pending_slot: u64 = no_slot,
    pending_next_free: u64 = no_slot,
    pending_child_len: u16 = 0,
    pending_child: [255]u8 = @splat(0),

    pub fn pendingChild(self: *const Header) []const u8 {
        return self.pending_child[0..self.pending_child_len];
    }

    pub fn setPendingChild(self: *Header, child_id: []const u8) void {
        std.debug.assert(child_id.len <= self.pending_child.len);
        self.pending_child_len = @intCast(child_id.len);
        @memcpy(self.pending_child[0..child_id.len], child_id);
    }

    pub fn clearPending(self: *Header) void {
        self.pending_kind = .none;
        self.pending_slot = no_slot;
        self.pending_next_free = no_slot;
        self.pending_child_len = 0;
    }
};

pub const Slot = struct {
    occupied: bool = false,
    next_free: u64 = no_slot,
    child_len: u16 = 0,
    child: [255]u8 = @splat(0),

    pub fn childId(self: *const Slot) []const u8 {
        return self.child[0..self.child_len];
    }

    pub fn setOccupied(self: *Slot, child_id: []const u8) void {
        std.debug.assert(child_id.len <= self.child.len);
        self.occupied = true;
        self.next_free = no_slot;
        self.child_len = @intCast(child_id.len);
        @memcpy(self.child[0..child_id.len], child_id);
    }

    pub fn setFree(self: *Slot, next_free: u64) void {
        self.occupied = false;
        self.next_free = next_free;
        self.child_len = 0;
    }
};

pub const PageData = struct {
    number: u64,
    storage_epoch: u64,
    slots: [page_slots]Slot = @splat(.{}),

    // Field-wise init; a partial `.{}` literal materializes a page-sized
    // (~17KB) const template at every call site.
    pub fn init(number: u64, storage_epoch: u64) PageData {
        var page: PageData = undefined;
        page.number = number;
        page.storage_epoch = storage_epoch;
        for (&page.slots) |*slot| slot.* = .{};
        return page;
    }
};

pub fn encodeHeader(alloc: Allocator, header: Header) Allocator.Error![]u8 {
    std.debug.assert(header.active_count_known);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll(header_magic) catch return error.OutOfMemory;
    writeInt(&out.writer, u32, header_schema_version) catch return error.OutOfMemory;
    writeInt(&out.writer, u64, header.storage_epoch) catch return error.OutOfMemory;
    writeInt(&out.writer, u64, header.generation) catch return error.OutOfMemory;
    writeInt(&out.writer, u64, header.high_watermark) catch return error.OutOfMemory;
    writeInt(&out.writer, u64, header.active_count) catch return error.OutOfMemory;
    writeInt(&out.writer, u64, header.free_head) catch return error.OutOfMemory;
    writeInt(&out.writer, u64, header.delivery_offset) catch return error.OutOfMemory;
    writeInt(&out.writer, u64, header.migration_inode) catch return error.OutOfMemory;
    writeInt(&out.writer, u64, header.migration_size) catch return error.OutOfMemory;
    writeInt(&out.writer, i128, header.migration_mtime_ns) catch return error.OutOfMemory;
    writeInt(&out.writer, u64, header.migration_offset) catch return error.OutOfMemory;
    out.writer.writeByte(@backingInt(header.pending_kind)) catch return error.OutOfMemory;
    writeInt(&out.writer, u64, header.pending_slot) catch return error.OutOfMemory;
    writeInt(&out.writer, u64, header.pending_next_free) catch return error.OutOfMemory;
    writeInt(&out.writer, u16, header.pending_child_len) catch return error.OutOfMemory;
    out.writer.writeAll(header.pendingChild()) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

pub fn decodeHeader(bytes: []const u8) Error!Header {
    var cursor = ByteCursor{ .bytes = bytes };
    if (!std.mem.eql(u8, try cursor.take(header_magic.len), header_magic)) {
        return error.InvalidIndex;
    }
    const version = try cursor.readInt(u32);
    if (version != legacy_schema_version and
        version != epoch_schema_version and
        version != header_schema_version)
    {
        return error.InvalidIndex;
    }
    const storage_epoch = if (version >= epoch_schema_version)
        try cursor.readInt(u64)
    else
        0;
    const generation = try cursor.readInt(u64);
    const high_watermark = try cursor.readInt(u64);
    const active_count = if (version == header_schema_version)
        try cursor.readInt(u64)
    else
        0;
    var header = Header{
        .storage_epoch = storage_epoch,
        .generation = generation,
        .high_watermark = high_watermark,
        .active_count = active_count,
        .active_count_known = version == header_schema_version,
        .free_head = try cursor.readInt(u64),
        .delivery_offset = try cursor.readInt(u64),
        .migration_inode = try cursor.readInt(u64),
        .migration_size = try cursor.readInt(u64),
        .migration_mtime_ns = try cursor.readInt(i128),
        .migration_offset = try cursor.readInt(u64),
    };
    header.pending_kind = switch (try cursor.readByte()) {
        0 => .none,
        1 => .allocate,
        2 => .free,
        else => return error.InvalidIndex,
    };
    header.pending_slot = try cursor.readInt(u64);
    header.pending_next_free = try cursor.readInt(u64);
    const child_len = try cursor.readInt(u16);
    if (child_len > header.pending_child.len) return error.InvalidIndex;
    const child = try cursor.take(child_len);
    header.setPendingChild(child);
    if (!cursor.done()) return error.InvalidIndex;
    if (header.active_count_known and header.active_count > header.high_watermark) {
        return error.InvalidIndex;
    }
    if (header.delivery_offset > header.high_watermark) return error.InvalidIndex;
    if (header.migration_offset > header.migration_size) return error.InvalidIndex;
    if (header.pending_kind == .none) {
        if (header.pending_slot != no_slot or
            header.pending_next_free != no_slot or
            header.pending_child_len != 0)
        {
            return error.InvalidIndex;
        }
    } else {
        domain.validateId(header.pendingChild()) catch return error.InvalidIndex;
        if (header.pending_slot == no_slot) return error.InvalidIndex;
    }
    return header;
}

pub fn decodePage(
    bytes: []const u8,
    expected_number: u64,
    expected_storage_epoch: u64,
) Error!PageData {
    var page: PageData = undefined;
    try decodePageInto(&page, bytes, expected_number, expected_storage_epoch);
    return page;
}

// noinline keeps the comptime-known error returns behind a call boundary;
// inlined into an `Error!PageData` result location they each materialize a
// page-sized error-union constant.
pub noinline fn decodePageInto(
    page: *PageData,
    bytes: []const u8,
    expected_number: u64,
    expected_storage_epoch: u64,
) Error!void {
    var cursor = ByteCursor{ .bytes = bytes };
    if (!std.mem.eql(u8, try cursor.take(page_magic.len), page_magic)) {
        return error.InvalidIndex;
    }
    const version = try cursor.readInt(u32);
    if (version != legacy_schema_version and version != epoch_schema_version) {
        return error.InvalidIndex;
    }
    const number = try cursor.readInt(u64);
    if (number != expected_number) return error.InvalidIndex;
    const storage_epoch = if (version == epoch_schema_version)
        try cursor.readInt(u64)
    else
        0;
    if (storage_epoch != expected_storage_epoch) return error.InvalidIndex;
    page.number = number;
    page.storage_epoch = storage_epoch;
    for (&page.slots) |*slot| {
        slot.* = .{};
        const occupied = switch (try cursor.readByte()) {
            0 => false,
            1 => true,
            else => return error.InvalidIndex,
        };
        const next_free = try cursor.readInt(u64);
        const child_len = try cursor.readInt(u16);
        if (child_len > slot.child.len) return error.InvalidIndex;
        const child_id = try cursor.take(child_len);
        if (occupied) {
            domain.validateId(child_id) catch return error.InvalidIndex;
            if (next_free != no_slot) return error.InvalidIndex;
            slot.setOccupied(child_id);
        } else {
            if (child_len != 0) return error.InvalidIndex;
            slot.setFree(next_free);
        }
    }
    if (!cursor.done()) return error.InvalidIndex;
}

pub fn pageFileName(number: u64) [38]u8 {
    const prefix = "relationship-page-";
    const suffix = ".bin";
    var number_bytes: [@sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, &number_bytes, number, .big);
    const hex = std.fmt.bytesToHex(number_bytes, .lower);
    var buffer: [prefix.len + hex.len + suffix.len]u8 = undefined;
    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len .. prefix.len + hex.len], &hex);
    @memcpy(buffer[prefix.len + hex.len ..], suffix);
    return buffer;
}

const ByteCursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(self: *ByteCursor, len: usize) Error![]const u8 {
        const end = std.math.add(usize, self.offset, len) catch
            return error.InvalidIndex;
        if (end > self.bytes.len) return error.InvalidIndex;
        const result = self.bytes[self.offset..end];
        self.offset = end;
        return result;
    }

    fn readByte(self: *ByteCursor) Error!u8 {
        return (try self.take(1))[0];
    }

    fn readInt(self: *ByteCursor, comptime T: type) Error!T {
        const raw = try self.take(@sizeOf(T));
        return std.mem.readInt(T, raw[0..@sizeOf(T)], .little);
    }

    fn done(self: ByteCursor) bool {
        return self.offset == self.bytes.len;
    }
};

fn writeInt(writer: *std.Io.Writer, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

test "relationship index header preserves active occupancy and reads legacy counts as unknown" {
    const alloc = std.testing.allocator;
    const bytes = try encodeHeader(alloc, .{
        .storage_epoch = 7,
        .generation = 9,
        .high_watermark = 4,
        .active_count = 2,
    });
    defer alloc.free(bytes);
    const decoded = try decodeHeader(bytes);
    try std.testing.expect(decoded.active_count_known);
    try std.testing.expectEqual(@as(u64, 2), decoded.active_count);
}
