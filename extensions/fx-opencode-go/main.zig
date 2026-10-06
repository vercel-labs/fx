//! Native packaging composes transport without adding a runtime or dependency to fx Core.
const std = @import("std");
const runtime = @import("runtime.zig");

/// Explicit allocator and I/O ownership remain inside this executable.
pub fn main(init: std.process.Init) !void {
    try runtime.serve(std.heap.c_allocator, init.io);
}
