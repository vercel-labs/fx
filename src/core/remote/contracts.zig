const std = @import("std");

const Allocator = std.mem.Allocator;

pub const protocol_version: u32 = 1;
pub const max_frame_bytes: usize = 8 * 1024 * 1024;
pub const max_outbound_messages: usize = 64;
pub const max_outbound_bytes: usize = 8 * 1024 * 1024;
pub const snapshot_chunk_bytes: usize = 512 * 1024;
pub const max_snapshot_bytes: usize = 24 * 1024 * 1024;
pub const max_upgrade_header_bytes: usize = 16 * 1024;
pub const socket_send_timeout_seconds: i64 = 5;
pub const max_actors: usize = 16;
pub const max_attachments_per_actor: usize = 16;
pub const max_operations_per_actor: usize = 128;
pub const max_tools_per_actor: usize = 256;
pub const default_capability = "fx.sh/cap/remote-attach";

pub const Role = enum {
    observer,
    primary,
    controller,

    pub fn parse(value: []const u8) ?Role {
        if (std.mem.eql(u8, value, "observer")) return .observer;
        if (std.mem.eql(u8, value, "primary")) return .primary;
        if (std.mem.eql(u8, value, "controller")) return .controller;
        return null;
    }
};

pub const RunState = enum {
    idle,
    running,
    waiting_input,
    paused,
};

pub const OperationState = enum {
    accepted,
    running,
    completed,
    failed,
    cancelled,
};

pub const HistoryRole = enum {
    user,
    assistant,
    notice,
};

pub const HistoryItem = struct {
    role: HistoryRole,
    text: []u8,

    pub fn deinit(self: *HistoryItem, alloc: Allocator) void {
        alloc.free(self.text);
        self.* = undefined;
    }
};

pub const ToolRecord = struct {
    id: []u8,
    title: []u8,
    kind: []u8,
    status: []u8,
    progress: ?[]u8 = null,
    result: ?[]u8 = null,

    pub fn deinit(self: *ToolRecord, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.title);
        alloc.free(self.kind);
        alloc.free(self.status);
        if (self.progress) |value| alloc.free(value);
        if (self.result) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const PendingInteraction = struct {
    id: u64,
    method: []u8,
    params_json: []u8,

    pub fn deinit(self: *PendingInteraction, alloc: Allocator) void {
        alloc.free(self.method);
        alloc.free(self.params_json);
        self.* = undefined;
    }
};

pub const OperationRecord = struct {
    id: []u8,
    payload_digest: [32]u8,
    state: OperationState,
    result_json: ?[]u8 = null,
    error_json: ?[]u8 = null,

    pub fn deinit(self: *OperationRecord, alloc: Allocator) void {
        alloc.free(self.id);
        if (self.result_json) |value| alloc.free(value);
        if (self.error_json) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const Principal = struct {
    observe_sessions: [][]u8 = &.{},
    control_sessions: [][]u8 = &.{},

    pub fn deinit(self: *Principal, alloc: Allocator) void {
        freeSessions(alloc, self.observe_sessions);
        freeSessions(alloc, self.control_sessions);
        self.* = .{};
    }

    pub fn authorizes(self: Principal, role: Role, session_id: []const u8) bool {
        if (containsSession(self.control_sessions, session_id)) return true;
        return role == .observer and containsSession(self.observe_sessions, session_id);
    }

    fn containsSession(sessions: []const []u8, session_id: []const u8) bool {
        for (sessions) |session| {
            if (std.mem.eql(u8, session, "*") or std.mem.eql(u8, session, session_id)) return true;
        }
        return false;
    }

    fn freeSessions(alloc: Allocator, sessions: [][]u8) void {
        for (sessions) |session| alloc.free(session);
        if (sessions.len > 0) alloc.free(sessions);
    }
};

pub fn parseCapabilityHeader(
    alloc: Allocator,
    json: []const u8,
    capability: []const u8,
) !Principal {
    if (json.len == 0 or json.len > 16 * 1024) return error.InvalidCapability;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidCapability,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCapability;
    const entries = parsed.value.object.get(capability) orelse return error.CapabilityMissing;
    if (entries != .array or entries.array.items.len == 0 or entries.array.items.len > 32)
        return error.InvalidCapability;

    var observe_sessions: std.ArrayList([]u8) = .empty;
    var control_sessions: std.ArrayList([]u8) = .empty;
    errdefer {
        for (observe_sessions.items) |session| alloc.free(session);
        observe_sessions.deinit(alloc);
        for (control_sessions.items) |session| alloc.free(session);
        control_sessions.deinit(alloc);
    }
    for (entries.array.items) |entry| {
        if (entry != .object) return error.InvalidCapability;
        const actions = entry.object.get("actions") orelse return error.InvalidCapability;
        const resources = entry.object.get("sessions") orelse return error.InvalidCapability;
        if (actions != .array or resources != .array or
            actions.array.items.len == 0 or actions.array.items.len > 16 or
            resources.array.items.len == 0 or resources.array.items.len > 64)
            return error.InvalidCapability;
        var observe = false;
        var control = false;
        for (actions.array.items) |action| {
            if (action != .string) return error.InvalidCapability;
            if (std.mem.eql(u8, action.string, "observe")) {
                if (observe) return error.InvalidCapability;
                observe = true;
            } else if (std.mem.eql(u8, action.string, "control")) {
                if (control) return error.InvalidCapability;
                control = true;
            } else return error.InvalidCapability;
        }
        for (resources.array.items) |resource| {
            if (resource != .string or !validSessionResource(resource.string)) return error.InvalidCapability;
            if (observe) try appendUnique(alloc, &observe_sessions, resource.string);
            if (control) try appendUnique(alloc, &control_sessions, resource.string);
        }
    }
    if (observe_sessions.items.len == 0 and control_sessions.items.len == 0) return error.CapabilityMissing;
    const owned_observe = try observe_sessions.toOwnedSlice(alloc);
    errdefer Principal.freeSessions(alloc, owned_observe);
    const owned_control = try control_sessions.toOwnedSlice(alloc);
    return .{ .observe_sessions = owned_observe, .control_sessions = owned_control };
}

fn validSessionResource(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f) return false;
    return true;
}

fn appendUnique(alloc: Allocator, sessions: *std.ArrayList([]u8), value: []const u8) !void {
    for (sessions.items) |existing| if (std.mem.eql(u8, existing, value)) return error.InvalidCapability;
    const owned = try alloc.dupe(u8, value);
    errdefer alloc.free(owned);
    try sessions.append(alloc, owned);
}

pub fn sanitizeSemanticAlloc(alloc: Allocator, text: []const u8) ![]u8 {
    var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(alloc);
    var iterator = view.iterator();
    while (iterator.nextCodepointSlice()) |slice| {
        const codepoint = std.unicode.utf8Decode(slice) catch return error.InvalidUtf8;
        if (codepoint == '\n' or codepoint == '\t' or
            (codepoint >= 0x20 and !(codepoint >= 0x7f and codepoint <= 0x9f)))
            try output.appendSlice(alloc, slice);
    }
    return output.toOwnedSlice(alloc);
}

pub fn operationDigest(method: []const u8, payload_json: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(method);
    hash.update(&.{0});
    hash.update(payload_json);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub fn randomId(io: std.Io, buffer: *[32]u8) ![]const u8 {
    var bytes: [16]u8 = undefined;
    try io.randomSecure(&bytes);
    const encoded = std.fmt.bytesToHex(bytes, .lower);
    @memcpy(buffer, &encoded);
    return buffer;
}

test "capability parser requires typed actions and sessions" {
    const alloc = std.testing.allocator;
    var principal = try parseCapabilityHeader(
        alloc,
        "{\"fx.sh/cap/remote-attach\":[{\"actions\":[\"observe\",\"control\"],\"sessions\":[\"session-a\"]}]}",
        default_capability,
    );
    defer principal.deinit(alloc);
    try std.testing.expect(principal.authorizes(.observer, "session-a"));
    try std.testing.expect(principal.authorizes(.controller, "session-a"));
    try std.testing.expect(!principal.authorizes(.controller, "session-b"));
}

test "capability parser preserves action and session association" {
    const alloc = std.testing.allocator;
    var principal = try parseCapabilityHeader(
        alloc,
        "{\"fx.sh/cap/remote-attach\":[{\"actions\":[\"observe\"],\"sessions\":[\"session-a\"]},{\"actions\":[\"control\"],\"sessions\":[\"session-b\"]}]}",
        default_capability,
    );
    defer principal.deinit(alloc);
    try std.testing.expect(principal.authorizes(.observer, "session-a"));
    try std.testing.expect(!principal.authorizes(.controller, "session-a"));
    try std.testing.expect(principal.authorizes(.observer, "session-b"));
    try std.testing.expect(principal.authorizes(.controller, "session-b"));
}

test "capability parser rejects missing malformed duplicate and unrelated grants" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidCapability, parseCapabilityHeader(alloc, "[]", default_capability));
    try std.testing.expectError(error.CapabilityMissing, parseCapabilityHeader(alloc, "{}", default_capability));
    try std.testing.expectError(error.InvalidCapability, parseCapabilityHeader(
        alloc,
        "{\"fx.sh/cap/remote-attach\":[{\"actions\":[],\"sessions\":[\"*\"]}]}",
        default_capability,
    ));
    try std.testing.expectError(error.InvalidCapability, parseCapabilityHeader(
        alloc,
        "{\"fx.sh/cap/remote-attach\":[{\"actions\":[\"other\"],\"sessions\":[\"*\"]}]}",
        default_capability,
    ));
    try std.testing.expectError(error.InvalidCapability, parseCapabilityHeader(
        alloc,
        "{\"fx.sh/cap/remote-attach\":[{\"actions\":[\"observe\",\"observe\"],\"sessions\":[\"*\"]}]}",
        default_capability,
    ));
    try std.testing.expectError(error.InvalidCapability, parseCapabilityHeader(
        alloc,
        "{\"fx.sh/cap/remote-attach\":[{\"actions\":[\"observe\"],\"sessions\":[\"*\",\"*\"]}]}",
        default_capability,
    ));
}

test "capability parser releases every failing allocation path" {
    const backing = std.testing.allocator;
    const input = "{\"fx.sh/cap/remote-attach\":[{\"actions\":[\"observe\"],\"sessions\":[\"session-a\",\"session-b\"]},{\"actions\":[\"control\"],\"sessions\":[\"session-c\"]}]}";
    var probe = std.testing.FailingAllocator.init(backing, .{});
    var counted = try parseCapabilityHeader(probe.allocator(), input, default_capability);
    counted.deinit(probe.allocator());
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);
    for (0..probe.alloc_index) |fail_index| {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        if (parseCapabilityHeader(failing.allocator(), input, default_capability)) |principal| {
            var owned = principal;
            owned.deinit(failing.allocator());
        } else |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "semantic sanitizer strips terminal controls and preserves safe UTF-8" {
    const sanitized = try sanitizeSemanticAlloc(std.testing.allocator, "a\x1b[31m\x00\xc2\x85✓\n\tb");
    defer std.testing.allocator.free(sanitized);
    try std.testing.expectEqualStrings("a[31m✓\n\tb", sanitized);
}

test "operation digest binds method and payload" {
    const first = operationDigest("fx/prompt", "{\"text\":\"a\"}");
    const same = operationDigest("fx/prompt", "{\"text\":\"a\"}");
    const changed = operationDigest("fx/prompt", "{\"text\":\"b\"}");
    try std.testing.expectEqualSlices(u8, &first, &same);
    try std.testing.expect(!std.mem.eql(u8, &first, &changed));
}
