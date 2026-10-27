//! The browser front door for sessions (D197): one `Slot` per session
//! runtime holds the node's browser, if the browser tool opened one. Attach
//! and detach never change its lifetime; the session closing or resetting
//! closes the browser, its tabs, and a launched browser's process.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const browser_mod = @import("browser.zig");
const debug_trace = @import("../shared/debug_trace.zig");

pub const Browser = browser_mod.Browser;

pub const Slot = struct {
    /// Held for a whole browser call, so calls of one node never interleave
    /// on the connection.
    lock: std.Io.Mutex = .init,
    browser: ?*Browser = null,

    pub fn acquire(self: *Slot) void {
        self.lock.lockUncancelable(io_mod.getIo());
    }

    pub fn release(self: *Slot) void {
        self.lock.unlock(io_mod.getIo());
    }

    /// Closes the browser. Only the owning session calls this, after tool
    /// callers have joined; a session may reset and call it again.
    pub fn deinit(self: *Slot) void {
        self.acquire();
        defer self.release();
        self.closeLocked();
    }

    /// Closes the browser while the caller holds the lock.
    pub fn closeLocked(self: *Slot) void {
        if (self.browser) |browser| {
            debug_trace.logf("browser", "event=close label={s} tabs={d}", .{ browser.label, browser.tabs.items.len });
            browser.close();
        }
        self.browser = null;
    }
};

test "an empty browser slot closes without a browser and can close again" {
    var slot: Slot = .{};
    slot.deinit();
    slot.deinit();
    try std.testing.expect(slot.browser == null);
}
