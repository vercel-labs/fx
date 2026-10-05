const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const io_mod = @import("../shared/io.zig");
const artifact_digest = @import("artifact_digest.zig");

const Allocator = std.mem.Allocator;
const private_dir_permissions = std.Io.File.Permissions.fromMode(0o700);
const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);

pub const subagent_relationship_index_file = "relationship-index.bin";

pub const ManagedChildKind = enum {
    background_records,
    background_logs,
    command_artifacts,
    browser_artifacts,
    tool_results,
    subagent_control,
    terminal_state,
    terminal_proofs,
    /// Session-scoped context supplied by the client that created it, such as
    /// an ACP client system prompt.
    client_context,
};

pub const Mode = enum {
    read_only,
    writable,
};

pub const Options = struct {
    replace_ops: io_mod.DurableOps = .{},
    lock_ops: io_mod.LockOps = .{},
};

pub const SubagentControlInitError = error{
    OutOfMemory,
    SessionPathUnsafe,
    PrivateStatePermissionsUnsupported,
    SessionChildStoreFailed,
};

pub const TerminalInitError = SubagentControlInitError;

pub const AdvisoryLockError = error{
    OutOfMemory,
    InvalidManagedChildName,
    SessionChildReadOnly,
    SessionPathUnsafe,
    PrivateStatePermissionsUnsupported,
    LockBusy,
    LockUnsupported,
    SessionChildStoreFailed,
};

pub const ManagedStat = struct {
    size: u64,
    modified_at_ns: i128,
};

/// What a v2 session's blobs can fail with (D44).
pub const BlobError = error{
    OutOfMemory,
    /// This session holds no body under that name.
    BlobNotFound,
    /// The blob's bytes no longer match its name.
    BlobDamaged,
    BlobTooLarge,
    /// The session has closed, so nothing more can be stored.
    BlobStoreClosed,
    SessionChildReadOnly,
    BlobStoreFailed,
    NoSpaceLeft,
    AccessDenied,
    ReadOnlyFileSystem,
    FileTooBig,
};

/// The large bodies of a v2 session, each a blob of that session named by
/// its hash (D44). The session adapter implements it; every capability
/// that holds it keeps it alive through `retain` and `release`, so a copy
/// may outlive the session, which then refuses only new bodies.
pub const Blobs = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const Hash = [artifact_digest.blob_hex_bytes]u8;

    pub const VTable = struct {
        put: *const fn (ctx: *anyopaque, bytes: []const u8) BlobError!Hash,
        /// The first `len` bytes of an open file outside the session.
        put_file: *const fn (ctx: *anyopaque, file: std.Io.File, len: u64) BlobError!Hash,
        /// Keeps `bytes` as the compactor record `name`, replacing any record
        /// of that name (D50).
        put_record: *const fn (ctx: *anyopaque, name: []const u8, bytes: []const u8) BlobError!void,
        /// Every compactor record's name, with a moved session's old
        /// tool-results names (D50). `arena` owns the list.
        record_names: *const fn (ctx: *anyopaque, arena: Allocator) BlobError![]const []const u8,
        /// The blob a handle of `kind` refers to: the one it names, a
        /// compactor record's (D50), or in a session moved off the side
        /// folder, the one its old name maps to (D47).
        resolve: *const fn (ctx: *anyopaque, kind: ManagedChildKind, name: []const u8) BlobError!Hash,
        /// A blob's bytes, at most `max_bytes`, checked against its name.
        /// Caller owns.
        get: *const fn (ctx: *anyopaque, alloc: Allocator, hash: []const u8, max_bytes: usize) BlobError![]u8,
        /// The read-only file of a blob, for readers that page through a
        /// large body and tools that open files by path (D49). Caller owns.
        path: *const fn (ctx: *anyopaque, alloc: Allocator, hash: []const u8) BlobError![]u8,
        retain: *const fn (ctx: *anyopaque) void,
        release: *const fn (ctx: *anyopaque) void,
    };
};

pub const ManagedEntry = struct {
    relative_name: []u8,
    display_path: ?[]u8,

    pub fn deinit(self: *ManagedEntry, alloc: Allocator) void {
        alloc.free(self.relative_name);
        if (self.display_path) |path| alloc.free(path);
        self.* = undefined;
    }
};

pub const ManagedEntryList = struct {
    alloc: Allocator,
    names: [][]u8,

    pub fn deinit(self: *ManagedEntryList) void {
        for (self.names) |name| self.alloc.free(name);
        self.alloc.free(self.names);
        self.* = undefined;
    }
};

const ManagedFileImpl = struct {
    alloc: Allocator,
    file: std.Io.File,
    relative_name: []u8,
    display_path: ?[]u8,
};

pub const ManagedFile = struct {
    impl: *ManagedFileImpl,

    pub fn deinit(self: *ManagedFile) void {
        self.impl.file.close(io_mod.getIo());
        self.impl.alloc.free(self.impl.relative_name);
        if (self.impl.display_path) |path| self.impl.alloc.free(path);
        const alloc = self.impl.alloc;
        alloc.destroy(self.impl);
        self.* = undefined;
    }

    pub fn writeAll(self: *ManagedFile, bytes: []const u8) !void {
        try self.impl.file.writeStreamingAll(io_mod.getIo(), bytes);
    }

    pub fn sync(self: *ManagedFile) !void {
        try self.impl.file.sync(io_mod.getIo());
    }

    pub fn readToEnd(
        self: *ManagedFile,
        alloc: Allocator,
        max_bytes: usize,
    ) ![]u8 {
        return io_mod.readFileToEnd(alloc, &self.impl.file, max_bytes);
    }

    pub fn stat(self: *ManagedFile) !ManagedStat {
        return managedStat(self.impl.file);
    }

    pub fn readRange(
        self: *ManagedFile,
        alloc: Allocator,
        start: u64,
        len: usize,
    ) ![]u8 {
        if (len == 0) return alloc.dupe(u8, "");
        var read_buf: [8192]u8 = undefined;
        var reader = self.impl.file.reader(io_mod.getIo(), &read_buf);
        try reader.seekTo(start);
        const out = try alloc.alloc(u8, len);
        errdefer alloc.free(out);
        const read_len = try reader.interface.readSliceShort(out);
        if (read_len == out.len) return out;
        return alloc.realloc(out, read_len);
    }

    pub fn readRangeInto(
        self: *ManagedFile,
        start: u64,
        out: []u8,
    ) !usize {
        if (out.len == 0) return 0;
        var read_buf: [8192]u8 = undefined;
        var reader = self.impl.file.reader(io_mod.getIo(), &read_buf);
        try reader.seekTo(start);
        var total: usize = 0;
        while (total < out.len) {
            const read_len = try reader.interface.readSliceShort(out[total..]);
            if (read_len == 0) break;
            total += read_len;
        }
        return total;
    }

    pub fn relativeName(self: ManagedFile) []const u8 {
        return self.impl.relative_name;
    }

    pub fn displayPath(self: ManagedFile) ?[]const u8 {
        return self.impl.display_path;
    }

    /// Returns the verified open descriptor for immediate child stdio
    /// inheritance. The ManagedFile remains the owner and must outlive spawn.
    pub fn childStdioFile(self: ManagedFile) std.Io.File {
        return self.impl.file;
    }
};

const CapabilityImpl = struct {
    alloc: Allocator,
    mode: Mode,
    /// Null for a v2 session's capability, which holds its bodies as blobs
    /// and has no side folder (D48).
    session_dir: ?io_mod.VerifiedDir,
    blobs: ?Blobs = null,
    /// A v2 session's terminal folder, `~/.fx/terminal/{id}` (D45), where
    /// its terminal kinds route; opened on first use and made only by a
    /// write. `display_session_path` is its path.
    terminal_dir: ?io_mod.VerifiedDir = null,
    display_session_path: []u8,
    legacy_direct_kind: ?ManagedChildKind = null,
    legacy_background_root: bool = false,
    legacy_display_route: ?[]u8 = null,
    replace_ops: io_mod.DurableOps,
    lock_ops: io_mod.LockOps,
    allowed_kind: ?ManagedChildKind = null,
    background_records: ?io_mod.VerifiedDir = null,
    background_logs: ?io_mod.VerifiedDir = null,
    logs_parent: ?io_mod.VerifiedDir = null,
    command_artifacts: ?io_mod.VerifiedDir = null,
    artifacts_parent: ?io_mod.VerifiedDir = null,
    browser_artifacts: ?io_mod.VerifiedDir = null,
    tool_results: ?io_mod.VerifiedDir = null,
    subagent_control: ?io_mod.VerifiedDir = null,
    terminal_parent: ?io_mod.VerifiedDir = null,
    terminal_state: ?io_mod.VerifiedDir = null,
    terminal_proofs: ?io_mod.VerifiedDir = null,
    client_context: ?io_mod.VerifiedDir = null,
    indeterminate_names: [@typeInfo(ManagedChildKind).@"enum".fields.len]?[]u8 =
        [_]?[]u8{null} ** @typeInfo(ManagedChildKind).@"enum".fields.len,

    fn deinit(self: *CapabilityImpl) void {
        closeOptionalDir(&self.background_logs);
        closeOptionalDir(&self.background_records);
        closeOptionalDir(&self.command_artifacts);
        closeOptionalDir(&self.logs_parent);
        closeOptionalDir(&self.browser_artifacts);
        closeOptionalDir(&self.artifacts_parent);
        closeOptionalDir(&self.tool_results);
        closeOptionalDir(&self.subagent_control);
        closeOptionalDir(&self.terminal_state);
        closeOptionalDir(&self.terminal_proofs);
        closeOptionalDir(&self.terminal_parent);
        closeOptionalDir(&self.client_context);
        closeOptionalDir(&self.session_dir);
        closeOptionalDir(&self.terminal_dir);
        if (self.blobs) |blobs| blobs.vtable.release(blobs.ctx);
        self.alloc.free(self.display_session_path);
        if (self.legacy_display_route) |path| self.alloc.free(path);
        for (&self.indeterminate_names) |*name| {
            if (name.*) |owned| self.alloc.free(owned);
            name.* = null;
        }
    }

    fn route(
        self: *CapabilityImpl,
        kind: ManagedChildKind,
        create_if_missing: bool,
    ) !?*io_mod.VerifiedDir {
        if (self.allowed_kind) |allowed| {
            if (kind != allowed) return error.SessionChildStoreFailed;
        }
        if (self.legacy_direct_kind) |direct_kind| {
            if (kind != direct_kind) return error.SessionChildStoreFailed;
            return self.directRoute(kind);
        }
        if (self.legacy_background_root) {
            return switch (kind) {
                .background_records => &self.background_records.?,
                .background_logs => if (self.background_logs) |*managed_route|
                    managed_route
                else
                    null,
                else => error.SessionChildStoreFailed,
            };
        }
        // A v2 capability has no side folder: its bodies are blobs (D48),
        // and its terminal state lives in its terminal folder (D45).
        const session_dir = if (self.session_dir) |*dir| dir else switch (kind) {
            .terminal_state, .terminal_proofs => try self.terminalDir(create_if_missing) orelse return null,
            else => return if (create_if_missing) error.SessionChildStoreFailed else null,
        };
        return switch (kind) {
            .background_records => self.ensureComponent(
                session_dir,
                &self.background_records,
                "background",
                create_if_missing,
            ),
            .background_logs => blk: {
                const parent = try self.route(
                    .background_records,
                    create_if_missing,
                ) orelse break :blk null;
                break :blk self.ensureComponent(
                    parent,
                    &self.background_logs,
                    "logs",
                    create_if_missing,
                );
            },
            .command_artifacts => blk: {
                const parent = try self.ensureComponent(
                    session_dir,
                    &self.logs_parent,
                    "logs",
                    create_if_missing,
                ) orelse break :blk null;
                break :blk self.ensureComponent(
                    parent,
                    &self.command_artifacts,
                    "commands",
                    create_if_missing,
                );
            },
            .browser_artifacts => blk: {
                const parent = try self.ensureComponent(
                    session_dir,
                    &self.artifacts_parent,
                    "artifacts",
                    create_if_missing,
                ) orelse break :blk null;
                break :blk self.ensureComponent(
                    parent,
                    &self.browser_artifacts,
                    "browser",
                    create_if_missing,
                );
            },
            .tool_results => self.ensureComponent(
                session_dir,
                &self.tool_results,
                "tool-results",
                create_if_missing,
            ),
            .subagent_control => self.ensureComponent(
                session_dir,
                &self.subagent_control,
                "subagent",
                create_if_missing,
            ),
            .client_context => self.ensureComponent(
                session_dir,
                &self.client_context,
                "client",
                create_if_missing,
            ),
            .terminal_state, .terminal_proofs => blk: {
                const parent = try self.ensureComponent(
                    session_dir,
                    &self.terminal_parent,
                    "terminal",
                    create_if_missing,
                ) orelse break :blk null;
                break :blk switch (kind) {
                    .terminal_state => self.ensureComponent(
                        parent,
                        &self.terminal_state,
                        "state",
                        create_if_missing,
                    ),
                    .terminal_proofs => self.ensureComponent(
                        parent,
                        &self.terminal_proofs,
                        "proofs",
                        create_if_missing,
                    ),
                    else => unreachable,
                };
            },
        };
    }

    /// A v2 capability's terminal folder (D45), opened once. Missing, it is
    /// made only for a write (`create`); a read finds nothing.
    fn terminalDir(self: *CapabilityImpl, create: bool) !?*io_mod.VerifiedDir {
        if (self.terminal_dir) |*dir| return dir;
        const owner_path = self.display_session_path;
        if (self.blobs == null or owner_path.len == 0) return if (create) error.SessionChildStoreFailed else null;
        if (create and self.mode != .writable) return error.SessionChildReadOnly;
        const root_path = std.fs.path.dirname(owner_path) orelse return error.SessionPathUnsafe;
        const fx_path = std.fs.path.dirname(root_path) orelse return error.SessionPathUnsafe;
        var fx = io_mod.VerifiedDir{ .dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), fx_path, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return if (create) error.SessionChildStoreFailed else null,
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return error.SessionChildStoreFailed,
        } };
        defer fx.close();
        const root_name = std.fs.path.basename(root_path);
        var root = if (create)
            try io_mod.openOrCreateVerifiedPrivateDir(&fx, root_name)
        else
            (try io_mod.openVerifiedPrivateDirIfPresent(&fx, root_name)) orelse return null;
        defer root.close();
        const id = std.fs.path.basename(owner_path);
        self.terminal_dir = if (create)
            try io_mod.openOrCreateVerifiedPrivateDir(&root, id)
        else
            (try io_mod.openVerifiedPrivateDirIfPresent(&root, id)) orelse return null;
        return &self.terminal_dir.?;
    }

    fn directRoute(
        self: *CapabilityImpl,
        kind: ManagedChildKind,
    ) *io_mod.VerifiedDir {
        return switch (kind) {
            .background_records => &self.background_records.?,
            .background_logs => &self.background_logs.?,
            .command_artifacts => &self.command_artifacts.?,
            .browser_artifacts => &self.browser_artifacts.?,
            .tool_results => &self.tool_results.?,
            .subagent_control => &self.subagent_control.?,
            .terminal_state => &self.terminal_state.?,
            .terminal_proofs => &self.terminal_proofs.?,
            .client_context => &self.client_context.?,
        };
    }

    fn ensureComponent(
        self: *CapabilityImpl,
        parent: *io_mod.VerifiedDir,
        slot: *?io_mod.VerifiedDir,
        name: []const u8,
        create_if_missing: bool,
    ) !?*io_mod.VerifiedDir {
        if (slot.*) |*dir| return dir;

        var created = false;
        var dir = parent.dir.openDir(io_mod.getIo(), name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (!create_if_missing) return null;
                if (self.mode != .writable) return error.SessionChildReadOnly;
                parent.dir.createDir(
                    io_mod.getIo(),
                    name,
                    private_dir_permissions,
                ) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => {},
                    error.NotDir, error.SymLinkLoop => {
                        return error.SessionPathUnsafe;
                    },
                    else => return error.SessionChildStoreFailed,
                };
                created = true;
                break :blk parent.dir.openDir(io_mod.getIo(), name, .{
                    .iterate = true,
                    .follow_symlinks = false,
                }) catch |open_err| switch (open_err) {
                    error.NotDir, error.SymLinkLoop => {
                        return error.SessionPathUnsafe;
                    },
                    else => return error.SessionChildStoreFailed,
                };
            },
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return error.SessionChildStoreFailed,
        };
        errdefer dir.close(io_mod.getIo());

        if (self.mode == .writable) {
            dir.setPermissions(io_mod.getIo(), private_dir_permissions) catch
                return error.PrivateStatePermissionsUnsupported;
        }
        try verifyPrivateDirectory(dir);
        if (created) {
            io_mod.syncVerifiedDir(parent.dir) catch
                return error.SessionChildStoreFailed;
        }

        slot.* = .{ .dir = dir };
        return &slot.*.?;
    }

    fn displayPath(
        self: *CapabilityImpl,
        alloc: Allocator,
        kind: ManagedChildKind,
        name: []const u8,
    ) ![]u8 {
        const route_path = try self.displayRoutePath(alloc, kind);
        defer alloc.free(route_path);
        return std.fs.path.join(alloc, &.{ route_path, name });
    }

    fn displayRoutePath(
        self: *CapabilityImpl,
        alloc: Allocator,
        kind: ManagedChildKind,
    ) ![]u8 {
        if (self.legacy_direct_kind == kind) {
            return alloc.dupe(u8, self.legacy_display_route.?);
        }
        if (self.legacy_background_root) {
            return switch (kind) {
                .background_records => alloc.dupe(
                    u8,
                    self.legacy_display_route.?,
                ),
                .background_logs => std.fs.path.join(
                    alloc,
                    &.{ self.legacy_display_route.?, "logs" },
                ),
                else => error.SessionChildStoreFailed,
            };
        }
        return switch (kind) {
            .background_records => std.fs.path.join(
                alloc,
                &.{ self.display_session_path, "background" },
            ),
            .background_logs => std.fs.path.join(
                alloc,
                &.{ self.display_session_path, "background", "logs" },
            ),
            .command_artifacts => std.fs.path.join(
                alloc,
                &.{ self.display_session_path, "logs", "commands" },
            ),
            .browser_artifacts => std.fs.path.join(
                alloc,
                &.{ self.display_session_path, "artifacts", "browser" },
            ),
            .tool_results => std.fs.path.join(
                alloc,
                &.{ self.display_session_path, "tool-results" },
            ),
            .subagent_control => std.fs.path.join(
                alloc,
                &.{ self.display_session_path, "subagent" },
            ),
            .terminal_state => std.fs.path.join(
                alloc,
                &.{ self.display_session_path, "terminal", "state" },
            ),
            .terminal_proofs => std.fs.path.join(
                alloc,
                &.{ self.display_session_path, "terminal", "proofs" },
            ),
            .client_context => std.fs.path.join(
                alloc,
                &.{ self.display_session_path, "client" },
            ),
        };
    }

    fn setIndeterminate(
        self: *CapabilityImpl,
        kind: ManagedChildKind,
        name: []const u8,
    ) !void {
        const replacement = try self.alloc.dupe(u8, name);
        self.setIndeterminateOwned(kind, replacement);
    }

    fn setIndeterminateOwned(
        self: *CapabilityImpl,
        kind: ManagedChildKind,
        replacement: []u8,
    ) void {
        const index = @intFromEnum(kind);
        if (self.indeterminate_names[index]) |old| self.alloc.free(old);
        self.indeterminate_names[index] = replacement;
    }

    fn clearIndeterminate(self: *CapabilityImpl, kind: ManagedChildKind) void {
        const index = @intFromEnum(kind);
        if (self.indeterminate_names[index]) |name| self.alloc.free(name);
        self.indeterminate_names[index] = null;
    }

    fn resolveIndeterminate(self: *CapabilityImpl, kind: ManagedChildKind) !void {
        const name = self.indeterminate_names[@intFromEnum(kind)] orelse return;
        const route_dir = try self.route(kind, false) orelse
            return error.FileNotFound;
        var file = try openPrivateFile(route_dir, name, .read_only, self.mode);
        file.close(io_mod.getIo());
        self.replace_ops.sync_dir(
            self.replace_ops.ctx,
            route_dir.dir,
        ) catch return error.SessionChildCommitIndeterminate;
        self.clearIndeterminate(kind);
    }
};

/// Blobs held in memory, for the stores' tests: bodies by hash, with the
/// adapter's rules for names and limits, compactor records by name, and no
/// moved map. Given a folder, each body is also written there read-only, so
/// `path` has a file.
pub const MemoryBlobsForTesting = struct {
    alloc: Allocator,
    dir: ?[]const u8 = null,
    mutex: std.Io.Mutex = .init,
    bodies: std.StringHashMapUnmanaged([]u8) = .empty,
    records: std.StringArrayHashMapUnmanaged(Blobs.Hash) = .empty,
    refs: usize = 0,
    closed: bool = false,
    puts: usize = 0,

    const vtable: Blobs.VTable = .{
        .put = put,
        .put_file = putFile,
        .put_record = putRecord,
        .record_names = recordNames,
        .resolve = resolve,
        .get = get,
        .path = path,
        .retain = retain,
        .release = release,
    };

    pub fn init(alloc: Allocator) MemoryBlobsForTesting {
        return .{ .alloc = alloc };
    }

    /// As `init`, also writing each body to `dir`, which must outlive it.
    pub fn initWithFiles(alloc: Allocator, dir: []const u8) MemoryBlobsForTesting {
        return .{ .alloc = alloc, .dir = dir };
    }

    pub fn deinit(self: *MemoryBlobsForTesting) void {
        std.debug.assert(self.refs == 0);
        var it = self.bodies.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.bodies.deinit(self.alloc);
        for (self.records.keys()) |name| self.alloc.free(name);
        self.records.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn blobs(self: *MemoryBlobsForTesting) Blobs {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn count(self: *MemoryBlobsForTesting) usize {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.bodies.count();
    }

    fn from(ctx: *anyopaque) *MemoryBlobsForTesting {
        return @ptrCast(@alignCast(ctx));
    }

    fn put(ctx: *anyopaque, bytes: []const u8) BlobError!Blobs.Hash {
        const self = from(ctx);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hash = std.fmt.bytesToHex(digest, .lower);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.BlobStoreClosed;
        self.puts += 1;
        if (self.bodies.contains(&hash)) return hash;
        const key = try self.alloc.dupe(u8, &hash);
        errdefer self.alloc.free(key);
        const body = try self.alloc.dupe(u8, bytes);
        errdefer self.alloc.free(body);
        if (self.dir) |dir| {
            const file_path = try std.fs.path.join(self.alloc, &.{ dir, &hash });
            defer self.alloc.free(file_path);
            var file = std.Io.Dir.createFileAbsolute(io_mod.getIo(), file_path, .{
                .exclusive = true,
                .permissions = std.Io.File.Permissions.fromMode(0o400),
            }) catch return error.BlobStoreFailed;
            defer file.close(io_mod.getIo());
            file.writeStreamingAll(io_mod.getIo(), bytes) catch return error.BlobStoreFailed;
        }
        try self.bodies.put(self.alloc, key, body);
        return hash;
    }

    fn putFile(ctx: *anyopaque, file: std.Io.File, len: u64) BlobError!Blobs.Hash {
        const self = from(ctx);
        const bytes = try self.alloc.alloc(u8, std.math.cast(usize, len) orelse return error.BlobTooLarge);
        defer self.alloc.free(bytes);
        const got = file.readPositionalAll(io_mod.getIo(), bytes, 0) catch return error.BlobStoreFailed;
        if (got != bytes.len) return error.BlobStoreFailed;
        return put(ctx, bytes);
    }

    fn putRecord(ctx: *anyopaque, name: []const u8, bytes: []const u8) BlobError!void {
        const self = from(ctx);
        const hash = try put(ctx, bytes);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.records.getPtr(name)) |known| {
            known.* = hash;
            return;
        }
        const key = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(key);
        try self.records.put(self.alloc, key, hash);
    }

    fn recordNames(ctx: *anyopaque, arena: Allocator) BlobError![]const []const u8 {
        const self = from(ctx);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const names = try arena.alloc([]const u8, self.records.count());
        for (self.records.keys(), names) |name, *out| out.* = try arena.dupe(u8, name);
        return names;
    }

    fn resolve(ctx: *anyopaque, kind: ManagedChildKind, name: []const u8) BlobError!Blobs.Hash {
        const self = from(ctx);
        if (artifact_digest.blobHash(name)) |hash| return hash[0..artifact_digest.blob_hex_bytes].*;
        if (kind != .tool_results) return error.BlobNotFound;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.records.get(name) orelse error.BlobNotFound;
    }

    fn get(ctx: *anyopaque, alloc: Allocator, hash: []const u8, max_bytes: usize) BlobError![]u8 {
        const self = from(ctx);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const body = self.bodies.get(hash) orelse return error.BlobNotFound;
        if (body.len > max_bytes) return error.BlobTooLarge;
        return alloc.dupe(u8, body);
    }

    fn path(ctx: *anyopaque, alloc: Allocator, hash: []const u8) BlobError![]u8 {
        const self = from(ctx);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (!self.bodies.contains(hash)) return error.BlobNotFound;
        const dir = self.dir orelse return error.BlobStoreFailed;
        return std.fs.path.join(alloc, &.{ dir, hash });
    }

    fn retain(ctx: *anyopaque) void {
        const self = from(ctx);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.refs += 1;
    }

    fn release(ctx: *anyopaque) void {
        const self = from(ctx);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.refs -= 1;
    }
};

pub const SessionChildCapability = struct {
    impl: *CapabilityImpl,

    pub fn duplicate(
        self: *const SessionChildCapability,
        alloc: Allocator,
    ) !SessionChildCapability {
        if (self.impl.blobs) |blobs| return initBlobs(alloc, blobs, self.impl.display_session_path, self.impl.mode);
        return initWithOptions(
            alloc,
            self.impl.session_dir.?.dir,
            self.impl.display_session_path,
            self.impl.mode,
            .{},
        );
    }

    /// A v2 session's capability: its bodies are that session's blobs, its
    /// terminal kinds route to `terminal_path`, its `~/.fx/terminal/{id}`
    /// (D45), and it has no side folder, so every other kind is absent
    /// (D44, D48). An empty `terminal_path` gives no terminal kinds.
    pub fn initBlobs(alloc: Allocator, blobs: Blobs, terminal_path: []const u8, mode: Mode) !SessionChildCapability {
        if (mode == .writable) io_mod.e2eFailIfDurableMutationAttempted();
        const display = try alloc.dupe(u8, terminal_path);
        errdefer alloc.free(display);
        const impl = try alloc.create(CapabilityImpl);
        impl.* = .{
            .alloc = alloc,
            .mode = mode,
            .session_dir = null,
            .blobs = blobs,
            .display_session_path = display,
            .replace_ops = .{},
            .lock_ops = .{},
        };
        blobs.vtable.retain(blobs.ctx);
        return .{ .impl = impl };
    }

    /// Whether bodies are blobs of a v2 session rather than files (D44).
    pub fn holdsBlobs(self: *const SessionChildCapability) bool {
        return self.impl.blobs != null;
    }

    /// Stores a body as a blob and returns its hash; `holdsBlobs` only.
    pub fn putBlob(self: *SessionChildCapability, bytes: []const u8) BlobError!Blobs.Hash {
        const blobs = try self.writableBlobs();
        return blobs.vtable.put(blobs.ctx, bytes);
    }

    /// As `putBlob`, for the first `len` bytes of an open file.
    pub fn putBlobFile(self: *SessionChildCapability, file: std.Io.File, len: u64) BlobError!Blobs.Hash {
        const blobs = try self.writableBlobs();
        return blobs.vtable.put_file(blobs.ctx, file, len);
    }

    /// Keeps `bytes` as the compactor record `name`, replacing any of that
    /// name; `holdsBlobs` only (D50). `readBlob` and `openBlobFile` read it
    /// back under `.tool_results`.
    pub fn putRecord(self: *SessionChildCapability, name: []const u8, bytes: []const u8) BlobError!void {
        const blobs = try self.writableBlobs();
        return blobs.vtable.put_record(blobs.ctx, name, bytes);
    }

    /// Every compactor record's name; `holdsBlobs` only (D50). `arena` owns
    /// the list.
    pub fn recordNames(self: *SessionChildCapability, arena: Allocator) BlobError![]const []const u8 {
        const blobs = self.impl.blobs orelse return error.BlobStoreFailed;
        return blobs.vtable.record_names(blobs.ctx, arena);
    }

    /// The body a handle of `kind` refers to, at most `max_bytes` and
    /// checked against its blob's name; caller owns. `holdsBlobs` only.
    pub fn readBlob(self: *SessionChildCapability, alloc: Allocator, kind: ManagedChildKind, name: []const u8, max_bytes: usize) BlobError![]u8 {
        const blobs = self.impl.blobs orelse return error.BlobStoreFailed;
        const hash = try blobs.vtable.resolve(blobs.ctx, kind, name);
        return blobs.vtable.get(blobs.ctx, alloc, &hash, max_bytes);
    }

    /// Opens the read-only file of the blob a handle of `kind` refers to,
    /// for a reader that pages through it (D49). Its bytes are not checked
    /// against the name, as a side file's never were. Caller closes it.
    pub fn openBlobFile(self: *SessionChildCapability, alloc: Allocator, kind: ManagedChildKind, name: []const u8) BlobError!std.Io.File {
        const blobs = self.impl.blobs orelse return error.BlobStoreFailed;
        const hash = try blobs.vtable.resolve(blobs.ctx, kind, name);
        const file_path = try blobs.vtable.path(blobs.ctx, alloc, &hash);
        defer alloc.free(file_path);
        return std.Io.Dir.openFileAbsolute(io_mod.getIo(), file_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => error.BlobNotFound,
            error.AccessDenied, error.PermissionDenied => error.AccessDenied,
            else => error.BlobStoreFailed,
        };
    }

    /// The read-only file of the blob a handle of `kind` refers to, for a
    /// tool that opens files by path (D49); caller owns.
    pub fn blobPath(self: *SessionChildCapability, alloc: Allocator, kind: ManagedChildKind, name: []const u8) BlobError![]u8 {
        const blobs = self.impl.blobs orelse return error.BlobStoreFailed;
        const hash = try blobs.vtable.resolve(blobs.ctx, kind, name);
        return blobs.vtable.path(blobs.ctx, alloc, &hash);
    }

    fn writableBlobs(self: *SessionChildCapability) BlobError!Blobs {
        const blobs = self.impl.blobs orelse return error.BlobStoreFailed;
        if (self.impl.mode != .writable) return error.SessionChildReadOnly;
        return blobs;
    }

    pub fn init(
        alloc: Allocator,
        session_dir: std.Io.Dir,
        display_session_path: []const u8,
        mode: Mode,
    ) !SessionChildCapability {
        if (mode == .writable) io_mod.e2eFailIfDurableMutationAttempted();
        return initWithOptions(
            alloc,
            session_dir,
            display_session_path,
            mode,
            .{},
        );
    }

    pub fn initLegacyRoute(
        alloc: Allocator,
        route_path: []const u8,
        kind: ManagedChildKind,
        mode: Mode,
    ) !SessionChildCapability {
        if (mode == .writable) io_mod.e2eFailIfDurableMutationAttempted();
        if (mode == .writable) try config_runtime.makeAbsolutePath(route_path);
        var route = std.Io.Dir.openDirAbsolute(io_mod.getIo(), route_path, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        errdefer route.close(io_mod.getIo());
        if (mode == .writable) {
            route.setPermissions(io_mod.getIo(), private_dir_permissions) catch
                return error.PrivateStatePermissionsUnsupported;
        }
        return initOpenedLegacyRoute(alloc, route, route_path, kind, mode);
    }

    /// Reads only an existing control route; legacy session parents need not
    /// have acquired current-format directory permissions before discovery.
    pub fn initLegacySubagentControl(
        alloc: Allocator,
        session_dir: std.Io.Dir,
        display_session_path: []const u8,
    ) !?SessionChildCapability {
        var route = session_dir.openDir(io_mod.getIo(), "subagent", .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        errdefer route.close(io_mod.getIo());
        const display = try std.fs.path.join(alloc, &.{ display_session_path, "subagent" });
        defer alloc.free(display);
        return try initOpenedLegacyRoute(alloc, route, display, .subagent_control, .read_only);
    }

    fn initOpenedLegacyRoute(
        alloc: Allocator,
        route: std.Io.Dir,
        route_path: []const u8,
        kind: ManagedChildKind,
        mode: Mode,
    ) !SessionChildCapability {
        try verifyPrivateDirectory(route);

        var retained = try route.openDir(io_mod.getIo(), ".", .{
            .iterate = true,
            .follow_symlinks = false,
        });
        errdefer retained.close(io_mod.getIo());
        const display = try alloc.dupe(u8, route_path);
        errdefer alloc.free(display);
        const direct_display = try alloc.dupe(u8, route_path);
        errdefer alloc.free(direct_display);
        const impl = try alloc.create(CapabilityImpl);
        impl.* = .{
            .alloc = alloc,
            .mode = mode,
            .session_dir = .{ .dir = retained },
            .display_session_path = display,
            .legacy_direct_kind = kind,
            .legacy_display_route = direct_display,
            .replace_ops = .{},
            .lock_ops = .{},
        };
        switch (kind) {
            .background_records => impl.background_records = .{ .dir = route },
            .background_logs => impl.background_logs = .{ .dir = route },
            .command_artifacts => impl.command_artifacts = .{ .dir = route },
            .browser_artifacts => impl.browser_artifacts = .{ .dir = route },
            .tool_results => impl.tool_results = .{ .dir = route },
            .subagent_control => impl.subagent_control = .{ .dir = route },
            .terminal_state => impl.terminal_state = .{ .dir = route },
            .terminal_proofs => impl.terminal_proofs = .{ .dir = route },
            .client_context => impl.client_context = .{ .dir = route },
        }
        return .{ .impl = impl };
    }

    pub fn initLegacyBackgroundRoutes(
        alloc: Allocator,
        background_path: []const u8,
        mode: Mode,
    ) !SessionChildCapability {
        if (mode == .writable) io_mod.e2eFailIfDurableMutationAttempted();
        if (mode == .writable) {
            try config_runtime.makeAbsolutePath(background_path);
        }
        var records = std.Io.Dir.openDirAbsolute(
            io_mod.getIo(),
            background_path,
            .{ .iterate = true, .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        errdefer records.close(io_mod.getIo());
        if (mode == .writable) {
            records.setPermissions(
                io_mod.getIo(),
                private_dir_permissions,
            ) catch return error.PrivateStatePermissionsUnsupported;
        }
        try verifyPrivateDirectory(records);

        if (mode == .writable) {
            records.createDir(
                io_mod.getIo(),
                "logs",
                private_dir_permissions,
            ) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                error.NotDir, error.SymLinkLoop => {
                    return error.SessionPathUnsafe;
                },
                else => return error.SessionChildStoreFailed,
            };
        }
        const logs: ?std.Io.Dir = records.openDir(io_mod.getIo(), "logs", .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => if (mode == .read_only)
                null
            else
                return error.SessionChildStoreFailed,
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        errdefer if (logs) |route| route.close(io_mod.getIo());
        if (logs) |route| {
            if (mode == .writable) {
                route.setPermissions(
                    io_mod.getIo(),
                    private_dir_permissions,
                ) catch return error.PrivateStatePermissionsUnsupported;
            }
            try verifyPrivateDirectory(route);
        }

        var retained = try records.openDir(io_mod.getIo(), ".", .{
            .iterate = true,
            .follow_symlinks = false,
        });
        errdefer retained.close(io_mod.getIo());
        const display = try alloc.dupe(u8, background_path);
        errdefer alloc.free(display);
        const direct_display = try alloc.dupe(u8, background_path);
        errdefer alloc.free(direct_display);
        const impl = try alloc.create(CapabilityImpl);
        impl.* = .{
            .alloc = alloc,
            .mode = mode,
            .session_dir = .{ .dir = retained },
            .display_session_path = display,
            .legacy_background_root = true,
            .legacy_display_route = direct_display,
            .replace_ops = .{},
            .lock_ops = .{},
            .background_records = .{ .dir = records },
            .background_logs = if (logs) |route|
                .{ .dir = route }
            else
                null,
        };
        return .{ .impl = impl };
    }

    pub fn initForTesting(
        alloc: Allocator,
        session_dir: std.Io.Dir,
        display_session_path: []const u8,
        mode: Mode,
        options: Options,
    ) !SessionChildCapability {
        return initWithOptions(
            alloc,
            session_dir,
            display_session_path,
            mode,
            options,
        );
    }

    fn initWithOptions(
        alloc: Allocator,
        session_dir: std.Io.Dir,
        display_session_path: []const u8,
        mode: Mode,
        options: Options,
    ) !SessionChildCapability {
        if (mode == .writable) io_mod.e2eFailIfDurableMutationAttempted();
        var retained = try session_dir.openDir(io_mod.getIo(), ".", .{
            .iterate = true,
            .follow_symlinks = false,
        });
        errdefer retained.close(io_mod.getIo());
        try verifyPrivateDirectory(retained);
        const display = try alloc.dupe(u8, display_session_path);
        errdefer alloc.free(display);
        const impl = try alloc.create(CapabilityImpl);
        impl.* = .{
            .alloc = alloc,
            .mode = mode,
            .session_dir = .{ .dir = retained },
            .display_session_path = display,
            .replace_ops = options.replace_ops,
            .lock_ops = options.lock_ops,
        };
        return .{ .impl = impl };
    }

    /// Opens a capability restricted to the subagent control route. This does
    /// not acquire or imply authority over the session transcript.
    pub fn initSubagentControl(
        alloc: Allocator,
        session_dir: std.Io.Dir,
        display_session_path: []const u8,
        mode: Mode,
        options: Options,
    ) SubagentControlInitError!SessionChildCapability {
        var capability = initWithOptions(
            alloc,
            session_dir,
            display_session_path,
            mode,
            options,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            error.PrivateStatePermissionsUnsupported => error.PrivateStatePermissionsUnsupported,
            else => error.SessionChildStoreFailed,
        };
        capability.impl.allowed_kind = .subagent_control;
        return capability;
    }

    /// Opens a capability restricted to host-owned terminal records and
    /// payloads. Holder proofs remain inaccessible through this route.
    pub fn initTerminalState(
        alloc: Allocator,
        session_dir: std.Io.Dir,
        display_session_path: []const u8,
        mode: Mode,
        options: Options,
    ) TerminalInitError!SessionChildCapability {
        var capability = initWithOptions(
            alloc,
            session_dir,
            display_session_path,
            mode,
            options,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            error.PrivateStatePermissionsUnsupported => error.PrivateStatePermissionsUnsupported,
            else => error.SessionChildStoreFailed,
        };
        capability.impl.allowed_kind = .terminal_state;
        return capability;
    }

    /// Opens a capability restricted to holder proofs in the owning durable
    /// fx session. It does not imply access to host-owned terminal state.
    pub fn initTerminalProofs(
        alloc: Allocator,
        session_dir: std.Io.Dir,
        display_session_path: []const u8,
        mode: Mode,
        options: Options,
    ) TerminalInitError!SessionChildCapability {
        var capability = initWithOptions(
            alloc,
            session_dir,
            display_session_path,
            mode,
            options,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            error.PrivateStatePermissionsUnsupported => error.PrivateStatePermissionsUnsupported,
            else => error.SessionChildStoreFailed,
        };
        capability.impl.allowed_kind = .terminal_proofs;
        return capability;
    }

    pub fn deinit(self: *SessionChildCapability) void {
        const alloc = self.impl.alloc;
        self.impl.deinit();
        alloc.destroy(self.impl);
        self.* = undefined;
    }

    pub fn cloneReadOnly(
        self: *const SessionChildCapability,
        alloc: Allocator,
    ) !SessionChildCapability {
        if (self.impl.legacy_direct_kind != null or
            self.impl.legacy_background_root)
        {
            return error.SessionChildStoreFailed;
        }
        var cloned = if (self.impl.blobs) |blobs|
            try initBlobs(alloc, blobs, self.impl.display_session_path, .read_only)
        else
            try initWithOptions(
                alloc,
                self.impl.session_dir.?.dir,
                self.impl.display_session_path,
                .read_only,
                .{},
            );
        cloned.impl.allowed_kind = self.impl.allowed_kind;
        return cloned;
    }

    pub fn createExclusiveFile(
        self: *SessionChildCapability,
        alloc: Allocator,
        kind: ManagedChildKind,
        name: []const u8,
    ) !ManagedFile {
        try validateName(name);
        if (self.impl.mode != .writable) return error.SessionChildReadOnly;
        try self.impl.resolveIndeterminate(kind);
        const route_dir = (try self.impl.route(kind, true)).?;
        var file = route_dir.dir.createFile(io_mod.getIo(), name, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .permissions = private_file_permissions,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.IsDir, error.NotDir, error.SymLinkLoop => {
                return error.SessionPathUnsafe;
            },
            error.PathAlreadyExists => {
                const existing = route_dir.dir.statFile(
                    io_mod.getIo(),
                    name,
                    .{ .follow_symlinks = false },
                ) catch |stat_err| switch (stat_err) {
                    error.NotDir, error.SymLinkLoop => {
                        return error.SessionPathUnsafe;
                    },
                    else => return stat_err,
                };
                try verifyPrivateStat(existing);
                return error.PathAlreadyExists;
            },
            else => return err,
        };
        var file_open = true;
        errdefer if (file_open) file.close(io_mod.getIo());
        file.setPermissions(io_mod.getIo(), private_file_permissions) catch
            return error.PrivateStatePermissionsUnsupported;
        try verifyPrivateRegularFile(file);
        io_mod.syncVerifiedDir(route_dir.dir) catch {
            file.close(io_mod.getIo());
            file_open = false;
            route_dir.dir.deleteFile(io_mod.getIo(), name) catch {};
            return error.SessionChildStoreFailed;
        };
        const managed = wrapManagedFile(
            alloc,
            file,
            name,
            try self.impl.displayPath(alloc, kind, name),
        ) catch |err| {
            file.close(io_mod.getIo());
            file_open = false;
            route_dir.dir.deleteFile(io_mod.getIo(), name) catch {};
            return err;
        };
        file_open = false;
        return managed;
    }

    pub fn openFileReadOnly(
        self: *SessionChildCapability,
        alloc: Allocator,
        kind: ManagedChildKind,
        name: []const u8,
    ) !ManagedFile {
        try validateName(name);
        const route_dir = try self.impl.route(kind, false) orelse
            return error.FileNotFound;
        const file = try openPrivateFile(
            route_dir,
            name,
            .read_only,
            self.impl.mode,
        );
        return wrapManagedFile(
            alloc,
            file,
            name,
            try self.impl.displayPath(alloc, kind, name),
        ) catch |err| {
            file.close(io_mod.getIo());
            return err;
        };
    }

    pub fn stat(
        self: *SessionChildCapability,
        kind: ManagedChildKind,
        name: []const u8,
    ) !ManagedStat {
        try validateName(name);
        const route_dir = try self.impl.route(kind, false) orelse
            return error.FileNotFound;
        var file = try openPrivateFile(
            route_dir,
            name,
            .read_only,
            self.impl.mode,
        );
        defer file.close(io_mod.getIo());
        return managedStat(file);
    }

    pub fn truncate(
        self: *SessionChildCapability,
        kind: ManagedChildKind,
        name: []const u8,
        length: u64,
    ) !void {
        try validateName(name);
        if (self.impl.mode != .writable) return error.SessionChildReadOnly;
        const route_dir = try self.impl.route(kind, false) orelse
            return error.FileNotFound;
        var file = try openPrivateFile(
            route_dir,
            name,
            .read_write,
            self.impl.mode,
        );
        defer file.close(io_mod.getIo());
        try file.setLength(io_mod.getIo(), length);
        try file.sync(io_mod.getIo());
    }

    pub fn iterate(
        self: *SessionChildCapability,
        alloc: Allocator,
        kind: ManagedChildKind,
    ) !ManagedEntryList {
        const route_dir = try self.impl.route(kind, false) orelse {
            return .{
                .alloc = alloc,
                .names = try alloc.alloc([]u8, 0),
            };
        };

        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |name| alloc.free(name);
            names.deinit(alloc);
        }
        var iter = route_dir.dir.iterate();
        while (try iter.next(io_mod.getIo())) |entry| {
            try validateName(entry.name);
            if (kind == .background_records and
                std.mem.eql(u8, entry.name, "logs"))
            {
                var child = route_dir.dir.openDir(
                    io_mod.getIo(),
                    entry.name,
                    .{ .follow_symlinks = false },
                ) catch |err| switch (err) {
                    error.NotDir, error.SymLinkLoop => {
                        return error.SessionPathUnsafe;
                    },
                    else => return err,
                };
                defer child.close(io_mod.getIo());
                try verifyPrivateDirectory(child);
                continue;
            }
            const file_stat = route_dir.dir.statFile(io_mod.getIo(), entry.name, .{
                .follow_symlinks = false,
            }) catch |err| switch (err) {
                error.NotDir, error.SymLinkLoop => {
                    return error.SessionPathUnsafe;
                },
                else => return err,
            };
            try verifyPrivateStat(file_stat);
            const owned_name = try alloc.dupe(u8, entry.name);
            errdefer alloc.free(owned_name);
            try names.append(alloc, owned_name);
        }
        return .{
            .alloc = alloc,
            .names = try names.toOwnedSlice(alloc),
        };
    }

    pub fn atomicReplace(
        self: *SessionChildCapability,
        alloc: Allocator,
        kind: ManagedChildKind,
        name: []const u8,
        bytes: []const u8,
    ) !ManagedEntry {
        try validateName(name);
        if (self.impl.mode != .writable) return error.SessionChildReadOnly;
        try self.impl.resolveIndeterminate(kind);
        const route_dir = (try self.impl.route(kind, true)).?;
        var entry = try makeManagedEntry(self.impl, alloc, kind, name);
        errdefer entry.deinit(alloc);

        io_mod.durableReplaceVerifiedWithOps(
            alloc,
            route_dir,
            name,
            bytes,
            self.impl.replace_ops,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DurablePathUnsafe => return error.SessionPathUnsafe,
            error.PrivateStatePermissionsUnsupported => return err,
            error.DurableReplacePostRenameFailed => {
                try self.impl.setIndeterminate(kind, name);
                return error.SessionChildCommitIndeterminate;
            },
            else => return error.SessionChildStoreFailed,
        };
        self.impl.clearIndeterminate(kind);
        return entry;
    }

    pub fn acquireTimedAdvisoryLock(
        self: *SessionChildCapability,
        kind: ManagedChildKind,
        name: []const u8,
        deadline_ms: u64,
    ) AdvisoryLockError!io_mod.TimedAdvisoryLock {
        validateName(name) catch return error.InvalidManagedChildName;
        if (self.impl.mode != .writable) return error.SessionChildReadOnly;
        const route_dir = (self.impl.route(kind, true) catch |err| return switch (err) {
            error.SessionChildReadOnly => error.SessionChildReadOnly,
            error.SessionPathUnsafe => error.SessionPathUnsafe,
            error.PrivateStatePermissionsUnsupported => error.PrivateStatePermissionsUnsupported,
            else => error.SessionChildStoreFailed,
        }).?;
        return io_mod.acquireTimedAdvisoryLockWithOps(
            route_dir,
            name,
            deadline_ms,
            self.impl.lock_ops,
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.LockBusy => error.LockBusy,
            error.LockUnsupported => error.LockUnsupported,
            error.DurablePathUnsafe => error.SessionPathUnsafe,
            error.PrivateStatePermissionsUnsupported => error.PrivateStatePermissionsUnsupported,
            else => error.SessionChildStoreFailed,
        };
    }

    pub fn delete(
        self: *SessionChildCapability,
        kind: ManagedChildKind,
        name: []const u8,
    ) !void {
        try validateName(name);
        if (self.impl.mode != .writable) return error.SessionChildReadOnly;
        try self.impl.resolveIndeterminate(kind);
        const route_dir = try self.impl.route(kind, false) orelse
            return error.FileNotFound;
        _ = try self.stat(kind, name);
        route_dir.dir.deleteFile(io_mod.getIo(), name) catch |err| switch (err) {
            error.IsDir, error.NotDir, error.SymLinkLoop => {
                return error.SessionPathUnsafe;
            },
            else => return err,
        };
        io_mod.syncVerifiedDir(route_dir.dir) catch
            return error.SessionChildStoreFailed;
    }

    pub fn rename(
        self: *SessionChildCapability,
        kind: ManagedChildKind,
        source_name: []const u8,
        target_name: []const u8,
    ) !void {
        try validateName(source_name);
        try validateName(target_name);
        if (self.impl.mode != .writable) return error.SessionChildReadOnly;
        try self.impl.resolveIndeterminate(kind);
        const route_dir = try self.impl.route(kind, false) orelse
            return error.FileNotFound;
        _ = try self.stat(kind, source_name);
        if (self.stat(kind, target_name)) |_| {
            return error.PathAlreadyExists;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        const pending_name = try self.impl.alloc.dupe(u8, target_name);
        var pending_name_owned = true;
        defer if (pending_name_owned) self.impl.alloc.free(pending_name);
        route_dir.dir.rename(
            source_name,
            route_dir.dir,
            target_name,
            io_mod.getIo(),
        ) catch |err| switch (err) {
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        self.impl.setIndeterminateOwned(kind, pending_name);
        pending_name_owned = false;
        self.impl.replace_ops.sync_dir(
            self.impl.replace_ops.ctx,
            route_dir.dir,
        ) catch {
            return error.SessionChildCommitIndeterminate;
        };
        self.impl.clearIndeterminate(kind);
    }

    pub fn hasIndeterminateEntry(
        self: SessionChildCapability,
        kind: ManagedChildKind,
        name: []const u8,
    ) bool {
        const pending = self.impl.indeterminate_names[@intFromEnum(kind)] orelse
            return false;
        return std.mem.eql(u8, pending, name);
    }

    pub fn confirmIndeterminateEntry(
        self: *SessionChildCapability,
        kind: ManagedChildKind,
        name: []const u8,
    ) !bool {
        try validateName(name);
        if (self.impl.mode != .writable) return error.SessionChildReadOnly;
        if (!self.hasIndeterminateEntry(kind, name)) return false;
        try self.impl.resolveIndeterminate(kind);
        return true;
    }

    pub fn indeterminateEntryName(
        self: SessionChildCapability,
        kind: ManagedChildKind,
    ) ?[]const u8 {
        return self.impl.indeterminate_names[@intFromEnum(kind)];
    }

    /// Returns non-authoritative metadata for compatibility rendering only.
    pub fn displayRoutePath(
        self: SessionChildCapability,
        alloc: Allocator,
        kind: ManagedChildKind,
    ) ![]u8 {
        return self.impl.displayRoutePath(alloc, kind);
    }

    pub fn validateManagedName(name: []const u8) !void {
        try validateName(name);
    }
};

fn closeOptionalDir(optional: *?io_mod.VerifiedDir) void {
    if (optional.*) |*dir| dir.close();
    optional.* = null;
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 255 or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, ".."))
    {
        return error.InvalidManagedChildName;
    }
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            byte != '.' and byte != '_' and byte != '-')
        {
            return error.InvalidManagedChildName;
        }
    }
}

fn verifyPrivateDirectory(dir: std.Io.Dir) !void {
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory) return error.SessionPathUnsafe;
    if (stat.permissions.toMode() & 0o777 != 0o700) {
        return error.PrivateStatePermissionsUnsupported;
    }
}

fn verifyPrivateRegularFile(file: std.Io.File) !void {
    try verifyPrivateStat(try file.stat(io_mod.getIo()));
}

fn verifyPrivateOpenedStat(
    stat: std.Io.File.Stat,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) !void {
    io_mod.verifyOpenedRegularFile(stat, mode) catch
        return error.SessionPathUnsafe;
    if (stat.permissions.toMode() & 0o777 != 0o600) {
        return error.PrivateStatePermissionsUnsupported;
    }
}

fn verifyPrivateStat(stat: std.Io.File.Stat) !void {
    if (stat.kind != .file or stat.nlink != 1) {
        return error.SessionPathUnsafe;
    }
    if (stat.permissions.toMode() & 0o777 != 0o600) {
        return error.PrivateStatePermissionsUnsupported;
    }
}

fn openPrivateFile(
    dir: *io_mod.VerifiedDir,
    name: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
    capability_mode: Mode,
) !std.Io.File {
    var file = io_mod.openExistingRegularFile(
        dir.dir,
        name,
        mode,
    ) catch |err| switch (err) {
        error.DurablePathUnsafe => return error.SessionPathUnsafe,
        else => return err,
    };
    errdefer file.close(io_mod.getIo());
    if (capability_mode == .writable and mode != .read_only) {
        file.setPermissions(io_mod.getIo(), private_file_permissions) catch
            return error.PrivateStatePermissionsUnsupported;
    }
    try verifyPrivateOpenedStat(try file.stat(io_mod.getIo()), mode);
    return file;
}

fn managedStat(file: std.Io.File) !ManagedStat {
    const stat = try file.stat(io_mod.getIo());
    try verifyPrivateStat(stat);
    return .{
        .size = stat.size,
        .modified_at_ns = stat.mtime.nanoseconds,
    };
}

fn wrapManagedFile(
    alloc: Allocator,
    file: std.Io.File,
    name: []const u8,
    display_path: []u8,
) !ManagedFile {
    errdefer alloc.free(display_path);
    const relative_name = try alloc.dupe(u8, name);
    errdefer alloc.free(relative_name);
    const impl = try alloc.create(ManagedFileImpl);
    impl.* = .{
        .alloc = alloc,
        .file = file,
        .relative_name = relative_name,
        .display_path = display_path,
    };
    return .{ .impl = impl };
}

fn makeManagedEntry(
    impl: *CapabilityImpl,
    alloc: Allocator,
    kind: ManagedChildKind,
    name: []const u8,
) !ManagedEntry {
    const relative_name = try alloc.dupe(u8, name);
    errdefer alloc.free(relative_name);
    return .{
        .relative_name = relative_name,
        .display_path = try impl.displayPath(alloc, kind, name),
    };
}

fn openTestSession(
    alloc: Allocator,
    tmp: *std.testing.TmpDir,
) !struct { dir: std.Io.Dir, display_path: []u8 } {
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    const display_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    errdefer alloc.free(display_path);
    const dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    return .{ .dir = dir, .display_path = display_path };
}

fn countEntries(dir: std.Io.Dir) !usize {
    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(io_mod.getIo()) != null) count += 1;
    return count;
}

test "private read-only file remains valid after atomic replacement unlinks it" {
    if (comptime @import("builtin").os.tag == .windows or
        @import("builtin").os.tag == .wasi)
    {
        return error.SkipZigTest;
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var target = try tmp.dir.createFile(io_mod.getIo(), "target", .{
        .truncate = true,
        .permissions = private_file_permissions,
    });
    target.close(io_mod.getIo());
    var file = try io_mod.openExistingRegularFile(
        tmp.dir,
        "target",
        .read_only,
    );
    defer file.close(io_mod.getIo());
    var replacement = try tmp.dir.createFile(io_mod.getIo(), "replacement", .{
        .truncate = true,
        .permissions = private_file_permissions,
    });
    replacement.close(io_mod.getIo());
    try tmp.dir.rename("replacement", tmp.dir, "target", io_mod.getIo());

    const stat = try file.stat(io_mod.getIo());
    try std.testing.expectEqual(@as(u64, 0), stat.nlink);
    try verifyPrivateOpenedStat(stat, .read_only);
    try std.testing.expectError(
        error.SessionPathUnsafe,
        verifyPrivateOpenedStat(stat, .read_write),
    );
}

test "managed child capability rejects invalid names and unsafe routes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try openTestSession(alloc, &tmp);
    defer session.dir.close(io_mod.getIo());
    defer alloc.free(session.display_path);
    var capability = try SessionChildCapability.initForTesting(
        alloc,
        session.dir,
        session.display_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    const invalid_names = [_][]const u8{
        "",
        ".",
        "..",
        "nested/name",
        "nested\\name",
        "nul\x00name",
        "snowman-\xe2\x98\x83",
    };
    for (invalid_names) |name| {
        try std.testing.expectError(
            error.InvalidManagedChildName,
            capability.stat(.tool_results, name),
        );
    }

    var linked = try capability.createExclusiveFile(alloc, .tool_results, "linked.txt");
    linked.deinit();
    var source_buf: [128]u8 = undefined;
    const source = try std.fmt.bufPrintZ(&source_buf, "tool-results/linked.txt", .{});
    var target_buf: [128]u8 = undefined;
    const target = try std.fmt.bufPrintZ(&target_buf, "tool-results/linked-again.txt", .{});
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.linkat(session.dir.handle, source, session.dir.handle, target, 0),
    );
    try std.testing.expectError(
        error.SessionPathUnsafe,
        capability.stat(.tool_results, "linked.txt"),
    );
    try std.testing.expectError(
        error.SessionPathUnsafe,
        capability.createExclusiveFile(
            alloc,
            .tool_results,
            "linked.txt",
        ),
    );
    try session.dir.createDir(
        io_mod.getIo(),
        "tool-results/wrong-kind",
        std.Io.File.Permissions.fromMode(0o700),
    );
    try std.testing.expectError(
        error.SessionPathUnsafe,
        capability.createExclusiveFile(
            alloc,
            .tool_results,
            "wrong-kind",
        ),
    );
    try session.dir.symLink(
        io_mod.getIo(),
        "../outside-file",
        "tool-results/linked-path",
        .{},
    );
    try std.testing.expectError(
        error.SessionPathUnsafe,
        capability.createExclusiveFile(
            alloc,
            .tool_results,
            "linked-path",
        ),
    );

    try tmp.dir.createDir(
        io_mod.getIo(),
        "outside",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var wrong_kind = try session.dir.createFile(io_mod.getIo(), "artifacts", .{
        .truncate = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    wrong_kind.close(io_mod.getIo());
    try std.testing.expectError(
        error.SessionPathUnsafe,
        capability.iterate(alloc, .browser_artifacts),
    );
}

test "read-only capability clone owns independent retained routes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try openTestSession(alloc, &tmp);
    defer session.dir.close(io_mod.getIo());
    defer alloc.free(session.display_path);
    var original = try SessionChildCapability.initForTesting(
        alloc,
        session.dir,
        session.display_path,
        .writable,
        .{},
    );
    var original_open = true;
    defer if (original_open) original.deinit();

    var file = try original.createExclusiveFile(
        alloc,
        .tool_results,
        "result.txt",
    );
    try file.writeAll("retained result");
    try file.sync();
    file.deinit();

    var cloned = try original.cloneReadOnly(alloc);
    defer cloned.deinit();
    original.deinit();
    original_open = false;

    var retained = try cloned.openFileReadOnly(
        alloc,
        .tool_results,
        "result.txt",
    );
    defer retained.deinit();
    const bytes = try retained.readToEnd(alloc, 64);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("retained result", bytes);
    try std.testing.expectError(
        error.SessionChildReadOnly,
        cloned.createExclusiveFile(alloc, .tool_results, "blocked.txt"),
    );
}

test "retained route handle contains pathname swaps" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try openTestSession(alloc, &tmp);
    defer session.dir.close(io_mod.getIo());
    defer alloc.free(session.display_path);
    var capability = try SessionChildCapability.initForTesting(
        alloc,
        session.dir,
        session.display_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    var first = try capability.createExclusiveFile(alloc, .tool_results, "first.txt");
    defer first.deinit();
    try first.writeAll("original");
    try first.sync();

    try tmp.dir.createDir(
        io_mod.getIo(),
        "outside",
        std.Io.File.Permissions.fromMode(0o700),
    );
    try session.dir.rename(
        "tool-results",
        session.dir,
        "retained-tool-results",
        io_mod.getIo(),
    );
    try session.dir.symLink(
        io_mod.getIo(),
        "../outside",
        "tool-results",
        .{ .is_directory = true },
    );

    var second = try capability.atomicReplace(
        alloc,
        .tool_results,
        "second.txt",
        "contained",
    );
    defer second.deinit(alloc);

    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(io_mod.getIo(), "outside/second.txt", .{}),
    );
    const contained = try tmp.dir.statFile(
        io_mod.getIo(),
        "session/retained-tool-results/second.txt",
        .{},
    );
    try std.testing.expectEqual(std.Io.File.Kind.file, contained.kind);
}

test "read only capability leaves every missing fixed route absent" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try openTestSession(alloc, &tmp);
    defer session.dir.close(io_mod.getIo());
    defer alloc.free(session.display_path);
    var capability = try SessionChildCapability.initForTesting(
        alloc,
        session.dir,
        session.display_path,
        .read_only,
        .{},
    );
    defer capability.deinit();

    const kinds = [_]ManagedChildKind{
        .background_records,
        .background_logs,
        .command_artifacts,
        .browser_artifacts,
        .tool_results,
        .subagent_control,
        .terminal_state,
        .terminal_proofs,
    };
    for (kinds) |kind| {
        var entries = try capability.iterate(alloc, kind);
        defer entries.deinit();
        try std.testing.expectEqual(@as(usize, 0), entries.names.len);
    }

    try std.testing.expectEqual(@as(usize, 0), try countEntries(session.dir));
}

test "subagent control capability is route restricted and rejects symlinks" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try openTestSession(alloc, &tmp);
    defer session.dir.close(io_mod.getIo());
    defer alloc.free(session.display_path);
    var capability = try SessionChildCapability.initSubagentControl(
        alloc,
        session.dir,
        session.display_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    try std.testing.expectError(
        error.SessionChildStoreFailed,
        capability.createExclusiveFile(alloc, .background_records, "wrong-route.json"),
    );
    var entry = try capability.atomicReplace(
        alloc,
        .subagent_control,
        "control.json",
        "{}",
    );
    entry.deinit(alloc);
    var lock = try capability.acquireTimedAdvisoryLock(
        .subagent_control,
        "subagent-control.lock",
        10,
    );
    lock.release();

    try session.dir.symLink(
        io_mod.getIo(),
        "../outside-control",
        "subagent/linked.json",
        .{},
    );
    try std.testing.expectError(
        error.SessionPathUnsafe,
        capability.openFileReadOnly(alloc, .subagent_control, "linked.json"),
    );
}

test "subagent control capability rejects a symlinked route" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try openTestSession(alloc, &tmp);
    defer session.dir.close(io_mod.getIo());
    defer alloc.free(session.display_path);
    try tmp.dir.createDir(
        io_mod.getIo(),
        "outside",
        std.Io.File.Permissions.fromMode(0o700),
    );
    try session.dir.symLink(
        io_mod.getIo(),
        "../outside",
        "subagent",
        .{ .is_directory = true },
    );
    var capability = try SessionChildCapability.initSubagentControl(
        alloc,
        session.dir,
        session.display_path,
        .writable,
        .{},
    );
    defer capability.deinit();
    try std.testing.expectError(
        error.SessionPathUnsafe,
        capability.iterate(alloc, .subagent_control),
    );
}

test "terminal capabilities are private route restricted and reject symlinks" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try openTestSession(alloc, &tmp);
    defer session.dir.close(io_mod.getIo());
    defer alloc.free(session.display_path);
    var state = try SessionChildCapability.initTerminalState(
        alloc,
        session.dir,
        session.display_path,
        .writable,
        .{},
    );
    defer state.deinit();
    var entry = try state.atomicReplace(
        alloc,
        .terminal_state,
        "record.json",
        "{}",
    );
    entry.deinit(alloc);
    try std.testing.expectError(
        error.SessionChildStoreFailed,
        state.atomicReplace(alloc, .terminal_proofs, "proof.bin", "proof"),
    );
    const terminal_stat = try session.dir.statFile(
        io_mod.getIo(),
        "terminal",
        .{ .follow_symlinks = false },
    );
    const state_stat = try session.dir.statFile(
        io_mod.getIo(),
        "terminal/state",
        .{ .follow_symlinks = false },
    );
    const record_stat = try session.dir.statFile(
        io_mod.getIo(),
        "terminal/state/record.json",
        .{ .follow_symlinks = false },
    );
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), terminal_stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), state_stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), record_stat.permissions.toMode() & 0o777);

    try session.dir.rename(
        "terminal",
        session.dir,
        "terminal-owned",
        io_mod.getIo(),
    );
    try tmp.dir.createDir(
        io_mod.getIo(),
        "outside-terminal",
        std.Io.File.Permissions.fromMode(0o700),
    );
    try session.dir.symLink(
        io_mod.getIo(),
        "../outside-terminal",
        "terminal",
        .{ .is_directory = true },
    );
    var fresh = try SessionChildCapability.initTerminalState(
        alloc,
        session.dir,
        session.display_path,
        .writable,
        .{},
    );
    defer fresh.deinit();
    try std.testing.expectError(
        error.SessionPathUnsafe,
        fresh.iterate(alloc, .terminal_state),
    );
}

const FailFirstParentSync = struct {
    calls: usize = 0,

    fn syncDir(raw: ?*anyopaque, _: std.Io.Dir) anyerror!void {
        const self: *FailFirstParentSync = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls == 1) return error.InjectedParentSyncFailure;
    }
};

test "a v2 capability keeps terminal kinds in the terminal folder, made only by a write (D45)" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io_mod.getIo(), "fx", private_dir_permissions);
    const fx_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "fx");
    defer alloc.free(fx_path);
    const terminal_path = try std.fs.path.join(alloc, &.{ fx_path, "terminal", "kYIGy8ik0H3K" });
    defer alloc.free(terminal_path);

    var memory = MemoryBlobsForTesting.init(alloc);
    defer memory.deinit();
    var capability = try SessionChildCapability.initBlobs(alloc, memory.blobs(), terminal_path, .writable);
    defer capability.deinit();

    // A read finds nothing and makes nothing.
    try std.testing.expectError(error.FileNotFound, capability.openFileReadOnly(alloc, .terminal_state, "record.json"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io_mod.getIo(), "fx/terminal", .{ .follow_symlinks = false }));

    var entry = try capability.atomicReplace(alloc, .terminal_state, "record.json", "{}");
    entry.deinit(alloc);
    for ([_][]const u8{ "fx/terminal", "fx/terminal/kYIGy8ik0H3K" }) |sub_path| {
        const stat = try tmp.dir.statFile(io_mod.getIo(), sub_path, .{ .follow_symlinks = false });
        try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
    }

    // A read-only clone reads it back; side-folder kinds stay absent.
    var reader = try capability.cloneReadOnly(alloc);
    defer reader.deinit();
    var file = try reader.openFileReadOnly(alloc, .terminal_state, "record.json");
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, 16);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("{}", bytes);
    try std.testing.expectError(error.SessionChildStoreFailed, capability.atomicReplace(alloc, .background_records, "record.json", "{}"));

    // A read-only capability never makes the folder.
    const other_path = try std.fs.path.join(alloc, &.{ fx_path, "terminal", "otherSession1" });
    defer alloc.free(other_path);
    var read_only = try SessionChildCapability.initBlobs(alloc, memory.blobs(), other_path, .read_only);
    defer read_only.deinit();
    try std.testing.expectError(error.FileNotFound, read_only.openFileReadOnly(alloc, .terminal_state, "record.json"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io_mod.getIo(), "fx/terminal/otherSession1", .{ .follow_symlinks = false }));
}

test "post rename parent sync failure is indeterminate and next write reopens" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try openTestSession(alloc, &tmp);
    defer session.dir.close(io_mod.getIo());
    defer alloc.free(session.display_path);
    var sync_state = FailFirstParentSync{};
    var capability = try SessionChildCapability.initForTesting(
        alloc,
        session.dir,
        session.display_path,
        .writable,
        .{
            .replace_ops = .{
                .ctx = &sync_state,
                .sync_dir = FailFirstParentSync.syncDir,
            },
        },
    );
    defer capability.deinit();

    try std.testing.expectError(
        error.SessionChildCommitIndeterminate,
        capability.atomicReplace(alloc, .tool_results, "1.json", "{\"id\":1}"),
    );
    try std.testing.expect(capability.hasIndeterminateEntry(.tool_results, "1.json"));

    var resolved = try capability.atomicReplace(
        alloc,
        .tool_results,
        "1.json",
        "{\"id\":1,\"resolved\":true}",
    );
    defer resolved.deinit(alloc);
    try std.testing.expect(!capability.hasIndeterminateEntry(.tool_results, "1.json"));

    var file = try capability.openFileReadOnly(alloc, .tool_results, "1.json");
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, 1024);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("{\"id\":1,\"resolved\":true}", bytes);
}

test "rename confirms the recorded target before publication" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session = try openTestSession(alloc, &tmp);
    defer session.dir.close(io_mod.getIo());
    defer alloc.free(session.display_path);
    var sync_state = FailFirstParentSync{};
    var capability = try SessionChildCapability.initForTesting(
        alloc,
        session.dir,
        session.display_path,
        .writable,
        .{
            .replace_ops = .{
                .ctx = &sync_state,
                .sync_dir = FailFirstParentSync.syncDir,
            },
        },
    );
    defer capability.deinit();

    var source = try capability.createExclusiveFile(
        alloc,
        .command_artifacts,
        "source.log",
    );
    try source.writeAll("saved output");
    try source.sync();
    source.deinit();
    try std.testing.expectError(
        error.SessionChildCommitIndeterminate,
        capability.rename(
            .command_artifacts,
            "source.log",
            "target.log",
        ),
    );
    try std.testing.expect(capability.hasIndeterminateEntry(
        .command_artifacts,
        "target.log",
    ));
    try std.testing.expectError(
        error.FileNotFound,
        capability.stat(.command_artifacts, "source.log"),
    );
    const target = try capability.stat(.command_artifacts, "target.log");
    try std.testing.expectEqual(@as(u64, 12), target.size);

    try std.testing.expect(try capability.confirmIndeterminateEntry(
        .command_artifacts,
        "target.log",
    ));
    try std.testing.expectEqual(@as(usize, 2), sync_state.calls);
    try std.testing.expect(!capability.hasIndeterminateEntry(
        .command_artifacts,
        "target.log",
    ));
    try capability.delete(.command_artifacts, "target.log");
}
