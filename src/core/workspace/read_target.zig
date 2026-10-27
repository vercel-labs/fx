//! How read_file splits its `path` argument (D161). A trailing selector
//! (`:N`, `:N-`, `:N-M`, `:N+K`, comma lists of those, `:raw`, or a range
//! with raw) picks lines. The rest is a web URL, an internal URL, or a
//! filesystem path that may continue into an archive member
//! (`a.zip:dir/f.txt` or `a.zip/dir/f.txt`) or a SQLite table
//! (`app.db:users`, `app.db:users:42`, `app.db?q=SELECT ...`).
//!
//! Only std is imported, so the permission checks resolve exactly the file
//! the tool opens.
const std = @import("std");
const scheme = @import("../recall/scheme.zig");

pub const max_ranges = 8;

/// Inclusive 1-based line range; a null end reads to the end.
pub const Range = struct {
    start: usize,
    end: ?usize = null,

    pub fn contains(self: Range, line: usize) bool {
        if (line < self.start) return false;
        return if (self.end) |end| line <= end else true;
    }
};

pub const Selector = struct {
    ranges: [max_ranges]Range = undefined,
    range_count: usize = 0,
    raw: bool = false,

    pub fn lines(self: *const Selector) []const Range {
        return self.ranges[0..self.range_count];
    }

    pub fn isEmpty(self: Selector) bool {
        return self.range_count == 0 and !self.raw;
    }
};

pub const Kind = enum { file, url, internal };
pub const Container = enum { none, archive, gzip, sqlite };

pub const Target = struct {
    kind: Kind,
    /// The URL, internal URL or filesystem path, without the selector, the
    /// archive member or the SQLite table.
    base: []const u8,
    selector: Selector = .{},
    container: Container = .none,
    /// The archive member, or the SQLite table spec with any `?query`.
    inner: []const u8 = "",
};

const archive_extensions = [_][]const u8{ ".tar.gz", ".tgz", ".tar", ".zip", ".jar", ".whl" };
const sqlite_extensions = [_][]const u8{ ".sqlite3", ".sqlite", ".db3", ".db" };

pub fn isWebUrl(path: []const u8) bool {
    return startsWithIgnoreCase(path, "http://") or startsWithIgnoreCase(path, "https://");
}

/// Splits `path`. Never fails: text that does not parse as a selector or a
/// container stays part of the path.
pub fn parse(path: []const u8) Target {
    const kind: Kind = if (isWebUrl(path)) .url else if (scheme.isInternalUrl(path)) .internal else .file;
    // `db:table:42` names row 42, so a SQLite target takes no line selector.
    if (kind == .file) if (splitSqlite(path)) |split| {
        return .{ .kind = .file, .base = split.base, .inner = split.inner, .container = .sqlite };
    };
    var selector: Selector = .{};
    const rest = stripSelector(path, kind, &selector);
    var target: Target = .{ .kind = kind, .base = rest, .selector = selector };
    if (kind != .file) return target;
    if (splitArchive(rest)) |split| {
        target.base = split.base;
        target.inner = split.inner;
        target.container = .archive;
        return target;
    }
    if (endsWithIgnoreCase(rest, ".gz") and !endsWithIgnoreCase(rest, ".tar.gz")) target.container = .gzip;
    return target;
}

/// The filesystem path a file target opens, for permission checks.
pub fn filesystemPath(path: []const u8) []const u8 {
    return parse(path).base;
}

/// A short row label: the host and path of a URL, `archive › member`, or
/// `db › table`. Null keeps the path as it is. Writes into `buf`.
pub fn displayLabel(buf: []u8, path: []const u8) ?[]const u8 {
    const target = parse(path);
    switch (target.kind) {
        .url => {
            const after = target.base[(std.mem.find(u8, target.base, "://") orelse return null) + 3 ..];
            const trimmed = std.mem.trimEnd(u8, after[0 .. std.mem.findAny(u8, after, "?#") orelse after.len], "/");
            return std.mem.print(buf, "{s}", .{clip(trimmed, buf.len)}) catch null;
        },
        .internal => return null,
        .file => {},
    }
    const name = std.Io.Dir.path.basename(target.base);
    return switch (target.container) {
        .archive => if (target.inner.len == 0) null else std.mem.print(buf, "{s} › {s}", .{ name, clip(target.inner, buf.len / 2) }) catch null,
        .sqlite => if (target.inner.len == 0) null else std.mem.print(buf, "{s} › {s}", .{ name, clip(target.inner, buf.len / 2) }) catch null,
        else => null,
    };
}

fn clip(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    return text[0..end];
}

fn stripSelector(path: []const u8, kind: Kind, selector: *Selector) []const u8 {
    // A colon inside a URL's authority is a port, never a selector.
    const floor: usize = switch (kind) {
        .url => blk: {
            const start = (std.mem.find(u8, path, "://") orelse 0) + 3;
            break :blk std.mem.findScalarPos(u8, path, start, '/') orelse path.len;
        },
        .internal => (std.mem.find(u8, path, "://") orelse 0) + 3,
        .file => 0,
    };
    var rest = path;
    var chunks: usize = 0;
    while (chunks < 2) : (chunks += 1) {
        const colon = std.mem.findScalarLast(u8, rest, ':') orelse break;
        if (colon < floor or colon == 0) break;
        const chunk = rest[colon + 1 ..];
        if (!selector.raw and std.ascii.eqlIgnoreCase(chunk, "raw")) {
            selector.raw = true;
        } else if (selector.range_count == 0 and parseRanges(chunk, selector)) {} else break;
        rest = rest[0..colon];
    }
    return rest;
}

/// Parses `N`, `N-`, `N-M`, `N+K` and comma lists of them into `selector`.
pub fn parseRanges(text: []const u8, selector: *Selector) bool {
    if (text.len == 0) return false;
    var parsed: [max_ranges]Range = undefined;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " ");
        if (count == max_ranges) return false;
        parsed[count] = parseRange(part) orelse return false;
        count += 1;
    }
    selector.ranges = parsed;
    selector.range_count = count;
    return true;
}

fn parseRange(part: []const u8) ?Range {
    if (part.len == 0) return null;
    if (std.mem.findScalar(u8, part, '+')) |plus| {
        const start = parsePositive(part[0..plus]) orelse return null;
        const count = parsePositive(part[plus + 1 ..]) orelse return null;
        return .{ .start = start, .end = start + count - 1 };
    }
    if (std.mem.findScalar(u8, part, '-')) |dash| {
        const start = parsePositive(part[0..dash]) orelse return null;
        if (dash + 1 == part.len) return .{ .start = start };
        const end = parsePositive(part[dash + 1 ..]) orelse return null;
        if (end < start) return null;
        return .{ .start = start, .end = end };
    }
    return .{ .start = parsePositive(part) orelse return null };
}

fn parsePositive(text: []const u8) ?usize {
    if (text.len == 0 or text.len > 9) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    const value = std.fmt.parseUnsigned(usize, text, 10) catch return null;
    return if (value == 0) null else value;
}

const Split = struct { base: []const u8, inner: []const u8 };

fn splitArchive(path: []const u8) ?Split {
    var search: usize = 0;
    while (search < path.len) {
        const sep = std.mem.findAnyPos(u8, path, search, ":/") orelse break;
        defer search = sep + 1;
        const head = path[0..sep];
        for (archive_extensions) |ext| {
            if (!endsWithIgnoreCase(head, ext) or head.len == ext.len) continue;
            return .{ .base = head, .inner = std.mem.trimStart(u8, path[sep + 1 ..], "/") };
        }
    }
    for (archive_extensions) |ext| {
        if (endsWithIgnoreCase(path, ext) and path.len > ext.len) return .{ .base = path, .inner = "" };
    }
    return null;
}

fn splitSqlite(path: []const u8) ?Split {
    for (sqlite_extensions) |ext| {
        var search: usize = 0;
        while (findIgnoreCasePos(path, search, ext)) |at| {
            defer search = at + 1;
            const end = at + ext.len;
            if (at == 0 or path[at - 1] == '/') continue;
            if (end == path.len) return .{ .base = path, .inner = "" };
            if (path[end] == ':') return .{ .base = path[0..end], .inner = path[end + 1 ..] };
            if (path[end] == '?') return .{ .base = path[0..end], .inner = path[end..] };
        }
    }
    return null;
}

fn findIgnoreCasePos(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    return text.len >= suffix.len and std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

const testing = std.testing;

test "selectors split from files, URLs and internal URLs" {
    var t = parse("src/main.zig:10-20");
    try testing.expectEqualStrings("src/main.zig", t.base);
    try testing.expectEqual(@as(usize, 1), t.selector.range_count);
    try testing.expectEqual(@as(usize, 20), t.selector.ranges[0].end.?);

    t = parse("a.txt:5+3,40-:raw");
    try testing.expectEqualStrings("a.txt", t.base);
    try testing.expect(t.selector.raw);
    try testing.expectEqual(@as(usize, 2), t.selector.range_count);
    try testing.expectEqual(@as(usize, 7), t.selector.ranges[0].end.?);
    try testing.expect(t.selector.ranges[1].end == null);

    t = parse("a.txt:raw:2-4");
    try testing.expect(t.selector.raw and t.selector.range_count == 1);

    t = parse("http://host:8080");
    try testing.expectEqual(Kind.url, t.kind);
    try testing.expectEqualStrings("http://host:8080", t.base);
    t = parse("http://host:8080/docs:5-20");
    try testing.expectEqualStrings("http://host:8080/docs", t.base);
    try testing.expectEqual(@as(usize, 5), t.selector.ranges[0].start);

    t = parse("history://w1/turn/2:3-4");
    try testing.expectEqual(Kind.internal, t.kind);
    try testing.expectEqualStrings("history://w1/turn/2", t.base);

    t = parse("notes:draft");
    try testing.expectEqualStrings("notes:draft", t.base);
    try testing.expect(t.selector.isEmpty());
    t = parse("a.txt:0-3");
    try testing.expectEqualStrings("a.txt:0-3", t.base);
}

test "archive members and sqlite tables split from the file path" {
    var t = parse("dist/bundle.zip:src/a.txt:3-4");
    try testing.expectEqual(Container.archive, t.container);
    try testing.expectEqualStrings("dist/bundle.zip", t.base);
    try testing.expectEqualStrings("src/a.txt", t.inner);
    try testing.expectEqual(@as(usize, 3), t.selector.ranges[0].start);

    t = parse("x/logs.tar.gz/var/log/app.log");
    try testing.expectEqualStrings("x/logs.tar.gz", t.base);
    try testing.expectEqualStrings("var/log/app.log", t.inner);

    t = parse("pkg.tgz");
    try testing.expectEqual(Container.archive, t.container);
    try testing.expectEqualStrings("", t.inner);

    t = parse("app.db:users:42");
    try testing.expectEqual(Container.sqlite, t.container);
    try testing.expectEqualStrings("app.db", t.base);
    try testing.expectEqualStrings("users:42", t.inner);

    t = parse("data/app.sqlite?q=SELECT 1");
    try testing.expectEqualStrings("data/app.sqlite", t.base);
    try testing.expectEqualStrings("?q=SELECT 1", t.inner);

    t = parse("server.log.gz:1-40");
    try testing.expectEqual(Container.gzip, t.container);
    try testing.expectEqualStrings("server.log.gz", t.base);

    t = parse("src/database.zig");
    try testing.expectEqual(Container.none, t.container);
    try testing.expectEqualStrings("src/database.zig", filesystemPath("src/database.zig:3"));
}

test "row labels name the host, member or table" {
    var buf: [160]u8 = undefined;
    try testing.expectEqualStrings("example.com/docs/intro", displayLabel(&buf, "https://example.com/docs/intro/?x=1").?);
    try testing.expectEqualStrings("bundle.zip › src/a.txt", displayLabel(&buf, "dist/bundle.zip:src/a.txt").?);
    try testing.expectEqualStrings("app.db › users", displayLabel(&buf, "data/app.db:users").?);
    try testing.expect(displayLabel(&buf, "src/main.zig:1-4") == null);
}
