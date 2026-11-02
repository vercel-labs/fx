pub const ModelPromptOverlayFn = *const fn (model: []const u8) ?[]const u8;

pub const Policy = struct {
    system_prompt: []const u8,
    /// Variant for hosts that present fx inside another application instead
    /// of a terminal. Falls back to `system_prompt` when absent.
    embedded_system_prompt: ?[]const u8 = null,
    model_prompt_overlay_fn: ?ModelPromptOverlayFn = null,

    pub fn systemPromptFor(self: Policy, terminal_ui: bool) []const u8 {
        if (terminal_ui) return self.system_prompt;
        return self.embedded_system_prompt orelse self.system_prompt;
    }

    pub fn modelPromptOverlay(self: Policy, model: []const u8) ?[]const u8 {
        const overlay_fn = self.model_prompt_overlay_fn orelse return null;
        return overlay_fn(model);
    }
};

test "prompt policy resolves the supplied model overlay" {
    const Fixture = struct {
        fn overlay(model: []const u8) ?[]const u8 {
            return if (model.len > 0) "overlay" else null;
        }
    };
    const policy = Policy{
        .system_prompt = "system",
        .model_prompt_overlay_fn = Fixture.overlay,
    };

    try @import("std").testing.expectEqualStrings("overlay", policy.modelPromptOverlay("model").?);
    try @import("std").testing.expect(policy.modelPromptOverlay("") == null);
}
