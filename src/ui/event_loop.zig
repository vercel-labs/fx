const std = @import("std");
const debug_trace = @import("../core/shared/debug_trace.zig");
const record_tape = @import("../core/workspace/record_tape.zig");
const shell_runtime = @import("shell_runtime.zig");

pub const EventLoopCallbacks = struct {
    ctx: *anyopaque,
    collect_facts: *const fn (*anyopaque) anyerror!void,
    next_collected_byte: *const fn (*anyopaque) ?u8,
    handle_byte: *const fn (*anyopaque, u8) anyerror!void,
    settle_delivery_epoch: *const fn (*anyopaque) anyerror!void,
    commit_frame: *const fn (*anyopaque) anyerror!void,
    poll_timeout_ms: ?*const fn (*anyopaque, i32) i32 = null,
};

const max_input_reads_per_fact_collection = 32;

fn attemptFinalFrameCommit(callbacks: EventLoopCallbacks, reason: []const u8) void {
    callbacks.commit_frame(callbacks.ctx) catch |err| debug_trace.logf(
        "event_loop",
        "final_frame_commit_failed reason={s} err={s}",
        .{ reason, @errorName(err) },
    );
}

pub const ExitCause = enum {
    requested_exit,
    input_closed,
};

pub fn pump_ready_input(terminal: anytype, should_exit: *bool, callbacks: EventLoopCallbacks) !?ExitCause {
    var buf: [128]u8 = undefined;
    var handled_input = false;

    while (callbacks.next_collected_byte(callbacks.ctx)) |byte| {
        handled_input = true;
        try callbacks.handle_byte(callbacks.ctx, byte);
        if (should_exit.*) return .requested_exit;
    }

    var poll_result = try terminal.pollInput(0);
    var input_reads: usize = 0;

    while (poll_result.readable and input_reads < max_input_reads_per_fact_collection) : (input_reads += 1) {
        const read_len = try terminal.read(&buf);
        if (read_len == 0) {
            if (input_reads > 0) attemptFinalFrameCommit(callbacks, "eof");
            return .input_closed;
        }

        handled_input = true;
        record_tape.recordStdin(buf[0..read_len]);
        for (buf[0..read_len]) |byte| {
            try callbacks.handle_byte(callbacks.ctx, byte);
            if (should_exit.*) return .requested_exit;
        }
        poll_result = try terminal.pollInput(0);
    }

    if (poll_result.readable) {
        try callbacks.commit_frame(callbacks.ctx);
        return null;
    }
    if (poll_result.closed()) {
        if (input_reads > 0) attemptFinalFrameCommit(callbacks, "hangup");
        return .input_closed;
    }

    if (handled_input) {
        try callbacks.settle_delivery_epoch(callbacks.ctx);
        try callbacks.commit_frame(callbacks.ctx);
    }
    return null;
}

pub fn run(terminal: anytype, should_exit: *bool, poll_timeout_ms: i32, callbacks: EventLoopCallbacks) !ExitCause {
    var buf: [128]u8 = undefined;

    while (!should_exit.*) {
        try callbacks.collect_facts(callbacks.ctx);
        if (should_exit.*) return .requested_exit;

        while (callbacks.next_collected_byte(callbacks.ctx)) |byte| {
            try callbacks.handle_byte(callbacks.ctx, byte);
            if (should_exit.*) return .requested_exit;
        }

        const timeout_ms = if (callbacks.poll_timeout_ms) |resolve|
            resolve(callbacks.ctx, poll_timeout_ms)
        else
            poll_timeout_ms;
        var poll_result = try terminal.pollInput(timeout_ms);
        var input_reads: usize = 0;
        while (poll_result.readable and input_reads < max_input_reads_per_fact_collection) : (input_reads += 1) {
            const read_len = try terminal.read(&buf);
            if (read_len == 0) {
                if (input_reads > 0) attemptFinalFrameCommit(callbacks, "eof");
                return .input_closed;
            }

            record_tape.recordStdin(buf[0..read_len]);
            for (buf[0..read_len]) |byte| {
                try callbacks.handle_byte(callbacks.ctx, byte);
                if (should_exit.*) return .requested_exit;
            }
            poll_result = try terminal.pollInput(0);
        }

        if (poll_result.readable) {
            try callbacks.commit_frame(callbacks.ctx);
            continue;
        }
        if (poll_result.closed()) {
            if (input_reads > 0) attemptFinalFrameCommit(callbacks, "hangup");
            return .input_closed;
        }

        try callbacks.settle_delivery_epoch(callbacks.ctx);
        try callbacks.commit_frame(callbacks.ctx);
    }
    return .requested_exit;
}

test "event loop exposes a post-input commit callback" {
    try std.testing.expect(@hasField(EventLoopCallbacks, "commit_frame"));
    try std.testing.expect(@hasField(EventLoopCallbacks, "settle_delivery_epoch"));
}

const EventLoopTestTrace = struct {
    bytes: [8]u8 = undefined,
    len: usize = 0,
    collected: [2]u8 = undefined,
    collected_len: usize = 0,
    collected_index: usize = 0,
    should_exit: *bool,

    fn append(self: *EventLoopTestTrace, byte: u8) void {
        self.bytes[self.len] = byte;
        self.len += 1;
    }
};

const EventLoopTestTerminal = struct {
    polls: *usize,
    burst_reads: ?*usize = null,
    observed_timeout_ms: ?*i32 = null,

    fn pollInput(self: EventLoopTestTerminal, timeout_ms: i32) !shell_runtime.PollResult {
        self.polls.* += 1;
        if (self.observed_timeout_ms) |observed| {
            if (self.polls.* == 1) observed.* = timeout_ms;
        }
        if (self.burst_reads) |reads| {
            if (reads.* < 2) return .{ .readable = true };
            return if (timeout_ms == 0) .{} else .{ .hung_up = true };
        }
        if (self.polls.* > 1) return .{ .hung_up = true };
        return .{ .readable = true };
    }

    fn read(self: EventLoopTestTerminal, buf: []u8) !usize {
        const bytes = if (self.burst_reads) |reads| blk: {
            const chunk = if (reads.* == 0) "ab" else "de";
            reads.* += 1;
            break :blk chunk;
        } else "ab";
        @memcpy(buf[0..bytes.len], bytes);
        return bytes.len;
    }
};

fn collectEventLoopTestFacts(ctx: *anyopaque) !void {
    const trace: *EventLoopTestTrace = @ptrCast(@alignCast(ctx));
    trace.append('t');
}

fn noCollectedEventLoopByte(_: *anyopaque) ?u8 {
    return null;
}

fn nextCollectedEventLoopByte(ctx: *anyopaque) ?u8 {
    const trace: *EventLoopTestTrace = @ptrCast(@alignCast(ctx));
    if (trace.collected_index >= trace.collected_len) return null;
    const byte = trace.collected[trace.collected_index];
    trace.collected_index += 1;
    return byte;
}

fn handleEventLoopTestByte(ctx: *anyopaque, byte: u8) !void {
    const trace: *EventLoopTestTrace = @ptrCast(@alignCast(ctx));
    trace.append(byte);
}

fn commitEventLoopTestFrame(ctx: *anyopaque) !void {
    const trace: *EventLoopTestTrace = @ptrCast(@alignCast(ctx));
    trace.append('c');
    trace.should_exit.* = true;
}

fn commitEventLoopTestFrameWithoutExit(ctx: *anyopaque) !void {
    const trace: *EventLoopTestTrace = @ptrCast(@alignCast(ctx));
    trace.append('c');
}

fn settleEventLoopTestDeliveryEpoch(ctx: *anyopaque) !void {
    const trace: *EventLoopTestTrace = @ptrCast(@alignCast(ctx));
    trace.append('s');
}

fn collectAndExitEventLoopTest(ctx: *anyopaque) !void {
    const trace: *EventLoopTestTrace = @ptrCast(@alignCast(ctx));
    trace.append('t');
    trace.should_exit.* = true;
}

fn handleAndExitEventLoopTestByte(ctx: *anyopaque, byte: u8) !void {
    const trace: *EventLoopTestTrace = @ptrCast(@alignCast(ctx));
    trace.append(byte);
    trace.should_exit.* = true;
}

fn rejectUnexpectedEventLoopByte(_: *anyopaque, _: u8) !void {
    return error.UnexpectedByte;
}

fn rejectUnexpectedEventLoopCommit(_: *anyopaque) !void {
    return error.UnexpectedCommit;
}

fn failEventLoopTestCommit(ctx: *anyopaque) !void {
    const trace: *EventLoopTestTrace = @ptrCast(@alignCast(ctx));
    trace.append('c');
    return error.FinalCommitFailed;
}

fn useLongerPollTimeout(_: *anyopaque, default_timeout_ms: i32) i32 {
    return default_timeout_ms * 2;
}

test "event loop commits once after every byte from the current read" {
    var should_exit = false;
    var polls: usize = 0;
    var trace = EventLoopTestTrace{ .should_exit = &should_exit };

    const exit_cause = try run(EventLoopTestTerminal{ .polls = &polls }, &should_exit, 8, .{
        .ctx = &trace,
        .collect_facts = collectEventLoopTestFacts,
        .next_collected_byte = noCollectedEventLoopByte,
        .handle_byte = handleEventLoopTestByte,
        .settle_delivery_epoch = settleEventLoopTestDeliveryEpoch,
        .commit_frame = commitEventLoopTestFrame,
    });

    try std.testing.expectEqual(ExitCause.input_closed, exit_cause);
    try std.testing.expectEqualStrings("tabc", trace.bytes[0..trace.len]);
}

test "event loop batches already readable input before committing a frame" {
    var should_exit = false;
    var polls: usize = 0;
    var reads: usize = 0;
    var trace = EventLoopTestTrace{ .should_exit = &should_exit };

    const exit_cause = try run(EventLoopTestTerminal{ .polls = &polls, .burst_reads = &reads }, &should_exit, 8, .{
        .ctx = &trace,
        .collect_facts = collectEventLoopTestFacts,
        .next_collected_byte = noCollectedEventLoopByte,
        .handle_byte = handleEventLoopTestByte,
        .settle_delivery_epoch = settleEventLoopTestDeliveryEpoch,
        .commit_frame = commitEventLoopTestFrame,
    });

    try std.testing.expectEqual(ExitCause.requested_exit, exit_cause);
    try std.testing.expectEqualStrings("tabdesc", trace.bytes[0..trace.len]);
}

test "cooperative input pump renders ready input without collecting facts" {
    var should_exit = false;
    var polls: usize = 0;
    var reads: usize = 0;
    var trace = EventLoopTestTrace{ .should_exit = &should_exit };

    const exit_cause = try pump_ready_input(EventLoopTestTerminal{
        .polls = &polls,
        .burst_reads = &reads,
    }, &should_exit, .{
        .ctx = &trace,
        .collect_facts = collectEventLoopTestFacts,
        .next_collected_byte = noCollectedEventLoopByte,
        .handle_byte = handleEventLoopTestByte,
        .settle_delivery_epoch = settleEventLoopTestDeliveryEpoch,
        .commit_frame = commitEventLoopTestFrameWithoutExit,
    });

    try std.testing.expectEqual(@as(?ExitCause, null), exit_cause);
    try std.testing.expect(!should_exit);
    try std.testing.expectEqualStrings("abdesc", trace.bytes[0..trace.len]);
}

test "cooperative input pump is idle when no input is ready" {
    const Terminal = struct {
        fn pollInput(_: @This(), timeout_ms: i32) !shell_runtime.PollResult {
            try std.testing.expectEqual(@as(i32, 0), timeout_ms);
            return .{};
        }

        fn read(_: @This(), _: []u8) !usize {
            return error.UnexpectedRead;
        }
    };

    var should_exit = false;
    var trace = EventLoopTestTrace{ .should_exit = &should_exit };
    const exit_cause = try pump_ready_input(Terminal{}, &should_exit, .{
        .ctx = &trace,
        .collect_facts = collectEventLoopTestFacts,
        .next_collected_byte = noCollectedEventLoopByte,
        .handle_byte = rejectUnexpectedEventLoopByte,
        .settle_delivery_epoch = rejectUnexpectedEventLoopCommit,
        .commit_frame = rejectUnexpectedEventLoopCommit,
    });

    try std.testing.expectEqual(@as(?ExitCause, null), exit_cause);
    try std.testing.expect(!should_exit);
    try std.testing.expectEqual(@as(usize, 0), trace.len);
}

test "event loop settles a facts-only delivery epoch before committing" {
    const Terminal = struct {
        fn pollInput(_: @This(), _: i32) !shell_runtime.PollResult {
            return .{};
        }

        fn read(_: @This(), _: []u8) !usize {
            return error.UnexpectedRead;
        }
    };

    var should_exit = false;
    var trace = EventLoopTestTrace{ .should_exit = &should_exit };
    const exit_cause = try run(Terminal{}, &should_exit, 8, .{
        .ctx = &trace,
        .collect_facts = collectEventLoopTestFacts,
        .next_collected_byte = noCollectedEventLoopByte,
        .handle_byte = handleEventLoopTestByte,
        .settle_delivery_epoch = settleEventLoopTestDeliveryEpoch,
        .commit_frame = commitEventLoopTestFrame,
    });

    try std.testing.expectEqual(ExitCause.requested_exit, exit_cause);
    try std.testing.expectEqualStrings("tsc", trace.bytes[0..trace.len]);
}

test "event loop resolves a dynamic poll timeout" {
    var should_exit = false;
    var polls: usize = 0;
    var observed_timeout_ms: i32 = 0;
    var trace = EventLoopTestTrace{ .should_exit = &should_exit };

    const exit_cause = try run(EventLoopTestTerminal{
        .polls = &polls,
        .observed_timeout_ms = &observed_timeout_ms,
    }, &should_exit, 8, .{
        .ctx = &trace,
        .collect_facts = collectEventLoopTestFacts,
        .next_collected_byte = noCollectedEventLoopByte,
        .handle_byte = handleEventLoopTestByte,
        .settle_delivery_epoch = settleEventLoopTestDeliveryEpoch,
        .commit_frame = commitEventLoopTestFrame,
        .poll_timeout_ms = useLongerPollTimeout,
    });

    try std.testing.expectEqual(ExitCause.input_closed, exit_cause);
    try std.testing.expectEqual(@as(i32, 16), observed_timeout_ms);
}

test "event loop dispatches probe-collected input before polled input" {
    var should_exit = false;
    var polls: usize = 0;
    var trace = EventLoopTestTrace{
        .collected = .{ 'x', 0 },
        .collected_len = 1,
        .should_exit = &should_exit,
    };

    const exit_cause = try run(EventLoopTestTerminal{ .polls = &polls }, &should_exit, 8, .{
        .ctx = &trace,
        .collect_facts = collectEventLoopTestFacts,
        .next_collected_byte = nextCollectedEventLoopByte,
        .handle_byte = handleEventLoopTestByte,
        .settle_delivery_epoch = settleEventLoopTestDeliveryEpoch,
        .commit_frame = commitEventLoopTestFrame,
    });

    try std.testing.expectEqual(ExitCause.input_closed, exit_cause);
    try std.testing.expectEqualStrings("txabc", trace.bytes[0..trace.len]);
}

test "event loop stops after fact collection requests exit" {
    var should_exit = false;
    var polls: usize = 0;
    var trace = EventLoopTestTrace{ .should_exit = &should_exit };

    const exit_cause = try run(EventLoopTestTerminal{ .polls = &polls }, &should_exit, 8, .{
        .ctx = &trace,
        .collect_facts = collectAndExitEventLoopTest,
        .next_collected_byte = noCollectedEventLoopByte,
        .handle_byte = rejectUnexpectedEventLoopByte,
        .settle_delivery_epoch = settleEventLoopTestDeliveryEpoch,
        .commit_frame = rejectUnexpectedEventLoopCommit,
    });

    try std.testing.expectEqual(ExitCause.requested_exit, exit_cause);
    try std.testing.expectEqual(@as(usize, 0), polls);
    try std.testing.expectEqualStrings("t", trace.bytes[0..trace.len]);
}

test "event loop skips frame commit after input requests exit" {
    var should_exit = false;
    var polls: usize = 0;
    var trace = EventLoopTestTrace{ .should_exit = &should_exit };

    const exit_cause = try run(
        EventLoopTestTerminal{ .polls = &polls },
        &should_exit,
        8,
        .{
            .ctx = &trace,
            .collect_facts = collectEventLoopTestFacts,
            .next_collected_byte = noCollectedEventLoopByte,
            .handle_byte = handleAndExitEventLoopTestByte,
            .settle_delivery_epoch = settleEventLoopTestDeliveryEpoch,
            .commit_frame = rejectUnexpectedEventLoopCommit,
        },
    );

    try std.testing.expectEqual(ExitCause.requested_exit, exit_cause);
    try std.testing.expectEqualStrings("ta", trace.bytes[0..trace.len]);
}

const EventLoopClosedTerminal = struct {
    poll_result: shell_runtime.PollResult,

    fn pollInput(self: EventLoopClosedTerminal, _: i32) !shell_runtime.PollResult {
        return self.poll_result;
    }

    fn read(_: EventLoopClosedTerminal, _: []u8) !usize {
        return 0;
    }
};

test "event loop distinguishes requested exit from input closure" {
    var should_exit = false;
    var trace = EventLoopTestTrace{ .should_exit = &should_exit };
    const callbacks = EventLoopCallbacks{
        .ctx = &trace,
        .collect_facts = collectEventLoopTestFacts,
        .next_collected_byte = noCollectedEventLoopByte,
        .handle_byte = rejectUnexpectedEventLoopByte,
        .settle_delivery_epoch = settleEventLoopTestDeliveryEpoch,
        .commit_frame = rejectUnexpectedEventLoopCommit,
    };

    for ([_]shell_runtime.PollResult{
        .{ .readable = true },
        .{ .hung_up = true },
        .{ .has_error = true },
    }) |poll_result| {
        try std.testing.expectEqual(
            ExitCause.input_closed,
            try run(
                EventLoopClosedTerminal{ .poll_result = poll_result },
                &should_exit,
                8,
                callbacks,
            ),
        );
        try std.testing.expect(!should_exit);
    }
}

test "event loop treats a failed final commit after hangup as a clean close" {
    var should_exit = false;
    var polls: usize = 0;
    var trace = EventLoopTestTrace{ .should_exit = &should_exit };

    const exit_cause = try run(EventLoopTestTerminal{ .polls = &polls }, &should_exit, 8, .{
        .ctx = &trace,
        .collect_facts = collectEventLoopTestFacts,
        .next_collected_byte = noCollectedEventLoopByte,
        .handle_byte = handleEventLoopTestByte,
        .settle_delivery_epoch = settleEventLoopTestDeliveryEpoch,
        .commit_frame = failEventLoopTestCommit,
    });

    try std.testing.expectEqual(ExitCause.input_closed, exit_cause);
    try std.testing.expect(!should_exit);
    try std.testing.expectEqualStrings("tabc", trace.bytes[0..trace.len]);
}

test "event loop commits a frame before sustained readable input can starve it" {
    const Terminal = struct {
        fn pollInput(_: @This(), _: i32) !shell_runtime.PollResult {
            return .{ .readable = true };
        }

        fn read(_: @This(), buf: []u8) !usize {
            buf[0] = 'x';
            return 1;
        }
    };
    const Trace = struct {
        handled: usize = 0,
        should_exit: *bool,

        fn collect(_: *anyopaque) !void {}
        fn next(_: *anyopaque) ?u8 {
            return null;
        }
        fn handle(ctx: *anyopaque, _: u8) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.handled += 1;
        }
        fn settle(_: *anyopaque) !void {
            return error.UnexpectedSettlement;
        }
        fn commit(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.should_exit.* = true;
        }
    };

    var should_exit = false;
    var trace = Trace{ .should_exit = &should_exit };
    const exit_cause = try run(Terminal{}, &should_exit, 8, .{
        .ctx = &trace,
        .collect_facts = Trace.collect,
        .next_collected_byte = Trace.next,
        .handle_byte = Trace.handle,
        .settle_delivery_epoch = Trace.settle,
        .commit_frame = Trace.commit,
    });
    try std.testing.expectEqual(ExitCause.requested_exit, exit_cause);
    try std.testing.expectEqual(max_input_reads_per_fact_collection, trace.handled);
}

test "event loop commits handled input before read EOF" {
    const Terminal = struct {
        reads: *usize,

        fn pollInput(_: @This(), _: i32) !shell_runtime.PollResult {
            return .{ .readable = true };
        }

        fn read(self: @This(), buf: []u8) !usize {
            if (self.reads.* > 0) return 0;
            self.reads.* += 1;
            buf[0] = 'x';
            return 1;
        }
    };
    const Trace = struct {
        commits: usize = 0,

        fn collect(_: *anyopaque) !void {}
        fn next(_: *anyopaque) ?u8 {
            return null;
        }
        fn handle(_: *anyopaque, _: u8) !void {}
        fn settle(_: *anyopaque) !void {
            return error.UnexpectedSettlement;
        }
        fn commit(ctx: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.commits += 1;
            return error.FinalCommitFailed;
        }
    };

    var should_exit = false;
    var reads: usize = 0;
    var trace = Trace{};
    const exit_cause = try run(Terminal{ .reads = &reads }, &should_exit, 8, .{
        .ctx = &trace,
        .collect_facts = Trace.collect,
        .next_collected_byte = Trace.next,
        .handle_byte = Trace.handle,
        .settle_delivery_epoch = Trace.settle,
        .commit_frame = Trace.commit,
    });
    try std.testing.expectEqual(ExitCause.input_closed, exit_cause);
    try std.testing.expect(!should_exit);
    try std.testing.expectEqual(@as(usize, 1), trace.commits);
}
