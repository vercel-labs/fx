//! What a command row carries under it in a tool group: the outline of
//! its Python, a browser script's first lines, and the end of its output.
const std = @import("std");
const tiers = @import("tool_group_tiers.zig");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");
const human_text = @import("../../core/shared/human_text.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const python_outline = @import("python_outline.zig");

const Allocator = std.mem.Allocator;
const ToolDetailRecord = transcript_blocks.ToolDetailRecord;
const Row = tiers.Row;
const Item = tiers.Item;

/// Output lines a command block keeps from the end of its output.
const tail_lines = 4;
/// Rows a Python outline shows, `Module · N nodes` included, before
/// "… N more".
const outline_rows = 9;
/// Script lines a browser run shows, "… N more lines" included.
const browser_code_rows = 6;
/// Shell lines kept on each side of an embedded Python cell.
const shell_chunk_lines = 2;

/// The command as the model wrote it, newlines intact, which a heredoc's
/// outline needs; the display text folds them away.
pub fn commandText(arena: Allocator, record: *const ToolDetailRecord) ?[]const u8 {
    if (record.arguments_json) |json| {
        if (tool_args.parseToolArgsObject(arena, json)) |args| {
            if (tool_args.optionalStringArg(args, "command")) |command| return command;
            if (std.mem.eql(u8, record.tool_name, "browser")) if (tool_args.optionalStringArg(args, "code")) |code| return code;
        } else |_| {}
    }
    return record.command_display;
}

/// The output a command printed, as people saw it: a shell call's result is
/// its visible output. Other command tools keep an envelope for the model,
/// so their output stays in the full transcript.
pub fn commandOutput(record: *const ToolDetailRecord) []const u8 {
    if (!std.mem.eql(u8, record.tool_name, "shell") and !std.mem.eql(u8, record.tool_name, "browser")) return "";
    return record.result orelse "";
}

pub fn firstLineOf(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len], " \t\r");
}

/// The rows under a command: what ran, when the row does not say it, the
/// outline of its Python, then the end of its output.
pub fn appendCommandBody(arena: Allocator, rows: *std.ArrayList(Row), item: Item) !void {
    const record = item.detail.?;
    const command = commandText(arena, record) orelse "";
    const failed = tiers.commandFailed(record);
    const reason = if (failed) try human_text.failureReason(arena, commandOutput(record)) else null;
    if (std.mem.eql(u8, record.tool_name, "browser")) return appendBrowserBody(arena, rows, item.entry_id, command, commandOutput(record));
    const script = python_outline.script(command);
    if (failed and reason != null and command.len > 0) {
        const shown = if (script) |found| try arena.print("{s} {s}", .{ found.interpreter, found.form }) else firstLineOf(command);
        try appendBody(arena, rows, item.entry_id, try arena.print("$ {s}", .{shown}));
    }
    if (script) |found| try appendScriptBody(arena, rows, item.entry_id, found);
    const output = commandOutput(record);
    var lines: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, output, '\n');
    while (split.next()) |raw| {
        const line = visibleLine(raw);
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        if (reason) |text| if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), text)) continue;
        try lines.append(arena, line);
    }
    const start = lines.items.len -| tail_lines;
    // An outline and the output it printed read apart.
    if (script != null and lines.items.len > 0) try appendBody(arena, rows, item.entry_id, "Output");
    if (start > 0) try appendBody(arena, rows, item.entry_id, try arena.print("… {d} earlier line{s}", .{ start, if (start == 1) "" else "s" }));
    // The tail keeps its own indentation, less what all of it shares.
    var common: usize = std.math.maxInt(usize);
    for (lines.items[start..]) |line| common = @min(common, line.len - std.mem.trimStart(u8, line, " ").len);
    for (lines.items[start..]) |*line| line.* = line.*[common..];
    for (lines.items[start..]) |line| {
        const plain = try std.mem.replaceOwned(u8, arena, try stripEscapes(arena, line), "\t", "    ");
        const safe = try text_utils.encodeTerminalSafe(arena, plain, 400);
        try appendBody(arena, rows, item.entry_id, safe.bytes);
    }
}

/// A browser run as a code block: the script's first lines, then the end
/// of what it displayed and returned.
fn appendBrowserBody(arena: Allocator, rows: *std.ArrayList(Row), entry_id: u32, code: []const u8, output: []const u8) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, std.mem.trimEnd(u8, code, " \t\r\n"), '\n');
    while (split.next()) |line| if (std.mem.trim(u8, line, " \t\r").len > 0) try lines.append(arena, line);
    const limit = if (lines.items.len > browser_code_rows) browser_code_rows - 1 else lines.items.len;
    for (lines.items[0..limit]) |line| try appendBody(arena, rows, entry_id, try safeLine(arena, line));
    if (limit < lines.items.len) try appendBody(arena, rows, entry_id, try arena.print("… {d} more lines", .{lines.items.len - limit}));
    var tail: std.ArrayList([]const u8) = .empty;
    var out_split = std.mem.splitScalar(u8, output, '\n');
    while (out_split.next()) |raw| {
        const line = visibleLine(raw);
        // The saved-images notice is for the model, not the person.
        if (std.mem.startsWith(u8, line, "Saved images: ")) continue;
        if (std.mem.trim(u8, line, " \t").len > 0) try tail.append(arena, line);
    }
    if (tail.items.len == 0) return;
    try appendBody(arena, rows, entry_id, "Output");
    const start = tail.items.len -| tail_lines;
    if (start > 0) try appendBody(arena, rows, entry_id, try arena.print("… {d} earlier line{s}", .{ start, if (start == 1) "" else "s" }));
    for (tail.items[start..]) |line| try appendBody(arena, rows, entry_id, try safeLine(arena, line));
}

/// A Python cell as proto shows it: the shell around it when the command
/// does more than run it, and between, the cell's outline, or its first
/// lines when the outline cannot read it.
fn appendScriptBody(arena: Allocator, rows: *std.ArrayList(Row), entry_id: u32, found: python_outline.Script) !void {
    const mixed = found.mixed();
    if (mixed) {
        var before: std.ArrayList([]const u8) = .empty;
        var split = std.mem.splitScalar(u8, found.before, '\n');
        while (split.next()) |line| if (std.mem.trim(u8, line, " \t\r").len > 0) try before.append(arena, line);
        for (before.items[before.items.len -| shell_chunk_lines..]) |line| try appendBody(arena, rows, entry_id, try safeLine(arena, line));
    }
    if (try python_outline.parse(arena, found.code)) |outline| {
        for (try python_outline.rows(arena, outline, outline_rows)) |row| try appendBody(arena, rows, entry_id, try safeLine(arena, row));
    } else {
        var lines: std.ArrayList([]const u8) = .empty;
        var split = std.mem.splitScalar(u8, std.mem.trimEnd(u8, found.code, " \t\r\n"), '\n');
        while (split.next()) |line| if (std.mem.trim(u8, line, " \t\r").len > 0) try lines.append(arena, line);
        const limit = if (lines.items.len > outline_rows) outline_rows - 1 else lines.items.len;
        for (lines.items[0..limit]) |line| try appendBody(arena, rows, entry_id, try safeLine(arena, line));
        if (limit < lines.items.len) try appendBody(arena, rows, entry_id, try arena.print("… {d} more lines", .{lines.items.len - limit}));
    }
    if (mixed) {
        var shown: usize = 0;
        var split = std.mem.splitScalar(u8, found.after, '\n');
        while (split.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
            if (shown == shell_chunk_lines) {
                try appendBody(arena, rows, entry_id, "…");
                break;
            }
            try appendBody(arena, rows, entry_id, try safeLine(arena, line));
            shown += 1;
        }
    }
}

pub fn safeLine(arena: Allocator, line: []const u8) ![]const u8 {
    const plain = try std.mem.replaceOwned(u8, arena, std.mem.trimEnd(u8, line, " \t\r"), "\t", "    ");
    return (try text_utils.encodeTerminalSafe(arena, plain, 400)).bytes;
}

pub fn appendBody(arena: Allocator, rows: *std.ArrayList(Row), entry_id: u32, text: []const u8) !void {
    try rows.append(arena, .{ .entry_id = entry_id, .kind = .body, .style = .dim, .text = text });
}

/// What a terminal shows of a line: the text after its last carriage return.
fn visibleLine(raw: []const u8) []const u8 {
    const line = std.mem.trimEnd(u8, raw, "\r");
    return if (std.mem.findScalarLast(u8, line, '\r')) |at| line[at + 1 ..] else line;
}

/// The line without terminal escape sequences, so output colors never
/// reach the transcript's own styling.
fn stripEscapes(arena: Allocator, line: []const u8) ![]const u8 {
    if (std.mem.findScalar(u8, line, 0x1b) == null) return line;
    var out: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < line.len) {
        if (line[index] == 0x1b and index + 1 < line.len and line[index + 1] == '[') {
            index += 2;
            while (index < line.len and (line[index] < 0x40 or line[index] > 0x7e)) index += 1;
            index += 1;
            continue;
        }
        try out.append(arena, line[index]);
        index += 1;
    }
    return out.items;
}
