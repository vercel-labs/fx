//! Strict profile-owned manifests prevent workspace files from activating code.
const std = @import("std");
const protocol = @import("protocol.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const max_model_id_bytes = 256;
const terminal_delete_byte = 0x7f;
const https_scheme = "https";
const http_scheme = "http";
const loopback_hosts = [_][]const u8{ "localhost", "127.0.0.1", "::1", "[::1]" };
const max_environment_name_bytes = 256;
const max_header_count = 64;
const max_header_name_bytes = 256;
const max_header_value_bytes = 8192;
const header_token_punctuation = "!#$%&'*+-.^_`|~";
const managed_header_names = [_][]const u8{ "authorization", "proxy-authorization", "host", "content-length", "content-type", "connection", "transfer-encoding", "user-agent" };
const header_source_key = "source";
const header_environment_name_key = "name";
const header_session_source = "session_id";
const header_environment_source = "env";
const session_binding_fields = 1;
const environment_binding_fields = 2;

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

/// Menu inputs must remain bounded and consistent before any adapter retains them.
pub fn validate_model(model: protocol.Model) !void {
    try validate_model_id(model.id);
    try validate_model_id(model.wire_id);
    try validate_model_id(model.name);
    if (model.context_window) |limit| if (limit == 0) return error.ExtensionModelInvalid;
    if (model.max_output_tokens) |limit| {
        if (limit == 0) return error.ExtensionModelInvalid;
        if (model.context_window) |context| if (limit > context) return error.ExtensionModelInvalid;
    }
    if (model.reasoning_efforts.len > types.ReasoningEffort.max_options or
        (!model.reasoning and model.reasoning_efforts.len != 0)) return error.ExtensionModelInvalid;
    for (model.reasoning_efforts, 0..) |effort, index| {
        const parsed = types.ReasoningEffort.parse(effort) orelse return error.ExtensionModelInvalid;
        if (parsed.isDefault()) return error.ExtensionModelInvalid;
        for (model.reasoning_efforts[0..index]) |previous| {
            if (std.mem.eql(u8, previous, effort)) return error.ExtensionModelInvalid;
        }
    }
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

/// Portable slot names prevent implicit shell expressions and ambiguous environment lookups.
pub fn validate_environment_name(value: []const u8) !void {
    if (value.len == 0 or value.len > max_environment_name_bytes) return error.ExtensionCredentialReferenceInvalid;
    if (!std.ascii.isAlphabetic(value[0]) and value[0] != '_') return error.ExtensionCredentialReferenceInvalid;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.ExtensionCredentialReferenceInvalid;
}

/// Host-managed authentication and framing cannot be replaced by manifest metadata.
pub fn validate_headers(headers: ?std.json.Value) !void {
    const value = headers orelse return;
    if (value != .object or value.object.count() > max_header_count) return error.ExtensionHeaderInvalid;
    var fields = value.object.iterator();
    var count: usize = 0;
    while (fields.next()) |field| {
        const name = field.key_ptr.*;
        // HTTP names are case-insensitive; ambiguous bindings cannot choose different credentials.
        for (value.object.keys()[0..count]) |previous| {
            if (std.ascii.eqlIgnoreCase(previous, name)) return error.ExtensionHeaderInvalid;
        }
        count += 1;
        if (name.len == 0 or name.len > max_header_name_bytes) return error.ExtensionHeaderInvalid;
        for (name) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and std.mem.findScalar(u8, header_token_punctuation, byte) == null) return error.ExtensionHeaderInvalid;
        }
        for (managed_header_names) |managed| if (std.ascii.eqlIgnoreCase(name, managed)) return error.ExtensionHeaderInvalid;
        const binding = field.value_ptr.*;
        switch (binding) {
            .string => |text| {
                if (text.len > max_header_value_bytes) return error.ExtensionHeaderInvalid;
                for (text) |byte| if (byte < ' ' or byte == terminal_delete_byte) return error.ExtensionHeaderInvalid;
            },
            .object => |object| {
                const source = object.get(header_source_key) orelse return error.ExtensionHeaderInvalid;
                if (source != .string) return error.ExtensionHeaderInvalid;
                if (std.mem.eql(u8, source.string, header_session_source)) {
                    if (object.count() != session_binding_fields) return error.ExtensionHeaderInvalid;
                } else if (std.mem.eql(u8, source.string, header_environment_source)) {
                    if (object.count() != environment_binding_fields) return error.ExtensionHeaderInvalid;
                    const environment = object.get(header_environment_name_key) orelse return error.ExtensionHeaderInvalid;
                    if (environment != .string) return error.ExtensionHeaderInvalid;
                    validate_environment_name(environment.string) catch return error.ExtensionHeaderInvalid;
                } else return error.ExtensionHeaderInvalid;
            },
            else => return error.ExtensionHeaderInvalid,
        }
    }
}

/// Remote credentials require TLS; loopback alone supports deterministic HTTP fixtures.
pub fn validate_endpoint(value: []const u8) !void {
    for (value) |byte| if (byte <= ' ' or byte == terminal_delete_byte) return error.ExtensionEndpointInvalid;
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
