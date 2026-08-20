const std = @import("std");
const connection_registry = @import("connection_registry.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const route_snapshot = @import("route_snapshot.zig");

pub fn owned(alloc: std.mem.Allocator, model: []const u8) !route_snapshot.RouteSnapshot {
    return route_snapshot.RouteSnapshot.admit(
        alloc,
        connection_registry.Profile{
            .id = @constCast("test-connection"),
            .display_name = @constCast("Example Cloud"),
            .adapter_id = @constCast("test-adapter"),
            .endpoint = @constCast("https://example.invalid"),
            .protocol = @constCast("test-model-stream"),
            .credential_ref = @constCast("test-credential"),
            .remembered_model = @constCast(model),
            .internal_models = .{
                .permission_review = @constCast("test/reviewer"),
                .vision = @constCast("test/vision"),
            },
        },
        model_capabilities.configuredDescriptor(model, .{}),
        "https://example.invalid",
    );
}
