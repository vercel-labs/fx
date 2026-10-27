//! `proto-fx ttsr list|test|scan` output: each subcommand fills one snapshot
//! and renders it as text or JSON.
const std = @import("std");

const Allocator = std.mem.Allocator;
const OutputFormat = @import("output_contracts.zig").OutputFormat;

pub const Snippet = struct { line: usize, text: []const u8 };

pub const RuleRow = struct {
    name: []const u8,
    path: []const u8,
    provider: []const u8,
    /// The compiled condition, or null when it did not compile.
    condition: ?[]const u8,
    errors: []const []const u8 = &.{},
    scope: []const []const u8 = &.{},
    globs: []const []const u8 = &.{},
    interrupt_mode: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub const Hit = struct {
    name: []const u8,
    path: []const u8,
    provider: []const u8,
    condition: []const u8,
    snippets: []const Snippet = &.{},
};

pub const ListSnapshot = struct {
    rules: []const RuleRow,
    warnings: []const []const u8 = &.{},

    pub fn render(self: ListSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        const w = &out.writer;
        switch (format) {
            .json => try std.json.Stringify.value(self, .{}, w),
            .text => {
                if (self.rules.len == 0) {
                    try w.writeAll("No stream rules for this workspace.\n");
                } else {
                    try w.print("Stream rules ({d})\n", .{self.rules.len});
                    for (self.rules) |row| {
                        try w.print("  {s} [{s}]\n", .{ row.name, row.provider });
                        if (row.condition) |condition| try w.print("    condition: {s}\n", .{condition}) else try w.writeAll("    condition: invalid\n");
                        for (row.errors) |message| try w.print("    error: {s}\n", .{message});
                        if (row.scope.len > 0) try writeJoined(w, "    scope: ", row.scope);
                        if (row.globs.len > 0) try writeJoined(w, "    globs: ", row.globs);
                        if (row.interrupt_mode) |mode| try w.print("    interrupt: {s}\n", .{mode});
                        if (row.description) |description| try w.print("    {s}\n", .{firstLine(description)});
                    }
                }
                for (self.warnings) |warning| try w.print("warning: {s}\n", .{warning});
            },
        }
        if (format == .json) try w.writeByte('\n');
        return out.toOwnedSlice();
    }
};

/// What `ttsr test --llm` asked a model (D253).
pub const JudgeReport = struct {
    /// The model that answered last, and the role that picked it; null
    /// role for the profile's own model.
    model: ?[]const u8 = null,
    role: ?[]const u8 = null,
    calls: usize = 0,
    answered: usize = 0,
    /// Why a question went unanswered, when one did.
    unavailable: ?[]const u8 = null,
};

pub const TestSnapshot = struct {
    source: []const u8,
    tool: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    snippet_preview: []const u8,
    snippet_bytes: usize,
    evaluated: usize,
    triggered: []const Hit,
    not_triggered: []const Hit,
    errors: []const RuleError = &.{},
    note: ?[]const u8 = null,
    /// Set with `--llm`.
    judge: ?JudgeReport = null,
    /// Only `--verbose` text lists the rules that did not fire.
    verbose: bool = false,

    pub fn render(self: TestSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        const w = &out.writer;
        switch (format) {
            .json => {
                try std.json.Stringify.value(.{
                    .source = self.source,
                    .tool = self.tool,
                    .file_path = self.file_path,
                    .snippet_preview = self.snippet_preview,
                    .snippet_bytes = self.snippet_bytes,
                    .evaluated = self.evaluated,
                    .triggered = self.triggered,
                    .not_triggered = self.not_triggered,
                    .errors = self.errors,
                    .note = self.note,
                    .judge = self.judge,
                }, .{}, w);
                try w.writeByte('\n');
            },
            .text => {
                try w.print("Rule test · source {s}", .{self.source});
                if (self.tool) |tool| try w.print(":{s}", .{tool});
                if (self.file_path) |path| try w.print(" · path {s}", .{path});
                try w.print(" · {d} bytes\n  \"{s}\"\n", .{ self.snippet_bytes, self.snippet_preview });
                if (self.note) |note| try w.print("note: {s}\n", .{note});
                if (self.judge) |judge| try writeJudge(w, judge);
                for (self.errors) |failure| try w.print("error: {s}: {s}\n", .{ failure.name, failure.message });
                if (self.triggered.len == 0) {
                    try w.print("No rules triggered ({d} evaluated).\n", .{self.evaluated});
                } else {
                    try w.print("Triggered ({d})\n", .{self.triggered.len});
                    for (self.triggered) |hit| try writeHit(w, hit, "✓");
                }
                if (self.verbose and self.not_triggered.len > 0) {
                    try w.print("Not triggered ({d})\n", .{self.not_triggered.len});
                    for (self.not_triggered) |hit| try writeHit(w, hit, "✗");
                }
            },
        }
        return out.toOwnedSlice();
    }
};

fn writeJudge(w: *std.Io.Writer, judge: JudgeReport) !void {
    if (judge.calls == 0) {
        try w.print("judge: {s}\n", .{judge.unavailable orelse "no llm: condition needed a verdict"});
        return;
    }
    try w.print("judge: {s}", .{judge.model orelse "?"});
    if (judge.role) |role| try w.print(" via @{s}", .{role}) else try w.writeAll(" (the profile's model)");
    try w.print(" · {d} of {d} question{s} answered", .{ judge.answered, judge.calls, if (judge.calls == 1) "" else "s" });
    if (judge.unavailable) |reason| try w.print(" · {s}", .{reason});
    try w.writeByte('\n');
}

pub const RuleError = struct { name: []const u8, message: []const u8 };

pub const FileHits = struct { file: []const u8, matches: []const Hit };

pub const ScanSnapshot = struct {
    directory: []const u8,
    total_files: usize,
    scanned_files: usize,
    matched_files: usize,
    total_matches: usize,
    evaluated_rules: usize,
    skipped_binary: usize,
    skipped_large: usize,
    skipped_unreadable: usize,
    skipped_no_relevant_rules: usize,
    max_bytes: usize,
    files: []const FileHits,
    errors: []const RuleError = &.{},
    verbose: bool = false,

    pub fn render(self: ScanSnapshot, alloc: Allocator, format: OutputFormat) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        const w = &out.writer;
        switch (format) {
            .json => {
                try std.json.Stringify.value(.{
                    .files = self.files,
                    .errors = self.errors,
                    .summary = .{
                        .directory = self.directory,
                        .total_files = self.total_files,
                        .scanned_files = self.scanned_files,
                        .matched_files = self.matched_files,
                        .total_matches = self.total_matches,
                        .evaluated_rules = self.evaluated_rules,
                        .skipped = .{
                            .binary = self.skipped_binary,
                            .large = self.skipped_large,
                            .unreadable = self.skipped_unreadable,
                            .no_relevant_rules = self.skipped_no_relevant_rules,
                        },
                        .max_bytes = self.max_bytes,
                    },
                }, .{}, w);
                try w.writeByte('\n');
            },
            .text => {
                try w.print("Rule scan · {s} · {d} files · {d} scanned · {d} rules\n", .{ self.directory, self.total_files, self.scanned_files, self.evaluated_rules });
                for (self.errors) |failure| try w.print("error: {s}: {s}\n", .{ failure.name, failure.message });
                const skipped = self.skipped_binary + self.skipped_large + self.skipped_unreadable + self.skipped_no_relevant_rules;
                if (skipped > 0) try w.print("  skipped: binary {d} · large {d} · unreadable {d} · no relevant rules {d}\n", .{ self.skipped_binary, self.skipped_large, self.skipped_unreadable, self.skipped_no_relevant_rules });
                if (self.matched_files == 0) {
                    try w.writeAll("No rule matches.\n");
                } else {
                    try w.print("{d} matches across {d} files\n", .{ self.total_matches, self.matched_files });
                    if (!self.verbose) {
                        try w.writeAll("  rerun with --verbose to list the files, conditions and lines\n");
                    } else for (self.files) |file| {
                        try w.print("{s}\n", .{file.file});
                        for (file.matches) |hit| try writeHit(w, hit, "✓");
                    }
                }
            },
        }
        return out.toOwnedSlice();
    }
};

fn writeHit(w: *std.Io.Writer, hit: Hit, mark: []const u8) !void {
    try w.print("  {s} {s} [{s}] · {s}\n", .{ mark, hit.name, hit.provider, hit.condition });
    for (hit.snippets) |snippet| try w.print("    L{d}: {s}\n", .{ snippet.line, snippet.text });
}

fn writeJoined(w: *std.Io.Writer, prefix: []const u8, items: []const []const u8) !void {
    try w.writeAll(prefix);
    for (items, 0..) |item, index| {
        if (index > 0) try w.writeAll(", ");
        try w.writeAll(item);
    }
    try w.writeByte('\n');
}

fn firstLine(text: []const u8) []const u8 {
    return std.mem.sliceTo(text, '\n');
}

test "ttsr snapshots render text and json from the same data" {
    const alloc = std.testing.allocator;
    const hit: Hit = .{ .name = "no-force", .path = "/r.md", .provider = "project", .condition = "regex /push --force/", .snippets = &.{.{ .line = 1, .text = "git push --force" }} };
    const test_snapshot: TestSnapshot = .{ .source = "tool", .tool = "shell", .snippet_preview = "git push --force", .snippet_bytes = 16, .evaluated = 2, .triggered = &.{hit}, .not_triggered = &.{} };
    const text = try test_snapshot.render(alloc, .text);
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "✓ no-force [project] · regex /push --force/\n    L1: git push --force") != null);
    const json = try test_snapshot.render(alloc, .json);
    defer alloc.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"triggered\":[{\"name\":\"no-force\"") != null);
    const list: ListSnapshot = .{ .rules = &.{.{ .name = "a", .path = "p", .provider = "built-in", .condition = null, .errors = &.{"bad"} }} };
    const list_text = try list.render(alloc, .text);
    defer alloc.free(list_text);
    try std.testing.expect(std.mem.find(u8, list_text, "condition: invalid\n    error: bad") != null);
    const scan: ScanSnapshot = .{ .directory = "/w", .total_files = 3, .scanned_files = 1, .matched_files = 1, .total_matches = 1, .evaluated_rules = 2, .skipped_binary = 1, .skipped_large = 0, .skipped_unreadable = 0, .skipped_no_relevant_rules = 1, .max_bytes = 10, .files = &.{.{ .file = "a.ts", .matches = &.{hit} }}, .verbose = true };
    const scan_json = try scan.render(alloc, .json);
    defer alloc.free(scan_json);
    try std.testing.expect(std.mem.find(u8, scan_json, "\"skipped\":{\"binary\":1") != null);
}
