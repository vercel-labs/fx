const mod_api = @import("mod_api.zig");
const builtin_mod = @import("builtins/mod.zig");

pub const mods = .{builtin_mod};
pub const Catalog = mod_api.Catalog(mods);

pub const tool_registry = Catalog.registry;
pub const tool_set = Catalog.tool_set;
pub const native_command_registry = Catalog.command_registry;
