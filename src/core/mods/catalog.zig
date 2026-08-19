const std = @import("std");
const hooks = @import("../hooks/hooks.zig");
const command = @import("command.zig");
const manifest_mod = @import("manifest.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");

pub const HookRegistration = struct {
    pre_tool_use: []const hooks.PreToolUseHandler = &.{},
    stop: []const hooks.StopHandler = &.{},
    post_turn_end: []const hooks.PostTurnEndHandler = &.{},
    attention_required: []const hooks.AttentionRequiredHandler = &.{},
};

pub const Contribution = struct {
    tools: []const tool_dispatch.Tool = &.{},
    advertised_tool_names: []const []const u8 = &.{},
    read_only_tool_names: []const []const u8 = &.{},
    commands: []const command.Command = &.{},
    hooks: HookRegistration = .{},
};

pub const InitContext = struct {
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
};

pub fn validateMod(comptime Mod: type) void {
    if (!@hasDecl(Mod, "manifest")) {
        @compileError("fx mod must declare `pub const manifest: fx.ModManifest`");
    }
    if (@TypeOf(Mod.manifest) != manifest_mod.Manifest) {
        @compileError("fx mod `manifest` must have type fx.ModManifest");
    }
    manifest_mod.validate(Mod.manifest);

    if (!@hasDecl(Mod, "contribution")) {
        @compileError("fx mod must declare `pub const contribution: fx.ModContribution`");
    }
    if (@TypeOf(Mod.contribution) != Contribution) {
        @compileError("fx mod `contribution` must have type fx.ModContribution");
    }

    if (@hasDecl(Mod, "State") != @hasDecl(Mod, "init")) {
        @compileError("stateful fx mods must declare both `State` and `init`");
    }
    if (@hasDecl(Mod, "State") != @hasDecl(Mod, "deinit")) {
        @compileError("stateful fx mods must declare `State`, `init`, and `deinit`");
    }
    if (@hasDecl(Mod, "State")) {
        const init_info = @typeInfo(@TypeOf(Mod.init)).@"fn";
        if (init_info.params.len != 1 or init_info.params[0].type == null or
            init_info.params[0].type.? != InitContext or init_info.return_type == null)
        {
            @compileError("fx mod `init` must accept one fx.InitContext parameter and return its State (optionally through an error union)");
        }
        const init_return = init_info.return_type.?;
        const init_payload = switch (@typeInfo(init_return)) {
            .error_union => |error_union| error_union.payload,
            else => init_return,
        };
        if (init_payload != Mod.State) {
            @compileError("fx mod `init` must return its State or an error union containing its State");
        }
        const deinit_info = @typeInfo(@TypeOf(Mod.deinit)).@"fn";
        if (deinit_info.params.len != 1 or deinit_info.params[0].type == null or
            deinit_info.params[0].type.? != *Mod.State or deinit_info.return_type == null or
            deinit_info.return_type.? != void)
        {
            @compileError("fx mod `deinit` must have signature fn (*State) void");
        }
    }
}

pub fn Catalog(comptime Mods: anytype) type {
    comptime {
        for (Mods) |Mod| validateMod(Mod);
        validateUniqueNames(Mods);
        validateContributions(Mods);
    }

    return struct {
        pub const mods = Mods;
        pub const tool_count = totalTools(Mods);
        pub const advertised_tool_count = totalAdvertisedTools(Mods);
        pub const read_only_tool_count = totalReadOnlyTools(Mods);
        pub const command_count = totalCommands(Mods);

        pub const tools = collectTools(Mods, tool_count);
        pub const advertised_tool_names = collectNames(Mods, "advertised_tool_names", advertised_tool_count);
        pub const read_only_tool_names = collectNames(Mods, "read_only_tool_names", read_only_tool_count);
        pub const commands = collectCommands(Mods, command_count);

        pub const registry = tool_dispatch.Registry{ .tools = tools[0..] };
        pub const tool_set = tool_set_contract.ToolSet{
            .registry = registry,
            .order = advertised_tool_names[0..],
            .read_only_tool_names = read_only_tool_names[0..],
        };
        pub const command_registry = command.Registry{ .commands = commands[0..] };

        pub fn registerHooks(runtime: *hooks.Runtime) !void {
            inline for (Mods) |Mod| {
                inline for (Mod.contribution.hooks.pre_tool_use) |handler| try runtime.registerPreToolUse(handler);
                inline for (Mod.contribution.hooks.stop) |handler| try runtime.registerStop(handler);
                inline for (Mod.contribution.hooks.post_turn_end) |handler| try runtime.registerPostTurnEnd(handler);
                inline for (Mod.contribution.hooks.attention_required) |handler| try runtime.registerAttentionRequired(handler);
            }
        }

        pub fn States() type {
            return StateTuple(Mods);
        }

        pub fn init(init_context: InitContext) !States() {
            var states: States() = undefined;
            var initialized: usize = 0;
            errdefer deinitPrefix(&states, initialized);
            inline for (Mods, 0..) |Mod, index| {
                if (@hasDecl(Mod, "State")) {
                    states[index] = try initOne(Mod, init_context);
                } else {
                    states[index] = {};
                }
                initialized = index + 1;
            }
            return states;
        }

        pub fn deinit(states: *States()) void {
            deinitPrefix(states, Mods.len);
        }

        fn deinitPrefix(states: *States(), count: usize) void {
            inline for (Mods, 0..) |Mod, index| {
                if (@hasDecl(Mod, "State")) {
                    if (index < count) Mod.deinit(&states[index]);
                }
            }
        }
    };
}

fn initOne(comptime Mod: type, init_context: InitContext) !Mod.State {
    const result = Mod.init(init_context);
    return switch (@typeInfo(@TypeOf(result))) {
        .error_union => try result,
        else => result,
    };
}

fn StateTuple(comptime Mods: anytype) type {
    var fields: [Mods.len]type = undefined;
    inline for (Mods, 0..) |Mod, index| {
        fields[index] = if (@hasDecl(Mod, "State")) Mod.State else void;
    }
    return std.meta.Tuple(&fields);
}

fn totalTools(comptime Mods: anytype) usize {
    var count: usize = 0;
    inline for (Mods) |Mod| count += Mod.contribution.tools.len;
    return count;
}

fn totalAdvertisedTools(comptime Mods: anytype) usize {
    var count: usize = 0;
    inline for (Mods) |Mod| count += Mod.contribution.advertised_tool_names.len;
    return count;
}

fn totalReadOnlyTools(comptime Mods: anytype) usize {
    var count: usize = 0;
    inline for (Mods) |Mod| count += Mod.contribution.read_only_tool_names.len;
    return count;
}

fn totalCommands(comptime Mods: anytype) usize {
    var count: usize = 0;
    inline for (Mods) |Mod| count += Mod.contribution.commands.len;
    return count;
}

fn collectTools(comptime Mods: anytype, comptime count: usize) [count]tool_dispatch.Tool {
    var result: [count]tool_dispatch.Tool = undefined;
    var index: usize = 0;
    inline for (Mods) |Mod| {
        inline for (Mod.contribution.tools) |tool| {
            result[index] = tool;
            index += 1;
        }
    }
    return result;
}

fn collectCommands(comptime Mods: anytype, comptime count: usize) [count]command.Command {
    var result: [count]command.Command = undefined;
    var index: usize = 0;
    inline for (Mods) |Mod| {
        inline for (Mod.contribution.commands) |entry| {
            result[index] = entry;
            index += 1;
        }
    }
    return result;
}

fn collectNames(comptime Mods: anytype, comptime field_name: []const u8, comptime count: usize) [count][]const u8 {
    var result: [count][]const u8 = undefined;
    var index: usize = 0;
    inline for (Mods) |Mod| {
        const values = @field(Mod.contribution, field_name);
        inline for (values) |value| {
            result[index] = value;
            index += 1;
        }
    }
    return result;
}

fn validateContributions(comptime Mods: anytype) void {
    inline for (Mods) |Mod| {
        inline for (Mod.contribution.advertised_tool_names) |name| {
            if (!contributionHasTool(Mod.contribution, name)) {
                @compileError(std.fmt.comptimePrint(
                    "fx mod '{s}' advertises unknown tool '{s}'",
                    .{ Mod.manifest.name, name },
                ));
            }
        }
        inline for (Mod.contribution.read_only_tool_names) |name| {
            if (!contributionHasTool(Mod.contribution, name)) {
                @compileError(std.fmt.comptimePrint(
                    "fx mod '{s}' marks unknown tool '{s}' read-only",
                    .{ Mod.manifest.name, name },
                ));
            }
        }
    }
}

fn contributionHasTool(comptime contribution: Contribution, comptime name: []const u8) bool {
    inline for (contribution.tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return true;
    }
    return false;
}

fn validateUniqueNames(comptime Mods: anytype) void {
    @setEvalBranchQuota(20000);
    inline for (Mods, 0..) |Left, left_mod_index| {
        inline for (Left.contribution.tools, 0..) |left, left_index| {
            inline for (Mods, 0..) |Right, right_mod_index| {
                inline for (Right.contribution.tools, 0..) |right, right_index| {
                    if (right_mod_index < left_mod_index or
                        (right_mod_index == left_mod_index and right_index <= left_index)) continue;
                    if (std.mem.eql(u8, left.name, right.name)) {
                        @compileError(std.fmt.comptimePrint(
                            "duplicate fx tool name '{s}' in mods '{s}' and '{s}'",
                            .{ left.name, Left.manifest.name, Right.manifest.name },
                        ));
                    }
                }
            }
        }
        inline for (Left.contribution.commands, 0..) |left, left_index| {
            inline for (Mods, 0..) |Right, right_mod_index| {
                inline for (Right.contribution.commands, 0..) |right, right_index| {
                    if (right_mod_index < left_mod_index or
                        (right_mod_index == left_mod_index and right_index <= left_index)) continue;
                    if (std.mem.eql(u8, left.name, right.name)) {
                        @compileError(std.fmt.comptimePrint(
                            "duplicate fx command name '{s}' in mods '{s}' and '{s}'",
                            .{ left.name, Left.manifest.name, Right.manifest.name },
                        ));
                    }
                }
            }
        }
    }
}

const EmptyMod = struct {
    pub const manifest: manifest_mod.Manifest = .{ .name = "empty", .version = "1.0.0" };
    pub const contribution: Contribution = .{};
};

const CommandMod = struct {
    fn run(_: command.Context, _: []const u8) !void {}

    const commands = [_]command.Command{.{
        .name = "fixture",
        .description = "Fixture command",
        .handler = run,
    }};

    pub const manifest: manifest_mod.Manifest = .{ .name = "commands", .version = "1.0.0" };
    pub const contribution: Contribution = .{ .commands = &commands };
};

const StatefulMod = struct {
    pub const State = struct { initialized: bool };

    pub fn init(_: InitContext) !State {
        return .{ .initialized = true };
    }

    pub fn deinit(state: *State) void {
        state.initialized = false;
    }

    pub const manifest: manifest_mod.Manifest = .{ .name = "stateful", .version = "1.0.0" };
    pub const contribution: Contribution = .{};
};

test "catalog composes native mod commands at comptime" {
    const TestCatalog = Catalog(.{ EmptyMod, CommandMod });
    try std.testing.expectEqual(@as(usize, 1), TestCatalog.command_count);
    try std.testing.expectEqualStrings("fixture", TestCatalog.commands[0].name);
    try std.testing.expectEqual(@as(usize, 0), TestCatalog.tool_count);
}

test "catalog initializes and deinitializes stateful mods" {
    const TestCatalog = Catalog(.{ EmptyMod, StatefulMod });
    var states = try TestCatalog.init(.{
        .allocator = std.testing.allocator,
        .workspace_root = "/tmp/workspace",
    });
    try std.testing.expect(states[1].initialized);
    TestCatalog.deinit(&states);
    try std.testing.expect(!states[1].initialized);
}
