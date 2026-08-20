const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

pub const max_code_bytes: usize = 256 * 1024;
pub const default_max_output_bytes: usize = 64 * 1024;
pub const max_frame_bytes: usize = 2 * 1024 * 1024;
const managed_ipython_requirement = "ipython==9.16.1";
const bootstrap_lock_name = "kernel-bootstrap.lock";

pub const ExecutionResult = struct {
    stdout: []u8,
    stderr: []u8,
    result: ?[]u8,
    status: Status,
    duration_ms: u64,

    pub const Status = enum { success, failed };

    pub fn deinit(self: ExecutionResult, alloc: Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
        if (self.result) |result| alloc.free(result);
    }
};

pub const ProviderFn = *const fn (
    ?*anyopaque,
    Allocator,
    []const u8,
    []const u8,
    []const u8,
) anyerror!ExecutionResult;

pub const ResetFn = *const fn (?*anyopaque) void;

/// A testable execution backend. Production uses the stdio Python worker;
/// tests can supply a fake provider without starting a child process.
pub const Provider = struct {
    context: ?*anyopaque = null,
    execute_fn: ProviderFn,
    reset_fn: ?ResetFn = null,

    fn execute(
        self: Provider,
        alloc: Allocator,
        root_session_id: []const u8,
        cwd: []const u8,
        code: []const u8,
    ) !ExecutionResult {
        return self.execute_fn(self.context, alloc, root_session_id, cwd, code);
    }

    fn reset(self: Provider) void {
        if (self.reset_fn) |reset_fn| reset_fn(self.context);
    }
};

pub const Options = struct {
    max_output_bytes: usize = default_max_output_bytes,
    python: ?[]const u8 = null,
    provider: ?Provider = null,
};

pub const Runtime = struct {
    allocator: Allocator,
    options: Options,
    mutex: std.Io.Mutex = .init,
    child: ?std.process.Child = null,
    root_session_id: ?[]u8 = null,
    worker_cwd: ?[]u8 = null,
    resolved_python: ?[]u8 = null,

    pub fn init(allocator: Allocator, options: Options) Runtime {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn deinit(self: *Runtime) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.stopWorker();
        if (self.root_session_id) |id| self.allocator.free(id);
        self.root_session_id = null;
        if (self.resolved_python) |python| self.allocator.free(python);
        self.resolved_python = null;
    }

    /// Stops the current session namespace while retaining the resolved
    /// Python executable for a later lazy restart.
    pub fn resetSession(self: *Runtime) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.stopWorker();
        if (self.options.provider) |provider| provider.reset();
        if (self.root_session_id) |id| self.allocator.free(id);
        self.root_session_id = null;
    }

    /// Executes code serially in one persistent namespace. A changed root
    /// identity tears down the old worker before starting a new one, which
    /// prevents a resumed session from inheriting another session's globals.
    pub fn execute(
        self: *Runtime,
        alloc: Allocator,
        root_session_id: []const u8,
        cwd: []const u8,
        code: []const u8,
        cancel_flag: ?*const std.atomic.Value(bool),
    ) !ExecutionResult {
        if (code.len == 0) return error.EmptyCode;
        if (code.len > max_code_bytes) return error.CodeTooLarge;
        if (isCancelled(cancel_flag)) return error.Cancelled;

        try self.lockForExecution(cancel_flag);
        defer self.mutex.unlock(io_mod.getIo());

        try self.ensureSession(root_session_id);
        if (self.options.provider) |provider| {
            const result = try provider.execute(alloc, root_session_id, cwd, code);
            if (isCancelled(cancel_flag)) {
                result.deinit(alloc);
                return error.Cancelled;
            }
            return result;
        }
        try self.ensureWorker(cwd, cancel_flag);
        const result = try self.executeWorker(alloc, code, cancel_flag);
        if (isCancelled(cancel_flag)) {
            result.deinit(alloc);
            self.stopWorker();
            return error.Cancelled;
        }
        return result;
    }

    fn lockForExecution(
        self: *Runtime,
        cancel_flag: ?*const std.atomic.Value(bool),
    ) !void {
        while (!self.mutex.tryLock()) {
            if (isCancelled(cancel_flag)) return error.Cancelled;
            io_mod.sleep(5 * std.time.ns_per_ms);
        }
        if (isCancelled(cancel_flag)) {
            self.mutex.unlock(io_mod.getIo());
            return error.Cancelled;
        }
    }

    fn ensureSession(self: *Runtime, root_session_id: []const u8) !void {
        if (self.root_session_id) |current| {
            if (std.mem.eql(u8, current, root_session_id)) return;
            self.stopWorker();
            if (self.options.provider) |provider| provider.reset();
            self.allocator.free(current);
            self.root_session_id = null;
        }
        self.root_session_id = try self.allocator.dupe(u8, root_session_id);
    }

    fn ensureWorker(
        self: *Runtime,
        cwd: []const u8,
        cancel_flag: ?*const std.atomic.Value(bool),
    ) !void {
        if (self.child != null) {
            if (self.worker_cwd) |current| {
                if (std.mem.eql(u8, current, cwd)) return;
            }
            self.stopWorker();
        }

        const python = try self.resolvePython(cancel_flag);
        if (isCancelled(cancel_flag)) return error.Cancelled;
        var child = try std.process.spawn(io_mod.getIo(), .{
            .argv = &.{ python, "-u", "-c", worker_script },
            .cwd = .{ .path = cwd },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = if (builtin.os.tag == .macos or builtin.os.tag == .linux) 0 else null,
        });
        errdefer {
            if (child.stdin) |stdin| stdin.close(io_mod.getIo());
            if (child.stdout) |stdout| stdout.close(io_mod.getIo());
            child.stdin = null;
            child.stdout = null;
            killChildProcessGroup(&child);
        }
        self.worker_cwd = try self.allocator.dupe(u8, cwd);
        self.child = child;
    }

    fn resolvePython(
        self: *Runtime,
        cancel_flag: ?*const std.atomic.Value(bool),
    ) ![]const u8 {
        if (self.resolved_python) |python| return python;
        if (isCancelled(cancel_flag)) return error.Cancelled;
        if (self.options.python orelse io_mod.getenv("FX_IPYTHON_PYTHON")) |python| {
            self.resolved_python = try self.allocator.dupe(u8, python);
            return self.resolved_python.?;
        }

        const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
        if (!std.fs.path.isAbsolute(home)) return error.InvalidHomePath;
        var home_dir = io_mod.VerifiedDir{
            .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
        };
        defer home_dir.close();
        var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(
            &home_dir,
            profile_paths.root_dir_name,
        );
        defer fx_dir.close();
        var lock = if (cancel_flag) |flag|
            try io_mod.acquireTimedAdvisoryLockCancellable(
                &fx_dir,
                bootstrap_lock_name,
                60_000,
                flag,
            )
        else
            try io_mod.acquireTimedAdvisoryLock(
                &fx_dir,
                bootstrap_lock_name,
                60_000,
            );
        defer lock.release();
        if (isCancelled(cancel_flag)) return error.Cancelled;

        const venv = try std.fs.path.join(self.allocator, &.{ home, profile_paths.root_dir_name, "kernel-venv" });
        defer self.allocator.free(venv);
        const python = try std.fs.path.join(self.allocator, &.{ venv, "bin", "python" });
        errdefer self.allocator.free(python);

        if (!try pythonImportsIpython(self.allocator, python, cancel_flag)) {
            try bootstrapManagedPython(self.allocator, venv, python, cancel_flag);
            if (!try pythonImportsIpython(self.allocator, python, cancel_flag)) {
                return error.IpythonBootstrapIncomplete;
            }
        }
        self.resolved_python = python;
        return python;
    }

    fn executeWorker(
        self: *Runtime,
        alloc: Allocator,
        code: []const u8,
        cancel_flag: ?*const std.atomic.Value(bool),
    ) !ExecutionResult {
        var request_writer: std.Io.Writer.Allocating = .init(alloc);
        defer request_writer.deinit();
        try request_writer.writer.writeAll("{\"code\":");
        try std.json.Stringify.value(code, .{}, &request_writer.writer);
        try request_writer.writer.print(",\"max_output_bytes\":{d}}}", .{self.options.max_output_bytes});
        const request = try request_writer.toOwnedSlice();
        defer alloc.free(request);

        if (request.len > max_frame_bytes) return error.RequestTooLarge;
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(request.len), .big);
        const child = &(self.child orelse return error.WorkerUnavailable);
        child.stdin.?.writeStreamingAll(io_mod.getIo(), &header) catch |err| {
            self.stopWorker();
            return err;
        };
        child.stdin.?.writeStreamingAll(io_mod.getIo(), request) catch |err| {
            self.stopWorker();
            return err;
        };

        return self.readWorkerResponse(alloc, child, cancel_flag) catch |err| {
            self.stopWorker();
            return err;
        };
    }

    fn readWorkerResponse(
        self: *Runtime,
        alloc: Allocator,
        child: *std.process.Child,
        cancel_flag: ?*const std.atomic.Value(bool),
    ) !ExecutionResult {
        var response_header: [4]u8 = undefined;
        try readExact(&child.stdout.?, &response_header, cancel_flag);
        const response_len = std.mem.readInt(u32, &response_header, .big);
        if (response_len > max_frame_bytes) return error.ResponseTooLarge;
        const response = try alloc.alloc(u8, response_len);
        defer alloc.free(response);
        try readExact(&child.stdout.?, response, cancel_flag);
        return parseResponse(alloc, response, self.options.max_output_bytes);
    }

    fn stopWorker(self: *Runtime) void {
        if (self.child) |*child| {
            if (child.stdin) |stdin| stdin.close(io_mod.getIo());
            if (child.stdout) |stdout| stdout.close(io_mod.getIo());
            child.stdin = null;
            child.stdout = null;
            killChildProcessGroup(child);
        }
        self.child = null;
        if (self.worker_cwd) |cwd| self.allocator.free(cwd);
        self.worker_cwd = null;
    }
};

fn commandSucceeded(
    alloc: Allocator,
    argv: []const []const u8,
    cancel_flag: ?*const std.atomic.Value(bool),
) !bool {
    if (isCancelled(cancel_flag)) return error.Cancelled;
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) {
        const result = std.process.run(alloc, io_mod.getIo(), .{
            .argv = argv,
            .stdout_limit = .limited(128 * 1024),
            .stderr_limit = .limited(128 * 1024),
        }) catch return false;
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        if (isCancelled(cancel_flag)) return error.Cancelled;
        return result.term == .exited and result.term.exited == 0;
    }

    var child = std.process.spawn(io_mod.getIo(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }) catch return false;
    defer if (child.id != null) killChildProcessGroup(&child);
    const pid = child.id orelse return false;
    while (true) {
        if (isCancelled(cancel_flag)) {
            killChildProcessGroup(&child);
            return error.Cancelled;
        }
        var status: c_int = undefined;
        const waited = std.c.waitpid(pid, &status, std.c.W.NOHANG);
        switch (std.c.errno(waited)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return false,
        }
        if (waited == pid) {
            child.id = null;
            const raw_status: u32 = @bitCast(status);
            return std.c.W.IFEXITED(raw_status) and std.c.W.EXITSTATUS(raw_status) == 0;
        }
        if (waited != 0) return false;
        io_mod.sleep(25 * std.time.ns_per_ms);
    }
}

fn killChildProcessGroup(child: *std.process.Child) void {
    if (child.id) |pid| {
        if (comptime builtin.os.tag == .linux or builtin.os.tag == .macos) {
            std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
        }
    }
    child.kill(io_mod.getIo());
}

fn pythonImportsIpython(
    alloc: Allocator,
    python: []const u8,
    cancel_flag: ?*const std.atomic.Value(bool),
) !bool {
    return commandSucceeded(
        alloc,
        &.{ python, "-c", "from IPython.core.interactiveshell import InteractiveShell" },
        cancel_flag,
    );
}

fn bootstrapManagedPython(
    alloc: Allocator,
    venv: []const u8,
    python: []const u8,
    cancel_flag: ?*const std.atomic.Value(bool),
) !void {
    const uv_created = try commandSucceeded(alloc, &.{
        "uv",
        "venv",
        "--python",
        "python3",
        "--allow-existing",
        venv,
    }, cancel_flag);
    if (uv_created and try commandSucceeded(alloc, &.{
        "uv",
        "pip",
        "install",
        "--python",
        python,
        managed_ipython_requirement,
    }, cancel_flag)) return;

    if (!try commandSucceeded(alloc, &.{ "python3", "-m", "venv", venv }, cancel_flag)) {
        return error.IpythonVenvCreationFailed;
    }
    if (!try commandSucceeded(alloc, &.{
        python,
        "-m",
        "pip",
        "install",
        managed_ipython_requirement,
    }, cancel_flag)) return error.IpythonInstallFailed;
}

fn isCancelled(cancel_flag: ?*const std.atomic.Value(bool)) bool {
    return if (cancel_flag) |flag| flag.load(.acquire) else false;
}

fn readExact(
    file: *std.Io.File,
    out: []u8,
    cancel_flag: ?*const std.atomic.Value(bool),
) !void {
    var total: usize = 0;
    while (total < out.len) {
        if (isCancelled(cancel_flag)) return error.Cancelled;
        if (comptime builtin.os.tag == .linux or builtin.os.tag == .macos) {
            var descriptors = [_]std.posix.pollfd{.{
                .fd = file.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = try std.posix.poll(&descriptors, 25);
            if (ready == 0) continue;
        }
        const count = file.readStreaming(io_mod.getIo(), &.{out[total..]}) catch |err| switch (err) {
            error.EndOfStream => return error.WorkerClosed,
            else => return err,
        };
        if (count == 0) return error.WorkerClosed;
        total += count;
    }
}

const WorkerResponse = struct {
    stdout: []const u8,
    stderr: []const u8,
    result: ?[]const u8 = null,
    status: []const u8,
    duration_ms: u64,
};

fn parseResponse(alloc: Allocator, bytes: []const u8, max_output: usize) !ExecutionResult {
    var parsed = try std.json.parseFromSlice(WorkerResponse, alloc, bytes, .{});
    defer parsed.deinit();
    const response = parsed.value;
    const status: ExecutionResult.Status = if (std.mem.eql(u8, response.status, "success"))
        .success
    else if (std.mem.eql(u8, response.status, "error"))
        .failed
    else
        return error.InvalidWorkerResponse;
    const stdout = try clippedDupe(alloc, response.stdout, max_output);
    errdefer alloc.free(stdout);
    const stderr = try clippedDupe(alloc, response.stderr, max_output);
    errdefer alloc.free(stderr);
    const result = if (response.result) |value| try clippedDupe(alloc, value, max_output) else null;
    errdefer if (result) |value| alloc.free(value);
    return .{
        .stdout = stdout,
        .stderr = stderr,
        .result = result,
        .status = status,
        .duration_ms = response.duration_ms,
    };
}

fn clippedDupe(alloc: Allocator, text: []const u8, limit: usize) ![]u8 {
    const actual = @min(text.len, limit);
    return alloc.dupe(u8, text[0..actual]);
}

const worker_script =
    \\import contextlib
    \\import io
    \\import json
    \\import os
    \\import struct
    \\import sys
    \\import time
    \\import traceback
    \\
    \\protocol_fd = os.dup(1)
    \\devnull_fd = os.open(os.devnull, os.O_WRONLY)
    \\os.dup2(devnull_fd, 1)
    \\os.dup2(devnull_fd, 2)
    \\os.close(devnull_fd)
    \\try:
    \\    from IPython.core.interactiveshell import InteractiveShell
    \\    shell = InteractiveShell.instance()
    \\except ImportError:
    \\    shell = None
    \\
    \\class BoundedText(io.TextIOBase):
    \\    marker = "\\n[output truncated by fx]"
    \\    def __init__(self, limit):
    \\        self.limit = max(0, int(limit))
    \\        self.parts = []
    \\        self.size = 0
    \\        self.truncated = False
    \\    def writable(self):
    \\        return True
    \\    def write(self, value):
    \\        text = str(value)
    \\        encoded = text.encode("utf-8", "replace")
    \\        remaining = max(0, self.limit - self.size)
    \\        if len(encoded) <= remaining:
    \\            self.parts.append(text)
    \\            self.size += len(encoded)
    \\        else:
    \\            self.parts.append(encoded[:remaining].decode("utf-8", "ignore"))
    \\            self.size = self.limit
    \\            self.truncated = True
    \\        return len(text)
    \\    def flush(self):
    \\        return None
    \\    def getvalue(self):
    \\        value = "".join(self.parts)
    \\        if not self.truncated:
    \\            return value
    \\        marker = self.marker.encode("utf-8")
    \\        encoded = value.encode("utf-8")
    \\        if len(marker) >= self.limit:
    \\            return marker[:self.limit].decode("utf-8", "ignore")
    \\        return encoded[:self.limit - len(marker)].decode("utf-8", "ignore") + self.marker
    \\
    \\def clip(value, limit):
    \\    if value is None:
    \\        return None
    \\    capture = BoundedText(limit)
    \\    capture.write(value)
    \\    return capture.getvalue()
    \\
    \\def write_all(fd, value):
    \\    remaining = memoryview(value)
    \\    while remaining:
    \\        written = os.write(fd, remaining)
    \\        remaining = remaining[written:]
    \\
    \\def read_exact(size):
    \\    data = bytearray()
    \\    while len(data) < size:
    \\        chunk = sys.stdin.buffer.read(size - len(data))
    \\        if not chunk:
    \\            return None
    \\        data.extend(chunk)
    \\    return bytes(data)
    \\
    \\def execute(code, max_output_bytes):
    \\    started = time.monotonic()
    \\    stdout = BoundedText(max_output_bytes)
    \\    stderr = BoundedText(max_output_bytes)
    \\    result = None
    \\    status = "success"
    \\    try:
    \\        if shell is None:
    \\            raise RuntimeError("IPython is unavailable; install the ipython package for FX_IPYTHON_PYTHON")
    \\        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
    \\            execution = shell.run_cell(code, store_history=True, silent=False)
    \\        if execution.error_before_exec is not None or execution.error_in_exec is not None:
    \\            status = "error"
    \\            error_value = execution.error_before_exec or execution.error_in_exec
    \\            result = clip("".join(traceback.format_exception(type(error_value), error_value, error_value.__traceback__)), max_output_bytes)
    \\        elif execution.result is not None:
    \\            result = clip(repr(execution.result), max_output_bytes)
    \\        return {"stdout": stdout.getvalue(), "stderr": stderr.getvalue(), "result": result, "status": status, "duration_ms": int((time.monotonic() - started) * 1000)}
    \\    except BaseException:
    \\        status = "error"
    \\        result = clip(traceback.format_exc(), max_output_bytes)
    \\    return {"stdout": stdout.getvalue(), "stderr": stderr.getvalue(), "result": result, "status": status, "duration_ms": int((time.monotonic() - started) * 1000)}
    \\
    \\while True:
    \\    header = read_exact(4)
    \\    if header is None:
    \\        break
    \\    size = struct.unpack(">I", header)[0]
    \\    payload = read_exact(size)
    \\    if payload is None:
    \\        break
    \\    try:
    \\        request = json.loads(payload.decode("utf-8"))
    \\        response = execute(request["code"], request["max_output_bytes"])
    \\    except BaseException:
    \\        response = {"stdout": "", "stderr": "", "result": traceback.format_exc(), "status": "error", "duration_ms": 0}
    \\    encoded = json.dumps(response, ensure_ascii=True).encode("utf-8")
    \\    write_all(protocol_fd, struct.pack(">I", len(encoded)))
    \\    write_all(protocol_fd, encoded)
;

test "runtime provider is serialized and resets when root identity changes" {
    const Fake = struct {
        calls: usize = 0,
        resets: usize = 0,

        fn execute(
            raw: ?*anyopaque,
            alloc: Allocator,
            _: []const u8,
            _: []const u8,
            _: []const u8,
        ) !ExecutionResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return .{
                .stdout = try alloc.dupe(u8, "ok"),
                .stderr = try alloc.dupe(u8, ""),
                .result = null,
                .status = .success,
                .duration_ms = 1,
            };
        }

        fn reset(raw: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.resets += 1;
        }
    };

    var fake = Fake{};
    var runtime = Runtime.init(std.testing.allocator, .{ .provider = .{
        .context = @ptrCast(&fake),
        .execute_fn = Fake.execute,
        .reset_fn = Fake.reset,
    } });
    defer runtime.deinit();

    const first = try runtime.execute(std.testing.allocator, "root-a", ".", "1+1", null);
    first.deinit(std.testing.allocator);
    const second = try runtime.execute(std.testing.allocator, "root-a", ".", "2+2", null);
    second.deinit(std.testing.allocator);
    const third = try runtime.execute(std.testing.allocator, "root-b", ".", "3+3", null);
    third.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expectEqual(@as(usize, 1), fake.resets);

    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(
        error.Cancelled,
        runtime.execute(std.testing.allocator, "root-b", ".", "4+4", &cancelled),
    );
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
}

test "queued kernel execution observes cancellation before entering the namespace" {
    const Fake = struct {
        calls: usize = 0,

        fn execute(
            raw: ?*anyopaque,
            alloc: Allocator,
            _: []const u8,
            _: []const u8,
            _: []const u8,
        ) !ExecutionResult {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return .{
                .stdout = try alloc.dupe(u8, "unexpected"),
                .stderr = try alloc.dupe(u8, ""),
                .result = null,
                .status = .success,
                .duration_ms = 0,
            };
        }
    };

    var fake = Fake{};
    var runtime = Runtime.init(std.testing.allocator, .{ .provider = .{
        .context = @ptrCast(&fake),
        .execute_fn = Fake.execute,
    } });
    defer runtime.deinit();
    runtime.mutex.lockUncancelable(io_mod.getIo());
    defer runtime.mutex.unlock(io_mod.getIo());

    var cancel_flag = std.atomic.Value(bool).init(false);
    const Cancel = struct {
        fn afterDelay(flag: *std.atomic.Value(bool)) void {
            io_mod.sleep(25 * std.time.ns_per_ms);
            flag.store(true, .release);
        }
    };
    var cancel_thread = try std.Thread.spawn(.{}, Cancel.afterDelay, .{&cancel_flag});
    defer cancel_thread.join();
    try std.testing.expectError(
        error.Cancelled,
        runtime.execute(std.testing.allocator, "root", ".", "1+1", &cancel_flag),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "kernel helper subprocess observes cancellation" {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var cancel_flag = std.atomic.Value(bool).init(false);
    const Cancel = struct {
        fn afterDelay(flag: *std.atomic.Value(bool)) void {
            io_mod.sleep(50 * std.time.ns_per_ms);
            flag.store(true, .release);
        }
    };
    var cancel_thread = try std.Thread.spawn(.{}, Cancel.afterDelay, .{&cancel_flag});
    defer cancel_thread.join();
    try std.testing.expectError(
        error.Cancelled,
        commandSucceeded(
            std.testing.allocator,
            &.{ "sh", "-c", "sleep 5" },
            &cancel_flag,
        ),
    );
}

test "worker response is bounded and typed" {
    const result = try parseResponse(std.testing.allocator, "{\"stdout\":\"abcdef\",\"stderr\":\"e\",\"result\":null,\"status\":\"success\",\"duration_ms\":4}", 3);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("abc", result.stdout);
    try std.testing.expectEqualStrings("e", result.stderr);
    try std.testing.expectEqual(.success, result.status);
}

test "configured IPython worker persists cells, runs magics, and preserves framing" {
    const python = io_mod.getenv("FX_IPYTHON_TEST_PYTHON") orelse return error.SkipZigTest;
    const cwd = io_mod.getenv("PWD") orelse return error.SkipZigTest;
    var runtime = Runtime.init(std.testing.allocator, .{
        .python = python,
        .max_output_bytes = 16 * 1024,
    });
    defer runtime.deinit();

    const first = try runtime.execute(
        std.testing.allocator,
        "ipython-test-root",
        cwd,
        "value = 41\nprint('framed stdout')\n%timeit -n 1 -r 1 value",
        null,
    );
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(.success, first.status);
    try std.testing.expect(std.mem.find(u8, first.stdout, "framed stdout") != null);
    try std.testing.expect(std.mem.find(u8, first.stdout, "per loop") != null);
    try std.testing.expect(std.mem.findScalar(u8, first.stdout, 0) == null);

    const second = try runtime.execute(
        std.testing.allocator,
        "ipython-test-root",
        cwd,
        "value + 1",
        null,
    );
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(.success, second.status);
    try std.testing.expectEqualStrings("42", second.result orelse return error.TestExpectedEqual);
    try std.testing.expectEqualStrings("", second.stderr);

    const failed = try runtime.execute(
        std.testing.allocator,
        "ipython-test-root",
        cwd,
        "raise ValueError('framed-error')",
        null,
    );
    defer failed.deinit(std.testing.allocator);
    try std.testing.expectEqual(.failed, failed.status);
    try std.testing.expect(std.mem.find(u8, failed.result orelse "", "framed-error") != null);
    try std.testing.expect(std.mem.find(u8, failed.result orelse "", "Traceback") != null);

    var cancel_flag = std.atomic.Value(bool).init(false);
    const Cancel = struct {
        fn afterDelay(flag: *std.atomic.Value(bool)) void {
            io_mod.sleep(100 * std.time.ns_per_ms);
            flag.store(true, .release);
        }
    };
    var cancel_thread = try std.Thread.spawn(.{}, Cancel.afterDelay, .{&cancel_flag});
    defer cancel_thread.join();
    try std.testing.expectError(
        error.Cancelled,
        runtime.execute(
            std.testing.allocator,
            "ipython-test-root",
            cwd,
            "while True: pass",
            &cancel_flag,
        ),
    );

    try std.testing.expectError(
        error.WorkerClosed,
        runtime.execute(
            std.testing.allocator,
            "ipython-test-root",
            cwd,
            "import os; os._exit(0)",
            null,
        ),
    );
    const restarted = try runtime.execute(
        std.testing.allocator,
        "ipython-test-root",
        cwd,
        "6 * 7",
        null,
    );
    defer restarted.deinit(std.testing.allocator);
    try std.testing.expectEqual(.success, restarted.status);
    try std.testing.expectEqualStrings("42", restarted.result orelse return error.TestExpectedEqual);
}
