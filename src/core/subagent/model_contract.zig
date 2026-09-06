const std = @import("std");
const domain = @import("domain.zig");

const Allocator = std.mem.Allocator;

const max_error_code_bytes: usize = 64;

pub const Action = enum { run, message };

pub const RunInput = struct { task: []const u8 };
pub const MessageInput = struct {
    agent: []const u8,
    instructions: ?[]const u8 = null,
    message: []const u8,
};
pub const RequestInput = union(Action) {
    run: RunInput,
    message: MessageInput,
};

pub const Request = union(Action) {
    run: struct { task: []u8 },
    message: struct {
        agent: []u8,
        instructions: ?[]u8 = null,
        message: []u8,
    },
    pub fn deinit(self: *Request, alloc: Allocator) void {
        switch (self.*) {
            .run => |value| alloc.free(value.task),
            .message => |value| {
                alloc.free(value.agent);
                if (value.instructions) |instructions| alloc.free(instructions);
                alloc.free(value.message);
            },
        }
        self.* = undefined;
    }

    pub fn action(self: Request) Action {
        return std.meta.activeTag(self);
    }

    pub fn agentName(self: Request) ?[]const u8 {
        return switch (self) {
            .message => |value| value.agent,
            .run => null,
        };
    }
};

pub const ValidationError = error{
    OutOfMemory,
    InvalidTask,
    InvalidAgent,
    InvalidInstructions,
    InvalidMessage,
};

pub fn validateRequest(
    alloc: Allocator,
    input: RequestInput,
) ValidationError!Request {
    return switch (input) {
        .run => |value| blk: {
            try validateText(value.task, domain.max_prompt_bytes, error.InvalidTask);
            break :blk .{ .run = .{ .task = try alloc.dupe(u8, value.task) } };
        },
        .message => |value| blk: {
            if (!domain.validAgentName(value.agent)) return error.InvalidAgent;
            if (value.instructions) |instructions| {
                if (instructions.len == 0 or
                    !domain.validInstructions(instructions))
                {
                    return error.InvalidInstructions;
                }
            }
            try validateText(value.message, domain.max_message_bytes, error.InvalidMessage);
            const agent = try alloc.dupe(u8, value.agent);
            errdefer alloc.free(agent);
            const instructions = if (value.instructions) |instructions|
                try alloc.dupe(u8, instructions)
            else
                null;
            errdefer if (instructions) |owned| alloc.free(owned);
            break :blk .{ .message = .{
                .agent = agent,
                .instructions = instructions,
                .message = try alloc.dupe(u8, value.message),
            } };
        },
    };
}

fn validateText(
    value: []const u8,
    max_bytes: usize,
    invalid: ValidationError,
) ValidationError!void {
    if (value.len == 0 or value.len > max_bytes or
        !std.unicode.utf8ValidateSlice(value) or
        std.mem.findScalar(u8, value, 0) != null)
    {
        return invalid;
    }
}

pub const Kind = enum { one_off, persistent };
pub const Phase = enum { idle, running, awaiting_approval, interrupted, finished };
pub const Snapshot = struct {
    kind: Kind,
    phase: Phase,
};

pub const RejectCode = enum {
    child_unavailable,
    child_busy,
    child_not_persistent,
};

pub const Plan = union(enum) {
    create_one_off,
    create_persistent,
    continue_persistent,
    reject: RejectCode,
};

pub fn plan(request: Request, snapshot: ?Snapshot) Plan {
    return switch (request) {
        .run => .create_one_off,
        .message => if (snapshot) |child| switch (child.kind) {
            .one_off => .{ .reject = .child_not_persistent },
            .persistent => switch (child.phase) {
                .idle, .interrupted => .continue_persistent,
                .running, .awaiting_approval => .{ .reject = .child_busy },
                .finished => .{ .reject = .child_unavailable },
            },
        } else .create_persistent,
    };
}

pub fn requestFingerprint(request: Request) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.request.v1\x00");
    hash.update(@tagName(request.action()));
    hash.update("\x00");
    switch (request) {
        .run => |value| hash.update(value.task),
        .message => |value| {
            hash.update(value.agent);
            hash.update("\x00");
            if (value.instructions) |instructions| {
                hash.update("\x01");
                hash.update(instructions);
            } else {
                hash.update("\x00");
            }
            hash.update("\x00");
            hash.update(value.message);
        },
    }
    return hash.finalResult();
}

pub const Result = struct {
    ok: bool,
    result: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
};

pub fn encodeResultAlloc(alloc: Allocator, result: Result) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{{\"ok\":{s},\"result\":", .{
        if (result.ok) "true" else "false",
    });
    try writeOptionalString(&out.writer, result.result);
    try out.writer.writeAll(",\"error_code\":");
    try writeOptionalString(
        &out.writer,
        if (result.error_code) |code| code[0..@min(code.len, max_error_code_bytes)] else null,
    );
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try std.json.Stringify.value(text, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

test "minimal request validation owns one-off and persistent intent" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(Action).@"enum".fields.len);
    try std.testing.expectEqual(@as(usize, 4), @typeInfo(Plan).@"union".fields.len);
    var run = try validateRequest(alloc, .{ .run = .{ .task = "review this" } });
    defer run.deinit(alloc);
    try std.testing.expectEqual(Action.run, run.action());
    try std.testing.expectEqual(Plan.create_one_off, plan(run, null));

    var message = try validateRequest(alloc, .{ .message = .{
        .agent = "reviewer",
        .instructions = "Review strictly.",
        .message = "review this",
    } });
    defer message.deinit(alloc);
    try std.testing.expectEqual(Action.message, message.action());
    try std.testing.expectEqual(Plan.create_persistent, plan(message, null));
    try std.testing.expectEqualStrings(
        "Review strictly.",
        message.message.instructions.?,
    );
    try std.testing.expectError(
        error.InvalidInstructions,
        validateRequest(alloc, .{ .message = .{
            .agent = "reviewer",
            .instructions = "",
            .message = "review this",
        } }),
    );
}

test "persistent instruction updates participate in operation identity" {
    const alloc = std.testing.allocator;
    var inherited = try validateRequest(alloc, .{ .message = .{
        .agent = "reviewer",
        .message = "review this",
    } });
    defer inherited.deinit(alloc);
    var strict = try validateRequest(alloc, .{ .message = .{
        .agent = "reviewer",
        .instructions = "Review strictly.",
        .message = "review this",
    } });
    defer strict.deinit(alloc);
    var security = try validateRequest(alloc, .{ .message = .{
        .agent = "reviewer",
        .instructions = "Review security.",
        .message = "review this",
    } });
    defer security.deinit(alloc);
    const inherited_fingerprint = requestFingerprint(inherited);
    const strict_fingerprint = requestFingerprint(strict);
    const security_fingerprint = requestFingerprint(security);
    try std.testing.expect(!std.mem.eql(
        u8,
        &inherited_fingerprint,
        &strict_fingerprint,
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        &strict_fingerprint,
        &security_fingerprint,
    ));
}

test "persistent planning derives continue and busy" {
    const alloc = std.testing.allocator;
    var message = try validateRequest(alloc, .{ .message = .{
        .agent = "reviewer",
        .message = "continue",
    } });
    defer message.deinit(alloc);
    try std.testing.expectEqual(
        Plan.continue_persistent,
        plan(message, .{ .kind = .persistent, .phase = .idle }),
    );
    const busy = plan(message, .{ .kind = .persistent, .phase = .running });
    try std.testing.expectEqual(RejectCode.child_busy, busy.reject);
}

test "terminal result omits scheduler identities and phases" {
    const alloc = std.testing.allocator;
    const encoded = try encodeResultAlloc(alloc, .{
        .ok = true,
        .result = "review complete",
    });
    defer alloc.free(encoded);
    try std.testing.expect(std.mem.find(u8, encoded, "\"result\":\"review complete\"") != null);
    try std.testing.expect(std.mem.find(u8, encoded, "retryable") == null);
    try std.testing.expect(std.mem.find(u8, encoded, "requested") == null);
    try std.testing.expect(std.mem.find(u8, encoded, "cursor") == null);
    try std.testing.expect(std.mem.find(u8, encoded, "operation_id") == null);
    try std.testing.expect(std.mem.find(u8, encoded, "child_id") == null);
    try std.testing.expect(std.mem.find(u8, encoded, "status") == null);
}
