//! U02 lab: drives the real request core with a seeded random event stream and
//! writes its trace, so the Bun driver can have TLC check the core against
//! spec/Request.tla before any transport exists. Dev only; never moves into fx.
//!
//! Usage: request_lab <trace-path> [--seed N] [--steps N] [--slots N]
//!                    [--plant-bug late-delivery]
//!
//! `--plant-bug late-delivery` is a known-bad control: when a late response
//! arrives, the lab reports the core as having delivered it a second time.

const std = @import("std");
const mcp = @import("mcp");

/// Trace code is compiled in.
pub const mcpv2_trace = true;
const request = mcp.core.request;

const Options = struct {
    trace_path: []const u8,
    seed: u64 = 1,
    steps: u32 = 200,
    slots: usize = 4,
    plant_late_delivery: bool = false,
};

fn parseOptions(args: []const [:0]const u8) !Options {
    if (args.len < 2) return error.InvalidArguments;
    var options: Options = .{ .trace_path = args[1] };
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        const value = if (index + 1 < args.len) args[index + 1] else "";
        if (std.mem.eql(u8, arg, "--seed")) {
            options.seed = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--steps")) {
            options.steps = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--slots")) {
            options.slots = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--plant-bug") and std.mem.eql(u8, value, "late-delivery")) {
            options.plant_late_delivery = true;
        } else return error.InvalidArguments;
        index += 1;
    }
    if (options.slots == 0 or options.slots > 64) return error.InvalidArguments;
    return options;
}

/// Picks the next event. Ids range over every issued id plus one unknown, so
/// late, duplicate, and unknown-id messages all occur.
fn nextEvent(random: std.Random, table: *const request.Table, sent_initialize: bool) request.Event {
    const id = random.intRangeAtMost(request.Id, 1, table.next_id);
    return switch (random.uintLessThan(u8, 10)) {
        0, 1 => .{ .send = if (!sent_initialize and random.uintLessThan(u8, 3) == 0) .initialize else .normal },
        2, 3 => .{ .response_received = .{ .id = id, .response = if (random.boolean()) .result else .peer_error } },
        4 => .{ .cancel_requested = id },
        5 => .{ .timer_fired = .{ .id = id, .kind = .hard, .generation = 0 } },
        6 => .{ .timer_fired = .{ .id = id, .kind = .idle, .generation = random.intRangeAtMost(u32, 1, 3) } },
        7 => .{ .transport_lost = id },
        8 => .{ .progress_received = .{ .token = id, .value = @floatFromInt(random.uintLessThan(u8, 5)) } },
        else => .{ .server_cancel_received = id },
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const options = parseOptions(args) catch {
        std.debug.print("usage: request_lab <trace-path> [--seed N] [--steps N] [--slots N] [--plant-bug late-delivery]\n", .{});
        std.process.exit(2);
    };

    var file = try std.Io.Dir.cwd().createFile(io, options.trace_path, .{});
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    var trace: mcp.trace.Writer = .init(&file_writer.interface);

    const slots = try arena.alloc(request.Slot, options.slots);
    var table: request.Table = .init(slots, .{});
    var prng: std.Random.DefaultPrng = .init(options.seed);
    const random = prng.random();
    var sent_initialize = false;

    var delivered: u32 = 0;
    for (0..options.steps) |_| {
        const event = nextEvent(random, &table, sent_initialize);
        var out: request.Output = .{};
        table.step(event, &out) catch |err| switch (err) {
            // Refused steps change nothing and have no model action.
            error.TooManyInFlight, error.InitializeNotCancellable => continue,
            error.IdsExhausted => return err,
        };
        if (event == .send and event.send == .initialize) sent_initialize = true;
        for (out.effects()) |effect| delivered += @intFromBool(effect == .deliver);

        if (options.plant_late_delivery and event == .response_received and out.transition.?.from == .done) {
            out.transition.?.state = .{ .outcome = .result, .delivered = 2, .cancel_sent = false, .progress = 0 };
        }
        try request.writeTrace(&trace, "lab", &out);
    }
    try file_writer.interface.flush();
    std.debug.print("request_lab: seed {d}, {d} steps, {d} ids, {d} outcomes delivered\n", .{
        options.seed, trace.next_seq - 1, table.next_id - 1, delivered,
    });
}
