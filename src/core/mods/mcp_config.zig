const std = @import("std");
const manifest = @import("manifest.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const project_config = @import("../mcp/project_config.zig");
const mod_program = @import("../shared/mod_program.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;
const McpServerConfig = mcp_contract.McpServerConfig;

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
