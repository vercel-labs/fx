//! Versioned data contracts keep extensions independent of fx runtime layout.
const std = @import("std");

pub const version: u32 = 1;
pub const manifest_name = "extension.json";
pub const registry_relative_path = ".fx/extension.json";
pub const provider_capability = "providers";
pub const max_manifest_bytes = 1024 * 1024;
pub const max_models_bytes = 8 * 1024 * 1024;
pub const reserved_provider_ids = [_][]const u8{ "gateway", "vercel", "codex", "grok", "extension" };

/// Credentials remain environment references until an admitted request needs them.
pub const Provider = struct {
    id: []const u8,
    base_url: []const u8,
    api_key_env: []const u8,
    models_file: []const u8,
    headers: ?std.json.Value = null,
};

/// Catalog snapshots stay offline so installing an extension cannot add startup I/O.
pub const Model = struct {
    id: []const u8,
    wire_id: []const u8,
    name: []const u8,
    tool_call: bool = false,
    reasoning: bool = false,
    reasoning_efforts: []const []const u8 = &.{},
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
    supports_vision: bool = false,
    structured_output: bool = false,
};

pub const ModelFile = struct {
    source: ?[]const u8 = null,
    retrieved_at: ?[]const u8 = null,
    source_digest: ?[]const u8 = null,
    models: []const Model,
};
