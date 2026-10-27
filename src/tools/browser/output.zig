//! What a browser run hands back (D199): `display()` text, console lines
//! and dialog notices in order, the return value, and screenshots, which are
//! saved to a file and attached as images for vision-capable models.
const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const cdp = @import("../../core/browser/cdp.zig");
const types = @import("../../core/shared/types.zig");
const page_mod = @import("page.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Page = page_mod.Page;

/// The longest side of an attached screenshot, as proto resizes them.
const max_image_side: f64 = 1024;
/// Images one run attaches; later screenshots are saved only.
const max_images = 3;
/// Full-page captures stop at this many CSS pixels of height.
const max_full_page_height: f64 = 8000;

pub const Output = struct {
    gpa: Allocator,
    text: std.ArrayList(u8) = .empty,
    /// Owned by `gpa`: base64 JPEG data and mime type, ready for a tool result.
    images: std.ArrayList(types.ToolImage) = .empty,
    /// Where screenshots go; null uses the temporary folder.
    screenshot_dir: ?[]const u8 = null,
    max_text_bytes: usize,
    dropped_bytes: usize = 0,
    screenshots: usize = 0,

    pub fn deinit(self: *Output) void {
        self.text.deinit(self.gpa);
        for (self.images.items) |image| {
            self.gpa.free(image.data);
            self.gpa.free(image.mime_type);
        }
        self.images.deinit(self.gpa);
    }

    /// Takes the images; the caller frees them.
    pub fn takeImages(self: *Output) ![]types.ToolImage {
        return self.images.toOwnedSlice(self.gpa);
    }

    /// Appends one block of text on its own line, within the text budget.
    pub fn line(self: *Output, text: []const u8) void {
        const trimmed = std.mem.trimEnd(u8, text, "\n");
        const needed = trimmed.len + 1;
        if (self.text.items.len + needed > self.max_text_bytes) {
            self.dropped_bytes += needed;
            return;
        }
        self.text.appendSlice(self.gpa, trimmed) catch return;
        self.text.append(self.gpa, '\n') catch return;
    }

    /// The text with a note for anything over budget, owned by `alloc`.
    pub fn finish(self: *Output, alloc: Allocator) ![]u8 {
        const body = std.mem.trimEnd(u8, self.text.items, "\n");
        if (self.dropped_bytes == 0) return alloc.dupe(u8, body);
        return alloc.print("{s}\n[output truncated: {d} more bytes not shown; return less or display() a summary]", .{ body, self.dropped_bytes });
    }

    /// `tab.screenshot({ selector?, fullPage?, silent? })`: captures, saves,
    /// attaches, and answers the saved path as JSON.
    pub fn screenshot(self: *Output, arena: Allocator, page: *Page, args: Value) page_mod.Failure![]const u8 {
        const browser = page.browser;
        var metrics = browser.call(page.tab.session_id, "Page.getLayoutMetrics", .{}) catch |err| return page.protocolFailure(err, "tab.screenshot");
        defer metrics.deinit(browser.alloc);
        const viewport = if (metrics.value() == .object) metrics.value().object.get("cssVisualViewport") else null;
        const content = if (metrics.value() == .object) metrics.value().object.get("cssContentSize") else null;
        const v = viewport orelse return page.fail("tab.screenshot: no layout metrics", .{});
        const page_x = cdp.floatField(v, "pageX") orelse 0;
        const page_y = cdp.floatField(v, "pageY") orelse 0;
        var clip: Clip = .{
            .x = page_x,
            .y = page_y,
            .width = cdp.floatField(v, "clientWidth") orelse 1280,
            .height = cdp.floatField(v, "clientHeight") orelse 800,
        };
        const full_page = if (args == .object) if (args.object.get("fullPage")) |f| f == .bool and f.bool else false else false;
        const silent = if (args == .object) if (args.object.get("silent")) |f| f == .bool and f.bool else false else false;
        const selector_target: ?Value = if (args == .object) blk: {
            if (args.object.get("target")) |target| break :blk target;
            if (cdp.stringField(args, "selector")) |selector| {
                var object: std.json.ObjectMap = .empty;
                object.put(arena, "selector", .{ .string = selector }) catch return page.fail("out of memory", .{});
                break :blk Value{ .object = object };
            }
            break :blk null;
        } else null;
        if (selector_target) |target| {
            const object_id = try page.resolveTarget(target, 5_000);
            const b = try page.box(object_id);
            // The box is in viewport coordinates after scrolling it into view.
            var after = browser.call(page.tab.session_id, "Page.getLayoutMetrics", .{}) catch |err| return page.protocolFailure(err, "tab.screenshot");
            defer after.deinit(browser.alloc);
            const scrolled = if (after.value() == .object) after.value().object.get("cssVisualViewport") else null;
            clip = .{
                .x = b.x + (if (scrolled) |s| cdp.floatField(s, "pageX") orelse 0 else 0),
                .y = b.y + (if (scrolled) |s| cdp.floatField(s, "pageY") orelse 0 else 0),
                .width = @max(1, b.width),
                .height = @max(1, b.height),
            };
        } else if (full_page) {
            const c = content orelse return page.fail("tab.screenshot: no content size", .{});
            clip = .{ .x = 0, .y = 0, .width = cdp.floatField(c, "width") orelse clip.width, .height = @min(cdp.floatField(c, "height") orelse clip.height, max_full_page_height) };
        }
        const longest = @max(clip.width, clip.height);
        const scale = if (longest > max_image_side) max_image_side / longest else 1;
        var shot = browser.call(page.tab.session_id, "Page.captureScreenshot", .{
            .format = "jpeg",
            .quality = 75,
            .clip = .{ .x = clip.x, .y = clip.y, .width = clip.width, .height = clip.height, .scale = scale },
            .captureBeyondViewport = full_page,
        }) catch |err| return page.protocolFailure(err, "tab.screenshot");
        defer shot.deinit(browser.alloc);
        const data = cdp.stringField(shot.value(), "data") orelse return page.fail("tab.screenshot returned no image", .{});
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data) catch return page.fail("tab.screenshot returned bad data", .{});
        const bytes = arena.alloc(u8, decoded_len) catch return page.fail("out of memory", .{});
        std.base64.standard.Decoder.decode(bytes, data) catch return page.fail("tab.screenshot returned bad data", .{});
        const path = self.save(arena, bytes) catch |err| return page.fail("tab.screenshot could not save the image: {s}", .{@errorName(err)});
        self.screenshots += 1;
        const width: u32 = @intFromFloat(@round(clip.width * scale));
        const height: u32 = @intFromFloat(@round(clip.height * scale));
        if (!silent) {
            if (self.images.items.len < max_images) {
                const owned = self.gpa.dupe(u8, data) catch return page.fail("out of memory", .{});
                const mime = self.gpa.dupe(u8, "image/jpeg") catch {
                    self.gpa.free(owned);
                    return page.fail("out of memory", .{});
                };
                self.images.append(self.gpa, .{ .data = owned, .mime_type = mime }) catch {
                    self.gpa.free(owned);
                    self.gpa.free(mime);
                    return page.fail("out of memory", .{});
                };
                const text = arena.print("Screenshot {d}x{d} jpeg, {d} bytes, attached: {s}", .{ width, height, bytes.len, path }) catch path;
                self.line(text);
            } else {
                const text = arena.print("Screenshot {d}x{d} jpeg saved (not attached, {d} per run): {s}", .{ width, height, max_images, path }) catch path;
                self.line(text);
            }
        }
        var out: std.Io.Writer.Allocating = .init(arena);
        std.json.Stringify.value(path, .{}, &out.writer) catch return page.fail("out of memory", .{});
        return out.toOwnedSlice() catch page.fail("out of memory", .{});
    }

    fn save(self: *Output, arena: Allocator, bytes: []const u8) ![]const u8 {
        const io = io_mod.getIo();
        const dir = self.screenshot_dir orelse std.mem.trimEnd(u8, io_mod.getenv("TMPDIR") orelse "/tmp", "/");
        if (self.screenshot_dir != null) try std.Io.Dir.cwd().createDirPath(io, dir);
        var nonce: [4]u8 = undefined;
        io.random(&nonce);
        const name = try arena.print("proto-fx-screenshot-{d}-{s}.jpg", .{ io_mod.milliTimestamp(), &std.fmt.bytesToHex(nonce, .lower) });
        const path = try std.Io.Dir.path.join(arena, &.{ dir, name });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
        return path;
    }
};

const Clip = struct { x: f64, y: f64, width: f64, height: f64 };

test "browser run output keeps lines in order and reports what it dropped" {
    const alloc = std.testing.allocator;
    var output: Output = .{ .gpa = alloc, .max_text_bytes = 16 };
    defer output.deinit();
    output.line("first\n");
    output.line("second");
    output.line("this one does not fit");
    const text = try output.finish(alloc);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("first\nsecond\n[output truncated: 22 more bytes not shown; return less or display() a summary]", text);
}
