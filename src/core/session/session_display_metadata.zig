const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const image_attachments = @import("../images/image_attachments.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("session.zig");

const Allocator = std.mem.Allocator;

pub const sidecar_file = "display.json";
pub const max_sidecar_bytes: usize = 16 * 1024;
const max_title_words: usize = 8;
pub const max_title_bytes: usize = 240;
const max_preview_lines: usize = 2;
const max_preview_bytes: usize = 240;
pub const fallback_title = "Untitled session";
pub const image_title = "Image session";

pub const DisplayMetadata = struct {
    present: bool = false,
    title: []u8,
    preview: ?[]u8 = null,
    origin_workspace_root: ?[]u8 = null,

    pub fn deinit(self: *DisplayMetadata, alloc: Allocator) void {
        alloc.free(self.title);
        if (self.preview) |preview| alloc.free(preview);
        if (self.origin_workspace_root) |root| alloc.free(root);
        self.* = undefined;
    }
};

pub fn missingFallback(alloc: Allocator) !DisplayMetadata {
    return .{
        .present = false,
        .title = try alloc.dupe(u8, fallback_title),
    };
}

pub fn deriveFromHistory(alloc: Allocator, history: []const session.HistoryTurn) !DisplayMetadata {
    const candidate = firstPromptCandidate(history) orelse {
        return if (history.len == 0) missingFallback(alloc) else missingFallbackPresent(alloc);
    };
    switch (candidate) {
        .text => |prompt| {
            if (!std.unicode.utf8ValidateSlice(prompt)) return missingFallbackPresent(alloc);

            const first_line = firstNonEmptyLine(prompt) orelse return missingFallbackPresent(alloc);
            const title = try cappedTitle(alloc, first_line);
            errdefer alloc.free(title);
            const preview = try boundedPreview(alloc, prompt);
            errdefer if (preview) |value| alloc.free(value);

            return .{
                .present = true,
                .title = title,
                .preview = preview,
            };
        },
        .image_only => return .{
            .present = true,
            .title = try alloc.dupe(u8, image_title),
        },
    }
}

fn missingFallbackPresent(alloc: Allocator) !DisplayMetadata {
    return .{
        .present = true,
        .title = try alloc.dupe(u8, fallback_title),
    };
}

const PromptCandidate = union(enum) {
    text: []const u8,
    image_only,
};

fn firstPromptCandidate(history: []const session.HistoryTurn) ?PromptCandidate {
    for (history) |turn| {
        switch (turn) {
            .assistant => |entry| if (promptCandidateFromUser(entry.user)) |candidate| return candidate,
            .interrupted => |entry| if (promptCandidateFromUser(entry.user)) |candidate| return candidate,
            .compacted_summary => {},
        }
    }
    return null;
}

fn promptCandidateFromUser(user: session.UserTurn) ?PromptCandidate {
    const trimmed = std.mem.trim(u8, user.text, " \t\r\n");
    if (isCanonicalImageOnlyText(user.text, user.images)) return .image_only;
    if (trimmed.len > 0 and !isSlashCommandOnly(trimmed)) return .{ .text = user.text };
    if (user.images.len > 0) return .image_only;
    return null;
}

fn isCanonicalImageOnlyText(text: []const u8, images: []const session.ImageAttachment) bool {
    if (images.len == 0) return false;

    var text_offset: usize = 0;
    for (images, 0..) |image, index| {
        if (index > 0) {
            if (text_offset >= text.len or text[text_offset] != '\n') return false;
            text_offset += 1;
        }
        const placeholder = image_attachments.matchImagePlaceholder(text, text_offset) orelse return false;
        if (placeholder.id != image.id) return false;
        text_offset += placeholder.length;
    }
    return text_offset == text.len;
}

fn isSlashCommandOnly(trimmed: []const u8) bool {
    return trimmed.len > 0 and trimmed[0] == '/' and std.mem.findScalar(u8, trimmed, '\n') == null;
}

fn firstNonEmptyLine(text: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

fn cappedTitle(alloc: Allocator, line: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var words: usize = 0;
    var index: usize = 0;
    while (index < line.len and words < max_title_words) {
        while (index < line.len and std.ascii.isWhitespace(line[index])) index += 1;
        const start = index;
        while (index < line.len and !std.ascii.isWhitespace(line[index])) index += 1;
        if (index == start) break;
        const separator: usize = if (words > 0) 1 else 0;
        const remaining = max_title_bytes - @min(max_title_bytes, out.items.len + separator);
        const take = validUtf8PrefixLen(line[start..index], remaining);
        if (take == 0) break;
        if (words > 0) try out.append(alloc, ' ');
        try out.appendSlice(alloc, line[start .. start + take]);
        words += 1;
    }

    if (out.items.len == 0) return try alloc.dupe(u8, fallback_title);
    return try out.toOwnedSlice(alloc);
}

fn boundedPreview(alloc: Allocator, text: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var line_count: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line_count == max_preview_lines) break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (out.items.len > 0) try out.append(alloc, '\n');
        const remaining = max_preview_bytes - @min(max_preview_bytes, out.items.len);
        if (remaining == 0) break;
        const take = validUtf8PrefixLen(trimmed, remaining);
        try out.appendSlice(alloc, trimmed[0..take]);
        line_count += 1;
        if (take < trimmed.len or out.items.len >= max_preview_bytes) break;
    }

    if (out.items.len == 0) {
        out.deinit(alloc);
        return null;
    }
    return try out.toOwnedSlice(alloc);
}

fn validUtf8PrefixLen(text: []const u8, max_bytes: usize) usize {
    var end = @min(text.len, max_bytes);
    while (end > 0 and !std.unicode.utf8ValidateSlice(text[0..end])) {
        end -= 1;
    }
    return end;
}

pub fn encodeSidecar(alloc: Allocator, metadata: DisplayMetadata) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"schema_version\":1,\"title\":");
    try std.json.Stringify.value(metadata.title, .{}, &out.writer);
    try out.writer.writeAll(",\"preview\":");
    if (metadata.preview) |preview| {
        try std.json.Stringify.value(preview, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeAll(",\"origin_workspace_root\":");
    if (metadata.origin_workspace_root) |root| {
        try std.json.Stringify.value(root, .{}, &out.writer);
    } else {
        try out.writer.writeAll("null");
    }
    try out.writer.writeByte('}');

    if (out.written().len > max_sidecar_bytes) return error.DisplayMetadataTooLarge;
    return try out.toOwnedSlice();
}

pub fn decodeSidecar(alloc: Allocator, bytes: []const u8) !DisplayMetadata {
    if (bytes.len == 0 or bytes.len > max_sidecar_bytes) return error.InvalidDisplayMetadata;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidDisplayMetadata,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidDisplayMetadata;
    const root = parsed.value.object;
    const schema = root.get("schema_version") orelse return error.InvalidDisplayMetadata;
    if (schema != .integer or schema.integer != 1) return error.InvalidDisplayMetadata;

    const title = try requiredStringDup(alloc, root.get("title"));
    errdefer alloc.free(title);
    if (title.len == 0 or !std.unicode.utf8ValidateSlice(title)) {
        return error.InvalidDisplayMetadata;
    }
    const preview = try optionalStringDup(alloc, root.get("preview"));
    errdefer if (preview) |value| alloc.free(value);
    const origin = try optionalStringDup(alloc, root.get("origin_workspace_root"));
    errdefer if (origin) |value| alloc.free(value);

    return .{
        .present = true,
        .title = title,
        .preview = preview,
        .origin_workspace_root = origin,
    };
}

pub fn decodeSidecarOrFallback(alloc: Allocator, bytes: []const u8) !DisplayMetadata {
    return decodeSidecar(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("session", "event=display_sidecar_invalid err={s}", .{@errorName(err)});
            return missingFallback(alloc);
        },
    };
}

pub fn readSidecarOrFallback(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
) !DisplayMetadata {
    var file = session_dir.dir.openFile(io_mod.getIo(), sidecar_file, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return missingFallback(alloc),
        error.NotDir, error.SymLinkLoop, error.IsDir => return missingFallback(alloc),
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const bytes = io_mod.readFileToEnd(alloc, &file, max_sidecar_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("session", "event=display_sidecar_unreadable err={s}", .{@errorName(err)});
            return missingFallback(alloc);
        },
    };
    defer alloc.free(bytes);
    return decodeSidecarOrFallback(alloc, bytes);
}

pub fn writeSidecar(
    alloc: Allocator,
    session_dir: *io_mod.VerifiedDir,
    metadata: DisplayMetadata,
) !void {
    const bytes = try encodeSidecar(alloc, metadata);
    defer alloc.free(bytes);
    try io_mod.durableReplaceVerified(alloc, session_dir, sidecar_file, bytes);
}

fn requiredStringDup(alloc: Allocator, maybe_value: ?std.json.Value) ![]u8 {
    const value = maybe_value orelse return error.InvalidDisplayMetadata;
    if (value != .string) return error.InvalidDisplayMetadata;
    return try alloc.dupe(u8, value.string);
}

fn optionalStringDup(alloc: Allocator, maybe_value: ?std.json.Value) !?[]u8 {
    const value = maybe_value orelse return error.InvalidDisplayMetadata;
    switch (value) {
        .null => return null,
        .string => |text| {
            if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidDisplayMetadata;
            return try alloc.dupe(u8, text);
        },
        else => return error.InvalidDisplayMetadata,
    }
}

test "display metadata derives capped title from first prompt line and bounded preview" {
    const alloc = std.testing.allocator;
    const history = [_]session.HistoryTurn{
        makeAssistantTurn(
            "one two three four five six seven eight nine ten\nsecond line kept\nthird line dropped",
        ),
    };

    var metadata = try deriveFromHistory(alloc, &history);
    defer metadata.deinit(alloc);

    try std.testing.expect(metadata.present);
    try std.testing.expectEqualStrings("one two three four five six seven eight", metadata.title);
    try std.testing.expectEqualStrings(
        "one two three four five six seven eight nine ten\nsecond line kept",
        metadata.preview.?,
    );
}

test "display metadata byte-caps a single-token title" {
    const alloc = std.testing.allocator;
    const long_token = "x" ** 512;
    const history = [_]session.HistoryTurn{makeAssistantTurn(long_token)};

    var metadata = try deriveFromHistory(alloc, &history);
    defer metadata.deinit(alloc);

    try std.testing.expect(metadata.present);
    try std.testing.expectEqual(max_title_bytes, metadata.title.len);
}

test "display metadata falls back for empty or non-text initial history" {
    const alloc = std.testing.allocator;
    var no_history = try deriveFromHistory(alloc, &.{});
    defer no_history.deinit(alloc);
    try std.testing.expect(!no_history.present);
    try std.testing.expectEqualStrings("Untitled session", no_history.title);

    const empty_history = [_]session.HistoryTurn{
        makeAssistantTurn("   \n\t"),
    };

    var metadata = try deriveFromHistory(alloc, &empty_history);
    defer metadata.deinit(alloc);

    try std.testing.expect(metadata.present);
    try std.testing.expectEqualStrings("Untitled session", metadata.title);
    try std.testing.expect(metadata.preview == null);
}

test "display metadata skips slash-only turns and handles image-only sessions" {
    const alloc = std.testing.allocator;
    const slash_then_prompt = [_]session.HistoryTurn{
        makeAssistantTurn("/resume"),
        makeAssistantTurn("real prompt title"),
    };

    var metadata = try deriveFromHistory(alloc, &slash_then_prompt);
    defer metadata.deinit(alloc);
    try std.testing.expect(metadata.present);
    try std.testing.expectEqualStrings("real prompt title", metadata.title);

    const image = session.ImageAttachment{
        .path = @constCast("/tmp/image.png"),
        .media_type = @constCast("image/png"),
    };
    var images = [_]session.ImageAttachment{image};
    const image_only = [_]session.HistoryTurn{
        makeAssistantTurnWithImages("", images[0..]),
    };

    var image_metadata = try deriveFromHistory(alloc, &image_only);
    defer image_metadata.deinit(alloc);
    try std.testing.expect(image_metadata.present);
    try std.testing.expectEqualStrings("Image session", image_metadata.title);
    try std.testing.expect(image_metadata.preview == null);
}

test "display metadata treats canonical image placeholders as image-only syntax" {
    const alloc = std.testing.allocator;
    const first = session.ImageAttachment{
        .id = 7,
        .path = @constCast("/tmp/first.png"),
        .media_type = @constCast("image/png"),
    };
    const second = session.ImageAttachment{
        .id = 9,
        .path = @constCast("/tmp/second.png"),
        .media_type = @constCast("image/png"),
    };
    var images = [_]session.ImageAttachment{ first, second };

    const image_only = [_]session.HistoryTurn{
        makeAssistantTurnWithImages("[Image #7]\n[Image #9]", images[0..]),
    };
    var image_metadata = try deriveFromHistory(alloc, &image_only);
    defer image_metadata.deinit(alloc);
    try std.testing.expectEqualStrings(image_title, image_metadata.title);
    try std.testing.expect(image_metadata.preview == null);

    const mixed = [_]session.HistoryTurn{
        makeAssistantTurnWithImages("Describe [Image #7]", images[0..1]),
    };
    var mixed_metadata = try deriveFromHistory(alloc, &mixed);
    defer mixed_metadata.deinit(alloc);
    try std.testing.expectEqualStrings("Describe [Image #7]", mixed_metadata.title);

    const mismatched = [_]session.HistoryTurn{
        makeAssistantTurnWithImages("[Image #8]", images[0..1]),
    };
    var mismatched_metadata = try deriveFromHistory(alloc, &mismatched);
    defer mismatched_metadata.deinit(alloc);
    try std.testing.expectEqualStrings("[Image #8]", mismatched_metadata.title);
}

test "display metadata sidecar round trips and invalid sidecar falls back" {
    const alloc = std.testing.allocator;
    const source = DisplayMetadata{
        .present = true,
        .title = @constCast("Plan release notes"),
        .preview = @constCast("Plan release notes\nship checklist"),
        .origin_workspace_root = @constCast("/tmp/origin"),
    };

    const bytes = try encodeSidecar(alloc, source);
    defer alloc.free(bytes);

    var decoded = try decodeSidecar(alloc, bytes);
    defer decoded.deinit(alloc);

    try std.testing.expect(decoded.present);
    try std.testing.expectEqualStrings("Plan release notes", decoded.title);
    try std.testing.expectEqualStrings("Plan release notes\nship checklist", decoded.preview.?);
    try std.testing.expectEqualStrings("/tmp/origin", decoded.origin_workspace_root.?);

    var fallback = try decodeSidecarOrFallback(alloc, "{\"schema_version\":1,\"title\":42}");
    defer fallback.deinit(alloc);
    try std.testing.expect(!fallback.present);
    try std.testing.expectEqualStrings("Untitled session", fallback.title);
    try std.testing.expect(fallback.preview == null);
}

fn makeAssistantTurn(text: []const u8) session.HistoryTurn {
    return makeAssistantTurnWithImages(text, &.{});
}

fn makeAssistantTurnWithImages(text: []const u8, images: []session.ImageAttachment) session.HistoryTurn {
    return .{ .assistant = .{
        .user = .{ .text = @constCast(text), .images = images },
        .assistant = @constCast("reply"),
        .execution = .{},
    } };
}
