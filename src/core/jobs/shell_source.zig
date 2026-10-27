//! Shell commands as jobs. A captured command the model was handed while it
//! ran is job `bg_N`, the same execution as its `shell-N` session. The
//! managed execution runtime already delivers output exactly once: a result
//! is reserved while one consumer holds it and becomes a tombstone when
//! committed, so this source only adapts it.
const std = @import("std");
const jobs = @import("jobs.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const command_contract = @import("../execution/command_contract.zig");
const result_commit = @import("../tooling/result_commit.zig");
const text_utils = @import("../shared/text_utils.zig");
const Allocator = std.mem.Allocator;

const execution_prefix = "shell-";
const job_prefix = "bg_";
/// Result text that reaches the model inline; longer output keeps its head
/// and tail and points at the full output.
pub const inline_result_bytes = 12_000;
const preview_bytes = 4_000;

pub const Source = struct {
    runtime: *managed_execution.Runtime,

    const vtable = jobs.Source.VTable{
        .kind = .shell,
        .owns = owns,
        .list = list,
        .reserve = reserve,
        .logs = logs,
        .cancel = cancel,
    };

    pub fn source(self: *Source) jobs.Source {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn from(raw: *anyopaque) *Source {
        return @ptrCast(@alignCast(raw));
    }

    fn owns(id: []const u8) bool {
        return executionNumber(id, job_prefix) != null;
    }

    fn list(raw: *anyopaque, arena: Allocator) anyerror![]jobs.Job {
        const items = try from(raw).runtime.jobList(arena);
        const result = try arena.alloc(jobs.Job, items.len);
        var count: usize = 0;
        for (items) |item| {
            const id = (try jobId(arena, item.execution_id)) orelse continue;
            result[count] = .{
                .id = id,
                .kind = .shell,
                .label = item.command,
                .state = jobState(item.state),
                .started_ms = item.started_ms,
                .ended_ms = item.ended_ms,
                .tearing_down = item.stopping,
                .delivered = item.delivered,
            };
            count += 1;
        }
        return result[0..count];
    }

    fn reserve(raw: *anyopaque, arena: Allocator, id: []const u8) anyerror!?jobs.Settled {
        const self = from(raw);
        const execution_id = (try executionId(arena, id)) orelse return null;
        var job: ?jobs.Job = null;
        for (try list(raw, arena)) |candidate| if (std.mem.eql(u8, candidate.id, id)) {
            job = candidate;
        };
        const found = job orelse return null;
        if (!found.state.settled() or found.delivered) return null;
        // A zero wait on a settled execution reserves its final snapshot. A
        // shell interact or another consumer holding it answers busy.
        const prepared = self.runtime.wait(arena, execution_id, 0, null) catch |err| switch (err) {
            error.ExecutionBusy, error.ExecutionNotFound => return null,
            else => return err,
        };
        const token = result_commit.Token{
            .context = self.runtime,
            .identity = prepared.reservation_id,
            .commit_fn = commitReservation,
            .cancel_fn = cancelReservation,
        };
        errdefer token.cancel();
        if (prepared.snapshot.state == .running) {
            token.cancel();
            return null;
        }
        return .{ .job = found, .text = try resultText(arena, prepared.snapshot), .token = token };
    }

    fn logs(raw: *anyopaque, arena: Allocator, id: []const u8, max_bytes: usize) anyerror!jobs.Logs {
        const execution_id = (try executionId(arena, id)) orelse return error.UnknownJob;
        const peek = try from(raw).runtime.peekOutput(arena, execution_id, max_bytes);
        return .{ .text = try modelSafe(arena, peek.tail), .retained_bytes = peek.retained_bytes, .total_bytes = peek.total_bytes, .handle = peek.handle };
    }

    fn cancel(raw: *anyopaque, arena: Allocator, id: []const u8, force: bool) anyerror!jobs.Cancelled {
        const self = from(raw);
        const execution_id = (try executionId(arena, id)) orelse return error.UnknownJob;
        var before: ?jobs.Job = null;
        for (try list(raw, arena)) |candidate| if (std.mem.eql(u8, candidate.id, id)) {
            before = candidate;
        };
        const job = before orelse return error.UnknownJob;
        if (job.state.settled()) return .{ .status = .already_settled };
        const prepared = self.runtime.stop(arena, execution_id, force) catch |err| switch (err) {
            // A wait or interact holds the result; the stop still applies
            // once it lets go, so report it as requested.
            error.ExecutionBusy => return .{ .status = .requested },
            else => return err,
        };
        const token = result_commit.Token{
            .context = self.runtime,
            .identity = prepared.reservation_id,
            .commit_fn = commitReservation,
            .cancel_fn = cancelReservation,
        };
        if (prepared.snapshot.state == .running or prepared.snapshot.state == .lost) {
            token.cancel();
            return .{ .status = .requested };
        }
        var settled_job = job;
        settled_job.state = jobState(prepared.snapshot.state);
        settled_job.tearing_down = false;
        return .{ .status = .settled, .settled = .{
            .job = settled_job,
            .text = try resultText(arena, prepared.snapshot),
            .token = token,
        } };
    }

    fn commitReservation(raw: *anyopaque, reservation_id: u64) anyerror!void {
        const runtime: *managed_execution.Runtime = @ptrCast(@alignCast(raw));
        return runtime.commitReservation(reservation_id);
    }

    fn cancelReservation(raw: *anyopaque, reservation_id: u64) void {
        const runtime: *managed_execution.Runtime = @ptrCast(@alignCast(raw));
        runtime.cancelReservation(reservation_id) catch {};
    }
};

fn executionNumber(id: []const u8, prefix: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, id, prefix)) return null;
    return std.fmt.parseUnsigned(u64, id[prefix.len..], 10) catch null;
}

/// `shell-3` is job `bg_3`; null for an execution id of another shape.
pub fn jobId(alloc: Allocator, execution_id: []const u8) !?[]u8 {
    const number = executionNumber(execution_id, execution_prefix) orelse return null;
    return try alloc.print(job_prefix ++ "{d}", .{number});
}

pub fn executionId(alloc: Allocator, job_id: []const u8) !?[]u8 {
    const number = executionNumber(job_id, job_prefix) orelse return null;
    return try alloc.print(execution_prefix ++ "{d}", .{number});
}

fn jobState(state: managed_execution.SnapshotState) jobs.State {
    return switch (state) {
        .running => .running,
        .completed => |status| if (statusSucceeded(status)) .completed else .failed,
        .stopped => .cancelled,
        .lost => .failed,
    };
}

fn statusSucceeded(status: command_contract.CommandStatus) bool {
    return switch (status) {
        .exit_code => |code| code == 0,
        .finished => true,
        .signal, .indeterminate => false,
    };
}

/// The model-facing text of a settled command: its status line, then its
/// undelivered output, with head and tail kept when it is long.
fn resultText(arena: Allocator, snapshot: managed_execution.Snapshot) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    try writer.print("$ {s}\n", .{snapshot.command});
    switch (snapshot.state) {
        .completed => |status| try writeStatus(writer, status),
        .stopped => try writer.writeAll("cancelled"),
        .lost => try writer.print("lost ({s})", .{snapshot.error_name orelse "unknown"}),
        .running => try writer.writeAll("running"),
    }
    if (snapshot.duration_ms) |ms| {
        var buf: [32]u8 = undefined;
        try writer.print(" · {s}", .{jobs.formatDuration(&buf, ms)});
    }
    try writer.writeByte('\n');
    const output = std.mem.trimEnd(u8, try modelSafe(arena, snapshot.output_delta), "\n");
    if (output.len <= inline_result_bytes) {
        try writer.writeAll(output);
    } else {
        try text_utils.writeHeadTailBounded(writer, output, preview_bytes, "\n… output omitted …\n", .up);
    }
    if (snapshot.output_file) |handle| if (output.len > inline_result_bytes or snapshot.output_truncated) {
        try writer.print("\nFull output: read_tool_result handle {s}", .{handle});
    };
    return out.written();
}

/// Output as the shell tool gives it to the model: as is when it is valid
/// text, escaped otherwise.
fn modelSafe(arena: Allocator, output: []const u8) ![]const u8 {
    if (text_utils.isModelSafeText(output)) return output;
    const encoded = try text_utils.encodeTerminalSafe(arena, output, output.len * 4 + 16);
    return encoded.bytes;
}

fn writeStatus(writer: *std.Io.Writer, status: command_contract.CommandStatus) !void {
    switch (status) {
        .exit_code => |code| try writer.print("exit {d}", .{code}),
        .signal => |signal| try writer.print("signal {d}", .{signal}),
        .finished => try writer.writeAll("finished"),
        .indeterminate => try writer.writeAll("exit unknown"),
    }
}

test "shell executions and jobs share one number" {
    const alloc = std.testing.allocator;
    const job = (try jobId(alloc, "shell-12")).?;
    defer alloc.free(job);
    try std.testing.expectEqualStrings("bg_12", job);
    const execution = (try executionId(alloc, job)).?;
    defer alloc.free(execution);
    try std.testing.expectEqualStrings("shell-12", execution);
    try std.testing.expect((try jobId(alloc, "tty-1")) == null);
    try std.testing.expect(!Source.owns("bg_x"));
}

test "result text states the outcome before the output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var snapshot = managed_execution.Snapshot{
        .execution_id = @constCast("shell-1"),
        .command = @constCast("npm test"),
        .cwd = @constCast("/tmp"),
        .retained = true,
        .state = .{ .completed = .{ .exit_code = 1 } },
        .output_delta = @constCast("3 failing\n"),
        .output_truncated = false,
        .duration_ms = 4_100,
    };
    try std.testing.expectEqualStrings("$ npm test\nexit 1 · 4.1s\n3 failing", try resultText(arena, snapshot));
    try std.testing.expectEqual(jobs.State.failed, jobState(snapshot.state));
    snapshot.state = .{ .stopped = null };
    try std.testing.expectEqual(jobs.State.cancelled, jobState(snapshot.state));
}

fn startTestJob(runtime: *managed_execution.Runtime, execution_id: []const u8, command: []const u8) !void {
    var input = managed_execution.StartCapturedInput{
        .execution_id = execution_id,
        .command = command,
        .cwd = "/tmp",
        .environment = .legacy,
        .authority = undefined,
        .max_output_bytes = 4096,
        .timeout_ms = 5_000,
        .command_artifact_dir = null,
        .yield_time_ms = 0,
    };
    input.authority = .{ .shell_allowed = .{
        .fingerprint = .init(.{
            .command = input.command,
            .resolved_cwd = input.cwd,
            .target_os = @import("builtin").target.os.tag,
            .environment = input.environment,
        }),
        .source = .yolo,
    } };
    var started = try runtime.startCaptured(std.testing.allocator, input);
    defer started.deinit(std.testing.allocator);
    // The model got the running handle: the command is now a job.
    try runtime.commitDelivery(started.snapshot.execution_id, started.reservation_id);
}

test "a backgrounded command reaches a wait once and is not delivered again" {
    if (comptime @import("builtin").target.os.tag == .wasi) return;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var runtime = managed_execution.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    try startTestJob(&runtime, "shell-7", "sleep 0.2; printf done");
    var shell: Source = .{ .runtime = &runtime };
    var registry = jobs.Registry.init(std.testing.allocator);
    defer registry.deinit();
    registry.addSource(shell.source());

    const listed = try registry.list(arena);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings("bg_7", listed[0].id);
    const outcome = try registry.wait(arena, &.{"bg_7"}, 5_000, null);
    try std.testing.expectEqual(@as(usize, 1), outcome.settled.len);
    try std.testing.expectEqual(jobs.State.completed, outcome.settled[0].job.state);
    try std.testing.expect(std.mem.endsWith(u8, outcome.settled[0].text, "\ndone"));
    // Reserved by the wait until its result commits.
    try std.testing.expectEqual(@as(usize, 0), (try registry.takeDeliveries(arena)).len);
    try outcome.settled[0].token.commit();
    try std.testing.expectEqual(@as(usize, 0), (try registry.takeDeliveries(arena)).len);
    try std.testing.expect((try registry.find(arena, "bg_7")).?.delivered);
}

test "a backgrounded command nobody waits on is delivered automatically once" {
    if (comptime @import("builtin").target.os.tag == .wasi) return;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var runtime = managed_execution.Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    try startTestJob(&runtime, "shell-8", "printf out; exit 3");
    var shell: Source = .{ .runtime = &runtime };
    var registry = jobs.Registry.init(std.testing.allocator);
    defer registry.deinit();
    registry.addSource(shell.source());

    var delivered: []jobs.Settled = &.{};
    var tries: usize = 0;
    while (delivered.len == 0 and tries < 200) : (tries += 1) {
        delivered = try registry.takeDeliveries(arena);
        if (delivered.len == 0) @import("../shared/io.zig").sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 1), delivered.len);
    try std.testing.expectEqual(jobs.State.failed, delivered[0].job.state);
    try std.testing.expect(std.mem.find(u8, delivered[0].text, "exit 3") != null);
    // A refused notice leaves it deliverable; a committed one does not.
    delivered[0].token.cancel();
    const again = try registry.takeDeliveries(arena);
    try std.testing.expectEqual(@as(usize, 1), again.len);
    try again[0].token.commit();
    try std.testing.expectEqual(@as(usize, 0), (try registry.takeDeliveries(arena)).len);
    try std.testing.expectEqual(jobs.Cancelled{ .status = .already_settled }, try registry.cancel(arena, "bg_8", false));
}
