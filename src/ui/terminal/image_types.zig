const std = @import("std");
const types = @import("../../core/shared/types.zig");

pub const Protocol = enum {
    none,
    kitty,

    pub fn supportsMediaType(self: Protocol, media_type: []const u8) bool {
        return switch (self) {
            .none => false,
            // Kitty's f=100 transfer is always PNG. The renderer passes PNG
            // through and normalizes these other supported formats first.
            .kitty => std.mem.eql(u8, media_type, "image/png") or
                std.mem.eql(u8, media_type, "image/jpeg") or
                std.mem.eql(u8, media_type, "image/gif") or
                std.mem.eql(u8, media_type, "image/webp"),
        };
    }
};

pub const CellDimensions = struct {
    width_px: u16 = 8,
    height_px: u16 = 16,
};

pub const preview_origin_col: u16 = 1;

pub const PreviewConfig = struct {
    protocol: Protocol = .none,
    cells: CellDimensions = .{},
    // Use roomy inline-image defaults. fitPreview still reserves two terminal
    // columns and preserves the source aspect ratio.
    max_width_cells: u16 = 100,
    max_height_cells: u16 = 20,

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
    if (width_px == 0 or height_px == 0) return null;

    const max_cols_u64: u64 = max_columns;
    const max_rows_u64: u64 = config.max_height_cells;
    const cell_width_px: u64 = config.cells.width_px;
    const cell_height_px: u64 = config.cells.height_px;
    const max_width_px = max_cols_u64 * cell_width_px;
    const max_height_px = max_rows_u64 * cell_height_px;
    const width_limited = max_width_px * height_px <= max_height_px * width_px;

    // Like Pi, scale both small and large images until one configured bound is
    // filled. This produces a legible preview instead of preserving tiny source
    // dimensions as a tiny terminal placement.
    const columns = if (width_limited)
        max_cols_u64
    else
        @max(
            @as(u64, 1),
            width_px * max_height_px / (height_px * cell_width_px),
        );
    const rows = if (width_limited)
        @max(
            @as(u64, 1),
            ceilDiv(height_px * max_width_px, width_px * cell_height_px),
        )
    else
        max_rows_u64;

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

test "preview fit upscales small images to the configured bounds" {
    const attachment = types.ImageAttachment{
        .path = @constCast("/tmp/small.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast("/tmp/snapshot.png"),
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .pixel_width = 100,
        .pixel_height = 50,
    };
    const fit = fitPreview(attachment, 80, .{
        .protocol = .kitty,
        .cells = .{ .width_px = 10, .height_px = 10 },
        .max_width_cells = 20,
        .max_height_cells = 20,
    }).?;
    try std.testing.expectEqual(Fit{ .columns = 20, .rows = 10 }, fit);
}

test "preview fit uses large inline preview defaults" {
    const attachment = types.ImageAttachment{
        .path = @constCast("/tmp/landscape.png"),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast("/tmp/snapshot.png"),
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .pixel_width = 800,
        .pixel_height = 600,
    };
    const fit = fitPreview(attachment, 120, .{ .protocol = .kitty }).?;
    try std.testing.expectEqual(Fit{ .columns = 53, .rows = 20 }, fit);
}

test "preview fit accepts convertible payloads and rejects unsupported ones" {
    const attachment = types.ImageAttachment{
        .path = @constCast("/tmp/image.jpg"),
        .media_type = @constCast("image/jpeg"),
        .snapshot_path = @constCast("/tmp/snapshot.jpg"),
        .snapshot_sha256 = @constCast("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    };
    try std.testing.expect(fitPreview(attachment, 80, .{ .protocol = .kitty }) != null);
    try std.testing.expect(fitPreview(attachment, 2, .{ .protocol = .kitty }) == null);

    var unsupported = attachment;
    unsupported.media_type = @constCast("image/avif");
    try std.testing.expect(fitPreview(unsupported, 80, .{ .protocol = .kitty }) == null);
}
