const std = @import("std");
const unicode = @import("unicode.zig");
const utf = @import("utf.zig");

/// Canonical NFC normalization, matching the normalization pass used by the
/// upstream Qwen tokenizer. Returned storage belongs to the caller.
pub fn nfc(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var decomposed: std.ArrayList(u21) = .empty;
    defer decomposed.deinit(alloc);
    var pos: usize = 0;
    while (pos < text.len) {
        const decoded = utf.decode(text, pos);
        pos += @max(decoded.len, 1);
        try appendDecomposed(alloc, &decomposed, decoded.codepoint);
    }
    // Canonical ordering is local to each starter sequence. This insertion
    // pass is linear for normal text and handles all non-zero classes.
    var i: usize = 0;
    while (i < decomposed.items.len) : (i += 1) {
        const cls = unicode.combiningClass(decomposed.items[i]);
        if (cls == 0) continue;
        var j = i;
        while (j > 0) {
            const previous_cls = unicode.combiningClass(decomposed.items[j - 1]);
            if (previous_cls == 0 or previous_cls <= cls) break;
            const tmp = decomposed.items[j - 1];
            decomposed.items[j - 1] = decomposed.items[j];
            decomposed.items[j] = tmp;
            j -= 1;
        }
    }

    var composed: std.ArrayList(u21) = .empty;
    defer composed.deinit(alloc);
    var starter: ?usize = null;
    var last_class: u8 = 0;
    for (decomposed.items) |cp| {
        const cls = unicode.combiningClass(cp);
        if (starter) |starter_index| {
            const can_compose = last_class == 0 or last_class < cls;
            if (can_compose) {
                const pair = (@as(u64, composed.items[starter_index]) << 21) | cp;
                if (unicode.compose(pair)) |combined| {
                    composed.items[starter_index] = combined;
                    continue;
                }
            }
        }
        try composed.append(alloc, cp);
        if (cls == 0) {
            starter = composed.items.len - 1;
            last_class = 0;
        } else {
            last_class = cls;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (composed.items) |cp| {
        var buf: [4]u8 = undefined;
        const n = utf.encode(cp, &buf);
        try out.appendSlice(alloc, buf[0..n]);
    }
    return out.toOwnedSlice(alloc);
}

fn appendDecomposed(alloc: std.mem.Allocator, out: *std.ArrayList(u21), cp: u21) !void {
    if (unicode.findDecomposition(cp)) |entry| {
        for (entry.parts[0..entry.len]) |part| try appendDecomposed(alloc, out, part);
    } else {
        try out.append(alloc, cp);
    }
}
