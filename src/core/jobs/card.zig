//! The transcript card of a `jobs` call: a status phrase in the voice of
//! the other tool rows, then one aligned row per job. It reads the tool's
//! JSON result, so a replayed call renders the same card.
//!
//! "Listed jobs · 1 of 3 running · 1 failed"
//! "  ◐ bg_1  shell  bun run build  1m2s"
//! "  ✗ bg_2  shell  npm test       4.1s"
const std = @import("std");
const jobs = @import("jobs.zig");
const text_utils = @import("../shared/text_utils.zig");
const Allocator = std.mem.Allocator;

/// Collapsed lists show this many rows, then "… N more jobs".
pub const max_rows = 8;
const max_label_cols = 40;

pub const RowJob = struct {
    id: []const u8 = "",
    kind: []const u8 = "",
    label: []const u8 = "",
    state: []const u8 = "",
    duration_ms: u64 = 0,
    tearing_down: bool = false,
};

const Result = struct {
    op: []const u8 = "",
    id: ?[]const u8 = null,
    jobs: []const RowJob = &.{},
    pending: []const RowJob = &.{},
    timed_out: bool = false,
    waited_ms: u64 = 0,
    receipt: ?[]const u8 = null,
    signal: ?[]const u8 = null,
    retained_bytes: usize = 0,
};

/// The card's lines, the phrase first, or null when `output` is not a jobs
/// result.
pub fn statusText(arena: Allocator, output: []const u8) !?[]const u8 {
    const result = std.json.parseFromSliceLeaky(Result, arena, output, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    var buf: [32]u8 = undefined;
    const op = result.op;
    if (std.mem.eql(u8, op, "list")) {
        try writer.writeAll("Listed jobs");
        try writeCounts(writer, result.jobs);
        try writeRows(arena, writer, result.jobs);
    } else if (std.mem.eql(u8, op, "wait")) {
        if (result.jobs.len > 0) {
            try writer.print("Waited · {d} settled", .{result.jobs.len});
            if (result.pending.len > 0) try writer.print(" · {d} still running", .{result.pending.len});
            try writeRows(arena, writer, result.jobs);
        } else if (result.timed_out) {
            try writer.print("Waited {s} · nothing settled · {d} still running", .{ jobs.formatDuration(&buf, result.waited_ms), result.pending.len });
        } else {
            try writer.writeAll("Waited · nothing left to wait on");
        }
    } else if (std.mem.eql(u8, op, "inspect")) {
        try writer.print("Inspected {s}", .{result.id orelse "job"});
        try writeRows(arena, writer, result.jobs);
    } else if (std.mem.eql(u8, op, "logs")) {
        try writer.print("Read logs {s}", .{result.id orelse "job"});
        if (result.retained_bytes > 0) try writer.print(" · {d} bytes", .{result.retained_bytes});
    } else if (std.mem.eql(u8, op, "cancel") or std.mem.eql(u8, op, "signal")) {
        try writer.print("{s} {s}", .{ if (std.mem.eql(u8, op, "cancel")) "Cancelled" else "Signalled", result.id orelse "job" });
        if (result.signal) |signal| try writer.print(" {s}", .{signal});
        if (result.receipt) |receipt| try writer.print(" · {s}", .{receiptWord(receipt)});
    } else return null;
    return out.written();
}

/// The row of a shell run that went to the background:
/// "Backgrounded npm run build · bg_3". Null for any other shell result.
pub fn backgroundedShellText(arena: Allocator, args_json: []const u8, output: []const u8) !?[]const u8 {
    const Run = struct { state: []const u8 = "", job_id: ?[]const u8 = null };
    const run = std.json.parseFromSliceLeaky(Run, arena, output, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const job_id = run.job_id orelse return null;
    if (!std.mem.eql(u8, run.state, "running")) return null;
    const Args = struct { command: []const u8 = "" };
    const args = std.json.parseFromSliceLeaky(Args, arena, args_json, .{ .ignore_unknown_fields = true }) catch Args{};
    const command = try text_utils.encodeTerminalSafeInline(arena, args.command, 160);
    return try arena.print("Backgrounded {s} · {s}", .{ command.bytes, job_id });
}

fn receiptWord(receipt: []const u8) []const u8 {
    if (std.mem.eql(u8, receipt, "already_settled")) return "already settled";
    return receipt;
}

fn writeCounts(writer: *std.Io.Writer, rows: []const RowJob) !void {
    var running: usize = 0;
    var failed: usize = 0;
    var cancelled: usize = 0;
    var done: usize = 0;
    for (rows) |row| switch (stateOf(row)) {
        .queued, .running => running += 1,
        .failed => failed += 1,
        .cancelled => cancelled += 1,
        .completed => done += 1,
    };
    if (rows.len == 0) return writer.writeAll(" · none");
    if (running == rows.len) {
        try writer.print(" · {d} running", .{running});
    } else if (running > 0) {
        try writer.print(" · {d} of {d} running", .{ running, rows.len });
    } else {
        try writer.print(" · {d} settled", .{rows.len});
    }
    if (done > 0 and running > 0) try writer.print(" · {d} done", .{done});
    if (failed > 0) try writer.print(" · {d} failed", .{failed});
    if (cancelled > 0) try writer.print(" · {d} cancelled", .{cancelled});
}

fn stateOf(row: RowJob) jobs.State {
    return std.meta.stringToEnum(jobs.State, row.state) orelse .running;
}

pub fn glyph(state: jobs.State) []const u8 {
    return switch (state) {
        .queued, .running => "◐",
        .completed => "✓",
        .failed => "✗",
        .cancelled => "⊘",
    };
}

/// Rows aligned in columns: glyph, id, kind, label, duration.
fn writeRows(arena: Allocator, writer: *std.Io.Writer, rows: []const RowJob) !void {
    const shown = rows[0..@min(rows.len, max_rows)];
    var id_cols: usize = 0;
    var kind_cols: usize = 0;
    var label_cols: usize = 0;
    const labels = try arena.alloc([]const u8, shown.len);
    for (shown, labels) |row, *label| {
        const safe = try text_utils.encodeTerminalSafeInline(arena, row.label, max_label_cols * 4);
        label.* = clipCols(safe.bytes, max_label_cols);
        id_cols = @max(id_cols, row.id.len);
        kind_cols = @max(kind_cols, row.kind.len);
        label_cols = @max(label_cols, cols(label.*));
    }
    var buf: [32]u8 = undefined;
    for (shown, labels) |row, label| {
        try writer.print("\n  {s} ", .{glyph(stateOf(row))});
        try pad(writer, row.id, id_cols);
        try writer.writeAll("  ");
        try pad(writer, row.kind, kind_cols);
        try writer.writeAll("  ");
        try pad(writer, label, label_cols);
        try writer.print("  {s}", .{jobs.formatDuration(&buf, row.duration_ms)});
        if (row.tearing_down) try writer.writeAll(" · tearing down");
    }
    if (rows.len > shown.len) try writer.print("\n  … {d} more jobs", .{rows.len - shown.len});
}

fn cols(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn clipCols(text: []const u8, max: usize) []const u8 {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (count += 1) {
        if (count == max) return text[0..index];
        index += std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
    }
    return text;
}

fn pad(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    try writer.splatByteAll(' ', width -| cols(text));
}

test "a list card counts states and aligns its rows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const output =
        \\{"op":"list","jobs":[
        \\{"id":"bg_1","kind":"shell","label":"bun run build","state":"running","duration_ms":62000},
        \\{"id":"bg_2","kind":"shell","label":"npm test","state":"failed","duration_ms":4100},
        \\{"id":"w-t1","kind":"worker","label":"parser","state":"completed","duration_ms":850}]}
    ;
    try std.testing.expectEqualStrings(
        "Listed jobs · 1 of 3 running · 1 done · 1 failed\n" ++
            "  ◐ bg_1  shell   bun run build  1m2s\n" ++
            "  ✗ bg_2  shell   npm test       4.1s\n" ++
            "  ✓ w-t1  worker  parser         850ms",
        (try statusText(arena, output)).?,
    );
}

test "wait cards report what settled or that the window passed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "Waited 30.0s · nothing settled · 1 still running",
        (try statusText(arena, "{\"op\":\"wait\",\"timed_out\":true,\"waited_ms\":30000,\"pending\":[{\"id\":\"bg_1\"}]}")).?,
    );
    try std.testing.expectEqualStrings(
        "Waited · 1 settled\n  ✓ bg_3  shell  make  2m",
        (try statusText(arena, "{\"op\":\"wait\",\"jobs\":[{\"id\":\"bg_3\",\"kind\":\"shell\",\"label\":\"make\",\"state\":\"completed\",\"duration_ms\":120000}]}")).?,
    );
    try std.testing.expectEqualStrings(
        "Cancelled bg_3 · settled",
        (try statusText(arena, "{\"op\":\"cancel\",\"id\":\"bg_3\",\"receipt\":\"settled\"}")).?,
    );
    try std.testing.expect((try statusText(arena, "not json")) == null);
}

test "a backgrounded shell run names its job" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "Backgrounded sleep 90 · bg_3",
        (try backgroundedShellText(arena, "{\"action\":\"run\",\"command\":\"sleep 90\"}", "{\"state\":\"running\",\"job_id\":\"bg_3\"}")).?,
    );
    try std.testing.expect((try backgroundedShellText(arena, "{}", "{\"state\":\"completed\"}")) == null);
}

test "long lists collapse after eight rows" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rows: [11]RowJob = undefined;
    for (&rows, 0..) |*row, index| row.* = .{ .id = try arena.print("bg_{d}", .{index}), .kind = "shell", .label = "x", .state = "completed" };
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeRows(arena, &out.writer, &rows);
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "\n  … 3 more jobs"));
}
