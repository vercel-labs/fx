const std = @import("std");
const host_target = @import("../hosts/target.zig");
const lsp_client = @import("../lsp/client.zig");
const pathing = @import("../workspace/pathing.zig");
const permissions = @import("../permissions/permissions.zig");
const protocol = @import("../lsp/protocol.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const StartSpec = lsp_client.StartSpec;
pub const DiagnosticMark = lsp_client.DiagnosticMark;

pub const Registry = struct {
    alloc: Allocator = std.heap.page_allocator,
    clients: std.ArrayList(*lsp_client.Client) = .empty,

    pub fn init(alloc: Allocator) Registry {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Registry) void {
        var index = self.clients.items.len;
        while (index > 0) {
            index -= 1;
            self.clients.items[index].deinit();
        }
        self.clients.deinit(self.alloc);
        self.* = .{ .alloc = self.alloc };
    }

    pub fn start(self: *Registry, spec: StartSpec) !*lsp_client.Client {
        if (self.find(spec.name) != null) return error.AlreadyStarted;
        const client = try lsp_client.Client.start(self.alloc, spec);
        errdefer client.deinit();
        try self.clients.append(self.alloc, client);
        return client;
    }

    pub fn stop(self: *Registry, name: []const u8) bool {
        if (name.len == 0) {
            const had = self.clients.items.len > 0;
            self.deinit();
            self.* = .{ .alloc = self.alloc, .clients = .empty };
            return had;
        }
        for (self.clients.items, 0..) |client, index| {
            if (!std.mem.eql(u8, client.name, name)) continue;
            client.deinit();
            _ = self.clients.orderedRemove(index);
            return true;
        }
        return false;
    }

    pub fn find(self: *Registry, name: []const u8) ?*lsp_client.Client {
        for (self.clients.items) |client| {
            if (std.mem.eql(u8, client.name, name)) return client;
        }
        return null;
    }

    pub fn didOpen(self: *Registry, path: []const u8, text: []const u8) void {
        for (self.clients.items) |client| client.notifyDidOpen(path, text);
    }

    pub fn marksForPath(self: *Registry, alloc: Allocator, path: []const u8) ![]DiagnosticMark {
        var out: std.ArrayList(DiagnosticMark) = .empty;
        errdefer out.deinit(alloc);
        for (self.clients.items) |client| {
            const marks = try client.marksForPath(alloc, path);
            defer alloc.free(marks);
            try out.appendSlice(alloc, marks);
        }
        return out.toOwnedSlice(alloc);
    }

    pub fn countsForPath(self: *Registry, path: []const u8) struct { errors: usize, warnings: usize } {
        var errors: usize = 0;
        var warnings: usize = 0;
        for (self.clients.items) |client| {
            const counts = client.diagnosticCounts(path);
            errors += counts.errors;
            warnings += counts.warnings;
        }
        return .{ .errors = errors, .warnings = warnings };
    }

    pub fn definition(
        self: *Registry,
        path: []const u8,
        line: u32,
        character: u32,
    ) !?protocol.Location {
        for (self.clients.items) |client| {
            if (client.requestDefinition(self.alloc, path, line, character) catch null) |location| {
                return location;
            }
        }
        return null;
    }
};

pub fn spawnAllowed(
    mode: types.PermissionMode,
    grants: []const types.PermissionGrant,
    rules: types.PermissionRuleSet,
    alloc: Allocator,
    workspace_root: []const u8,
    command: []const u8,
) bool {
    if (comptime host_target.is_wasm) return false;
    if (mode == .yolo) return true;
    if (permissions.isToolAllowed(grants, "lsp", command) or
        permissions.isToolAllowed(grants, "lsp", "*"))
        return true;
    const decision = permissions.ruleDecisionFor(
        alloc,
        rules,
        workspace_root,
        "lsp",
        command,
        .none,
    ) catch return false;
    return switch (decision) {
        .allow => true,
        .deny => false,
        .none, .ask => mode == .auto,
    };
}

pub fn joinCommand(alloc: Allocator, argv: []const []const u8) ![]u8 {
    return std.mem.join(alloc, " ", argv);
}

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn start(app: *App, spec: StartSpec) !void {
            if (comptime !@hasField(App, "lsp")) return error.LspUnavailable;
            if (app.lsp.find(spec.name) != null) return;
            const command = try joinCommand(app.alloc, spec.argv);
            defer app.alloc.free(command);
            if (!spawnPermitted(app, command)) return error.PermissionDenied;
            _ = app.lsp.start(spec) catch |err| switch (err) {
                error.AlreadyStarted => return,
                else => return err,
            };
            const message = try std.fmt.allocPrint(
                app.alloc,
                "Started language server {s}.",
                .{spec.name},
            );
            defer app.alloc.free(message);
            try app.writeDomainNotice(.{
                .topic = "lua",
                .tone = .neutral,
                .body = message,
            }, true);
        }

        pub fn stop(app: *App, name: []const u8) !void {
            if (comptime !@hasField(App, "lsp")) return;
            if (!app.lsp.stop(name)) {
                if (name.len == 0) return;
                const message = try std.fmt.allocPrint(
                    app.alloc,
                    "Language server {s} is not running.",
                    .{name},
                );
                defer app.alloc.free(message);
                try app.writeDomainNotice(.{
                    .topic = "lua",
                    .tone = .neutral,
                    .body = message,
                }, true);
            }
        }

        pub fn didOpen(app: *App, path: []const u8, text: []const u8) void {
            if (comptime !@hasField(App, "lsp")) return;
            var arena_state = std.heap.ArenaAllocator.init(app.alloc);
            defer arena_state.deinit();
            const workspace = if (comptime @hasField(App, "workspace_root")) app.workspace_root else "";
            const resolved = pathing.resolveWorkspaceOrExternalPath(
                arena_state.allocator(),
                workspace,
                path,
            ) catch path;
            app.lsp.didOpen(resolved, text);
        }

        fn spawnPermitted(app: *App, command: []const u8) bool {
            if (comptime !@hasField(App, "permission_engine")) return false;
            const workspace = if (comptime @hasField(App, "workspace_root")) app.workspace_root else "";
            return spawnAllowed(
                app.permission_engine.mode,
                app.permission_engine.grants.items,
                app.permission_engine.rules,
                app.alloc,
                workspace,
                command,
            );
        }
    };
}

test "spawnAllowed honors yolo auto ask and configured deny" {
    const alloc = std.testing.allocator;
    try std.testing.expect(spawnAllowed(.yolo, &.{}, .{}, alloc, "/tmp", "zls"));
    try std.testing.expect(spawnAllowed(.auto, &.{}, .{}, alloc, "/tmp", "zls"));
    try std.testing.expect(!spawnAllowed(.ask, &.{}, .{}, alloc, "/tmp", "zls"));

    var grants: std.ArrayList(types.PermissionGrant) = .empty;
    defer {
        permissions.clearAllowedTools(alloc, &grants);
        grants.deinit(alloc);
    }
    try permissions.allowToolForSession(alloc, &grants, "lsp", "zls");
    try std.testing.expect(spawnAllowed(.ask, grants.items, .{}, alloc, "/tmp", "zls"));
}
