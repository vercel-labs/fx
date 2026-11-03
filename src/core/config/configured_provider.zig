const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const tokenizer = @import("../tokenizer/tokenizer.zig");
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
    InvalidHeader,
    InvalidCommand,
};

pub const Protocol = enum { @"openai-chat-completions", @"anthropic-messages", @"openai-responses", @"google-generative-ai" };
/// How a Chat Completions endpoint takes a reasoning effort: not at all,
/// OpenRouter's `reasoning` object, or OpenAI's `reasoning_effort` (D146).
pub const ReasoningFormat = enum { none, openrouter, openai };
/// Where a definition's model list comes from: only what it declares, or
/// also OpenRouter's public catalog, fetched and cached (D146).
pub const CatalogSource = enum { declared, openrouter };
pub const Discovery = struct {
    type: enum { ollama, @"llama.cpp", @"lm-studio", @"openai-models-list", proxy, litellm },
    timeout_ms: u32 = 10_000,
    inject_v1: bool = true,
};
/// An extra request header. A value starting with `!` is a command whose
/// trimmed output is the value; `!!` escapes a literal `!` (D148).
pub const Header = struct { name: []const u8, value: []const u8 };
/// Where the credential goes: `Authorization: Bearer` or Anthropic's
/// `x-api-key`, which only the Messages protocol accepts.
pub const KeyHeader = enum { authorization, x_api_key };
/// How a Messages model turns thinking on: a token budget, or adaptive
/// thinking with an effort level.
pub const ThinkingMode = enum { budget, adaptive };
pub const ToolChoiceMode = enum { omit, send };

/// Describes a credential slot, never a credential value. Resolution belongs at
/// the effectful edge; `none` must omit Authorization rather than supply a token.
pub const Auth = union(enum) {
    none,
    /// The environment variable holding the key.
    bearer: []const u8,
    /// A `!command` whose trimmed output is the key; run without a shell.
    command: []const u8,
    /// The key `/login` saved for this provider, else this environment variable.
    login: []const u8,
};

/// Prices per million tokens, matching the model picker and provider catalogs.
pub const ModelCost = struct {
    input: f64 = 0,
    output: f64 = 0,
    cache_read: f64 = 0,
    cache_write: f64 = 0,
};

pub const RemoteCompaction = struct {
    enabled: bool = true,
    protocol: ?Protocol = null,
    endpoint: ?[]const u8 = null,
    model: ?[]const u8 = null,
    v2_streaming_enabled: bool = false,
    v2_endpoint: ?[]const u8 = null,
    streaming_endpoint: ?[]const u8 = null,
};

pub const ModelMetadata = struct {
    id: []const u8,
    /// Set only for parsed overrides, so explicit false/zero values still win.
    fields: []const []const u8 = &.{},
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    cost: ?ModelCost = null,
    intelligence: ?f64 = null,
    recommended: bool = false,
    beta: bool = false,
    released: i64 = 0,
    base_url: ?[]const u8 = null,
    headers: []const Header = &.{},
    max_context_window: ?u32 = null,
    omit_max_output_tokens: bool = false,
    prefer_websockets: ?bool = null,
    tokenizer: ?[]const u8 = null,
    context_promotion_target: ?[]const u8 = null,
    compaction_model: ?[]const u8 = null,
    remote_compaction: ?RemoteCompaction = null,
    compat: @import("model_compatibility.zig").Compatibility = .{},
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
    supports_tool_use: ?bool = null,
    supports_vision: ?bool = null,
    /// Owned. Empty means the model takes no reasoning effort.
    reasoning_efforts: []const types.ReasoningEffort = &.{},
    thinking: ?ThinkingMode = null,
    /// The wire protocol for this model when it differs from the provider's.
    protocol: ?Protocol = null,
};

/// Registry owns all slices. Treat definitions as immutable while borrowed by
/// requests; destroying the registry invalidates every definition and lookup.
pub const Definition = struct {
    id: []const u8,
    protocol: Protocol,
    base_url: []const u8,
    auth: Auth,
    key_header: KeyHeader = .authorization,
    tool_choice_mode: ToolChoiceMode = .omit,
    reviewer_model: ?[]const u8 = null,
    model_metadata: []const ModelMetadata = &.{},
    /// Owns parsed model metadata; preset model tables remain borrowed.
    model_storage: ?std.heap.ArenaAllocator = null,
    /// Original, owned config for profile patches; never used as a transport.
    source: ?std.json.Value = null,
    model_defaults: ?*const ModelMetadata = null,
    discovery: ?Discovery = null,
    headers: []const Header = &.{},
    reasoning_format: ReasoningFormat = .none,
    /// The model a first switch to this provider selects.
    default_model: ?[]const u8 = null,
    catalog: CatalogSource = .declared,
    /// Static models a built-in preset ships; borrowed, never freed, and
    /// shadowed by `model_metadata` entries with the same id.
    builtin_models: []const ModelMetadata = &.{},
    /// Built in rather than written by the user (D145).
    preset: bool = false,

    /// The model's endpoint override, otherwise the provider's endpoint.
    pub fn baseUrlFor(self: Definition, model_id: []const u8) []const u8 {
        const metadata = self.model(model_id) orelse return self.base_url;
        return metadata.base_url orelse self.base_url;
    }

    /// Caller owns the returned URL. base_url is already a validated API prefix.
    pub fn chat_url(self: Definition, alloc: Allocator, model_id: []const u8) Allocator.Error![]u8 {
        return std.mem.concat(alloc, u8, &.{ self.baseUrlFor(model_id), "/chat/completions" });
    }

    /// Caller owns the returned URL.
    pub fn messages_url(self: Definition, alloc: Allocator, model_id: []const u8) Allocator.Error![]u8 {
        return std.mem.concat(alloc, u8, &.{ self.baseUrlFor(model_id), "/messages" });
    }

    /// Caller owns the returned URL.
    pub fn responses_url(self: Definition, alloc: Allocator, model_id: []const u8) Allocator.Error![]u8 {
        return std.mem.concat(alloc, u8, &.{ self.baseUrlFor(model_id), "/responses" });
    }

    /// Borrowed metadata; absence and unspecified fields remain unknown.
    pub fn model(self: Definition, id: []const u8) ?*const ModelMetadata {
        if (id.len > max_model_bytes) return null;
        for (self.model_metadata) |*metadata| {
            if (std.mem.eql(u8, metadata.id, id)) return metadata;
        }
        for (self.builtin_models) |*metadata| {
            if (std.mem.eql(u8, metadata.id, id)) return metadata;
        }
        return self.model_defaults;
    }

    /// The wire protocol `id` is sent with.
    pub fn protocolFor(self: Definition, id: []const u8) Protocol {
        const metadata = self.model(id) orelse return self.protocol;
        return metadata.protocol orelse self.protocol;
    }

    /// Whether any model is sent with a protocol other than the provider's.
    pub fn mixed(self: Definition) bool {
        for ([_][]const ModelMetadata{ self.model_metadata, self.builtin_models }) |list| {
            for (list) |metadata| if (metadata.protocol) |protocol| if (protocol != self.protocol) return true;
        }
        return false;
    }

    /// The credential slot's environment variable, if it has one.
    pub fn keyEnv(self: Definition) ?[]const u8 {
        return switch (self.auth) {
            .bearer, .login => |env| if (env.len == 0) null else env,
            .none, .command => null,
        };
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
            .bearer, .command, .login => |text| hash_part(&hash, text),
        }
        // Hashed only when set, so existing bearer bindings keep their identity.
        if (self.key_header == .x_api_key) hash_part(&hash, "x-api-key");
        for (self.headers) |header| hash_part(&hash, header.name);
        return hash.finalResult();
    }

    pub fn deinit(self: Definition, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.base_url);
        switch (self.auth) {
            .none => {},
            .bearer, .command, .login => |text| alloc.free(text),
        }
        if (self.reviewer_model) |id| alloc.free(id);
        if (self.default_model) |id| alloc.free(id);
        for (self.headers) |header| {
            alloc.free(header.name);
            alloc.free(header.value);
        }
        alloc.free(self.headers);
        if (self.model_storage) |storage| {
            var owned = storage;
            owned.deinit();
        }
    }
};

/// Native providers keep their transport/auth identity. This is only policy.
pub const NativeOverrides = struct {
    id: []const u8,
    default_model: ?[]const u8 = null,
    reviewer_model: ?[]const u8 = null,
    model_metadata: []const ModelMetadata = &.{},
    defaults: ?*const ModelMetadata = null,
    storage: std.heap.ArenaAllocator,

    pub fn model(self: NativeOverrides, id: []const u8) ?*const ModelMetadata {
        for (self.model_metadata) |*metadata| if (std.mem.eql(u8, metadata.id, id)) return metadata;
        return self.defaults;
    }

    pub fn deinit(self: NativeOverrides) void {
        var storage = self.storage;
        storage.deinit();
    }
};

pub const Registry = struct {
    definitions: []const Definition = &.{},
    native_overrides: []const NativeOverrides = &.{},

    pub fn native(self: Registry, id: []const u8) ?*const NativeOverrides {
        for (self.native_overrides) |*overrides| if (std.mem.eql(u8, overrides.id, id)) return overrides;
        return null;
    }

    pub fn model(self: Registry, provider: []const u8, id: []const u8) ?*const ModelMetadata {
        if (self.native(provider)) |overrides| return overrides.model(id);
        if (self.get(provider)) |definition| return definition.model(id);
        return null;
    }

    /// Takes ownership on success and failure, like put.
    pub fn putNative(self: *Registry, alloc: Allocator, overrides: NativeOverrides) Allocator.Error!void {
        for (self.native_overrides, 0..) |existing, index| {
            if (!std.mem.eql(u8, existing.id, overrides.id)) continue;
            existing.deinit();
            @constCast(self.native_overrides)[index] = overrides;
            return;
        }
        const grown = alloc.alloc(NativeOverrides, self.native_overrides.len + 1) catch |err| {
            overrides.deinit();
            return err;
        };
        @memcpy(grown[0..self.native_overrides.len], self.native_overrides);
        grown[self.native_overrides.len] = overrides;
        alloc.free(self.native_overrides);
        self.native_overrides = grown;
    }

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
        for (self.native_overrides) |overrides| overrides.deinit();
        alloc.free(self.native_overrides);
        self.* = .{};
    }

    /// Adds `definition`, replacing one with the same id. Takes ownership of
    /// `definition` on success and on failure.
    pub fn put(self: *Registry, alloc: Allocator, definition: Definition) Allocator.Error!void {
        for (self.definitions, 0..) |existing, index| {
            if (!std.mem.eql(u8, existing.id, definition.id)) continue;
            existing.deinit(alloc);
            @constCast(self.definitions)[index] = definition;
            return;
        }
        const grown = alloc.alloc(Definition, self.definitions.len + 1) catch |err| {
            definition.deinit(alloc);
            return err;
        };
        @memcpy(grown[0..self.definitions.len], self.definitions);
        grown[self.definitions.len] = definition;
        alloc.free(self.definitions);
        self.definitions = grown;
    }

    /// How many definitions the user wrote, leaving out built-in presets.
    pub fn userCount(self: Registry) usize {
        var count: usize = 0;
        for (self.definitions) |definition| count += @intFromBool(!definition.preset);
        return count;
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

/// Parses one definition. All returned storage is owned by `alloc`.
pub fn parse_definition(alloc: Allocator, id: []const u8, value: std.json.Value) ParseError!Definition {
    try validate_id(id);
    try check_fields(value, &.{ "protocol", "base_url", "auth", "tool_choice_mode", "reviewer_model", "model_metadata", "headers", "reasoning_format", "default_model", "defaults", "compat", "remote_compaction", "discovery" });
    const protocol = try required(value, "protocol");
    if (protocol != .string) return error.InvalidProtocol;
    const kind = std.meta.stringToEnum(Protocol, protocol.string) orelse return error.InvalidProtocol;
    const url = try required(value, "base_url");
    if (url != .string) return error.InvalidBaseUrl;
    const normalized = try validate_url(url.string);
    const auth_value = try required(value, "auth");
    const auth = try parse_auth(auth_value);
    // A login key names its Messages header explicitly; `x-api-key` implies it.
    const header_value = auth_value.object.get("header");
    const key_header: KeyHeader = if (auth_value.object.get("type").?.string[0] == 'x' or
        (header_value != null and std.mem.eql(u8, header_value.?.string, "x-api-key"))) .x_api_key else .authorization;
    var mode: ToolChoiceMode = .omit;
    if (value.object.get("tool_choice_mode")) |choice| {
        if (choice != .string) return error.InvalidToolChoiceMode;
        mode = if (std.mem.eql(u8, choice.string, "omit")) .omit else if (std.mem.eql(u8, choice.string, "send")) .send else return error.InvalidToolChoiceMode;
    }
    var reasoning_format: ReasoningFormat = .none;
    if (value.object.get("reasoning_format")) |format| {
        if (format != .string) return error.InvalidObject;
        reasoning_format = std.meta.stringToEnum(ReasoningFormat, format.string) orelse return error.InvalidObject;
    }
    const reviewer = try optional_model(value.object.get("reviewer_model"));
    const default_model = try optional_model(value.object.get("default_model"));

    var definition: Definition = .{
        .id = try alloc.dupe(u8, id),
        .protocol = kind,
        .key_header = key_header,
        .base_url = &.{},
        .auth = .none,
        .tool_choice_mode = mode,
        .reasoning_format = reasoning_format,
    };
    errdefer definition.deinit(alloc);
    definition.base_url = try alloc.dupe(u8, normalized);
    definition.auth = switch (auth) {
        .none => .none,
        .bearer => |text| .{ .bearer = try alloc.dupe(u8, text) },
        .command => |text| .{ .command = try alloc.dupe(u8, text) },
        .login => |text| .{ .login = try alloc.dupe(u8, text) },
    };
    if (reviewer) |model_id| definition.reviewer_model = try alloc.dupe(u8, model_id);
    if (default_model) |model_id| definition.default_model = try alloc.dupe(u8, model_id);
    if (value.object.get("headers")) |headers| definition.headers = try parse_headers(alloc, headers);
    definition.model_storage = .init(alloc);
    const arena = definition.model_storage.?.allocator();
    const source_json = try std.json.Stringify.valueAlloc(arena, value, .{});
    definition.source = std.json.parseFromSliceLeaky(std.json.Value, arena, source_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidObject,
    };
    const policy = try parsePolicy(arena, value, kind, reasoning_format);
    definition.model_metadata = policy.models;
    definition.model_defaults = policy.defaults;
    if (value.object.get("discovery")) |discovery| {
        if (kind != .@"openai-chat-completions" and kind != .@"openai-responses") return error.InvalidProtocol;
        try check_fields(discovery, &.{ "type", "timeout_ms", "inject_v1" });
        definition.discovery = try metadataValue(?Discovery, arena, value, "discovery", null);
        if (definition.discovery.?.timeout_ms == 0) return error.InvalidModelMetadata;
        if (discovery.object.contains("inject_v1") and definition.discovery.?.type != .@"openai-models-list") return error.UnknownField;
    }
    // Only the Messages transport has a separate key header.
    if (auth_value.object.get("type").?.string[0] == 'x' and kind != .@"anthropic-messages" and !definition.mixed()) return error.InvalidAuth;
    return definition;
}

pub fn isNativeId(id: []const u8) bool {
    return std.mem.eql(u8, id, "gateway") or std.mem.eql(u8, id, "codex") or std.mem.eql(u8, id, "grok");
}

pub fn parseNative(alloc: Allocator, id: []const u8, value: std.json.Value) ParseError!NativeOverrides {
    if (!isNativeId(id)) return error.InvalidProviderId;
    try check_fields(value, &.{ "default_model", "reviewer_model", "model_metadata", "defaults", "base_url", "headers", "compat", "remote_compaction" });
    var overrides: NativeOverrides = .{ .id = "", .storage = .init(alloc) };
    errdefer overrides.deinit();
    const arena = overrides.storage.allocator();
    overrides.id = try arena.dupe(u8, id);
    if (try optional_model(value.object.get("default_model"))) |model| overrides.default_model = try arena.dupe(u8, model);
    if (try optional_model(value.object.get("reviewer_model"))) |model| overrides.reviewer_model = try arena.dupe(u8, model);
    var policy_value = value;
    policy_value.object = try value.object.clone(arena);
    var defaults: std.json.Value = value.object.get("defaults") orelse .{ .object = .empty };
    if (defaults != .object) return error.InvalidObject;
    defaults.object = try defaults.object.clone(arena);
    for ([_][]const u8{ "base_url", "headers" }) |key| if (value.object.get(key)) |field| try defaults.object.put(arena, key, field);
    try policy_value.object.put(arena, "defaults", defaults);
    const protocol: Protocol = if (std.mem.eql(u8, id, "grok")) .@"openai-chat-completions" else .@"openai-responses";
    const policy = try parsePolicy(arena, policy_value, protocol, .openai);
    // Native wire protocols are owned by their transports, not models.json.
    if (policy.defaults) |metadata| if (metadata.protocol != null) return error.InvalidProtocol;
    for (policy.models) |metadata| if (metadata.protocol != null) return error.InvalidProtocol;
    overrides.model_metadata = policy.models;
    overrides.defaults = policy.defaults;
    return overrides;
}

const Policy = struct { models: []const ModelMetadata, defaults: ?*const ModelMetadata };

fn parsePolicy(arena: Allocator, value: std.json.Value, protocol: Protocol, reasoning: ReasoningFormat) ParseError!Policy {
    var defaults: std.json.Value = .{ .object = .empty };
    if (value.object.get("defaults")) |fields| {
        if (fields != .object) return error.InvalidObject;
        defaults.object = try fields.object.clone(arena);
    }
    for ([_][]const u8{ "compat", "remote_compaction" }) |key| if (value.object.get(key)) |field| try defaults.object.put(arena, key, field);
    var result: Policy = .{ .models = &.{}, .defaults = null };
    if (defaults.object.count() > 0) {
        var single: std.json.Value = .{ .object = .empty };
        try single.object.put(arena, "__defaults__", defaults);
        const parsed = try parse_metadata(arena, single, protocol, reasoning);
        result.defaults = &parsed[0];
    }
    if (value.object.get("model_metadata")) |models| {
        if (models != .object) return error.InvalidObject;
        var effective: std.json.Value = .{ .object = .empty };
        var iterator = models.object.iterator();
        while (iterator.next()) |entry| try effective.object.put(arena, entry.key_ptr.*, try overlayValue(arena, defaults, entry.value_ptr.*));
        result.models = try parse_metadata(arena, effective, protocol, reasoning);
    }
    return result;
}

/// Object fields merge recursively; explicit scalar/array values replace.
/// The result borrows leaf values from its inputs and owns only map storage.
pub fn overlayValue(arena: Allocator, base: std.json.Value, patch: std.json.Value) Allocator.Error!std.json.Value {
    if (base != .object or patch != .object) return patch;
    var result: std.json.Value = .{ .object = try base.object.clone(arena) };
    var iterator = patch.object.iterator();
    while (iterator.next()) |entry| {
        const current = result.object.get(entry.key_ptr.*);
        try result.object.put(arena, entry.key_ptr.*, if (current) |field| try overlayValue(arena, field, entry.value_ptr.*) else entry.value_ptr.*);
    }
    return result;
}

fn optional_model(value: ?std.json.Value) ParseError!?[]const u8 {
    const present = value orelse return null;
    if (present != .string) return error.InvalidModelId;
    try validate_model_id(present.string);
    return present.string;
}

fn parse_auth(value: std.json.Value) ParseError!Auth {
    try check_fields(value, &.{ "type", "env", "command", "header" });
    const kind = try required(value, "type");
    if (kind != .string) return error.InvalidAuth;
    if (std.mem.eql(u8, kind.string, "none")) {
        if (value.object.count() != 1) return error.InvalidAuth;
        return .none;
    }
    const login = std.mem.eql(u8, kind.string, "login");
    if (value.object.get("header")) |header| {
        if (!login or header != .string) return error.InvalidAuth;
        if (!std.mem.eql(u8, header.string, "x-api-key") and !std.mem.eql(u8, header.string, "authorization")) return error.InvalidAuth;
    }
    if (!login and !std.mem.eql(u8, kind.string, "bearer") and !std.mem.eql(u8, kind.string, "x-api-key")) return error.InvalidAuth;
    if (value.object.get("command")) |command| {
        if (login or value.object.contains("env")) return error.InvalidAuth;
        if (command != .string) return error.InvalidCommand;
        try validate_command(command.string);
        return .{ .command = command.string };
    }
    if (login and !value.object.contains("env")) return .{ .login = "" };

    const env = try required(value, "env");
    if (env != .string) return error.InvalidEnvironmentName;
    try validate_env(env.string);
    return if (login) .{ .login = env.string } else .{ .bearer = env.string };
}

fn validate_env(env: []const u8) ParseError!void {
    if (env.len > max_env_bytes) return error.LimitExceeded;
    if (env.len == 0 or (!std.ascii.isAlphabetic(env[0]) and env[0] != '_')) return error.InvalidEnvironmentName;
    for (env) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidEnvironmentName;
    }
}

/// A `!command` is printable ASCII after the bang and names a program.
pub fn validate_command(text: []const u8) error{ InvalidCommand, LimitExceeded }!void {
    if (text.len > max_url_bytes) return error.LimitExceeded;
    if (text.len < 2 or text[0] != '!' or text[1] == '!') return error.InvalidCommand;
    if (std.mem.trim(u8, text[1..], " ").len == 0) return error.InvalidCommand;
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidCommand;
}

fn parse_headers(alloc: Allocator, value: std.json.Value) ParseError![]const Header {
    if (value != .object) return error.InvalidObject;
    if (value.object.count() > 16) return error.LimitExceeded;
    const headers = try alloc.alloc(Header, value.object.count());
    var initialized: usize = 0;
    errdefer {
        for (headers[0..initialized]) |header| {
            alloc.free(header.name);
            alloc.free(header.value);
        }
        alloc.free(headers);
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (name.len == 0 or name.len > 128) return error.InvalidHeader;
        for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidHeader;
        // Credentials belong in `auth`, where they are redacted and bound.
        for ([_][]const u8{ "authorization", "x-api-key", "content-type", "content-length", "host" }) |reserved| {
            if (std.ascii.eqlIgnoreCase(name, reserved)) return error.InvalidHeader;
        }
        const text = entry.value_ptr.*;
        if (text != .string or text.string.len > max_url_bytes) return error.InvalidHeader;
        for (text.string) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidHeader;
        if (text.string.len != 0 and text.string[0] == '!' and !std.mem.startsWith(u8, text.string, "!!")) try validate_command(text.string);
        const owned_name = try alloc.dupe(u8, name);
        errdefer alloc.free(owned_name);
        headers[initialized] = .{ .name = owned_name, .value = try alloc.dupe(u8, text.string) };
        initialized += 1;
    }
    return headers;
}

fn parse_metadata(alloc: Allocator, value: std.json.Value, protocol: Protocol, reasoning_format: ReasoningFormat) ParseError![]const ModelMetadata {
    if (value != .object) return error.InvalidObject;
    if (value.object.count() > max_models) return error.LimitExceeded;
    const models = try alloc.alloc(ModelMetadata, value.object.count());
    var initialized: usize = 0;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        try validate_model_id(entry.key_ptr.*);
        const metadata = entry.value_ptr.*;
        try check_fields(metadata, &.{
            "context_window",   "max_output_tokens", "supports_tool_use",  "supports_vision",        "reasoning_efforts", "thinking",  "protocol",
            "name",             "description",       "cost",               "intelligence",           "recommended",       "beta",      "released",
            "base_url",         "headers",           "max_context_window", "omit_max_output_tokens", "prefer_websockets", "tokenizer", "context_promotion_target",
            "compaction_model", "remote_compaction", "compat",
        });
        var model_protocol: ?Protocol = null;
        if (metadata.object.get("protocol")) |kind| {
            if (kind != .string) return error.InvalidProtocol;
            model_protocol = std.meta.stringToEnum(Protocol, kind.string) orelse return error.InvalidProtocol;
        }
        // Chat Completions sends reasoning settings only in a declared format.
        const effective = model_protocol orelse protocol;
        if (effective == .@"openai-chat-completions" and reasoning_format == .none and metadata.object.contains("reasoning_efforts")) return error.UnknownField;
        if (effective != .@"anthropic-messages" and metadata.object.contains("thinking")) return error.UnknownField;
        var thinking: ?ThinkingMode = null;
        if (metadata.object.get("thinking")) |mode| {
            if (mode != .string) return error.InvalidModelMetadata;
            thinking = std.meta.stringToEnum(ThinkingMode, mode.string) orelse return error.InvalidModelMetadata;
        }
        const context = try positive_limit(metadata.object.get("context_window"));
        const output = try positive_limit(metadata.object.get("max_output_tokens"));
        if (context != null and output != null and output.? >= context.?) return error.InvalidModelMetadata;
        if (metadata.object.get("tokenizer")) |tokenizer_value| switch (tokenizer_value) {
            .null => {},
            .string => if (tokenizer.Encoding.parse(tokenizer_value.string) == null) return error.InvalidModelMetadata,
            else => return error.InvalidModelMetadata,
        };
        const tools = try optional_bool(metadata.object.get("supports_tool_use"));
        const vision = try optional_bool(metadata.object.get("supports_vision"));
        const efforts = try parse_efforts(alloc, metadata.object.get("reasoning_efforts"));
        models[initialized] = .{
            .fields = try metadataFields(alloc, metadata.object),
            .reasoning_efforts = efforts,
            .thinking = thinking,
            .protocol = model_protocol,
            .id = try alloc.dupe(u8, entry.key_ptr.*),
            .context_window = context,
            .max_output_tokens = output,
            .supports_tool_use = tools,
            .supports_vision = vision,
            .name = try metadataValue(?[]const u8, alloc, metadata, "name", null),
            .description = try metadataValue(?[]const u8, alloc, metadata, "description", null),
            .cost = try metadataValue(?ModelCost, alloc, metadata, "cost", null),
            .intelligence = try metadataValue(?f64, alloc, metadata, "intelligence", null),
            .recommended = try metadataValue(bool, alloc, metadata, "recommended", false),
            .beta = try metadataValue(bool, alloc, metadata, "beta", false),
            .released = try metadataValue(i64, alloc, metadata, "released", 0),
            .base_url = if (metadata.object.get("base_url")) |url| try alloc.dupe(u8, try validate_url(if (url == .string) url.string else return error.InvalidBaseUrl)) else null,
            .headers = if (metadata.object.get("headers")) |headers| try parse_headers(alloc, headers) else &.{},
            .max_context_window = try positive_limit(metadata.object.get("max_context_window")),
            .omit_max_output_tokens = try metadataValue(bool, alloc, metadata, "omit_max_output_tokens", false),
            .prefer_websockets = try optional_bool(metadata.object.get("prefer_websockets")),
            .tokenizer = try metadataValue(?[]const u8, alloc, metadata, "tokenizer", null),
            .context_promotion_target = try metadataValue(?[]const u8, alloc, metadata, "context_promotion_target", null),
            .compaction_model = try metadataValue(?[]const u8, alloc, metadata, "compaction_model", null),
            .remote_compaction = try metadataValue(?RemoteCompaction, alloc, metadata, "remote_compaction", null),
            .compat = try metadataValue(@import("model_compatibility.zig").Compatibility, alloc, metadata, "compat", .{}),
        };
        initialized += 1;
    }
    return models;
}

fn metadataFields(arena: Allocator, object: std.json.ObjectMap) Allocator.Error![]const []const u8 {
    const names = try arena.alloc([]const u8, object.count());
    for (object.keys(), names) |name, *owned| owned.* = try arena.dupe(u8, name);
    return names;
}

/// A parsed override changes only explicitly supplied fields. Static catalog
/// metadata has no field mask, and is not itself an override.
pub fn overlayMetadata(base: ModelMetadata, patch: ModelMetadata) ModelMetadata {
    var result = base;
    inline for (@typeInfo(ModelMetadata).@"struct".field_names) |field_name| {
        if (comptime !std.mem.eql(u8, field_name, "id") and !std.mem.eql(u8, field_name, "fields")) {
            for (patch.fields) |name| if (std.mem.eql(u8, name, field_name)) {
                @field(result, field_name) = @field(patch, field_name);
                break;
            };
        }
    }
    result.id = base.id;
    result.fields = patch.fields;
    return result;
}

fn metadataValue(comptime T: type, arena: Allocator, object: std.json.Value, key: []const u8, default: T) ParseError!T {
    const value = object.object.get(key) orelse return default;
    return std.json.parseFromValueLeaky(T, arena, value, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidModelMetadata,
    };
}

fn parse_efforts(alloc: Allocator, value: ?std.json.Value) ParseError![]const types.ReasoningEffort {
    const present = value orelse return &.{};
    if (present != .array or present.array.items.len > types.ReasoningEffort.max_options) return error.InvalidModelMetadata;
    const efforts = try alloc.alloc(types.ReasoningEffort, present.array.items.len);
    errdefer alloc.free(efforts);
    for (present.array.items, efforts) |item, *effort| {
        if (item != .string) return error.InvalidModelMetadata;
        effort.* = types.ReasoningEffort.parse(item.string) orelse return error.InvalidModelMetadata;
        if (effort.* == .auto) return error.InvalidModelMetadata;
    }
    return efforts;
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
    const chat = try local.chat_url(alloc, "small");
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
    const chat = try definition.chat_url(alloc, "model");
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
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"m\":{\"tokenizer\":\"not-a-tokenizer\"}}}}", .err = error.InvalidModelMetadata },
        .{ .json = "{\"local\":{" ++ test_required_fields ++ ",\"model_metadata\":{\"m\":{\"tokenizer\":1}}}}", .err = error.InvalidModelMetadata },
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
        .{ .json = "{\"type\":\"bearer\",\"command\":\"get-key\"}", .err = error.InvalidCommand },
        .{ .json = "{\"type\":\"bearer\",\"command\":\"!get-key\",\"env\":\"K\"}", .err = error.InvalidAuth },
        .{ .json = "{\"type\":\"login\",\"command\":\"!get-key\"}", .err = error.InvalidAuth },
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

test "configured anthropic messages provider takes an x-api-key slot and thinking metadata" {
    const alloc = std.testing.allocator;
    var registry = try Registry.parse_json(alloc,
        \\{"claude":{"protocol":"anthropic-messages","base_url":"https://api.anthropic.com/v1","auth":{"type":"x-api-key","env":"ANTHROPIC_API_KEY"},"model_metadata":{"claude-opus":{"max_output_tokens":32000,"reasoning_efforts":["low","high"],"thinking":"adaptive"}}}}
    );
    defer registry.deinit(alloc);
    const claude = registry.get("claude").?;
    try std.testing.expectEqual(Protocol.@"anthropic-messages", claude.protocol);
    try std.testing.expectEqual(KeyHeader.x_api_key, claude.key_header);
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", claude.auth.bearer);
    const url = try claude.messages_url(alloc, "claude-opus");
    defer alloc.free(url);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url);
    const metadata = claude.model("claude-opus").?;
    try std.testing.expectEqual(ThinkingMode.adaptive, metadata.thinking.?);
    try std.testing.expectEqualStrings("high", metadata.reasoning_efforts[1].label());
    var bearer = claude.*;
    bearer.key_header = .authorization;
    try std.testing.expect(!std.mem.eql(u8, &claude.binding_identity(), &bearer.binding_identity()));
    for ([_][]const u8{
        \\{"x":{"protocol":"openai-chat-completions","base_url":"https://e.com","auth":{"type":"x-api-key","env":"K"}}}
        ,
        \\{"x":{"protocol":"openai-chat-completions","base_url":"https://e.com","auth":{"type":"none"},"model_metadata":{"m":{"reasoning_efforts":["low"]}}}}
        ,
        \\{"x":{"protocol":"anthropic-messages","base_url":"https://e.com","auth":{"type":"none"},"model_metadata":{"m":{"reasoning_efforts":["auto"]}}}}
        ,
        \\{"x":{"protocol":"anthropic-messages","base_url":"https://e.com","auth":{"type":"none"},"model_metadata":{"m":{"thinking":"always"}}}}
        ,
    }) |json| {
        if (Registry.parse_json(alloc, json)) |parsed| {
            var owned = parsed;
            owned.deinit(alloc);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "configured model metadata preserves display and request policy" {
    const alloc = std.testing.allocator;
    var registry = try Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-responses","base_url":"http://localhost:1234/v1","auth":{"type":"none"},"model_metadata":{"small":{"name":"Small","description":"Fast text and images","cost":{"input":1,"output":4,"cache_read":0.1},"base_url":"https://models.example/v1","headers":{"X-Model":"small"},"prefer_websockets":true,"context_promotion_target":"large","compaction_model":"summary","remote_compaction":{"enabled":true,"endpoint":"https://models.example/v1/responses/compact"},"compat":{"supportsStore":false}}}}}
    );
    defer registry.deinit(alloc);
    const metadata = registry.get("local").?.model("small").?;
    try std.testing.expectEqualStrings("Small", metadata.name.?);
    try std.testing.expectEqual(@as(f64, 4), metadata.cost.?.output);
    try std.testing.expectEqualStrings("https://models.example/v1", metadata.base_url.?);
    try std.testing.expectEqualStrings("X-Model", metadata.headers[0].name);
    try std.testing.expect(metadata.prefer_websockets.?);
    try std.testing.expectEqualStrings("large", metadata.context_promotion_target.?);
    try std.testing.expectEqualStrings("summary", metadata.compaction_model.?);
    try std.testing.expectEqualStrings("https://models.example/v1/responses/compact", metadata.remote_compaction.?.endpoint.?);
    try std.testing.expectEqual(@as(?bool, false), metadata.compat.supports_store);
}

test "configured provider routes per model and parses headers, login and command keys" {
    const alloc = std.testing.allocator;
    var registry = try Registry.parse_json(alloc,
        \\{"zen":{"protocol":"openai-chat-completions","base_url":"https://opencode.ai/zen/v1","auth":{"type":"x-api-key","command":"!op read op://vault/zen"},
        \\"reasoning_format":"openai","default_model":"claude-x","headers":{"X-Title":"fx","X-Key":"!pass show zen","X-Bang":"!!literal"},
        \\"model_metadata":{"claude-x":{"protocol":"anthropic-messages","thinking":"adaptive","reasoning_efforts":["low","high"]},"gpt-x":{"protocol":"openai-responses","reasoning_efforts":["low"]},"glm":{"reasoning_efforts":["high"]}}},
        \\"router":{"protocol":"openai-chat-completions","base_url":"https://openrouter.ai/api/v1","auth":{"type":"login","env":"OPENROUTER_API_KEY"}}}
    );
    defer registry.deinit(alloc);
    const zen = registry.get("zen").?;
    try std.testing.expect(zen.mixed());
    try std.testing.expectEqual(Protocol.@"anthropic-messages", zen.protocolFor("claude-x"));
    try std.testing.expectEqual(Protocol.@"openai-responses", zen.protocolFor("gpt-x"));
    try std.testing.expectEqual(Protocol.@"openai-chat-completions", zen.protocolFor("glm"));
    try std.testing.expectEqual(Protocol.@"openai-chat-completions", zen.protocolFor("unknown"));
    try std.testing.expectEqualStrings("!op read op://vault/zen", zen.auth.command);
    try std.testing.expectEqual(KeyHeader.x_api_key, zen.key_header);
    try std.testing.expectEqual(ReasoningFormat.openai, zen.reasoning_format);
    try std.testing.expectEqualStrings("claude-x", zen.default_model.?);
    try std.testing.expectEqual(@as(usize, 3), zen.headers.len);
    const router = registry.get("router").?;
    try std.testing.expectEqualStrings("OPENROUTER_API_KEY", router.keyEnv().?);
    try std.testing.expect(!router.mixed());
    try std.testing.expectEqual(@as(usize, 2), registry.userCount());
    var with_builtin = router.*;
    const builtin = [_]ModelMetadata{.{ .id = "anthropic/claude", .protocol = .@"anthropic-messages" }};
    with_builtin.builtin_models = &builtin;
    try std.testing.expect(with_builtin.mixed());
    try std.testing.expectEqual(Protocol.@"anthropic-messages", with_builtin.protocolFor("anthropic/claude"));
    for ([_][]const u8{
        \\{"x":{"protocol":"openai-chat-completions","base_url":"https://e.com","auth":{"type":"none"},"headers":{"Authorization":"Bearer k"}}}
        ,
        \\{"x":{"protocol":"openai-chat-completions","base_url":"https://e.com","auth":{"type":"none"},"headers":{"X-A":"!"}}}
        ,
        \\{"x":{"protocol":"openai-chat-completions","base_url":"https://e.com","auth":{"type":"none"},"headers":{"bad header":"v"}}}
        ,
        \\{"x":{"protocol":"openai-chat-completions","base_url":"https://e.com","auth":{"type":"none"},"reasoning_format":"other"}}
        ,
        \\{"x":{"protocol":"openai-chat-completions","base_url":"https://e.com","auth":{"type":"none"},"model_metadata":{"m":{"protocol":"grpc"}}}}
        ,
        \\{"x":{"protocol":"openai-responses","base_url":"https://e.com","auth":{"type":"none"},"model_metadata":{"m":{"thinking":"adaptive"}}}}
        ,
    }) |json| {
        if (Registry.parse_json(alloc, json)) |parsed| {
            var owned = parsed;
            owned.deinit(alloc);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
