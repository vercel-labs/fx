const std = @import("std");
const gateway_json = @import("gateway_json.zig");
const gateway_error_format = @import("gateway_error_format.zig");

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

/// Returned diagnostics are owned by the caller and freed by calling `deinit`.
pub fn collect(alloc: Allocator, payload: []const u8, err_body: ?[]const u8) FailureDiagnostics {
    return .{
        .schema = if (err_body) |body| gateway_error_format.formatSchemaDiagnostic(alloc, body) catch null else null,
        .request_shape = gateway_json.formatGatewayRequestShapeSummary(alloc, payload) catch null,
    };
}
