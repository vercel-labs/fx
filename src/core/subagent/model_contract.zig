const std = @import("std");
const domain = @import("domain.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

const max_error_code_bytes: usize = 64;

pub const Action = enum { run, message };

pub const RunInput = struct {
    task: []const u8,
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    fast: ?bool = null,
};
pub const MessageInput = struct {
    agent: []const u8,
    instructions: ?[]const u8 = null,
    message: []const u8,
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    fast: ?bool = null,
};
pub const RequestInput = union(Action) {
    run: RunInput,
    message: MessageInput,
};

/// Creation-time routing overrides carried by a request. All default to the
/// parent's values; overrides apply only when a child session is created.
pub const Override = struct {
    model: ?[]const u8 = null,
    effort: ?types.ReasoningEffort = null,
    fast: ?bool = null,

    pub fn present(self: Override) bool {
        return self.model != null or self.effort != null or self.fast != null;
    }
};

pub const Request = union(Action) {
    run: struct {
        task: []u8,
        model: ?[]u8 = null,
        effort: ?types.ReasoningEffort = null,
        fast: ?bool = null,
    },
    message: struct {
        agent: []u8,
        instructions: ?[]u8 = null,
        message: []u8,
        model: ?[]u8 = null,
        effort: ?types.ReasoningEffort = null,
        fast: ?bool = null,
    },
    pub fn deinit(self: *Request, alloc: Allocator) void {
        switch (self.*) {
            .run => |value| {
                alloc.free(value.task);
                if (value.model) |model| alloc.free(model);
            },
            .message => |value| {
                alloc.free(value.agent);
                if (value.instructions) |instructions| alloc.free(instructions);
                alloc.free(value.message);
                if (value.model) |model| alloc.free(model);
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

    /// Borrows from the request; the request must outlive the returned value.
    pub fn override(self: Request) Override {
        return switch (self) {
            .run => |value| .{ .model = value.model, .effort = value.effort, .fast = value.fast },
            .message => |value| .{ .model = value.model, .effort = value.effort, .fast = value.fast },
        };
    }
};

pub const ValidationError = error{
    OutOfMemory,
    InvalidTask,
    InvalidAgent,
    InvalidInstructions,
    InvalidMessage,
    InvalidModel,
    InvalidEffort,
};

pub fn validateRequest(
    alloc: Allocator,
    input: RequestInput,
) ValidationError!Request {
    return switch (input) {
        .run => |value| blk: {
            try validateText(value.task, domain.max_prompt_bytes, error.InvalidTask);
            const effort = try validateOverrideText(value.model, value.effort);
            const task = try alloc.dupe(u8, value.task);
            errdefer alloc.free(task);
            break :blk .{ .run = .{
                .task = task,
                .model = try dupeOptional(alloc, value.model),
                .effort = effort,
                .fast = value.fast,
            } };
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
            const effort = try validateOverrideText(value.model, value.effort);
            const agent = try alloc.dupe(u8, value.agent);
            errdefer alloc.free(agent);
            const instructions = if (value.instructions) |instructions|
                try alloc.dupe(u8, instructions)
            else
                null;
            errdefer if (instructions) |owned| alloc.free(owned);
            const message = try alloc.dupe(u8, value.message);
            errdefer alloc.free(message);
            break :blk .{ .message = .{
                .agent = agent,
                .instructions = instructions,
                .message = message,
                .model = try dupeOptional(alloc, value.model),
                .effort = effort,
                .fast = value.fast,
            } };
        },
    };
}

/// Validates override text without allocating. Returns the parsed effort.
fn validateOverrideText(
    model: ?[]const u8,
    effort: ?[]const u8,
) ValidationError!?types.ReasoningEffort {
    if (model) |raw| try validateText(raw, domain.max_model_bytes, error.InvalidModel);
    if (effort) |raw| {
        return types.ReasoningEffort.parse(raw) orelse error.InvalidEffort;
    }
    return null;
}

/// Returns an owned copy the caller frees, or null. Never fails on null.
fn dupeOptional(alloc: Allocator, value: ?[]const u8) ValidationError!?[]u8 {
    return if (value) |raw| try alloc.dupe(u8, raw) else null;
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
pub const Phase = @import("child_state.zig").Phase;
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
    steer_persistent,
    reject: RejectCode,
};

pub fn plan(request: Request, snapshot: ?Snapshot) Plan {
    return switch (request) {
        .run => .create_one_off,
        .message => if (snapshot) |child| switch (child.kind) {
            .one_off => .{ .reject = .child_not_persistent },
            .persistent => switch (child.phase) {
                .idle, .interrupted => .continue_persistent,
                .running, .awaiting_approval => if (request.message.instructions != null)
                    .{ .reject = .child_busy }
                else
                    .steer_persistent,
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
    // Overrides extend the identity only when present so that override-less
    // requests keep their pre-override fingerprints in persisted registries.
    // The leading NUL is unambiguous: validated request text never contains
    // NUL, so the override section cannot be confused with task or message
    // content.
    const override = request.override();
    if (override.present()) {
        hash.update("\x00\x01");
        if (override.model) |model| {
            hash.update("\x01");
            hash.update(model);
        } else {
            hash.update("\x00");
        }
        hash.update("\x00");
        if (override.effort) |effort| {
            hash.update("\x01");
            hash.update(effort.label());
        } else {
            hash.update("\x00");
        }
        // Preserve fingerprints produced before Fast overrides existed when
        // no Fast preference is supplied.
        if (override.fast) |fast| {
            hash.update("\x00\x01");
            hash.update(if (fast) "\x01" else "\x00");
        }
    }
    return hash.finalResult();
}

pub const steering_pending_result = "The subagent is still running. Handle the user's steering now. Its result will arrive automatically; do not delegate again to poll for it.";

pub const Result = struct {
    ok: bool,
    pending: bool = false,
    result: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
    delivery: ?types.SteeringDelivery = null,
};

pub fn feedbackResult(delivery: types.SteeringDelivery) Result {
    return .{
        .ok = delivery != .not_applied,
        .delivery = delivery,
        .result = switch (delivery) {
            .queued => "Feedback queued for the running child. Its result will arrive automatically.",
            .applied => "Feedback consumed at the child's safe boundary. This is not a task-completion result.",
            .not_applied => "Feedback was not applied before the child stopped.",
        },
        .error_code = if (delivery == .not_applied) "feedback_not_applied" else null,
    };
}

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
    if (result.pending) try out.writer.writeAll(",\"pending\":true");
    if (result.delivery) |delivery| try out.writer.print(",\"delivery\":\"{s}\"", .{@tagName(delivery)});
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

test "creation overrides validate and participate in operation identity" {
    const alloc = std.testing.allocator;
    var plain = try validateRequest(alloc, .{ .run = .{ .task = "review this" } });
    defer plain.deinit(alloc);
    var routed = try validateRequest(alloc, .{ .run = .{
        .task = "review this",
        .model = "gpt-5.6-sol-fast",
        .effort = "medium",
    } });
    defer routed.deinit(alloc);
    try std.testing.expectEqualStrings("gpt-5.6-sol-fast", routed.run.model.?);
    try std.testing.expectEqualStrings("medium", routed.run.effort.?.label());
    try std.testing.expect(routed.run.fast == null);
    try std.testing.expect(plain.override().present() == false);
    try std.testing.expect(routed.override().present());
    // Override-less requests keep their pre-override fingerprint.
    const plain_digest = requestFingerprint(plain);
    const expected_plain = comptime blk: {
        @setEvalBranchQuota(100_000);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("fx.subagent.request.v1\x00");
        hash.update("run");
        hash.update("\x00");
        hash.update("review this");
        break :blk hash.finalResult();
    };
    try std.testing.expectEqual(expected_plain, plain_digest);
    const routed_digest = requestFingerprint(routed);
    try std.testing.expect(!std.mem.eql(u8, &plain_digest, &routed_digest));
    const expected_routed = comptime blk: {
        @setEvalBranchQuota(100_000);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("fx.subagent.request.v1\x00");
        hash.update("run");
        hash.update("\x00");
        hash.update("review this");
        hash.update("\x00\x01\x01");
        hash.update("gpt-5.6-sol-fast");
        hash.update("\x00\x01");
        hash.update("medium");
        break :blk hash.finalResult();
    };
    try std.testing.expectEqual(expected_routed, routed_digest);

    var accelerated = try validateRequest(alloc, .{ .run = .{
        .task = "review this",
        .fast = true,
    } });
    defer accelerated.deinit(alloc);
    try std.testing.expectEqual(true, accelerated.run.fast.?);
    const accelerated_digest = requestFingerprint(accelerated);
    try std.testing.expect(!std.mem.eql(u8, &plain_digest, &accelerated_digest));

    var normal = try validateRequest(alloc, .{ .run = .{
        .task = "review this",
        .fast = false,
    } });
    defer normal.deinit(alloc);
    try std.testing.expect(normal.override().present());
    const normal_digest = requestFingerprint(normal);
    try std.testing.expect(!std.mem.eql(u8, &plain_digest, &normal_digest));
    try std.testing.expect(!std.mem.eql(u8, &accelerated_digest, &normal_digest));

    var rerouted = try validateRequest(alloc, .{ .message = .{
        .agent = "reviewer",
        .message = "review this",
        .effort = "high",
    } });
    defer rerouted.deinit(alloc);
    try std.testing.expect(rerouted.message.model == null);
    try std.testing.expectEqualStrings("high", rerouted.message.effort.?.label());

    try std.testing.expectError(
        error.InvalidModel,
        validateRequest(alloc, .{ .run = .{ .task = "t", .model = "" } }),
    );
    try std.testing.expectError(
        error.InvalidEffort,
        validateRequest(alloc, .{ .run = .{ .task = "t", .effort = "not an effort!" } }),
    );
}

test "persistent planning derives continuation steering and busy overlay changes" {
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
    try std.testing.expect(busy == .steer_persistent);
    message.message.instructions = try alloc.dupe(u8, "new overlay");
    try std.testing.expectEqual(RejectCode.child_busy, plan(message, .{ .kind = .persistent, .phase = .running }).reject);
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
