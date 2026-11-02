//! Binary payloads that cross a libfx host boundary beside JSON-RPC frames.
//!
//! Prompt images and kernel checkpoints travel as raw bytes through this
//! store, so the model request is the only place their bytes are base64
//! encoded. Hosts choose inbound ids and reference them from the frame that
//! consumes them; the store chooses outbound ids for the host to take.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Id = u32;

pub const TakeError = Allocator.Error || error{ AttachmentUnavailable, AttachmentTooLarge };
pub const PutError = Allocator.Error || error{AttachmentStoreFull};

pub const Store = struct {
    context: ?*anyopaque = null,
    take_fn: *const fn (?*anyopaque, Allocator, Id, usize) TakeError![]u8,
    put_fn: *const fn (?*anyopaque, []const u8) PutError!Id,

    /// Removes inbound payload `id` and returns an allocator-owned copy. A
    /// payload over `max_bytes` fails with `AttachmentTooLarge`; hosts drop
    /// any payload left behind before they attach new ones.
    pub fn take(self: Store, alloc: Allocator, id: Id, max_bytes: usize) TakeError![]u8 {
        return self.take_fn(self.context, alloc, id, max_bytes);
    }

    /// Copies `bytes` into the outbound table and returns the id the host
    /// uses to take them. The caller keeps ownership of `bytes`.
    pub fn put(self: Store, bytes: []const u8) PutError!Id {
        return self.put_fn(self.context, bytes);
    }
};

/// Parses a JSON attachment reference. Returns null for anything that is not
/// an id in the store's range, including zero, which hosts never assign.
pub fn idFromJson(value: std.json.Value) ?Id {
    if (value != .integer) return null;
    const id = std.math.cast(Id, value.integer) orelse return null;
    return if (id == 0) null else id;
}

test "idFromJson accepts only positive u32 integers" {
    try std.testing.expectEqual(@as(?Id, 7), idFromJson(.{ .integer = 7 }));
    try std.testing.expectEqual(@as(?Id, std.math.maxInt(Id)), idFromJson(.{ .integer = std.math.maxInt(Id) }));
    try std.testing.expectEqual(@as(?Id, null), idFromJson(.{ .integer = 0 }));
    try std.testing.expectEqual(@as(?Id, null), idFromJson(.{ .integer = -1 }));
    try std.testing.expectEqual(@as(?Id, null), idFromJson(.{ .integer = @as(i64, std.math.maxInt(Id)) + 1 }));
    try std.testing.expectEqual(@as(?Id, null), idFromJson(.{ .string = "1" }));
}
