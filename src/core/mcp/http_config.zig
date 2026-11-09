//! The URL and header rules for a configured HTTP MCP server, checked when
//! fx reads the config.

const std = @import("std");
const mcp_contract = @import("mcp_contract.zig");

pub const EndpointError = error{
    InvalidEndpoint,
    InsecureEndpoint,
};

pub const HeaderError = error{
    InvalidHeaderName,
    InvalidHeaderValue,
    DuplicateHeader,
    ReservedHeader,
};

pub fn validateEndpoint(url: []const u8) EndpointError!void {
    const uri = std.Uri.parse(url) catch return error.InvalidEndpoint;
    if (uri.user != null or uri.password != null or uri.fragment != null) {
        return error.InvalidEndpoint;
    }
    const host_component = uri.host orelse return error.InvalidEndpoint;

    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or uri.port == null) {
        return error.InsecureEndpoint;
    }

    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return error.InvalidEndpoint;
    if (std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]"))
    {
        return;
    }
    return error.InsecureEndpoint;
}

/// An `oauth.resource`: an endpoint `validateEndpoint` takes, whose host and
/// path fit fx's buffers.
pub fn validateOAuthResource(url: []const u8) error{InvalidOAuthResource}!void {
    validateEndpoint(url) catch return error.InvalidOAuthResource;
    const uri = std.Uri.parse(url) catch return error.InvalidOAuthResource;
    const host_component = uri.host orelse return error.InvalidOAuthResource;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    _ = host_component.toRaw(&host_buf) catch return error.InvalidOAuthResource;
    var path_buf: [4096]u8 = undefined;
    _ = uri.path.toRaw(&path_buf) catch return error.InvalidOAuthResource;
}

/// An `oauth.client_metadata_url`: an HTTPS document with a path, and no
/// credentials or fragment.
pub fn validateClientMetadataUrl(url: []const u8) error{InvalidClientMetadataUrl}!void {
    const uri = std.Uri.parse(url) catch return error.InvalidClientMetadataUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or uri.host == null or
        uri.user != null or uri.password != null or uri.fragment != null)
    {
        return error.InvalidClientMetadataUrl;
    }
    var path_buffer: [4096]u8 = undefined;
    const path = uri.path.toRaw(&path_buffer) catch
        return error.InvalidClientMetadataUrl;
    if (std.mem.trim(u8, path, "/").len == 0) {
        return error.InvalidClientMetadataUrl;
    }
}

pub fn validateStaticHeaders(headers: []const mcp_contract.McpHttpHeader) HeaderError!void {
    for (headers, 0..) |header, index| {
        if (!isHttpToken(header.name)) return error.InvalidHeaderName;
        if (!isValidHeaderValue(header.value)) return error.InvalidHeaderValue;
        if (isReservedHeader(header.name)) return error.ReservedHeader;

        for (headers[0..index]) |previous| {
            if (std.ascii.eqlIgnoreCase(previous.name, header.name)) {
                return error.DuplicateHeader;
            }
        }
    }
}

fn isHttpToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
            else => return false,
        }
    }
    return true;
}

fn isValidHeaderValue(value: []const u8) bool {
    for (value) |byte| {
        if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return false;
    }
    return true;
}

fn isReservedHeader(name: []const u8) bool {
    const reserved = [_][]const u8{
        "accept",
        "accept-encoding",
        "connection",
        "content-length",
        "content-type",
        "host",
        "last-event-id",
        "mcp-method",
        "mcp-name",
        "mcp-protocol-version",
        "mcp-session-id",
        "transfer-encoding",
    };
    for (reserved) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    }
    const prefix = "mcp-param-";
    return name.len >= prefix.len and std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix);
}

test "MCP endpoint policy accepts HTTPS and explicit loopback HTTP" {
    try validateEndpoint("https://mcp.example.com/rpc?workspace=one");
    try validateEndpoint("http://localhost:4321/mcp");
    try validateEndpoint("http://127.0.0.1:4321/mcp");
    try validateEndpoint("http://[::1]:4321/mcp");

    try std.testing.expectError(error.InsecureEndpoint, validateEndpoint("http://example.com/mcp"));
    try std.testing.expectError(error.InsecureEndpoint, validateEndpoint("http://localhost/mcp"));
    try std.testing.expectError(error.InvalidEndpoint, validateEndpoint("https://user@example.com/mcp"));
    try std.testing.expectError(error.InvalidEndpoint, validateEndpoint("https://example.com/mcp#fragment"));
}

test "an OAuth resource and client metadata URL follow fx's URL rules" {
    try validateOAuthResource("https://api.example.com/mcp?tenant=one");
    try validateOAuthResource("http://localhost:9876/mcp");
    try std.testing.expectError(error.InvalidOAuthResource, validateOAuthResource("http://api.example.com/mcp"));
    try std.testing.expectError(error.InvalidOAuthResource, validateOAuthResource("http://localhost/mcp"));
    try std.testing.expectError(error.InvalidOAuthResource, validateOAuthResource("https://user@api.example.com/mcp"));
    try std.testing.expectError(error.InvalidOAuthResource, validateOAuthResource("https://api.example.com/mcp#part"));

    try validateClientMetadataUrl("https://fx.example.com/client.json");
    try std.testing.expectError(error.InvalidClientMetadataUrl, validateClientMetadataUrl("http://fx.example.com/client.json"));
    try std.testing.expectError(error.InvalidClientMetadataUrl, validateClientMetadataUrl("https://fx.example.com/"));
    try std.testing.expectError(error.InvalidClientMetadataUrl, validateClientMetadataUrl("https://fx.example.com/client.json#part"));
}

test "MCP static headers reject malformed duplicate and protocol-owned names" {
    const valid = [_]mcp_contract.McpHttpHeader{
        .{ .name = @constCast("Authorization"), .value = @constCast("Bearer redacted") },
        .{ .name = @constCast("X-Workspace"), .value = @constCast("one") },
    };
    try validateStaticHeaders(&valid);

    const duplicate = [_]mcp_contract.McpHttpHeader{
        .{ .name = @constCast("X-Workspace"), .value = @constCast("one") },
        .{ .name = @constCast("x-workspace"), .value = @constCast("two") },
    };
    try std.testing.expectError(error.DuplicateHeader, validateStaticHeaders(&duplicate));

    const invalid_name = [_]mcp_contract.McpHttpHeader{
        .{ .name = @constCast("Bad Header"), .value = @constCast("value") },
    };
    try std.testing.expectError(error.InvalidHeaderName, validateStaticHeaders(&invalid_name));

    const injected = [_]mcp_contract.McpHttpHeader{
        .{ .name = @constCast("X-Test"), .value = @constCast("one\r\ntwo") },
    };
    try std.testing.expectError(error.InvalidHeaderValue, validateStaticHeaders(&injected));

    const reserved = [_]mcp_contract.McpHttpHeader{
        .{ .name = @constCast("Mcp-Param-Region"), .value = @constCast("override") },
    };
    try std.testing.expectError(error.ReservedHeader, validateStaticHeaders(&reserved));

    const legacy_reserved = [_]mcp_contract.McpHttpHeader{
        .{ .name = @constCast("MCP-Session-Id"), .value = @constCast("override") },
    };
    try std.testing.expectError(error.ReservedHeader, validateStaticHeaders(&legacy_reserved));
}
