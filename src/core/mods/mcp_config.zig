const std = @import("std");
const manifest = @import("manifest.zig");
const mod_pins = @import("mod_pins.zig");
const store = @import("store.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const project_config = @import("../mcp/project_config.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const mod_program = @import("../shared/mod_program.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;
pub const McpServerConfig = mcp_contract.McpServerConfig;
pub const McpAuthConfig = mcp_contract.McpAuthConfig;

pub const ModMcpClash = struct {
    server: []u8,
    mods: [][]u8,

    pub fn deinit(self: *ModMcpClash, alloc: Allocator) void {
        alloc.free(self.server);
        for (self.mods) |m| alloc.free(m);
        alloc.free(self.mods);
        self.* = undefined;
    }
};

pub const LoadedModServers = struct {
    configs: std.ArrayList(McpServerConfig) = .empty,
    clashes: []ModMcpClash = &.{},

    pub fn deinit(self: *LoadedModServers, alloc: Allocator) void {
        deinitConfigs(alloc, &self.configs);
        for (self.clashes) |*clash| clash.deinit(alloc);
        if (self.clashes.len > 0) alloc.free(self.clashes);
        self.* = .{};
    }
};

pub const ModSource = struct {
    name: []const u8,
    dir: []const u8,
};

pub const Failure = struct {
    server: []const u8,
    reason: []const u8,

    pub fn deinit(self: *Failure, alloc: Allocator) void {
        alloc.free(self.server);
        alloc.free(self.reason);
        self.* = undefined;
    }
};

pub const ParseResult = union(enum) {
    ok: std.ArrayList(McpServerConfig),
    invalid: Failure,
};

pub fn deinitConfigs(alloc: Allocator, configs: *std.ArrayList(McpServerConfig)) void {
    project_config.deinitConfigs(alloc, configs);
}

/// The stdio command as the mod wrote it. `parse` resolves a command under the
/// mod folder and records that folder as `cwd`, so a command inside it comes back
/// relative to the folder. Any other command is returned unchanged.
pub fn writtenCommand(config: *const McpServerConfig) ?[]const u8 {
    const command = config.command orelse return null;
    const dir = std.mem.trimEnd(u8, config.cwd orelse return command, "/");
    if (command.len <= dir.len + 1 or command[dir.len] != '/') return command;
    if (!std.mem.eql(u8, command[0..dir.len], dir)) return command;
    return command[dir.len + 1 ..];
}

/// The names of the person's environment variables that fx reads for a mod
/// server, each once and in order: `${NAME}` and `${NAME:-default}` in its
/// command, arguments, env values, and header values, then each header
/// environment name, the bearer token name, and the OAuth client secret name.
/// An env key is not one of them: it names a variable the mod sets for its
/// server. Every name borrows from `config`.
pub fn variableNames(alloc: Allocator, config: *const McpServerConfig) Allocator.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    if (writtenCommand(config)) |command| try templateNames(alloc, &names, command);
    for (config.args) |argument| try templateNames(alloc, &names, argument);
    for (config.env) |entry| try templateNames(alloc, &names, entry.value);
    for (config.headers) |header| try templateNames(alloc, &names, header.value);
    for (config.header_env) |header| try addName(alloc, &names, header.env);
    if (config.bearer_token_env) |name| try addName(alloc, &names, name);
    if (config.auth) |auth| if (auth.client_secret_env) |name| try addName(alloc, &names, name);
    return names.items;
}

/// Reads the names of `${...}` expressions the way `project_config`'s template
/// check does: a `$${` is an escape, and `:-` ends the name.
fn templateNames(alloc: Allocator, names: *std.ArrayList([]const u8), input: []const u8) Allocator.Error!void {
    var cursor: usize = 0;
    while (cursor < input.len) {
        const relative_start = std.mem.find(u8, input[cursor..], "${") orelse return;
        const start = cursor + relative_start;
        if (start > cursor and input[start - 1] == '$') {
            cursor = start + 2;
            continue;
        }
        const expression_start = start + 2;
        const relative_end = std.mem.findScalar(u8, input[expression_start..], '}') orelse return;
        const expression = input[expression_start .. expression_start + relative_end];
        const name = if (std.mem.find(u8, expression, ":-")) |marker| expression[0..marker] else expression;
        try addName(alloc, names, name);
        cursor = expression_start + relative_end + 1;
    }
}

fn addName(alloc: Allocator, names: *std.ArrayList([]const u8), name: []const u8) Allocator.Error!void {
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try names.append(alloc, name);
}

/// Strictly parses a mod's `"mcp"` map using `project_config.parseProfileServerMap`
/// (`source = .mod`, `allow_stored_credentials = true`, `allow_authorization_header = false`,
/// `force_optional = false`), resolving relative stdio programs and `cwd` under
/// `mod_source.dir`. Any skipped or invalid entry fails the whole parse with the
/// offending server name and reason owned by `alloc`.
pub fn parse(alloc: Allocator, mcp_val: std.json.Value, mod_source: ModSource) !ParseResult {
    if (mcp_val != .object) {
        return .{ .invalid = .{
            .server = try alloc.dupe(u8, ""),
            .reason = try alloc.dupe(u8, "must hold one JSON object"),
        } };
    }
    if (mcp_val.object.count() > manifest.max_mods) {
        return .{ .invalid = .{
            .server = try alloc.dupe(u8, ""),
            .reason = try alloc.print("must have at most {d} entries", .{manifest.max_mods}),
        } };
    }

    var skipped: std.ArrayList(project_config.WorkspaceDiagnostic) = .empty;
    defer {
        for (skipped.items) |*diag| diag.deinit(alloc);
        skipped.deinit(alloc);
    }

    var configs = try project_config.parseProfileServerMap(alloc, mcp_val, .{
        .source = .mod,
        .scope = .profile,
        .allow_stored_credentials = true,
        .allow_authorization_header = false,
        .force_optional = false,
    }, &skipped);
    errdefer deinitConfigs(alloc, &configs);

    if (skipped.items.len > 0) {
        const first = skipped.items[0];
        const server = try alloc.dupe(u8, first.server_name orelse "");
        errdefer alloc.free(server);
        const reason = try alloc.dupe(u8, project_config.entryProblemWords(first.problem orelse .other));
        deinitConfigs(alloc, &configs);
        return .{ .invalid = .{ .server = server, .reason = reason } };
    }

    for (configs.items) |*cfg| {
        if (cfg.name.len == 0) {
            const server = try alloc.dupe(u8, "");
            errdefer alloc.free(server);
            const reason = try alloc.dupe(u8, "its name cannot be empty");
            deinitConfigs(alloc, &configs);
            return .{ .invalid = .{ .server = server, .reason = reason } };
        }
        if (!text_utils.isTerminalSafe(cfg.name)) {
            const server = try alloc.dupe(u8, cfg.name);
            errdefer alloc.free(server);
            const reason = try alloc.dupe(u8, project_config.entryProblemWords(.name));
            deinitConfigs(alloc, &configs);
            return .{ .invalid = .{ .server = server, .reason = reason } };
        }
        if (!project_config.hasValidEnvTemplates(cfg)) {
            const server = try alloc.dupe(u8, cfg.name);
            errdefer alloc.free(server);
            const reason = try alloc.dupe(u8, project_config.entryProblemWords(.variable));
            deinitConfigs(alloc, &configs);
            return .{ .invalid = .{ .server = server, .reason = reason } };
        }
        if (cfg.transport == .stdio) {
            const raw_cmd = cfg.command orelse {
                const server = try alloc.dupe(u8, cfg.name);
                errdefer alloc.free(server);
                const reason = try alloc.dupe(u8, project_config.entryProblemWords(.command));
                deinitConfigs(alloc, &configs);
                return .{ .invalid = .{ .server = server, .reason = reason } };
            };
            const resolved_cmd = mod_program.resolve(alloc, raw_cmd, mod_source.dir) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidProgram => {
                    const server = try alloc.dupe(u8, cfg.name);
                    errdefer alloc.free(server);
                    const reason = try alloc.dupe(u8, "its \"command\" must stay inside the mod");
                    deinitConfigs(alloc, &configs);
                    return .{ .invalid = .{ .server = server, .reason = reason } };
                },
                error.PathTooLong => {
                    const server = try alloc.dupe(u8, cfg.name);
                    errdefer alloc.free(server);
                    const reason = try alloc.dupe(u8, "its \"command\" is too long");
                    deinitConfigs(alloc, &configs);
                    return .{ .invalid = .{ .server = server, .reason = reason } };
                },
            };
            alloc.free(raw_cmd);
            cfg.command = resolved_cmd;
            cfg.cwd = try alloc.dupe(u8, mod_source.dir);
        }
        cfg.mod_name = try alloc.dupe(u8, mod_source.name);
    }

    return .{ .ok = configs };
}

/// Loads enabled mods' `"mcp"` servers in `pinned` mod-name order, resolving
/// stdio commands and `cwd` against each mod's pinned version path. Servers
/// shadowed by `profile_configs` are skipped without a clash, and any name
/// defined by two or more enabled mods loads from neither and is returned in
/// `clashes`. Broken mods trace to `debug_trace` only.
pub fn loadFromPinned(
    alloc: Allocator,
    io: std.Io,
    pinned: *const mod_pins.ModPins,
    profile_configs: []const McpServerConfig,
) error{OutOfMemory}!LoadedModServers {
    for (pinned.problems) |problem| {
        debug_trace.logf("mcp", "mod MCP pin problem reason={s}", .{problem});
    }

    var candidates: std.ArrayList(McpServerConfig) = .empty;
    var ownership_transferred = false;
    errdefer if (!ownership_transferred) deinitConfigs(alloc, &candidates);

    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();

    for (pinned.pins) |pin_entry| {
        _ = scratch_state.reset(.retain_capacity);
        const scratch = scratch_state.allocator();

        const read_res = try store.readManifestAt(scratch, std.Io.Dir.cwd(), io, pin_entry.path, pin_entry.name);
        const decoded = switch (read_res) {
            .ok => |m| m,
            .problem => |p| {
                debug_trace.logf("mcp", "mod MCP manifest skipped mod={s} problem={s}", .{ pin_entry.name, @tagName(p) });
                continue;
            },
        };
        const mcp_val = decoded.mcp orelse continue;

        const parsed = parse(alloc, mcp_val, .{ .name = pin_entry.name, .dir = pin_entry.path }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                debug_trace.logf("mcp", "mod MCP parse skipped mod={s} err={s}", .{ pin_entry.name, @errorName(err) });
                continue;
            },
        };
        switch (parsed) {
            .ok => |list| {
                var mut = list;
                defer mut.deinit(alloc);
                errdefer for (mut.items) |*item| item.deinit(alloc);
                try candidates.appendSlice(alloc, mut.items);
                mut.clearRetainingCapacity();
            },
            .invalid => |bad| {
                var mut_bad = bad;
                defer mut_bad.deinit(alloc);
                debug_trace.logf("mcp", "mod MCP entry skipped mod={s} server={s} reason={s}", .{ pin_entry.name, mut_bad.server, mut_bad.reason });
            },
        }
    }

    const items = candidates.items;
    const keep = try alloc.alloc(bool, items.len);
    defer alloc.free(keep);
    @memset(keep, false);

    var clashes: std.ArrayList(ModMcpClash) = .empty;
    errdefer {
        for (clashes.items) |*clash| clash.deinit(alloc);
        clashes.deinit(alloc);
    }

    // Pass 1 only decides keep/drop and records clashes without freeing or
    // moving any candidate, so earlier entries stay valid for later compares
    // and any OOM leaves `candidates` intact for `errdefer`.
    var kept_count: usize = 0;
    for (items, 0..) |cand, idx| {
        const name = cand.name;
        if (project_config.configNamePresent(profile_configs, name)) continue;
        var seen_earlier = false;
        for (items[0..idx]) |earlier| {
            if (std.mem.eql(u8, earlier.name, name)) {
                seen_earlier = true;
                break;
            }
        }
        if (seen_earlier) continue;

        var clash_count: usize = 1;
        for (items[idx + 1 ..]) |later| {
            if (std.mem.eql(u8, later.name, name)) clash_count += 1;
        }
        if (clash_count > 1) {
            var mods_list: std.ArrayList([]u8) = .empty;
            errdefer {
                for (mods_list.items) |m| alloc.free(m);
                mods_list.deinit(alloc);
            }
            for (items[idx..]) |entry| {
                if (!std.mem.eql(u8, entry.name, name)) continue;
                const mod_name = entry.mod_name orelse continue;
                var already = false;
                for (mods_list.items) |prev| if (std.mem.eql(u8, prev, mod_name)) {
                    already = true;
                    break;
                };
                if (!already) {
                    const duped = try alloc.dupe(u8, mod_name);
                    errdefer alloc.free(duped);
                    try mods_list.append(alloc, duped);
                }
            }
            const clash_server = try alloc.dupe(u8, name);
            errdefer alloc.free(clash_server);
            const clash_mods = try mods_list.toOwnedSlice(alloc);
            errdefer {
                for (clash_mods) |m| alloc.free(m);
                alloc.free(clash_mods);
            }
            try clashes.append(alloc, .{ .server = clash_server, .mods = clash_mods });
            continue;
        }

        keep[idx] = true;
        kept_count += 1;
    }

    var kept: std.ArrayList(McpServerConfig) = .empty;
    errdefer deinitConfigs(alloc, &kept);
    try kept.ensureTotalCapacity(alloc, kept_count);
    const clashes_slice = try clashes.toOwnedSlice(alloc);

    // Pass 2 cannot fail: move kept entries and free dropped ones.
    ownership_transferred = true;
    for (items, 0..) |*cand, idx| {
        if (keep[idx]) {
            kept.appendAssumeCapacity(cand.*);
        } else {
            cand.deinit(alloc);
        }
    }
    candidates.deinit(alloc);

    return .{
        .configs = kept,
        .clashes = clashes_slice,
    };
}

test "variableNames lists each name a mod server reads once, and writtenCommand keeps the command as written" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mod_dir = "/tmp/fx-home/mods/.store/glm-0123456789abcdef";
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{
        \\  "glm":{"command":"bin/glm","args":["--token","${GLM_TOKEN:-none}"],"env":{"TEAM":"${GLM_TEAM}"}},
        \\  "remote":{"type":"http","url":"https://mcp.example.com/mcp","headers":{"X-Key":"${GLM_TOKEN}"},"header_env":{"X-Team":"GLM_TEAM"},"bearer_token_env":"MCP_TOKEN"},
        \\  "signin":{"type":"http","url":"https://auth.example.com/mcp","oauth":{"client_id":"fx-mod","client_secret_env":"MCP_CLIENT_SECRET"}}
        \\}
    , .{ .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();

    var configs = switch (try parse(alloc, parsed.value, .{ .name = "glm", .dir = mod_dir })) {
        .ok => |c| c,
        .invalid => return error.TestUnexpectedResult,
    };
    defer deinitConfigs(alloc, &configs);

    const Find = struct {
        fn byName(items: []const McpServerConfig, name: []const u8) !*const McpServerConfig {
            for (items) |*item| if (std.mem.eql(u8, item.name, name)) return item;
            return error.TestUnexpectedResult;
        }
    };
    const glm = try Find.byName(configs.items, "glm");
    const remote = try Find.byName(configs.items, "remote");
    const signin = try Find.byName(configs.items, "signin");
    try std.testing.expectEqualStrings("bin/glm", writtenCommand(glm).?);
    try std.testing.expect(writtenCommand(remote) == null);

    // `TEAM` is the env key the mod sets, so only the variable its value reads counts.
    const glm_names = try variableNames(arena, glm);
    try std.testing.expectEqual(@as(usize, 2), glm_names.len);
    try std.testing.expectEqualStrings("GLM_TOKEN", glm_names[0]);
    try std.testing.expectEqualStrings("GLM_TEAM", glm_names[1]);

    const remote_names = try variableNames(arena, remote);
    try std.testing.expectEqual(@as(usize, 3), remote_names.len);
    try std.testing.expectEqualStrings("GLM_TOKEN", remote_names[0]);
    try std.testing.expectEqualStrings("GLM_TEAM", remote_names[1]);
    try std.testing.expectEqualStrings("MCP_TOKEN", remote_names[2]);

    // fx reads the OAuth client secret from the person's environment and sends it.
    const signin_names = try variableNames(arena, signin);
    try std.testing.expectEqual(@as(usize, 1), signin_names.len);
    try std.testing.expectEqualStrings("MCP_CLIENT_SECRET", signin_names[0]);
}

test "parse accepts valid stdio and http mod servers, resolves relative command, and sets cwd and mod_name" {
    const alloc = std.testing.allocator;
    const mod_dir = "/tmp/fx-home/mods/.store/alpha-0123456789abcdef";
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{
        \\  "fs":{"command":"bin/fs","args":["--stdio"]},
        \\  "web":{"type":"http","url":"https://example.com/mcp","bearer_token_env":"TOK"}
        \\}
    , .{ .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();

    const res = try parse(alloc, parsed.value, .{ .name = "alpha", .dir = mod_dir });
    var configs = switch (res) {
        .ok => |c| c,
        .invalid => return error.TestUnexpectedResult,
    };
    defer deinitConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 2), configs.items.len);
    const fs = configs.items[0];
    try std.testing.expectEqual(mcp_contract.ConfigSource.mod, fs.source);
    try std.testing.expectEqualStrings("alpha", fs.mod_name.?);
    try std.testing.expectEqualStrings("/tmp/fx-home/mods/.store/alpha-0123456789abcdef/bin/fs", fs.command.?);
    try std.testing.expectEqualStrings(mod_dir, fs.cwd.?);
    try std.testing.expect(!fs.allow_stored_credentials);

    const web = configs.items[1];
    try std.testing.expectEqual(mcp_contract.ConfigSource.mod, web.source);
    try std.testing.expectEqualStrings("alpha", web.mod_name.?);
    try std.testing.expect(web.cwd == null);
    try std.testing.expect(web.allow_stored_credentials);
}

test "parse strictly refuses Authorization headers, .. escapes, unprintable names, and invalid env templates" {
    const alloc = std.testing.allocator;
    const mod_dir = "/tmp/fx-home/mods/alpha";

    const cases = [_]struct {
        json: []const u8,
        server: []const u8,
        needle: []const u8,
    }{
        .{
            .json = "{\"authd\":{\"type\":\"http\",\"url\":\"https://example.com/mcp\",\"headers\":{\"Authorization\":\"Bearer x\"}}}",
            .server = "authd",
            .needle = "Authorization header",
        },
        .{
            .json = "{\"esc\":{\"command\":\"../outside\"}}",
            .server = "esc",
            .needle = "must stay inside the mod",
        },
        .{
            .json = "{\"bad\\u001b\":{\"command\":\"node\"}}",
            .server = "bad\x1b",
            .needle = "won't print",
        },
        .{
            .json = "{\"tpl\":{\"command\":\"node\",\"args\":[\"${BAD-NAME}\"]}}",
            .server = "tpl",
            .needle = "${...}",
        },
        .{
            .json = "{\"plain\":{\"type\":\"http\",\"url\":\"http://example.com/mcp\"}}",
            .server = "plain",
            .needle = "https",
        },
    };
    for (cases) |c| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, c.json, .{ .duplicate_field_behavior = .@"error" });
        defer parsed.deinit();
        const res = try parse(alloc, parsed.value, .{ .name = "alpha", .dir = mod_dir });
        switch (res) {
            .ok => |configs| {
                var mut = configs;
                deinitConfigs(alloc, &mut);
                return error.TestUnexpectedResult;
            },
            .invalid => |bad| {
                var mut_bad = bad;
                defer mut_bad.deinit(alloc);
                try std.testing.expectEqualStrings(c.server, bad.server);
                try std.testing.expect(std.mem.find(u8, bad.reason, c.needle) != null);
            },
        }
    }
}

test "loadFromPinned survives allocation failures across profile shadows, clashes, and kept servers" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "alpha");
    try tmp.dir.createDirPath(io, "beta");
    try tmp.dir.writeFile(io, .{
        .sub_path = "alpha/mod.json",
        .data = "{\"name\":\"alpha\",\"version\":\"1.0.0\",\"mcp\":{\"prof\":{\"command\":\"bin/p\"},\"clash\":{\"command\":\"bin/ca\"},\"kept\":{\"command\":\"bin/k\"}}}",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "beta/mod.json",
        .data = "{\"name\":\"beta\",\"version\":\"1.0.0\",\"mcp\":{\"clash\":{\"command\":\"bin/cb\"}}}",
    });

    const alpha_dir = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "alpha");
    defer std.testing.allocator.free(alpha_dir);
    const beta_dir = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "beta");
    defer std.testing.allocator.free(beta_dir);

    const alpha_name = try std.testing.allocator.dupe(u8, "alpha");
    defer std.testing.allocator.free(alpha_name);
    const beta_name = try std.testing.allocator.dupe(u8, "beta");
    defer std.testing.allocator.free(beta_name);

    const pin_items = [_]@import("pins.zig").Pin{
        .{ .name = alpha_name, .token = @splat('0'), .path = alpha_dir, .file = undefined },
        .{ .name = beta_name, .token = @splat('1'), .path = beta_dir, .file = undefined },
    };
    const pinned: mod_pins.ModPins = .{ .io = io, .pins = @constCast(&pin_items) };
    const profile = [_]McpServerConfig{.{ .name = "prof", .command = "profile-prof" }};

    const Body = struct {
        io: std.Io,
        pinned: *const mod_pins.ModPins,
        profile: []const McpServerConfig,

        fn run(alloc: Allocator, self: @This()) !void {
            var loaded = try loadFromPinned(alloc, self.io, self.pinned, self.profile);
            defer loaded.deinit(alloc);
            try std.testing.expectEqual(@as(usize, 1), loaded.configs.items.len);
            try std.testing.expectEqualStrings("kept", loaded.configs.items[0].name);
            try std.testing.expectEqual(@as(usize, 1), loaded.clashes.len);
            try std.testing.expectEqualStrings("clash", loaded.clashes[0].server);
        }
    };
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        Body.run,
        .{Body{ .io = io, .pinned = &pinned, .profile = &profile }},
    );
}
