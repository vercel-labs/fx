const fx = @import("fx_mod");

fn hello(context: fx.NativeCommandContext, payload: []const u8) !void {
    _ = context;
    _ = payload;
}

const commands = [_]fx.NativeCommand{.{
    .name = "hello",
    .description = "Run a native fx mod command",
    .handler = hello,
}};

pub const manifest: fx.ModManifest = .{
    .name = "example.hello",
    .version = "1.0.0",
    .description = "Minimal native fx mod",
};

pub const contribution: fx.ModContribution = .{
    .commands = commands[0..],
};
