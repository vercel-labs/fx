const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const mem_utils = @import("../shared/mem_utils.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const elicitation = @import("elicitation.zig");
const json_depth = @import("json_depth.zig");
const mcp_json = @import("mcp_json.zig");
const mrtr = @import("mrtr.zig");
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
    legacy_wire: ?elicitation.Wire = null,
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
            try alloc.print("MCP protocol failure: the server's reply is nested deeper than fx accepts ({d} levels)", .{json_depth.max_server_json_depth})
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
        .protocol_failure => |failure| blk: {
            if (options.legacy_wire == .legacy_mcp_2025_11 and
                failure.code == elicitation.legacy_url_required_error_code and
                failure.data_json != null)
            {
                if (try legacy_url_required(
                    alloc,
                    options.tool_name,
                    failure.data_json.?,
                    options.max_tool_result_bytes,
                )) |required_result| break :blk required_result;
            }
            break :blk .{
                .model_output = try render_owned_protocol_error(
                    alloc,
                    options.tool_name,
                    failure,
                    options.max_tool_result_bytes,
                ),
                .status = .protocol_failure,
            };
        },
        .input_required => |required| blk: {
            const input_requests_json = try mrtr.renderRequests(alloc, required.requests);
            errdefer mem_utils.free(alloc, input_requests_json);
            const request_state_json = if (required.request_state_json) |state|
                try alloc.dupe(u8, state)
            else
                null;
            errdefer if (request_state_json) |state| mem_utils.free(alloc, state);
            const raw = try render_input_required(
                alloc,
                input_requests_json,
                request_state_json,
            );
            defer alloc.free(raw);
            break :blk .{
                .model_output = try tool_result_limits.prepareModelOutput(
                    alloc,
                    options.tool_name,
                    raw,
                    options.max_tool_result_bytes,
                ),
                .status = .input_required,
                .input_required = .{
                    .input_requests_json = input_requests_json,
                    .request_state_json = request_state_json,
                },
            };
        },
    };
}

fn legacy_url_required(
    alloc: Allocator,
    tool_name: []const u8,
    data_json: []const u8,
    max_tool_result_bytes: usize,
) !?tool_mcp_runtime.CallResult {
    var required = elicitation.parseLegacyUrlRequired(
        alloc,
        .legacy_mcp_2025_11,
        data_json,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer required.deinit(alloc);
    const input_requests_json = try elicitation.renderLegacyUrlRequiredRequests(
        alloc,
        required,
        .{},
    );
    errdefer mem_utils.free(alloc, input_requests_json);
    const raw = try render_input_required(alloc, input_requests_json, null);
    defer alloc.free(raw);
    return .{
        .model_output = try tool_result_limits.prepareModelOutput(
            alloc,
            tool_name,
            raw,
            max_tool_result_bytes,
        ),
        .status = .input_required,
        .input_required = .{
            .input_requests_json = input_requests_json,
            .legacy_retry_without_responses = true,
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

fn write_protocol_diagnostic(
    scratch: Allocator,
    writer: *std.Io.Writer,
    code: i64,
    message: []const u8,
    data_json: ?[]const u8,
) !void {
    try writer.print("MCP protocol error {d}: ", .{code});
    const safe_message = try text_utils.sanitizeModelText(scratch, message);
    try writer.writeAll(safe_message);
    if (data_json) |data| {
        const safe_data = try text_utils.sanitizeModelText(scratch, data);
        try writer.writeAll("; data=");
        try writer.writeAll(safe_data);
    }
}

const invalid_params_prefix = "MCP protocol error -32602: ";
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
    const message = text[invalid_params_prefix.len..];
    var line: std.Io.Writer.Allocating = .init(arena);
    const named = (writeGoRejections(&line.writer, message) catch return error.OutOfMemory) or
        try writeZodRejections(arena, &line.writer, message);
    if (!named) line.writer.writeAll("the server rejected the call's parameters (-32602)") catch return error.OutOfMemory;
    // Mask before the length cut, which could leave a token too short to match.
    const masked = text_utils.maskSecrets(arena, line.written()) catch return error.OutOfMemory;
    const encoded = try text_utils.encodeTerminalSafeInline(arena, masked, max_cause_bytes);
    return encoded.bytes;
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

fn render_input_required(
    alloc: Allocator,
    input_requests_json: []const u8,
    request_state_json: ?[]const u8,
) error{OutOfMemory}![]u8 {
    return render_input_required_fallible(
        alloc,
        input_requests_json,
        request_state_json,
    ) catch error.OutOfMemory;
}

fn render_input_required_fallible(
    alloc: Allocator,
    input_requests_json: []const u8,
    request_state_json: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"resultType\":\"input_required\",\"inputRequests\":");
    try out.writer.writeAll(input_requests_json);
    if (request_state_json) |state| {
        try out.writer.writeAll(",\"requestState\":");
        try mcp_json.write_compact(&out.writer, state);
    }
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
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

fn check_input_required_allocation_failures(alloc: Allocator) !void {
    var result = try extract(alloc, .{
        .server_name = "server",
        .tool_name = "mcp_server_confirm",
        .response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"input_required\",\"inputRequests\":{\"confirm\":{\"method\":\"elicitation/create\",\"params\":{\"message\":\"Continue?\",\"requestedSchema\":{\"type\":\"object\",\"properties\":{\"confirmed\":{\"type\":\"boolean\"}}}}}},\"requestState\":{\"opaque\":true}}}",
        .max_tool_result_bytes = 64 * 1024,
        .protocol = .modern,
    });
    defer result.deinit(alloc);
    try std.testing.expectEqual(tool_mcp_runtime.CallStatus.input_required, result.status);
}

test "input-required result releases every allocation failure path" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        check_input_required_allocation_failures,
        .{},
    );
}

fn check_legacy_url_required_allocation_failures(alloc: Allocator) !void {
    var result = try extract(alloc, .{
        .server_name = "server",
        .tool_name = "mcp_server_authorize",
        .response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32042,\"message\":\"URL elicitation required\",\"data\":{\"elicitations\":[{\"mode\":\"url\",\"message\":\"Authorize\",\"url\":\"https://example.test/connect\",\"elicitationId\":\"legacy-url\"}]}}}",
        .max_tool_result_bytes = 64 * 1024,
        .protocol = .legacy,
        .legacy_wire = .legacy_mcp_2025_11,
    });
    defer result.deinit(alloc);
    try std.testing.expectEqual(tool_mcp_runtime.CallStatus.input_required, result.status);
    try std.testing.expect(result.input_required.?.legacy_retry_without_responses);
}

test "2025-11 URL-required errors become retry input only on that wire" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        check_legacy_url_required_allocation_failures,
        .{},
    );

    var old = try extract(std.testing.allocator, .{
        .server_name = "server",
        .tool_name = "tool",
        .response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32042,\"message\":\"URL elicitation required\",\"data\":{\"elicitations\":[{\"mode\":\"url\",\"message\":\"Authorize\",\"url\":\"https://example.test/connect\",\"elicitationId\":\"legacy-url\"}]}}}",
        .max_tool_result_bytes = 64 * 1024,
        .protocol = .legacy,
        .legacy_wire = .legacy_mcp_2025_06,
    });
    defer old.deinit(std.testing.allocator);
    try std.testing.expectEqual(tool_mcp_runtime.CallStatus.protocol_failure, old.status);
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
        "MCP protocol error -32602: validating \"arguments\": validating root: validating /properties/limit: type: \"40\" has type \"string\", want \"number\"\n\nFull input schema for tool \"search\":\n{\"type\":\"object\"}",
        "arguments rejected: limit is a string, the schema wants a number",
    );
    try expectCause(
        "MCP protocol error -32602: validating /properties/filter/properties/env: type: 1 has type \"integer\", want \"string\"",
        "arguments rejected: filter.env is an integer, the schema wants a string",
    );
    try expectCause(
        "MCP protocol error -32602: validating /properties/queries: type: [\"a\"] has type \"string\", want \"array\"\nvalidating /properties/verbose: type: \"true\" has type \"string\", want \"boolean\"",
        "arguments rejected: queries is a string, the schema wants an array; verbose is a string, the schema wants a boolean",
    );
    try expectCause(
        "MCP protocol error -32602: validating /properties/id: type: \"x\" has type \"string\", want [\"integer\",\"null\"]",
        "arguments rejected: id is a string, the schema wants [\"integer\",\"null\"]",
    );
    try expectCause(
        "MCP protocol error -32602: validating /properties/a: type: 1 has type \"integer\", want \"string\"\nvalidating /properties/b: type: 1 has type \"integer\", want \"string\"\nvalidating /properties/c: type: 1 has type \"integer\", want \"string\"\nvalidating /properties/d: type: 1 has type \"integer\", want \"string\"",
        "arguments rejected: a is an integer, the schema wants a string; b is an integer, the schema wants a string; c is an integer, the schema wants a string; and more",
    );
}

test "a -32602 as the TypeScript SDK's zod issues names each path and type" {
    try expectCause(
        "MCP protocol error -32602: MCP error -32602: Invalid arguments for tool search: [\n  {\n    \"code\": \"invalid_type\",\n    \"expected\": \"number\",\n    \"received\": \"string\",\n    \"path\": [\n      \"limit\"\n    ],\n    \"message\": \"Expected number, received string\"\n  }\n]",
        "arguments rejected: limit is a string, the schema wants a number",
    );
    try expectCause(
        "MCP protocol error -32602: Invalid arguments: [{\"code\":\"invalid_type\",\"expected\":\"boolean\",\"path\":[\"options\",\"verbose\"]},{\"code\":\"invalid_type\",\"expected\":\"string\",\"received\":\"number\",\"path\":[\"queries\",0]}]",
        "arguments rejected: options.verbose must be a boolean; queries[0] is a number, the schema wants a string",
    );
    try expectCause(
        "MCP protocol error -32602: Invalid arguments: [{\"code\":\"invalid_type\",\"expected\":\"object\",\"received\":\"string\",\"path\":[]}]",
        "arguments rejected: the arguments object is a string, the schema wants an object",
    );
}

test "a -32602 fx can't read says the server refused the parameters" {
    const general = "the server rejected the call's parameters (-32602)";
    try expectCause("MCP protocol error -32602: Unknown tool: nope", general);
    try expectCause("MCP protocol error -32602: ", general);
    try expectCause("MCP protocol error -32602: Invalid arguments: [not json]", general);
    try expectCause("MCP protocol error -32602: Invalid arguments: [{\"code\":\"custom\",\"path\":[\"x\"]}]", general);
    // The trace keeps the start of a long result, which can cut a line short.
    try expectCause("MCP protocol error -32602: validating /properties/limit: type: \"40\" has ty", general);
}

test "only a -32602 gets a cause, so other failures keep their text" {
    try expectCause("MCP protocol error -32603: internal error", null);
    try expectCause("MCP protocol error -32000: validating /properties/limit: type: \"40\" has type \"string\", want \"number\"", null);
    try expectCause("MCP protocol error -326020: Unknown tool", null);
    try expectCause("tool said: MCP protocol error -32602: Unknown tool", null);
    try expectCause("Invalid input: labels require at least one item", null);
    try expectCause("", null);
}

test "an invalid-params cause leaves out what the server wrote after the type and masks secrets" {
    const token = "ghp_" ++ text_utils.repeat("a", 36);
    try expectCause(
        "MCP protocol error -32602: validating /properties/limit: type: \"40\" has type \"string\", want \"number\" token=" ++ token,
        "arguments rejected: limit is a string, the schema wants a number",
    );
    try expectCause(
        "MCP protocol error -32602: validating /properties/id: type: \"x\" has type \"string\", want [\"integer\",\"null\"] (see " ++ token ++ ")",
        "arguments rejected: id is a string, the schema wants [\"integer\",\"null\"]",
    );
    try expectCause(
        "MCP protocol error -32602: validating /properties/limit: type: \"40\" has type \"string\", want number, see " ++ token,
        "arguments rejected: limit is a string, the schema wants a number",
    );
    try expectCause("MCP protocol error -32602: validating /properties/limit: type: \"40\" has type \"string\", want \"number", "the server rejected the call's parameters (-32602)");
    try expectCause(
        "MCP protocol error -32602: validating /properties/" ++ token ++ ": type: 1 has type \"integer\", want \"string\"",
        "arguments rejected: [redacted] is an integer, the schema wants a string",
    );
    try expectCause(
        "MCP protocol error -32602: [{\"code\":\"invalid_type\",\"expected\":\"number\",\"received\":\"string\",\"path\":[\"" ++ token ++ "\"]}]",
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
        "MCP protocol error -32602: validating /properties/a\x1b[2Jb: type: 1 has type \"integer\", want \"string\"",
        "MCP protocol error -32602: validating /properties/a\rb: type: 1 has type \"\x07integer\", want \"str\x00ing\"",
        try arena.print("MCP protocol error -32602: validating /properties/{s}: type: 1 has type \"integer\", want \"string\"", .{long_field}),
        "MCP protocol error -32602: Invalid arguments: [{\"expected\":\"number\\u001b[31m\",\"received\":\"string\",\"path\":[\"a\\nb\"]}]",
        "MCP protocol error -32602: Unknown tool \xff\xfe",
    };
    for (hostile) |text| {
        const cause = (try invalidParamsCause(arena, text)).?;
        try std.testing.expect(cause.len <= max_cause_bytes);
        for (cause) |byte| try std.testing.expect(byte >= 0x20 and byte != 0x7f);
    }
}

fn invalidParamsCauseAllocationFailures(alloc: Allocator) !void {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    _ = try invalidParamsCause(
        arena_state.allocator(),
        "MCP protocol error -32602: Invalid arguments: [{\"expected\":\"number\",\"received\":\"string\",\"path\":[\"limit\"]},{\"expected\":\"array\",\"path\":[\"queries\",0]}]",
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
