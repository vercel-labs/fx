//! Runs model-written JavaScript in a separate, confined fx process, so a bug
//! in the engine can crash or hang only that process. The parent starts
//! `fx __fx_sandbox__` with an empty environment and sends it the program.
//! The child confines itself (`confine.zig`) before it reads anything, then
//! runs the program in the embedded engine. Each tool call the program makes
//! travels back to the parent, which runs it through a `Caller` and returns
//! the result. The parent kills a child that keeps JavaScript running past
//! the program's time limit and a short grace.
//!
//! Each frame on the pipes is a u32 little-endian length followed by that
//! many bytes of JSON:
//!
//! - parent to child, first: `{"source"}`
//! - child to parent: `{"kind": "call", "tool", "input"}`, answered with
//!   `{"ok", "text"}`
//! - child to parent, last: `{"kind": "outcome", "outcome", "text", "logs",
//!   "logs_truncated"}`
//!
//! The limits travel as arguments, because the child needs them before it
//! confines itself and reads its first frame.

const std = @import("std");
const build_options = @import("build_options");
const engine = @import("js_engine");
const confine = @import("confine.zig");
const json_decode = @import("../shared/json_decode.zig");
const self_exe = @import("../shared/self_exe.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");

/// Whether this platform has a sandbox. Without one, code mode never runs.
pub const supported = confine.supported;

/// Whether code mode can run in this build: the fx binary on a platform with
/// a sandbox. libfx can't start the sandbox child, since its process is the
/// host's.
pub const available = supported and !build_options.libfx;

pub const Limits = engine.Limits;
pub const CallResult = engine.CallResult;

/// The hidden first argument that makes fx the sandbox child. Four
/// arguments follow it: heap bytes, stack bytes, time in milliseconds, and
/// the most tool calls.
const child_argument = "__fx_sandbox__";

/// Largest program the parent sends.
pub const max_source_bytes = 1024 * 1024;
/// Largest first frame: the program, escaped as a JSON string.
const max_run_frame_bytes = 7 * max_source_bytes;
/// Largest frame either side sends after the first.
const max_frame_bytes = 8 * 1024 * 1024;
/// Console output kept for one program.
const max_log_bytes = 32 * 1024;
/// The most text a reply carries. One byte escapes to at most six in JSON, so
/// the reply's frame fits however its text escapes.
const max_result_text_bytes = (max_frame_bytes - 1024) / 6;
/// The most text an outcome carries, for the same reason, next to its logs.
const max_outcome_text_bytes = (max_frame_bytes - 6 * max_log_bytes - 1024) / 6;
/// Bytes the parent writes to the child at once. A pipe that reports
/// `POLLOUT` has room for a write this small on Linux and macOS, so the write
/// can't block.
const pipe_chunk_bytes = 512;

/// What a program sees when one tool call's input won't fit in a frame.
const call_too_large = "This tool call's input is over 8 MiB, the most one call can send. Send less in each call.";
/// How long past the program's time limit the parent waits, each time it
/// hands control to the child, before it kills the child.
const grace_ms = 2000;
/// How often the parent checks for cancellation while the child runs.
const cancel_poll_ms = 100;

/// How the child exits. Only `reported` means an outcome frame was sent.
const ChildExit = enum(u8) {
    reported = 0,
    bad_arguments = 2,
    unconfined = 3,
    bad_frame = 4,
    out_of_memory = 5,
    write_failed = 6,
};

/// Runs the tool calls a program makes, in the parent.
pub const Caller = struct {
    context: *anyopaque,
    /// Runs one call. The text may live in `arena`, which lasts until the
    /// result is sent.
    call_fn: *const fn (context: *anyopaque, arena: std.mem.Allocator, name: []const u8, args_json: []const u8) CallerError!CallResult,
    /// Whether the run was cancelled. Checked while the child runs.
    cancelled_fn: *const fn (context: *anyopaque) bool,
};

pub const CallerError = error{ OutOfMemory, Cancelled };

/// What a sandboxed run produced. Text is owned by the allocator passed to
/// `run`, except `failed`, which is static.
pub const Result = union(enum) {
    /// The program finished. The JSON text of its return value, or null
    /// when the value has no JSON form.
    returned: ?[]u8,
    /// The program threw. The text names the error and where it happened.
    threw: []u8,
    /// The program ran past its time limit and was stopped.
    timed_out,
    /// The program waits on a promise that nothing left can settle.
    unsettled,
    /// The run was cancelled, and the child was stopped.
    cancelled,
    /// The child stopped without reporting an outcome. The text says why,
    /// in words a model can act on.
    failed: []const u8,

    pub fn deinit(result: Result, gpa: std.mem.Allocator) void {
        switch (result) {
            .returned => |json| if (json) |text| gpa.free(text),
            .threw => |text| gpa.free(text),
            .timed_out, .unsettled, .cancelled, .failed => {},
        }
    }
};

/// A run's result and the program's console output.
pub const Report = struct {
    result: Result,
    /// The program's `console` lines, owned by the allocator passed to `run`
    /// when not empty.
    logs: []const u8 = "",
    /// Lines past `max_log_bytes` were dropped.
    logs_truncated: bool = false,

    pub fn deinit(report: Report, gpa: std.mem.Allocator) void {
        report.result.deinit(gpa);
        if (report.logs.len > 0) gpa.free(report.logs);
    }
};

pub const RunError = error{OutOfMemory};

const message = struct {
    const unsupported = "Code mode needs a sandbox, and fx has none for this platform.";
    const too_large = "The program is over 1 MiB. Send a shorter program.";
    const no_start = "The sandbox process could not start.";
    const unconfined = "The sandbox could not lock its process down on this system, so fx did not run the program.";
    const refused = "The sandbox stopped the program because the engine made a system call that code mode does not allow.";
    const out_of_resources = "The program used up its CPU time or memory and was stopped.";
    const killed = "The sandbox process was killed before it reported an outcome.";
    const crashed = "The JavaScript engine crashed while running the program.";
    const no_outcome = "The sandbox process exited without reporting an outcome.";
    const bad_frame = "The sandbox process sent a message fx could not read.";
    /// The child's outcome when the size message itself can't be formatted.
    const return_too_large = "The return value is too large to send back. Return less, such as a summary or the first items.";
};

const OutcomeKind = enum { returned, threw, timed_out, unsettled };

/// Every frame the child sends.
const ChildFrame = struct {
    kind: enum { call, outcome },
    tool: []const u8 = "",
    input: []const u8 = "",
    outcome: OutcomeKind = .returned,
    text: ?[]const u8 = null,
    logs: []const u8 = "",
    logs_truncated: bool = false,
};

const RunFrame = struct {
    source: []const u8,
};

const ResultFrame = struct {
    ok: bool,
    text: []const u8,
};

/// Runs `source` in a fresh sandbox child. Each tool call the program makes
/// goes to `caller`, which also answers a name that is no tool.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    limits: Limits,
    caller: Caller,
) RunError!Report {
    if (!supported) return .{ .result = .{ .failed = message.unsupported } };
    if (source.len > max_source_bytes) return .{ .result = .{ .failed = message.too_large } };
    var child = startChild(gpa, io, limits) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("code_mode", "sandbox process did not start err={t}", .{err});
            return .{ .result = .{ .failed = message.no_start } };
        },
    };
    // Kills and reaps the child, so a child that keeps running after its
    // outcome or after a bad frame can't hold the parent. Idempotent, and
    // does nothing once `wait` has returned.
    defer child.kill(io);
    var parent: Parent = .{ .gpa = gpa, .io = io, .child = &child, .limits = limits, .caller = caller };
    return parent.drive(source);
}

/// The parent's side of one run.
const Parent = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    limits: Limits,
    caller: Caller,
    calls: usize = 0,

    fn drive(parent: *Parent, source: []const u8) RunError!Report {
        var call_arena: std.heap.ArenaAllocator = .init(parent.gpa);
        defer call_arena.deinit();

        parent.send(RunFrame{ .source = source }) catch |err| return parent.stopFor(err);
        while (true) {
            const frame = parent.awaitFrame() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Cancelled => return parent.cancelled(),
                error.DeadlinePassed => return parent.timedOut(),
                error.FrameTooLarge => {
                    debug_trace.logf("code_mode", "stopped sandbox process that sent a frame over max_bytes={d}", .{max_frame_bytes});
                    return .{ .result = .{ .failed = message.bad_frame } };
                },
                error.EndOfStream, error.ReadFailed => return .{ .result = .{ .failed = parent.stopAndDescribe() } },
            };
            defer parent.gpa.free(frame);
            const parsed = json_decode.parseFromSlice(ChildFrame, parent.gpa, frame, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .result = .{ .failed = message.bad_frame } },
            };
            defer parsed.deinit();
            switch (parsed.value.kind) {
                .outcome => return outcomeReport(parent.gpa, parsed.value),
                .call => {
                    parent.calls += 1;
                    const answer = parent.caller.call_fn(parent.caller.context, call_arena.allocator(), parsed.value.tool, parsed.value.input) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Cancelled => return parent.cancelled(),
                    };
                    parent.send(ResultFrame{ .ok = answer.ok, .text = fitFrame(answer.text) }) catch |err| return parent.stopFor(err);
                    _ = call_arena.reset(.retain_capacity);
                },
            }
        }
    }

    const SendError = error{ OutOfMemory, Cancelled, DeadlinePassed };

    /// Sends one frame to the child. The deadline and cancellation apply as
    /// they do to a read, so a child that stops reading can't hold the
    /// parent. A failed write means the child already exited, and the next
    /// read reports why.
    fn send(parent: *Parent, value: anytype) SendError!void {
        var frame: std.Io.Writer.Allocating = .init(parent.gpa);
        defer frame.deinit();
        frame.writer.writeAll(&@as([4]u8, @splat(0))) catch return error.OutOfMemory;
        std.json.Stringify.value(value, .{}, &frame.writer) catch return error.OutOfMemory;
        const bytes = frame.written();
        std.mem.writeInt(u32, bytes[0..4], @intCast(bytes.len - 4), .little);
        const deadline_ms = std.Io.Clock.awake.now(parent.io).toMilliseconds() + parent.limits.time_ms + grace_ms;
        writeToChild(parent.io, parent.child.stdin.?, bytes, deadline_ms, parent.caller) catch |err| switch (err) {
            error.Cancelled => return error.Cancelled,
            error.DeadlinePassed => return error.DeadlinePassed,
            error.WriteFailed => debug_trace.logf("code_mode", "writing to the sandbox process failed bytes={d}", .{bytes.len}),
        };
    }

    fn stopFor(parent: *Parent, err: SendError) RunError!Report {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Cancelled => parent.cancelled(),
            error.DeadlinePassed => parent.timedOut(),
        };
    }

    fn cancelled(parent: *Parent) Report {
        debug_trace.logf("code_mode", "stopped sandbox process for a cancelled run calls={d}", .{parent.calls});
        return .{ .result = .cancelled };
    }

    fn timedOut(parent: *Parent) Report {
        debug_trace.logf("code_mode", "killed sandbox process still running grace_ms={d} past time_ms={d}", .{ grace_ms, parent.limits.time_ms });
        return .{ .result = .timed_out };
    }

    const AwaitError = error{ OutOfMemory, Cancelled, DeadlinePassed, EndOfStream, ReadFailed, FrameTooLarge };

    /// Reads one frame from the child. The deadline starts now: the child
    /// has control from the moment the parent sends it a frame. The caller
    /// owns the returned bytes.
    fn awaitFrame(parent: *Parent) AwaitError![]u8 {
        const deadline_ms = std.Io.Clock.awake.now(parent.io).toMilliseconds() + parent.limits.time_ms + grace_ms;
        var header: [4]u8 = undefined;
        try parent.readBefore(&header, deadline_ms);
        const len = std.mem.readInt(u32, &header, .little);
        if (len > max_frame_bytes) return error.FrameTooLarge;
        const payload = try parent.gpa.alloc(u8, len);
        errdefer parent.gpa.free(payload);
        try parent.readBefore(payload, deadline_ms);
        return payload;
    }

    fn readBefore(parent: *Parent, buffer: []u8, deadline_ms: i64) AwaitError!void {
        return readFromChild(parent.io, parent.child.stdout.?, buffer, deadline_ms, parent.caller);
    }

    /// Why a child that sent no outcome stopped. A child that is still
    /// running, such as one that closed its stdout, would block `wait`
    /// forever, so it is killed first. A child already exiting keeps the
    /// status it exited with.
    fn stopAndDescribe(parent: *Parent) []const u8 {
        if (parent.child.id) |pid| std.posix.kill(pid, .KILL) catch {};
        const term = parent.child.wait(parent.io) catch return message.no_outcome;
        debug_trace.logf("code_mode", "sandbox process stopped without an outcome term={f}", .{term});
        return describeExit(term);
    }
};

fn readFromChild(io: std.Io, file: std.Io.File, buffer: []u8, deadline_ms: i64, caller: ?Caller) Parent.AwaitError!void {
    var filled: usize = 0;
    while (filled < buffer.len) {
        if (caller) |c| if (c.cancelled_fn(c.context)) return error.Cancelled;
        const remaining = deadline_ms - std.Io.Clock.awake.now(io).toMilliseconds();
        if (remaining <= 0) return error.DeadlinePassed;
        var fds = [_]std.posix.pollfd{.{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, @intCast(@min(remaining, cancel_poll_ms))) catch return error.ReadFailed;
        if (ready == 0) continue;
        const n = std.posix.read(file.handle, buffer[filled..]) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        filled += n;
    }
}

/// Writes `bytes` to the child a chunk at a time, each once the pipe has room
/// for it, so no write blocks past the deadline or a cancellation.
fn writeToChild(io: std.Io, file: std.Io.File, bytes: []const u8, deadline_ms: i64, caller: ?Caller) error{ Cancelled, DeadlinePassed, WriteFailed }!void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        if (caller) |c| if (c.cancelled_fn(c.context)) return error.Cancelled;
        const remaining = deadline_ms - std.Io.Clock.awake.now(io).toMilliseconds();
        if (remaining <= 0) return error.DeadlinePassed;
        var fds = [_]std.posix.pollfd{.{ .fd = file.handle, .events = std.posix.POLL.OUT, .revents = 0 }};
        const ready = std.posix.poll(&fds, @intCast(@min(remaining, cancel_poll_ms))) catch return error.WriteFailed;
        if (ready == 0) continue;
        const chunk = bytes[sent..][0..@min(bytes.len - sent, pipe_chunk_bytes)];
        const rc = std.c.write(file.handle, chunk.ptr, chunk.len);
        if (rc < 0) switch (std.c.errno(rc)) {
            .INTR, .AGAIN => continue,
            else => return error.WriteFailed,
        };
        sent += @intCast(rc);
    }
}

/// Text that fits in one frame however JSON escapes it. A tool result this
/// large has already passed the tool's own output limit.
fn fitFrame(text: []const u8) []const u8 {
    return text_utils.utf8PrefixByBytes(text, max_result_text_bytes);
}

fn startChild(gpa: std.mem.Allocator, io: std.Io, limits: Limits) !std.process.Child {
    const exe = try self_exe.pathForReexec(gpa);
    defer gpa.free(exe);
    var heap_buffer: [24]u8 = undefined;
    var stack_buffer: [24]u8 = undefined;
    var time_buffer: [24]u8 = undefined;
    var calls_buffer: [24]u8 = undefined;
    const argv = [_][]const u8{
        exe,
        child_argument,
        try std.mem.print(&heap_buffer, "{d}", .{limits.heap_bytes}),
        try std.mem.print(&stack_buffer, "{d}", .{limits.stack_bytes}),
        try std.mem.print(&time_buffer, "{d}", .{limits.time_ms}),
        try std.mem.print(&calls_buffer, "{d}", .{limits.max_calls}),
    };
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    return std.process.spawn(io, .{
        .argv = &argv,
        .cwd = .{ .path = "/" },
        .environ_map = &environ,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
}

fn describeExit(term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .exited => |code| switch (code) {
            @backingInt(ChildExit.unconfined) => message.unconfined,
            @backingInt(ChildExit.out_of_memory) => message.out_of_resources,
            else => message.no_outcome,
        },
        .signal => |signal| switch (signal) {
            .SYS => message.refused,
            // The CPU limit on macOS. On Linux it kills the process instead.
            .XCPU => message.out_of_resources,
            // fx itself kills a child that closed its output without an
            // outcome, so a kill doesn't say the program ran out of anything.
            .KILL => message.killed,
            else => message.crashed,
        },
        .stopped, .unknown => message.crashed,
    };
}

fn outcomeReport(gpa: std.mem.Allocator, frame: ChildFrame) RunError!Report {
    const result: Result = switch (frame.outcome) {
        .returned => .{ .returned = if (frame.text) |json| try gpa.dupe(u8, json) else null },
        .threw => .{ .threw = try gpa.dupe(u8, frame.text orelse "") },
        .timed_out => .timed_out,
        .unsettled => .unsettled,
    };
    errdefer result.deinit(gpa);
    return .{
        .result = result,
        .logs = if (frame.logs.len > 0) try gpa.dupe(u8, frame.logs) else "",
        .logs_truncated = frame.logs_truncated,
    };
}

/// Whether this process was started as the sandbox child.
pub fn isChildInvocationRaw(raw_args: []const [*:0]const u8) bool {
    return raw_args.len == 6 and std.mem.eql(u8, std.mem.sliceTo(raw_args[1], 0), child_argument);
}

/// The sandbox child's whole life, from `mainC` before any other startup
/// work. Returns the process exit code.
extern "c" fn tzset() void;

pub fn runChild(gpa: std.mem.Allocator, io: std.Io, raw_args: []const [*:0]const u8) u8 {
    const limits = parseLimits(raw_args[2..]) orelse return @backingInt(ChildExit.bad_arguments);
    // Load the local time zone while files can still be opened: the engine's
    // local-time Date methods need it, and libc keeps it after the first
    // load. Confined, the zone file's open would stop the child on Linux and
    // leave it on UTC on macOS.
    tzset();
    confine.confine(.{
        .address_space_bytes = addressSpaceBytes(limits),
        .cpu_seconds = limits.time_ms / 1000 + 2,
    }) catch return @backingInt(ChildExit.unconfined);

    var in_buffer: [4096]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(io, &in_buffer);
    var out_buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buffer);

    const first = readFrame(gpa, &in.interface, max_run_frame_bytes) catch return @backingInt(ChildExit.bad_frame);
    defer gpa.free(first);
    const run_frame = json_decode.parseFromSlice(RunFrame, gpa, first, .{}) catch return @backingInt(ChildExit.bad_frame);
    defer run_frame.deinit();
    if (run_frame.value.source.len > max_source_bytes) return @backingInt(ChildExit.bad_frame);

    var host: ChildHost = .{ .gpa = gpa, .reader = &in.interface, .writer = &out.interface };
    defer host.deinit();
    const outcome = engine.run(gpa, io, run_frame.value.source, limits, host.engineHost()) catch
        return @backingInt(ChildExit.out_of_memory);
    defer outcome.deinit(gpa);
    writeOutcome(gpa, &out.interface, outcome, host.logs.items, host.logs_truncated) catch |err| return switch (err) {
        error.OutOfMemory => @backingInt(ChildExit.out_of_memory),
        error.WriteFailed => @backingInt(ChildExit.write_failed),
    };
    return @backingInt(ChildExit.reported);
}

/// The engine's host in the child: each tool call becomes a frame to the
/// parent, and `console` lines collect until the outcome.
const ChildHost = struct {
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    /// The last result frame and its parse, kept until the next call, since
    /// the engine borrows the result's text until then.
    last_frame: ?[]u8 = null,
    last_result: ?std.json.Parsed(ResultFrame) = null,
    logs: std.ArrayList(u8) = .empty,
    logs_truncated: bool = false,

    fn engineHost(host: *ChildHost) engine.Host {
        return .{ .context = host, .call_fn = call, .log_fn = log };
    }

    fn deinit(host: *ChildHost) void {
        host.releaseLast();
        host.logs.deinit(host.gpa);
    }

    fn releaseLast(host: *ChildHost) void {
        if (host.last_result) |parsed| parsed.deinit();
        if (host.last_frame) |frame| host.gpa.free(frame);
        host.last_result = null;
        host.last_frame = null;
    }

    /// A closed or garbled pipe means the parent is gone or has given up on
    /// the run, so the program stops.
    fn call(context: *anyopaque, name: []const u8, args_json: []const u8) engine.CallError!engine.CallResult {
        const host: *ChildHost = @ptrCast(@alignCast(context));
        host.releaseLast();
        // The parent stops a child that sends a frame over the limit, so the
        // program gets an error it can repair instead. JSON escaping only
        // grows the text, so inputs this long are over before it runs.
        if (name.len + args_json.len > max_frame_bytes) return .{ .ok = false, .text = call_too_large };
        var json: std.Io.Writer.Allocating = .init(host.gpa);
        defer json.deinit();
        std.json.Stringify.value(.{ .kind = "call", .tool = name, .input = args_json }, .{}, &json.writer) catch return error.OutOfMemory;
        if (json.written().len > max_frame_bytes) return .{ .ok = false, .text = call_too_large };
        writeFrame(host.writer, json.written()) catch return error.Stopped;
        host.last_frame = readFrame(host.gpa, host.reader, max_frame_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Stopped,
        };
        host.last_result = json_decode.parseFromSlice(ResultFrame, host.gpa, host.last_frame.?, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Stopped,
        };
        return .{ .ok = host.last_result.?.value.ok, .text = host.last_result.?.value.text };
    }

    fn log(context: *anyopaque, line: []const u8) void {
        const host: *ChildHost = @ptrCast(@alignCast(context));
        const room = max_log_bytes -| host.logs.items.len;
        const kept = line[0..@min(line.len, room -| 1)];
        if (kept.len < line.len) host.logs_truncated = true;
        if (room == 0) return;
        host.logs.appendSlice(host.gpa, kept) catch return;
        host.logs.append(host.gpa, '\n') catch return;
    }
};

fn parseLimits(args: []const [*:0]const u8) ?Limits {
    if (args.len != 4) return null;
    const heap_bytes = std.fmt.parseInt(usize, std.mem.sliceTo(args[0], 0), 10) catch return null;
    const stack_bytes = std.fmt.parseInt(usize, std.mem.sliceTo(args[1], 0), 10) catch return null;
    const time_ms = std.fmt.parseInt(u32, std.mem.sliceTo(args[2], 0), 10) catch return null;
    const max_calls = std.fmt.parseInt(u32, std.mem.sliceTo(args[3], 0), 10) catch return null;
    if (heap_bytes == 0 or stack_bytes == 0 or time_ms == 0) return null;
    return .{ .heap_bytes = heap_bytes, .stack_bytes = stack_bytes, .time_ms = time_ms, .max_calls = max_calls };
}

/// The engine caps its heap at twice `heap_bytes`; the rest covers the
/// binary's own mappings, which are large in a Debug build.
fn addressSpaceBytes(limits: Limits) u64 {
    return (@as(u64, limits.heap_bytes) *| 2) +| (1 << 30);
}

fn readFrame(gpa: std.mem.Allocator, reader: *std.Io.Reader, max_bytes: usize) ![]u8 {
    const len = try reader.takeInt(u32, .little);
    if (len > max_bytes) return error.FrameTooLarge;
    return reader.readAllocAll(gpa, len);
}

fn writeFrame(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try writer.writeInt(u32, @intCast(bytes.len), .little);
    try writer.writeAll(bytes);
    try writer.flush();
}

fn writeOutcome(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    outcome: engine.Outcome,
    logs: []const u8,
    logs_truncated: bool,
) error{ OutOfMemory, WriteFailed }!void {
    var too_large_buffer: [160]u8 = undefined;
    const kind: OutcomeKind, const text: ?[]const u8 = switch (outcome) {
        .returned => |json| if (json != null and json.?.len > max_outcome_text_bytes) .{
            .threw,
            std.mem.print(&too_large_buffer, "The return value is {d} bytes as JSON, over the {d}-byte limit. Return less, such as a summary or the first items.", .{ json.?.len, max_outcome_text_bytes }) catch message.return_too_large,
        } else .{ .returned, json },
        .threw => |thrown| .{ .threw, text_utils.utf8PrefixByBytes(thrown, max_outcome_text_bytes) },
        .timed_out => .{ .timed_out, null },
        .unsettled => .{ .unsettled, null },
    };
    var json: std.Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    std.json.Stringify.value(.{
        .kind = "outcome",
        .outcome = kind,
        .text = text,
        .logs = logs,
        .logs_truncated = logs_truncated,
    }, .{}, &json.writer) catch return error.OutOfMemory;
    try writeFrame(writer, json.written());
}

/// A caller for tests. It answers each tool from `answer_fn`, records every
/// call, and can wait before it answers or report a cancelled run.
const FakeCaller = struct {
    io: std.Io,
    answer_fn: *const fn (name: []const u8, args_json: []const u8) CallResult = answerHello,
    delay_ms: u32 = 0,
    cancelled: bool = false,
    calls: std.ArrayList(u8) = .empty,

    fn caller(fake: *FakeCaller) Caller {
        return .{ .context = fake, .call_fn = call, .cancelled_fn = isCancelled };
    }

    fn deinit(fake: *FakeCaller) void {
        fake.calls.deinit(std.testing.allocator);
    }

    fn call(context: *anyopaque, _: std.mem.Allocator, name: []const u8, args_json: []const u8) CallerError!CallResult {
        const fake: *FakeCaller = @ptrCast(@alignCast(context));
        const until = std.Io.Clock.awake.now(fake.io).toMilliseconds() + fake.delay_ms;
        while (std.Io.Clock.awake.now(fake.io).toMilliseconds() < until) {}
        fake.calls.print(std.testing.allocator, "{s} {s}\n", .{ name, args_json }) catch return error.OutOfMemory;
        return fake.answer_fn(name, args_json);
    }

    fn isCancelled(context: *anyopaque) bool {
        const fake: *FakeCaller = @ptrCast(@alignCast(context));
        return fake.cancelled;
    }

    fn answerHello(_: []const u8, _: []const u8) CallResult {
        return .{ .ok = true, .text = "hello" };
    }

    /// More than a pipe holds, so the parent's write waits on the child.
    fn answerPlainMiB(_: []const u8, _: []const u8) CallResult {
        return .{ .ok = true, .text = &plain_answer };
    }

    /// Bytes JSON escapes to six each.
    fn answerEscaped(_: []const u8, _: []const u8) CallResult {
        return .{ .ok = true, .text = &escaped_answer };
    }

    const plain_answer: [1024 * 1024]u8 = @splat('x');
    const escaped_answer: [2 * 1024 * 1024]u8 = @splat(1);
};

/// Runs `source` in a real child. A run that fails fails the test here, so a
/// test that reads its result's value sees a run that got as far as a result.
fn runForTest(fake: *FakeCaller, source: []const u8, limits: Limits) !Report {
    if (!supported) return error.SkipZigTest;
    const report = try run(std.testing.allocator, std.testing.io, source, limits, fake.caller());
    if (report.result == .failed) {
        std.debug.print("sandboxed run failed: {s}\n", .{report.result.failed});
        report.deinit(std.testing.allocator);
        return error.TestUnexpectedResult;
    }
    return report;
}

test "a sandboxed program returns its value" {
    var fake: FakeCaller = .{ .io = std.testing.io };
    defer fake.deinit();
    const report = try runForTest(&fake, "return [1, 2].map((x) => x * 2);", .{});
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("[2,4]", report.result.returned.?);
}

test "a sandboxed program can read the local time" {
    var fake: FakeCaller = .{ .io = std.testing.io };
    defer fake.deinit();
    const report = try runForTest(&fake, "return [new Date(0).getTimezoneOffset(), new Date(2020, 0, 1).getFullYear()];", .{});
    defer report.deinit(std.testing.allocator);
    const offset_end = std.mem.findScalar(u8, report.result.returned.?, ',') orelse return error.TestUnexpectedResult;
    _ = try std.fmt.parseInt(i32, report.result.returned.?[1..offset_end], 10);
    try std.testing.expectEqualStrings(",2020]", report.result.returned.?[offset_end..]);
}

test "a sandboxed program's error names what went wrong" {
    var fake: FakeCaller = .{ .io = std.testing.io };
    defer fake.deinit();
    const report = try runForTest(&fake, "return missing + 1;", .{});
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, report.result.threw, "ReferenceError") != null);
}

test "a sandboxed program has no way to reach the host" {
    var fake: FakeCaller = .{ .io = std.testing.io };
    defer fake.deinit();
    const report = try runForTest(&fake,
        \\return [typeof require, typeof process, typeof Deno, typeof fetch, typeof std, typeof os];
    , .{});
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        \\["undefined","undefined","undefined","undefined","undefined","undefined"]
    , report.result.returned.?);
}

test "a sandboxed program calls the parent's tools and logs" {
    var fake: FakeCaller = .{ .io = std.testing.io };
    defer fake.deinit();
    const report = try runForTest(&fake,
        \\const text = await tools.read_file({ path: "a.txt" });
        \\console.log("read", text.length);
        \\return [text, typeof tools.shell];
    , .{});
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("[\"hello\",\"function\"]", report.result.returned.?);
    try std.testing.expectEqualStrings("read_file {\"path\":\"a.txt\"}\n", fake.calls.items);
    try std.testing.expectEqualStrings("read 5\n", report.logs);
    try std.testing.expect(!report.logs_truncated);
}

test "a sandboxed program's failed tool call throws the tool's message" {
    const answer = struct {
        fn answer(_: []const u8, _: []const u8) CallResult {
            return .{ .ok = false, .text = "Permission denied for shell." };
        }
    }.answer;
    var fake: FakeCaller = .{ .io = std.testing.io, .answer_fn = answer };
    defer fake.deinit();
    const report = try runForTest(&fake,
        \\try { await tools.shell({ command: "rm -rf /" }); } catch (e) { return e.message; }
    , .{});
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\"Permission denied for shell.\"", report.result.returned.?);
}

test "a sandboxed program's console output is capped" {
    var fake: FakeCaller = .{ .io = std.testing.io };
    defer fake.deinit();
    const report = try runForTest(&fake, "for (let i = 0; i < 5000; i++) console.log('x'.repeat(20)); return 1;", .{});
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.logs.len <= max_log_bytes);
    try std.testing.expect(report.logs_truncated);
}

test "the sandbox applies the program's time limit" {
    var fake: FakeCaller = .{ .io = std.testing.io };
    defer fake.deinit();
    const report = try runForTest(&fake, "for (;;) {}", .{ .time_ms = 300 });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Result.timed_out, report.result);
}

test "the sandbox applies the program's heap limit" {
    var fake: FakeCaller = .{ .io = std.testing.io };
    defer fake.deinit();
    const report = try runForTest(&fake,
        \\const kept = [];
        \\for (;;) kept.push('x'.repeat(65536) + kept.length);
    , .{ .heap_bytes = 4 * 1024 * 1024 });
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, report.result.threw, "out of memory") != null);
}

test "a slow tool call doesn't trip the sandbox's watchdog" {
    // The call outlasts the program's time limit and the grace together, so
    // this passes only if the watchdog restarts after each handoff.
    var fake: FakeCaller = .{ .io = std.testing.io, .delay_ms = grace_ms + 500 };
    defer fake.deinit();
    const report = try runForTest(&fake, "await tools.read_file({}); return 'done';", .{ .time_ms = 300 });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\"done\"", report.result.returned.?);
}

test "a cancelled run stops the sandbox child" {
    var fake: FakeCaller = .{ .io = std.testing.io, .cancelled = true };
    defer fake.deinit();
    const started = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    const report = try runForTest(&fake, "for (;;) {}", .{ .time_ms = 10_000 });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(Result.cancelled, report.result);
    try std.testing.expect(std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - started < 5_000);
}

test "the sandbox child refuses a first frame over its limit" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var child = try startChild(std.testing.allocator, io, .{});
    defer child.kill(io);
    var buffer: [16]u8 = undefined;
    var writer = child.stdin.?.writerStreaming(io, &buffer);
    try writer.interface.writeInt(u32, max_run_frame_bytes + 1, .little);
    try writer.interface.flush();
    child.stdin.?.close(io);
    child.stdin = null;
    const term = try child.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = @backingInt(ChildExit.bad_frame) }, term);
}

test "the parent stops waiting for a sandbox child that never reports" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    // The child waits for a program that never comes.
    var child = try startChild(std.testing.allocator, io, .{});
    defer child.kill(io);
    var buffer: [4]u8 = undefined;
    const deadline_ms = std.Io.Clock.awake.now(io).toMilliseconds() + 300;
    try std.testing.expectError(error.DeadlinePassed, readFromChild(io, child.stdout.?, &buffer, deadline_ms, null));
}

test "a sandboxed program's tool call over the frame limit throws instead of being sent" {
    const programs = [_][]const u8{
        // Over the limit before it is escaped.
        \\const input = { data: "x".repeat(9 * 1024 * 1024) };
        \\try { await tools.read_file(input); return "sent"; } catch (e) { return e.message; }
        ,
        // Under it until the frame escapes it a second time.
        \\const input = { data: '"'.repeat(5 * 512 * 1024) };
        \\try { await tools.read_file(input); return "sent"; } catch (e) { return e.message; }
        ,
    };
    for (programs) |program| {
        var fake: FakeCaller = .{ .io = std.testing.io };
        defer fake.deinit();
        const report = try runForTest(&fake, program, .{});
        defer report.deinit(std.testing.allocator);
        try std.testing.expect(report.result == .returned);
        try std.testing.expectEqualStrings("\"" ++ call_too_large ++ "\"", report.result.returned.?);
        try std.testing.expectEqualStrings("", fake.calls.items);
    }
}

test "a reply that JSON escaping grows still reaches the program" {
    var fake: FakeCaller = .{ .io = std.testing.io, .answer_fn = FakeCaller.answerEscaped };
    defer fake.deinit();
    const report = try runForTest(&fake, "return (await tools.read_file({})).length;", .{});
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.result == .returned);
    var expected: [16]u8 = undefined;
    try std.testing.expectEqualStrings(try std.mem.print(&expected, "{d}", .{max_result_text_bytes}), report.result.returned.?);
}

test "a return value that JSON escaping grows past a frame throws a message the program can act on" {
    var fake: FakeCaller = .{ .io = std.testing.io };
    defer fake.deinit();
    const report = try runForTest(&fake, "return \"\\x01\".repeat(1200 * 1024);", .{});
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.result == .threw);
    try std.testing.expect(std.mem.find(u8, report.result.threw, "Return less") != null);
}

test "a thrown error's text is cut to fit a frame" {
    var fake: FakeCaller = .{ .io = std.testing.io };
    defer fake.deinit();
    const report = try runForTest(&fake, "throw new Error('x'.repeat(9 * 1024 * 1024));", .{});
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.result == .threw);
    try std.testing.expect(std.mem.startsWith(u8, report.result.threw, "Error: xxx"));
    try std.testing.expect(report.result.threw.len <= max_outcome_text_bytes);
}

test "the parent stops writing to a child that stops reading" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    const call = "{\"kind\":\"call\",\"tool\":\"read_file\",\"input\":\"{}\"}";
    var script_buffer: [160]u8 = undefined;
    // Sends one call, then never reads the reply.
    const script = try std.mem.print(&script_buffer, "printf '\\{o:0>3}\\000\\000\\000%s' '{s}'; exec sleep 30", .{ call.len, call });
    var fake: FakeCaller = .{ .io = io, .answer_fn = FakeCaller.answerPlainMiB };
    defer fake.deinit();
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    var parent: Parent = .{ .gpa = std.testing.allocator, .io = io, .child = &child, .limits = .{ .time_ms = 500 }, .caller = fake.caller() };
    const started_ms = std.Io.Clock.awake.now(io).toMilliseconds();
    const report = try parent.drive("return 1;");
    defer report.deinit(std.testing.allocator);
    child.kill(io);
    try std.testing.expect(std.Io.Clock.awake.now(io).toMilliseconds() - started_ms < 10_000);
    try std.testing.expect(report.result == .timed_out);
}

test "the parent does not wait on a child that keeps running" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    const outcome = "{\"kind\":\"outcome\",\"outcome\":\"returned\",\"text\":\"1\"}";
    var outcome_script_buffer: [160]u8 = undefined;
    const outcome_script = try std.mem.print(&outcome_script_buffer, "printf '\\{o:0>3}\\000\\000\\000%s' '{s}'; exec sleep 30", .{ outcome.len, outcome });
    const cases = [_]struct { script: []const u8, returned: bool, failure: []const u8 = "" }{
        // A frame header over the limit, then no body.
        .{ .script = "printf '\\377\\377\\377\\177'; exec sleep 30", .returned = false, .failure = message.bad_frame },
        // No frame at all, with stdout closed. fx kills it, and says so
        // rather than blaming the program's resources.
        .{ .script = "exec 1>&-; exec sleep 30", .returned = false, .failure = message.killed },
        // A valid outcome, then no exit.
        .{ .script = outcome_script, .returned = true },
    };
    for (cases) |case| {
        var fake: FakeCaller = .{ .io = io };
        defer fake.deinit();
        var child = try std.process.spawn(io, .{
            .argv = &.{ "/bin/sh", "-c", case.script },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        var parent: Parent = .{ .gpa = std.testing.allocator, .io = io, .child = &child, .limits = .{ .time_ms = 20_000 }, .caller = fake.caller() };
        const started_ms = std.Io.Clock.awake.now(io).toMilliseconds();
        const report = try parent.drive("return 1;");
        defer report.deinit(std.testing.allocator);
        child.kill(io);
        try std.testing.expect(std.Io.Clock.awake.now(io).toMilliseconds() - started_ms < 10_000);
        if (case.returned) {
            try std.testing.expect(report.result == .returned);
            try std.testing.expectEqualStrings("1", report.result.returned.?);
        } else {
            try std.testing.expect(report.result == .failed);
            try std.testing.expectEqualStrings(case.failure, report.result.failed);
        }
    }
}

test "the parent reads a sandbox child's frame or refuses it on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzFrame, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{\"kind\":\"outcome\",\"outcome\":\"returned\",\"text\":\"[2,4]\",\"logs\":\"a\\n\"}",
            "{\"kind\":\"outcome\",\"outcome\":\"returned\"}",
            "{\"kind\":\"outcome\",\"outcome\":\"threw\",\"text\":\"Error: x\\u001b[2J\"}",
            "{\"kind\":\"outcome\",\"outcome\":\"timed_out\",\"logs_truncated\":true}",
            "{\"kind\":\"outcome\",\"outcome\":\"unsettled\",\"text\":null}",
            "{\"kind\":\"call\",\"tool\":\"read_file\",\"input\":\"{\\\"path\\\":\\\"a\\\"}\"}",
            "{\"kind\":\"outcome\",\"outcome\":\"exploded\"}",
            "{\"kind\":\"shout\"}",
            "\xff\x00{",
        }) ++ @import("fuzz_corpus").sandbox_frame.*),
    });
}

/// The child is untrusted, so whatever bytes it sends must parse into a call
/// or an outcome, as `Parent.drive` reads them, or be refused, and any text
/// is a copy no longer than the frame it came in.
fn fuzzFrame(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    const parsed = json_decode.parseFromSlice(ChildFrame, gpa, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer parsed.deinit();
    switch (parsed.value.kind) {
        .call => {
            try std.testing.expect(parsed.value.tool.len <= bytes.len);
            try std.testing.expect(parsed.value.input.len <= bytes.len);
        },
        .outcome => {
            const report = try outcomeReport(gpa, parsed.value);
            defer report.deinit(gpa);
            try std.testing.expect(report.logs.len <= bytes.len);
            switch (report.result) {
                .returned => |json| if (json) |json_text| try std.testing.expect(json_text.len <= bytes.len),
                .threw => |thrown| try std.testing.expect(thrown.len <= bytes.len),
                .timed_out, .unsettled, .cancelled, .failed => {},
            }
        },
    }
}

test "a sandbox child that stops without an outcome gets a reason a model can act on" {
    const cases = [_]struct { term: std.process.Child.Term, reason: []const u8 }{
        .{ .term = .{ .exited = @backingInt(ChildExit.unconfined) }, .reason = message.unconfined },
        .{ .term = .{ .exited = @backingInt(ChildExit.out_of_memory) }, .reason = message.out_of_resources },
        .{ .term = .{ .exited = @backingInt(ChildExit.bad_frame) }, .reason = message.no_outcome },
        .{ .term = .{ .exited = @backingInt(ChildExit.write_failed) }, .reason = message.no_outcome },
        .{ .term = .{ .signal = .SYS }, .reason = message.refused },
        .{ .term = .{ .signal = .XCPU }, .reason = message.out_of_resources },
        .{ .term = .{ .signal = .KILL }, .reason = message.killed },
        .{ .term = .{ .signal = .SEGV }, .reason = message.crashed },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.reason, describeExit(case.term));
}

test "the sandbox child reads its limits only from well-formed arguments" {
    try std.testing.expectEqual(@as(?Limits, null), parseLimits(&.{ "1", "2", "3" }));
    try std.testing.expectEqual(@as(?Limits, null), parseLimits(&.{ "0", "2", "3", "4" }));
    try std.testing.expectEqual(@as(?Limits, null), parseLimits(&.{ "1", "2", "-3", "4" }));
    try std.testing.expectEqual(
        @as(?Limits, .{ .heap_bytes = 1, .stack_bytes = 2, .time_ms = 3, .max_calls = 4 }),
        parseLimits(&.{ "1", "2", "3", "4" }),
    );
}
