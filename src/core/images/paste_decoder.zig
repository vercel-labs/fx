const std = @import("std");
const image_attachments = @import("image_attachments.zig");

pub const drop_classifier_max_bytes: usize = 10 * 1024 * 1024;

pub const RasterImage = struct {
    bytes: []u8,
    media_type: []const u8,

    pub fn deinit(self: RasterImage, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
    }
};

pub const UnwrapResult = union(enum) {
    raster: RasterImage,
    text: []u8,
    unchanged,

    pub fn deinit(self: UnwrapResult, alloc: std.mem.Allocator) void {
        switch (self) {
            .raster => |image| image.deinit(alloc),
            .text => |text| alloc.free(text),
            .unchanged => {},
        }
    }
};

pub fn unwrapPaste(alloc: std.mem.Allocator, bytes: []const u8) !UnwrapResult {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return .unchanged;

    if (try decodeOsc52Payload(alloc, trimmed)) |decoded| {
        var decoded_owned = true;
        defer if (decoded_owned) alloc.free(decoded);
        if (standaloneRasterMediaType(decoded)) |media_type| {
            decoded_owned = false;
            return .{ .raster = .{ .bytes = decoded, .media_type = media_type } };
        }
        if (std.unicode.utf8ValidateSlice(decoded)) {
            decoded_owned = false;
            return .{ .text = decoded };
        }
        return .unchanged;
    }

    if (try decodeDataUriImage(alloc, trimmed)) |image| {
        return .{ .raster = image };
    }

    if (standaloneRasterMediaType(trimmed)) |media_type| {
        return .{ .raster = .{
            .bytes = try alloc.dupe(u8, trimmed),
            .media_type = media_type,
        } };
    }

    return .unchanged;
}

pub fn decodeFileUrl(alloc: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const trimmed = image_attachments.stripBalancedOuterQuotes(std.mem.trim(u8, raw, " \t\r\n"));
    if (!std.ascii.startsWithIgnoreCase(trimmed, "file:")) return null;

    var rest = trimmed["file:".len..];
    if (rest.len >= 2 and rest[0] == '/' and rest[1] == '/') {
        rest = rest[2..];
        const slash = std.mem.findScalar(u8, rest, '/') orelse return null;
        const host = rest[0..slash];
        if (!(host.len == 0 or
            std.ascii.eqlIgnoreCase(host, "localhost") or
            std.mem.eql(u8, host, "127.0.0.1")))
        {
            return null;
        }
        rest = rest[slash..];
    }

    if (rest.len == 0 or rest[0] != '/') return null;
    if (std.mem.findScalar(u8, rest, '?') != null or std.mem.findScalar(u8, rest, '#') != null) {
        return null;
    }
    return percentDecodePath(alloc, rest);
}

pub fn isDropShapedPaste(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes.len >= drop_classifier_max_bytes) return false;

    var saw_path = false;
    var i: usize = 0;
    while (i < bytes.len) {
        while (i < bytes.len and image_attachments.isWhitespace(bytes[i])) : (i += 1) {}
        if (i >= bytes.len) break;
        const start = i;
        i = image_attachments.nextShellTokenEnd(bytes, start);
        if (!isDroppedPathToken(bytes[start..i])) return false;
        saw_path = true;
    }
    return saw_path;
}

pub fn hasFileUrlToken(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        while (i < bytes.len and image_attachments.isWhitespace(bytes[i])) : (i += 1) {}
        if (i >= bytes.len) break;
        const start = i;
        i = image_attachments.nextShellTokenEnd(bytes, start);
        const token = image_attachments.stripBalancedOuterQuotes(std.mem.trim(u8, bytes[start..i], " \t\r\n"));
        const path_start: usize = if (std.mem.startsWith(u8, token, "@")) 1 else 0;
        if (std.ascii.startsWithIgnoreCase(token[path_start..], "file:")) return true;
    }
    return false;
}

pub fn isUnixAbsolutePathToken(raw: []const u8) bool {
    const trimmed = image_attachments.stripBalancedOuterQuotes(std.mem.trim(u8, raw, " \t\r\n"));
    const path_start: usize = if (std.mem.startsWith(u8, trimmed, "@")) 1 else 0;
    return path_start < trimmed.len and trimmed[path_start] == '/';
}

fn isDroppedPathToken(raw: []const u8) bool {
    const trimmed = image_attachments.stripBalancedOuterQuotes(std.mem.trim(u8, raw, " \t\r\n"));
    if (trimmed.len == 0) return false;
    if (std.ascii.startsWithIgnoreCase(trimmed, "file:")) return true;
    return isUnixAbsolutePathToken(trimmed);
}

fn standaloneRasterMediaType(bytes: []const u8) ?[]const u8 {
    const media_type = image_attachments.detectMediaTypeFromBytes(bytes) orelse return null;
    if (std.mem.eql(u8, media_type, "image/png") or std.mem.eql(u8, media_type, "image/jpeg")) {
        return media_type;
    }
    if (std.unicode.utf8ValidateSlice(bytes) and isPrintableAscii(bytes)) {
        return null;
    }
    return media_type;
}

fn isPrintableAscii(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte > 0x7e) return false;
        if (byte < 0x20 and byte != '\t' and byte != '\n' and byte != '\r') return false;
    }
    return true;
}

fn decodeOsc52Payload(alloc: std.mem.Allocator, bytes: []const u8) !?[]u8 {
    const payload = osc52PayloadSlice(bytes) orelse return null;
    if (payload.len == 0 or (payload.len == 1 and payload[0] == '?')) return null;
    return decodeBase64(alloc, payload) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
}

fn osc52PayloadSlice(bytes: []const u8) ?[]const u8 {
    const prefix = osc52Prefix(bytes) orelse return null;
    const body = bytes[prefix.len..];
    const first_sep = std.mem.findScalar(u8, body, ';') orelse return null;
    var payload = body[first_sep + 1 ..];
    if (std.mem.endsWith(u8, payload, "\x1b\\")) {
        payload = payload[0 .. payload.len - 2];
    } else if (std.mem.endsWith(u8, payload, "\x07")) {
        payload = payload[0 .. payload.len - 1];
    }
    return payload;
}

fn osc52Prefix(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 5 and bytes[0] == 0x1b and bytes[1] == ']' and
        bytes[2] == '5' and bytes[3] == '2' and bytes[4] == ';')
    {
        return bytes[0..5];
    }
    if (bytes.len >= 4 and bytes[0] == ']' and
        bytes[1] == '5' and bytes[2] == '2' and bytes[3] == ';')
    {
        return bytes[0..4];
    }
    return null;
}

fn decodeDataUriImage(alloc: std.mem.Allocator, bytes: []const u8) !?RasterImage {
    if (!std.ascii.startsWithIgnoreCase(bytes, "data:image/")) return null;
    const rest = bytes["data:image/".len..];
    const sep = std.mem.find(u8, rest, ";base64,") orelse return null;
    const subtype = rest[0..sep];
    const payload = rest[sep + ";base64,".len ..];
    if (!isSupportedDataUriSubtype(subtype) or payload.len == 0) return null;

    const decoded = decodeBase64(alloc, payload) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    errdefer alloc.free(decoded);

    const media_type = image_attachments.detectMediaTypeFromBytes(decoded) orelse {
        alloc.free(decoded);
        return null;
    };
    return .{ .bytes = decoded, .media_type = media_type };
}

fn isSupportedDataUriSubtype(subtype: []const u8) bool {
    return std.ascii.eqlIgnoreCase(subtype, "png") or
        std.ascii.eqlIgnoreCase(subtype, "jpeg") or
        std.ascii.eqlIgnoreCase(subtype, "jpg") or
        std.ascii.eqlIgnoreCase(subtype, "gif") or
        std.ascii.eqlIgnoreCase(subtype, "webp");
}

fn decodeBase64(alloc: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(alloc);
    try compact.ensureTotalCapacity(alloc, encoded.len);
    for (encoded) |byte| {
        if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') continue;
        try compact.append(alloc, byte);
    }
    if (compact.items.len == 0) return error.InvalidBase64;

    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(compact.items) catch return error.InvalidBase64;
    if (decoded_len > image_attachments.max_image_bytes) return error.ImageTooLarge;
    const decoded = try alloc.alloc(u8, decoded_len);
    errdefer alloc.free(decoded);
    decoder.decode(decoded, compact.items) catch {
        return error.InvalidBase64;
    };
    return decoded;
}

fn percentDecodePath(alloc: std.mem.Allocator, path: []const u8) !?[]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    var keep_output = false;
    defer if (!keep_output) out.deinit();

    var i: usize = 0;
    while (i < path.len) {
        const byte = path[i];
        if (byte == 0) return null;
        if (byte == '%') {
            if (i + 3 > path.len) return null;
            const value = std.fmt.parseInt(u8, path[i + 1 .. i + 3], 16) catch return null;
            if (value == 0) return null;
            try out.writer.writeByte(value);
            i += 3;
            continue;
        }
        try out.writer.writeByte(byte);
        i += 1;
    }

    const decoded = try out.toOwnedSlice();
    keep_output = true;
    if (decoded.len == 0 or decoded[0] != '/') {
        alloc.free(decoded);
        return null;
    }
    return decoded;
}

const png_magic = "\x89PNG\r\n\x1a\n";
const jpeg_magic = "\xff\xd8\xff";

fn encodeBase64(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const buf = try alloc.alloc(u8, encoder.calcSize(bytes.len));
    const encoded = encoder.encode(buf, bytes);
    std.debug.assert(encoded.ptr == buf.ptr);
    return buf[0..encoded.len];
}

test "unwrapPaste decodes raw png and jpeg magic as raster" {
    const alloc = std.testing.allocator;
    {
        const result = try unwrapPaste(alloc, png_magic ++ "rest");
        defer result.deinit(alloc);
        try std.testing.expectEqualStrings("image/png", result.raster.media_type);
        try std.testing.expectEqualSlices(u8, png_magic ++ "rest", result.raster.bytes);
    }
    {
        const result = try unwrapPaste(alloc, jpeg_magic ++ "rest");
        defer result.deinit(alloc);
        try std.testing.expectEqualStrings("image/jpeg", result.raster.media_type);
    }
}

test "unwrapPaste does not treat gif or webp captions as rasters" {
    const alloc = std.testing.allocator;
    {
        const result = try unwrapPaste(alloc, "GIF89a is a joke");
        defer result.deinit(alloc);
        try std.testing.expect(result == .unchanged);
    }
    {
        const result = try unwrapPaste(alloc, "RIFFxxxxWEBPrest");
        defer result.deinit(alloc);
        try std.testing.expect(result == .unchanged);
    }
}

test "unwrapPaste decodes data URI images as vision rasters" {
    const alloc = std.testing.allocator;
    const encoded = try encodeBase64(alloc, png_magic ++ "payload");
    defer alloc.free(encoded);
    const uri = try std.fmt.allocPrint(alloc, "data:image/png;base64,{s}", .{encoded});
    defer alloc.free(uri);

    const result = try unwrapPaste(alloc, uri);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("image/png", result.raster.media_type);
    try std.testing.expectEqualSlices(u8, png_magic ++ "payload", result.raster.bytes);
}

test "unwrapPaste decodes OSC 52 image payloads and ignores query frames" {
    const alloc = std.testing.allocator;
    const encoded = try encodeBase64(alloc, png_magic ++ "osc");
    defer alloc.free(encoded);
    const sequence = try std.fmt.allocPrint(alloc, "\x1b]52;c;{s}\x07", .{encoded});
    defer alloc.free(sequence);

    const result = try unwrapPaste(alloc, sequence);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("image/png", result.raster.media_type);
    try std.testing.expectEqualSlices(u8, png_magic ++ "osc", result.raster.bytes);

    const query = try unwrapPaste(alloc, "\x1b]52;c;?\x07");
    defer query.deinit(alloc);
    try std.testing.expect(query == .unchanged);
}

test "unwrapPaste decodes OSC 52 utf8 clipboard text" {
    const alloc = std.testing.allocator;
    const encoded = try encodeBase64(alloc, "hello from clipboard");
    defer alloc.free(encoded);
    const sequence = try std.fmt.allocPrint(alloc, "\x1b]52;c;{s}\x1b\\", .{encoded});
    defer alloc.free(sequence);

    const result = try unwrapPaste(alloc, sequence);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("hello from clipboard", result.text);
}

test "decodeFileUrl percent-decodes local paths and rejects unsafe urls" {
    const alloc = std.testing.allocator;
    {
        const path = try decodeFileUrl(alloc, "file:///tmp/CleanShot%202026.png");
        defer alloc.free(path.?);
        try std.testing.expectEqualStrings("/tmp/CleanShot 2026.png", path.?);
    }
    {
        const path = try decodeFileUrl(alloc, "file://localhost/tmp/photo.jpg");
        defer alloc.free(path.?);
        try std.testing.expectEqualStrings("/tmp/photo.jpg", path.?);
    }
    try std.testing.expect(try decodeFileUrl(alloc, "file://remote.example/tmp/a.png") == null);
    try std.testing.expect(try decodeFileUrl(alloc, "file:///tmp/a.png?rev=1") == null);
    try std.testing.expect(try decodeFileUrl(alloc, "file:///tmp/a.png#frag") == null);
    try std.testing.expect(try decodeFileUrl(alloc, "file:///tmp/%00secret.png") == null);
    try std.testing.expect(try decodeFileUrl(alloc, "/tmp/plain.png") == null);
}

test "drop-shaped paste is file urls or absolute paths only" {
    try std.testing.expect(isDropShapedPaste("file:///tmp/a.png"));
    try std.testing.expect(isDropShapedPaste("file:///tmp/a.png\nfile:///tmp/notes.txt"));
    try std.testing.expect(isDropShapedPaste("/tmp/a.png /tmp/b.txt"));
    try std.testing.expect(!isDropShapedPaste("inspect /tmp/a.png please"));
    try std.testing.expect(!isDropShapedPaste(""));
    try std.testing.expect(hasFileUrlToken("see file:///tmp/a.png later"));
    try std.testing.expect(!hasFileUrlToken("/tmp/a.png"));
}
