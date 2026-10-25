//! The footer's path to the focused node of a session tree, such as
//! `root › reviewer › tests`. When it is wider than its room, the nodes
//! nearest the root give way first, so the focused node stays readable.
const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");

pub const separator = " › ";
const elided = "…";

/// `path` (labels joined by `separator`) fitted to `width` cells in `out`.
/// Drops leading labels behind an ellipsis, then clips the focused label.
pub fn fit(path: []const u8, width: usize, out: []u8) []const u8 {
    if (width == 0 or path.len == 0) return "";
    var start: usize = 0;
    while (true) {
        const rest = path[start..];
        const marker: []const u8 = if (start > 0) elided ++ separator else "";
        if (display_width.visibleWidth(marker) + display_width.visibleWidth(rest) <= width) {
            return join(out, marker, rest);
        }
        const next = std.mem.find(u8, rest, separator) orelse break;
        start += next + separator.len;
    }
    // Only the focused label is left and it is still too wide.
    const last = path[start..];
    const kept = display_width.prefixByWidth(last, width -| 1);
    return join(out, kept, if (kept.len < last.len) elided else "");
}

fn join(out: []u8, first: []const u8, second: []const u8) []const u8 {
    const total = @min(first.len + second.len, out.len);
    const head = @min(first.len, total);
    @memcpy(out[0..head], first[0..head]);
    @memcpy(out[head..total], second[0 .. total - head]);
    return out[0..total];
}

test "a breadcrumb drops the labels nearest the root before the focused one" {
    var buf: [128]u8 = undefined;
    const path = "root › reviewer › tests";
    try std.testing.expectEqualStrings(path, fit(path, 40, &buf));
    try std.testing.expectEqualStrings("… › reviewer › tests", fit(path, 20, &buf));
    try std.testing.expectEqualStrings("… › tests", fit(path, 12, &buf));
    try std.testing.expectEqualStrings("tes…", fit(path, 4, &buf));
    try std.testing.expectEqualStrings("", fit(path, 0, &buf));
}
