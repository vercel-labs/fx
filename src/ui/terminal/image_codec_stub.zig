const std = @import("std");

pub const Dimensions = struct {
    width: u32,
    height: u32,
};

pub const Bounds = struct {
    width: u32,
    height: u32,
};

pub fn convertToPng(
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: Dimensions,
    _: Bounds,
) anyerror![]u8 {
    return error.UnsupportedMediaType;
}
