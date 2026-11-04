const std = @import("std");
const hooks = @import("../hooks/hooks.zig");

pub const ConfigureError = std.mem.Allocator.Error || hooks.RegistrationError;

pub const Preferences = struct {
    turn_end: bool = false,
    attention_required: bool = false,
    // Max retains the ordinary sound gates and enables additional direct cues.
    max: bool = false,
};

pub const Cue = enum {
    success,
    @"error",
    bloom,
    press,
    click,
    release,
    toggle,
};

pub const Kind = enum {
    turn_end,
    attention_required,
};

pub const Notification = struct {
    kind: Kind,
    cue: Cue = .success,
};

pub const Provider = struct {
    configure: *const fn (*anyopaque) ConfigureError!void,
    set_preferences: *const fn (*anyopaque, Preferences) void,
    preferences: *const fn (*const anyopaque) Preferences,
    max_enabled: *const fn (*const anyopaque) bool,
    queue: *const fn (*anyopaque, Notification) void,
    presentation_finished: *const fn (*anyopaque) void,
    flush: *const fn (*anyopaque) void,
    play_cue: *const fn (*anyopaque, Cue) void,
    play_max_cue: *const fn (*anyopaque, Cue) void,
    /// The session id names the agent whose turn needs attention.
    dispatch_attention_required: *const fn (*anyopaque, ?[]const u8, u64, hooks.AttentionKind) void,
};
