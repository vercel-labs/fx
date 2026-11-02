const std = @import("std");
const vercel_protocol = @import("vercel_protocol.zig");
const gateway_error_format = @import("../core/shared/gateway_error_format.zig");

const Allocator = std.mem.Allocator;

pub const FailureDiagnostics = struct {
    schema: ?[]u8 = null,
    request_shape: ?[]u8 = null,

    pub fn deinit(self: *FailureDiagnostics, alloc: Allocator) void {
        if (self.schema) |owned| alloc.free(owned);
        if (self.request_shape) |owned| alloc.free(owned);
        self.* = .{};
    }

    pub fn schemaText(self: FailureDiagnostics) []const u8 {
        return self.schema orelse "";
    }

    pub fn requestShapeText(self: FailureDiagnostics) []const u8 {
        return self.request_shape orelse "";
    }
};

/// Gateway error bodies are small; anything larger is not one.
const max_error_body_bytes: usize = 64 * 1024;

/// Reports whether a Gateway error body records a provider attempt rejected
/// with HTTP 413. Gateway returns the status of the last provider it tried,
/// so a size rejection from one provider can arrive as a 400 from a later
/// fallback. Malformed or unrecognized bodies report false.
pub fn providerRejectedRequestSize(alloc: Allocator, err_body: []const u8) bool {
    if (err_body.len > max_error_body_bytes) return false;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, err_body, .{}) catch return false;
    defer parsed.deinit();
    const routing = objectPath(parsed.value, &.{ "providerMetadata", "gateway", "routing" }) orelse return false;
    const model_attempts = routing.object.get("modelAttempts") orelse return false;
    if (model_attempts != .array) return false;
    for (model_attempts.array.items) |model_attempt| {
        if (model_attempt != .object) continue;
        const provider_attempts = model_attempt.object.get("providerAttempts") orelse continue;
        if (provider_attempts != .array) continue;
        for (provider_attempts.array.items) |attempt| {
            if (attempt != .object) continue;
            const status = attempt.object.get("statusCode") orelse continue;
            if (status == .integer and status.integer == 413) return true;
        }
    }
    return false;
}

fn objectPath(root: std.json.Value, keys: []const []const u8) ?std.json.Value {
    var value = root;
    for (keys) |key| {
        if (value != .object) return null;
        value = value.object.get(key) orelse return null;
    }
    return if (value == .object) value else null;
}

test "a provider 413 behind a Gateway fallback reports a size rejection" {
    const alloc = std.testing.allocator;
    // Shapes Gateway returned on 2026-10-07 for a 34 MB request to
    // anthropic/claude-haiku-4.5, reduced to the fields that matter.
    const default_route =
        \\{"error":{"message":"Bad Request","type":"AI_APICallError","param":{"statusCode":400}},
        \\"providerMetadata":{"gateway":{"routing":{"resolvedProvider":"anthropic","modelAttemptCount":1,
        \\"modelAttempts":[{"canonicalSlug":"anthropic/claude-haiku-4.5","success":false,"providerAttempts":[
        \\{"provider":"anthropic","success":false,"error":"Payload Too Large","statusCode":413},
        \\{"provider":"bedrock","success":false,"error":"Input is too long.","statusCode":400},
        \\{"provider":"vertexAnthropic","success":false,"error":"Bad Request","statusCode":400}]}]}}}}
    ;
    const vertex_only =
        \\{"error":{"message":"Bad Request","type":"AI_APICallError"},
        \\"providerMetadata":{"gateway":{"routing":{"modelAttempts":[{"providerAttempts":[
        \\{"provider":"vertexAnthropic","success":false,"error":"Bad Request","statusCode":400}]}]}}}}
    ;
    const bedrock_only =
        \\{"error":{"message":"Input is too long."},
        \\"providerMetadata":{"gateway":{"routing":{"modelAttempts":[{"providerAttempts":[
        \\{"provider":"bedrock","success":false,"error":"Input is too long.","statusCode":400}]}]}}}}
    ;
    try std.testing.expect(providerRejectedRequestSize(alloc, default_route));
    try std.testing.expect(!providerRejectedRequestSize(alloc, vertex_only));
    try std.testing.expect(!providerRejectedRequestSize(alloc, bedrock_only));
    try std.testing.expect(!providerRejectedRequestSize(alloc, "AI_APICallError: Bad Request"));
    try std.testing.expect(!providerRejectedRequestSize(alloc, "{\"providerMetadata\":{\"gateway\":{\"routing\":{\"modelAttempts\":[{\"providerAttempts\":[{\"statusCode\":\"413\"}]}]}}}}"));
    try std.testing.expect(!providerRejectedRequestSize(alloc, "{\"providerMetadata\":[]}"));
}

/// Returned diagnostics are owned by the caller and freed by calling `deinit`.
pub fn collect(alloc: Allocator, payload: []const u8, err_body: ?[]const u8) FailureDiagnostics {
    return .{
        .schema = if (err_body) |body| gateway_error_format.formatSchemaDiagnostic(alloc, body) catch null else null,
        .request_shape = vercel_protocol.formatGatewayRequestShapeSummary(alloc, payload) catch null,
    };
}
