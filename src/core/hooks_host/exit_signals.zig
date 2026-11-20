//! Stops every hook process group when a CLI surface ends by a signal (R3.9).
//! The handler calls only async-signal-safe functions: `killAll`, which loads
//! atomics and calls `kill(2)`, then `sigaction(2)` and `raise(3)`. It
//! allocates nothing, takes no lock, and writes no trace.

const std = @import("std");
const live_groups = @import("live_groups.zig");

/// The signals a CLI surface that runs hooks handles: a terminal's Ctrl-C, a `kill`, and a hang-up. Callers
/// pass a subset of this list to `installExitSignals` and `restoreExitSignals`, so the list is defined once.
pub const surface_signals = [_]std.posix.SIG{ .TERM, .HUP, .INT };

/// The one signal `fx ask` adds to its own interrupt handler, which covers INT and TERM and cancels the turn.
/// A hang-up must end the process at once, so it gets this handler instead.
pub const hangup_signals = [_]std.posix.SIG{.HUP};

/// What each signal in `surface_signals` had before `installExitSignals` replaced it. `null` means the
/// install left the signal alone, so the restore leaves it alone too.
var previous: [surface_signals.len]?std.posix.Sigaction = @splat(null);

/// The slot of `sig` in `previous`. Callers pass only signals from `surface_signals`, so any other signal
/// is a programmer error.
fn slotOf(sig: std.posix.SIG) usize {
    return std.mem.findScalar(std.posix.SIG, &surface_signals, sig) orelse @panic("exit signal is not in surface_signals");
}

/// Stops the hook groups, then re-raises the signal with its default action, so the process ends by that
/// signal, as it would without this handler.
fn handle(sig: std.posix.SIG) callconv(.c) void {
    live_groups.killAll();
    const default_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &default_action, null);
    _ = std.c.raise(sig);
}

/// Installs `handle` for each signal in `signals`, and keeps the previous dispositions. A signal that starts
/// ignored stays ignored: a parent can start fx with a signal ignored (`nohup` ignores SIGHUP, and a shell's
/// background job ignores SIGINT), and that parent expects fx not to take it, so the install leaves it alone.
/// Call it once, on the main thread, before the surface starts a hook. Pair it with `restoreExitSignals` on
/// the same list.
pub fn installExitSignals(signals: []const std.posix.SIG) void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handle },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for (signals) |sig| {
        const slot = slotOf(sig);
        var current: std.posix.Sigaction = undefined;
        std.posix.sigaction(sig, null, &current);
        if (current.handler.handler == std.posix.SIG.IGN) {
            previous[slot] = null;
            continue;
        }
        var old: std.posix.Sigaction = undefined;
        std.posix.sigaction(sig, &action, &old);
        previous[slot] = old;
    }
}

/// Gives back the dispositions that `installExitSignals` replaced, for the same list. A signal the install
/// left alone is left alone. Call it only after an install.
pub fn restoreExitSignals(signals: []const std.posix.SIG) void {
    for (signals) |sig| {
        const slot = slotOf(sig);
        const old = previous[slot] orelse continue;
        std.posix.sigaction(sig, &old, null);
        previous[slot] = null;
    }
}

test "installExitSignals leaves a signal that starts ignored, and restoreExitSignals keeps it ignored" {
    const ignore_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for (surface_signals) |sig| {
        var saved: std.posix.Sigaction = undefined;
        std.posix.sigaction(sig, &ignore_action, &saved);
        defer std.posix.sigaction(sig, &saved, null);
        installExitSignals(&.{sig});
        var during: std.posix.Sigaction = undefined;
        std.posix.sigaction(sig, null, &during);
        restoreExitSignals(&.{sig});
        var after: std.posix.Sigaction = undefined;
        std.posix.sigaction(sig, null, &after);
        try std.testing.expect(during.handler.handler == std.posix.SIG.IGN);
        try std.testing.expect(after.handler.handler == std.posix.SIG.IGN);
    }
}

test "installExitSignals replaces a default signal, and restoreExitSignals gives the default back" {
    const default_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var saved: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.HUP, &default_action, &saved);
    defer std.posix.sigaction(std.posix.SIG.HUP, &saved, null);
    installExitSignals(&.{std.posix.SIG.HUP});
    var during: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.HUP, null, &during);
    restoreExitSignals(&.{std.posix.SIG.HUP});
    var after: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.HUP, null, &after);
    // `handler` is an untagged C union, so compare the handler pointer, the field the install sets.
    try std.testing.expect(during.handler.handler != std.posix.SIG.DFL);
    try std.testing.expect(after.handler.handler == std.posix.SIG.DFL);
}
