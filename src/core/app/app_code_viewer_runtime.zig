const std = @import("std");
const app_lifecycle = @import("app_lifecycle.zig");
const app_render_runtime = @import("app_render_runtime.zig");
const code_highlight = @import("../../ui/render_engine/code_highlight.zig");
const code_highlight_languages = @import("../../ui/render_engine/code_highlight_languages.zig");
const code_viewer_layout = @import("../../ui/code_viewer_layout.zig");
const code_viewer_screen = @import("../../ui/code_viewer_screen.zig");
const diff_mod = @import("../output/diff.zig");
const io_mod = @import("../shared/io.zig");
const pathing = @import("../workspace/pathing.zig");
const text_utils = @import("../shared/text_utils.zig");
const transcript_blocks = @import("../../ui/render_engine/transcript_blocks.zig");
const ui_render = @import("../../ui/render.zig");

const Allocator = std.mem.Allocator;
const ToolDetailRecord = transcript_blocks.ToolDetailRecord;

pub const max_view_file_bytes: usize = 2 * 1024 * 1024;
const max_highlight_bytes: usize = 256 * 1024;

pub const Kind = code_viewer_screen.Kind;
pub const Mode = code_viewer_screen.Mode;
pub const DiffLayout = code_viewer_screen.DiffLayout;

pub const OpenSpec = struct {
    path: []const u8 = "",
    line: ?u32 = null,
    want_diff: bool = false,
};

pub const Session = struct {
    alloc: Allocator = std.heap.page_allocator,
    kind: Kind = .file,
    path: []u8 = &.{},
    source: []u8 = &.{},
    old_text: []u8 = &.{},
    new_text: []u8 = &.{},
    highlighted: []u8 = &.{},
    lines: std.ArrayList([]const u8) = .empty,
    highlighted_lines: std.ArrayList([]const u8) = .empty,
    diff_lines: []diff_mod.DiffLine = &.{},
    hunks: std.ArrayList(code_viewer_layout.Hunk) = .empty,
    pairs: std.ArrayList(code_viewer_layout.Pair) = .empty,
    cursor: usize = 0,
    scroll: usize = 0,
    mode: Mode = .browse,
    query: std.ArrayList(u8) = .empty,
    matches: std.ArrayList(usize) = .empty,
    match_index: usize = 0,
    goto_buf: std.ArrayList(u8) = .empty,
    hunk_index: usize = 0,
    diff_layout: DiffLayout = .unified,
    language: []const u8 = "",

    pub fn init(alloc: Allocator) Session {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Session) void {
        self.clear();
        self.lines.deinit(self.alloc);
        self.highlighted_lines.deinit(self.alloc);
        self.hunks.deinit(self.alloc);
        self.pairs.deinit(self.alloc);
        self.query.deinit(self.alloc);
        self.matches.deinit(self.alloc);
        self.goto_buf.deinit(self.alloc);
        self.* = .{ .alloc = self.alloc };
    }

    pub fn active(self: *const Session) bool {
        return self.path.len > 0 or self.source.len > 0 or self.diff_lines.len > 0;
    }

    pub fn clear(self: *Session) void {
        if (self.path.len > 0) self.alloc.free(self.path);
        if (self.source.len > 0) self.alloc.free(self.source);
        if (self.old_text.len > 0) self.alloc.free(self.old_text);
        if (self.new_text.len > 0) self.alloc.free(self.new_text);
        if (self.highlighted.len > 0) self.alloc.free(self.highlighted);
        if (self.diff_lines.len > 0) self.alloc.free(self.diff_lines);
        self.path = &.{};
        self.source = &.{};
        self.old_text = &.{};
        self.new_text = &.{};
        self.highlighted = &.{};
        self.diff_lines = &.{};
        self.lines.clearRetainingCapacity();
        self.highlighted_lines.clearRetainingCapacity();
        self.hunks.clearRetainingCapacity();
        self.pairs.clearRetainingCapacity();
        self.query.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        self.goto_buf.clearRetainingCapacity();
        self.cursor = 0;
        self.scroll = 0;
        self.mode = .browse;
        self.match_index = 0;
        self.hunk_index = 0;
        self.diff_layout = .unified;
        self.language = "";
        self.kind = .file;
    }

    pub fn loadFile(self: *Session, path: []const u8, source: []const u8, line: ?u32) !void {
        self.clear();
        errdefer self.clear();
        self.kind = .file;
        self.path = try self.alloc.dupe(u8, path);
        self.source = try self.alloc.dupe(u8, source);
        try code_viewer_layout.splitLines(self.source, &self.lines, self.alloc);
        try self.applyHighlight();
        if (line) |target| self.gotoLine(target);
    }

    pub fn loadDiff(
        self: *Session,
        path: []const u8,
        old_text: []const u8,
        new_text: []const u8,
        line: ?u32,
    ) !void {
        self.clear();
        errdefer self.clear();
        self.kind = .diff;
        self.path = try self.alloc.dupe(u8, path);
        self.old_text = try self.alloc.dupe(u8, old_text);
        self.new_text = try self.alloc.dupe(u8, new_text);
        self.diff_lines = try diff_mod.compute(self.alloc, self.old_text, self.new_text);
        try code_viewer_layout.collectHunks(self.diff_lines, &self.hunks, self.alloc);
        try code_viewer_layout.pairDiffLines(self.diff_lines, &self.pairs, self.alloc);
        if (line) |target| {
            self.jumpToNewLine(target);
        } else if (self.hunks.items.len > 0) {
            self.hunk_index = 0;
            self.cursor = self.hunks.items[0].first_change;
        }
    }

    pub fn displayLineCount(self: *const Session) usize {
        return switch (self.kind) {
            .file => self.lines.items.len,
            .diff => switch (self.diff_layout) {
                .unified => self.diff_lines.len,
                .side_by_side => self.pairs.items.len,
            },
        };
    }

    pub fn moveBy(self: *Session, delta: isize) void {
        const count = self.displayLineCount();
        if (count == 0) {
            self.cursor = 0;
            return;
        }
        if (delta < 0) {
            const steps: usize = @intCast(-delta);
            self.cursor -|= steps;
        } else {
            const steps: usize = @intCast(delta);
            self.cursor = @min(self.cursor + steps, count - 1);
        }
    }

    pub fn pageBy(self: *Session, delta: isize, body_rows: usize) void {
        const span: isize = @intCast(@max(body_rows, 1));
        self.moveBy(delta * span);
    }

    pub fn gotoTop(self: *Session) void {
        self.cursor = 0;
    }

    pub fn gotoBottom(self: *Session) void {
        const count = self.displayLineCount();
        self.cursor = if (count == 0) 0 else count - 1;
    }

    pub fn gotoLine(self: *Session, line: u32) void {
        if (self.kind == .diff) {
            self.jumpToNewLine(line);
            return;
        }
        const count = self.displayLineCount();
        if (count == 0 or line == 0) {
            self.cursor = 0;
            return;
        }
        self.cursor = @min(@as(usize, line - 1), count - 1);
    }

    pub fn syncScroll(self: *Session, body_rows: usize) void {
        self.scroll = code_viewer_layout.clampScroll(
            self.scroll,
            self.cursor,
            body_rows,
            self.displayLineCount(),
        );
    }

    pub fn beginSearch(self: *Session) !void {
        self.mode = .search;
        self.query.clearRetainingCapacity();
        try self.refreshMatches();
    }

    pub fn searchFor(self: *Session, query: []const u8) !void {
        self.mode = .search;
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(self.alloc, query);
        try self.refreshMatches();
        self.jumpToCurrentMatch();
    }

    pub fn beginGoto(self: *Session) void {
        self.mode = .goto_line;
        self.goto_buf.clearRetainingCapacity();
    }

    pub fn cancelPrompt(self: *Session) void {
        if (self.mode == .search) {
            self.query.clearRetainingCapacity();
            self.matches.clearRetainingCapacity();
            self.match_index = 0;
        } else {
            self.goto_buf.clearRetainingCapacity();
        }
        self.mode = .browse;
    }

    pub fn appendPromptByte(self: *Session, byte: u8) !void {
        switch (self.mode) {
            .search => {
                if (byte >= 32 and byte < 127) {
                    try self.query.append(self.alloc, byte);
                    try self.refreshMatches();
                    self.jumpToCurrentMatch();
                }
            },
            .goto_line => {
                if (byte >= '0' and byte <= '9' and self.goto_buf.items.len < 10) {
                    try self.goto_buf.append(self.alloc, byte);
                }
            },
            .browse => {},
        }
    }

    pub fn deletePromptByte(self: *Session) !void {
        switch (self.mode) {
            .search => {
                if (self.query.items.len > 0) {
                    _ = self.query.pop();
                    try self.refreshMatches();
                }
            },
            .goto_line => {
                if (self.goto_buf.items.len > 0) _ = self.goto_buf.pop();
            },
            .browse => {},
        }
    }

    pub fn confirmPrompt(self: *Session) void {
        switch (self.mode) {
            .search => {
                self.mode = .browse;
                self.jumpToCurrentMatch();
            },
            .goto_line => {
                const parsed = std.fmt.parseInt(u32, self.goto_buf.items, 10) catch 0;
                if (parsed > 0) self.gotoLine(parsed);
                self.goto_buf.clearRetainingCapacity();
                self.mode = .browse;
            },
            .browse => {},
        }
    }

    pub fn nextMatch(self: *Session) void {
        if (self.matches.items.len == 0) return;
        self.match_index = (self.match_index + 1) % self.matches.items.len;
        self.jumpToCurrentMatch();
    }

    pub fn previousMatch(self: *Session) void {
        if (self.matches.items.len == 0) return;
        self.match_index = if (self.match_index == 0)
            self.matches.items.len - 1
        else
            self.match_index - 1;
        self.jumpToCurrentMatch();
    }

    pub fn nextHunk(self: *Session) void {
        if (self.hunks.items.len == 0) return;
        self.hunk_index = (self.hunk_index + 1) % self.hunks.items.len;
        self.cursorForHunk();
    }

    pub fn previousHunk(self: *Session) void {
        if (self.hunks.items.len == 0) return;
        self.hunk_index = if (self.hunk_index == 0)
            self.hunks.items.len - 1
        else
            self.hunk_index - 1;
        self.cursorForHunk();
    }

    pub fn toggleDiffLayout(self: *Session) void {
        if (self.kind != .diff) return;
        self.diff_layout = switch (self.diff_layout) {
            .unified => .side_by_side,
            .side_by_side => .unified,
        };
        if (self.diff_layout == .side_by_side) {
            self.cursor = code_viewer_layout.pairIndexForDiffIndex(self.pairs.items, self.cursor);
        } else if (self.hunks.items.len > 0) {
            self.cursorForHunk();
        } else {
            self.cursor = @min(self.cursor, self.diff_lines.len -| 1);
        }
    }

    fn applyHighlight(self: *Session) !void {
        self.language = code_viewer_layout.profileLabelForPath(self.path);
        if (self.source.len == 0 or self.source.len > max_highlight_bytes) return;
        const profile = code_highlight_languages.resolve(self.language) orelse
            code_highlight_languages.infer(self.alloc, self.source) orelse return;
        if (self.language.len == 0) self.language = profile.label;
        const theme: code_highlight.Theme = if (ui_render.is_light) .light else .dark;
        self.highlighted = code_highlight.highlight(self.alloc, self.source, profile, theme) catch return;
        try code_viewer_layout.splitLines(self.highlighted, &self.highlighted_lines, self.alloc);
    }

    fn refreshMatches(self: *Session) !void {
        const haystacks: []const []const u8 = switch (self.kind) {
            .file => self.lines.items,
            .diff => blk: {
                // Search the raw unified text, then map back through display rows.
                break :blk &.{};
            },
        };
        if (self.kind == .file) {
            try code_viewer_layout.collectMatches(haystacks, self.query.items, &self.matches, self.alloc);
        } else {
            self.matches.clearRetainingCapacity();
            const query = self.query.items;
            if (query.len == 0) return;
            switch (self.diff_layout) {
                .unified => {
                    for (self.diff_lines, 0..) |line, index| {
                        if (code_viewer_layout.lineMatches(line.text, query)) {
                            try self.matches.append(self.alloc, index);
                        }
                    }
                },
                .side_by_side => {
                    for (self.pairs.items, 0..) |pair, index| {
                        const left = if (pair.left) |line| line.text else "";
                        const right = if (pair.right) |line| line.text else "";
                        if (code_viewer_layout.lineMatches(left, query) or
                            code_viewer_layout.lineMatches(right, query))
                        {
                            try self.matches.append(self.alloc, index);
                        }
                    }
                },
            }
        }
        if (self.matches.items.len == 0) {
            self.match_index = 0;
            return;
        }
        var best: usize = 0;
        for (self.matches.items, 0..) |line_index, i| {
            if (line_index >= self.cursor) {
                best = i;
                break;
            }
            best = i;
        }
        self.match_index = best;
    }

    fn jumpToCurrentMatch(self: *Session) void {
        if (self.matches.items.len == 0) return;
        self.cursor = self.matches.items[self.match_index];
    }

    fn cursorForHunk(self: *Session) void {
        if (self.hunks.items.len == 0) return;
        const hunk = self.hunks.items[self.hunk_index];
        self.cursor = switch (self.diff_layout) {
            .unified => hunk.first_change,
            .side_by_side => code_viewer_layout.pairIndexForDiffIndex(self.pairs.items, hunk.first_change),
        };
    }

    fn jumpToNewLine(self: *Session, line: u32) void {
        if (line == 0) {
            self.cursor = 0;
            return;
        }
        switch (self.diff_layout) {
            .unified => {
                for (self.diff_lines, 0..) |diff_line, index| {
                    if (diff_line.new_num == line) {
                        self.cursor = index;
                        return;
                    }
                }
                self.cursor = self.diff_lines.len -| 1;
            },
            .side_by_side => {
                for (self.pairs.items, 0..) |pair, index| {
                    if (pair.right) |right| {
                        if (right.new_num == line) {
                            self.cursor = index;
                            return;
                        }
                    }
                }
                self.cursor = self.pairs.items.len -| 1;
            },
        }
    }
};

pub const ParsedOpen = struct {
    path: []const u8 = "",
    line: ?u32 = null,
    want_diff: bool = false,
};

pub fn parseOpenPayload(payload: []const u8) ParsedOpen {
    var rest = std.mem.trim(u8, payload, " \t");
    var want_diff = false;
    if (std.mem.startsWith(u8, rest, "--diff")) {
        const after = rest["--diff".len..];
        if (after.len == 0 or after[0] == ' ' or after[0] == '\t') {
            want_diff = true;
            rest = std.mem.trim(u8, after, " \t");
        }
    }
    const split = splitPathAndLine(rest);
    return .{
        .path = split.path,
        .line = split.line,
        .want_diff = want_diff,
    };
}

pub fn splitPathAndLine(spec: []const u8) struct { path: []const u8, line: ?u32 } {
    if (spec.len == 0) return .{ .path = "", .line = null };
    if (std.mem.lastIndexOfScalar(u8, spec, ':')) |index| {
        if (index > 0 and index + 1 < spec.len) {
            const suffix = spec[index + 1 ..];
            if (allDigits(suffix)) {
                const line = std.fmt.parseInt(u32, suffix, 10) catch
                    return .{ .path = spec, .line = null };
                if (line > 0) return .{ .path = spec[0..index], .line = line };
            }
        }
    }
    return .{ .path = spec, .line = null };
}

pub const ToolViewTarget = union(enum) {
    file: struct { path: []const u8 },
    diff: struct { path: []const u8, old_text: []const u8, new_text: []const u8 },
};

pub fn lastViewableTool(
    details: []const ToolDetailRecord,
    want_diff: bool,
    path_filter: []const u8,
) ?ToolViewTarget {
    var index = details.len;
    while (index > 0) {
        index -= 1;
        const detail = details[index];
        if (detail.outcome != null and detail.outcome != .completed) continue;
        const target = viewTargetFromDetail(detail) orelse continue;
        if (want_diff and target != .diff) continue;
        if (!want_diff and target == .diff) {
            // A later read_file wins for a file view; keep scanning for one.
            if (path_filter.len == 0) {
                // Prefer a file when not asking for a diff, but accept a diff if
                // it is the only remaining viewable result.
            } else if (!pathMatches(target, path_filter)) continue;
        }
        if (path_filter.len > 0 and !pathMatches(target, path_filter)) continue;
        if (!want_diff and target == .diff) continue;
        return target;
    }
    if (!want_diff) {
        index = details.len;
        while (index > 0) {
            index -= 1;
            const detail = details[index];
            if (detail.outcome != null and detail.outcome != .completed) continue;
            const target = viewTargetFromDetail(detail) orelse continue;
            if (path_filter.len > 0 and !pathMatches(target, path_filter)) continue;
            return target;
        }
    }
    return null;
}

pub fn viewTargetFromDetail(detail: ToolDetailRecord) ?ToolViewTarget {
    const args = detail.arguments_json orelse {
        if (std.mem.eql(u8, detail.tool_name, "read_file")) {
            if (detail.result) |body| {
                if (pathFromResultBody(body)) |path| return .{ .file = .{ .path = path } };
            }
        }
        return null;
    };
    if (std.mem.eql(u8, detail.tool_name, "edit_file")) {
        const path = jsonStringField(args, "path") orelse return null;
        const old_text = jsonStringField(args, "old_string") orelse return null;
        const new_text = jsonStringField(args, "new_string") orelse return null;
        return .{ .diff = .{ .path = path, .old_text = old_text, .new_text = new_text } };
    }
    if (std.mem.eql(u8, detail.tool_name, "read_file") or
        std.mem.eql(u8, detail.tool_name, "write_file") or
        std.mem.eql(u8, detail.tool_name, "open_file"))
    {
        const path = jsonStringField(args, "path") orelse return null;
        return .{ .file = .{ .path = path } };
    }
    return null;
}

pub fn toolResultIsViewable(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "read_file") or
        std.mem.eql(u8, tool_name, "edit_file") or
        std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "open_file");
}

fn pathMatches(target: ToolViewTarget, filter: []const u8) bool {
    const path = switch (target) {
        .file => |file| file.path,
        .diff => |diff| diff.path,
    };
    return std.mem.eql(u8, path, filter) or std.mem.endsWith(u8, path, filter);
}

fn pathFromResultBody(body: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, body, "<path>")) return null;
    const close = std.mem.find(u8, body, "</path>") orelse return null;
    const path = body["<path>".len..close];
    if (path.len == 0) return null;
    return path;
}

fn jsonStringField(args_json: []const u8, key: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index + key.len + 3 < args_json.len) : (index += 1) {
        if (args_json[index] != '"') continue;
        if (!std.mem.startsWith(u8, args_json[index + 1 ..], key)) continue;
        if (args_json[index + 1 + key.len] != '"') continue;
        var cursor = index + 2 + key.len;
        cursor = skipJsonSpace(args_json, cursor);
        if (cursor >= args_json.len or args_json[cursor] != ':') continue;
        cursor = skipJsonSpace(args_json, cursor + 1);
        if (cursor >= args_json.len or args_json[cursor] != '"') continue;
        const start = cursor + 1;
        var end = start;
        while (end < args_json.len) : (end += 1) {
            if (args_json[end] == '\\' and end + 1 < args_json.len) {
                end += 1;
                continue;
            }
            if (args_json[end] == '"') return args_json[start..end];
        }
        return null;
    }
    return null;
}

fn skipJsonSpace(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len) : (index += 1) {
        switch (text[index]) {
            ' ', '\t', '\n', '\r' => {},
            else => return index,
        }
    }
    return index;
}

fn allDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    return true;
}

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn handleView(app: *App, payload: []const u8) !void {
            const parsed = parseOpenPayload(payload);
            if (parsed.path.len == 0) {
                try openLastToolResult(app, parsed.want_diff, parsed.path, parsed.line);
                return;
            }
            if (parsed.want_diff) {
                try openLastToolResult(app, true, parsed.path, parsed.line);
                return;
            }
            try openPath(app, parsed.path, parsed.line);
        }

        pub fn gotoDefinition(app: *App) !void {
            if (comptime !@hasField(App, "lsp") or !@hasField(App, "code_viewer")) return;
            if (app.lsp.clients.items.len == 0) {
                try writeViewNotice(app, .neutral, "No language server is running. Start one with fx.lsp.start.");
                return;
            }
            if (app.code_viewer.kind != .file or app.code_viewer.path.len == 0) return;
            const line: u32 = @intCast(app.code_viewer.cursor);
            const location = app.lsp.definition(app.code_viewer.path, line, 0) catch null;
            const found = location orelse {
                try writeViewNotice(app, .neutral, "No definition found.");
                return;
            };
            defer found.deinit(app.alloc);
            const protocol = @import("../lsp/protocol.zig");
            const path = protocol.decodeUriPath(app.alloc, found.uri) catch {
                try writeViewNotice(app, .@"error", "Definition path is invalid.");
                return;
            };
            defer app.alloc.free(path);
            try openPath(app, path, found.line + 1);
        }

        pub fn openPath(app: *App, path: []const u8, line: ?u32) !void {
            if (comptime @hasField(App, "code_viewer") and @hasField(App, "terminal")) {
                const source = readWorkspaceFile(app, path) catch |err| {
                    try noticePathError(app, path, err);
                    return;
                };
                defer app.alloc.free(source);
                prepareScreen(app) catch |err| {
                    try noticePathError(app, path, err);
                    return;
                };
                app.code_viewer.loadFile(path, source, line) catch |err| {
                    try noticePathError(app, path, err);
                    return;
                };
                if (comptime @hasField(App, "lsp")) {
                    const app_lsp_runtime = @import("app_lsp_runtime.zig");
                    app_lsp_runtime.Runtime(App).didOpen(app, path, source);
                }
                try enterScreen(app);
                return;
            }
            try writeViewNotice(app, .@"error", "The code viewer is unavailable in this runtime.");
        }

        pub fn openDiff(
            app: *App,
            path: []const u8,
            old_text: []const u8,
            new_text: []const u8,
            line: ?u32,
        ) !void {
            if (comptime @hasField(App, "code_viewer") and @hasField(App, "terminal")) {
                prepareScreen(app) catch |err| {
                    try noticePathError(app, path, err);
                    return;
                };
                app.code_viewer.loadDiff(path, old_text, new_text, line) catch |err| {
                    try noticePathError(app, path, err);
                    return;
                };
                try enterScreen(app);
                return;
            }
            try writeViewNotice(app, .@"error", "The code viewer is unavailable in this runtime.");
        }

        pub fn close(app: *App) !void {
            if (comptime @hasField(App, "code_viewer")) {
                if (comptime @hasField(App, "terminal")) {
                    if (app.terminal.codeViewerScreenActive()) {
                        try app_lifecycle.leaveCodeViewerScreen(
                            &app.terminal,
                            &app.shell,
                            &app.metrics,
                        );
                        try app_render_runtime.Runtime(App).requestNormalViewportRecovery(app);
                    }
                }
                app.code_viewer.clear();
            }
        }

        pub fn closeIfActive(app: *App) !bool {
            if (comptime @hasField(App, "code_viewer")) {
                if (!app.code_viewer.active()) return false;
                try close(app);
                return true;
            }
            return false;
        }

        fn openLastToolResult(app: *App, want_diff: bool, path_filter: []const u8, line: ?u32) !void {
            if (comptime !@hasField(App, "shell")) {
                try writeViewNotice(app, .@"error", "No tool result is available to view.");
                return;
            }
            const target = lastViewableTool(app.shell.tool_details.items, want_diff, path_filter) orelse {
                const message = if (want_diff)
                    "No edit diff is available. Run an edit, or pass /view <path>."
                else
                    "No file is available. Pass /view <path> or run read_file first.";
                try writeViewNotice(app, .neutral, message);
                return;
            };
            switch (target) {
                .file => |file| try openPath(app, file.path, line),
                .diff => |diff| try openDiff(app, diff.path, diff.old_text, diff.new_text, line),
            }
        }

        fn prepareScreen(app: *App) !void {
            if (comptime @hasField(App, "skills")) app.skills.closeMenu();
            if (comptime @hasField(App, "model_cache")) app.model_cache.closeMenu();
            if (comptime @hasField(App, "input_runtime")) {
                app.input_runtime.help_menu.close();
                app.input_runtime.settings_menu.close();
            }
            if (comptime !@hasField(App, "terminal")) return;
            if (app.terminal.fileApprovalScreenActive() or
                app.terminal.terminalSessionScreenActive() or
                app.terminal.subagentManagerScreenActive())
            {
                return error.AlternateScreenAlreadyOwned;
            }
            if (app.terminal.fullTranscriptScreenActive()) {
                try app_lifecycle.closeFullTranscript(
                    app.alloc,
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                );
            }
            if (app.terminal.catalogMenuScreenActive()) {
                try app_lifecycle.leaveCatalogMenuScreen(
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                );
            }
        }

        fn enterScreen(app: *App) !void {
            if (comptime @hasField(App, "terminal") and @hasField(App, "code_viewer")) {
                app_lifecycle.enterCodeViewerScreen(
                    &app.terminal,
                    &app.shell,
                    &app.metrics,
                ) catch |err| {
                    app.code_viewer.clear();
                    if (err == error.AlternateScreenAlreadyOwned) {
                        try writeViewNotice(app, .@"error", "Close the current full-screen view before opening the code viewer.");
                        return;
                    }
                    return err;
                };
                app_render_runtime.Runtime(App).requestActiveSurfaceFrame(app, .modal);
            }
        }

        fn readWorkspaceFile(app: *App, path: []const u8) ![]u8 {
            var arena_state = std.heap.ArenaAllocator.init(app.alloc);
            defer arena_state.deinit();
            const workspace = if (comptime @hasField(App, "workspace_root")) app.workspace_root else "";
            const target = try pathing.resolveWorkspaceOrExternalPath(
                arena_state.allocator(),
                workspace,
                path,
            );
            var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), target, .{});
            defer file.close(io_mod.getIo());
            const content = try io_mod.readFileToEnd(app.alloc, &file, max_view_file_bytes + 1);
            errdefer app.alloc.free(content);
            if (content.len > max_view_file_bytes) return error.FileTooBig;
            if (!text_utils.isModelSafeText(content)) return error.BinaryFile;
            return content;
        }

        fn writeViewNotice(app: *App, tone: @import("../shared/types.zig").NoticeTone, body: []const u8) !void {
            try app.writeDomainNotice(.{
                .topic = "view",
                .tone = tone,
                .body = body,
            }, true);
        }

        fn noticePathError(app: *App, path: []const u8, err: anyerror) !void {
            const reason = switch (err) {
                error.FileNotFound => "file not found",
                error.FileTooBig => "file is larger than the 2 MiB viewer limit",
                error.BinaryFile => "binary file omitted",
                error.IsDir => "path is a directory",
                error.AccessDenied, error.PermissionDenied => "access denied",
                error.PathOutsideWorkspace => "path is outside the workspace",
                error.AlternateScreenAlreadyOwned => "another full-screen view is open",
                else => @errorName(err),
            };
            const message = try std.fmt.allocPrint(app.alloc, "Cannot open {s}: {s}.", .{ path, reason });
            defer app.alloc.free(message);
            try app.writeDomainNotice(.{
                .topic = "view",
                .tone = .@"error",
                .body = message,
            }, true);
        }
    };
}

test "parseOpenPayload extracts path line and diff flag" {
    const file = parseOpenPayload("src/main.zig:12");
    try std.testing.expectEqualStrings("src/main.zig", file.path);
    try std.testing.expectEqual(@as(?u32, 12), file.line);
    try std.testing.expect(!file.want_diff);

    const diff = parseOpenPayload("--diff src/app.zig");
    try std.testing.expectEqualStrings("src/app.zig", diff.path);
    try std.testing.expect(diff.want_diff);

    const empty = parseOpenPayload("  ");
    try std.testing.expectEqualStrings("", empty.path);
    try std.testing.expect(!empty.want_diff);
}

test "session search goto and hunk navigation stay in range" {
    const alloc = std.testing.allocator;
    var session = Session.init(alloc);
    defer session.deinit();
    try session.loadFile("demo.zig", "alpha\nbeta\nalphabet\n", 2);
    try std.testing.expectEqual(@as(usize, 1), session.cursor);
    try std.testing.expectEqual(@as(usize, 4), session.displayLineCount());
    try std.testing.expectEqualStrings("alpha", session.lines.items[0]);
    try session.searchFor("alp");
    try std.testing.expectEqualStrings("alp", session.query.items);
    try std.testing.expectEqual(@as(usize, 2), session.matches.items.len);
    try std.testing.expectEqual(@as(usize, 2), session.cursor);
    session.confirmPrompt();
    try std.testing.expectEqual(Mode.browse, session.mode);
    session.nextMatch();
    try std.testing.expectEqual(@as(usize, 0), session.cursor);
    session.gotoLine(1);
    try std.testing.expectEqual(@as(usize, 0), session.cursor);

    var diff_session = Session.init(alloc);
    defer diff_session.deinit();
    try diff_session.loadDiff("demo.txt", "keep\nold\n", "keep\nnew\n", null);
    try std.testing.expectEqual(Kind.diff, diff_session.kind);
    try std.testing.expectEqual(@as(usize, 1), diff_session.hunks.items.len);
    try std.testing.expectEqual(@as(usize, 1), diff_session.cursor);
    diff_session.nextHunk();
    try std.testing.expectEqual(@as(usize, 1), diff_session.cursor);
    diff_session.toggleDiffLayout();
    try std.testing.expectEqual(DiffLayout.side_by_side, diff_session.diff_layout);
    try std.testing.expectEqual(@as(usize, 1), diff_session.cursor);
}

test "last viewable tool prefers a completed read_file" {
    const details = [_]ToolDetailRecord{
        .{
            .entry_id = 1,
            .tool_name = @constCast("read_file"),
            .arguments_json = @constCast("{\"path\":\"src/a.zig\"}"),
            .outcome = .completed,
        },
        .{
            .entry_id = 2,
            .tool_name = @constCast("edit_file"),
            .arguments_json = @constCast("{\"path\":\"src/b.zig\",\"old_string\":\"old\",\"new_string\":\"new\"}"),
            .outcome = .completed,
        },
    };
    const file = lastViewableTool(&details, false, "") orelse return error.TestExpectedEqual;
    switch (file) {
        .file => |value| try std.testing.expectEqualStrings("src/a.zig", value.path),
        else => return error.TestExpectedEqual,
    }
    const diff = lastViewableTool(&details, true, "") orelse return error.TestExpectedEqual;
    switch (diff) {
        .diff => |value| {
            try std.testing.expectEqualStrings("src/b.zig", value.path);
            try std.testing.expectEqualStrings("old", value.old_text);
            try std.testing.expectEqualStrings("new", value.new_text);
        },
        else => return error.TestExpectedEqual,
    }
}

test "tool result body path is a viewable fallback" {
    const detail = ToolDetailRecord{
        .entry_id = 3,
        .tool_name = @constCast("read_file"),
        .result = @constCast("<path>README.md</path>\n<content>\nhi\n</content>"),
        .outcome = .completed,
    };
    const target = viewTargetFromDetail(detail) orelse return error.TestExpectedEqual;
    switch (target) {
        .file => |file| try std.testing.expectEqualStrings("README.md", file.path),
        else => return error.TestExpectedEqual,
    }
    try std.testing.expect(toolResultIsViewable("read_file"));
    try std.testing.expect(toolResultIsViewable("edit_file"));
    try std.testing.expect(!toolResultIsViewable("run_command"));
}
