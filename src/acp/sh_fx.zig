//! fx's extensions to ACP by their `sh.fx` names, as
//! `src/protocol/spec/sh-fx.md` defines them, and the set of extensions that
//! both sides of a connection list at `initialize`.
//!
//! fx lists its extensions in `agentCapabilities._meta` and a client lists the
//! ones it wants in `clientCapabilities._meta`. fx sends an extension's
//! notifications and `_meta` keys only when both lists name it, so a client
//! that lists none receives only standard ACP messages.

const std = @import("std");

pub const Extension = enum {
    /// Steers sent as `session/prompt` with `sh.fx/delivery`, and the
    /// `sh.fx/steeringDelivery` and `sh.fx/steerInput` keys.
    prompt_delivery,
    /// The `_sh.fx/session/*` steering methods of a host that keeps the
    /// session's journal, and `sh.fx/steerInput` on its steers.
    host_steering,
    /// `_sh.fx/session/new`, checkpoint and restore, the `_sh.fx/journal/*`
    /// methods, and the keys of journaled turns and stored images.
    journal,
    /// `_sh.fx/hooks/event` and the client's hook settings.
    hooks,
    /// `_sh.fx/tools/call` for the tools a client lists in its capability.
    host_tools,
    /// `sh.fx/toolCall` on `tool_call` updates.
    tool_call,
    /// `sh.fx/permissionMode` on each value of the `mode` config option.
    permission_mode,
    /// `sh.fx/modelResponseRecovery` on `session_info_update`.
    model_response_recovery,
    /// `_sh.fx/session/turn_progress`: a running turn's phase, tokens, and
    /// provider.
    turn_progress,
    /// `_sh.fx/session/model_call` for each model call that ends.
    model_calls,
    /// `sh.fx/usage` in the `_meta` of a `session/prompt` response.
    usage,
    /// `sh.fx/commandResult` on the `tool_call_update` that ends a shell call.
    command_result,
    /// `sh.fx/keepTurnOnDisconnect`: when this client's connection ends,
    /// fx lets its sessions' running turns finish and saves them, instead of
    /// cancelling them, and exits once they and the queued prompts are done.
    keep_turn_on_disconnect,
    /// `sh.fx/sessionClients`: the client lists the clients that have the session open, and fx
    /// sends each listing client the list as `_sh.fx/session/clients_update`.
    session_clients,

    pub fn capabilityName(self: Extension) []const u8 {
        return switch (self) {
            .prompt_delivery => "sh.fx/promptDelivery",
            .host_steering => "sh.fx/hostSteering",
            .journal => "sh.fx/journal",
            .hooks => "sh.fx/hooks",
            .host_tools => "sh.fx/hostTools",
            .tool_call => "sh.fx/toolCall",
            .permission_mode => "sh.fx/permissionMode",
            .model_response_recovery => "sh.fx/modelResponseRecovery",
            .turn_progress => "sh.fx/turnProgress",
            .model_calls => "sh.fx/modelCalls",
            .usage => "sh.fx/usage",
            .command_result => "sh.fx/commandResult",
            .keep_turn_on_disconnect => "sh.fx/keepTurnOnDisconnect",
            .session_clients => "sh.fx/sessionClients",
        };
    }
};

pub const Set = std.EnumSet(Extension);

/// The extensions a client lists in `clientCapabilities._meta`. Each entry's
/// value is an object; an entry with any other value doesn't list its
/// extension, and names fx doesn't know are ignored.
pub fn clientList(capabilities: std.json.ObjectMap) Set {
    var set: Set = .empty;
    const meta = capabilities.get("_meta") orelse return set;
    if (meta != .object) return set;
    for (std.enums.values(Extension)) |extension| {
        const value = meta.object.get(extension.capabilityName()) orelse continue;
        if (value == .object) set.insert(extension);
    }
    return set;
}

/// The value a client gives an extension in `clientCapabilities._meta`, when
/// it lists the extension.
pub fn clientValue(capabilities: std.json.ObjectMap, extension: Extension) ?std.json.ObjectMap {
    const meta = capabilities.get("_meta") orelse return null;
    if (meta != .object) return null;
    const value = meta.object.get(extension.capabilityName()) orelse return null;
    return if (value == .object) value.object else null;
}

/// Method and notification names, in the spec's "Names in use today" table.
pub const method = struct {
    pub const session_steer = "_sh.fx/session/steer";
    pub const session_withdraw_steer = "_sh.fx/session/withdraw_steer";
    pub const session_end_turn_for_steer = "_sh.fx/session/end_turn_for_steer";
    pub const session_follow_up = "_sh.fx/session/follow_up";
    pub const session_checkpoint = "_sh.fx/session/checkpoint";
    pub const session_restore = "_sh.fx/session/restore";
    pub const session_new = "_sh.fx/session/new";
    pub const journal_snapshot = "_sh.fx/journal/snapshot";
    pub const journal_open = "_sh.fx/journal/open";
    pub const journal_stage_images = "_sh.fx/journal/stage_images";
    pub const journal_append = "_sh.fx/journal/append";
    pub const journal_flush = "_sh.fx/journal/flush";
    pub const hooks_event = "_sh.fx/hooks/event";
    pub const session_turn_progress = "_sh.fx/session/turn_progress";
    pub const session_model_call = "_sh.fx/session/model_call";
    pub const tools_call = "_sh.fx/tools/call";
    pub const session_clients_update = "_sh.fx/session/clients_update";
};

test "clientList takes the extensions a client lists with an object" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"fs":{},"_meta":{"sh.fx/toolCall":{},"sh.fx/journal":true,"sh.fx/unknown":{},"fx":{"steering":true},"sh.fx/hostTools":{"tools":[]}}}
    , .{});
    defer parsed.deinit();
    const set = clientList(parsed.value.object);
    try std.testing.expect(set.contains(.tool_call));
    try std.testing.expect(set.contains(.host_tools));
    try std.testing.expect(!set.contains(.journal));
    try std.testing.expectEqual(@as(usize, 2), set.count());
    try std.testing.expect(clientValue(parsed.value.object, .host_tools).?.get("tools") != null);
    try std.testing.expect(clientValue(parsed.value.object, .journal) == null);
}

test "clientList is empty for a client that lists no extension" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"fs":{"readTextFile":true},"_meta":"none"}
    , .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), clientList(parsed.value.object).count());
}

test "clientList takes keepTurnOnDisconnect only as an object" {
    const alloc = std.testing.allocator;
    const listed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"_meta":{"sh.fx/keepTurnOnDisconnect":{}}}
    , .{});
    defer listed.deinit();
    try std.testing.expect(clientList(listed.value.object).contains(.keep_turn_on_disconnect));

    const not_object = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"_meta":{"sh.fx/keepTurnOnDisconnect":true}}
    , .{});
    defer not_object.deinit();
    try std.testing.expect(!clientList(not_object.value.object).contains(.keep_turn_on_disconnect));
}

test "clientList takes sessionClients only as an object" {
    const alloc = std.testing.allocator;
    const listed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"_meta":{"sh.fx/sessionClients":{}}}
    , .{});
    defer listed.deinit();
    try std.testing.expect(clientList(listed.value.object).contains(.session_clients));

    const not_object = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"_meta":{"sh.fx/sessionClients":true}}
    , .{});
    defer not_object.deinit();
    try std.testing.expect(!clientList(not_object.value.object).contains(.session_clients));
}
