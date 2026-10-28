//! Finds the stream rules for a workspace.
//!
//! Sources, highest priority first; a later source never replaces a name an
//! earlier one claimed:
//!
//! 1. `<workspace>/.proto-fx/rules/*.md`
//! 2. `~/.proto-fx/rules/*.md`
//! 3. Cursor: `<workspace>/.cursor/rules/*.mdc` and `~/.cursor/rules/*.mdc`
//! 4. Windsurf: `<workspace>/.windsurf/rules/*.md` and
//!    `~/.codeium/windsurf/memories/global_rules.md`
//! 5. The built-in rules, unless `builtin_rules` is off
//!
//! Only rules with a condition stream; plain guidance files are skipped.
//! Reading never starts a process.
const std = @import("std");
const rule_mod = @import("rule.zig");
const builtin_rules = @import("builtin.zig");
const settings_mod = @import("settings.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;
const Rule = rule_mod.Rule;

const max_rule_bytes = 256 * 1024;
const max_rules_per_dir = 256;

pub const Loaded = struct {
    rules: []const Rule,
    /// One line per file that could not be read as a rule.
    warnings: []const []const u8,
};

pub const Options = struct {
    workspace_root: []const u8,
    home: ?[]const u8,
    settings: settings_mod.Settings = .{},
};

/// Every streaming rule for the workspace, minus disabled ones. Memory
/// comes from `arena`.
pub fn load(arena: Allocator, options: Options) !Loaded {
    var loader: Loader = .{ .arena = arena, .settings = options.settings };
    const root = options.workspace_root;
    if (root.len > 0) try loader.dir(try join(arena, &.{ root, profile_paths.root_dir_name, "rules" }), .project, &.{ ".md", ".mdc" });
    if (options.home) |home| try loader.dir(try join(arena, &.{ home, profile_paths.root_dir_name, "rules" }), .user, &.{ ".md", ".mdc" });
    if (root.len > 0) try loader.dir(try join(arena, &.{ root, ".cursor", "rules" }), .cursor, &.{ ".mdc", ".md" });
    if (options.home) |home| try loader.dir(try join(arena, &.{ home, ".cursor", "rules" }), .cursor, &.{".mdc"});
    if (root.len > 0) try loader.dir(try join(arena, &.{ root, ".windsurf", "rules" }), .windsurf, &.{".md"});
    if (options.home) |home| try loader.file(try join(arena, &.{ home, ".codeium", "windsurf", "memories", "global_rules.md" }), "global_rules", .windsurf);
    if (options.settings.builtin_rules) {
        for (builtin_rules.sources) |source| {
            try loader.add(source.name, source.content, try arena.print("builtin://{s}.md", .{source.name}), .builtin);
        }
    }
    return .{ .rules = loader.rules.items, .warnings = loader.warnings.items };
}

/// Reads one rule file outside discovery, as `proto-fx ttsr test --rule`
/// does. Memory comes from `arena`.
pub fn loadFile(arena: Allocator, path: []const u8) !Rule {
    var file = try std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    const content = try io_mod.readFileToEnd(arena, &file, max_rule_bytes);
    const base = std.Io.Dir.path.basename(path);
    const name = stripExtension(base);
    return try rule_mod.parseMarkdown(arena, name, content, path, .file) orelse error.RuleDisabled;
}

/// The description of the rule an injection names by `path` as its row
/// shows it (workspace-relative, `~/...`, or `builtin://`), when the rule
/// can still be read. Memory comes from `arena`.
pub fn describe(arena: Allocator, path: []const u8, workspace_root: []const u8, home: ?[]const u8) ?[]const u8 {
    const builtin_prefix = "builtin://";
    if (std.mem.startsWith(u8, path, builtin_prefix)) {
        const name = stripExtension(path[builtin_prefix.len..]);
        for (builtin_rules.sources) |source| if (std.mem.eql(u8, source.name, name)) {
            const parsed = rule_mod.parseMarkdown(arena, name, source.content, path, .builtin) catch return null;
            return (parsed orelse return null).description;
        };
        return null;
    }
    const full = if (std.mem.startsWith(u8, path, "~/"))
        join(arena, &.{ home orelse return null, path[2..] }) catch return null
    else if (std.Io.Dir.path.isAbsolute(path))
        path
    else
        join(arena, &.{ workspace_root, path }) catch return null;
    const parsed = loadFile(arena, full) catch return null;
    return parsed.description;
}

fn join(arena: Allocator, parts: []const []const u8) ![]const u8 {
    return std.Io.Dir.path.join(arena, parts);
}

fn stripExtension(base: []const u8) []const u8 {
    for ([_][]const u8{ ".mdc", ".md" }) |ext| if (std.mem.endsWith(u8, base, ext)) return base[0 .. base.len - ext.len];
    return base;
}

const Loader = struct {
    arena: Allocator,
    settings: settings_mod.Settings,
    rules: std.ArrayList(Rule) = .empty,
    warnings: std.ArrayList([]const u8) = .empty,

    fn claimed(self: *const Loader, name: []const u8) bool {
        for (self.rules.items) |existing| if (std.mem.eql(u8, existing.name, name)) return true;
        return false;
    }

    fn add(self: *Loader, name: []const u8, content: []const u8, path: []const u8, provider: rule_mod.Provider) !void {
        if (self.claimed(name) or self.settings.isDisabled(name)) return;
        const parsed = rule_mod.parseMarkdown(self.arena, name, content, path, provider) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidFrontmatter => {
                try self.warnings.append(self.arena, try self.arena.print("{s}: frontmatter is not valid YAML", .{path}));
                return;
            },
        };
        const rule = parsed orelse return;
        if (!rule.hasCondition()) return;
        try self.rules.append(self.arena, rule);
    }

    fn file(self: *Loader, path: []const u8, name: []const u8, provider: rule_mod.Provider) !void {
        const content = readFile(self.arena, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        try self.add(name, content, path, provider);
    }

    fn dir(self: *Loader, path: []const u8, provider: rule_mod.Provider, extensions: []const []const u8) !void {
        const io = io_mod.getIo();
        var handle = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
        defer handle.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = handle.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            const wanted = for (extensions) |ext| {
                if (std.mem.endsWith(u8, entry.name, ext)) break true;
            } else false;
            if (!wanted) continue;
            try names.append(self.arena, try self.arena.dupe(u8, entry.name));
            if (names.items.len >= max_rules_per_dir) break;
        }
        std.sort.pdq([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        for (names.items) |base| {
            try self.file(try join(self.arena, &.{ path, base }), stripExtension(base), provider);
        }
    }
};

fn readFile(arena: Allocator, path: []const u8) ![]u8 {
    var handle = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer handle.close(io_mod.getIo());
    return io_mod.readFileToEnd(arena, &handle, max_rule_bytes);
}

test "discovery orders sources, skips guidance and honors settings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = io_mod.getIo();
    try tmp.dir.createDirPath(io, "ws/.proto-fx/rules");
    try tmp.dir.createDirPath(io, "ws/.cursor/rules");
    try tmp.dir.createDirPath(io, "home/.proto-fx/rules");
    try tmp.dir.writeFile(io, .{ .sub_path = "ws/.proto-fx/rules/no-force.md", .data = "---\nscope: tool:shell\nmatch: 'push --force'\n---\nProject wins." });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.proto-fx/rules/no-force.md", .data = "---\nmatch: 'push --force'\n---\nUser loses." });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.proto-fx/rules/guidance.md", .data = "Plain guidance without a condition." });
    try tmp.dir.writeFile(io, .{ .sub_path = "ws/.cursor/rules/ts.mdc", .data = "---\ndescription: ts\nglobs: *.ts\ncondition: 'as any'\n---\nNo any." });
    try tmp.dir.writeFile(io, .{ .sub_path = "ws/.cursor/rules/broken.mdc", .data = "---\nmatch: [a\n---\nBroken." });
    const root = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const ws = try join(arena, &.{ root, "ws" });
    const home = try join(arena, &.{ root, "home" });

    const loaded = try load(arena, .{ .workspace_root = ws, .home = home });
    try std.testing.expectEqualStrings("no-force", loaded.rules[0].name);
    try std.testing.expectEqualStrings("Project wins.", loaded.rules[0].content);
    try std.testing.expectEqual(rule_mod.Provider.project, loaded.rules[0].provider);
    try std.testing.expectEqualStrings("ts", loaded.rules[1].name);
    try std.testing.expectEqual(rule_mod.Provider.cursor, loaded.rules[1].provider);
    try std.testing.expectEqual(@as(usize, 1), loaded.warnings.len);
    try std.testing.expectEqual(@as(usize, 2 + builtin_rules.sources.len), loaded.rules.len);

    const trimmed = try load(arena, .{ .workspace_root = ws, .home = home, .settings = .{ .builtin_rules = false, .disabled_rules = &.{"ts"} } });
    try std.testing.expectEqual(@as(usize, 1), trimmed.rules.len);
}

test "every built-in rule parses and compiles" {
    const matcher = @import("matcher.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (builtin_rules.sources) |source| {
        const rule = (try rule_mod.parseMarkdown(arena, source.name, source.content, source.name, .builtin)).?;
        try std.testing.expect(rule.hasCondition());
        try std.testing.expect(rule.content.len > 0);
        const compiled = try matcher.compile(arena, rule.match.?);
        if (compiled.program == null) {
            for (compiled.errors) |err| std.debug.print("{s}: {s}\n", .{ source.name, err });
            return error.TestBuiltinRuleFailed;
        }
    }
}
