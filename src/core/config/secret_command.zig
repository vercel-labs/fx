//! `!command` values for provider keys and headers (D148), as proto's
//! models.yml allows. The text after `!` is split into words, with single and
//! double quotes grouping, and run directly: no shell, so no variable,
//! glob, pipe or substitution expansion. Only the user's own profile files
//! hold these commands; a repository's `.fx.json` cannot. The program gets no
//! terminal input, 10 seconds and 16 KiB of output; its trimmed output is the
//! value. A value is resolved once per process.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const host_target = @import("../hosts/target.zig");
const Allocator = std.mem.Allocator;

const timeout_ms = 10_000;
const max_output = 16 * 1024;
const max_words = 64;

pub const Error = Allocator.Error || error{ InvalidCommand, CommandFailed };

/// Splits `!command args` into words. Words borrow from `text` unless quoted
/// text had to be joined; all memory belongs to `arena`.
pub fn splitWords(arena: Allocator, text: []const u8) Error![]const []const u8 {
    if (text.len < 2 or text[0] != '!') return error.InvalidCommand;
    var words: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quote: ?u8 = null;
    for (text[1..]) |byte| {
        if (quote) |open| {
            if (byte == open) quote = null else try current.append(arena, byte);
            continue;
        }
        switch (byte) {
            ' ', '\t' => if (in_word) {
                try words.append(arena, try current.toOwnedSlice(arena));
                in_word = false;
            },
            '\'', '"' => {
                quote = byte;
                in_word = true;
            },
            else => {
                try current.append(arena, byte);
                in_word = true;
            },
        }
    }
    if (quote != null) return error.InvalidCommand;
    if (in_word) try words.append(arena, try current.toOwnedSlice(arena));
    if (words.items.len == 0 or words.items.len > max_words or words.items[0].len == 0) return error.InvalidCommand;
    return words.items;
}

var cache_mutex: std.Io.Mutex = .init;
var cache: std.array_hash_map.String([]u8) = .empty;

/// The value for `text`: a literal (with a leading `!!` unescaped to `!`), or
/// the trimmed output of the command a single `!` starts. Caller owns it.
pub fn resolve(alloc: Allocator, text: []const u8) Error![]u8 {
    if (text.len == 0 or text[0] != '!') return alloc.dupe(u8, text);
    if (std.mem.startsWith(u8, text, "!!")) return alloc.dupe(u8, text[1..]);
    const io = io_mod.getIo();
    cache_mutex.lockUncancelable(io);
    defer cache_mutex.unlock(io);
    if (cache.get(text)) |value| return alloc.dupe(u8, value);
    const value = try run(std.heap.c_allocator, text);
    errdefer std.heap.c_allocator.free(value);
    const key = try std.heap.c_allocator.dupe(u8, text);
    errdefer std.heap.c_allocator.free(key);
    try cache.put(std.heap.c_allocator, key, value);
    return alloc.dupe(u8, value);
}

/// Runs the command once. Caller owns the trimmed output.
pub fn run(alloc: Allocator, text: []const u8) Error![]u8 {
    if (comptime host_target.is_wasm) return error.CommandFailed;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = try splitWords(arena, text);
    const result = std.process.run(arena, io_mod.getIo(), .{
        .argv = argv,
        .cwd = if (io_mod.homeDir()) |home| .{ .path = home } else .inherit,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CommandFailed,
    };
    defer @memset(result.stdout, 0);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
    const value = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (value.len == 0) return error.CommandFailed;
    return alloc.dupe(u8, value);
}

test "command words split on blanks, group quotes and never expand" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const words = try splitWords(arena, "!op read 'op://Private/Open Router/key' \"$HOME\" a*b");
    try std.testing.expectEqual(@as(usize, 5), words.len);
    try std.testing.expectEqualStrings("op", words[0]);
    try std.testing.expectEqualStrings("op://Private/Open Router/key", words[2]);
    try std.testing.expectEqualStrings("$HOME", words[3]);
    try std.testing.expectEqualStrings("a*b", words[4]);
    try std.testing.expectError(error.InvalidCommand, splitWords(arena, "!echo 'open"));
    try std.testing.expectError(error.InvalidCommand, splitWords(arena, "!  "));
    try std.testing.expectError(error.InvalidCommand, splitWords(arena, "echo"));
}

test "command values run without a shell and literals pass through" {
    const alloc = std.testing.allocator;
    const literal = try resolve(alloc, "plain");
    defer alloc.free(literal);
    try std.testing.expectEqualStrings("plain", literal);
    const escaped = try resolve(alloc, "!!bang");
    defer alloc.free(escaped);
    try std.testing.expectEqualStrings("!bang", escaped);
    const output = try run(alloc, "!printf '  key-$HOME;x  \\n'");
    defer alloc.free(output);
    // printf sees the literal text: no shell expanded `$HOME` or split at `;`.
    try std.testing.expectEqualStrings("key-$HOME;x", output);
    try std.testing.expectError(error.CommandFailed, run(alloc, "!false"));
    try std.testing.expectError(error.CommandFailed, run(alloc, "!fx-no-such-program-for-test"));
}
