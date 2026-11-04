const std = @import("std");
const io_mod = @import("../shared/io.zig");
const mcp_contract = @import("mcp_contract.zig");
const project_config = @import("project_config.zig");

const max_config_bytes: usize = 1024 * 1024;

/// The workspace's `.mcp.json` bytes: a regular file of at most 1 MiB, never
/// through a symlink or a hard link, so a FIFO or a device in a cloned repo
/// can't block the read. Null when there is none, and
/// `error.UnreadableConfig` when it exists but fx won't read it. Caller owns
/// the bytes.
pub fn readFile(alloc: std.mem.Allocator, workspace_root: []const u8) !?[]u8 {
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), workspace_root, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer dir.close(io_mod.getIo());
    var file = io_mod.openExistingRegularFile(dir, ".mcp.json", .read_only) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.UnreadableConfig,
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.size > max_config_bytes) return error.UnreadableConfig;
    return io_mod.readFileToEnd(alloc, &file, max_config_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnreadableConfig,
    };
}

pub fn load(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    scope: mcp_contract.ConfigScope,
    choices: project_config.ProjectMcpChoices,
) !project_config.WorkspaceParseResult {
    const bytes = (readFile(alloc, workspace_root) catch |err| switch (err) {
        error.UnreadableConfig => return invalidResult(alloc),
        else => |e| return e,
    }) orelse return .{};
    defer alloc.free(bytes);
    var result = try project_config.parseWorkspaceJson(
        alloc,
        bytes,
        scope,
        choices,
    );
    errdefer result.deinit(alloc);
    const has_approved = for (result.configs.items) |config| {
        if (config.workspace_admission == .approved) break true;
    } else false;
    if (!has_approved) return result;
    var environment = io_mod.cloneEnvironMap(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.process.Environ.Map.init(alloc),
    };
    defer environment.deinit();
    try project_config.expandApprovedWorkspaceConfigs(
        alloc,
        &result,
        &environment,
    );
    return result;
}

fn invalidResult(alloc: std.mem.Allocator) !project_config.WorkspaceParseResult {
    var result: project_config.WorkspaceParseResult = .{};
    errdefer result.deinit(alloc);
    try result.diagnostics.append(alloc, .{ .cause = .invalid_entry });
    return result;
}
