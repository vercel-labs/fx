//! Waiting for a test thread's event, so a thread that never sets it fails its
//! test instead of hanging it.

const std = @import("std");
const io_mod = @import("io.zig");

/// How long a test waits for a thread it started to set its event.
const limit_ms: u32 = 5000;

/// Whether `event` is set within `ms`. The wait ends when the event is set, so
/// a thread that gets there quickly costs the test no time.
fn setWithin(event: *std.Io.Event, ms: u32) bool {
    event.waitTimeout(io_mod.getIo(), .{ .duration = .{
        .clock = .awake,
        .raw = .fromMilliseconds(ms),
    } }) catch return false;
    return true;
}

/// Whether `event` is set within `limit_ms`.
pub fn setInTime(event: *std.Io.Event) bool {
    return setWithin(event, limit_ms);
}

test "an event that is already set is seen at once" {
    var event: std.Io.Event = .unset;
    event.set(io_mod.getIo());
    try std.testing.expect(setInTime(&event));
}

test "an event that another thread sets is seen" {
    const Setter = struct {
        fn run(event: *std.Io.Event) void {
            io_mod.sleep(5 * std.time.ns_per_ms);
            event.set(io_mod.getIo());
        }
    };
    var event: std.Io.Event = .unset;
    const thread = try std.Thread.spawn(.{}, Setter.run, .{&event});
    defer thread.join();
    try std.testing.expect(setInTime(&event));
}

test "an event that nothing sets is not seen within its limit" {
    var event: std.Io.Event = .unset;
    try std.testing.expect(!setWithin(&event, 20));
}
