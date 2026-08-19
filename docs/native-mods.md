# Native Zig mods

fx exposes a compile-time mod API as the `fx_mod` Zig module. Native mods are ordinary Zig packages linked into a custom fx distribution. They are type checked with the application and add no runtime interpreter or dynamic-library ABI.

## Contract

A mod is a namespace with a manifest and contribution:

```zig
const fx = @import("fx_mod");

pub const manifest: fx.ModManifest = .{
    .name = "acme.deploy",
    .version = "1.0.0",
    .description = "Deployment tools",
    .capabilities = .{
        .workspace_read = true,
        .terminal = true,
        .network = true,
    },
};

pub const contribution: fx.ModContribution = .{
    .tools = tools[0..],
    .commands = commands[0..],
    .hooks = .{
        .post_turn_end = post_turn_end_hooks[0..],
    },
};
```

Tools use fx's existing `Tool` descriptor and therefore retain normal argument validation, permission admission, cancellation, result limits, and transcript behavior.

Native slash commands use the open command contract:

```zig
fn deploy(context: fx.NativeCommandContext, payload: []const u8) !void {
    _ = context;
    _ = payload;
}

const commands = [_]fx.NativeCommand{.{
    .name = "deploy",
    .description = "Deploy the current workspace",
    .handler = deploy,
}};
```

The built-in slash router remains a closed typed enum. A custom distribution should try its `NativeCommandRegistry` before delegating to the built-in command router.

## Composition

Compose mods at compile time:

```zig
const fx = @import("fx_mod");
const builtins = @import("fx_builtins");
const deploy = @import("deploy_mod");

const Distribution = fx.Catalog(.{ builtins, deploy });

pub const tool_set = Distribution.tool_set;
pub const command_registry = Distribution.command_registry;
```

`Catalog` validates the manifest contract and rejects duplicate tool or native-command names at compile time. It also aggregates the four current typed lifecycle hooks:

- `pre_tool_use`
- `stop`
- `post_turn_end`
- `attention_required`

Call `Distribution.registerHooks(&runtime)` before freezing the lifecycle runtime.

## State and ownership

A stateful mod declares `State`, `init`, and `deinit` together. The distribution owns initialization order and must deinitialize in reverse order. Allocators remain explicit, and data crossing erased tool or hook boundaries follows the ownership rules in those existing contracts.

Capability declarations document the ambient authority a compiled mod expects. They do not bypass fx's runtime permission system. Tool effects must continue to use the normal dispatch and capability paths.

## Runtime-installed extensions

Native mods deliberately require rebuilding the distribution. Runtime-installed portable extensions should use a separate byte-oriented WebAssembly ABI rather than Zig shared libraries. Zig does not promise a stable ABI for arbitrary Zig types across compiler versions and separately built dynamic libraries.
