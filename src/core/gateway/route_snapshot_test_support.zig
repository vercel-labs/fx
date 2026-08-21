const std = @import("std");
const connection_registry = @import("connection_registry.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const route_snapshot = @import("route_snapshot.zig");

pub fn owned(alloc: std.mem.Allocator, model: []const u8) !route_snapshot.RouteSnapshot {
    return route_snapshot.RouteSnapshot.admit(
        alloc,
        connection_registry.Profile{
            .id = @constCast("vercel"),
            .display_name = @constCast("Vercel AI Gateway"),
            .adapter_id = @constCast("vercel_ai_gateway"),
            .endpoint = @constCast("https://example.invalid"),
            .protocol = @constCast("vercel_ai_gateway"),
            .credential_ref = @constCast("automatic"),
            .remembered_model = @constCast(model),
            .permission_review_model = null,
        },
        model_capabilities.configuredDescriptor(model, .{}),
        "https://example.invalid",
    );
}
