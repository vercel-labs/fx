const std = @import("std");
const builtin = @import("builtin");
const host = @import("host.zig");
const native_secret_store = @import("native_secret_store.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

pub const clipboard = host.Clipboard{
    .copy_fn = copyToClipboard,
    .copy_file_fn = copy_file_to_clipboard,
};

pub const secret_store = native_secret_store.provider;

fn copyToClipboard(_: ?*anyopaque, text: []const u8) host.ClipboardError!bool {
    if (builtin.os.tag == .windows) {
        return copyToClipboardWindows(text);
    }
    const argv = clipboardCommand(builtin.os.tag) orelse return false;
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
        logUnsuccessfulTerm(term);
        return error.CopyFailed;
    }
    return true;
}

fn copyToClipboardWindows(text: []const u8) host.ClipboardError!bool {
    // Win32 clipboard: OpenClipboard → EmptyClipboard → SetClipboardData
    // (CF_UNICODETEXT backed by a GMEM_MOVEABLE buffer) → CloseClipboard.
    // The shell transfers ownership of the GMEM_MOVEABLE handle to the
    // clipboard on a successful SetClipboardData, so we must not call
    // GlobalFree on it.
    const user32 = struct {
        extern "user32" fn OpenClipboard(hwnd: ?*anyopaque) callconv(.c) c_int;
        extern "user32" fn CloseClipboard() callconv(.c) c_int;
        extern "user32" fn EmptyClipboard() callconv(.c) c_int;
        extern "user32" fn SetClipboardData(format: c_uint, hmem: ?*anyopaque) callconv(.c) ?*anyopaque;
    };
    const kernel32 = struct {
        extern "kernel32" fn GlobalAlloc(flags: c_uint, bytes: usize) callconv(.c) ?*anyopaque;
        extern "kernel32" fn GlobalLock(hmem: *anyopaque) callconv(.c) ?*anyopaque;
        extern "kernel32" fn GlobalUnlock(hmem: *anyopaque) callconv(.c) c_int;
    };
    const CF_UNICODETEXT: c_uint = 13;
    const GMEM_MOVEABLE: c_uint = 0x0002;

    const wide = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, text) catch {
        debug_trace.logf("host", "clipboard utf8→utf16 alloc failed", .{});
        return error.CopyFailed;
    };
    defer std.heap.page_allocator.free(wide);

    // Total size in bytes includes the UTF-16 payload plus the terminating
    // NUL (which the slice already has) but Win32 wants a fully 16-bit-
    // aligned size for the trailing NUL word.
    const bytes: usize = (wide.len + 1) * @sizeOf(u16);
    const hmem = kernel32.GlobalAlloc(GMEM_MOVEABLE, bytes) orelse {
        debug_trace.logf("host", "clipboard GlobalAlloc failed", .{});
        return error.CopyFailed;
    };
    const locked = kernel32.GlobalLock(hmem) orelse {
        debug_trace.logf("host", "clipboard GlobalLock failed", .{});
        return error.CopyFailed;
    };
    const locked_w: [*]u16 = @ptrCast(@alignCast(locked));
    @memcpy(locked_w[0..wide.len], wide);
    locked_w[wide.len] = 0;
    _ = kernel32.GlobalUnlock(hmem);

    if (user32.OpenClipboard(null) == 0) {
        debug_trace.logf("host", "clipboard OpenClipboard failed", .{});
        return error.CopyFailed;
    }
    defer _ = user32.CloseClipboard();
    _ = user32.EmptyClipboard();
    if (user32.SetClipboardData(CF_UNICODETEXT, hmem) == null) {
        debug_trace.logf("host", "clipboard SetClipboardData failed", .{});
        return error.CopyFailed;
    }
    // hmem is now owned by the clipboard; do not free.
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

fn clipboard_process_term(status: c_int) std.process.Child.Term {
    const raw_status: u32 = @bitCast(status);
    return if (std.c.W.IFEXITED(raw_status))
        .{ .exited = std.c.W.EXITSTATUS(raw_status) }
    else if (std.c.W.IFSIGNALED(raw_status))
        .{ .signal = std.c.W.TERMSIG(raw_status) }
    else if (std.c.W.IFSTOPPED(raw_status))
        .{ .stopped = std.c.W.STOPSIG(raw_status) }
    else
        .{ .unknown = raw_status };
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

fn try_reap_clipboard_process(child: *std.process.Child) error{WaitFailed}!?std.process.Child.Term {
    const pid = child.id orelse return error.WaitFailed;
    var status: c_int = undefined;
    const waited = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    if (waited == 0) return null;
    if (waited != pid) return error.WaitFailed;

    child.id = null;
    return clipboard_process_term(status);
}

fn kill_and_wait_clipboard_process(child: *std.process.Child) !std.process.Child.Term {
    const pid = child.id orelse return error.WaitFailed;
    std.posix.kill(pid, .KILL) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => |kill_err| return kill_err,
    };
    return child.wait(io_mod.getIo());
}

fn wait_for_clipboard_process(
    child: *std.process.Child,
    deadline: std.Io.Clock.Timestamp,
) !std.process.Child.Term {
    const io = io_mod.getIo();
    while (true) {
        if (try try_reap_clipboard_process(child)) |term| return term;

        const now = std.Io.Clock.Timestamp.now(io, .awake);
        if (!std.Io.Clock.Timestamp.compare(now, .lt, deadline)) {
            _ = try kill_and_wait_clipboard_process(child);
            return error.Timeout;
        }
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
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
    defer child.kill(io_mod.getIo());
    defer close_clipboard_process_streams(&child);

    const term = wait_for_clipboard_process(&child, deadline) catch |err| {
        if (child.id != null) {
            _ = kill_and_wait_clipboard_process(&child) catch |cleanup_err| {
                debug_trace.logf("host", "clipboard file copy cleanup failed err={s}", .{@errorName(cleanup_err)});
            };
        }
        return err;
    };
    const stderr = try collect_clipboard_process_output(alloc, &child, deadline);
    return .{
        .term = term,
        .stderr = stderr,
    };
}

// Publish eager file representations so the pasteboard server owns them after
// this short-lived process exits.
fn copy_file_to_clipboard(_: ?*anyopaque, alloc: std.mem.Allocator, path: []const u8) host.ClipboardError!bool {
    if (comptime builtin.os.tag != .macos) return false;

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
        .signal => |signal| debug_trace.logf("host", "clipboard file copy failed term=signal signal={d} elapsed_ms={d} stderr={s}", .{ @intFromEnum(signal), elapsed_ms, result.stderr }),
        .stopped => |signal| debug_trace.logf("host", "clipboard file copy failed term=stopped signal={d} elapsed_ms={d} stderr={s}", .{ @intFromEnum(signal), elapsed_ms, result.stderr }),
        .unknown => |status| debug_trace.logf("host", "clipboard file copy failed term=unknown status={d} elapsed_ms={d} stderr={s}", .{ status, elapsed_ms, result.stderr }),
    }
    return error.CopyFailed;
}

fn clipboardCommand(os_tag: std.Target.Os.Tag) ?[]const []const u8 {
    return switch (os_tag) {
        .macos => &.{"pbcopy"},
        .linux => &.{ "xclip", "-selection", "clipboard" },
        .windows => null, // copyToClipboardWindows bypasses this path
        else => null,
    };
}

fn copySucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        .signal, .stopped, .unknown => false,
    };
}

fn logUnsuccessfulTerm(term: std.process.Child.Term) void {
    switch (term) {
        .exited => |code| debug_trace.logf("host", "clipboard copy failed exit_code={d}", .{code}),
        .signal => |signal| debug_trace.logf("host", "clipboard copy failed term=signal signal={d}", .{@intFromEnum(signal)}),
        .stopped => |signal| debug_trace.logf("host", "clipboard copy failed term=stopped signal={d}", .{@intFromEnum(signal)}),
        .unknown => |status| debug_trace.logf("host", "clipboard copy failed term=unknown status={d}", .{status}),
    }
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
