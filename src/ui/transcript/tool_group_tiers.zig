//! Which rows of a tool group a person sees, and how loud each one is.
//!
//! Every row belongs to one tier:
//! - attention: failed, denied, cancelled or timed out, or still running.
//!   It keeps the status color and is never folded.
//! - outcome: what changed: files written or edited, commands run, workers
//!   started or stopped, jobs backgrounded or cancelled, checkpoints.
//! - routine: reads, lists, inspects, logs, observes, fetches, recall and
//!   sends. Adjacent routine rows share one dim row, "Read 6 files ·
//!   notes.md, app.py, +4".
//!
//! Rows come in the order the calls ran. A shell command that only reads,
//! lists or searches files reads as what it did (D290), and adjacent ones,
//! with file reads, share one "Explored · Read a, b · Searched x" row; a
//! call still running joins that row in the present tense. A command row
//! carries a short tail of its output (and a Python run its outline) so a
//! person sees what happened without opening the full transcript.
//!
//! A group only ever grows (D295): a new call appends rows or joins the
//! last shared row, a settling call fills in its own row and output, and
//! nothing above is folded away or cut. The inline renderer cannot take
//! back rows that have scrolled into the terminal's history, so a group
//! that shrank left that height as blank rows. Ctrl+O keeps every row.
const std = @import("std");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");
const human_text = @import("../../core/shared/human_text.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const python_outline = @import("python_outline.zig");
const bodies = @import("tool_group_bodies.zig");
const command_summary = @import("command_summary.zig");
const browser_summary = @import("../../core/browser/script_summary.zig");
const checklist_presentation = @import("../../core/checklist/presentation.zig");

const Allocator = std.mem.Allocator;
const ToolDetailRecord = transcript_blocks.ToolDetailRecord;

/// Names a fold lists before "+N".
const fold_names = 2;
/// Names one verb of an Explored row lists before "+N".
const explore_names = 3;

pub const Tier = enum { attention, outcome, routine };

pub const Item = struct {
    entry_id: u32,
    detail: ?*const ToolDetailRecord,
    /// The status phrase without its marker or styling.
    phrase: []const u8,
    /// Rows a card carries under its phrase, such as a worker's reply.
    continuation: ?[]const u8 = null,
};

pub const Style = enum { normal, dim, attention, output, success, accent, warning, dropped };
pub const Kind = enum { item, fold, arg, body };

pub const Row = struct {
    entry_id: u32,
    kind: Kind,
    style: Style,
    text: []const u8,
    /// The record an item row's command may be highlighted from.
    detail: ?*const ToolDetailRecord = null,
    /// Closed task text the renderer draws struck through.
    strike: bool = false,
    /// A row under a checklist call: it carries its own tree branches,
    /// so it hangs instead of continuing the group's rail.
    own_tree: bool = false,
    /// The call has not settled; its row gets the running glyph.
    running: bool = false,
};

pub fn isLive(detail: ?*const ToolDetailRecord) bool {
    const record = detail orelse return false;
    return record.outcome == null and record.fallback_disposition == null;
}

pub fn commandFailed(record: *const ToolDetailRecord) bool {
    if (record.activity_kind != .command) return false;
    const presentation = record.command_process_presentation orelse return false;
    return switch (presentation) {
        // A search that finds nothing exits 1; it did not fail.
        .exit_code => |code| code != 0 and !(code == 1 and searchFoundNothing(record)),
        .signal, .timed_out, .output_capture_failed => true,
    };
}

fn searchFoundNothing(record: *const ToolDetailRecord) bool {
    var buffer: [32 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const actions = explored(fixed.allocator(), record) orelse return false;
    for (actions) |action| if (action.kind != .search) return false;
    return std.mem.trim(u8, record.result orelse "", " \t\r\n").len == 0;
}

/// Whether a call only explores: a file read, a search, or a shell run that
/// only reads, lists and searches. An agent thinks between these, so its
/// thoughts do not split a block of them (D290).
pub fn isExploration(record: *const ToolDetailRecord) bool {
    if (record.activity_kind == .read) return true;
    var buffer: [32 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    return explored(fixed.allocator(), record) != null;
}

/// What a shell run reads, lists and searches when that is all it does,
/// or null (D290). Presentation only: it never decides what runs.
pub fn explored(arena: Allocator, record: *const ToolDetailRecord) ?[]const command_summary.Action {
    if (!isCommandRun(arena, record)) return null;
    if (!std.mem.eql(u8, record.tool_name, "shell") and !record.isCapturedCommand()) return null;
    const command = bodies.commandText(arena, record) orelse return null;
    if (python_outline.script(command) != null) return null;
    return command_summary.explore(arena, command) catch null;
}

/// An item's explored actions, when its row names a command it ran or is
/// running. A row in other words, such as the instruction refresh, keeps
/// them.
fn exploredItem(arena: Allocator, item: Item) ?[]const command_summary.Action {
    const record = item.detail orelse return null;
    if (!std.mem.startsWith(u8, item.phrase, "Ran ") and !std.mem.startsWith(u8, item.phrase, "Running ")) return null;
    return explored(arena, record);
}

/// Labels of a call that a security review held, and what each means.
const review_holds = [_][2][]const u8{
    .{ "Review unavailable", "reviewer unavailable" },
    .{ "Safety caution", "safety caution" },
    .{ "Review evidence incomplete", "review evidence incomplete" },
};

/// Why a review held this call, or null when it was not held.
fn heldReason(item: Item) ?[]const u8 {
    const record = item.detail orelse return null;
    if (record.outcome != .denied) return null;
    for (review_holds) |hold| {
        if (std.mem.startsWith(u8, item.phrase, hold[0])) return hold[1];
    }
    return null;
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
    if (exploredItem(arena, item) != null) return .routine;
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
        .write, .edit, .command, .subagent, .mcp => .outcome,
        .read, .open, .ask => if (isOneOf(name, &.{ "checkpoint", "rewind" })) .outcome else .routine,
    };
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

fn familyOf(arena: Allocator, item: Item) ?Family {
    const value = item.detail orelse return null;
    const name = value.tool_name;
    if (std.mem.eql(u8, name, "read_file")) return .{ .verb = "read", .one = "file", .many = "files" };
    if (std.mem.eql(u8, name, "write_file")) return .{ .verb = "wrote", .one = "file", .many = "files" };
    if (std.mem.eql(u8, name, "edit_file")) return .{ .verb = "edited", .one = "file", .many = "files" };
    if (std.mem.eql(u8, name, "web_fetch")) return .{ .verb = "fetched", .one = "page", .many = "pages" };
    // A read that failed counts as the command it was.
    if (!isFailure(value)) if (exploredItem(arena, item)) |actions| return switch (actions[0].kind) {
        .read => .{ .verb = "read", .one = "file", .many = "files" },
        .list => .{ .verb = "listed", .one = "directory", .many = "directories" },
        .search => .{ .verb = "searched", .one = "pattern", .many = "patterns" },
    };
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
        if (anomalyOf(item)) |anomaly| counts_by_anomaly[@backingInt(anomaly)] += 1;
        const family = familyOf(arena, item) orelse {
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

const Anomaly = enum { unreported, not_executed, timed_out, failed, held, denied, cancelled, running };
const anomaly_labels = [_][]const u8{ "unreported", "not executed", "timed out", "failed", "held", "denied", "cancelled", "running" };

/// What about a row needs attention, in the order the header names it.
fn anomalyOf(item: Item) ?Anomaly {
    const record = item.detail orelse return null;
    if (record.fallback_disposition) |disposition| return switch (disposition) {
        .completion_unreported => .unreported,
        .not_executed => .not_executed,
    };
    if (isLive(record)) return .running;
    if (record.command_process_presentation) |presentation| if (presentation == .timed_out and record.activity_kind == .command) return .timed_out;
    if (heldReason(item) != null) return .held;
    if (record.outcome == .denied) return .denied;
    if (record.outcome == .cancelled) return .cancelled;
    if (isFailure(record)) return .failed;
    return null;
}

// ---- rows ------------------------------------------------------------------

/// The rows under the header, in the order the calls ran (D295).
pub fn plan(arena: Allocator, items: []const Item) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    var index: usize = 0;
    while (index < items.len) {
        const kind = runKind(arena, items[index]) orelse {
            const item = items[index];
            const tail = if (item.detail) |record| keepsOutput(arena, item, record) else false;
            try appendItem(arena, &rows, item, styleOf(arena, item), tail);
            index += 1;
            continue;
        };
        var end = index + 1;
        while (end < items.len) : (end += 1) {
            const next = runKind(arena, items[end]) orelse break;
            if (!std.mem.eql(u8, next, kind)) break;
        }
        try appendRun(arena, &rows, items[index..end], kind);
        index = end;
    }
    return rows.items;
}

const explore_run = "explore";

/// The shared row an item joins with its neighbors, or null for a row of
/// its own: reads, lists and searches share "explore"; other routine calls
/// share by tool and verb. A call that failed or still waits on a person
/// stands alone; one that is running joins, so settling it moves nothing.
fn runKind(arena: Allocator, item: Item) ?[]const u8 {
    const record = item.detail orelse return null;
    if (isFailure(record)) return null;
    if (isFileRead(item)) return explore_run;
    if (exploredItem(arena, item) != null) return explore_run;
    if (isLive(record)) return null;
    if (tierOf(arena, item) != .routine) return null;
    return foldKey(arena, item) catch null;
}

/// A file read whose row says so: "Read notes.md", "Reading app.py".
fn isFileRead(item: Item) bool {
    const record = item.detail orelse return false;
    if (!std.mem.eql(u8, record.tool_name, "read_file")) return false;
    return std.mem.startsWith(u8, item.phrase, "Read ") or std.mem.startsWith(u8, item.phrase, "Reading ");
}

fn appendRun(arena: Allocator, rows: *std.ArrayList(Row), run: []const Item, kind: []const u8) !void {
    if (std.mem.eql(u8, kind, explore_run)) return appendExploreRun(arena, rows, run);
    const text = if (run.len == 1)
        try itemText(arena, run[0])
    else blk: {
        var folds: std.ArrayList(Fold) = .empty;
        for (run) |item| try addToFold(arena, &folds, item);
        break :blk try folds.items[0].text(arena);
    };
    const item = run[0];
    try rows.append(arena, .{
        .entry_id = item.entry_id,
        .kind = if (run.len == 1) .item else .fold,
        .style = .dim,
        .text = text,
        .detail = if (run.len == 1) item.detail else null,
        .running = run.len == 1 and isLive(item.detail),
    });
    if (run.len == 1) if (try argumentLine(arena, item, text)) |line| {
        try bodies.appendArgBody(arena, rows, item.entry_id, line);
    };
}

/// Reads, lists and searches read as one tree row each, in the order they
/// ran: "Read notes.md", "Searched \"x\" in app.py". A shell command that did
/// several of them becomes several rows instead of one combined "Explored".
fn appendExploreRun(arena: Allocator, rows: *std.ArrayList(Row), run: []const Item) !void {
    for (run) |item| {
        const running = isLive(item.detail);
        var emitted = false;
        if (exploredItem(arena, item)) |actions| {
            for (actions) |action| {
                try rows.append(arena, .{
                    .entry_id = item.entry_id,
                    .kind = .item,
                    .style = .dim,
                    .text = try arena.print("{s} {s}", .{
                        if (running) action.kind.present() else action.kind.past(),
                        action.target,
                    }),
                    .running = running,
                });
                emitted = true;
            }
        }
        if (!emitted) try rows.append(arena, .{
            .entry_id = item.entry_id,
            .kind = .item,
            .style = .dim,
            .text = try itemText(arena, item),
            .detail = item.detail,
            .running = running,
        });
    }
}

/// A group of one: its row in its own voice, never dim, with what it
/// carries under it.
pub fn single(arena: Allocator, item: Item) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    const style: Style = if (isFailure(item.detail)) .attention else .normal;
    const tail = if (item.detail) |record| keepsOutput(arena, item, record) else false;
    try appendItem(arena, &rows, item, style, tail);
    return rows.items;
}

/// A command keeps its output under its row unless it only read files and
/// finished well: then its row says what it read (D290).
fn keepsOutput(arena: Allocator, item: Item, record: *const ToolDetailRecord) bool {
    if (!isCommandRun(arena, record)) return false;
    // A call that was held or denied never ran: there is nothing under it.
    if (record.outcome == .denied) return false;
    if (isFailure(record)) return true;
    return exploredItem(arena, item) == null;
}

/// Adjacent reads as one row, codex's way: actions of a kind share their
/// verb, "Explored · Read a.ts, b.ts · Searched "x" in c.ts", and a call
/// still running reads in the present tense.
fn exploredText(arena: Allocator, run: []const Item) ![]const u8 {
    const Action = struct { kind: command_summary.Kind, target: []const u8, running: bool };
    var actions: std.ArrayList(Action) = .empty;
    for (run) |item| {
        const running = isLive(item.detail);
        if (exploredItem(arena, item)) |found| {
            for (found) |action| try actions.append(arena, .{ .kind = action.kind, .target = action.target, .running = running });
        } else {
            // A file read names its file and lines, not its whole path.
            const target = targetOf(item.phrase);
            const name = std.Io.Dir.path.basename(target[0 .. std.mem.findScalar(u8, target, ':') orelse target.len]);
            const range = if (std.mem.findScalar(u8, target, ':')) |at| target[at..] else "";
            try actions.append(arena, .{ .kind = .read, .target = try arena.print("{s}{s}", .{ name, range }), .running = running });
        }
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    try writer.writeAll("Explored · ");
    var index: usize = 0;
    while (index < actions.items.len) {
        const first = actions.items[index];
        var names: std.ArrayList([]const u8) = .empty;
        var end = index;
        while (end < actions.items.len and actions.items[end].kind == first.kind and actions.items[end].running == first.running) : (end += 1) {
            const target = actions.items[end].target;
            for (names.items) |known| {
                if (std.mem.eql(u8, known, target)) break;
            } else try names.append(arena, target);
        }
        if (index > 0) try writer.writeAll(" · ");
        try writer.print("{s} ", .{if (first.running) first.kind.present() else first.kind.past()});
        for (names.items[0..@min(names.items.len, explore_names)], 0..) |name, position| {
            if (position > 0) try writer.writeAll(", ");
            try writer.writeAll(name);
        }
        if (names.items.len > explore_names) try writer.print(", +{d}", .{names.items.len - explore_names});
        index = end;
    }
    return out.written();
}

fn appendItem(arena: Allocator, rows: *std.ArrayList(Row), item: Item, style: Style, tail: bool) !void {
    const text = try itemText(arena, item);
    try rows.append(arena, .{
        .entry_id = item.entry_id,
        .kind = .item,
        .style = style,
        .text = text,
        .detail = item.detail,
        .running = isLive(item.detail),
    });
    // What the row itself does not say, said once, under it. A row that
    // already says what the call read, listed or searched carries enough.
    const summarized = isFileRead(item) or exploredItem(arena, item) != null;
    if (!summarized) if (try argumentLine(arena, item, text)) |line| {
        try bodies.appendArgBody(arena, rows, item.entry_id, line);
    };
    // A card keeps one row under it: the one that carries its outcome.
    if (item.continuation) |continuation| {
        if (firstRow(continuation)) |row| try bodies.appendBody(arena, rows, item.entry_id, row);
    }
    if (tail) try bodies.appendCommandBody(arena, rows, item);
    if (item.detail) |record| if (try checklistView(arena, record)) |view| {
        for (view.body) |body_row| {
            const painted = checklistRowStyle(body_row);
            try rows.append(arena, .{
                .entry_id = item.entry_id,
                .kind = .body,
                .style = painted.style,
                .strike = painted.strike,
                .own_tree = true,
                .text = try bodies.safeLine(arena, body_row.text),
            });
        }
    };
}

/// How a checklist body row paints (D234): proto's colors by role and
/// status, with closed tasks struck through.
fn checklistRowStyle(row: checklist_presentation.BodyRow) struct { style: Style, strike: bool } {
    return switch (row.role) {
        .phase => .{ .style = .accent, .strike = false },
        .note => .{ .style = .dim, .strike = false },
        .task => switch (row.status orelse .pending) {
            .completed => .{ .style = .success, .strike = true },
            .in_progress => .{ .style = .accent, .strike = false },
            .blocked => .{ .style = .warning, .strike = false },
            .abandoned => .{ .style = .dropped, .strike = true },
            .pending => .{ .style = .dim, .strike = false },
        },
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
    if (record.outcome == .denied) return deniedText(arena, item, record);
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
        if (try human_text.failureReason(arena, bodies.commandOutput(record))) |reason| return arena.print("{s} · {s}", .{ label, reason });
        const name = if (bodies.commandText(arena, record)) |command|
            if (python_outline.script(command)) |found| found.interpreter else try command_summary.clean(arena, command)
        else if (std.mem.startsWith(u8, item.phrase, "Ran "))
            item.phrase["Ran ".len..]
        else
            return item.phrase;
        return arena.print("{s} · {s}", .{ label, name });
    }
    // A run names its command by the first line, and inline Python by its
    // interpreter; the outline below shows the rest.
    const verb = for ([_][]const u8{ "Ran", "Running", "Backgrounded" }) |candidate| {
        if (std.mem.startsWith(u8, item.phrase, candidate) and item.phrase.len > candidate.len and item.phrase[candidate.len] == ' ') break candidate;
    } else return item.phrase;
    if (exploredItem(arena, item)) |actions| return command_summary.phrase(arena, actions, isLive(record));
    const command = bodies.commandText(arena, record) orelse return item.phrase;
    if (python_outline.script(command)) |found| return arena.print("{s} {s}", .{ verb, found.interpreter });
    // The command without a leading `cd` or quiet redirects (D294).
    const first = bodies.firstLineOf(command);
    const cleaned = try command_summary.clean(arena, command);
    if (first.len < std.mem.trimEnd(u8, command, " \t\r\n").len) return arena.print("{s} {s} …", .{ verb, cleaned });
    if (cleaned.ptr == first.ptr or std.mem.eql(u8, cleaned, first)) return item.phrase;
    return arena.print("{s} {s}", .{ verb, cleaned });
}

/// Argument names a row may repeat so a person can see what the call acted
/// on. The row already carries any value it names, so only missing ones are
/// listed.
const argument_keys = [_][]const u8{ "path", "file_path", "pattern", "query", "url" };

/// The call's command or arguments, for a row that does not already say
/// them: proto's dim "└─" line. Null when the row carries everything.
fn argumentLine(arena: Allocator, item: Item, text: []const u8) !?[]const u8 {
    // A row that already ends in an ellipsis is a truncated frozen phrase;
    // its stored record may carry unrelated content, so nothing is added.
    if (std.mem.endsWith(u8, text, "…") or std.mem.endsWith(u8, text, "...")) return null;
    const record = item.detail orelse return null;
    if (!std.mem.eql(u8, record.tool_name, "browser")) if (bodies.commandText(arena, record)) |command| {
        // The row's voice already drops a leading `cd` and quiet redirects
        // (D294); the argument line uses the same cleaned command so it
        // never adds back what that decision hid.
        const cleaned = try command_summary.clean(arena, command);
        if (std.mem.find(u8, text, cleaned) != null) return null;
        return try bodies.safeLine(arena, cleaned);
    };
    const json = record.arguments_json orelse return null;
    const args = tool_args.parseToolArgsObject(arena, json) catch return null;
    var out: std.Io.Writer.Allocating = .init(arena);
    for (argument_keys) |key| {
        const raw = tool_args.optionalStringArg(args, key) orelse continue;
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (value.len == 0 or std.mem.find(u8, text, value) != null) continue;
        if (out.written().len > 0) try out.writer.writeAll(", ");
        try out.writer.print("{s}: {s}", .{ key, value });
    }
    if (out.written().len == 0) return null;
    return try bodies.safeLine(arena, out.written());
}

/// A call that did not run, in plain words (D293): "Held · reviewer
/// unavailable · grep -rn x src" for a review hold, "Denied · npm test"
/// otherwise. The model gets the reason with the result and goes on.
fn deniedText(arena: Allocator, item: Item, record: *const ToolDetailRecord) ![]const u8 {
    const separator = std.mem.find(u8, item.phrase, ": ");
    const label = if (separator) |at| item.phrase[0..at] else "Denied";
    var action = if (separator) |at| item.phrase[at + 2 ..] else item.phrase;
    if (record.activity_kind == .command) {
        if (bodies.commandText(arena, record)) |command| {
            action = if (python_outline.script(command)) |found| found.interpreter else try command_summary.clean(arena, command);
        }
    }
    if (heldReason(item)) |reason| return arena.print("Held · {s} · {s}", .{ reason, action });
    if (std.mem.eql(u8, action, item.phrase)) return item.phrase;
    return arena.print("{s} · {s}", .{ label, action });
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
    // The script names what it tried; a refused navigation did not happen (D235).
    const output = record.result orelse "";
    if (std.mem.find(u8, output, "navigation blocked: ") != null or std.mem.find(u8, output, ") refused: ") != null) {
        return arena.print("{s} · navigation blocked", .{summary});
    }
    return summary;
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

/// The shared row a routine call joins: reads and fetches by tool and
/// verb, every other routine call one list of what was checked.
fn foldKey(arena: Allocator, item: Item) ![]const u8 {
    const verb = item.phrase[0 .. std.mem.findScalar(u8, item.phrase, ' ') orelse item.phrase.len];
    const tool = if (item.detail) |record| record.tool_name else "";
    if (std.mem.eql(u8, tool, "web_fetch")) return arena.print("{s}\x00{s}", .{ tool, verb });
    return "routine";
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

test "adjacent routine rows fold, outcomes stay, failures say why" {
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
    const rows = try plan(arena, &items);
    var texts: std.ArrayList([]const u8) = .empty;
    for (rows) |row| try texts.append(arena, try arena.print("{s}:{s}", .{ @tagName(row.style), row.text }));
    const joined = try std.mem.join(arena, "\n", texts.items);
    try std.testing.expectEqualStrings(
        \\dim:Read notes.md
        \\dim:Read app.py
        \\dim:Read lib/a.py
        \\normal:Wrote out.txt +1
        \\attention:Exited 1 · cat: nope.txt: No such file or directory
        \\dim:cat nope.txt
        \\dim:Inspected sleep 9 ×2
    , joined);
}

test "a group of commands keeps every row and its output, in order" {
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
    const rows = try plan(arena, &items);
    try std.testing.expectEqual(@as(usize, 18), rows.len);
    for (0..9) |index| {
        try std.testing.expectEqualStrings(try arena.print("Ran echo {d}", .{index}), rows[index * 2].text);
        try std.testing.expectEqualStrings(try arena.print("{d}", .{index}), rows[index * 2 + 1].text);
    }
}

test "a running row comes last and settling it moves nothing above it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var records: [4]ToolDetailRecord = undefined;
    var items: [4]Item = undefined;
    for (&records, &items, 0..) |*record, *item, index| {
        const command = try arena.print("make step{d}", .{index});
        record.* = testRecord(@intCast(index + 1), "shell", .command, "{\"action\":\"run\"}");
        record.command_display = @constCast(command);
        record.command_process_presentation = .{ .exit_code = 0 };
        record.result = @constCast(try arena.print("built {d}\n", .{index}));
        item.* = .{ .entry_id = @intCast(index + 1), .detail = record, .phrase = try arena.print("Ran {s}", .{command}) };
    }
    records[3].outcome = null;
    records[3].command_process_presentation = null;
    records[3].result = null;
    items[3].phrase = "Running make step3";
    const live = try plan(arena, &items);
    try std.testing.expectEqualStrings("Running make step3", live[live.len - 1].text);
    records[3].outcome = .completed;
    records[3].command_process_presentation = .{ .exit_code = 0 };
    records[3].result = @constCast("built 3\n");
    items[3].phrase = "Ran make step3";
    const settled = try plan(arena, &items);
    // Every row before the running one is unchanged; the settled row and
    // its output follow.
    for (live[0 .. live.len - 1], 0..) |row, index| try std.testing.expectEqualStrings(row.text, settled[index].text);
    try std.testing.expectEqualStrings("Ran make step3", settled[live.len - 1].text);
    try std.testing.expectEqualStrings("built 3", settled[settled.len - 1].text);
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
    const rows = try plan(arena, &items);
    const expected = [_][]const u8{
        "Exited 1 · AttributeError: module 'os' has no attribute 'nope'",
        "python3 - <<'PY'",
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
    const rows = try plan(arena, &items);
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
    const broken = try plan(arena, &items);
    try std.testing.expectEqualStrings("print((1,", broken[2].text);
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
    const rows = try plan(arena, &items);
    var texts: std.ArrayList([]const u8) = .empty;
    for (rows) |row| try texts.append(arena, row.text);
    const joined = try std.mem.join(arena, "\n", texts.items);
    try std.testing.expect(std.mem.find(u8, joined, "Opened example.com") != null);
    try std.testing.expect(std.mem.find(u8, joined, "Filled #name, clicked Sign in +1\nawait tab.fill('#name', 'Ada');\nawait tab.click('text/Sign in');\nreturn await tab.text('#out');\nOutput\nHello Ada") != null);

    var blocked = testRecord(3, "browser", .command, "{\"action\":\"run\",\"code\":\"await tab.click('#go');\"}");
    blocked.result = @constCast("[main: navigation blocked: http://localhost/ is denied by the web_fetch rule for domain:localhost]");
    const blocked_rows = try plan(arena, &.{.{ .entry_id = 3, .detail = &blocked, .phrase = "Ran browser script on main" }});
    try std.testing.expectEqualStrings("Clicked #go · navigation blocked", blocked_rows[0].text);
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
    const rows = try plan(arena, &items);
    var texts: std.ArrayList([]const u8) = .empty;
    for (rows) |row| try texts.append(arena, try arena.print("{s}:{s}:{s}", .{ @tagName(row.style), row.text, if (row.strike) "struck" else "plain" }));
    const joined = try std.mem.join(arena, "\n", texts.items);
    try std.testing.expectEqualStrings(
        \\normal:Planned 2 tasks:plain
        \\accent:├─ □ Write parser:plain
        \\dim:└─ □ Add tests:plain
        \\normal:Completed Write parser:plain
        \\dim:1 of 2 done · next: Add tests:plain
    , joined);
    // Checklist body rows hang on their own tree; item rows do not.
    for (rows) |row| try std.testing.expectEqual(row.kind == .body, row.own_tree);
}

fn shellRun(arena: Allocator, entry_id: u32, command: []const u8, output: []const u8, exit_code: i32) !ToolDetailRecord {
    var record = testRecord(entry_id, "shell", .command, try arena.print("{f}", .{std.json.fmt(.{ .action = "run", .command = command }, .{})}));
    record.command_display = @constCast(command);
    record.command_process_presentation = .{ .exit_code = exit_code };
    record.result = @constCast(output);
    return record;
}

test "adjacent reading commands share one Explored row and only other commands keep their output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var records = [_]ToolDetailRecord{
        try shellRun(arena, 1, "ls -la ~/code/proto 2>/dev/null", "a\nb\n", 0),
        try shellRun(arena, 2, "cd ~/code/proto && sed -n '1,120p' packages/tui/src/components/markdown.ts", "line\n", 0),
        try shellRun(arena, 3, "cd ~/code/proto && grep -n \"table\" packages/tui/src/components/markdown.ts | head -60", "12: table\n", 0),
        try shellRun(arena, 4, "cd ~/code/proto && cat package.json", "{}\n", 0),
        try shellRun(arena, 5, "cd ~/code/proto && git log --oneline -3", "abc first\n", 0),
        try shellRun(arena, 6, "rg -n nothing-here src", "", 1),
    };
    var items: [records.len]Item = undefined;
    for (&items, &records) |*item, *record| item.* = .{ .entry_id = record.entry_id, .detail = record, .phrase = try arena.print("Ran {s}", .{record.command_display.?}) };
    const summary = try header(arena, &items);
    try std.testing.expectEqualStrings("Read 2 files, searched 2 patterns, listed 1 directory and 1 other call", summary.words);
    try std.testing.expectEqualStrings("", summary.attention);
    const rows = try plan(arena, &items);
    var texts: std.ArrayList([]const u8) = .empty;
    for (rows) |row| try texts.append(arena, try arena.print("{s}:{s}", .{ @tagName(row.style), row.text }));
    try std.testing.expectEqualStrings(
        \\dim:Listed ~/code/proto
        \\dim:Read markdown.ts:1-120
        \\dim:Searched "table" in markdown.ts
        \\dim:Read package.json
        \\normal:Ran git log --oneline -3
        \\output:abc first
        \\dim:Searched "nothing-here" in src
    , try std.mem.join(arena, "\n", texts.items));

    // A group of one read reads as what it read, with nothing under it.
    const one = try single(arena, items[1]);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("Read markdown.ts:1-120", one[0].text);
    // While it runs it says so.
    records[2].outcome = null;
    records[2].command_process_presentation = null;
    const live = try single(arena, items[2]);
    // A job sent to the background names its Python by the interpreter.
    var job = try shellRun(arena, 7, "sleep 4; python3 - <<'PY'\nprint(1)\nPY", "", 0);
    const backgrounded = try single(arena, .{ .entry_id = 7, .detail = &job, .phrase = "Backgrounded sleep 4; python3 - <<'PY' print(1) PY" });
    try std.testing.expectEqualStrings("Backgrounded python3", backgrounded[0].text);
    try std.testing.expectEqualStrings("Searching \"table\" in markdown.ts", live[0].text);
}

test "a call a review held says so plainly and the header counts it as held" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var held = try shellRun(arena, 1, "cd ~/code/proto && grep -rn \"getMarkdownTheme\" packages/coding-agent/src --include=\"*.ts\" | head -20", "", 0);
    held.outcome = .denied;
    held.command_process_presentation = null;
    var denied = try shellRun(arena, 2, "npm publish", "", 0);
    denied.outcome = .denied;
    denied.command_process_presentation = null;
    var ran = try shellRun(arena, 3, "make", "ok\n", 0);
    const items = [_]Item{
        .{ .entry_id = 1, .detail = &held, .phrase = "Review unavailable: Running cd ~/code/proto && grep -rn \"getMarkdownTheme\" packages/coding-agent/src --include=\"*.ts\" | head -20" },
        .{ .entry_id = 2, .detail = &denied, .phrase = "Denied by auto agent: Running npm publish" },
        .{ .entry_id = 3, .detail = &ran, .phrase = "Ran make" },
    };
    const summary = try header(arena, &items);
    try std.testing.expectEqualStrings(" · 1 held · 1 denied", summary.attention);
    const rows = try plan(arena, &items);
    try std.testing.expectEqualStrings("Held · reviewer unavailable · grep -rn \"getMarkdownTheme\" packages/coding-agent/src --include=\"*.ts\" | head -20", rows[0].text);
    try std.testing.expectEqual(Style.attention, rows[0].style);
    try std.testing.expectEqualStrings("Denied by auto agent · npm publish", rows[1].text);
    // Nothing ran, so nothing sits under either row.
    try std.testing.expectEqualStrings("Ran make", rows[2].text);
}
