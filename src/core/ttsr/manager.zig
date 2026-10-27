//! Registered rules and the per-stream buffers they match against, ported
//! from proto's `TtsrManager`.
//!
//! Every delta appends to its stream's buffer (assistant text, reasoning,
//! or one tool call's argument digest). A rule whose regexes are plain
//! literals is evaluated only once one of them has appeared, found by
//! scanning just the new bytes plus a literal-length overlap; after that the
//! whole buffer is evaluated, so regex width, count and region semantics
//! match a full scan. Buffers never span two responses.
const std = @import("std");
const matcher = @import("matcher.zig");
const evaluate = @import("evaluate.zig");
const rule_mod = @import("rule.zig");
const settings_mod = @import("settings.zig");
const ledger_mod = @import("ledger.zig");
const paths = @import("paths.zig");
const regions = @import("regions.zig");

const Allocator = std.mem.Allocator;
const Rule = rule_mod.Rule;

pub const Entry = struct {
    rule: Rule,
    program: matcher.Program,
    scope: rule_mod.Scope,
    overlap: usize,
};

pub const Match = struct {
    entry: *const Entry,
    evidence: evaluate.Evidence,
};

/// What one buffer is, for scope, paths and evaluation.
pub const StreamContext = struct {
    source: regions.Source,
    /// Buffers with the same key accumulate; a tool call uses its id.
    key: []const u8,
    tool_name: ?[]const u8 = null,
    file_paths: []const []const u8 = &.{},
    lang: ?[]const u8 = null,
    history: []const evaluate.ToolCallRecord = &.{},
    judge: ?evaluate.Judge = null,
    settled: bool = false,
};

pub const CompileError = struct { rule: []const u8, message: []const u8 };

const Scan = struct { processed: usize = 0, seen: bool = false };

const Buffer = struct {
    text: std.ArrayList(u8) = .empty,
    scans: []Scan = &.{},
};

pub const Manager = struct {
    gpa: Allocator,
    /// Rules, programs and compile errors.
    arena: std.heap.ArenaAllocator,
    /// Results of the latest check.
    scratch: std.heap.ArenaAllocator,
    settings: settings_mod.Settings,
    cwd: []const u8,
    home: ?[]const u8,
    entries: std.ArrayList(Entry) = .empty,
    errors: std.ArrayList(CompileError) = .empty,
    buffers: std.StringArrayHashMapUnmanaged(Buffer) = .empty,
    ledger: ledger_mod.Ledger,
    can_match_text: bool = false,
    can_match_thinking: bool = false,

    pub fn init(gpa: Allocator, settings: settings_mod.Settings, cwd: []const u8, home: ?[]const u8) Manager {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .scratch = std.heap.ArenaAllocator.init(gpa),
            .settings = settings,
            .cwd = cwd,
            .home = home,
            .ledger = ledger_mod.Ledger.init(gpa),
        };
    }

    pub fn deinit(self: *Manager) void {
        self.resetBuffers();
        self.buffers.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        self.errors.deinit(self.gpa);
        self.ledger.deinit();
        self.scratch.deinit();
        self.arena.deinit();
    }

    pub fn hasRules(self: *const Manager) bool {
        return self.settings.enabled and self.entries.items.len > 0;
    }

    pub fn hasJudgeRules(self: *const Manager) bool {
        for (self.entries.items) |entry| if (entry.program.needs_judge) return true;
        return false;
    }

    pub fn hasSettledRules(self: *const Manager) bool {
        for (self.entries.items) |entry| if (entry.program.needs_judge or entry.program.needs_ast) return true;
        return false;
    }

    /// Compiles and registers `rule`, copying it into the manager. False
    /// when it does not compile, has no reachable scope, or repeats a name.
    pub fn addRule(self: *Manager, rule: Rule) !bool {
        if (!self.settings.enabled) return false;
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.rule.name, rule.name)) return false;
        const arena = self.arena.allocator();
        const compiled = if (rule.match) |spec| try matcher.compile(arena, spec) else try matcher.compileLegacy(arena, rule.condition, rule.ast_condition);
        for (compiled.errors) |message| try self.errors.append(self.gpa, .{ .rule = rule.name, .message = message });
        const program = compiled.program orelse return false;
        const scope = try rule_mod.buildScope(arena, rule.scope);
        if (!scope.reachable()) {
            try self.errors.append(self.gpa, .{ .rule = rule.name, .message = "scope excludes every stream" });
            return false;
        }
        var overlap: usize = 0;
        for (program.incremental_literals) |literal| overlap = @max(overlap, literal.len -| 1);
        try self.entries.append(self.gpa, .{ .rule = rule, .program = program, .scope = scope, .overlap = overlap });
        if (scope.text) self.can_match_text = true;
        if (scope.thinking) self.can_match_thinking = true;
        // New entries change every buffer's scan table.
        self.resetBuffers();
        return true;
    }

    pub fn resetBuffers(self: *Manager) void {
        for (self.buffers.keys(), self.buffers.values()) |key, *buf| {
            self.gpa.free(key);
            buf.text.deinit(self.gpa);
            self.gpa.free(buf.scans);
        }
        self.buffers.clearRetainingCapacity();
    }

    fn buffer(self: *Manager, key: []const u8) !*Buffer {
        if (self.buffers.getPtr(key)) |existing| return existing;
        const owned = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned);
        const scans = try self.gpa.alloc(Scan, self.entries.items.len);
        @memset(scans, .{});
        errdefer self.gpa.free(scans);
        try self.buffers.put(self.gpa, owned, .{ .scans = scans });
        return self.buffers.getPtr(owned).?;
    }

    /// Appends `delta` to the context's buffer and returns the rules that
    /// now fire. Results live until the next check.
    pub fn checkDelta(self: *Manager, delta: []const u8, ctx: StreamContext) ![]const Match {
        _ = self.scratch.reset(.retain_capacity);
        if (!self.settings.enabled) return &.{};
        if (ctx.source == .text and !self.can_match_text) return &.{};
        if (ctx.source == .thinking and !self.can_match_thinking) return &.{};
        const buf = try self.buffer(ctx.key);
        const previous = buf.text.items.len;
        try buf.text.appendSlice(self.gpa, delta);
        return self.matchCandidates(buf, previous, ctx, true);
    }

    /// Replaces the context's buffer with `snapshot` and evaluates it.
    pub fn checkSnapshot(self: *Manager, snapshot: []const u8, ctx: StreamContext) ![]const Match {
        _ = self.scratch.reset(.retain_capacity);
        if (!self.settings.enabled) return &.{};
        const buf = try self.buffer(ctx.key);
        buf.text.clearRetainingCapacity();
        try buf.text.appendSlice(self.gpa, snapshot);
        @memset(buf.scans, .{});
        return self.matchCandidates(buf, 0, ctx, false);
    }

    fn matchCandidates(self: *Manager, buf: *Buffer, previous: usize, ctx: StreamContext, incremental: bool) ![]const Match {
        const scratch = self.scratch.allocator();
        const text = buf.text.items;
        const targets = try paths.resolveTargets(scratch, ctx.file_paths, self.cwd, self.home);
        var eval_ctx = evaluate.Context.init(scratch, .{
            .text = text,
            .source = ctx.source,
            .lang = ctx.lang,
            .file_paths = ctx.file_paths,
            .tool_name = ctx.tool_name,
            .cwd = self.cwd,
            .home = self.home,
            .history = ctx.history,
            .judge = ctx.judge,
            .settled = ctx.settled,
        });
        var matches: std.ArrayList(Match) = .empty;
        for (self.entries.items, 0..) |*entry, index| {
            if (!self.ledger.canTrigger(self.settings, entry.rule.name)) continue;
            if (!inScope(entry, ctx, targets)) continue;
            if (!matchesGlobalGlobs(entry, targets)) continue;
            if (incremental) {
                if (!mayMatchDelta(entry, &buf.scans[index], text, previous)) continue;
            } else if (!matcher.mayMatch(entry.program, text)) continue;
            const evidence = try evaluate.evaluate(entry.program, &eval_ctx) orelse continue;
            try matches.append(scratch, .{ .entry = entry, .evidence = evidence });
        }
        return matches.items;
    }

    pub fn markInjected(self: *Manager, name: []const u8) !void {
        try self.ledger.mark(name);
    }

    /// One assistant message finished.
    pub fn countMessage(self: *Manager) void {
        self.ledger.message_count += 1;
    }

    pub fn find(self: *const Manager, name: []const u8) ?*const Entry {
        for (self.entries.items) |*entry| if (std.mem.eql(u8, entry.rule.name, name)) return entry;
        return null;
    }
};

/// Before a literal has appeared, only the new bytes and an overlap can
/// hold a new occurrence; once one has, the rule evaluates every time.
fn mayMatchDelta(entry: *const Entry, scan: *Scan, text: []const u8, previous: usize) bool {
    const literals = entry.program.incremental_literals;
    if (literals.len == 0) return true;
    if (scan.seen) {
        scan.processed = text.len;
        return true;
    }
    // A rule out of scope for part of the stream rescans from the start.
    const from = if (scan.processed == previous) previous -| entry.overlap else 0;
    const window = text[from..];
    for (literals) |literal| if (std.mem.find(u8, window, literal) != null) {
        scan.seen = true;
        break;
    };
    scan.processed = text.len;
    return scan.seen;
}

fn inScope(entry: *const Entry, ctx: StreamContext, targets: []const paths.Target) bool {
    switch (ctx.source) {
        .text => return entry.scope.text,
        .thinking => return entry.scope.thinking,
        .tool => {},
    }
    if (entry.scope.any_tool) return true;
    for (entry.scope.tools) |tool_scope| {
        if (tool_scope.tool) |name| {
            const tool_name = ctx.tool_name orelse continue;
            if (!std.ascii.eqlIgnoreCase(name, tool_name)) continue;
        }
        if (tool_scope.path_glob) |glob| if (!paths.matchesAny(glob, targets)) continue;
        return true;
    }
    return false;
}

fn matchesGlobalGlobs(entry: *const Entry, targets: []const paths.Target) bool {
    if (entry.rule.globs.len == 0) return true;
    for (entry.rule.globs) |glob| if (paths.matchesAny(glob, targets)) return true;
    return false;
}

fn testRule(arena: Allocator, name: []const u8, frontmatter: []const u8) !Rule {
    const content = try arena.print("---\n{s}\n---\nBody of {s}.", .{ frontmatter, name });
    return (try rule_mod.parseMarkdown(arena, name, content, "/r.md", .project)).?;
}

test "manager matches deltas incrementally across chunk boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var manager = Manager.init(std.testing.allocator, .{}, "/w", null);
    defer manager.deinit();
    try std.testing.expect(try manager.addRule(try testRule(arena, "no-force", "scope: tool:shell\nmatch: 'push --force'")));
    try std.testing.expect(try manager.addRule(try testRule(arena, "text-rule", "match: { regex: 'TODO', in: prose }")));
    try std.testing.expect(!try manager.addRule(try testRule(arena, "broken", "match: { regex: '(' }")));
    try std.testing.expectEqual(@as(usize, 1), manager.errors.items.len);
    const ctx: StreamContext = .{ .source = .tool, .key = "toolcall:1", .tool_name = "shell", .lang = "bash" };
    try std.testing.expectEqual(@as(usize, 0), (try manager.checkDelta("git push --fo", ctx)).len);
    const fired = try manager.checkDelta("rce origin main", ctx);
    try std.testing.expectEqual(@as(usize, 1), fired.len);
    try std.testing.expectEqualStrings("no-force", fired[0].entry.rule.name);
    // Out of scope: another tool.
    try std.testing.expectEqual(@as(usize, 0), (try manager.checkDelta("git push --force", .{ .source = .tool, .key = "toolcall:2", .tool_name = "write_file" })).len);
    // Thinking is outside the default scope.
    try std.testing.expectEqual(@as(usize, 0), (try manager.checkDelta("TODO", .{ .source = .thinking, .key = "thinking" })).len);
    try std.testing.expectEqual(@as(usize, 1), (try manager.checkDelta("a TODO", .{ .source = .text, .key = "text" })).len);
    try manager.markInjected("no-force");
    try std.testing.expectEqual(@as(usize, 0), (try manager.checkSnapshot("git push --force", ctx)).len);
}

test "manager gates by scope path globs and rule globs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var manager = Manager.init(std.testing.allocator, .{}, "/w", null);
    defer manager.deinit();
    _ = try manager.addRule(try testRule(arena, "py-print", "scope: 'tool:edit_file(**/*.py)'\nmatch: 'print\\('"));
    _ = try manager.addRule(try testRule(arena, "ts-only", "globs: ['*.ts']\nmatch: 'console.log'"));
    const py: StreamContext = .{ .source = .tool, .key = "toolcall:1", .tool_name = "edit_file", .file_paths = &.{"src/app.py"} };
    try std.testing.expectEqual(@as(usize, 1), (try manager.checkSnapshot("print(x)", py)).len);
    var rs = py;
    rs.file_paths = &.{"src/app.rs"};
    try std.testing.expectEqual(@as(usize, 0), (try manager.checkSnapshot("print(x)", rs)).len);
    const ts: StreamContext = .{ .source = .tool, .key = "toolcall:2", .tool_name = "write_file", .file_paths = &.{"web/a.ts"} };
    try std.testing.expectEqual(@as(usize, 1), (try manager.checkSnapshot("console.log(1)", ts)).len);
    try std.testing.expectEqual(@as(usize, 0), (try manager.checkSnapshot("console.log(1)", .{ .source = .text, .key = "text" })).len);
}

test "manager disabled settings register nothing" {
    var manager = Manager.init(std.testing.allocator, .{ .enabled = false }, "/w", null);
    defer manager.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expect(!try manager.addRule(try testRule(arena_state.allocator(), "x", "match: x")));
    try std.testing.expect(!manager.hasRules());
}
