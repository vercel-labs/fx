//! JSONL trace of core steps, format version 1.
//!
//! A core writes one line per step when it is given a writer, so a model
//! checker can confirm the run is a behavior of the machine's model. `data`
//! carries only model projections (call
//! sequence numbers, credential ordinals, counts, flags), never tokens,
//! prompts, model output, generation ids, or credentials.

const std = @import("std");

pub const format_version = 1;

/// Whether trace code is compiled in. Release fx leaves it out: a program has
/// it only by declaring `pub const usage_trace = true;` in its root file, and
/// tests always have it.
pub const enabled = @import("builtin").is_test or
    (@hasDecl(@import("root"), "usage_trace") and @import("root").usage_trace);

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

/// Writes trace lines to `out`, which it borrows. Sequence numbers start at 1
/// and are contiguous for the life of the writer. Does not flush; the owner
/// of `out` does.
pub const Writer = struct {
    out: *std.Io.Writer,
    next_seq: u64 = 1,

    pub fn init(out: *std.Io.Writer) Writer {
        return .{ .out = out };
    }

    pub fn write(self: *Writer, step: Step) std.Io.Writer.Error!void {
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
        .machine = "ledger",
        .instance = "session",
        .event = "finish_lookup",
        .from = "active",
        .to = "lookup",
        .effects = &.{ "persist_checkpoint", "start_lookup" },
        .data = &.{
            .{ .name = "call", .value = .{ .int = 7 } },
            .{ .name = "incident", .value = .{ .boolean = false } },
            .{ .name = "note", .value = .{ .string = "x" } },
        },
    });
    try trace.write(.{ .machine = "ledger", .instance = "session", .event = "begin", .from = "idle", .to = "active" });

    try std.testing.expectEqualStrings(
        "{\"v\":1,\"seq\":1,\"machine\":\"ledger\",\"inst\":\"session\",\"event\":\"finish_lookup\"," ++
            "\"from\":\"active\",\"to\":\"lookup\",\"effects\":[\"persist_checkpoint\",\"start_lookup\"]," ++
            "\"data\":{\"call\":7,\"incident\":false,\"note\":\"x\"}}\n" ++
            "{\"v\":1,\"seq\":2,\"machine\":\"ledger\",\"inst\":\"session\",\"event\":\"begin\"," ++
            "\"from\":\"idle\",\"to\":\"active\",\"effects\":[],\"data\":{}}\n",
        buffer.written(),
    );
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

test "a failing writer reports the error and keeps the sequence number" {
    var storage: [8]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&storage);
    var trace: Writer = .init(&fixed);
    try std.testing.expectError(error.WriteFailed, trace.write(.{ .machine = "m", .instance = "i", .event = "e", .from = "a", .to = "b" }));
    try std.testing.expectEqual(@as(u64, 1), trace.next_seq);
}
