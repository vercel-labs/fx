//! The startup welcome: the animated black prism banner above the title row.
//! The transcript runtime owns one `Welcome`. Writing the welcome renders the
//! first frame and starts the frame clock; later frames replace the welcome
//! entry while it is the only transcript content.

const std = @import("std");
const black_prism = @import("black_prism.zig");
const display_width = @import("../core/shared/display_width.zig");
const ui_render = @import("render.zig");

const Allocator = std.mem.Allocator;

pub const Welcome = struct {
    /// Present while the banner animates. Holds the scene geometry, so frames
    /// after the first only recolor it.
    animation: ?black_prism.Animation = null,
    /// The title row, rendered once per welcome write.
    title: ?[]u8 = null,
    /// Terminal rows the last rendered welcome occupies at its width.
    rows: u16 = 0,

    pub fn deinit(self: *Welcome, alloc: Allocator) void {
        self.stop();
        if (self.title) |title| alloc.free(title);
        self.* = .{};
    }

    pub fn animating(self: *const Welcome) bool {
        return self.animation != null;
    }

    /// Renders frame 0 at `cols` with a fresh title and starts the frame clock
    /// at `now_ms`. Caller owns the result.
    pub fn begin(self: *Welcome, alloc: Allocator, cols: u16, now_ms: i64) ![]u8 {
        const title = try ui_render.welcomeTitle(alloc);
        if (self.title) |old| alloc.free(old);
        self.title = title;
        if (self.animation == null) self.animation = try black_prism.Animation.init(alloc);
        errdefer self.stop();
        const animation = &self.animation.?;
        animation.start(now_ms);
        const frame = try animation.renderFrame(alloc, cols, 0);
        defer alloc.free(frame);
        return self.compose(alloc, frame, cols);
    }

    /// Renders the frame due at `now_ms`, or returns null when none is due or
    /// the animation is stopped. Caller owns the result.
    pub fn next(self: *Welcome, alloc: Allocator, cols: u16, now_ms: i64) !?[]u8 {
        const animation = if (self.animation) |*value| value else return null;
        const frame = (try animation.nextFrame(alloc, cols, now_ms)) orelse return null;
        defer alloc.free(frame);
        return try self.compose(alloc, frame, cols);
    }

    /// Stops the animation and frees the scene. The welcome entry keeps its
    /// last frame.
    pub fn stop(self: *Welcome) void {
        if (self.animation) |*animation| animation.deinit();
        self.animation = null;
    }

    fn compose(self: *Welcome, alloc: Allocator, frame: []const u8, cols: u16) ![]u8 {
        const bytes = try alloc.print("{s}\n{s}", .{ frame, self.title.? });
        self.rows = renderedRows(bytes, cols);
        return bytes;
    }
};

/// Rows `bytes` fill at `cols`, counting each newline-terminated line and the
/// rows a long line wraps onto.
fn renderedRows(bytes: []const u8, cols: u16) u16 {
    const width: usize = if (cols == 0) 80 else cols;
    var rows: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (lines.index == null and line.len == 0) break;
        const visible = display_width.visibleWidthIgnoringAnsi(line);
        rows += @max(1, @divCeil(visible, width));
    }
    return std.math.cast(u16, rows) orelse std.math.maxInt(u16);
}

test "welcome rows match the banner, title, and spacing" {
    const alloc = std.testing.allocator;
    var welcome: Welcome = .{};
    defer welcome.deinit(alloc);

    const bytes = try welcome.begin(alloc, 96, 1_000);
    defer alloc.free(bytes);
    try std.testing.expect(welcome.animating());
    try std.testing.expect(std.mem.find(u8, bytes, "Run /help for commands") != null);
    try std.testing.expectEqual(ui_render.welcome_message_reserved_rows, welcome.rows);
    try std.testing.expectEqual(@as(usize, welcome.rows), std.mem.count(u8, bytes, "\n"));

    // A narrow terminal wraps the title onto more rows.
    const narrow = (try welcome.next(alloc, 20, 3_000)).?;
    defer alloc.free(narrow);
    try std.testing.expect(welcome.rows > ui_render.welcome_message_reserved_rows);

    welcome.stop();
    try std.testing.expect(!welcome.animating());
    try std.testing.expect((try welcome.next(alloc, 96, 5_000)) == null);
}

test "rendered rows count wrapped lines and ignore the final newline" {
    try std.testing.expectEqual(@as(u16, 3), renderedRows("a\n\nb\n", 10));
    try std.testing.expectEqual(@as(u16, 2), renderedRows("abcdefghijkl\n", 10));
    try std.testing.expectEqual(@as(u16, 1), renderedRows("abc", 10));
}
