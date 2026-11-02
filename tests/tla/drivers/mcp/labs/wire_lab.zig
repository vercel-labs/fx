//! U01 lab: decodes each line of an input file with the real wire decoder and
//! prints what it found, one JSON line per input line, for the u01 Bun
//! scenarios. Empty lines are skipped. Dev only; never moves into fx.
//!
//! Output per line, by message kind:
//!   {"kind":"response","id":7,"result":"complete"}    or "code":-32602 for errors
//!   {"kind":"notification","method":"notifications/progress"}
//!   {"kind":"request","id":"\"srv-1\"","method":"ping"} (id is the raw JSON text)
//!   {"error":"InvalidJson"}
//!
//! Usage: wire_lab <input-file>. Exit codes: 0 done, 2 usage.

const std = @import("std");
const mcp = @import("mcp");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: wire_lab <input-file>\n", .{});
        std.process.exit(2);
    }
    const input = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .unlimited);

    var buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var json: std.json.Stringify = .{ .writer = out };
        try json.beginObject();
        if (mcp.wire.decode(line)) |message| switch (message) {
            .response => |r| {
                try json.objectField("kind");
                try json.write("response");
                try json.objectField("id");
                try json.write(r.id);
                switch (r.body) {
                    .result => |result| {
                        try json.objectField("result");
                        try json.write(@tagName(result.kind));
                    },
                    .failure => |failure| {
                        try json.objectField("code");
                        try json.write(failure.code);
                    },
                }
            },
            .notification => |n| {
                try json.objectField("kind");
                try json.write("notification");
                try json.objectField("method");
                try json.write(n.method);
            },
            .request => |q| {
                try json.objectField("kind");
                try json.write("request");
                try json.objectField("id");
                try json.write(q.id);
                try json.objectField("method");
                try json.write(q.method);
            },
        } else |err| {
            try json.objectField("error");
            try json.write(@errorName(err));
        }
        try json.endObject();
        try out.writeByte('\n');
    }
    try out.flush();
}
