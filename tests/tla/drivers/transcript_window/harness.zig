//! Runs the real transcript window core over JSON lines for the TLA+ drivers.
//!
//! The first input line is the config: `{"config":{"window":2,"read_step":1,
//! "slice":1,"saved":true}}`. The harness then prints the zero state, and one
//! line per event after it: `abstract(state)`, the live ids in order, the
//! step's effects, and the rejection, if any. A crash is the driver killing
//! this process; a new one starts from the zero state and is sent `resumed`.

const std = @import("std");
const tw = @import("transcript_window");

const Input = struct {
    config: ?tw.Config = null,
    event: ?[]const u8 = null,
    id: ?tw.BlockId = null,
    seq: ?tw.Seq = null,
    dir: ?[]const u8 = null,
    token: ?tw.Token = null,
    count: ?u32 = null,
    cycle: ?u32 = null,
    cycle_first: ?tw.Seq = null,
    next_seq: ?tw.Seq = null,
};

const EffectJson = struct {
    kind: []const u8,
    seq: ?tw.Seq = null,
    id: ?tw.BlockId = null,
    from: ?tw.Seq = null,
    to: ?tw.Seq = null,
    lo: ?tw.Seq = null,
    hi: ?tw.Seq = null,
    token: ?tw.Token = null,
    dir: ?tw.Dir = null,
    count: ?u32 = null,
};

const Line = struct {
    state: tw.Abstract,
    live: []const tw.BlockId,
    out: []const EffectJson,
    rejected: ?tw.Rejection = null,
};

fn need(comptime T: type, value: ?T) error{InvalidEvent}!T {
    return value orelse error.InvalidEvent;
}

fn parseDir(text: ?[]const u8) error{InvalidEvent}!tw.Dir {
    const dir = try need([]const u8, text);
    if (std.mem.eql(u8, dir, "older")) return .older;
    if (std.mem.eql(u8, dir, "newer")) return .newer;
    return error.InvalidEvent;
}

fn event(input: Input) error{InvalidEvent}!tw.Event {
    const name = try need([]const u8, input.event);
    const eql = std.mem.eql;
    if (eql(u8, name, "turn_started")) return .turn_started;
    if (eql(u8, name, "turn_ended")) return .turn_ended;
    if (eql(u8, name, "block_opened")) return .{ .block_opened = try need(tw.BlockId, input.id) };
    if (eql(u8, name, "block_changed")) return .{ .block_changed = try need(tw.BlockId, input.id) };
    if (eql(u8, name, "block_finished")) return .{ .block_finished = try need(tw.BlockId, input.id) };
    if (eql(u8, name, "saved_through")) return .{ .saved_through = try need(tw.Seq, input.seq) };
    if (eql(u8, name, "compacted")) return .compacted;
    if (eql(u8, name, "resized")) return .resized;
    if (eql(u8, name, "reprint_tick")) return .reprint_tick;
    if (eql(u8, name, "ctrlo_opened")) return .ctrlo_opened;
    if (eql(u8, name, "ctrlo_scrolled")) return .{ .ctrlo_scrolled = try parseDir(input.dir) };
    if (eql(u8, name, "ctrlo_closed")) return .ctrlo_closed;
    if (eql(u8, name, "log_read_done")) return .{ .log_read_done = .{
        .token = try need(tw.Token, input.token),
        .count = try need(u32, input.count),
    } };
    if (eql(u8, name, "log_read_failed")) return .{ .log_read_failed = try need(tw.Token, input.token) };
    if (eql(u8, name, "resumed")) return .{ .resumed = .{
        .cycle = try need(u32, input.cycle),
        .cycle_first = try need(tw.Seq, input.cycle_first),
        .next_seq = try need(tw.Seq, input.next_seq),
    } };
    return error.InvalidEvent;
}

fn effectJson(effect: tw.Effect) EffectJson {
    return switch (effect) {
        .paint_final => |seq| .{ .kind = "paint_final", .seq = seq },
        .repaint_block => |id| .{ .kind = "repaint_block", .id = id },
        .reprint_begin => .{ .kind = "reprint_begin" },
        .reprint_slice => |range| .{ .kind = "reprint_slice", .from = range.from, .to = range.to },
        .repaint_live => .{ .kind = "repaint_live" },
        .drop => |range| .{ .kind = "drop", .from = range.from, .to = range.to },
        .ctrlo_show => |range| .{ .kind = "ctrlo_show", .lo = range.from, .hi = range.to },
        .read_log => |read| .{ .kind = "read_log", .token = read.token, .dir = read.dir, .from = read.from, .count = read.count },
    };
}

fn writeLine(writer: *std.Io.Writer, state: *const tw.State, effect: ?tw.Effect, rejected: ?tw.Rejection) !void {
    var live: [tw.max_live]tw.BlockId = undefined;
    const ids = live[0..state.live.len];
    @memcpy(ids, state.live.items());
    std.mem.sort(tw.BlockId, ids, {}, std.sort.asc(tw.BlockId));
    var effects: [1]EffectJson = undefined;
    var count: usize = 0;
    if (effect) |one| {
        effects[0] = effectJson(one);
        count = 1;
    }
    try std.json.Stringify.value(Line{
        .state = tw.abstract(state),
        .live = ids,
        .out = effects[0..count],
        .rejected = rejected,
    }, .{ .emit_null_optional_fields = false }, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var in_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buffer);
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);

    var state: ?tw.State = null;
    while (try stdin.interface.takeDelimiter('\n')) |raw| {
        const text = std.mem.trim(u8, raw, " \r\t");
        if (text.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Input, alloc, text, .{});
        defer parsed.deinit();
        if (parsed.value.config) |config| {
            state = tw.State.init(config);
            try writeLine(&stdout.interface, &state.?, null, null);
            continue;
        }
        const out = tw.step(state orelse return error.MissingConfig, try event(parsed.value));
        state = out.state;
        try writeLine(&stdout.interface, &state.?, out.effect, out.rejected);
    }
}
