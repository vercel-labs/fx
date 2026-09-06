const std = @import("std");
const text_utils = @import("../shared/text_utils.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const elicitation = @import("elicitation.zig");
const mcp_json = @import("mcp_json.zig");
const mrtr = @import("mrtr.zig");
const protocol_negotiation = @import("protocol_negotiation.zig");
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

/// Parses an MCP response into the bounded, secret-masked model result.
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
        const raw = try std.fmt.allocPrint(
            alloc,
            "MCP protocol failure: {s}",
            .{@errorName(err)},
        );
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
            errdefer alloc.free(input_requests_json);
            const request_state_json = if (required.request_state_json) |state|
                try alloc.dupe(u8, state)
            else
                null;
            errdefer if (request_state_json) |state| alloc.free(state);
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

pub fn protocol_diagnostic_alloc(
    alloc: Allocator,
    code: i64,
    message: []const u8,
    data_json: ?[]const u8,
) ![]u8 {
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    var raw: std.Io.Writer.Allocating = .init(scratch);
    try write_protocol_diagnostic(
        scratch,
        &raw.writer,
        code,
        message,
        data_json,
    );
    return try alloc.dupe(u8, raw.writer.buffered());
}

pub fn format_protocol_error(
    alloc: Allocator,
    protocol_error: protocol_negotiation.ProtocolError,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var raw: std.Io.Writer.Allocating = .init(arena);

    try raw.writer.print("MCP protocol error {d}: ", .{protocol_error.code});
    const safe_message = try text_utils.sanitizeModelText(
        arena,
        protocol_error.message,
    );
    try raw.writer.writeAll(try text_utils.maskSecrets(arena, safe_message));
    if (protocol_error.data) |data| {
        try raw.writer.writeAll("; data=");
        try write_masked_json_value(arena, &raw.writer, data);
    }
    return try alloc.dupe(u8, raw.writer.buffered());
}

pub fn frame_too_large_result(
    alloc: Allocator,
    server_name: []const u8,
    tool_name: []const u8,
    cap_bytes: usize,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"server\":");
    try std.json.Stringify.value(server_name, .{}, &out.writer);
    try out.writer.writeAll(",\"tool\":");
    try std.json.Stringify.value(tool_name, .{}, &out.writer);
    try out.writer.writeAll(",\"error\":{\"kind\":\"response_frame_too_large\",\"message\":\"MCP response frame exceeded the raw pre-parse cap\",\"cap_bytes\":");
    try out.writer.print("{d}", .{cap_bytes});
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
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
    errdefer alloc.free(input_requests_json);
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
    defer scratch_state.deinit();
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
    try writer.writeAll(try text_utils.maskSecrets(scratch, safe_message));
    if (data_json) |data| {
        const safe_data = try text_utils.sanitizeModelText(scratch, data);
        try writer.writeAll("; data=");
        try writer.writeAll(try text_utils.maskSecrets(scratch, safe_data));
    }
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
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var full = std.Io.Writer.Allocating.init(arena);
    try write_envelope(arena, &full.writer, server_name, tool_name, result);
    const full_output = full.writer.buffered();
    if (full_output.len <= max_tool_result_bytes) {
        return try alloc.dupe(u8, full_output);
    }

    const combined = try collect_result_text(arena, result);
    const marker = try std.fmt.allocPrint(
        arena,
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
    try write_masked_json_value(alloc, writer, result);
    try writer.writeByte('}');
}

fn write_masked_json_value(
    alloc: Allocator,
    writer: *std.Io.Writer,
    value: std.json.Value,
) !void {
    switch (value) {
        .null, .bool, .integer, .float, .number_string => try std.json.Stringify.value(value, .{}, writer),
        .string => |text| {
            const sanitized = try text_utils.sanitizeModelText(alloc, text);
            try std.json.Stringify.value(
                try text_utils.maskSecrets(alloc, sanitized),
                .{},
                writer,
            );
        },
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                try write_masked_json_value(alloc, writer, item);
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
                try write_masked_json_value(alloc, writer, entry.value_ptr.*);
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
            const masked = try text_utils.maskSecrets(arena, sanitized);
            if (needs_separator.*) try writer.writeByte('\n');
            try writer.writeAll(masked);
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
        std.testing.allocator,
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
        std.testing.allocator,
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

test "large tool results stay valid, bounded, and secret-masked" {
    const alloc = std.testing.allocator;
    const large_text = "TOKEN=secret-value " ++ ("x" ** 1800);
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
    try std.testing.expect(std.mem.find(
        u8,
        result.model_output,
        "TOKEN=secret-value",
    ) == null);
    try std.testing.expect(std.mem.find(
        u8,
        result.model_output,
        "TOKEN=[redacted]",
    ) != null);
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
