//! First-use provisioning. It runs on a tool/session worker, never the paint path.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const Allocator = std.mem.Allocator;

pub const Paths = struct {
    python: []u8,
    runtime: []u8,
    /// A folder holding dill for a project interpreter that lacks it; the
    /// kernel imports dill from it only to snapshot or restore.
    dill_path: ?[]u8 = null,

    pub fn deinit(self: Paths, alloc: Allocator) void {
        alloc.free(self.python);
        alloc.free(self.runtime);
        if (self.dill_path) |path| alloc.free(path);
    }
};

/// Kernels need these; older project interpreters fall back to the managed one.
const project_probe = "import sys; assert sys.version_info >= (3, 11)";
const full_probe = "import sys, dill; assert sys.version_info >= (3, 11)";

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

/// Picks the kernel interpreter: `explicit_python`, then PROTO_FX_KERNEL_PYTHON,
/// then the project's environment in `cwd` (UV_PROJECT_ENVIRONMENT or
/// `.venv`, as uv uses) when it is Python 3.11 or newer, else the managed venv.
pub fn ensure(alloc: Allocator, explicit_python: ?[]const u8, cwd: []const u8, progress: ?Progress, cancel: Cancellation) !Paths {
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
        if (!try probe(alloc, python, full_probe, cancel)) return error.KernelPythonRequiresPython311AndDill;
        return .{ .python = try alloc.dupe(u8, python), .runtime = runtime };
    }
    if (try projectPython(alloc, cwd, cancel)) |project| {
        errdefer alloc.free(project);
        if (try probe(alloc, project, full_probe, cancel)) return .{ .python = project, .runtime = runtime };
        // dill is pure Python: borrow it from the managed venv.
        const managed = try managedPython(alloc, root, progress, cancel);
        defer alloc.free(managed);
        return .{ .python = project, .runtime = runtime, .dill_path = try sitePackages(alloc, root) };
    }
    return .{ .python = try managedPython(alloc, root, progress, cancel), .runtime = runtime };
}

/// The project environment's interpreter in `cwd`, if it has one that can
/// run a kernel. Caller owns it.
fn projectPython(alloc: Allocator, cwd: []const u8, cancel: Cancellation) !?[]u8 {
    if (cwd.len == 0 or !std.Io.Dir.path.isAbsolute(cwd)) return null;
    const env_dir = if (io_mod.getenv("UV_PROJECT_ENVIRONMENT")) |configured|
        (if (std.Io.Dir.path.isAbsolute(configured)) try alloc.dupe(u8, configured) else try std.Io.Dir.path.join(alloc, &.{ cwd, configured }))
    else
        try std.Io.Dir.path.join(alloc, &.{ cwd, ".venv" });
    defer alloc.free(env_dir);
    const python = try std.Io.Dir.path.join(alloc, &.{ env_dir, "bin", "python" });
    errdefer alloc.free(python);
    std.Io.Dir.cwd().access(io_mod.getIo(), python, .{}) catch {
        alloc.free(python);
        return null;
    };
    if (!try probe(alloc, python, project_probe, cancel)) {
        alloc.free(python);
        return null;
    }
    return python;
}

/// `<root>/venv/lib/python3.*/site-packages`. Caller owns it.
fn sitePackages(alloc: Allocator, root: []const u8) ![]u8 {
    const io = io_mod.getIo();
    const lib = try std.Io.Dir.path.join(alloc, &.{ root, "venv", "lib" });
    defer alloc.free(lib);
    var dir = try std.Io.Dir.openDirAbsolute(io, lib, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "python3")) return std.Io.Dir.path.join(alloc, &.{ lib, entry.name, "site-packages" });
    }
    return error.KernelPythonProvisioningFailed;
}

/// The managed venv's interpreter, provisioned with uv on first use.
fn managedPython(alloc: Allocator, root: []const u8, progress: ?Progress, cancel: Cancellation) ![]u8 {
    const venv = try std.Io.Dir.path.join(alloc, &.{ root, "venv" });
    defer alloc.free(venv);
    const python = try std.Io.Dir.path.join(alloc, &.{ venv, "bin", "python" });
    errdefer alloc.free(python);
    if (!try probe(alloc, python, full_probe, cancel)) {
        if (progress) |sink| sink.report(sink.context, "Setting up Python 3.11 kernel (first use needs internet)...");
        const uv = try findUv(alloc);
        defer alloc.free(uv);
        try run(alloc, &.{ uv, "venv", venv, "--python", "3.11", "--allow-existing" }, cancel);
        try run(alloc, &.{ uv, "pip", "install", "--python", python, "dill" }, cancel);
        if (!try probe(alloc, python, full_probe, cancel)) return error.KernelPythonRequiresPython311AndDill;
    }
    return python;
}

/// Interpreters that passed the probe in this process. A probe costs a whole
/// Python start, so each kernel start would otherwise pay for two.
var probed_lock: std.Io.Mutex = .init;
var probed: std.ArrayList([]u8) = .empty;

fn probe(alloc: Allocator, python: []const u8, check: []const u8, cancel: Cancellation) !bool {
    const io = io_mod.getIo();
    // A cached key is the interpreter, a NUL, and the check it passed.
    const key = try std.mem.concat(alloc, u8, &.{ python, "\x00", check });
    defer alloc.free(key);
    probed_lock.lockUncancelable(io);
    for (probed.items) |known| if (std.mem.eql(u8, known, key)) {
        probed_lock.unlock(io);
        return true;
    };
    probed_lock.unlock(io);
    const ok = command(alloc, &.{ python, "-c", check }, cancel, 15_000) catch |err| switch (err) {
        error.OutOfMemory, error.Cancelled => return err,
        else => false,
    };
    if (!ok) return false;
    probed_lock.lockUncancelable(io);
    defer probed_lock.unlock(io);
    const owned = std.heap.c_allocator.dupe(u8, key) catch return true;
    probed.append(std.heap.c_allocator, owned) catch std.heap.c_allocator.free(owned);
    return true;
}

/// Drops a cached probe, after the interpreter failed to start a kernel.
pub fn forget(python: []const u8) void {
    const io = io_mod.getIo();
    probed_lock.lockUncancelable(io);
    defer probed_lock.unlock(io);
    var index: usize = 0;
    while (index < probed.items.len) {
        const known = probed.items[index];
        if (std.mem.startsWith(u8, known, python) and known.len > python.len and known[python.len] == 0) {
            std.heap.c_allocator.free(probed.swapRemove(index));
        } else index += 1;
    }
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
