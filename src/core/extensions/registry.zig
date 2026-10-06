//! Registry ownership keeps provider contributions additive and session-local.
const std = @import("std");
const protocol = @import("protocol.zig");
const manifest_mod = @import("manifest.zig");
const io_mod = @import("../shared/io.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const types = @import("../shared/types.zig");
const provider_set = @import("../gateway/provider_set.zig");
const gateway_provider = @import("../gateway/gateway_provider.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const credentials = @import("../auth/credentials.zig");
const secret = @import("../auth/secret.zig");

const Allocator = std.mem.Allocator;
const public_model_id_format = "{s}/{s}";
const credential_scope_separator = "\x00";
const credential_scope_domain = "fx-extension-credential-v1";
const blank_key_bytes = " \t\r\n";
const first_printable_byte = ' ';
const terminal_delete_byte = 0x7f;

/// Borrowed descriptors remain valid until their owning registry is destroyed.
pub const ModelBinding = struct {
    extension_index: usize,
    provider: protocol.Provider,
    model: protocol.Model,
    public_id: []const u8,

    pub fn capabilities(self: ModelBinding) model_capabilities.Capabilities {
        var efforts: [types.ReasoningEffort.max_options]types.ReasoningEffort = undefined;
        var count: usize = 0;
        for (self.model.reasoning_efforts) |effort| {
            if (count == efforts.len) break;
            efforts[count] = types.ReasoningEffort.parse(effort) orelse continue;
            count += 1;
        }
        return .{
            .supports_reasoning = self.model.reasoning,
            .reasoning_efforts = model_capabilities.ReasoningEffortOptions.fromSlice(efforts[0..count]),
            .supports_tool_use = self.model.tool_call,
            .supports_vision = self.model.supports_vision,
            .context_window = self.model.context_window,
            .max_output_tokens = self.model.max_output_tokens,
        };
    }
};

const Loaded = struct {
    root: []u8,
    manifest: std.json.Parsed(manifest_mod.Manifest),
    catalogs: std.ArrayList(std.json.Parsed(protocol.ModelFile)) = .empty,

    fn deinit(self: *Loaded, alloc: Allocator) void {
        for (self.catalogs.items) |*catalog| catalog.deinit();
        self.catalogs.deinit(alloc);
        self.manifest.deinit();
        alloc.free(self.root);
    }
};

pub const Registry = struct {
    alloc: Allocator,
    entries: std.ArrayList(Loaded) = .empty,
    bindings: std.ArrayList(ModelBinding) = .empty,

    /// Scoped leases prevent a shared extension route from mixing independent keys.
    pub fn resolve_credential(self: *const Registry, alloc: Allocator, public_id: []const u8) !?credentials.Credential {
        const binding = self.resolve_model(public_id) orelse return error.ExtensionModelNotRegistered;
        const key = io_mod.getenv(binding.provider.api_key_env) orelse return null;
        if (std.mem.trim(u8, key, blank_key_bytes).len == 0) return null;
        for (key) |byte| if (byte < first_printable_byte or byte == terminal_delete_byte) return error.ExtensionCredentialInvalid;
        const owned_key = try alloc.dupe(u8, key);
        errdefer secret.zeroAndFree(alloc, owned_key);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(credential_scope_domain);
        for ([_][]const u8{ binding.provider.id, binding.provider.base_url, binding.provider.api_key_env }) |part| {
            hash.update(credential_scope_separator);
            hash.update(part);
        }
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        hash.final(&digest);
        const scope = std.fmt.bytesToHex(digest, .lower);
        return .{ .token = owned_key, .source = .extension_api_key, .account_id = try alloc.dupe(u8, &scope) };
    }

    /// Session-owned adapter contexts cannot replace the immutable built-in routes.
    pub fn attach(self: *Registry, builtins: provider_set.Set) provider_set.Set {
        var result = builtins;
        result.extension = .{
            .cli_model_catalog = .{ .context = self, .fetch_fn = catalog_ids },
        };
        return result;
    }

    /// Every public ID belongs to one provider; ambiguity cannot redirect credentials.
    pub fn resolve_model(self: *const Registry, public_id: []const u8) ?ModelBinding {
        for (self.bindings.items) |binding| if (std.mem.eql(u8, binding.public_id, public_id)) return binding;
        return null;
    }

    /// Caller owns the registry and must release it after all adapters stop using it.
    pub fn deinit(self: *Registry) void {
        for (self.bindings.items) |binding| self.alloc.free(binding.public_id);
        self.bindings.deinit(self.alloc);
        for (self.entries.items) |*entry| entry.deinit(self.alloc);
        self.entries.deinit(self.alloc);
    }
};

/// Owned copies keep CLI rendering independent of registry teardown.
fn catalog_ids(raw: ?*anyopaque, alloc: Allocator, input: gateway_provider.CliModelCatalogInput) gateway_provider.CliModelCatalogResult {
    const registry: *Registry = @ptrCast(@alignCast(raw.?));
    var ids: std.ArrayList([]u8) = .empty;
    var complete = false;
    defer if (!complete) {
        for (ids.items) |id| alloc.free(id);
        ids.deinit(alloc);
    };
    const failure: gateway_provider.CliModelCatalogResult = .{ .failure = .{
        .access = model_catalog.AccessMetadata.init(input.access),
        .anonymous_fallback_used = false,
        .failure = .{ .category = .resource_exhausted },
    } };
    for (registry.bindings.items) |binding| {
        const id = alloc.dupe(u8, binding.public_id) catch return failure;
        ids.append(alloc, id) catch {
            alloc.free(id);
            return failure;
        };
    }
    complete = true;
    var access = model_catalog.AccessMetadata.init(input.access);
    access.private_models_may_be_hidden = false;
    access.public_only_reason = null;
    return .{ .loaded = .{ .ids = ids, .provenance = .{ .access = access } } };
}

/// Missing profile registration is intentionally equivalent to upstream behavior.
pub fn load(alloc: Allocator, registry_path: []const u8) !Registry {
    var registry = Registry{ .alloc = alloc };
    errdefer registry.deinit();
    var parsed = manifest_mod.read_json(manifest_mod.RegistryFile, alloc, registry_path, protocol.max_manifest_bytes) catch |err| {
        if (err == error.FileNotFound) return registry;
        return err;
    };
    defer parsed.deinit();
    if (parsed.value.version != protocol.version) return error.ExtensionVersionUnsupported;
    const registry_dir = std.fs.path.dirname(registry_path) orelse return error.ExtensionPathInvalid;
    for (parsed.value.extensions) |registration| {
        const joined = try std.fs.path.resolve(alloc, &.{ registry_dir, registration.path });
        defer alloc.free(joined);
        const root = try io_mod.realpathAlloc(alloc, joined);
        var owns_root = true;
        errdefer if (owns_root) alloc.free(root);
        const path = try manifest_mod.canonical_child_path(alloc, root, protocol.manifest_name);
        defer alloc.free(path);
        const extension = try manifest_mod.read_json(manifest_mod.Manifest, alloc, path, protocol.max_manifest_bytes);
        var loaded = Loaded{ .root = root, .manifest = extension };
        owns_root = false;
        errdefer loaded.deinit(alloc);
        if (extension.value.version != protocol.version) return error.ExtensionVersionUnsupported;
        try manifest_mod.validate_id(extension.value.id);
        for (registry.entries.items) |entry| {
            if (std.mem.eql(u8, entry.manifest.value.id, extension.value.id)) return error.ExtensionIdDuplicate;
        }
        const entrypoint = try manifest_mod.owned_child_path(alloc, root, extension.value.entrypoint);
        alloc.free(entrypoint);
        for (extension.value.capabilities) |capability| {
            if (!std.mem.eql(u8, capability, protocol.provider_capability)) return error.ExtensionCapabilityUnsupported;
        }
        for (extension.value.providers) |provider| {
            try manifest_mod.validate_id(provider.id);
            for (protocol.reserved_provider_ids) |reserved| {
                if (std.ascii.eqlIgnoreCase(reserved, provider.id)) return error.ExtensionProviderReserved;
            }
            for (registry.bindings.items) |binding| {
                if (std.mem.eql(u8, binding.provider.id, provider.id)) return error.ExtensionProviderDuplicate;
            }
            try manifest_mod.validate_endpoint(provider.base_url);
            if (provider.api_key_env.len == 0) return error.ExtensionCredentialReferenceInvalid;
            const models_path = try manifest_mod.canonical_child_path(alloc, root, provider.models_file);
            defer alloc.free(models_path);
            var catalog = try manifest_mod.read_json(protocol.ModelFile, alloc, models_path, protocol.max_models_bytes);
            loaded.catalogs.append(alloc, catalog) catch |err| {
                catalog.deinit();
                return err;
            };
            for (catalog.value.models) |model| {
                try manifest_mod.validate_model_id(model.id);
                try manifest_mod.validate_model_id(model.wire_id);
                const public_id = try std.fmt.allocPrint(alloc, public_model_id_format, .{ provider.id, model.id });
                errdefer alloc.free(public_id);
                if (registry.resolve_model(public_id) != null) return error.ExtensionModelDuplicate;
                try registry.bindings.append(alloc, .{
                    .extension_index = registry.entries.items.len,
                    .provider = provider,
                    .model = model,
                    .public_id = public_id,
                });
            }
        }
        try registry.entries.append(alloc, loaded);
    }
    return registry;
}
