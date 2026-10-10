//! JSONL trace of core steps (docs/approach.md §6, format version 1).
//!
//! The I/O layer writes one line per `step` call when tracing is on. The Bun
//! bridge turns a trace into a TLA+ observation and asks TLC whether it is a
//! behavior of the machine's model. `data` carries only model projections
//! (ids, versions, flags, counters), never tokens or user content.

const std = @import("std");

pub const format_version = 1;

/// Whether trace code is compiled in. Release fx leaves it out:
/// a program has it only by declaring `pub const mcpv2_trace = true;` in its
/// root file, and tests always have it.
pub const enabled = @import("builtin").is_test or
    (@hasDecl(@import("root"), "mcpv2_trace") and @import("root").mcpv2_trace);

/// `writer` when trace code is compiled in, else a null known at compile
/// time, so the mapping behind `if (trace.on(w)) |t|` isn't compiled either.
pub inline fn on(writer: ?*Writer) ?*Writer {
    if (!enabled) return null;
    return writer;
}

pub const Value = union(enum) {
    int: i64,
    boolean: bool,
    string: []const u8,
};

pub const Field = struct {
    name: []const u8,
    value: Value,
};

pub const Step = struct {
    machine: []const u8,
    instance: []const u8,
    event: []const u8,
    from: []const u8,
    to: []const u8,
    effects: []const []const u8 = &.{},
    data: []const Field = &.{},
};

/// Writes trace lines to `out`. Sequence numbers start at 1 and are contiguous
/// for the life of the writer. Does not flush; the owner of `out` does.
pub const Writer = struct {
    out: *std.Io.Writer,
    next_seq: u64 = 1,
    /// A child's records go to its parent, each instance after `prefix` and
    /// a dot (the engine: one child per server, one trace).
    parent: ?*Writer = null,
    prefix: []const u8 = "",

    pub fn init(out: *std.Io.Writer) Writer {
        return .{ .out = out };
    }

    pub fn child(parent: *Writer, prefix: []const u8) Writer {
        return .{ .out = parent.out, .parent = parent, .prefix = prefix };
    }

    pub fn write(self: *Writer, step: Step) std.Io.Writer.Error!void {
        if (self.parent) |parent| {
            var buffer: [256]u8 = undefined;
            var named = step;
            named.instance = std.fmt.bufPrint(&buffer, "{s}.{s}", .{ self.prefix, step.instance }) catch return error.WriteFailed;
            return parent.write(named);
        }
        const w = self.out;
        try w.print("{{\"v\":{d},\"seq\":{d},\"machine\":", .{ format_version, self.next_seq });
        try writeString(w, step.machine);
        try w.writeAll(",\"inst\":");
        try writeString(w, step.instance);
        try w.writeAll(",\"event\":");
        try writeString(w, step.event);
        try w.writeAll(",\"from\":");
        try writeString(w, step.from);
        try w.writeAll(",\"to\":");
        try writeString(w, step.to);
        try w.writeAll(",\"effects\":[");
        for (step.effects, 0..) |effect, index| {
            if (index > 0) try w.writeByte(',');
            try writeString(w, effect);
        }
        try w.writeAll("],\"data\":{");
        for (step.data, 0..) |field, index| {
            if (index > 0) try w.writeByte(',');
            try writeString(w, field.name);
            try w.writeByte(':');
            switch (field.value) {
                .int => |n| try w.print("{d}", .{n}),
                .boolean => |b| try w.writeAll(if (b) "true" else "false"),
                .string => |s| try writeString(w, s),
            }
        }
        try w.writeAll("}}\n");
        self.next_seq += 1;
    }
};

fn writeString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try std.json.Stringify.value(s, .{}, w);
}

test "writes one JSON line per step with contiguous sequence numbers" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var trace: Writer = .init(&buffer.writer);

    try trace.write(.{
        .machine = "request",
        .instance = "linear#7",
        .event = "response_received",
        .from = "sent",
        .to = "done",
        .effects = &.{"deliver"},
        .data = &.{
            .{ .name = "id", .value = .{ .int = 7 } },
            .{ .name = "late", .value = .{ .boolean = false } },
            .{ .name = "outcome", .value = .{ .string = "result" } },
        },
    });
    try trace.write(.{ .machine = "request", .instance = "linear#8", .event = "send", .from = "idle", .to = "sent" });

    try std.testing.expectEqualStrings(
        "{\"v\":1,\"seq\":1,\"machine\":\"request\",\"inst\":\"linear#7\",\"event\":\"response_received\"," ++
            "\"from\":\"sent\",\"to\":\"done\",\"effects\":[\"deliver\"],\"data\":{\"id\":7,\"late\":false,\"outcome\":\"result\"}}\n" ++
            "{\"v\":1,\"seq\":2,\"machine\":\"request\",\"inst\":\"linear#8\",\"event\":\"send\"," ++
            "\"from\":\"idle\",\"to\":\"sent\",\"effects\":[],\"data\":{}}\n",
        buffer.written(),
    );
}

test "a child writes through its parent, its instances after its prefix" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var trace: Writer = .init(&buffer.writer);
    var linear = trace.child("linear");
    try linear.write(.{ .machine = "m", .instance = "x1", .event = "e", .from = "", .to = "" });
    try trace.write(.{ .machine = "m", .instance = "linear", .event = "e", .from = "", .to = "" });
    try std.testing.expect(std.mem.find(u8, buffer.written(), "\"seq\":1,\"machine\":\"m\",\"inst\":\"linear.x1\"") != null);
    try std.testing.expect(std.mem.find(u8, buffer.written(), "\"seq\":2,\"machine\":\"m\",\"inst\":\"linear\"") != null);
}

test "escapes strings so a record never spans two lines" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var trace: Writer = .init(&buffer.writer);

    try trace.write(.{
        .machine = "m",
        .instance = "line\nbreak \"quoted\" back\\slash",
        .event = "e",
        .from = "a",
        .to = "b",
    });

    const written = buffer.written();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "\n"));
    try std.testing.expect(std.mem.find(u8, written, "\"line\\nbreak \\\"quoted\\\" back\\\\slash\"") != null);
}
