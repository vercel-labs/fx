//! First-use provisioning. It runs on a tool/session worker, never the paint path.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const Allocator = std.mem.Allocator;

pub const Paths = struct {
    python: []u8,
    runtime: []u8,

    pub fn deinit(self: Paths, alloc: Allocator) void {
        alloc.free(self.python);
        alloc.free(self.runtime);
    }
};

pub const Progress = struct {
    context: ?*anyopaque = null,
    report: *const fn (?*anyopaque, []const u8) void,
};

/// Returned paths belong to the caller. A process-shared file lock protects installation.
pub const Cancellation = struct {
    caller: ?*const std.atomic.Value(bool) = null,
    owner: ?*const std.atomic.Value(bool) = null,

    fn check(self: Cancellation) !void {
        if ((if (self.caller) |flag| flag.load(.acquire) else false) or
            (if (self.owner) |flag| flag.load(.acquire) else false)) return error.Cancelled;
    }
};

pub fn ensure(alloc: Allocator, explicit_python: ?[]const u8, progress: ?Progress, cancel: Cancellation) !Paths {
    const io = io_mod.getIo();
    const root = if (io_mod.getenv("PROTO_FX_KERNEL_HOME")) |path|
        try alloc.dupe(u8, path)
    else
        try std.Io.Dir.path.join(alloc, &.{ io_mod.homeDir() orelse return error.HomeNotSet, ".proto-fx", "kernel" });
    defer alloc.free(root);
    if (!std.Io.Dir.path.isAbsolute(root)) return error.KernelHomeMustBeAbsolute;
    try std.Io.Dir.cwd().createDirPath(io, root);
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer dir.close(io);
    var lock = try dir.createFile(io, ".install.lock", .{ .truncate = false, .permissions = .fromMode(0o600) });
    defer lock.close(io);
    while (!try lock.tryLock(io, .exclusive)) {
        try cancel.check();
        io_mod.sleep(50 * std.time.ns_per_ms);
    }
    try cancel.check();
    defer lock.unlock(io);
    // The payload is compiled into proto-fx, so the installed executable does not depend on a checkout.
    try dir.writeFile(io, .{ .sub_path = "runtime.py.new", .data = @embedFile("runtime.py"), .flags = .{ .permissions = .fromMode(0o600) } });
    try dir.rename("runtime.py.new", dir, "runtime.py", io);
    const runtime = try std.Io.Dir.path.join(alloc, &.{ root, "runtime.py" });
    errdefer alloc.free(runtime);
    const selected = explicit_python orelse io_mod.getenv("PROTO_FX_KERNEL_PYTHON");
    if (selected) |python| {
        if (!try probe(alloc, python, cancel)) return error.KernelPythonRequiresPython311AndDill;
        return .{ .python = try alloc.dupe(u8, python), .runtime = runtime };
    }
    const venv = try std.Io.Dir.path.join(alloc, &.{ root, "venv" });
    defer alloc.free(venv);
    const python = try std.Io.Dir.path.join(alloc, &.{ venv, "bin", "python" });
    errdefer alloc.free(python);
    if (!try probe(alloc, python, cancel)) {
        if (progress) |sink| sink.report(sink.context, "Setting up Python 3.11 kernel (first use needs internet)...");
        const uv = try findUv(alloc);
        defer alloc.free(uv);
        try run(alloc, &.{ uv, "venv", venv, "--python", "3.11", "--allow-existing" }, cancel);
        try run(alloc, &.{ uv, "pip", "install", "--python", python, "dill" }, cancel);
        if (!try probe(alloc, python, cancel)) return error.KernelPythonRequiresPython311AndDill;
    }
    return .{ .python = python, .runtime = runtime };
}

fn probe(alloc: Allocator, python: []const u8, cancel: Cancellation) !bool {
    return command(alloc, &.{ python, "-c", "import sys, dill; assert sys.version_info >= (3, 11)" }, cancel, 15_000) catch |err| switch (err) {
        error.OutOfMemory, error.Cancelled => return err,
        else => false,
    };
}

fn findUv(alloc: Allocator) ![]u8 {
    if (io_mod.getenv("PROTO_FX_UV")) |uv| return alloc.dupe(u8, uv);
    if (io_mod.homeDir()) |home| {
        const local = try std.Io.Dir.path.join(alloc, &.{ home, ".local", "bin", "uv" });
        if (std.Io.Dir.cwd().access(io_mod.getIo(), local, .{})) |_| return local else |_| alloc.free(local);
    }
    return alloc.dupe(u8, "uv");
}

fn run(alloc: Allocator, argv: []const []const u8, cancel: Cancellation) !void {
    if (!try command(alloc, argv, cancel, 180_000)) return error.KernelPythonProvisioningFailed;
}

fn command(alloc: Allocator, argv: []const []const u8, cancel: Cancellation, timeout_ms: i64) !bool {
    try cancel.check();
    const io = io_mod.getIo();
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe }) catch |err| switch (err) {
        error.FileNotFound => return error.KernelSetupNeedsUv,
        else => return err,
    };
    defer child.kill(io);
    var storage: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(alloc, io, storage.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    const deadline = io_mod.monotonicMilliTimestamp() + timeout_ms;
    while (true) {
        try cancel.check();
        if (io_mod.monotonicMilliTimestamp() >= deadline) return error.KernelSetupTimedOut;
        reader.fill(4096, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => continue,
            error.EndOfStream => break,
            else => return err,
        };
        // Setup output is not model output. Drain continuously without retaining megabytes of uv progress.
        reader.reader(0).tossBuffered();
        reader.reader(1).tossBuffered();
    }
    try reader.checkAnyError();
    return (try child.wait(io)).success();
}
