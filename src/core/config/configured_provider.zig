const std = @import("std");
const request_fragment = @import("request_fragment.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const text_utils = @import("../shared/text_utils.zig");
const Allocator = std.mem.Allocator;

const max_providers = 32;
const max_models = 256;
pub const max_id_bytes = 64;
pub const max_model_bytes = 1024;
const max_url_bytes = 2048;
const max_env_bytes = 128;
const max_json_bytes = 1024 * 1024;
/// As many levels as fx offers for any model (`types.ReasoningEffort.max_options`).
pub const max_effort_levels = 16;
const max_effort_name_bytes = 64;
const max_headers = 16;
const max_header_name_bytes = 64;
/// One day: longer than any wait a person sits through, and it keeps every
/// bound far from overflow.
pub const max_timeout_ms = 24 * 60 * 60 * 1000;

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
    InvalidRequestFields,
    ReservedRequestField,
    InvalidEffortLevel,
    InvalidHeader,
    ReservedHeader,
    InvalidTimeout,
    InvalidConnectionOption,
};

pub const Protocol = enum {
    @"openai-chat-completions",
    @"openai-responses",
    @"anthropic-messages",

    /// Where a model request goes, after the connection's base URL.
    pub fn request_path(self: Protocol) []const u8 {
        return switch (self) {
            .@"openai-chat-completions" => "/chat/completions",
            .@"openai-responses" => "/responses",
            .@"anthropic-messages" => "/messages",
        };
    }

    /// The top-level request fields fx writes itself. A model's `request`
    /// fields and its effort levels cannot name one
    /// (`tests/tla/configured_provider/ConfiguredRequest.tla`
    /// OwnedKeysKeepFxValue). The reasoning controls are left out on purpose:
    /// an effort level is how a connection sets them.
    pub fn owned_request_fields(self: Protocol) []const []const u8 {
        return switch (self) {
            .@"openai-chat-completions" => &.{ "model", "messages", "stream", "stream_options", "tools", "tool_choice", "parallel_tool_calls", "max_tokens", "max_completion_tokens", "response_format" },
            .@"openai-responses" => &.{ "model", "input", "instructions", "stream", "store", "tools", "tool_choice", "parallel_tool_calls", "max_output_tokens", "include", "text" },
            .@"anthropic-messages" => &.{ "model", "messages", "system", "stream", "tools", "tool_choice", "max_tokens" },
        };
    }
};

pub const ToolChoiceMode = enum { omit, send };

/// The Chat Completions field that carries the output limit. Servers differ:
/// some read only one of the two and ignore the other without an error.
pub const OutputLimitField = enum { max_tokens, max_completion_tokens };

/// Describes a credential slot, never a credential value. Resolution belongs at
/// the effectful edge; `none` must omit Authorization rather than supply a token.
pub const Auth = union(enum) {
    none,
    bearer: []const u8,
};

/// A request header whose value is read from the environment variable `env`
/// when a request is sent. Like `Auth`, it never holds the value.
pub const Header = struct {
    name: []const u8,
    env: []const u8,
};

/// How long one request may wait. Null keeps fx's own bound for that wait
/// (`tests/tla/configured_provider/ConfiguredDeadlines.tla`).
pub const Timeouts = struct {
    connect_ms: ?u32 = null,
    first_response_ms: ?u32 = null,
    stall_ms: ?u32 = null,
};

/// One effort level a model offers, and the request fields that choose it.
pub const EffortLevel = struct {
    name: []const u8,
    fields: request_fragment.Fragment,
};

pub const ModelMetadata = struct {
    id: []const u8,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
    supports_tool_use: ?bool = null,
    supports_vision: ?bool = null,
    /// Chat Completions only. Null sends `max_tokens`.
    output_limit_field: ?OutputLimitField = null,
    /// Fields sent with every request for the model.
    request: ?request_fragment.Fragment = null,
    /// The levels fx offers for the model, in the settings' order. Null means
    /// the settings do not say; an empty list says the model has none.
    reasoning_efforts: ?[]const EffortLevel = null,

    pub fn effort(self: *const ModelMetadata, name: []const u8) ?*const EffortLevel {
        const levels = self.reasoning_efforts orelse return null;
        for (levels) |*level| {
            if (std.mem.eql(u8, level.name, name)) return level;
        }
        return null;
    }
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
    /// The model that names a session from its first prompt. Null: sessions
    /// on this connection keep the title derived from the prompt.
    title_model: ?[]const u8 = null,
    /// The model that reads images for a selected model that cannot. Null:
    /// the connection has no image fallback.
    vision_model: ?[]const u8 = null,
    headers: []const Header = &.{},
    timeouts: Timeouts = .{},
    /// Ask the server for its model list (`GET {base_url}/models`). Off unless
    /// the settings turn it on, so fx never probes a server on its own
    /// (`tests/tla/configured_provider/ConfiguredCatalog.tla` NoRequestWhenOff).
    fetch_models: bool = false,
    /// Metadata for every model on the connection that does not set a field
    /// itself, including one the settings do not declare. Its `id` is empty.
    model_defaults: ?ModelMetadata = null,
    model_metadata: []const ModelMetadata = &.{},

    /// Caller owns the returned URL. base_url is already a validated API prefix.
    pub fn chat_url(self: Definition, alloc: Allocator) Allocator.Error![]u8 {
        return std.mem.concat(alloc, u8, &.{ self.base_url, "/chat/completions" });
    }

    /// The URL model requests go to for the connection's protocol. Caller owns it.
    pub fn request_url(self: Definition, alloc: Allocator) Allocator.Error![]u8 {
        return std.mem.concat(alloc, u8, &.{ self.base_url, self.protocol.request_path() });
    }

    /// The URL of the server's model list. Caller owns it.
    pub fn models_url(self: Definition, alloc: Allocator) Allocator.Error![]u8 {
        return std.mem.concat(alloc, u8, &.{ self.base_url, "/models" });
    }

    /// Borrowed metadata; absence and unspecified fields remain unknown.
    pub fn model(self: Definition, id: []const u8) ?*const ModelMetadata {
        if (id.len > max_model_bytes) return null;
        for (self.model_metadata) |*metadata| {
            if (std.mem.eql(u8, metadata.id, id)) return metadata;
        }
        return null;
    }

    /// What the connection knows about `id`: the model's own metadata, with
    /// `model_defaults` for each field it leaves out. Null when the settings
    /// say nothing about the model. The result borrows `id` and the registry.
    pub fn metadata_for(self: Definition, id: []const u8) ?ModelMetadata {
        if (id.len > max_model_bytes) return null;
        const declared = self.model(id);
        const defaults = self.model_defaults orelse return if (declared) |metadata| metadata.* else null;
        var merged: ModelMetadata = if (declared) |metadata| metadata.* else .{ .id = id };
        inline for (@typeInfo(ModelMetadata).@"struct".field_names) |name| {
            if (comptime !std.mem.eql(u8, name, "id")) {
                if (@field(merged, name) == null) @field(merged, name) = @field(defaults, name);
            }
        }
        return merged;
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
};

pub const Registry = struct {
    definitions: []const Definition = &.{},
    /// Holds every slice the definitions point at. Null for an empty registry
    /// and for a view built from another registry's `definitions`.
    arena: ?*std.heap.ArenaAllocator = null,

    /// Parse the providers object itself, not the surrounding settings object.
    /// All returned storage is owned, independent of `providers`, and must be
    /// freed with deinit using the same allocator. Errors leave no owned state.
    /// PRECONDITION: the caller's JSON parser must reject duplicate keys at all
    /// depths (including providers in the enclosing settings). Value's ObjectMap
    /// cannot retain evidence of duplicates already discarded by another parser.
    pub fn parse(alloc: Allocator, providers: std.json.Value) ParseError!Registry {
        if (providers != .object) return error.InvalidObject;
        if (providers.object.count() > max_providers) return error.LimitExceeded;
        const arena = try alloc.create(std.heap.ArenaAllocator);
        arena.* = .init(alloc);
        errdefer {
            arena.deinit();
            alloc.destroy(arena);
        }
        const owned = arena.allocator();
        const definitions = try owned.alloc(Definition, providers.object.count());
        var iterator = providers.object.iterator();
        var index: usize = 0;
        while (iterator.next()) |entry| : (index += 1) {
            definitions[index] = try parse_definition(owned, entry.key_ptr.*, entry.value_ptr.*);
        }
        return .{ .definitions = definitions, .arena = arena };
    }

    /// Bounded, duplicate-rejecting convenience parser for a raw providers object.
    /// std.json.Value parses iteratively; input size also bounds nesting/work.
    /// The temporary JSON tree is released before returning the owned registry.
    /// A string longer than a URL may be, a request field's value included, is
    /// refused here.
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
        if (self.arena) |arena| {
            arena.deinit();
            alloc.destroy(arena);
        }
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

/// `owned` is the registry's arena: a failure frees nothing here.
fn parse_definition(owned: Allocator, id: []const u8, value: std.json.Value) ParseError!Definition {
    try validate_id(id);
    try check_fields(value, &.{ "protocol", "base_url", "auth", "tool_choice_mode", "reviewer_model", "title_model", "vision_model", "headers", "timeouts", "fetch_models", "model_defaults", "model_metadata" });
    const protocol_name = try required(value, "protocol");
    if (protocol_name != .string) return error.InvalidProtocol;
    const protocol = std.meta.stringToEnum(Protocol, protocol_name.string) orelse return error.InvalidProtocol;
    const url = try required(value, "base_url");
    if (url != .string) return error.InvalidBaseUrl;
    const normalized = try validate_url(url.string);
    const auth = try parse_auth(try required(value, "auth"));
    var mode: ToolChoiceMode = .omit;
    if (value.object.get("tool_choice_mode")) |choice| {
        if (choice != .string) return error.InvalidToolChoiceMode;
        mode = if (std.mem.eql(u8, choice.string, "omit")) .omit else if (std.mem.eql(u8, choice.string, "send")) .send else return error.InvalidToolChoiceMode;
    }
    var fetch_models = false;
    if (value.object.get("fetch_models")) |fetch| {
        if (fetch != .bool) return error.InvalidConnectionOption;
        fetch_models = fetch.bool;
    }
    return .{
        .id = try owned.dupe(u8, id),
        .protocol = protocol,
        .base_url = try owned.dupe(u8, normalized),
        .auth = switch (auth) {
            .none => .none,
            .bearer => |env| .{ .bearer = try owned.dupe(u8, env) },
        },
        .tool_choice_mode = mode,
        .reviewer_model = try optional_model(owned, value.object.get("reviewer_model")),
        .title_model = try optional_model(owned, value.object.get("title_model")),
        .vision_model = try optional_model(owned, value.object.get("vision_model")),
        .headers = if (value.object.get("headers")) |headers| try parse_headers(owned, headers) else &.{},
        .timeouts = if (value.object.get("timeouts")) |timeouts| try parse_timeouts(timeouts) else .{},
        .fetch_models = fetch_models,
        .model_defaults = if (value.object.get("model_defaults")) |defaults| try parse_model(owned, protocol, "", defaults) else null,
        .model_metadata = if (value.object.get("model_metadata")) |metadata| try parse_metadata(owned, protocol, metadata) else &.{},
    };
}

fn optional_model(owned: Allocator, value: ?std.json.Value) ParseError!?[]const u8 {
    const present = value orelse return null;
    if (present != .string) return error.InvalidModelId;
    try validate_model_id(present.string);
    return try owned.dupe(u8, present.string);
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
    return .{ .bearer = try environment_name(try required(value, "env")) };
}

/// The name of an environment variable, borrowed from `value`.
fn environment_name(value: std.json.Value) ParseError![]const u8 {
    if (value != .string) return error.InvalidEnvironmentName;
    const env = value.string;
    if (env.len > max_env_bytes) return error.LimitExceeded;
    if (env.len == 0 or (!std.ascii.isAlphabetic(env[0]) and env[0] != '_')) return error.InvalidEnvironmentName;
    for (env) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidEnvironmentName;
    }
    return env;
}

/// Headers fx sets on every request, or that the transport owns. `auth` is
/// how a connection sets Authorization.
const reserved_headers = [_][]const u8{ "authorization", "content-type", "content-length", "host", "accept", "accept-encoding", "user-agent", "connection", "transfer-encoding" };

fn parse_headers(owned: Allocator, value: std.json.Value) ParseError![]const Header {
    if (value != .object) return error.InvalidHeader;
    if (value.object.count() > max_headers) return error.LimitExceeded;
    const headers = try owned.alloc(Header, value.object.count());
    var iterator = value.object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        const name = entry.key_ptr.*;
        if (name.len > max_header_name_bytes) return error.LimitExceeded;
        if (name.len == 0) return error.InvalidHeader;
        for (name) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and std.mem.findScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return error.InvalidHeader;
        }
        for (reserved_headers) |reserved| {
            if (std.ascii.eqlIgnoreCase(name, reserved)) return error.ReservedHeader;
        }
        // Header names are case-insensitive, so two spellings are one header.
        for (headers[0..index]) |earlier| {
            if (std.ascii.eqlIgnoreCase(earlier.name, name)) return error.DuplicateField;
        }
        const slot = entry.value_ptr.*;
        if (slot != .object) return error.InvalidHeader;
        try check_fields(slot, &.{"env"});
        headers[index] = .{
            .name = try owned.dupe(u8, name),
            .env = try owned.dupe(u8, try environment_name(try required(slot, "env"))),
        };
    }
    return headers;
}

fn parse_timeouts(value: std.json.Value) ParseError!Timeouts {
    if (value != .object) return error.InvalidTimeout;
    try check_fields(value, &.{ "connect_ms", "first_response_ms", "stall_ms" });
    return .{
        .connect_ms = try timeout(value.object.get("connect_ms")),
        .first_response_ms = try timeout(value.object.get("first_response_ms")),
        .stall_ms = try timeout(value.object.get("stall_ms")),
    };
}

fn timeout(value: ?std.json.Value) ParseError!?u32 {
    const present = value orelse return null;
    if (present != .integer or present.integer <= 0 or present.integer > max_timeout_ms) return error.InvalidTimeout;
    return @intCast(present.integer);
}

fn parse_metadata(owned: Allocator, protocol: Protocol, value: std.json.Value) ParseError![]const ModelMetadata {
    if (value != .object) return error.InvalidObject;
    if (value.object.count() > max_models) return error.LimitExceeded;
    const models = try owned.alloc(ModelMetadata, value.object.count());
    var iterator = value.object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        try validate_model_id(entry.key_ptr.*);
        models[index] = try parse_model(owned, protocol, entry.key_ptr.*, entry.value_ptr.*);
    }
    return models;
}

fn parse_model(owned: Allocator, protocol: Protocol, id: []const u8, metadata: std.json.Value) ParseError!ModelMetadata {
    try check_fields(metadata, &.{ "context_window", "max_output_tokens", "supports_tool_use", "supports_vision", "output_limit_field", "request", "reasoning_efforts" });
    const context = try positive_limit(metadata.object.get("context_window"));
    const output = try positive_limit(metadata.object.get("max_output_tokens"));
    if (context != null and output != null and output.? >= context.?) return error.InvalidModelMetadata;
    var limit_field: ?OutputLimitField = null;
    if (metadata.object.get("output_limit_field")) |field| {
        // The other protocols each have one field for the limit.
        if (protocol != .@"openai-chat-completions" or field != .string) return error.InvalidModelMetadata;
        limit_field = std.meta.stringToEnum(OutputLimitField, field.string) orelse return error.InvalidModelMetadata;
    }
    const fx_fields = protocol.owned_request_fields();
    return .{
        .id = try owned.dupe(u8, id),
        .context_window = context,
        .max_output_tokens = output,
        .supports_tool_use = try optional_bool(metadata.object.get("supports_tool_use")),
        .supports_vision = try optional_bool(metadata.object.get("supports_vision")),
        .output_limit_field = limit_field,
        .request = if (metadata.object.get("request")) |fields| try request_fragment.parse(owned, fields, fx_fields) else null,
        .reasoning_efforts = if (metadata.object.get("reasoning_efforts")) |levels| try parse_efforts(owned, levels, fx_fields) else null,
    };
}

fn parse_efforts(owned: Allocator, value: std.json.Value, fx_fields: []const []const u8) ParseError![]const EffortLevel {
    if (value != .object) return error.InvalidEffortLevel;
    if (value.object.count() > max_effort_levels) return error.LimitExceeded;
    const levels = try owned.alloc(EffortLevel, value.object.count());
    var iterator = value.object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        try validate_effort_name(entry.key_ptr.*);
        levels[index] = .{
            .name = try owned.dupe(u8, entry.key_ptr.*),
            .fields = try request_fragment.parse(owned, entry.value_ptr.*, fx_fields),
        };
    }
    return levels;
}

/// A level's name follows the rule for an effort anywhere in fx
/// (`types.ReasoningEffort`), and is never one of the words for "no level".
fn validate_effort_name(name: []const u8) error{ LimitExceeded, InvalidEffortLevel }!void {
    if (name.len > max_effort_name_bytes) return error.LimitExceeded;
    if (name.len == 0) return error.InvalidEffortLevel;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return error.InvalidEffortLevel;
    }
    for ([_][]const u8{ "auto", "adaptive", "default" }) |unset| {
        if (std.ascii.eqlIgnoreCase(name, unset)) return error.InvalidEffortLevel;
    }
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
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, test_allocations, .{});
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
        const json = try alloc.print("{{\"local\":{{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://example.com\",\"auth\":{s}}}}}", .{case.json});
        defer alloc.free(json);
        try std.testing.expectError(case.err, Registry.parse_json(alloc, json));
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"type\":\"bearer\",\"env\":\"_key_2\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("_key_2", (try parse_auth(parsed.value)).bearer);
}

test "configured provider scalar bounds and minimum input budget" {
    try validate_id(text_utils.repeat("a", max_id_bytes));
    try validate_id("Local_2-test");
    try std.testing.expectError(error.LimitExceeded, validate_id(text_utils.repeat("a", max_id_bytes + 1)));
    try validate_model_id(text_utils.repeat("m", max_model_bytes));
    try validate_model_id("vendor/model:tag");
    try validate_model_id("model with internal spaces");
    try std.testing.expectError(error.InvalidModelId, validate_model_id(" leading"));
    try std.testing.expectError(error.InvalidModelId, validate_model_id("trailing "));
    try std.testing.expectError(error.LimitExceeded, validate_model_id(text_utils.repeat("m", max_model_bytes + 1)));
    try std.testing.expectError(error.InvalidModelId, validate_model_id("bad\xff"));
    const prefix = "https://example.com/";
    _ = try validate_url(prefix ++ text_utils.repeat("a", max_url_bytes - prefix.len));
    try std.testing.expectError(error.LimitExceeded, validate_url(prefix ++ text_utils.repeat("a", max_url_bytes - prefix.len + 1)));

    const alloc = std.testing.allocator;
    for ([_]usize{ max_env_bytes, max_env_bytes + 1 }) |length| {
        const env = text_utils.repeat("E", max_env_bytes + 1);
        const json = try alloc.print("{{\"local\":{{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://example.com\",\"auth\":{{\"type\":\"bearer\",\"env\":\"{s}\"}}}}}}", .{env[0..length]});
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
        try providers.object.put(scratch, try scratch.print("local{d}", .{index}), parsed.value);
    }
    var registry = try Registry.parse(alloc, providers);
    registry.deinit(alloc);
    try providers.object.put(scratch, "overflow", parsed.value);
    try std.testing.expectError(error.LimitExceeded, Registry.parse(alloc, providers));

    var metadata: std.json.Value = .{ .object = .empty };
    for (0..max_models) |index| {
        try metadata.object.put(scratch, try scratch.print("model/{d}", .{index}), .{ .object = .empty });
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
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, test_invalid_allocations, .{});
}

const test_options_json =
    \\{"router":{"protocol":"openai-chat-completions","base_url":"https://example.com/v1","auth":{"type":"bearer","env":"ROUTER_KEY"},
    \\"title_model":"small/title","vision_model":"small/vision","fetch_models":true,
    \\"headers":{"X-Org":{"env":"ROUTER_ORG"},"x-trace":{"env":"_TRACE"}},
    \\"timeouts":{"connect_ms":1,"first_response_ms":600000,"stall_ms":86400000},
    \\"model_defaults":{"context_window":65536,"supports_tool_use":true,"request":{"top_p":0.9},"reasoning_efforts":{"low":{"reasoning_effort":"low"}}},
    \\"model_metadata":{
    \\"thinker":{"max_output_tokens":4096,"output_limit_field":"max_completion_tokens","request":{"temperature":0.2},
    \\"reasoning_efforts":{"high":{"reasoning":{"effort":"high"}},"low":{"reasoning":{"effort":"low"}},"x-high.2":{}}},
    \\"plain":{"reasoning_efforts":{}}}}}
;

test "configured provider reads connection options, request fields, and effort levels in order" {
    var registry = try Registry.parse_json(std.testing.allocator, test_options_json);
    defer registry.deinit(std.testing.allocator);
    const router = registry.get("router").?;
    try std.testing.expectEqualStrings("small/title", router.title_model.?);
    try std.testing.expectEqualStrings("small/vision", router.vision_model.?);
    try std.testing.expect(router.fetch_models);
    try std.testing.expectEqual(@as(usize, 2), router.headers.len);
    try std.testing.expectEqualStrings("X-Org", router.headers[0].name);
    try std.testing.expectEqualStrings("ROUTER_ORG", router.headers[0].env);
    try std.testing.expectEqualStrings("_TRACE", router.headers[1].env);
    try std.testing.expectEqual(Timeouts{ .connect_ms = 1, .first_response_ms = 600_000, .stall_ms = max_timeout_ms }, router.timeouts);

    const thinker = router.model("thinker").?;
    try std.testing.expectEqual(@as(?OutputLimitField, .max_completion_tokens), thinker.output_limit_field);
    try std.testing.expectEqualStrings("temperature", thinker.request.?.fields[0].key);
    const levels = thinker.reasoning_efforts.?;
    try std.testing.expectEqual(@as(usize, 3), levels.len);
    for ([_][]const u8{ "high", "low", "x-high.2" }, levels) |name, level| try std.testing.expectEqualStrings(name, level.name);
    try std.testing.expectEqualStrings("{\"effort\":\"high\"}", thinker.effort("high").?.fields.fields[0].value_json);
    try std.testing.expectEqual(@as(usize, 0), thinker.effort("x-high.2").?.fields.fields.len);
    try std.testing.expect(thinker.effort("medium") == null);
    try std.testing.expect(thinker.effort("HIGH") == null);

    // A declared model keeps its own fields and takes the rest from the defaults.
    const merged = router.metadata_for("thinker").?;
    try std.testing.expectEqual(@as(?u32, 65536), merged.context_window);
    try std.testing.expectEqual(@as(?u32, 4096), merged.max_output_tokens);
    try std.testing.expectEqual(@as(?bool, true), merged.supports_tool_use);
    try std.testing.expect(merged.supports_vision == null);
    try std.testing.expectEqualStrings("temperature", merged.request.?.fields[0].key);
    try std.testing.expectEqual(@as(usize, 3), merged.reasoning_efforts.?.len);
    // "This model has no levels" is not the same as leaving the levels out.
    try std.testing.expectEqual(@as(usize, 0), router.metadata_for("plain").?.reasoning_efforts.?.len);
    // A model the settings do not declare gets the defaults.
    const served = router.metadata_for("served-by-the-server").?;
    try std.testing.expectEqualStrings("served-by-the-server", served.id);
    try std.testing.expectEqual(@as(?u32, 65536), served.context_window);
    try std.testing.expectEqualStrings("top_p", served.request.?.fields[0].key);
    try std.testing.expectEqualStrings("low", served.reasoning_efforts.?[0].name);
    try std.testing.expect(served.output_limit_field == null);

    for ([_]struct { protocol: []const u8, path: []const u8 }{
        .{ .protocol = "openai-chat-completions", .path = "/chat/completions" },
        .{ .protocol = "openai-responses", .path = "/responses" },
        .{ .protocol = "anthropic-messages", .path = "/messages" },
    }) |case| {
        const json = try std.testing.allocator.print("{{\"c\":{{\"protocol\":\"{s}\",\"base_url\":\"https://example.com/v1/\",\"auth\":{{\"type\":\"none\"}}}}}}", .{case.protocol});
        defer std.testing.allocator.free(json);
        var one = try Registry.parse_json(std.testing.allocator, json);
        defer one.deinit(std.testing.allocator);
        const definition = one.get("c").?;
        try std.testing.expectEqualStrings(case.protocol, @tagName(definition.protocol));
        const url = try definition.request_url(std.testing.allocator);
        defer std.testing.allocator.free(url);
        try std.testing.expectEqualStrings(case.path, url["https://example.com/v1".len..]);
        const models = try definition.models_url(std.testing.allocator);
        defer std.testing.allocator.free(models);
        try std.testing.expectEqualStrings("https://example.com/v1/models", models);
        try std.testing.expect(!definition.fetch_models);
        try std.testing.expect(definition.metadata_for("anything") == null);
        try std.testing.expect(definition.title_model == null and definition.vision_model == null);
        try std.testing.expectEqual(Timeouts{}, definition.timeouts);
    }
}

test "configured provider connection options do not change a connection's identity, and its protocol does" {
    const alloc = std.testing.allocator;
    var plain = try Registry.parse_json(alloc, "{\"router\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"https://example.com/v1\",\"auth\":{\"type\":\"bearer\",\"env\":\"ROUTER_KEY\"}}}");
    defer plain.deinit(alloc);
    var options = try Registry.parse_json(alloc, test_options_json);
    defer options.deinit(alloc);
    const identity = plain.get("router").?.binding_identity();
    // A session saved before the options existed still resumes.
    try std.testing.expectEqual(identity, options.get("router").?.binding_identity());
    var other = plain.get("router").?.*;
    other.protocol = .@"openai-responses";
    try std.testing.expect(!std.mem.eql(u8, &identity, &other.binding_identity()));
}

test "configured provider refuses fx's own fields and headers, and malformed options" {
    const cases = [_]struct { json: []const u8, err: ParseError }{
        .{ .json = "\"model_metadata\":{\"m\":{\"request\":{\"messages\":[]}}}", .err = error.ReservedRequestField },
        .{ .json = "\"model_metadata\":{\"m\":{\"request\":{\"max_tokens\":1}}}", .err = error.ReservedRequestField },
        .{ .json = "\"model_metadata\":{\"m\":{\"request\":{\"max_completion_tokens\":1}}}", .err = error.ReservedRequestField },
        .{ .json = "\"model_metadata\":{\"m\":{\"reasoning_efforts\":{\"high\":{\"model\":\"other\"}}}}", .err = error.ReservedRequestField },
        .{ .json = "\"model_defaults\":{\"request\":{\"stream\":false}}", .err = error.ReservedRequestField },
        .{ .json = "\"model_metadata\":{\"m\":{\"request\":[]}}", .err = error.InvalidRequestFields },
        .{ .json = "\"model_metadata\":{\"m\":{\"request\":null}}", .err = error.InvalidRequestFields },
        .{ .json = "\"model_metadata\":{\"m\":{\"reasoning_efforts\":{\"high\":\"high\"}}}", .err = error.InvalidRequestFields },
        .{ .json = "\"model_metadata\":{\"m\":{\"reasoning_efforts\":[\"low\",\"high\"]}}", .err = error.InvalidEffortLevel },
        .{ .json = "\"model_metadata\":{\"m\":{\"reasoning_efforts\":{\"\":{}}}}", .err = error.InvalidEffortLevel },
        .{ .json = "\"model_metadata\":{\"m\":{\"reasoning_efforts\":{\"very high\":{}}}}", .err = error.InvalidEffortLevel },
        .{ .json = "\"model_metadata\":{\"m\":{\"reasoning_efforts\":{\"auto\":{}}}}", .err = error.InvalidEffortLevel },
        .{ .json = "\"model_metadata\":{\"m\":{\"reasoning_efforts\":{\"Default\":{}}}}", .err = error.InvalidEffortLevel },
        .{ .json = "\"model_metadata\":{\"m\":{\"reasoning_efforts\":{\"" ++ text_utils.repeat("e", max_effort_name_bytes + 1) ++ "\":{}}}}", .err = error.LimitExceeded },
        .{ .json = "\"model_metadata\":{\"m\":{\"output_limit_field\":\"max_output_tokens\"}}", .err = error.InvalidModelMetadata },
        .{ .json = "\"model_metadata\":{\"m\":{\"output_limit_field\":true}}", .err = error.InvalidModelMetadata },
        .{ .json = "\"model_defaults\":[]", .err = error.InvalidObject },
        .{ .json = "\"model_defaults\":{\"context_window\":2,\"max_output_tokens\":2}", .err = error.InvalidModelMetadata },
        .{ .json = "\"model_defaults\":{\"id\":\"m\"}", .err = error.UnknownField },
        .{ .json = "\"headers\":{\"Authorization\":{\"env\":\"KEY\"}}", .err = error.ReservedHeader },
        .{ .json = "\"headers\":{\"content-TYPE\":{\"env\":\"KEY\"}}", .err = error.ReservedHeader },
        .{ .json = "\"headers\":{\"Host\":{\"env\":\"KEY\"}}", .err = error.ReservedHeader },
        .{ .json = "\"headers\":{\"X-Org\":{\"env\":\"A\"},\"x-org\":{\"env\":\"B\"}}", .err = error.DuplicateField },
        .{ .json = "\"headers\":{\"X Org\":{\"env\":\"KEY\"}}", .err = error.InvalidHeader },
        .{ .json = "\"headers\":{\"X-Org:\":{\"env\":\"KEY\"}}", .err = error.InvalidHeader },
        .{ .json = "\"headers\":{\"\":{\"env\":\"KEY\"}}", .err = error.InvalidHeader },
        .{ .json = "\"headers\":{\"X-Org\":\"literal-value\"}", .err = error.InvalidHeader },
        .{ .json = "\"headers\":[]", .err = error.InvalidHeader },
        .{ .json = "\"headers\":{\"X-Org\":{}}", .err = error.MissingField },
        .{ .json = "\"headers\":{\"X-Org\":{\"env\":\"KEY\",\"value\":\"literal\"}}", .err = error.UnknownField },
        .{ .json = "\"headers\":{\"X-Org\":{\"env\":\"1KEY\"}}", .err = error.InvalidEnvironmentName },
        .{ .json = "\"headers\":{\"" ++ text_utils.repeat("h", max_header_name_bytes + 1) ++ "\":{\"env\":\"KEY\"}}", .err = error.LimitExceeded },
        .{ .json = "\"timeouts\":{\"connect_ms\":0}", .err = error.InvalidTimeout },
        .{ .json = "\"timeouts\":{\"first_response_ms\":-1}", .err = error.InvalidTimeout },
        .{ .json = "\"timeouts\":{\"stall_ms\":86400001}", .err = error.InvalidTimeout },
        .{ .json = "\"timeouts\":{\"stall_ms\":1.5}", .err = error.InvalidTimeout },
        .{ .json = "\"timeouts\":{\"stall_ms\":\"30s\"}", .err = error.InvalidTimeout },
        .{ .json = "\"timeouts\":{\"stall_ms\":null}", .err = error.InvalidTimeout },
        .{ .json = "\"timeouts\":300", .err = error.InvalidTimeout },
        .{ .json = "\"timeouts\":{\"total_ms\":1}", .err = error.UnknownField },
        .{ .json = "\"fetch_models\":\"yes\"", .err = error.InvalidConnectionOption },
        .{ .json = "\"fetch_models\":null", .err = error.InvalidConnectionOption },
        .{ .json = "\"title_model\":\"\"", .err = error.InvalidModelId },
        .{ .json = "\"vision_model\":7", .err = error.InvalidModelId },
    };
    for (cases) |case| {
        const json = "{\"local\":{" ++ test_required_fields ++ ",";
        const whole = try std.mem.concat(std.testing.allocator, u8, &.{ json, case.json, "}}" });
        defer std.testing.allocator.free(whole);
        std.testing.expectError(case.err, Registry.parse_json(std.testing.allocator, whole)) catch |err| {
            std.debug.print("case: {s}\n", .{case.json});
            return err;
        };
    }

    // Each protocol keeps its own fields, and only Chat Completions has two
    // names for the output limit.
    const per_protocol = [_]struct { protocol: []const u8, fragment: []const u8, err: ?ParseError }{
        .{ .protocol = "openai-chat-completions", .fragment = "\"request\":{\"input\":1,\"system\":2,\"max_output_tokens\":3,\"reasoning\":{},\"thinking\":{}}", .err = null },
        .{ .protocol = "openai-responses", .fragment = "\"request\":{\"input\":1}", .err = error.ReservedRequestField },
        .{ .protocol = "openai-responses", .fragment = "\"request\":{\"max_output_tokens\":1}", .err = error.ReservedRequestField },
        .{ .protocol = "openai-responses", .fragment = "\"request\":{\"messages\":1,\"max_tokens\":2,\"reasoning\":{\"effort\":\"low\"}}", .err = null },
        .{ .protocol = "openai-responses", .fragment = "\"output_limit_field\":\"max_tokens\"", .err = error.InvalidModelMetadata },
        .{ .protocol = "anthropic-messages", .fragment = "\"request\":{\"system\":\"x\"}", .err = error.ReservedRequestField },
        .{ .protocol = "anthropic-messages", .fragment = "\"request\":{\"max_tokens\":1}", .err = error.ReservedRequestField },
        .{ .protocol = "anthropic-messages", .fragment = "\"request\":{\"input\":1,\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":1024}}", .err = null },
        .{ .protocol = "anthropic-messages", .fragment = "\"output_limit_field\":\"max_tokens\"", .err = error.InvalidModelMetadata },
    };
    for (per_protocol) |case| {
        const json = try std.testing.allocator.print("{{\"c\":{{\"protocol\":\"{s}\",\"base_url\":\"https://example.com\",\"auth\":{{\"type\":\"none\"}},\"model_metadata\":{{\"m\":{{{s}}}}}}}}}", .{ case.protocol, case.fragment });
        defer std.testing.allocator.free(json);
        if (case.err) |err| {
            try std.testing.expectError(err, Registry.parse_json(std.testing.allocator, json));
        } else {
            var registry = try Registry.parse_json(std.testing.allocator, json);
            registry.deinit(std.testing.allocator);
        }
    }
}

test "configured provider takes sixteen effort levels and sixteen headers, and one more of neither" {
    const alloc = std.testing.allocator;
    for ([_]usize{ max_effort_levels, max_effort_levels + 1 }) |count| {
        var levels: std.ArrayList(u8) = .empty;
        defer levels.deinit(alloc);
        var headers: std.ArrayList(u8) = .empty;
        defer headers.deinit(alloc);
        for (0..count) |index| {
            try levels.print(alloc, "{s}\"level{d}\":{{\"reasoning_effort\":\"level{d}\"}}", .{ if (index == 0) "" else ",", index, index });
            try headers.print(alloc, "{s}\"X-H{d}\":{{\"env\":\"H{d}\"}}", .{ if (index == 0) "" else ",", index, index });
        }
        for ([_][]const u8{
            try alloc.print("\"model_metadata\":{{\"m\":{{\"reasoning_efforts\":{{{s}}}}}}}", .{levels.items}),
            try alloc.print("\"headers\":{{{s}}}", .{headers.items}),
        }) |option| {
            defer alloc.free(option);
            const json = try std.mem.concat(alloc, u8, &.{ "{\"local\":{" ++ test_required_fields ++ ",", option, "}}" });
            defer alloc.free(json);
            if (count == max_effort_levels) {
                var registry = try Registry.parse_json(alloc, json);
                defer registry.deinit(alloc);
                const local = registry.get("local").?;
                const listed = if (local.model("m")) |m| m.reasoning_efforts.?.len else local.headers.len;
                try std.testing.expectEqual(count, listed);
            } else try std.testing.expectError(error.LimitExceeded, Registry.parse_json(alloc, json));
        }
    }
}

fn test_option_allocations(alloc: Allocator) !void {
    var registry = try Registry.parse_json(alloc, test_options_json);
    defer registry.deinit(alloc);
    const url = try registry.get("router").?.request_url(alloc);
    defer alloc.free(url);
    const invalid = "{\"first\":{" ++ test_required_fields ++ ",\"headers\":{\"X-A\":{\"env\":\"A\"}},\"model_metadata\":{\"m\":{\"request\":{\"a\":[1,{\"b\":2}]},\"reasoning_efforts\":{\"low\":{\"c\":1},\"high\":{\"model\":2}}}}}}";
    if (Registry.parse_json(alloc, invalid)) |parsed| {
        var unexpected = parsed;
        unexpected.deinit(alloc);
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.ReservedRequestField => {},
        else => return err,
    }
}

test "configured provider options release everything on any allocation failure" {
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, test_option_allocations, .{});
}

test "configured provider settings parse or are refused on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzDefinition, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{\"local\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"http://127.0.0.1:11434/v1\",\"auth\":{\"type\":\"none\"}}}",
            test_options_json,
            "{\"a\":{\"protocol\":\"anthropic-messages\",\"base_url\":\"https://example.com/v1\",\"auth\":{\"type\":\"none\"},\"headers\":{\"x-api-key\":{\"env\":\"KEY\"}},\"model_metadata\":{\"m\":{\"reasoning_efforts\":{\"high\":{\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":2048}}}}}}}",
            "{\"r\":{\"protocol\":\"openai-responses\",\"base_url\":\"https://example.com/v1\",\"auth\":{\"type\":\"none\"},\"model_metadata\":{\"m\":{\"request\":{\"input\":1}}}}}",
            "{\"local\":{\"protocol\":\"openai-chat-completions\",\"base_url\":\"http://127.0.0.1:1/v1\",\"auth\":{\"type\":\"none\"},\"timeouts\":{\"stall_ms\":0}}}",
            "\xff\x00{",
        }) ++ @import("fuzz_corpus").configured_provider_definition.*),
    });
}

/// Whatever bytes the settings hold, the parser refuses them or returns a
/// registry that keeps its own limits: no fragment names a field fx writes
/// for the connection's protocol, and no model offers more levels than fx can.
fn fuzzDefinition(_: void, smith: *std.testing.Smith) anyerror!void {
    const alloc = std.testing.allocator;
    var buffer: [4096]u8 = undefined;
    const json = buffer[0..@intCast(smith.slice(&buffer))];
    var registry = Registry.parse_json(alloc, json) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer registry.deinit(alloc);
    for (registry.definitions) |definition| {
        const owned = definition.protocol.owned_request_fields();
        if (definition.model_defaults) |defaults| try expectWithinLimits(defaults, owned);
        for (definition.model_metadata) |metadata| {
            try expectWithinLimits(metadata, owned);
            try std.testing.expect(definition.metadata_for(metadata.id) != null);
        }
        try std.testing.expect(definition.headers.len <= max_headers);
        _ = definition.binding_identity();
    }
}

fn expectWithinLimits(metadata: ModelMetadata, owned: []const []const u8) !void {
    for (owned) |name| {
        if (metadata.request) |fields| try std.testing.expect(!fields.has(name));
        for (metadata.reasoning_efforts orelse &.{}) |level| try std.testing.expect(!level.fields.has(name));
    }
    if (metadata.reasoning_efforts) |levels| try std.testing.expect(levels.len <= max_effort_levels);
}

test "a model's request fields and effort levels reach the body as valid JSON on fuzzed settings" {
    try std.testing.fuzz({}, fuzzFragments, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{\"temperature\":0.2,\"top_p\":0.9}\x00{\"reasoning_effort\":\"high\",\"temperature\":0.7}",
            "{\"temperature\":0.2}\x00{\"reasoning\":{\"effort\":\"high\"},\"temperature\":0.7}",
            "{\"metadata\":{\"user_id\":\"u\"}}\x00{\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":2048}}",
            "{\"options\":{\"num_ctx\":[1,2,{\"a\":null}]},\"stop\":[\"\\n\"]}",
            "{\"model\":\"x\"}\x00{}",
            "[]\x00{\"a\":1}",
        }) ++ @import("fuzz_corpus").configured_request_fragments.*),
    });
}

/// Two fragments from arbitrary bytes, the model's and a level's, split at
/// the first NUL, written after fx's own fields: the body stays one valid
/// JSON object, every field fx writes keeps fx's value, and a field both set
/// carries the level's value
/// (`tests/tla/configured_provider/ConfiguredRequest.tla` OwnedKeysKeepFxValue,
/// LevelBeatsRequest). The input's length picks the protocol whose fields fx owns.
fn fuzzFragments(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: [2048]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    const protocols = std.enums.values(Protocol);
    const owned = protocols[bytes.len % protocols.len].owned_request_fields();
    const split = std.mem.findScalar(u8, bytes, 0);
    const request = fuzzFragment(arena, if (split) |at| bytes[0..at] else bytes, owned) orelse return;
    const level = fuzzFragment(arena, if (split) |at| bytes[at + 1 ..] else "{}", owned) orelse return;

    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("{\"model\":\"fx-model\",\"stream\":true");
    try request_fragment.write(&out.writer, request, level);
    try out.writer.writeByte('}');
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, out.written(), .{ .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    const body = parsed.value.object;
    try std.testing.expectEqualStrings("fx-model", body.get("model").?.string);
    try std.testing.expect(body.get("stream").?.bool);
    for (level.fields) |field| {
        var expected = try std.json.parseFromSlice(std.json.Value, arena, field.value_json, .{});
        defer expected.deinit();
        var sent: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(body.get(field.key).?, .{}, &sent.writer);
        var wanted: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(expected.value, .{}, &wanted.writer);
        try std.testing.expectEqualStrings(wanted.written(), sent.written());
    }
}

/// A fragment parsed from `bytes`, or null when the settings would refuse it.
fn fuzzFragment(arena: Allocator, bytes: []const u8, owned: []const []const u8) ?request_fragment.Fragment {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .duplicate_field_behavior = .@"error", .max_value_len = max_url_bytes }) catch return null;
    return request_fragment.parse(arena, value, owned) catch null;
}
