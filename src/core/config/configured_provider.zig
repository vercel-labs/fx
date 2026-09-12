const std = @import("std");
const Allocator = std.mem.Allocator;

const max_providers = 32;
const max_models = 256;
pub const max_id_bytes = 64;
pub const max_model_bytes = 1024;
const max_url_bytes = 2048;
const max_env_bytes = 128;
const max_json_bytes = 1024 * 1024;

pub const ParseError = Allocator.Error || error{
    InvalidJson,
    DuplicateField,
    LimitExceeded,
    InvalidObject,
    UnknownField,
    MissingField,
    InvalidProviderId,
    ReservedProviderId,
    InvalidProtocol,
    InvalidBaseUrl,
    InsecureBaseUrl,
    InvalidAuth,
    InvalidEnvironmentName,
    InvalidToolChoiceMode,
    InvalidModelId,
    InvalidModelMetadata,
};

pub const Protocol = enum { @"openai-chat-completions" };
pub const ToolChoiceMode = enum { omit, send };

/// Describes a credential slot, never a credential value. Resolution belongs at
/// the effectful edge; `none` must omit Authorization rather than supply a token.
pub const Auth = union(enum) {
    none,
    bearer: []const u8,
};

pub const ModelMetadata = struct {
    id: []const u8,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
    supports_tool_use: ?bool = null,
    supports_vision: ?bool = null,
};

/// Registry owns all slices. Treat definitions as immutable while borrowed by
/// requests; destroying the registry invalidates every definition and lookup.
pub const Definition = struct {
    id: []const u8,
    protocol: Protocol,
    base_url: []const u8,
    auth: Auth,
    tool_choice_mode: ToolChoiceMode = .omit,
    reviewer_model: ?[]const u8 = null,
    model_metadata: []const ModelMetadata = &.{},

    /// Caller owns the returned URL. base_url is already a validated API prefix.
    pub fn chat_url(self: Definition, alloc: Allocator) Allocator.Error![]u8 {
        return std.mem.concat(alloc, u8, &.{ self.base_url, "/chat/completions" });
    }

    /// Borrowed metadata; absence and unspecified fields remain unknown.
    pub fn model(self: Definition, id: []const u8) ?*const ModelMetadata {
        if (id.len > max_model_bytes) return null;
        for (self.model_metadata) |*metadata| {
            if (std.mem.eql(u8, metadata.id, id)) return metadata;
        }
        return null;
    }

    /// Non-secret route provenance, stable across credential rotation in the
    /// same environment slot. Length framing prevents ambiguous concatenations.
    /// This does not snapshot model/compatibility policy or authorize a send.
    pub fn binding_identity(self: Definition) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("fx-configured-provider-v1");
        hash_part(&hash, self.id);
        hash_part(&hash, @tagName(self.protocol));
        hash_part(&hash, self.base_url);
        hash_part(&hash, @tagName(self.auth));
        switch (self.auth) {
            .none => {},
            .bearer => |env| hash_part(&hash, env),
        }
        return hash.finalResult();
    }

    fn deinit(self: Definition, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.base_url);
        switch (self.auth) {
            .none => {},
            .bearer => |env| alloc.free(env),
        }
        if (self.reviewer_model) |id| alloc.free(id);
        for (self.model_metadata) |metadata| alloc.free(metadata.id);
        alloc.free(self.model_metadata);
    }
};

pub const Registry = struct {
    definitions: []const Definition = &.{},

    /// Parse the providers object itself, not the surrounding settings object.
    /// All returned storage is owned, independent of `providers`, and must be
    /// freed with deinit using the same allocator. Errors leave no owned state.
    /// PRECONDITION: the caller's JSON parser must reject duplicate keys at all
    /// depths (including providers in the enclosing settings). Value's ObjectMap
    /// cannot retain evidence of duplicates already discarded by another parser.
    pub fn parse(alloc: Allocator, providers: std.json.Value) ParseError!Registry {
        if (providers != .object) return error.InvalidObject;
        if (providers.object.count() > max_providers) return error.LimitExceeded;
        const definitions = try alloc.alloc(Definition, providers.object.count());
        var initialized: usize = 0;
        errdefer {
            for (definitions[0..initialized]) |definition| definition.deinit(alloc);
            alloc.free(definitions);
        }
        var iterator = providers.object.iterator();
        while (iterator.next()) |entry| {
            definitions[initialized] = try parse_definition(alloc, entry.key_ptr.*, entry.value_ptr.*);
            initialized += 1;
        }
        return .{ .definitions = definitions };
    }

    /// Bounded, duplicate-rejecting convenience parser for a raw providers object.
    /// std.json.Value parses iteratively; input size also bounds nesting/work.
    /// The temporary JSON tree is released before returning the owned registry.
    pub fn parse_json(alloc: Allocator, json: []const u8) ParseError!Registry {
        if (json.len > max_json_bytes) return error.LimitExceeded;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{
            .duplicate_field_behavior = .@"error",
            .max_value_len = max_url_bytes,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateField => return error.DuplicateField,
            error.ValueTooLong => return error.LimitExceeded,
            else => return error.InvalidJson,
        };
        defer parsed.deinit();
        return parse(alloc, parsed.value);
    }

    pub fn deinit(self: *Registry, alloc: Allocator) void {
        for (self.definitions) |definition| definition.deinit(alloc);
        alloc.free(self.definitions);
        self.* = .{};
    }

    /// Returns a borrow valid until registry teardown. IDs are case-sensitive.
    pub fn get(self: Registry, id: []const u8) ?*const Definition {
        if (id.len > max_id_bytes) return null;
        for (self.definitions) |*definition| {
            if (std.mem.eql(u8, definition.id, id)) return definition;
        }
        return null;
    }
};

fn parse_definition(alloc: Allocator, id: []const u8, value: std.json.Value) ParseError!Definition {
    try validate_id(id);
    try check_fields(value, &.{ "protocol", "base_url", "auth", "tool_choice_mode", "reviewer_model", "model_metadata" });
    const protocol = try required(value, "protocol");
    if (protocol != .string or !std.mem.eql(u8, protocol.string, "openai-chat-completions")) return error.InvalidProtocol;
    const url = try required(value, "base_url");
    if (url != .string) return error.InvalidBaseUrl;
    const normalized = try validate_url(url.string);
    const auth = try parse_auth(try required(value, "auth"));
    var mode: ToolChoiceMode = .omit;
    if (value.object.get("tool_choice_mode")) |choice| {
        if (choice != .string) return error.InvalidToolChoiceMode;
        mode = if (std.mem.eql(u8, choice.string, "omit")) .omit else if (std.mem.eql(u8, choice.string, "send")) .send else return error.InvalidToolChoiceMode;
    }
    var reviewer: ?[]const u8 = null;
    if (value.object.get("reviewer_model")) |model_value| {
        if (model_value != .string) return error.InvalidModelId;
        try validate_model_id(model_value.string);
        reviewer = model_value.string;
    }

    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const owned_url = try alloc.dupe(u8, normalized);
    errdefer alloc.free(owned_url);
    const owned_auth: Auth = switch (auth) {
        .none => .none,
        .bearer => |env| .{ .bearer = try alloc.dupe(u8, env) },
    };
    errdefer switch (owned_auth) {
        .none => {},
        .bearer => |env| alloc.free(env),
    };
    const owned_reviewer = if (reviewer) |model_id| try alloc.dupe(u8, model_id) else null;
    errdefer if (owned_reviewer) |model_id| alloc.free(model_id);
    return .{
        .id = owned_id,
        .protocol = .@"openai-chat-completions",
        .base_url = owned_url,
        .auth = owned_auth,
        .tool_choice_mode = mode,
        .reviewer_model = owned_reviewer,
        .model_metadata = if (value.object.get("model_metadata")) |metadata| try parse_metadata(alloc, metadata) else &.{},
    };
}

fn parse_auth(value: std.json.Value) ParseError!Auth {
    try check_fields(value, &.{ "type", "env" });
    const kind = try required(value, "type");
    if (kind != .string) return error.InvalidAuth;
    if (std.mem.eql(u8, kind.string, "none")) {
        if (value.object.contains("env")) return error.InvalidAuth;
        return .none;
    }
    if (!std.mem.eql(u8, kind.string, "bearer")) return error.InvalidAuth;
    const env = try required(value, "env");
    if (env != .string) return error.InvalidEnvironmentName;
    if (env.string.len > max_env_bytes) return error.LimitExceeded;
    if (env.string.len == 0 or (!std.ascii.isAlphabetic(env.string[0]) and env.string[0] != '_')) return error.InvalidEnvironmentName;
    for (env.string) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidEnvironmentName;
    }
    return .{ .bearer = env.string };
}

fn parse_metadata(alloc: Allocator, value: std.json.Value) ParseError![]const ModelMetadata {
    if (value != .object) return error.InvalidObject;
    if (value.object.count() > max_models) return error.LimitExceeded;
    const models = try alloc.alloc(ModelMetadata, value.object.count());
    var initialized: usize = 0;
    errdefer {
        for (models[0..initialized]) |metadata| alloc.free(metadata.id);
        alloc.free(models);
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        try validate_model_id(entry.key_ptr.*);
        const metadata = entry.value_ptr.*;
        try check_fields(metadata, &.{ "context_window", "max_output_tokens", "supports_tool_use", "supports_vision" });
        const context = try positive_limit(metadata.object.get("context_window"));
        const output = try positive_limit(metadata.object.get("max_output_tokens"));
        if (context != null and output != null and output.? >= context.?) return error.InvalidModelMetadata;
        const tools = try optional_bool(metadata.object.get("supports_tool_use"));
        const vision = try optional_bool(metadata.object.get("supports_vision"));
        models[initialized] = .{
            .id = try alloc.dupe(u8, entry.key_ptr.*),
            .context_window = context,
            .max_output_tokens = output,
            .supports_tool_use = tools,
            .supports_vision = vision,
        };
        initialized += 1;
    }
    return models;
}

fn positive_limit(value: ?std.json.Value) ParseError!?u32 {
    const present = value orelse return null;
    if (present != .integer or present.integer <= 0 or present.integer > std.math.maxInt(u32)) return error.InvalidModelMetadata;
    return @intCast(present.integer);
}

fn optional_bool(value: ?std.json.Value) ParseError!?bool {
    const present = value orelse return null;
    if (present != .bool) return error.InvalidModelMetadata;
    return present.bool;
}

fn check_fields(value: std.json.Value, allowed: []const []const u8) ParseError!void {
    if (value != .object) return error.InvalidObject;
    if (value.object.count() > allowed.len) return error.UnknownField;
    for (value.object.keys()) |key| {
        for (allowed) |name| {
            if (std.mem.eql(u8, key, name)) break;
        } else return error.UnknownField;
    }
}

fn required(value: std.json.Value, name: []const u8) ParseError!std.json.Value {
    return value.object.get(name) orelse error.MissingField;
}

// Named connection IDs are ASCII [A-Za-z][A-Za-z0-9_-]*. Built-in names are
// reserved case-insensitively, matching the existing provider selector.
pub fn validate_id(id: []const u8) error{ LimitExceeded, InvalidProviderId, ReservedProviderId }!void {
    if (id.len > max_id_bytes) return error.LimitExceeded;
    if (id.len == 0 or !std.ascii.isAlphabetic(id[0])) return error.InvalidProviderId;
    for (id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return error.InvalidProviderId;
    }
    for ([_][]const u8{ "gateway", "codex", "grok" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(id, reserved)) return error.ReservedProviderId;
    }
}

pub fn validate_model_id(id: []const u8) error{ LimitExceeded, InvalidModelId }!void {
    if (id.len > max_model_bytes) return error.LimitExceeded;
    if (id.len == 0 or !std.unicode.utf8ValidateSlice(id)) return error.InvalidModelId;
    if (std.mem.trim(u8, id, " \t\r\n").len != id.len) return error.InvalidModelId;
    for (id) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidModelId;
    }
}

/// Returns a borrow, removing only one optional trailing slash. No decoding,
/// case folding, default-port removal, or path-prefix rewriting is performed.
fn validate_url(url: []const u8) ParseError![]const u8 {
    if (url.len > max_url_bytes) return error.LimitExceeded;
    for (url) |byte| {
        if (byte <= 0x20 or byte >= 0x7f or byte == '\\') return error.InvalidBaseUrl;
    }
    const uri = std.Uri.parse(url) catch return error.InvalidBaseUrl;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidBaseUrl;
    const host = (uri.host orelse return error.InvalidBaseUrl).percent_encoded;
    if (host.len == 0) return error.InvalidBaseUrl;
    // Check the complete authority: Uri.parse alone accepts some malformed
    // bracket suffixes and parseInt accepts signs/underscores in ports.
    const rest = url[uri.scheme.len + 1 ..];
    if (!std.mem.startsWith(u8, rest, "//")) return error.InvalidBaseUrl;
    const authority = rest[2 .. 2 + (std.mem.findScalar(u8, rest[2..], '/') orelse rest.len - 2)];
    if (!std.mem.startsWith(u8, authority, host)) return error.InvalidBaseUrl;
    const port = authority[host.len..];
    if (port.len != 0) {
        if (port[0] != ':' or port.len < 2 or port.len > 6) return error.InvalidBaseUrl;
        for (port[1..]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidBaseUrl;
        const number = std.fmt.parseInt(u16, port[1..], 10) catch return error.InvalidBaseUrl;
        if (number == 0) return error.InvalidBaseUrl;
    }
    if (host[0] == '[') {
        if (host.len < 3 or host[host.len - 1] != ']') return error.InvalidBaseUrl;
        _ = std.Io.net.Ip6Address.parse(host[1 .. host.len - 1], 0) catch return error.InvalidBaseUrl;
    } else {
        if (host.len > 253) return error.InvalidBaseUrl;
        var labels = std.mem.splitScalar(u8, host, '.');
        while (labels.next()) |label| {
            if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return error.InvalidBaseUrl;
            for (label) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return error.InvalidBaseUrl;
        }
    }
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InsecureBaseUrl;
        if (!std.mem.eql(u8, host, "127.0.0.1") and !std.mem.eql(u8, host, "[::1]") and !std.ascii.eqlIgnoreCase(host, "localhost")) return error.InsecureBaseUrl;
    }
    // Preserve encoded path bytes but reject malformed escapes and encoded
    // controls so later HTTP construction cannot reinterpret unsafe bytes.
    const path = uri.path.percent_encoded;
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        const byte = path[index];
        if (byte == '%') {
            if (path.len - index < 3) return error.InvalidBaseUrl;
            const decoded = std.fmt.parseInt(u8, path[index + 1 ..][0..2], 16) catch return error.InvalidBaseUrl;
            if (!std.ascii.isHex(path[index + 1]) or !std.ascii.isHex(path[index + 2]) or decoded < 0x20 or decoded == 0x7f) return error.InvalidBaseUrl;
            index += 2;
        } else if (!std.ascii.isAlphanumeric(byte) and std.mem.findScalar(u8, "/-._~!$&'()*+,;=:@", byte) == null) return error.InvalidBaseUrl;
    }
    return if (std.mem.endsWith(u8, url, "/")) url[0 .. url.len - 1] else url;
}

fn hash_part(hash: *std.crypto.hash.sha2.Sha256, part: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(part.len), .big);
    hash.update(&length);
    hash.update(part);
}

const test_json =
    \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:11434/v1/","auth":{"type":"none"}},
    \\"router":{"protocol":"openai-chat-completions","base_url":"https://openrouter.ai/api/v1","auth":{"type":"bearer","env":"OPENROUTER_API_KEY"},"tool_choice_mode":"send","reviewer_model":"openai/review","model_metadata":{"openai/gpt-4.1":{"context_window":8192,"max_output_tokens":1024,"supports_tool_use":true,"supports_vision":false},"unknown":{}}}}
;

test "configured provider owns definitions and preserves unknown metadata" {
    const alloc = std.testing.allocator;
    const input = try alloc.dupe(u8, test_json);
    var registry = try Registry.parse_json(alloc, input);
    alloc.free(input);
    defer registry.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), registry.definitions.len);
    const local = registry.get("local").?;
    try std.testing.expectEqual(Auth.none, local.auth);
    try std.testing.expectEqual(ToolChoiceMode.omit, local.tool_choice_mode);
    try std.testing.expect(local.reviewer_model == null);
    const chat = try local.chat_url(alloc);
    defer alloc.free(chat);
    try std.testing.expectEqualStrings("http://localhost:11434/v1/chat/completions", chat);
    const router = registry.get("router").?;
    try std.testing.expectEqualStrings("OPENROUTER_API_KEY", router.auth.bearer);
    try std.testing.expectEqualStrings("openai/review", router.reviewer_model.?);
    try std.testing.expectEqual(ToolChoiceMode.send, router.tool_choice_mode);
    const metadata = router.model("openai/gpt-4.1").?;
    try std.testing.expectEqual(@as(?u32, 8192), metadata.context_window);
    try std.testing.expectEqual(@as(?u32, 1024), metadata.max_output_tokens);
    try std.testing.expectEqual(@as(?bool, true), metadata.supports_tool_use);
    try std.testing.expectEqual(@as(?bool, false), metadata.supports_vision);
    const unknown = router.model("unknown").?;
    try std.testing.expect(unknown.context_window == null and unknown.max_output_tokens == null);
    try std.testing.expect(unknown.supports_tool_use == null and unknown.supports_vision == null);
    try std.testing.expect(router.model("missing") == null);
    try std.testing.expect(registry.get("Router") == null);
}

test "configured provider URL policy and prefix normalization" {
    const valid = [_][2][]const u8{
        .{ "https://example.com", "https://example.com" },
        .{ "https://example.com/", "https://example.com" },
        .{ "https://example.com/api/v1/", "https://example.com/api/v1" },
        .{ "https://example.com/a//b/%2f/", "https://example.com/a//b/%2f" },
        .{ "http://localhost", "http://localhost" },
        .{ "http://127.0.0.1:80/v1", "http://127.0.0.1:80/v1" },
        .{ "http://[::1]:65535/v1", "http://[::1]:65535/v1" },
        .{ "HTTPS://Example.com/API/V1", "HTTPS://Example.com/API/V1" },
        .{ "https://[2001:db8::1]/v1", "https://[2001:db8::1]/v1" },
    };
    for (valid) |pair| try std.testing.expectEqualStrings(pair[1], try validate_url(pair[0]));
    const invalid = [_][]const u8{
        "",                          "https:/example.com",      "https://",                  "https://user:secret@example.com", "https://@example.com",      "https://example.com?",  "https://example.com#",
        "https://example.com/\r\nx", "https://example.com/a b", "https://example.com\\evil", "https://example.com/%0a",         "https://example.com/%7f",   "https://example.com/%", "https://example.com/%zz",
        "https://example.com:",      "https://example.com:+80", "https://example.com:-1",    "https://example.com:8_0",         "https://example.com:65536", "https://example.com:0", "https://example.com:abc",
        "https://[::1]extra",        "https://[::1]extra:80",   "https://[not-ip]:80",       "https://::1",                     "https://%6cocalhost",       "https://bad..host",     "https://-bad.host",
        "https://bad_host",
    };
    for (invalid) |url| try std.testing.expectError(error.InvalidBaseUrl, validate_url(url));
    const insecure = [_][]const u8{ "http://example.com", "ftp://example.com", "http://127.0.0.2", "http://127.1", "http://2130706433", "http://localhost.evil", "http://[::ffff:127.0.0.1]", "http://[0:0:0:0:0:0:0:1]" };
    for (insecure) |url| try std.testing.expectError(error.InsecureBaseUrl, validate_url(url));
}

test "configured provider binding identity separates name endpoint and auth slot" {
    var registry = try Registry.parse_json(std.testing.allocator, test_json);
    defer registry.deinit(std.testing.allocator);
    const original = registry.get("router").?.*;
    const identity = original.binding_identity();
    try std.testing.expectEqual(identity, original.binding_identity());
    var changed = original;
    changed.id = "other";
    try std.testing.expect(!std.mem.eql(u8, &identity, &changed.binding_identity()));
    changed = original;
    changed.base_url = "https://example.com/api/v1";
    try std.testing.expect(!std.mem.eql(u8, &identity, &changed.binding_identity()));
    changed = original;
    changed.auth = .{ .bearer = "OTHER_KEY" };
    try std.testing.expect(!std.mem.eql(u8, &identity, &changed.binding_identity()));
    changed.auth = .none;
    try std.testing.expect(!std.mem.eql(u8, &identity, &changed.binding_identity()));
    changed = original;
    changed.base_url = try validate_url("https://openrouter.ai/api/v1/");
    try std.testing.expectEqual(identity, changed.binding_identity());
}

test "configured provider duplicate keys are rejected before Value loses evidence" {
    for ([_][]const u8{
        "{\"local\":{},\"local\":{}}",
        "{\"local\":{\"protocol\":1,\"protocol\":2}}",
        "{\"local\":{\"auth\":{\"type\":\"none\",\"type\":\"bearer\"}}}",
        "{\"local\":{\"model_metadata\":{\"model\":{},\"model\":{}}}}",
        "{\"local\":{\"model_metadata\":{\"model\":{\"supports_vision\":true,\"supports_vision\":false}}}}",
        "{\"local\":{},\"lo\\u0063al\":{}}",
    }) |json| try std.testing.expectError(error.DuplicateField, Registry.parse_json(std.testing.allocator, json));
}

fn test_allocations(alloc: Allocator) !void {
    var registry = try Registry.parse_json(alloc, test_json);
    defer registry.deinit(alloc);
    const definition = registry.get("router").?;
    const chat = try definition.chat_url(alloc);
    defer alloc.free(chat);
    _ = definition.binding_identity();
}

test "configured provider allocation failures release partial registry and URLs" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, test_allocations, .{});
}

const test_required_fields = "\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://example.com/v1\",\"auth\":{\"type\":\"none\"}";

test "configured provider invalid schemas fail explicitly" {
    const cases = [_]struct { json: []const u8, err: ParseError }{
        .{ .json = "{", .err = error.InvalidJson },
        .{ .json = "null", .err = error.InvalidObject },
        .{ .json = "[]", .err = error.InvalidObject },
        .{ .json = "{\"\":{}}", .err = error.InvalidProviderId },
        .{ .json = "{\"1local\":{}}", .err = error.InvalidProviderId },
        .{ .json = "{\"local.host\":{}}", .err = error.InvalidProviderId },
        .{ .json = "{\"local/host\":{}}", .err = error.InvalidProviderId },
        .{ .json = "{\" local\":{}}", .err = error.InvalidProviderId },
        .{ .json = "{\"GATEWAY\":{}}", .err = error.ReservedProviderId },
        .{ .json = "{\"codex\":{}}", .err = error.ReservedProviderId },
        .{ .json = "{\"Grok\":{}}", .err = error.ReservedProviderId },
        .{ .json = "{\"local\":null}", .err = error.InvalidObject },
        .{ .json = "{\"local\":{}}", .err = error.MissingField },
        .{ .json = "{\"local\":{\"protocol\":\"responses\"}}", .err = error.InvalidProtocol },
        .{ .json = "{\"local\":{\"protocol\":false}}", .err = error.InvalidProtocol },
        .{ .json = "{\"local\":{\"protocol\":\"openai-chat-completions\",\"base_url\":null}}", .err = error.InvalidBaseUrl },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"secret\":\"not-allowed\"}}", .err = error.UnknownField },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"tool_choice_mode\":\"auto\"}}", .err = error.InvalidToolChoiceMode },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"tool_choice_mode\":null}}", .err = error.InvalidToolChoiceMode },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"reviewer_model\":null}}", .err = error.InvalidModelId },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"reviewer_model\":\"\"}}", .err = error.InvalidModelId },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"reviewer_model\":\"bad\\nmodel\"}}", .err = error.InvalidModelId },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"model_metadata\":null}}", .err = error.InvalidObject },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"\":{}}}}", .err = error.InvalidModelId },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"m\":[]}}}", .err = error.InvalidObject },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"m\":{\"context_window\":0}}}}", .err = error.InvalidModelMetadata },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"m\":{\"context_window\":-1}}}}", .err = error.InvalidModelMetadata },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"m\":{\"context_window\":1.5}}}}", .err = error.InvalidModelMetadata },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"m\":{\"context_window\":4294967296}}}}", .err = error.InvalidModelMetadata },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"m\":{\"max_output_tokens\":null}}}}", .err = error.InvalidModelMetadata },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"m\":{\"max_output_tokens\":\"10\"}}}}", .err = error.InvalidModelMetadata },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"m\":{\"context_window\":1,\"max_output_tokens\":1}}}}", .err = error.InvalidModelMetadata },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"m\":{\"context_window\":2,\"max_output_tokens\":3}}}}", .err = error.InvalidModelMetadata },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"m\":{\"supports_tool_use\":1}}}}", .err = error.InvalidModelMetadata },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"m\":{\"supports_vision\":null}}}}", .err = error.InvalidModelMetadata },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"m\":{\"supports_search\":true}}}}", .err = error.UnknownField },
    };
    for (cases) |case| try std.testing.expectError(case.err, Registry.parse_json(std.testing.allocator, case.json));
}

test "configured provider auth admits only explicit none or a portable environment slot" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { json: []const u8, err: ParseError }{
        .{ .json = "null", .err = error.InvalidObject },
        .{ .json = "{}", .err = error.MissingField },
        .{ .json = "{\"type\":false}", .err = error.InvalidAuth },
        .{ .json = "{\"type\":\"basic\"}", .err = error.InvalidAuth },
        .{ .json = "{\"type\":\"none\",\"env\":\"KEY\"}", .err = error.InvalidAuth },
        .{ .json = "{\"type\":\"none\",\"env\":null}", .err = error.InvalidAuth },
        .{ .json = "{\"type\":\"bearer\"}", .err = error.MissingField },
        .{ .json = "{\"type\":\"bearer\",\"env\":null}", .err = error.InvalidEnvironmentName },
        .{ .json = "{\"type\":\"bearer\",\"env\":\"\"}", .err = error.InvalidEnvironmentName },
        .{ .json = "{\"type\":\"bearer\",\"env\":\"1KEY\"}", .err = error.InvalidEnvironmentName },
        .{ .json = "{\"type\":\"bearer\",\"env\":\"${KEY}\"}", .err = error.InvalidEnvironmentName },
        .{ .json = "{\"type\":\"bearer\",\"env\":\"KEY=secret\"}", .err = error.InvalidEnvironmentName },
        .{ .json = "{\"type\":\"bearer\",\"env\":\"KEY\\n\"}", .err = error.InvalidEnvironmentName },
        .{ .json = "{\"type\":\"bearer\",\"env\":\"KEY\",\"token\":\"literal\"}", .err = error.UnknownField },
        .{ .json = "{\"type\":\"bearer\",\"command\":\"get-key\"}", .err = error.UnknownField },
    };
    for (cases) |case| {
        const json = try std.fmt.allocPrint(alloc, "{{\"local\":{{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://example.com\",\"auth\":{s}}}}}", .{case.json});
        defer alloc.free(json);
        try std.testing.expectError(case.err, Registry.parse_json(alloc, json));
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"type\":\"bearer\",\"env\":\"_key_2\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("_key_2", (try parse_auth(parsed.value)).bearer);
}

test "configured provider scalar bounds and minimum input budget" {
    try validate_id("a" ** max_id_bytes);
    try validate_id("Local_2-test");
    try std.testing.expectError(error.LimitExceeded, validate_id("a" ** (max_id_bytes + 1)));
    try validate_model_id("m" ** max_model_bytes);
    try validate_model_id("vendor/model:tag");
    try validate_model_id("model with internal spaces");
    try std.testing.expectError(error.InvalidModelId, validate_model_id(" leading"));
    try std.testing.expectError(error.InvalidModelId, validate_model_id("trailing "));
    try std.testing.expectError(error.LimitExceeded, validate_model_id("m" ** (max_model_bytes + 1)));
    try std.testing.expectError(error.InvalidModelId, validate_model_id("bad\xff"));
    const prefix = "https://example.com/";
    _ = try validate_url(prefix ++ "a" ** (max_url_bytes - prefix.len));
    try std.testing.expectError(error.LimitExceeded, validate_url(prefix ++ "a" ** (max_url_bytes - prefix.len + 1)));

    const alloc = std.testing.allocator;
    for ([_]usize{ max_env_bytes, max_env_bytes + 1 }) |length| {
        const env = "E" ** (max_env_bytes + 1);
        const json = try std.fmt.allocPrint(alloc, "{{\"local\":{{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://example.com\",\"auth\":{{\"type\":\"bearer\",\"env\":\"{s}\"}}}}}}", .{env[0..length]});
        defer alloc.free(json);
        if (length == max_env_bytes) {
            var registry = try Registry.parse_json(alloc, json);
            defer registry.deinit(alloc);
            try std.testing.expectEqual(max_env_bytes, registry.get("local").?.auth.bearer.len);
        } else try std.testing.expectError(error.LimitExceeded, Registry.parse_json(alloc, json));
    }
    const json = "{\"local\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"small\":{\"context_window\":2,\"max_output_tokens\":1},\"large\":{\"context_window\":4294967295},\"output-only\":{\"max_output_tokens\":1}}}}";
    var registry = try Registry.parse_json(alloc, json);
    defer registry.deinit(alloc);
    try std.testing.expectEqual(@as(?u32, std.math.maxInt(u32)), registry.get("local").?.model("large").?.context_window);
    try std.testing.expect(registry.get("local").?.model("output-only").?.context_window == null);
}

test "configured provider registry model count and raw input bounds" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, scratch, "{" ++ test_required_fields ++ "}", .{});
    var providers: std.json.Value = .{ .object = .empty };
    for (0..max_providers) |index| {
        try providers.object.put(scratch, try std.fmt.allocPrint(scratch, "local{d}", .{index}), parsed.value);
    }
    var registry = try Registry.parse(alloc, providers);
    registry.deinit(alloc);
    try providers.object.put(scratch, "overflow", parsed.value);
    try std.testing.expectError(error.LimitExceeded, Registry.parse(alloc, providers));

    var metadata: std.json.Value = .{ .object = .empty };
    for (0..max_models) |index| {
        try metadata.object.put(scratch, try std.fmt.allocPrint(scratch, "model/{d}", .{index}), .{ .object = .empty });
    }
    var definition = parsed.value;
    try definition.object.put(scratch, "model_metadata", metadata);
    var one: std.json.Value = .{ .object = .empty };
    try one.object.put(scratch, "local", definition);
    registry = try Registry.parse(alloc, one);
    registry.deinit(alloc);
    try metadata.object.put(scratch, "overflow", .{ .object = .empty });
    try definition.object.put(scratch, "model_metadata", metadata);
    try one.object.put(scratch, "local", definition);
    try std.testing.expectError(error.LimitExceeded, Registry.parse(alloc, one));

    const raw = try alloc.alloc(u8, max_json_bytes + 1);
    defer alloc.free(raw);
    @memset(raw, ' ');
    raw[0] = '{';
    raw[1] = '}';
    registry = try Registry.parse_json(alloc, raw[0..max_json_bytes]);
    registry.deinit(alloc);
    try std.testing.expectError(error.LimitExceeded, Registry.parse_json(alloc, raw));
    registry = try Registry.parse_json(alloc, "{}");
    registry.deinit(alloc);
    registry.deinit(alloc);
}

fn test_invalid_allocations(alloc: Allocator) !void {
    const json = "{\"first\":{" ++ test_required_fields ++ "},\"second\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"valid\":{},\"invalid\":{\"max_output_tokens\":0}}}}";
    var registry = Registry.parse_json(alloc, json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidModelMetadata => return,
        else => return err,
    };
    defer registry.deinit(alloc);
    return error.TestUnexpectedResult;
}

test "configured provider validation failures release earlier definitions and models" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, test_invalid_allocations, .{});
}
