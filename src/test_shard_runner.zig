//! Shard-aware test runner. Declared with `.mode = .simple` in build.zig, so
//! `std.Build.addRunArtifact` does not enable the build-runner IPC protocol
//! (`std.zig.Server`) for this executable at all: it runs this as a plain
//! process and reads its exit code. That keeps this file built entirely from
//! stable, public APIs (`builtin.test_functions`, `std.testing`, `std.Io`),
//! with no coupling to the compiler's internal test-runner protocol.
//!
//! The per-test setup/teardown loop mirrors Zig's own non-server ("terminal
//! mode") test runner, restricted to a disjoint modulo slice of
//! `builtin.test_functions` selected via `FX_TEST_SHARD` / `FX_TEST_SHARD_COUNT`.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;

fn shardEnv(environ: std.process.Environ, comptime name: []const u8, default: u32) u32 {
    const value = std.process.Environ.getAlloc(environ, std.heap.page_allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return default,
        else => std.debug.panic("unable to read {s}: {t}", .{ name, err }),
    };
    defer std.heap.page_allocator.free(value);
    return std.fmt.parseInt(u32, value, 10) catch
        std.debug.panic("unable to parse {s}", .{name});
}

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    const shard = shardEnv(init.environ, "FX_TEST_SHARD", 0);
    const shard_count = shardEnv(init.environ, "FX_TEST_SHARD_COUNT", 1);
    if (shard_count == 0) @panic("FX_TEST_SHARD_COUNT must be at least 1");
    if (shard >= shard_count) @panic("FX_TEST_SHARD must be below FX_TEST_SHARD_COUNT");

    const test_fn_list = builtin.test_functions;
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var leaks: usize = 0;

    var index: usize = shard;
    while (index < test_fn_list.len) : (index += shard_count) {
        const test_fn = test_fn_list[index];
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        defer {
            testing.io_instance.deinit();
            if (testing.allocator_instance.deinit() == .leak) leaks += 1;
        }
        testing.log_level = .warn;
        testing.environ = init.environ;

        if (test_fn.func()) |_| {
            ok_count += 1;
        } else |err| switch (err) {
            error.SkipZigTest => skip_count += 1,
            else => {
                fail_count += 1;
                std.debug.print("{s}...FAIL ({t})\n", .{ test_fn.name, err });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
            },
        }
    }

    std.debug.print(
        "shard {d}/{d}: {d} passed, {d} skipped, {d} failed\n",
        .{ shard, shard_count, ok_count, skip_count, fail_count },
    );
    if (log_err_count != 0) {
        std.debug.print("{d} errors were logged.\n", .{log_err_count});
    }
    if (leaks != 0) {
        std.debug.print("{d} tests leaked memory.\n", .{leaks});
    }
    if (leaks != 0 or log_err_count != 0 or fail_count != 0) {
        std.process.exit(1);
    }
}

/// std.testing.fuzz unconditionally delegates to `@import("root").fuzz`, so
/// any custom test runner must provide this. We never run `zig build test
/// --fuzz`, so only the non-fuzzing corpus-replay behavior is implemented,
/// matching what Zig's own runner does when `builtin.fuzz` is false.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), smith: *testing.Smith) anyerror!void,
    options: testing.FuzzInputOptions,
) anyerror!void {
    if (builtin.fuzz) @panic("zig build test --fuzz is not supported by this shard-aware test runner");
    for (options.corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
    var smith: testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}

fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
