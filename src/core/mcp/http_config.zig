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

/// An MCP server's URL: HTTPS, or plain HTTP to 127.0.0.1, localhost, or
/// [::1], with no credentials or fragment. Plain HTTP without a port goes to
/// port 80 (`src/mcp/io/http.zig`). (`tests/tla/mcp_config/ProfileLoad.tla`
/// PlainHttpOnlyToLoopback, LoopbackHttpNeverSkipped)
pub fn validateServerUrl(url: []const u8) EndpointError!void {
    const uri = std.Uri.parse(url) catch return error.InvalidEndpoint;
    if (uri.user != null or uri.password != null or uri.fragment != null) {
        return error.InvalidEndpoint;
    }
    const host_component = uri.host orelse return error.InvalidEndpoint;

    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InsecureEndpoint;

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

/// The libfx gateway URL: a URL `validateServerUrl` takes, whose plain HTTP
/// names its port, as the gateway endpoint policy in `sdk/NAPI.md` says.
pub fn validateEndpoint(url: []const u8) EndpointError!void {
    try validateServerUrl(url);
    const uri = std.Uri.parse(url) catch return error.InvalidEndpoint;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http") and uri.port == null) {
        return error.InsecureEndpoint;
    }
}

/// An `oauth.resource`: a URL `validateServerUrl` takes, whose host and path
/// fit fx's buffers.
pub fn validateOAuthResource(url: []const u8) error{InvalidOAuthResource}!void {
    validateServerUrl(url) catch return error.InvalidOAuthResource;
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

test "an MCP server URL is HTTPS, or plain HTTP to loopback with or without a port" {
    try validateServerUrl("https://mcp.example.com/rpc?workspace=one");
    try validateServerUrl("https://localhost/mcp");
    try validateServerUrl("http://localhost:4321/mcp");
    try validateServerUrl("http://127.0.0.1:4321/mcp");
    try validateServerUrl("http://[::1]:4321/mcp");
    try validateServerUrl("http://localhost/mcp");
    try validateServerUrl("http://127.0.0.1/mcp");
    try validateServerUrl("http://[::1]/mcp");
    try validateServerUrl("HTTP://LOCALHOST/mcp");

    try std.testing.expectError(error.InsecureEndpoint, validateServerUrl("http://example.com/mcp"));
    try std.testing.expectError(error.InsecureEndpoint, validateServerUrl("http://example.com:8080/mcp"));
    try std.testing.expectError(error.InsecureEndpoint, validateServerUrl("http://localhost.example.com/mcp"));
    try std.testing.expectError(error.InsecureEndpoint, validateServerUrl("http://127.0.0.2/mcp"));
    try std.testing.expectError(error.InsecureEndpoint, validateServerUrl("ftp://localhost/mcp"));
    try std.testing.expectError(error.InvalidEndpoint, validateServerUrl("http://localhost:/mcp"));
    try std.testing.expectError(error.InvalidEndpoint, validateServerUrl("http://user@localhost/mcp"));
    try std.testing.expectError(error.InvalidEndpoint, validateServerUrl("http://localhost/mcp#part"));
    try std.testing.expectError(error.InvalidEndpoint, validateServerUrl("https://user@example.com/mcp"));
    try std.testing.expectError(error.InvalidEndpoint, validateServerUrl("https://example.com/mcp#fragment"));
}

test "the libfx gateway URL still names its port on plain HTTP" {
    try validateEndpoint("https://mcp.example.com/rpc?workspace=one");
    try validateEndpoint("http://localhost:4321/mcp");
    try validateEndpoint("http://127.0.0.1:4321/mcp");
    try validateEndpoint("http://[::1]:4321/mcp");

    try std.testing.expectError(error.InsecureEndpoint, validateEndpoint("http://example.com/mcp"));
    try std.testing.expectError(error.InsecureEndpoint, validateEndpoint("http://localhost/mcp"));
    try std.testing.expectError(error.InvalidEndpoint, validateEndpoint("https://user@example.com/mcp"));
    try std.testing.expectError(error.InvalidEndpoint, validateEndpoint("https://example.com/mcp#fragment"));
}

fn fuzzServerUrl(_: void, smith: *std.testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    const url = buffer[0..len];
    const server = validateServerUrl(url);
    const gateway = validateEndpoint(url);
    // The gateway rule only narrows the server rule.
    if (gateway) |_| try server else |_| {}
    server catch return;

    const uri = try std.Uri.parse(url);
    try std.testing.expect(uri.user == null and uri.password == null and uri.fragment == null);
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        try gateway;
        return;
    }
    try std.testing.expect(std.ascii.eqlIgnoreCase(uri.scheme, "http"));
    // The host the engine would connect to (src/mcp/io/http.zig) is loopback,
    // or fx can't name it and never connects.
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    if (std.Io.net.HostName.fromUri(uri, &host_buffer)) |host| {
        try std.testing.expect(std.mem.eql(u8, host.bytes, "127.0.0.1") or
            std.ascii.eqlIgnoreCase(host.bytes, "localhost") or
            std.mem.eql(u8, host.bytes, "[::1]"));
    } else |_| {}
    if (uri.port == null) {
        try std.testing.expectError(error.InsecureEndpoint, gateway);
    } else {
        try gateway;
    }
}

test "MCP server URLs keep plain HTTP on loopback for fuzzed URLs" {
    try std.testing.fuzz({}, fuzzServerUrl, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "http://localhost/mcp",
            "http://localhost:4321/mcp",
            "http://127.0.0.1/mcp",
            "http://[::1]/mcp",
            "HTTP://LOCALHOST/mcp",
            "http://%6Cocalhost/mcp",
            "http://localhost.example.com/mcp",
            "http://example.com/mcp",
            "http://user@localhost/mcp",
            "http://localhost:/mcp",
            "https://mcp.example.com/mcp",
        }) ++ @import("fuzz_corpus").mcp_server_url.*),
    });
}

test "an OAuth resource and client metadata URL follow fx's URL rules" {
    try validateOAuthResource("https://api.example.com/mcp?tenant=one");
    try validateOAuthResource("http://localhost:9876/mcp");
    try validateOAuthResource("http://localhost/mcp");
    try std.testing.expectError(error.InvalidOAuthResource, validateOAuthResource("http://api.example.com/mcp"));
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
