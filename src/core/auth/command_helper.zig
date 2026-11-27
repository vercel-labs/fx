//! Runs a custom connection's sign-in helper and decodes the token it prints.
//! The helper runs without a shell, under a deadline, with capped output and
//! a cancel flag. Its output holds a secret, so every copy is zeroed once it
//! is no longer needed.

const std = @import("std");
const configured_provider = @import("../config/configured_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const select_watch = @import("../shared/select_watch.zig");
const secret = @import("secret.zig");
const text_utils = @import("../shared/text_utils.zig");

pub const max_output_bytes: usize = 16 * 1024;
pub const max_stderr_bytes: usize = 4 * 1024;
pub const max_token_bytes: usize = 16 * 1024;
pub const max_headers: usize = 16;
pub const max_header_value_bytes: usize = 4 * 1024;
pub const run_timeout_ms: u32 = 30_000;

const expires_at_limit_s: i64 = 1 << 40;
const max_message_bytes: usize = 300;

pub const Header = struct { name: []const u8, value: []u8 };

pub const Output = struct {
    token: []u8,
    expires_at_s: ?i64,
    headers: []Header,

    pub fn deinit(self: *Output, alloc: std.mem.Allocator) void {
        secret.zeroAndFree(alloc, self.token);
        freeHeaders(alloc, self.headers);
        alloc.free(self.headers);
    }
};

pub const DecodeError = error{ OutOfMemory, NotJson, NotAnObject, MissingToken, BadToken, BadExpiry, BadHeaders };

/// Decodes one helper output. The caller owns the result and calls `deinit`.
pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) DecodeError!Output {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotJson,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.NotAnObject;
    const fields = parsed.value.object;
    const token = try decodeToken(alloc, fields);
    errdefer secret.zeroAndFree(alloc, token);
    const expires_at_s = try decodeExpiry(fields);
    const headers = try decodeHeaders(alloc, fields);
    return .{ .token = token, .expires_at_s = expires_at_s, .headers = headers };
}

fn decodeToken(alloc: std.mem.Allocator, fields: std.json.ObjectMap) DecodeError![]u8 {
    const value = fields.get("token") orelse return error.MissingToken;
    if (value != .string) return error.MissingToken;
    if (!isTokenText(value.string)) return error.BadToken;
    return alloc.dupe(u8, value.string);
}

fn isTokenText(token: []const u8) bool {
    if (token.len == 0 or token.len > max_token_bytes) return false;
    for (token) |byte| {
        if (byte < 0x21 or byte > 0x7e) return false;
    }
    return true;
}

fn decodeExpiry(fields: std.json.ObjectMap) DecodeError!?i64 {
    const value = fields.get("expires_at") orelse return null;
    if (value != .integer) return error.BadExpiry;
    if (value.integer <= 0 or value.integer >= expires_at_limit_s) return error.BadExpiry;
    return value.integer;
}

fn decodeHeaders(alloc: std.mem.Allocator, fields: std.json.ObjectMap) DecodeError![]Header {
    const value = fields.get("headers") orelse return alloc.alloc(Header, 0);
    if (value != .object) return error.BadHeaders;
    const object = value.object;
    if (object.count() > max_headers) return error.BadHeaders;
    const headers = try alloc.alloc(Header, object.count());
    var filled: usize = 0;
    errdefer {
        freeHeaders(alloc, headers[0..filled]);
        alloc.free(headers);
    }
    var entries = object.iterator();
    while (entries.next()) |entry| {
        headers[filled] = try decodeHeader(alloc, entry.key_ptr.*, entry.value_ptr.*, headers[0..filled]);
        filled += 1;
    }
    return headers;
}

fn decodeHeader(alloc: std.mem.Allocator, name: []const u8, value: std.json.Value, earlier: []const Header) DecodeError!Header {
    if (!isHeaderName(name) or hasHeaderNamed(earlier, name)) return error.BadHeaders;
    if (value != .string or !isHeaderValue(value.string)) return error.BadHeaders;
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    const owned_value = try alloc.dupe(u8, value.string);
    return .{ .name = owned_name, .value = owned_value };
}

fn isHeaderName(name: []const u8) bool {
    if (name.len == 0 or name.len > configured_provider.max_header_name_bytes) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
    }
    return !configured_provider.is_reserved_header(name);
}

fn hasHeaderNamed(headers: []const Header, name: []const u8) bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return true;
    }
    return false;
}

fn isHeaderValue(value: []const u8) bool {
    if (value.len > max_header_value_bytes) return false;
    for (value) |byte| {
        if (byte < 0x20 or byte > 0x7e) return false;
    }
    return true;
}

fn freeHeaders(alloc: std.mem.Allocator, headers: []Header) void {
    for (headers) |header| {
        alloc.free(header.name);
        secret.zeroAndFree(alloc, header.value);
    }
}

pub const Failure = enum { spawn_failed, timed_out, cancelled, exited, output_too_large, unreadable_output };

pub const Result = union(enum) {
    ok: Output,
    failed: struct { failure: Failure, message: []u8 },

    pub fn deinit(self: *Result, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*output| output.deinit(alloc),
            .failed => |failed| alloc.free(failed.message),
        }
    }
};

/// Runs `argv` without a shell and returns the decoded token, or why none came.
/// The caller owns the result and calls `deinit`. A null `cwd` inherits fx's
/// directory, and a null `cancel_flag` means the run cannot be cancelled.
pub fn run(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    cancel_flag: ?*const std.atomic.Value(bool),
    timeout_ms: u32,
) std.mem.Allocator.Error!Result {
    const spawn: Spawn = .{
        .alloc = alloc,
        .argv = argv,
        .cwd = cwd,
        .timeout = timeoutOf(timeout_ms),
    };
    const outcome = if (cancel_flag) |flag|
        runCancellable(&spawn, flag)
    else
        ProcessOutcome{ .finished = runChild(&spawn) };
    return switch (outcome) {
        .finished => |result| finishRun(alloc, timeout_ms, result),
        .cancelled => failedWith(alloc, .cancelled, "the helper was cancelled", .{}),
        .unavailable => |err| failedWith(alloc, .spawn_failed, "the helper could not be run: {s}", .{@errorName(err)}),
    };
}

const Spawn = struct {
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    timeout: std.Io.Timeout,
};

fn timeoutOf(timeout_ms: u32) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } };
}

const ProcessOutcome = union(enum) {
    finished: std.process.RunError!std.process.RunResult,
    cancelled,
    unavailable: std.Io.ConcurrentError,
};

const CancelCondition = struct {
    flag: *const std.atomic.Value(bool),

    pub fn cancelled(condition: CancelCondition) bool {
        return condition.flag.load(.acquire);
    }

    pub fn expired(_: CancelCondition, _: std.Io) bool {
        return false;
    }
};

const CancelWatch = select_watch.Watch(CancelCondition);

const RunEvent = union(enum) {
    process: std.process.RunError!std.process.RunResult,
    watch: std.Io.Cancelable!select_watch.Outcome,
};

fn runCancellable(spawn: *const Spawn, flag: *const std.atomic.Value(bool)) ProcessOutcome {
    const io = io_mod.getIo();
    var watch: CancelWatch = .{};
    var select_buffer: [2]RunEvent = undefined;
    var select: std.Io.Select(RunEvent) = .init(io, &select_buffer);
    select.concurrent(.watch, CancelWatch.run, .{
        &watch,
        select.io,
        CancelCondition{ .flag = flag },
    }) catch |err| return .{ .unavailable = err };
    select.concurrent(.process, runChild, .{spawn}) catch |err| {
        watch.finish(&select);
        return .{ .unavailable = err };
    };
    const event = select.await() catch {
        abandonRun(spawn.alloc, &select, &watch);
        return .cancelled;
    };
    switch (event) {
        .process => |result| {
            watch.finish(&select);
            return .{ .finished = result };
        },
        .watch => {
            abandonRun(spawn.alloc, &select, &watch);
            return .cancelled;
        },
    }
}

/// A late result can hold the token, so its output is zeroed before it is freed.
fn abandonRun(alloc: std.mem.Allocator, select: *std.Io.Select(RunEvent), watch: *CancelWatch) void {
    watch.stop(select.io);
    while (select.cancel()) |item| switch (item) {
        .process => |result| if (result) |late| {
            secret.zeroAndFree(alloc, late.stdout);
            alloc.free(late.stderr);
        } else |_| {},
        .watch => {},
    };
}

fn runChild(spawn: *const Spawn) std.process.RunError!std.process.RunResult {
    return std.process.run(spawn.alloc, io_mod.getIo(), .{
        .argv = spawn.argv,
        .cwd = childCwd(spawn.cwd),
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_stderr_bytes),
        .timeout = spawn.timeout,
    });
}

fn childCwd(cwd: ?[]const u8) std.process.Child.Cwd {
    const path = cwd orelse return .inherit;
    return .{ .path = path };
}

fn finishRun(
    alloc: std.mem.Allocator,
    timeout_ms: u32,
    result: std.process.RunError!std.process.RunResult,
) std.mem.Allocator.Error!Result {
    const process = result catch |err| return runError(alloc, timeout_ms, err);
    defer alloc.free(process.stderr);
    defer secret.zeroAndFree(alloc, process.stdout);
    return switch (process.term) {
        .exited => |status| if (status == 0)
            decodeStdout(alloc, process.stdout)
        else
            exitFailure(alloc, status, process.stderr),
        .signal, .stopped => |signal| failedWith(alloc, .exited, "the helper was stopped by signal {d}", .{@backingInt(signal)}),
        .unknown => failedWith(alloc, .exited, "the helper ended abnormally", .{}),
    };
}

fn decodeStdout(alloc: std.mem.Allocator, stdout: []const u8) std.mem.Allocator.Error!Result {
    const output = decode(alloc, stdout) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failedWith(alloc, .unreadable_output, "the helper did not print a valid token: {s}", .{@errorName(err)}),
    };
    return .{ .ok = output };
}

fn exitFailure(alloc: std.mem.Allocator, status: u8, stderr: []const u8) std.mem.Allocator.Error!Result {
    debug_trace.logf("command_helper", "helper exited status={d}", .{status});
    const line = firstLine(stderr);
    if (line.len == 0) return failedWith(alloc, .exited, "the helper exited with status {d}", .{status});
    return failedWith(alloc, .exited, "the helper exited with status {d}: {f}", .{ status, text_utils.terminalSafe(line) });
}

fn firstLine(stderr: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, stderr, '\n') orelse stderr.len;
    return std.mem.trim(u8, stderr[0..end], " \t\r");
}

/// `std.process.run` returns spawn and pipe-read errors in one set, and some
/// names appear in both, so any other error counts as the helper not running.
fn runError(alloc: std.mem.Allocator, timeout_ms: u32, err: std.process.RunError) std.mem.Allocator.Error!Result {
    return switch (err) {
        error.StreamTooLong => failedWith(alloc, .output_too_large, "the helper printed more output than fx reads", .{}),
        error.Timeout => failedWith(alloc, .timed_out, "the helper did not finish within {d} ms", .{timeout_ms}),
        error.OutOfMemory => error.OutOfMemory,
        else => failedWith(alloc, .spawn_failed, "the helper could not be run: {s}", .{@errorName(err)}),
    };
}

fn failedWith(alloc: std.mem.Allocator, failure: Failure, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!Result {
    debug_trace.logf("command_helper", "run failed kind={s}", .{@tagName(failure)});
    const full = try alloc.print(fmt, args);
    defer alloc.free(full);
    const message = try alloc.dupe(u8, text_utils.utf8PrefixByBytes(full, max_message_bytes));
    return .{ .failed = .{ .failure = failure, .message = message } };
}

fn expectWithinLimits(output: Output) !void {
    try std.testing.expect(output.token.len >= 1 and output.token.len <= max_token_bytes);
    for (output.token) |byte| try std.testing.expect(byte >= 0x21 and byte <= 0x7e);
    try std.testing.expect(output.headers.len <= max_headers);
    for (output.headers) |header| {
        try std.testing.expect(!configured_provider.is_reserved_header(header.name));
        try std.testing.expect(header.value.len <= max_header_value_bytes);
        for (header.value) |byte| try std.testing.expect(byte >= 0x20 and byte <= 0x7e);
    }
}

fn expectRefused(bytes: []const u8, expected: DecodeError) !void {
    var output = decode(std.testing.allocator, bytes) catch |err| {
        try std.testing.expectEqual(expected, err);
        return;
    };
    output.deinit(std.testing.allocator);
    return error.TestUnexpectedResult;
}

fn tokenJson(buffer: []u8, token_len: usize) []const u8 {
    const prefix = "{\"token\":\"";
    const suffix = "\"}";
    @memcpy(buffer[0..prefix.len], prefix);
    @memset(buffer[prefix.len..][0..token_len], 'a');
    @memcpy(buffer[prefix.len + token_len ..][0..suffix.len], suffix);
    return buffer[0 .. prefix.len + token_len + suffix.len];
}

fn headersJson(comptime count: usize) []const u8 {
    return comptime blk: {
        var text: []const u8 = "{\"token\":\"t\",\"headers\":{";
        for (0..count) |i| {
            if (i > 0) text = text ++ ",";
            text = text ++ std.fmt.comptimePrint("\"X-H{d}\":\"v\"", .{i});
        }
        break :blk text ++ "}}";
    };
}

fn expectFailure(result: *Result, expected: Failure) ![]const u8 {
    switch (result.*) {
        .ok => return error.TestUnexpectedResult,
        .failed => |failed| {
            try std.testing.expectEqual(expected, failed.failure);
            return failed.message;
        },
    }
}

const test_timeout_ms: u32 = 5_000;

test "decode reads a minimal helper output" {
    var output = try decode(std.testing.allocator, "{\"token\":\"t\"}");
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("t", output.token);
    try std.testing.expectEqual(@as(?i64, null), output.expires_at_s);
    try std.testing.expectEqual(@as(usize, 0), output.headers.len);
}

test "decode reads expiry and headers" {
    var output = try decode(std.testing.allocator, "{\"token\":\"abc\",\"expires_at\":1700000000,\"headers\":{\"X-Team\":\"blue\"}}");
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("abc", output.token);
    try std.testing.expectEqual(@as(?i64, 1700000000), output.expires_at_s);
    try std.testing.expectEqual(@as(usize, 1), output.headers.len);
    try std.testing.expectEqualStrings("X-Team", output.headers[0].name);
    try std.testing.expectEqualStrings("blue", output.headers[0].value);
    try expectWithinLimits(output);
}

test "decode ignores fields it does not use" {
    var output = try decode(std.testing.allocator, " {\"token\":\"t\",\"model\":\"m\",\"nested\":{\"a\":[1,2]}}\n");
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("t", output.token);
}

test "decode accepts a token of exactly max_token_bytes" {
    var json: [max_token_bytes + 16]u8 = undefined;
    var output = try decode(std.testing.allocator, tokenJson(&json, max_token_bytes));
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(max_token_bytes, output.token.len);
}

test "decode accepts the most headers allowed" {
    var output = try decode(std.testing.allocator, headersJson(max_headers));
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(max_headers, output.headers.len);
}

test "decode refuses malformed helper output" {
    try expectRefused("", error.NotJson);
    try expectRefused("token", error.NotJson);
    try expectRefused("{\"token\":\"t\"} x", error.NotJson);
    try expectRefused("[\"t\"]", error.NotAnObject);
    try expectRefused("\"t\"", error.NotAnObject);
    try expectRefused("{}", error.MissingToken);
    try expectRefused("{\"token\":5}", error.MissingToken);
    try expectRefused("{\"token\":\"\"}", error.BadToken);
    try expectRefused("{\"token\":\"a b\"}", error.BadToken);
    try expectRefused("{\"token\":\"a\\u0001\"}", error.BadToken);
    try expectRefused("{\"token\":\"t\",\"headers\":[]}", error.BadHeaders);
    try expectRefused("{\"token\":\"t\",\"headers\":{\"Authorization\":\"x\"}}", error.BadHeaders);
    try expectRefused("{\"token\":\"t\",\"headers\":{\"content-TYPE\":\"x\"}}", error.BadHeaders);
    try expectRefused("{\"token\":\"t\",\"headers\":{\"X A\":\"x\"}}", error.BadHeaders);
    try expectRefused("{\"token\":\"t\",\"headers\":{\"X-A\":5}}", error.BadHeaders);
    try expectRefused("{\"token\":\"t\",\"headers\":{\"X-A\":\"a\\u0001\"}}", error.BadHeaders);
    try expectRefused("{\"token\":\"t\",\"headers\":{\"X-A\":\"1\",\"x-a\":\"2\"}}", error.BadHeaders);
    try expectRefused(headersJson(max_headers + 1), error.BadHeaders);
    try expectRefused("{\"token\":\"t\",\"expires_at\":-1}", error.BadExpiry);
    try expectRefused("{\"token\":\"t\",\"expires_at\":0}", error.BadExpiry);
    try expectRefused("{\"token\":\"t\",\"expires_at\":1099511627776}", error.BadExpiry);
    try expectRefused("{\"token\":\"t\",\"expires_at\":1.5}", error.BadExpiry);
    try expectRefused("{\"token\":\"t\",\"expires_at\":\"1700000000\"}", error.BadExpiry);
}

test "decode refuses a token over max_token_bytes" {
    var json: [max_token_bytes + 16]u8 = undefined;
    try expectRefused(tokenJson(&json, max_token_bytes + 1), error.BadToken);
}

test "run returns the token a helper prints" {
    var result = try run(std.testing.allocator, &.{ "/bin/sh", "-c", "printf '%s' '{\"token\":\"tok-123\"}'" }, null, null, test_timeout_ms);
    defer result.deinit(std.testing.allocator);
    switch (result) {
        .ok => |output| try std.testing.expectEqualStrings("tok-123", output.token),
        .failed => return error.TestUnexpectedResult,
    }
}

test "run reports a non-zero exit with the helper's first stderr line" {
    var result = try run(std.testing.allocator, &.{ "/bin/sh", "-c", "printf 'no session\\n' >&2; exit 3" }, null, null, test_timeout_ms);
    defer result.deinit(std.testing.allocator);
    const message = try expectFailure(&result, .exited);
    try std.testing.expect(std.mem.find(u8, message, "status 3: no session") != null);
}

test "run keeps escape sequences out of a failure message" {
    var result = try run(std.testing.allocator, &.{ "/bin/sh", "-c", "printf 'bad\\033[31mred\\n' >&2; exit 2" }, null, null, test_timeout_ms);
    defer result.deinit(std.testing.allocator);
    const message = try expectFailure(&result, .exited);
    try std.testing.expect(std.mem.findScalar(u8, message, 0x1b) == null);
    try std.testing.expect(std.mem.find(u8, message, "status 2") != null);
}

test "run stops a helper that prints more than max_output_bytes" {
    var result = try run(std.testing.allocator, &.{ "/bin/sh", "-c", "head -c 20000 /dev/zero" }, null, null, test_timeout_ms);
    defer result.deinit(std.testing.allocator);
    _ = try expectFailure(&result, .output_too_large);
}

test "run stops a helper that outlives its timeout" {
    const started_ms = io_mod.milliTimestamp();
    var result = try run(std.testing.allocator, &.{ "sleep", "5" }, null, null, 200);
    defer result.deinit(std.testing.allocator);
    _ = try expectFailure(&result, .timed_out);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 2_000);
}

test "run reports a helper that cannot be started" {
    var result = try run(std.testing.allocator, &.{"fx-missing-sign-in-helper"}, null, null, test_timeout_ms);
    defer result.deinit(std.testing.allocator);
    _ = try expectFailure(&result, .spawn_failed);
}

test "run refuses a helper that prints no token" {
    var result = try run(std.testing.allocator, &.{ "/bin/sh", "-c", "printf garbage" }, null, null, test_timeout_ms);
    defer result.deinit(std.testing.allocator);
    _ = try expectFailure(&result, .unreadable_output);
}

test "cancel stops a running helper" {
    const Canceller = struct {
        flag: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            io_mod.sleep(100 * std.time.ns_per_ms);
            self.flag.store(true, .release);
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    var canceller = Canceller{ .flag = &cancel };
    const thread = try std.Thread.spawn(.{}, Canceller.run, .{&canceller});
    const started_ms = io_mod.milliTimestamp();
    var result = try run(std.testing.allocator, &.{ "/bin/sh", "-c", "exec sleep 5" }, null, &cancel, test_timeout_ms);
    thread.join();
    defer result.deinit(std.testing.allocator);
    _ = try expectFailure(&result, .cancelled);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 2_000);
}

test "command helper output decodes or is refused on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzDecode, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{\"token\":\"t\"}",
            "{\"token\":\"abc\",\"expires_at\":1700000000,\"headers\":{\"X-Team\":\"blue\"}}",
            "{\"token\":\"abc\",\"model\":\"m\",\"nested\":[1,{\"a\":null}]}",
            "{\"token\":\"a b\"}",
            "{\"token\":\"t\",\"headers\":{\"Authorization\":\"x\"}}",
            "{\"token\":\"t\",\"expires_at\":-1}",
            "\xff\x00{",
        }) ++ @import("fuzz_corpus").command_auth_output.*),
    });
}

fn fuzzDecode(_: void, smith: *std.testing.Smith) anyerror!void {
    const alloc = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    var output = decode(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer output.deinit(alloc);
    try expectWithinLimits(output);
}
