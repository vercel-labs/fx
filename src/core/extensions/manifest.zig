//! Strict profile-owned manifests prevent workspace files from activating code.
const std = @import("std");
const protocol = @import("protocol.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const max_model_id_bytes = 256;
const terminal_delete_byte = 0x7f;
const https_scheme = "https";
const http_scheme = "http";
const loopback_hosts = [_][]const u8{ "localhost", "127.0.0.1", "::1", "[::1]" };

pub const RegistryFile = struct {
    version: u32,
    extensions: []const struct { path: []const u8 },
};

pub const Manifest = struct {
    version: u32,
    id: []const u8,
    entrypoint: []const u8,
    capabilities: []const []const u8,
    providers: []const protocol.Provider,
};

/// One allocation boundary makes parse failure cleanup independent of field count.
pub fn read_json(comptime T: type, alloc: Allocator, path: []const u8, max_bytes: usize) !std.json.Parsed(T) {
    var file = try std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_bytes);
    defer alloc.free(bytes);
    return std.json.parseFromSlice(T, alloc, bytes, .{ .allocate = .alloc_always });
}

/// IDs cannot contain separators because they participate in namespace routing.
pub fn validate_id(id: []const u8) !void {
    if (id.len == 0) return error.ExtensionIdInvalid;
    for (id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.ExtensionIdInvalid;
    }
}

/// Model aliases may include vendor separators but never terminal control bytes.
pub fn validate_model_id(id: []const u8) !void {
    if (id.len == 0 or id.len > max_model_id_bytes) return error.ExtensionModelInvalid;
    for (id) |byte| if (byte < ' ' or byte == terminal_delete_byte) return error.ExtensionModelInvalid;
}

/// Offline lexical validation prevents missing entrypoints from escaping their root.
pub fn owned_child_path(alloc: Allocator, root: []const u8, relative: []const u8) ![]u8 {
    if (relative.len == 0 or std.fs.path.isAbsolute(relative)) return error.ExtensionPathInvalid;
    const path = try std.fs.path.resolve(alloc, &.{ root, relative });
    errdefer alloc.free(path);
    if (!std.mem.startsWith(u8, path, root) or path.len <= root.len or path[root.len] != std.fs.path.sep) return error.ExtensionPathEscapesRoot;
    return path;
}

/// Canonical checks also reject symlinks that escape the trusted extension directory.
pub fn canonical_child_path(alloc: Allocator, root: []const u8, relative: []const u8) ![]u8 {
    const lexical = try owned_child_path(alloc, root, relative);
    defer alloc.free(lexical);
    const canonical = try io_mod.realpathAlloc(alloc, lexical);
    errdefer alloc.free(canonical);
    if (!std.mem.startsWith(u8, canonical, root) or canonical.len <= root.len or canonical[root.len] != std.fs.path.sep) return error.ExtensionPathEscapesRoot;
    return canonical;
}

/// Remote credentials require TLS; loopback alone supports deterministic HTTP fixtures.
pub fn validate_endpoint(value: []const u8) !void {
    const uri = std.Uri.parse(value) catch return error.ExtensionEndpointInvalid;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.ExtensionEndpointInvalid;
    const host = uri.host orelse return error.ExtensionEndpointInvalid;
    const host_text = switch (host) {
        .raw => |raw| raw,
        .percent_encoded => |raw| raw,
    };
    if (host_text.len == 0 or std.mem.findScalar(u8, host_text, '%') != null) return error.ExtensionEndpointInvalid;
    if (std.mem.eql(u8, uri.scheme, https_scheme)) return;
    if (std.mem.eql(u8, uri.scheme, http_scheme)) {
        for (loopback_hosts) |allowed| if (std.ascii.eqlIgnoreCase(host_text, allowed)) return;
    }
    return error.ExtensionEndpointInvalid;
}
