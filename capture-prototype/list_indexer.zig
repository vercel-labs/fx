//! Prints every file fx's native indexer lists under one root, NUL-separated.
//! Throwaway prototype tool for capture-prototype/run.sh; not part of fx.
const std = @import("std");
const io_mod = @import("core/shared/io.zig");
const indexer = @import("core/indexer/indexer.zig");

pub fn main(init: std.process.Init) !void {
    io_mod.setIo(init.io);
    io_mod.setEnvironMap(init.environ_map);
    const alloc = std.heap.smp_allocator;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer args.deinit();
    _ = args.skip();
    const root = args.next() orelse return error.MissingRoot;
    var result = try indexer.scan(alloc, root, .{ .candidate_cap = 1_000_000 }, null);
    defer result.deinit();
    if (result.tree.incomplete) return error.IncompleteListing;
    var buf: [64 * 1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    for (result.tree.entries) |entry| {
        if (entry.kind != .file) continue;
        try out.interface.writeAll(entry.path);
        try out.interface.writeByte(0);
    }
    try out.interface.flush();
}
