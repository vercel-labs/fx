const std = @import("std");
const builtin = @import("builtin");
const host = @import("host.zig");
const native_secret_store = @import("native_secret_store.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const child_wait = @import("../shared/child_wait.zig");

pub const clipboard = host.Clipboard{
    .copy_fn = copyToClipboard,
    .copy_file_fn = copy_file_to_clipboard,
    .read_text_fn = read_clipboard_text,
};

pub const secret_store = native_secret_store.provider;

fn copyToClipboard(_: ?*anyopaque, text: []const u8) host.ClipboardError!bool {
    const argv = clipboardCommand(builtin.target.os.tag) orelse return false;
    const io = io_mod.getIo();
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        debug_trace.logf("host", "clipboard copy spawn failed err={s}", .{@errorName(err)});
        return error.CopyFailed;
    };
    defer child.kill(io);

    if (child.stdin) |*stdin| {
        stdin.writeStreamingAll(io, text) catch |err| {
            stdin.close(io);
            child.stdin = null;
            debug_trace.logf("host", "clipboard copy write failed err={s}", .{@errorName(err)});
            return error.CopyFailed;
        };
        stdin.close(io);
        child.stdin = null;
    } else {
        debug_trace.logf("host", "clipboard copy failed reason=stdin_unavailable", .{});
        return error.CopyFailed;
    }

    const term = child.wait(io) catch |err| {
        debug_trace.logf("host", "clipboard copy wait failed err={s}", .{@errorName(err)});
        return error.CopyFailed;
    };
    if (!copySucceeded(term)) {
        logUnsuccessfulTerm("copy", term);
        return error.CopyFailed;
    }
    return true;
}

const ClipboardProcessResult = struct {
    term: std.process.Child.Term,
    stderr: []u8,
};

fn collect_clipboard_process_output(
    alloc: std.mem.Allocator,
    child: *std.process.Child,
    deadline: std.Io.Clock.Timestamp,
) std.process.RunError![]u8 {
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io_mod.getIo(), multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    while (multi_reader.fill(64, .{ .deadline = deadline })) |_| {
        if (stdout_reader.buffered().len > 1024 or stderr_reader.buffered().len > 4096) {
            return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |fill_err| return fill_err,
    }
    try multi_reader.checkAnyError();

    return multi_reader.toOwnedSlice(1);
}

fn close_clipboard_process_streams(child: *std.process.Child) void {
    const io = io_mod.getIo();
    if (child.stdin) |stdin| stdin.close(io);
    if (child.stdout) |stdout| stdout.close(io);
    if (child.stderr) |stderr| stderr.close(io);
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
}

fn run_clipboard_process(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    deadline: std.Io.Clock.Timestamp,
) !ClipboardProcessResult {
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child_wait.killAndReap(&child, "clipboard file copy");
    defer close_clipboard_process_streams(&child);

    const term = try child_wait.waitWithDeadline(&child, deadline);
    const stderr = try collect_clipboard_process_output(alloc, &child, deadline);
    return .{
        .term = term,
        .stderr = stderr,
    };
}

// Publish eager file representations so the pasteboard server owns them after
// this short-lived process exits.
fn copy_file_to_clipboard(_: ?*anyopaque, alloc: std.mem.Allocator, path: []const u8) host.ClipboardError!bool {
    if (comptime builtin.target.os.tag != .macos) return false;

    const script =
        \\function run(argv) {
        \\  ObjC.import("AppKit");
        \\  var url = $.NSURL.fileURLWithPath(argv[0]).standardizedURL;
        \\  var expected = ObjC.unwrap(url.absoluteString);
        \\  var pb = $.NSPasteboard.generalPasteboard;
        \\  pb.clearContents;
        \\  if (!pb.setStringForType(expected, "public.file-url")) {
        \\    throw new Error("public.file-url materialization failed");
        \\  }
        \\  var files = $.NSArray.arrayWithObject(argv[0]);
        \\  if (!pb.setPropertyListForType(files, "NSFilenamesPboardType")) {
        \\    throw new Error("NSFilenamesPboardType materialization failed");
        \\  }
        \\  var copiedValue = pb.stringForType("public.file-url");
        \\  if (!copiedValue) throw new Error("public.file-url readback missing");
        \\  var copied = ObjC.unwrap(copiedValue);
        \\  if (copied !== expected) throw new Error("public.file-url readback mismatch");
        \\  var copiedFiles = ObjC.deepUnwrap(pb.propertyListForType("NSFilenamesPboardType"));
        \\  if (!copiedFiles || copiedFiles.length !== 1 || copiedFiles[0] !== argv[0]) {
        \\    throw new Error("NSFilenamesPboardType readback mismatch");
        \\  }
        \\}
    ;
    const argv: []const []const u8 = &.{ "osascript", "-l", "JavaScript", "-e", script, path };
    const started_ms = io_mod.milliTimestamp();
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromSeconds(5),
    });
    const result = run_clipboard_process(alloc, argv, deadline) catch |err| {
        const finished_ms = io_mod.milliTimestamp();
        const elapsed_ms = if (finished_ms >= started_ms) finished_ms - started_ms else 0;
        debug_trace.logf("host", "clipboard file copy process failed err={s} elapsed_ms={d}", .{ @errorName(err), elapsed_ms });
        return error.CopyFailed;
    };
    defer alloc.free(result.stderr);

    const finished_ms = io_mod.milliTimestamp();
    const elapsed_ms = if (finished_ms >= started_ms) finished_ms - started_ms else 0;
    switch (result.term) {
        .exited => |code| {
            if (code == 0) return true;
            debug_trace.logf("host", "clipboard file copy failed exit_code={d} elapsed_ms={d} stderr={s}", .{ code, elapsed_ms, result.stderr });
        },
        .signal => |signal| debug_trace.logf("host", "clipboard file copy failed term=signal signal={d} elapsed_ms={d} stderr={s}", .{ @backingInt(signal), elapsed_ms, result.stderr }),
        .stopped => |signal| debug_trace.logf("host", "clipboard file copy failed term=stopped signal={d} elapsed_ms={d} stderr={s}", .{ @backingInt(signal), elapsed_ms, result.stderr }),
        .unknown => |status| debug_trace.logf("host", "clipboard file copy failed term=unknown status={d} elapsed_ms={d} stderr={s}", .{ status, elapsed_ms, result.stderr }),
    }
    return error.CopyFailed;
}

const max_clipboard_text_bytes: usize = 16 * 1024 * 1024;
/// stderr is read only to recognize xclip's "no text" message, which is short.
const max_clipboard_read_stderr_bytes: usize = 1024;
const clipboard_read_timeout_seconds = 2;
/// Free buffer bytes the reader keeps for each read, in bytes.
const clipboard_read_spare_capacity_bytes: usize = 64;
/// Exit status xclip uses when the selection has no text target.
const no_text_exit_code: u8 = 1;

const ClipboardReadOutput = struct {
    text: []u8,
    stderr: []u8,
};

const ClipboardReadResult = struct {
    term: std.process.Child.Term,
    text: []u8,
    stderr: []u8,
};

// Both pipes are drained before the child is waited on: a child that fills a
// pipe cannot exit until it is read, so waiting first would time out large text.
fn collect_clipboard_read_output(
    alloc: std.mem.Allocator,
    child: *std.process.Child,
    deadline: std.Io.Clock.Timestamp,
    max_stdout_bytes: usize,
) !ClipboardReadOutput {
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(alloc, io_mod.getIo(), multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    while (multi_reader.fill(clipboard_read_spare_capacity_bytes, .{ .deadline = deadline })) |_| {
        if (stdout_reader.buffered().len > max_stdout_bytes) return error.StreamTooLong;
        if (stderr_reader.buffered().len > max_clipboard_read_stderr_bytes) return error.StderrTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |fill_err| return fill_err,
    }
    try multi_reader.checkAnyError();

    const text = try multi_reader.toOwnedSlice(0);
    errdefer alloc.free(text);
    return .{ .text = text, .stderr = try multi_reader.toOwnedSlice(1) };
}

fn run_clipboard_read(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    deadline: std.Io.Clock.Timestamp,
    max_stdout_bytes: usize,
) !ClipboardReadResult {
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child_wait.killAndReap(&child, "clipboard text read");
    defer close_clipboard_process_streams(&child);

    const output = try collect_clipboard_read_output(alloc, &child, deadline, max_stdout_bytes);
    errdefer {
        alloc.free(output.text);
        alloc.free(output.stderr);
    }
    const term = try child_wait.waitWithDeadline(&child, deadline);
    return .{ .term = term, .text = output.text, .stderr = output.stderr };
}

/// True when the read failed only because the selection has no text target.
/// xclip reports that as `Error: target STRING not available` with exit 1.
fn noTextTarget(term: std.process.Child.Term, stderr: []const u8) bool {
    const code = switch (term) {
        .exited => |exit_code| exit_code,
        else => return false,
    };
    if (code != no_text_exit_code) return false;
    const message = std.mem.trim(u8, stderr, " \r\n\t");
    return std.mem.startsWith(u8, message, "Error: target ") and
        std.mem.endsWith(u8, message, " not available");
}

/// Runs a read command. Returns the stdout bytes, owned by the caller, or null
/// when the read worked but found no text. Every failed read is an error.
fn runClipboardTextRead(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    deadline: std.Io.Clock.Timestamp,
    max_stdout_bytes: usize,
) host.ClipboardError!?[]u8 {
    const result = run_clipboard_read(alloc, argv, deadline, max_stdout_bytes) catch |err| {
        debug_trace.logf("host", "clipboard text read failed err={s}", .{@errorName(err)});
        return switch (err) {
            error.Timeout => error.ReadTimedOut,
            error.StreamTooLong => error.ReadTooLarge,
            error.OutOfMemory => error.OutOfMemory,
            else => error.ReadFailed,
        };
    };
    defer alloc.free(result.stderr);
    if (noTextTarget(result.term, result.stderr)) {
        alloc.free(result.text);
        return null;
    }
    if (!copySucceeded(result.term)) {
        alloc.free(result.text);
        logUnsuccessfulTerm("text read", result.term);
        return error.ReadFailed;
    }
    if (result.text.len == 0) {
        alloc.free(result.text);
        return null;
    }
    return result.text;
}

fn read_clipboard_text(_: ?*anyopaque, alloc: std.mem.Allocator) host.ClipboardError!?[]u8 {
    const argv = clipboardReadCommand(builtin.target.os.tag) orelse return null;
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromSeconds(clipboard_read_timeout_seconds),
    });
    return runClipboardTextRead(alloc, argv, deadline, max_clipboard_text_bytes);
}

fn clipboardCommand(os_tag: std.Target.Os.Tag) ?[]const []const u8 {
    return switch (os_tag) {
        .macos => &.{"pbcopy"},
        .linux => &.{ "xclip", "-selection", "clipboard" },
        else => null,
    };
}

fn clipboardReadCommand(os_tag: std.Target.Os.Tag) ?[]const []const u8 {
    return switch (os_tag) {
        .macos => &.{"pbpaste"},
        .linux => &.{ "xclip", "-selection", "clipboard", "-o" },
        else => null,
    };
}

fn copySucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        .signal, .stopped, .unknown => false,
    };
}

fn logUnsuccessfulTerm(operation: []const u8, term: std.process.Child.Term) void {
    switch (term) {
        .exited => |code| debug_trace.logf("host", "clipboard {s} failed exit_code={d}", .{ operation, code }),
        .signal => |signal| debug_trace.logf("host", "clipboard {s} failed term=signal signal={d}", .{ operation, @backingInt(signal) }),
        .stopped => |signal| debug_trace.logf("host", "clipboard {s} failed term=stopped signal={d}", .{ operation, @backingInt(signal) }),
        .unknown => |status| debug_trace.logf("host", "clipboard {s} failed term=unknown status={d}", .{ operation, status }),
    }
}

test "native clipboard selects the platform read command" {
    try std.testing.expectEqualSlices([]const u8, &.{"pbpaste"}, clipboardReadCommand(.macos).?);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "xclip", "-selection", "clipboard", "-o" },
        clipboardReadCommand(.linux).?,
    );
    try std.testing.expect(clipboardReadCommand(.windows) == null);
    try std.testing.expect(clipboardReadCommand(.wasi) == null);
}

fn testReadDeadline(milliseconds: i64) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(milliseconds),
    });
}

test "native clipboard read reports a command that outlives its deadline" {
    try std.testing.expectError(error.ReadTimedOut, runClipboardTextRead(
        std.testing.allocator,
        &.{ "sh", "-c", "sleep 5" },
        testReadDeadline(100),
        max_clipboard_text_bytes,
    ));
}

test "native clipboard read reports a command that exits non-zero" {
    try std.testing.expectError(error.ReadFailed, runClipboardTextRead(
        std.testing.allocator,
        &.{ "sh", "-c", "exit 3" },
        testReadDeadline(5000),
        max_clipboard_text_bytes,
    ));
}

test "native clipboard read reports output over the byte cap" {
    try std.testing.expectError(error.ReadTooLarge, runClipboardTextRead(
        std.testing.allocator,
        &.{ "sh", "-c", "printf abcdef" },
        testReadDeadline(5000),
        3,
    ));
}

test "native clipboard read returns stdout bytes unchanged" {
    const text = (try runClipboardTextRead(
        std.testing.allocator,
        &.{ "sh", "-c", "printf 'a\\r\\nb'" },
        testReadDeadline(5000),
        max_clipboard_text_bytes,
    )).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("a\r\nb", text);
}

test "native clipboard read treats xclip's no-text message as an empty clipboard" {
    try std.testing.expect((try runClipboardTextRead(
        std.testing.allocator,
        &.{ "sh", "-c", "echo 'Error: target STRING not available' >&2; exit 1" },
        testReadDeadline(5000),
        max_clipboard_text_bytes,
    )) == null);
}

test "native clipboard read keeps other stderr messages as failures" {
    try std.testing.expectError(error.ReadFailed, runClipboardTextRead(
        std.testing.allocator,
        &.{ "sh", "-c", "echo \"Error: Can't open display: :99\" >&2; exit 1" },
        testReadDeadline(5000),
        max_clipboard_text_bytes,
    ));
}

test "native clipboard read reports a program that cannot start" {
    try std.testing.expectError(error.ReadFailed, runClipboardTextRead(
        std.testing.allocator,
        &.{"fx-no-such-clipboard-tool"},
        testReadDeadline(5000),
        max_clipboard_text_bytes,
    ));
}

test "native clipboard selects the platform command" {
    try std.testing.expectEqualStrings("pbcopy", clipboardCommand(.macos).?[0]);
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "xclip", "-selection", "clipboard" },
        clipboardCommand(.linux).?,
    );
    try std.testing.expect(clipboardCommand(.windows) == null);
    try std.testing.expect(clipboardCommand(.wasi) == null);
}

test "native clipboard accepts only a successful exit" {
    try std.testing.expect(copySucceeded(.{ .exited = 0 }));
    try std.testing.expect(!copySucceeded(.{ .exited = 1 }));
    try std.testing.expect(!copySucceeded(.{ .signal = .TERM }));
    try std.testing.expect(!copySucceeded(.{ .stopped = .STOP }));
    try std.testing.expect(!copySucceeded(.{ .unknown = 1 }));
}
