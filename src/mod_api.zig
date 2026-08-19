pub const manifest = @import("core/mods/manifest.zig");
pub const command = @import("core/mods/command.zig");
pub const catalog = @import("core/mods/catalog.zig");
pub const hooks = @import("core/hooks/hooks.zig");
pub const tooling = @import("core/tooling/tool_dispatch.zig");

pub const api_version = manifest.current_api_version;
pub const Capabilities = manifest.Capabilities;
pub const ModManifest = manifest.Manifest;
pub const ModContribution = catalog.Contribution;
pub const HookRegistration = catalog.HookRegistration;
pub const InitContext = catalog.InitContext;
pub const NativeCommand = command.Command;
pub const NativeCommandContext = command.Context;
pub const NativeCommandRegistry = command.Registry;
pub const Tool = tooling.Tool;
pub const ToolResult = tooling.ToolResult;
pub const ToolInput = tooling.ToolInput;
pub const ToolContext = tooling.DispatchContext;

pub const Catalog = catalog.Catalog;
pub const validateMod = catalog.validateMod;
