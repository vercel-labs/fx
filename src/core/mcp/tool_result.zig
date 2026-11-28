const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const mem_utils = @import("../shared/mem_utils.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_result_cut_marker = @import("../shared/tool_result_cut_marker.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const server_json_depth = @import("server_json_depth.zig");
const tools_feature = @import("features/tools.zig");

const tool_content = @import("../tooling/tool_content.zig");
const image_data = @import("../images/image_data.zig");
const types = @import("../shared/types.zig");
const Allocator = std.mem.Allocator;

pub const ExtractOptions = struct {
    server_name: []const u8,
    tool_name: []const u8,
    response: []const u8,
    max_tool_result_bytes: usize,
    protocol: tools_feature.Protocol,
    output_schema_json: ?[]const u8 = null,
};

/// Parses an MCP response into the bounded, sanitized model result.
/// The caller owns every allocation in the returned result.
pub fn extract(alloc: Allocator, options: ExtractOptions) !tool_mcp_runtime.CallResult {
    var outcome = tools_feature.parseCallOutcome(
        alloc,
        options.response,
        options.protocol,
        options.output_schema_json,
        @max(options.max_tool_result_bytes, image_data.max_result_frame_bytes),
        .{},
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const raw = if (err == error.NestingTooDeep)
            try alloc.print("MCP protocol failure: the server's reply is nested deeper than fx accepts ({d} levels)", .{server_json_depth.max_server_json_depth})
        else
            try alloc.print("MCP protocol failure: {s}", .{@errorName(err)});
        defer alloc.free(raw);
        return .{
            .model_output = try tool_result_limits.prepareModelOutput(
                alloc,
                options.tool_name,
                raw,
                options.max_tool_result_bytes,
            ),
            .status = .protocol_failure,
        };
    };
    defer outcome.deinit(alloc);
    return switch (outcome) {
        .complete => |complete| blk: {
            var parsed = std.json.parseFromSlice(
                std.json.Value,
                alloc,
                complete.result_json,
                .{ .parse_numbers = false },
            ) catch return error.McpInvalidJson;
            defer parsed.deinit();
            var images: []types.ToolImage = &.{};
            errdefer types.freeToolImages(alloc, images);
            if (parsed.value.object.getPtr("content")) |content| {
                if (content.* == .array) images = try image_data.parseToolImages(alloc, content.array.items);
                try tool_content.projectMediaForText(parsed.arena.allocator(), content);
            }
            break :blk .{
                .images = images,
                .model_output = try serialize_capped(
                    alloc,
                    options.server_name,
                    options.tool_name,
                    parsed.value,
                    options.max_tool_result_bytes,
                ),
                .status = if (complete.is_error) .tool_failure else .success,
            };
        },
        .protocol_failure => |failure| .{
            .model_output = try render_owned_protocol_error(
                alloc,
                options.tool_name,
                failure,
                options.max_tool_result_bytes,
            ),
            .status = .protocol_failure,
        },
    };
}

fn render_owned_protocol_error(
    alloc: Allocator,
    tool_name: []const u8,
    failure: tools_feature.ProtocolError,
    max_tool_result_bytes: usize,
) ![]const u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(scratch_state);
    const scratch = scratch_state.allocator();
    var raw: std.Io.Writer.Allocating = .init(scratch);
    try write_protocol_diagnostic(
        scratch,
        &raw.writer,
        failure.code,
        failure.message,
        failure.data_json,
    );
    return tool_result_limits.prepareModelOutput(
        alloc,
        tool_name,
        raw.writer.buffered(),
        max_tool_result_bytes,
    );
}

/// The words every protocol error text starts with, before its code: this file writes them in
/// `write_protocol_diagnostic`, and reads them in `invalid_params_prefix` and `protocolErrorWithoutData`.
const protocol_error_words = "MCP protocol error ";

/// The label between a protocol error's message and its data: this file writes it in
/// `write_protocol_diagnostic`, and reads it in `withoutData` and the tests of the readers.
const data_label = "; data=";

fn write_protocol_diagnostic(
    scratch: Allocator,
    writer: *std.Io.Writer,
    code: i64,
    message: []const u8,
    data_json: ?[]const u8,
) !void {
    try writer.print(protocol_error_words ++ "{d}: ", .{code});
    const safe_message = try text_utils.sanitizeModelText(scratch, message);
    try writer.writeAll(safe_message);
    if (data_json) |data| {
        const safe_data = try text_utils.sanitizeModelText(scratch, data);
        try writer.writeAll(data_label);
        try writer.writeAll(safe_data);
    }
}

const invalid_params_prefix = protocol_error_words ++ "-32602: ";
const max_cause_fields = 3;
const max_cause_bytes = 240;

/// Why an MCP server refused a call's parameters, as one short line, read from
/// the text `write_protocol_diagnostic` wrote for a JSON-RPC -32602 error. It
/// names each field and type the server's validator reported, in the Go SDK's
/// words or as the TypeScript SDK's zod issues, and otherwise says the server
/// refused the parameters, which is also how servers answer an unknown tool.
/// Null for any other text, so callers keep showing what they showed before.
/// The line has no control bytes or line breaks and is at most
/// `max_cause_bytes` long; it is allocated in `arena`.
/// (`tests/e2e/mcp-stdio.test.ts` "the TUI and the trace name the rejected
/// arguments when an MCP server refuses a call's parameters")
pub fn invalidParamsCause(arena: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    if (!std.mem.startsWith(u8, text, invalid_params_prefix)) return null;
    const message = (try protocolErrorWithoutData(arena, text))[invalid_params_prefix.len..];
    var line: std.Io.Writer.Allocating = .init(arena);
    const named = (writeGoRejections(&line.writer, message) catch return error.OutOfMemory) or
        try writeZodRejections(arena, &line.writer, message);
    if (!named) line.writer.writeAll("the server rejected the call's parameters (-32602)") catch return error.OutOfMemory;
    // Mask before the length cut, which could leave a token too short to match.
    const masked = text_utils.maskSecrets(arena, line.written()) catch return error.OutOfMemory;
    const encoded = try text_utils.encodeTerminalSafeInline(arena, masked, max_cause_bytes);
    return encoded.bytes;
}

/// `text` without the data of a protocol error: the words of `write_protocol_diagnostic`, `protocol_error_words`
/// and `<code>: `, and the server's message, for any code, and none of the `; data=` and the data after it (see
/// `withoutData`). Text that does not start with those words comes back as it is. A line that shows what the
/// server said, and not what it sent for the model, reads this.
/// (`tests/e2e/mcp-stdio.test.ts` "an error's data never reaches a trace, a log line, the trace report or the cause line")
pub fn protocolErrorWithoutData(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (!std.mem.startsWith(u8, text, protocol_error_words)) return text;
    const code_start = protocol_error_words.len;
    var at = code_start;
    if (at < text.len and text[at] == '-') at += 1;
    const digits_start = at;
    while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
    if (at == digits_start or !std.mem.startsWith(u8, text[at..], ": ")) return text;
    const message_start = at + ": ".len;
    const message = try withoutData(arena, text[message_start..]);
    return text[0 .. message_start + message.len];
}

/// The message of the text `write_protocol_diagnostic` wrote, without the `; data=` and the data it
/// adds when the server gave some. The data is JSON to the end of the text, or the start of JSON when
/// the text was cut, so the first `; data=` whose rest is one JSON value, or a prefix of one, is the
/// one it wrote. The data can never put a label before the real one: the message comes first. A
/// message that says `; data=` itself stays whole while no JSON follows it. When the server's own
/// message has a `; data=` that the start of JSON follows, such as `; data="`, the data can decide
/// whether fx cuts there, so the cause can lose the fields after it. The cause still never holds a
/// word of the data, because every cut is inside the message. The marker that ends a text the result
/// cap cut is not part of the data.
fn withoutData(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const body = withoutCutMarker(text);
    var from: usize = 0;
    while (std.mem.find(u8, body[from..], data_label)) |found| {
        const at = from + found;
        if (try isJsonOrPrefix(arena, body[at + data_label.len ..])) return text[0..at];
        from = at + 1;
    }
    return text;
}

/// `text` without the one-line marker `truncateText` ends a cut text with.
fn withoutCutMarker(text: []const u8) []const u8 {
    const start = std.mem.findLast(u8, text, tool_result_cut_marker.cut_marker_start) orelse return text;
    const marker = text[start..];
    if (!std.mem.endsWith(u8, marker, tool_result_cut_marker.cut_marker_end)) return text;
    if (std.mem.findScalar(u8, marker[1 .. marker.len - 1], '\n') != null) return text;
    return text[0..start];
}

/// Whether `rest` is one JSON value, or the start of one that was cut (it ends inside the value).
fn isJsonOrPrefix(arena: Allocator, rest: []const u8) Allocator.Error!bool {
    var scanner: std.json.Scanner = .initCompleteInput(arena, rest);
    defer scanner.deinit();
    while (true) {
        const token = scanner.next() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnexpectedEndOfInput => return true,
            error.SyntaxError, error.BufferUnderrun => return false,
        };
        if (token == .end_of_document) return true;
    }
}

/// The Go SDK's validator names one field a line:
/// `validating /properties/limit: type: "40" has type "string", want "number"`.
fn writeGoRejections(writer: *std.Io.Writer, message: []const u8) std.Io.Writer.Error!bool {
    const marker = "validating /properties/";
    var count: usize = 0;
    var rest = message;
    while (std.mem.find(u8, rest, marker)) |at| {
        rest = rest[at + marker.len ..];
        const entry = rest[0 .. std.mem.findScalar(u8, rest, '\n') orelse rest.len];
        const field_end = std.mem.find(u8, entry, ": ") orelse continue;
        const actual = quotedAfter(entry[field_end..], "has type \"") orelse continue;
        const want_at = std.mem.find(u8, entry[field_end..], ", want ") orelse continue;
        const want = wantedType(entry[field_end + want_at + ", want ".len ..]) orelse continue;
        if (count == max_cause_fields) {
            try writer.writeAll("; and more");
            break;
        }
        try writer.writeAll(if (count == 0) "arguments rejected: " else "; ");
        try writeFieldPath(writer, entry[0..field_end]);
        try writer.print(" is {s}, the schema wants {s}", .{ typeWithArticle(actual), typeWithArticle(want) });
        count += 1;
    }
    return count > 0;
}

/// The type after `want `: a quoted name, a bracketed list, or one bare word.
/// Whatever the server wrote after it stays out of the cause.
fn wantedType(after_want: []const u8) ?[]const u8 {
    const text = std.mem.trimStart(u8, after_want, " \t");
    if (text.len == 0) return null;
    const want = switch (text[0]) {
        '"' => text[1 .. 1 + (std.mem.findScalar(u8, text[1..], '"') orelse return null)],
        '[' => text[0 .. 1 + (std.mem.findScalar(u8, text, ']') orelse return null)],
        else => text[0 .. std.mem.findAny(u8, text, " \t\r,;") orelse text.len],
    };
    return if (want.len == 0) null else want;
}

/// The TypeScript SDK sends zod's issues as a JSON array:
/// `[{"code":"invalid_type","expected":"number","received":"string","path":["limit"]}]`.
fn writeZodRejections(arena: Allocator, writer: *std.Io.Writer, message: []const u8) Allocator.Error!bool {
    const open = std.mem.findScalar(u8, message, '[') orelse return false;
    const close = std.mem.findScalarLast(u8, message, ']') orelse return false;
    if (close <= open) return false;
    const issues = std.json.parseFromSliceLeaky(std.json.Value, arena, message[open .. close + 1], .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    if (issues != .array) return false;
    var count: usize = 0;
    for (issues.array.items) |issue| {
        if (issue != .object) continue;
        const expected = issue.object.get("expected") orelse continue;
        if (expected != .string or expected.string.len == 0) continue;
        if (count == max_cause_fields) {
            writer.writeAll("; and more") catch return error.OutOfMemory;
            break;
        }
        writer.writeAll(if (count == 0) "arguments rejected: " else "; ") catch return error.OutOfMemory;
        writeZodPath(writer, issue.object.get("path")) catch return error.OutOfMemory;
        const received = issue.object.get("received");
        if (received != null and received.? == .string and received.?.string.len > 0) {
            writer.print(" is {s}, the schema wants {s}", .{ typeWithArticle(received.?.string), typeWithArticle(expected.string) }) catch return error.OutOfMemory;
        } else {
            writer.print(" must be {s}", .{typeWithArticle(expected.string)}) catch return error.OutOfMemory;
        }
        count += 1;
    }
    return count > 0;
}

fn quotedAfter(text: []const u8, opening: []const u8) ?[]const u8 {
    const start = (std.mem.find(u8, text, opening) orelse return null) + opening.len;
    const len = std.mem.findScalar(u8, text[start..], '"') orelse return null;
    return if (len == 0) null else text[start..][0..len];
}

/// `filter/properties/env` as `filter.env`.
fn writeFieldPath(writer: *std.Io.Writer, path: []const u8) std.Io.Writer.Error!void {
    var rest = path;
    while (std.mem.find(u8, rest, "/properties/")) |at| {
        try writer.writeAll(rest[0..at]);
        try writer.writeByte('.');
        rest = rest[at + "/properties/".len ..];
    }
    try writer.writeAll(rest);
}

fn writeZodPath(writer: *std.Io.Writer, path: ?std.json.Value) std.Io.Writer.Error!void {
    const empty: []const std.json.Value = &.{};
    const parts: []const std.json.Value = if (path) |value| (if (value == .array) value.array.items else empty) else empty;
    var written: usize = 0;
    for (parts) |part| {
        switch (part) {
            .string => |name| {
                if (written > 0) try writer.writeByte('.');
                try writer.writeAll(name);
            },
            .integer => |index| try writer.print("[{d}]", .{index}),
            else => continue,
        }
        written += 1;
    }
    if (written == 0) try writer.writeAll("the arguments object");
}

fn typeWithArticle(json_type: []const u8) []const u8 {
    const names = [_]struct { []const u8, []const u8 }{
        .{ "string", "a string" },   .{ "number", "a number" }, .{ "integer", "an integer" },
        .{ "boolean", "a boolean" }, .{ "array", "an array" },  .{ "object", "an object" },
    };
    for (names) |name| if (std.mem.eql(u8, name[0], json_type)) return name[1];
    return json_type;
}

fn serialize_capped(
    alloc: Allocator,
    server_name: []const u8,
    tool_name: []const u8,
    result: std.json.Value,
    max_tool_result_bytes: usize,
) ![]u8 {
    var arena_impl = std.heap.ArenaAllocator.init(alloc);
    defer mem_utils.deinit_arena(arena_impl);
    const arena = arena_impl.allocator();

    var full = std.Io.Writer.Allocating.init(arena);
    try write_envelope(arena, &full.writer, server_name, tool_name, result);
    const full_output = full.writer.buffered();
    if (full_output.len <= max_tool_result_bytes) {
        return try alloc.dupe(u8, full_output);
    }

    const combined = try collect_result_text(arena, result);
    const marker = try arena.print(
        "\n... [mcp tool result truncated for {s}/{s}: original {d} bytes; cap is {d} bytes]\n",
        .{ server_name, tool_name, full_output.len, max_tool_result_bytes },
    );

    const truncation_source = if (combined.len == 0) marker else combined;
    var low: usize = 0;
    var high: usize = @min(
        truncation_source.len + marker.len,
        max_tool_result_bytes,
    );
    var best: []const u8 = "";
    while (low <= high) {
        const mid = low + (high - low) / 2;
        const inner = try tool_result_limits.truncateText(arena, .{
            .text = truncation_source,
            .max_bytes = mid,
            .marker = marker,
            .trace_scope = "mcp",
            .trace_label = tool_name,
        });
        const candidate = try build_truncated_envelope(
            arena,
            server_name,
            tool_name,
            inner,
            full_output.len,
            max_tool_result_bytes,
        );
        if (candidate.len <= max_tool_result_bytes) {
            best = candidate;
            low = mid + 1;
        } else {
            if (mid == 0) break;
            high = mid - 1;
        }
    }

    if (best.len == 0) {
        best = try build_truncated_envelope(
            arena,
            server_name,
            tool_name,
            marker,
            full_output.len,
            max_tool_result_bytes,
        );
    }
    return try alloc.dupe(u8, best);
}

fn write_envelope(
    alloc: Allocator,
    writer: *std.Io.Writer,
    server_name: []const u8,
    tool_name: []const u8,
    result: std.json.Value,
) !void {
    try writer.writeAll("{\"server\":");
    try std.json.Stringify.value(server_name, .{}, writer);
    try writer.writeAll(",\"tool\":");
    try std.json.Stringify.value(tool_name, .{}, writer);
    try writer.writeAll(",\"result\":");
    try writeJsonProjection(alloc, writer, result, false);
    try writer.writeByte('}');
}

/// JSON projection for MCP result envelopes. `mask_strings` selects the
/// display projection (diagnostics); the model envelope uses the
/// sanitize-only projection.
fn writeJsonProjection(
    alloc: Allocator,
    writer: *std.Io.Writer,
    value: std.json.Value,
    comptime mask_strings: bool,
) !void {
    switch (value) {
        .null, .bool, .integer, .float, .number_string => try std.json.Stringify.value(value, .{}, writer),
        .string => |text| {
            const sanitized = try text_utils.sanitizeModelText(alloc, text);
            const projected = if (mask_strings)
                try text_utils.maskSecrets(alloc, sanitized)
            else
                sanitized;
            try std.json.Stringify.value(projected, .{}, writer);
        },
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                try writeJsonProjection(alloc, writer, item, mask_strings);
            }
            try writer.writeByte(']');
        },
        .object => |object| {
            try writer.writeByte('{');
            var it = object.iterator();
            var index: usize = 0;
            while (it.next()) |entry| : (index += 1) {
                if (index > 0) try writer.writeByte(',');
                try std.json.Stringify.value(entry.key_ptr.*, .{}, writer);
                try writer.writeByte(':');
                try writeJsonProjection(alloc, writer, entry.value_ptr.*, mask_strings);
            }
            try writer.writeByte('}');
        },
    }
}

fn collect_result_text(arena: Allocator, result: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var needs_separator = false;
    try append_text_strings(arena, &out.writer, result, &needs_separator);
    return try out.toOwnedSlice();
}

fn append_text_strings(
    arena: Allocator,
    writer: *std.Io.Writer,
    value: std.json.Value,
    needs_separator: *bool,
) !void {
    switch (value) {
        .string => |text| {
            const sanitized = try text_utils.sanitizeModelText(arena, text);
            if (needs_separator.*) try writer.writeByte('\n');
            try writer.writeAll(sanitized);
            needs_separator.* = true;
        },
        .array => |array| for (array.items) |item| {
            try append_text_strings(arena, writer, item, needs_separator);
        },
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "text") or
                    std.mem.eql(u8, entry.key_ptr.*, "data") or
                    std.mem.eql(u8, entry.key_ptr.*, "blob") or
                    std.mem.eql(u8, entry.key_ptr.*, "content"))
                {
                    try append_text_strings(
                        arena,
                        writer,
                        entry.value_ptr.*,
                        needs_separator,
                    );
                }
            }
        },
        else => {},
    }
}

fn build_truncated_envelope(
    alloc: Allocator,
    server_name: []const u8,
    tool_name: []const u8,
    text: []const u8,
    original_bytes: usize,
    cap_bytes: usize,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    try out.writer.writeAll("{\"server\":");
    try std.json.Stringify.value(server_name, .{}, &out.writer);
    try out.writer.writeAll(",\"tool\":");
    try std.json.Stringify.value(tool_name, .{}, &out.writer);
    try out.writer.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(text, .{}, &out.writer);
    try out.writer.writeAll("}],\"truncated\":true,\"original_bytes\":");
    try out.writer.print("{d}", .{original_bytes});
    try out.writer.writeAll(",\"cap_bytes\":");
    try out.writer.print("{d}", .{cap_bytes});
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

fn extract_legacy(alloc: Allocator, response: []const u8) !tool_mcp_runtime.CallResult {
    return extract(alloc, .{
        .server_name = "server",
        .tool_name = "mcp__server__tool",
        .response = response,
        .max_tool_result_bytes = tool_result_limits.default_max_tool_result_bytes,
        .protocol = .legacy,
    });
}

test "tool result extracts all content" {
    const alloc = std.testing.allocator;
    const response =
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"hello "},{"type":"image","data":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=","mimeType":"image/png"},{"type":"text","text":"world"}]}}
    ;
    var result = try extract_legacy(alloc, response);
    defer result.deinit(alloc);

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        result.model_output,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "server",
        parsed.value.object.get("server").?.string,
    );
    const content = parsed.value.object.get("result").?.object.get("content").?.array.items;
    try std.testing.expectEqualStrings("hello ", content[0].object.get("text").?.string);
    try std.testing.expect(content[1].object.get("data") == null);
    try std.testing.expectEqual(@as(usize, 1), result.images.len);
    try std.testing.expectEqualStrings("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=", result.images[0].data);
    try std.testing.expectEqualStrings("image/png", result.images[0].mime_type);
    try std.testing.expectEqualStrings("world", content[2].object.get("text").?.string);
}

test "tool result retains protocol error diagnostics" {
    const alloc = std.testing.allocator;
    var result = try extract_legacy(alloc,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"something failed"}}
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(
        tool_mcp_runtime.CallStatus.protocol_failure,
        result.status,
    );
    try std.testing.expect(std.mem.find(
        u8,
        result.model_output,
        "something failed",
    ) != null);
}

test "modern tool results validate result type and retain typed error data" {
    const alloc = std.testing.allocator;
    var rendered = try extract(alloc, .{
        .server_name = "server",
        .tool_name = "mcp__server__tool",
        .response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"Invalid tool arguments\",\"data\":{\"field\":\"path\"}}}",
        .max_tool_result_bytes = tool_result_limits.default_max_tool_result_bytes,
        .protocol = .modern,
    });
    defer rendered.deinit(alloc);
    try std.testing.expectEqual(
        tool_mcp_runtime.CallStatus.protocol_failure,
        rendered.status,
    );
    try std.testing.expect(std.mem.find(
        u8,
        rendered.model_output,
        "Invalid tool arguments",
    ) != null);

    var missing = try extract(alloc, .{
        .server_name = "server",
        .tool_name = "mcp__server__tool",
        .response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[]}}",
        .max_tool_result_bytes = tool_result_limits.default_max_tool_result_bytes,
        .protocol = .modern,
    });
    defer missing.deinit(alloc);
    try std.testing.expectEqual(tool_mcp_runtime.CallStatus.success, missing.status);
}

test "a -32042 answer reaches the model as a protocol error, as the host hands it over" {
    // The host holds the call for the user's answer to the URLs, and gives the model the error without its data
    // (`tests/tla/mcp_host/ErrorData.tla`, `UrlRetry.tla`).
    const alloc = std.testing.allocator;
    var result = try extract(alloc, .{
        .server_name = "server",
        .tool_name = "mcp_server_authorize",
        .response = "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32042,\"message\":\"URL elicitation required\"}}",
        .max_tool_result_bytes = 64 * 1024,
        .protocol = .modern,
    });
    defer result.deinit(alloc);
    try std.testing.expectEqual(tool_mcp_runtime.CallStatus.protocol_failure, result.status);
    try std.testing.expect(std.mem.find(u8, result.model_output, "MCP protocol error -32042") != null);
}

test "invalid tool responses retain bounded protocol failures" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        "{not json",
        "{\"jsonrpc\":\"2.0\",\"id\":1}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[]}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":{}}}",
    }) |response| {
        var result = try extract_legacy(alloc, response);
        defer result.deinit(alloc);
        try std.testing.expectEqual(
            tool_mcp_runtime.CallStatus.protocol_failure,
            result.status,
        );
    }
}

test "large tool results stay valid, bounded, and verbatim" {
    const alloc = std.testing.allocator;
    const needle = "MY_NOTE_TOKEN=abcdefgh";
    const large_text = needle ++ text_utils.repeat("x", 1800);
    const response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"" ++ large_text ++ "\"}]}}";
    var result = try extract(alloc, .{
        .server_name = "filesystem",
        .tool_name = "mcp__filesystem__dump",
        .response = response,
        .max_tool_result_bytes = 1024,
        .protocol = .legacy,
    });
    defer result.deinit(alloc);

    try std.testing.expect(result.model_output.len <= 1024);
    try std.testing.expect(std.mem.find(u8, result.model_output, needle) != null);
    try std.testing.expect(std.mem.find(u8, result.model_output, "[redacted]") == null);
    try std.testing.expect(std.mem.find(
        u8,
        result.model_output,
        "mcp tool result truncated for filesystem/mcp__filesystem__dump",
    ) != null);

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        result.model_output,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "filesystem",
        parsed.value.object.get("server").?.string,
    );
    try std.testing.expect(
        parsed.value.object.get("result").?.object.get("truncated").?.bool,
    );
}

fn expectCause(text: []const u8, expected: ?[]const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const cause = try invalidParamsCause(arena_state.allocator(), text);
    if (expected) |wanted| {
        try std.testing.expectEqualStrings(wanted, cause orelse return error.TestExpectedCause);
    } else if (cause) |got| {
        std.debug.print("unexpected cause {s}\n", .{got});
        return error.TestUnexpectedCause;
    }
}

test "a -32602 in the Go SDK's words names each rejected field and type" {
    try expectCause(
        protocol_error_words ++ "-32602: validating \"arguments\": validating root: validating /properties/limit: type: \"40\" has type \"string\", want \"number\"\n\nFull input schema for tool \"search\":\n{\"type\":\"object\"}",
        "arguments rejected: limit is a string, the schema wants a number",
    );
    try expectCause(
        protocol_error_words ++ "-32602: validating /properties/filter/properties/env: type: 1 has type \"integer\", want \"string\"",
        "arguments rejected: filter.env is an integer, the schema wants a string",
    );
    try expectCause(
        protocol_error_words ++ "-32602: validating /properties/queries: type: [\"a\"] has type \"string\", want \"array\"\nvalidating /properties/verbose: type: \"true\" has type \"string\", want \"boolean\"",
        "arguments rejected: queries is a string, the schema wants an array; verbose is a string, the schema wants a boolean",
    );
    try expectCause(
        protocol_error_words ++ "-32602: validating /properties/id: type: \"x\" has type \"string\", want [\"integer\",\"null\"]",
        "arguments rejected: id is a string, the schema wants [\"integer\",\"null\"]",
    );
    try expectCause(
        protocol_error_words ++ "-32602: validating /properties/a: type: 1 has type \"integer\", want \"string\"\nvalidating /properties/b: type: 1 has type \"integer\", want \"string\"\nvalidating /properties/c: type: 1 has type \"integer\", want \"string\"\nvalidating /properties/d: type: 1 has type \"integer\", want \"string\"",
        "arguments rejected: a is an integer, the schema wants a string; b is an integer, the schema wants a string; c is an integer, the schema wants a string; and more",
    );
}

test "a -32602 as the TypeScript SDK's zod issues names each path and type" {
    try expectCause(
        protocol_error_words ++ "-32602: MCP error -32602: Invalid arguments for tool search: [\n  {\n    \"code\": \"invalid_type\",\n    \"expected\": \"number\",\n    \"received\": \"string\",\n    \"path\": [\n      \"limit\"\n    ],\n    \"message\": \"Expected number, received string\"\n  }\n]",
        "arguments rejected: limit is a string, the schema wants a number",
    );
    try expectCause(
        protocol_error_words ++ "-32602: Invalid arguments: [{\"code\":\"invalid_type\",\"expected\":\"boolean\",\"path\":[\"options\",\"verbose\"]},{\"code\":\"invalid_type\",\"expected\":\"string\",\"received\":\"number\",\"path\":[\"queries\",0]}]",
        "arguments rejected: options.verbose must be a boolean; queries[0] is a number, the schema wants a string",
    );
    try expectCause(
        protocol_error_words ++ "-32602: Invalid arguments: [{\"code\":\"invalid_type\",\"expected\":\"object\",\"received\":\"string\",\"path\":[]}]",
        "arguments rejected: the arguments object is a string, the schema wants an object",
    );
}

test "a -32602 fx can't read says the server refused the parameters" {
    const general = "the server rejected the call's parameters (-32602)";
    try expectCause(protocol_error_words ++ "-32602: Unknown tool: nope", general);
    try expectCause(protocol_error_words ++ "-32602: ", general);
    try expectCause(protocol_error_words ++ "-32602: Invalid arguments: [not json]", general);
    try expectCause(protocol_error_words ++ "-32602: Invalid arguments: [{\"code\":\"custom\",\"path\":[\"x\"]}]", general);
    // The trace keeps the start of a long result, which can cut a line short.
    try expectCause(protocol_error_words ++ "-32602: validating /properties/limit: type: \"40\" has ty", general);
}

test "only a -32602 gets a cause, so other failures keep their text" {
    try expectCause(protocol_error_words ++ "-32603: internal error", null);
    try expectCause(protocol_error_words ++ "-32000: validating /properties/limit: type: \"40\" has type \"string\", want \"number\"", null);
    try expectCause(protocol_error_words ++ "-326020: Unknown tool", null);
    try expectCause("tool said: " ++ protocol_error_words ++ "-32602: Unknown tool", null);
    try expectCause("Invalid input: labels require at least one item", null);
    try expectCause("", null);
}

test "an invalid-params cause leaves out what the server wrote after the type and masks secrets" {
    const token = "ghp_" ++ text_utils.repeat("a", 36);
    try expectCause(
        protocol_error_words ++ "-32602: validating /properties/limit: type: \"40\" has type \"string\", want \"number\" token=" ++ token,
        "arguments rejected: limit is a string, the schema wants a number",
    );
    try expectCause(
        protocol_error_words ++ "-32602: validating /properties/id: type: \"x\" has type \"string\", want [\"integer\",\"null\"] (see " ++ token ++ ")",
        "arguments rejected: id is a string, the schema wants [\"integer\",\"null\"]",
    );
    try expectCause(
        protocol_error_words ++ "-32602: validating /properties/limit: type: \"40\" has type \"string\", want number, see " ++ token,
        "arguments rejected: limit is a string, the schema wants a number",
    );
    try expectCause(protocol_error_words ++ "-32602: validating /properties/limit: type: \"40\" has type \"string\", want \"number", "the server rejected the call's parameters (-32602)");
    try expectCause(
        protocol_error_words ++ "-32602: validating /properties/" ++ token ++ ": type: 1 has type \"integer\", want \"string\"",
        "arguments rejected: [redacted] is an integer, the schema wants a string",
    );
    try expectCause(
        protocol_error_words ++ "-32602: [{\"code\":\"invalid_type\",\"expected\":\"number\",\"received\":\"string\",\"path\":[\"" ++ token ++ "\"]}]",
        "arguments rejected: [redacted] is a string, the schema wants a number",
    );
}

test "an invalid-params cause stays one terminal-safe line within its bound" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const long_field = try arena.alloc(u8, 1000);
    @memset(long_field, 'f');
    const hostile = [_][]const u8{
        protocol_error_words ++ "-32602: validating /properties/a\x1b[2Jb: type: 1 has type \"integer\", want \"string\"",
        protocol_error_words ++ "-32602: validating /properties/a\rb: type: 1 has type \"\x07integer\", want \"str\x00ing\"",
        try arena.print(protocol_error_words ++ "-32602: validating /properties/{s}: type: 1 has type \"integer\", want \"string\"", .{long_field}),
        protocol_error_words ++ "-32602: Invalid arguments: [{\"expected\":\"number\\u001b[31m\",\"received\":\"string\",\"path\":[\"a\\nb\"]}]",
        protocol_error_words ++ "-32602: Unknown tool \xff\xfe",
    };
    for (hostile) |text| {
        const cause = (try invalidParamsCause(arena, text)).?;
        try std.testing.expect(cause.len <= max_cause_bytes);
        for (cause) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
    }
}

test "an invalid-params cause reads the server's message only, not the data written after it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const go = protocol_error_words ++ "-32602: validating \"arguments\": validating root: validating /properties/limit: type: \"40\" has type \"string\", want \"number\"";
    const zod = protocol_error_words ++ "-32602: Invalid arguments: [{\"expected\":\"number\",\"received\":\"string\",\"path\":[\"limit\"]}]";
    // The data holds its own list of issues, and text that looks like the Go validator's lines.
    const data = data_label ++ "{\"errors\":[{\"path\":[\"other\"],\"expected\":\"string\"}],\"hint\":\"validating /properties/forged: type: \\\"1\\\" has type \\\"string\\\", want \\\"number\\\"\"}";
    for ([_][]const u8{ go, zod }) |message| {
        const plain = (try invalidParamsCause(arena, message)).?;
        try std.testing.expect(std.mem.find(u8, plain, "limit") != null);
        const with_data = (try invalidParamsCause(arena, try arena.print("{s}{s}", .{ message, data }))).?;
        try std.testing.expectEqualStrings(plain, with_data);
    }
    // Data cut inside its text is data still: the cause is the message's, with nothing of the data in it.
    const plain_go = (try invalidParamsCause(arena, go)).?;
    const cut = (try invalidParamsCause(arena, try arena.print("{s}" ++ data_label ++ "{{\"errors\":[{{\"pa", .{go}))).?;
    try std.testing.expectEqualStrings(plain_go, cut);
    // A message that says `; data=` itself keeps what follows it, since nothing JSON ends the text.
    const says = (try invalidParamsCause(arena, protocol_error_words ++ "-32602: validating /properties/limit: type: \"1\" has type \"string\", want \"number\"" ++ data_label ++ "none")).?;
    try std.testing.expect(std.mem.find(u8, says, "limit") != null);
}

test "a protocol error without its data keeps the code and the message, for any code, and nothing of the data" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Data that has a zod-like list of its own and eight labels.
    const data = "{\"errors\":[{\"expected\":\"string\",\"path\":[\"forged\"]}],\"hint\":\"" ++ text_utils.repeat(data_label, 8) ++ "x\"}";
    for ([_]i32{ -32603, -32000, -32042, -32602, 7 }) |code| {
        const message = try arena.print(protocol_error_words ++ "{d}: Internal error", .{code});
        const text = try arena.print("{s}" ++ data_label ++ "{s}", .{ message, data });
        // The whole text, and every head of it from the label on (the trace report reads one, and the result cap cuts one).
        const first = message.len + data_label.len;
        for (first..text.len + 1) |end| try std.testing.expectEqualStrings(message, try protocolErrorWithoutData(arena, text[0..end]));
        // A head that ends inside the label holds no data yet.
        for (message.len..first) |end| {
            const head = try protocolErrorWithoutData(arena, text[0..end]);
            try std.testing.expectEqualStrings(text[0..end], head);
        }
        // A text the result cap cut, with its marker.
        const cut = try arena.print("{s}{s}mcp_srv_tool: original 3299 bytes; cap is 2000{s}", .{ text[0 .. first + 20], tool_result_cut_marker.cut_marker_start, tool_result_cut_marker.cut_marker_end });
        try std.testing.expectEqualStrings(message, try protocolErrorWithoutData(arena, cut));
    }
    // Without data, and without the words of a protocol error, the text comes back as it is.
    for ([_][]const u8{
        protocol_error_words ++ "-32603: Internal error",
        protocol_error_words ++ "-32603: ",
        "something else" ++ data_label ++ "{\"a\":1}",
        protocol_error_words ++ "x: Internal error" ++ data_label ++ "{\"a\":1}",
        protocol_error_words ++ "-: Internal error" ++ data_label ++ "{\"a\":1}",
        protocol_error_words ++ "-32603 Internal error" ++ data_label ++ "{\"a\":1}",
        protocol_error_words,
        "",
    }) |text| {
        const same = try protocolErrorWithoutData(arena, text);
        try std.testing.expectEqual(text.ptr, same.ptr);
        try std.testing.expectEqual(text.len, same.len);
    }
    // A message that says `; data=` itself stays whole while no JSON follows it; the data is what follows the one
    // that does.
    try std.testing.expectEqualStrings(
        protocol_error_words ++ "-32603: tried" ++ data_label ++ "none",
        try protocolErrorWithoutData(arena, protocol_error_words ++ "-32603: tried" ++ data_label ++ "none" ++ data_label ++ "{\"a\":1}"),
    );
}

/// `message` and then `data` as `write_protocol_diagnostic` writes them for a -32602.
fn textWithData(arena: Allocator, message: []const u8, data: []const u8) ![]const u8 {
    return try arena.print("{s}{s}" ++ data_label ++ "{s}", .{ invalid_params_prefix, message, data });
}

/// The cause of `message` and `data` is the cause of `message` alone, for the whole text and for the
/// heads of it that hold the message and the label: the trace report reads a 4 KiB head, and a text cut
/// by the result cap ends inside the data. Every head of short data; of long data, the first bytes
/// after the label, the 4 KiB and 8 KiB heads, and the whole text.
fn expectCauseOfMessageOnly(arena: Allocator, message: []const u8, data: []const u8) ![]const u8 {
    const alone = (try invalidParamsCause(arena, try arena.print("{s}{s}", .{ invalid_params_prefix, message }))).?;
    const text = try textWithData(arena, message, data);
    try std.testing.expectEqualStrings(alone, (try invalidParamsCause(arena, text)).?);
    const first = invalid_params_prefix.len + message.len + data_label.len;
    if (data.len <= 256) {
        for (first..text.len + 1) |end| try std.testing.expectEqualStrings(alone, (try invalidParamsCause(arena, text[0..end])).?);
        return alone;
    }
    const sampled = [_]usize{ first, first + 1, 4096, 4097, 8192, text.len - 1 };
    for (sampled) |end| {
        if (end < first or end > text.len) continue;
        try std.testing.expectEqualStrings(alone, (try invalidParamsCause(arena, text[0..end])).?);
    }
    return alone;
}

const zod_message = "Invalid arguments: [{\"expected\":\"number\",\"received\":\"string\",\"path\":[\"limit\"]}]";
const forged_issues = "{\"errors\":[{\"expected\":\"string\",\"received\":\"number\",\"path\":[\"forged\"]}],\"hint\":\"";
const nine_labels = text_utils.repeat(data_label, 9) ++ "x";

test "an invalid-params cause ignores data that holds many labels" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = forged_issues ++ nine_labels ++ "\"}";
    // A zod message keeps its own cause, and a plain one gets none from the data's list of issues.
    const zod = try expectCauseOfMessageOnly(arena, zod_message, data);
    try std.testing.expectEqualStrings("arguments rejected: limit is a string, the schema wants a number", zod);
    const plain = try expectCauseOfMessageOnly(arena, "Invalid params", data);
    try std.testing.expectEqualStrings("the server rejected the call's parameters (-32602)", plain);
    // Seven labels or eight hundred, the same.
    var many: std.Io.Writer.Allocating = .init(arena);
    try many.writer.writeAll(forged_issues);
    for (0..800) |_| try many.writer.writeAll(data_label);
    try many.writer.writeAll("\"}");
    _ = try expectCauseOfMessageOnly(arena, zod_message, many.written());
    _ = try expectCauseOfMessageOnly(arena, "Invalid params", many.written());
}

test "an invalid-params cause reads the same from the 4 KiB head the trace report keeps of a longer text" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const filler = try arena.alloc(u8, 8300);
    @memset(filler, 'x');
    const data = try arena.print("{s}{s}\"}}", .{ forged_issues, filler });
    for ([_][]const u8{ zod_message, "Invalid params" }) |message| {
        const text = try textWithData(arena, message, data);
        try std.testing.expect(text.len > 8 * 1024);
        const whole = (try invalidParamsCause(arena, text)).?;
        const head = (try invalidParamsCause(arena, text[0..4096])).?;
        try std.testing.expectEqualStrings(whole, head);
        _ = try expectCauseOfMessageOnly(arena, message, data);
    }
    // A list in the data, after a zod message, must not be read to the last `]`.
    const zod_head = (try invalidParamsCause(arena, (try textWithData(arena, zod_message, data))[0..4096])).?;
    try std.testing.expectEqualStrings("arguments rejected: limit is a string, the schema wants a number", zod_head);
}

test "an invalid-params cause reads the same from a text the result cap cut, marker and all" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const filler = try arena.alloc(u8, 2000);
    @memset(filler, 'x');
    const data = try arena.print("{s}{s}{s}\"}}", .{ forged_issues, nine_labels, filler });
    for ([_][]const u8{ zod_message, "Invalid params" }) |message| {
        const alone = (try invalidParamsCause(arena, try arena.print("{s}{s}", .{ invalid_params_prefix, message }))).?;
        const text = try textWithData(arena, message, data);
        // Caps that cut inside the label's neighbourhood and deep in the data.
        for ([_]usize{ 200, 260, 400, 1000 }) |cap| {
            const output = try tool_result_limits.prepareModelOutput(arena, "mcp_srv_tool", text, cap);
            try std.testing.expect(std.mem.find(u8, output, tool_result_cut_marker.cut_marker_start ++ "mcp_srv_tool: original ") != null);
            try std.testing.expectEqualStrings(alone, (try invalidParamsCause(arena, output)).?);
        }
    }
}

fn invalidParamsCauseAllocationFailures(alloc: Allocator) !void {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    _ = try invalidParamsCause(
        arena_state.allocator(),
        protocol_error_words ++ "-32602: Invalid arguments: [{\"expected\":\"number\",\"received\":\"string\",\"path\":[\"limit\"]},{\"expected\":\"array\",\"path\":[\"queries\",0]}]",
    );
}

test "an invalid-params cause reports running out of memory" {
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, invalidParamsCauseAllocationFailures, .{});
}

/// Fails only its `fail_index`th allocation. `checkAllAllocationFailures`
/// fails every allocation after the first, so code that swallows a failure
/// and then allocates again still ends in error.OutOfMemory there; here it
/// succeeds, and the test sees it. Never resizes, as `no_resize` does.
const FailOnceAllocator = struct {
    backing: Allocator,
    fail_index: usize,
    index: usize = 0,
    failed: bool = false,

    fn allocator(self: *FailOnceAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *FailOnceAllocator = @ptrCast(@alignCast(ctx));
        defer self.index += 1;
        if (self.index == self.fail_index) {
            self.failed = true;
            return null;
        }
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *FailOnceAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, return_address);
    }
};

test "an invalid-params cause reports running out of memory even when memory comes back" {
    var counting: FailOnceAllocator = .{ .backing = std.testing.allocator, .fail_index = std.math.maxInt(usize) };
    try invalidParamsCauseAllocationFailures(counting.allocator());
    for (0..counting.index) |fail_index| {
        var once: FailOnceAllocator = .{ .backing = std.testing.allocator, .fail_index = fail_index };
        try std.testing.expectError(error.OutOfMemory, invalidParamsCauseAllocationFailures(once.allocator()));
        try std.testing.expect(once.failed);
    }
}

test "the readers of a protocol error's words follow what write_protocol_diagnostic writes" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]i64{ -32602, -32603, -32601, -32000 }) |code| {
        for ([_]?[]const u8{ null, "{\"a\":1}" }) |data| {
            var out: std.Io.Writer.Allocating = .init(arena);
            try write_protocol_diagnostic(arena, &out.writer, code, "Invalid params", data);
            const text = out.written();
            // The message and no data, whatever the code, and whether or not the server gave data.
            try std.testing.expectEqualStrings(
                try arena.print(protocol_error_words ++ "{d}: Invalid params", .{code}),
                try protocolErrorWithoutData(arena, text),
            );
            // A cause for -32602 only.
            try std.testing.expectEqual(code == -32602, (try invalidParamsCause(arena, text)) != null);
        }
    }
}

fn fuzzInvalidParamsCause(_: void, smith: *std.testing.Smith) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var raw: [1024]u8 = undefined;
    const bytes = raw[0..smith.slice(&raw)];
    const prefixed = try arena.print("{s}{s}", .{ invalid_params_prefix, bytes });
    for ([_][]const u8{ bytes, prefixed }) |text| {
        const cause = try invalidParamsCause(arena, text);
        // A cause exactly for -32602 text, one safe line within its bound,
        // and the same each time.
        try std.testing.expectEqual(std.mem.startsWith(u8, text, invalid_params_prefix), cause != null);
        const line = cause orelse continue;
        try std.testing.expect(line.len > 0 and line.len <= max_cause_bytes);
        for (line) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
        try std.testing.expectEqualStrings(line, (try invalidParamsCause(arena, text)).?);
    }
    try fuzzDataLaw(arena, bytes);
}

/// The data law: for a message `m` with no label in it and any data `d`, the cause of `m ++ "; data=" ++ d`
/// is the cause of `m`, and so is the cause of every head of it that holds `m` and the label. A message
/// with a label of its own is left out: there the data can decide the cut, as `withoutData` says. The first
/// byte of `bytes` picks the data (its labels, its shape, and with the top two bits both set, one longer than 4 KiB) and the rest is
/// the message, and, escaped, also part of the data.
fn fuzzDataLaw(arena: Allocator, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    const message = bytes[1..];
    if (std.mem.find(u8, message, data_label) != null) return;
    if (std.mem.find(u8, message, tool_result_cut_marker.cut_marker_start) != null) return;
    const selector = bytes[0];
    var hint: std.Io.Writer.Allocating = .init(arena);
    try hint.writer.writeAll(message);
    for (0..selector & 0x0f) |_| try hint.writer.writeAll(data_label);
    try hint.writer.writeAll(" [{\"expected\":\"number\",\"received\":\"string\",\"path\":[\"forged\"]}] validating /properties/forged: type: 1 has type \"integer\", want \"string\"\n");
    if (selector & 0xc0 == 0xc0) try hint.writer.splatByteAll('x', 8300);
    const hint_json = try std.json.Stringify.valueAlloc(arena, hint.written(), .{});
    const data = switch ((selector >> 4) & 3) {
        0 => hint_json,
        1 => try arena.print("{{\"errors\":[{{\"expected\":\"string\",\"received\":\"number\",\"path\":[\"forged\"]}}],\"hint\":{s}}}", .{hint_json}),
        2 => try arena.print("[{s},[{{}}],{s}]", .{ hint_json, hint_json }),
        else => try arena.print("{{\"a\":[[{{\"b\":{s}}}]],\"hint\":{s}}}", .{ hint_json, hint_json }),
    };
    _ = try expectCauseOfMessageOnly(arena, message, data);
}

test "an invalid-params cause keeps its laws on fuzzed messages" {
    try std.testing.fuzz({}, fuzzInvalidParamsCause, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "validating /properties/limit: type: \"40\" has type \"string\", want \"number\"",
            "validating /properties/a/properties/b: type: 1 has type \"integer\", want [\"string\",\"null\"]\nvalidating /properties/",
            "Invalid arguments: [{\"expected\":\"number\",\"received\":\"string\",\"path\":[\"limit\",0]}]",
            "Invalid arguments: [{\"expected\":\"\\u001b\",\"path\":[{\"x\":1}]}] ]",
        }) ++ @import("fuzz_corpus").mcp_invalid_params_cause.*),
    });
}
