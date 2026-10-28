//! A tool group as it streams in, one call at a time (D291): each frame is
//! the group with the calls so far settled and the newest one running.
//! The user saw the tree jump between a short live view and a full settled
//! one on every call, with earlier calls' output appearing and vanishing
//! under later rows. These tests hold the layout still: a body row always
//! sits under its own call, the tree's connectors close once, the rows of
//! settled calls keep their place when a call starts, and nothing above a
//! call moves when it settles.
const std = @import("std");
const transcript_blocks = @import("render_engine/transcript_blocks.zig");
const projection_mod = @import("transcript/tool_group_projection.zig");

const TranscriptEntry = transcript_blocks.TranscriptEntry;
const ToolDetailRecord = transcript_blocks.ToolDetailRecord;

const Call = struct { command: []const u8, output: []const u8, explores: bool };

/// The live session the user captured, in small: reads, a search, a
/// command that is not a read, and a Python cell.
const calls = [_]Call{
    .{ .command = "ls -la ~/code/proto 2>/dev/null", .output = "README.md\npackages\n", .explores = true },
    .{ .command = "cd ~/code/proto 2>/dev/null && git log --oneline -3 && du -sh packages", .output = "abc1 one\nabc2 two\nabc3 three\n 41M packages\n", .explores = false },
    .{ .command = "cd ~/code/proto && sed -n '1,120p' packages/coding-agent/src/modes/components/assistant-message.ts", .output = "import x\n", .explores = true },
    .{ .command = "cd ~/code/proto && python3 - <<'PY'\nimport os\nfor name in os.listdir('.'):\n    print(name)\nPY", .output = "README.md\npackages\n", .explores = false },
    .{ .command = "cd ~/code/proto && grep -n \"table\" packages/tui/src/components/markdown.ts | head -60", .output = "12: table\n", .explores = true },
    .{ .command = "cd ~/code/proto && make check", .output = "ok\n", .explores = false },
};

const Line = struct { entry_id: u32, text: []const u8 };

const Stage = struct {
    entries: [calls.len]TranscriptEntry = undefined,
    details: [calls.len]ToolDetailRecord = undefined,
    len: usize = 0,

    /// Calls `0..settled` finished and, when `running`, call `settled`
    /// still running.
    fn init(arena: std.mem.Allocator, settled: usize, running: bool) !Stage {
        var stage: Stage = .{};
        const count = settled + @intFromBool(running);
        for (calls[0..count], 0..) |call, index| {
            const entry_id: u32 = @intCast(index + 1);
            const live = index == settled;
            const first_line = call.command[0 .. std.mem.findScalar(u8, call.command, '\n') orelse call.command.len];
            stage.entries[index] = .{ .raw_bytes = .{
                .id = entry_id,
                .bytes = try arena.print("● {s} {s}\n", .{ if (live) "Running" else "Ran", first_line }),
                .class = .tool_status,
            } };
            stage.details[index] = .{
                .entry_id = entry_id,
                .tool_name = @constCast("shell"),
                .activity_kind = .command,
                .arguments_json = try arena.print("{f}", .{std.json.fmt(.{ .action = "run", .command = call.command }, .{})}),
                .command_display = @constCast(call.command),
                .outcome = if (live) null else .completed,
                .command_process_presentation = if (live) null else .{ .exit_code = 0 },
                .result = if (live) null else @constCast(call.output),
            };
        }
        stage.len = count;
        return stage;
    }

    /// The group's rows as plain text with the call each belongs to.
    fn lines(self: *const Stage, arena: std.mem.Allocator) ![]Line {
        var projection = try projection_mod.buildStyled(arena, self.entries[0..self.len], self.details[0..self.len], 120, .{}, .{});
        const action = projection.entry_actions.items[0].override;
        var out: std.ArrayList(Line) = .empty;
        var split = std.mem.splitScalar(u8, action.bytes, '\n');
        var index: usize = 0;
        while (split.next()) |raw| : (index += 1) {
            const entry_id = switch (action.line_provenance[index]) {
                .entry => |entry| entry.entry_id,
                else => 0,
            };
            try out.append(arena, .{ .entry_id = entry_id, .text = try plain(arena, raw) });
        }
        projection.deinit(arena);
        return out.items;
    }
};

fn plain(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b and index + 1 < text.len and text[index + 1] == '[') {
            index += 2;
            while (index < text.len and (text[index] < 0x40 or text[index] > 0x7e)) index += 1;
            index += 1;
            continue;
        }
        try out.append(arena, text[index]);
        index += 1;
    }
    return out.items;
}

fn isBody(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "│") or std.mem.startsWith(u8, text, "    ");
}

/// A body row sits under its own call, and the tree closes once: after
/// `└` no row opens with `├` and bodies drop the rail.
fn expectWellFormed(rows: []const Line) !void {
    var owner: ?u32 = null;
    var closed = false;
    for (rows[1..]) |row| {
        if (isBody(row.text)) {
            try std.testing.expectEqual(owner, row.entry_id);
            try std.testing.expect(std.mem.startsWith(u8, row.text, if (closed) "    " else "│"));
            continue;
        }
        try std.testing.expect(!closed);
        if (std.mem.startsWith(u8, row.text, "└")) closed = true else try std.testing.expect(std.mem.startsWith(u8, row.text, "├"));
        owner = row.entry_id;
    }
    try std.testing.expect(closed);
}

/// A row without its tree rail: the last row's `└` becomes `├` when a call
/// joins below it, and nothing else may change.
fn withoutRail(text: []const u8) []const u8 {
    for ([_][]const u8{ "├ ", "└ ", "│   ", "    " }) |rail| {
        if (std.mem.startsWith(u8, text, rail)) return text[rail.len..];
    }
    return text;
}

fn expectSameRows(expected: []const Line, actual: []const Line) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqual(want.entry_id, got.entry_id);
        try std.testing.expectEqualStrings(withoutRail(want.text), withoutRail(got.text));
    }
}

/// The rows after the header that do not belong to `entry_id`.
fn rowsBesides(arena: std.mem.Allocator, rows: []const Line, entry_id: u32) ![]const Line {
    var out: std.ArrayList(Line) = .empty;
    for (rows[1..]) |row| {
        if (row.entry_id != entry_id) try out.append(arena, row);
    }
    return out.items;
}

test "a streaming tool group keeps each call's rows in place as calls arrive and settle" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var before_settle: ?[]Line = null;
    for (1..calls.len + 1) |settled_count| {
        const settled = try (try Stage.init(arena, settled_count, false)).lines(arena);
        // A group of one is its own row; a tree starts with the second call.
        if (settled_count > 1) try expectWellFormed(settled);
        try std.testing.expect(std.mem.find(u8, settled[0].text, "running") == null);
        const settling: u32 = @intCast(settled_count);
        if (before_settle) |live| {
            // Settling a call moved nothing above it. A read joins the
            // Explored row, which keeps its place.
            const before = try rowsBesides(arena, live, settling);
            const after = try rowsBesides(arena, settled, settling);
            if (calls[settling - 1].explores) {
                try std.testing.expectEqual(before.len, after.len);
                for (before, after) |want, got| try std.testing.expectEqual(want.entry_id, got.entry_id);
            } else {
                try expectSameRows(before, after);
            }
        }
        if (settled_count == calls.len) break;

        // The next call starts: the settled rows stay as they were and the
        // running call's rows come last.
        const live = try (try Stage.init(arena, settled_count, true)).lines(arena);
        try expectWellFormed(live);
        try std.testing.expect(std.mem.find(u8, live[0].text, "1 running") != null);
        const running = settling + 1;
        const first_running = for (live, 0..) |row, index| {
            if (row.entry_id == running) break index;
        } else return error.TestRunningRowMissing;
        for (live[first_running..]) |row| try std.testing.expectEqual(running, row.entry_id);
        if (settled_count > 1) try expectSameRows(settled[1..], try rowsBesides(arena, live, running));
        before_settle = live;
    }
}

test "reads fold into the Explored row while other commands and Python keep their output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const stage = try Stage.init(arena, calls.len, false);
    const rows = try stage.lines(arena);
    var texts: std.ArrayList([]const u8) = .empty;
    for (rows) |row| try texts.append(arena, row.text);
    try std.testing.expectEqualStrings(
        \\● Ran 3 commands, listed 1 directory, read 1 file and 1 other call
        \\├ Explored · Listed ~/code/proto · Read assistant-message.ts:1-120 · Searched "table" in markdown.ts
        \\├ Ran git log --oneline -3 && du -sh packages
        \\│   abc1 one
        \\│   abc2 two
        \\│   abc3 three
        \\│    41M packages
        \\├ Ran python3
        \\│   cd ~/code/proto && python3 - <<'PY'
        \\│   Module · 3 nodes
        \\│   ├─ import os
        \\│   └─ for name os.listdir('.') ·L2
        \\│      └─ print(name)
        \\│   PY
        \\│   Output
        \\│   README.md
        \\│   packages
        \\└ Ran make check
        \\    ok
    , try std.mem.join(arena, "\n", texts.items));
}

test "long commands drop their cd and quiet redirects and end at a word" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const commands = [_][]const u8{
        "cd ~/code/proto 2>/dev/null && npm run build -- --filter packages/tui 2>/dev/null; npm test -- --runInBand",
        "cd ~/code/proto && make lint 2>&1",
    };
    var entries: [commands.len]TranscriptEntry = undefined;
    var details: [commands.len]ToolDetailRecord = undefined;
    for (commands, &entries, &details, 0..) |command, *entry, *detail, index| {
        const entry_id: u32 = @intCast(index + 1);
        entry.* = .{ .raw_bytes = .{ .id = entry_id, .bytes = try arena.print("● Ran {s}\n", .{command}), .class = .tool_status } };
        detail.* = .{
            .entry_id = entry_id,
            .tool_name = @constCast("shell"),
            .activity_kind = .command,
            .arguments_json = try arena.print("{f}", .{std.json.fmt(.{ .action = "run", .command = command }, .{})}),
            .command_display = @constCast(command),
            .outcome = .completed,
            .command_process_presentation = .{ .exit_code = 0 },
            .result = @constCast("done\n"),
        };
    }
    var projection = try projection_mod.buildStyled(arena, &entries, &details, 60, .{}, .{});
    defer projection.deinit(arena);
    var texts: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, projection.entry_actions.items[0].override.bytes, '\n');
    while (split.next()) |line| try texts.append(arena, try plain(arena, line));
    try std.testing.expectEqualStrings(
        \\● Ran 2 commands
        \\├ Ran npm run build -- --filter packages/tui; npm test -- …
        \\│   done
        \\└ Ran make lint
        \\    done
    , try std.mem.join(arena, "\n", texts.items));
}
