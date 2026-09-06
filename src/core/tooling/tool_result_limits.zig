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

/// Returns an owned sanitized and secret-masked copy before any model cap.
pub fn prepareRedactedOutput(
    alloc: Allocator,
    raw: []const u8,
) error{OutOfMemory}![]u8 {
    var scratch_impl = std.heap.ArenaAllocator.init(alloc);
    defer scratch_impl.deinit();
    const redacted = try redactModelText(scratch_impl.allocator(), raw);
    return alloc.dupe(u8, redacted);
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

    const redacted = try redactModelText(scratch, raw);
    const capped = try truncateText(scratch, .{
        .text = redacted,
        .max_bytes = max_bytes,
        .marker = try std.fmt.allocPrint(
            scratch,
            "\n... [tool result truncated for {s}: original {d} bytes; cap is {d} bytes]\n",
            .{ tool_name, redacted.len, max_bytes },
        ),
        .trace_scope = "tool",
        .trace_label = tool_name,
    });
    return .{
        .model_output = try alloc.dupe(u8, capped),
        .truncated = redacted.len > max_bytes,
    };
}

/// Returns an owned, bounded model projection without replacing secret-like
/// text. This is reserved for explicit `read_tool_result` retrieval, where the
/// model requested exact bytes from an already bounded result page or query.
pub fn prepareUnmaskedModelOutputWithTruncation(
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
        .marker = try std.fmt.allocPrint(
            scratch,
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

fn redactModelText(
    alloc: Allocator,
    raw: []const u8,
) error{OutOfMemory}![]const u8 {
    const sanitized = try text_utils.sanitizeModelText(alloc, raw);
    return text_utils.maskSecrets(alloc, sanitized) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
    };
}

pub fn modelProjectionPreservesText(
    request_scratch: Allocator,
    raw: []const u8,
) error{OutOfMemory}!bool {
    const sanitized = try text_utils.sanitizeModelText(request_scratch, raw);
    const masked = text_utils.maskSecrets(request_scratch, sanitized) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    return std.mem.eql(u8, raw, masked);
}

test "model projection stability rejects sanitized and secret-bearing identities" {
    var scratch_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const invalid_utf8 = [_]u8{0xff};

    try std.testing.expect(try modelProjectionPreservesText(scratch, "mcp_datadog_list_incidents"));
    try std.testing.expect(!try modelProjectionPreservesText(scratch, &invalid_utf8));
    try std.testing.expect(!try modelProjectionPreservesText(scratch, "token=secret-value"));
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

test "prepareModelOutput masks secrets before applying cap" {
    const alloc = std.testing.allocator;
    const output = try prepareModelOutput(alloc, "mcp__server__tool", "token=secret-value", default_max_tool_result_bytes);
    defer alloc.free(@constCast(output));

    try std.testing.expectEqualStrings("token=[redacted]", output);
}

test "prepareModelOutput masks quoted sensitive assignments" {
    const alloc = std.testing.allocator;
    const output = try prepareModelOutput(alloc, "run_command", "API_KEY=\"secret-value\"", default_max_tool_result_bytes);
    defer alloc.free(@constCast(output));

    try std.testing.expectEqualStrings("API_KEY=\"[redacted]\"", output);
}

test "prepareUnmaskedModelOutput preserves secret-like text" {
    const alloc = std.testing.allocator;
    const raw = "TOOL_DATA_TOKEN=0123456789abcdef01234567";
    const prepared = try prepareUnmaskedModelOutputWithTruncation(
        alloc,
        "read_tool_result",
        raw,
        default_max_tool_result_bytes,
    );
    defer alloc.free(prepared.model_output);

    try std.testing.expectEqualStrings(raw, prepared.model_output);
    try std.testing.expect(!prepared.truncated);
}

test "prepareInlineResult does not classify redaction shrink as cap loss" {
    const alloc = std.testing.allocator;
    const raw = "AI_GATEWAY_API_KEY=abcdefghijklmnop end";
    const prepared = try prepareInlineResult(
        alloc,
        "mcp__server__tool",
        raw,
        default_max_tool_result_bytes,
    );
    defer alloc.free(prepared.model_output);

    try std.testing.expectEqualStrings(
        "AI_GATEWAY_API_KEY=[redacted] end",
        prepared.model_output,
    );
    try std.testing.expect(prepared.model_output.len < raw.len);
    try std.testing.expect(!prepared.memory.truncated);
    try std.testing.expectEqual(raw.len, prepared.memory.output_bytes);
}

test "prepareInlineResult classifies cap loss after redaction expansion" {
    const alloc = std.testing.allocator;
    const raw = "CUSTOM_API_KEY=abc123\n" ** 46;
    try std.testing.expectEqual(@as(usize, 1012), raw.len);

    const prepared = try prepareInlineResult(
        alloc,
        "mcp__server__tool",
        raw,
        min_configured_tool_result_bytes,
    );
    defer alloc.free(prepared.model_output);

    try std.testing.expectEqual(min_configured_tool_result_bytes, prepared.model_output.len);
    try std.testing.expect(prepared.memory.truncated);
    try std.testing.expect(std.mem.find(u8, prepared.model_output, "abc123") == null);
    try std.testing.expect(std.mem.find(u8, prepared.model_output, "[redacted]") != null);
}

test "prepareModelOutput caps chatty output with explicit marker" {
    const alloc = std.testing.allocator;
    var bytes = [_]u8{'x'} ** 256;
    const output = try prepareModelOutput(alloc, "grep_files", bytes[0..], 128);
    defer alloc.free(@constCast(output));

    try std.testing.expect(output.len <= 128);
    try std.testing.expect(std.mem.find(u8, output, "... [tool result truncated for grep_files: original 256 bytes; cap is 128 bytes]") != null);
}

test "prepareModelOutput keeps complete codepoints at the cap" {
    const alloc = std.testing.allocator;
    const text = "x" ++ ("\xc3\xa9" ** 300);
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
