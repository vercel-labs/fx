//! JSON parsing entry points that share the single `std.json.Value`
//! recursive-descent parser instead of specializing one parser per target
//! type. `std.json.parseFromSlice(T, ...)` instantiates a full parser clone
//! per type (~115 clones, ~94 KiB in the fx binary); funnelling through a
//! `Value` document plus `parseFromValue` keeps only the small tree-walk
//! clone per type.
//!
//! Semantics: `parseFromValue` always copies into the returned arena, so the
//! result matches `.allocate = .alloc_always` — string slices never borrow
//! from `bytes` and callers may free the input immediately.

const std = @import("std");

/// Parses `bytes` as JSON into a fully owned `T`, sharing the common
/// `std.json.Value` parser. Only `options` relevant to tree conversion
/// (`duplicate_field_behavior`, `ignore_unknown_fields`, `max_value_len`)
/// are honored; allocation always matches `.alloc_always`.
pub fn parseOwned(
    comptime T: type,
    alloc: std.mem.Allocator,
    bytes: []const u8,
    options: std.json.ParseOptions,
) !std.json.Parsed(T) {
    var doc = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{
        .max_value_len = options.max_value_len,
    });
    defer doc.deinit();
    return std.json.parseFromValue(T, alloc, doc.value, options);
}
