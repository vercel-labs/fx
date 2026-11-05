//! Runs model-written JavaScript in a separate, confined fx process, so a bug
//! in the engine can crash or hang only that process. The parent starts
//! `fx __fx_sandbox__` with an empty environment and sends it the program.
//! The child confines itself (`confine.zig`) before it reads anything, runs
//! the program in the embedded engine, and sends back one outcome. The parent
//! kills a child that is still running past the program's time limit and a
//! short grace.
//!
//! Each frame on the pipes is a u32 little-endian length followed by that
//! many bytes: the program's source from the parent, and one JSON outcome
//! from the child. The limits travel as arguments, because the child needs
//! them before it confines itself and reads its first frame.

const std = @import("std");
const engine = @import("js_engine");
const confine = @import("confine.zig");
const json_decode = @import("../shared/json_decode.zig");
const self_exe = @import("../shared/self_exe.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");

/// Whether code mode can run here. Without a sandbox it never runs.
pub const supported = confine.supported;

pub const Limits = engine.Limits;

/// The hidden first argument that makes fx the sandbox child. Three
/// arguments follow it: heap bytes, stack bytes, and time in milliseconds.
const child_argument = "__fx_sandbox__";

/// Largest program the parent sends.
const max_source_bytes = 1024 * 1024;
/// Largest outcome the child sends back.
const max_outcome_bytes = 8 * 1024 * 1024;
/// The most text an outcome carries. One byte escapes to at most six in JSON,
/// so the outcome's frame fits however its text escapes.
const max_outcome_text_bytes = (max_outcome_bytes - 1024) / 6;
/// How long past the program's time limit the parent waits for the child to
/// start, report, and exit.
const grace_ms = 2000;

/// How the child exits. Only `reported` means an outcome frame was sent.
const ChildExit = enum(u8) {
    reported = 0,
    bad_arguments = 2,
    unconfined = 3,
    bad_frame = 4,
    out_of_memory = 5,
    write_failed = 6,
};

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
    /// The child stopped without reporting an outcome. The text says why,
    /// in words a model can act on.
    failed: []const u8,

    pub fn deinit(result: Result, gpa: std.mem.Allocator) void {
        switch (result) {
            .returned => |json| if (json) |text| gpa.free(text),
            .threw => |text| gpa.free(text),
            .timed_out, .unsettled, .failed => {},
        }
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
    const bad_outcome = "The sandbox process sent an outcome fx could not read.";
    /// The child's outcome when the size message itself can't be formatted.
    const return_too_large = "The return value is too large to send back. Return less, such as a summary or the first items.";
};

/// The child's outcome frame.
const OutcomeFrame = struct {
    outcome: enum { returned, threw, timed_out, unsettled },
    text: ?[]const u8 = null,
};

/// Runs `source` in a fresh sandbox child and waits for its outcome.
pub fn run(gpa: std.mem.Allocator, io: std.Io, source: []const u8, limits: Limits) RunError!Result {
    if (!supported) return .{ .failed = message.unsupported };
    if (source.len > max_source_bytes) return .{ .failed = message.too_large };
    var child = startChild(gpa, io, limits) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("code_mode", "sandbox process did not start err={t}", .{err});
            return .{ .failed = message.no_start };
        },
    };
    // Kills and reaps the child, so a child that keeps running after its
    // outcome or after a bad frame can't hold the parent. Idempotent, and
    // does nothing once `wait` has returned.
    defer child.kill(io);
    return finish(gpa, io, &child, source, limits);
}

/// Sends `source` to a started child and reads its outcome. The caller kills
/// the child afterwards.
fn finish(gpa: std.mem.Allocator, io: std.Io, child: *std.process.Child, source: []const u8, limits: Limits) RunError!Result {
    sendSource(io, child, source);
    const deadline_ms = std.Io.Clock.awake.now(io).toMilliseconds() + limits.time_ms + grace_ms;
    const frame = awaitFrame(gpa, io, child.stdout.?, deadline_ms) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DeadlinePassed => {
            debug_trace.logf("code_mode", "killed sandbox process still running grace_ms={d} past time_ms={d}", .{ grace_ms, limits.time_ms });
            return .timed_out;
        },
        error.FrameTooLarge => {
            debug_trace.logf("code_mode", "stopped sandbox process that sent a frame over max_bytes={d}", .{max_outcome_bytes});
            return .{ .failed = message.bad_outcome };
        },
        error.EndOfStream, error.ReadFailed => return .{ .failed = stopAndDescribe(io, child) },
    };
    defer gpa.free(frame);
    return parseOutcome(gpa, frame);
}

/// Why a child that sent no outcome stopped. A child that is still running,
/// such as one that closed its stdout, would block `wait` forever, so it is
/// killed first. A child already exiting keeps the status it exited with.
fn stopAndDescribe(io: std.Io, child: *std.process.Child) []const u8 {
    if (child.id) |pid| std.posix.kill(pid, .KILL) catch {};
    const term = child.wait(io) catch return message.no_outcome;
    debug_trace.logf("code_mode", "sandbox process stopped without an outcome term={f}", .{term});
    return describeExit(term);
}

fn startChild(gpa: std.mem.Allocator, io: std.Io, limits: Limits) !std.process.Child {
    const exe = try self_exe.pathForReexec(gpa);
    defer gpa.free(exe);
    var heap_buffer: [24]u8 = undefined;
    var stack_buffer: [24]u8 = undefined;
    var time_buffer: [24]u8 = undefined;
    const argv = [_][]const u8{
        exe,
        child_argument,
        try std.mem.print(&heap_buffer, "{d}", .{limits.heap_bytes}),
        try std.mem.print(&stack_buffer, "{d}", .{limits.stack_bytes}),
        try std.mem.print(&time_buffer, "{d}", .{limits.time_ms}),
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

/// Sends the program and closes the child's stdin. A failed write means the
/// child already exited, and its exit status says why.
fn sendSource(io: std.Io, child: *std.process.Child, source: []const u8) void {
    const stdin = child.stdin.?;
    var buffer: [4096]u8 = undefined;
    var writer = stdin.writerStreaming(io, &buffer);
    writeFrame(&writer.interface, source) catch |err| {
        debug_trace.logf("code_mode", "sending the program to the sandbox process failed err={t}", .{err});
    };
    stdin.close(io);
    child.stdin = null;
}

const AwaitError = error{ OutOfMemory, DeadlinePassed, EndOfStream, ReadFailed, FrameTooLarge };

/// Reads one frame from the child, giving up at `deadline_ms` on the awake
/// clock. The caller owns the returned bytes.
fn awaitFrame(gpa: std.mem.Allocator, io: std.Io, file: std.Io.File, deadline_ms: i64) AwaitError![]u8 {
    var header: [4]u8 = undefined;
    try readBefore(io, file, &header, deadline_ms);
    const len = std.mem.readInt(u32, &header, .little);
    if (len > max_outcome_bytes) return error.FrameTooLarge;
    const payload = try gpa.alloc(u8, len);
    errdefer gpa.free(payload);
    try readBefore(io, file, payload, deadline_ms);
    return payload;
}

fn readBefore(io: std.Io, file: std.Io.File, buffer: []u8, deadline_ms: i64) AwaitError!void {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const remaining = deadline_ms - std.Io.Clock.awake.now(io).toMilliseconds();
        if (remaining <= 0) return error.DeadlinePassed;
        var fds = [_]std.posix.pollfd{.{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, @intCast(@min(remaining, std.math.maxInt(i32)))) catch return error.ReadFailed;
        if (ready == 0) continue;
        const n = std.posix.read(file.handle, buffer[filled..]) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        filled += n;
    }
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

fn parseOutcome(gpa: std.mem.Allocator, frame: []const u8) RunError!Result {
    const parsed = json_decode.parseFromSlice(OutcomeFrame, gpa, frame, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failed = message.bad_outcome },
    };
    defer parsed.deinit();
    const text = parsed.value.text;
    return switch (parsed.value.outcome) {
        .returned => .{ .returned = if (text) |json| try gpa.dupe(u8, json) else null },
        .threw => .{ .threw = try gpa.dupe(u8, text orelse "") },
        .timed_out => .timed_out,
        .unsettled => .unsettled,
    };
}

/// Whether this process was started as the sandbox child.
pub fn isChildInvocationRaw(raw_args: []const [*:0]const u8) bool {
    return raw_args.len == 5 and std.mem.eql(u8, std.mem.sliceTo(raw_args[1], 0), child_argument);
}

/// The sandbox child's whole life, from `mainC` before any other startup
/// work. Returns the process exit code.
pub fn runChild(gpa: std.mem.Allocator, io: std.Io, raw_args: []const [*:0]const u8) u8 {
    const limits = parseLimits(raw_args[2..]) orelse return @backingInt(ChildExit.bad_arguments);
    confine.confine(.{
        .address_space_bytes = addressSpaceBytes(limits),
        .cpu_seconds = limits.time_ms / 1000 + 2,
    }) catch return @backingInt(ChildExit.unconfined);

    var in_buffer: [4096]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(io, &in_buffer);
    const source = readFrame(gpa, &in.interface, max_source_bytes) catch return @backingInt(ChildExit.bad_frame);
    defer gpa.free(source);

    const outcome = engine.run(gpa, io, source, limits) catch return @backingInt(ChildExit.out_of_memory);
    defer outcome.deinit(gpa);
    var out_buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    writeOutcome(gpa, &out.interface, outcome) catch |err| return switch (err) {
        error.OutOfMemory => @backingInt(ChildExit.out_of_memory),
        error.WriteFailed => @backingInt(ChildExit.write_failed),
    };
    return @backingInt(ChildExit.reported);
}

fn parseLimits(args: []const [*:0]const u8) ?Limits {
    if (args.len != 3) return null;
    const heap_bytes = std.fmt.parseInt(usize, std.mem.sliceTo(args[0], 0), 10) catch return null;
    const stack_bytes = std.fmt.parseInt(usize, std.mem.sliceTo(args[1], 0), 10) catch return null;
    const time_ms = std.fmt.parseInt(u32, std.mem.sliceTo(args[2], 0), 10) catch return null;
    if (heap_bytes == 0 or stack_bytes == 0 or time_ms == 0) return null;
    return .{ .heap_bytes = heap_bytes, .stack_bytes = stack_bytes, .time_ms = time_ms };
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

fn writeOutcome(gpa: std.mem.Allocator, writer: *std.Io.Writer, outcome: engine.Outcome) error{ OutOfMemory, WriteFailed }!void {
    var too_large_buffer: [160]u8 = undefined;
    const frame: OutcomeFrame = switch (outcome) {
        .returned => |json| if (json != null and json.?.len > max_outcome_text_bytes) .{
            .outcome = .threw,
            .text = std.mem.print(&too_large_buffer, "The return value is {d} bytes as JSON, over the {d}-byte limit. Return less, such as a summary or the first items.", .{ json.?.len, max_outcome_text_bytes }) catch message.return_too_large,
        } else .{ .outcome = .returned, .text = json },
        .threw => |text| .{ .outcome = .threw, .text = text_utils.utf8PrefixByBytes(text, max_outcome_text_bytes) },
        .timed_out => .{ .outcome = .timed_out },
        .unsettled => .{ .outcome = .unsettled },
    };
    var json: std.Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    std.json.Stringify.value(frame, .{}, &json.writer) catch return error.OutOfMemory;
    try writeFrame(writer, json.written());
}

fn runForTest(source: []const u8, limits: Limits) !Result {
    if (!supported) return error.SkipZigTest;
    const result = try run(std.testing.allocator, std.testing.io, source, limits);
    switch (result) {
        .failed => |text| std.debug.print("sandboxed run failed: {s}\n", .{text}),
        else => {},
    }
    return result;
}

test "a sandboxed program returns its value" {
    const result = try runForTest("return [1, 2].map((x) => x * 2);", .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("[2,4]", result.returned.?);
}

test "a sandboxed program's error names what went wrong" {
    const result = try runForTest("return missing + 1;", .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, result.threw, "ReferenceError") != null);
}

test "a sandboxed program has no way to reach the host" {
    const result = try runForTest(
        \\return [typeof require, typeof process, typeof Deno, typeof fetch, typeof std, typeof os];
    , .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        \\["undefined","undefined","undefined","undefined","undefined","undefined"]
    , result.returned.?);
}

test "the sandbox applies the program's time limit" {
    const result = try runForTest("for (;;) {}", .{ .time_ms = 300 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Result.timed_out, result);
}

test "the sandbox applies the program's heap limit" {
    const result = try runForTest(
        \\const kept = [];
        \\for (;;) kept.push('x'.repeat(65536) + kept.length);
    , .{ .heap_bytes = 4 * 1024 * 1024 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, result.threw, "out of memory") != null);
}

test "a return value that JSON escaping grows past a frame throws a message the program can act on" {
    const result = try runForTest("return \"\\x01\".repeat(1200 * 1024);", .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .threw);
    try std.testing.expect(std.mem.find(u8, result.threw, "Return less") != null);
}

test "a thrown error's text is cut to fit a frame" {
    const result = try runForTest("throw new Error('x'.repeat(9 * 1024 * 1024));", .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .threw);
    try std.testing.expect(std.mem.startsWith(u8, result.threw, "Error: xxx"));
    try std.testing.expect(result.threw.len <= max_outcome_text_bytes);
}

test "the sandbox child refuses a frame over its limit" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    var child = try startChild(std.testing.allocator, io, .{});
    defer child.kill(io);
    var buffer: [16]u8 = undefined;
    var writer = child.stdin.?.writerStreaming(io, &buffer);
    try writer.interface.writeInt(u32, max_source_bytes + 1, .little);
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
    const deadline_ms = std.Io.Clock.awake.now(io).toMilliseconds() + 300;
    try std.testing.expectError(error.DeadlinePassed, awaitFrame(std.testing.allocator, io, child.stdout.?, deadline_ms));
}

test "the parent does not wait on a child that keeps running" {
    if (!supported) return error.SkipZigTest;
    const io = std.testing.io;
    const outcome = "{\"outcome\":\"returned\",\"text\":\"1\"}";
    var outcome_script_buffer: [128]u8 = undefined;
    const outcome_script = try std.mem.print(&outcome_script_buffer, "printf '\\{o:0>3}\\000\\000\\000%s' '{s}'; exec sleep 30", .{ outcome.len, outcome });
    const cases = [_]struct { script: []const u8, returned: bool, failure: []const u8 = "" }{
        // A frame header over the limit, then no body.
        .{ .script = "printf '\\377\\377\\377\\177'; exec sleep 30", .returned = false, .failure = message.bad_outcome },
        // No frame at all, with stdout closed. fx kills it, and says so
        // rather than blaming the program's resources.
        .{ .script = "exec 1>&-; exec sleep 30", .returned = false, .failure = message.killed },
        // A valid outcome, then no exit.
        .{ .script = outcome_script, .returned = true },
    };
    for (cases) |case| {
        var child = try std.process.spawn(io, .{
            .argv = &.{ "/bin/sh", "-c", case.script },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        const started_ms = std.Io.Clock.awake.now(io).toMilliseconds();
        const result = try finish(std.testing.allocator, io, &child, "return 1;", .{ .time_ms = 20_000 });
        defer result.deinit(std.testing.allocator);
        child.kill(io);
        try std.testing.expect(std.Io.Clock.awake.now(io).toMilliseconds() - started_ms < 10_000);
        if (case.returned) {
            try std.testing.expect(result == .returned);
            try std.testing.expectEqualStrings("1", result.returned.?);
        } else {
            try std.testing.expect(result == .failed);
            try std.testing.expectEqualStrings(case.failure, result.failed);
        }
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
    try std.testing.expectEqual(@as(?Limits, null), parseLimits(&.{ "1", "2" }));
    try std.testing.expectEqual(@as(?Limits, null), parseLimits(&.{ "0", "2", "3" }));
    try std.testing.expectEqual(@as(?Limits, null), parseLimits(&.{ "1", "2", "-3" }));
    try std.testing.expectEqual(@as(?Limits, .{ .heap_bytes = 1, .stack_bytes = 2, .time_ms = 3 }), parseLimits(&.{ "1", "2", "3" }));
}
