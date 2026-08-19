const std = @import("std");

pub const current_api_version: u32 = 1;

pub const Capabilities = packed struct {
    workspace_read: bool = false,
    workspace_write: bool = false,
    terminal: bool = false,
    network: bool = false,
    secrets: bool = false,
    clipboard: bool = false,
    _reserved: u10 = 0,
};

pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8 = "",
    api_version: u32 = current_api_version,
    capabilities: Capabilities = .{},
};

pub fn validate(comptime manifest: Manifest) void {
    if (manifest.api_version != current_api_version) {
        @compileError(std.fmt.comptimePrint(
            "fx mod '{s}' targets API version {d}, but this fx build supports {d}",
            .{ manifest.name, manifest.api_version, current_api_version },
        ));
    }
    validateToken("mod name", manifest.name);
    if (manifest.version.len == 0) @compileError("fx mod version must not be empty");
}

fn validateToken(comptime label: []const u8, comptime value: []const u8) void {
    if (value.len == 0) @compileError(label ++ " must not be empty");
    for (value) |byte| {
        const valid = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-';
        if (!valid) {
            @compileError(std.fmt.comptimePrint(
                "{s} '{s}' contains invalid byte 0x{x}",
                .{ label, value, byte },
            ));
        }
    }
}

test "manifest capabilities default to no ambient authority" {
    const manifest = Manifest{ .name = "fixture", .version = "1.0.0" };
    try std.testing.expect(!manifest.capabilities.workspace_read);
    try std.testing.expect(!manifest.capabilities.workspace_write);
    try std.testing.expect(!manifest.capabilities.terminal);
    try std.testing.expect(!manifest.capabilities.network);
    try std.testing.expect(!manifest.capabilities.secrets);
    try std.testing.expect(!manifest.capabilities.clipboard);
}
