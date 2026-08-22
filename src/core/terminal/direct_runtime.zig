const std = @import("std");
const client = @import("client.zig");
const contracts = @import("contracts.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const operation = @import("operation.zig");
const shell_resolver = @import("shell_resolver.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const max_pending = 32;
pub const start_wait_ceiling_ms: u64 = 20_000;

pub const OpenIntentAdmission = enum {
    accepted,
    occupied,
};

pub const DeinitDisposition = enum {
    settled,
    abnormal,
};

pub const Admission = struct {
    alloc: Allocator,
    profile_user: []const u8,
    durable_session_id: []const u8,
    workspace_root: []const u8,
    command: []const u8,
};

const Pending = struct {
    correlation_id: contracts.CorrelationId,
    command: []u8,
    starting_pending: bool = true,
    completion: ?client.Completion = null,

    fn deinit(self: *Pending, alloc: Allocator) void {
        if (self.completion) |*completion| completion.deinit();
        alloc.free(self.command);
        self.* = undefined;
    }
};

pub const NoticePhase = enum { starting, final };

pub const Notice = union(enum) {
    starting: struct {
        correlation_id: contracts.CorrelationId,
        command: []const u8,
    },
    running: struct {
        correlation_id: contracts.CorrelationId,
        command: []const u8,
        session_id: []const u8,
    },
    failed: struct {
        correlation_id: contracts.CorrelationId,
        command: []const u8,
        code: contracts.StructuredErrorCode,
    },

    pub fn correlationId(self: Notice) contracts.CorrelationId {
        return switch (self) {
            inline else => |value| value.correlation_id,
        };
    }

    pub fn phase(self: Notice) NoticePhase {
        return switch (self) {
            .starting => .starting,
            .running, .failed => .final,
        };
    }
};

pub const Runtime = struct {
    pending: [max_pending]?Pending = @splat(null),
    len: usize = 0,
    open_intent: ?[]u8 = null,

    pub fn deinitSettled(
        self: *Runtime,
        alloc: Allocator,
    ) DeinitDisposition {
        if (self.len != 0) {
            self.deinitAbnormal(alloc, "graceful_exit_invariant");
            return .abnormal;
        }
        self.deinitEmpty(alloc);
        return .settled;
    }

    pub fn deinitAbnormal(
        self: *Runtime,
        alloc: Allocator,
        reason: []const u8,
    ) void {
        for (self.pending[0..self.len]) |*entry| {
            if (entry.*) |*pending| {
                debug_trace.logf(
                    "terminal",
                    "direct pending dropped correlation={d} phase={s} reason={s}",
                    .{
                        pending.correlation_id.value,
                        pendingPhase(pending),
                        reason,
                    },
                );
                pending.deinit(alloc);
                entry.* = null;
            }
        }
        self.len = 0;
        self.deinitEmpty(alloc);
    }

    fn deinitEmpty(self: *Runtime, alloc: Allocator) void {
        if (self.open_intent) |session_id| alloc.free(session_id);
        self.* = .{};
    }

    pub fn requestOpen(
        self: *Runtime,
        alloc: Allocator,
        session_id: []const u8,
    ) Allocator.Error!OpenIntentAdmission {
        if (self.open_intent != null) return .occupied;
        const owned = try alloc.dupe(u8, session_id);
        self.open_intent = owned;
        return .accepted;
    }

    pub fn pendingOpenIntent(self: *const Runtime) ?[]const u8 {
        return self.open_intent;
    }

    pub fn takeOpenIntent(self: *Runtime) ?[]u8 {
        const session_id = self.open_intent orelse return null;
        self.open_intent = null;
        return session_id;
    }

    pub fn admit(
        self: *Runtime,
        terminal_client: *client.Runtime,
        input: Admission,
    ) !contracts.CorrelationId {
        if (self.len == self.pending.len) return error.QueueFull;
        const command = try input.alloc.dupe(u8, input.command);
        errdefer input.alloc.free(command);
        var persistence = try operation.prepareStartPersistence(input.alloc, .{
            .profile_user = input.profile_user,
            .durable_session_id = input.durable_session_id,
            .workspace_root = input.workspace_root,
            .cwd = input.workspace_root,
            .transport_role = .interactive,
            .backend = .native,
            .actor = .human,
            .controls = .full(),
            .lifetime = .session,
            .direct_human_model_read_only = true,
        });
        defer persistence.deinit();
        const request = contracts.ActionRequest{ .start = .{
            .cwd = input.workspace_root,
            .command = input.command,
            .shell = try shell_resolver.profileShell(input.alloc, null, .user),
            .backend = .native,
            .return_when = .started,
            .wait_ceiling_ms = start_wait_ceiling_ms,
            .persistence = persistence.view(),
        } };
        try operation.validate(request);
        const correlation_id = terminal_client.nextCorrelationId();
        try terminal_client.admit(input.alloc, correlation_id, request);
        self.pending[self.len] = .{
            .correlation_id = correlation_id,
            .command = command,
        };
        self.len += 1;
        return correlation_id;
    }

    pub fn nextNotice(
        self: *Runtime,
        terminal_client: *client.Runtime,
    ) ?Notice {
        for (self.pending[0..self.len]) |*entry| {
            if (entry.*) |*pending| {
                if (pending.starting_pending) return .{ .starting = .{
                    .correlation_id = pending.correlation_id,
                    .command = pending.command,
                } };
                if (pending.completion == null) {
                    pending.completion = terminal_client.takeCompletionFor(
                        pending.correlation_id,
                    ) orelse continue;
                }
                if (finalNotice(pending)) |notice| return notice;
            }
        }
        return null;
    }

    pub fn acknowledgeNotice(
        self: *Runtime,
        alloc: Allocator,
        correlation_id: contracts.CorrelationId,
        phase: NoticePhase,
    ) void {
        for (self.pending[0..self.len], 0..) |entry, index| {
            const pending = entry.?;
            if (pending.correlation_id.value != correlation_id.value) continue;
            switch (phase) {
                .starting => {
                    std.debug.assert(pending.starting_pending);
                    self.pending[index].?.starting_pending = false;
                },
                .final => {
                    std.debug.assert(!pending.starting_pending);
                    std.debug.assert(pending.completion != null);
                    var removed = self.removeAt(index);
                    removed.deinit(alloc);
                },
            }
            return;
        }
        unreachable;
    }

    pub fn hasAcceptedPending(self: *const Runtime) bool {
        return self.len != 0;
    }

    pub fn pendingCount(self: *const Runtime) usize {
        return self.len;
    }

    fn removeAt(self: *Runtime, index: usize) Pending {
        const result = self.pending[index].?;
        var current = index;
        while (current + 1 < self.len) : (current += 1) {
            self.pending[current] = self.pending[current + 1];
        }
        self.len -= 1;
        self.pending[self.len] = null;
        return result;
    }
};

fn finalNotice(pending: *const Pending) ?Notice {
    const completion = &pending.completion.?;
    if (completion.is_missing_capability(
        contracts.protocol_capability_complete_process_tree_signals,
    )) {
        return .{ .failed = .{
            .correlation_id = pending.correlation_id,
            .command = pending.command,
            .code = .unsupported_host,
        } };
    }
    if (completion.kind != .response) return null;
    if (completion.frame) |*frame| {
        switch (frame.message().payload) {
            .response => |response| switch (response) {
                .success => |success| switch (success) {
                    .start => |start| return .{ .running = .{
                        .correlation_id = pending.correlation_id,
                        .command = pending.command,
                        .session_id = start.session.session_id,
                    } },
                    else => {},
                },
                .failure => |failure| return .{ .failed = .{
                    .correlation_id = pending.correlation_id,
                    .command = pending.command,
                    .code = failure.code,
                } },
            },
            else => {},
        }
    }
    return null;
}

fn pendingPhase(pending: *const Pending) []const u8 {
    if (pending.starting_pending) return "starting_notice";
    if (pending.completion == null) return "awaiting_host_result";
    return if (finalNotice(pending) != null)
        "final_notice"
    else
        "indeterminate_completion";
}

test "terminal open intent is first wins and reports occupied without mutation" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer _ = runtime.deinitSettled(alloc);

    try std.testing.expectEqual(
        OpenIntentAdmission.accepted,
        try runtime.requestOpen(alloc, "terminal-a"),
    );
    try std.testing.expectEqualStrings("terminal-a", runtime.pendingOpenIntent().?);
    try std.testing.expectEqual(
        OpenIntentAdmission.occupied,
        try runtime.requestOpen(alloc, "terminal-b"),
    );
    try std.testing.expectEqualStrings("terminal-a", runtime.pendingOpenIntent().?);
    const taken = runtime.takeOpenIntent().?;
    defer alloc.free(taken);
    try std.testing.expectEqualStrings("terminal-a", taken);
    try std.testing.expect(runtime.pendingOpenIntent() == null);
}

test "terminal open intent allocation failure preserves exact ownership" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer _ = runtime.deinitSettled(alloc);
    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );

    try std.testing.expectError(
        error.OutOfMemory,
        runtime.requestOpen(failing.allocator(), "terminal-a"),
    );
    try std.testing.expect(runtime.pendingOpenIntent() == null);

    try std.testing.expectEqual(
        OpenIntentAdmission.accepted,
        try runtime.requestOpen(alloc, "terminal-a"),
    );
    const original = runtime.pendingOpenIntent().?;
    try std.testing.expectEqual(
        OpenIntentAdmission.occupied,
        try runtime.requestOpen(failing.allocator(), "terminal-b"),
    );
    try std.testing.expectEqual(original.ptr, runtime.pendingOpenIntent().?.ptr);
    try std.testing.expectEqualStrings("terminal-a", runtime.pendingOpenIntent().?);
}

test "direct lifecycle retains indeterminate completion without fabricating failure" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinitAbnormal(alloc, "test_cleanup");
    var terminal_client: client.Runtime = .{};
    defer terminal_client.deinit();

    runtime.pending[0] = .{
        .correlation_id = .{ .value = 7 },
        .command = try alloc.dupe(u8, "zig build test"),
    };
    runtime.len = 1;

    const first_start = runtime.nextNotice(&terminal_client).?;
    try std.testing.expectEqual(NoticePhase.starting, first_start.phase());
    try std.testing.expectEqual(NoticePhase.starting, runtime.nextNotice(&terminal_client).?.phase());
    runtime.acknowledgeNotice(alloc, first_start.correlationId(), first_start.phase());
    try std.testing.expect(runtime.nextNotice(&terminal_client) == null);

    runtime.pending[0].?.completion = .{
        .kind = .disconnected,
        .correlation_id = .{ .value = 7 },
    };
    try std.testing.expect(runtime.nextNotice(&terminal_client) == null);
    try std.testing.expect(runtime.hasAcceptedPending());
    try std.testing.expectEqual(
        client.CompletionKind.disconnected,
        runtime.pending[0].?.completion.?.kind,
    );
}

test "direct lifecycle finalizes complete signal capability misses" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinitAbnormal(alloc, "test_cleanup");
    var terminal_client: client.Runtime = .{};
    defer terminal_client.deinit();

    runtime.pending[0] = .{
        .correlation_id = .{ .value = 7 },
        .command = try alloc.dupe(u8, "zig build test"),
        .starting_pending = false,
        .completion = .{
            .kind = .unavailable,
            .correlation_id = .{ .value = 7 },
            .missing_capabilities = contracts.protocol_capability_complete_process_tree_signals,
        },
    };
    runtime.len = 1;

    const failed = runtime.nextNotice(&terminal_client) orelse
        return error.TestExpectedResult;
    switch (failed) {
        .failed => |notice| {
            try std.testing.expectEqual(
                contracts.StructuredErrorCode.unsupported_host,
                notice.code,
            );
            try std.testing.expectEqualStrings("zig build test", notice.command);
        },
        else => return error.TestUnexpectedResult,
    }
    runtime.acknowledgeNotice(
        alloc,
        failed.correlationId(),
        failed.phase(),
    );
    try std.testing.expectEqual(@as(usize, 0), runtime.pendingCount());

    runtime.pending[0] = .{
        .correlation_id = .{ .value = 8 },
        .command = try alloc.dupe(u8, "ordinary unavailable"),
        .starting_pending = false,
        .completion = .{
            .kind = .unavailable,
            .correlation_id = .{ .value = 8 },
        },
    };
    runtime.len = 1;
    try std.testing.expect(runtime.nextNotice(&terminal_client) == null);
    try std.testing.expectEqual(@as(usize, 1), runtime.pendingCount());
}

test "indeterminate completion does not starve a later authoritative result" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    defer runtime.deinitAbnormal(alloc, "test_cleanup");
    var terminal_client: client.Runtime = .{};
    defer terminal_client.deinit();

    var encoded = try protocol.encodeFrame(
        alloc,
        contracts.current_protocol_revision,
        0,
        .{ .value = 8 },
        .{ .response = .{ .success = .{ .start = .{
            .session = .{
                .session_id = "terminal-b",
                .lifecycle = .running,
                .attention = .{},
                .backend = .native,
                .output_cursor = .{ .segment = 1, .offset = 0 },
                .screen_recovery = .{ .unavailable = .missing },
            },
            .outcome = .started,
        } } } },
    );
    defer encoded.deinit(alloc);

    runtime.pending[0] = .{
        .correlation_id = .{ .value = 7 },
        .command = try alloc.dupe(u8, "indeterminate"),
        .starting_pending = false,
        .completion = .{
            .kind = .disconnected,
            .correlation_id = .{ .value = 7 },
        },
    };
    runtime.pending[1] = .{
        .correlation_id = .{ .value = 8 },
        .command = try alloc.dupe(u8, "authoritative"),
        .starting_pending = false,
        .completion = .{
            .kind = .response,
            .correlation_id = .{ .value = 8 },
            .frame = try protocol.decodeFrame(alloc, encoded.bytes),
        },
    };
    runtime.len = 2;

    const notice = runtime.nextNotice(&terminal_client).?;
    switch (notice) {
        .running => |running| {
            try std.testing.expectEqual(@as(u64, 8), running.correlation_id.value);
            try std.testing.expectEqualStrings("terminal-b", running.session_id);
        },
        else => return error.TestUnexpectedResult,
    }
    runtime.acknowledgeNotice(alloc, notice.correlationId(), notice.phase());

    try std.testing.expectEqual(@as(usize, 1), runtime.pendingCount());
    try std.testing.expectEqual(@as(u64, 7), runtime.pending[0].?.correlation_id.value);
    try std.testing.expect(runtime.nextNotice(&terminal_client) == null);
}

test "abnormal direct cleanup releases accepted unresolved outcomes" {
    const alloc = std.testing.allocator;
    var runtime: Runtime = .{};
    runtime.pending[0] = .{
        .correlation_id = .{ .value = 8 },
        .command = try alloc.dupe(u8, "unresolved"),
        .starting_pending = false,
    };
    runtime.len = 1;

    runtime.deinitAbnormal(alloc, "input_closed");
    try std.testing.expect(!runtime.hasAcceptedPending());
}

test "settled direct cleanup distinguishes empty from abnormal" {
    const alloc = std.testing.allocator;
    var settled: Runtime = .{};
    try std.testing.expectEqual(
        DeinitDisposition.settled,
        settled.deinitSettled(alloc),
    );

    var runtime: Runtime = .{};
    runtime.pending[0] = .{
        .correlation_id = .{ .value = 9 },
        .command = try alloc.dupe(u8, "unsettled"),
        .starting_pending = false,
    };
    runtime.len = 1;

    try std.testing.expectEqual(
        DeinitDisposition.abnormal,
        runtime.deinitSettled(alloc),
    );
    try std.testing.expect(!runtime.hasAcceptedPending());
}
