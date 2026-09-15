// Versioned on-disk contract shared by builder and freestanding stub.
pub const page_size = 16384;
pub const magic = 0x3252454741505846; // FXPAGER2
pub const max_pages = 4096;
pub const Config = extern struct {
    magic: u64,
    self_addr: u64,
    state_addr: u64,
    state_len: u64,
    template_addr: u64,
    reloc_addr: u64,
    reloc_count: u64,
    text_addr: u64,
    page_count: u64,
    table_addr: u64,
    blob_addr: u64,
    blob_len: u64,
    entry_addr: u64,
    sigaction_addr: u64,
    eager: u64,
    readonly_len: u64,
};
pub const Frame = extern struct { off: u32, len: u32, checksum: u64 };

// Integrity check for decoded bytes before execute permission is installed.
// Authentication is provided by the Mach-O signature, not this checksum.
pub fn page_hash(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| hash = (hash ^ byte) *% 0x100000001b3;
    return hash;
}
test "pager contract layout" {
    const std = @import("std");
    try std.testing.expectEqual(128, @sizeOf(Config));
    try std.testing.expectEqual(16, @sizeOf(Frame));
}

test "page integrity detects changed bytes" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u64, 0xcbf29ce484222325), page_hash(""));
    try std.testing.expect(page_hash("pager") != page_hash("Pager"));
}
