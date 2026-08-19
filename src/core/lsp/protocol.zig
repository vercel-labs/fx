const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Severity = enum(u8) {
    err = 1,
    warning = 2,
    information = 3,
    hint = 4,

    pub fn fromInt(value: i64) Severity {
        return switch (value) {
            1 => .err,
            2 => .warning,
            3 => .information,
            4 => .hint,
            else => .err,
        };
    }

    pub fn marker(self: Severity) []const u8 {
        return switch (self) {
            .err => "E",
            .warning => "W",
            .information => "I",
            .hint => "H",
        };
    }

    pub fn worse(self: Severity, other: Severity) Severity {
        return if (@intFromEnum(self) <= @intFromEnum(other)) self else other;
    }
};

pub const Diagnostic = struct {
    uri: []u8,
    line: u32,
    character: u32,
    end_line: u32,
    end_character: u32,
    severity: Severity,
    message: []u8,

    pub fn deinit(self: Diagnostic, alloc: Allocator) void {
        alloc.free(self.uri);
        alloc.free(self.message);
    }
};

pub const Location = struct {
    uri: []u8,
    line: u32,
    character: u32,

    pub fn deinit(self: Location, alloc: Allocator) void {
        alloc.free(self.uri);
    }
};

pub const PublishDiagnostics = struct {
    uri: []u8,
    diagnostics: []Diagnostic,

    pub fn deinit(self: PublishDiagnostics, alloc: Allocator) void {
        for (self.diagnostics) |item| item.deinit(alloc);
        if (self.diagnostics.len > 0) alloc.free(self.diagnostics);
        alloc.free(self.uri);
    }
};

pub fn fileUriFromPath(alloc: Allocator, path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("file://");
    if (path.len == 0 or path[0] != '/') try out.writer.writeByte('/');
    for (path) |byte| {
        if (isUriSafe(byte)) {
            try out.writer.writeByte(byte);
        } else {
            try out.writer.print("%{X:0>2}", .{byte});
        }
    }
    return out.toOwnedSlice();
}

pub fn pathFromFileUri(uri: []const u8) ?[]const u8 {
    var rest = uri;
    if (std.mem.startsWith(u8, rest, "file://")) {
        rest = rest["file://".len..];
    } else {
        return if (rest.len > 0) rest else null;
    }
    if (std.mem.startsWith(u8, rest, "localhost")) rest = rest["localhost".len..];
    if (rest.len == 0) return null;
    return rest;
}

pub fn decodeUriPath(alloc: Allocator, uri: []const u8) ![]u8 {
    const raw = pathFromFileUri(uri) orelse return error.InvalidUri;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var index: usize = 0;
    while (index < raw.len) {
        if (raw[index] == '%' and index + 2 < raw.len) {
            const value = std.fmt.parseInt(u8, raw[index + 1 .. index + 3], 16) catch {
                try out.append(alloc, raw[index]);
                index += 1;
                continue;
            };
            try out.append(alloc, value);
            index += 3;
            continue;
        }
        try out.append(alloc, raw[index]);
        index += 1;
    }
    return out.toOwnedSlice(alloc);
}

pub fn languageIdForPath(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    if (std.ascii.eqlIgnoreCase(basename, "dockerfile")) return "dockerfile";
    if (std.ascii.eqlIgnoreCase(basename, "makefile")) return "makefile";
    const ext = std.fs.path.extension(basename);
    if (ext.len <= 1) return "plaintext";
    const label = ext[1..];
    if (std.ascii.eqlIgnoreCase(label, "ts") or std.ascii.eqlIgnoreCase(label, "tsx")) return "typescript";
    if (std.ascii.eqlIgnoreCase(label, "js") or std.ascii.eqlIgnoreCase(label, "jsx") or
        std.ascii.eqlIgnoreCase(label, "mjs") or std.ascii.eqlIgnoreCase(label, "cjs"))
        return "javascript";
    if (std.ascii.eqlIgnoreCase(label, "py")) return "python";
    if (std.ascii.eqlIgnoreCase(label, "rs")) return "rust";
    if (std.ascii.eqlIgnoreCase(label, "go")) return "go";
    if (std.ascii.eqlIgnoreCase(label, "zig")) return "zig";
    if (std.ascii.eqlIgnoreCase(label, "c") or std.ascii.eqlIgnoreCase(label, "h")) return "c";
    if (std.ascii.eqlIgnoreCase(label, "cc") or std.ascii.eqlIgnoreCase(label, "cpp") or
        std.ascii.eqlIgnoreCase(label, "cxx") or std.ascii.eqlIgnoreCase(label, "hpp"))
        return "cpp";
    if (std.ascii.eqlIgnoreCase(label, "lua")) return "lua";
    if (std.ascii.eqlIgnoreCase(label, "json")) return "json";
    if (std.ascii.eqlIgnoreCase(label, "md")) return "markdown";
    return label;
}

pub fn parsePublishDiagnostics(alloc: Allocator, body: []const u8) !?PublishDiagnostics {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();
    const object = asObject(parsed.value) orelse return null;
    const method = asString(object.get("method")) orelse return null;
    if (!std.mem.eql(u8, method, "textDocument/publishDiagnostics")) return null;
    const params = asObject(object.get("params")) orelse return null;
    const uri = asString(params.get("uri")) orelse return null;
    const list = asArray(params.get("diagnostics")) orelse return null;
    const uri_copy = try alloc.dupe(u8, uri);
    errdefer alloc.free(uri_copy);
    var items: std.ArrayList(Diagnostic) = .empty;
    errdefer {
        for (items.items) |item| item.deinit(alloc);
        items.deinit(alloc);
    }
    for (list.items) |entry| {
        const diagnostic = try parseDiagnostic(alloc, uri_copy, entry) orelse continue;
        try items.append(alloc, diagnostic);
    }
    return .{
        .uri = uri_copy,
        .diagnostics = try items.toOwnedSlice(alloc),
    };
}

pub fn parseDefinitionResult(alloc: Allocator, body: []const u8) !?Location {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();
    const object = asObject(parsed.value) orelse return null;
    const result = object.get("result") orelse return null;
    return parseLocationValue(alloc, result);
}

pub fn parseRequestId(value: ?std.json.Value) ?i64 {
    return asInt(value);
}

const Range = struct {
    line: u32,
    character: u32,
    end_line: u32,
    end_character: u32,
};

fn parseDiagnostic(alloc: Allocator, uri: []const u8, value: std.json.Value) !?Diagnostic {
    const object = asObject(value) orelse return null;
    const message = asString(object.get("message")) orelse return null;
    const range = parseRange(object.get("range")) orelse Range{
        .line = 0,
        .character = 0,
        .end_line = 0,
        .end_character = 0,
    };
    const severity = if (asInt(object.get("severity"))) |number|
        Severity.fromInt(number)
    else
        .err;
    return .{
        .uri = try alloc.dupe(u8, uri),
        .line = range.line,
        .character = range.character,
        .end_line = range.end_line,
        .end_character = range.end_character,
        .severity = severity,
        .message = try alloc.dupe(u8, message),
    };
}

fn parseRange(value: ?std.json.Value) ?Range {
    const object = asObject(value) orelse return null;
    const start = asObject(object.get("start")) orelse return null;
    const end = asObject(object.get("end")) orelse start;
    return .{
        .line = intToU32(asInt(start.get("line")) orelse 0),
        .character = intToU32(asInt(start.get("character")) orelse 0),
        .end_line = intToU32(asInt(end.get("line")) orelse 0),
        .end_character = intToU32(asInt(end.get("character")) orelse 0),
    };
}

fn parseLocationValue(alloc: Allocator, value: std.json.Value) !?Location {
    switch (value) {
        .null => return null,
        .array => |array| {
            for (array.items) |item| {
                if (try parseOneLocation(alloc, item)) |location| return location;
            }
            return null;
        },
        .object => return parseOneLocation(alloc, value),
        else => return null,
    }
}

fn parseOneLocation(alloc: Allocator, value: std.json.Value) !?Location {
    const object = asObject(value) orelse return null;
    if (asString(object.get("uri")) orelse asString(object.get("targetUri"))) |uri| {
        const range = parseRange(object.get("range")) orelse
            parseRange(object.get("targetSelectionRange")) orelse
            parseRange(object.get("targetRange")) orelse
            Range{ .line = 0, .character = 0, .end_line = 0, .end_character = 0 };
        return .{
            .uri = try alloc.dupe(u8, uri),
            .line = range.line,
            .character = range.character,
        };
    }
    return null;
}

fn asObject(value: ?std.json.Value) ?std.json.ObjectMap {
    const present = value orelse return null;
    return switch (present) {
        .object => |object| object,
        else => null,
    };
}

fn asArray(value: ?std.json.Value) ?std.json.Array {
    const present = value orelse return null;
    return switch (present) {
        .array => |array| array,
        else => null,
    };
}

fn asString(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}

fn asInt(value: ?std.json.Value) ?i64 {
    const present = value orelse return null;
    return switch (present) {
        .integer => |number| number,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        .float => |number| blk: {
            if (number != @trunc(number)) break :blk null;
            if (number > @as(f64, @floatFromInt(std.math.maxInt(i64))) or
                number < @as(f64, @floatFromInt(std.math.minInt(i64))))
                break :blk null;
            break :blk @intFromFloat(number);
        },
        else => null,
    };
}

fn intToU32(value: i64) u32 {
    if (value <= 0) return 0;
    return std.math.cast(u32, value) orelse std.math.maxInt(u32);
}

fn isUriSafe(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '-', '_', '.', '~', '/' => true,
        else => false,
    };
}

test "file uri round-trips absolute unix paths" {
    const alloc = std.testing.allocator;
    const uri = try fileUriFromPath(alloc, "/tmp/demo file.zig");
    defer alloc.free(uri);
    try std.testing.expectEqualStrings("file:///tmp/demo%20file.zig", uri);
    const path = try decodeUriPath(alloc, uri);
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/tmp/demo file.zig", path);
}

test "parsePublishDiagnostics reads severity range and message" {
    const alloc = std.testing.allocator;
    const body =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///tmp/a.zig","diagnostics":[{"range":{"start":{"line":2,"character":4},"end":{"line":2,"character":8}},"severity":2,"message":"unused"}]}}
    ;
    const parsed = (try parsePublishDiagnostics(alloc, body)) orelse return error.TestExpectedEqual;
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("file:///tmp/a.zig", parsed.uri);
    try std.testing.expectEqual(@as(usize, 1), parsed.diagnostics.len);
    try std.testing.expectEqual(@as(u32, 2), parsed.diagnostics[0].line);
    try std.testing.expectEqual(@as(u32, 4), parsed.diagnostics[0].character);
    try std.testing.expectEqual(Severity.warning, parsed.diagnostics[0].severity);
    try std.testing.expectEqualStrings("unused", parsed.diagnostics[0].message);
}

test "parseDefinitionResult accepts Location array and LocationLink" {
    const alloc = std.testing.allocator;
    const array_body =
        \\{"jsonrpc":"2.0","id":2,"result":[{"uri":"file:///tmp/b.zig","range":{"start":{"line":9,"character":1},"end":{"line":9,"character":4}}}]}
    ;
    const array = (try parseDefinitionResult(alloc, array_body)) orelse return error.TestExpectedEqual;
    defer array.deinit(alloc);
    try std.testing.expectEqualStrings("file:///tmp/b.zig", array.uri);
    try std.testing.expectEqual(@as(u32, 9), array.line);

    const link_body =
        \\{"jsonrpc":"2.0","id":3,"result":{"targetUri":"file:///tmp/c.zig","targetSelectionRange":{"start":{"line":1,"character":0},"end":{"line":1,"character":2}}}}
    ;
    const link = (try parseDefinitionResult(alloc, link_body)) orelse return error.TestExpectedEqual;
    defer link.deinit(alloc);
    try std.testing.expectEqualStrings("file:///tmp/c.zig", link.uri);
    try std.testing.expectEqual(@as(u32, 1), link.line);

    const empty_body = "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":null}";
    try std.testing.expect((try parseDefinitionResult(alloc, empty_body)) == null);
}

test "languageIdForPath maps common extensions" {
    try std.testing.expectEqualStrings("zig", languageIdForPath("src/main.zig"));
    try std.testing.expectEqualStrings("typescript", languageIdForPath("app.tsx"));
    try std.testing.expectEqualStrings("python", languageIdForPath("lib.py"));
    try std.testing.expectEqualStrings("plaintext", languageIdForPath("LICENSE"));
}
