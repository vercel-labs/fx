//! Tests of the two places `native_keychain.zig` reads a secret from a child
//! process: the API key read, and the runner the OAuth session and MCP
//! credential reads share. Each runs a fake child in place of `/usr/bin/security`
//! or `osascript`, so none of them touches the real Keychain. The tests that
//! store to or delete from the real Keychain stay in `native_keychain.zig`,
//! which `src/main.zig` does not run.
const std = @import("std");
const builtin = @import("builtin");
const native_keychain = @import("native_keychain.zig");
const secret = @import("../auth/secret.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");

/// The largest reply the OAuth session and MCP credential reads accept.
const reply_limit: usize = 1024 * 1024;

/// A child that prints `first` and `second` joined, `filler` bytes of filler,
/// then `tail`'s command, as a Keychain read prints a saved session. With 4 KiB
/// of filler the reply outgrows the reader's first buffer several times. The
/// marker travels in two words, so the spawn's own copies of the arguments and
/// the environment never hold all of it.
fn replyArgvWords(first: []const u8, second: []const u8, filler: []const u8, comptime tail: []const u8) [7][]const u8 {
    const script = "printf '%s%s' \"$1\" \"$2\"; head -c \"$3\" /dev/zero | tr '\\0' x" ++ tail;
    return .{ "/bin/sh", "-c", script, "sh", first, second, filler };
}

fn replyArgv(marker: []const u8, filler: []const u8, comptime tail: []const u8) [7][]const u8 {
    const half = marker.len / 2;
    return replyArgvWords(marker[0..half], marker[half..], filler, tail);
}

const reply_filler = "4096";
const reply_filler_bytes = 4096;

test "a Keychain read gives back no block that holds the reply it grew" {
    if (comptime builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    const marker = "KEYCHAIN_SESSION_MARK";
    // With a trailing newline the read copies the key out of the reply; without
    // one it returns the reply block itself.
    inline for (.{ "; printf '\\n'", "" }) |tail| {
        var scan: testing_allocator.ReleaseScan = .{ .needle = marker };
        const argv = replyArgv(marker, reply_filler, tail);
        const key = (try native_keychain.loadFromChild(scan.allocator(), &argv)) orelse
            return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.startsWith(u8, key, marker));
        try std.testing.expectEqual(marker.len + reply_filler_bytes, key.len);
        secret.zeroAndFree(scan.allocator(), key);
        try scan.expectWiped();
    }
}

test "a failed Keychain read gives back no block that holds what the child printed" {
    if (comptime builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    const marker = "KEYCHAIN_FAILED_MARK";
    var scan: testing_allocator.ReleaseScan = .{ .needle = marker };
    const argv = replyArgv(marker, reply_filler, "; exit 3");
    try std.testing.expectError(
        error.KeychainReadFailed,
        native_keychain.loadFromChild(scan.allocator(), &argv),
    );
    try scan.expectWiped();
}

test "an empty Keychain read returns nothing and holds nothing" {
    if (comptime builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    var scan: testing_allocator.ReleaseScan = .{ .needle = "KEYCHAIN_EMPTY_MARK" };
    const argv: []const []const u8 = &.{ "/bin/sh", "-c", "exit 0" };
    try std.testing.expect(try native_keychain.loadFromChild(scan.allocator(), argv) == null);
    try std.testing.expectEqual(@as(usize, 0), scan.holding);
}

test "the Keychain runner gives back no block that holds the reply it grew" {
    if (comptime builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    const marker = "KEYCHAIN_RUNNER_MARK";
    const argv = replyArgv(marker, reply_filler, "; printf '\\n'");
    var never_cancelled = std.atomic.Value(bool).init(false);
    // Without a flag the child runs in this task; with one it runs in a task
    // the cancel watch races against.
    for ([_]?*const std.atomic.Value(bool){ null, &never_cancelled }) |flag| {
        var scan: testing_allocator.ReleaseScan = .{ .needle = marker };
        const alloc = scan.allocator();
        const result = try native_keychain.runMcpKeychainProcess(alloc, &argv, flag, .limited(reply_limit + 1));
        try std.testing.expect(std.mem.startsWith(u8, result.stdout, marker));
        secret.zeroAndFree(alloc, result.stdout);
        alloc.free(result.stderr);
        try scan.expectWiped();
    }
}

test "a Keychain reply over the limit gives back no block that holds it" {
    if (comptime builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    const marker = "KEYCHAIN_LIMIT_MARK";
    var scan: testing_allocator.ReleaseScan = .{ .needle = marker };
    const argv = replyArgv(marker, reply_filler, "; printf '\\n'");
    try std.testing.expectError(
        error.StreamTooLong,
        native_keychain.runMcpKeychainProcess(scan.allocator(), &argv, null, .limited(1024)),
    );
    try scan.expectWiped();
}

test "Keychain reads over libc return the reply and leave the marker to the scan" {
    if (comptime builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    // tests/tla/drivers/secret/driver.ts runs this test with scan.c loaded, the
    // two halves of the marker and the filler size in these variables, so the
    // blocks libc gets back are looked at. The halves keep the whole marker out
    // of the environment copy the spawn makes. Run by itself it checks the
    // reads still return what the child printed.
    const first: []const u8 = if (std.c.getenv("FX_SECRET_SCAN_KEYCHAIN_FIRST")) |value|
        std.mem.span(value)
    else
        "KEYCHAIN_LIBC_";
    const second: []const u8 = if (std.c.getenv("FX_SECRET_SCAN_KEYCHAIN_SECOND")) |value|
        std.mem.span(value)
    else
        "MARK";
    const filler: []const u8 = if (std.c.getenv("FX_SECRET_SCAN_KEYCHAIN_BYTES")) |value|
        std.mem.span(value)
    else
        reply_filler;
    const filler_bytes = try std.fmt.parseInt(usize, filler, 10);
    const reply_bytes = first.len + second.len + filler_bytes;
    const alloc = std.heap.c_allocator;
    const argv = replyArgvWords(first, second, filler, "; printf '\\n'");

    const key = (try native_keychain.loadFromChild(alloc, &argv)) orelse
        return error.TestUnexpectedResult;
    defer secret.zeroAndFree(alloc, key);
    try expectMarkerFirst(key, first, second);
    try std.testing.expectEqual(reply_bytes, key.len);

    const result = try native_keychain.runMcpKeychainProcess(alloc, &argv, null, .limited(reply_limit + 1));
    defer alloc.free(result.stderr);
    defer secret.zeroAndFree(alloc, result.stdout);
    try expectMarkerFirst(result.stdout, first, second);
    try std.testing.expectEqual(reply_bytes + 1, result.stdout.len);
}

fn expectMarkerFirst(reply: []const u8, first: []const u8, second: []const u8) !void {
    try std.testing.expect(std.mem.startsWith(u8, reply, first));
    try std.testing.expect(std.mem.startsWith(u8, reply[first.len..], second));
}
