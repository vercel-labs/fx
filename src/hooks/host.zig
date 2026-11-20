//! What the hooks engine needs from fx. fx fills a Host; the engine starts
//! processes, reads the clock, and writes debug lines only through it.

const std = @import("std");

/// One environment variable fx adds for a hook process.
pub const EnvVar = struct { name: []const u8, value: []const u8 };

/// How to start one hook process. All slices are borrowed for one call.
pub const ProcessRequest = struct {
    /// The program and its arguments. A shell command is {"/bin/sh", "-c", command}.
    argv: []const []const u8,
    stdin: []const u8,
    cwd: []const u8,
    /// Added to the host's clean base environment; on a name clash these win.
    env: []const EnvVar,
    timeout_ms: u32,
    stdout_limit: usize,
    stderr_limit: usize,
    /// When this becomes true, the host stops the process and returns `cancelled`.
    cancel: ?*const std.atomic.Value(bool),
};

/// A process that exited on its own. Buffers are allocated with the allocator passed to `run_process`.
const Exited = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,
    /// The process wrote more than `stdout_limit` bytes; `stdout` holds the first `stdout_limit`.
    stdout_overflow: bool = false,
};

/// How one hook process ended.
pub const ProcessResult = union(enum) {
    exited: Exited,
    /// A signal stopped the process.
    signaled: struct { signal: u32, stderr: []u8 },
    /// The process could not start; the text says why. Allocated like the buffers above.
    spawn_failed: []u8,
    timed_out,
    cancelled,
};

/// The services fx gives the engine.
pub const Host = struct {
    ctx: *anyopaque,
    /// Runs one hook process to its end. Buffers in the result are allocated with `alloc`.
    /// The engine calls it only on a thread that may block.
    run_process: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, request: ProcessRequest) std.mem.Allocator.Error!ProcessResult,
    /// Milliseconds from a monotonic clock, used only to measure how long a hook ran.
    now_ms: *const fn (ctx: *anyopaque) u64,
    /// Writes one debug line. Must not block for long.
    trace: *const fn (ctx: *anyopaque, line: []const u8) void,
};
