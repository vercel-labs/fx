const std = @import("std");

const Allocator = std.mem.Allocator;
const max_profiles: usize = 64;
const max_identifier_bytes: usize = 128;
const max_display_name_bytes: usize = 256;
const max_endpoint_bytes: usize = 2048;
pub const max_model_bytes: usize = 1024;

pub const max_connection_id_bytes = max_identifier_bytes;

pub const DisconnectReason = enum {
    not_checked,
    missing_credential,
    unsupported_adapter,
    invalid_credential_reference,
    authentication_failed,
};

pub const AuthStateTag = enum {
    disconnected,
    connected,
};

pub const AuthState = union(AuthStateTag) {
    disconnected: DisconnectReason,
    connected,
};

/// Borrowed input. A Runtime or Stored value duplicates every field it keeps.
pub const ProfileInput = struct {
    id: []const u8,
    display_name: []const u8,
    adapter_id: []const u8,
    endpoint: ?[]const u8 = null,
    protocol: ?[]const u8 = null,
    credential_ref: []const u8,
    remembered_model: []const u8,
    permission_review_model: ?[]const u8 = null,
};

/// Provider-owned metadata used only to seed a built-in connection. Core adds
/// the current model and any legacy credential preference when no registry has
/// been persisted yet.
pub const Seed = struct {
    id: []const u8,
    display_name: []const u8,
    adapter_id: []const u8,
    endpoint: ?[]const u8 = null,
    protocol: ?[]const u8 = null,
    credential_ref: []const u8,
    permission_review_model: ?[]const u8 = null,

    pub fn profile(
        self: Seed,
        remembered_model: []const u8,
        credential_ref: ?[]const u8,
    ) ProfileInput {
        return .{
            .id = self.id,
            .display_name = self.display_name,
            .adapter_id = self.adapter_id,
            .endpoint = self.endpoint,
            .protocol = self.protocol,
            .credential_ref = credential_ref orelse self.credential_ref,
            .remembered_model = remembered_model,
            .permission_review_model = self.permission_review_model,
        };
    }
};

pub const Profile = struct {
    id: []u8,
    display_name: []u8,
    adapter_id: []u8,
    endpoint: ?[]u8,
    protocol: ?[]u8,
    credential_ref: []u8,
    remembered_model: []u8,
    permission_review_model: ?[]u8,
    auth: AuthState = .{ .disconnected = .not_checked },

    fn init(alloc: Allocator, profile_input: ProfileInput, auth: AuthState) !Profile {
        try validateProfile(profile_input);
        const id = try alloc.dupe(u8, profile_input.id);
        errdefer alloc.free(id);
        const display_name = try alloc.dupe(u8, profile_input.display_name);
        errdefer alloc.free(display_name);
        const adapter_id = try alloc.dupe(u8, profile_input.adapter_id);
        errdefer alloc.free(adapter_id);
        const endpoint = if (profile_input.endpoint) |value| try alloc.dupe(u8, value) else null;
        errdefer if (endpoint) |value| alloc.free(value);
        const protocol = if (profile_input.protocol) |value| try alloc.dupe(u8, value) else null;
        errdefer if (protocol) |value| alloc.free(value);
        const credential_ref = try alloc.dupe(u8, profile_input.credential_ref);
        errdefer alloc.free(credential_ref);
        const remembered_model = try alloc.dupe(u8, profile_input.remembered_model);
        errdefer alloc.free(remembered_model);
        const permission_review_model = if (profile_input.permission_review_model) |value|
            try alloc.dupe(u8, value)
        else
            null;
        return .{
            .id = id,
            .display_name = display_name,
            .adapter_id = adapter_id,
            .endpoint = endpoint,
            .protocol = protocol,
            .credential_ref = credential_ref,
            .remembered_model = remembered_model,
            .permission_review_model = permission_review_model,
            .auth = auth,
        };
    }

    fn asInput(self: Profile) ProfileInput {
        return .{
            .id = self.id,
            .display_name = self.display_name,
            .adapter_id = self.adapter_id,
            .endpoint = self.endpoint,
            .protocol = self.protocol,
            .credential_ref = self.credential_ref,
            .remembered_model = self.remembered_model,
            .permission_review_model = self.permission_review_model,
        };
    }

    fn clone(self: Profile, alloc: Allocator, preserve_auth: bool) !Profile {
        return init(
            alloc,
            self.asInput(),
            if (preserve_auth) self.auth else .{ .disconnected = .not_checked },
        );
    }

    fn deinit(self: *Profile, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.display_name);
        alloc.free(self.adapter_id);
        if (self.endpoint) |value| alloc.free(value);
        if (self.protocol) |value| alloc.free(value);
        alloc.free(self.credential_ref);
        alloc.free(self.remembered_model);
        if (self.permission_review_model) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const Snapshot = struct {
    selected_id: []const u8,
    profiles: []const Profile,
};

/// Owned persisted representation. It contains references and profile metadata,
/// never credential bytes or live authentication state.
pub const Stored = struct {
    selected_id: []u8,
    profiles: []Profile,

    fn fromSnapshot(alloc: Allocator, state_snapshot: Snapshot) !Stored {
        try validateSnapshot(state_snapshot);
        const selected_id = try alloc.dupe(u8, state_snapshot.selected_id);
        errdefer alloc.free(selected_id);
        const profiles = try alloc.alloc(Profile, state_snapshot.profiles.len);
        errdefer alloc.free(profiles);
        var initialized: usize = 0;
        errdefer for (profiles[0..initialized]) |*profile| profile.deinit(alloc);
        for (state_snapshot.profiles, 0..) |profile_value, index| {
            profiles[index] = try profile_value.clone(alloc, false);
            initialized += 1;
        }
        return .{ .selected_id = selected_id, .profiles = profiles };
    }

    pub fn snapshot(self: *const Stored) Snapshot {
        return .{ .selected_id = self.selected_id, .profiles = self.profiles };
    }

    pub fn deinit(self: *Stored, alloc: Allocator) void {
        for (self.profiles) |*profile| profile.deinit(alloc);
        alloc.free(self.profiles);
        alloc.free(self.selected_id);
        self.* = undefined;
    }
};

pub const PersistenceOutcome = union(enum) {
    committed,
    /// The replacement became authoritative, but its final durability could
    /// not be confirmed. The registry must install the replacement before
    /// returning the persistence error to its caller.
    replaced_indeterminate: anyerror,
};

pub const Persistence = struct {
    context: ?*anyopaque = null,
    write_fn: *const fn (?*anyopaque, Allocator, Snapshot) anyerror!PersistenceOutcome,

    pub const unavailable = Persistence{ .write_fn = unavailableWrite };

    fn write(self: Persistence, alloc: Allocator, snapshot: Snapshot) !PersistenceOutcome {
        return self.write_fn(self.context, alloc, snapshot);
    }

    fn unavailableWrite(_: ?*anyopaque, _: Allocator, _: Snapshot) anyerror!PersistenceOutcome {
        return error.ConnectionPersistenceUnavailable;
    }
};

pub const Status = struct {
    id: []const u8,
    selected: bool,
    auth: AuthState,
};

const StoredProfile = struct {
    id: []const u8,
    display_name: []const u8,
    adapter_id: []const u8,
    endpoint: ?[]const u8 = null,
    protocol: ?[]const u8 = null,
    credential_ref: []const u8,
    remembered_model: []const u8,
    permission_review_model: ?[]const u8 = null,

    fn input(self: StoredProfile) ProfileInput {
        return .{
            .id = self.id,
            .display_name = self.display_name,
            .adapter_id = self.adapter_id,
            .endpoint = self.endpoint,
            .protocol = self.protocol,
            .credential_ref = self.credential_ref,
            .remembered_model = self.remembered_model,
            .permission_review_model = self.permission_review_model,
        };
    }
};

const StoredDocument = struct {
    selected: []const u8,
    profiles: []StoredProfile,
};

pub const Runtime = struct {
    const Self = @This();

    alloc: Allocator,
    profiles: std.ArrayList(Profile) = .empty,
    selected_index: usize = 0,
    persistence: Persistence,

    pub fn init(
        alloc: Allocator,
        seed: ProfileInput,
        stored: ?*const Stored,
        persistence: Persistence,
    ) !Self {
        try validateProfile(seed);
        var self = Self{ .alloc = alloc, .persistence = persistence };
        errdefer self.deinit();

        if (stored) |value| {
            try validateSnapshot(value.snapshot());
            try self.profiles.ensureTotalCapacity(alloc, value.profiles.len + 1);
            for (value.profiles) |profile_value| {
                self.profiles.appendAssumeCapacity(try profile_value.clone(alloc, false));
            }
            if (self.indexOf(seed.id) == null) {
                if (value.profiles.len == max_profiles) return error.TooManyConnections;
                self.profiles.appendAssumeCapacity(try Profile.init(
                    alloc,
                    seed,
                    .{ .disconnected = .not_checked },
                ));
            }
            self.selected_index = self.indexOf(value.selected_id) orelse
                return error.UnknownSelectedConnection;
        } else {
            var profile_value = try Profile.init(alloc, seed, .{ .disconnected = .not_checked });
            errdefer profile_value.deinit(alloc);
            try self.profiles.append(alloc, profile_value);
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.profiles.items) |*profile_value| profile_value.deinit(self.alloc);
        self.profiles.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn list(self: *const Self) []const Profile {
        return self.profiles.items;
    }

    pub fn selectedProfile(self: *const Self) Profile {
        return self.profiles.items[self.selected_index];
    }

    pub fn profile(self: *const Self, id: []const u8) error{UnknownConnection}!Profile {
        const index = self.indexOf(id) orelse return error.UnknownConnection;
        return self.profiles.items[index];
    }

    pub fn snapshot(self: *const Self) Snapshot {
        return .{
            .selected_id = self.selectedProfile().id,
            .profiles = self.profiles.items,
        };
    }

    pub fn status(self: *const Self, id: []const u8) error{UnknownConnection}!Status {
        const index = self.indexOf(id) orelse return error.UnknownConnection;
        const selected = self.profiles.items[index];
        return .{ .id = selected.id, .selected = index == self.selected_index, .auth = selected.auth };
    }

    pub fn add(self: *Self, input: ProfileInput) !void {
        try validateProfile(input);
        if (self.profiles.items.len >= max_profiles) return error.TooManyConnections;
        if (self.indexOf(input.id) != null) return error.DuplicateConnection;

        var next = try self.clone();
        defer next.deinit();
        try next.profiles.ensureUnusedCapacity(self.alloc, 1);
        next.profiles.appendAssumeCapacity(try Profile.init(
            self.alloc,
            input,
            .{ .disconnected = .not_checked },
        ));
        try self.commit(&next);
    }

    pub fn select(self: *Self, id: []const u8) !bool {
        const index = self.indexOf(id) orelse return error.UnknownConnection;
        if (index == self.selected_index) return false;

        var next = try self.clone();
        defer next.deinit();
        next.selected_index = index;
        try self.commit(&next);
        return true;
    }

    pub fn rememberSelectedModel(self: *Self, model: []const u8) !void {
        try validateModel(model);
        const current = self.selectedProfile();
        if (std.mem.eql(u8, current.remembered_model, model)) return;

        var next = try self.clone();
        defer next.deinit();
        const replacement = try self.alloc.dupe(u8, model);
        self.alloc.free(next.profiles.items[next.selected_index].remembered_model);
        next.profiles.items[next.selected_index].remembered_model = replacement;
        try self.commit(&next);
    }

    pub fn rememberSelectedCredentialReference(self: *Self, credential_ref: []const u8) !void {
        try validateIdentifier(credential_ref);
        const current = self.selectedProfile();
        if (std.mem.eql(u8, current.credential_ref, credential_ref)) return;

        var next = try self.clone();
        defer next.deinit();
        const replacement = try self.alloc.dupe(u8, credential_ref);
        self.alloc.free(next.profiles.items[next.selected_index].credential_ref);
        next.profiles.items[next.selected_index].credential_ref = replacement;
        try self.commit(&next);
    }

    pub fn markConnected(self: *Self, id: []const u8) error{UnknownConnection}!void {
        const index = self.indexOf(id) orelse return error.UnknownConnection;
        self.profiles.items[index].auth = .connected;
    }

    pub fn markDisconnected(
        self: *Self,
        id: []const u8,
        reason: DisconnectReason,
    ) error{UnknownConnection}!void {
        const index = self.indexOf(id) orelse return error.UnknownConnection;
        self.profiles.items[index].auth = .{ .disconnected = reason };
    }

    pub fn markSelectedConnected(self: *Self) void {
        self.profiles.items[self.selected_index].auth = .connected;
    }

    pub fn markSelectedDisconnected(self: *Self, reason: DisconnectReason) void {
        self.profiles.items[self.selected_index].auth = .{ .disconnected = reason };
    }

    fn clone(self: *const Self) !Self {
        var result = Self{
            .alloc = self.alloc,
            .selected_index = self.selected_index,
            .persistence = self.persistence,
        };
        errdefer result.deinit();
        try result.profiles.ensureTotalCapacity(self.alloc, self.profiles.items.len);
        for (self.profiles.items) |profile_value| {
            result.profiles.appendAssumeCapacity(try profile_value.clone(self.alloc, true));
        }
        return result;
    }

    fn commit(self: *Self, next: *Self) !void {
        const outcome = try self.persistence.write(self.alloc, next.snapshot());
        for (self.profiles.items) |*profile_value| profile_value.deinit(self.alloc);
        self.profiles.deinit(self.alloc);
        self.profiles = next.profiles;
        self.selected_index = next.selected_index;
        next.profiles = .empty;
        switch (outcome) {
            .committed => {},
            .replaced_indeterminate => |err| return err,
        }
    }

    fn indexOf(self: *const Self, id: []const u8) ?usize {
        for (self.profiles.items, 0..) |profile_value, index| {
            if (std.mem.eql(u8, profile_value.id, id)) return index;
        }
        return null;
    }
};

pub fn parseStored(alloc: Allocator, value: std.json.Value) !Stored {
    var parsed = try std.json.parseFromValue(StoredDocument, alloc, value, .{});
    defer parsed.deinit();
    if (parsed.value.profiles.len == 0 or parsed.value.profiles.len > max_profiles) {
        return error.InvalidConnectionsShape;
    }

    var profiles: std.ArrayList(Profile) = .empty;
    errdefer {
        for (profiles.items) |*profile_value| profile_value.deinit(alloc);
        profiles.deinit(alloc);
    }
    try profiles.ensureTotalCapacity(alloc, parsed.value.profiles.len);
    for (parsed.value.profiles) |profile_value| {
        profiles.appendAssumeCapacity(try Profile.init(
            alloc,
            profile_value.input(),
            .{ .disconnected = .not_checked },
        ));
    }

    const owned_selected = try alloc.dupe(u8, parsed.value.selected);
    errdefer alloc.free(owned_selected);
    const owned_profiles = try profiles.toOwnedSlice(alloc);
    errdefer {
        for (owned_profiles) |*profile_value| profile_value.deinit(alloc);
        alloc.free(owned_profiles);
    }
    try validateSnapshot(.{ .selected_id = owned_selected, .profiles = owned_profiles });
    return .{ .selected_id = owned_selected, .profiles = owned_profiles };
}

pub fn validate(snapshot_value: Snapshot) !void {
    try validateSnapshot(snapshot_value);
}

fn validateSnapshot(snapshot: Snapshot) !void {
    if (snapshot.profiles.len == 0 or snapshot.profiles.len > max_profiles) {
        return error.InvalidConnectionsShape;
    }
    try validateIdentifier(snapshot.selected_id);
    var selected_found = false;
    for (snapshot.profiles, 0..) |profile_value, index| {
        try validateProfile(profile_value.asInput());
        if (std.mem.eql(u8, profile_value.id, snapshot.selected_id)) selected_found = true;
        for (snapshot.profiles[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, profile_value.id)) return error.DuplicateConnection;
        }
    }
    if (!selected_found) return error.UnknownSelectedConnection;
}

fn validateProfile(input: ProfileInput) !void {
    try validateIdentifier(input.id);
    try validateDisplayName(input.display_name);
    try validateIdentifier(input.adapter_id);
    try validateIdentifier(input.credential_ref);
    try validateModel(input.remembered_model);
    if (input.endpoint) |endpoint| {
        try validateText(endpoint, max_endpoint_bytes);
        if (input.protocol == null) return error.ProtocolRequired;
    }
    if (input.protocol) |protocol| try validateIdentifier(protocol);
    if (input.permission_review_model) |model| try validateModel(model);
}

fn validateIdentifier(value: []const u8) !void {
    if (value.len == 0 or value.len > max_identifier_bytes) return error.InvalidConnectionIdentifier;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '.' or byte == ':')) {
            return error.InvalidConnectionIdentifier;
        }
    }
}

fn validateDisplayName(value: []const u8) !void {
    try validateText(value, max_display_name_bytes);
    if (!std.mem.eql(u8, value, std.mem.trim(u8, value, " \t\r\n"))) {
        return error.InvalidConnectionDisplayName;
    }
}

fn validateModel(value: []const u8) !void {
    try validateText(value, max_model_bytes);
    if (!std.mem.eql(u8, value, std.mem.trim(u8, value, " \t\r\n"))) {
        return error.InvalidConnectionModel;
    }
}

fn validateText(value: []const u8, max_bytes: usize) !void {
    if (value.len == 0 or value.len > max_bytes or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidConnectionText;
    }
    for (value) |byte| if (std.ascii.isControl(byte)) return error.InvalidConnectionText;
}

const test_seed = ProfileInput{
    .id = "vercel",
    .display_name = "Vercel AI Gateway",
    .adapter_id = "vercel_ai_gateway",
    .endpoint = "https://ai-gateway.vercel.sh/v3/ai/language-model",
    .protocol = "vercel_ai_gateway",
    .credential_ref = "automatic",
    .remembered_model = "zai/glm-5.2-fast",
    .permission_review_model = "openai/gpt-5.4",
};

const test_local = ProfileInput{
    .id = "local",
    .display_name = "Local",
    .adapter_id = "custom",
    .endpoint = "http://127.0.0.1:8080/v1",
    .protocol = "openai_compatible",
    .credential_ref = "local_key",
    .remembered_model = "local/model",
};

const PersistenceCapture = struct {
    writes: usize = 0,
    stored: ?Stored = null,

    fn deinit(self: *PersistenceCapture, alloc: std.mem.Allocator) void {
        if (self.stored) |*stored| stored.deinit(alloc);
    }

    fn persistence(self: *PersistenceCapture) Persistence {
        return .{ .context = self, .write_fn = write };
    }

    fn write(raw: ?*anyopaque, alloc: std.mem.Allocator, snapshot: Snapshot) !PersistenceOutcome {
        const self: *PersistenceCapture = @ptrCast(@alignCast(raw.?));
        var stored = try Stored.fromSnapshot(alloc, snapshot);
        errdefer stored.deinit(alloc);
        if (self.stored) |*previous| previous.deinit(alloc);
        self.stored = stored;
        self.writes += 1;
        return .committed;
    }
};

const RejectingPersistence = struct {
    writes: usize = 0,

    fn persistence(self: *RejectingPersistence) Persistence {
        return .{ .context = self, .write_fn = write };
    }

    fn write(raw: ?*anyopaque, _: Allocator, _: Snapshot) !PersistenceOutcome {
        const self: *RejectingPersistence = @ptrCast(@alignCast(raw.?));
        self.writes += 1;
        return error.ConnectionWriteFailed;
    }
};

const IndeterminatePersistence = struct {
    writes: usize = 0,
    stored: ?Stored = null,

    fn deinit(self: *IndeterminatePersistence, alloc: Allocator) void {
        if (self.stored) |*stored| stored.deinit(alloc);
    }

    fn persistence(self: *IndeterminatePersistence) Persistence {
        return .{ .context = self, .write_fn = write };
    }

    fn write(raw: ?*anyopaque, alloc: Allocator, snapshot: Snapshot) !PersistenceOutcome {
        const self: *IndeterminatePersistence = @ptrCast(@alignCast(raw.?));
        var stored = try Stored.fromSnapshot(alloc, snapshot);
        errdefer stored.deinit(alloc);
        if (self.stored) |*previous| previous.deinit(alloc);
        self.stored = stored;
        self.writes += 1;
        return .{ .replaced_indeterminate = error.SettingsCommitIndeterminate };
    }
};

test "connection selection is idempotent and unknown ids preserve state" {
    const alloc = std.testing.allocator;
    var capture = PersistenceCapture{};
    defer capture.deinit(alloc);
    var runtime = try Runtime.init(alloc, test_seed, null, capture.persistence());
    defer runtime.deinit();

    try std.testing.expect(!try runtime.select("vercel"));
    try std.testing.expectEqual(@as(usize, 0), capture.writes);
    try std.testing.expectError(error.UnknownConnection, runtime.select("missing"));
    try std.testing.expectEqualStrings("vercel", runtime.selectedProfile().id);
    try std.testing.expectEqual(@as(usize, 0), capture.writes);
}

test "definite persistence failure leaves connection selection unchanged" {
    const alloc = std.testing.allocator;
    var capture = PersistenceCapture{};
    defer capture.deinit(alloc);
    var persistence = RejectingPersistence{};
    var runtime = try Runtime.init(alloc, test_seed, null, capture.persistence());
    defer runtime.deinit();
    try runtime.add(test_local);
    runtime.persistence = persistence.persistence();

    try std.testing.expectError(
        error.ConnectionWriteFailed,
        runtime.select("local"),
    );
    try std.testing.expectEqual(@as(usize, 1), persistence.writes);
    try std.testing.expectEqualStrings("vercel", runtime.selectedProfile().id);
}

test "indeterminate persistence installs the authoritative connection selection" {
    const alloc = std.testing.allocator;
    var capture = PersistenceCapture{};
    defer capture.deinit(alloc);
    var persistence = IndeterminatePersistence{};
    defer persistence.deinit(alloc);
    var runtime = try Runtime.init(alloc, test_seed, null, capture.persistence());
    defer runtime.deinit();
    try runtime.add(test_local);
    runtime.persistence = persistence.persistence();

    try std.testing.expectError(
        error.SettingsCommitIndeterminate,
        runtime.select("local"),
    );
    try std.testing.expectEqual(@as(usize, 1), persistence.writes);
    try std.testing.expectEqualStrings("local", runtime.selectedProfile().id);
    try std.testing.expectEqualStrings("local", persistence.stored.?.selected_id);
}

test "models credentials and authentication status stay isolated by connection" {
    const alloc = std.testing.allocator;
    var capture = PersistenceCapture{};
    defer capture.deinit(alloc);
    var runtime = try Runtime.init(alloc, test_seed, null, capture.persistence());
    defer runtime.deinit();

    try runtime.add(test_local);
    try runtime.markConnected("vercel");
    try std.testing.expect(try runtime.select("local"));
    try runtime.rememberSelectedModel("local/next");
    try runtime.rememberSelectedCredentialReference("local_key_next");
    try runtime.markDisconnected("local", .authentication_failed);

    const vercel = runtime.list()[0];
    try std.testing.expectEqualStrings("zai/glm-5.2-fast", vercel.remembered_model);
    try std.testing.expectEqualStrings("automatic", vercel.credential_ref);
    try std.testing.expectEqual(AuthStateTag.connected, std.meta.activeTag((try runtime.status("vercel")).auth));

    const local = runtime.list()[1];
    try std.testing.expectEqualStrings("local/next", local.remembered_model);
    try std.testing.expectEqualStrings("local_key_next", local.credential_ref);
    const local_status = try runtime.status("local");
    try std.testing.expect(local_status.selected);
    try std.testing.expectEqual(DisconnectReason.authentication_failed, local_status.auth.disconnected);
}

test "persisted profiles and active selection survive restart without secret fields" {
    const alloc = std.testing.allocator;
    var capture = PersistenceCapture{};
    defer capture.deinit(alloc);
    {
        var runtime = try Runtime.init(alloc, test_seed, null, capture.persistence());
        defer runtime.deinit();
        try runtime.add(.{
            .id = "remote",
            .display_name = "Remote",
            .adapter_id = "custom",
            .endpoint = "https://example.invalid/v1",
            .protocol = "openai_compatible",
            .credential_ref = "remote_key",
            .remembered_model = "remote/model",
        });
        try std.testing.expect(try runtime.select("remote"));
    }

    var restarted = try Runtime.init(alloc, test_seed, &capture.stored.?, Persistence.unavailable);
    defer restarted.deinit();
    try std.testing.expectEqualStrings("remote", restarted.selectedProfile().id);
    try std.testing.expectEqualStrings("remote/model", restarted.selectedProfile().remembered_model);
    try std.testing.expect(!@hasField(Profile, "api_key"));
    try std.testing.expect(!@hasField(Profile, "token"));
    try std.testing.expect(!@hasField(Profile, "secret"));
}

test "connection models preserve the legacy 1024 byte boundary" {
    var accepted_bytes: [1024]u8 = undefined;
    @memset(accepted_bytes[0..], 'm');
    var accepted_seed = test_seed;
    accepted_seed.remembered_model = accepted_bytes[0..];
    var runtime = try Runtime.init(
        std.testing.allocator,
        accepted_seed,
        null,
        Persistence.unavailable,
    );
    defer runtime.deinit();
    try std.testing.expectEqual(@as(usize, 1024), runtime.selectedProfile().remembered_model.len);

    var rejected_bytes: [1025]u8 = undefined;
    @memset(rejected_bytes[0..], 'm');
    var rejected_seed = test_seed;
    rejected_seed.remembered_model = rejected_bytes[0..];
    try std.testing.expectError(
        error.InvalidConnectionText,
        Runtime.init(std.testing.allocator, rejected_seed, null, Persistence.unavailable),
    );
}

test "profile parser rejects secret-bearing and unsupported endpoint shapes" {
    const alloc = std.testing.allocator;
    var secret_value = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"selected\":\"vercel\",\"profiles\":[{\"id\":\"vercel\",\"display_name\":\"Vercel\",\"adapter_id\":\"vercel_ai_gateway\",\"endpoint\":\"https://example.invalid\",\"protocol\":\"vercel_ai_gateway\",\"credential_ref\":\"automatic\",\"remembered_model\":\"model\",\"api_key\":\"secret\"}]}",
        .{},
    );
    defer secret_value.deinit();
    try std.testing.expectError(error.UnknownField, parseStored(alloc, secret_value.value));

    var unsupported_value = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"selected\":\"custom\",\"profiles\":[{\"id\":\"custom\",\"display_name\":\"Custom\",\"adapter_id\":\"custom\",\"endpoint\":\"https://example.invalid\",\"credential_ref\":\"key_ref\",\"remembered_model\":\"model\"}]}",
        .{},
    );
    defer unsupported_value.deinit();
    try std.testing.expectError(error.ProtocolRequired, parseStored(alloc, unsupported_value.value));
}

test "profile parser safely rejects duplicate ids and unknown selection" {
    const alloc = std.testing.allocator;
    var duplicate_value = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"selected\":\"vercel\",\"profiles\":[{\"id\":\"vercel\",\"display_name\":\"Vercel\",\"adapter_id\":\"gateway\",\"credential_ref\":\"automatic\",\"remembered_model\":\"model\"},{\"id\":\"vercel\",\"display_name\":\"Duplicate\",\"adapter_id\":\"gateway\",\"credential_ref\":\"automatic\",\"remembered_model\":\"model\"}]}",
        .{},
    );
    defer duplicate_value.deinit();
    try std.testing.expectError(error.DuplicateConnection, parseStored(alloc, duplicate_value.value));

    var unknown_value = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"selected\":\"missing\",\"profiles\":[{\"id\":\"vercel\",\"display_name\":\"Vercel\",\"adapter_id\":\"gateway\",\"credential_ref\":\"automatic\",\"remembered_model\":\"model\"}]}",
        .{},
    );
    defer unknown_value.deinit();
    try std.testing.expectError(error.UnknownSelectedConnection, parseStored(alloc, unknown_value.value));
}
