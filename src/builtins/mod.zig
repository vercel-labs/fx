const builtin_tools = @import("tools.zig");
const mod_api = @import("../mod_api.zig");

pub const manifest: mod_api.ModManifest = .{
    .name = "fx.builtins",
    .version = "1.0.0",
    .description = "First-party fx capabilities",
    .capabilities = .{
        .workspace_read = true,
        .workspace_write = true,
        .terminal = true,
        .network = true,
        .secrets = true,
        .clipboard = true,
    },
};

pub const contribution: mod_api.ModContribution = .{
    .tools = builtin_tools.all[0..],
    .advertised_tool_names = builtin_tools.advertisement_order[0..],
    .read_only_tool_names = builtin_tools.read_only_tool_names[0..],
};
