const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const Allocator = std.mem.Allocator;

pub const default_max_tool_result_bytes: usize = 64 * 1024;
pub const min_configured_tool_result_bytes: usize = 1024;

pub fn resolveMaxToolResultBytes(setting: ?usize, default_value: usize) usize {
    return setting orelse default_value;
}

pub const PreparedModelOutput = struct {
    model_output: []u8,
    truncated: bool,
};

/// Returns an owned sanitized copy before any model cap.
pub fn prepareSanitizedOutput(
    alloc: Allocator,
    raw: []const u8,
) error{OutOfMemory}![]u8 {
    var scratch_impl = std.heap.ArenaAllocator.init(alloc);
    defer scratch_impl.deinit();
    const sanitized = try text_utils.sanitizeModelText(scratch_impl.allocator(), raw);
    return alloc.dupe(u8, sanitized);
}

pub fn prepareModelOutput(
    alloc: Allocator,
    tool_name: []const u8,
    raw: []const u8,
    max_bytes: usize,
) error{OutOfMemory}![]const u8 {
    return (try prepareModelOutputWithTruncation(
        alloc,
        tool_name,
        raw,
        max_bytes,
    )).model_output;
}

pub fn prepareModelOutputWithTruncation(
    alloc: Allocator,
    tool_name: []const u8,
    raw: []const u8,
    max_bytes: usize,
) error{OutOfMemory}!PreparedModelOutput {
    var scratch_impl = std.heap.ArenaAllocator.init(alloc);
    defer scratch_impl.deinit();
    const scratch = scratch_impl.allocator();

    const sanitized = try text_utils.sanitizeModelText(scratch, raw);
    const capped = try truncateText(scratch, .{
        .text = sanitized,
        .max_bytes = max_bytes,
        .marker = try scratch.print(
            "\n... [tool result truncated for {s}: original {d} bytes; cap is {d} bytes]\n",
            .{ tool_name, sanitized.len, max_bytes },
        ),
        .trace_scope = "tool",
        .trace_label = tool_name,
    });
    return .{
        .model_output = try alloc.dupe(u8, capped),
        .truncated = sanitized.len > max_bytes,
    };
}

pub fn modelProjectionPreservesText(
    request_scratch: Allocator,
    raw: []const u8,
) error{OutOfMemory}!bool {
    const sanitized = try text_utils.sanitizeModelText(request_scratch, raw);
    return std.mem.eql(u8, raw, sanitized);
}

test "model projection stability rejects non-utf8 identities" {
    var scratch_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const invalid_utf8 = [_]u8{0xff};

    try std.testing.expect(try modelProjectionPreservesText(scratch, "mcp_datadog_list_incidents"));
    try std.testing.expect(!try modelProjectionPreservesText(scratch, &invalid_utf8));
}

pub const PreparedInlineResult = struct {
    model_output: []u8,
    memory: types.ToolResultMemory,
};

pub fn prepareInlineResult(
    alloc: Allocator,
    tool_name: []const u8,
    raw_output: []const u8,
    max_bytes: usize,
) error{OutOfMemory}!PreparedInlineResult {
    const prepared = try prepareModelOutputWithTruncation(
        alloc,
        tool_name,
        raw_output,
        max_bytes,
    );
    return .{
        .model_output = prepared.model_output,
        .memory = .{
            .output_handle = null,
            .preview = null,
            .output_bytes = raw_output.len,
            .stored_output_bytes = prepared.model_output.len,
            .truncated = prepared.truncated,
        },
    };
}

pub const TruncateOptions = struct {
    text: []const u8,
    max_bytes: usize,
    marker: []const u8,
    trace_scope: []const u8 = "tool",
    trace_label: []const u8 = "result",
};

pub fn truncateText(arena: std.mem.Allocator, opts: TruncateOptions) ![]const u8 {
    if (opts.text.len <= opts.max_bytes) return opts.text;

    const prefix_cap = if (opts.max_bytes > opts.marker.len)
        opts.max_bytes - opts.marker.len
    else
        0;
    const prefix_len = text_utils.utf8BackwardBoundary(opts.text, prefix_cap);

    debug_trace.logf(
        opts.trace_scope,
        "model-facing tool result truncated label={s} original_bytes={d} cap_bytes={d}",
        .{ opts.trace_label, opts.text.len, opts.max_bytes },
    );

    if (prefix_len == 0) return try arena.dupe(u8, opts.marker);
    return try std.mem.concat(arena, u8, &.{ opts.text[0..prefix_len], opts.marker });
}

test "prepareModelOutput preserves secret-shaped assignments verbatim" {
    const alloc = std.testing.allocator;
    const raw = "token=abcdefghijklmnopqrstuvwxyz";
    const output = try prepareModelOutput(alloc, "mcp__server__tool", raw, default_max_tool_result_bytes);
    defer alloc.free(@constCast(output));

    try std.testing.expectEqualStrings(raw, output);
}

test "prepareModelOutput preserves quoted sensitive assignments verbatim" {
    const alloc = std.testing.allocator;
    const raw = "API_KEY=\"secret-value-123456\"";
    const output = try prepareModelOutput(alloc, "run_command", raw, default_max_tool_result_bytes);
    defer alloc.free(@constCast(output));

    try std.testing.expectEqualStrings(raw, output);
}

test "prepareInlineResult preserves assignments without reclassifying lengths" {
    const alloc = std.testing.allocator;
    const raw = "AI_GATEWAY_KEY=abcdefghijklmnop";
    const prepared = try prepareInlineResult(
        alloc,
        "mcp__server__tool",
        raw,
        default_max_tool_result_bytes,
    );
    defer alloc.free(prepared.model_output);

    try std.testing.expectEqualStrings(raw, prepared.model_output);
    try std.testing.expect(!prepared.memory.truncated);
    try std.testing.expectEqual(raw.len, prepared.memory.output_bytes);
    try std.testing.expectEqual(raw.len, prepared.memory.stored_output_bytes);
}

test "prepareModelOutput caps chatty output with explicit marker" {
    const alloc = std.testing.allocator;
    var bytes: [256]u8 = @splat('x');
    const output = try prepareModelOutput(alloc, "grep_files", bytes[0..], 128);
    defer alloc.free(@constCast(output));

    try std.testing.expect(output.len <= 128);
    try std.testing.expect(std.mem.find(u8, output, "... [tool result truncated for grep_files: original 256 bytes; cap is 128 bytes]") != null);
}

test "prepareModelOutput keeps complete codepoints at the cap" {
    const alloc = std.testing.allocator;
    const text = "x" ++ text_utils.repeat("\xc3\xa9", 300);
    for ([_]usize{ 128, 129 }) |cap| {
        const output = try prepareModelOutput(alloc, "grep_files", text, cap);
        defer alloc.free(@constCast(output));
        try std.testing.expect(output.len <= cap);
        const marker_start = std.mem.find(u8, output, "\n... [tool result truncated").?;
        const prefix = output[0..marker_start];
        try std.testing.expect(std.unicode.utf8ValidateSlice(prefix));
        try std.testing.expect(std.mem.endsWith(u8, prefix, "\xc3\xa9"));
    }
}
