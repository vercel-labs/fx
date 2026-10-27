//! Which rows of a tool group a person sees, and how loud each one is.
//!
//! Every row belongs to one tier:
//! - attention: failed, denied, cancelled or timed out, or still running.
//!   It keeps the status color and is never folded.
//! - outcome: what changed: files written or edited, commands run, workers
//!   started or stopped, jobs backgrounded or cancelled, checkpoints.
//! - routine: reads, lists, inspects, logs, observes, fetches, recall and
//!   sends. Routine rows never stand alone in a settled group: similar ones
//!   fold into one dim row, "Read 6 files · notes.md, app.py, +4".
//!
//! A settled group shows its folds, then at most `settled_row_cap` rows,
//! attention first and then the newest outcomes, in the order they ran;
//! older outcomes fold too. A command row carries a short tail of its
//! output (and a Python run its outline) so a person sees what happened
//! without opening the full transcript. A live group shows only its last
//! few rows. Ctrl+O keeps every row.
const std = @import("std");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");
const human_text = @import("../../core/shared/human_text.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const python_outline = @import("python_outline.zig");
const browser_summary = @import("../../core/browser/script_summary.zig");
const checklist_presentation = @import("../../core/checklist/presentation.zig");

const Allocator = std.mem.Allocator;
const ToolDetailRecord = transcript_blocks.ToolDetailRecord;

/// Rows a settled group shows besides its folds.
pub const settled_row_cap = 5;
/// Rows a live group shows: the newest, so it does not grow while it runs.
pub const live_row_count = 3;
/// Output lines a command block keeps from the end of its output.
const tail_lines = 4;
/// Commands, newest first, that keep their output tail in a settled group.
const tail_blocks = 3;
/// Rows a Python outline shows, `Module · N nodes` included, before
/// "… N more".
const outline_rows = 9;
/// Script lines a browser run shows, "… N more lines" included.
const browser_code_rows = 6;
/// Shell lines kept on each side of an embedded Python cell.
const shell_chunk_lines = 2;
/// Names a fold lists before "+N".
const fold_names = 2;
/// The widest command name a fold lists.
const fold_name_bytes = 32;

pub const Tier = enum { attention, outcome, routine };

pub const Item = struct {
    entry_id: u32,
    detail: ?*const ToolDetailRecord,
    /// The status phrase without its marker or styling.
    phrase: []const u8,
    /// Rows a card carries under its phrase, such as a worker's reply.
    continuation: ?[]const u8 = null,
};

pub const Style = enum { normal, dim, attention };
pub const Kind = enum { item, fold, body };

pub const Row = struct {
    entry_id: u32,
    kind: Kind,
    style: Style,
    text: []const u8,
    /// The record an item row's command may be highlighted from.
    detail: ?*const ToolDetailRecord = null,
};

pub fn isLive(detail: ?*const ToolDetailRecord) bool {
    const record = detail orelse return false;
    return record.outcome == null and record.fallback_disposition == null;
}

fn commandFailed(record: *const ToolDetailRecord) bool {
    if (record.activity_kind != .command) return false;
    const presentation = record.command_process_presentation orelse return false;
    return switch (presentation) {
        .exit_code => |code| code != 0,
        .signal, .timed_out, .output_capture_failed => true,
    };
}

pub fn isFailure(detail: ?*const ToolDetailRecord) bool {
    const record = detail orelse return false;
    if (record.fallback_disposition != null) return true;
    if (commandFailed(record)) return true;
    const outcome = record.outcome orelse return false;
    return switch (outcome) {
        .failed, .denied, .cancelled => true,
        .completed, .deferred => false,
    };
}

/// The operation a call's arguments name: a shell action, or a jobs or
/// fleet op. Empty when there is none.
fn operation(arena: Allocator, record: *const ToolDetailRecord) []const u8 {
    const json = record.arguments_json orelse return "";
    const args = tool_args.parseToolArgsObject(arena, json) catch return "";
    return tool_args.optionalStringArg(args, "op") orelse tool_args.optionalStringArg(args, "action") orelse "";
}

fn isOneOf(value: []const u8, comptime options: []const []const u8) bool {
    inline for (options) |option| {
        if (std.mem.eql(u8, value, option)) return true;
    }
    return false;
}

pub fn tierOf(arena: Allocator, item: Item) Tier {
    const record = item.detail orelse return .outcome;
    if (isLive(record) or isFailure(record)) return .attention;
    const op = operation(arena, record);
    const name = record.tool_name;
    if (std.mem.eql(u8, name, "shell")) {
        // Writing to or watching a session is routine; running or stopping
        // one is what happened.
        const label = record.command_action_label orelse "";
        const watched = isOneOf(label, &.{ "Observed", "Sent input to" });
        return if (std.mem.eql(u8, op, "interact") or watched) .routine else .outcome;
    }
    if (std.mem.eql(u8, name, "jobs")) return if (isOneOf(op, &.{"cancel"})) .outcome else .routine;
    // Opening a page and running a script are what happened; closing is routine.
    if (std.mem.eql(u8, name, "browser")) return if (isOneOf(op, &.{"close"})) .routine else .outcome;
    if (std.mem.eql(u8, name, "fleet")) return if (isOneOf(op, &.{ "spawn", "run", "terminate" })) .outcome else .routine;
    // Changing the plan is what happened; looking at it is routine.
    if (std.mem.eql(u8, name, "checklist")) return if (isOneOf(op, &.{"view"})) .routine else .outcome;
    const kind = record.activity_kind orelse return .outcome;
    return switch (kind) {
        .write, .edit, .command, .subagent => .outcome,
        .read, .open, .ask => if (isOneOf(name, &.{ "checkpoint", "rewind" })) .outcome else .routine,
    };
}

/// An outcome that changed something a person keeps: a file, a worker, a
/// checkpoint. It outranks a command when rows are scarce.
fn isChange(detail: ?*const ToolDetailRecord) bool {
    const record = detail orelse return false;
    const kind = record.activity_kind orelse return false;
    if (kind == .write or kind == .edit) return true;
    if (std.mem.eql(u8, record.tool_name, "fleet") or isOneOf(record.tool_name, &.{ "checkpoint", "rewind", "checklist" })) return true;
    return false;
}

fn isCommandRun(arena: Allocator, record: *const ToolDetailRecord) bool {
    if (record.activity_kind != .command) return false;
    if (!std.mem.eql(u8, record.tool_name, "shell")) return true;
    const op = operation(arena, record);
    if (op.len > 0) return std.mem.eql(u8, op, "run");
    // A record without its arguments still says what its row did.
    const label = record.command_action_label orelse return true;
    return !isOneOf(label, &.{ "Observed", "Sent input to", "Stopped" });
}

// ---- header ----------------------------------------------------------------

const Family = struct { verb: []const u8, one: []const u8, many: []const u8 };

fn familyOf(arena: Allocator, record: ?*const ToolDetailRecord) ?Family {
    const value = record orelse return null;
    const name = value.tool_name;
    if (std.mem.eql(u8, name, "read_file")) return .{ .verb = "read", .one = "file", .many = "files" };
    if (std.mem.eql(u8, name, "write_file")) return .{ .verb = "wrote", .one = "file", .many = "files" };
    if (std.mem.eql(u8, name, "edit_file")) return .{ .verb = "edited", .one = "file", .many = "files" };
    if (std.mem.eql(u8, name, "web_fetch")) return .{ .verb = "fetched", .one = "page", .many = "pages" };
    if (isCommandRun(arena, value)) return .{ .verb = "ran", .one = "command", .many = "commands" };
    const starts_worker = std.mem.eql(u8, name, "subagent") or
        (std.mem.eql(u8, name, "fleet") and isOneOf(operation(arena, value), &.{ "spawn", "run" }));
    if (starts_worker) return .{ .verb = "started", .one = "worker", .many = "workers" };
    return null;
}

pub const Header = struct {
    /// "Read 6 files, ran 4 commands and 3 other calls".
    words: []const u8,
    /// " · 1 failed · 1 running", or empty; drawn in the status color.
    attention: []const u8,
};

/// The group's summary in plain words: up to three kinds of work by how
/// often they happened, then what needs attention.
pub fn header(arena: Allocator, items: []const Item) !Header {
    const max_families = 8;
    var families: [max_families]Family = undefined;
    var counts: [max_families]usize = @splat(0);
    var family_count: usize = 0;
    var other: usize = 0;
    var counts_by_anomaly: [anomaly_labels.len]usize = @splat(0);
    for (items) |item| {
        if (anomalyOf(item.detail)) |anomaly| counts_by_anomaly[@backingInt(anomaly)] += 1;
        const family = familyOf(arena, item.detail) orelse {
            other += 1;
            continue;
        };
        const index = for (families[0..family_count], 0..) |known, i| {
            if (std.mem.eql(u8, known.verb, family.verb)) break i;
        } else blk: {
            if (family_count == max_families) {
                other += 1;
                continue;
            }
            families[family_count] = family;
            family_count += 1;
            break :blk family_count - 1;
        };
        counts[index] += 1;
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    var shown: usize = 0;
    var emitted: [max_families]bool = @splat(false);
    while (shown < 3) : (shown += 1) {
        var best: ?usize = null;
        for (counts[0..family_count], 0..) |count, index| {
            if (emitted[index]) continue;
            if (best == null or count > counts[best.?]) best = index;
        }
        const index = best orelse break;
        emitted[index] = true;
        const family = families[index];
        if (shown > 0) try writer.writeAll(", ");
        try writer.print("{s} {d} {s}", .{ family.verb, counts[index], if (counts[index] == 1) family.one else family.many });
    }
    for (counts[0..family_count], 0..) |count, index| {
        if (!emitted[index]) other += count;
    }
    if (shown == 0) {
        try writer.print("{d} tool call{s}", .{ other, if (other == 1) "" else "s" });
    } else if (other > 0) {
        try writer.print(" and {d} other call{s}", .{ other, if (other == 1) "" else "s" });
    }
    const words = out.written();
    if (words.len > 0) words[0] = std.ascii.toUpper(words[0]);

    var attention: std.Io.Writer.Allocating = .init(arena);
    for (counts_by_anomaly, anomaly_labels) |count, label| {
        if (count > 0) try attention.writer.print(" · {d} {s}", .{ count, label });
    }
    return .{ .words = words, .attention = attention.written() };
}

const Anomaly = enum { unreported, not_executed, timed_out, failed, denied, cancelled, running };
const anomaly_labels = [_][]const u8{ "unreported", "not executed", "timed out", "failed", "denied", "cancelled", "running" };

/// What about a row needs attention, in the order the header names it.
fn anomalyOf(detail: ?*const ToolDetailRecord) ?Anomaly {
    const record = detail orelse return null;
    if (record.fallback_disposition) |disposition| return switch (disposition) {
        .completion_unreported => .unreported,
        .not_executed => .not_executed,
    };
    if (isLive(record)) return .running;
    if (record.command_process_presentation) |presentation| if (presentation == .timed_out and record.activity_kind == .command) return .timed_out;
    if (record.outcome == .denied) return .denied;
    if (record.outcome == .cancelled) return .cancelled;
    if (isFailure(record)) return .failed;
    return null;
}

// ---- rows ------------------------------------------------------------------

/// The rows under the header. `live` shows only the newest rows.
pub fn plan(arena: Allocator, items: []const Item, live: bool) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    if (live) {
        const start = items.len -| live_row_count;
        if (start > 0) try rows.append(arena, .{
            .entry_id = items[0].entry_id,
            .kind = .fold,
            .style = .dim,
            .text = try arena.print("… {d} earlier", .{start}),
        });
        for (items[start..]) |item| try rows.append(arena, .{
            .entry_id = item.entry_id,
            .kind = .item,
            .style = styleOf(arena, item),
            .text = try itemText(arena, item),
            .detail = item.detail,
        });
        return rows.items;
    }

    const tiers = try arena.alloc(Tier, items.len);
    var attention: usize = 0;
    for (items, tiers) |item, *tier| {
        tier.* = tierOf(arena, item);
        if (tier.* == .attention) attention += 1;
    }
    // Attention rows always show. The newest changes to files, workers and
    // checkpoints fill what is left first, then the newest other outcomes.
    const shown = try arena.alloc(bool, items.len);
    @memset(shown, false);
    var unrecorded: usize = 0;
    for (items) |item| unrecorded += @intFromBool(item.detail == null);
    var room = settled_row_cap -| (attention + unrecorded);
    // A row without a record cannot be told apart from its neighbors, so it
    // always shows, as rows did before tiers.
    for (items, tiers, shown) |item, tier, *visible| {
        if (tier == .attention or item.detail == null) visible.* = true;
    }
    for ([_]bool{ true, false }) |changes| {
        var index = items.len;
        while (index > 0 and room > 0) {
            index -= 1;
            if (tiers[index] != .outcome or shown[index]) continue;
            if (isChange(items[index].detail) != changes) continue;
            shown[index] = true;
            room -= 1;
        }
    }

    var folds: std.ArrayList(Fold) = .empty;
    var more_commands: Fold = .{ .key = "", .verb = "Ran", .entry_id = 0, .noun = .{ "more command", "more commands" } };
    var more_other: usize = 0;
    var more_other_entry: ?u32 = null;
    for (items, tiers, shown) |item, tier, visible| {
        if (visible) continue;
        if (tier == .routine) {
            try addToFold(arena, &folds, item);
            continue;
        }
        const record = item.detail orelse {
            more_other += 1;
            more_other_entry = more_other_entry orelse item.entry_id;
            continue;
        };
        if (isCommandRun(arena, record)) {
            if (more_commands.count == 0) more_commands.entry_id = item.entry_id;
            try more_commands.add(arena, commandName(arena, record) orelse targetOf(item.phrase));
        } else {
            more_other += 1;
            more_other_entry = more_other_entry orelse item.entry_id;
        }
    }
    for (folds.items) |*fold| try rows.append(arena, .{ .entry_id = fold.entry_id, .kind = .fold, .style = .dim, .text = try fold.text(arena) });
    if (more_commands.count > 0) try rows.append(arena, .{ .entry_id = more_commands.entry_id, .kind = .fold, .style = .dim, .text = try more_commands.text(arena) });
    if (more_other > 0) try rows.append(arena, .{
        .entry_id = more_other_entry.?,
        .kind = .fold,
        .style = .dim,
        .text = try arena.print("+{d} more · ctrl+o", .{more_other}),
    });

    // The newest commands keep their output; older ones keep their row.
    var tails_left: usize = tail_blocks;
    const keeps_tail = try arena.alloc(bool, items.len);
    @memset(keeps_tail, false);
    var index = items.len;
    while (index > 0 and tails_left > 0) {
        index -= 1;
        const record = items[index].detail orelse continue;
        if (!shown[index] or !isCommandRun(arena, record)) continue;
        keeps_tail[index] = true;
        tails_left -= 1;
    }
    for (items, shown, keeps_tail) |item, visible, tail| {
        if (visible) try appendItem(arena, &rows, item, styleOf(arena, item), tail);
    }
    return rows.items;
}

/// A group of one: its row in its own voice, never dim, with what it
/// carries under it.
pub fn single(arena: Allocator, item: Item) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    const style: Style = if (isFailure(item.detail)) .attention else .normal;
    const tail = if (item.detail) |record| isCommandRun(arena, record) else false;
    try appendItem(arena, &rows, item, style, tail);
    return rows.items;
}

fn appendItem(arena: Allocator, rows: *std.ArrayList(Row), item: Item, style: Style, tail: bool) !void {
    try rows.append(arena, .{
        .entry_id = item.entry_id,
        .kind = .item,
        .style = style,
        .text = try itemText(arena, item),
        .detail = item.detail,
    });
    // A card keeps one row under it: the one that carries its outcome.
    if (item.continuation) |continuation| {
        if (firstRow(continuation)) |row| try appendBody(arena, rows, item.entry_id, row);
    }
    if (tail) try appendCommandBody(arena, rows, item);
    if (item.detail) |record| if (try checklistView(arena, record)) |view| {
        for (view.body) |line| try appendBody(arena, rows, item.entry_id, try safeLine(arena, line));
    };
}

/// A settled checklist call in proto-fx's voice (D234): what changed, and
/// under it the list or the progress.
fn checklistView(arena: Allocator, record: *const ToolDetailRecord) !?checklist_presentation.View {
    if (!std.mem.eql(u8, record.tool_name, "checklist") or isLive(record)) return null;
    if (record.outcome != null and record.outcome.? != .completed and record.outcome.? != .failed) return null;
    const json = record.arguments_json orelse return null;
    return checklist_presentation.view(arena, json, record.result orelse "", isFailure(record));
}

fn styleOf(arena: Allocator, item: Item) Style {
    if (isFailure(item.detail)) return .attention;
    return switch (tierOf(arena, item)) {
        .routine => .dim,
        .attention, .outcome => .normal,
    };
}

fn firstRow(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

/// An item's row: its phrase, except a finished command reads by its
/// outcome and a failed one says why: "Exited 1 · AttributeError: …".
fn itemText(arena: Allocator, item: Item) ![]const u8 {
    const record = item.detail orelse return item.phrase;
    if (std.mem.eql(u8, record.tool_name, "browser")) return browserText(arena, item, record);
    if (try checklistView(arena, record)) |view| return view.headline;
    if (!isCommandRun(arena, record)) return item.phrase;
    if (commandFailed(record)) {
        const label = switch (record.command_process_presentation.?) {
            .exit_code => |code| try arena.print("Exited {d}", .{code}),
            .signal => |signal| try arena.print("Signaled {d}", .{signal}),
            .timed_out => "Timed out",
            .output_capture_failed => "Output capture failed",
        };
        // With a reason, the command moves to the row below; without one
        // the row names the command.
        if (try human_text.failureReason(arena, commandOutput(record))) |reason| return arena.print("{s} · {s}", .{ label, reason });
        const name = if (commandText(arena, record)) |command|
            if (python_outline.script(command)) |found| found.interpreter else firstLineOf(command)
        else if (std.mem.startsWith(u8, item.phrase, "Ran "))
            item.phrase["Ran ".len..]
        else
            return item.phrase;
        return arena.print("{s} · {s}", .{ label, name });
    }
    // A run names its command by the first line, and inline Python by its
    // interpreter; the outline below shows the rest.
    const verb = for ([_][]const u8{ "Ran", "Running" }) |candidate| {
        if (std.mem.startsWith(u8, item.phrase, candidate) and item.phrase.len > candidate.len and item.phrase[candidate.len] == ' ') break candidate;
    } else return item.phrase;
    const command = commandText(arena, record) orelse return item.phrase;
    if (python_outline.script(command)) |found| return arena.print("{s} {s}", .{ verb, found.interpreter });
    const first = firstLineOf(command);
    if (first.len < std.mem.trimEnd(u8, command, " \t\r\n").len) return arena.print("{s} {s} …", .{ verb, first });
    return item.phrase;
}

/// A browser row in proto-fx's voice: "Opened example.com", and a settled
/// run by what its script did, "Filled #email, clicked Sign in".
fn browserText(arena: Allocator, item: Item, record: *const ToolDetailRecord) ![]const u8 {
    const json = record.arguments_json orelse return item.phrase;
    const args = tool_args.parseToolArgsObject(arena, json) catch return item.phrase;
    const action = tool_args.optionalStringArg(args, "action") orelse return item.phrase;
    if (std.mem.eql(u8, action, "open")) {
        const url = tool_args.optionalStringArg(args, "url") orelse return item.phrase;
        const verb = for ([_][]const u8{ "Opened", "Opening" }) |candidate| {
            if (std.mem.startsWith(u8, item.phrase, candidate)) break candidate;
        } else return item.phrase;
        return arena.print("{s} {s}", .{ verb, browser_summary.shortUrl(url) });
    }
    if (!std.mem.eql(u8, action, "run") or isLive(record)) return item.phrase;
    const code = tool_args.optionalStringArg(args, "code") orelse return item.phrase;
    const summary = (try browser_summary.summarize(arena, code)) orelse return item.phrase;
    if (isFailure(record)) {
        if (try human_text.failureReason(arena, record.result orelse "")) |reason| return arena.print("Failed · {s}", .{reason});
    }
    return summary;
}

/// The command as the model wrote it, newlines intact, which a heredoc's
/// outline needs; the display text folds them away.
fn commandText(arena: Allocator, record: *const ToolDetailRecord) ?[]const u8 {
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
fn commandOutput(record: *const ToolDetailRecord) []const u8 {
    if (!std.mem.eql(u8, record.tool_name, "shell") and !std.mem.eql(u8, record.tool_name, "browser")) return "";
    return record.result orelse "";
}

fn firstLineOf(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text[0 .. std.mem.findScalar(u8, text, '\n') orelse text.len], " \t\r");
}

/// The rows under a command: what ran, when the row does not say it, the
/// outline of its Python, then the end of its output.
fn appendCommandBody(arena: Allocator, rows: *std.ArrayList(Row), item: Item) !void {
    const record = item.detail.?;
    const command = commandText(arena, record) orelse "";
    const failed = commandFailed(record);
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

fn safeLine(arena: Allocator, line: []const u8) ![]const u8 {
    const plain = try std.mem.replaceOwned(u8, arena, std.mem.trimEnd(u8, line, " \t\r"), "\t", "    ");
    return (try text_utils.encodeTerminalSafe(arena, plain, 400)).bytes;
}

fn appendBody(arena: Allocator, rows: *std.ArrayList(Row), entry_id: u32, text: []const u8) !void {
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

// ---- folds -----------------------------------------------------------------

/// Similar routine rows as one: a verb, how many, and the first names.
const Fold = struct {
    key: []const u8,
    verb: []const u8,
    entry_id: u32,
    /// "file", "files": a count reads "Read 6 files · …" when set.
    noun: ?[2][]const u8 = null,
    /// Names are whole phrases of different verbs: "Listed jobs,
    /// inspected npm test ×2".
    combined: bool = false,
    /// The first row's own phrase, which a fold of one shows as it is.
    first_phrase: []const u8 = "",
    count: usize = 0,
    names: std.ArrayList([]const u8) = .empty,
    repeats: std.ArrayList(usize) = .empty,

    fn add(self: *Fold, arena: Allocator, name: []const u8) !void {
        self.count += 1;
        for (self.names.items, self.repeats.items) |known, *repeat| {
            if (std.mem.eql(u8, known, name)) {
                repeat.* += 1;
                return;
            }
        }
        try self.names.append(arena, name);
        try self.repeats.append(arena, 1);
    }

    fn text(self: *const Fold, arena: Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const writer = &out.writer;
        const distinct = self.names.items.len;
        if (self.count == 1 and self.first_phrase.len > 0) return self.first_phrase;
        if (self.noun) |noun| {
            try writer.print("{s} {d} {s}", .{ self.verb, self.count, if (self.count == 1) noun[0] else noun[1] });
            if (distinct > 0) try writer.writeAll(" · ");
        } else if (!self.combined) {
            try writer.print("{s} ", .{self.verb});
        }
        const limit: usize = if (self.combined) fold_names + 1 else fold_names;
        for (self.names.items[0..@min(distinct, limit)], self.repeats.items[0..@min(distinct, limit)], 0..) |name, repeat, index| {
            if (index > 0) try writer.writeAll(", ");
            if (self.combined and index > 0 and name.len > 0) {
                try writer.writeByte(std.ascii.toLower(name[0]));
                try writer.writeAll(name[1..]);
            } else try writer.writeAll(name);
            if (repeat > 1 and self.noun == null) try writer.print(" ×{d}", .{repeat});
        }
        if (distinct > limit) try writer.print(", +{d}", .{distinct - limit});
        return out.written();
    }
};

/// Reads and fetches fold by count, "Read 6 files · a, b, +4"; every other
/// routine row joins one list of what was checked, "Listed jobs,
/// inspected npm test ×2".
fn addToFold(arena: Allocator, folds: *std.ArrayList(Fold), item: Item) !void {
    const verb = item.phrase[0 .. std.mem.findScalar(u8, item.phrase, ' ') orelse item.phrase.len];
    const tool = if (item.detail) |record| record.tool_name else "";
    const noun: ?[2][]const u8 = if (std.mem.eql(u8, tool, "read_file")) .{ "file", "files" } else if (std.mem.eql(u8, tool, "web_fetch")) .{ "page", "pages" } else null;
    const fold_verb = if (std.mem.eql(u8, tool, "read_file")) "Read" else if (std.mem.eql(u8, tool, "web_fetch")) "Fetched" else verb;
    const key = if (noun != null) try arena.print("{s}\x00{s}", .{ tool, verb }) else "";
    const fold = for (folds.items) |*known| {
        if (std.mem.eql(u8, known.key, key)) break known;
    } else blk: {
        try folds.append(arena, .{
            .key = key,
            .verb = fold_verb,
            .entry_id = item.entry_id,
            .noun = noun,
            .combined = noun == null,
            .first_phrase = phraseHead(item.phrase),
        });
        break :blk &folds.items[folds.items.len - 1];
    };
    try fold.add(arena, if (noun != null) targetOf(item.phrase) else phraseHead(item.phrase));
}

/// A phrase before its " · " detail: "Inspected npm test".
fn phraseHead(phrase: []const u8) []const u8 {
    return std.mem.trim(u8, phrase[0 .. std.mem.find(u8, phrase, " · ") orelse phrase.len], " ");
}

/// What a routine phrase acted on: the words after its verb, before any
/// " · " detail.
fn targetOf(phrase: []const u8) []const u8 {
    const after_verb = if (std.mem.findScalar(u8, phrase, ' ')) |space| phrase[space + 1 ..] else phrase;
    const end = std.mem.find(u8, after_verb, " · ") orelse after_verb.len;
    return std.mem.trim(u8, after_verb[0..end], " ");
}

/// A command as a fold lists it: its first line, short.
fn commandName(arena: Allocator, record: *const ToolDetailRecord) ?[]const u8 {
    const command = commandText(arena, record) orelse return null;
    if (python_outline.script(command)) |found| return found.interpreter;
    const first = firstLineOf(command);
    if (first.len <= fold_name_bytes) return first;
    var end: usize = fold_name_bytes;
    while (end > 0 and (first[end] & 0xc0) == 0x80) end -= 1;
    return first[0..end];
}

// ---- tests -----------------------------------------------------------------

fn testRecord(entry_id: u32, tool_name: []const u8, kind: @import("../../core/shared/types.zig").ToolActivityKind, args: []const u8) ToolDetailRecord {
    return .{
        .entry_id = entry_id,
        .tool_name = @constCast(tool_name),
        .activity_kind = kind,
        .arguments_json = @constCast(args),
        .outcome = .completed,
    };
}

test "routine rows fold, outcomes stay, failures say why" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var records = [_]ToolDetailRecord{
        testRecord(1, "read_file", .read, "{\"path\":\"notes.md\"}"),
        testRecord(2, "read_file", .read, "{\"path\":\"app.py\"}"),
        testRecord(3, "read_file", .read, "{\"path\":\"lib/a.py\"}"),
        testRecord(4, "write_file", .write, "{}"),
        testRecord(5, "shell", .command, "{\"action\":\"run\",\"command\":\"cat nope.txt\"}"),
        testRecord(6, "jobs", .read, "{\"op\":\"inspect\",\"id\":\"bg_1\"}"),
        testRecord(7, "jobs", .read, "{\"op\":\"inspect\",\"id\":\"bg_1\"}"),
    };
    records[4].command_process_presentation = .{ .exit_code = 1 };
    records[4].command_display = @constCast("cat nope.txt");
    records[4].result = @constCast("cat: nope.txt: No such file or directory\n");
    const items = [_]Item{
        .{ .entry_id = 1, .detail = &records[0], .phrase = "Read notes.md" },
        .{ .entry_id = 2, .detail = &records[1], .phrase = "Read app.py" },
        .{ .entry_id = 3, .detail = &records[2], .phrase = "Read lib/a.py" },
        .{ .entry_id = 4, .detail = &records[3], .phrase = "Wrote out.txt +1" },
        .{ .entry_id = 5, .detail = &records[4], .phrase = "Exited 1: Running cat nope.txt" },
        .{ .entry_id = 6, .detail = &records[5], .phrase = "Inspected sleep 9 · running · 1.2s" },
        .{ .entry_id = 7, .detail = &records[6], .phrase = "Inspected sleep 9 · running · 2.3s" },
    };
    const summary = try header(arena, &items);
    try std.testing.expectEqualStrings("Read 3 files, wrote 1 file, ran 1 command and 2 other calls", summary.words);
    try std.testing.expectEqualStrings(" · 1 failed", summary.attention);
    const rows = try plan(arena, &items, false);
    var texts: std.ArrayList([]const u8) = .empty;
    for (rows) |row| try texts.append(arena, try arena.print("{s}:{s}", .{ @tagName(row.style), row.text }));
    const joined = try std.mem.join(arena, "\n", texts.items);
    try std.testing.expectEqualStrings(
        \\dim:Read 3 files · notes.md, app.py, +1
        \\dim:Inspected sleep 9 ×2
        \\normal:Wrote out.txt +1
        \\attention:Exited 1 · cat: nope.txt: No such file or directory
        \\dim:$ cat nope.txt
    , joined);
}

test "a settled group caps its rows and folds older commands" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var records: [9]ToolDetailRecord = undefined;
    var items: [9]Item = undefined;
    for (&records, &items, 0..) |*record, *item, index| {
        const command = try arena.print("echo {d}", .{index});
        record.* = testRecord(@intCast(index + 1), "shell", .command, "{\"action\":\"run\"}");
        record.command_display = @constCast(command);
        record.command_process_presentation = .{ .exit_code = 0 };
        record.result = @constCast(try arena.print("{d}\n", .{index}));
        item.* = .{ .entry_id = @intCast(index + 1), .detail = record, .phrase = try arena.print("Ran {s}", .{command}) };
    }
    const rows = try plan(arena, &items, false);
    var item_rows: usize = 0;
    var body_rows: usize = 0;
    for (rows) |row| switch (row.kind) {
        .item => item_rows += 1,
        .body => body_rows += 1,
        .fold => try std.testing.expectEqualStrings("Ran 4 more commands · echo 0, echo 1, +2", row.text),
    };
    try std.testing.expectEqual(@as(usize, settled_row_cap), item_rows);
    try std.testing.expectEqual(@as(usize, tail_blocks), body_rows);
    try std.testing.expectEqualStrings("Ran echo 8", rows[rows.len - 2].text);
    try std.testing.expectEqualStrings("8", rows[rows.len - 1].text);
}

test "a live group shows only its newest rows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var items: [6]Item = undefined;
    for (&items, 0..) |*item, index| item.* = .{ .entry_id = @intCast(index + 1), .detail = null, .phrase = try arena.print("Read f{d}", .{index}) };
    const rows = try plan(arena, &items, true);
    try std.testing.expectEqual(@as(usize, 4), rows.len);
    try std.testing.expectEqualStrings("… 3 earlier", rows[0].text);
    try std.testing.expectEqualStrings("Read f5", rows[3].text);
}

test "a Python run outlines its code and keeps the end of its output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var record = testRecord(1, "shell", .command, "{\"action\":\"run\"}");
    record.command_display = @constCast("python3 - <<'PY'\nimport os\nos.nope()\nPY");
    record.command_process_presentation = .{ .exit_code = 1 };
    record.result = @constCast("Traceback (most recent call last):\n  File \"<stdin>\", line 2, in <module>\nAttributeError: module 'os' has no attribute 'nope'\n");
    const items = [_]Item{.{ .entry_id = 1, .detail = &record, .phrase = "Exited 1: Running python3 - <<'PY' import os os.nope() PY" }};
    const rows = try plan(arena, &items, false);
    const expected = [_][]const u8{
        "Exited 1 · AttributeError: module 'os' has no attribute 'nope'",
        "$ python3 heredoc",
        "Module · 2 nodes",
        "├─ import os",
        "└─ os.nope()",
        "Output",
        "Traceback (most recent call last):",
        "  File \"<stdin>\", line 2, in <module>",
    };
    try std.testing.expectEqual(expected.len, rows.len);
    for (expected, rows) |want, row| try std.testing.expectEqualStrings(want, row.text);
}

test "a Python cell inside other shell keeps its shell chunks, and unparsed code shows its lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var record = testRecord(1, "shell", .command, "{\"action\":\"run\"}");
    record.command_display = @constCast("proto models --help && python3.13 <<'PY'\nfor x in range(3):\n    print(x)\nPY\necho done");
    record.command_process_presentation = .{ .exit_code = 0 };
    record.result = @constCast("0\n1\n2\ndone\n");
    const items = [_]Item{.{ .entry_id = 1, .detail = &record, .phrase = "Ran proto models --help && python3.13" }};
    const rows = try plan(arena, &items, false);
    const expected = [_][]const u8{
        "Ran python3.13",
        "proto models --help && python3.13 <<'PY'",
        "Module · 2 nodes",
        "└─ for x range(3) ·L1",
        "   └─ print(x)",
        "PY",
        "echo done",
        "Output",
        "0",
        "1",
        "2",
        "done",
    };
    try std.testing.expectEqual(expected.len, rows.len);
    for (expected, rows) |want, row| try std.testing.expectEqualStrings(want, row.text);

    record.command_display = @constCast("python3 - <<'PY'\nprint((1,\nPY");
    const broken = try plan(arena, &items, false);
    try std.testing.expectEqualStrings("print((1,", broken[1].text);
}

test "browser rows read by what they opened and did, with the script and its output tail" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var opened = testRecord(1, "browser", .open, "{\"action\":\"open\",\"url\":\"https://example.com/\"}");
    var ran = testRecord(2, "browser", .command, "{\"action\":\"run\",\"code\":\"await tab.fill('#name', 'Ada');\\nawait tab.click('text/Sign in');\\nreturn await tab.text('#out');\"}");
    ran.result = @constCast("Hello Ada");
    const items = [_]Item{
        .{ .entry_id = 1, .detail = &opened, .phrase = "Opened https://example.com/" },
        .{ .entry_id = 2, .detail = &ran, .phrase = "Ran browser script on main" },
    };
    const rows = try plan(arena, &items, false);
    var texts: std.ArrayList([]const u8) = .empty;
    for (rows) |row| try texts.append(arena, row.text);
    const joined = try std.mem.join(arena, "\n", texts.items);
    try std.testing.expect(std.mem.find(u8, joined, "Opened example.com") != null);
    try std.testing.expect(std.mem.find(u8, joined, "Filled #name, clicked Sign in +1\nawait tab.fill('#name', 'Ada');\nawait tab.click('text/Sign in');\nreturn await tab.text('#out');\nOutput\nHello Ada") != null);
}

test "checklist rows read by what changed, with the list or the progress under them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var planned = testRecord(1, "checklist", .read, "{\"op\":\"init\",\"items\":[\"Write parser\",\"Add tests\"]}");
    planned.result = @constCast("Initialized 2 tasks in 1 phases; in progress: \"Write parser\"\n  Tasks:\n    - [ ] Write parser (in progress)\n    - [ ] Add tests");
    var done = testRecord(2, "checklist", .read, "{\"op\":\"done\",\"task\":\"Write parser\"}");
    done.result = @constCast("done \"Write parser\" (1/2 done) → in progress: \"Add tests\"");
    const items = [_]Item{
        .{ .entry_id = 1, .detail = &planned, .phrase = "Updated checklist" },
        .{ .entry_id = 2, .detail = &done, .phrase = "Updated checklist" },
    };
    const rows = try plan(arena, &items, false);
    var texts: std.ArrayList([]const u8) = .empty;
    for (rows) |row| try texts.append(arena, row.text);
    const joined = try std.mem.join(arena, "\n", texts.items);
    try std.testing.expectEqualStrings("Planned 2 tasks\n→ Write parser\n○ Add tests\nCompleted Write parser\n1 of 2 done · next: Add tests", joined);
}
