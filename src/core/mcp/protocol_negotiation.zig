//! Pure MCP response and stdio protocol-negotiation decisions.

const std = @import("std");
const elicitation = @import("elicitation.zig");
const mcp_contract = @import("mcp_contract.zig");

pub const legacy_protocol_version = "2024-11-05";
pub const legacy_2025_03_protocol_version = "2025-03-26";
pub const legacy_2025_06_protocol_version = "2025-06-18";
pub const legacy_2025_11_protocol_version = "2025-11-25";
pub const modern_protocol_version = "2026-07-28";
pub const unsupported_protocol_version_code: i64 = -32022;
const missing_required_client_capability_code: i64 = -32021;

pub const Protocol = enum {
    unselected,
    legacy,
    modern,
};

pub const ProtocolError = struct {
    code: i64,
    message: []const u8,
    data: ?std.json.Value,
};

pub const ResponsePayload = union(enum) {
    complete: std.json.Value,
    protocol_error: ProtocolError,
};

pub const DiscoveryOutcome = union(enum) {
    modern,
    legacy_fallback: LegacyStdioVersion,
    unsupported,
    modern_protocol_error: ProtocolError,
};

/// HTTP discovery runs before protocol negotiation. Stock legacy SDK servers
/// may reject that probe with an ordinary JSON-RPC error (often `id: null`), so
/// any well-formed error falls back to legacy initialization. Only the explicit
/// modern-version retry signal keeps the connection on the modern path.
pub const HttpDiscoveryOutcome = enum {
    modern,
    retry_modern,
    legacy_fallback,
    unsupported,
};

pub const LegacyStdioVersion = enum {
    v2025_11_25,
    v2025_06_18,
    v2025_03_26,
    v2024_11_05,

    pub fn string(self: LegacyStdioVersion) []const u8 {
        return switch (self) {
            .v2025_11_25 => legacy_2025_11_protocol_version,
            .v2025_06_18 => legacy_2025_06_protocol_version,
            .v2025_03_26 => legacy_2025_03_protocol_version,
            .v2024_11_05 => legacy_protocol_version,
        };
    }

    pub fn wire(self: LegacyStdioVersion) ?elicitation.Wire {
        return switch (self) {
            .v2025_11_25 => .legacy_mcp_2025_11,
            .v2025_06_18 => .legacy_mcp_2025_06,
            .v2025_03_26, .v2024_11_05 => null,
        };
    }

    pub fn parse(value: []const u8) ?LegacyStdioVersion {
        if (std.mem.eql(u8, value, legacy_2025_11_protocol_version)) return .v2025_11_25;
        if (std.mem.eql(u8, value, legacy_2025_06_protocol_version)) return .v2025_06_18;
        if (std.mem.eql(u8, value, legacy_2025_03_protocol_version)) return .v2025_03_26;
        if (std.mem.eql(u8, value, legacy_protocol_version)) return .v2024_11_05;
        return null;
    }

    pub fn older(self: LegacyStdioVersion) ?LegacyStdioVersion {
        return switch (self) {
            .v2025_11_25 => .v2025_06_18,
            .v2025_06_18 => .v2025_03_26,
            .v2025_03_26 => .v2024_11_05,
            .v2024_11_05 => null,
        };
    }

    fn preference(self: LegacyStdioVersion) u3 {
        return switch (self) {
            .v2025_11_25 => 4,
            .v2025_06_18 => 3,
            .v2025_03_26 => 2,
            .v2024_11_05 => 1,
        };
    }

    fn isOlderThan(self: LegacyStdioVersion, other: LegacyStdioVersion) bool {
        return self.preference() < other.preference();
    }
};

pub const LegacyInitializeObservation = union(enum) {
    accepted: LegacyStdioVersion,
    unsupported: ?LegacyStdioVersion,
    connection_closed,
};

pub const LegacyInitializeTransition = union(enum) {
    accept: LegacyStdioVersion,
    retry: LegacyStdioVersion,
    fail,
};

pub fn decideLegacyInitializeTransition(
    offered: LegacyStdioVersion,
    observation: LegacyInitializeObservation,
) LegacyInitializeTransition {
    return switch (observation) {
        .accepted => |negotiated| .{ .accept = negotiated },
        .connection_closed => if (offered.older()) |version|
            .{ .retry = version }
        else
            .fail,
        .unsupported => |hint| if (hint) |version|
            if (version.isOlderThan(offered))
                .{ .retry = version }
            else
                .fail
        else if (offered.older()) |version|
            .{ .retry = version }
        else
            .fail,
    };
}

pub fn classifyResponsePayload(value: std.json.Value, protocol: Protocol) !ResponsePayload {
    try mcp_contract.validateJsonRpcResponseEnvelope(value);
    const object = value.object;

    if (object.get("error")) |error_value| {
        if (error_value != .object) return error.McpInvalidProtocolError;
        const code_value = error_value.object.get("code") orelse return error.McpInvalidProtocolError;
        const message_value = error_value.object.get("message") orelse return error.McpInvalidProtocolError;
        if (code_value != .integer or message_value != .string) return error.McpInvalidProtocolError;
        return .{ .protocol_error = .{
            .code = code_value.integer,
            .message = message_value.string,
            .data = error_value.object.get("data"),
        } };
    }

    const result = object.get("result") orelse return error.McpNoResult;
    if (result != .object) return error.McpInvalidResult;

    if (protocol == .modern) {
        const result_type = result.object.get("resultType") orelse return error.McpMissingResultType;
        if (result_type != .string) return error.McpInvalidResultType;
        if (!std.mem.eql(u8, result_type.string, "complete")) return error.McpUnsupportedResultType;
    }
    return .{ .complete = result };
}

pub fn classifyDiscoveryResponse(value: std.json.Value) !DiscoveryOutcome {
    if (value != .object) return error.McpInvalidJson;
    const object = value.object;

    if (object.get("error") != null) {
        const payload = try classifyResponsePayload(value, .modern);
        const protocol_error = switch (payload) {
            .complete => unreachable,
            .protocol_error => |err| err,
        };
        if (protocol_error.code == missing_required_client_capability_code) {
            return .{ .modern_protocol_error = protocol_error };
        }
        if (protocol_error.code != unsupported_protocol_version_code) {
            return .{ .legacy_fallback = .v2025_11_25 };
        }
        if (selectLegacyStdioVersion(protocol_error)) |version| {
            return .{ .legacy_fallback = version };
        }
        return .{ .modern_protocol_error = protocol_error };
    }

    const result = object.get("result") orelse return error.McpNoResult;
    if (result != .object) return error.McpInvalidResult;

    const payload = try classifyResponsePayload(value, .modern);
    const discover = switch (payload) {
        .complete => |complete| complete,
        .protocol_error => unreachable,
    };
    const supported_versions = discover.object.get("supportedVersions") orelse return error.McpInvalidDiscoverResult;
    const capabilities = discover.object.get("capabilities") orelse return error.McpInvalidDiscoverResult;
    if (supported_versions != .array or capabilities != .object) return error.McpInvalidDiscoverResult;
    var legacy_selection: ?LegacyStdioVersion = null;
    for (supported_versions.array.items) |version_value| {
        if (version_value != .string) return error.McpInvalidDiscoverResult;
        if (std.mem.eql(u8, version_value.string, modern_protocol_version)) return .modern;
        if (LegacyStdioVersion.parse(version_value.string)) |candidate| {
            if (legacy_selection == null or legacy_selection.?.isOlderThan(candidate)) {
                legacy_selection = candidate;
            }
        }
    }
    if (legacy_selection) |version| return .{ .legacy_fallback = version };
    return .unsupported;
}

pub fn classifyHttpDiscoveryResponse(value: std.json.Value) !HttpDiscoveryOutcome {
    if (value != .object) return error.McpInvalidJson;
    if (value.object.contains("error")) {
        const payload = try classifyResponsePayload(value, .modern);
        const protocol_error = switch (payload) {
            .complete => unreachable,
            .protocol_error => |err| err,
        };
        if (protocol_error.code == unsupported_protocol_version_code and
            protocolErrorSupportsVersion(protocol_error, modern_protocol_version))
        {
            return .retry_modern;
        }
        return .legacy_fallback;
    }

    return switch (try classifyDiscoveryResponse(value)) {
        .modern => .modern,
        .legacy_fallback => .legacy_fallback,
        .unsupported => .unsupported,
        .modern_protocol_error => unreachable,
    };
}

pub fn selectLegacyStdioVersion(protocol_error: ProtocolError) ?LegacyStdioVersion {
    return selectLegacyStdioVersionForRequest(protocol_error, modern_protocol_version);
}

pub fn selectLegacyStdioVersionForRequest(
    protocol_error: ProtocolError,
    requested_version: []const u8,
) ?LegacyStdioVersion {
    inline for ([_]LegacyStdioVersion{
        .v2025_11_25,
        .v2025_06_18,
        .v2025_03_26,
        .v2024_11_05,
    }) |version| {
        if (protocolErrorSupportsVersionForRequest(
            protocol_error,
            requested_version,
            version.string(),
        )) return version;
    }
    return null;
}

pub fn classifyLegacyInitializeResponse(
    value: std.json.Value,
    offered: LegacyStdioVersion,
) !LegacyInitializeObservation {
    const payload = try classifyResponsePayload(value, .legacy);
    const result = switch (payload) {
        .complete => |complete| complete,
        .protocol_error => |protocol_error| {
            if (protocol_error.code == unsupported_protocol_version_code) {
                return .{ .unsupported = selectLegacyStdioVersionForRequest(
                    protocol_error,
                    offered.string(),
                ) };
            }
            if (protocol_error.code == -32602) {
                const supported = selectLegacyStdioVersionForRequest(
                    protocol_error,
                    offered.string(),
                ) orelse return error.McpInitFailed;
                return .{ .unsupported = supported };
            }
            return error.McpInitFailed;
        },
    };
    const version = result.object.get("protocolVersion") orelse
        return error.McpUnsupportedProtocolVersion;
    if (version != .string) return error.McpUnsupportedProtocolVersion;
    return .{ .accepted = LegacyStdioVersion.parse(version.string) orelse
        return error.McpUnsupportedProtocolVersion };
}

pub fn protocolErrorSupportsVersion(protocol_error: ProtocolError, version: []const u8) bool {
    return protocolErrorSupportsVersionForRequest(
        protocol_error,
        modern_protocol_version,
        version,
    );
}

pub fn protocolErrorSupportsVersionForRequest(
    protocol_error: ProtocolError,
    requested_version: []const u8,
    version: []const u8,
) bool {
    const data = protocol_error.data orelse return false;
    if (data != .object) return false;
    const supported = data.object.get("supported") orelse return false;
    const requested = data.object.get("requested") orelse return false;
    if (supported != .array or requested != .string) return false;
    if (!std.mem.eql(u8, requested.string, requested_version)) return false;
    var found = false;
    for (supported.array.items) |supported_version| {
        if (supported_version != .string) return false;
        if (std.mem.eql(u8, supported_version.string, version)) found = true;
    }
    return found;
}

test "legacy initialization transitions are bounded and monotonic" {
    const cases = [_]struct {
        offered: LegacyStdioVersion,
        observation: LegacyInitializeObservation,
        expected: LegacyInitializeTransition,
    }{
        .{ .offered = .v2025_11_25, .observation = .{ .accepted = .v2025_11_25 }, .expected = .{ .accept = .v2025_11_25 } },
        .{ .offered = .v2025_11_25, .observation = .{ .accepted = .v2024_11_05 }, .expected = .{ .accept = .v2024_11_05 } },
        .{ .offered = .v2025_06_18, .observation = .{ .accepted = .v2025_11_25 }, .expected = .{ .accept = .v2025_11_25 } },
        .{ .offered = .v2025_03_26, .observation = .{ .accepted = .v2025_03_26 }, .expected = .{ .accept = .v2025_03_26 } },
        .{ .offered = .v2025_11_25, .observation = .connection_closed, .expected = .{ .retry = .v2025_06_18 } },
        .{ .offered = .v2025_06_18, .observation = .connection_closed, .expected = .{ .retry = .v2025_03_26 } },
        .{ .offered = .v2025_03_26, .observation = .connection_closed, .expected = .{ .retry = .v2024_11_05 } },
        .{ .offered = .v2024_11_05, .observation = .connection_closed, .expected = .fail },
        .{ .offered = .v2025_11_25, .observation = .{ .unsupported = null }, .expected = .{ .retry = .v2025_06_18 } },
        .{ .offered = .v2025_06_18, .observation = .{ .unsupported = null }, .expected = .{ .retry = .v2025_03_26 } },
        .{ .offered = .v2025_03_26, .observation = .{ .unsupported = null }, .expected = .{ .retry = .v2024_11_05 } },
        .{ .offered = .v2024_11_05, .observation = .{ .unsupported = null }, .expected = .fail },
        .{ .offered = .v2025_11_25, .observation = .{ .unsupported = .v2024_11_05 }, .expected = .{ .retry = .v2024_11_05 } },
        .{ .offered = .v2025_11_25, .observation = .{ .unsupported = .v2025_11_25 }, .expected = .fail },
        .{ .offered = .v2025_06_18, .observation = .{ .unsupported = .v2025_11_25 }, .expected = .fail },
    };
    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            decideLegacyInitializeTransition(case.offered, case.observation),
        );
    }
}

test "MCP legacy stdio negotiation includes 2025-03-26" {
    try std.testing.expectEqual(
        LegacyStdioVersion.v2025_03_26,
        LegacyStdioVersion.parse("2025-03-26").?,
    );
    try std.testing.expectEqual(
        LegacyStdioVersion.v2025_03_26,
        LegacyStdioVersion.v2025_06_18.older().?,
    );
    try std.testing.expectEqual(
        LegacyStdioVersion.v2024_11_05,
        LegacyStdioVersion.v2025_03_26.older().?,
    );
}

test "method-not-found discovery begins fallback at the newest legacy version" {
    const alloc = std.testing.allocator;
    var response = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
        .{},
    );
    defer response.deinit();

    switch (try classifyDiscoveryResponse(response.value)) {
        .legacy_fallback => |version| try std.testing.expectEqual(LegacyStdioVersion.v2025_11_25, version),
        else => return error.TestUnexpectedResult,
    }
}

test "ordinary well-formed discovery errors begin legacy fallback independent of code" {
    const responses = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32602,\"message\":\"Invalid params\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32000,\"message\":\"Server not initialized\"}}",
    };
    for (responses) |text| {
        var response = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            text,
            .{},
        );
        defer response.deinit();

        switch (try classifyDiscoveryResponse(response.value)) {
            .legacy_fallback => |version| try std.testing.expectEqual(
                LegacyStdioVersion.v2025_11_25,
                version,
            ),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "recognized modern discovery errors never downgrade" {
    const responses = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32021,\"message\":\"Missing required client capability\",\"data\":{\"capability\":\"roots\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"supported\":[\"2026-07-28\"],\"requested\":\"2026-07-28\"}}}",
    };
    for (responses) |text| {
        var response = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            text,
            .{},
        );
        defer response.deinit();

        switch (try classifyDiscoveryResponse(response.value)) {
            .modern_protocol_error => {},
            else => return error.TestUnexpectedResult,
        }
    }
}

test "HTTP discovery state machine accepts stock SDK null-id errors as legacy fallback" {
    const responses = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"Server not initialized\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"Bad Request: Unsupported protocol version\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32004,\"message\":\"invalid request\"}}",
    };
    for (responses) |text| {
        var response = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
        defer response.deinit();
        try std.testing.expectEqual(
            HttpDiscoveryOutcome.legacy_fallback,
            try classifyHttpDiscoveryResponse(response.value),
        );
    }
}

test "HTTP discovery retries modern only when the server explicitly supports it" {
    var response = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"supported\":[\"2026-07-28\"],\"requested\":\"2026-07-28\"}}}",
        .{},
    );
    defer response.deinit();
    try std.testing.expectEqual(
        HttpDiscoveryOutcome.retry_modern,
        try classifyHttpDiscoveryResponse(response.value),
    );
}

test "discovery selects the newest legacy version independent of server ordering" {
    const responses = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"resultType\":\"complete\",\"supportedVersions\":[\"2024-11-05\",\"2025-06-18\",\"2025-11-25\"],\"capabilities\":{}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"resultType\":\"complete\",\"supportedVersions\":[\"2025-11-25\",\"2025-06-18\",\"2024-11-05\"],\"capabilities\":{}}}",
    };
    for (responses) |text| {
        var response = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
        defer response.deinit();

        switch (try classifyDiscoveryResponse(response.value)) {
            .legacy_fallback => |version| try std.testing.expectEqual(LegacyStdioVersion.v2025_11_25, version),
            else => return error.TestUnexpectedResult,
        }
    }
}
