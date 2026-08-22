const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;
const schema_version: i64 = 1;
const max_auth_file_bytes: usize = 64 * 1024;
const mutation_lock_deadline_ms: u64 = 2000;
const max_api_key_bytes: usize = 8 * 1024;

pub const Kind = enum {
    zen,
    go,

    pub fn slug(self: Kind) []const u8 {
        return switch (self) {
            .zen => "zen",
            .go => "go",
        };
    }

    pub fn authFileName(self: Kind) []const u8 {
        return switch (self) {
            .zen => profile_paths.zen_auth_file_name,
            .go => profile_paths.go_auth_file_name,
        };
    }

    pub fn lockFileName(self: Kind) []const u8 {
        return switch (self) {
            .zen => "zen-auth.lock",
            .go => "go-auth.lock",
        };
    }

    pub fn modelPrefix(self: Kind) []const u8 {
        return switch (self) {
            .zen => "opencode/",
            .go => "opencode-go/",
        };
    }
};

pub const Session = struct {
    api_key: []u8,

    pub fn deinit(self: *Session, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.api_key);
        self.* = undefined;
    }
};

pub const DeleteOutcome = enum {
    deleted,
    missing,
    deleted_not_durable,
};

pub const Mutation = struct {
    kind: Kind,
    fx_dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,

    pub fn deinit(self: *Mutation) void {
        self.lock.release();
        self.fx_dir.close();
        self.* = undefined;
    }

    pub fn load(self: *Mutation, alloc: Allocator) !?Session {
        return loadFromDir(alloc, &self.fx_dir.dir, self.kind, true);
    }

    pub fn save(self: *Mutation, alloc: Allocator, session: Session) !void {
        const text = try stringify(alloc, session);
        defer secret.zeroAndFree(alloc, text);
        try io_mod.durableReplaceVerified(alloc, &self.fx_dir, self.kind.authFileName(), text);
    }

    pub fn delete(self: *Mutation) !DeleteOutcome {
        self.fx_dir.dir.deleteFile(io_mod.getIo(), self.kind.authFileName()) catch |err| switch (err) {
            error.FileNotFound => return .missing,
            else => return err,
        };
        const durable: io_mod.DurableOps = .{};
        durable.sync_dir(durable.ctx, self.fx_dir.dir) catch return .deleted_not_durable;
        return .deleted;
    }
};

pub fn validApiKey(api_key: []const u8) bool {
    const trimmed = std.mem.trim(u8, api_key, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > max_api_key_bytes) return false;
    for (trimmed) |byte| {
        if (byte < 0x21 or byte > 0x7e) return false;
    }
    return true;
}

pub fn load(alloc: Allocator, kind: Kind) !?Session {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.getenv("HOME") orelse return null;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
        debug_trace.logf("auth", "OpenCode session load failed step=open_home kind={s} err={s}", .{ kind.slug(), @errorName(err) });
        return null;
    };
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| {
        if (err != error.FileNotFound) {
            debug_trace.logf("auth", "OpenCode session load failed step=open_profile kind={s} err={s}", .{ kind.slug(), @errorName(err) });
        }
        return null;
    };
    defer fx_dir.close(io_mod.getIo());
    return loadFromDir(alloc, &fx_dir, kind, false);
}

fn loadFromDir(alloc: Allocator, fx_dir: *std.Io.Dir, kind: Kind, report_open_failure: bool) !?Session {
    var file = fx_dir.openFile(io_mod.getIo(), kind.authFileName(), .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("auth", "OpenCode session load failed step=open_file kind={s} err={s}", .{ kind.slug(), @errorName(err) });
            if (report_open_failure) return err;
            return null;
        },
    };
    defer file.close(io_mod.getIo());

    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("auth", "OpenCode session load failed step=permissions kind={s} err=InsecureAuthFile", .{kind.slug()});
        return null;
    }

    const bytes = try io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes);
    defer secret.zeroAndFree(alloc, bytes);
    return parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "OpenCode session load failed step=parse kind={s} err={s}", .{ kind.slug(), @errorName(err) });
            return null;
        },
    };
}

pub fn saveNewSession(alloc: Allocator, kind: Kind, session: Session) !void {
    if (comptime host_target.is_wasm) return error.OpenCodeAuthUnavailable;
    var mutation = try beginMutation(kind);
    defer mutation.deinit();
    try mutation.save(alloc, session);
}

pub fn beginExistingMutation(kind: Kind) !?Mutation {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();

    const fx_dir = openExistingPrivateFxDir(&home_dir) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try lockMutation(kind, fx_dir);
}

fn beginMutation(kind: Kind) !Mutation {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();

    const fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name);
    return lockMutation(kind, fx_dir);
}

fn lockMutation(kind: Kind, open_fx_dir: io_mod.VerifiedDir) !Mutation {
    var fx_dir = open_fx_dir;
    errdefer fx_dir.close();
    var lock = try io_mod.acquireTimedAdvisoryLock(
        &fx_dir,
        kind.lockFileName(),
        mutation_lock_deadline_ms,
    );
    errdefer lock.release();
    return .{ .kind = kind, .fx_dir = fx_dir, .lock = lock };
}

fn openExistingPrivateFxDir(home_dir: *io_mod.VerifiedDir) !io_mod.VerifiedDir {
    var dir = try home_dir.dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    errdefer dir.close(io_mod.getIo());

    const initial_stat = try dir.stat(io_mod.getIo());
    if (initial_stat.kind != .directory) return error.DurablePathUnsafe;
    if (initial_stat.permissions.toMode() & 0o200 == 0) return error.PrivateStatePermissionsUnsupported;
    dir.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(0o700)) catch {
        return error.PrivateStatePermissionsUnsupported;
    };
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory or stat.permissions.toMode() & 0o777 != 0o700) {
        return error.PrivateStatePermissionsUnsupported;
    }
    return .{ .dir = dir };
}

pub fn parse(alloc: Allocator, bytes: []const u8) !Session {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenCodeAuthSession;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidOpenCodeAuthSession;
    if (version != .integer or version.integer != schema_version) return error.InvalidOpenCodeAuthSession;
    const api_key_value = object.get("api_key") orelse return error.InvalidOpenCodeAuthSession;
    if (api_key_value != .string or !validApiKey(api_key_value.string)) return error.InvalidOpenCodeAuthSession;
    return .{ .api_key = try alloc.dupe(u8, std.mem.trim(u8, api_key_value.string, " \t\r\n")) };
}

pub fn stringify(alloc: Allocator, session: Session) ![]u8 {
    if (!validApiKey(session.api_key)) return error.InvalidOpenCodeAuthSession;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"version\":1,\"api_key\":");
    try std.json.Stringify.value(session.api_key, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

pub fn sourceExists(alloc: Allocator, kind: Kind) !bool {
    var session = (try load(alloc, kind)) orelse return false;
    defer session.deinit(alloc);
    return true;
}

pub fn logout(kind: Kind) !DeleteOutcome {
    if (comptime host_target.is_wasm) return .missing;
    var mutation = (try beginExistingMutation(kind)) orelse return .missing;
    defer mutation.deinit();
    return mutation.delete();
}

test "OpenCode auth session round trips an API key" {
    const alloc = std.testing.allocator;
    var session = Session{ .api_key = try alloc.dupe(u8, "sk-opencode-test") };
    defer session.deinit(alloc);
    const encoded = try stringify(alloc, session);
    defer secret.zeroAndFree(alloc, encoded);
    var decoded = try parse(alloc, encoded);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualStrings(session.api_key, decoded.api_key);
}

test "OpenCode API keys reject empty or non-printable bytes" {
    try std.testing.expect(validApiKey("sk-abc"));
    try std.testing.expect(!validApiKey(""));
    try std.testing.expect(!validApiKey("   "));
    try std.testing.expect(!validApiKey("sk\nsecret"));
    try std.testing.expectError(
        error.InvalidOpenCodeAuthSession,
        parse(std.testing.allocator, "{\"version\":1,\"api_key\":\"sk\\ninjected\"}"),
    );
}
