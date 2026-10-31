//! A JSON-lines shell around the real `fx mcp call` bridge core, for the Bun
//! drivers.
//!
//! Built from `src/core/mcp_host/mcp_call.zig` (or a planted-bug copy of it)
//! as the `mcp_call` module. `--capacity N` sets the requests the bridge holds
//! at once (the model uses 2). On start it prints the core's zero state. Then
//! it reads one event per line and prints one line per event:
//!
//!   in:  {"event":"started","token":"t1"}
//!        {"event":"request","token":"t1","version":1}
//!        {"event":"authorized","id":0,"allow":true}
//!        {"event":"call_finished","id":0,"outcome":"ok"}
//!   out: {"state":{"open":true,"next":1,"registered":[...],"entries":[...]},"out":[...]}
//!
//! `state` is `mcp_call.abstract`, and `out` is the effects `step` returned,
//! in the spec's record shapes. The harness is a shell: it maps the model's
//! names for owners and tokens onto the core's ids and 32-byte tokens and
//! back, and holds the state between lines. A crash is the driver killing
//! this process.
const std = @import("std");
const mcp_call = @import("mcp_call");

const Input = struct {
    event: []const u8,
    token: ?[]const u8 = null,
    owner: ?[]const u8 = null,
    version: ?u32 = null,
    id: ?u64 = null,
    allow: ?bool = null,
    outcome: ?mcp_call.Outcome = null,
    delivered: ?bool = null,
};

const RegisteredJson = struct { owner: []const u8, token: []const u8 };
const EntryJson = struct { id: u64, owner: []const u8, stage: mcp_call.Stage };
const StateJson = struct {
    open: bool,
    next: u64,
    registered: []const RegisteredJson,
    entries: []const EntryJson,
};
const EffectJson = struct {
    kind: []const u8,
    id: ?u64 = null,
    owner: ?[]const u8 = null,
    reason: ?mcp_call.Refusal = null,
    outcome: ?mcp_call.ReplyOutcome = null,
    what: ?mcp_call.Drop = null,
};
const Line = struct { state: StateJson, out: []const EffectJson };

const token_names = [_][]const u8{ "t1", "t2", "forged" };

fn token(name: []const u8) error{InvalidToken}!mcp_call.Token {
    for (token_names, 0..) |known, index| {
        if (std.mem.eql(u8, known, name)) return @splat(@as(u8, @intCast(0x11 * (index + 1))));
    }
    return error.InvalidToken;
}

fn tokenName(value: mcp_call.Token) []const u8 {
    for (token_names) |name| {
        const known = token(name) catch continue;
        if (std.mem.eql(u8, &known, &value)) return name;
    }
    return "unknown";
}

fn owner(name: []const u8) error{InvalidOwner}!mcp_call.OwnerId {
    if (std.mem.eql(u8, name, "main")) return .main;
    if (std.mem.eql(u8, name, "child")) return @fromBackingInt(1);
    return error.InvalidOwner;
}

fn ownerName(id: mcp_call.OwnerId) []const u8 {
    return if (id == .main) "main" else "child";
}

const InputError = error{ InvalidEvent, InvalidToken, InvalidOwner };

fn need(comptime T: type, value: ?T) InputError!T {
    return value orelse error.InvalidEvent;
}

fn event(input: Input) InputError!mcp_call.Event {
    const name = input.event;
    if (std.mem.eql(u8, name, "started")) return .{ .started = try token(try need([]const u8, input.token)) };
    if (std.mem.eql(u8, name, "stopped")) return .stopped;
    if (std.mem.eql(u8, name, "owner_added")) return .{ .owner_added = .{
        .owner = try owner(try need([]const u8, input.owner)),
        .token = try token(try need([]const u8, input.token)),
    } };
    if (std.mem.eql(u8, name, "owner_removed")) return .{ .owner_removed = try owner(try need([]const u8, input.owner)) };
    if (std.mem.eql(u8, name, "request")) return .{ .request = .{
        .token = try token(try need([]const u8, input.token)),
        .version = try need(u32, input.version),
    } };
    const id: mcp_call.RequestId = @fromBackingInt(try need(u64, input.id));
    if (std.mem.eql(u8, name, "authorized")) return .{ .authorized = .{ .id = id, .decision = if (try need(bool, input.allow)) .allow else .deny } };
    if (std.mem.eql(u8, name, "call_finished")) return .{ .call_finished = .{ .id = id, .outcome = try need(mcp_call.Outcome, input.outcome) } };
    if (std.mem.eql(u8, name, "reply_done")) return .{ .reply_done = .{ .id = id, .delivery = if (try need(bool, input.delivered)) .delivered else .lost } };
    if (std.mem.eql(u8, name, "client_gone")) return .{ .client_gone = id };
    return error.InvalidEvent;
}

fn effectJson(effect: mcp_call.Effect) EffectJson {
    return switch (effect) {
        .refuse => |reason| .{ .kind = "refuse", .reason = reason },
        .authorize => |work| .{ .kind = "authorize", .id = @backingInt(work.id), .owner = ownerName(work.owner) },
        .call => |work| .{ .kind = "call", .id = @backingInt(work.id), .owner = ownerName(work.owner) },
        .withdraw => |id| .{ .kind = "withdraw", .id = @backingInt(id) },
        .cancel => |id| .{ .kind = "cancel", .id = @backingInt(id) },
        .reply => |reply| .{ .kind = "reply", .id = @backingInt(reply.id), .outcome = reply.outcome },
        .log => |log| .{ .kind = "log", .id = @backingInt(log.id), .what = log.drop },
    };
}

fn writeLine(writer: *std.Io.Writer, state: *const mcp_call.State, effects: []const mcp_call.Effect) !void {
    const view = mcp_call.abstract(state);
    var registered: [mcp_call.max_owners]RegisteredJson = undefined;
    for (view.owners(), 0..) |registration, index| registered[index] = .{ .owner = ownerName(registration.id), .token = tokenName(registration.token) };
    var entries: [mcp_call.max_slots]EntryJson = undefined;
    for (view.entries(), 0..) |entry, index| entries[index] = .{ .id = @backingInt(entry.id), .owner = ownerName(entry.owner), .stage = entry.stage };
    var out: [mcp_call.max_effects]EffectJson = undefined;
    for (effects, 0..) |effect, index| out[index] = effectJson(effect);
    const line: Line = .{
        .state = .{ .open = view.open, .next = view.next, .registered = registered[0..view.owners().len], .entries = entries[0..view.entries().len] },
        .out = out[0..effects.len],
    };
    try std.json.Stringify.value(line, .{ .emit_null_optional_fields = false }, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const args = try init.minimal.args.toSlice(arena_state.allocator());
    var capacity: u8 = mcp_call.default_capacity;
    if (args.len == 3 and std.mem.eql(u8, args[1], "--capacity")) capacity = try std.fmt.parseInt(u8, args[2], 10);

    var in_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buffer);
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);

    var state = mcp_call.State.init(capacity);
    try writeLine(&stdout.interface, &state, &.{});
    while (try stdin.interface.takeDelimiter('\n')) |raw| {
        const text = std.mem.trim(u8, raw, " \r\t");
        if (text.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Input, alloc, text, .{});
        defer parsed.deinit();
        const out = mcp_call.step(state, try event(parsed.value));
        state = out.state;
        try writeLine(&stdout.interface, &state, out.effects());
    }
}
