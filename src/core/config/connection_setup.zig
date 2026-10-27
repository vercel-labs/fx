//! Configure a direct Chat Completions or Anthropic Messages connection,
//! discovering its model catalog when the user did not select a model (D149).
//! This runs on the setup command, not paint.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const configured = @import("configured_provider.zig");
const model_provider = @import("model_provider.zig");
const settings_store = @import("settings_store.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const http = @import("../../gateway/client.zig");
const Allocator = std.mem.Allocator;

pub const usage = "proto-fx setup --base-url URL [--protocol chat-completions|anthropic-messages] [--model MODEL] [--api-key-env NAME] [--name NAME]";

/// The `--protocol` value as a settings protocol name, or null when unknown.
pub fn protocolName(value: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, value, "chat-completions") or std.mem.eql(u8, value, "openai-chat-completions")) return "openai-chat-completions";
    if (std.mem.eql(u8, value, "anthropic-messages") or std.mem.eql(u8, value, "messages")) return "anthropic-messages";
    return null;
}

/// Whether `err` means the arguments were malformed, so the usage helps.
pub fn isUsageError(err: anyerror) bool {
    return err == error.InvalidSetupArguments or err == error.BaseUrlRequired;
}

/// Returned summary is caller-owned. The settings transaction preserves all
/// unrelated profile fields and stores only the key's environment-variable name.
/// When an environment, network, or file operation fails, `failure` receives
/// a caller-owned sentence naming what failed. Setup creates the profile
/// directory under HOME but never HOME itself.
pub fn run(alloc: Allocator, args: []const [:0]const u8, failure: *?[]u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var base: ?[]const u8 = io_mod.getenv("PROTO_FX_BASE_URL");
    var selected: ?[]const u8 = null;
    var key_env: ?[]const u8 = null;
    var name: []const u8 = "local";
    var protocol: []const u8 = "openai-chat-completions";
    var index: usize = 0;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return error.InvalidSetupArguments;
        const option = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, option, "--base-url")) {
            base = value;
        } else if (std.mem.eql(u8, option, "--model")) {
            selected = value;
        } else if (std.mem.eql(u8, option, "--api-key-env")) {
            key_env = value;
        } else if (std.mem.eql(u8, option, "--name")) {
            name = value;
        } else if (std.mem.eql(u8, option, "--protocol")) {
            protocol = protocolName(value) orelse return error.InvalidSetupArguments;
        } else return error.InvalidSetupArguments;
    }
    const raw_base = base orelse return error.BaseUrlRequired;
    try configured.validate_id(name);
    var prefix = std.mem.trimEnd(u8, raw_base, "/");
    var definition: std.json.Value = .{ .object = .empty };
    try definition.object.put(a, "protocol", .{ .string = protocol });
    try definition.object.put(a, "base_url", .{ .string = prefix });
    var auth: std.json.Value = .{ .object = .empty };
    // Messages endpoints take the key in Anthropic's `x-api-key` header.
    const messages = std.mem.eql(u8, protocol, "anthropic-messages");
    try auth.object.put(a, "type", .{ .string = if (key_env == null) "none" else if (messages) "x-api-key" else "bearer" });
    if (key_env) |env| try auth.object.put(a, "env", .{ .string = env });
    try definition.object.put(a, "auth", auth);
    var providers: std.json.Value = .{ .object = .empty };
    try providers.object.put(a, name, definition);
    // Validate the URL and credential slot before contacting anything.
    var checked = try configured.Registry.parse(a, providers);
    checked.deinit(a);
    const bearer: ?[]const u8 = if (key_env) |env| io_mod.getenv(env) orelse {
        failure.* = try alloc.print("the environment variable {s} named by --api-key-env is not set", .{env});
        return error.ApiKeyEnvironmentMissing;
    } else null;
    var metadata: std.json.Value = .{ .object = .empty };
    var discovered: usize = 0;
    if (selected == null) {
        const candidates: []const []const u8 = if (std.mem.endsWith(u8, prefix, "/v1"))
            &.{prefix}
        else
            &.{ try a.print("{s}/v1", .{prefix}), prefix };
        var found = false;
        var last_error: anyerror = error.ModelDiscoveryFailed;
        var last_url: []const u8 = "";
        for (candidates) |candidate| {
            const url = try a.print("{s}/models", .{candidate});
            last_url = url;
            var cancel = std.atomic.Value(bool).init(false);
            const response = http.fetchGatewayJsonAtUrlCancellable(a, bearer, null, url, &cancel, 10_000) catch |err| {
                last_error = err;
                continue;
            };
            const body = switch (response) {
                .success => |bytes| bytes,
                .http_status => |status| {
                    last_error = if (status == .unauthorized or status == .forbidden) error.ModelDiscoveryUnauthorized else error.ModelDiscoveryFailed;
                    continue;
                },
            };
            const catalog = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{ .allocate = .alloc_always }) catch {
                last_error = error.InvalidModelCatalog;
                continue;
            };
            if (catalog != .object) continue;
            const data = catalog.object.get("data") orelse continue;
            if (data != .array) continue;
            for (data.array.items) |item| {
                if (metadata.object.count() >= 256) break;
                if (item != .object) continue;
                const id = item.object.get("id") orelse continue;
                if (id != .string or id.string.len == 0 or id.string.len > configured.max_model_bytes) continue;
                var details: std.json.Value = .{ .object = .empty };
                // Explicit server capabilities win. A coding endpoint is expected
                // to support tools; unsupported responses still surface normally.
                try details.object.put(a, "supports_tool_use", .{ .bool = true });
                inline for (&.{ "context_window", "max_output_tokens" }) |field| {
                    if (item.object.get(field)) |value| {
                        if (value == .integer and value.integer > 0 and value.integer <= std.math.maxInt(u32)) try details.object.put(a, field, value);
                    }
                }
                inline for (&.{ "supports_tool_use", "supports_vision" }) |field| {
                    if (item.object.get(field)) |value| if (value == .bool) try details.object.put(a, field, value);
                }
                try metadata.object.put(a, id.string, details);
                if (selected == null) selected = id.string;
            }
            if (metadata.object.count() == 0) {
                last_error = error.NoModelsDiscovered;
                continue;
            }
            prefix = candidate;
            discovered = metadata.object.count();
            found = true;
            break;
        }
        if (!found) {
            failure.* = try alloc.print("could not list models at {s} ({s}); pass --model to set up offline", .{ last_url, @errorName(last_error) });
            return last_error;
        }
    } else {
        // An explicit model permits offline setup, without guessing capabilities.
        try metadata.object.put(a, selected.?, .{ .object = .empty });
    }
    const model = selected orelse return error.NoModelsDiscovered;
    try settings_store.validateModel(model);
    try definition.object.put(a, "base_url", .{ .string = prefix });
    try definition.object.put(a, "model_metadata", metadata);
    try providers.object.put(a, name, definition);
    var json: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(providers, .{}, &json.writer);
    const provider = model_provider.parse(name) orelse return error.InvalidProviderId;
    const home = io_mod.homeDir() orelse {
        failure.* = try alloc.dupe(u8, "HOME is not set, so there is no profile to save the connection in");
        return error.HomeUnavailable;
    };
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{}) catch |err| {
        failure.* = if (err == error.FileNotFound)
            try alloc.print("the home directory {s} does not exist", .{home})
        else
            try alloc.print("cannot open the home directory {s} ({s})", .{ home, @errorName(err) });
        return err;
    };
    home_dir.close(io_mod.getIo());
    saveConnection(alloc, home, json.written(), provider, model) catch |err| {
        const root = profile_paths.rootDir(a, home) catch home;
        failure.* = try alloc.print("cannot save the connection in {s} ({s})", .{ root, @errorName(err) });
        return err;
    };
    return alloc.print("Connected {s}: {s}\nModel: {s}\nDiscovered {d} models. Run proto-fx to begin.\n", .{ name, prefix, model, discovered });
}

fn saveConnection(alloc: Allocator, home: []const u8, connections_json: []const u8, provider: model_provider.ProviderId, model: []const u8) !void {
    var store = try settings_store.Store.initFromHome(alloc, home, .writable);
    defer store.deinit(alloc);
    var outcome = try store.applyUserPatch(alloc, .{
        .connections_json = connections_json,
        .provider = provider,
        .model_preference = .{ .provider = provider, .model = model },
        .clear_credential_source = true,
    });
    outcome.deinit(alloc);
}

test "setup names a missing home instead of printing usage" {
    const alloc = std.testing.allocator;
    var failure: ?[]u8 = null;
    defer if (failure) |message| alloc.free(message);
    const args = [_][:0]const u8{ "--model", "m" };
    try std.testing.expectError(error.BaseUrlRequired, run(alloc, &args, &failure));
    try std.testing.expect(isUsageError(error.BaseUrlRequired));
    try std.testing.expect(failure == null);
    try std.testing.expect(!isUsageError(error.FileNotFound));
    const bad = [_][:0]const u8{ "--base-url", "http://127.0.0.1:1/v1", "--protocol", "grpc" };
    try std.testing.expectError(error.InvalidSetupArguments, run(alloc, &bad, &failure));
    try std.testing.expectEqualStrings("anthropic-messages", protocolName("anthropic-messages").?);
    try std.testing.expectEqualStrings("openai-chat-completions", protocolName("chat-completions").?);
}
