const std = @import("std");
const build_options = @import("build_options");
const mcp_json = @import("mcp_json.zig");
const mcp_contract = @import("mcp_contract.zig");
const elicitation = @import("elicitation.zig");
const protocol_negotiation = @import("protocol_negotiation.zig");
const tools_feature = @import("features/tools.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const ServerCapabilities = @import("catalog_state.zig").ServerCapabilities;
const Allocator = std.mem.Allocator;
const StdioProtocol = protocol_negotiation.Protocol;
const modern_protocol_version = protocol_negotiation.modern_protocol_version;

pub fn buildDiscoverRequest(alloc: Allocator, request_id: u64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try out.writer.print("{d}", .{request_id});
    try out.writer.writeAll(",\"method\":\"server/discover\",\"params\":{\"_meta\":");
    try writeModernRequestMetadata(&out.writer);
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

pub fn buildToolsListRequest(
    alloc: Allocator,
    request_id: u64,
    protocol: StdioProtocol,
    cursor: ?[]const u8,
) ![]u8 {
    return tools_feature.buildListRequest(
        alloc,
        request_id,
        featureProtocol(protocol),
        cursor,
        writeModernRequestMetadata,
    );
}

pub fn writeModernRequestMetadata(writer: *std.Io.Writer) !void {
    return writeModernRequestMetadataWithProgress(writer, null, .{});
}

pub fn buildToolCallRequest(alloc: Allocator, request_id: u64, original_name: []const u8, arguments_json: []const u8) ![]u8 {
    return buildToolCallRequestForProtocol(
        alloc,
        request_id,
        original_name,
        arguments_json,
        .legacy,
        null,
        null,
        .{},
    );
}

pub fn buildToolCallRequestForProtocol(
    alloc: Allocator,
    request_id: u64,
    original_name: []const u8,
    arguments_json: []const u8,
    protocol: StdioProtocol,
    progress_token: ?u64,
    continuation: ?tool_mcp_runtime.Continuation,
    capabilities: elicitation.Capabilities,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try out.writer.print("{d}", .{request_id});
    try out.writer.writeAll(",\"method\":\"tools/call\",\"params\":{");
    if (protocol == .modern) {
        try out.writer.writeAll("\"_meta\":");
        try writeModernRequestMetadataWithProgress(&out.writer, progress_token, capabilities);
        try out.writer.writeAll(",");
    } else if (progress_token) |token| {
        try out.writer.print("\"_meta\":{{\"progressToken\":{d}}},", .{token});
    }
    try out.writer.writeAll("\"name\":");
    try std.json.Stringify.value(original_name, .{}, &out.writer);
    try out.writer.writeAll(",\"arguments\":");
    // Models may pretty-print arguments; a raw newline would split the NDJSON
    // frame, so compact them onto a single line before framing.
    try mcp_json.write_compact(&out.writer, arguments_json);
    if (continuation) |value| {
        try out.writer.writeAll(",\"inputResponses\":");
        try mcp_json.write_compact(&out.writer, value.input_responses_json);
        if (value.request_state_json) |state| {
            try out.writer.writeAll(",\"requestState\":");
            try mcp_json.write_compact(&out.writer, state);
        }
    }
    try out.writer.writeAll("}}");

    return try out.toOwnedSlice();
}

pub fn writeModernRequestMetadataWithProgress(
    writer: *std.Io.Writer,
    progress_token: ?u64,
    capabilities: elicitation.Capabilities,
) !void {
    try writer.writeAll("{\"io.modelcontextprotocol/protocolVersion\":\"");
    try writer.writeAll(modern_protocol_version);
    try writer.writeAll("\",\"io.modelcontextprotocol/clientInfo\":{\"name\":\"fx\",\"version\":");
    try std.json.Stringify.value(build_options.app_version, .{}, writer);
    try writer.writeAll("},\"io.modelcontextprotocol/clientCapabilities\":{");
    if (capabilities.any()) {
        try writer.writeAll("\"elicitation\":{");
        var wrote_mode = false;
        if (capabilities.form) {
            try writer.writeAll("\"form\":{}");
            wrote_mode = true;
        }
        if (capabilities.url) {
            if (wrote_mode) try writer.writeByte(',');
            try writer.writeAll("\"url\":{}");
        }
        try writer.writeByte('}');
    }
    try writer.writeByte('}');
    if (progress_token) |token| {
        try writer.print(",\"progressToken\":{d}", .{token});
    }
    try writer.writeByte('}');
}

pub fn writeModernRequestMetadataForm(writer: *std.Io.Writer) !void {
    return writeModernRequestMetadataWithProgress(writer, null, .{ .form = true });
}

pub fn writeModernRequestMetadataUrl(writer: *std.Io.Writer) !void {
    return writeModernRequestMetadataWithProgress(writer, null, .{ .url = true });
}

pub fn writeModernRequestMetadataFormAndUrl(writer: *std.Io.Writer) !void {
    return writeModernRequestMetadataWithProgress(writer, null, .{ .form = true, .url = true });
}

pub fn buildLegacyInitializeRequest(
    alloc: Allocator,
    request_id: u64,
    protocol_version: []const u8,
    negotiated_wire: ?elicitation.Wire,
    elicitation_capabilities: elicitation.Capabilities,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"protocolVersion\":",
        .{request_id},
    );
    try std.json.Stringify.value(protocol_version, .{}, &out.writer);
    try out.writer.writeAll(",\"capabilities\":{");
    if (negotiated_wire != null and elicitation_capabilities.form) {
        try out.writer.writeAll("\"elicitation\":");
        if (negotiated_wire.? == .legacy_mcp_2025_06) {
            try out.writer.writeAll("{}");
        } else {
            try out.writer.writeAll("{\"form\":{}");
            if (elicitation_capabilities.url) try out.writer.writeAll(",\"url\":{}");
            try out.writer.writeByte('}');
        }
    } else if (negotiated_wire == .legacy_mcp_2025_11 and elicitation_capabilities.url) {
        try out.writer.writeAll("\"elicitation\":{\"url\":{}}");
    }
    try out.writer.writeAll("},\"clientInfo\":{\"name\":\"fx\",\"version\":");
    try std.json.Stringify.value(build_options.app_version, .{}, &out.writer);
    try out.writer.writeAll("}}}");
    return out.toOwnedSlice();
}

pub fn buildCancellationNotification(
    alloc: Allocator,
    request_id: u64,
    reason: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":",
    );
    try out.writer.print("{d}", .{request_id});
    try out.writer.writeAll(",\"reason\":");
    try std.json.Stringify.value(reason, .{}, &out.writer);
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

pub fn parseToolsListChangedCapabilityFromResponse(
    alloc: Allocator,
    response: []const u8,
) !bool {
    return (try parseServerCapabilitiesFromResponse(alloc, response)).tools_list_changed;
}

pub fn parseServerCapabilitiesFromResponse(
    alloc: Allocator,
    response: []const u8,
) !ParsedServerCapabilities {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response, .{}) catch
        return error.McpInvalidJson;
    defer parsed.deinit();
    return parseServerCapabilities(parsed.value);
}

pub fn parseServerIdentity(value: std.json.Value) !ParsedServerIdentity {
    try mcp_contract.validateJsonRpcResponseEnvelope(value);
    const result = value.object.get("result") orelse return error.McpInvalidResult;
    if (result != .object) return error.McpInvalidResult;
    const info = blk: {
        if (result.object.get("_meta")) |meta| {
            if (meta != .object) return error.McpInvalidResult;
            if (meta.object.get("io.modelcontextprotocol/serverInfo")) |modern| {
                break :blk modern;
            }
        }
        break :blk result.object.get("serverInfo") orelse return .{};
    };
    if (info != .object) return error.McpInvalidResult;
    const name = if (info.object.get("name")) |field| blk: {
        if (field != .string) return error.McpInvalidResult;
        break :blk if (field.string.len > 0) field.string else null;
    } else null;
    const version = if (info.object.get("version")) |field| blk: {
        if (field != .string) return error.McpInvalidResult;
        break :blk if (field.string.len > 0) field.string else null;
    } else null;
    return .{ .name = name, .version = version };
}

pub fn parseToolsListChangedCapability(value: std.json.Value) !bool {
    return (try parseServerCapabilities(value)).tools_list_changed;
}

pub fn parseServerCapabilities(value: std.json.Value) !ParsedServerCapabilities {
    try mcp_contract.validateJsonRpcResponseEnvelope(value);
    if (value.object.contains("error")) return .{};
    const result = value.object.get("result") orelse return error.McpInvalidResult;
    if (result != .object) return error.McpInvalidResult;
    const capabilities = result.object.get("capabilities") orelse return .{};
    if (capabilities != .object) return error.McpInvalidResult;
    var parsed: ParsedServerCapabilities = .{};
    if (capabilities.object.get("tools")) |tools| {
        if (tools != .object) return error.McpInvalidResult;
        parsed.tools_list_changed = try optionalCapabilityBool(tools.object, "listChanged");
    }
    if (capabilities.object.get("resources")) |resources| {
        if (resources != .object) return error.McpInvalidResult;
        parsed.features.resources = true;
        parsed.features.resources_list_changed = try optionalCapabilityBool(resources.object, "listChanged");
        parsed.features.resources_subscribe = try optionalCapabilityBool(resources.object, "subscribe");
    }
    if (capabilities.object.get("prompts")) |prompts| {
        if (prompts != .object) return error.McpInvalidResult;
        parsed.features.prompts = true;
        parsed.features.prompts_list_changed = try optionalCapabilityBool(prompts.object, "listChanged");
    }
    if (capabilities.object.get("completions")) |completions| {
        if (completions != .object) return error.McpInvalidResult;
        parsed.features.completion = true;
    }
    return parsed;
}

pub fn optionalCapabilityBool(object: std.json.ObjectMap, name: []const u8) !bool {
    const value = object.get(name) orelse return false;
    if (value != .bool) return error.McpInvalidResult;
    return value.bool;
}

pub fn featureProtocol(protocol: StdioProtocol) tools_feature.Protocol {
    return switch (protocol) {
        .legacy => .legacy,
        .modern => .modern,
        .unselected => .legacy,
    };
}

pub const ParsedServerIdentity = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

pub const ParsedServerCapabilities = struct {
    tools_list_changed: bool = false,
    features: ServerCapabilities = .{},
};

pub fn metadataWriterForCapabilities(
    capabilities: elicitation.Capabilities,
) *const fn (*std.Io.Writer) anyerror!void {
    if (capabilities.form and capabilities.url) return writeModernRequestMetadataFormAndUrl;
    if (capabilities.form) return writeModernRequestMetadataForm;
    if (capabilities.url) return writeModernRequestMetadataUrl;
    return writeModernRequestMetadata;
}
