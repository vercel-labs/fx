//! Built-in provider presets and the profile model-override file.
//!
//! OpenRouter, OpenCode Zen and OpenCode Go are configured providers that ship
//! with fx (D145): each is a definition like one a user writes, marked
//! `preset`, with a built-in model table. `models.json` in the profile (D148)
//! patches a preset by key, or adds or replaces a whole definition, in the
//! same schema as settings.json `providers`.
const std = @import("std");
const configured = @import("configured_provider.zig");
const preset_models = @import("provider_preset_models.zig");
const cursor_models = @import("../../gateway/cursor_models.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const Allocator = std.mem.Allocator;

pub const models_file_name = "models.json";
const max_models_file_bytes = 1024 * 1024;

pub const Login = enum {
    /// Browser PKCE sign-in, or a pasted key.
    browser_or_key,
    /// A pasted key only.
    key,
    /// Claude Code on the installed Claude Code's login (D184) or a
    /// subscription token from `claude setup-token`, or a pasted Anthropic
    /// API key (D166).
    claude_or_key,
    /// Cursor's browser sign-in, polled until it completes, or a pasted
    /// Cursor API key (D202).
    cursor,
};

pub const Preset = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    /// Where to get a key by hand.
    key_url: []const u8,
    /// Keys from this provider start with this, when it is known.
    key_prefix: []const u8 = "",
    login: Login,
    /// The definition, in the settings.json `providers` schema.
    json: []const u8,
    models: []const configured.ModelMetadata,
    catalog: configured.CatalogSource = .declared,
};

pub const presets = [_]Preset{
    .{
        .id = "anthropic",
        .name = "Anthropic",
        .description = "Claude through Claude Code with a subscription, or an Anthropic API key",
        .key_url = "https://console.anthropic.com/settings/keys",
        .key_prefix = "sk-ant-",
        .login = .claude_or_key,
        // The transport resolves its own credential and picks Claude Code or
        // the Messages API by the key's kind (D165, D166).
        .json =
        \\{"protocol":"anthropic-messages","base_url":"https://api.anthropic.com/v1","auth":{"type":"none"},"default_model":"claude-opus-5-5","reviewer_model":"claude-haiku-5-5"}
        ,
        .models = &preset_models.anthropic,
    },
    .{
        .id = "cursor",
        .name = "Cursor",
        .description = "Cursor account: browser sign-in or a Cursor API key",
        .key_url = "https://cursor.com/dashboard?tab=integrations",
        .login = .cursor,
        // Cursor's agent service over Connect; the protocol field is unused
        // because the cursor transport owns the preset (D200).
        .json =
        \\{"protocol":"openai-chat-completions","base_url":"https://api2.cursor.sh","auth":{"type":"login","env":"CURSOR_API_KEY"},"default_model":"composer-2.5","reviewer_model":"composer-2.5-fast"}
        ,
        .models = &cursor_models.metadata,
    },
    .{
        .id = "openrouter",
        .name = "OpenRouter",
        .description = "OpenRouter account: browser sign-in or an sk-or- key",
        .key_url = "https://openrouter.ai/settings/keys",
        .key_prefix = "sk-or-",
        .login = .browser_or_key,
        // Chat Completions for every model: OpenRouter applies `cache_control`
        // for anthropic/* there and returns reasoning details (D146).
        .json =
        \\{"protocol":"openai-chat-completions","base_url":"https://openrouter.ai/api/v1","auth":{"type":"login","env":"OPENROUTER_API_KEY"},"tool_choice_mode":"send","reasoning_format":"openrouter","default_model":"anthropic/claude-sonnet-5.5","headers":{"HTTP-Referer":"https://github.com/vercel-labs/fx","X-Title":"proto-fx"}}
        ,
        .models = &preset_models.openrouter,
        .catalog = .openrouter,
    },
    .{
        .id = "opencode-zen",
        .name = "OpenCode Zen",
        .description = "OpenCode Zen API key from opencode.ai/auth",
        .key_url = "https://opencode.ai/auth",
        .login = .key,
        .json =
        \\{"protocol":"openai-chat-completions","base_url":"https://opencode.ai/zen/v1","auth":{"type":"login","env":"OPENCODE_API_KEY","header":"x-api-key"},"tool_choice_mode":"send","reasoning_format":"openai","default_model":"claude-sonnet-5-5"}
        ,
        .models = &preset_models.opencode_zen,
    },
    .{
        .id = "opencode-go",
        .name = "OpenCode Go",
        .description = "OpenCode Go API key from opencode.ai/auth",
        .key_url = "https://opencode.ai/auth",
        .login = .key,
        .json =
        \\{"protocol":"openai-chat-completions","base_url":"https://opencode.ai/zen/go/v1","auth":{"type":"login","env":"OPENCODE_API_KEY","header":"x-api-key"},"tool_choice_mode":"send","reasoning_format":"openai","default_model":"glm-5.3"}
        ,
        .models = &preset_models.opencode_go,
    },
};

pub fn presetFor(id: []const u8) ?*const Preset {
    for (&presets) |*preset| if (std.mem.eql(u8, preset.id, id)) return preset;
    return null;
}

pub const ExtendError = configured.ParseError || error{ InvalidModelsFile, StreamTooLong };

/// Adds the presets to `registry`, then applies `<fx_dir>/models.json` when
/// `fx_dir` is set. A user definition in settings.json with a preset's id
/// keeps priority over the preset; models.json wins over both.
pub fn extend(alloc: Allocator, registry: *?configured.Registry, fx_dir: ?[]const u8) !void {
    if (registry.* == null) registry.* = .{};
    const target = &registry.*.?;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const overrides = if (fx_dir) |dir| try loadOverrides(arena, dir) else null;
    for (&presets) |*preset| {
        const patch = if (overrides) |object| object.get(preset.id) else null;
        // A user's own definition with this id replaces the preset entirely;
        // a metadata patch must not silently restore the preset's endpoint.
        if (target.get(preset.id)) |existing| {
            const overlay = patch orelse continue;
            if (overlay != .object) return error.InvalidModelsFile;
            const source = existing.source orelse return error.InvalidModelsFile;
            var definition = try configured.parse_definition(alloc, preset.id, try configured.overlayValue(arena, source, overlay));
            definition.preset = existing.preset;
            definition.catalog = existing.catalog;
            definition.builtin_models = existing.builtin_models;
            try target.put(alloc, definition);
        } else try target.put(alloc, try buildPreset(alloc, arena, preset, patch));
    }
    const object = overrides orelse return;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (presetFor(entry.key_ptr.*) != null) continue;
        const id = entry.key_ptr.*;
        if (configured.isNativeId(id)) {
            try target.putNative(alloc, try configured.parseNative(alloc, id, entry.value_ptr.*));
        } else {
            const base = if (target.get(id)) |definition| definition.source else null;
            const value = if (base) |source| try configured.overlayValue(arena, source, entry.value_ptr.*) else entry.value_ptr.*;
            try target.put(alloc, try configured.parse_definition(alloc, id, value));
        }
    }
}

/// The definition for `preset` with `patch` laid over it: top-level keys
/// replace, `headers` and `model_metadata` merge by key. Caller owns it.
pub fn buildPreset(alloc: Allocator, arena: Allocator, preset: *const Preset, patch: ?std.json.Value) !configured.Definition {
    var base = try std.json.parseFromSliceLeaky(std.json.Value, arena, preset.json, .{});
    if (patch) |overlay| {
        if (overlay != .object) return error.InvalidModelsFile;
        base = try configured.overlayValue(arena, base, overlay);
    }
    var definition = try configured.parse_definition(alloc, preset.id, base);
    definition.builtin_models = preset.models;
    // Materialize preset policy once. Requests and catalog projections see
    // the same effective defaults/overrides without changing the transport.
    const parsed_models = definition.model_metadata;
    const storage = definition.model_storage.?.allocator();
    var models: std.ArrayList(configured.ModelMetadata) = .empty;
    for (preset.models) |builtin| {
        var metadata = builtin;
        if (definition.model_defaults) |defaults| metadata = configured.overlayMetadata(metadata, defaults.*);
        for (parsed_models) |override| if (std.mem.eql(u8, override.id, builtin.id)) {
            metadata = configured.overlayMetadata(metadata, override);
            break;
        };
        try models.append(storage, metadata);
    }
    for (parsed_models) |metadata| {
        const builtin = for (preset.models) |model| {
            if (std.mem.eql(u8, model.id, metadata.id)) break true;
        } else false;
        if (!builtin) try models.append(storage, metadata);
    }
    definition.model_metadata = models.items;
    definition.catalog = preset.catalog;
    definition.preset = true;
    return definition;
}

/// The `providers` object of models.json, or null when the file is absent.
/// Borrows from `arena`.
fn loadOverrides(arena: Allocator, fx_dir: []const u8) !?std.json.ObjectMap {
    const path = try std.Io.Dir.path.join(arena, &.{ fx_dir, models_file_name });
    var file = io_mod.openExistingRegularFile(std.Io.Dir.cwd(), path, .read_only) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(arena, &file, max_models_file_bytes);
    return try parseOverrides(arena, bytes);
}

pub fn parseOverrides(arena: Allocator, bytes: []const u8) !std.json.ObjectMap {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DuplicateField => return error.DuplicateField,
        else => return error.InvalidModelsFile,
    };
    if (root != .object) return error.InvalidModelsFile;
    for (root.object.keys()) |key| if (!std.mem.eql(u8, key, "providers")) return error.InvalidModelsFile;
    const providers = root.object.get("providers") orelse return .empty;
    if (providers != .object) return error.InvalidModelsFile;
    return providers.object;
}

/// The profile directory under `home`. Caller owns it.
pub fn fxDir(alloc: Allocator, home: []const u8) ![]u8 {
    return profile_paths.rootDir(alloc, home);
}

test "presets join the registry with their built-in models and routes" {
    const alloc = std.testing.allocator;
    var registry: ?configured.Registry = null;
    defer if (registry) |*value| value.deinit(alloc);
    try extend(alloc, &registry, null);
    const value = registry.?;
    try std.testing.expectEqual(@as(usize, 0), value.userCount());
    const claude = value.get("anthropic").?;
    try std.testing.expect(claude.preset and !claude.mixed());
    try std.testing.expectEqualStrings("claude-opus-5-5", claude.default_model.?);
    try std.testing.expectEqualStrings("claude-haiku-5-5", claude.reviewer_model.?);
    for ([_][]const u8{ "claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-4-8" }) |id| try std.testing.expect(claude.model(id) != null);
    const router = value.get("openrouter").?;
    try std.testing.expect(router.preset);
    try std.testing.expectEqual(configured.CatalogSource.openrouter, router.catalog);
    try std.testing.expectEqual(configured.ReasoningFormat.openrouter, router.reasoning_format);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-5.5", router.default_model.?);
    try std.testing.expect(router.model(router.default_model.?) != null);
    const zen = value.get("opencode-zen").?;
    try std.testing.expect(zen.mixed());
    try std.testing.expectEqual(configured.KeyHeader.x_api_key, zen.key_header);
    try std.testing.expectEqualStrings("OPENCODE_API_KEY", zen.keyEnv().?);
    try std.testing.expectEqual(configured.Protocol.@"anthropic-messages", zen.protocolFor("claude-sonnet-5-5"));
    try std.testing.expectEqual(configured.Protocol.@"openai-responses", zen.protocolFor("gpt-5.5"));
    try std.testing.expectEqual(configured.Protocol.@"openai-chat-completions", zen.protocolFor("kimi-k3"));
    try std.testing.expectEqual(configured.Protocol.@"google-generative-ai", zen.protocolFor("gemini-3-pro"));
    const gemini = zen.model("gemini-3-pro").?;
    try std.testing.expectEqualStrings("Gemini 3 Pro", gemini.name.?);
    try std.testing.expect(gemini.cost != null);
    try std.testing.expect(zen.model(zen.default_model.?) != null);
    const cursor = value.get("cursor").?;
    try std.testing.expect(cursor.preset);
    try std.testing.expectEqualStrings("composer-2.5", cursor.default_model.?);
    try std.testing.expect(cursor.model("claude-opus-5-high") != null);
    const go = value.get("opencode-go").?;
    try std.testing.expect(go.model(go.default_model.?) != null);
}

test "native model overrides preserve native identity and merge provider defaults" {
    const alloc = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const overrides = try parseOverrides(arena.allocator(),
        \\{"providers":{"codex":{"default_model":"custom-codex","compat":{"supportsStore":false},"defaults":{"context_window":64000,"prefer_websockets":false},"model_metadata":{"custom-codex":{"name":"Custom Codex","max_output_tokens":4000,"headers":{"X-Model":"custom"}}}},"gateway":{"model_metadata":{"custom/model":{"supports_vision":true}}},"grok":{"model_metadata":{"custom-grok":{"tokenizer":"o200k_base"}}}}}
    );
    var registry: configured.Registry = .{};
    defer registry.deinit(alloc);
    var iterator = overrides.iterator();
    while (iterator.next()) |entry| try registry.putNative(alloc, try configured.parseNative(alloc, entry.key_ptr.*, entry.value_ptr.*));
    try std.testing.expectEqual(@as(usize, 0), registry.definitions.len);
    try std.testing.expect(registry.get("codex") == null);
    try std.testing.expectEqualStrings("custom-codex", registry.native("codex").?.default_model.?);
    const model = registry.model("codex", "custom-codex").?;
    try std.testing.expectEqual(@as(?u32, 64000), model.context_window);
    try std.testing.expectEqual(@as(?u32, 4000), model.max_output_tokens);
    try std.testing.expectEqual(@as(?bool, false), model.prefer_websockets);
    try std.testing.expectEqual(@as(?bool, false), model.compat.supports_store);
    try std.testing.expectEqualStrings("custom", model.headers[0].value);
    try std.testing.expectEqual(@as(?u32, 64000), registry.model("codex", "discovered-codex").?.context_window);
    try std.testing.expectEqual(@as(?bool, true), registry.model("gateway", "custom/model").?.supports_vision);
    const forbidden = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"protocol\":\"openai-responses\"}", .{});
    try std.testing.expectError(error.UnknownField, configured.parseNative(alloc, "codex", forbidden));
}

test "models.json patches presets by key and adds whole definitions" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const overrides = try parseOverrides(arena_state.allocator(),
        \\{"providers":{"openrouter":{"base_url":"http://127.0.0.1:8394/v1","headers":{"X-Title":"mine"},"model_metadata":{"local/claude":{"protocol":"anthropic-messages","context_window":200000}}},
        \\"cento":{"protocol":"anthropic-messages","base_url":"http://127.0.0.1:8394/v1","auth":{"type":"bearer","command":"!printf dummy"},"model_metadata":{"claude-cento":{}}}}}
    );
    var registry: configured.Registry = try .parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1/v1","auth":{"type":"none"}}}
    );
    defer registry.deinit(alloc);
    const router = try buildPreset(alloc, arena_state.allocator(), presetFor("openrouter").?, overrides.get("openrouter"));
    try registry.put(alloc, router);
    try registry.put(alloc, try configured.parse_definition(alloc, "cento", overrides.get("cento").?));
    const patched = registry.get("openrouter").?;
    try std.testing.expectEqualStrings("http://127.0.0.1:8394/v1", patched.base_url);
    try std.testing.expectEqual(@as(usize, 2), patched.headers.len);
    for (patched.headers) |header| if (std.mem.eql(u8, header.name, "X-Title")) try std.testing.expectEqualStrings("mine", header.value);
    try std.testing.expectEqual(configured.Protocol.@"anthropic-messages", patched.protocolFor("local/claude"));
    try std.testing.expect(patched.model("anthropic/claude-sonnet-5.5") != null);
    try std.testing.expectEqualStrings("!printf dummy", registry.get("cento").?.auth.command);
    try std.testing.expectEqual(@as(usize, 2), registry.userCount());
    for ([_][]const u8{ "[]", "{\"models\":{}}", "{\"providers\":[]}", "{\"providers\":{},\"providers\":{}}" }) |bad| {
        if (parseOverrides(arena_state.allocator(), bad)) |_| return error.TestUnexpectedResult else |_| {}
    }
}
