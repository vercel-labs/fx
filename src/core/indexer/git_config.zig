//! Git config files read as text, never through git. The parser follows git's
//! config.c syntax: sections, quoted subsections, value quoting and escapes,
//! line continuations, comments and implicit booleans. The loader follows
//! `include.path` and `includeIf` like git, in one of two modes:
//!
//! - `values` evaluates `gitdir:`, `gitdir/i:` and `onbranch:` conditions to
//!   read settings, and treats `hasconfig:` as unmatched with a trace, an
//!   accepted parity limitation;
//! - `every_include` counts every `includeIf` as included, for callers that
//!   must over-approximate, such as finding filter drivers to disable.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const bounded_read = @import("bounded_read.zig");
const layout_mod = @import("layout.zig");
const wildmatch = @import("wildmatch.zig");

const Allocator = std.mem.Allocator;

const max_config_file_bytes: usize = 1024 * 1024;
const max_include_depth: usize = 10;

pub const Entry = struct {
    /// Lowercase.
    section: []const u8,
    /// Exact for `[section "sub"]`; lowercase for legacy `[section.sub]`.
    subsection: ?[]const u8,
    /// Lowercase.
    name: []const u8,
    /// Null when the line has no `=`, which git reads as boolean true.
    value: ?[]const u8,
};

pub const ParseError = error{ OutOfMemory, InvalidConfig };

const Reader = struct {
    text: []const u8,
    pos: usize = 0,
    eof: bool = false,

    /// git's get_next_char: folds CRLF to LF and reports EOF as LF.
    fn next(self: *Reader) u8 {
        if (self.pos >= self.text.len) {
            self.eof = true;
            return '\n';
        }
        const c = self.text[self.pos];
        self.pos += 1;
        if (c == '\r' and self.pos < self.text.len and self.text[self.pos] == '\n') {
            self.pos += 1;
            return '\n';
        }
        return c;
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-';
}

/// Parses config `text`. Memory belongs to `arena`. Malformed input is
/// `error.InvalidConfig`, as git refuses the whole file.
pub fn parse(arena: Allocator, text: []const u8) ParseError![]Entry {
    var reader: Reader = .{ .text = text };
    if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) reader.pos = 3;
    var entries: std.ArrayList(Entry) = .empty;
    var section: ?[]const u8 = null;
    var subsection: ?[]const u8 = null;
    var comment = false;
    while (true) {
        const c = reader.next();
        if (c == '\n') {
            if (reader.eof) break;
            comment = false;
            continue;
        }
        if (comment or isSpace(c)) continue;
        if (c == '#' or c == ';') {
            comment = true;
            continue;
        }
        if (c == '[') {
            const header = try parseHeader(arena, &reader);
            section = header.section;
            subsection = header.subsection;
            continue;
        }
        if (!std.ascii.isAlphabetic(c)) return error.InvalidConfig;
        const current_section = section orelse return error.InvalidConfig;

        var name: std.ArrayList(u8) = .empty;
        try name.append(arena, std.ascii.toLower(c));
        var ch: u8 = undefined;
        while (true) {
            ch = reader.next();
            if (reader.eof or !isKeyChar(ch)) break;
            try name.append(arena, std.ascii.toLower(ch));
        }
        while (ch == ' ' or ch == '\t') ch = reader.next();
        var value: ?[]const u8 = null;
        if (ch != '\n') {
            if (ch != '=') return error.InvalidConfig;
            value = try parseValue(arena, &reader);
        }
        try entries.append(arena, .{
            .section = current_section,
            .subsection = subsection,
            .name = try name.toOwnedSlice(arena),
            .value = value,
        });
    }
    return entries.toOwnedSlice(arena);
}

const Header = struct { section: []const u8, subsection: ?[]const u8 };

/// git's get_base_var and get_extended_base_var.
fn parseHeader(arena: Allocator, reader: *Reader) ParseError!Header {
    var base: std.ArrayList(u8) = .empty;
    var quoted: ?[]const u8 = null;
    while (true) {
        const c = reader.next();
        if (reader.eof) return error.InvalidConfig;
        if (c == ']') break;
        if (isSpace(c)) {
            var ch = c;
            while (true) {
                if (ch == '\n') return error.InvalidConfig;
                ch = reader.next();
                if (!isSpace(ch)) break;
            }
            if (ch != '"') return error.InvalidConfig;
            var sub: std.ArrayList(u8) = .empty;
            while (true) {
                var q = reader.next();
                if (q == '\n') return error.InvalidConfig;
                if (q == '"') break;
                if (q == '\\') {
                    q = reader.next();
                    if (q == '\n') return error.InvalidConfig;
                }
                try sub.append(arena, q);
            }
            if (reader.next() != ']') return error.InvalidConfig;
            quoted = try sub.toOwnedSlice(arena);
            break;
        }
        if (!isKeyChar(c) and c != '.') return error.InvalidConfig;
        try base.append(arena, std.ascii.toLower(c));
    }
    if (base.items.len == 0) return error.InvalidConfig;
    const dot = std.mem.findScalar(u8, base.items, '.');
    const section = if (dot) |i| base.items[0..i] else base.items;
    if (section.len == 0) return error.InvalidConfig;
    const dotted_rest: ?[]const u8 = if (dot) |i| base.items[i + 1 ..] else null;
    const subsection: ?[]const u8 = if (quoted) |q|
        (if (dotted_rest) |rest| try std.mem.concat(arena, u8, &.{ rest, ".", q }) else q)
    else
        dotted_rest;
    return .{ .section = section, .subsection = subsection };
}

/// git's parse_value: quotes toggle, `\t \b \n \\ \"` escape, a backslash at
/// line end continues the value, unquoted `#` or `;` starts a comment, and
/// unquoted trailing whitespace is dropped.
fn parseValue(arena: Allocator, reader: *Reader) ParseError![]const u8 {
    var value: std.ArrayList(u8) = .empty;
    var quote = false;
    var comment = false;
    var trim_len: usize = 0;
    while (true) {
        var c = reader.next();
        if (c == '\n') {
            if (quote) return error.InvalidConfig;
            if (trim_len != 0) value.shrinkRetainingCapacity(trim_len);
            return value.toOwnedSlice(arena);
        }
        if (comment) continue;
        if (isSpace(c) and !quote) {
            if (trim_len == 0) trim_len = value.items.len;
            if (value.items.len != 0) try value.append(arena, c);
            continue;
        }
        if (!quote and (c == ';' or c == '#')) {
            comment = true;
            continue;
        }
        trim_len = 0;
        if (c == '\\') {
            c = reader.next();
            switch (c) {
                '\n' => continue,
                't' => c = '\t',
                'b' => c = 0x08,
                'n' => c = '\n',
                '\\', '"' => {},
                else => return error.InvalidConfig,
            }
            try value.append(arena, c);
            continue;
        }
        if (c == '"') {
            quote = !quote;
            continue;
        }
        try value.append(arena, c);
    }
}

/// git's git_config_bool. Null for a value git rejects.
fn parseBool(value: ?[]const u8) ?bool {
    const v = value orelse return true;
    if (v.len == 0) return false;
    for ([_][]const u8{ "true", "yes", "on" }) |word| {
        if (std.ascii.eqlIgnoreCase(v, word)) return true;
    }
    for ([_][]const u8{ "false", "no", "off" }) |word| {
        if (std.ascii.eqlIgnoreCase(v, word)) return false;
    }
    const number = std.fmt.parseInt(i64, v, 10) catch return null;
    return number != 0;
}

pub const Scope = enum { system, global, local, worktree };

pub const Mode = enum { values, every_include };

pub const LoadedEntry = struct {
    entry: Entry,
    scope: Scope,
};

pub const Unavailable = struct {
    path: []const u8,
    /// Static string.
    reason: []const u8,
};

pub const Loaded = struct {
    /// In file order, with included files spliced in at their directive.
    entries: []const LoadedEntry,
    unavailable: []const Unavailable,
    /// Every config file read or looked for, missing ones included, so a
    /// later change to any of them can be detected.
    paths: []const []const u8 = &.{},

    /// The last entry for the key, or null when unset.
    pub fn last(self: Loaded, section: []const u8, subsection: ?[]const u8, name: []const u8) ?*const Entry {
        var i = self.entries.len;
        while (i > 0) {
            i -= 1;
            const entry = &self.entries[i].entry;
            if (keyMatches(entry, section, subsection, name)) return entry;
        }
        return null;
    }
};

fn keyMatches(entry: *const Entry, section: []const u8, subsection: ?[]const u8, name: []const u8) bool {
    if (!std.mem.eql(u8, entry.section, section) or !std.mem.eql(u8, entry.name, name)) return false;
    if (subsection) |want| {
        const have = entry.subsection orelse return false;
        return std.mem.eql(u8, have, want);
    }
    return entry.subsection == null;
}

/// Where config comes from and what conditions are evaluated against.
pub const Context = struct {
    home: ?[]const u8 = null,
    /// Never empty: git treats an empty `XDG_CONFIG_HOME` as unset.
    xdg_config_home: ?[]const u8 = null,
    /// `GIT_CONFIG_GLOBAL`: replaces the user files when set.
    global_override: ?[]const u8 = null,
    /// `GIT_CONFIG_SYSTEM`, or the conventional `/etc/gitconfig`. Git's
    /// compiled-in system path can differ; that is a parity limitation.
    system_path: []const u8 = "/etc/gitconfig",
    no_system: bool = false,
    layout: ?layout_mod.Layout = null,
    /// `realpath` of `layout.git_dir`, tried first by `gitdir:` like git.
    git_dir_real: ?[]const u8 = null,
    branch: ?[]const u8 = null,

    /// Reads git's environment variables and the repository's HEAD. Memory
    /// belongs to `arena`.
    pub fn fromEnvironment(arena: Allocator, layout: ?layout_mod.Layout) Allocator.Error!Context {
        var context: Context = .{
            .home = io_mod.getenv("HOME"),
            .xdg_config_home = if (io_mod.getenv("XDG_CONFIG_HOME")) |xdg| if (xdg.len > 0) xdg else null else null,
            .global_override = io_mod.getenv("GIT_CONFIG_GLOBAL"),
            .no_system = if (io_mod.getenv("GIT_CONFIG_NOSYSTEM")) |v| parseBool(v) orelse false else false,
            .layout = layout,
        };
        if (io_mod.getenv("GIT_CONFIG_SYSTEM")) |path| context.system_path = path;
        if (layout) |found| {
            context.git_dir_real = io_mod.realpathAlloc(arena, found.git_dir) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            context.branch = try layout_mod.currentBranch(arena, found);
        }
        return context;
    }
};

const Loader = struct {
    arena: Allocator,
    context: *const Context,
    mode: Mode,
    entries: std.ArrayList(LoadedEntry) = .empty,
    unavailable: std.ArrayList(Unavailable) = .empty,
    paths: std.ArrayList([]const u8) = .empty,

    fn readFile(self: *Loader, path: []const u8, scope: Scope, depth: usize) Allocator.Error!void {
        if (depth > max_include_depth) return self.markUnavailable(path, "include_depth");
        // git reads /dev/null as an empty file; it is commonly used to
        // disable a config level.
        if (std.mem.eql(u8, path, "/dev/null")) return;
        try self.paths.append(self.arena, path);
        const content = switch (try bounded_read.readAbsolute(self.arena, path, max_config_file_bytes)) {
            .content => |bytes| bytes,
            .missing => return,
            .unavailable => |reason| return self.markUnavailable(path, reason),
        };
        const parsed = parse(self.arena, content) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidConfig => return self.markUnavailable(path, "invalid_config"),
        };
        for (parsed) |entry| {
            try self.entries.append(self.arena, .{ .entry = entry, .scope = scope });
            if (!std.mem.eql(u8, entry.name, "path")) continue;
            const include_value = entry.value orelse continue;
            const included = if (std.mem.eql(u8, entry.section, "include") and entry.subsection == null)
                true
            else if (std.mem.eql(u8, entry.section, "includeif") and entry.subsection != null)
                self.mode == .every_include or try self.conditionMatches(entry.subsection.?, path)
            else
                false;
            if (!included) continue;
            const target = try self.includePath(include_value, path) orelse continue;
            try self.readFile(target, scope, depth + 1);
        }
    }

    fn markUnavailable(self: *Loader, path: []const u8, reason: []const u8) Allocator.Error!void {
        try self.unavailable.append(self.arena, .{ .path = path, .reason = reason });
    }

    /// git's include path handling: `~/` from HOME, relative to the
    /// including file's directory otherwise. Null when it cannot expand.
    fn includePath(self: *Loader, raw: []const u8, config_path: []const u8) Allocator.Error!?[]const u8 {
        const expanded = try self.expandHome(raw) orelse return null;
        if (std.fs.path.isAbsolute(expanded)) return expanded;
        const dir = std.fs.path.dirname(config_path) orelse return null;
        return try std.fs.path.join(self.arena, &.{ dir, expanded });
    }

    fn expandHome(self: *Loader, raw: []const u8) Allocator.Error!?[]const u8 {
        if (raw.len == 0) return null;
        if (raw[0] != '~') return raw;
        if (!std.mem.startsWith(u8, raw, "~/")) return null;
        const home = self.context.home orelse return null;
        return try std.fs.path.join(self.arena, &.{ home, raw[2..] });
    }

    fn conditionMatches(self: *Loader, condition: []const u8, config_path: []const u8) Allocator.Error!bool {
        if (std.mem.startsWith(u8, condition, "gitdir:")) return self.gitdirMatches(condition["gitdir:".len..], false, config_path);
        if (std.mem.startsWith(u8, condition, "gitdir/i:")) return self.gitdirMatches(condition["gitdir/i:".len..], true, config_path);
        if (std.mem.startsWith(u8, condition, "onbranch:")) return self.branchMatches(condition["onbranch:".len..]);
        if (std.mem.startsWith(u8, condition, "hasconfig:")) {
            debug_trace.logf("indexer", "config includeIf hasconfig treated as unmatched path={s}", .{config_path});
        }
        return false;
    }

    /// git's include_by_gitdir and prepare_include_condition_pattern.
    fn gitdirMatches(self: *Loader, raw: []const u8, fold_case: bool, config_path: []const u8) Allocator.Error!bool {
        const layout = self.context.layout orelse return false;
        var pattern = try self.expandHome(raw) orelse return false;
        var literal_len: usize = 0;
        if (std.mem.startsWith(u8, pattern, "./")) {
            const real_config = io_mod.realpathAlloc(self.arena, config_path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return false,
            };
            const dir = std.fs.path.dirname(real_config) orelse return false;
            pattern = try std.mem.concat(self.arena, u8, &.{ dir, pattern[1..] });
            literal_len = dir.len + 1;
        } else if (!std.fs.path.isAbsolute(pattern)) {
            pattern = try std.mem.concat(self.arena, u8, &.{ "**/", pattern });
        }
        if (std.mem.endsWith(u8, pattern, "/")) pattern = try std.mem.concat(self.arena, u8, &.{ pattern, "**" });

        const candidates = [_]?[]const u8{ self.context.git_dir_real, layout.git_dir };
        for (candidates) |maybe_text| {
            const text = maybe_text orelse continue;
            if (literal_len > 0) {
                if (text.len < literal_len) continue;
                const same = if (fold_case)
                    std.ascii.eqlIgnoreCase(pattern[0..literal_len], text[0..literal_len])
                else
                    std.mem.eql(u8, pattern[0..literal_len], text[0..literal_len]);
                if (!same) continue;
            }
            if (wildmatch.match(pattern[literal_len..], text[literal_len..], .{ .pathname = true, .casefold = fold_case })) return true;
        }
        return false;
    }

    /// git's include_by_branch.
    fn branchMatches(self: *Loader, raw: []const u8) Allocator.Error!bool {
        const branch = self.context.branch orelse return false;
        const pattern = if (std.mem.endsWith(u8, raw, "/")) try std.mem.concat(self.arena, u8, &.{ raw, "**" }) else raw;
        return wildmatch.match(pattern, branch, .{ .pathname = true });
    }

    fn result(self: *Loader) Allocator.Error!Loaded {
        return .{
            .entries = try self.entries.toOwnedSlice(self.arena),
            .unavailable = try self.unavailable.toOwnedSlice(self.arena),
            .paths = try self.paths.toOwnedSlice(self.arena),
        };
    }
};

/// Loads system, user and repository config in git's precedence order, in
/// `values` mode. Memory belongs to `arena`.
pub fn loadAll(arena: Allocator, context: *const Context) Allocator.Error!Loaded {
    var loader: Loader = .{ .arena = arena, .context = context, .mode = .values };
    if (!context.no_system) try loader.readFile(context.system_path, .system, 0);
    if (context.global_override) |path| {
        if (path.len > 0) try loader.readFile(path, .global, 0);
    } else {
        if (context.xdg_config_home) |xdg| {
            try loader.readFile(try std.fs.path.join(arena, &.{ xdg, "git", "config" }), .global, 0);
        } else if (context.home) |home| {
            try loader.readFile(try std.fs.path.join(arena, &.{ home, ".config", "git", "config" }), .global, 0);
        }
        if (context.home) |home| try loader.readFile(try std.fs.path.join(arena, &.{ home, ".gitconfig" }), .global, 0);
    }
    if (context.layout) |layout| {
        const local_start = loader.entries.items.len;
        try loader.readFile(try std.fs.path.join(arena, &.{ layout.common_dir, "config" }), .local, 0);
        var worktree_config = false;
        for (loader.entries.items[local_start..]) |loaded| {
            const entry = loaded.entry;
            if (std.mem.eql(u8, entry.section, "extensions") and entry.subsection == null and std.mem.eql(u8, entry.name, "worktreeconfig")) {
                worktree_config = parseBool(entry.value) orelse false;
            }
        }
        if (worktree_config) try loader.readFile(try std.fs.path.join(arena, &.{ layout.git_dir, "config.worktree" }), .worktree, 0);
    }
    return loader.result();
}

/// Loads only the repository's own config (`config`, `config.worktree` and
/// everything they include) with every `includeIf` counted as included.
/// Memory belongs to `arena`.
pub fn loadRepositoryEveryInclude(arena: Allocator, context: *const Context) Allocator.Error!Loaded {
    var loader: Loader = .{ .arena = arena, .context = context, .mode = .every_include };
    if (context.layout) |layout| {
        try loader.readFile(try std.fs.path.join(arena, &.{ layout.common_dir, "config" }), .local, 0);
        try loader.readFile(try std.fs.path.join(arena, &.{ layout.git_dir, "config.worktree" }), .worktree, 0);
    }
    return loader.result();
}

/// Distinct filter driver names with a `clean`, `smudge` or `process`
/// command. Memory belongs to `arena`.
pub fn filterDriverNames(arena: Allocator, loaded: Loaded) Allocator.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (loaded.entries) |loaded_entry| {
        const entry = loaded_entry.entry;
        if (!std.mem.eql(u8, entry.section, "filter")) continue;
        const name = entry.subsection orelse continue;
        const program = std.mem.eql(u8, entry.name, "clean") or std.mem.eql(u8, entry.name, "smudge") or std.mem.eql(u8, entry.name, "process");
        if (!program) continue;
        for (names.items) |known| {
            if (std.mem.eql(u8, known, name)) break;
        } else try names.append(arena, name);
    }
    return names.toOwnedSlice(arena);
}

pub const ObjectFormat = enum { sha1, sha256 };

pub const IgnoreSettings = struct {
    /// Absolute path of the excludes file to read, or null for none.
    excludes_file: ?[]const u8,
    ignore_case: bool,
    object_format: ObjectFormat,
    /// Settings git would refuse, by key. Static strings.
    invalid: []const []const u8,
};

/// Settings that shape ignore decisions and index parsing, from config
/// loaded in `values` mode. Memory belongs to `arena`.
pub fn ignoreSettings(arena: Allocator, loaded: Loaded, context: *const Context) Allocator.Error!IgnoreSettings {
    var invalid: std.ArrayList([]const u8) = .empty;
    const ignore_case = if (loaded.last("core", null, "ignorecase")) |entry|
        parseBool(entry.value) orelse blk: {
            try invalid.append(arena, "core.ignorecase");
            break :blk false;
        }
    else
        false;

    var object_format: ObjectFormat = .sha1;
    var i = loaded.entries.len;
    while (i > 0) {
        i -= 1;
        const loaded_entry = loaded.entries[i];
        if (loaded_entry.scope != .local) continue;
        if (!keyMatches(&loaded_entry.entry, "extensions", null, "objectformat")) continue;
        const value = loaded_entry.entry.value orelse "";
        if (std.ascii.eqlIgnoreCase(value, "sha256")) {
            object_format = .sha256;
        } else if (!std.ascii.eqlIgnoreCase(value, "sha1")) {
            try invalid.append(arena, "extensions.objectformat");
        }
        break;
    }

    const excludes_file: ?[]const u8 = if (loaded.last("core", null, "excludesfile")) |entry| blk: {
        const raw = entry.value orelse break :blk null;
        if (raw.len == 0) break :blk null;
        if (std.mem.startsWith(u8, raw, "~/")) {
            const home = context.home orelse break :blk null;
            break :blk try std.fs.path.join(arena, &.{ home, raw[2..] });
        }
        if (std.fs.path.isAbsolute(raw)) break :blk raw;
        // git resolves a relative path from the worktree root, its cwd.
        const layout = context.layout orelse break :blk null;
        break :blk try std.fs.path.join(arena, &.{ layout.worktree_root, raw });
    } else if (context.xdg_config_home) |xdg|
        try std.fs.path.join(arena, &.{ xdg, "git", "ignore" })
    else if (context.home) |home|
        try std.fs.path.join(arena, &.{ home, ".config", "git", "ignore" })
    else
        null;

    return .{
        .excludes_file = excludes_file,
        .ignore_case = ignore_case,
        .object_format = object_format,
        .invalid = try invalid.toOwnedSlice(arena),
    };
}

fn expectParsed(text: []const u8, expected: []const Entry) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const entries = try parse(arena_state.allocator(), text);
    try std.testing.expectEqual(expected.len, entries.len);
    for (expected, entries) |want, have| {
        try std.testing.expectEqualStrings(want.section, have.section);
        try std.testing.expectEqualStrings(want.name, have.name);
        if (want.subsection) |sub| try std.testing.expectEqualStrings(sub, have.subsection.?) else try std.testing.expect(have.subsection == null);
        if (want.value) |value| try std.testing.expectEqualStrings(value, have.value.?) else try std.testing.expect(have.value == null);
    }
}

test "config parser follows git's section, key and value syntax" {
    try expectParsed(
        "\xef\xbb\xbf# comment\r\n[Core]\r\n\tExcludesFile = ~/ignore  ; trailing comment\r\n" ++
            "\tbare\n[filter \"My \\\"LFS\\\"\"]\n clean = run \"a  b\" # c\n" ++
            "[Section.Sub]\nkey=one\\\n two\nesc = \"tab\\there\\n\"\nspaced =   inner  value   \n",
        &.{
            .{ .section = "core", .subsection = null, .name = "excludesfile", .value = "~/ignore" },
            .{ .section = "core", .subsection = null, .name = "bare", .value = null },
            .{ .section = "filter", .subsection = "My \"LFS\"", .name = "clean", .value = "run a  b" },
            .{ .section = "section", .subsection = "sub", .name = "key", .value = "one two" },
            .{ .section = "section", .subsection = "sub", .name = "esc", .value = "tab\there\n" },
            .{ .section = "section", .subsection = "sub", .name = "spaced", .value = "inner  value" },
        },
    );
}

test "config parser rejects input git refuses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bad = [_][]const u8{
        "key = value\n",
        "[core]\nname # no equals\n",
        "[core]\nname = \"unterminated\n",
        "[core]\nname = bad\\q\n",
        "[core\n",
        "[]\n",
        "[core \"sub\" ]\n",
        "[core]\n9name = x\n",
    };
    for (bad) |text| {
        if (parse(arena, text)) |_| {
            std.debug.print("accepted: {s}\n", .{text});
            return error.TestUnexpectedResult;
        } else |err| try std.testing.expectEqual(error.InvalidConfig, err);
    }
}

test "config booleans follow git" {
    try std.testing.expectEqual(@as(?bool, true), parseBool(null));
    try std.testing.expectEqual(@as(?bool, false), parseBool(""));
    try std.testing.expectEqual(@as(?bool, true), parseBool("Yes"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("off"));
    try std.testing.expectEqual(@as(?bool, true), parseBool("2"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("0"));
    try std.testing.expectEqual(@as(?bool, null), parseBool("maybe"));
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = content });
}

const TestRepo = struct {
    root: []const u8,
    context: Context,
};

/// Builds `home/` and a repository at `repo_path` inside `tmp`, and a context
/// that reads only those files.
fn testRepo(arena: Allocator, tmp: *std.testing.TmpDir, repo_path: []const u8, branch: []const u8) !TestRepo {
    const head = try std.fmt.allocPrint(arena, "{s}/.git/HEAD", .{repo_path});
    try writeTestFile(tmp.dir, head, try std.fmt.allocPrint(arena, "ref: refs/heads/{s}\n", .{branch}));
    try tmp.dir.createDirPath(std.testing.io, try std.fmt.allocPrint(arena, "{s}/.git/objects", .{repo_path}));
    try tmp.dir.createDirPath(std.testing.io, try std.fmt.allocPrint(arena, "{s}/.git/refs", .{repo_path}));
    try tmp.dir.createDirPath(std.testing.io, "home");
    const root = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const layout = (try layout_mod.discover(arena, try std.fs.path.join(arena, &.{ root, repo_path }))).?;
    var context = try Context.fromEnvironment(arena, layout);
    context.home = try std.fs.path.join(arena, &.{ root, "home" });
    context.xdg_config_home = null;
    context.global_override = null;
    context.no_system = true;
    return .{ .root = root, .context = context };
}

test "config includes follow relative and home paths, skip missing files and stop at depth" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try testRepo(arena, &tmp, "repo", "main");
    try writeTestFile(tmp.dir, "home/.gitconfig", "[include]\npath = conf/a\npath = ~/conf/missing\n[core]\nignorecase = false\n");
    try writeTestFile(tmp.dir, "home/conf/a", "[include]\npath = b\n[core]\nignorecase = true\n");
    try writeTestFile(tmp.dir, "home/conf/b", "[core]\nexcludesfile = ~/from-b\n");
    try writeTestFile(tmp.dir, "repo/.git/config", "[include]\npath = loop\n");
    try writeTestFile(tmp.dir, "repo/.git/loop", "[include]\npath = loop\n");

    const loaded = try loadAll(arena, &repo.context);
    const settings = try ignoreSettings(arena, loaded, &repo.context);
    // The last value wins in file order, after spliced-in includes.
    try std.testing.expect(!settings.ignore_case);
    try std.testing.expectEqualStrings(try std.fs.path.join(arena, &.{ repo.root, "home/from-b" }), settings.excludes_file.?);
    try std.testing.expectEqual(@as(usize, 1), loaded.unavailable.len);
    try std.testing.expectEqualStrings("include_depth", loaded.unavailable[0].reason);
}

test "config includeIf evaluates gitdir, gitdir/i and onbranch, and never hasconfig" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const matching = try testRepo(arena, &tmp, "work/one", "feat/x");
    const other = try testRepo(arena, &tmp, "play/two", "main");
    const root = matching.root;
    const gitconfig = try std.fmt.allocPrint(arena,
        \\[includeIf "gitdir:{s}/work/"]
        \\path = work.inc
        \\[includeIf "gitdir/i:{s}/PLAY/"]
        \\path = play.inc
        \\[includeIf "onbranch:feat/"]
        \\path = feat.inc
        \\[includeIf "hasconfig:remote.*.url:https://example.com/**"]
        \\path = hasconfig.inc
        \\
    , .{ root, root });
    try writeTestFile(tmp.dir, "home/.gitconfig", gitconfig);
    try writeTestFile(tmp.dir, "home/work.inc", "[core]\nexcludesfile = /work-excludes\n");
    try writeTestFile(tmp.dir, "home/play.inc", "[core]\nexcludesfile = /play-excludes\n");
    try writeTestFile(tmp.dir, "home/feat.inc", "[core]\nignorecase = true\n");
    try writeTestFile(tmp.dir, "home/hasconfig.inc", "[core]\nexcludesfile = /never\n");

    const work_loaded = try loadAll(arena, &matching.context);
    const work = try ignoreSettings(arena, work_loaded, &matching.context);
    try std.testing.expectEqualStrings("/work-excludes", work.excludes_file.?);
    try std.testing.expect(work.ignore_case);

    const play_loaded = try loadAll(arena, &other.context);
    const play = try ignoreSettings(arena, play_loaded, &other.context);
    try std.testing.expectEqualStrings("/play-excludes", play.excludes_file.?);
    try std.testing.expect(!play.ignore_case);

    // Outside any repository no condition matches.
    var no_repo = matching.context;
    no_repo.layout = null;
    no_repo.git_dir_real = null;
    no_repo.branch = null;
    const none = try ignoreSettings(arena, try loadAll(arena, &no_repo), &no_repo);
    try std.testing.expectEqualStrings(try std.fs.path.join(arena, &.{ root, "home/.config/git/ignore" }), none.excludes_file.?);
}

test "config gitdir patterns relative to the including file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try testRepo(arena, &tmp, "home/projects/app", "main");
    try writeTestFile(tmp.dir, "home/.gitconfig", "[includeIf \"gitdir:./projects/\"]\npath = projects.inc\n");
    try writeTestFile(tmp.dir, "home/projects.inc", "[core]\nexcludesfile = relative/ignore\n");
    const settings = try ignoreSettings(arena, try loadAll(arena, &repo.context), &repo.context);
    const expected = try std.fs.path.join(arena, &.{ repo.context.layout.?.worktree_root, "relative/ignore" });
    try std.testing.expectEqualStrings(expected, settings.excludes_file.?);
}

test "repository filter names come only from repository config and count every includeIf" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try testRepo(arena, &tmp, "repo", "main");
    try writeTestFile(tmp.dir, "home/.gitconfig", "[filter \"lfs\"]\nclean = git-lfs clean -- %f\n");
    try writeTestFile(tmp.dir, "repo/.git/config", "[filter \"evil\"]\nclean = /tmp/x\n[includeIf \"onbranch:never/\"]\npath = hidden\n[filter \"evil\"]\nsmudge = /tmp/y\n[filter \"meta\"]\nrequired = true\n");
    try writeTestFile(tmp.dir, "repo/.git/hidden", "[filter \"Hidden\"]\nprocess = /tmp/z\n");
    try writeTestFile(tmp.dir, "repo/.git/config.worktree", "[filter \"wt\"]\nclean = /tmp/w\n");

    const every = try loadRepositoryEveryInclude(arena, &repo.context);
    const names = try filterDriverNames(arena, every);
    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings("evil", names[0]);
    try std.testing.expectEqualStrings("Hidden", names[1]);
    try std.testing.expectEqualStrings("wt", names[2]);

    // In values mode the onbranch include does not match and config.worktree
    // is read only when extensions.worktreeConfig is set.
    const values = try filterDriverNames(arena, try loadAll(arena, &repo.context));
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqualStrings("lfs", values[0]);
    try std.testing.expectEqualStrings("evil", values[1]);
}

test "config sources that are not bounded regular files are unavailable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try testRepo(arena, &tmp, "repo", "main");
    try tmp.dir.createDirPath(std.testing.io, "repo/.git/config");
    try writeTestFile(tmp.dir, "home/.gitconfig", "[core]\nbroken = \"x\n");
    const loaded = try loadAll(arena, &repo.context);
    try std.testing.expectEqual(@as(usize, 2), loaded.unavailable.len);
    try std.testing.expectEqualStrings("invalid_config", loaded.unavailable[0].reason);
    try std.testing.expect(loaded.entries.len == 0);
}
