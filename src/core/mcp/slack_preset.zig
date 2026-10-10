const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const client_id = "12364000946.12017137861236";
pub const endpoint = "https://mcp.slack.com/mcp";
pub const configuration_conflict = "Slack has custom configuration. Keep it and use /mcp auth slack --open, or remove it with /mcp remove slack before adding the fx preset.";

/// Returns the endpoint owned by the caller, including the existing OAuth test fixture override.
pub fn endpoint_alloc(alloc: std.mem.Allocator) ![]u8 {
    if (io_mod.getenv("FX_E2E_SLACK_ORIGIN")) |origin| {
        if (!std.mem.eql(u8, origin, "https://fx.sh")) {
            if (!std.mem.startsWith(u8, origin, "http://127.0.0.1:")) return error.InvalidSlackTestOrigin;
            const port = std.fmt.parseInt(u16, origin[17..], 10) catch return error.InvalidSlackTestOrigin;
            if (port < 1024) return error.InvalidSlackTestOrigin;
            return alloc.print("{s}/mcp", .{origin});
        }
    }
    return alloc.dupe(u8, endpoint);
}
