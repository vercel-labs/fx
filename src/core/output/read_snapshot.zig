//! `proto-fx read` output: one read rendered as text or JSON.
const std = @import("std");

const Allocator = std.mem.Allocator;
const OutputFormat = @import("output_contracts.zig").OutputFormat;

pub const ReadImage = struct {
    mime_type: []const u8,
    /// Base64 bytes, as the model receives them.
    data_bytes: usize,
};

/// Every field is borrowed from the read result.
pub const Snapshot = struct {
    pub const Image = ReadImage;

    target: []const u8,
    ok: bool,
    /// What the model would read: the tool result body.
    content: []const u8,
    images: []const ReadImage = &.{},

    pub fn render(self: Snapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .text => self.renderText(alloc),
            .json => std.json.Stringify.valueAlloc(alloc, self, .{}),
        };
    }

    fn renderText(self: Snapshot, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        const w = &out.writer;
        if (!self.ok) try w.writeAll("read failed: ");
        try w.writeAll(self.content);
        if (self.content.len == 0 or self.content[self.content.len - 1] != '\n') try w.writeByte('\n');
        for (self.images) |image| try w.print("[image attached: {s}, {d} base64 bytes]\n", .{ image.mime_type, image.data_bytes });
        return out.toOwnedSlice();
    }
};

test "read snapshot renders text and json from the same fields" {
    const alloc = std.testing.allocator;
    const images = [_]ReadImage{.{ .mime_type = "image/png", .data_bytes = 8 }};
    const snapshot = Snapshot{ .target = "a.png", .ok = true, .content = "<path>a.png</path>", .images = &images };
    const text = try snapshot.render(alloc, .text);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("<path>a.png</path>\n[image attached: image/png, 8 base64 bytes]\n", text);
    const json = try snapshot.render(alloc, .json);
    defer alloc.free(json);
    try std.testing.expectEqualStrings("{\"target\":\"a.png\",\"ok\":true,\"content\":\"<path>a.png</path>\",\"images\":[{\"mime_type\":\"image/png\",\"data_bytes\":8}]}", json);
}
