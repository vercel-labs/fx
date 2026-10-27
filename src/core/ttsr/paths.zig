//! Target paths and globs for rule conditions.
//!
//! A tool call names its files in whatever spelling the model typed:
//! `src/a.ts`, `./src/a.ts`, `/home/me/proj/src/a.ts`. Each raw path is
//! resolved once against the session directory into the spellings a
//! condition may test. `under:` and `outside:` use the absolute form.
const std = @import("std");

const Allocator = std.mem.Allocator;
const path = std.Io.Dir.path;

pub const Target = struct {
    /// As the tool spelled it, with forward slashes.
    raw: []const u8,
    /// Null for scheme URIs such as `https://`.
    absolute: ?[]const u8 = null,
    /// Null when the path escapes the session directory.
    relative: ?[]const u8 = null,
};

/// Resolves `file_paths` against `cwd`; `home` expands a leading `~`.
/// Memory comes from `arena`.
pub fn resolveTargets(arena: Allocator, file_paths: []const []const u8, cwd: []const u8, home: ?[]const u8) ![]Target {
    var targets: std.ArrayList(Target) = .empty;
    outer: for (file_paths) |file_path| {
        const raw = try slashes(arena, std.mem.trim(u8, file_path, " \t\r\n"));
        if (raw.len == 0) continue;
        for (targets.items) |seen| if (std.mem.eql(u8, seen.raw, raw)) continue :outer;
        if (hasScheme(raw)) {
            try targets.append(arena, .{ .raw = raw });
            continue;
        }
        const absolute = try resolveUnder(arena, cwd, raw, home);
        const relative = try path.relativeAlloc(arena, cwd, null, cwd, absolute);
        const inside = relative.len > 0 and !std.mem.eql(u8, relative, "..") and
            !std.mem.startsWith(u8, relative, "../") and !path.isAbsolute(relative);
        try targets.append(arena, .{ .raw = raw, .absolute = absolute, .relative = if (inside) relative else null });
    }
    return targets.toOwnedSlice(arena);
}

/// Resolves an `under:` or `outside:` directory. `cwd` names the session
/// directory; `~` the home directory.
pub fn resolveRoot(arena: Allocator, root: []const u8, cwd: []const u8, home: ?[]const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, root, " ");
    if (std.mem.eql(u8, trimmed, "cwd")) return path.resolveAlloc(arena, &.{cwd});
    return resolveUnder(arena, cwd, try slashes(arena, trimmed), home);
}

fn resolveUnder(arena: Allocator, cwd: []const u8, raw: []const u8, home: ?[]const u8) ![]const u8 {
    if (home) |h| {
        if (std.mem.eql(u8, raw, "~")) return path.resolveAlloc(arena, &.{h});
        if (std.mem.startsWith(u8, raw, "~/")) return path.resolveAlloc(arena, &.{ h, raw[2..] });
    }
    return path.resolveAlloc(arena, &.{ cwd, raw });
}

fn slashes(arena: Allocator, value: []const u8) ![]const u8 {
    if (std.mem.findScalar(u8, value, '\\') == null) return value;
    const copy = try arena.dupe(u8, value);
    std.mem.replaceScalar(u8, copy, '\\', '/');
    return copy;
}

fn hasScheme(raw: []const u8) bool {
    const colon = std.mem.find(u8, raw, "://") orelse return false;
    if (colon == 0 or !std.ascii.isAlphabetic(raw[0])) return false;
    for (raw[0..colon]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '.' and c != '-') return false;
    }
    return true;
}

pub fn isUnderRoot(absolute: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, absolute, root)) return true;
    const trimmed = std.mem.trimEnd(u8, root, "/");
    return absolute.len > trimmed.len and std.mem.startsWith(u8, absolute, trimmed) and absolute[trimmed.len] == '/';
}

/// Whether `glob` matches any spelling of `target`, or its basename.
pub fn matchesTarget(glob: []const u8, target: Target) bool {
    if (globMatch(glob, target.raw)) return true;
    if (target.relative) |relative| if (globMatch(glob, relative)) return true;
    if (target.absolute) |absolute| if (globMatch(glob, absolute)) return true;
    const slash = std.mem.findScalarLast(u8, target.raw, '/') orelse return false;
    return globMatch(glob, target.raw[slash + 1 ..]);
}

pub fn matchesAny(glob: []const u8, targets: []const Target) bool {
    for (targets) |target| if (matchesTarget(glob, target)) return true;
    return false;
}

/// The extension of the first path that has one, lowercased into `buf`.
pub fn deriveLang(buf: []u8, file_paths: []const []const u8) ?[]const u8 {
    for (file_paths) |file_path| {
        const base_start = if (std.mem.findAny(u8, file_path, "/\\")) |_| (std.mem.findScalarLast(u8, file_path, '/') orelse std.mem.findScalarLast(u8, file_path, '\\').?) + 1 else 0;
        const base = file_path[base_start..];
        const dot = std.mem.findScalarLast(u8, base, '.') orelse continue;
        if (dot == 0 or dot + 1 >= base.len) continue;
        const ext = base[dot + 1 ..];
        if (ext.len > buf.len) continue;
        return std.ascii.lowerString(buf[0..ext.len], ext);
    }
    return null;
}

/// Glob matching with `*` (not across `/`), `**` (any depth), `?`,
/// `[abc]`/`[!a-z]` classes and `{a,b}` alternatives.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    if (std.mem.findScalar(u8, pattern, '{')) |open| {
        var depth: usize = 0;
        var close: ?usize = null;
        for (pattern[open..], open..) |c, i| {
            if (c == '{') depth += 1;
            if (c == '}') {
                depth -= 1;
                if (depth == 0) {
                    close = i;
                    break;
                }
            }
        }
        const end = close orelse return matchSimple(pattern, text);
        var buf: [512]u8 = undefined;
        var start = open + 1;
        var level: usize = 0;
        var i = open + 1;
        while (i <= end) : (i += 1) {
            const c = pattern[i];
            if (c == '{') level += 1;
            if ((c == ',' and level == 0) or i == end) {
                const option = pattern[start..i];
                const total = open + option.len + (pattern.len - end - 1);
                if (total <= buf.len) {
                    @memcpy(buf[0..open], pattern[0..open]);
                    @memcpy(buf[open .. open + option.len], option);
                    @memcpy(buf[open + option.len .. total], pattern[end + 1 ..]);
                    if (globMatch(buf[0..total], text)) return true;
                }
                start = i + 1;
            }
            if (c == '}' and i != end) level -= 1;
        }
        return false;
    }
    return matchSimple(pattern, text);
}

fn matchSimple(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    while (p < pattern.len) {
        const c = pattern[p];
        if (c == '*') {
            const double = p + 1 < pattern.len and pattern[p + 1] == '*';
            if (double) {
                var rest = pattern[p + 2 ..];
                // `**/` also matches no directory at all.
                if (rest.len > 0 and rest[0] == '/') {
                    if (matchSimple(rest[1..], text[t..])) return true;
                    rest = rest[0..];
                }
                var k = t;
                while (k <= text.len) : (k += 1) {
                    if (matchSimple(rest, text[k..])) return true;
                }
                return false;
            }
            var k = t;
            while (k <= text.len) : (k += 1) {
                if (matchSimple(pattern[p + 1 ..], text[k..])) return true;
                if (k < text.len and text[k] == '/') break;
            }
            return false;
        }
        if (t >= text.len) return false;
        switch (c) {
            '?' => if (text[t] == '/') return false,
            '[' => {
                const close = std.mem.findScalarPos(u8, pattern, p + 1, ']') orelse return false;
                var body = pattern[p + 1 .. close];
                const negate = body.len > 0 and (body[0] == '!' or body[0] == '^');
                if (negate) body = body[1..];
                var hit = false;
                var i: usize = 0;
                while (i < body.len) : (i += 1) {
                    if (i + 2 < body.len and body[i + 1] == '-') {
                        if (text[t] >= body[i] and text[t] <= body[i + 2]) hit = true;
                        i += 2;
                    } else if (body[i] == text[t]) hit = true;
                }
                if (hit == negate) return false;
                p = close;
            },
            '\\' => {
                p += 1;
                if (p >= pattern.len or pattern[p] != text[t]) return false;
            },
            else => if (c != text[t]) return false,
        }
        p += 1;
        t += 1;
    }
    return t == text.len;
}

test "glob matches stars, globstars, classes and alternatives" {
    try std.testing.expect(globMatch("*.ts", "a.ts"));
    try std.testing.expect(!globMatch("*.ts", "src/a.ts"));
    try std.testing.expect(globMatch("**/*.ts", "a.ts"));
    try std.testing.expect(globMatch("**/*.ts", "src/deep/a.ts"));
    try std.testing.expect(globMatch("src/**", "src/a/b.go"));
    try std.testing.expect(globMatch("*.{ts,tsx}", "a.tsx"));
    try std.testing.expect(!globMatch("*.{ts,tsx}", "a.js"));
    try std.testing.expect(globMatch("[ab]?.py", "bx.py"));
    try std.testing.expect(!globMatch("[!ab]?.py", "bx.py"));
}

test "targets resolve spellings and containment against the session directory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const targets = try resolveTargets(arena, &.{ "./src/a.ts", "/elsewhere/b.ts", "https://x.dev/c", "~/notes.md", "./src/a.ts" }, "/work/proj", "/home/me");
    try std.testing.expectEqual(@as(usize, 4), targets.len);
    try std.testing.expectEqualStrings("/work/proj/src/a.ts", targets[0].absolute.?);
    try std.testing.expectEqualStrings("src/a.ts", targets[0].relative.?);
    try std.testing.expect(targets[1].relative == null);
    try std.testing.expect(targets[2].absolute == null);
    try std.testing.expectEqualStrings("/home/me/notes.md", targets[3].absolute.?);
    try std.testing.expect(matchesTarget("src/*.ts", targets[0]));
    try std.testing.expect(matchesTarget("a.ts", targets[0]));
    try std.testing.expect(isUnderRoot("/work/proj/src/a.ts", try resolveRoot(arena, "cwd", "/work/proj", null)));
    try std.testing.expect(!isUnderRoot("/work/project/a.ts", "/work/proj"));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("tsx", deriveLang(&buf, &.{ "Makefile", "src/App.TSX" }).?);
}
