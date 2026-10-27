//! `proto-fx ttsr list|test|scan`: inspect the workspace's stream rules,
//! check a snippet against them, or scan a folder with them, as proto's
//! `ttsr-cli.ts` does.
//!
//! `test` and `scan` evaluate settled buffers: `ast:` conditions settle,
//! and `llm:` conditions settle as no match, since neither command calls a
//! model.
const std = @import("std");
const ttsr = @import("../ttsr/ttsr.zig");
const indexer = @import("../indexer/indexer.zig");
const io_mod = @import("../shared/io.zig");
const output_contracts = @import("../output/output_contracts.zig");
const snapshot = @import("../output/ttsr_snapshot.zig");

const Allocator = std.mem.Allocator;
const Manager = ttsr.manager.Manager;

pub const Action = enum { list, @"test", scan };

pub const default_max_scan_bytes: usize = 5 * 1024 * 1024;
const binary_probe_bytes = 8192;
const max_snippet_bytes = 16 * 1024 * 1024;

pub const Options = struct {
    action: Action,
    format: output_contracts.OutputFormat = .text,
    verbose: bool = false,
    snippet: ?[]const u8 = null,
    /// Snippet file for `test`; `-` reads stdin.
    file: ?[]const u8 = null,
    /// One rule file evaluated alone, with default settings.
    rule: ?[]const u8 = null,
    source: ?ttsr.evaluate.Source = null,
    tool: ?[]const u8 = null,
    /// The file the snippet stands for, which sets its language.
    path: ?[]const u8 = null,
    directory: ?[]const u8 = null,
    max_bytes: usize = default_max_scan_bytes,
};

pub const ParseError = error{ InvalidTtsrArguments, OutOfMemory };

pub fn parseArgs(args: []const [:0]const u8) ParseError!Options {
    if (args.len == 0) return error.InvalidTtsrArguments;
    var options: Options = .{ .action = std.meta.stringToEnum(Action, args[0]) orelse return error.InvalidTtsrArguments };
    var index: usize = 1;
    var options_done = false;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (!options_done and std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--")) {
                options_done = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--json")) {
                options.format = .json;
                continue;
            }
            if (std.mem.eql(u8, arg, "--verbose")) {
                options.verbose = true;
                continue;
            }
            index += 1;
            if (index >= args.len) return error.InvalidTtsrArguments;
            const value: []const u8 = args[index];
            if (std.mem.eql(u8, arg, "--rule")) {
                options.rule = value;
            } else if (options.action == .@"test" and std.mem.eql(u8, arg, "--file")) {
                options.file = value;
            } else if (options.action == .@"test" and std.mem.eql(u8, arg, "--source")) {
                options.source = std.meta.stringToEnum(ttsr.evaluate.Source, value) orelse return error.InvalidTtsrArguments;
            } else if (options.action == .@"test" and std.mem.eql(u8, arg, "--tool")) {
                options.tool = value;
            } else if (options.action == .@"test" and std.mem.eql(u8, arg, "--path")) {
                options.path = value;
            } else if (options.action == .scan and std.mem.eql(u8, arg, "--max-bytes")) {
                options.max_bytes = std.fmt.parseInt(usize, value, 10) catch return error.InvalidTtsrArguments;
            } else return error.InvalidTtsrArguments;
            continue;
        }
        switch (options.action) {
            .list => return error.InvalidTtsrArguments,
            .@"test" => {
                if (options.snippet != null) return error.InvalidTtsrArguments;
                options.snippet = arg;
            },
            .scan => {
                if (options.directory != null) return error.InvalidTtsrArguments;
                options.directory = arg;
            },
        }
    }
    if (options.action == .@"test" and options.snippet == null and options.file == null) return error.InvalidTtsrArguments;
    return options;
}

pub const Result = struct {
    output: []u8,
    format: output_contracts.OutputFormat,
    succeeded: bool,
};

/// The rules a command evaluates and the manager holding them compiled.
const Loaded = struct {
    manager: Manager,
    rules: []const ttsr.rule.Rule,
    warnings: []const []const u8,
};

fn loadRules(arena: Allocator, options: Options, workspace_root: []const u8, home: ?[]const u8) !Loaded {
    if (options.rule) |rule_path| {
        const rule = ttsr.discovery.loadFile(arena, rule_path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidFrontmatter => return error.InvalidRuleFile,
            else => return error.RuleFileUnreadable,
        };
        var manager = Manager.init(arena, .{}, workspace_root, home);
        const rules = try arena.alloc(ttsr.rule.Rule, 1);
        rules[0] = rule;
        _ = try manager.addRule(rule);
        return .{ .manager = manager, .rules = rules, .warnings = &.{} };
    }
    const settings = ttsr.settings.load(arena, home, workspace_root);
    var manager = Manager.init(arena, settings, workspace_root, home);
    if (!settings.enabled) return .{ .manager = manager, .rules = &.{}, .warnings = &.{"stream rules are disabled in settings"} };
    const loaded = try ttsr.discovery.load(arena, .{ .workspace_root = workspace_root, .home = home, .settings = settings });
    for (loaded.rules) |rule| _ = try manager.addRule(rule);
    return .{ .manager = manager, .rules = loaded.rules, .warnings = loaded.warnings };
}

fn errorsFor(arena: Allocator, manager: *const Manager) ![]const snapshot.RuleError {
    const out = try arena.alloc(snapshot.RuleError, manager.errors.items.len);
    for (manager.errors.items, out) |failure, *row| row.* = .{ .name = failure.rule, .message = failure.message };
    return out;
}

fn hitFor(arena: Allocator, entry: *const ttsr.manager.Entry, evidence: ?ttsr.evaluate.Evidence) !snapshot.Hit {
    var snippets: []snapshot.Snippet = &.{};
    if (evidence) |found| {
        snippets = try arena.alloc(snapshot.Snippet, found.snippets.len);
        for (found.snippets, snippets) |from, *to| to.* = .{ .line = from.line, .text = try arena.dupe(u8, from.text) };
    }
    return .{ .name = entry.rule.name, .path = entry.rule.path, .provider = entry.rule.provider.label(), .condition = entry.program.description, .snippets = snippets };
}

/// Runs one subcommand in `workspace_root`. The caller owns `output`.
pub fn run(alloc: Allocator, options: Options, workspace_root: []const u8, home: ?[]const u8) !Result {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var loaded = loadRules(arena, options, workspace_root, home) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(alloc, options.format, switch (err) {
            error.InvalidRuleFile => "the rule file's frontmatter is not valid YAML",
            else => "the rule file could not be read",
        }),
    };
    defer loaded.manager.deinit();
    return switch (options.action) {
        .list => list(alloc, arena, options, &loaded),
        .@"test" => runTest(alloc, arena, options, &loaded, workspace_root),
        .scan => scan(alloc, arena, options, &loaded, workspace_root),
    };
}

fn fail(alloc: Allocator, format: output_contracts.OutputFormat, message: []const u8) !Result {
    const output = switch (format) {
        .json => try alloc.print("{f}\n", .{std.json.fmt(.{ .@"error" = message }, .{})}),
        .text => try alloc.print("ttsr: {s}\n", .{message}),
    };
    return .{ .output = output, .format = format, .succeeded = false };
}

fn list(alloc: Allocator, arena: Allocator, options: Options, loaded: *Loaded) !Result {
    const rows = try arena.alloc(snapshot.RuleRow, loaded.rules.len);
    for (loaded.rules, rows) |rule, *row| {
        var errors: std.ArrayList([]const u8) = .empty;
        for (loaded.manager.errors.items) |failure| if (std.mem.eql(u8, failure.rule, rule.name)) try errors.append(arena, failure.message);
        const entry = loaded.manager.find(rule.name);
        row.* = .{
            .name = rule.name,
            .path = rule.path,
            .provider = rule.provider.label(),
            .condition = if (entry) |e| e.program.description else null,
            .errors = errors.items,
            .scope = rule.scope,
            .globs = rule.globs,
            .interrupt_mode = if (rule.interrupt_mode) |mode| mode.label() else null,
            .description = rule.description,
        };
    }
    const output = try (snapshot.ListSnapshot{ .rules = rows, .warnings = loaded.warnings }).render(alloc, options.format);
    return .{ .output = output, .format = options.format, .succeeded = true };
}

const source_extensions = [_][]const u8{ "ts", "tsx", "js", "jsx", "mjs", "cjs", "rs", "py", "go", "java", "kt", "swift", "c", "cc", "cpp", "h", "hpp", "rb", "php", "lua", "css", "scss", "html", "json", "yaml", "yml", "toml", "md", "mdc", "cs", "sh", "bash", "sql", "zig", "dart", "scala", "ex", "exs", "proto", "tf" };

fn isSourcePath(path: []const u8) bool {
    var buf: [16]u8 = undefined;
    const lang = ttsr.paths.deriveLang(&buf, &.{path}) orelse return false;
    for (source_extensions) |ext| if (std.mem.eql(u8, ext, lang)) return true;
    return false;
}

fn readSnippet(arena: Allocator, options: Options) ![]const u8 {
    const file = options.file orelse return options.snippet.?;
    const io = io_mod.getIo();
    if (std.mem.eql(u8, file, "-")) {
        var stdin = std.Io.File.stdin();
        return io_mod.readFileToEnd(arena, &stdin, max_snippet_bytes);
    }
    var handle = try std.Io.Dir.cwd().openFile(io, file, .{});
    defer handle.close(io);
    return io_mod.readFileToEnd(arena, &handle, max_snippet_bytes);
}

fn runTest(alloc: Allocator, arena: Allocator, options: Options, loaded: *Loaded, workspace_root: []const u8) !Result {
    const snippet = readSnippet(arena, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(alloc, options.format, "the snippet file could not be read"),
    };
    const file_path: ?[]const u8 = options.path orelse if (options.file) |file|
        (if (std.mem.eql(u8, file, "-")) null else try std.Io.Dir.path.resolveAlloc(arena, &.{ workspace_root, file }))
    else
        null;
    const inferred_tool = if (file_path) |path| isSourcePath(path) else false;
    const source = options.source orelse if (inferred_tool) ttsr.evaluate.Source.tool else .text;
    const tool: ?[]const u8 = options.tool orelse if (source == .tool) "shell" else null;
    var note: ?[]const u8 = null;
    if (options.source == null and file_path != null and source == .text) {
        note = "inferred --source text from the file's extension; pass --source tool --tool shell to evaluate tool rules";
    }
    const paths: []const []const u8 = if (file_path) |path| blk: {
        const one = try arena.alloc([]const u8, 1);
        one[0] = path;
        break :blk one;
    } else &.{};
    const shell_without_path = tool != null and std.mem.eql(u8, tool.?, "shell") and file_path == null;
    const matches = try loaded.manager.checkSnapshot(snippet, .{
        .source = source,
        .key = "ttsr-test",
        .tool_name = tool,
        .file_paths = paths,
        .lang = if (shell_without_path) "bash" else null,
        .settled = true,
    });
    var triggered: std.ArrayList(snapshot.Hit) = .empty;
    var not_triggered: std.ArrayList(snapshot.Hit) = .empty;
    for (loaded.manager.entries.items) |*entry| {
        const found = for (matches) |match| {
            if (match.entry == entry) break match;
        } else null;
        if (found) |match| try triggered.append(arena, try hitFor(arena, entry, match.evidence)) else try not_triggered.append(arena, try hitFor(arena, entry, null));
    }
    var preview: std.ArrayList(u8) = .empty;
    var last_space = false;
    for (std.mem.trim(u8, snippet, " \t\r\n")) |c| {
        const space = std.ascii.isWhitespace(c);
        if (space and last_space) continue;
        last_space = space;
        try preview.append(arena, if (space) ' ' else c);
        if (preview.items.len >= 80) break;
    }
    const result: snapshot.TestSnapshot = .{
        .source = @tagName(source),
        .tool = tool,
        .file_path = file_path,
        .snippet_preview = preview.items,
        .snippet_bytes = snippet.len,
        .evaluated = loaded.manager.entries.items.len,
        .triggered = triggered.items,
        .not_triggered = not_triggered.items,
        .errors = try errorsFor(arena, &loaded.manager),
        .note = note,
        .verbose = options.verbose,
    };
    const output = try result.render(alloc, options.format);
    // A single rule under test that does not fire is a failed check.
    const succeeded = options.rule == null or triggered.items.len > 0;
    return .{ .output = output, .format = options.format, .succeeded = succeeded };
}

fn scan(alloc: Allocator, arena: Allocator, options: Options, loaded: *Loaded, workspace_root: []const u8) !Result {
    const directory = if (options.directory) |dir| try std.Io.Dir.path.resolveAlloc(arena, &.{ workspace_root, dir }) else workspace_root;
    var tree = indexer.scan(arena, directory, .{}, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(alloc, options.format, "the folder could not be read"),
    };
    defer tree.deinit();
    var files: std.ArrayList(snapshot.FileHits) = .empty;
    var summary: snapshot.ScanSnapshot = .{
        .directory = directory,
        .total_files = 0,
        .scanned_files = 0,
        .matched_files = 0,
        .total_matches = 0,
        .evaluated_rules = loaded.manager.entries.items.len,
        .skipped_binary = 0,
        .skipped_large = 0,
        .skipped_unreadable = 0,
        .skipped_no_relevant_rules = 0,
        .max_bytes = options.max_bytes,
        .files = &.{},
        .errors = try errorsFor(arena, &loaded.manager),
        .verbose = options.verbose,
    };
    const io = io_mod.getIo();
    for (tree.tree.entries) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.path, ".git") or std.mem.startsWith(u8, entry.path, ".git/")) continue;
        summary.total_files += 1;
        const absolute = try std.Io.Dir.path.join(arena, &.{ directory, entry.path });
        const content = readScanFile(arena, io, absolute, options.max_bytes) catch |err| {
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FileTooBig => summary.skipped_large += 1,
                error.BinaryFile => summary.skipped_binary += 1,
                else => summary.skipped_unreadable += 1,
            }
            continue;
        };
        var relevant = false;
        for (loaded.manager.entries.items) |rule_entry| if (ttsr.matcher.mayMatch(rule_entry.program, content)) {
            relevant = true;
        };
        if (!relevant) {
            summary.skipped_no_relevant_rules += 1;
            continue;
        }
        summary.scanned_files += 1;
        const paths = try arena.alloc([]const u8, 1);
        paths[0] = absolute;
        const matches = try loaded.manager.checkSnapshot(content, .{
            .source = .tool,
            .key = "ttsr-scan",
            .tool_name = "shell",
            .file_paths = paths,
            .settled = true,
        });
        if (matches.len == 0) continue;
        summary.matched_files += 1;
        summary.total_matches += matches.len;
        const hits = try arena.alloc(snapshot.Hit, matches.len);
        for (matches, hits) |match, *hit| hit.* = try hitFor(arena, match.entry, match.evidence);
        try files.append(arena, .{ .file = try arena.dupe(u8, entry.path), .matches = hits });
    }
    summary.files = files.items;
    const output = try summary.render(alloc, options.format);
    return .{ .output = output, .format = options.format, .succeeded = true };
}

fn readScanFile(arena: Allocator, io: std.Io, path: []const u8, max_bytes: usize) ![]const u8 {
    var handle = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer handle.close(io);
    const stat = try handle.stat(io);
    if (max_bytes > 0 and stat.size > max_bytes) return error.FileTooBig;
    const content = try io_mod.readFileToEnd(arena, &handle, if (max_bytes > 0) max_bytes else max_snippet_bytes);
    if (std.mem.findScalar(u8, content[0..@min(content.len, binary_probe_bytes)], 0) != null) return error.BinaryFile;
    return content;
}

test "ttsr arguments parse per subcommand" {
    const parsed = try parseArgs(&.{ "test", "git push --force", "--source", "tool", "--tool", "shell", "--json" });
    try std.testing.expectEqual(Action.@"test", parsed.action);
    try std.testing.expectEqualStrings("git push --force", parsed.snippet.?);
    try std.testing.expectEqual(ttsr.evaluate.Source.tool, parsed.source.?);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, parsed.format);
    const scanned = try parseArgs(&.{ "scan", "src", "--max-bytes", "100", "--verbose" });
    try std.testing.expectEqualStrings("src", scanned.directory.?);
    try std.testing.expectEqual(@as(usize, 100), scanned.max_bytes);
    for ([_][]const [:0]const u8{ &.{}, &.{"bogus"}, &.{ "list", "extra" }, &.{"test"}, &.{ "scan", "--file", "x" }, &.{ "test", "a", "--source", "nowhere" } }) |bad| {
        try std.testing.expectError(error.InvalidTtsrArguments, parseArgs(bad));
    }
}

test "ttsr test and scan evaluate the workspace rules" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = io_mod.getIo();
    try tmp.dir.createDirPath(io, "ws/.proto-fx/rules");
    try tmp.dir.createDirPath(io, "ws/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "ws/.proto-fx/rules/no-force.md", .data = "---\nscope: tool:shell\nmatch: 'push --force'\n---\nNo force pushes." });
    try tmp.dir.writeFile(io, .{ .sub_path = "ws/.proto-fx/settings-unused", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ws/src/deploy.sh", .data = "#!/bin/sh\ngit push --force origin main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ws/src/clean.sh", .data = "echo ok\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home-marker", .data = "" });
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "ws");
    defer alloc.free(root);
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    const tested = try run(alloc, try parseArgs(&.{ "test", "git push --force", "--source", "tool" }), root, home);
    defer alloc.free(tested.output);
    try std.testing.expect(std.mem.find(u8, tested.output, "✓ no-force [project]") != null);

    const listed = try run(alloc, try parseArgs(&.{ "list", "--json" }), root, home);
    defer alloc.free(listed.output);
    try std.testing.expect(std.mem.find(u8, listed.output, "\"name\":\"no-force\"") != null);

    const scanned = try run(alloc, try parseArgs(&.{ "scan", "--verbose" }), root, home);
    defer alloc.free(scanned.output);
    try std.testing.expect(std.mem.find(u8, scanned.output, "src/deploy.sh\n  ✓ no-force") != null);
    try std.testing.expect(std.mem.find(u8, scanned.output, "src/clean.sh") == null);
}
