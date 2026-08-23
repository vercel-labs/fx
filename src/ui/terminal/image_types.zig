const std = @import("std");
const types = @import("../../core/shared/types.zig");

pub const Protocol = enum {
    none,
    kitty,

    pub fn supportsMediaType(self: Protocol, media_type: []const u8) bool {
        return switch (self) {
            .none => false,
            // Kitty's f=100 transfer is a PNG payload. Other attachment formats
            // keep their ordinary linked text badge until fx has a native decoder.
            .kitty => std.mem.eql(u8, media_type, "image/png"),
        };
    }
};

pub const CellDimensions = struct {
    width_px: u16 = 8,
    height_px: u16 = 16,
};

pub const PreviewConfig = struct {
    protocol: Protocol = .none,
    cells: CellDimensions = .{},
    max_width_cells: u16 = 48,
    max_height_cells: u16 = 10,

    pub fn enabled(self: PreviewConfig) bool {
        return self.protocol != .none and
            self.cells.width_px > 0 and
            self.cells.height_px > 0 and
            self.max_width_cells > 0 and
            self.max_height_cells > 0;
    }

    pub fn supports(self: PreviewConfig, attachment: types.ImageAttachment) bool {
        return self.enabled() and
            attachment.snapshot_path != null and
            attachment.snapshot_sha256 != null and
            self.protocol.supportsMediaType(attachment.media_type);
    }
};

pub const Fit = struct {
    columns: u16,
    rows: u16,
};

pub fn fitPreview(
    attachment: types.ImageAttachment,
    terminal_cols: u16,
    config: PreviewConfig,
) ?Fit {
    if (!config.supports(attachment) or terminal_cols <= 2) return null;
    const max_columns = @min(config.max_width_cells, terminal_cols - 2);
    if (max_columns == 0) return null;

    const width_px: u64 = if (attachment.pixel_width > 0) attachment.pixel_width else 800;
    const height_px: u64 = if (attachment.pixel_height > 0) attachment.pixel_height else 600;
    const natural_columns = ceilDiv(width_px, config.cells.width_px);
    const natural_rows = ceilDiv(height_px, config.cells.height_px);
    if (natural_columns == 0 or natural_rows == 0) return null;

    const max_cols_u64: u64 = max_columns;
    const max_rows_u64: u64 = config.max_height_cells;
    var columns = natural_columns;
    var rows = natural_rows;
    if (columns > max_cols_u64 or rows > max_rows_u64) {
        const width_limited = max_cols_u64 * natural_rows <= max_rows_u64 * natural_columns;
        if (width_limited) {
            columns = max_cols_u64;
            rows = @max(@as(u64, 1), ceilDiv(natural_rows * max_cols_u64, natural_columns));
        } else {
            rows = max_rows_u64;
            columns = @max(@as(u64, 1), ceilDiv(natural_columns * max_rows_u64, natural_rows));
        }
    }

    return .{
        .columns = @intCast(@min(columns, max_cols_u64)),
        .rows = @intCast(@min(rows, max_rows_u64)),
    };
}

pub const Placement = struct {
    source_namespace: usize,
    entry_id: u32,
    attachment: types.ImageAttachment,
    row: u16,
    col: u16,
    columns: u16,
    rows: u16,

    pub fn bottom(self: Placement) u16 {
        return self.row +| self.rows -| 1;
    }

    pub fn right(self: Placement) u16 {
        return self.col +| self.columns -| 1;
    }
};

fn ceilDiv(numerator: u64, denominator: u64) u64 {
    if (denominator == 0) return 0;
    return numerator / denominator + @intFromBool(numerator % denominator != 0);
}

test "preview fit preserves cell aspect ratio inside both bounds" {
    const attachment = types.ImageAttachment{
        .path = @constCast("/tmp/image.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast("/tmp/snapshot.png"),
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .pixel_width = 100,
        .pixel_height = 100,
    };
    const fit = fitPreview(attachment, 80, .{
        .protocol = .kitty,
        .cells = .{ .width_px = 10, .height_px = 10 },
        .max_width_cells = 10,
        .max_height_cells = 2,
    }).?;
    try std.testing.expectEqual(Fit{ .columns = 2, .rows = 2 }, fit);
}

test "preview fit rejects unsupported payloads and narrow terminals" {
    const attachment = types.ImageAttachment{
        .path = @constCast("/tmp/image.jpg"),
        .media_type = @constCast("image/jpeg"),
        .snapshot_path = @constCast("/tmp/snapshot.jpg"),
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    };
    try std.testing.expect(fitPreview(attachment, 80, .{ .protocol = .kitty }) == null);
    try std.testing.expect(fitPreview(attachment, 2, .{ .protocol = .kitty }) == null);
}
