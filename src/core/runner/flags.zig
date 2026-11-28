//! Shared argument plumbing for the runner's own command lines. The runner's
//! flags are read through `cli_flags`, which takes sentinel-terminated words.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// The words as sentinel-terminated strings, the form `cli_flags.Parser` reads.
/// The strings live in `arena`.
pub fn sentinelWords(arena: Allocator, words: []const []const u8) Allocator.Error![]const [:0]const u8 {
    const out = try arena.alloc([:0]const u8, words.len);
    for (words, out) |word, *slot| {
        const copy = try arena.allocSentinel(u8, word.len, 0);
        @memcpy(copy, word);
        slot.* = copy;
    }
    return out;
}
