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
//!
//! `wire_lab fields <input-file> <trace-path>` reads one object field by name
//! with the real `objectFields`, for the FieldRead model. Each input line is
//!   {"object":"{...}","name":"isError","plain":1,"escaped":0,"other":0,"flag":true}
//! where `plain`, `escaped` and `other` count the members the scenario wrote
//! (see FieldRead.tla) and `flag` is the field's boolean value. It prints
//!   {"found":"<raw value>"}   {"found":null}   {"error":"DuplicateField"}
//! and writes one FieldRead trace record per line the engine read.

const std = @import("std");
const mcp = @import("mcp");

/// Trace code is compiled in.
pub const mcpv2_trace = true;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 4 and std.mem.eql(u8, args[1], "fields")) return fields(io, arena, args[2], args[3]);
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

const FieldCase = struct { object: []const u8, name: []const u8, plain: i64, escaped: i64, other: i64, flag: bool };

fn fields(io: std.Io, arena: std.mem.Allocator, input_path: []const u8, trace_path: []const u8) !void {
    const input = try std.Io.Dir.cwd().readFileAlloc(io, input_path, arena, .unlimited);

    var trace_file = try std.Io.Dir.cwd().createFile(io, trace_path, .{});
    defer trace_file.close(io);
    var trace_buffer: [4096]u8 = undefined;
    var trace_writer = trace_file.writer(io, &trace_buffer);
    var trace: mcp.trace.Writer = .init(&trace_writer.interface);

    var buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const c = try std.json.parseFromSliceLeaky(FieldCase, arena, line, .{});
        var json: std.json.Stringify = .{ .writer = out };
        try json.beginObject();
        var found: [1]?[]const u8 = undefined;
        const names = [_][]const u8{c.name};
        var engine: i64 = 0;
        if (mcp.wire.objectFields(c.object, &names, &found)) |_| {
            try json.objectField("found");
            if (found[0]) |raw| {
                engine = 1;
                try json.write(raw);
            } else try json.write(null);
        } else |err| {
            try json.objectField("error");
            try json.write(@errorName(err));
            if (err == error.DuplicateField) engine = 2 else {
                try json.endObject();
                try out.writeByte('\n');
                continue;
            }
        }
        try json.endObject();
        try out.writeByte('\n');
        try trace.write(.{
            .machine = "FieldRead",
            .instance = "wire",
            .event = "read",
            .from = "idle",
            .to = "idle",
            .data = &.{
                .{ .name = "plain", .value = .{ .int = c.plain } },
                .{ .name = "escaped", .value = .{ .int = c.escaped } },
                .{ .name = "other", .value = .{ .int = c.other } },
                .{ .name = "flag", .value = .{ .boolean = c.flag } },
                .{ .name = "engine", .value = .{ .int = engine } },
            },
        });
    }
    try out.flush();
    try trace_writer.interface.flush();
}
