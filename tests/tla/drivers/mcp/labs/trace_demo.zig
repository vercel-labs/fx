//! Bridge self-test program. Not product code.
//!
//! Runs the Selftest machine as a pure step function over events from the
//! command line and writes a real trace through `mcp.trace`. With
//! `--allow-late-delivery` it reproduces the planted bug from
//! Selftest.tla, so the bridge must reject its trace.
//!
//! Usage: trace_demo <trace-path> [--allow-late-delivery] <event>...
//! Events: response_received, cancel_requested

const std = @import("std");
const mcp = @import("mcp");

/// Trace code is compiled in.
pub const mcpv2_trace = true;

const Status = enum { pending, done, cancelled };

const Event = enum { response_received, cancel_requested };

const Machine = struct {
    status: Status = .pending,
    outcomes: i64 = 0,

    /// Pure: returns the next state, or null when the event is not allowed.
    fn step(self: Machine, event: Event, allow_late_delivery: bool) ?Machine {
        return switch (event) {
            .response_received => switch (self.status) {
                .pending => .{ .status = .done, .outcomes = self.outcomes + 1 },
                .cancelled => if (allow_late_delivery) .{ .status = .done, .outcomes = self.outcomes + 1 } else null,
                .done => null,
            },
            .cancel_requested => switch (self.status) {
                .pending => .{ .status = .cancelled, .outcomes = self.outcomes + 1 },
                .cancelled, .done => null,
            },
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: trace_demo <trace-path> [--allow-late-delivery] <event>...\n", .{});
        return error.InvalidArguments;
    }

    var allow_late_delivery = false;
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--allow-late-delivery")) allow_late_delivery = true;
    }

    var file = try std.Io.Dir.cwd().createFile(io, args[1], .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    var trace: mcp.trace.Writer = .init(&file_writer.interface);

    var machine: Machine = .{};
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--allow-late-delivery")) continue;
        const event = std.meta.stringToEnum(Event, arg) orelse {
            std.debug.print("trace_demo: unknown event {s}\n", .{arg});
            return error.InvalidArguments;
        };
        const next = machine.step(event, allow_late_delivery) orelse continue;
        try trace.write(.{
            .machine = "selftest",
            .instance = "demo",
            .event = @tagName(event),
            .from = @tagName(machine.status),
            .to = @tagName(next.status),
            .data = &.{.{ .name = "outcomes", .value = .{ .int = next.outcomes } }},
        });
        machine = next;
    }
    try file_writer.interface.flush();
}
