//! Parsing of the Vercel answers the built-in runner reads (spec R1.8): the one
//! place that turns outside JSON into a value, checks its shape, and bounds its
//! text. `api.zig` and `sandbox.zig` import it; code outside this folder does not.

const std = @import("std");
const transport = @import("transport.zig");

const Allocator = std.mem.Allocator;

pub const ParseError = Allocator.Error || error{BadReply};

pub fn parseRoot(arena: Allocator, bytes: []const u8) ParseError!std.json.Value {
    if (bytes.len > transport.max_response_bytes) return error.BadReply;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadReply,
    };
}

pub fn objectOf(value: std.json.Value) ParseError!std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.BadReply,
    };
}

/// A required string: present, a JSON string, non-empty, and at most `max` bytes.
/// The result is copied out of the reply, so it outlives the reply's bytes.
pub fn requiredText(arena: Allocator, value: ?std.json.Value, max: usize) ParseError![]const u8 {
    var ignored: Problem = .{};
    return textField(arena, value, "", max, &ignored);
}

/// The first field that made a reply unreadable, and what was wrong with it (N1). `field` is a path
/// in the reply, such as `session.startedAt`: fixed text in our code, never a value from the reply
/// (R4.8). A parser records its problem here before it returns BadReply.
pub const Problem = struct {
    field: []const u8 = "",
    reason: Reason = .shape,

    pub const Reason = enum { not_json, not_object, missing, not_integer, not_text, empty, too_long, out_of_range, shape };

    /// Records the failure, and returns the error a parser returns.
    pub fn fail(self: *Problem, field: []const u8, reason: Reason) ParseError {
        self.* = .{ .field = field, .reason = reason };
        return error.BadReply;
    }

    /// The reason text, such as `session.startedAt is missing`. The caller adds the step.
    pub fn describe(self: Problem, alloc: Allocator) Allocator.Error![]u8 {
        return switch (self.reason) {
            .not_json => alloc.dupe(u8, "the body is not JSON"),
            .not_object => alloc.print("{s} is not an object", .{self.field}),
            .missing => alloc.print("{s} is missing", .{self.field}),
            .not_integer => alloc.print("{s} is not an integer", .{self.field}),
            .not_text => alloc.print("{s} is not a string", .{self.field}),
            .empty => alloc.print("{s} is empty", .{self.field}),
            .too_long => alloc.print("{s} is too long", .{self.field}),
            .out_of_range => alloc.print("{s} is out of range", .{self.field}),
            .shape => alloc.dupe(u8, "the body does not have the expected shape"),
        };
    }
};

/// The root of a reply, which must be a JSON object. A body that is not one records why.
pub fn rootOf(arena: Allocator, bytes: []const u8, problem: *Problem) ParseError!std.json.ObjectMap {
    const root = parseRoot(arena, bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadReply => problem.fail("the body", .not_json),
    };
    return switch (root) {
        .object => |object| object,
        else => problem.fail("the body", .not_object),
    };
}

/// A required object field, which must be a JSON object.
pub fn objectField(value: ?std.json.Value, field: []const u8, problem: *Problem) ParseError!std.json.ObjectMap {
    const found = value orelse return problem.fail(field, .missing);
    return switch (found) {
        .object => |object| object,
        else => problem.fail(field, .not_object),
    };
}

/// A required integer field.
pub fn integerField(value: ?std.json.Value, field: []const u8, problem: *Problem) ParseError!i64 {
    const found = value orelse return problem.fail(field, .missing);
    return switch (found) {
        .integer => |integer| integer,
        else => problem.fail(field, .not_integer),
    };
}

/// A required string field: present, a JSON string, non-empty, and at most `max` bytes. The result
/// is copied out of the reply, so it outlives the reply's bytes.
pub fn textField(arena: Allocator, value: ?std.json.Value, field: []const u8, max: usize, problem: *Problem) ParseError![]const u8 {
    const found = value orelse return problem.fail(field, .missing);
    const text = switch (found) {
        .string => |string| string,
        else => return problem.fail(field, .not_text),
    };
    if (text.len == 0) return problem.fail(field, .empty);
    if (text.len > max) return problem.fail(field, .too_long);
    return arena.dupe(u8, text);
}
