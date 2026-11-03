//! Cursor's model catalog, from proto's packages/catalog/src/models/cursor.json
//! (D204). Effort selection routes to the wire id Cursor discovery reported
//! for that effort (`effortRouting`, with `off` for no reasoning effort), and
//! `max_mode` is the catalog's `cursorMaxMode`, or the `-xhigh`/`-max` tier
//! rule proto falls back to. Vision capability remains catalog metadata; the
//! Cursor request transport serializes verified images when routing permits.
const std = @import("std");
const types = @import("../core/shared/types.zig");
const configured_provider = @import("../core/config/configured_provider.zig");
const ModelMetadata = configured_provider.ModelMetadata;
const ModelCost = configured_provider.ModelCost;

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    context_window: u32,
    max_output_tokens: u32,
    efforts: []const []const u8 = &.{},
    /// Effort name (or "off") to the wire id it runs as, where it differs.
    routes: []const [2][]const u8 = &.{},
    max_mode: ?bool = null,
    cost: ModelCost = .{},
    description: ?[]const u8 = null,
    intelligence: ?f64 = null,
};

pub const default_model = "composer-2.5";
/// The fast model for titles and permission reviews.
pub const small_model = "composer-2.5-fast";

pub const models = [_]Model{
    .{ .id = "claude-4-sonnet", .name = "Claude Sonnet 4", .context_window = 200000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-4-sonnet-thinking" }, .{ "low", "claude-4-sonnet-thinking" }, .{ "medium", "claude-4-sonnet-thinking" }, .{ "high", "claude-4-sonnet-thinking" } }, .max_mode = false },
    .{ .id = "claude-4.5-opus-high", .name = "Claude Opus 4.5", .context_window = 200000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-4.5-opus-high-thinking" }, .{ "low", "claude-4.5-opus-high-thinking" }, .{ "medium", "claude-4.5-opus-high-thinking" }, .{ "high", "claude-4.5-opus-high-thinking" } }, .max_mode = false },
    .{ .id = "claude-4.5-sonnet", .name = "Claude Sonnet 4.5", .context_window = 200000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-4.5-sonnet-thinking" }, .{ "low", "claude-4.5-sonnet-thinking" }, .{ "medium", "claude-4.5-sonnet-thinking" }, .{ "high", "claude-4.5-sonnet-thinking" } }, .max_mode = false },
    .{ .id = "claude-4.6-opus-high", .name = "Claude Opus 4.6 1M", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-4.6-opus-high-thinking" }, .{ "low", "claude-4.6-opus-high-thinking" }, .{ "medium", "claude-4.6-opus-high-thinking" }, .{ "high", "claude-4.6-opus-high-thinking" } }, .max_mode = false },
    .{ .id = "claude-4.6-opus-max", .name = "Claude Opus 4.6 1M Max", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-4.6-opus-max-thinking" }, .{ "low", "claude-4.6-opus-max-thinking" }, .{ "medium", "claude-4.6-opus-max-thinking" }, .{ "high", "claude-4.6-opus-max-thinking" } }, .max_mode = false },
    .{ .id = "claude-4.6-sonnet-medium", .name = "Claude Sonnet 4.6 1M", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-4.6-sonnet-medium-thinking" }, .{ "low", "claude-4.6-sonnet-medium-thinking" }, .{ "medium", "claude-4.6-sonnet-medium-thinking" }, .{ "high", "claude-4.6-sonnet-medium-thinking" } }, .max_mode = false },
    .{ .id = "claude-fable-5-high", .name = "Claude Fable 5 1M (NO ZDR)", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-fable-5-thinking-high" }, .{ "low", "claude-fable-5-thinking-high" }, .{ "medium", "claude-fable-5-thinking-high" }, .{ "high", "claude-fable-5-thinking-high" } }, .max_mode = false },
    .{ .id = "claude-fable-5-low", .name = "Claude Fable 5 1M Low (NO ZDR)", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-fable-5-thinking-low" }, .{ "low", "claude-fable-5-thinking-low" }, .{ "medium", "claude-fable-5-thinking-low" }, .{ "high", "claude-fable-5-thinking-low" } }, .max_mode = false },
    .{ .id = "claude-fable-5-max", .name = "Claude Fable 5 1M Max (NO ZDR)", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-fable-5-thinking-max" }, .{ "low", "claude-fable-5-thinking-max" }, .{ "medium", "claude-fable-5-thinking-max" }, .{ "high", "claude-fable-5-thinking-max" } }, .max_mode = false },
    .{ .id = "claude-fable-5-medium", .name = "Claude Fable 5 1M Medium (NO ZDR)", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-fable-5-thinking-medium" }, .{ "low", "claude-fable-5-thinking-medium" }, .{ "medium", "claude-fable-5-thinking-medium" }, .{ "high", "claude-fable-5-thinking-medium" } }, .max_mode = false },
    .{ .id = "claude-fable-5-xhigh", .name = "Claude Fable 5 1M Extra High (NO ZDR)", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-fable-5-thinking-xhigh" }, .{ "low", "claude-fable-5-thinking-xhigh" }, .{ "medium", "claude-fable-5-thinking-xhigh" }, .{ "high", "claude-fable-5-thinking-xhigh" } }, .max_mode = false },
    .{ .id = "claude-opus-4-7-high", .name = "Claude Opus 4.7 1M High", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-7-thinking-high" }, .{ "low", "claude-opus-4-7-thinking-high" }, .{ "medium", "claude-opus-4-7-thinking-high" }, .{ "high", "claude-opus-4-7-thinking-high" } }, .max_mode = false },
    .{ .id = "claude-opus-4-7-high-fast", .name = "Claude Opus 4.7 1M High Fast", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-7-thinking-high-fast" }, .{ "low", "claude-opus-4-7-thinking-high-fast" }, .{ "medium", "claude-opus-4-7-thinking-high-fast" }, .{ "high", "claude-opus-4-7-thinking-high-fast" } }, .max_mode = true },
    .{ .id = "claude-opus-4-7-low", .name = "Claude Opus 4.7 1M Low", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-7-thinking-low" }, .{ "low", "claude-opus-4-7-thinking-low" }, .{ "medium", "claude-opus-4-7-thinking-low" }, .{ "high", "claude-opus-4-7-thinking-low" } }, .max_mode = false },
    .{ .id = "claude-opus-4-7-low-fast", .name = "Claude Opus 4.7 1M Low Fast", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-7-thinking-low-fast" }, .{ "low", "claude-opus-4-7-thinking-low-fast" }, .{ "medium", "claude-opus-4-7-thinking-low-fast" }, .{ "high", "claude-opus-4-7-thinking-low-fast" } }, .max_mode = true },
    .{ .id = "claude-opus-4-7-max", .name = "Claude Opus 4.7 1M Max", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-7-thinking-max" }, .{ "low", "claude-opus-4-7-thinking-max" }, .{ "medium", "claude-opus-4-7-thinking-max" }, .{ "high", "claude-opus-4-7-thinking-max" } }, .max_mode = false },
    .{ .id = "claude-opus-4-7-max-fast", .name = "Claude Opus 4.7 1M Max Fast", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-7-thinking-max-fast" }, .{ "low", "claude-opus-4-7-thinking-max-fast" }, .{ "medium", "claude-opus-4-7-thinking-max-fast" }, .{ "high", "claude-opus-4-7-thinking-max-fast" } }, .max_mode = true },
    .{ .id = "claude-opus-4-7-medium", .name = "Claude Opus 4.7 1M Medium", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-7-thinking-medium" }, .{ "low", "claude-opus-4-7-thinking-medium" }, .{ "medium", "claude-opus-4-7-thinking-medium" }, .{ "high", "claude-opus-4-7-thinking-medium" } }, .max_mode = false },
    .{ .id = "claude-opus-4-7-medium-fast", .name = "Claude Opus 4.7 1M Medium Fast", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-7-thinking-medium-fast" }, .{ "low", "claude-opus-4-7-thinking-medium-fast" }, .{ "medium", "claude-opus-4-7-thinking-medium-fast" }, .{ "high", "claude-opus-4-7-thinking-medium-fast" } }, .max_mode = true },
    .{ .id = "claude-opus-4-7-xhigh", .name = "Claude Opus 4.7 1M", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-7-thinking-xhigh" }, .{ "low", "claude-opus-4-7-thinking-xhigh" }, .{ "medium", "claude-opus-4-7-thinking-xhigh" }, .{ "high", "claude-opus-4-7-thinking-xhigh" } }, .max_mode = false },
    .{ .id = "claude-opus-4-7-xhigh-fast", .name = "Claude Opus 4.7 1M Fast", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-7-thinking-xhigh-fast" }, .{ "low", "claude-opus-4-7-thinking-xhigh-fast" }, .{ "medium", "claude-opus-4-7-thinking-xhigh-fast" }, .{ "high", "claude-opus-4-7-thinking-xhigh-fast" } }, .max_mode = true },
    .{ .id = "claude-opus-4-8-high", .name = "Claude Opus 4.8 1M", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-8-thinking-high" }, .{ "low", "claude-opus-4-8-thinking-high" }, .{ "medium", "claude-opus-4-8-thinking-high" }, .{ "high", "claude-opus-4-8-thinking-high" } }, .max_mode = false },
    .{ .id = "claude-opus-4-8-high-fast", .name = "Claude Opus 4.8 1M Fast", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-8-thinking-high-fast" }, .{ "low", "claude-opus-4-8-thinking-high-fast" }, .{ "medium", "claude-opus-4-8-thinking-high-fast" }, .{ "high", "claude-opus-4-8-thinking-high-fast" } }, .max_mode = true },
    .{ .id = "claude-opus-4-8-low", .name = "Claude Opus 4.8 1M Low", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-8-thinking-low" }, .{ "low", "claude-opus-4-8-thinking-low" }, .{ "medium", "claude-opus-4-8-thinking-low" }, .{ "high", "claude-opus-4-8-thinking-low" } }, .max_mode = false },
    .{ .id = "claude-opus-4-8-low-fast", .name = "Claude Opus 4.8 1M Low Fast", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-8-thinking-low-fast" }, .{ "low", "claude-opus-4-8-thinking-low-fast" }, .{ "medium", "claude-opus-4-8-thinking-low-fast" }, .{ "high", "claude-opus-4-8-thinking-low-fast" } }, .max_mode = true },
    .{ .id = "claude-opus-4-8-max", .name = "Claude Opus 4.8 1M Max", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-8-thinking-max" }, .{ "low", "claude-opus-4-8-thinking-max" }, .{ "medium", "claude-opus-4-8-thinking-max" }, .{ "high", "claude-opus-4-8-thinking-max" } }, .max_mode = false },
    .{ .id = "claude-opus-4-8-max-fast", .name = "Claude Opus 4.8 1M Max Fast", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-8-thinking-max-fast" }, .{ "low", "claude-opus-4-8-thinking-max-fast" }, .{ "medium", "claude-opus-4-8-thinking-max-fast" }, .{ "high", "claude-opus-4-8-thinking-max-fast" } }, .max_mode = true },
    .{ .id = "claude-opus-4-8-medium", .name = "Claude Opus 4.8 1M Medium", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-8-thinking-medium" }, .{ "low", "claude-opus-4-8-thinking-medium" }, .{ "medium", "claude-opus-4-8-thinking-medium" }, .{ "high", "claude-opus-4-8-thinking-medium" } }, .max_mode = false },
    .{ .id = "claude-opus-4-8-medium-fast", .name = "Claude Opus 4.8 1M Medium Fast", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-8-thinking-medium-fast" }, .{ "low", "claude-opus-4-8-thinking-medium-fast" }, .{ "medium", "claude-opus-4-8-thinking-medium-fast" }, .{ "high", "claude-opus-4-8-thinking-medium-fast" } }, .max_mode = true },
    .{ .id = "claude-opus-4-8-xhigh", .name = "Claude Opus 4.8 1M Extra High", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-8-thinking-xhigh" }, .{ "low", "claude-opus-4-8-thinking-xhigh" }, .{ "medium", "claude-opus-4-8-thinking-xhigh" }, .{ "high", "claude-opus-4-8-thinking-xhigh" } }, .max_mode = false },
    .{ .id = "claude-opus-4-8-xhigh-fast", .name = "Claude Opus 4.8 1M Extra High Fast", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-4-8-thinking-xhigh-fast" }, .{ "low", "claude-opus-4-8-thinking-xhigh-fast" }, .{ "medium", "claude-opus-4-8-thinking-xhigh-fast" }, .{ "high", "claude-opus-4-8-thinking-xhigh-fast" } }, .max_mode = true },
    .{ .id = "claude-opus-5-high", .name = "Claude Opus 5 1M", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-5-thinking-high" }, .{ "low", "claude-opus-5-thinking-high" }, .{ "medium", "claude-opus-5-thinking-high" }, .{ "high", "claude-opus-5-thinking-high" } }, .max_mode = false },
    .{ .id = "claude-opus-5-high-fast", .name = "Claude Opus 5 1M Fast", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-5-thinking-high-fast" }, .{ "low", "claude-opus-5-thinking-high-fast" }, .{ "medium", "claude-opus-5-thinking-high-fast" }, .{ "high", "claude-opus-5-thinking-high-fast" } }, .max_mode = true },
    .{ .id = "claude-opus-5-low", .name = "Claude Opus 5 1M Low", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-5-thinking-low" }, .{ "low", "claude-opus-5-thinking-low" }, .{ "medium", "claude-opus-5-thinking-low" }, .{ "high", "claude-opus-5-thinking-low" } }, .max_mode = false },
    .{ .id = "claude-opus-5-low-fast", .name = "Claude Opus 5 1M Low Fast", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-5-thinking-low-fast" }, .{ "low", "claude-opus-5-thinking-low-fast" }, .{ "medium", "claude-opus-5-thinking-low-fast" }, .{ "high", "claude-opus-5-thinking-low-fast" } }, .max_mode = true },
    .{ .id = "claude-opus-5-medium", .name = "Claude Opus 5 1M Medium", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-5-thinking-medium" }, .{ "low", "claude-opus-5-thinking-medium" }, .{ "medium", "claude-opus-5-thinking-medium" }, .{ "high", "claude-opus-5-thinking-medium" } }, .max_mode = false },
    .{ .id = "claude-opus-5-medium-fast", .name = "Claude Opus 5 1M Medium Fast", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-opus-5-thinking-medium-fast" }, .{ "low", "claude-opus-5-thinking-medium-fast" }, .{ "medium", "claude-opus-5-thinking-medium-fast" }, .{ "high", "claude-opus-5-thinking-medium-fast" } }, .max_mode = true },
    .{ .id = "claude-opus-5-thinking-max", .name = "Claude Opus 5 1M Max Thinking", .context_window = 1000000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "claude-opus-5-thinking-max-fast", .name = "Claude Opus 5 1M Max Thinking Fast", .context_window = 1000000, .max_output_tokens = 64000, .max_mode = true },
    .{ .id = "claude-opus-5-thinking-xhigh", .name = "Claude Opus 5 1M Extra High Thinking", .context_window = 1000000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "claude-opus-5-thinking-xhigh-fast", .name = "Claude Opus 5 1M Extra High Thinking Fast", .context_window = 1000000, .max_output_tokens = 64000, .max_mode = true },
    .{ .id = "claude-sonnet-5-high", .name = "Claude Sonnet 5 1M", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-sonnet-5-thinking-high" }, .{ "low", "claude-sonnet-5-thinking-high" }, .{ "medium", "claude-sonnet-5-thinking-high" }, .{ "high", "claude-sonnet-5-thinking-high" } }, .max_mode = false },
    .{ .id = "claude-sonnet-5-low", .name = "Claude Sonnet 5 1M Low", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-sonnet-5-thinking-low" }, .{ "low", "claude-sonnet-5-thinking-low" }, .{ "medium", "claude-sonnet-5-thinking-low" }, .{ "high", "claude-sonnet-5-thinking-low" } }, .max_mode = false },
    .{ .id = "claude-sonnet-5-max", .name = "Claude Sonnet 5 1M Max", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-sonnet-5-thinking-max" }, .{ "low", "claude-sonnet-5-thinking-max" }, .{ "medium", "claude-sonnet-5-thinking-max" }, .{ "high", "claude-sonnet-5-thinking-max" } }, .max_mode = false },
    .{ .id = "claude-sonnet-5-medium", .name = "Claude Sonnet 5 1M Medium", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-sonnet-5-thinking-medium" }, .{ "low", "claude-sonnet-5-thinking-medium" }, .{ "medium", "claude-sonnet-5-thinking-medium" }, .{ "high", "claude-sonnet-5-thinking-medium" } }, .max_mode = false },
    .{ .id = "claude-sonnet-5-xhigh", .name = "Claude Sonnet 5 1M Extra High", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "claude-sonnet-5-thinking-xhigh" }, .{ "low", "claude-sonnet-5-thinking-xhigh" }, .{ "medium", "claude-sonnet-5-thinking-xhigh" }, .{ "high", "claude-sonnet-5-thinking-xhigh" } }, .max_mode = false },
    .{ .id = "composer-1", .name = "Composer 1", .context_window = 200000, .max_output_tokens = 64000 },
    .{ .id = "composer-1.5", .name = "Composer 1.5", .context_window = 200000, .max_output_tokens = 64000 },
    .{ .id = "composer-2.5", .name = "Composer 2.5", .context_window = 200000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "composer-2.5-fast", .name = "Composer 2.5 Fast", .context_window = 200000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "cursor-grok-4.5", .name = "Grok 4.5", .context_window = 256000, .max_output_tokens = 64000, .efforts = &.{ "low", "medium", "high" }, .routes = &.{ .{ "low", "cursor-grok-4.5-low" }, .{ "medium", "cursor-grok-4.5-medium" }, .{ "high", "cursor-grok-4.5-high" } }, .max_mode = false },
    .{ .id = "cursor-grok-4.5-fast", .name = "Grok 4.5 Fast", .context_window = 256000, .max_output_tokens = 64000, .efforts = &.{ "low", "medium", "high" }, .routes = &.{ .{ "low", "cursor-grok-4.5-low-fast" }, .{ "medium", "cursor-grok-4.5-medium-fast" }, .{ "high", "cursor-grok-4.5-high-fast" } }, .max_mode = false },
    .{ .id = "cursor-grok-4.6", .name = "Grok 4.6", .context_window = 256000, .max_output_tokens = 64000, .efforts = &.{ "low", "medium", "high", "xhigh" }, .routes = &.{ .{ "low", "cursor-grok-4.6-low" }, .{ "medium", "cursor-grok-4.6-medium" }, .{ "high", "cursor-grok-4.6-high" }, .{ "xhigh", "cursor-grok-4.6-xhigh" } }, .max_mode = true },
    .{ .id = "cursor-grok-4.6-fast", .name = "Grok 4.6 Fast", .context_window = 256000, .max_output_tokens = 64000, .efforts = &.{ "low", "medium", "high", "xhigh" }, .routes = &.{ .{ "low", "cursor-grok-4.6-low-fast" }, .{ "medium", "cursor-grok-4.6-medium-fast" }, .{ "high", "cursor-grok-4.6-high-fast" }, .{ "xhigh", "cursor-grok-4.6-xhigh-fast" } }, .max_mode = true },
    .{ .id = "default", .name = "Auto", .context_window = 256000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "gemini-3-flash", .name = "Gemini 3 Flash", .context_window = 1048576, .max_output_tokens = 65536, .efforts = &.{ "minimal", "low", "medium", "high" }, .max_mode = false },
    .{ .id = "gemini-3-pro", .name = "Gemini 3 Pro", .context_window = 1048576, .max_output_tokens = 65536, .efforts = &.{ "low", "high" } },
    .{ .id = "gemini-3.1-pro", .name = "Gemini 3.1 Pro Preview", .context_window = 1048576, .max_output_tokens = 65536, .efforts = &.{ "low", "high" }, .max_mode = false },
    .{ .id = "gemini-3.5-flash", .name = "Gemini 3.5 Flash", .context_window = 200000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .max_mode = false },
    .{ .id = "gemini-3.6-flash", .name = "Gemini 3.6 Flash", .context_window = 200000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .routes = &.{ .{ "minimal", "gemini-3.6-flash-minimal" }, .{ "low", "gemini-3.6-flash-low" }, .{ "medium", "gemini-3.6-flash-medium" }, .{ "high", "gemini-3.6-flash-high" } }, .max_mode = false },
    .{ .id = "gemini-3.7-flash", .name = "Gemini 3.7 Flash", .context_window = 200000, .max_output_tokens = 64000, .efforts = &.{ "low", "medium", "high" }, .routes = &.{ .{ "low", "gemini-3.7-flash-low" }, .{ "medium", "gemini-3.7-flash-medium" }, .{ "high", "gemini-3.7-flash-high" } }, .max_mode = false },
    .{ .id = "glm-5.2", .name = "GLM-5.2", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "high", "max" }, .routes = &.{ .{ "high", "glm-5.2-high" }, .{ "max", "glm-5.2-max" } }, .max_mode = false },
    .{ .id = "gpt-5-mini", .name = "GPT-5 Mini", .context_window = 200000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .max_mode = false },
    .{ .id = "gpt-5.1", .name = "GPT-5.1", .context_window = 200000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .max_mode = false },
    .{ .id = "gpt-5.1-codex-max", .name = "GPT-5.1 Codex Max", .context_window = 272000, .max_output_tokens = 128000, .efforts = &.{ "minimal", "low", "medium", "high" } },
    .{ .id = "gpt-5.1-codex-max-high", .name = "GPT-5.1 Codex Max High", .context_window = 272000, .max_output_tokens = 128000, .efforts = &.{ "minimal", "low", "medium", "high" } },
    .{ .id = "gpt-5.1-codex-mini", .name = "GPT-5.1 Codex Mini", .context_window = 272000, .max_output_tokens = 128000, .efforts = &.{ "medium", "high" } },
    .{ .id = "gpt-5.1-high", .name = "GPT-5.1 High", .context_window = 200000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "gpt-5.1-low", .name = "GPT-5.1 Low", .context_window = 200000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "gpt-5.2", .name = "GPT-5.2", .context_window = 400000, .max_output_tokens = 128000, .efforts = &.{ "low", "medium", "high", "xhigh" }, .max_mode = false },
    .{ .id = "gpt-5.2-codex", .name = "GPT-5.2 Codex", .context_window = 272000, .max_output_tokens = 128000, .efforts = &.{ "low", "medium", "high", "xhigh" } },
    .{ .id = "gpt-5.2-codex-fast", .name = "GPT-5.2 Codex Fast", .context_window = 272000, .max_output_tokens = 64000 },
    .{ .id = "gpt-5.2-codex-high", .name = "GPT-5.2 Codex High", .context_window = 272000, .max_output_tokens = 64000 },
    .{ .id = "gpt-5.2-codex-high-fast", .name = "GPT-5.2 Codex High Fast", .context_window = 272000, .max_output_tokens = 64000 },
    .{ .id = "gpt-5.2-codex-low", .name = "GPT-5.2 Codex Low", .context_window = 272000, .max_output_tokens = 64000 },
    .{ .id = "gpt-5.2-codex-low-fast", .name = "GPT-5.2 Codex Low Fast", .context_window = 272000, .max_output_tokens = 64000 },
    .{ .id = "gpt-5.2-codex-xhigh", .name = "GPT-5.2 Codex Extra High", .context_window = 272000, .max_output_tokens = 64000 },
    .{ .id = "gpt-5.2-codex-xhigh-fast", .name = "GPT-5.2 Codex Extra High Fast", .context_window = 272000, .max_output_tokens = 64000 },
    .{ .id = "gpt-5.2-fast", .name = "GPT-5.2 Fast", .context_window = 200000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "gpt-5.2-high", .name = "GPT-5.2 High", .context_window = 400000, .max_output_tokens = 128000, .efforts = &.{ "low", "medium", "high", "xhigh" }, .max_mode = false },
    .{ .id = "gpt-5.2-high-fast", .name = "GPT-5.2 High Fast", .context_window = 200000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "gpt-5.2-low", .name = "GPT-5.2 Low", .context_window = 200000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "gpt-5.2-low-fast", .name = "GPT-5.2 Low Fast", .context_window = 200000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "gpt-5.2-xhigh", .name = "GPT-5.2 Extra High", .context_window = 200000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "gpt-5.2-xhigh-fast", .name = "GPT-5.2 Extra High Fast", .context_window = 200000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "gpt-5.3-codex", .name = "GPT-5.3 Codex", .context_window = 272000, .max_output_tokens = 128000, .efforts = &.{ "low", "medium", "high", "xhigh" }, .max_mode = false },
    .{ .id = "gpt-5.3-codex-fast", .name = "Codex 5.3 Fast", .context_window = 272000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "gpt-5.3-codex-high", .name = "Codex 5.3 High", .context_window = 272000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "gpt-5.3-codex-high-fast", .name = "Codex 5.3 High Fast", .context_window = 272000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "gpt-5.3-codex-low", .name = "Codex 5.3 Low", .context_window = 272000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "gpt-5.3-codex-low-fast", .name = "Codex 5.3 Low Fast", .context_window = 272000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "gpt-5.3-codex-spark-preview", .name = "GPT-5.3 Codex Spark", .context_window = 200000, .max_output_tokens = 64000 },
    .{ .id = "gpt-5.3-codex-xhigh", .name = "Codex 5.3 Extra High", .context_window = 272000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "gpt-5.3-codex-xhigh-fast", .name = "Codex 5.3 Extra High Fast", .context_window = 272000, .max_output_tokens = 64000, .max_mode = false },
    .{ .id = "gpt-5.4", .name = "GPT-5.4", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "low", "medium", "high", "xhigh" }, .routes = &.{ .{ "low", "gpt-5.4-low" }, .{ "medium", "gpt-5.4-medium" }, .{ "high", "gpt-5.4-high" }, .{ "xhigh", "gpt-5.4-xhigh" } }, .max_mode = false },
    .{ .id = "gpt-5.4-fast", .name = "GPT-5.4 Fast", .context_window = 200000, .max_output_tokens = 64000, .efforts = &.{ "medium", "high", "xhigh" }, .routes = &.{ .{ "medium", "gpt-5.4-medium-fast" }, .{ "high", "gpt-5.4-high-fast" }, .{ "xhigh", "gpt-5.4-xhigh-fast" } }, .max_mode = false },
    .{ .id = "gpt-5.4-mini", .name = "GPT-5.4 mini", .context_window = 200000, .max_output_tokens = 64000, .efforts = &.{ "low", "medium", "high", "xhigh" }, .routes = &.{ .{ "off", "gpt-5.4-mini-none" }, .{ "low", "gpt-5.4-mini-low" }, .{ "medium", "gpt-5.4-mini-medium" }, .{ "high", "gpt-5.4-mini-high" }, .{ "xhigh", "gpt-5.4-mini-xhigh" } }, .max_mode = false },
    .{ .id = "gpt-5.4-nano", .name = "GPT-5.4 nano", .context_window = 200000, .max_output_tokens = 64000, .efforts = &.{ "low", "medium", "high", "xhigh" }, .routes = &.{ .{ "off", "gpt-5.4-nano-none" }, .{ "low", "gpt-5.4-nano-low" }, .{ "medium", "gpt-5.4-nano-medium" }, .{ "high", "gpt-5.4-nano-high" }, .{ "xhigh", "gpt-5.4-nano-xhigh" } }, .max_mode = false },
    .{ .id = "gpt-5.5", .name = "GPT-5.5", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "low", "medium", "high", "xhigh" }, .routes = &.{ .{ "off", "gpt-5.5-none" }, .{ "low", "gpt-5.5-low" }, .{ "medium", "gpt-5.5-medium" }, .{ "high", "gpt-5.5-high" }, .{ "xhigh", "gpt-5.5-extra-high" } }, .max_mode = false },
    .{ .id = "gpt-5.5-fast", .name = "GPT-5.5 Extra Fast", .context_window = 200000, .max_output_tokens = 64000, .efforts = &.{ "low", "medium", "high", "xhigh" }, .routes = &.{ .{ "off", "gpt-5.5-none-fast" }, .{ "low", "gpt-5.5-low-fast" }, .{ "medium", "gpt-5.5-medium-fast" }, .{ "high", "gpt-5.5-high-fast" }, .{ "xhigh", "gpt-5.5-extra-high-fast" } }, .max_mode = false },
    .{ .id = "gpt-5.6-luna", .name = "GPT-5.6 Luna", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "low", "medium", "high", "xhigh", "max" }, .routes = &.{ .{ "off", "gpt-5.6-luna-none" }, .{ "low", "gpt-5.6-luna-low" }, .{ "medium", "gpt-5.6-luna-medium" }, .{ "high", "gpt-5.6-luna-high" }, .{ "xhigh", "gpt-5.6-luna-xhigh" }, .{ "max", "gpt-5.6-luna-max" } }, .max_mode = true },
    .{ .id = "gpt-5.6-luna-fast", .name = "GPT-5.6 Luna Fast", .context_window = 272000, .max_output_tokens = 64000, .efforts = &.{ "low", "medium", "high", "xhigh", "max" }, .routes = &.{ .{ "off", "gpt-5.6-luna-none-fast" }, .{ "low", "gpt-5.6-luna-low-fast" }, .{ "medium", "gpt-5.6-luna-medium-fast" }, .{ "high", "gpt-5.6-luna-high-fast" }, .{ "xhigh", "gpt-5.6-luna-xhigh-fast" }, .{ "max", "gpt-5.6-luna-max-fast" } }, .max_mode = true },
    .{ .id = "gpt-5.6-sol", .name = "GPT-5.6 Sol", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "low", "medium", "high", "xhigh", "max" }, .routes = &.{ .{ "off", "gpt-5.6-sol-none" }, .{ "low", "gpt-5.6-sol-low" }, .{ "medium", "gpt-5.6-sol-medium" }, .{ "high", "gpt-5.6-sol-high" }, .{ "xhigh", "gpt-5.6-sol-xhigh" }, .{ "max", "gpt-5.6-sol-max" } }, .max_mode = true },
    .{ .id = "gpt-5.6-sol-fast", .name = "GPT-5.6 Sol Fast", .context_window = 272000, .max_output_tokens = 64000, .efforts = &.{ "low", "medium", "high", "xhigh", "max" }, .routes = &.{ .{ "off", "gpt-5.6-sol-none-fast" }, .{ "low", "gpt-5.6-sol-low-fast" }, .{ "medium", "gpt-5.6-sol-medium-fast" }, .{ "high", "gpt-5.6-sol-high-fast" }, .{ "xhigh", "gpt-5.6-sol-xhigh-fast" }, .{ "max", "gpt-5.6-sol-max-fast" } }, .max_mode = true },
    .{ .id = "gpt-5.6-terra", .name = "GPT-5.6 Terra", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "low", "medium", "high", "xhigh", "max" }, .routes = &.{ .{ "off", "gpt-5.6-terra-none" }, .{ "low", "gpt-5.6-terra-low" }, .{ "medium", "gpt-5.6-terra-medium" }, .{ "high", "gpt-5.6-terra-high" }, .{ "xhigh", "gpt-5.6-terra-xhigh" }, .{ "max", "gpt-5.6-terra-max" } }, .max_mode = true },
    .{ .id = "gpt-5.6-terra-fast", .name = "GPT-5.6 Terra Fast", .context_window = 272000, .max_output_tokens = 64000, .efforts = &.{ "low", "medium", "high", "xhigh", "max" }, .routes = &.{ .{ "off", "gpt-5.6-terra-none-fast" }, .{ "low", "gpt-5.6-terra-low-fast" }, .{ "medium", "gpt-5.6-terra-medium-fast" }, .{ "high", "gpt-5.6-terra-high-fast" }, .{ "xhigh", "gpt-5.6-terra-xhigh-fast" }, .{ "max", "gpt-5.6-terra-max-fast" } }, .max_mode = true },
    .{ .id = "grok-code-fast-1", .name = "Grok Code Fast 1", .context_window = 256000, .max_output_tokens = 10000, .efforts = &.{ "minimal", "low", "medium", "high" } },
    .{ .id = "kimi-k2.5", .name = "kimi-k2.5", .context_window = 262144, .max_output_tokens = 65536, .efforts = &.{ "minimal", "low", "medium", "high" } },
    .{ .id = "kimi-k2.7-code", .name = "Kimi K2.7 Code", .context_window = 262000, .max_output_tokens = 64000, .efforts = &.{ "minimal", "low", "medium", "high" }, .max_mode = false },
    .{ .id = "kimi-k3-high", .name = "Kimi K3 High", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "low", "high", "max" }, .max_mode = false },
    .{ .id = "kimi-k3-low", .name = "Kimi K3 Low", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "low", "high", "max" }, .max_mode = false },
    .{ .id = "kimi-k3-max", .name = "Kimi K3", .context_window = 1000000, .max_output_tokens = 64000, .efforts = &.{ "low", "high", "max" }, .max_mode = false },
};

pub fn find(id: []const u8) ?*const Model {
    for (&models) |*model| if (std.mem.eql(u8, model.id, id)) return model;
    return null;
}

/// The wire id for `id` at `effort` (null for none), and whether it runs in
/// max mode.
pub fn route(id: []const u8, effort: ?[]const u8) struct { wire_id: []const u8, max_mode: bool } {
    const model = find(id) orelse return .{ .wire_id = id, .max_mode = maxModeTier(id) };
    const key = effort orelse "off";
    var wire_id = id;
    for (model.routes) |entry| if (std.mem.eql(u8, entry[0], key)) {
        wire_id = entry[1];
    };
    return .{ .wire_id = wire_id, .max_mode = model.max_mode orelse maxModeTier(wire_id) };
}

/// proto's `isCursorMaxModeWireId`: the `-xhigh` and `-max` tiers, before
/// an optional `-fast`.
pub fn maxModeTier(wire_id: []const u8) bool {
    const base = if (std.mem.endsWith(u8, wire_id, "-fast")) wire_id[0 .. wire_id.len - 5] else wire_id;
    return std.mem.endsWith(u8, base, "-xhigh") or std.mem.endsWith(u8, base, "-max");
}

pub const metadata = blk: {
    @setEvalBranchQuota(1_000_000);
    var list: [models.len]ModelMetadata = undefined;
    for (models, &list) |model, *entry| {
        var efforts: [model.efforts.len]types.ReasoningEffort = undefined;
        for (model.efforts, &efforts) |name, *effort| effort.* = types.ReasoningEffort.literal(name);
        const frozen = efforts;
        entry.* = .{
            .id = model.id,
            .name = model.name,
            .description = model.description,
            .cost = model.cost,
            .intelligence = model.intelligence,
            .context_window = model.context_window,
            .max_output_tokens = model.max_output_tokens,
            .supports_tool_use = true,
            .supports_vision = resolveInput(model.id),
            .reasoning_efforts = &frozen,
        };
    }
    break :blk list;
};

/// Cursor's discovery response carries no modality bits. These are the same
/// family rules used by the reference catalog; unknown static rows stay text.
pub fn resolveInput(id: []const u8) bool {
    const no_vision = [_][]const u8{
        "claude-4.6-opus-high",        "claude-4.6-sonnet-medium", "composer-1",               "composer-1.5",        "glm-5.2",
        "gpt-5.1-high",                "gpt-5.4-fast",             "grok-code-fast-1",         "gpt-5.2-codex-fast",  "gpt-5.2-codex-high",
        "gpt-5.2-codex-high-fast",     "gpt-5.2-codex-low",        "gpt-5.2-codex-low-fast",   "gpt-5.2-codex-xhigh", "gpt-5.2-codex-xhigh-fast",
        "gpt-5.3-codex-fast",          "gpt-5.3-codex-high",       "gpt-5.3-codex-high-fast",  "gpt-5.3-codex-low",   "gpt-5.3-codex-low-fast",
        "gpt-5.3-codex-spark-preview", "gpt-5.3-codex-xhigh",      "gpt-5.3-codex-xhigh-fast",
    };
    for (no_vision) |excluded| if (std.ascii.eqlIgnoreCase(id, excluded)) return false;
    if (std.ascii.eqlIgnoreCase(id, "composer-2.5") or std.ascii.startsWithIgnoreCase(id, "composer-2.5-")) return true;
    if (std.ascii.startsWithIgnoreCase(id, "kimi-k3") or std.ascii.startsWithIgnoreCase(id, "kimi-k2.")) return true;
    if (std.ascii.startsWithIgnoreCase(id, "cursor-grok-4")) return true;
    return containsIgnoreCase(id, "claude") or containsIgnoreCase(id, "gemini") or
        containsIgnoreCase(id, "gpt-") or containsIgnoreCase(id, "codex");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index <= haystack.len - needle.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

test "efforts route to the wire ids Cursor reported" {
    const opus = route("claude-opus-5-high", "high");
    try std.testing.expectEqualStrings("claude-opus-5-thinking-high", opus.wire_id);
    try std.testing.expectEqualStrings("claude-opus-5-high", route("claude-opus-5-high", null).wire_id);
    try std.testing.expectEqualStrings("gpt-5.5-extra-high", route("gpt-5.5", "xhigh").wire_id);
    try std.testing.expect(!route("gpt-5.5", "xhigh").max_mode);
    try std.testing.expect(route("claude-opus-4-7-high-fast", null).max_mode);
    try std.testing.expect(!route("claude-opus-4-8-max", null).max_mode);
    try std.testing.expect(route("unlisted-xhigh-fast", null).max_mode);
    try std.testing.expectEqualStrings("composer-2.5", route("composer-2.5", null).wire_id);
    try std.testing.expect(find(default_model) != null and find(small_model) != null);
    try std.testing.expectEqual(models.len, metadata.len);
}
