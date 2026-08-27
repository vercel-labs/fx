const std = @import("std");
const contracts = @import("contracts.zig");
const monitor_core = @import("monitor.zig");
const operation = @import("operation.zig");
const recovery = @import("recovery.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_layout = @import("../session/session_layout.zig");
const process_supervisor = @import("../background/process_supervisor.zig");
const background_process_provider = @import(
    "../execution/background_process_provider.zig",
);
const profile_paths = @import("../shared/profile_paths.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const per_session_payload_limit: u64 = 64 * 1024 * 1024;
pub const profile_payload_limit: u64 = 512 * 1024 * 1024;
const default_segment_bytes: u64 = 1024 * 1024;
const max_record_bytes: usize = 1024 * 1024;
const max_event_bytes: usize = 64 * 1024;
pub const monitor_set_bytes_limit: usize = max_record_bytes;
pub const monitor_runtime_headroom: usize = max_event_bytes;
pub const monitor_admission_bytes_limit: usize =
    monitor_set_bytes_limit - monitor_runtime_headroom;
pub const monitor_event_transaction_headroom: usize = max_event_bytes;
pub const monitor_transaction_bytes_limit: usize =
    monitor_set_bytes_limit + monitor_event_transaction_headroom;
const event_retention_limit: u64 = 256;
const record_schema_version: u16 = 1;
const authority_schema_version: u16 = 2;
const owner_catalog_authority_schema_version: u16 = 2;
const event_schema_version: u16 = 1;
const monitor_transaction_schema_version: u16 = 1;
const close_transaction_schema_version: u16 = 2;
const checkpoint_schema_version: u16 = 1;
const checkpoint_magic = "FXCP";
const checkpoint_header_bytes: usize = 4 + 2 + 2 + 8 + 8 + 4 + 32;

pub const FailurePoint = enum {
    grant,
    start,
    append,
    acknowledgement,
    cancellation,
    checkpoint_replacement,
    revoke,
    close,
    finalization,
    after_journal_create,
    after_proof_write,
    after_authority_write,
    after_close_authority_write,
    after_close_record_write,
    after_close_authority_event,
    after_close_monitor_transaction_prepare,
    after_close_monitor_event,
    after_close_monitor_state_write,
    after_close_monitor_record_write,
    after_close_monitor_cleanup,
    after_close_lifecycle_record,
    after_close_lifecycle_event,
    after_close_cleanup,
    before_close_recovery_oom,
    before_close_recovery_capability,
    after_monitor_write,
    after_monitor_state_write,
    after_monitor_record,
    after_monitor_event_record,
    after_monitor_transaction_prepare,
    after_monitor_transaction_commit,
    after_monitor_event_indeterminate,
    after_journal_sync,
    after_checkpoint_write,
    after_checkpoint_record,
    after_event_write,
    after_acknowledgement_record,
    after_eviction_record,
};

const MonitorReconciliationFailure = enum {
    allocation,
    io,
    indeterminate,
};

pub const MonitorReconciliationControl = struct {
    max_attempts: u8 = 3,
    retry_delay_ms: u16 = 5,
    cancelled: ?*const std.atomic.Value(bool) = null,
    observed_attempts: ?*std.atomic.Value(u8) = null,

    fn is_cancelled(self: MonitorReconciliationControl) bool {
        return if (self.cancelled) |value| value.load(.acquire) else false;
    }
};

const Options = struct {
    per_session_limit: u64 = per_session_payload_limit,
    profile_limit: u64 = profile_payload_limit,
    segment_bytes: u64 = default_segment_bytes,
    fail_at: ?FailurePoint = null,
    fail_monitor_reconciliation_once: ?MonitorReconciliationFailure = null,
    fail_monitor_reconciliation_count: u8 = 1,

    fn validate(self: Options) error{InvalidStoreOptions}!void {
        if (self.per_session_limit == 0 or self.profile_limit == 0 or
            self.segment_bytes == 0 or self.per_session_limit > self.profile_limit or
            self.fail_monitor_reconciliation_count == 0)
        {
            return error.InvalidStoreOptions;
        }
    }
};

pub const PersistedTermination = union(enum) {
    exited: i32,
    signal: u32,

    fn validate(self: PersistedTermination) error{InvalidTerminalRecord}!void {
        const outcome: contracts.ReturnOutcome = switch (self) {
            .exited => |code| .{ .exited = code },
            .signal => |signal| .{ .signal = signal },
        };
        outcome.validate() catch return error.InvalidTerminalRecord;
    }
};

pub const DurableEvent = struct {
    id: u64,
    kind: contracts.HostEvent,
    lifecycle: contracts.Lifecycle,
    cursor: contracts.RawCursor,
    created_at_ms: i64,
    monitor_sequence: ?u64 = null,
    monitor_reason: ?monitor_core.EventReason = null,

    pub fn validate(self: DurableEvent) error{InvalidDurableEvent}!void {
        if (self.id == 0) return error.InvalidDurableEvent;
        self.cursor.validate() catch return error.InvalidDurableEvent;
        if ((self.monitor_sequence == null) != (self.monitor_reason == null) or
            if (self.monitor_sequence) |sequence| sequence == 0 else false)
        {
            return error.InvalidDurableEvent;
        }
    }
};

pub const JournalFile = struct {
    file_id: u64,
    range: contracts.RawRange,
    payload_bytes: u64,
    checksum: contracts.CheckpointChecksum,

    fn validate(self: JournalFile) error{InvalidTerminalRecord}!void {
        if (self.file_id == 0) return error.InvalidTerminalRecord;
        self.range.validate() catch return error.InvalidTerminalRecord;
        if (self.range.start.segment != self.range.end.segment or
            self.range.end.offset - self.range.start.offset != self.payload_bytes)
        {
            return error.InvalidTerminalRecord;
        }
    }
};

const EventWire = struct {
    schema_version: u16 = event_schema_version,
    event: DurableEvent,
};

const MonitorTransaction = struct {
    schema_version: u16 = monitor_transaction_schema_version,
    committed: bool = false,
    updated_at_ms: i64,
    candidate: monitor_core.PersistedSet,
    event: ?DurableEvent = null,

    fn validate(self: MonitorTransaction) !void {
        if (self.schema_version != monitor_transaction_schema_version) {
            return error.InvalidMonitorTransaction;
        }
        if (self.updated_at_ms < 0) return error.InvalidMonitorTransaction;
        try validate_monitor_set(self.candidate);
        if (self.event) |event| {
            try event.validate();
            if (event.monitor_sequence == null or event.kind != .monitor) {
                return error.InvalidMonitorTransaction;
            }
        }
    }
};

const CloseTransaction = struct {
    schema_version: u16 = close_transaction_schema_version,
    updated_at_ms: i64,
    initiator_verifier: ?contracts.CheckpointChecksum,
    authority_generation: contracts.AuthorityGeneration,
    authority_event: DurableEvent,
    lifecycle_event: ?DurableEvent = null,

    fn validate(self: CloseTransaction) !void {
        if (self.schema_version != close_transaction_schema_version or
            self.updated_at_ms < 0)
        {
            return error.InvalidCloseTransaction;
        }
        self.authority_generation.validate() catch
            return error.InvalidCloseTransaction;
        self.authority_event.validate() catch
            return error.InvalidCloseTransaction;
        if (self.authority_event.kind != .authority_revoked or
            self.authority_event.monitor_sequence != null)
        {
            return error.InvalidCloseTransaction;
        }
        if (self.lifecycle_event) |event| {
            event.validate() catch return error.InvalidCloseTransaction;
            if (event.kind != .lifecycle or event.lifecycle != .closed or
                event.monitor_sequence != null or
                event.id <= self.authority_event.id)
            {
                return error.InvalidCloseTransaction;
            }
        }
    }
};

const MonitorCommitContext = enum {
    ordinary,
    close,
};

const CloseRecoveryErrorClass = enum {
    isolate,
    propagate,
};

fn classify_close_recovery_error(err: anyerror) CloseRecoveryErrorClass {
    return switch (err) {
        error.InvalidCloseTransaction, error.StreamTooLong => .isolate,
        else => .propagate,
    };
}

pub const Record = struct {
    session_id: []u8,
    owner_session_id: []u8,
    host_identity: []u8,
    backend_identity: []u8,
    shell: []u8,
    cwd: []u8,
    command: ?[]u8,
    backend: contracts.Backend,
    lifecycle: contracts.Lifecycle,
    attention: contracts.AttentionState,
    dimensions: contracts.Dimensions,
    pid: ?[]u8,
    process_token: ?[]u8,
    takeover_owner_pid: ?[]u8,
    takeover_owner_process_token: ?[]u8,
    output_cursor: contracts.RawCursor,
    available_from: contracts.RawCursor,
    raw_gap: ?contracts.RawGap,
    raw_replay_exact: bool,
    screen_recovery: contracts.ScreenRecovery,
    checkpoint_payload_bytes: u64,
    journal_payload_bytes: u64,
    journal_files: []JournalFile,
    journal_cleanup_through: u64,
    checkpoint_generation: u64,
    checkpoint_cleanup_generation: ?u64,
    next_event_id: u64,
    acknowledged_event_id: u64,
    event_gap_through: u64,
    event_cleanup_through: u64,
    monitor_count: u16,
    authority_generation: contracts.AuthorityGeneration,
    authority_revoked: bool,
    direct_human_model_read_only: bool,
    termination: ?PersistedTermination,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn deinit(self: *Record, alloc: Allocator) void {
        alloc.free(self.journal_files);
        if (self.takeover_owner_process_token) |value| alloc.free(value);
        if (self.takeover_owner_pid) |value| alloc.free(value);
        if (self.process_token) |value| alloc.free(value);
        if (self.pid) |value| alloc.free(value);
        if (self.command) |value| alloc.free(value);
        alloc.free(self.cwd);
        alloc.free(self.shell);
        alloc.free(self.backend_identity);
        alloc.free(self.host_identity);
        alloc.free(self.owner_session_id);
        alloc.free(self.session_id);
        self.* = undefined;
    }

    pub fn validate(self: Record) error{InvalidTerminalRecord}!void {
        contracts.validate_session_id(self.session_id) catch
            return error.InvalidTerminalRecord;
        contracts.validate_session_id(self.owner_session_id) catch
            return error.InvalidTerminalRecord;
        if (self.host_identity.len == 0 or self.backend_identity.len == 0 or
            self.shell.len == 0 or self.cwd.len == 0 or
            !std.fs.path.isAbsolute(self.cwd))
        {
            return error.InvalidTerminalRecord;
        }
        self.attention.validate() catch return error.InvalidTerminalRecord;
        self.dimensions.validate() catch return error.InvalidTerminalRecord;
        self.output_cursor.validate() catch return error.InvalidTerminalRecord;
        self.available_from.validate() catch return error.InvalidTerminalRecord;
        if (contracts.compare_raw_cursors(
            self.available_from,
            self.output_cursor,
        ) == .gt) return error.InvalidTerminalRecord;
        if (self.raw_gap) |gap| {
            gap.validate() catch return error.InvalidTerminalRecord;
            const is_prefix_gap = contracts.compare_raw_cursors(
                gap.available_from,
                self.available_from,
            ) == .eq;
            if ((!is_prefix_gap and contracts.compare_raw_cursors(
                gap.missing_from,
                self.available_from,
            ) == .lt) or
                contracts.compare_raw_cursors(
                    gap.available_from,
                    self.output_cursor,
                ) == .gt)
            {
                return error.InvalidTerminalRecord;
            }
        }
        switch (self.screen_recovery) {
            .available => |checkpoint| {
                if (self.checkpoint_generation == 0 or
                    self.checkpoint_payload_bytes == 0)
                {
                    return error.InvalidTerminalRecord;
                }
                checkpoint.validate_header() catch
                    return error.InvalidTerminalRecord;
                if (@as(u64, checkpoint.payload_len) !=
                    self.checkpoint_payload_bytes)
                {
                    return error.InvalidTerminalRecord;
                }
                if (contracts.compare_raw_cursors(
                    checkpoint.applied_cursor,
                    self.output_cursor,
                ) == .gt) return error.InvalidTerminalRecord;
            },
            .unavailable => {
                if (self.checkpoint_generation != 0 or
                    self.checkpoint_payload_bytes != 0)
                {
                    return error.InvalidTerminalRecord;
                }
            },
        }
        self.authority_generation.validate() catch
            return error.InvalidTerminalRecord;
        if (self.next_event_id == 0 or
            self.acknowledged_event_id >= self.next_event_id or
            self.event_gap_through >= self.next_event_id or
            self.event_cleanup_through >= self.next_event_id or
            self.event_cleanup_through > @max(
                self.acknowledged_event_id,
                self.event_gap_through,
            ))
        {
            return error.InvalidTerminalRecord;
        }
        var journal_bytes: u64 = 0;
        var internal_gap_seen = false;
        for (self.journal_files, 0..) |file, index| {
            try file.validate();
            journal_bytes = std.math.add(
                u64,
                journal_bytes,
                file.payload_bytes,
            ) catch return error.InvalidTerminalRecord;
            if (index == 0) {
                if (contracts.compare_raw_cursors(
                    file.range.start,
                    self.available_from,
                ) != .eq) return error.InvalidTerminalRecord;
            } else {
                const previous = self.journal_files[index - 1];
                if (file.file_id <= previous.file_id) {
                    return error.InvalidTerminalRecord;
                }
                if (contracts.compare_raw_cursors(
                    previous.range.end,
                    file.range.start,
                ) != .eq) {
                    const gap = self.raw_gap orelse
                        return error.InvalidTerminalRecord;
                    if (internal_gap_seen or
                        contracts.compare_raw_cursors(
                            previous.range.end,
                            gap.missing_from,
                        ) != .eq or
                        contracts.compare_raw_cursors(
                            file.range.start,
                            gap.available_from,
                        ) != .eq)
                    {
                        return error.InvalidTerminalRecord;
                    }
                    internal_gap_seen = true;
                }
            }
        }
        if (self.raw_gap) |gap| {
            const prefix_gap = contracts.compare_raw_cursors(
                gap.available_from,
                self.available_from,
            ) == .eq;
            if (!prefix_gap and !internal_gap_seen) {
                return error.InvalidTerminalRecord;
            }
        }
        if (journal_bytes != self.journal_payload_bytes) {
            return error.InvalidTerminalRecord;
        }
        if (self.journal_files.len == 0) {
            if (self.journal_payload_bytes != 0 or
                contracts.compare_raw_cursors(
                    self.available_from,
                    self.output_cursor,
                ) != .eq)
            {
                return error.InvalidTerminalRecord;
            }
        } else if (contracts.compare_raw_cursors(
            self.journal_files[self.journal_files.len - 1].range.end,
            self.output_cursor,
        ) != .eq) {
            return error.InvalidTerminalRecord;
        }
        if (self.termination) |termination| try termination.validate();
        if (self.process_token) |token| {
            _ = process_supervisor.ProcessInstanceToken.parse(token) catch
                return error.InvalidTerminalRecord;
        }
        if ((self.takeover_owner_pid == null) !=
            (self.takeover_owner_process_token == null))
        {
            return error.InvalidTerminalRecord;
        }
        const human_takeover = self.attention.attention == .user_takeover and
            self.attention.write_lease == .human;
        if (human_takeover != (self.takeover_owner_pid != null)) {
            return error.InvalidTerminalRecord;
        }
        if (self.takeover_owner_pid) |pid| {
            _ = std.fmt.parseInt(std.posix.pid_t, pid, 10) catch
                return error.InvalidTerminalRecord;
            _ = process_supervisor.ProcessInstanceToken.parse(
                self.takeover_owner_process_token.?,
            ) catch return error.InvalidTerminalRecord;
        }
        const payload_total = std.math.add(
            u64,
            self.checkpoint_payload_bytes,
            self.journal_payload_bytes,
        ) catch return error.InvalidTerminalRecord;
        if (payload_total > per_session_payload_limit) {
            return error.InvalidTerminalRecord;
        }
    }
};

const RecordWire = struct {
    schema_version: u16 = record_schema_version,
    session_id: []const u8,
    owner_session_id: []const u8,
    host_identity: []const u8,
    backend_identity: []const u8,
    shell: []const u8,
    cwd: []const u8,
    command: ?[]const u8,
    backend: contracts.Backend,
    lifecycle: contracts.Lifecycle,
    attention: contracts.AttentionState,
    dimensions: contracts.Dimensions,
    pid: ?[]const u8,
    process_token: ?[]const u8,
    takeover_owner_pid: ?[]const u8 = null,
    takeover_owner_process_token: ?[]const u8 = null,
    output_cursor: contracts.RawCursor,
    available_from: contracts.RawCursor,
    raw_gap: ?contracts.RawGap,
    raw_replay_exact: bool = false,
    screen_recovery: contracts.ScreenRecovery,
    checkpoint_payload_bytes: u64,
    journal_payload_bytes: u64,
    journal_files: []const JournalFile,
    journal_cleanup_through: u64,
    checkpoint_generation: u64,
    checkpoint_cleanup_generation: ?u64,
    next_event_id: u64,
    acknowledged_event_id: u64,
    event_gap_through: u64,
    event_cleanup_through: u64,
    monitor_count: u16,
    authority_generation: contracts.AuthorityGeneration,
    authority_revoked: bool,
    direct_human_model_read_only: bool,
    termination: ?PersistedTermination,
    created_at_ms: i64,
    updated_at_ms: i64,
};

const AuthorityWire = struct {
    schema_version: u16 = authority_schema_version,
    session_id: []const u8,
    grant: contracts.AuthorityGrant,
    direct_human_model_read_only: bool,
    verifier: contracts.CheckpointChecksum,
    revoked: bool,
};

const OwnerCatalogAuthorityWire = struct {
    schema_version: u16 = owner_catalog_authority_schema_version,
    principal: contracts.OwnerCatalogPrincipal,
    actor: contracts.ActorRole,
    verifier: contracts.CheckpointChecksum,
};

pub const ProfileStore = struct {
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
    sessions_dir: io_mod.VerifiedDir,
    display_sessions_path: []u8,
    options: Options,
    mutex: std.Io.Mutex = .init,
    residents: std.ArrayList(*DurableSession) = .empty,
    monitor_reconciliation_failure_count: u8 = 0,

    pub fn init(
        alloc: Allocator,
        home: []const u8,
        process_provider: background_process_provider.Provider,
    ) !ProfileStore {
        return init_with_options(alloc, home, process_provider, .{});
    }

    fn init_with_options(
        alloc: Allocator,
        home: []const u8,
        process_provider: background_process_provider.Provider,
        options: Options,
    ) !ProfileStore {
        try options.validate();
        var home_dir = io_mod.VerifiedDir{
            .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{
                .iterate = true,
                .follow_symlinks = false,
            }),
        };
        defer home_dir.close();
        var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(
            &home_dir,
            profile_paths.root_dir_name,
        );
        defer fx_dir.close();
        var sessions_dir = try io_mod.openOrCreateVerifiedPrivateDir(
            &fx_dir,
            profile_paths.sessions_dir_name,
        );
        errdefer sessions_dir.close();
        return .{
            .alloc = alloc,
            .process_provider = process_provider,
            .sessions_dir = sessions_dir,
            .display_sessions_path = try profile_paths.sessionsDir(alloc, home),
            .options = options,
        };
    }

    pub fn deinit(self: *ProfileStore) void {
        std.debug.assert(self.residents.items.len == 0);
        self.residents.deinit(self.alloc);
        self.alloc.free(self.display_sessions_path);
        self.sessions_dir.close();
        self.* = undefined;
    }

    pub fn register_resident(
        self: *ProfileStore,
        session: *DurableSession,
    ) Allocator.Error!void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        try self.register_resident_locked(session);
    }

    fn register_resident_locked(
        self: *ProfileStore,
        session: *DurableSession,
    ) Allocator.Error!void {
        for (self.residents.items) |resident| {
            if (resident == session) return;
            std.debug.assert(!std.mem.eql(
                u8,
                resident.record.session_id,
                session.record.session_id,
            ));
        }
        try self.residents.append(self.alloc, session);
        session.registered = true;
    }

    pub fn unregister_resident(
        self: *ProfileStore,
        session: *DurableSession,
    ) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        for (self.residents.items, 0..) |resident, index| {
            if (resident != session) continue;
            _ = self.residents.swapRemove(index);
            session.registered = false;
            return;
        }
    }

    fn resident_by_id(
        self: *ProfileStore,
        session_id: []const u8,
    ) ?*DurableSession {
        for (self.residents.items) |resident| {
            if (std.mem.eql(u8, resident.record.session_id, session_id)) {
                return resident;
            }
        }
        return null;
    }

    fn open_capability(
        self: *ProfileStore,
        owner_session_id: []const u8,
        comptime proof_route: bool,
    ) !session_child_store.SessionChildCapability {
        try session_layout.validateSessionId(owner_session_id);
        var owner_dir = self.sessions_dir.dir.openDir(
            io_mod.getIo(),
            owner_session_id,
            .{ .iterate = true, .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.NotDir, error.SymLinkLoop => return error.SessionPathUnsafe,
            else => return err,
        };
        defer owner_dir.close(io_mod.getIo());
        const display_path = try session_layout.sessionDirPath(
            self.alloc,
            self.display_sessions_path,
            owner_session_id,
        );
        defer self.alloc.free(display_path);
        return if (proof_route)
            session_child_store.SessionChildCapability.initTerminalProofs(
                self.alloc,
                owner_dir,
                display_path,
                .writable,
                .{},
            )
        else
            session_child_store.SessionChildCapability.initTerminalState(
                self.alloc,
                owner_dir,
                display_path,
                .writable,
                .{},
            );
    }

    fn open_existing(
        self: *ProfileStore,
        owner_session_id: []const u8,
        terminal_session_id: []const u8,
    ) !DurableSession {
        var state = try self.open_capability(owner_session_id, false);
        errdefer state.deinit();
        var record = try load_record(self.alloc, &state, terminal_session_id);
        errdefer record.deinit(self.alloc);
        if (!std.mem.eql(u8, record.owner_session_id, owner_session_id)) {
            return error.InvalidTerminalRecord;
        }
        return .{
            .profile = self,
            .state = state,
            .record = record,
            .journal = null,
        };
    }

    pub fn open_terminal(
        self: *ProfileStore,
        terminal_session_id: []const u8,
    ) !*DurableSession {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        try contracts.validate_session_id(terminal_session_id);
        if (self.resident_by_id(terminal_session_id) != null) {
            return error.TerminalSessionResident;
        }
        var result: ?DurableSession = null;
        errdefer if (result) |*session| session.deinit();
        var iter = self.sessions_dir.dir.iterate();
        while (try iter.next(zio)) |entry| {
            session_layout.validateSessionId(entry.name) catch continue;
            if (entry.kind != .directory) continue;
            var capability = self.open_capability(entry.name, false) catch continue;
            defer capability.deinit();
            const name = try record_name(self.alloc, terminal_session_id);
            defer self.alloc.free(name);
            _ = capability.stat(.terminal_state, name) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            if (result != null) return error.DuplicateTerminalSession;
            result = try self.open_existing(entry.name, terminal_session_id);
        }
        const session = result orelse return error.TerminalSessionNotFound;
        const resident = try self.alloc.create(DurableSession);
        errdefer self.alloc.destroy(resident);
        resident.* = session;
        result = null;
        errdefer resident.deinit();
        try self.register_resident_locked(resident);
        return resident;
    }

    pub fn release_terminal(
        self: *ProfileStore,
        session: *DurableSession,
    ) void {
        session.deinit();
        self.alloc.destroy(session);
    }

    pub fn ownerCatalog(
        self: *ProfileStore,
        claim: contracts.OwnerCatalogAuthorityClaim,
    ) !CatalogList {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        try verify_owner_catalog_claim(self.alloc, self, claim);

        var result = CatalogList{ .alloc = self.alloc };
        errdefer result.deinit();
        var capability = try self.open_capability(
            claim.principal.durable_session_id,
            false,
        );
        defer capability.deinit();
        var names = capability.iterate(self.alloc, .terminal_state) catch |err| switch (err) {
            error.FileNotFound => return result,
            else => return err,
        };
        defer names.deinit();
        for (names.names) |name| {
            const terminal_id = terminal_id_from_record_name(name) orelse continue;
            var record = load_record(self.alloc, &capability, terminal_id) catch continue;
            defer record.deinit(self.alloc);
            if (!std.mem.eql(
                u8,
                record.owner_session_id,
                claim.principal.durable_session_id,
            )) continue;
            const authority = load_authority(
                self.alloc,
                &capability,
                terminal_id,
            ) catch continue;
            defer authority.deinit();
            if (!owner_catalog_scope_matches(
                claim.principal,
                authority.value.grant.principal,
            )) continue;
            _ = try reconcile_takeover_owner_record(
                self.alloc,
                self.process_provider,
                &capability,
                &record,
                io_mod.milliTimestamp(),
            );
            const session_id = try self.alloc.dupe(u8, record.session_id);
            errdefer self.alloc.free(session_id);
            const cwd = try self.alloc.dupe(u8, record.cwd);
            errdefer self.alloc.free(cwd);
            const workspace_root = try self.alloc.dupe(
                u8,
                authority.value.grant.principal.workspace_root,
            );
            errdefer self.alloc.free(workspace_root);
            try result.entries.append(self.alloc, .{
                .facts = facts_from_record(record, session_id),
                .cwd = cwd,
                .workspace_root = workspace_root,
                .authorization = catalog_authorization(
                    &record,
                    &authority.value,
                    claim.actor,
                ),
            });
        }
        return result;
    }

    fn ensure_profile_capacity(
        self: *ProfileStore,
        additional: u64,
        active_session_id: []const u8,
    ) !void {
        try self.retry_pending_cleanups();
        while (true) {
            var candidates = try self.scan_payload_candidates();
            defer candidates.deinit(self.alloc);
            const required = std.math.add(u64, candidates.total_bytes, additional) catch
                return error.CapacityExceeded;
            if (required <= self.options.profile_limit) return;
            const selected = choose_eviction(
                candidates.items.items,
                active_session_id,
            ) orelse
                return error.CapacityExceeded;
            const candidate = candidates.items.items[selected.index];
            if (self.resident_by_id(candidate.session_id)) |resident| {
                switch (selected.class) {
                    .completed_output => try resident.evict_completed_output(),
                    .completed_checkpoint => try resident.evict_completed_checkpoint(),
                    .live_covered_journal => try resident.evict_live_covered_journals(),
                }
            } else {
                var session = try self.open_existing(
                    candidate.owner_session_id,
                    candidate.session_id,
                );
                defer session.deinit();
                switch (selected.class) {
                    .completed_output => try session.evict_completed_output(),
                    .completed_checkpoint => try session.evict_completed_checkpoint(),
                    .live_covered_journal => try session.evict_live_covered_journals(),
                }
            }
        }
    }

    fn retry_pending_cleanups(self: *ProfileStore) !void {
        var iter = self.sessions_dir.dir.iterate();
        while (try iter.next(io_mod.getIo())) |entry| {
            session_layout.validateSessionId(entry.name) catch continue;
            if (entry.kind != .directory) continue;
            var capability = self.open_capability(entry.name, false) catch continue;
            defer capability.deinit();
            var names = capability.iterate(self.alloc, .terminal_state) catch continue;
            defer names.deinit();
            for (names.names) |name| {
                const terminal_id = terminal_id_from_record_name(name) orelse continue;
                var detached: ?DurableSession = null;
                const session = self.resident_by_id(terminal_id) orelse blk: {
                    detached = self.open_existing(entry.name, terminal_id) catch continue;
                    break :blk &detached.?;
                };
                defer if (detached) |*value| value.deinit();
                try session.retry_journal_cleanup();
                try session.retry_checkpoint_cleanup();
                try session.retry_event_cleanup_locked();
            }
        }
    }

    fn scan_payload_candidates(self: *ProfileStore) !CandidateList {
        var list = CandidateList{};
        errdefer list.deinit(self.alloc);
        var iter = self.sessions_dir.dir.iterate();
        while (try iter.next(io_mod.getIo())) |entry| {
            session_layout.validateSessionId(entry.name) catch continue;
            if (entry.kind != .directory) continue;
            var capability = self.open_capability(entry.name, false) catch continue;
            defer capability.deinit();
            var names = capability.iterate(self.alloc, .terminal_state) catch continue;
            defer names.deinit();
            for (names.names) |name| {
                if (!is_payload_artifact_name(name)) continue;
                const stat = capability.stat(.terminal_state, name) catch continue;
                const payload_bytes = if (std.mem.startsWith(
                    u8,
                    name,
                    "checkpoint-",
                ) and stat.size >= checkpoint_header_bytes)
                    stat.size - checkpoint_header_bytes
                else
                    stat.size;
                list.total_bytes = std.math.add(
                    u64,
                    list.total_bytes,
                    payload_bytes,
                ) catch return error.CapacityExceeded;
            }
            for (names.names) |name| {
                const terminal_id = terminal_id_from_record_name(name) orelse continue;
                var record = load_record(
                    self.alloc,
                    &capability,
                    terminal_id,
                ) catch continue;
                defer record.deinit(self.alloc);
                if (is_live(record.lifecycle)) {
                    const reserve = try checkpoint_reserve_bytes(record.dimensions);
                    list.total_bytes = std.math.add(
                        u64,
                        list.total_bytes,
                        reserve -| record.checkpoint_payload_bytes,
                    ) catch return error.CapacityExceeded;
                }
                const owner_session_id = try self.alloc.dupe(
                    u8,
                    record.owner_session_id,
                );
                errdefer self.alloc.free(owner_session_id);
                const session_id = try self.alloc.dupe(u8, record.session_id);
                errdefer self.alloc.free(session_id);
                try list.items.append(self.alloc, .{
                    .owner_session_id = owner_session_id,
                    .session_id = session_id,
                    .lifecycle = record.lifecycle,
                    .created_at_ms = record.created_at_ms,
                    .journal_bytes = record.journal_payload_bytes,
                    .checkpoint_bytes = record.checkpoint_payload_bytes,
                    .covered_live_bytes = try covered_live_bytes(
                        self.alloc,
                        &capability,
                        record,
                    ),
                });
            }
        }
        return list;
    }

    pub fn recover(
        self: *ProfileStore,
        host_identity: []const u8,
        now_ms: i64,
    ) !RecoveredList {
        var recovered = RecoveredList{ .profile = self };
        errdefer recovered.deinit();
        var iter = self.sessions_dir.dir.iterate();
        while (try iter.next(io_mod.getIo())) |entry| {
            session_layout.validateSessionId(entry.name) catch continue;
            if (entry.kind != .directory) continue;
            var capability = self.open_capability(entry.name, false) catch continue;
            defer capability.deinit();
            var names = capability.iterate(self.alloc, .terminal_state) catch continue;
            defer names.deinit();
            var terminal_ids: std.ArrayList([]u8) = .empty;
            defer {
                for (terminal_ids.items) |terminal_id| self.alloc.free(terminal_id);
                terminal_ids.deinit(self.alloc);
            }
            try collect_artifact_ids(self.alloc, &terminal_ids, names.names);
            var proof_capability = self.open_capability(entry.name, true) catch null;
            defer if (proof_capability) |*proofs| proofs.deinit();
            if (proof_capability) |*proofs| {
                var proof_names = proofs.iterate(
                    self.alloc,
                    .terminal_proofs,
                ) catch null;
                defer if (proof_names) |*items| items.deinit();
                if (proof_names) |items| {
                    try collect_artifact_ids(
                        self.alloc,
                        &terminal_ids,
                        items.names,
                    );
                }
            }
            for (terminal_ids.items) |terminal_id| {
                var session = self.open_existing(entry.name, terminal_id) catch |err| {
                    if (err == error.TerminalRecordNotFound) {
                        cleanup_session_artifacts(
                            self.alloc,
                            &capability,
                            if (proof_capability) |*proofs| proofs else null,
                            terminal_id,
                        );
                    }
                    try recovered.append_diagnostic(
                        self.alloc,
                        entry.name,
                        terminal_id,
                        if (err == error.TerminalRecordNotFound)
                            "PartialStartArtifacts"
                        else
                            @errorName(err),
                    );
                    continue;
                };
                var keep = false;
                defer if (!keep) session.deinit();
                const repaired_close = session.reconcile_close_transaction(now_ms) catch |err| switch (classify_close_recovery_error(err)) {
                    .isolate => blk: {
                        try session.isolate_invalid_close_transaction(now_ms);
                        try recovered.append_diagnostic(
                            self.alloc,
                            entry.name,
                            terminal_id,
                            "InvalidCloseTransaction",
                        );
                        break :blk false;
                    },
                    .propagate => return err,
                };
                if (repaired_close) {
                    try recovered.append_diagnostic(
                        self.alloc,
                        entry.name,
                        terminal_id,
                        "CloseTransactionReconciled",
                    );
                }
                const removed_orphans = session.reconcile_unreferenced_artifacts() catch |err| blk: {
                    try recovered.append_diagnostic(
                        self.alloc,
                        entry.name,
                        terminal_id,
                        @errorName(err),
                    );
                    break :blk false;
                };
                if (removed_orphans) {
                    try recovered.append_diagnostic(
                        self.alloc,
                        entry.name,
                        terminal_id,
                        "UnreferencedArtifacts",
                    );
                }
                var authority_recoverable = true;
                const repaired_authority = session.reconcile_authority() catch |err| blk: {
                    if (!is_definitive_recovery_authority_error(err)) return err;
                    try recovered.append_diagnostic(
                        self.alloc,
                        entry.name,
                        terminal_id,
                        @errorName(err),
                    );
                    authority_recoverable = false;
                    break :blk false;
                };
                if (repaired_authority) {
                    try recovered.append_diagnostic(
                        self.alloc,
                        entry.name,
                        terminal_id,
                        "AuthorityRecordReconciled",
                    );
                }
                const repaired_journal = session.reconcile_journals() catch |err| blk: {
                    try recovered.append_diagnostic(
                        self.alloc,
                        entry.name,
                        terminal_id,
                        @errorName(err),
                    );
                    break :blk false;
                };
                if (repaired_journal) {
                    try recovered.append_diagnostic(
                        self.alloc,
                        entry.name,
                        terminal_id,
                        "CorruptJournalChain",
                    );
                }
                session.reconcile_checkpoint() catch |err| {
                    try recovered.append_diagnostic(
                        self.alloc,
                        entry.name,
                        terminal_id,
                        @errorName(err),
                    );
                };
                const repaired_monitors = session.reconcile_monitor_transaction() catch |err| blk: {
                    try recovered.append_diagnostic(
                        self.alloc,
                        entry.name,
                        terminal_id,
                        @errorName(err),
                    );
                    break :blk false;
                };
                if (repaired_monitors) {
                    try recovered.append_diagnostic(
                        self.alloc,
                        entry.name,
                        terminal_id,
                        "MonitorTransactionReconciled",
                    );
                }
                const repaired_events = session.reconcile_events() catch |err| blk: {
                    try recovered.append_diagnostic(
                        self.alloc,
                        entry.name,
                        terminal_id,
                        @errorName(err),
                    );
                    break :blk false;
                };
                if (repaired_events) {
                    try recovered.append_diagnostic(
                        self.alloc,
                        entry.name,
                        terminal_id,
                        "CorruptEventChain",
                    );
                }
                var monitors: ?MonitorDefinitions = session.load_monitor_definitions(
                    self.alloc,
                ) catch |err| blk: {
                    try recovered.append_diagnostic(
                        self.alloc,
                        entry.name,
                        terminal_id,
                        @errorName(err),
                    );
                    break :blk null;
                };
                if (monitors) |*definitions| definitions.deinit();
                if (session.record.backend == .tmux and
                    (session.record.lifecycle == .starting or
                        session.record.lifecycle == .running))
                {
                    var execution_scope: ?RecoveredExecutionScope = if (authority_recoverable)
                        session.load_recovery_execution_scope(self.alloc) catch |err| blk: {
                            if (!is_definitive_recovery_authority_error(err)) return err;
                            try recovered.append_diagnostic(
                                self.alloc,
                                entry.name,
                                terminal_id,
                                @errorName(err),
                            );
                            authority_recoverable = false;
                            break :blk null;
                        }
                    else
                        null;
                    if (execution_scope) |*scope| scope.deinit(self.alloc);
                    if (!authority_recoverable) {
                        try session.persist_lost(now_ms);
                    }
                    try recovered.sessions.append(self.alloc, session);
                    keep = true;
                    continue;
                }
                const process_evidence = process_evidence_for(
                    self.alloc,
                    self.process_provider,
                    session.record,
                );
                const decision = recovery.reconcile(.{
                    .record = .valid,
                    .lifecycle = session.record.lifecycle,
                    .termination_present = session.record.termination != null,
                    .host = if (std.mem.eql(
                        u8,
                        session.record.host_identity,
                        host_identity,
                    )) .present_same else .present_foreign,
                    .process = process_evidence,
                    .checkpoint = checkpoint_evidence_for(session.record),
                });
                switch (decision.disposition) {
                    .retain_live, .unavailable => {
                        // A newly constructed registry has no PTY descriptor to
                        // attach even when stale identity text happens to match.
                        try session.persist_lost(now_ms);
                    },
                    .mark_lost => try session.persist_lost(now_ms),
                    .finalize_exited => {
                        if (session.record.lifecycle == .starting or
                            session.record.lifecycle == .running)
                        {
                            session.record.lifecycle = .exited;
                            session.record.updated_at_ms = now_ms;
                            try save_record(
                                self.alloc,
                                try session.state_capability(),
                                session.record,
                            );
                        }
                    },
                    .retain_final => {},
                    .isolate_corrupt => unreachable,
                }
                session.release_completed_handles();
                try recovered.sessions.append(self.alloc, session);
                keep = true;
            }
        }
        return recovered;
    }
};

pub const CatalogEntry = struct {
    facts: contracts.SessionFacts,
    cwd: []u8,
    workspace_root: []u8,
    authorization: Authorization,

    fn deinit(self: *CatalogEntry, alloc: Allocator) void {
        alloc.free(self.workspace_root);
        alloc.free(self.cwd);
        alloc.free(self.facts.session_id);
        self.* = undefined;
    }
};

pub const CatalogList = struct {
    alloc: Allocator,
    entries: std.ArrayList(CatalogEntry) = .empty,

    pub fn deinit(self: *CatalogList) void {
        for (self.entries.items) |*entry| entry.deinit(self.alloc);
        self.entries.deinit(self.alloc);
        self.* = undefined;
    }
};

pub const RecoveryDiagnostic = struct {
    owner_session_id: []u8,
    terminal_session_id: []u8,
    reason: []u8,

    fn deinit(self: *RecoveryDiagnostic, alloc: Allocator) void {
        alloc.free(self.reason);
        alloc.free(self.terminal_session_id);
        alloc.free(self.owner_session_id);
        self.* = undefined;
    }
};

pub const RecoveredList = struct {
    profile: ?*ProfileStore = null,
    sessions: std.ArrayList(DurableSession) = .empty,
    diagnostics: std.ArrayList(RecoveryDiagnostic) = .empty,

    pub fn deinit(self: *RecoveredList) void {
        const profile = self.profile orelse {
            std.debug.assert(self.sessions.items.len == 0);
            std.debug.assert(self.diagnostics.items.len == 0);
            return;
        };
        for (self.sessions.items) |*session| session.deinit();
        self.sessions.deinit(profile.alloc);
        for (self.diagnostics.items) |*diagnostic| {
            diagnostic.deinit(profile.alloc);
        }
        self.diagnostics.deinit(profile.alloc);
        self.* = undefined;
    }

    fn append_diagnostic(
        self: *RecoveredList,
        alloc: Allocator,
        owner_session_id: []const u8,
        terminal_session_id: []const u8,
        reason: []const u8,
    ) !void {
        const owner = try alloc.dupe(u8, owner_session_id);
        errdefer alloc.free(owner);
        const terminal = try alloc.dupe(u8, terminal_session_id);
        errdefer alloc.free(terminal);
        try self.diagnostics.append(alloc, .{
            .owner_session_id = owner,
            .terminal_session_id = terminal,
            .reason = try alloc.dupe(u8, reason),
        });
    }
};

fn process_evidence_for(
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
    record: Record,
) recovery.ProcessEvidence {
    const pid = record.pid orelse return .missing;
    const token_text = record.process_token orelse return .missing;
    const token = process_supervisor.ProcessInstanceToken.parse(token_text) catch
        return .mismatched;
    return switch (process_provider.matchToken(
        alloc,
        pid,
        token,
    )) {
        .matched => .matched,
        .missing => .missing,
        .mismatched => .mismatched,
        .unavailable => .unavailable,
    };
}

fn optional_text_eql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn takeover_owner_matches(
    record: Record,
    owner: *const contracts.ProcessOwner,
) bool {
    const pid = record.takeover_owner_pid orelse return false;
    const process_token = record.takeover_owner_process_token orelse return false;
    var pid_buffer: [32]u8 = undefined;
    const owner_pid = std.fmt.bufPrint(&pid_buffer, "{d}", .{owner.pid}) catch
        return false;
    return std.mem.eql(u8, pid, owner_pid) and
        std.mem.eql(u8, process_token, owner.token());
}

fn takeover_owner_evidence(
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
    record: Record,
) process_supervisor.TokenMatch {
    const pid = record.takeover_owner_pid orelse return .mismatched;
    const token_text = record.takeover_owner_process_token orelse
        return .mismatched;
    const token = process_supervisor.ProcessInstanceToken.parse(token_text) catch
        return .mismatched;
    return process_provider.matchToken(
        alloc,
        pid,
        token,
    );
}

fn reconcile_takeover_owner_record(
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
    capability: *session_child_store.SessionChildCapability,
    record: *Record,
    now_ms: i64,
) !bool {
    if (record.attention.write_lease != .human) return false;
    switch (takeover_owner_evidence(alloc, process_provider, record.*)) {
        .matched, .unavailable => return false,
        .missing, .mismatched => {},
    }

    const previous_attention = record.attention;
    const previous_owner_pid = record.takeover_owner_pid;
    const previous_owner_process_token = record.takeover_owner_process_token;
    const previous_updated_at_ms = record.updated_at_ms;
    record.attention = .{};
    record.takeover_owner_pid = null;
    record.takeover_owner_process_token = null;
    record.updated_at_ms = now_ms;
    save_record(alloc, capability, record.*) catch |err| {
        record.attention = previous_attention;
        record.takeover_owner_pid = previous_owner_pid;
        record.takeover_owner_process_token = previous_owner_process_token;
        record.updated_at_ms = previous_updated_at_ms;
        return err;
    };
    alloc.free(previous_owner_process_token.?);
    alloc.free(previous_owner_pid.?);
    debug_trace.logf(
        "terminal_store",
        "orphan takeover owner reconciled id={s}",
        .{record.session_id},
    );
    return true;
}

fn checkpoint_evidence_for(record: Record) recovery.CheckpointEvidence {
    return switch (record.screen_recovery) {
        .available => .valid_contiguous,
        .unavailable => |reason| switch (reason) {
            .missing => .missing,
            .corrupt => .corrupt,
            .unsupported_schema => .unsupported,
            .retention_evicted => .retention_evicted,
            .raw_gap => .disconnected,
            .resize_uncheckpointed => .resize_uncheckpointed,
        },
    };
}

const PayloadCandidate = struct {
    owner_session_id: []u8,
    session_id: []u8,
    lifecycle: contracts.Lifecycle,
    created_at_ms: i64,
    journal_bytes: u64,
    checkpoint_bytes: u64,
    covered_live_bytes: u64,
};

const CandidateList = struct {
    items: std.ArrayList(PayloadCandidate) = .empty,
    total_bytes: u64 = 0,

    fn deinit(self: *CandidateList, alloc: Allocator) void {
        for (self.items.items) |candidate| {
            alloc.free(candidate.session_id);
            alloc.free(candidate.owner_session_id);
        }
        self.items.deinit(alloc);
        self.* = undefined;
    }
};

pub const EvictionClass = enum {
    completed_output,
    completed_checkpoint,
    live_covered_journal,
};

pub const EvictionSelection = struct {
    index: usize,
    class: EvictionClass,
};

fn choose_eviction(
    items: []const PayloadCandidate,
    active_session_id: []const u8,
) ?EvictionSelection {
    const classes = [_]EvictionClass{
        .completed_output,
        .completed_checkpoint,
        .live_covered_journal,
    };
    for (classes) |class| {
        var selected: ?usize = null;
        for (items, 0..) |item, index| {
            if (std.mem.eql(u8, item.session_id, active_session_id)) continue;
            const eligible = switch (class) {
                .completed_output => is_completed(item.lifecycle) and
                    item.journal_bytes != 0,
                .completed_checkpoint => is_completed(item.lifecycle) and
                    item.checkpoint_bytes != 0,
                .live_covered_journal => is_live(item.lifecycle) and
                    item.covered_live_bytes != 0,
            };
            if (!eligible) continue;
            if (selected == null or
                item.created_at_ms < items[selected.?].created_at_ms)
            {
                selected = index;
            }
        }
        if (selected) |index| return .{ .index = index, .class = class };
    }
    return null;
}

fn is_completed(lifecycle: contracts.Lifecycle) bool {
    return lifecycle == .exited or lifecycle == .lost or lifecycle == .closed;
}

fn is_live(lifecycle: contracts.Lifecycle) bool {
    return lifecycle == .starting or lifecycle == .running;
}

fn terminal_id_from_record_name(name: []const u8) ?[]const u8 {
    const prefix = "record-";
    const suffix = ".json";
    if (!std.mem.startsWith(u8, name, prefix) or
        !std.mem.endsWith(u8, name, suffix) or
        name.len <= prefix.len + suffix.len)
    {
        return null;
    }
    const id = name[prefix.len .. name.len - suffix.len];
    contracts.validate_session_id(id) catch return null;
    return id;
}

fn terminal_id_from_artifact_name(name: []const u8) ?[]const u8 {
    const fixed = [_]struct { prefix: []const u8, suffix: []const u8 }{
        .{ .prefix = "record-", .suffix = ".json" },
        .{ .prefix = "authority-", .suffix = ".json" },
        .{ .prefix = "monitors-", .suffix = ".json" },
        .{ .prefix = "monitor-transaction-", .suffix = ".json" },
        .{ .prefix = "close-transaction-", .suffix = ".json" },
        .{ .prefix = "proof-", .suffix = ".bin" },
    };
    for (fixed) |shape| {
        if (!std.mem.startsWith(u8, name, shape.prefix) or
            !std.mem.endsWith(u8, name, shape.suffix) or
            name.len <= shape.prefix.len + shape.suffix.len)
        {
            continue;
        }
        const id = name[shape.prefix.len .. name.len - shape.suffix.len];
        contracts.validate_session_id(id) catch continue;
        return id;
    }
    const indexed = [_]struct { prefix: []const u8, suffix: []const u8 }{
        .{ .prefix = "checkpoint-", .suffix = ".bin" },
        .{ .prefix = "journal-", .suffix = ".bin" },
        .{ .prefix = "event-", .suffix = ".json" },
    };
    for (indexed) |shape| {
        if (!std.mem.startsWith(u8, name, shape.prefix) or
            !std.mem.endsWith(u8, name, shape.suffix) or
            name.len <= shape.prefix.len + shape.suffix.len + 2)
        {
            continue;
        }
        const body = name[shape.prefix.len .. name.len - shape.suffix.len];
        const separator = std.mem.lastIndexOfScalar(u8, body, '-') orelse continue;
        if (separator == 0 or separator + 1 == body.len) continue;
        _ = std.fmt.parseInt(u64, body[separator + 1 ..], 10) catch continue;
        const id = body[0..separator];
        contracts.validate_session_id(id) catch continue;
        return id;
    }
    return null;
}

fn is_payload_artifact_name(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".bin")) return false;
    return std.mem.startsWith(u8, name, "journal-") or
        std.mem.startsWith(u8, name, "checkpoint-");
}

fn collect_artifact_ids(
    alloc: Allocator,
    ids: *std.ArrayList([]u8),
    names: []const []u8,
) !void {
    for (names) |name| {
        const id = terminal_id_from_artifact_name(name) orelse continue;
        var duplicate = false;
        for (ids.items) |existing| {
            if (std.mem.eql(u8, existing, id)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) {
            const owned = try alloc.dupe(u8, id);
            errdefer alloc.free(owned);
            try ids.append(alloc, owned);
        }
    }
}

fn cleanup_session_artifacts(
    alloc: Allocator,
    state: *session_child_store.SessionChildCapability,
    proofs: ?*session_child_store.SessionChildCapability,
    session_id: []const u8,
) void {
    cleanup_session_artifacts_in(
        alloc,
        state,
        .terminal_state,
        session_id,
    );
    if (proofs) |capability| {
        cleanup_session_artifacts_in(
            alloc,
            capability,
            .terminal_proofs,
            session_id,
        );
    }
}

fn cleanup_session_artifacts_in(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    kind: session_child_store.ManagedChildKind,
    session_id: []const u8,
) void {
    var names = capability.iterate(alloc, kind) catch return;
    defer names.deinit();
    for (names.names) |name| {
        const id = terminal_id_from_artifact_name(name) orelse continue;
        if (!std.mem.eql(u8, id, session_id)) continue;
        capability.delete(kind, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => debug_trace.logf(
                "terminal_store",
                "partial artifact cleanup failed file={s} err={s}",
                .{ name, @errorName(err) },
            ),
        };
    }
}

fn indexed_artifact_id(
    name: []const u8,
    kind: []const u8,
    session_id: []const u8,
    suffix: []const u8,
) ?u64 {
    if (!std.mem.startsWith(u8, name, kind) or
        name.len <= kind.len + session_id.len + suffix.len + 2 or
        name[kind.len] != '-' or
        !std.mem.eql(
            u8,
            name[kind.len + 1 .. kind.len + 1 + session_id.len],
            session_id,
        ) or
        name[kind.len + 1 + session_id.len] != '-' or
        !std.mem.endsWith(u8, name, suffix))
    {
        return null;
    }
    const digits = name[kind.len + 2 + session_id.len .. name.len - suffix.len];
    if (digits.len == 0) return null;
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

fn covered_live_bytes(
    _: Allocator,
    _: *session_child_store.SessionChildCapability,
    record: Record,
) !u64 {
    const checkpoint = switch (record.screen_recovery) {
        .unavailable => return 0,
        .available => |value| value,
    };
    if (!is_live(record.lifecycle)) return 0;
    var total: u64 = 0;
    for (record.journal_files) |file| {
        if (contracts.compare_raw_cursors(
            file.range.end,
            checkpoint.applied_cursor,
        ) == .gt) break;
        total = std.math.add(u64, total, file.payload_bytes) catch
            return error.CapacityExceeded;
    }
    return total;
}

fn record_wire(record: Record) RecordWire {
    return .{
        .session_id = record.session_id,
        .owner_session_id = record.owner_session_id,
        .host_identity = record.host_identity,
        .backend_identity = record.backend_identity,
        .shell = record.shell,
        .cwd = record.cwd,
        .command = record.command,
        .backend = record.backend,
        .lifecycle = record.lifecycle,
        .attention = record.attention,
        .dimensions = record.dimensions,
        .pid = record.pid,
        .process_token = record.process_token,
        .takeover_owner_pid = record.takeover_owner_pid,
        .takeover_owner_process_token = record.takeover_owner_process_token,
        .output_cursor = record.output_cursor,
        .available_from = record.available_from,
        .raw_gap = record.raw_gap,
        .raw_replay_exact = record.raw_replay_exact,
        .screen_recovery = record.screen_recovery,
        .checkpoint_payload_bytes = record.checkpoint_payload_bytes,
        .journal_payload_bytes = record.journal_payload_bytes,
        .journal_files = record.journal_files,
        .journal_cleanup_through = record.journal_cleanup_through,
        .checkpoint_generation = record.checkpoint_generation,
        .checkpoint_cleanup_generation = record.checkpoint_cleanup_generation,
        .next_event_id = record.next_event_id,
        .acknowledged_event_id = record.acknowledged_event_id,
        .event_gap_through = record.event_gap_through,
        .event_cleanup_through = record.event_cleanup_through,
        .monitor_count = record.monitor_count,
        .authority_generation = record.authority_generation,
        .authority_revoked = record.authority_revoked,
        .direct_human_model_read_only = record.direct_human_model_read_only,
        .termination = record.termination,
        .created_at_ms = record.created_at_ms,
        .updated_at_ms = record.updated_at_ms,
    };
}

fn render_json(alloc: Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    std.json.Stringify.value(value, .{}, &out.writer) catch
        return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn clone_record(alloc: Allocator, wire: RecordWire) Allocator.Error!Record {
    const session_id = try alloc.dupe(u8, wire.session_id);
    errdefer alloc.free(session_id);
    const owner_session_id = try alloc.dupe(u8, wire.owner_session_id);
    errdefer alloc.free(owner_session_id);
    const host_identity = try alloc.dupe(u8, wire.host_identity);
    errdefer alloc.free(host_identity);
    const backend_identity = try alloc.dupe(u8, wire.backend_identity);
    errdefer alloc.free(backend_identity);
    const shell = try alloc.dupe(u8, wire.shell);
    errdefer alloc.free(shell);
    const cwd = try alloc.dupe(u8, wire.cwd);
    errdefer alloc.free(cwd);
    const command = if (wire.command) |value| try alloc.dupe(u8, value) else null;
    errdefer if (command) |value| alloc.free(value);
    const pid = if (wire.pid) |value| try alloc.dupe(u8, value) else null;
    errdefer if (pid) |value| alloc.free(value);
    const takeover_owner_pid = if (wire.takeover_owner_pid) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (takeover_owner_pid) |value| alloc.free(value);
    const takeover_owner_process_token = if (wire.takeover_owner_process_token) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (takeover_owner_process_token) |value| alloc.free(value);
    const journal_files = try alloc.dupe(JournalFile, wire.journal_files);
    errdefer alloc.free(journal_files);
    return .{
        .session_id = session_id,
        .owner_session_id = owner_session_id,
        .host_identity = host_identity,
        .backend_identity = backend_identity,
        .shell = shell,
        .cwd = cwd,
        .command = command,
        .backend = wire.backend,
        .lifecycle = wire.lifecycle,
        .attention = wire.attention,
        .dimensions = wire.dimensions,
        .pid = pid,
        .process_token = if (wire.process_token) |value|
            try alloc.dupe(u8, value)
        else
            null,
        .takeover_owner_pid = takeover_owner_pid,
        .takeover_owner_process_token = takeover_owner_process_token,
        .output_cursor = wire.output_cursor,
        .available_from = wire.available_from,
        .raw_gap = wire.raw_gap,
        .raw_replay_exact = wire.raw_replay_exact,
        .screen_recovery = wire.screen_recovery,
        .checkpoint_payload_bytes = wire.checkpoint_payload_bytes,
        .journal_payload_bytes = wire.journal_payload_bytes,
        .journal_files = journal_files,
        .journal_cleanup_through = wire.journal_cleanup_through,
        .checkpoint_generation = wire.checkpoint_generation,
        .checkpoint_cleanup_generation = wire.checkpoint_cleanup_generation,
        .next_event_id = wire.next_event_id,
        .acknowledged_event_id = wire.acknowledged_event_id,
        .event_gap_through = wire.event_gap_through,
        .event_cleanup_through = wire.event_cleanup_through,
        .monitor_count = wire.monitor_count,
        .authority_generation = wire.authority_generation,
        .authority_revoked = wire.authority_revoked,
        .direct_human_model_read_only = wire.direct_human_model_read_only,
        .termination = wire.termination,
        .created_at_ms = wire.created_at_ms,
        .updated_at_ms = wire.updated_at_ms,
    };
}

fn parse_record(alloc: Allocator, bytes: []const u8) !Record {
    var parsed = std.json.parseFromSlice(
        RecordWire,
        alloc,
        bytes,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidTerminalRecord,
    };
    defer parsed.deinit();
    if (parsed.value.schema_version != record_schema_version) {
        return error.UnsupportedTerminalSchema;
    }
    var record = try clone_record(alloc, parsed.value);
    errdefer record.deinit(alloc);
    try record.validate();
    return record;
}

fn make_name(
    alloc: Allocator,
    prefix: []const u8,
    session_id: []const u8,
    suffix: []const u8,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{s}-{s}{s}", .{
        prefix,
        session_id,
        suffix,
    });
}

fn record_name(alloc: Allocator, session_id: []const u8) Allocator.Error![]u8 {
    return make_name(alloc, "record", session_id, ".json");
}

fn authority_name(alloc: Allocator, session_id: []const u8) Allocator.Error![]u8 {
    return make_name(alloc, "authority", session_id, ".json");
}

fn proof_name(alloc: Allocator, session_id: []const u8) Allocator.Error![]u8 {
    return make_name(alloc, "proof", session_id, ".bin");
}

fn checkpoint_name(
    alloc: Allocator,
    session_id: []const u8,
    generation: u64,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "checkpoint-{s}-{d}.bin",
        .{ session_id, generation },
    );
}

fn monitors_name(alloc: Allocator, session_id: []const u8) Allocator.Error![]u8 {
    return make_name(alloc, "monitors", session_id, ".json");
}

fn monitor_transaction_name(
    alloc: Allocator,
    session_id: []const u8,
) Allocator.Error![]u8 {
    return make_name(alloc, "monitor-transaction", session_id, ".json");
}

fn close_transaction_name(
    alloc: Allocator,
    session_id: []const u8,
) Allocator.Error![]u8 {
    return make_name(alloc, "close-transaction", session_id, ".json");
}

fn journal_name(
    alloc: Allocator,
    session_id: []const u8,
    segment: u64,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "journal-{s}-{d}.bin",
        .{ session_id, segment },
    );
}

fn find_journal_file(
    files: []const JournalFile,
    cursor: contracts.RawCursor,
) ?usize {
    for (files, 0..) |file, index| {
        if (cursor.segment != file.range.start.segment) continue;
        if (cursor.offset < file.range.start.offset) return null;
        if (cursor.offset < file.range.end.offset) return index;
        if (cursor.offset == file.range.end.offset and
            index + 1 < files.len and
            contracts.compare_raw_cursors(
                files[index + 1].range.start,
                cursor,
            ) == .eq)
        {
            return index + 1;
        }
    }
    return null;
}

fn event_name(
    alloc: Allocator,
    session_id: []const u8,
    event_id: u64,
) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "event-{s}-{d}.json",
        .{ session_id, event_id },
    );
}

fn load_event(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
    event_id: u64,
) !DurableEvent {
    const name = try event_name(alloc, session_id, event_id);
    defer alloc.free(name);
    var file = capability.openFileReadOnly(
        alloc,
        .terminal_state,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.MissingDurableEvent,
        else => return err,
    };
    defer file.deinit();
    const bytes = file.readToEnd(alloc, max_event_bytes) catch |err| switch (err) {
        error.StreamTooLong => return error.DurableEventTooLarge,
        else => return err,
    };
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(
        EventWire,
        alloc,
        bytes,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidDurableEvent,
    };
    defer parsed.deinit();
    if (parsed.value.schema_version != event_schema_version or
        parsed.value.event.id != event_id)
    {
        return error.InvalidDurableEvent;
    }
    try parsed.value.event.validate();
    return parsed.value.event;
}

fn proof_verifier(
    proof: contracts.HolderProof,
    grant: contracts.AuthorityGrant,
    direct_human_model_read_only: bool,
) contracts.CheckpointChecksum {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.terminal.holder-proof.v2\x00");
    hash.update(&proof.bytes);
    hash_u64(&hash, grant.generation.value);
    hash.update(@tagName(grant.actor));
    hash.update(@tagName(grant.principal.transport_role));
    hash.update(@tagName(grant.principal.backend));
    hash.update(@tagName(grant.principal.lifetime));
    hash.update(if (direct_human_model_read_only) "\x01" else "\x00");
    hash_text(&hash, grant.principal.profile_user);
    hash_text(&hash, grant.principal.durable_session_id);
    hash_text(&hash, grant.principal.workspace_root);
    hash_text(&hash, grant.principal.cwd);
    hash_allowed_controls(&hash, grant.controls);
    hash_u64(&hash, grant.repeated_probes.len);
    for (grant.repeated_probes) |probe| {
        hash_text(&hash, probe.command);
        hash_text(&hash, probe.cwd);
        hash_u64(&hash, probe.check_schedule.interval_ms);
        hash_monitor_notify(&hash, probe.notify_schedule);
        hash_monitor_lifetime(&hash, probe.lifetime);
    }
    var digest: contracts.CheckpointChecksum = undefined;
    hash.final(&digest);
    return digest;
}

fn close_initiator_verifier(
    claim: contracts.AuthorityClaim,
) contracts.CheckpointChecksum {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.terminal.close-initiator.v2\x00");
    hash.update(&claim.proof.bytes);
    hash_u64(&hash, claim.generation.value);
    hash_text(&hash, @tagName(claim.actor));
    hash_text(&hash, @tagName(claim.principal.transport_role));
    hash_text(&hash, @tagName(claim.principal.backend));
    hash_text(&hash, @tagName(claim.principal.lifetime));
    hash_text(&hash, claim.principal.profile_user);
    hash_text(&hash, claim.principal.durable_session_id);
    hash_text(&hash, claim.principal.workspace_root);
    hash_text(&hash, claim.principal.cwd);
    if (claim.process_owner) |owner| {
        hash.update("\x01");
        hash_u64(&hash, @intCast(owner.pid));
        hash_text(&hash, owner.token());
    } else {
        hash.update("\x00");
    }
    var digest: contracts.CheckpointChecksum = undefined;
    hash.final(&digest);
    return digest;
}

fn owner_catalog_key(
    principal: contracts.OwnerCatalogPrincipal,
    actor: contracts.ActorRole,
) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.terminal.owner-catalog-key.v2\x00");
    hash.update(@tagName(actor));
    hash.update(@tagName(principal.transport_role));
    hash_text(&hash, principal.profile_user);
    hash_text(&hash, principal.durable_session_id);
    hash_text(&hash, principal.workspace_root);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn owner_catalog_verifier(
    claim: contracts.OwnerCatalogAuthorityClaim,
) contracts.CheckpointChecksum {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.terminal.owner-catalog-proof.v2\x00");
    hash.update(&claim.proof.bytes);
    hash.update(@tagName(claim.actor));
    hash.update(@tagName(claim.principal.transport_role));
    hash_text(&hash, claim.principal.profile_user);
    hash_text(&hash, claim.principal.durable_session_id);
    hash_text(&hash, claim.principal.workspace_root);
    var digest: contracts.CheckpointChecksum = undefined;
    hash.final(&digest);
    return digest;
}

fn verify_owner_catalog_authority(
    authority: OwnerCatalogAuthorityWire,
    claim: contracts.OwnerCatalogAuthorityClaim,
) !void {
    try claim.validate();
    if (!authority.principal.eql(claim.principal) or
        authority.actor != claim.actor)
    {
        return error.PrincipalMismatch;
    }
    const verifier = owner_catalog_verifier(claim);
    if (!std.mem.eql(u8, &verifier, &authority.verifier)) {
        return error.InvalidHolderProof;
    }
}

fn verify_owner_catalog_claim(
    alloc: Allocator,
    profile: *ProfileStore,
    claim: contracts.OwnerCatalogAuthorityClaim,
) !void {
    try claim.validate();
    var capability = try profile.open_capability(
        claim.principal.durable_session_id,
        false,
    );
    defer capability.deinit();
    const key = owner_catalog_key(claim.principal, claim.actor);
    var name_buffer: [96]u8 = undefined;
    const name = try std.fmt.bufPrint(
        &name_buffer,
        "catalog-authority-{s}.json",
        .{&key},
    );
    var authority = try load_owner_catalog_authority(alloc, &capability, name);
    defer authority.deinit();
    try verify_owner_catalog_authority(authority.value, claim);
}

fn owner_catalog_scope_matches(
    owner: contracts.OwnerCatalogPrincipal,
    terminal: contracts.Principal,
) bool {
    return std.mem.eql(u8, owner.profile_user, terminal.profile_user) and
        std.mem.eql(u8, owner.durable_session_id, terminal.durable_session_id) and
        std.mem.eql(u8, owner.workspace_root, terminal.workspace_root) and
        owner.transport_role == terminal.transport_role;
}

fn catalog_authorization(
    record: *const Record,
    authority: *const AuthorityWire,
    actor: contracts.ActorRole,
) Authorization {
    if (record.authority_revoked or authority.revoked) {
        return .{ .actor = actor, .controls = .{} };
    }
    const observer_policy = verified_observer_policy(record, authority) catch
        return .{ .actor = actor, .controls = .{} };
    const direct_model_observer = observer_policy and
        authority.grant.actor == .human and actor == .agent;
    if (!direct_model_observer and authority.grant.actor != actor) {
        return .{ .actor = actor, .controls = .{} };
    }
    return .{
        .actor = actor,
        .controls = if (direct_model_observer)
            contracts.AllowedControls.observer()
        else
            authority.grant.controls,
    };
}

fn hash_monitor_notify(
    hash: *std.crypto.hash.sha2.Sha256,
    schedule: contracts.NotifySchedule,
) void {
    hash.update(@tagName(schedule));
    switch (schedule) {
        .every_n_checks => |count| hash_u64(hash, count),
        .interval => |value| hash_u64(hash, value.interval_ms),
        else => {},
    }
}

fn hash_monitor_lifetime(
    hash: *std.crypto.hash.sha2.Sha256,
    lifetime: contracts.MonitorLifetime,
) void {
    hash.update(@tagName(lifetime));
    if (lifetime == .duration_ms) hash_u64(hash, lifetime.duration_ms);
}

fn hash_text(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hash_u64(hash, value.len);
    hash.update(value);
}

fn hash_allowed_controls(
    hash: *std.crypto.hash.sha2.Sha256,
    controls: contracts.AllowedControls,
) void {
    const bits: u10 = @bitCast(controls);
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, bits, .little);
    hash.update(&bytes);
}

fn hash_u64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

pub const CreateInput = struct {
    session_id: []const u8,
    host_identity: []const u8,
    shell: []const u8,
    cwd: []const u8,
    command: ?[]const u8,
    backend: contracts.Backend,
    dimensions: contracts.Dimensions,
    persistence: contracts.StartPersistence,
    initial_monitors: []const contracts.MonitorDefinition,
    now_ms: i64,
};

pub const ReadPage = struct {
    output: []u8,
    range: ?contracts.RawRange,
    gap: ?contracts.RawGap,

    pub fn deinit(self: *ReadPage, alloc: Allocator) void {
        alloc.free(self.output);
        self.* = undefined;
    }
};

pub const MonitorDefinitions = struct {
    alloc: Allocator,
    parsed: std.json.Parsed(monitor_core.PersistedSet),
    definitions: []contracts.MonitorDefinition,

    pub fn view(self: *const MonitorDefinitions) []const contracts.MonitorDefinition {
        return self.definitions;
    }

    pub fn deinit(self: *MonitorDefinitions) void {
        self.alloc.free(self.definitions);
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub const MonitorSet = struct {
    parsed: std.json.Parsed(monitor_core.PersistedSet),

    pub fn clone(
        alloc: Allocator,
        set: monitor_core.PersistedSet,
    ) !MonitorSet {
        try validate_monitor_set(set);
        const bytes = try render_json(alloc, set);
        defer alloc.free(bytes);
        var parsed = std.json.parseFromSlice(
            monitor_core.PersistedSet,
            alloc,
            bytes,
            .{ .allocate = .alloc_always },
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidMonitorRecord,
        };
        errdefer parsed.deinit();
        try validate_monitor_set(parsed.value);
        return .{ .parsed = parsed };
    }

    pub fn view(self: *MonitorSet) *monitor_core.PersistedSet {
        return &self.parsed.value;
    }

    pub fn deinit(self: *MonitorSet) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub const MonitorCommitOutcome = enum {
    previous,
    candidate,
};

pub const MonitorTransitionOutcome = union(enum) {
    previous: anyerror,
    candidate,
    cancelled,
    indeterminate: anyerror,
};

pub const CloseCommitOutcome = union(enum) {
    previous: anyerror,
    candidate: ?anyerror,
    indeterminate: anyerror,
};

pub const MonitorNotification = struct {
    sequence: u64,
    reason: monitor_core.EventReason,
};

pub const EventReplay = struct {
    events: []DurableEvent,
    gap_through: u64,
    next_event_id: u64,

    pub fn deinit(self: *EventReplay, alloc: Allocator) void {
        alloc.free(self.events);
        self.* = undefined;
    }
};

pub const Authorization = struct {
    actor: contracts.ActorRole,
    controls: contracts.AllowedControls,
};

pub const AuthorityReload = struct {
    terminal_session_id: []const u8,
    principal: contracts.Principal,
    actor: contracts.ActorRole,
    generation: contracts.AuthorityGeneration,
};

pub const OwnerAuthorityReload = struct {
    terminal_session_id: []const u8,
    profile_user: []const u8,
    durable_session_id: []const u8,
    workspace_root: []const u8,
    transport_role: contracts.TransportRole,
    actor: contracts.ActorRole,
};

pub const OwnerCatalogAuthorityReload = struct {
    profile_user: []const u8,
    durable_session_id: []const u8,
    workspace_root: []const u8,
    transport_role: contracts.TransportRole,
    actor: contracts.ActorRole,
};

pub fn loadOrCreateOwnerCatalogClaim(
    alloc: Allocator,
    owner: *session_child_store.SessionChildCapability,
    input: OwnerCatalogAuthorityReload,
) !operation.OwnedOwnerCatalogClaim {
    const principal = contracts.OwnerCatalogPrincipal{
        .profile_user = input.profile_user,
        .durable_session_id = input.durable_session_id,
        .workspace_root = input.workspace_root,
        .transport_role = input.transport_role,
    };
    try principal.validate();
    const key = owner_catalog_key(principal, input.actor);
    var authority_name_buffer: [96]u8 = undefined;
    const catalog_authority_name = try std.fmt.bufPrint(
        &authority_name_buffer,
        "catalog-authority-{s}.json",
        .{&key},
    );
    var proof_name_buffer: [96]u8 = undefined;
    const catalog_proof_name = try std.fmt.bufPrint(
        &proof_name_buffer,
        "catalog-proof-{s}",
        .{&key},
    );
    var lock_name_buffer: [96]u8 = undefined;
    const lock_name = try std.fmt.bufPrint(
        &lock_name_buffer,
        "catalog-{s}.lock",
        .{&key},
    );
    var authority_lock = try owner.acquireTimedAdvisoryLock(
        .terminal_state,
        lock_name,
        2_000,
    );
    defer authority_lock.release();

    if (load_owner_catalog_authority(alloc, owner, catalog_authority_name)) |parsed_value| {
        var parsed = parsed_value;
        defer parsed.deinit();
        var proof = try read_owner_catalog_proof(alloc, owner, catalog_proof_name);
        defer std.crypto.secureZero(u8, @volatileCast(proof.bytes[0..]));
        const claim = contracts.OwnerCatalogAuthorityClaim{
            .principal = principal,
            .actor = input.actor,
            .proof = proof,
        };
        try verify_owner_catalog_authority(parsed.value, claim);
        return operation.ownOwnerCatalogClaim(alloc, claim);
    } else |err| switch (err) {
        error.OwnerCatalogAuthorityNotFound => {},
        else => return err,
    }

    var proof = contracts.OwnerCatalogProof{ .bytes = undefined };
    defer std.crypto.secureZero(u8, @volatileCast(proof.bytes[0..]));
    while (true) {
        try std.Io.randomSecure(io_mod.getIo(), &proof.bytes);
        proof.validate() catch continue;
        break;
    }
    const claim = contracts.OwnerCatalogAuthorityClaim{
        .principal = principal,
        .actor = input.actor,
        .proof = proof,
    };
    try write_owner_catalog_proof(alloc, owner, catalog_proof_name, proof);
    try write_owner_catalog_authority(
        alloc,
        owner,
        catalog_authority_name,
        claim,
    );
    return operation.ownOwnerCatalogClaim(alloc, claim);
}

/// Reloads authority for the current fx owner without trusting caller-supplied
/// cwd, backend, or generation. Those facts are recovered from durable state;
/// the active profile/session/workspace/transport identity must still match.
pub fn reloadOwnerAuthorityClaim(
    alloc: Allocator,
    owner: *session_child_store.SessionChildCapability,
    input: OwnerAuthorityReload,
) !operation.OwnedAuthorityClaim {
    try contracts.validate_session_id(input.terminal_session_id);
    try contracts.validate_session_id(input.durable_session_id);
    var record = try load_record(alloc, owner, input.terminal_session_id);
    defer record.deinit(alloc);
    if (!std.mem.eql(u8, record.owner_session_id, input.durable_session_id)) {
        return error.PrincipalMismatch;
    }
    const authority = try load_authority(alloc, owner, input.terminal_session_id);
    defer authority.deinit();
    const principal = authority.value.grant.principal;
    if (!std.mem.eql(u8, principal.profile_user, input.profile_user) or
        !std.mem.eql(u8, principal.durable_session_id, input.durable_session_id) or
        !std.mem.eql(u8, principal.workspace_root, input.workspace_root) or
        principal.transport_role != input.transport_role or
        !std.mem.eql(u8, principal.cwd, record.cwd) or
        principal.backend != record.backend or
        principal.lifetime != .session)
    {
        return error.PrincipalMismatch;
    }
    return reloadAuthorityClaim(alloc, owner, .{
        .terminal_session_id = input.terminal_session_id,
        .principal = principal,
        .actor = input.actor,
        .generation = record.authority_generation,
    });
}

/// Mints the session-shaped claim used only for an interactive human
/// takeover. The proof remains an owner-catalog proof; the host recognizes
/// and verifies that proof separately from the terminal's agent grant.
pub fn reloadHumanTakeoverAuthorityClaim(
    alloc: Allocator,
    owner: *session_child_store.SessionChildCapability,
    input: OwnerAuthorityReload,
) !operation.OwnedAuthorityClaim {
    try contracts.validate_session_id(input.terminal_session_id);
    try contracts.validate_session_id(input.durable_session_id);
    if (input.actor != .human) return error.ActorRoleMismatch;

    var record = try load_record(alloc, owner, input.terminal_session_id);
    defer record.deinit(alloc);
    if (!std.mem.eql(u8, record.owner_session_id, input.durable_session_id)) {
        return error.PrincipalMismatch;
    }
    const authority = try load_authority(alloc, owner, input.terminal_session_id);
    defer authority.deinit();
    const principal = authority.value.grant.principal;
    if (!std.mem.eql(u8, principal.profile_user, input.profile_user) or
        !std.mem.eql(u8, principal.durable_session_id, input.durable_session_id) or
        !std.mem.eql(u8, principal.workspace_root, input.workspace_root) or
        principal.transport_role != input.transport_role or
        !std.mem.eql(u8, principal.cwd, record.cwd) or
        principal.backend != record.backend or
        principal.lifetime != .session or
        authority.value.revoked or record.authority_revoked)
    {
        return error.PrincipalMismatch;
    }
    if (authority.value.grant.actor == .human) {
        return reloadAuthorityClaim(alloc, owner, .{
            .terminal_session_id = input.terminal_session_id,
            .principal = principal,
            .actor = .human,
            .generation = record.authority_generation,
        });
    }

    var catalog = try loadOrCreateOwnerCatalogClaim(alloc, owner, .{
        .profile_user = input.profile_user,
        .durable_session_id = input.durable_session_id,
        .workspace_root = input.workspace_root,
        .transport_role = input.transport_role,
        .actor = .human,
    });
    defer catalog.deinit();
    return operation.ownAuthorityClaim(alloc, .{
        .principal = principal,
        .actor = .human,
        .generation = record.authority_generation,
        .proof = .{ .bytes = catalog.view().proof.bytes },
    }, .humanTakeover());
}

/// Reloads a proof only through the managed-child capability of the durable fx
/// session that owns it. A terminal id alone cannot select proof storage.
pub fn reloadAuthorityClaim(
    alloc: Allocator,
    owner: *session_child_store.SessionChildCapability,
    input: AuthorityReload,
) !operation.OwnedAuthorityClaim {
    try contracts.validate_session_id(input.terminal_session_id);
    try input.principal.validate();
    try input.generation.validate();

    var record = try load_record(alloc, owner, input.terminal_session_id);
    defer record.deinit(alloc);
    if (!std.mem.eql(
        u8,
        record.owner_session_id,
        input.principal.durable_session_id,
    ) or !std.mem.eql(u8, record.cwd, input.principal.cwd) or
        record.backend != input.principal.backend)
    {
        return error.PrincipalMismatch;
    }
    const authority = try load_authority(
        alloc,
        owner,
        input.terminal_session_id,
    );
    defer authority.deinit();
    const observer_policy = try verified_observer_policy(
        &record,
        &authority.value,
    );
    if (record.authority_revoked or authority.value.revoked) {
        return error.AuthorityRevoked;
    }
    const grant = authority.value.grant;
    if (!grant.principal.eql(input.principal)) {
        return error.PrincipalMismatch;
    }
    if (record.authority_generation.value != input.generation.value or
        grant.generation.value != input.generation.value)
    {
        return error.StaleAuthorityGeneration;
    }
    const direct_model_observer = observer_policy and
        grant.actor == .human and input.actor == .agent;
    if (!direct_model_observer and grant.actor != input.actor) {
        return error.ActorRoleMismatch;
    }
    const controls = if (direct_model_observer)
        contracts.AllowedControls.observer()
    else
        grant.controls;

    var proof = try read_proof(alloc, owner, input.terminal_session_id);
    defer std.crypto.secureZero(u8, @volatileCast(proof.bytes[0..]));
    const actual = proof_verifier(proof, grant, observer_policy);
    if (!std.mem.eql(u8, &actual, &authority.value.verifier)) {
        return error.InvalidHolderProof;
    }
    return operation.ownAuthorityClaim(alloc, .{
        .principal = input.principal,
        .actor = input.actor,
        .generation = input.generation,
        .proof = proof,
    }, controls);
}

pub const RecoveredExecutionScope = struct {
    workspace_root: []u8,

    pub fn deinit(self: *RecoveredExecutionScope, alloc: Allocator) void {
        alloc.free(self.workspace_root);
        self.* = undefined;
    }
};

pub const DurableSession = struct {
    profile: *ProfileStore,
    state: ?session_child_store.SessionChildCapability,
    record: Record,
    journal: ?session_child_store.ManagedFile,
    registered: bool = false,

    pub fn create(profile: *ProfileStore, input: CreateInput) !DurableSession {
        const zio = io_mod.getIo();
        profile.mutex.lockUncancelable(zio);
        defer profile.mutex.unlock(zio);
        try contracts.validate_session_id(input.session_id);
        try input.dimensions.validate();
        for (input.initial_monitors) |definition| {
            try monitor_core.validate_definition(definition);
            try validate_repeated_probe_authority(
                input.persistence.grant,
                definition,
            );
        }
        var state = try profile.open_capability(
            input.persistence.grant.principal.durable_session_id,
            false,
        );
        errdefer state.deinit();
        var proofs = try profile.open_capability(
            input.persistence.grant.principal.durable_session_id,
            true,
        );
        defer proofs.deinit();
        errdefer |err| if (err != error.InjectedCrash) {
            cleanup_partial_start(
                profile.alloc,
                &state,
                &proofs,
                input.session_id,
            );
        };

        const reserve = try checkpoint_reserve_bytes(input.dimensions);
        if (reserve > profile.options.per_session_limit) {
            return error.CapacityExceeded;
        }
        try profile.ensure_profile_capacity(reserve, input.session_id);

        var backend_random: [16]u8 = undefined;
        io_mod.getIo().random(&backend_random);
        const backend_text = std.fmt.bytesToHex(backend_random, .lower);
        const alloc = profile.alloc;
        var fields_owned_by_record = false;
        const session_id = try alloc.dupe(u8, input.session_id);
        errdefer if (!fields_owned_by_record) alloc.free(session_id);
        const owner_session_id = try alloc.dupe(
            u8,
            input.persistence.grant.principal.durable_session_id,
        );
        errdefer if (!fields_owned_by_record) alloc.free(owner_session_id);
        const host_identity = try alloc.dupe(u8, input.host_identity);
        errdefer if (!fields_owned_by_record) alloc.free(host_identity);
        const backend_identity = try alloc.dupe(u8, &backend_text);
        errdefer if (!fields_owned_by_record) alloc.free(backend_identity);
        const shell = try alloc.dupe(u8, input.shell);
        errdefer if (!fields_owned_by_record) alloc.free(shell);
        const cwd = try alloc.dupe(u8, input.cwd);
        errdefer if (!fields_owned_by_record) alloc.free(cwd);
        const command = if (input.command) |value| try alloc.dupe(u8, value) else null;
        errdefer if (!fields_owned_by_record) {
            if (command) |value| alloc.free(value);
        };
        const initial_cursor = contracts.RawCursor{ .segment = 1, .offset = 0 };
        const journal_files = try alloc.alloc(JournalFile, 1);
        errdefer if (!fields_owned_by_record) alloc.free(journal_files);
        journal_files[0] = .{
            .file_id = 1,
            .range = .{ .start = initial_cursor, .end = initial_cursor },
            .payload_bytes = 0,
            .checksum = contracts.checkpoint_checksum(""),
        };
        var record = Record{
            .session_id = session_id,
            .owner_session_id = owner_session_id,
            .host_identity = host_identity,
            .backend_identity = backend_identity,
            .shell = shell,
            .cwd = cwd,
            .command = command,
            .backend = input.backend,
            .lifecycle = .starting,
            .attention = .{},
            .dimensions = input.dimensions,
            .pid = null,
            .process_token = null,
            .takeover_owner_pid = null,
            .takeover_owner_process_token = null,
            .output_cursor = initial_cursor,
            .available_from = initial_cursor,
            .raw_gap = null,
            .raw_replay_exact = true,
            .screen_recovery = .{ .unavailable = .missing },
            .checkpoint_payload_bytes = 0,
            .journal_payload_bytes = 0,
            .journal_files = journal_files,
            .journal_cleanup_through = 0,
            .checkpoint_generation = 0,
            .checkpoint_cleanup_generation = null,
            .next_event_id = 1,
            .acknowledged_event_id = 0,
            .event_gap_through = 0,
            .event_cleanup_through = 0,
            .monitor_count = @intCast(input.initial_monitors.len),
            .authority_generation = input.persistence.grant.generation,
            .authority_revoked = false,
            .direct_human_model_read_only = input.persistence.direct_human_model_read_only,
            .termination = null,
            .created_at_ms = input.now_ms,
            .updated_at_ms = input.now_ms,
        };
        fields_owned_by_record = true;
        errdefer record.deinit(alloc);

        const journal_file_name = try journal_name(alloc, input.session_id, 1);
        defer alloc.free(journal_file_name);
        var journal = try state.createExclusiveFile(
            alloc,
            .terminal_state,
            journal_file_name,
        );
        errdefer journal.deinit();
        try journal.sync();
        if (profile.options.fail_at == .after_journal_create) {
            return error.InjectedCrash;
        }

        try write_proof(alloc, &proofs, input.session_id, input.persistence.proof);
        if (profile.options.fail_at == .after_proof_write) {
            return error.InjectedCrash;
        }
        if (profile.options.fail_at == .grant) return error.InjectedFailure;
        try write_authority(
            alloc,
            &state,
            input.session_id,
            input.persistence.grant,
            input.persistence.direct_human_model_read_only,
            input.persistence.proof,
            false,
        );
        if (profile.options.fail_at == .after_authority_write) {
            return error.InjectedCrash;
        }
        try write_initial_monitors(
            alloc,
            &state,
            input.session_id,
            input.initial_monitors,
            input.now_ms,
        );
        if (profile.options.fail_at == .after_monitor_write) {
            return error.InjectedCrash;
        }
        if (profile.options.fail_at == .start) return error.InjectedFailure;
        try save_record(alloc, &state, record);
        return .{
            .profile = profile,
            .state = state,
            .record = record,
            .journal = journal,
        };
    }

    pub fn deinit(self: *DurableSession) void {
        if (self.registered) self.profile.unregister_resident(self);
        if (self.journal) |*journal| journal.deinit();
        self.record.deinit(self.profile.alloc);
        if (self.state) |*state| state.deinit();
        self.* = undefined;
    }

    /// Returns an owned execution scope. The caller frees it with `deinit`
    /// using the allocator passed here.
    pub fn load_recovery_execution_scope(
        self: *DurableSession,
        alloc: Allocator,
    ) !RecoveredExecutionScope {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        const authority = try load_authority(
            self.profile.alloc,
            try self.state_capability(),
            self.record.session_id,
        );
        defer authority.deinit();
        try validate_recovery_authority(&self.record, &authority.value);
        if (authority.value.revoked) return error.AuthorityRevoked;
        var proofs = try self.profile.open_capability(
            self.record.owner_session_id,
            true,
        );
        defer proofs.deinit();
        var proof = try read_proof(
            self.profile.alloc,
            &proofs,
            self.record.session_id,
        );
        defer std.crypto.secureZero(u8, @volatileCast(proof.bytes[0..]));
        const verifier = proof_verifier(
            proof,
            authority.value.grant,
            authority.value.direct_human_model_read_only,
        );
        if (!std.mem.eql(u8, &verifier, &authority.value.verifier)) {
            return error.InvalidHolderProof;
        }
        return .{
            .workspace_root = try alloc.dupe(
                u8,
                authority.value.grant.principal.workspace_root,
            ),
        };
    }

    pub fn rollback_unreleased_start(self: *DurableSession) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        if (self.record.lifecycle != .starting or self.record.pid != null) {
            return error.InvalidLifecycle;
        }
        if (self.registered) {
            for (self.profile.residents.items, 0..) |resident, index| {
                if (resident != self) continue;
                _ = self.profile.residents.swapRemove(index);
                self.registered = false;
                break;
            }
        }
        if (self.journal) |*journal| journal.deinit();
        self.journal = null;
        var proofs = try self.profile.open_capability(
            self.record.owner_session_id,
            true,
        );
        defer proofs.deinit();
        cleanup_partial_start(
            self.profile.alloc,
            try self.state_capability(),
            &proofs,
            self.record.session_id,
        );
    }

    fn state_capability(
        self: *DurableSession,
    ) !*session_child_store.SessionChildCapability {
        if (self.state == null) {
            self.state = try self.profile.open_capability(
                self.record.owner_session_id,
                false,
            );
        }
        return &self.state.?;
    }

    pub fn release_completed_handles(self: *DurableSession) void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        self.release_completed_handles_locked();
    }

    fn release_completed_handles_locked(self: *DurableSession) void {
        if (!is_completed(self.record.lifecycle)) return;
        if (self.journal) |*journal| journal.deinit();
        self.journal = null;
        if (self.state) |*state| state.deinit();
        self.state = null;
    }

    pub fn mark_started(
        self: *DurableSession,
        pid: []const u8,
        token: process_supervisor.ProcessInstanceToken,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.reject_close_intent_locked();
        if (self.record.lifecycle != .starting) {
            return error.InvalidLifecycle;
        }
        const alloc = self.profile.alloc;
        const pid_owned = try alloc.dupe(u8, pid);
        errdefer alloc.free(pid_owned);
        const token_owned = try alloc.dupe(u8, token.view());
        errdefer alloc.free(token_owned);
        const previous_pid = self.record.pid;
        const previous_token = self.record.process_token;
        const previous_lifecycle = self.record.lifecycle;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.pid = pid_owned;
        self.record.process_token = token_owned;
        self.record.lifecycle = try contracts.transition_lifecycle(
            self.record.lifecycle,
            .child_started,
        );
        self.record.updated_at_ms = now_ms;
        save_record(alloc, try self.state_capability(), self.record) catch |err| {
            self.record.pid = previous_pid;
            self.record.process_token = previous_token;
            self.record.lifecycle = previous_lifecycle;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        if (previous_pid) |value| alloc.free(value);
        if (previous_token) |value| alloc.free(value);
        _ = try self.append_event_locked(.lifecycle, now_ms);
    }

    pub fn append(self: *DurableSession, bytes: []const u8, now_ms: i64) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        if (bytes.len == 0) return;
        if (self.profile.options.fail_at == .append) return error.InjectedFailure;
        const appended_len = std.math.cast(u64, bytes.len) orelse
            return error.CapacityExceeded;
        const reserve = try checkpoint_reserve_bytes(self.record.dimensions);
        var retained_after = std.math.add(
            u64,
            self.record.journal_payload_bytes,
            appended_len,
        ) catch return error.CapacityExceeded;
        var session_after = std.math.add(
            u64,
            retained_after,
            @max(reserve, self.record.checkpoint_payload_bytes),
        ) catch return error.CapacityExceeded;
        if (session_after > self.profile.options.per_session_limit) {
            self.evict_live_covered_journals() catch
                return error.CapacityExceeded;
            retained_after = std.math.add(
                u64,
                self.record.journal_payload_bytes,
                appended_len,
            ) catch return error.CapacityExceeded;
            session_after = std.math.add(
                u64,
                retained_after,
                @max(reserve, self.record.checkpoint_payload_bytes),
            ) catch return error.CapacityExceeded;
            if (session_after > self.profile.options.per_session_limit) {
                return error.CapacityExceeded;
            }
        }
        self.profile.ensure_profile_capacity(
            appended_len,
            self.record.session_id,
        ) catch |err| switch (err) {
            error.CapacityExceeded => {
                self.evict_live_covered_journals() catch
                    return error.CapacityExceeded;
                try self.profile.ensure_profile_capacity(
                    appended_len,
                    self.record.session_id,
                );
            },
            else => return err,
        };

        var remaining = bytes;
        while (remaining.len != 0) {
            const current = self.record.journal_files[
                self.record.journal_files.len - 1
            ];
            const space = self.profile.options.segment_bytes -
                current.payload_bytes;
            const write_len = @min(
                remaining.len,
                std.math.cast(usize, if (space == 0)
                    self.profile.options.segment_bytes
                else
                    space) orelse return error.CapacityExceeded,
            );
            try self.append_journal_chunk(remaining[0..write_len], now_ms);
            remaining = remaining[write_len..];
        }
        std.debug.assert(self.record.journal_payload_bytes == retained_after);
    }

    pub fn begin_raw_gap(self: *DurableSession, now_ms: i64) !contracts.RawGap {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        if (!is_live(self.record.lifecycle)) return error.InvalidLifecycle;
        const next_segment = std.math.add(
            u64,
            self.record.output_cursor.segment,
            1,
        ) catch return error.CapacityExceeded;
        const next_cursor = contracts.RawCursor{
            .segment = next_segment,
            .offset = 0,
        };
        const collapse_previous_gap = self.record.raw_gap != null;
        const gap = contracts.RawGap{
            .missing_from = if (collapse_previous_gap)
                self.record.available_from
            else
                self.record.output_cursor,
            .available_from = next_cursor,
        };
        const previous_files = self.record.journal_files;
        const expanded = try self.profile.alloc.alloc(
            JournalFile,
            if (collapse_previous_gap) 1 else previous_files.len + 1,
        );
        errdefer self.profile.alloc.free(expanded);
        if (!collapse_previous_gap) {
            @memcpy(expanded[0..previous_files.len], previous_files);
        }
        const next_file_id = std.math.add(
            u64,
            previous_files[previous_files.len - 1].file_id,
            1,
        ) catch return error.CapacityExceeded;
        expanded[expanded.len - 1] = .{
            .file_id = next_file_id,
            .range = .{ .start = next_cursor, .end = next_cursor },
            .payload_bytes = 0,
            .checksum = contracts.checkpoint_checksum(""),
        };
        const name = try journal_name(
            self.profile.alloc,
            self.record.session_id,
            next_file_id,
        );
        defer self.profile.alloc.free(name);
        var journal = try (try self.state_capability()).createExclusiveFile(
            self.profile.alloc,
            .terminal_state,
            name,
        );
        var journal_owned = true;
        errdefer if (journal_owned) {
            journal.deinit();
            if (self.state_capability() catch null) |capability| {
                capability.delete(.terminal_state, name) catch {};
            }
        };
        try journal.sync();

        const previous_cursor = self.record.output_cursor;
        const previous_available = self.record.available_from;
        const previous_gap = self.record.raw_gap;
        const previous_exact = self.record.raw_replay_exact;
        const previous_journal_bytes = self.record.journal_payload_bytes;
        const previous_journal_cleanup = self.record.journal_cleanup_through;
        const previous_recovery = self.record.screen_recovery;
        const previous_checkpoint_bytes = self.record.checkpoint_payload_bytes;
        const previous_checkpoint_generation = self.record.checkpoint_generation;
        const previous_checkpoint_cleanup = self.record.checkpoint_cleanup_generation;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.journal_files = expanded;
        self.record.output_cursor = next_cursor;
        if (collapse_previous_gap) {
            self.record.available_from = next_cursor;
            self.record.journal_payload_bytes = 0;
            self.record.journal_cleanup_through = @max(
                self.record.journal_cleanup_through,
                previous_files[previous_files.len - 1].file_id,
            );
        }
        self.record.raw_gap = gap;
        self.record.raw_replay_exact = false;
        self.record.screen_recovery = .{ .unavailable = .raw_gap };
        self.record.checkpoint_payload_bytes = 0;
        self.record.checkpoint_generation = 0;
        self.record.checkpoint_cleanup_generation = if (previous_checkpoint_generation == 0)
            previous_checkpoint_cleanup
        else
            previous_checkpoint_generation;
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.journal_files = previous_files;
            self.record.output_cursor = previous_cursor;
            self.record.available_from = previous_available;
            self.record.raw_gap = previous_gap;
            self.record.raw_replay_exact = previous_exact;
            self.record.journal_payload_bytes = previous_journal_bytes;
            self.record.journal_cleanup_through = previous_journal_cleanup;
            self.record.screen_recovery = previous_recovery;
            self.record.checkpoint_payload_bytes = previous_checkpoint_bytes;
            self.record.checkpoint_generation = previous_checkpoint_generation;
            self.record.checkpoint_cleanup_generation = previous_checkpoint_cleanup;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        self.profile.alloc.free(previous_files);
        if (self.journal) |*previous| previous.deinit();
        self.journal = journal;
        journal_owned = false;
        self.retry_journal_cleanup() catch |err| debug_trace.logf(
            "terminal_store",
            "raw gap journal cleanup deferred id={s} err={s}",
            .{ self.record.session_id, @errorName(err) },
        );
        self.retry_checkpoint_cleanup() catch |err| debug_trace.logf(
            "terminal_store",
            "raw gap checkpoint cleanup deferred id={s} err={s}",
            .{ self.record.session_id, @errorName(err) },
        );
        return gap;
    }

    fn append_journal_chunk(
        self: *DurableSession,
        bytes: []const u8,
        now_ms: i64,
    ) !void {
        const alloc = self.profile.alloc;
        const previous_files = self.record.journal_files;
        var working = try alloc.dupe(JournalFile, previous_files);
        var working_owned = true;
        defer if (working_owned) alloc.free(working);

        var replacement: ?session_child_store.ManagedFile = null;
        var replacement_name: ?[]u8 = null;
        defer if (replacement_name) |name| alloc.free(name);
        errdefer |err| {
            if (replacement) |*file| file.deinit();
            if (err != error.InjectedCrash) {
                if (replacement_name) |name| {
                    const capability = self.state_capability() catch |cleanup_err| blk: {
                        debug_trace.logf(
                            "terminal_store",
                            "journal rollback open failed file={s} err={s}",
                            .{ name, @errorName(cleanup_err) },
                        );
                        break :blk null;
                    };
                    if (capability) |value| {
                        value.delete(.terminal_state, name) catch |cleanup_err| {
                            debug_trace.logf(
                                "terminal_store",
                                "journal rollback delete failed file={s} err={s}",
                                .{ name, @errorName(cleanup_err) },
                            );
                        };
                    }
                }
            }
        }

        const resumes_reopened_journal = self.journal == null;
        if (resumes_reopened_journal or
            working[working.len - 1].payload_bytes ==
                self.profile.options.segment_bytes)
        {
            const next_id = std.math.add(
                u64,
                working[working.len - 1].file_id,
                1,
            ) catch return error.CapacityExceeded;
            const expanded = try alloc.alloc(JournalFile, working.len + 1);
            @memcpy(expanded[0..working.len], working);
            alloc.free(working);
            working = expanded;
            const cursor = self.record.output_cursor;
            working[working.len - 1] = .{
                .file_id = next_id,
                .range = .{ .start = cursor, .end = cursor },
                .payload_bytes = 0,
                .checksum = contracts.checkpoint_checksum(""),
            };
            const name = try journal_name(alloc, self.record.session_id, next_id);
            replacement_name = name;
            replacement = try (try self.state_capability()).createExclusiveFile(
                alloc,
                .terminal_state,
                name,
            );
            try replacement.?.sync();
            if (resumes_reopened_journal) {
                debug_trace.logf(
                    "terminal_store",
                    "journal append resumed id={s} cursor={d}:{d} file={d}",
                    .{
                        self.record.session_id,
                        cursor.segment,
                        cursor.offset,
                        next_id,
                    },
                );
            }
        }

        const file = if (replacement) |*value|
            value
        else if (self.journal) |*value|
            value
        else
            return error.TerminalStoreFailed;
        try file.writeAll(bytes);
        try file.sync();
        if (self.profile.options.fail_at == .after_journal_sync) {
            return error.InjectedCrash;
        }

        const extent = &working[working.len - 1];
        const next_offset = std.math.add(
            u64,
            self.record.output_cursor.offset,
            bytes.len,
        ) catch return error.CapacityExceeded;
        const next_file_bytes = std.math.add(
            u64,
            extent.payload_bytes,
            bytes.len,
        ) catch return error.CapacityExceeded;
        extent.range.end.offset = next_offset;
        extent.payload_bytes = next_file_bytes;
        extent.checksum = try self.journal_checksum(
            extent.file_id,
            next_file_bytes,
        );

        const previous_output_cursor = self.record.output_cursor;
        const previous_journal_bytes = self.record.journal_payload_bytes;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.journal_files = working;
        self.record.output_cursor.offset = next_offset;
        self.record.journal_payload_bytes = std.math.add(
            u64,
            previous_journal_bytes,
            bytes.len,
        ) catch return error.CapacityExceeded;
        self.record.updated_at_ms = now_ms;
        save_record(
            alloc,
            try self.state_capability(),
            self.record,
        ) catch {
            self.record.journal_files = previous_files;
            self.record.output_cursor = previous_output_cursor;
            self.record.journal_payload_bytes = previous_journal_bytes;
            self.record.updated_at_ms = previous_updated_at_ms;
            return error.TerminalStoreFailed;
        };
        alloc.free(previous_files);
        working_owned = false;
        if (replacement) |new_file| {
            if (self.journal) |*old_file| old_file.deinit();
            self.journal = new_file;
            replacement = null;
        }
    }

    fn journal_checksum(
        self: *DurableSession,
        file_id: u64,
        expected_bytes: u64,
    ) !contracts.CheckpointChecksum {
        const alloc = self.profile.alloc;
        const name = try journal_name(alloc, self.record.session_id, file_id);
        defer alloc.free(name);
        var file = try (try self.state_capability()).openFileReadOnly(
            alloc,
            .terminal_state,
            name,
        );
        defer file.deinit();
        const max_bytes = std.math.cast(usize, expected_bytes) orelse
            return error.CapacityExceeded;
        const contents = try file.readToEnd(alloc, max_bytes + 1);
        defer alloc.free(contents);
        if (contents.len != max_bytes) return error.CorruptJournalSegment;
        return contracts.checkpoint_checksum(contents);
    }

    pub fn read(
        self: *DurableSession,
        alloc: Allocator,
        requested: contracts.RawCursor,
        max_bytes: usize,
    ) !ReadPage {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try requested.validate();
        if (max_bytes == 0) return error.InvalidReadLength;
        if (contracts.compare_raw_cursors(
            requested,
            self.record.output_cursor,
        ) == .gt) return error.InvalidCursor;

        var start = if (contracts.compare_raw_cursors(
            requested,
            self.record.available_from,
        ) == .lt)
            self.record.available_from
        else
            requested;
        var gap = if (contracts.compare_raw_cursors(requested, start) == .lt)
            contracts.RawGap{
                .missing_from = requested,
                .available_from = start,
            }
        else
            null;
        if (self.record.raw_gap) |raw_gap| {
            if (contracts.compare_raw_cursors(start, raw_gap.missing_from) != .lt and
                contracts.compare_raw_cursors(start, raw_gap.available_from) == .lt)
            {
                start = raw_gap.available_from;
                gap = raw_gap;
            }
        }
        if (contracts.compare_raw_cursors(start, self.record.output_cursor) == .eq) {
            return .{
                .output = try alloc.dupe(u8, ""),
                .range = null,
                .gap = gap,
            };
        }
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(alloc);
        try output.ensureTotalCapacity(alloc, max_bytes);
        var cursor = start;
        while (output.items.len < max_bytes and
            contracts.compare_raw_cursors(cursor, self.record.output_cursor) == .lt)
        {
            if (self.record.raw_gap) |raw_gap| {
                if (contracts.compare_raw_cursors(
                    cursor,
                    raw_gap.missing_from,
                ) == .eq) break;
            }
            const index = find_journal_file(self.record.journal_files, cursor) orelse
                return error.MissingJournalSegment;
            const extent = self.record.journal_files[index];
            const local_offset = cursor.offset - extent.range.start.offset;
            const remaining_file = extent.payload_bytes - local_offset;
            const wanted = @min(
                max_bytes - output.items.len,
                std.math.cast(usize, remaining_file) orelse
                    return error.InvalidReadLength,
            );
            const name = try journal_name(alloc, self.record.session_id, extent.file_id);
            defer alloc.free(name);
            var file = (try self.state_capability()).openFileReadOnly(
                alloc,
                .terminal_state,
                name,
            ) catch |err| switch (err) {
                error.FileNotFound => return error.MissingJournalSegment,
                else => return err,
            };
            defer file.deinit();
            const bytes = try file.readRange(alloc, local_offset, wanted);
            defer alloc.free(bytes);
            if (bytes.len != wanted) return error.CorruptJournalSegment;
            try output.appendSlice(alloc, bytes);
            cursor.offset = std.math.add(u64, cursor.offset, bytes.len) catch
                return error.CorruptJournalSegment;
            if (bytes.len == 0) return error.CorruptJournalSegment;
        }
        const owned_output = try output.toOwnedSlice(alloc);
        return .{
            .output = owned_output,
            .range = if (owned_output.len == 0) null else .{
                .start = start,
                .end = cursor,
            },
            .gap = gap,
        };
    }

    pub fn contains(
        self: *DurableSession,
        pattern: []const u8,
        requested: contracts.RawCursor,
    ) !bool {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        if (pattern.len == 0) return error.InvalidMatchPattern;
        try requested.validate();
        if (contracts.compare_raw_cursors(
            requested,
            self.record.output_cursor,
        ) == .gt) return false;
        var start = if (contracts.compare_raw_cursors(
            requested,
            self.record.available_from,
        ) == .lt)
            self.record.available_from
        else
            requested;
        if (self.record.raw_gap) |gap| {
            if (contracts.compare_raw_cursors(start, gap.missing_from) != .lt and
                contracts.compare_raw_cursors(start, gap.available_from) == .lt)
            {
                start = gap.available_from;
            }
        }
        var carry: std.ArrayList(u8) = .empty;
        defer carry.deinit(self.profile.alloc);
        try carry.ensureTotalCapacity(self.profile.alloc, pattern.len - 1);
        var cursor = start;
        while (contracts.compare_raw_cursors(
            cursor,
            self.record.output_cursor,
        ) == .lt) {
            if (self.record.raw_gap) |gap| {
                if (contracts.compare_raw_cursors(cursor, gap.missing_from) == .eq) {
                    carry.clearRetainingCapacity();
                    cursor = gap.available_from;
                    continue;
                }
            }
            const index = find_journal_file(self.record.journal_files, cursor) orelse
                return error.MissingJournalSegment;
            const extent = self.record.journal_files[index];
            const name = try journal_name(
                self.profile.alloc,
                self.record.session_id,
                extent.file_id,
            );
            defer self.profile.alloc.free(name);
            var file = (try self.state_capability()).openFileReadOnly(
                self.profile.alloc,
                .terminal_state,
                name,
            ) catch |err| switch (err) {
                error.FileNotFound => return error.MissingJournalSegment,
                else => return err,
            };
            defer file.deinit();
            const offset = cursor.offset - extent.range.start.offset;
            const length = std.math.cast(usize, extent.payload_bytes - offset) orelse
                return error.CapacityExceeded;
            const bytes = try file.readRange(self.profile.alloc, offset, length);
            defer self.profile.alloc.free(bytes);
            if (bytes.len != length) return error.CorruptJournalSegment;
            var combined: std.ArrayList(u8) = .empty;
            defer combined.deinit(self.profile.alloc);
            try combined.appendSlice(self.profile.alloc, carry.items);
            try combined.appendSlice(self.profile.alloc, bytes);
            if (std.mem.find(u8, combined.items, pattern) != null) return true;
            carry.clearRetainingCapacity();
            const tail_len = @min(combined.items.len, pattern.len - 1);
            if (tail_len != 0) {
                try carry.appendSlice(
                    self.profile.alloc,
                    combined.items[combined.items.len - tail_len ..],
                );
            }
            cursor = extent.range.end;
        }
        return false;
    }

    pub fn store_checkpoint(
        self: *DurableSession,
        envelope: contracts.CheckpointEnvelope,
        payload: []const u8,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.retry_checkpoint_cleanup();
        try envelope.validate(payload);
        if (contracts.compare_raw_cursors(
            envelope.applied_cursor,
            self.record.output_cursor,
        ) == .gt) return error.InvalidCheckpoint;
        if (self.profile.options.fail_at == .checkpoint_replacement) {
            return error.InjectedFailure;
        }
        const payload_len = std.math.cast(u64, payload.len) orelse
            return error.CapacityExceeded;
        const reserve = try checkpoint_reserve_bytes(self.record.dimensions);
        const session_after = std.math.add(
            u64,
            self.record.journal_payload_bytes,
            @max(reserve, payload_len),
        ) catch return error.CapacityExceeded;
        if (session_after > self.profile.options.per_session_limit) {
            return error.CapacityExceeded;
        }
        const additional = @max(reserve, payload_len) -|
            @max(reserve, self.record.checkpoint_payload_bytes);
        try self.profile.ensure_profile_capacity(additional, self.record.session_id);
        const bytes = try encode_checkpoint(self.profile.alloc, envelope, payload);
        defer self.profile.alloc.free(bytes);
        const next_generation = std.math.add(
            u64,
            self.record.checkpoint_generation,
            1,
        ) catch return error.CapacityExceeded;
        const name = try checkpoint_name(
            self.profile.alloc,
            self.record.session_id,
            next_generation,
        );
        defer self.profile.alloc.free(name);
        var entry = try (try self.state_capability()).atomicReplace(
            self.profile.alloc,
            .terminal_state,
            name,
            bytes,
        );
        entry.deinit(self.profile.alloc);
        if (self.profile.options.fail_at == .after_checkpoint_write) {
            return error.InjectedCrash;
        }
        const previous_recovery = self.record.screen_recovery;
        const previous_checkpoint_bytes = self.record.checkpoint_payload_bytes;
        const previous_generation = self.record.checkpoint_generation;
        const previous_cleanup_generation = self.record.checkpoint_cleanup_generation;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.screen_recovery = .{ .available = envelope };
        self.record.checkpoint_payload_bytes = payload_len;
        self.record.checkpoint_generation = next_generation;
        self.record.checkpoint_cleanup_generation = if (previous_generation == 0)
            previous_cleanup_generation
        else
            previous_generation;
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.screen_recovery = previous_recovery;
            self.record.checkpoint_payload_bytes = previous_checkpoint_bytes;
            self.record.checkpoint_generation = previous_generation;
            self.record.checkpoint_cleanup_generation = previous_cleanup_generation;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        if (self.profile.options.fail_at == .after_checkpoint_record) {
            return error.InjectedCrash;
        }
        try self.retry_checkpoint_cleanup();
    }

    pub fn load_checkpoint(
        self: *DurableSession,
        alloc: Allocator,
    ) !?Checkpoint {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        return self.load_checkpoint_locked(alloc);
    }

    fn load_checkpoint_locked(
        self: *DurableSession,
        alloc: Allocator,
    ) !?Checkpoint {
        const envelope = switch (self.record.screen_recovery) {
            .unavailable => return null,
            .available => |value| value,
        };
        const name = try checkpoint_name(
            alloc,
            self.record.session_id,
            self.record.checkpoint_generation,
        );
        defer alloc.free(name);
        var file = (try self.state_capability()).openFileReadOnly(
            alloc,
            .terminal_state,
            name,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.MissingCheckpoint,
            else => return err,
        };
        defer file.deinit();
        const bytes = try file.readToEnd(
            alloc,
            contracts.max_checkpoint_payload_bytes + checkpoint_header_bytes,
        );
        defer alloc.free(bytes);
        var checkpoint = try decode_checkpoint(alloc, bytes);
        errdefer checkpoint.deinit(alloc);
        if (!checkpoint_envelopes_equal(checkpoint.envelope, envelope)) {
            return error.InvalidCheckpoint;
        }
        if (checkpoint.payload.len != self.record.checkpoint_payload_bytes) {
            return error.InvalidCheckpoint;
        }
        return checkpoint;
    }

    fn retry_checkpoint_cleanup(self: *DurableSession) !void {
        const generation = self.record.checkpoint_cleanup_generation orelse return;
        const name = try checkpoint_name(
            self.profile.alloc,
            self.record.session_id,
            generation,
        );
        defer self.profile.alloc.free(name);
        (try self.state_capability()).delete(.terminal_state, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        self.record.checkpoint_cleanup_generation = null;
        try save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        );
    }

    pub fn append_event(
        self: *DurableSession,
        kind: contracts.HostEvent,
        now_ms: i64,
    ) !u64 {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        return self.append_event_locked(kind, now_ms);
    }

    fn append_event_locked(
        self: *DurableSession,
        kind: contracts.HostEvent,
        now_ms: i64,
    ) !u64 {
        const event_id = self.record.next_event_id;
        try self.write_event_locked(kind, null, null, now_ms);
        if (self.profile.options.fail_at == .after_event_write) {
            return error.InjectedCrash;
        }
        const previous_updated_at_ms = self.record.updated_at_ms;
        const previous_gap = self.record.event_gap_through;
        self.record.next_event_id = std.math.add(u64, event_id, 1) catch
            return error.EventIdExhausted;
        if (event_id > event_retention_limit) {
            self.record.event_gap_through = @max(
                self.record.event_gap_through,
                event_id - event_retention_limit,
            );
        }
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.next_event_id = event_id;
            self.record.event_gap_through = previous_gap;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        try self.retry_event_cleanup_locked();
        return event_id;
    }

    fn write_event_locked(
        self: *DurableSession,
        kind: contracts.HostEvent,
        monitor_sequence_value: ?u64,
        monitor_reason: ?monitor_core.EventReason,
        now_ms: i64,
    ) !void {
        const event_id = self.record.next_event_id;
        const event = DurableEvent{
            .id = event_id,
            .kind = kind,
            .lifecycle = self.record.lifecycle,
            .cursor = self.record.output_cursor,
            .created_at_ms = now_ms,
            .monitor_sequence = monitor_sequence_value,
            .monitor_reason = monitor_reason,
        };
        try self.write_event_value_locked(
            try self.state_capability(),
            event,
        );
    }

    fn write_event_value_locked(
        self: *DurableSession,
        capability: *session_child_store.SessionChildCapability,
        event: DurableEvent,
    ) !void {
        try event.validate();
        const bytes = try render_json(
            self.profile.alloc,
            EventWire{ .event = event },
        );
        defer self.profile.alloc.free(bytes);
        if (bytes.len > max_event_bytes) return error.DurableEventTooLarge;
        const name = try event_name(
            self.profile.alloc,
            self.record.session_id,
            event.id,
        );
        defer self.profile.alloc.free(name);
        var entry = try capability.atomicReplace(
            self.profile.alloc,
            .terminal_state,
            name,
            bytes,
        );
        entry.deinit(self.profile.alloc);
    }

    pub fn acknowledge(self: *DurableSession, event_id: u64, now_ms: i64) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        if (event_id <= self.record.acknowledged_event_id) {
            try self.retry_event_cleanup_locked();
            return;
        }
        if (event_id >= self.record.next_event_id) return error.UnknownEventId;
        if (self.profile.options.fail_at == .acknowledgement) {
            return error.InjectedFailure;
        }
        const previous_acknowledged = self.record.acknowledged_event_id;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.acknowledged_event_id = event_id;
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.acknowledged_event_id = previous_acknowledged;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        if (self.profile.options.fail_at == .after_acknowledgement_record) {
            return error.InjectedCrash;
        }
        try self.retry_event_cleanup_locked();
    }

    fn retry_event_cleanup_locked(self: *DurableSession) !void {
        const target = @max(
            self.record.acknowledged_event_id,
            self.record.event_gap_through,
        );
        if (target <= self.record.event_cleanup_through) return;
        var id = self.record.event_cleanup_through + 1;
        while (id <= target) : (id += 1) {
            const name = try event_name(
                self.profile.alloc,
                self.record.session_id,
                id,
            );
            defer self.profile.alloc.free(name);
            (try self.state_capability()).delete(.terminal_state, name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            if (id == std.math.maxInt(u64)) break;
        }
        self.record.event_cleanup_through = target;
        try save_record(self.profile.alloc, try self.state_capability(), self.record);
    }

    pub fn replay_events(
        self: *DurableSession,
        alloc: Allocator,
        after_event_id: u64,
        max_events: usize,
    ) !EventReplay {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        if (max_events == 0 or max_events > @as(usize, event_retention_limit)) {
            return error.InvalidEventReplayLimit;
        }
        const requested = std.math.add(u64, after_event_id, 1) catch
            return error.EventIdExhausted;
        const retained_after = @max(
            self.record.acknowledged_event_id,
            self.record.event_gap_through,
        );
        var id = @max(
            requested,
            std.math.add(u64, retained_after, 1) catch
                return error.EventIdExhausted,
        );
        var events: std.ArrayList(DurableEvent) = .empty;
        errdefer events.deinit(alloc);
        while (id < self.record.next_event_id and events.items.len < max_events) : (id += 1) {
            const event = try load_event(
                alloc,
                try self.state_capability(),
                self.record.session_id,
                id,
            );
            try events.append(alloc, event);
        }
        return .{
            .events = try events.toOwnedSlice(alloc),
            .gap_through = self.record.event_gap_through,
            .next_event_id = @min(id, self.record.next_event_id),
        };
    }

    pub fn load_monitor_definitions(
        self: *DurableSession,
        alloc: Allocator,
    ) !MonitorDefinitions {
        var set = try self.load_monitor_set(alloc);
        errdefer set.deinit();
        const definitions = try alloc.alloc(
            contracts.MonitorDefinition,
            set.parsed.value.monitors.len,
        );
        for (set.parsed.value.monitors, 0..) |monitor, index| {
            definitions[index] = monitor.definition;
        }
        return .{
            .alloc = alloc,
            .parsed = set.parsed,
            .definitions = definitions,
        };
    }

    pub fn load_monitor_set(
        self: *DurableSession,
        alloc: Allocator,
    ) !MonitorSet {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        _ = try self.reconcile_monitor_transaction_locked();
        return self.load_monitor_set_locked(alloc, true);
    }

    pub fn authorize_monitor_definition(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        definition: contracts.MonitorDefinition,
    ) !Authorization {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        const authorization = try self.authorize_locked(claim, .monitor);
        try monitor_core.validate_definition(definition);
        var authority = try load_authority(
            self.profile.alloc,
            try self.state_capability(),
            self.record.session_id,
        );
        defer authority.deinit();
        try validate_repeated_probe_authority(authority.value.grant, definition);
        return authorization;
    }

    fn load_monitor_set_locked(
        self: *DurableSession,
        alloc: Allocator,
        require_count_match: bool,
    ) !MonitorSet {
        const name = try monitors_name(alloc, self.record.session_id);
        defer alloc.free(name);
        var file = try (try self.state_capability()).openFileReadOnly(
            alloc,
            .terminal_state,
            name,
        );
        defer file.deinit();
        const bytes = try file.readToEnd(alloc, monitor_set_bytes_limit);
        defer alloc.free(bytes);
        var parsed = std.json.parseFromSlice(
            monitor_core.PersistedSet,
            alloc,
            bytes,
            .{ .allocate = .alloc_always },
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidMonitorRecord,
        };
        errdefer parsed.deinit();
        if (parsed.value.schema_version != monitor_core.schema_version or
            parsed.value.next_monitor_id == 0 or
            parsed.value.monitors.len > contracts.max_monitor_definitions or
            (require_count_match and
                parsed.value.monitors.len != self.record.monitor_count))
        {
            return error.InvalidMonitorRecord;
        }
        var previous_sequence: u64 = 0;
        for (parsed.value.monitors) |monitor| {
            monitor_core.validate_runtime(monitor) catch
                return error.InvalidMonitorRecord;
            const sequence = monitor_sequence(monitor.monitor_id) orelse
                return error.InvalidMonitorRecord;
            if (sequence <= previous_sequence or
                sequence >= parsed.value.next_monitor_id)
            {
                return error.InvalidMonitorRecord;
            }
            previous_sequence = sequence;
        }
        return .{ .parsed = parsed };
    }

    pub fn persist_monitor_set(
        self: *DurableSession,
        set: monitor_core.PersistedSet,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.reject_close_intent_locked();
        return self.persist_monitor_set_locked(set, now_ms, .ordinary);
    }

    fn persist_monitor_set_locked(
        self: *DurableSession,
        set: monitor_core.PersistedSet,
        now_ms: i64,
        context: MonitorCommitContext,
    ) !void {
        _ = try self.reconcile_monitor_transaction_locked();
        const capability = try self.state_capability();
        var transaction = MonitorTransaction{
            .updated_at_ms = now_ms,
            .candidate = set,
        };
        try ensure_monitor_set_fits(self.profile.alloc, set);
        try ensure_monitor_transaction_fits(self.profile.alloc, transaction);
        try write_monitor_transaction(
            self.profile.alloc,
            capability,
            self.record.session_id,
            transaction,
        );
        if (context == .close and closeFailureAt(
            self.profile,
            .after_close_monitor_transaction_prepare,
        )) return error.InjectedCrash;
        if (monitorFailureAt(
            self.profile,
            .after_monitor_transaction_prepare,
        )) return error.SessionChildCommitIndeterminate;
        transaction.committed = true;
        try write_monitor_transaction(
            self.profile.alloc,
            capability,
            self.record.session_id,
            transaction,
        );
        if (context == .close and closeFailureAt(
            self.profile,
            .after_close_monitor_event,
        )) return error.InjectedCrash;
        if (monitorFailureAt(
            self.profile,
            .after_monitor_transaction_commit,
        )) return error.SessionChildCommitIndeterminate;
        try apply_monitor_transaction_record(&self.record, transaction);
        write_monitor_set(
            self.profile.alloc,
            capability,
            self.record.session_id,
            set,
        ) catch |err| {
            if (context == .close) return err;
            debug_trace.logf(
                "terminal_store",
                "committed monitor state deferred id={s} err={s}",
                .{ self.record.session_id, @errorName(err) },
            );
            return;
        };
        if (context == .close and closeFailureAt(
            self.profile,
            .after_close_monitor_state_write,
        )) return error.InjectedCrash;
        if (monitorFailureAt(
            self.profile,
            .after_monitor_state_write,
        )) {
            return error.InjectedCrash;
        }
        save_record(
            self.profile.alloc,
            capability,
            self.record,
        ) catch |err| {
            if (context == .close) return err;
            debug_trace.logf(
                "terminal_store",
                "committed monitor record deferred id={s} err={s}",
                .{ self.record.session_id, @errorName(err) },
            );
            return;
        };
        if (context == .close and closeFailureAt(
            self.profile,
            .after_close_monitor_record_write,
        )) return error.InjectedCrash;
        if (monitorFailureAt(
            self.profile,
            .after_monitor_record,
        )) return error.InjectedCrash;
        if (context == .close) {
            try delete_monitor_transaction(
                self.profile.alloc,
                capability,
                self.record.session_id,
            );
            if (closeFailureAt(
                self.profile,
                .after_close_monitor_cleanup,
            )) return error.InjectedCrash;
        } else {
            delete_monitor_transaction(
                self.profile.alloc,
                capability,
                self.record.session_id,
            ) catch |err| debug_trace.logf(
                "terminal_store",
                "committed monitor transaction cleanup deferred id={s} err={s}",
                .{ self.record.session_id, @errorName(err) },
            );
        }
    }

    pub fn ensure_monitor_admission(
        self: *DurableSession,
        set: monitor_core.PersistedSet,
    ) !void {
        try ensure_monitor_set_admissible(self.profile.alloc, set);
    }

    pub fn commit_monitor_event(
        self: *DurableSession,
        set: monitor_core.PersistedSet,
        sequence: u64,
        reason: monitor_core.EventReason,
        now_ms: i64,
    ) !u64 {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.reject_close_intent_locked();
        return self.commit_monitor_event_locked(
            set,
            sequence,
            reason,
            now_ms,
            .ordinary,
        );
    }

    fn commit_monitor_event_locked(
        self: *DurableSession,
        set: monitor_core.PersistedSet,
        sequence: u64,
        reason: monitor_core.EventReason,
        now_ms: i64,
        context: MonitorCommitContext,
    ) !u64 {
        _ = try self.reconcile_monitor_transaction_locked();
        const event_id = self.record.next_event_id;
        var previous = try self.load_monitor_set_locked(self.profile.alloc, true);
        defer previous.deinit();
        const candidate_monitor = find_monitor_by_sequence_mut(set.monitors, sequence);
        const previous_monitor = find_monitor_by_sequence(
            previous.parsed.value.monitors,
            sequence,
        );
        if (candidate_monitor == null and previous_monitor == null) {
            return error.MonitorNotFound;
        }
        if (candidate_monitor) |persisted| {
            try monitor_core.note_notification(persisted, event_id, reason);
        }
        const event = DurableEvent{
            .id = event_id,
            .kind = .monitor,
            .lifecycle = self.record.lifecycle,
            .cursor = self.record.output_cursor,
            .created_at_ms = now_ms,
            .monitor_sequence = sequence,
            .monitor_reason = reason,
        };
        const transaction = MonitorTransaction{
            .updated_at_ms = now_ms,
            .candidate = set,
            .event = event,
        };
        try ensure_monitor_set_fits(self.profile.alloc, set);
        try ensure_monitor_transaction_fits(self.profile.alloc, transaction);
        const capability = try self.state_capability();
        try write_monitor_transaction(
            self.profile.alloc,
            capability,
            self.record.session_id,
            transaction,
        );
        if (context == .close and closeFailureAt(
            self.profile,
            .after_close_monitor_transaction_prepare,
        )) return error.InjectedCrash;
        if (monitorFailureAt(
            self.profile,
            .after_monitor_transaction_prepare,
        )) return error.SessionChildCommitIndeterminate;
        try self.write_event_locked(.monitor, sequence, reason, now_ms);
        if (context == .close and closeFailureAt(
            self.profile,
            .after_close_monitor_event,
        )) return error.InjectedCrash;
        if (monitorFailureAt(
            self.profile,
            .after_monitor_event_indeterminate,
        )) return error.SessionChildCommitIndeterminate;
        if (monitorFailureAt(
            self.profile,
            .after_event_write,
        )) {
            return error.InjectedCrash;
        }
        try apply_monitor_transaction_record(&self.record, transaction);
        write_monitor_set(
            self.profile.alloc,
            capability,
            self.record.session_id,
            set,
        ) catch |err| {
            if (context == .close) return err;
            debug_trace.logf(
                "terminal_store",
                "committed monitor event state deferred id={s} err={s}",
                .{ self.record.session_id, @errorName(err) },
            );
            return event_id;
        };
        if (context == .close and closeFailureAt(
            self.profile,
            .after_close_monitor_state_write,
        )) return error.InjectedCrash;
        if (monitorFailureAt(
            self.profile,
            .after_monitor_state_write,
        )) {
            return error.InjectedCrash;
        }
        save_record(
            self.profile.alloc,
            capability,
            self.record,
        ) catch |err| {
            if (context == .close) return err;
            debug_trace.logf(
                "terminal_store",
                "committed monitor event record deferred id={s} err={s}",
                .{ self.record.session_id, @errorName(err) },
            );
            return event_id;
        };
        if (context == .close and closeFailureAt(
            self.profile,
            .after_close_monitor_record_write,
        )) return error.InjectedCrash;
        if (monitorFailureAt(
            self.profile,
            .after_monitor_event_record,
        )) {
            return error.InjectedCrash;
        }
        if (context == .close) {
            try delete_monitor_transaction(
                self.profile.alloc,
                capability,
                self.record.session_id,
            );
            if (closeFailureAt(
                self.profile,
                .after_close_monitor_cleanup,
            )) return error.InjectedCrash;
        } else {
            delete_monitor_transaction(
                self.profile.alloc,
                capability,
                self.record.session_id,
            ) catch |err| debug_trace.logf(
                "terminal_store",
                "committed monitor event cleanup deferred id={s} err={s}",
                .{ self.record.session_id, @errorName(err) },
            );
        }
        try self.retry_event_cleanup_locked();
        return event_id;
    }

    pub fn reconcile_monitor_commit(
        self: *DurableSession,
        candidate: monitor_core.PersistedSet,
    ) !MonitorCommitOutcome {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try inject_monitor_reconciliation_failure(self.profile);
        _ = try self.reconcile_monitor_transaction_locked();
        var current = try self.load_monitor_set_locked(self.profile.alloc, true);
        defer current.deinit();
        return if (try monitor_sets_equal(
            self.profile.alloc,
            current.parsed.value,
            candidate,
        ))
            .candidate
        else
            .previous;
    }

    pub fn commit_monitor_transition(
        self: *DurableSession,
        candidate: monitor_core.PersistedSet,
        notification: ?MonitorNotification,
        now_ms: i64,
    ) MonitorTransitionOutcome {
        return self.commit_monitor_transition_controlled(
            candidate,
            notification,
            now_ms,
            .{},
        );
    }

    pub fn commit_monitor_transition_controlled(
        self: *DurableSession,
        candidate: monitor_core.PersistedSet,
        notification: ?MonitorNotification,
        now_ms: i64,
        control: MonitorReconciliationControl,
    ) MonitorTransitionOutcome {
        if (notification) |event| {
            _ = self.commit_monitor_event(
                candidate,
                event.sequence,
                event.reason,
                now_ms,
            ) catch |err| {
                if (err == error.CloseIntentCommitted) {
                    return .{ .previous = err };
                }
                return self.prove_monitor_commit(candidate, err, control);
            };
        } else {
            self.persist_monitor_set(candidate, now_ms) catch |err| {
                if (err == error.CloseIntentCommitted) {
                    return .{ .previous = err };
                }
                return self.prove_monitor_commit(candidate, err, control);
            };
        }
        return .candidate;
    }

    fn prove_monitor_commit(
        self: *DurableSession,
        candidate: monitor_core.PersistedSet,
        commit_error: anyerror,
        control: MonitorReconciliationControl,
    ) MonitorTransitionOutcome {
        if (control.max_attempts == 0) {
            return .{ .indeterminate = error.InvalidReconciliationBound };
        }
        var attempt: u8 = 0;
        while (attempt < control.max_attempts) : (attempt += 1) {
            if (control.is_cancelled()) return .cancelled;
            const outcome = self.reconcile_monitor_commit(candidate) catch |err| {
                if (control.observed_attempts) |observed| {
                    observed.store(attempt + 1, .release);
                }
                debug_trace.logf(
                    "terminal_store",
                    "monitor reconciliation attempt={d}/{d} id={s} err={s}",
                    .{
                        attempt + 1,
                        control.max_attempts,
                        self.record.session_id,
                        @errorName(err),
                    },
                );
                if (attempt + 1 == control.max_attempts) {
                    return .{ .indeterminate = err };
                }
                if (control.is_cancelled()) return .cancelled;
                if (control.retry_delay_ms != 0) {
                    io_mod.getIo().sleep(
                        .fromMilliseconds(control.retry_delay_ms),
                        .awake,
                    ) catch |sleep_err| {
                        return .{ .indeterminate = sleep_err };
                    };
                }
                continue;
            };
            if (outcome == .previous) return .{ .previous = commit_error };
            return .candidate;
        }
        unreachable;
    }

    pub fn resize(
        self: *DurableSession,
        dimensions: contracts.Dimensions,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.retry_checkpoint_cleanup();
        try self.check_resize_capacity_locked(dimensions);
        const previous_reserve = if (is_live(self.record.lifecycle))
            @max(
                try checkpoint_reserve_bytes(self.record.dimensions),
                self.record.checkpoint_payload_bytes,
            )
        else
            self.record.checkpoint_payload_bytes;
        const next_reserve = if (is_live(self.record.lifecycle))
            @max(
                try checkpoint_reserve_bytes(dimensions),
                self.record.checkpoint_payload_bytes,
            )
        else
            self.record.checkpoint_payload_bytes;
        try self.profile.ensure_profile_capacity(
            next_reserve -| previous_reserve,
            self.record.session_id,
        );
        const previous_dimensions = self.record.dimensions;
        const previous_raw_replay_exact = self.record.raw_replay_exact;
        const previous_screen_recovery = self.record.screen_recovery;
        const previous_checkpoint_payload_bytes = self.record.checkpoint_payload_bytes;
        const previous_checkpoint_generation = self.record.checkpoint_generation;
        const previous_checkpoint_cleanup_generation = self.record.checkpoint_cleanup_generation;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.dimensions = dimensions;
        self.record.raw_replay_exact = false;
        self.record.screen_recovery = .{ .unavailable = .resize_uncheckpointed };
        self.record.checkpoint_payload_bytes = 0;
        self.record.checkpoint_generation = 0;
        self.record.checkpoint_cleanup_generation = if (previous_checkpoint_generation == 0)
            previous_checkpoint_cleanup_generation
        else
            previous_checkpoint_generation;
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.dimensions = previous_dimensions;
            self.record.raw_replay_exact = previous_raw_replay_exact;
            self.record.screen_recovery = previous_screen_recovery;
            self.record.checkpoint_payload_bytes = previous_checkpoint_payload_bytes;
            self.record.checkpoint_generation = previous_checkpoint_generation;
            self.record.checkpoint_cleanup_generation = previous_checkpoint_cleanup_generation;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
    }

    pub fn check_resize_capacity(
        self: *const DurableSession,
        dimensions: contracts.Dimensions,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.check_resize_capacity_locked(dimensions);
    }

    fn check_resize_capacity_locked(
        self: *const DurableSession,
        dimensions: contracts.Dimensions,
    ) !void {
        try dimensions.validate();
        const reserve = try checkpoint_reserve_bytes(dimensions);
        const session_after = std.math.add(
            u64,
            self.record.journal_payload_bytes,
            @max(reserve, self.record.checkpoint_payload_bytes),
        ) catch return error.CapacityExceeded;
        if (session_after > self.profile.options.per_session_limit) {
            return error.CapacityExceeded;
        }
    }

    pub fn persist_termination(
        self: *DurableSession,
        termination: PersistedTermination,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.reject_close_intent_locked();
        try termination.validate();
        if (self.profile.options.fail_at == .finalization) {
            return error.InjectedFailure;
        }
        const previous_lifecycle = self.record.lifecycle;
        const previous_termination = self.record.termination;
        const previous_updated_at_ms = self.record.updated_at_ms;
        if (self.record.lifecycle == .starting or self.record.lifecycle == .running) {
            self.record.lifecycle = try contracts.transition_lifecycle(
                self.record.lifecycle,
                .child_exited,
            );
        }
        self.record.termination = termination;
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.lifecycle = previous_lifecycle;
            self.record.termination = previous_termination;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        _ = try self.append_event_locked(.lifecycle, now_ms);
    }

    pub fn persist_lost(self: *DurableSession, now_ms: i64) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.reject_close_intent_locked();
        if (self.profile.options.fail_at == .finalization) {
            return error.InjectedFailure;
        }
        defer self.release_completed_handles_locked();
        const previous_lifecycle = self.record.lifecycle;
        const previous_updated_at_ms = self.record.updated_at_ms;
        if (self.record.lifecycle == .starting or self.record.lifecycle == .running) {
            self.record.lifecycle = try contracts.transition_lifecycle(
                self.record.lifecycle,
                .host_lost,
            );
        }
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.lifecycle = previous_lifecycle;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        _ = try self.append_event_locked(.lifecycle, now_ms);
    }

    pub fn revoke(self: *DurableSession, now_ms: i64) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.revoke_locked(now_ms);
    }

    fn revoke_locked(self: *DurableSession, now_ms: i64) !void {
        if (self.record.authority_revoked) {
            try self.persist_attention_locked(.{}, now_ms);
            return;
        }
        if (self.profile.options.fail_at == .revoke) return error.InjectedFailure;
        const authority = try load_authority(
            self.profile.alloc,
            try self.state_capability(),
            self.record.session_id,
        );
        defer authority.deinit();
        const next_generation = try self.record.authority_generation.next();
        const previous_generation = self.record.authority_generation;
        const previous_revoked = self.record.authority_revoked;
        const previous_attention = self.record.attention;
        const previous_owner_pid = self.record.takeover_owner_pid;
        const previous_owner_process_token = self.record.takeover_owner_process_token;
        const previous_updated_at_ms = self.record.updated_at_ms;
        var grant = authority.value.grant;
        grant.generation = next_generation;
        try write_authority(
            self.profile.alloc,
            try self.state_capability(),
            self.record.session_id,
            grant,
            authority.value.direct_human_model_read_only,
            .{ .bytes = @splat(1) },
            true,
        );
        if (self.profile.options.fail_at == .after_authority_write) {
            return error.InjectedCrash;
        }
        self.record.authority_generation = next_generation;
        self.record.authority_revoked = true;
        self.record.attention = .{};
        self.record.takeover_owner_pid = null;
        self.record.takeover_owner_process_token = null;
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.authority_generation = previous_generation;
            self.record.authority_revoked = previous_revoked;
            self.record.attention = previous_attention;
            self.record.takeover_owner_pid = previous_owner_pid;
            self.record.takeover_owner_process_token = previous_owner_process_token;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        if (previous_owner_process_token) |value| self.profile.alloc.free(value);
        if (previous_owner_pid) |value| self.profile.alloc.free(value);
        _ = try self.append_event_locked(.authority_revoked, now_ms);
    }

    pub fn begin_close(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        now_ms: i64,
    ) CloseCommitOutcome {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        claim.validate() catch |err| return .{ .previous = err };
        const capability = self.state_capability() catch |err| {
            return .{ .previous = err };
        };
        var existing = load_close_transaction(
            self.profile.alloc,
            capability,
            self.record.session_id,
        ) catch |err| return .{ .indeterminate = err };
        if (existing) |*transaction| {
            defer transaction.deinit();
            const expected = transaction.value.initiator_verifier orelse
                return .{ .previous = error.AuthorityRevoked };
            const actual = close_initiator_verifier(claim);
            if (!std.mem.eql(u8, &expected, &actual)) {
                return .{ .previous = error.InvalidHolderProof };
            }
            self.reconcile_close_authority_locked(
                capability,
                transaction.value,
            ) catch |err| return .{ .candidate = err };
            return .{ .candidate = null };
        }
        if (self.record.lifecycle == .closed) {
            return .{ .previous = error.AuthorityRevoked };
        }
        _ = self.reconcile_monitor_transaction_locked() catch |err| {
            return .{ .previous = err };
        };
        _ = self.authorize_locked(claim, .close) catch |err| {
            return .{ .previous = err };
        };
        if (self.profile.options.fail_at == .close) {
            return .{ .previous = error.InjectedFailure };
        }
        const authority_generation = self.record.authority_generation.next() catch |err| {
            return .{ .previous = err };
        };
        const transaction = CloseTransaction{
            .updated_at_ms = now_ms,
            .initiator_verifier = close_initiator_verifier(claim),
            .authority_generation = authority_generation,
            .authority_event = .{
                .id = self.record.next_event_id,
                .kind = .authority_revoked,
                .lifecycle = self.record.lifecycle,
                .cursor = self.record.output_cursor,
                .created_at_ms = now_ms,
            },
        };
        write_close_transaction(
            self.profile.alloc,
            capability,
            self.record.session_id,
            transaction,
        ) catch |err| return .{ .previous = err };
        self.reconcile_close_authority_locked(
            capability,
            transaction,
        ) catch |err| return .{ .candidate = err };
        return .{ .candidate = null };
    }

    fn reject_close_intent_locked(self: *DurableSession) !void {
        var transaction = (try load_close_transaction(
            self.profile.alloc,
            try self.state_capability(),
            self.record.session_id,
        )) orelse return;
        transaction.deinit();
        return error.CloseIntentCommitted;
    }

    pub fn finish_close(self: *DurableSession, now_ms: i64) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        if (try self.reconcile_close_transaction_locked(now_ms, true)) return;
        if (self.record.lifecycle != .closed) return error.CloseIntentNotFound;
        self.release_completed_handles_locked();
    }

    fn reconcile_close_transaction(self: *DurableSession, now_ms: i64) !bool {
        if (self.profile.options.fail_at == .before_close_recovery_oom) {
            return error.OutOfMemory;
        }
        if (self.profile.options.fail_at == .before_close_recovery_capability) {
            return error.PrivateStatePermissionsUnsupported;
        }
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        return self.reconcile_close_transaction_locked(now_ms, false);
    }

    fn reconcile_close_transaction_locked(
        self: *DurableSession,
        now_ms: i64,
        cleanup_transaction: bool,
    ) !bool {
        const capability = try self.state_capability();
        var parsed = (try load_close_transaction(
            self.profile.alloc,
            capability,
            self.record.session_id,
        )) orelse return false;
        defer parsed.deinit();
        try self.reconcile_close_authority_locked(capability, parsed.value);
        try self.finalize_close_monitors_locked(now_ms);

        if (parsed.value.lifecycle_event == null) {
            parsed.value.lifecycle_event = .{
                .id = self.record.next_event_id,
                .kind = .lifecycle,
                .lifecycle = .closed,
                .cursor = self.record.output_cursor,
                .created_at_ms = now_ms,
            };
            try write_close_transaction(
                self.profile.alloc,
                capability,
                self.record.session_id,
                parsed.value,
            );
        }
        const lifecycle_event = parsed.value.lifecycle_event.?;
        if (self.record.lifecycle != .closed) {
            const previous_lifecycle = self.record.lifecycle;
            const previous_updated_at_ms = self.record.updated_at_ms;
            self.record.lifecycle = try contracts.transition_lifecycle(
                self.record.lifecycle,
                .close,
            );
            self.record.updated_at_ms = now_ms;
            save_record(
                self.profile.alloc,
                capability,
                self.record,
            ) catch |err| {
                self.record.lifecycle = previous_lifecycle;
                self.record.updated_at_ms = previous_updated_at_ms;
                return err;
            };
        }
        if (closeFailureAt(self.profile, .after_close_lifecycle_record)) {
            return error.InjectedCrash;
        }
        try self.commit_close_event_locked(capability, lifecycle_event);
        if (closeFailureAt(self.profile, .after_close_lifecycle_event)) {
            return error.InjectedCrash;
        }
        if (!cleanup_transaction) return true;
        try delete_close_transaction(
            self.profile.alloc,
            capability,
            self.record.session_id,
        );
        self.release_completed_handles_locked();
        if (closeFailureAt(self.profile, .after_close_cleanup)) {
            return error.InjectedCrash;
        }
        return true;
    }

    fn finalize_close_monitors_locked(
        self: *DurableSession,
        now_ms: i64,
    ) !void {
        while (true) {
            _ = try self.reconcile_monitor_transaction_locked();
            var current = try self.load_monitor_set_locked(
                self.profile.alloc,
                true,
            );
            defer current.deinit();
            if (current.parsed.value.monitors.len == 0) return;

            const monitor = current.parsed.value.monitors[0];
            var candidate = try MonitorSet.clone(
                self.profile.alloc,
                current.parsed.value,
            );
            defer candidate.deinit();
            const monitors = candidate.parsed.value.monitors;
            std.mem.copyForwards(
                monitor_core.PersistedMonitor,
                monitors[0 .. monitors.len - 1],
                monitors[1..],
            );
            candidate.parsed.value.monitors = monitors[0 .. monitors.len - 1];

            var reason: ?monitor_core.EventReason = null;
            if (monitor.definition.notify_schedule == .on_exit and
                monitor.runtime.last_event_reason != .session_exit)
            {
                var observed = monitor;
                const decision = try monitor_core.observe(
                    &observed,
                    .session_exit,
                    false,
                    now_ms,
                );
                reason = decision.notify;
            }
            if (reason) |event_reason| {
                const sequence = monitor_sequence(monitor.monitor_id) orelse
                    return error.InvalidMonitorRecord;
                _ = try self.commit_monitor_event_locked(
                    candidate.parsed.value,
                    sequence,
                    event_reason,
                    now_ms,
                    .close,
                );
            } else {
                try self.persist_monitor_set_locked(
                    candidate.parsed.value,
                    now_ms,
                    .close,
                );
            }
        }
    }

    fn isolate_invalid_close_transaction(
        self: *DurableSession,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        const capability = try self.state_capability();
        var authority = try load_authority(
            self.profile.alloc,
            capability,
            self.record.session_id,
        );
        defer authority.deinit();
        try validate_recovery_principal(&self.record, &authority.value);
        const current_generation = @max(
            self.record.authority_generation.value,
            authority.value.grant.generation.value,
        );
        const authority_generation = (contracts.AuthorityGeneration{
            .value = current_generation,
        }).next() catch |err| return err;
        const transaction = CloseTransaction{
            .updated_at_ms = now_ms,
            .initiator_verifier = null,
            .authority_generation = authority_generation,
            .authority_event = .{
                .id = self.record.next_event_id,
                .kind = .authority_revoked,
                .lifecycle = self.record.lifecycle,
                .cursor = self.record.output_cursor,
                .created_at_ms = now_ms,
            },
        };
        try write_close_transaction(
            self.profile.alloc,
            capability,
            self.record.session_id,
            transaction,
        );
        _ = try self.reconcile_close_transaction_locked(now_ms, false);
    }

    pub fn close_cleanup_pending(self: *DurableSession) !bool {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        var transaction = try load_close_transaction(
            self.profile.alloc,
            try self.state_capability(),
            self.record.session_id,
        );
        defer if (transaction) |*value| value.deinit();
        return transaction != null;
    }

    fn reconcile_close_authority_locked(
        self: *DurableSession,
        capability: *session_child_store.SessionChildCapability,
        transaction: CloseTransaction,
    ) !void {
        var authority = try load_authority(
            self.profile.alloc,
            capability,
            self.record.session_id,
        );
        defer authority.deinit();
        try validate_recovery_principal(&self.record, &authority.value);
        if (authority.value.grant.generation.value >
            transaction.authority_generation.value)
        {
            return error.InvalidCloseTransaction;
        }
        if (authority.value.grant.generation.value <
            transaction.authority_generation.value or !authority.value.revoked)
        {
            var grant = authority.value.grant;
            grant.generation = transaction.authority_generation;
            try write_authority(
                self.profile.alloc,
                capability,
                self.record.session_id,
                grant,
                authority.value.direct_human_model_read_only,
                .{ .bytes = @splat(1) },
                true,
            );
        }
        if (closeFailureAt(self.profile, .after_close_authority_write)) {
            return error.InjectedCrash;
        }
        if (self.record.authority_generation.value >
            transaction.authority_generation.value)
        {
            return error.InvalidCloseTransaction;
        }
        if (self.record.authority_generation.value <
            transaction.authority_generation.value or
            !self.record.authority_revoked or
            !std.meta.eql(self.record.attention, contracts.AttentionState{}) or
            self.record.takeover_owner_pid != null or
            self.record.takeover_owner_process_token != null)
        {
            const previous_generation = self.record.authority_generation;
            const previous_revoked = self.record.authority_revoked;
            const previous_attention = self.record.attention;
            const previous_owner_pid = self.record.takeover_owner_pid;
            const previous_owner_process_token = self.record.takeover_owner_process_token;
            const previous_updated_at_ms = self.record.updated_at_ms;
            self.record.authority_generation = transaction.authority_generation;
            self.record.authority_revoked = true;
            self.record.attention = .{};
            self.record.takeover_owner_pid = null;
            self.record.takeover_owner_process_token = null;
            self.record.updated_at_ms = transaction.updated_at_ms;
            save_record(
                self.profile.alloc,
                capability,
                self.record,
            ) catch |err| {
                self.record.authority_generation = previous_generation;
                self.record.authority_revoked = previous_revoked;
                self.record.attention = previous_attention;
                self.record.takeover_owner_pid = previous_owner_pid;
                self.record.takeover_owner_process_token = previous_owner_process_token;
                self.record.updated_at_ms = previous_updated_at_ms;
                return err;
            };
            if (previous_owner_process_token) |value| self.profile.alloc.free(value);
            if (previous_owner_pid) |value| self.profile.alloc.free(value);
        }
        if (closeFailureAt(self.profile, .after_close_record_write)) {
            return error.InjectedCrash;
        }
        try self.commit_close_event_locked(capability, transaction.authority_event);
        if (closeFailureAt(self.profile, .after_close_authority_event)) {
            return error.InjectedCrash;
        }
    }

    fn commit_close_event_locked(
        self: *DurableSession,
        capability: *session_child_store.SessionChildCapability,
        event: DurableEvent,
    ) !void {
        const next_event_id = std.math.add(u64, event.id, 1) catch
            return error.EventIdExhausted;
        if (self.record.next_event_id < event.id) {
            return error.InvalidCloseTransaction;
        }
        const existing = load_event(
            self.profile.alloc,
            capability,
            self.record.session_id,
            event.id,
        ) catch |err| switch (err) {
            error.MissingDurableEvent => null,
            else => return err,
        };
        if (existing) |persisted| {
            if (!std.meta.eql(event, persisted)) return error.InvalidCloseTransaction;
        } else {
            if (self.record.next_event_id > event.id) {
                return error.InvalidCloseTransaction;
            }
            try self.write_event_value_locked(capability, event);
        }
        if (self.record.next_event_id >= next_event_id) return;
        const previous_gap = self.record.event_gap_through;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.next_event_id = next_event_id;
        if (event.id > event_retention_limit) {
            self.record.event_gap_through = @max(
                self.record.event_gap_through,
                event.id - event_retention_limit,
            );
        }
        self.record.updated_at_ms = event.created_at_ms;
        save_record(
            self.profile.alloc,
            capability,
            self.record,
        ) catch |err| {
            self.record.next_event_id = event.id;
            self.record.event_gap_through = previous_gap;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
    }

    pub fn verify_claim(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        action: contracts.Action,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        _ = try self.authorize_locked(claim, action);
    }

    pub fn authorize(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        action: contracts.Action,
    ) !Authorization {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        return self.authorize_locked(claim, action);
    }

    fn authorize_locked(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        action: contracts.Action,
    ) !Authorization {
        const authorization = try self.resolve_claim_locked(claim);
        if (!authorization.controls.allows(action)) return error.ControlDenied;
        if (authorization.actor == .human and
            self.record.attention.write_lease == .human)
        {
            try self.verify_takeover_owner_locked(claim.process_owner);
        }
        return authorization;
    }

    fn resolve_claim_locked(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
    ) !Authorization {
        _ = try self.reconcile_takeover_owner_locked(io_mod.milliTimestamp());
        const authority = try load_authority(
            self.profile.alloc,
            try self.state_capability(),
            self.record.session_id,
        );
        defer authority.deinit();
        const observer_policy = try verified_observer_policy(
            &self.record,
            &authority.value,
        );
        if (authority.value.revoked or self.record.authority_revoked) {
            return error.AuthorityRevoked;
        }
        const grant = authority.value.grant;
        const direct_model_observer = observer_policy and
            grant.actor == .human and claim.actor == .agent;
        const human_takeover = grant.actor == .agent and claim.actor == .human;
        const controls = if (direct_model_observer)
            contracts.AllowedControls.observer()
        else if (human_takeover)
            contracts.AllowedControls.humanTakeover()
        else
            grant.controls;
        try claim.validate();
        if (!grant.principal.eql(claim.principal)) {
            return error.PrincipalMismatch;
        }
        if (!direct_model_observer and !human_takeover and grant.actor != claim.actor) {
            return error.ActorRoleMismatch;
        }
        if (grant.generation.value != claim.generation.value) {
            return error.StaleAuthorityGeneration;
        }
        if (human_takeover) {
            verify_owner_catalog_claim(self.profile.alloc, self.profile, .{
                .principal = .{
                    .profile_user = claim.principal.profile_user,
                    .durable_session_id = claim.principal.durable_session_id,
                    .workspace_root = claim.principal.workspace_root,
                    .transport_role = claim.principal.transport_role,
                },
                .actor = .human,
                .proof = .{ .bytes = claim.proof.bytes },
            }) catch |err| switch (err) {
                error.OwnerCatalogAuthorityNotFound => return error.ActorRoleMismatch,
                else => return err,
            };
        } else {
            const actual = proof_verifier(
                claim.proof,
                authority.value.grant,
                observer_policy,
            );
            if (!std.mem.eql(u8, &actual, &authority.value.verifier)) {
                return error.InvalidHolderProof;
            }
        }
        return .{
            .actor = claim.actor,
            .controls = controls,
        };
    }

    pub fn acquire_write_lease(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        now_ms: i64,
    ) !Authorization {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        const authorization = try self.resolve_claim_locked(claim);
        const lease: contracts.WriteLease = switch (authorization.actor) {
            .human => .human,
            .agent => .agent,
        };
        if (self.record.attention.write_lease != .none and
            self.record.attention.write_lease != lease)
        {
            return error.LeaseConflict;
        }
        if (!authorization.controls.write) return error.ControlDenied;
        var attention = self.record.attention;
        attention.write_lease = lease;
        if (authorization.actor == .human) {
            const owner = claim.process_owner orelse
                return error.InvalidAuthorityClaim;
            if (self.record.attention.write_lease == .human and
                !takeover_owner_matches(self.record, &owner))
            {
                return error.LeaseConflict;
            }
            attention.attention = .user_takeover;
            try self.persist_attention_with_owner_locked(
                attention,
                &owner,
                now_ms,
            );
        } else {
            try self.persist_attention_locked(attention, now_ms);
        }
        return authorization;
    }

    pub fn cancel_claim(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        if (self.profile.options.fail_at == .cancellation) {
            return error.InjectedCancellationPersistenceFailure;
        }
        const authorization = try self.resolve_claim_locked(claim);
        if (authorization.actor == .human and
            self.record.attention.write_lease == .human)
        {
            try self.verify_takeover_owner_locked(claim.process_owner);
        }
        try self.persist_attention_locked(
            contracts.cancel_attention(self.record.attention, authorization.actor),
            now_ms,
        );
    }

    pub fn release_write_lease(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        now_ms: i64,
    ) !Authorization {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        const authorization = try self.authorize_locked(claim, .write);
        const lease: contracts.WriteLease = switch (authorization.actor) {
            .human => .human,
            .agent => .agent,
        };
        if (self.record.attention.write_lease != .none and
            self.record.attention.write_lease != lease)
        {
            return error.LeaseConflict;
        }
        try self.persist_attention_locked(
            contracts.cancel_attention(self.record.attention, authorization.actor),
            now_ms,
        );
        return authorization;
    }

    pub fn authorize_write(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
    ) !Authorization {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        const authorization = try self.authorize_locked(claim, .write);
        const lease: contracts.WriteLease = switch (authorization.actor) {
            .human => .human,
            .agent => .agent,
        };
        if (self.record.attention.write_lease != lease) {
            return error.LeaseConflict;
        }
        return authorization;
    }

    pub fn begin_wait(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        now_ms: i64,
    ) !Authorization {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        const authorization = try self.authorize_locked(claim, .wait);
        if (authorization.actor == .agent) {
            var attention = self.record.attention;
            attention.attention = .agent_wait;
            try self.persist_attention_locked(attention, now_ms);
        }
        return authorization;
    }

    pub fn finish_wait(
        self: *DurableSession,
        actor: contracts.ActorRole,
        cancelled: bool,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        var attention = self.record.attention;
        if (actor == .agent and attention.attention == .agent_wait) {
            attention.attention = .background;
        }
        if (cancelled) attention = contracts.cancel_attention(attention, actor);
        try self.persist_attention_locked(attention, now_ms);
    }

    pub fn revoke_claim(
        self: *DurableSession,
        claim: contracts.AuthorityClaim,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        _ = try self.authorize_locked(claim, .close);
        try self.revoke_locked(now_ms);
    }

    fn persist_attention_locked(
        self: *DurableSession,
        attention: contracts.AttentionState,
        now_ms: i64,
    ) !void {
        if (attention.write_lease == .human) {
            return self.persist_attention_state_locked(
                attention,
                self.record.takeover_owner_pid,
                self.record.takeover_owner_process_token,
                now_ms,
            );
        }
        return self.persist_attention_state_locked(attention, null, null, now_ms);
    }

    fn persist_attention_with_owner_locked(
        self: *DurableSession,
        attention: contracts.AttentionState,
        owner: *const contracts.ProcessOwner,
        now_ms: i64,
    ) !void {
        var pid_buffer: [32]u8 = undefined;
        const pid = try std.fmt.bufPrint(&pid_buffer, "{d}", .{owner.pid});
        return self.persist_attention_state_locked(
            attention,
            pid,
            owner.token(),
            now_ms,
        );
    }

    fn persist_attention_state_locked(
        self: *DurableSession,
        attention: contracts.AttentionState,
        takeover_owner_pid: ?[]const u8,
        takeover_owner_process_token: ?[]const u8,
        now_ms: i64,
    ) !void {
        try attention.validate();
        const owner_complete = takeover_owner_pid != null and
            takeover_owner_process_token != null;
        const human_takeover = attention.attention == .user_takeover and
            attention.write_lease == .human;
        if (owner_complete != human_takeover or
            ((takeover_owner_pid == null) !=
                (takeover_owner_process_token == null)))
        {
            return error.InvalidAttentionState;
        }
        const owner_unchanged = optional_text_eql(
            self.record.takeover_owner_pid,
            takeover_owner_pid,
        ) and optional_text_eql(
            self.record.takeover_owner_process_token,
            takeover_owner_process_token,
        );
        if (std.meta.eql(self.record.attention, attention) and owner_unchanged) return;

        const next_owner_pid = if (takeover_owner_pid) |value|
            try self.profile.alloc.dupe(u8, value)
        else
            null;
        errdefer if (next_owner_pid) |value| self.profile.alloc.free(value);
        const next_owner_process_token = if (takeover_owner_process_token) |value|
            try self.profile.alloc.dupe(u8, value)
        else
            null;
        errdefer if (next_owner_process_token) |value| self.profile.alloc.free(value);

        const previous_attention = self.record.attention;
        const previous_owner_pid = self.record.takeover_owner_pid;
        const previous_owner_process_token = self.record.takeover_owner_process_token;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.attention = attention;
        self.record.takeover_owner_pid = next_owner_pid;
        self.record.takeover_owner_process_token = next_owner_process_token;
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.attention = previous_attention;
            self.record.takeover_owner_pid = previous_owner_pid;
            self.record.takeover_owner_process_token = previous_owner_process_token;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        if (previous_owner_process_token) |value| self.profile.alloc.free(value);
        if (previous_owner_pid) |value| self.profile.alloc.free(value);
    }

    fn verify_takeover_owner_locked(
        self: *DurableSession,
        process_owner: ?contracts.ProcessOwner,
    ) !void {
        const owner = process_owner orelse return error.InvalidAuthorityClaim;
        if (!takeover_owner_matches(self.record, &owner)) {
            return error.LeaseConflict;
        }
    }

    fn reconcile_takeover_owner_locked(
        self: *DurableSession,
        now_ms: i64,
    ) !bool {
        return reconcile_takeover_owner_record(
            self.profile.alloc,
            self.profile.process_provider,
            try self.state_capability(),
            &self.record,
            now_ms,
        );
    }

    pub fn facts(self: *const DurableSession) contracts.SessionFacts {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        return facts_from_record(self.record, self.record.session_id);
    }

    pub fn available_cursor(self: *const DurableSession) contracts.RawCursor {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        return self.record.available_from;
    }

    pub fn output_cursor(self: *const DurableSession) contracts.RawCursor {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        return self.record.output_cursor;
    }

    pub fn checkpoint_due_cursor(self: *const DurableSession) ?contracts.RawCursor {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        const anchor = switch (self.record.screen_recovery) {
            .available => |checkpoint| checkpoint.applied_cursor,
            .unavailable => contracts.RawCursor{ .segment = 1, .offset = 0 },
        };
        const output = self.record.output_cursor;
        if (contracts.compare_raw_cursors(anchor, output) != .lt) return null;
        if (anchor.segment != output.segment or
            output.offset - anchor.offset >= self.profile.options.segment_bytes)
        {
            return output;
        }
        return null;
    }

    pub fn mark_screen_unavailable(
        self: *DurableSession,
        reason: contracts.ScreenUnavailableReason,
        now_ms: i64,
    ) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.mark_screen_unavailable_locked(reason, now_ms);
    }

    fn mark_screen_unavailable_locked(
        self: *DurableSession,
        reason: contracts.ScreenUnavailableReason,
        now_ms: i64,
    ) !void {
        if (self.record.checkpoint_generation == 0) {
            switch (self.record.screen_recovery) {
                .unavailable => |current| if (current == reason) return,
                .available => {},
            }
        }
        try self.retry_checkpoint_cleanup();
        const previous_recovery = self.record.screen_recovery;
        const previous_checkpoint_bytes = self.record.checkpoint_payload_bytes;
        const previous_generation = self.record.checkpoint_generation;
        const previous_cleanup_generation = self.record.checkpoint_cleanup_generation;
        const previous_updated_at_ms = self.record.updated_at_ms;
        self.record.screen_recovery = .{ .unavailable = reason };
        self.record.checkpoint_payload_bytes = 0;
        self.record.checkpoint_generation = 0;
        self.record.checkpoint_cleanup_generation = if (previous_generation == 0)
            previous_cleanup_generation
        else
            previous_generation;
        self.record.updated_at_ms = now_ms;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.screen_recovery = previous_recovery;
            self.record.checkpoint_payload_bytes = previous_checkpoint_bytes;
            self.record.checkpoint_generation = previous_generation;
            self.record.checkpoint_cleanup_generation = previous_cleanup_generation;
            self.record.updated_at_ms = previous_updated_at_ms;
            return err;
        };
        try self.retry_checkpoint_cleanup();
    }

    pub fn reconcile_checkpoint(self: *DurableSession) !void {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.retry_checkpoint_cleanup();
        switch (self.record.screen_recovery) {
            .unavailable => return,
            .available => {},
        }
        var checkpoint = self.load_checkpoint_locked(self.profile.alloc) catch |err| {
            const reason = checkpoint_load_unavailable_reason(err) orelse
                return err;
            try self.mark_screen_unavailable_locked(
                reason,
                io_mod.milliTimestamp(),
            );
            return;
        } orelse return;
        defer checkpoint.deinit(self.profile.alloc);
        if (!contiguous_after_checkpoint(
            checkpoint.envelope,
            self.record.available_from,
            self.record.output_cursor,
        )) {
            try self.mark_screen_unavailable_locked(.raw_gap, io_mod.milliTimestamp());
        }
    }

    fn reconcile_authority(self: *DurableSession) !bool {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        const authority = try load_authority(
            self.profile.alloc,
            try self.state_capability(),
            self.record.session_id,
        );
        defer authority.deinit();
        try validate_recovery_principal(&self.record, &authority.value);
        if (authority.value.grant.generation.value <
            self.record.authority_generation.value)
        {
            return error.InvalidAuthorityRecord;
        }
        if (self.record.authority_revoked and !authority.value.revoked) {
            return error.InvalidAuthorityRecord;
        }
        const authority_matches = authority.value.grant.generation.value ==
            self.record.authority_generation.value and
            authority.value.revoked == self.record.authority_revoked;
        const revoked_takeover = authority.value.revoked and
            (self.record.attention.attention == .user_takeover or
                self.record.attention.write_lease == .human or
                self.record.takeover_owner_pid != null or
                self.record.takeover_owner_process_token != null);
        if (authority_matches and !revoked_takeover) {
            try validate_recovery_authority(&self.record, &authority.value);
            return false;
        }
        const previous_generation = self.record.authority_generation;
        const previous_revoked = self.record.authority_revoked;
        const previous_attention = self.record.attention;
        const previous_owner_pid = self.record.takeover_owner_pid;
        const previous_owner_process_token = self.record.takeover_owner_process_token;
        self.record.authority_generation = authority.value.grant.generation;
        self.record.authority_revoked = authority.value.revoked;
        if (authority.value.revoked) {
            self.record.attention = .{};
            self.record.takeover_owner_pid = null;
            self.record.takeover_owner_process_token = null;
        }
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.authority_generation = previous_generation;
            self.record.authority_revoked = previous_revoked;
            self.record.attention = previous_attention;
            self.record.takeover_owner_pid = previous_owner_pid;
            self.record.takeover_owner_process_token = previous_owner_process_token;
            return err;
        };
        if (authority.value.revoked) {
            if (previous_owner_process_token) |value| self.profile.alloc.free(value);
            if (previous_owner_pid) |value| self.profile.alloc.free(value);
        }
        try validate_recovery_authority(&self.record, &authority.value);
        return true;
    }

    fn reconcile_unreferenced_artifacts(self: *DurableSession) !bool {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.retry_journal_cleanup();
        try self.retry_checkpoint_cleanup();
        const capability = try self.state_capability();
        var names = try capability.iterate(self.profile.alloc, .terminal_state);
        defer names.deinit();
        var repaired = false;
        for (names.names) |name| {
            if (indexed_artifact_id(
                name,
                "journal",
                self.record.session_id,
                ".bin",
            )) |file_id| {
                var referenced = false;
                for (self.record.journal_files) |file| {
                    if (file.file_id == file_id) {
                        referenced = true;
                        break;
                    }
                }
                if (referenced) continue;
            } else if (indexed_artifact_id(
                name,
                "checkpoint",
                self.record.session_id,
                ".bin",
            )) |generation| {
                if (generation == self.record.checkpoint_generation) continue;
            } else {
                continue;
            }
            capability.delete(.terminal_state, name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            repaired = true;
        }
        return repaired;
    }

    fn reconcile_events(self: *DurableSession) !bool {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        try self.retry_event_cleanup_locked();
        const capability = try self.state_capability();
        var names = try capability.iterate(self.profile.alloc, .terminal_state);
        defer names.deinit();
        var repaired = false;
        for (names.names) |name| {
            const id = indexed_artifact_id(
                name,
                "event",
                self.record.session_id,
                ".json",
            ) orelse continue;
            if (id < self.record.next_event_id) continue;
            capability.delete(.terminal_state, name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            repaired = true;
        }
        const cleanup_target = @max(
            self.record.acknowledged_event_id,
            self.record.event_gap_through,
        );
        var id = std.math.add(u64, cleanup_target, 1) catch
            return error.EventIdExhausted;
        var gap_through = self.record.event_gap_through;
        while (id < self.record.next_event_id) : (id += 1) {
            _ = load_event(
                self.profile.alloc,
                capability,
                self.record.session_id,
                id,
            ) catch {
                gap_through = id;
                repaired = true;
                continue;
            };
        }
        if (gap_through != self.record.event_gap_through) {
            self.record.event_gap_through = gap_through;
            try save_record(self.profile.alloc, capability, self.record);
            try self.retry_event_cleanup_locked();
        }
        return repaired;
    }

    fn reconcile_monitor_transaction(self: *DurableSession) !bool {
        const zio = io_mod.getIo();
        self.profile.mutex.lockUncancelable(zio);
        defer self.profile.mutex.unlock(zio);
        return self.reconcile_monitor_transaction_locked();
    }

    fn reconcile_monitor_transaction_locked(self: *DurableSession) !bool {
        const capability = try self.state_capability();
        var transaction = (try load_monitor_transaction(
            self.profile.alloc,
            capability,
            self.record.session_id,
        )) orelse {
            var set = try self.load_monitor_set_locked(self.profile.alloc, false);
            defer set.deinit();
            if (set.parsed.value.monitors.len == self.record.monitor_count) {
                return false;
            }
            self.record.monitor_count = @intCast(set.parsed.value.monitors.len);
            try save_record(self.profile.alloc, capability, self.record);
            return true;
        };
        defer transaction.deinit();

        var committed = transaction.value.committed;
        if (transaction.value.event) |expected| {
            const actual = load_event(
                self.profile.alloc,
                capability,
                self.record.session_id,
                expected.id,
            ) catch |err| switch (err) {
                error.MissingDurableEvent => null,
                else => return err,
            };
            if (actual) |event| {
                if (!std.meta.eql(expected, event)) {
                    return error.InvalidMonitorTransaction;
                }
                committed = true;
            }
        }

        if (committed) {
            try write_monitor_set(
                self.profile.alloc,
                capability,
                self.record.session_id,
                transaction.value.candidate,
            );
            try apply_monitor_transaction_record(
                &self.record,
                transaction.value,
            );
            try save_record(self.profile.alloc, capability, self.record);
        }
        try delete_monitor_transaction(
            self.profile.alloc,
            capability,
            self.record.session_id,
        );
        return true;
    }

    fn reconcile_journals(self: *DurableSession) !bool {
        try self.retry_journal_cleanup();
        if (self.record.journal_files.len == 0) return false;
        const alloc = self.profile.alloc;
        const valid = try alloc.alloc(bool, self.record.journal_files.len);
        defer alloc.free(valid);
        var corrupted = false;
        for (self.record.journal_files, 0..) |extent, index| {
            const name = try journal_name(alloc, self.record.session_id, extent.file_id);
            defer alloc.free(name);
            const capability = try self.state_capability();
            const stat = capability.stat(.terminal_state, name) catch {
                valid[index] = false;
                corrupted = true;
                continue;
            };
            if (stat.size > extent.payload_bytes) {
                capability.truncate(
                    .terminal_state,
                    name,
                    extent.payload_bytes,
                ) catch {
                    valid[index] = false;
                    corrupted = true;
                    continue;
                };
                corrupted = true;
            } else if (stat.size < extent.payload_bytes) {
                valid[index] = false;
                corrupted = true;
                continue;
            }
            var file = capability.openFileReadOnly(
                alloc,
                .terminal_state,
                name,
            ) catch {
                valid[index] = false;
                corrupted = true;
                continue;
            };
            defer file.deinit();
            const expected = std.math.cast(usize, extent.payload_bytes) orelse
                return error.CapacityExceeded;
            const bytes = file.readToEnd(alloc, expected + 1) catch {
                valid[index] = false;
                corrupted = true;
                continue;
            };
            defer alloc.free(bytes);
            const actual_checksum = contracts.checkpoint_checksum(bytes);
            valid[index] = bytes.len == expected and std.mem.eql(
                u8,
                &actual_checksum,
                &extent.checksum,
            );
            corrupted = corrupted or !valid[index];
        }
        if (!corrupted) return false;

        var first_retained = self.record.journal_files.len;
        while (first_retained != 0 and valid[first_retained - 1]) {
            first_retained -= 1;
        }
        const previous_files = self.record.journal_files;
        const retained = try alloc.dupe(JournalFile, previous_files[first_retained..]);
        errdefer alloc.free(retained);
        var retained_bytes: u64 = 0;
        for (retained) |extent| {
            retained_bytes = std.math.add(
                u64,
                retained_bytes,
                extent.payload_bytes,
            ) catch return error.CapacityExceeded;
        }
        const previous_available = self.record.available_from;
        const new_available = if (retained.len == 0)
            self.record.output_cursor
        else
            retained[0].range.start;
        self.record.journal_files = retained;
        self.record.available_from = new_available;
        self.record.raw_gap = if (contracts.compare_raw_cursors(
            previous_available,
            new_available,
        ) == .lt) .{
            .missing_from = previous_available,
            .available_from = new_available,
        } else self.record.raw_gap;
        self.record.journal_payload_bytes = retained_bytes;
        if (first_retained != 0) {
            self.record.journal_cleanup_through = @max(
                self.record.journal_cleanup_through,
                previous_files[first_retained - 1].file_id,
            );
        }
        switch (self.record.screen_recovery) {
            .available => |checkpoint| {
                if (contracts.compare_raw_cursors(
                    checkpoint.applied_cursor,
                    new_available,
                ) == .lt) {
                    self.record.screen_recovery = .{ .unavailable = .raw_gap };
                    self.record.checkpoint_cleanup_generation =
                        self.record.checkpoint_generation;
                    self.record.checkpoint_generation = 0;
                    self.record.checkpoint_payload_bytes = 0;
                }
            },
            .unavailable => {},
        }
        try save_record(alloc, try self.state_capability(), self.record);
        alloc.free(previous_files);
        try self.retry_journal_cleanup();
        try self.retry_checkpoint_cleanup();
        return true;
    }

    fn evict_completed_output(self: *DurableSession) !void {
        if (!is_completed(self.record.lifecycle) or
            self.record.journal_payload_bytes == 0)
        {
            return error.InvalidEviction;
        }
        try self.commit_journal_eviction(self.record.journal_files.len);
    }

    fn evict_completed_checkpoint(self: *DurableSession) !void {
        if (!is_completed(self.record.lifecycle) or
            self.record.checkpoint_payload_bytes == 0)
        {
            return error.InvalidEviction;
        }
        const generation = self.record.checkpoint_generation;
        const previous_recovery = self.record.screen_recovery;
        const previous_bytes = self.record.checkpoint_payload_bytes;
        const previous_cleanup = self.record.checkpoint_cleanup_generation;
        self.record.screen_recovery = .{ .unavailable = .retention_evicted };
        self.record.checkpoint_payload_bytes = 0;
        self.record.checkpoint_generation = 0;
        self.record.checkpoint_cleanup_generation = generation;
        save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.screen_recovery = previous_recovery;
            self.record.checkpoint_payload_bytes = previous_bytes;
            self.record.checkpoint_generation = generation;
            self.record.checkpoint_cleanup_generation = previous_cleanup;
            return err;
        };
        if (self.profile.options.fail_at == .after_eviction_record) {
            return error.InjectedCrash;
        }
        try self.retry_checkpoint_cleanup();
    }

    fn evict_live_covered_journals(self: *DurableSession) !void {
        if (!is_live(self.record.lifecycle)) return error.InvalidEviction;
        const checkpoint = switch (self.record.screen_recovery) {
            .unavailable => return error.InvalidEviction,
            .available => |value| value,
        };
        var remove_count: usize = 0;
        while (remove_count + 1 < self.record.journal_files.len) : (remove_count += 1) {
            const file = self.record.journal_files[remove_count];
            if (file.payload_bytes != self.profile.options.segment_bytes or
                contracts.compare_raw_cursors(
                    file.range.end,
                    checkpoint.applied_cursor,
                ) == .gt)
            {
                break;
            }
        }
        if (remove_count == 0) return error.InvalidEviction;
        try self.commit_journal_eviction(remove_count);
    }

    fn commit_journal_eviction(
        self: *DurableSession,
        remove_count: usize,
    ) !void {
        if (remove_count == 0 or remove_count > self.record.journal_files.len) {
            return error.InvalidEviction;
        }
        const alloc = self.profile.alloc;
        const previous_files = self.record.journal_files;
        const retained = try alloc.dupe(JournalFile, previous_files[remove_count..]);
        errdefer alloc.free(retained);
        var removed_bytes: u64 = 0;
        for (previous_files[0..remove_count]) |file| {
            removed_bytes = std.math.add(
                u64,
                removed_bytes,
                file.payload_bytes,
            ) catch return error.CapacityExceeded;
        }
        const previous_available = self.record.available_from;
        const previous_gap = self.record.raw_gap;
        const previous_journal_bytes = self.record.journal_payload_bytes;
        const previous_cleanup = self.record.journal_cleanup_through;
        const new_available = if (retained.len == 0)
            self.record.output_cursor
        else
            retained[0].range.start;
        self.record.journal_files = retained;
        self.record.available_from = new_available;
        self.record.raw_gap = .{
            .missing_from = previous_available,
            .available_from = new_available,
        };
        self.record.journal_payload_bytes -= removed_bytes;
        self.record.journal_cleanup_through = @max(
            previous_cleanup,
            previous_files[remove_count - 1].file_id,
        );
        save_record(
            alloc,
            try self.state_capability(),
            self.record,
        ) catch |err| {
            self.record.journal_files = previous_files;
            self.record.available_from = previous_available;
            self.record.raw_gap = previous_gap;
            self.record.journal_payload_bytes = previous_journal_bytes;
            self.record.journal_cleanup_through = previous_cleanup;
            return err;
        };
        alloc.free(previous_files);
        if (self.profile.options.fail_at == .after_eviction_record) {
            return error.InjectedCrash;
        }
        if (retained.len == 0) {
            if (self.journal) |*journal| journal.deinit();
            self.journal = null;
        }
        try self.retry_journal_cleanup();
    }

    fn retry_journal_cleanup(self: *DurableSession) !void {
        const through = self.record.journal_cleanup_through;
        if (through == 0) return;
        var file_id: u64 = 1;
        while (file_id <= through) : (file_id += 1) {
            const name = try journal_name(
                self.profile.alloc,
                self.record.session_id,
                file_id,
            );
            defer self.profile.alloc.free(name);
            (try self.state_capability()).delete(.terminal_state, name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            if (file_id == std.math.maxInt(u64)) break;
        }
        self.record.journal_cleanup_through = 0;
        try save_record(
            self.profile.alloc,
            try self.state_capability(),
            self.record,
        );
    }
};

pub fn checkpoint_load_unavailable_reason(
    err: anyerror,
) ?contracts.ScreenUnavailableReason {
    return switch (err) {
        error.MissingCheckpoint => .missing,
        error.UnsupportedCheckpointSchema => .unsupported_schema,
        error.CheckpointChecksumMismatch,
        error.CheckpointTooLarge,
        error.InvalidCheckpoint,
        error.StreamTooLong,
        => .corrupt,
        else => null,
    };
}

fn is_definitive_recovery_authority_error(err: anyerror) bool {
    return switch (err) {
        error.AuthorityNotFound,
        error.InvalidAuthorityRecord,
        error.HolderProofNotFound,
        error.InvalidHolderProof,
        error.AuthorityRevoked,
        error.SessionPathUnsafe,
        error.StreamTooLong,
        => true,
        else => false,
    };
}

fn facts_from_record(record: Record, session_id: []const u8) contracts.SessionFacts {
    const unread_range: ?contracts.RawRange = if (contracts.compare_raw_cursors(
        record.available_from,
        record.output_cursor,
    ) == .lt and record.available_from.segment == record.output_cursor.segment)
        .{
            .start = record.available_from,
            .end = record.output_cursor,
        }
    else
        null;
    return .{
        .session_id = session_id,
        .lifecycle = record.lifecycle,
        .attention = record.attention,
        .backend = record.backend,
        .output_cursor = record.output_cursor,
        .unread_range = unread_range,
        .raw_gap = record.raw_gap,
        .screen_recovery = record.screen_recovery,
        .active_monitor_count = record.monitor_count,
    };
}

fn cleanup_partial_start(
    alloc: Allocator,
    state: *session_child_store.SessionChildCapability,
    proofs: *session_child_store.SessionChildCapability,
    session_id: []const u8,
) void {
    cleanup_session_artifacts(alloc, state, proofs, session_id);
}

pub const Checkpoint = struct {
    envelope: contracts.CheckpointEnvelope,
    payload: []u8,

    pub fn deinit(self: *Checkpoint, alloc: Allocator) void {
        alloc.free(self.payload);
        self.* = undefined;
    }
};

pub fn checkpoint_reserve_bytes(
    dimensions: contracts.Dimensions,
) error{ InvalidDimensions, CapacityExceeded }!u64 {
    try dimensions.validate();
    const cells = std.math.mul(
        u64,
        dimensions.rows,
        dimensions.columns,
    ) catch return error.CapacityExceeded;
    const cell_bytes = std.math.mul(u64, cells, 16) catch
        return error.CapacityExceeded;
    return std.math.add(u64, cell_bytes, 64 * 1024) catch
        return error.CapacityExceeded;
}

pub fn contiguous_after_checkpoint(
    checkpoint: contracts.CheckpointEnvelope,
    available_from: contracts.RawCursor,
    output_cursor: contracts.RawCursor,
) bool {
    checkpoint.validate_header() catch return false;
    available_from.validate() catch return false;
    output_cursor.validate() catch return false;
    if (contracts.compare_raw_cursors(
        checkpoint.applied_cursor,
        output_cursor,
    ) == .gt) return false;
    return contracts.compare_raw_cursors(
        available_from,
        checkpoint.applied_cursor,
    ) != .gt;
}

fn save_record(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    record: Record,
) !void {
    try record.validate();
    const bytes = try render_json(alloc, record_wire(record));
    defer alloc.free(bytes);
    if (bytes.len > max_record_bytes) return error.TerminalRecordTooLarge;
    const name = try record_name(alloc, record.session_id);
    defer alloc.free(name);
    var entry = try capability.atomicReplace(
        alloc,
        .terminal_state,
        name,
        bytes,
    );
    entry.deinit(alloc);
}

fn load_record(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
) !Record {
    const name = try record_name(alloc, session_id);
    defer alloc.free(name);
    var file = capability.openFileReadOnly(
        alloc,
        .terminal_state,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.TerminalRecordNotFound,
        else => return err,
    };
    defer file.deinit();
    const bytes = file.readToEnd(alloc, max_record_bytes) catch |err| switch (err) {
        error.StreamTooLong => return error.TerminalRecordTooLarge,
        else => return err,
    };
    defer alloc.free(bytes);
    return parse_record(alloc, bytes);
}

fn write_owner_catalog_proof(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    name: []const u8,
    proof: contracts.OwnerCatalogProof,
) !void {
    try proof.validate();
    var entry = try capability.atomicReplace(
        alloc,
        .terminal_proofs,
        name,
        &proof.bytes,
    );
    entry.deinit(alloc);
}

fn read_owner_catalog_proof(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    name: []const u8,
) !contracts.OwnerCatalogProof {
    var file = capability.openFileReadOnly(
        alloc,
        .terminal_proofs,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.OwnerCatalogProofNotFound,
        else => return err,
    };
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, 33);
    defer {
        std.crypto.secureZero(u8, @volatileCast(bytes));
        alloc.free(bytes);
    }
    if (bytes.len != 32) return error.InvalidHolderProof;
    var proof = contracts.OwnerCatalogProof{ .bytes = undefined };
    @memcpy(&proof.bytes, bytes);
    try proof.validate();
    return proof;
}

fn write_owner_catalog_authority(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    name: []const u8,
    claim: contracts.OwnerCatalogAuthorityClaim,
) !void {
    try claim.validate();
    const bytes = try render_json(alloc, OwnerCatalogAuthorityWire{
        .principal = claim.principal,
        .actor = claim.actor,
        .verifier = owner_catalog_verifier(claim),
    });
    defer alloc.free(bytes);
    var entry = try capability.atomicReplace(
        alloc,
        .terminal_state,
        name,
        bytes,
    );
    entry.deinit(alloc);
}

fn load_owner_catalog_authority(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    name: []const u8,
) !std.json.Parsed(OwnerCatalogAuthorityWire) {
    var file = capability.openFileReadOnly(
        alloc,
        .terminal_state,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.OwnerCatalogAuthorityNotFound,
        else => return err,
    };
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, max_record_bytes);
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(
        OwnerCatalogAuthorityWire,
        alloc,
        bytes,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAuthorityRecord,
    };
    errdefer parsed.deinit();
    if (parsed.value.schema_version != owner_catalog_authority_schema_version) {
        return error.TerminalAuthorityRetired;
    }
    parsed.value.principal.validate() catch return error.InvalidAuthorityRecord;
    return parsed;
}

fn write_proof(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
    proof: contracts.HolderProof,
) !void {
    try proof.validate();
    const name = try proof_name(alloc, session_id);
    defer alloc.free(name);
    var entry = try capability.atomicReplace(
        alloc,
        .terminal_proofs,
        name,
        &proof.bytes,
    );
    entry.deinit(alloc);
}

fn read_proof(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
) !contracts.HolderProof {
    const name = try proof_name(alloc, session_id);
    defer alloc.free(name);
    var file = capability.openFileReadOnly(
        alloc,
        .terminal_proofs,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.HolderProofNotFound,
        else => return err,
    };
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, 33);
    defer {
        std.crypto.secureZero(u8, @volatileCast(bytes));
        alloc.free(bytes);
    }
    if (bytes.len != 32) return error.InvalidHolderProof;
    var proof = contracts.HolderProof{ .bytes = undefined };
    @memcpy(&proof.bytes, bytes);
    try proof.validate();
    return proof;
}

fn write_authority(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
    grant: contracts.AuthorityGrant,
    direct_human_model_read_only: bool,
    proof: contracts.HolderProof,
    revoked: bool,
) !void {
    try grant.validate();
    if (direct_human_model_read_only and grant.actor != .human) {
        return error.InvalidAuthorityRecord;
    }
    const bytes = try render_json(alloc, AuthorityWire{
        .session_id = session_id,
        .grant = grant,
        .direct_human_model_read_only = direct_human_model_read_only,
        .verifier = proof_verifier(
            proof,
            grant,
            direct_human_model_read_only,
        ),
        .revoked = revoked,
    });
    defer alloc.free(bytes);
    const name = try authority_name(alloc, session_id);
    defer alloc.free(name);
    var entry = try capability.atomicReplace(
        alloc,
        .terminal_state,
        name,
        bytes,
    );
    entry.deinit(alloc);
}

fn load_authority(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
) !std.json.Parsed(AuthorityWire) {
    const name = try authority_name(alloc, session_id);
    defer alloc.free(name);
    var file = capability.openFileReadOnly(
        alloc,
        .terminal_state,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.AuthorityNotFound,
        else => return err,
    };
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, max_record_bytes);
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(
        AuthorityWire,
        alloc,
        bytes,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAuthorityRecord,
    };
    errdefer parsed.deinit();
    if (parsed.value.schema_version != authority_schema_version) {
        return error.TerminalAuthorityRetired;
    }
    if (!std.mem.eql(u8, parsed.value.session_id, session_id)) {
        return error.InvalidAuthorityRecord;
    }
    parsed.value.grant.validate() catch return error.InvalidAuthorityRecord;
    if (parsed.value.direct_human_model_read_only and
        parsed.value.grant.actor != .human)
    {
        return error.InvalidAuthorityRecord;
    }
    return parsed;
}

fn verified_observer_policy(
    record: *const Record,
    authority: *const AuthorityWire,
) error{InvalidAuthorityRecord}!bool {
    if (record.direct_human_model_read_only !=
        authority.direct_human_model_read_only)
    {
        return error.InvalidAuthorityRecord;
    }
    return authority.direct_human_model_read_only;
}

fn validate_recovery_principal(
    record: *const Record,
    authority: *const AuthorityWire,
) error{InvalidAuthorityRecord}!void {
    _ = try verified_observer_policy(record, authority);
    const principal = authority.grant.principal;
    if (!std.mem.eql(u8, record.session_id, authority.session_id) or
        !std.mem.eql(u8, record.owner_session_id, principal.durable_session_id) or
        !std.mem.eql(u8, record.cwd, principal.cwd) or
        record.backend != principal.backend or
        principal.lifetime != .session or
        !std.fs.path.isAbsolute(principal.workspace_root))
    {
        return error.InvalidAuthorityRecord;
    }
}

fn validate_recovery_authority(
    record: *const Record,
    authority: *const AuthorityWire,
) error{InvalidAuthorityRecord}!void {
    try validate_recovery_principal(record, authority);
    if (record.authority_generation.value != authority.grant.generation.value or
        record.authority_revoked != authority.revoked)
    {
        return error.InvalidAuthorityRecord;
    }
}

fn validate_repeated_probe_authority(
    grant: contracts.AuthorityGrant,
    definition: contracts.MonitorDefinition,
) !void {
    if (definition.condition != .custom_probe) return;
    for (grant.repeated_probes) |authority| {
        if (authority.matches(definition)) return;
    }
    return error.ProbeAuthorityDenied;
}

fn write_initial_monitors(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
    monitors: []const contracts.MonitorDefinition,
    now_ms: i64,
) !void {
    if (monitors.len > contracts.max_monitor_definitions) {
        return error.InvalidMonitor;
    }
    var id_buffers: [contracts.max_monitor_definitions][64]u8 = undefined;
    var persisted: [contracts.max_monitor_definitions]monitor_core.PersistedMonitor = undefined;
    for (monitors, 0..) |definition, index| {
        try monitor_core.validate_definition(definition);
        const sequence: u64 = @intCast(index + 1);
        persisted[index] = .{
            .monitor_id = try monitor_core.stable_id(&id_buffers[index], sequence),
            .definition = definition,
            .runtime = try monitor_core.initial_runtime(definition, now_ms),
        };
    }
    const next_monitor_id = std.math.add(u64, @intCast(monitors.len), 1) catch
        return error.MonitorIdExhausted;
    const set = monitor_core.PersistedSet{
        .next_monitor_id = next_monitor_id,
        .monitors = persisted[0..monitors.len],
    };
    try ensure_monitor_set_admissible(alloc, set);
    const bytes = try render_json(alloc, set);
    defer alloc.free(bytes);
    const name = try monitors_name(alloc, session_id);
    defer alloc.free(name);
    var entry = try capability.atomicReplace(
        alloc,
        .terminal_state,
        name,
        bytes,
    );
    entry.deinit(alloc);
}

fn ensure_monitor_set_fits(
    alloc: Allocator,
    set: monitor_core.PersistedSet,
) !void {
    try validate_monitor_set(set);
    const bytes = try render_json(alloc, set);
    defer alloc.free(bytes);
    try ensure_monitor_set_bytes_fit(bytes);
}

fn ensure_monitor_set_admissible(
    alloc: Allocator,
    set: monitor_core.PersistedSet,
) !void {
    try validate_monitor_set(set);
    const bytes = try render_json(alloc, set);
    defer alloc.free(bytes);
    if (bytes.len > monitor_admission_bytes_limit) {
        return error.MonitorStateTooLarge;
    }
}

fn ensure_monitor_transaction_fits(
    alloc: Allocator,
    transaction: MonitorTransaction,
) !void {
    try transaction.validate();
    const bytes = try render_json(alloc, transaction);
    defer alloc.free(bytes);
    try ensure_monitor_transaction_bytes_fit(bytes);
}

fn monitor_sets_equal(
    alloc: Allocator,
    left: monitor_core.PersistedSet,
    right: monitor_core.PersistedSet,
) !bool {
    const left_bytes = try render_json(alloc, left);
    defer alloc.free(left_bytes);
    const right_bytes = try render_json(alloc, right);
    defer alloc.free(right_bytes);
    return std.mem.eql(u8, left_bytes, right_bytes);
}

fn ensure_monitor_set_bytes_fit(bytes: []const u8) !void {
    if (bytes.len > monitor_set_bytes_limit) {
        return error.MonitorStateTooLarge;
    }
}

fn ensure_monitor_transaction_bytes_fit(bytes: []const u8) !void {
    if (bytes.len > monitor_transaction_bytes_limit) {
        return error.MonitorStateTooLarge;
    }
}

fn inject_monitor_reconciliation_failure(profile: *ProfileStore) !void {
    const failure = profile.options.fail_monitor_reconciliation_once orelse
        return;
    if (profile.monitor_reconciliation_failure_count >=
        profile.options.fail_monitor_reconciliation_count)
    {
        return;
    }
    profile.monitor_reconciliation_failure_count += 1;
    const requested = @tagName(failure);
    if (std.mem.eql(u8, requested, "allocation")) return error.OutOfMemory;
    if (std.mem.eql(u8, requested, "io")) return error.SessionChildStoreFailed;
    if (std.mem.eql(u8, requested, "indeterminate")) {
        return error.SessionChildCommitIndeterminate;
    }
}

fn monitorFailureAt(
    profile: *ProfileStore,
    point: FailurePoint,
) bool {
    return profile.options.fail_at == point;
}

fn closeFailureAt(profile: *ProfileStore, point: FailurePoint) bool {
    return profile.options.fail_at == point;
}

fn write_monitor_set(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
    set: monitor_core.PersistedSet,
) !void {
    try validate_monitor_set(set);
    const bytes = try render_json(alloc, set);
    defer alloc.free(bytes);
    try ensure_monitor_set_bytes_fit(bytes);
    const name = try monitors_name(alloc, session_id);
    defer alloc.free(name);
    var entry = try capability.atomicReplace(
        alloc,
        .terminal_state,
        name,
        bytes,
    );
    entry.deinit(alloc);
}

fn validate_monitor_set(set: monitor_core.PersistedSet) !void {
    if (set.schema_version != monitor_core.schema_version or
        set.next_monitor_id == 0 or
        set.monitors.len > contracts.max_monitor_definitions)
    {
        return error.InvalidMonitorRecord;
    }
    var previous_sequence: u64 = 0;
    for (set.monitors) |persisted| {
        try monitor_core.validate_runtime(persisted);
        const sequence = monitor_sequence(persisted.monitor_id) orelse
            return error.InvalidMonitorRecord;
        if (sequence <= previous_sequence or sequence >= set.next_monitor_id) {
            return error.InvalidMonitorRecord;
        }
        previous_sequence = sequence;
    }
}

fn write_monitor_transaction(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
    transaction: MonitorTransaction,
) !void {
    try transaction.validate();
    const bytes = try render_json(alloc, transaction);
    defer alloc.free(bytes);
    try ensure_monitor_transaction_bytes_fit(bytes);
    const name = try monitor_transaction_name(alloc, session_id);
    defer alloc.free(name);
    var entry = try capability.atomicReplace(
        alloc,
        .terminal_state,
        name,
        bytes,
    );
    entry.deinit(alloc);
}

fn load_monitor_transaction(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
) !?std.json.Parsed(MonitorTransaction) {
    const name = try monitor_transaction_name(alloc, session_id);
    defer alloc.free(name);
    var file = capability.openFileReadOnly(
        alloc,
        .terminal_state,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, monitor_transaction_bytes_limit);
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(
        MonitorTransaction,
        alloc,
        bytes,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidMonitorTransaction,
    };
    errdefer parsed.deinit();
    parsed.value.validate() catch return error.InvalidMonitorTransaction;
    return parsed;
}

fn delete_monitor_transaction(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
) !void {
    const name = try monitor_transaction_name(alloc, session_id);
    defer alloc.free(name);
    capability.delete(.terminal_state, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn write_close_transaction(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
    transaction: CloseTransaction,
) !void {
    try transaction.validate();
    const bytes = try render_json(alloc, transaction);
    defer alloc.free(bytes);
    if (bytes.len > max_event_bytes) return error.CloseTransactionTooLarge;
    const name = try close_transaction_name(alloc, session_id);
    defer alloc.free(name);
    var entry = try capability.atomicReplace(
        alloc,
        .terminal_state,
        name,
        bytes,
    );
    entry.deinit(alloc);
}

fn load_close_transaction(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
) !?std.json.Parsed(CloseTransaction) {
    const name = try close_transaction_name(alloc, session_id);
    defer alloc.free(name);
    var file = capability.openFileReadOnly(
        alloc,
        .terminal_state,
        name,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.deinit();
    const bytes = try file.readToEnd(alloc, max_event_bytes);
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(
        CloseTransaction,
        alloc,
        bytes,
        .{ .allocate = .alloc_always },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCloseTransaction,
    };
    errdefer parsed.deinit();
    parsed.value.validate() catch return error.InvalidCloseTransaction;
    return parsed;
}

fn delete_close_transaction(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
    session_id: []const u8,
) !void {
    const name = try close_transaction_name(alloc, session_id);
    defer alloc.free(name);
    capability.delete(.terminal_state, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn apply_monitor_transaction_record(
    record: *Record,
    transaction: MonitorTransaction,
) !void {
    record.monitor_count = std.math.cast(
        u16,
        transaction.candidate.monitors.len,
    ) orelse return error.InvalidMonitorTransaction;
    record.updated_at_ms = transaction.updated_at_ms;
    if (transaction.event) |event| {
        const next_event_id = std.math.add(u64, event.id, 1) catch
            return error.EventIdExhausted;
        if (record.next_event_id > event.id) {
            if (record.next_event_id != next_event_id) {
                return error.InvalidMonitorTransaction;
            }
            return;
        }
        if (record.next_event_id != event.id) {
            return error.InvalidMonitorTransaction;
        }
        record.next_event_id = next_event_id;
        if (event.id > event_retention_limit) {
            record.event_gap_through = @max(
                record.event_gap_through,
                event.id - event_retention_limit,
            );
        }
    }
}

fn monitor_sequence(monitor_id: []const u8) ?u64 {
    const prefix = "monitor-";
    if (!std.mem.startsWith(u8, monitor_id, prefix)) return null;
    const raw = monitor_id[prefix.len..];
    if (raw.len == 0 or raw[0] == '0') return null;
    return std.fmt.parseInt(u64, raw, 10) catch null;
}

fn find_monitor_by_sequence(
    monitors: []const monitor_core.PersistedMonitor,
    sequence: u64,
) ?*const monitor_core.PersistedMonitor {
    for (monitors) |*monitor| {
        if (monitor_sequence(monitor.monitor_id) == sequence) return monitor;
    }
    return null;
}

fn find_monitor_by_sequence_mut(
    monitors: []monitor_core.PersistedMonitor,
    sequence: u64,
) ?*monitor_core.PersistedMonitor {
    for (monitors) |*monitor| {
        if (monitor_sequence(monitor.monitor_id) == sequence) return monitor;
    }
    return null;
}

fn encode_checkpoint(
    alloc: Allocator,
    envelope: contracts.CheckpointEnvelope,
    payload: []const u8,
) ![]u8 {
    try envelope.validate(payload);
    const total = std.math.add(
        usize,
        checkpoint_header_bytes,
        payload.len,
    ) catch return error.CheckpointTooLarge;
    const bytes = try alloc.alloc(u8, total);
    errdefer alloc.free(bytes);
    @memcpy(bytes[0..4], checkpoint_magic);
    std.mem.writeInt(u16, bytes[4..6], checkpoint_schema_version, .little);
    std.mem.writeInt(u16, bytes[6..8], envelope.engine_schema_revision, .little);
    std.mem.writeInt(u64, bytes[8..16], envelope.applied_cursor.segment, .little);
    std.mem.writeInt(u64, bytes[16..24], envelope.applied_cursor.offset, .little);
    std.mem.writeInt(u32, bytes[24..28], envelope.payload_len, .little);
    @memcpy(bytes[28..60], &envelope.checksum);
    @memcpy(bytes[checkpoint_header_bytes..], payload);
    return bytes;
}

fn decode_checkpoint(alloc: Allocator, bytes: []const u8) !Checkpoint {
    if (bytes.len < checkpoint_header_bytes or
        !std.mem.eql(u8, bytes[0..4], checkpoint_magic))
    {
        return error.InvalidCheckpoint;
    }
    const schema_version = std.mem.readInt(u16, bytes[4..6], .little);
    if (schema_version != checkpoint_schema_version) {
        return error.UnsupportedCheckpointSchema;
    }
    const engine_revision = std.mem.readInt(u16, bytes[6..8], .little);
    const payload_len = std.mem.readInt(u32, bytes[24..28], .little);
    if (payload_len > contracts.max_checkpoint_payload_bytes) {
        return error.CheckpointTooLarge;
    }
    const expected = std.math.add(
        usize,
        checkpoint_header_bytes,
        payload_len,
    ) catch return error.CheckpointTooLarge;
    if (bytes.len != expected) return error.InvalidCheckpoint;
    var checksum: contracts.CheckpointChecksum = undefined;
    @memcpy(&checksum, bytes[28..60]);
    const envelope = contracts.CheckpointEnvelope{
        .engine_schema_revision = engine_revision,
        .applied_cursor = .{
            .segment = std.mem.readInt(u64, bytes[8..16], .little),
            .offset = std.mem.readInt(u64, bytes[16..24], .little),
        },
        .payload_len = payload_len,
        .checksum = checksum,
    };
    const payload = try alloc.dupe(u8, bytes[checkpoint_header_bytes..]);
    errdefer alloc.free(payload);
    try envelope.validate(payload);
    return .{ .envelope = envelope, .payload = payload };
}

fn checkpoint_envelopes_equal(
    left: contracts.CheckpointEnvelope,
    right: contracts.CheckpointEnvelope,
) bool {
    return left.engine_schema_revision == right.engine_schema_revision and
        contracts.compare_raw_cursors(
            left.applied_cursor,
            right.applied_cursor,
        ) == .eq and
        left.payload_len == right.payload_len and
        std.mem.eql(u8, &left.checksum, &right.checksum);
}

test "checkpoint load classification passes transient failures through" {
    try std.testing.expectEqual(
        contracts.ScreenUnavailableReason.missing,
        checkpoint_load_unavailable_reason(error.MissingCheckpoint).?,
    );
    try std.testing.expectEqual(
        contracts.ScreenUnavailableReason.unsupported_schema,
        checkpoint_load_unavailable_reason(error.UnsupportedCheckpointSchema).?,
    );
    try std.testing.expectEqual(
        contracts.ScreenUnavailableReason.corrupt,
        checkpoint_load_unavailable_reason(error.CheckpointChecksumMismatch).?,
    );
    try std.testing.expect(
        checkpoint_load_unavailable_reason(error.OutOfMemory) == null,
    );
    try std.testing.expect(
        checkpoint_load_unavailable_reason(error.AccessDenied) == null,
    );
}

test "recovery authority classification isolates only definitive evidence" {
    const definitive = [_]anyerror{
        error.AuthorityNotFound,
        error.InvalidAuthorityRecord,
        error.HolderProofNotFound,
        error.InvalidHolderProof,
        error.AuthorityRevoked,
        error.SessionPathUnsafe,
        error.StreamTooLong,
    };
    for (definitive) |err| {
        try std.testing.expect(is_definitive_recovery_authority_error(err));
    }

    const transient = [_]anyerror{
        error.OutOfMemory,
        error.AccessDenied,
        error.SessionChildStoreFailed,
        error.PrivateStatePermissionsUnsupported,
        error.InjectedFailure,
        error.InjectedSyncFailure,
        error.UnclassifiedRecoveryFailure,
    };
    for (transient) |err| {
        try std.testing.expect(!is_definitive_recovery_authority_error(err));
    }
}

test "close recovery classification isolates only malformed durable evidence" {
    for ([_]anyerror{
        error.InvalidCloseTransaction,
        error.StreamTooLong,
    }) |err| {
        try std.testing.expectEqual(
            CloseRecoveryErrorClass.isolate,
            classify_close_recovery_error(err),
        );
    }
    for ([_]anyerror{
        error.OutOfMemory,
        error.AccessDenied,
        error.PrivateStatePermissionsUnsupported,
        error.SessionChildStoreFailed,
        error.InjectedCrash,
        error.TmuxCommandFailed,
        error.UnclassifiedRecoveryFailure,
    }) |err| {
        try std.testing.expectEqual(
            CloseRecoveryErrorClass.propagate,
            classify_close_recovery_error(err),
        );
    }
}

const test_process_provider = background_process_provider.Provider{
    .spawn_prepared_fn = testSpawnPrepared,
    .capture_token_fn = testCaptureToken,
    .match_token_fn = testMatchToken,
    .signal_process_fn = testSignalProcess,
};

fn testSpawnPrepared(
    _: ?*anyopaque,
    _: Allocator,
    _: background_process_provider.SpawnRequest,
) background_process_provider.ProviderError!background_process_provider.PreparedProcess {
    return error.Unsupported;
}

fn testCaptureToken(
    _: ?*anyopaque,
    _: Allocator,
    _: []const u8,
) background_process_provider.ProviderError!process_supervisor.ProcessInstanceToken {
    return process_supervisor.ProcessInstanceToken.parse(
        "macos:00000000000000000000000000000000:1:2",
    ) catch unreachable;
}

fn testMatchToken(
    _: ?*anyopaque,
    _: Allocator,
    _: []const u8,
    _: process_supervisor.ProcessInstanceToken,
) process_supervisor.TokenMatch {
    return .matched;
}

fn testSignalProcess(
    _: ?*anyopaque,
    _: Allocator,
    _: []const u8,
    _: process_supervisor.ProcessInstanceToken,
) background_process_provider.ProviderError!void {
    return error.Unsupported;
}

const TestStoreFixture = struct {
    alloc: Allocator,
    tmp: std.testing.TmpDir,
    home: []u8,
    profile: ProfileStore,

    fn init(alloc: Allocator, options: Options) !TestStoreFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        errdefer alloc.free(home);
        var root = io_mod.VerifiedDir{ .dir = try tmp.dir.openDir(
            std.testing.io,
            ".",
            .{ .iterate = true, .follow_symlinks = false },
        ) };
        defer root.close();
        var fx = try io_mod.openOrCreateVerifiedPrivateDir(&root, ".fx");
        defer fx.close();
        var sessions = try io_mod.openOrCreateVerifiedPrivateDir(&fx, "sessions");
        defer sessions.close();
        var owner = try io_mod.openOrCreateVerifiedPrivateDir(
            &sessions,
            "terminal-store-owner",
        );
        owner.close();
        return .{
            .alloc = alloc,
            .tmp = tmp,
            .home = home,
            .profile = try ProfileStore.init_with_options(
                alloc,
                home,
                test_process_provider,
                options,
            ),
        };
    }

    fn deinit(self: *TestStoreFixture) void {
        self.profile.deinit();
        self.alloc.free(self.home);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn reopen(self: *TestStoreFixture) !void {
        const options = self.profile.options;
        const process_provider = self.profile.process_provider;
        self.profile.deinit();
        self.profile = try ProfileStore.init_with_options(
            self.alloc,
            self.home,
            process_provider,
            options,
        );
    }

    fn owner_capability(
        self: *TestStoreFixture,
        owner_session_id: []const u8,
        mode: session_child_store.Mode,
    ) !session_child_store.SessionChildCapability {
        var owner_dir = try self.profile.sessions_dir.dir.openDir(
            io_mod.getIo(),
            owner_session_id,
            .{ .iterate = true, .follow_symlinks = false },
        );
        defer owner_dir.close(io_mod.getIo());
        const display_path = try session_layout.sessionDirPath(
            self.alloc,
            self.profile.display_sessions_path,
            owner_session_id,
        );
        defer self.alloc.free(display_path);
        return session_child_store.SessionChildCapability.init(
            self.alloc,
            owner_dir,
            display_path,
            mode,
        );
    }

    fn create_owner(self: *TestStoreFixture, owner_session_id: []const u8) !void {
        var owner = try io_mod.openOrCreateVerifiedPrivateDir(
            &self.profile.sessions_dir,
            owner_session_id,
        );
        owner.close();
    }

    fn create(self: *TestStoreFixture, session_id: []const u8) !DurableSession {
        return self.create_with_dimensions(session_id, .{ .rows = 24, .columns = 80 });
    }

    fn create_with_dimensions(
        self: *TestStoreFixture,
        session_id: []const u8,
        dimensions: contracts.Dimensions,
    ) !DurableSession {
        return self.create_with_monitors(session_id, dimensions, &.{});
    }

    fn create_with_monitors(
        self: *TestStoreFixture,
        session_id: []const u8,
        dimensions: contracts.Dimensions,
        monitors: []const contracts.MonitorDefinition,
    ) !DurableSession {
        return self.create_with_persistence(
            session_id,
            dimensions,
            monitors,
            test_persistence(),
        );
    }

    fn create_with_persistence(
        self: *TestStoreFixture,
        session_id: []const u8,
        dimensions: contracts.Dimensions,
        monitors: []const contracts.MonitorDefinition,
        persistence: contracts.StartPersistence,
    ) !DurableSession {
        return DurableSession.create(&self.profile, .{
            .session_id = session_id,
            .host_identity = "host-one",
            .shell = "/bin/zsh",
            .cwd = "/workspace",
            .command = "printf ready",
            .backend = .native,
            .dimensions = dimensions,
            .persistence = persistence,
            .initial_monitors = monitors,
            .now_ms = 1,
        });
    }

    fn create_tmux(self: *TestStoreFixture, session_id: []const u8) !DurableSession {
        var persistence = test_persistence();
        persistence.grant.principal.backend = .tmux;
        return DurableSession.create(&self.profile, .{
            .session_id = session_id,
            .host_identity = "host-one",
            .shell = "/bin/zsh",
            .cwd = "/workspace",
            .command = "printf ready",
            .backend = .tmux,
            .dimensions = .{ .rows = 24, .columns = 80 },
            .persistence = persistence,
            .initial_monitors = &.{},
            .now_ms = 1,
        });
    }
};

const OneShotFailingAllocator = struct {
    failing: std.testing.FailingAllocator,

    fn init(alloc: Allocator) OneShotFailingAllocator {
        return .{ .failing = .init(alloc, .{}) };
    }

    fn allocator(self: *OneShotFailingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocate,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn allocate(
        raw: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(raw));
        const result = self.failing.allocator().rawAlloc(
            len,
            alignment,
            return_address,
        );
        if (result == null and self.failing.has_induced_failure) {
            self.failing.fail_index = std.math.maxInt(usize);
        }
        return result;
    }

    fn resize(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(raw));
        return self.failing.allocator().rawResize(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(raw));
        return self.failing.allocator().rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn free(
        raw: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *OneShotFailingAllocator = @ptrCast(@alignCast(raw));
        self.failing.allocator().rawFree(memory, alignment, return_address);
    }
};

const ConcurrentAppend = struct {
    session: *DurableSession,
    result: ?anyerror = null,

    fn run(self: *ConcurrentAppend) void {
        self.session.append("12345678", 2) catch |err| {
            self.result = err;
        };
    }
};

const ConcurrentResize = struct {
    session: *DurableSession,
    result: ?anyerror = null,

    fn run(self: *ConcurrentResize) void {
        self.session.resize(.{ .rows = 100, .columns = 100 }, 2) catch |err| {
            self.result = err;
        };
    }
};

fn checkStoreAllocationFailures(alloc: Allocator) !void {
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-store-allocation");
    defer session.deinit();
    _ = try session.append_event(.output, 2);
    var monitors = try session.load_monitor_definitions(alloc);
    defer monitors.deinit();
    var replay = try session.replay_events(alloc, 0, 1);
    defer replay.deinit(alloc);
}

fn checkAuthorityReloadAllocationFailures(alloc: Allocator) !void {
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-reload-allocation");
    defer session.deinit();
    var owner = try fixture.owner_capability(
        "terminal-store-owner",
        .read_only,
    );
    defer owner.deinit();
    const persistence = test_persistence();
    var loaded = try reloadAuthorityClaim(alloc, &owner, .{
        .terminal_session_id = "terminal-reload-allocation",
        .principal = persistence.grant.principal,
        .actor = persistence.grant.actor,
        .generation = persistence.grant.generation,
    });
    defer loaded.deinit();
}

fn checkRecoveryExecutionScopeAllocationFailures(alloc: Allocator) !void {
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var persistence = test_persistence();
    persistence.grant.principal.workspace_root = "/saved-workspace";
    var session = try fixture.create_with_persistence(
        "terminal-recovery-scope-allocation",
        .{ .rows = 24, .columns = 80 },
        &.{},
        persistence,
    );
    defer session.deinit();
    var scope = try session.load_recovery_execution_scope(alloc);
    defer scope.deinit(alloc);
}

fn test_persistence() contracts.StartPersistence {
    return .{
        .grant = .{
            .principal = .{
                .profile_user = "profile-user",
                .durable_session_id = "terminal-store-owner",
                .workspace_root = "/workspace",
                .cwd = "/workspace",
                .transport_role = .interactive,
                .backend = .native,
            },
            .actor = .agent,
            .controls = .full(),
            .generation = .{ .value = 1 },
        },
        .proof = .{ .bytes = @splat(7) },
    };
}

fn test_options() Options {
    return .{
        .per_session_limit = 256 * 1024,
        .profile_limit = 1024 * 1024,
        .segment_bytes = 4,
    };
}

fn expect_monitor_candidate(outcome: MonitorTransitionOutcome) !void {
    switch (outcome) {
        .candidate => {},
        .previous => |err| {
            _ = @errorName(err);
            return error.TestExpectedCandidateWinner;
        },
        .cancelled => return error.TestExpectedCandidateWinner,
        .indeterminate => |err| {
            _ = @errorName(err);
            return error.TestExpectedCandidateWinner;
        },
    }
}

fn expect_close_candidate(outcome: CloseCommitOutcome) !void {
    switch (outcome) {
        .candidate => {},
        .previous, .indeterminate => |err| {
            _ = @errorName(err);
            return error.TestExpectedCandidateWinner;
        },
    }
}

fn test_claim(persistence: contracts.StartPersistence) contracts.AuthorityClaim {
    return .{
        .principal = persistence.grant.principal,
        .actor = persistence.grant.actor,
        .generation = persistence.grant.generation,
        .proof = persistence.proof,
    };
}

fn test_process_owner(
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
) !contracts.ProcessOwner {
    var pid_buffer: [32]u8 = undefined;
    const pid = std.c.getpid();
    const pid_text = try std.fmt.bufPrint(&pid_buffer, "{d}", .{pid});
    const token = try process_provider.captureToken(
        alloc,
        pid_text,
    );
    return contracts.ProcessOwner.init(@intCast(pid), token.view());
}

test "owner catalog enumerates the exact durable owner without a terminal anchor" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();

    var first = try fixture.create("terminal-catalog-first");
    defer first.deinit();
    var second = try fixture.create("terminal-catalog-second");
    defer second.deinit();
    var third = try fixture.create("terminal-catalog-third");
    defer third.deinit();
    var foreign_persistence = test_persistence();
    foreign_persistence.grant.principal.workspace_root = "/foreign-workspace";
    foreign_persistence.grant.principal.cwd = "/foreign-workspace";
    var foreign = try fixture.create_with_persistence(
        "terminal-catalog-foreign",
        .{ .rows = 24, .columns = 80 },
        &.{},
        foreign_persistence,
    );
    defer foreign.deinit();
    try expect_close_candidate(first.begin_close(
        test_claim(test_persistence()),
        3,
    ));
    try first.finish_close(3);
    try second.revoke(4);

    var owner = try fixture.owner_capability(
        "terminal-store-owner",
        .writable,
    );
    defer owner.deinit();
    var claim = try loadOrCreateOwnerCatalogClaim(alloc, &owner, .{
        .profile_user = "profile-user",
        .durable_session_id = "terminal-store-owner",
        .workspace_root = "/workspace",
        .transport_role = .interactive,
        .actor = .agent,
    });
    defer claim.deinit();
    const catalog_claim = claim.view();
    try std.testing.expect(!std.mem.eql(
        u8,
        &catalog_claim.proof.bytes,
        &test_persistence().proof.bytes,
    ));

    var catalog = try fixture.profile.ownerCatalog(catalog_claim);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 3), catalog.entries.items.len);
    var found_closed = false;
    var found_revoked = false;
    var found_live = false;
    for (catalog.entries.items) |entry| {
        if (std.mem.eql(u8, entry.facts.session_id, "terminal-catalog-first")) {
            found_closed = entry.facts.lifecycle == .closed and
                !entry.authorization.controls.read and
                !entry.authorization.controls.inspect;
        }
        if (std.mem.eql(u8, entry.facts.session_id, "terminal-catalog-second")) {
            found_revoked = !entry.authorization.controls.read and
                !entry.authorization.controls.inspect;
        }
        if (std.mem.eql(u8, entry.facts.session_id, "terminal-catalog-third")) {
            found_live = true;
        }
        try std.testing.expect(!std.mem.eql(
            u8,
            entry.facts.session_id,
            "terminal-catalog-foreign",
        ));
    }
    try std.testing.expect(found_closed);
    try std.testing.expect(found_revoked);
    try std.testing.expect(found_live);

    var forged = catalog_claim;
    forged.proof.bytes[0] ^= 1;
    try std.testing.expectError(
        error.InvalidHolderProof,
        fixture.profile.ownerCatalog(forged),
    );
}

fn recovered_session_index(
    sessions: []const DurableSession,
    session_id: []const u8,
) ?usize {
    for (sessions, 0..) |session, index| {
        if (std.mem.eql(u8, session.record.session_id, session_id)) return index;
    }
    return null;
}

fn replace_test_authority(
    alloc: Allocator,
    session: *DurableSession,
    authority: AuthorityWire,
) !void {
    const bytes = try render_json(alloc, authority);
    defer alloc.free(bytes);
    const name = try authority_name(alloc, session.record.session_id);
    defer alloc.free(name);
    var entry = try (try session.state_capability()).atomicReplace(
        alloc,
        .terminal_state,
        name,
        bytes,
    );
    entry.deinit(alloc);
}

fn replace_test_close_transaction(
    alloc: Allocator,
    session: *DurableSession,
    bytes: []const u8,
) !void {
    const name = try close_transaction_name(alloc, session.record.session_id);
    defer alloc.free(name);
    var entry = try (try session.state_capability()).atomicReplace(
        alloc,
        .terminal_state,
        name,
        bytes,
    );
    entry.deinit(alloc);
}

fn expect_pending_close_unchanged(
    alloc: Allocator,
    profile: *ProfileStore,
    session_id: []const u8,
    generation: contracts.AuthorityGeneration,
    backend_identity: []const u8,
) !void {
    var unchanged = try profile.open_existing(
        "terminal-store-owner",
        session_id,
    );
    defer unchanged.deinit();
    try std.testing.expectEqual(contracts.Lifecycle.starting, unchanged.record.lifecycle);
    try std.testing.expect(unchanged.record.authority_revoked);
    try std.testing.expectEqual(generation, unchanged.record.authority_generation);
    try std.testing.expectEqualStrings(
        backend_identity,
        unchanged.record.backend_identity,
    );
    try std.testing.expect(try unchanged.close_cleanup_pending());
    var authority = try load_authority(
        alloc,
        try unchanged.state_capability(),
        session_id,
    );
    defer authority.deinit();
    try std.testing.expect(authority.value.revoked);
    try std.testing.expectEqual(generation, authority.value.grant.generation);
    var replay = try unchanged.replay_events(alloc, 0, 16);
    defer replay.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), replay.events.len);
    try std.testing.expectEqual(
        contracts.HostEvent.authority_revoked,
        replay.events[0].kind,
    );
}

test "durable journal rotates with monotonic cursors and reads exact bytes" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-journal");
    defer session.deinit();

    try session.append("abc", 2);
    try session.append("def", 3);
    try std.testing.expectEqual(
        contracts.RawCursor{ .segment = 1, .offset = 6 },
        session.record.output_cursor,
    );
    var page = try session.read(alloc, .{ .segment = 1, .offset = 0 }, 64);
    defer page.deinit(alloc);
    try std.testing.expectEqualStrings("abcdef", page.output);
    try std.testing.expectEqual(
        contracts.RawCursor{ .segment = 1, .offset = 6 },
        page.range.?.end,
    );
    var next = try session.read(alloc, page.range.?.end, 64);
    defer next.deinit(alloc);
    try std.testing.expectEqualStrings("", next.output);
    try std.testing.expect(try session.contains(
        "cde",
        .{ .segment = 1, .offset = 0 },
    ));
}

test "durable create load and replay release every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkStoreAllocationFailures,
        .{},
    );
}

test "public raw cursor paginates exactly across private journal rotation" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, .{
        .per_session_limit = 4 * 1024 * 1024,
        .profile_limit = 8 * 1024 * 1024,
        .segment_bytes = 1024 * 1024,
    });
    defer fixture.deinit();
    var session = try fixture.create("terminal-large-continuity");
    defer session.deinit();

    const payload = try alloc.alloc(u8, 1024 * 1024 + 12_345);
    defer alloc.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);
    try session.append(payload, 2);
    const facts = session.facts();
    try std.testing.expect(facts.raw_gap == null);
    try std.testing.expectEqual(
        contracts.RawRange{
            .start = .{ .segment = 1, .offset = 0 },
            .end = .{ .segment = 1, .offset = @intCast(payload.len) },
        },
        facts.unread_range.?,
    );

    var cursor = contracts.RawCursor{ .segment = 1, .offset = 0 };
    var consumed: usize = 0;
    while (consumed < payload.len) {
        var page = try session.read(alloc, cursor, 65_521);
        defer page.deinit(alloc);
        try std.testing.expect(page.range != null);
        try std.testing.expectEqual(cursor, page.range.?.start);
        try std.testing.expectEqualSlices(
            u8,
            payload[consumed .. consumed + page.output.len],
            page.output,
        );
        try std.testing.expect(page.output.len != 0);
        consumed += page.output.len;
        cursor = page.range.?.end;
        try std.testing.expectEqual(@as(u64, 1), cursor.segment);
    }
    try std.testing.expectEqual(payload.len, consumed);
    try std.testing.expectEqual(
        contracts.RawCursor{ .segment = 1, .offset = @intCast(payload.len) },
        cursor,
    );
}

test "checkpoint replacement stays opaque and separates raw gaps from screen state" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-checkpoint");
    defer session.deinit();
    try session.append("abc", 2);
    try session.append("def", 3);
    const payload = "opaque-screen";
    const envelope = contracts.CheckpointEnvelope{
        .engine_schema_revision = 1,
        .applied_cursor = session.record.output_cursor,
        .payload_len = payload.len,
        .checksum = contracts.checkpoint_checksum(payload),
    };
    try session.store_checkpoint(envelope, payload, 4);
    var checkpoint = (try session.load_checkpoint(alloc)).?;
    defer checkpoint.deinit(alloc);
    try std.testing.expectEqualStrings(payload, checkpoint.payload);

    try session.evict_live_covered_journals();
    try std.testing.expect(session.record.raw_gap != null);
    try std.testing.expect(session.record.screen_recovery == .available);
    var page = try session.read(alloc, .{ .segment = 1, .offset = 0 }, 64);
    defer page.deinit(alloc);
    try std.testing.expect(page.gap != null);
    try std.testing.expectEqualStrings("ef", page.output);

    var encoded = try encode_checkpoint(alloc, envelope, payload);
    defer alloc.free(encoded);
    encoded[encoded.len - 1] ^= 1;
    try std.testing.expectError(
        error.CheckpointChecksumMismatch,
        decode_checkpoint(alloc, encoded),
    );
    encoded[encoded.len - 1] ^= 1;
    std.mem.writeInt(u16, encoded[4..6], 2, .little);
    try std.testing.expectError(
        error.UnsupportedCheckpointSchema,
        decode_checkpoint(alloc, encoded),
    );
    std.mem.writeInt(u16, encoded[4..6], checkpoint_schema_version, .little);
    std.mem.writeInt(u32, encoded[24..28], payload.len + 1, .little);
    try std.testing.expectError(
        error.InvalidCheckpoint,
        decode_checkpoint(alloc, encoded),
    );
}

test "host absence gap retains both raw segments without matching across them" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-host-gap");
    try session.append("left", 2);
    const gap = try session.begin_raw_gap(3);
    try std.testing.expectEqual(
        contracts.RawCursor{ .segment = 1, .offset = 4 },
        gap.missing_from,
    );
    try std.testing.expectEqual(
        contracts.RawCursor{ .segment = 2, .offset = 0 },
        gap.available_from,
    );
    try session.append("right", 4);

    var before = try session.read(alloc, .{ .segment = 1, .offset = 0 }, 64);
    defer before.deinit(alloc);
    try std.testing.expectEqualStrings("left", before.output);
    try std.testing.expect(before.gap == null);
    var after = try session.read(alloc, gap.missing_from, 64);
    defer after.deinit(alloc);
    try std.testing.expectEqualStrings("right", after.output);
    try std.testing.expectEqual(gap, after.gap.?);
    try std.testing.expect(!try session.contains("ftr", .{ .segment = 1, .offset = 0 }));
    try std.testing.expect(try session.contains("right", .{ .segment = 1, .offset = 0 }));

    session.deinit();
    var reopened = try fixture.profile.open_existing(
        "terminal-store-owner",
        "terminal-host-gap",
    );
    defer reopened.deinit();
    try std.testing.expectEqual(gap, reopened.record.raw_gap.?);
    var reopened_after = try reopened.read(alloc, gap.missing_from, 64);
    defer reopened_after.deinit(alloc);
    try std.testing.expectEqualStrings("right", reopened_after.output);

    const second_gap = try reopened.begin_raw_gap(5);
    try std.testing.expectEqual(
        contracts.RawCursor{ .segment = 1, .offset = 0 },
        second_gap.missing_from,
    );
    try std.testing.expectEqual(
        contracts.RawCursor{ .segment = 3, .offset = 0 },
        second_gap.available_from,
    );
    try reopened.append("third", 6);
    var collapsed = try reopened.read(alloc, .{ .segment = 1, .offset = 0 }, 64);
    defer collapsed.deinit(alloc);
    try std.testing.expectEqualStrings("third", collapsed.output);
    try std.testing.expectEqual(second_gap, collapsed.gap.?);
}

test "reopened gap resumes the existing journal segment" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-reopened-gap");
    try session.append("left", 2);
    const gap = try session.begin_raw_gap(3);
    session.deinit();

    var reopened = try fixture.profile.open_existing(
        "terminal-store-owner",
        "terminal-reopened-gap",
    );
    defer reopened.deinit();
    try reopened.append("right", 4);

    try std.testing.expectEqual(gap, reopened.record.raw_gap.?);
    try std.testing.expectEqual(
        contracts.RawCursor{ .segment = 2, .offset = 5 },
        reopened.record.output_cursor,
    );
    var page = try reopened.read(alloc, gap.available_from, 64);
    defer page.deinit(alloc);
    try std.testing.expectEqualStrings("right", page.output);
}

test "available checkpoint record payload bytes match envelope" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-checkpoint-record-length");
    defer session.deinit();
    const payload = "opaque-screen";
    const envelope = contracts.CheckpointEnvelope{
        .engine_schema_revision = 1,
        .applied_cursor = session.record.output_cursor,
        .payload_len = payload.len,
        .checksum = contracts.checkpoint_checksum(payload),
    };
    try session.store_checkpoint(envelope, payload, 2);
    try session.record.validate();

    var malformed = session.record;
    malformed.checkpoint_payload_bytes = @as(u64, envelope.payload_len) - 1;
    try std.testing.expectError(
        error.InvalidTerminalRecord,
        malformed.validate(),
    );
    malformed.checkpoint_payload_bytes = @as(u64, envelope.payload_len) + 1;
    try std.testing.expectError(
        error.InvalidTerminalRecord,
        malformed.validate(),
    );
}

test "fresh reopen isolates checkpoint payload byte mismatch before accounting" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-checkpoint-record-corrupt");
    const payload = "opaque-screen";
    const envelope = contracts.CheckpointEnvelope{
        .engine_schema_revision = 1,
        .applied_cursor = session.record.output_cursor,
        .payload_len = payload.len,
        .checksum = contracts.checkpoint_checksum(payload),
    };
    try session.store_checkpoint(envelope, payload, 2);

    var malformed = session.record;
    malformed.checkpoint_payload_bytes = @as(u64, envelope.payload_len) + 1;
    const bytes = try render_json(alloc, record_wire(malformed));
    defer alloc.free(bytes);
    const name = try record_name(alloc, malformed.session_id);
    defer alloc.free(name);
    var entry = try (try session.state_capability()).atomicReplace(
        alloc,
        .terminal_state,
        name,
        bytes,
    );
    entry.deinit(alloc);
    session.deinit();
    try fixture.reopen();

    var candidates = try fixture.profile.scan_payload_candidates();
    defer candidates.deinit(alloc);
    try std.testing.expectEqual(@as(u64, payload.len), candidates.total_bytes);
    try std.testing.expectEqual(@as(usize, 0), candidates.items.items.len);

    var recovered = try fixture.profile.recover("host-two", 3);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 0), recovered.sessions.items.len);
    try std.testing.expectEqual(@as(usize, 1), recovered.diagnostics.items.len);
    try std.testing.expectEqualStrings(
        "InvalidTerminalRecord",
        recovered.diagnostics.items[0].reason,
    );
}

test "authority proof is principal bound generation checked and revocable" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-authority");
    defer session.deinit();
    const persistence = test_persistence();
    const claim = test_claim(persistence);
    try session.verify_claim(claim, .read);

    var foreign = claim;
    foreign.principal.profile_user = "foreign-profile";
    try std.testing.expectError(
        error.PrincipalMismatch,
        session.verify_claim(foreign, .read),
    );
    foreign = claim;
    foreign.principal.durable_session_id = "foreign-session";
    try std.testing.expectError(
        error.PrincipalMismatch,
        session.verify_claim(foreign, .read),
    );
    foreign = claim;
    foreign.principal.workspace_root = "/foreign";
    try std.testing.expectError(
        error.PrincipalMismatch,
        session.verify_claim(foreign, .read),
    );
    foreign = claim;
    foreign.principal.cwd = "/foreign";
    try std.testing.expectError(
        error.PrincipalMismatch,
        session.verify_claim(foreign, .read),
    );
    foreign = claim;
    foreign.principal.transport_role = .headless;
    try std.testing.expectError(
        error.PrincipalMismatch,
        session.verify_claim(foreign, .read),
    );
    foreign = claim;
    foreign.principal.transport_role = .acp;
    try std.testing.expectError(
        error.PrincipalMismatch,
        session.verify_claim(foreign, .read),
    );
    foreign = claim;
    foreign.principal.backend = .tmux;
    try std.testing.expectError(
        error.PrincipalMismatch,
        session.verify_claim(foreign, .read),
    );
    foreign = claim;
    foreign.actor = .human;
    try std.testing.expectError(
        error.ActorRoleMismatch,
        session.verify_claim(foreign, .read),
    );
    foreign = claim;
    foreign.generation = .{ .value = 2 };
    try std.testing.expectError(
        error.StaleAuthorityGeneration,
        session.verify_claim(foreign, .read),
    );
    foreign = claim;
    foreign.proof.bytes[0] ^= 1;
    try std.testing.expectError(
        error.InvalidHolderProof,
        session.verify_claim(foreign, .read),
    );
    try session.revoke(5);
    try std.testing.expectError(
        error.AuthorityRevoked,
        session.verify_claim(claim, .read),
    );
}

test "repeated probe authority requires every exact production bound" {
    const alloc = std.testing.allocator;
    const repeated = [_]contracts.RepeatedProbeAuthority{.{
        .command = "test -f ready",
        .cwd = "/workspace",
        .check_schedule = .{ .interval_ms = 25 },
        .notify_schedule = .{ .every_n_checks = 2 },
        .lifetime = .{ .duration_ms = 500 },
    }};
    const exact = contracts.MonitorDefinition{
        .condition = .{ .custom_probe = .{
            .command = "test -f ready",
            .cwd = "/workspace",
        } },
        .check_schedule = .{ .interval_ms = 25 },
        .notify_schedule = .{ .every_n_checks = 2 },
        .lifetime = .{ .duration_ms = 500 },
    };

    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var persistence = test_persistence();
    persistence.grant.repeated_probes = &repeated;
    var session = try fixture.create_with_persistence(
        "terminal-probe-authority",
        .{ .rows = 24, .columns = 80 },
        &.{},
        persistence,
    );
    defer session.deinit();
    _ = try session.authorize_monitor_definition(
        test_claim(persistence),
        exact,
    );

    var changed = exact;
    changed.condition.custom_probe.command = "test -f other";
    try std.testing.expectError(
        error.ProbeAuthorityDenied,
        session.authorize_monitor_definition(test_claim(persistence), changed),
    );
    changed = exact;
    changed.condition.custom_probe.cwd = "/workspace/other";
    try std.testing.expectError(
        error.ProbeAuthorityDenied,
        session.authorize_monitor_definition(test_claim(persistence), changed),
    );
    changed = exact;
    changed.check_schedule = .{ .interval_ms = 30 };
    try std.testing.expectError(
        error.ProbeAuthorityDenied,
        session.authorize_monitor_definition(test_claim(persistence), changed),
    );
    changed = exact;
    changed.notify_schedule = .every_check;
    try std.testing.expectError(
        error.ProbeAuthorityDenied,
        session.authorize_monitor_definition(test_claim(persistence), changed),
    );
    changed = exact;
    changed.lifetime = .{ .duration_ms = 501 };
    try std.testing.expectError(
        error.ProbeAuthorityDenied,
        session.authorize_monitor_definition(test_claim(persistence), changed),
    );

    var missing = try fixture.create_with_persistence(
        "terminal-probe-authority-missing",
        .{ .rows = 24, .columns = 80 },
        &.{},
        test_persistence(),
    );
    defer missing.deinit();
    try std.testing.expectError(
        error.ProbeAuthorityDenied,
        missing.authorize_monitor_definition(
            test_claim(test_persistence()),
            exact,
        ),
    );
}

test "holder proof verifier binds the verified observer policy" {
    var persistence = test_persistence();
    persistence.grant.actor = .human;
    const without_observer = proof_verifier(
        persistence.proof,
        persistence.grant,
        false,
    );
    const with_observer = proof_verifier(
        persistence.proof,
        persistence.grant,
        true,
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        &without_observer,
        &with_observer,
    ));
}

test "holder proof verifier ignores packed control padding" {
    const canonical = contracts.AllowedControls.full();
    var padded = canonical;
    std.mem.asBytes(&padded)[1] |= 0xfc;

    var canonical_hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash_allowed_controls(&canonical_hash, canonical);
    var canonical_digest: contracts.CheckpointChecksum = undefined;
    canonical_hash.final(&canonical_digest);

    var padded_hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash_allowed_controls(&padded_hash, padded);
    var padded_digest: contracts.CheckpointChecksum = undefined;
    padded_hash.final(&padded_digest);

    try std.testing.expectEqualSlices(
        u8,
        &canonical_digest,
        &padded_digest,
    );
}

test "authority reload covers allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkAuthorityReloadAllocationFailures,
        .{},
    );
}

test "recovery execution scope reloads the exact durable authority" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var persistence = test_persistence();
    persistence.grant.principal.workspace_root = "/saved-workspace";
    var session = try fixture.create_with_persistence(
        "terminal-recovery-scope",
        .{ .rows = 24, .columns = 80 },
        &.{},
        persistence,
    );
    defer session.deinit();

    var scope = try session.load_recovery_execution_scope(alloc);
    defer scope.deinit(alloc);
    try std.testing.expectEqualStrings("/saved-workspace", scope.workspace_root);
    try std.testing.expect(!std.mem.eql(u8, scope.workspace_root, session.record.cwd));
    try std.testing.expect(!@hasField(RecoveredExecutionScope, "proof"));
}

test "recovery execution scope authenticates workspace" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    const cases = [_][]const u8{"terminal-recovery-workspace-tamper"};

    for (cases) |session_id| {
        var session = try fixture.create(session_id);
        defer session.deinit();
        const parsed = try load_authority(
            alloc,
            try session.state_capability(),
            session_id,
        );
        defer parsed.deinit();
        var authority = parsed.value;
        authority.grant.principal.workspace_root = "/tampered-workspace";
        try replace_test_authority(alloc, &session, authority);
        try std.testing.expectError(
            error.InvalidHolderProof,
            session.load_recovery_execution_scope(alloc),
        );
    }
}

test "recovery execution scope rejects revocation before reading invalidated proof" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-recovery-scope-revoked");
    defer session.deinit();

    try session.revoke(2);
    try std.testing.expectError(
        error.AuthorityRevoked,
        session.load_recovery_execution_scope(alloc),
    );
}

test "recovery execution scope rejects record authority inconsistency" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-recovery-scope-inconsistent");
    defer session.deinit();

    const inconsistent_cwd = try alloc.dupe(u8, "/other-cwd");
    alloc.free(session.record.cwd);
    session.record.cwd = inconsistent_cwd;
    try save_record(
        alloc,
        try session.state_capability(),
        session.record,
    );
    try std.testing.expectError(
        error.InvalidAuthorityRecord,
        session.load_recovery_execution_scope(alloc),
    );
}

test "recovery execution scope covers allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkRecoveryExecutionScopeAllocationFailures,
        .{},
    );
}

test "tmux recovery propagates execution scope allocation failure without durable loss" {
    const alloc = std.testing.allocator;
    var failing = OneShotFailingAllocator.init(alloc);
    var fixture = try TestStoreFixture.init(failing.allocator(), test_options());
    defer fixture.deinit();
    var session = try fixture.create_tmux("terminal-recovery-scope-oom");
    const authority_generation = session.record.authority_generation;
    session.deinit();
    try fixture.reopen();

    const baseline_start = failing.failing.alloc_index;
    var baseline = try fixture.profile.recover("host-two", 2);
    baseline.deinit();
    const recovery_allocations = failing.failing.alloc_index - baseline_start;
    try std.testing.expect(recovery_allocations >= 2);
    // The saved workspace copy is immediately followed by the recovered-list append.
    failing.failing.fail_index = failing.failing.alloc_index +
        recovery_allocations - 2;

    if (fixture.profile.recover("host-two", 2)) |unexpected_value| {
        var unexpected = unexpected_value;
        defer unexpected.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expect(failing.failing.has_induced_failure);

    {
        var durable = try fixture.profile.open_existing(
            "terminal-store-owner",
            "terminal-recovery-scope-oom",
        );
        defer durable.deinit();
        try std.testing.expectEqual(
            contracts.Lifecycle.starting,
            durable.record.lifecycle,
        );
        try std.testing.expectEqual(
            authority_generation,
            durable.record.authority_generation,
        );
    }

    var recovered = try fixture.profile.recover("host-two", 2);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 0), recovered.diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 1), recovered.sessions.items.len);
    try std.testing.expectEqual(
        contracts.Lifecycle.starting,
        recovered.sessions.items[0].record.lifecycle,
    );
    try std.testing.expectEqual(
        authority_generation,
        recovered.sessions.items[0].record.authority_generation,
    );
}

test "tmux recovery propagates proof capability failure without durable loss" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create_tmux("terminal-recovery-proof-capability");
    const authority_generation = session.record.authority_generation;
    session.deinit();
    try fixture.reopen();

    const name = try proof_name(alloc, "terminal-recovery-proof-capability");
    defer alloc.free(name);
    const path = try std.fs.path.join(alloc, &.{
        fixture.home,
        ".fx",
        "sessions",
        "terminal-store-owner",
        "terminal",
        "proofs",
        name,
    });
    defer alloc.free(path);
    var proof_file = try std.Io.Dir.openFileAbsolute(
        std.testing.io,
        path,
        .{ .mode = .read_write },
    );
    try proof_file.setPermissions(
        std.testing.io,
        std.Io.File.Permissions.fromMode(0o640),
    );
    proof_file.close(std.testing.io);

    if (fixture.profile.recover("host-two", 2)) |unexpected_value| {
        var unexpected = unexpected_value;
        defer unexpected.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(
            error.PrivateStatePermissionsUnsupported,
            err,
        );
    }

    proof_file = try std.Io.Dir.openFileAbsolute(
        std.testing.io,
        path,
        .{ .mode = .read_write },
    );
    defer proof_file.close(std.testing.io);
    try proof_file.setPermissions(
        std.testing.io,
        std.Io.File.Permissions.fromMode(0o600),
    );

    {
        var durable = try fixture.profile.open_existing(
            "terminal-store-owner",
            "terminal-recovery-proof-capability",
        );
        defer durable.deinit();
        try std.testing.expectEqual(
            contracts.Lifecycle.starting,
            durable.record.lifecycle,
        );
        try std.testing.expectEqual(
            authority_generation,
            durable.record.authority_generation,
        );
    }

    var recovered = try fixture.profile.recover("host-two", 2);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 0), recovered.diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 1), recovered.sessions.items.len);
    try std.testing.expectEqual(
        contracts.Lifecycle.starting,
        recovered.sessions.items[0].record.lifecycle,
    );
    try std.testing.expectEqual(
        authority_generation,
        recovered.sessions.items[0].record.authority_generation,
    );
}

test "tmux recovery isolates invalid authority from a valid sibling" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var valid = try fixture.create_tmux("terminal-recovery-valid-sibling");
    var invalid = try fixture.create_tmux("terminal-recovery-invalid-sibling");
    const parsed = try load_authority(
        alloc,
        try invalid.state_capability(),
        invalid.record.session_id,
    );
    defer parsed.deinit();
    var authority = parsed.value;
    authority.grant.principal.workspace_root = "/tampered-workspace";
    try replace_test_authority(alloc, &invalid, authority);
    valid.deinit();
    invalid.deinit();
    try fixture.reopen();

    var recovered = try fixture.profile.recover("host-two", 2);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 2), recovered.sessions.items.len);
    const valid_index = recovered_session_index(
        recovered.sessions.items,
        "terminal-recovery-valid-sibling",
    ).?;
    const invalid_index = recovered_session_index(
        recovered.sessions.items,
        "terminal-recovery-invalid-sibling",
    ).?;
    try std.testing.expectEqual(
        contracts.Lifecycle.starting,
        recovered.sessions.items[valid_index].record.lifecycle,
    );
    try std.testing.expectEqual(
        contracts.Lifecycle.lost,
        recovered.sessions.items[invalid_index].record.lifecycle,
    );
    try std.testing.expectEqual(@as(usize, 1), recovered.diagnostics.items.len);
    try std.testing.expectEqualStrings(
        "terminal-recovery-invalid-sibling",
        recovered.diagnostics.items[0].terminal_session_id,
    );
    try std.testing.expectEqualStrings(
        "InvalidHolderProof",
        recovered.diagnostics.items[0].reason,
    );
}

test "close recovery isolates a malformed transaction from a live tmux sibling" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var persistence = test_persistence();
    persistence.grant.principal.backend = .tmux;
    var valid = try fixture.create_tmux("terminal-close-valid-tmux-sibling");
    var invalid = try fixture.create_tmux("terminal-close-invalid-transaction");
    try expect_close_candidate(invalid.begin_close(test_claim(persistence), 2));
    try replace_test_close_transaction(alloc, &invalid, "{");
    valid.deinit();
    invalid.deinit();
    try fixture.reopen();

    var recovered = try fixture.profile.recover("host-two", 3);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 2), recovered.sessions.items.len);
    const valid_index = recovered_session_index(
        recovered.sessions.items,
        "terminal-close-valid-tmux-sibling",
    ).?;
    const invalid_index = recovered_session_index(
        recovered.sessions.items,
        "terminal-close-invalid-transaction",
    ).?;
    const valid_sibling = &recovered.sessions.items[valid_index];
    const isolated = &recovered.sessions.items[invalid_index];
    try std.testing.expectEqual(
        contracts.Lifecycle.starting,
        valid_sibling.record.lifecycle,
    );
    try std.testing.expect(!valid_sibling.record.authority_revoked);
    try std.testing.expectEqual(contracts.Lifecycle.closed, isolated.record.lifecycle);
    try std.testing.expect(isolated.record.authority_revoked);
    try std.testing.expect(try isolated.close_cleanup_pending());
    try std.testing.expectEqual(@as(usize, 1), recovered.diagnostics.items.len);
    try std.testing.expectEqualStrings(
        "terminal-close-invalid-transaction",
        recovered.diagnostics.items[0].terminal_session_id,
    );
    try std.testing.expectEqualStrings(
        "InvalidCloseTransaction",
        recovered.diagnostics.items[0].reason,
    );
}

test "close recovery isolates an oversized transaction from a live tmux sibling" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var persistence = test_persistence();
    persistence.grant.principal.backend = .tmux;
    var valid = try fixture.create_tmux("terminal-close-valid-oversized-sibling");
    var invalid = try fixture.create_tmux("terminal-close-oversized-transaction");
    try expect_close_candidate(invalid.begin_close(test_claim(persistence), 2));
    const oversized = try alloc.alloc(u8, max_event_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    try replace_test_close_transaction(alloc, &invalid, oversized);
    valid.deinit();
    invalid.deinit();
    try fixture.reopen();

    var recovered = try fixture.profile.recover("host-two", 3);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 2), recovered.sessions.items.len);
    const valid_index = recovered_session_index(
        recovered.sessions.items,
        "terminal-close-valid-oversized-sibling",
    ).?;
    const invalid_index = recovered_session_index(
        recovered.sessions.items,
        "terminal-close-oversized-transaction",
    ).?;
    const valid_sibling = &recovered.sessions.items[valid_index];
    const isolated = &recovered.sessions.items[invalid_index];
    try std.testing.expectEqual(
        contracts.Lifecycle.starting,
        valid_sibling.record.lifecycle,
    );
    try std.testing.expect(!valid_sibling.record.authority_revoked);
    try std.testing.expectEqual(contracts.Lifecycle.closed, isolated.record.lifecycle);
    try std.testing.expect(isolated.record.authority_revoked);
    try std.testing.expect(try isolated.close_cleanup_pending());
    try std.testing.expectEqual(@as(usize, 1), recovered.diagnostics.items.len);
    try std.testing.expectEqualStrings(
        "terminal-close-oversized-transaction",
        recovered.diagnostics.items[0].terminal_session_id,
    );
    try std.testing.expectEqualStrings(
        "InvalidCloseTransaction",
        recovered.diagnostics.items[0].reason,
    );
}

test "close recovery propagates allocation failure without durable mutation" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var persistence = test_persistence();
    persistence.grant.principal.backend = .tmux;
    var session = try fixture.create_tmux("terminal-close-recovery-oom");
    var sibling = try fixture.create_tmux("terminal-close-recovery-oom-sibling");
    try expect_close_candidate(session.begin_close(test_claim(persistence), 2));
    try expect_close_candidate(sibling.begin_close(test_claim(persistence), 2));
    const generation = session.record.authority_generation;
    const sibling_generation = sibling.record.authority_generation;
    const backend_identity = try alloc.dupe(u8, session.record.backend_identity);
    defer alloc.free(backend_identity);
    const sibling_backend_identity = try alloc.dupe(
        u8,
        sibling.record.backend_identity,
    );
    defer alloc.free(sibling_backend_identity);
    session.deinit();
    sibling.deinit();
    try fixture.reopen();

    fixture.profile.options.fail_at = .before_close_recovery_oom;
    if (fixture.profile.recover("host-two", 3)) |unexpected_value| {
        var unexpected = unexpected_value;
        defer unexpected.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    fixture.profile.options.fail_at = null;

    try expect_pending_close_unchanged(
        alloc,
        &fixture.profile,
        "terminal-close-recovery-oom",
        generation,
        backend_identity,
    );
    try expect_pending_close_unchanged(
        alloc,
        &fixture.profile,
        "terminal-close-recovery-oom-sibling",
        sibling_generation,
        sibling_backend_identity,
    );
}

test "close recovery propagates capability failure without durable mutation" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var persistence = test_persistence();
    persistence.grant.principal.backend = .tmux;
    var session = try fixture.create_tmux("terminal-close-recovery-capability");
    var sibling = try fixture.create_tmux(
        "terminal-close-recovery-capability-sibling",
    );
    try expect_close_candidate(session.begin_close(test_claim(persistence), 2));
    try expect_close_candidate(sibling.begin_close(test_claim(persistence), 2));
    const generation = session.record.authority_generation;
    const sibling_generation = sibling.record.authority_generation;
    const backend_identity = try alloc.dupe(u8, session.record.backend_identity);
    defer alloc.free(backend_identity);
    const sibling_backend_identity = try alloc.dupe(
        u8,
        sibling.record.backend_identity,
    );
    defer alloc.free(sibling_backend_identity);
    session.deinit();
    sibling.deinit();
    try fixture.reopen();

    fixture.profile.options.fail_at = .before_close_recovery_capability;
    if (fixture.profile.recover("host-two", 3)) |unexpected_value| {
        var unexpected = unexpected_value;
        defer unexpected.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(
            error.PrivateStatePermissionsUnsupported,
            err,
        );
    }
    fixture.profile.options.fail_at = null;

    try expect_pending_close_unchanged(
        alloc,
        &fixture.profile,
        "terminal-close-recovery-capability",
        generation,
        backend_identity,
    );
    try expect_pending_close_unchanged(
        alloc,
        &fixture.profile,
        "terminal-close-recovery-capability-sibling",
        sibling_generation,
        sibling_backend_identity,
    );
}

test "authority reload requires owner capability and exact durable scope" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-authority-reload");
    defer session.deinit();
    const persistence = test_persistence();
    var owner = try fixture.owner_capability(
        "terminal-store-owner",
        .read_only,
    );
    defer owner.deinit();
    const input = AuthorityReload{
        .terminal_session_id = "terminal-authority-reload",
        .principal = persistence.grant.principal,
        .actor = persistence.grant.actor,
        .generation = persistence.grant.generation,
    };
    var loaded = try reloadAuthorityClaim(alloc, &owner, input);
    defer loaded.deinit();
    try std.testing.expect(persistence.grant.principal.eql(loaded.view().principal));
    try std.testing.expectEqual(persistence.grant.controls, loaded.controls);
    try session.verify_claim(loaded.view(), .write);

    var foreign = input;
    foreign.principal.profile_user = "foreign-profile";
    try std.testing.expectError(
        error.PrincipalMismatch,
        reloadAuthorityClaim(alloc, &owner, foreign),
    );
    foreign = input;
    foreign.principal.durable_session_id = "foreign-session";
    try std.testing.expectError(
        error.PrincipalMismatch,
        reloadAuthorityClaim(alloc, &owner, foreign),
    );
    foreign = input;
    foreign.principal.workspace_root = "/foreign";
    try std.testing.expectError(
        error.PrincipalMismatch,
        reloadAuthorityClaim(alloc, &owner, foreign),
    );
    foreign = input;
    foreign.principal.cwd = "/foreign";
    try std.testing.expectError(
        error.PrincipalMismatch,
        reloadAuthorityClaim(alloc, &owner, foreign),
    );
    foreign = input;
    foreign.principal.transport_role = .acp;
    try std.testing.expectError(
        error.PrincipalMismatch,
        reloadAuthorityClaim(alloc, &owner, foreign),
    );
    foreign = input;
    foreign.principal.backend = .tmux;
    try std.testing.expectError(
        error.PrincipalMismatch,
        reloadAuthorityClaim(alloc, &owner, foreign),
    );
    foreign = input;
    foreign.actor = .human;
    try std.testing.expectError(
        error.ActorRoleMismatch,
        reloadAuthorityClaim(alloc, &owner, foreign),
    );
    foreign = input;
    foreign.generation = .{ .value = 2 };
    try std.testing.expectError(
        error.StaleAuthorityGeneration,
        reloadAuthorityClaim(alloc, &owner, foreign),
    );

    try fixture.create_owner("terminal-foreign-owner");
    var foreign_owner = try fixture.owner_capability(
        "terminal-foreign-owner",
        .read_only,
    );
    defer foreign_owner.deinit();
    try std.testing.expectError(
        error.TerminalRecordNotFound,
        reloadAuthorityClaim(alloc, &foreign_owner, input),
    );
}

test "authority reload grants direct human model observer controls only" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var persistence = test_persistence();
    persistence.grant.actor = .human;
    persistence.direct_human_model_read_only = true;
    var session = try fixture.create_with_persistence(
        "terminal-human-reload",
        .{ .rows = 24, .columns = 80 },
        &.{},
        persistence,
    );
    defer session.deinit();
    var owner = try fixture.owner_capability(
        "terminal-store-owner",
        .read_only,
    );
    defer owner.deinit();
    const base = AuthorityReload{
        .terminal_session_id = "terminal-human-reload",
        .principal = persistence.grant.principal,
        .actor = .human,
        .generation = persistence.grant.generation,
    };
    var human = try reloadAuthorityClaim(alloc, &owner, base);
    defer human.deinit();
    try std.testing.expectEqual(contracts.AllowedControls.full(), human.controls);

    var model_input = base;
    model_input.actor = .agent;
    var model = try reloadAuthorityClaim(alloc, &owner, model_input);
    defer model.deinit();
    try std.testing.expectEqual(contracts.AllowedControls.observer(), model.controls);
    try session.verify_claim(model.view(), .read);
    try std.testing.expectError(
        error.ControlDenied,
        session.verify_claim(model.view(), .write),
    );
}

test "record observer policy tampering rejects reload and live authorization" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    const cases = [_]struct {
        session_id: []const u8,
        observer_policy: bool,
    }{
        .{
            .session_id = "terminal-policy-enable-tamper",
            .observer_policy = false,
        },
        .{
            .session_id = "terminal-policy-disable-tamper",
            .observer_policy = true,
        },
    };

    for (cases) |case| {
        var persistence = test_persistence();
        persistence.grant.actor = .human;
        persistence.direct_human_model_read_only = case.observer_policy;
        var session = try fixture.create_with_persistence(
            case.session_id,
            .{ .rows = 24, .columns = 80 },
            &.{},
            persistence,
        );
        defer session.deinit();
        var model = test_claim(persistence);
        model.actor = .agent;
        if (case.observer_policy) {
            try session.verify_claim(model, .read);
        } else {
            try std.testing.expectError(
                error.ActorRoleMismatch,
                session.verify_claim(model, .read),
            );
        }

        session.record.direct_human_model_read_only = !case.observer_policy;
        try std.testing.expectError(
            error.InvalidAuthorityRecord,
            session.verify_claim(model, .read),
        );
        try save_record(
            alloc,
            try session.state_capability(),
            session.record,
        );
        var owner = try fixture.owner_capability(
            "terminal-store-owner",
            .read_only,
        );
        defer owner.deinit();
        try std.testing.expectError(
            error.InvalidAuthorityRecord,
            reloadAuthorityClaim(alloc, &owner, .{
                .terminal_session_id = case.session_id,
                .principal = persistence.grant.principal,
                .actor = .agent,
                .generation = persistence.grant.generation,
            }),
        );
    }
}

test "authority reload rejects malformed state proof lifetime and revocation" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var malformed_session = try fixture.create("terminal-malformed-proof");
    defer malformed_session.deinit();
    const persistence = test_persistence();
    const input = AuthorityReload{
        .terminal_session_id = "terminal-malformed-proof",
        .principal = persistence.grant.principal,
        .actor = persistence.grant.actor,
        .generation = persistence.grant.generation,
    };
    var writable_owner = try fixture.owner_capability(
        "terminal-store-owner",
        .writable,
    );
    defer writable_owner.deinit();
    const proof_file = try proof_name(alloc, input.terminal_session_id);
    defer alloc.free(proof_file);
    var malformed = try writable_owner.atomicReplace(
        alloc,
        .terminal_proofs,
        proof_file,
        "bad",
    );
    malformed.deinit(alloc);
    try std.testing.expectError(
        error.InvalidHolderProof,
        reloadAuthorityClaim(alloc, &writable_owner, input),
    );

    var malformed_record = try fixture.create("terminal-malformed-record");
    defer malformed_record.deinit();
    const record_file = try record_name(alloc, "terminal-malformed-record");
    defer alloc.free(record_file);
    var bad_record = try writable_owner.atomicReplace(
        alloc,
        .terminal_state,
        record_file,
        "bad",
    );
    bad_record.deinit(alloc);
    var malformed_record_input = input;
    malformed_record_input.terminal_session_id = "terminal-malformed-record";
    try std.testing.expectError(
        error.InvalidTerminalRecord,
        reloadAuthorityClaim(alloc, &writable_owner, malformed_record_input),
    );

    var malformed_lifetime = try fixture.create("terminal-malformed-lifetime");
    defer malformed_lifetime.deinit();
    const authority_bytes = try render_json(alloc, AuthorityWire{
        .session_id = "terminal-malformed-lifetime",
        .grant = persistence.grant,
        .direct_human_model_read_only = false,
        .verifier = proof_verifier(
            persistence.proof,
            persistence.grant,
            false,
        ),
        .revoked = false,
    });
    defer alloc.free(authority_bytes);
    const invalid_lifetime = try std.mem.replaceOwned(
        u8,
        alloc,
        authority_bytes,
        "\"lifetime\":\"session\"",
        "\"lifetime\":\"foreign\"",
    );
    defer alloc.free(invalid_lifetime);
    const authority_file = try authority_name(
        alloc,
        "terminal-malformed-lifetime",
    );
    defer alloc.free(authority_file);
    var bad_authority = try writable_owner.atomicReplace(
        alloc,
        .terminal_state,
        authority_file,
        invalid_lifetime,
    );
    bad_authority.deinit(alloc);
    var malformed_lifetime_input = input;
    malformed_lifetime_input.terminal_session_id = "terminal-malformed-lifetime";
    try std.testing.expectError(
        error.InvalidAuthorityRecord,
        reloadAuthorityClaim(alloc, &writable_owner, malformed_lifetime_input),
    );

    var retired = try fixture.create("terminal-retired-authority");
    defer retired.deinit();
    const retired_authority = try render_json(alloc, AuthorityWire{
        .session_id = "terminal-retired-authority",
        .grant = persistence.grant,
        .direct_human_model_read_only = false,
        .verifier = proof_verifier(
            persistence.proof,
            persistence.grant,
            false,
        ),
        .revoked = false,
    });
    defer alloc.free(retired_authority);
    const legacy_authority = try std.mem.replaceOwned(
        u8,
        alloc,
        retired_authority,
        "\"schema_version\":2",
        "\"schema_version\":1",
    );
    defer alloc.free(legacy_authority);
    const retired_authority_file = try authority_name(
        alloc,
        "terminal-retired-authority",
    );
    defer alloc.free(retired_authority_file);
    var retired_authority_write = try writable_owner.atomicReplace(
        alloc,
        .terminal_state,
        retired_authority_file,
        legacy_authority,
    );
    retired_authority_write.deinit(alloc);
    var retired_input = input;
    retired_input.terminal_session_id = "terminal-retired-authority";
    try std.testing.expectError(
        error.TerminalAuthorityRetired,
        reloadAuthorityClaim(alloc, &writable_owner, retired_input),
    );

    var revoked = try fixture.create("terminal-revoked-reload");
    defer revoked.deinit();
    try revoked.revoke(5);
    var revoked_input = input;
    revoked_input.terminal_session_id = "terminal-revoked-reload";
    try std.testing.expectError(
        error.AuthorityRevoked,
        reloadAuthorityClaim(alloc, &writable_owner, revoked_input),
    );
}

test "write leases are exclusive durable and cancellation is actor scoped" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-lease");
    const agent = test_claim(test_persistence());
    _ = try session.acquire_write_lease(agent, 2);
    try std.testing.expectEqual(contracts.WriteLease.agent, session.facts().attention.write_lease);
    session.deinit();
    var reopened = try fixture.profile.open_existing(
        "terminal-store-owner",
        "terminal-lease",
    );
    defer reopened.deinit();
    try std.testing.expectEqual(
        contracts.WriteLease.agent,
        reopened.facts().attention.write_lease,
    );

    var human = agent;
    human.actor = .human;
    try std.testing.expectError(
        error.ActorRoleMismatch,
        reopened.acquire_write_lease(human, 3),
    );
    try std.testing.expectError(
        error.ActorRoleMismatch,
        reopened.cancel_claim(human, 4),
    );
    try std.testing.expectEqual(contracts.WriteLease.agent, reopened.facts().attention.write_lease);
    try reopened.cancel_claim(agent, 5);
    try std.testing.expectEqual(contracts.WriteLease.none, reopened.facts().attention.write_lease);
}

test "cancellation persistence failure preserves the lease for a clean retry" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-cancellation-failure");
    defer session.deinit();
    const claim = test_claim(test_persistence());
    _ = try session.acquire_write_lease(claim, 2);

    fixture.profile.options.fail_at = .cancellation;
    try std.testing.expectError(
        error.InjectedCancellationPersistenceFailure,
        session.cancel_claim(claim, 3),
    );
    try std.testing.expectEqual(
        contracts.WriteLease.agent,
        session.facts().attention.write_lease,
    );

    fixture.profile.options.fail_at = null;
    try session.cancel_claim(claim, 4);
    try std.testing.expectEqual(
        contracts.WriteLease.none,
        session.facts().attention.write_lease,
    );
}

test "human owner takeover proof is narrow and excludes agent writes" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-human-takeover");
    defer session.deinit();
    var owner = try fixture.owner_capability(
        "terminal-store-owner",
        .writable,
    );
    defer owner.deinit();
    var takeover = try reloadHumanTakeoverAuthorityClaim(alloc, &owner, .{
        .terminal_session_id = "terminal-human-takeover",
        .profile_user = "profile-user",
        .durable_session_id = "terminal-store-owner",
        .workspace_root = "/workspace",
        .transport_role = .interactive,
        .actor = .human,
    });
    defer takeover.deinit();
    takeover.value.process_owner = try test_process_owner(
        alloc,
        fixture.profile.process_provider,
    );

    try session.verify_claim(takeover.view(), .screen);
    try session.verify_claim(takeover.view(), .resize);
    try std.testing.expectError(
        error.ControlDenied,
        session.verify_claim(takeover.view(), .read),
    );
    try std.testing.expectError(
        error.ControlDenied,
        session.verify_claim(takeover.view(), .close),
    );
    try std.testing.expectError(
        error.ControlDenied,
        session.verify_claim(takeover.view(), .monitor),
    );
    _ = try session.acquire_write_lease(takeover.view(), 2);
    try std.testing.expectEqual(
        contracts.AttentionState{
            .attention = .user_takeover,
            .write_lease = .human,
        },
        session.facts().attention,
    );
    const agent_claim = test_claim(test_persistence());
    try session.verify_claim(agent_claim, .read);
    try session.verify_claim(agent_claim, .screen);
    try session.verify_claim(agent_claim, .monitor);
    try std.testing.expectError(
        error.LeaseConflict,
        session.acquire_write_lease(agent_claim, 3),
    );
    _ = try session.release_write_lease(takeover.view(), 4);
    try std.testing.expectEqual(
        contracts.WriteLease.none,
        session.facts().attention.write_lease,
    );

    var forged = takeover.view();
    forged.proof.bytes[0] ^= 0xff;
    try std.testing.expectError(
        error.InvalidHolderProof,
        session.acquire_write_lease(forged, 5),
    );
}

test "human takeover lease is reclaimable only after its Fx process owner is gone" {
    const Match = struct {
        var result: process_supervisor.TokenMatch = .matched;

        fn process(
            _: ?*anyopaque,
            _: Allocator,
            _: []const u8,
            _: process_supervisor.ProcessInstanceToken,
        ) process_supervisor.TokenMatch {
            return result;
        }
    };

    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-takeover-reclaim");
    defer session.deinit();
    var owner = try fixture.owner_capability(
        "terminal-store-owner",
        .writable,
    );
    defer owner.deinit();
    var takeover = try reloadHumanTakeoverAuthorityClaim(alloc, &owner, .{
        .terminal_session_id = "terminal-takeover-reclaim",
        .profile_user = "profile-user",
        .durable_session_id = "terminal-store-owner",
        .workspace_root = "/workspace",
        .transport_role = .interactive,
        .actor = .human,
    });
    defer takeover.deinit();
    takeover.value.process_owner = try test_process_owner(
        alloc,
        fixture.profile.process_provider,
    );

    _ = try session.acquire_write_lease(takeover.view(), 2);
    try std.testing.expect(session.record.takeover_owner_pid != null);
    try std.testing.expect(session.record.takeover_owner_process_token != null);
    try std.testing.expectEqual(
        contracts.AttentionState{
            .attention = .user_takeover,
            .write_lease = .human,
        },
        session.facts().attention,
    );

    try session.persist_attention_state_locked(
        session.record.attention,
        "424242",
        session.record.takeover_owner_process_token,
        3,
    );
    var match_provider = fixture.profile.process_provider;
    match_provider.match_token_fn = Match.process;
    fixture.profile.process_provider = match_provider;

    Match.result = .matched;
    try std.testing.expectEqual(
        contracts.AttentionState{
            .attention = .user_takeover,
            .write_lease = .human,
        },
        session.facts().attention,
    );
    try std.testing.expectError(
        error.LeaseConflict,
        session.acquire_write_lease(takeover.view(), 4),
    );

    Match.result = .unavailable;
    _ = try session.authorize(test_claim(test_persistence()), .read);
    try std.testing.expectEqual(
        contracts.AttentionState{
            .attention = .user_takeover,
            .write_lease = .human,
        },
        session.facts().attention,
    );
    try std.testing.expectError(
        error.LeaseConflict,
        session.acquire_write_lease(test_claim(test_persistence()), 5),
    );

    Match.result = .mismatched;
    _ = try session.authorize(test_claim(test_persistence()), .read);
    try std.testing.expectEqual(
        contracts.AttentionState{},
        session.facts().attention,
    );
    try std.testing.expect(session.record.takeover_owner_pid == null);
    try std.testing.expect(session.record.takeover_owner_process_token == null);

    Match.result = .matched;
    _ = try session.acquire_write_lease(takeover.view(), 6);
    Match.result = .missing;
    _ = try session.authorize(test_claim(test_persistence()), .read);
    try std.testing.expectEqual(contracts.AttentionState{}, session.facts().attention);
    try std.testing.expect(session.record.takeover_owner_pid == null);
    try std.testing.expect(session.record.takeover_owner_process_token == null);

    const agent = test_claim(test_persistence());
    _ = try session.acquire_write_lease(agent, 7);
    _ = try session.authorize_write(agent);
    _ = try session.release_write_lease(agent, 8);

    Match.result = .matched;
    _ = try session.acquire_write_lease(takeover.view(), 9);
    _ = try session.authorize_write(takeover.view());
    try std.testing.expectEqual(
        contracts.AttentionState{
            .attention = .user_takeover,
            .write_lease = .human,
        },
        session.facts().attention,
    );

    _ = try session.release_write_lease(takeover.view(), 10);
    try std.testing.expect(session.record.takeover_owner_pid == null);
    try std.testing.expect(session.record.takeover_owner_process_token == null);
}

test "terminal records require takeover attention lease and owner as one state" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-takeover-invariant");
    defer session.deinit();

    var malformed = session.record;
    malformed.attention = .{
        .attention = .user_takeover,
        .write_lease = .human,
    };
    try std.testing.expectError(error.InvalidTerminalRecord, malformed.validate());

    const process_owner = try test_process_owner(
        alloc,
        fixture.profile.process_provider,
    );
    var pid_buffer: [32]u8 = undefined;
    const pid = try std.fmt.bufPrint(&pid_buffer, "{d}", .{process_owner.pid});
    malformed = session.record;
    malformed.takeover_owner_pid = @constCast(pid);
    malformed.takeover_owner_process_token = @constCast(process_owner.token());
    try std.testing.expectError(error.InvalidTerminalRecord, malformed.validate());
}

test "direct human authority exposes only the owning model observer controls" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var persistence = test_persistence();
    persistence.grant.actor = .human;
    persistence.direct_human_model_read_only = true;
    var session = try fixture.create_with_persistence(
        "terminal-direct-human",
        .{ .rows = 24, .columns = 80 },
        &.{},
        persistence,
    );
    defer session.deinit();

    var model = test_claim(persistence);
    model.actor = .agent;
    const observer = try session.authorize(model, .read);
    try std.testing.expectEqual(contracts.AllowedControls.observer(), observer.controls);
    try session.verify_claim(model, .screen);
    try session.verify_claim(model, .inspect);
    try session.verify_claim(model, .list);
    var human = test_claim(persistence);
    human.process_owner = try test_process_owner(
        alloc,
        fixture.profile.process_provider,
    );
    _ = try session.acquire_write_lease(human, 2);
    try std.testing.expectError(
        error.LeaseConflict,
        session.acquire_write_lease(model, 3),
    );
    _ = try session.release_write_lease(human, 4);
    try std.testing.expectError(
        error.ControlDenied,
        session.acquire_write_lease(model, 5),
    );
    inline for (.{
        contracts.Action.write,
        .wait,
        .monitor,
        .resize,
        .signal,
        .close,
    }) |action| {
        try std.testing.expectError(
            error.ControlDenied,
            session.verify_claim(model, action),
        );
    }
}

test "durable event IDs and acknowledgement cursor are monotonic and idempotent" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-events");
    defer session.deinit();
    const first = try session.append_event(.output, 2);
    const second = try session.append_event(.lifecycle, 3);
    try std.testing.expectEqual(@as(u64, 1), first);
    try std.testing.expectEqual(@as(u64, 2), second);
    try session.acknowledge(second, 4);
    try session.acknowledge(second, 5);
    try std.testing.expectEqual(second, session.record.acknowledged_event_id);
    try std.testing.expectEqual(@as(u64, 0), session.record.event_gap_through);
    try std.testing.expectEqual(second, session.record.event_cleanup_through);
    try std.testing.expectError(
        error.UnknownEventId,
        session.acknowledge(3, 6),
    );
    var reconnected = try fixture.profile.open_existing(
        "terminal-store-owner",
        "terminal-events",
    );
    defer reconnected.deinit();
    try reconnected.acknowledge(second, 7);
    try std.testing.expectEqual(second, reconnected.record.acknowledged_event_id);
}

test "monitor definitions load durably and event replay is bounded resumable and gap aware" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    const definitions = [_]contracts.MonitorDefinition{.{
        .condition = .process_exit,
        .notify_schedule = .on_exit,
        .lifetime = .until_session_end,
    }};
    var session = try fixture.create_with_monitors(
        "terminal-monitor-replay",
        .{ .rows = 24, .columns = 80 },
        &definitions,
    );
    defer session.deinit();
    var loaded = try session.load_monitor_definitions(alloc);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.view().len);
    try std.testing.expect(loaded.view()[0].condition == .process_exit);

    var index: u64 = 0;
    while (index < 300) : (index += 1) {
        _ = try session.append_event(.output, @intCast(index + 2));
    }
    var first = try session.replay_events(alloc, 0, 10);
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 44), first.gap_through);
    try std.testing.expectEqual(@as(usize, 10), first.events.len);
    try std.testing.expectEqual(@as(u64, 45), first.events[0].id);
    try std.testing.expectEqual(@as(u64, 54), first.events[9].id);
    try std.testing.expectEqual(@as(u64, 55), first.next_event_id);
    try session.acknowledge(54, 400);
    var resumed = try session.replay_events(alloc, 54, 10);
    defer resumed.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 55), resumed.events[0].id);
    try std.testing.expectError(
        error.InvalidEventReplayLimit,
        session.replay_events(alloc, 0, 0),
    );
}

const MonitorCrashCase = enum {
    every_check,
    every_n_checks,
    interval,
    match,
    path_baseline,
};

fn monitor_crash_definition(case: MonitorCrashCase) contracts.MonitorDefinition {
    return switch (case) {
        .every_check => .{
            .condition = .{ .path_exists = "/workspace/ready" },
            .check_schedule = .{ .interval_ms = 25 },
            .notify_schedule = .every_check,
            .lifetime = .until_session_end,
        },
        .every_n_checks => .{
            .condition = .{ .path_exists = "/workspace/ready" },
            .check_schedule = .{ .interval_ms = 25 },
            .notify_schedule = .{ .every_n_checks = 2 },
            .lifetime = .until_session_end,
        },
        .interval => .{
            .condition = .process_exit,
            .notify_schedule = .{ .interval = .{ .interval_ms = 25 } },
            .lifetime = .until_session_end,
        },
        .match => .{
            .condition = .{ .output_matches = "re*dy" },
            .notify_schedule = .on_match,
            .lifetime = .until_session_end,
        },
        .path_baseline => .{
            .condition = .{ .path_changed = "/workspace/output" },
            .check_schedule = .{ .interval_ms = 25 },
            .notify_schedule = .every_check,
            .lifetime = .until_session_end,
        },
    };
}

fn advance_monitor_crash_case(
    persisted: *monitor_core.PersistedMonitor,
    case: MonitorCrashCase,
) !monitor_core.EventReason {
    const decision = switch (case) {
        .every_check => try monitor_core.observe(persisted, .check, false, 26),
        .every_n_checks => blk: {
            _ = try monitor_core.observe(persisted, .check, false, 26);
            break :blk try monitor_core.observe(persisted, .check, false, 51);
        },
        .interval => try monitor_core.timer_decision(persisted, 26),
        .match => blk: {
            const matched = try monitor_core.pattern_feed(
                "re*dy",
                true,
                &persisted.runtime.matcher_states,
                "ready",
            );
            break :blk try monitor_core.observe(persisted, .output, matched, 26);
        },
        .path_baseline => blk: {
            persisted.runtime.path_baseline = .{
                .exists = true,
                .size = 73,
                .modified_ns = 91,
            };
            break :blk try monitor_core.observe(persisted, .check, false, 26);
        },
    };
    return decision.notify orelse error.TestExpectedMonitorNotification;
}

test "monitor notification crash recovery restores the exact evaluated runtime once" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    const cases = [_]MonitorCrashCase{
        .every_check,
        .every_n_checks,
        .interval,
        .match,
        .path_baseline,
    };
    const points = [_]FailurePoint{
        .after_event_write,
        .after_monitor_state_write,
        .after_monitor_event_record,
    };
    for (cases, 0..) |case, case_index| {
        for (points, 0..) |point, point_index| {
            const session_id = try std.fmt.allocPrint(
                alloc,
                "terminal-monitor-commit-{d}-{d}",
                .{ case_index, point_index },
            );
            defer alloc.free(session_id);
            const definition = monitor_crash_definition(case);
            var session = try fixture.create_with_monitors(
                session_id,
                .{ .rows = 24, .columns = 80 },
                &.{definition},
            );
            var set = try session.load_monitor_set(alloc);
            const reason = try advance_monitor_crash_case(
                &set.parsed.value.monitors[0],
                case,
            );
            fixture.profile.options.fail_at = point;
            try std.testing.expectError(
                error.InjectedCrash,
                session.commit_monitor_event(
                    set.parsed.value,
                    1,
                    reason,
                    60,
                ),
            );
            const expected_runtime = set.parsed.value.monitors[0].runtime;
            fixture.profile.options.fail_at = null;
            set.deinit();
            session.deinit();

            try fixture.reopen();
            var recovered = try fixture.profile.recover("host-reopen", 61);
            const recovered_index = recovered_session_index(
                recovered.sessions.items,
                session_id,
            ).?;
            var recovered_set = try recovered.sessions.items[recovered_index]
                .load_monitor_set(alloc);
            defer recovered_set.deinit();
            try std.testing.expect(std.meta.eql(
                expected_runtime,
                recovered_set.parsed.value.monitors[0].runtime,
            ));
            var replay = try recovered.sessions.items[recovered_index]
                .replay_events(alloc, 0, 16);
            defer replay.deinit(alloc);
            var monitor_events: usize = 0;
            for (replay.events) |event| {
                if (event.monitor_sequence == null) continue;
                monitor_events += 1;
                try std.testing.expectEqual(@as(u64, 1), event.id);
                try std.testing.expectEqual(@as(?u64, 1), event.monitor_sequence);
                try std.testing.expectEqual(
                    @as(?monitor_core.EventReason, reason),
                    event.monitor_reason,
                );
            }
            try std.testing.expectEqual(@as(usize, 1), monitor_events);
            recovered.deinit();
        }
    }
}

test "monitor transaction reconciliation reports the durable winner" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    const definition = monitor_crash_definition(.match);

    const state_cases = [_]struct {
        point: FailurePoint,
        outcome: MonitorCommitOutcome,
    }{
        .{ .point = .after_monitor_transaction_prepare, .outcome = .previous },
        .{ .point = .after_monitor_transaction_commit, .outcome = .candidate },
        .{ .point = .after_monitor_state_write, .outcome = .candidate },
        .{ .point = .after_monitor_record, .outcome = .candidate },
    };
    for (state_cases, 0..) |case, index| {
        const session_id = try std.fmt.allocPrint(
            alloc,
            "terminal-monitor-state-outcome-{d}",
            .{index},
        );
        defer alloc.free(session_id);
        var session = try fixture.create_with_monitors(
            session_id,
            .{ .rows = 24, .columns = 80 },
            &.{definition},
        );
        defer session.deinit();
        var current = try session.load_monitor_set(alloc);
        defer current.deinit();
        var monitors = [_]monitor_core.PersistedMonitor{
            current.parsed.value.monitors[0],
            .{
                .monitor_id = "monitor-2",
                .definition = definition,
                .runtime = try monitor_core.initial_runtime(definition, 10),
            },
        };
        const candidate = monitor_core.PersistedSet{
            .next_monitor_id = 3,
            .monitors = &monitors,
        };
        fixture.profile.options.fail_at = case.point;
        var durable_error: ?anyerror = null;
        session.persist_monitor_set(candidate, 10) catch |err| {
            durable_error = err;
        };
        fixture.profile.options.fail_at = null;
        try std.testing.expect(durable_error != null);
        try std.testing.expectEqual(
            case.outcome,
            try session.reconcile_monitor_commit(candidate),
        );
        var resolved = try session.load_monitor_set(alloc);
        defer resolved.deinit();
        try std.testing.expectEqual(
            @as(usize, if (case.outcome == .candidate) 2 else 1),
            resolved.parsed.value.monitors.len,
        );
    }

    const event_cases = [_]struct {
        point: FailurePoint,
        outcome: MonitorCommitOutcome,
    }{
        .{ .point = .after_monitor_transaction_prepare, .outcome = .previous },
        .{ .point = .after_monitor_event_indeterminate, .outcome = .candidate },
        .{ .point = .after_event_write, .outcome = .candidate },
        .{ .point = .after_monitor_state_write, .outcome = .candidate },
        .{ .point = .after_monitor_event_record, .outcome = .candidate },
    };
    for (event_cases, 0..) |case, index| {
        const session_id = try std.fmt.allocPrint(
            alloc,
            "terminal-monitor-event-outcome-{d}",
            .{index},
        );
        defer alloc.free(session_id);
        var session = try fixture.create_with_monitors(
            session_id,
            .{ .rows = 24, .columns = 80 },
            &.{definition},
        );
        defer session.deinit();
        var candidate = try session.load_monitor_set(alloc);
        defer candidate.deinit();
        const decision = try monitor_core.observe(
            &candidate.parsed.value.monitors[0],
            .output,
            true,
            10,
        );
        const reason = decision.notify.?;
        fixture.profile.options.fail_at = case.point;
        var durable_error: ?anyerror = null;
        _ = session.commit_monitor_event(
            candidate.parsed.value,
            1,
            reason,
            10,
        ) catch |err| failed: {
            durable_error = err;
            break :failed 0;
        };
        fixture.profile.options.fail_at = null;
        try std.testing.expect(durable_error != null);
        try std.testing.expectEqual(
            case.outcome,
            try session.reconcile_monitor_commit(candidate.parsed.value),
        );
        var replay = try session.replay_events(alloc, 0, 16);
        defer replay.deinit(alloc);
        try std.testing.expectEqual(
            @as(usize, if (case.outcome == .candidate) 1 else 0),
            replay.events.len,
        );
    }
}

test "monitor notification and automatic removal recover as one transition" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    const definition = contracts.MonitorDefinition{
        .condition = .{ .output_contains = "ready" },
        .notify_schedule = .on_match,
        .lifetime = .until_match,
    };
    const points = [_]FailurePoint{
        .after_event_write,
        .after_monitor_state_write,
        .after_monitor_event_record,
    };
    for (points, 0..) |point, index| {
        const session_id = try std.fmt.allocPrint(
            alloc,
            "terminal-monitor-remove-{d}",
            .{index},
        );
        defer alloc.free(session_id);
        var session = try fixture.create_with_monitors(
            session_id,
            .{ .rows = 24, .columns = 80 },
            &.{definition},
        );
        var candidate = try session.load_monitor_set(alloc);
        const decision = try monitor_core.observe(
            &candidate.parsed.value.monitors[0],
            .output,
            true,
            10,
        );
        try std.testing.expect(decision.remove);
        candidate.parsed.value.monitors =
            candidate.parsed.value.monitors[0..0];
        fixture.profile.options.fail_at = point;
        try std.testing.expectError(
            error.InjectedCrash,
            session.commit_monitor_event(
                candidate.parsed.value,
                1,
                decision.notify.?,
                10,
            ),
        );
        fixture.profile.options.fail_at = null;
        candidate.deinit();
        session.deinit();

        try fixture.reopen();
        var recovered = try fixture.profile.open_existing(
            "terminal-store-owner",
            session_id,
        );
        var recovered_set = try recovered.load_monitor_set(alloc);
        try std.testing.expectEqual(
            @as(usize, 0),
            recovered_set.parsed.value.monitors.len,
        );
        recovered_set.deinit();
        var replay = try recovered.replay_events(alloc, 0, 16);
        try std.testing.expectEqual(@as(usize, 1), replay.events.len);
        try std.testing.expectEqual(
            @as(?monitor_core.EventReason, .matched),
            replay.events[0].monitor_reason,
        );
        replay.deinit(alloc);
        recovered.deinit();
    }

    const silent_definition = contracts.MonitorDefinition{
        .condition = .{ .output_contains = "ready" },
        .notify_schedule = .on_exit,
        .lifetime = .until_match,
    };
    var silent = try fixture.create_with_monitors(
        "terminal-monitor-silent-remove",
        .{ .rows = 24, .columns = 80 },
        &.{silent_definition},
    );
    var silent_candidate = try silent.load_monitor_set(alloc);
    const silent_decision = try monitor_core.observe(
        &silent_candidate.parsed.value.monitors[0],
        .output,
        true,
        20,
    );
    try std.testing.expect(silent_decision.notify == null);
    try std.testing.expect(silent_decision.remove);
    silent_candidate.parsed.value.monitors =
        silent_candidate.parsed.value.monitors[0..0];
    fixture.profile.options.fail_at = .after_monitor_transaction_commit;
    try expect_monitor_candidate(silent.commit_monitor_transition(
        silent_candidate.parsed.value,
        null,
        20,
    ));
    fixture.profile.options.fail_at = null;
    var silent_replay = try silent.replay_events(alloc, 0, 16);
    try std.testing.expectEqual(@as(usize, 0), silent_replay.events.len);
    silent_replay.deinit(alloc);
    var silent_set = try silent.load_monitor_set(alloc);
    try std.testing.expectEqual(
        @as(usize, 0),
        silent_set.parsed.value.monitors.len,
    );
    silent_set.deinit();
    silent_candidate.deinit();
    silent.deinit();
}

test "nested monitor reconciliation failures do not duplicate add or resurrect remove" {
    const alloc = std.testing.allocator;
    const failures = [_]MonitorReconciliationFailure{
        .allocation,
        .io,
        .indeterminate,
    };
    for (failures, 0..) |failure, index| {
        var options = test_options();
        options.fail_at = .after_monitor_transaction_commit;
        options.fail_monitor_reconciliation_once = failure;
        var fixture = try TestStoreFixture.init(alloc, options);
        defer fixture.deinit();
        const session_id = try std.fmt.allocPrint(
            alloc,
            "terminal-monitor-nested-{d}",
            .{index},
        );
        defer alloc.free(session_id);
        var session = try fixture.create(session_id);
        const definition = monitor_crash_definition(.match);
        var monitor = monitor_core.PersistedMonitor{
            .monitor_id = "monitor-1",
            .definition = definition,
            .runtime = try monitor_core.initial_runtime(definition, 10),
        };
        const added = monitor_core.PersistedSet{
            .next_monitor_id = 2,
            .monitors = @as(*[1]monitor_core.PersistedMonitor, &monitor),
        };
        try expect_monitor_candidate(
            session.commit_monitor_transition(added, null, 10),
        );
        var after_add = try session.load_monitor_set(alloc);
        try std.testing.expectEqual(
            @as(usize, 1),
            after_add.parsed.value.monitors.len,
        );
        after_add.deinit();

        fixture.profile.options.fail_at = .after_event_write;
        fixture.profile.monitor_reconciliation_failure_count = 0;
        const removed = monitor_core.PersistedSet{
            .next_monitor_id = 2,
            .monitors = &.{},
        };
        try expect_monitor_candidate(session.commit_monitor_transition(
            removed,
            .{ .sequence = 1, .reason = .removed },
            11,
        ));
        fixture.profile.options.fail_at = null;
        var after_remove = try session.load_monitor_set(alloc);
        try std.testing.expectEqual(
            @as(usize, 0),
            after_remove.parsed.value.monitors.len,
        );
        after_remove.deinit();
        var replay = try session.replay_events(alloc, 0, 16);
        try std.testing.expectEqual(@as(usize, 1), replay.events.len);
        replay.deinit(alloc);
        session.deinit();

        try fixture.reopen();
        var reopened = try fixture.profile.open_existing(
            "terminal-store-owner",
            session_id,
        );
        var reopened_set = try reopened.load_monitor_set(alloc);
        try std.testing.expectEqual(
            @as(usize, 0),
            reopened_set.parsed.value.monitors.len,
        );
        reopened_set.deinit();
        var reopened_replay = try reopened.replay_events(alloc, 0, 16);
        try std.testing.expectEqual(@as(usize, 1), reopened_replay.events.len);
        reopened_replay.deinit(alloc);
        reopened.deinit();
    }
}

const ReconciliationCancellation = struct {
    observed_attempts: *std.atomic.Value(u8),
    cancelled: *std.atomic.Value(bool),

    fn run(self: *ReconciliationCancellation) void {
        while (self.observed_attempts.load(.acquire) == 0) {
            std.Thread.yield() catch std.atomic.spinLoopHint();
        }
        self.cancelled.store(true, .release);
    }
};

test "monitor reconciliation is bounded cancelable and retains its transaction" {
    const alloc = std.testing.allocator;
    const definition = monitor_crash_definition(.match);
    var monitor = monitor_core.PersistedMonitor{
        .monitor_id = "monitor-1",
        .definition = definition,
        .runtime = try monitor_core.initial_runtime(definition, 10),
    };
    const candidate = monitor_core.PersistedSet{
        .next_monitor_id = 2,
        .monitors = @as(*[1]monitor_core.PersistedMonitor, &monitor),
    };

    var bounded_options = test_options();
    bounded_options.fail_at = .after_monitor_transaction_commit;
    bounded_options.fail_monitor_reconciliation_once = .io;
    bounded_options.fail_monitor_reconciliation_count = 3;
    var bounded = try TestStoreFixture.init(alloc, bounded_options);
    defer bounded.deinit();
    var bounded_session = try bounded.create("terminal-monitor-bounded");
    defer bounded_session.deinit();
    const bounded_outcome = bounded_session.commit_monitor_transition_controlled(
        candidate,
        null,
        10,
        .{ .max_attempts = 3, .retry_delay_ms = 0 },
    );
    switch (bounded_outcome) {
        .indeterminate => |err| try std.testing.expectEqual(
            error.SessionChildStoreFailed,
            err,
        ),
        .previous, .candidate, .cancelled => return error.TestExpectedIndeterminateWinner,
    }
    var retained = (try load_monitor_transaction(
        alloc,
        try bounded_session.state_capability(),
        bounded_session.record.session_id,
    )).?;
    retained.deinit();
    bounded.profile.options.fail_at = null;
    bounded.profile.options.fail_monitor_reconciliation_once = null;
    try std.testing.expectEqual(
        MonitorCommitOutcome.candidate,
        try bounded_session.reconcile_monitor_commit(candidate),
    );

    var cancelled_options = test_options();
    cancelled_options.fail_at = .after_monitor_transaction_commit;
    cancelled_options.fail_monitor_reconciliation_once = .io;
    cancelled_options.fail_monitor_reconciliation_count = 3;
    var cancelled_fixture = try TestStoreFixture.init(alloc, cancelled_options);
    defer cancelled_fixture.deinit();
    var cancelled_session = try cancelled_fixture.create(
        "terminal-monitor-cancelled",
    );
    defer cancelled_session.deinit();
    var cancelled: std.atomic.Value(bool) = .init(false);
    var observed_attempts: std.atomic.Value(u8) = .init(0);
    var cancellation = ReconciliationCancellation{
        .observed_attempts = &observed_attempts,
        .cancelled = &cancelled,
    };
    const cancellation_thread = try std.Thread.spawn(
        .{},
        ReconciliationCancellation.run,
        .{&cancellation},
    );
    const cancelled_outcome = cancelled_session.commit_monitor_transition_controlled(
        candidate,
        null,
        10,
        .{
            .max_attempts = 3,
            .retry_delay_ms = 100,
            .cancelled = &cancelled,
            .observed_attempts = &observed_attempts,
        },
    );
    cancellation_thread.join();
    switch (cancelled_outcome) {
        .cancelled => {},
        .previous, .candidate, .indeterminate => return error.TestExpectedCancellation,
    }
    try std.testing.expectEqual(@as(u8, 1), observed_attempts.load(.acquire));
    var cancelled_transaction = (try load_monitor_transaction(
        alloc,
        try cancelled_session.state_capability(),
        cancelled_session.record.session_id,
    )).?;
    cancelled_transaction.deinit();
    cancelled_fixture.profile.options.fail_at = null;
    cancelled_fixture.profile.options.fail_monitor_reconciliation_once = null;
    try std.testing.expectEqual(
        MonitorCommitOutcome.candidate,
        try cancelled_session.reconcile_monitor_commit(candidate),
    );
    var recovered = try cancelled_session.load_monitor_set(alloc);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 1), recovered.parsed.value.monitors.len);

    cancelled_fixture.profile.options.fail_at = .after_monitor_transaction_commit;
    var cancelled_before_session = try cancelled_fixture.create(
        "terminal-monitor-cancelled-before",
    );
    defer cancelled_before_session.deinit();
    var cancelled_before: std.atomic.Value(bool) = .init(true);
    switch (cancelled_before_session.commit_monitor_transition_controlled(
        candidate,
        null,
        10,
        .{ .cancelled = &cancelled_before },
    )) {
        .cancelled => {},
        .previous, .candidate, .indeterminate => return error.TestExpectedCancellation,
    }
    var before_transaction = (try load_monitor_transaction(
        alloc,
        try cancelled_before_session.state_capability(),
        cancelled_before_session.record.session_id,
    )).?;
    before_transaction.deinit();
    cancelled_fixture.profile.options.fail_at = null;
    try std.testing.expectEqual(
        MonitorCommitOutcome.candidate,
        try cancelled_before_session.reconcile_monitor_commit(candidate),
    );
}

test "exact monitor admission reserves runtime and event transaction headroom" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-monitor-byte-limit");

    const large_command = try alloc.alloc(u8, contracts.max_command_bytes);
    defer alloc.free(large_command);
    @memset(large_command, 'x');
    var id_buffers: [contracts.max_monitor_definitions][64]u8 = undefined;
    var monitors: [contracts.max_monitor_definitions]monitor_core.PersistedMonitor = undefined;
    for (&monitors, 0..) |*persisted, index| {
        const sequence: u64 = @intCast(index + 1);
        const definition = contracts.MonitorDefinition{
            .condition = .{ .custom_probe = .{
                .command = large_command,
                .cwd = "/workspace",
            } },
            .check_schedule = .{ .interval_ms = 25 },
            .notify_schedule = .every_check,
            .lifetime = .until_session_end,
        };
        persisted.* = .{
            .monitor_id = try monitor_core.stable_id(&id_buffers[index], sequence),
            .definition = definition,
            .runtime = try monitor_core.initial_runtime(definition, 1),
        };
    }

    var accepted_count: usize = 0;
    for (1..contracts.max_monitor_definitions + 1) |count| {
        const candidate = monitor_core.PersistedSet{
            .next_monitor_id = @intCast(count + 1),
            .monitors = monitors[0..count],
        };
        session.ensure_monitor_admission(candidate) catch |err| {
            try std.testing.expectEqual(error.MonitorStateTooLarge, err);
            break;
        };
        try session.persist_monitor_set(candidate, @intCast(count + 1));
        accepted_count = count;
    }
    try std.testing.expect(accepted_count > 0);
    try std.testing.expect(accepted_count + 1 < contracts.max_monitor_definitions);
    var after_failed_add = try session.load_monitor_set(alloc);
    try std.testing.expectEqual(
        accepted_count,
        after_failed_add.parsed.value.monitors.len,
    );
    after_failed_add.deinit();

    var exact_monitors = monitors;
    const adjustable_start = accepted_count - 1;
    const exact_count = accepted_count + 1;
    for (adjustable_start..exact_count) |index| {
        exact_monitors[index].definition.condition.custom_probe.command = large_command[0..1];
    }
    var exact = monitor_core.PersistedSet{
        .next_monitor_id = @intCast(exact_count + 1),
        .monitors = exact_monitors[0..exact_count],
    };
    var set_bytes = try render_json(alloc, exact);
    var remaining = monitor_admission_bytes_limit - set_bytes.len;
    alloc.free(set_bytes);
    for (adjustable_start..exact_count) |index| {
        const increase = @min(remaining, large_command.len - 1);
        exact_monitors[index].definition.condition.custom_probe.command =
            large_command[0 .. increase + 1];
        remaining -= increase;
    }
    try std.testing.expectEqual(@as(usize, 0), remaining);
    exact.monitors = exact_monitors[0..exact_count];
    set_bytes = try render_json(alloc, exact);
    try std.testing.expectEqual(monitor_admission_bytes_limit, set_bytes.len);
    alloc.free(set_bytes);
    try session.ensure_monitor_admission(exact);
    try session.persist_monitor_set(exact, 50);

    var oversized_update_monitors = exact_monitors;
    const update_index = if (oversized_update_monitors[adjustable_start]
        .definition.condition.custom_probe.command.len < large_command.len)
        adjustable_start
    else
        adjustable_start + 1;
    oversized_update_monitors[update_index]
        .definition.condition.custom_probe.command = large_command;
    try std.testing.expectError(
        error.MonitorStateTooLarge,
        session.ensure_monitor_admission(.{
            .next_monitor_id = exact.next_monitor_id,
            .monitors = oversized_update_monitors[0..exact_count],
        }),
    );

    var oversized_add_monitors = exact_monitors;
    oversized_add_monitors[exact_count].definition.condition.custom_probe.command =
        large_command[0..1];
    try std.testing.expectError(
        error.MonitorStateTooLarge,
        session.ensure_monitor_admission(.{
            .next_monitor_id = exact.next_monitor_id + 1,
            .monitors = oversized_add_monitors[0 .. exact_count + 1],
        }),
    );
    var unchanged = try session.load_monitor_set(alloc);
    try std.testing.expect(try monitor_sets_equal(
        alloc,
        exact,
        unchanged.parsed.value,
    ));
    unchanged.deinit();

    var event_candidate = try MonitorSet.clone(alloc, exact);
    defer event_candidate.deinit();
    const decision = try monitor_core.observe(
        &event_candidate.parsed.value.monitors[0],
        .check,
        true,
        53,
    );
    try std.testing.expectEqual(monitor_core.EventReason.check, decision.notify.?);
    set_bytes = try render_json(alloc, event_candidate.parsed.value);
    try std.testing.expect(set_bytes.len <= monitor_set_bytes_limit);
    alloc.free(set_bytes);
    const largest_transaction = MonitorTransaction{
        .committed = true,
        .updated_at_ms = std.math.maxInt(i64),
        .candidate = event_candidate.parsed.value,
        .event = .{
            .id = std.math.maxInt(u64) - 1,
            .kind = .monitor,
            .lifecycle = .starting,
            .cursor = .{
                .segment = std.math.maxInt(u64),
                .offset = std.math.maxInt(u64),
            },
            .created_at_ms = std.math.maxInt(i64),
            .monitor_sequence = std.math.maxInt(u64),
            .monitor_reason = .state_changed,
        },
    };
    const transaction_bytes = try render_json(alloc, largest_transaction);
    try std.testing.expect(
        transaction_bytes.len <= monitor_transaction_bytes_limit,
    );
    alloc.free(transaction_bytes);
    try expect_monitor_candidate(session.commit_monitor_transition(
        event_candidate.parsed.value,
        .{ .sequence = 1, .reason = decision.notify.? },
        53,
    ));
    session.deinit();

    try fixture.reopen();
    var reopened = try fixture.profile.open_existing(
        "terminal-store-owner",
        "terminal-monitor-byte-limit",
    );
    var reopened_owned = true;
    defer if (reopened_owned) reopened.deinit();
    var reopened_set = try reopened.load_monitor_set(alloc);
    try std.testing.expect(try monitor_sets_equal(
        alloc,
        event_candidate.parsed.value,
        reopened_set.parsed.value,
    ));
    reopened_set.deinit();
    var replay = try reopened.replay_events(alloc, 0, 16);
    try std.testing.expectEqual(@as(usize, 1), replay.events.len);
    const event_id = replay.events[0].id;
    replay.deinit(alloc);
    try reopened.acknowledge(event_id, 54);
    reopened.deinit();
    reopened_owned = false;

    try fixture.reopen();
    var acknowledged = try fixture.profile.open_existing(
        "terminal-store-owner",
        "terminal-monitor-byte-limit",
    );
    defer acknowledged.deinit();
    var after_ack = try acknowledged.replay_events(alloc, event_id, 16);
    defer after_ack.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), after_ack.events.len);
}

test "quota eviction selects oldest completed output before checkpoints and covered live journals" {
    var candidates = [_]PayloadCandidate{
        .{
            .owner_session_id = undefined,
            .session_id = @constCast("completed-new"),
            .lifecycle = .exited,
            .created_at_ms = 20,
            .journal_bytes = 1,
            .checkpoint_bytes = 1,
            .covered_live_bytes = 0,
        },
        .{
            .owner_session_id = undefined,
            .session_id = @constCast("live-old"),
            .lifecycle = .running,
            .created_at_ms = 1,
            .journal_bytes = 1,
            .checkpoint_bytes = 1,
            .covered_live_bytes = 1,
        },
        .{
            .owner_session_id = undefined,
            .session_id = @constCast("completed-old"),
            .lifecycle = .closed,
            .created_at_ms = 10,
            .journal_bytes = 1,
            .checkpoint_bytes = 1,
            .covered_live_bytes = 0,
        },
    };
    var selected = choose_eviction(&candidates, "active").?;
    try std.testing.expectEqual(EvictionClass.completed_output, selected.class);
    try std.testing.expectEqual(@as(usize, 2), selected.index);
    candidates[0].journal_bytes = 0;
    candidates[2].journal_bytes = 0;
    selected = choose_eviction(&candidates, "active").?;
    try std.testing.expectEqual(EvictionClass.completed_checkpoint, selected.class);
    candidates[0].checkpoint_bytes = 0;
    candidates[2].checkpoint_bytes = 0;
    selected = choose_eviction(&candidates, "active").?;
    try std.testing.expectEqual(EvictionClass.live_covered_journal, selected.class);
}

test "live quota evicts only journal segments covered by the pinned checkpoint" {
    const alloc = std.testing.allocator;
    var options = test_options();
    options.per_session_limit = 105 * 1024;
    options.segment_bytes = 1024;
    var fixture = try TestStoreFixture.init(alloc, options);
    defer fixture.deinit();
    var session = try fixture.create("terminal-live-quota");
    defer session.deinit();
    const block: [1000]u8 = @splat('x');
    for (0..10) |index| try session.append(&block, @intCast(index + 2));
    const payload = "checkpoint";
    const envelope = contracts.CheckpointEnvelope{
        .engine_schema_revision = 1,
        .applied_cursor = session.record.output_cursor,
        .payload_len = payload.len,
        .checksum = contracts.checkpoint_checksum(payload),
    };
    try session.store_checkpoint(envelope, payload, 20);
    const additional: [5000]u8 = @splat('y');
    try session.append(&additional, 21);
    try std.testing.expect(session.record.raw_gap != null);
    try std.testing.expectEqual(
        contracts.RawCursor{ .segment = 1, .offset = 9 * 1024 },
        session.record.available_from,
    );
    try std.testing.expect(session.record.screen_recovery == .available);
    try std.testing.expectError(
        error.CapacityExceeded,
        session.check_resize_capacity(.{ .rows = 100, .columns = 100 }),
    );
}

test "checkpoint cadence follows the journal byte boundary" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-checkpoint-cadence");
    defer session.deinit();

    for ("abc") |byte| {
        try session.append(&.{byte}, 2);
        try std.testing.expect(session.checkpoint_due_cursor() == null);
    }
    try std.testing.expectEqual(@as(u64, 0), session.record.checkpoint_generation);

    try session.append("d", 3);
    const first_cursor = session.checkpoint_due_cursor().?;
    try std.testing.expectEqual(
        contracts.RawCursor{ .segment = 1, .offset = 4 },
        first_cursor,
    );
    const payload = "checkpoint";
    try session.store_checkpoint(.{
        .engine_schema_revision = 1,
        .applied_cursor = first_cursor,
        .payload_len = payload.len,
        .checksum = contracts.checkpoint_checksum(payload),
    }, payload, 4);
    try std.testing.expectEqual(@as(u64, 1), session.record.checkpoint_generation);

    for ("efg") |byte| {
        try session.append(&.{byte}, 5);
        try std.testing.expect(session.checkpoint_due_cursor() == null);
    }
    try session.append("h", 6);
    try std.testing.expectEqual(
        contracts.RawCursor{ .segment = 1, .offset = 8 },
        session.checkpoint_due_cursor().?,
    );
    try std.testing.expectEqual(@as(u64, 1), session.record.checkpoint_generation);
}

test "failed resize checkpoint stays unavailable after fresh reopen" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create_with_dimensions(
        "terminal-resize-checkpoint-failure",
        .{ .rows = 2, .columns = 4 },
    );
    try session.append("abcdef", 2);
    const before_payload = "before";
    try session.store_checkpoint(.{
        .engine_schema_revision = 1,
        .applied_cursor = session.record.output_cursor,
        .payload_len = before_payload.len,
        .checksum = contracts.checkpoint_checksum(before_payload),
    }, before_payload, 3);

    const resized = contracts.Dimensions{ .rows = 2, .columns = 6 };
    try session.resize(resized, 4);
    try std.testing.expect(!session.record.raw_replay_exact);
    try std.testing.expectEqual(
        contracts.ScreenRecovery{ .unavailable = .resize_uncheckpointed },
        session.record.screen_recovery,
    );

    fixture.profile.options.fail_at = .checkpoint_replacement;
    const resized_payload = "resized";
    try std.testing.expectError(error.InjectedFailure, session.store_checkpoint(.{
        .engine_schema_revision = 1,
        .applied_cursor = session.record.output_cursor,
        .payload_len = resized_payload.len,
        .checksum = contracts.checkpoint_checksum(resized_payload),
    }, resized_payload, 5));
    fixture.profile.options.fail_at = null;
    session.deinit();
    try fixture.reopen();

    var reopened = try fixture.profile.open_existing(
        "terminal-store-owner",
        "terminal-resize-checkpoint-failure",
    );
    defer reopened.deinit();
    try std.testing.expectEqual(resized, reopened.record.dimensions);
    try std.testing.expect(!reopened.record.raw_replay_exact);
    try std.testing.expectEqual(
        contracts.ScreenRecovery{ .unavailable = .resize_uncheckpointed },
        reopened.facts().screen_recovery,
    );
}

test "profile quota serializes concurrent commitments at fixed limits" {
    const alloc = std.testing.allocator;
    const small_reserve = try checkpoint_reserve_bytes(.{ .rows = 1, .columns = 1 });
    {
        var fixture = try TestStoreFixture.init(alloc, .{
            .per_session_limit = small_reserve + 8,
            .profile_limit = small_reserve * 2 + 8,
            .segment_bytes = 4,
        });
        defer fixture.deinit();
        var first = try fixture.create_with_dimensions(
            "terminal-concurrent-append-a",
            .{ .rows = 1, .columns = 1 },
        );
        defer first.deinit();
        var second = try fixture.create_with_dimensions(
            "terminal-concurrent-append-b",
            .{ .rows = 1, .columns = 1 },
        );
        defer second.deinit();
        try std.testing.expectError(
            error.CapacityExceeded,
            fixture.create_with_dimensions(
                "terminal-concurrent-start-c",
                .{ .rows = 1, .columns = 1 },
            ),
        );
        var first_attempt = ConcurrentAppend{ .session = &first };
        var second_attempt = ConcurrentAppend{ .session = &second };
        const first_thread = try std.Thread.spawn(.{}, ConcurrentAppend.run, .{&first_attempt});
        const second_thread = try std.Thread.spawn(.{}, ConcurrentAppend.run, .{&second_attempt});
        first_thread.join();
        second_thread.join();
        const failures = @as(usize, @intFromBool(first_attempt.result != null)) +
            @as(usize, @intFromBool(second_attempt.result != null));
        try std.testing.expectEqual(@as(usize, 1), failures);
        const failure = first_attempt.result orelse second_attempt.result.?;
        try std.testing.expectEqual(error.CapacityExceeded, failure);
    }
    {
        const large_reserve = try checkpoint_reserve_bytes(.{
            .rows = 100,
            .columns = 100,
        });
        var fixture = try TestStoreFixture.init(alloc, .{
            .per_session_limit = large_reserve,
            .profile_limit = small_reserve + large_reserve,
            .segment_bytes = 4,
        });
        defer fixture.deinit();
        var first = try fixture.create_with_dimensions(
            "terminal-concurrent-resize-a",
            .{ .rows = 1, .columns = 1 },
        );
        defer first.deinit();
        var second = try fixture.create_with_dimensions(
            "terminal-concurrent-resize-b",
            .{ .rows = 1, .columns = 1 },
        );
        defer second.deinit();
        var first_attempt = ConcurrentResize{ .session = &first };
        var second_attempt = ConcurrentResize{ .session = &second };
        const first_thread = try std.Thread.spawn(.{}, ConcurrentResize.run, .{&first_attempt});
        const second_thread = try std.Thread.spawn(.{}, ConcurrentResize.run, .{&second_attempt});
        first_thread.join();
        second_thread.join();
        const failures = @as(usize, @intFromBool(first_attempt.result != null)) +
            @as(usize, @intFromBool(second_attempt.result != null));
        try std.testing.expectEqual(@as(usize, 1), failures);
        const failure = first_attempt.result orelse second_attempt.result.?;
        try std.testing.expectEqual(error.CapacityExceeded, failure);
    }
}

test "resident quota eviction mutates the single durable owner" {
    const alloc = std.testing.allocator;
    const reserve = try checkpoint_reserve_bytes(.{ .rows = 1, .columns = 1 });
    var fixture = try TestStoreFixture.init(alloc, .{
        .per_session_limit = reserve + 4,
        .profile_limit = reserve + 4,
        .segment_bytes = 4,
    });
    defer fixture.deinit();
    var completed = try fixture.create_with_dimensions(
        "terminal-resident-completed",
        .{ .rows = 1, .columns = 1 },
    );
    defer completed.deinit();
    try fixture.profile.register_resident(&completed);
    try completed.append("done", 2);
    try completed.persist_lost(3);

    var active = try fixture.create_with_dimensions(
        "terminal-resident-active",
        .{ .rows = 1, .columns = 1 },
    );
    defer active.deinit();
    try fixture.profile.register_resident(&active);
    try active.append("live", 4);
    try std.testing.expectEqual(@as(u64, 0), completed.record.journal_payload_bytes);
    const resident_facts = completed.facts();
    try std.testing.expect(resident_facts.raw_gap != null);
    try std.testing.expect(resident_facts.unread_range == null);
    try expect_close_candidate(completed.begin_close(
        test_claim(test_persistence()),
        5,
    ));
    try completed.finish_close(5);

    var reopened = try fixture.profile.open_existing(
        "terminal-store-owner",
        "terminal-resident-completed",
    );
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u64, 0), reopened.record.journal_payload_bytes);
    try std.testing.expectEqual(contracts.Lifecycle.closed, reopened.record.lifecycle);
}

test "close intent converges every durable boundary without reviving authority" {
    const alloc = std.testing.allocator;
    const definition = contracts.MonitorDefinition{
        .condition = .process_exit,
        .notify_schedule = .on_exit,
        .lifetime = .until_session_end,
    };
    const points = [_]FailurePoint{
        .after_close_authority_write,
        .after_close_record_write,
        .after_close_authority_event,
        .after_close_monitor_transaction_prepare,
        .after_close_monitor_event,
        .after_close_monitor_state_write,
        .after_close_monitor_record_write,
        .after_close_monitor_cleanup,
        .after_close_lifecycle_record,
        .after_close_lifecycle_event,
        .after_close_cleanup,
    };
    for (points, 0..) |point, index| {
        var fixture = try TestStoreFixture.init(alloc, test_options());
        defer fixture.deinit();
        const session_id = try std.fmt.allocPrint(
            alloc,
            "terminal-close-boundary-{d}",
            .{index},
        );
        defer alloc.free(session_id);
        const persistence = test_persistence();
        const claim = test_claim(persistence);
        var session = try fixture.create_with_persistence(
            session_id,
            .{ .rows = 24, .columns = 80 },
            &.{definition},
            persistence,
        );
        fixture.profile.options.fail_at = point;
        const outcome = session.begin_close(claim, 2);
        switch (outcome) {
            .candidate => {},
            .previous, .indeterminate => return error.TestExpectedCandidateWinner,
        }
        if (point == .after_close_monitor_transaction_prepare or
            point == .after_close_monitor_event or
            point == .after_close_monitor_state_write or
            point == .after_close_monitor_record_write or
            point == .after_close_monitor_cleanup or
            point == .after_close_lifecycle_record or
            point == .after_close_lifecycle_event or
            point == .after_close_cleanup)
        {
            try std.testing.expectError(error.InjectedCrash, session.finish_close(3));
        }
        fixture.profile.options.fail_at = null;
        session.deinit();
        try fixture.reopen();

        var recovered = try fixture.profile.recover("host-reopen", 4);
        defer recovered.deinit();
        const recovered_index = recovered_session_index(
            recovered.sessions.items,
            session_id,
        ).?;
        const reopened = &recovered.sessions.items[recovered_index];
        try reopened.finish_close(5);
        try std.testing.expectEqual(contracts.Lifecycle.closed, reopened.record.lifecycle);
        try std.testing.expect(reopened.record.authority_revoked);
        try std.testing.expectEqual(@as(usize, 0), reopened.record.monitor_count);
        try std.testing.expectError(
            error.AuthorityRevoked,
            reopened.authorize(claim, .read),
        );
        var replay = try reopened.replay_events(alloc, 0, 16);
        defer replay.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 3), replay.events.len);
        var authority_events: usize = 0;
        var session_exit_events: usize = 0;
        var closed_events: usize = 0;
        var previous_id: u64 = 0;
        for (replay.events) |event| {
            try std.testing.expect(event.id > previous_id);
            previous_id = event.id;
            if (event.kind == .authority_revoked) authority_events += 1;
            if (event.kind == .monitor and
                event.monitor_reason == .session_exit)
            {
                session_exit_events += 1;
            }
            if (event.kind == .lifecycle and event.lifecycle == .closed) {
                closed_events += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), authority_events);
        try std.testing.expectEqual(@as(usize, 1), session_exit_events);
        try std.testing.expectEqual(@as(usize, 1), closed_events);
        const transaction_name = try close_transaction_name(alloc, session_id);
        defer alloc.free(transaction_name);
        try std.testing.expectError(
            error.FileNotFound,
            (try reopened.state_capability()).stat(
                .terminal_state,
                transaction_name,
            ),
        );
        const monitor_transaction = try monitor_transaction_name(
            alloc,
            session_id,
        );
        defer alloc.free(monitor_transaction);
        try std.testing.expectError(
            error.FileNotFound,
            (try reopened.state_capability()).stat(
                .terminal_state,
                monitor_transaction,
            ),
        );
    }

    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    const persistence = test_persistence();
    const claim = test_claim(persistence);
    var usable = try fixture.create_with_persistence(
        "terminal-close-previous",
        .{ .rows = 24, .columns = 80 },
        &.{},
        persistence,
    );
    defer usable.deinit();
    fixture.profile.options.fail_at = .close;
    switch (usable.begin_close(claim, 2)) {
        .previous => |err| try std.testing.expectEqual(error.InjectedFailure, err),
        .candidate, .indeterminate => return error.TestExpectedPreviousWinner,
    }
    fixture.profile.options.fail_at = null;
    _ = try usable.authorize(claim, .write);
    try std.testing.expectEqual(contracts.Lifecycle.starting, usable.record.lifecycle);
    try std.testing.expect(!usable.record.authority_revoked);
}

test "close retries authenticate only while the durable winner remains" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    const persistence = test_persistence();
    const claim = test_claim(persistence);
    var foreign = claim;
    foreign.principal.cwd = "/foreign";
    var malformed = claim;
    malformed.generation.value = 0;

    var partial = try fixture.create_with_persistence(
        "terminal-close-authenticated-retry",
        .{ .rows = 24, .columns = 80 },
        &.{},
        persistence,
    );
    defer partial.deinit();
    fixture.profile.options.fail_at = .after_close_authority_event;
    switch (partial.begin_close(claim, 2)) {
        .candidate => |err| try std.testing.expectEqual(error.InjectedCrash, err.?),
        .previous, .indeterminate => return error.TestExpectedCandidateWinner,
    }
    fixture.profile.options.fail_at = null;
    switch (partial.begin_close(foreign, 3)) {
        .previous => |err| try std.testing.expectEqual(error.InvalidHolderProof, err),
        .candidate, .indeterminate => return error.TestExpectedPreviousWinner,
    }
    switch (partial.begin_close(malformed, 3)) {
        .previous => {},
        .candidate, .indeterminate => return error.TestExpectedPreviousWinner,
    }
    try expect_close_candidate(partial.begin_close(claim, 3));
    try partial.finish_close(4);

    for ([_]contracts.AuthorityClaim{ claim, foreign, malformed }) |retry| {
        switch (partial.begin_close(retry, 5)) {
            .previous => {},
            .candidate, .indeterminate => return error.TestExpectedPreviousWinner,
        }
    }
    var replay = try partial.replay_events(alloc, 0, 16);
    defer replay.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), replay.events.len);
    try std.testing.expectEqual(
        contracts.HostEvent.authority_revoked,
        replay.events[0].kind,
    );
    try std.testing.expectEqual(contracts.HostEvent.lifecycle, replay.events[1].kind);
}

test "close intent fences later monitor and lifecycle mutations" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    const persistence = test_persistence();
    var session = try fixture.create_with_persistence(
        "terminal-close-fence",
        .{ .rows = 24, .columns = 80 },
        &.{},
        persistence,
    );
    defer session.deinit();
    try expect_close_candidate(session.begin_close(
        test_claim(persistence),
        2,
    ));
    {
        var candidate = try session.load_monitor_set(alloc);
        defer candidate.deinit();
        switch (session.commit_monitor_transition(
            candidate.parsed.value,
            null,
            3,
        )) {
            .previous => |err| try std.testing.expectEqual(
                error.CloseIntentCommitted,
                err,
            ),
            .candidate, .cancelled, .indeterminate => {
                return error.TestExpectedPreviousWinner;
            },
        }
    }
    try std.testing.expectError(
        error.CloseIntentCommitted,
        session.persist_termination(.{ .exited = 0 }, 3),
    );
    try std.testing.expectError(
        error.CloseIntentCommitted,
        session.persist_lost(3),
    );
    try session.finish_close(4);
}

test "close orders a retained monitor event before revocation and lifecycle" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    const persistence = test_persistence();
    const definition = monitor_crash_definition(.match);
    var session = try fixture.create_with_persistence(
        "terminal-close-after-monitor",
        .{ .rows = 24, .columns = 80 },
        &.{definition},
        persistence,
    );
    defer session.deinit();
    {
        var candidate = try session.load_monitor_set(alloc);
        defer candidate.deinit();
        const decision = try monitor_core.observe(
            &candidate.parsed.value.monitors[0],
            .output,
            true,
            2,
        );
        fixture.profile.options.fail_at = .after_event_write;
        try std.testing.expectError(
            error.InjectedCrash,
            session.commit_monitor_event(
                candidate.parsed.value,
                1,
                decision.notify.?,
                2,
            ),
        );
    }
    fixture.profile.options.fail_at = null;
    try expect_close_candidate(session.begin_close(
        test_claim(persistence),
        3,
    ));
    try session.finish_close(4);
    var events = try session.replay_events(alloc, 0, 16);
    defer events.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), events.events.len);
    try std.testing.expectEqual(contracts.HostEvent.monitor, events.events[0].kind);
    try std.testing.expectEqual(
        contracts.HostEvent.authority_revoked,
        events.events[1].kind,
    );
    try std.testing.expectEqual(contracts.HostEvent.lifecycle, events.events[2].kind);
}

test "durable failure boundaries do not report success" {
    const alloc = std.testing.allocator;
    for ([_]FailurePoint{ .grant, .start }) |point| {
        var options = test_options();
        options.fail_at = point;
        var fixture = try TestStoreFixture.init(alloc, options);
        defer fixture.deinit();
        try std.testing.expectError(
            error.InjectedFailure,
            fixture.create(if (point == .grant) "terminal-fail-grant" else "terminal-fail-start"),
        );
        var state = try fixture.profile.open_capability(
            "terminal-store-owner",
            false,
        );
        defer state.deinit();
        const id = if (point == .grant)
            "terminal-fail-grant"
        else
            "terminal-fail-start";
        const name = try record_name(alloc, id);
        defer alloc.free(name);
        try std.testing.expectError(
            error.FileNotFound,
            state.stat(.terminal_state, name),
        );
    }

    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-failures");
    defer session.deinit();
    const payload = "checkpoint";
    const envelope = contracts.CheckpointEnvelope{
        .engine_schema_revision = 1,
        .applied_cursor = session.record.output_cursor,
        .payload_len = payload.len,
        .checksum = contracts.checkpoint_checksum(payload),
    };
    fixture.profile.options.fail_at = .append;
    try std.testing.expectError(error.InjectedFailure, session.append("x", 2));
    fixture.profile.options.fail_at = .checkpoint_replacement;
    try std.testing.expectError(
        error.InjectedFailure,
        session.store_checkpoint(envelope, payload, 3),
    );
    fixture.profile.options.fail_at = null;
    const event_id = try session.append_event(.output, 4);
    fixture.profile.options.fail_at = .acknowledgement;
    try std.testing.expectError(
        error.InjectedFailure,
        session.acknowledge(event_id, 5),
    );
    fixture.profile.options.fail_at = .revoke;
    try std.testing.expectError(error.InjectedFailure, session.revoke(6));
    fixture.profile.options.fail_at = .close;
    switch (session.begin_close(test_claim(test_persistence()), 7)) {
        .previous => |err| try std.testing.expectEqual(error.InjectedFailure, err),
        else => return error.TestExpectedPreviousWinner,
    }
    fixture.profile.options.fail_at = .finalization;
    try std.testing.expectError(error.InjectedFailure, session.persist_lost(8));
}

test "recovery discovers and removes partial start artifacts after durable effects" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    const points = [_]FailurePoint{
        .after_journal_create,
        .after_proof_write,
        .after_authority_write,
        .after_monitor_write,
    };
    for (points, 0..) |point, index| {
        const id = try std.fmt.allocPrint(alloc, "terminal-partial-{d}", .{index});
        defer alloc.free(id);
        fixture.profile.options.fail_at = point;
        try std.testing.expectError(error.InjectedCrash, fixture.create(id));
        fixture.profile.options.fail_at = null;
        try fixture.reopen();
        var recovered = try fixture.profile.recover("host-reopen", 10);
        defer recovered.deinit();
        try std.testing.expectEqual(@as(usize, 0), recovered.sessions.items.len);
        try std.testing.expectEqual(@as(usize, 1), recovered.diagnostics.items.len);
        try std.testing.expectEqualStrings(
            "PartialStartArtifacts",
            recovered.diagnostics.items[0].reason,
        );
    }
}

test "fresh reopen reconciles journal checkpoint event authority and cleanup commits" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();

    var journal = try fixture.create("terminal-crash-journal");
    try journal.append("base", 2);
    fixture.profile.options.fail_at = .after_journal_sync;
    try std.testing.expectError(error.InjectedCrash, journal.append("tail", 3));
    fixture.profile.options.fail_at = null;
    journal.deinit();
    try fixture.reopen();
    var journal_recovery = try fixture.profile.recover("host-reopen", 4);
    try std.testing.expectEqual(@as(usize, 1), journal_recovery.sessions.items.len);
    var page = try journal_recovery.sessions.items[0].read(
        alloc,
        .{ .segment = 1, .offset = 0 },
        64,
    );
    try std.testing.expectEqualStrings("base", page.output);
    page.deinit(alloc);
    journal_recovery.deinit();

    var checkpoint = try fixture.create("terminal-crash-checkpoint");
    const first_payload = "first";
    try checkpoint.store_checkpoint(.{
        .engine_schema_revision = 1,
        .applied_cursor = checkpoint.record.output_cursor,
        .payload_len = first_payload.len,
        .checksum = contracts.checkpoint_checksum(first_payload),
    }, first_payload, 2);
    const second_payload = "second";
    fixture.profile.options.fail_at = .after_checkpoint_write;
    try std.testing.expectError(error.InjectedCrash, checkpoint.store_checkpoint(.{
        .engine_schema_revision = 1,
        .applied_cursor = checkpoint.record.output_cursor,
        .payload_len = second_payload.len,
        .checksum = contracts.checkpoint_checksum(second_payload),
    }, second_payload, 3));
    fixture.profile.options.fail_at = null;
    checkpoint.deinit();
    try fixture.reopen();
    var checkpoint_recovery = try fixture.profile.recover("host-reopen", 4);
    const checkpoint_index = recovered_session_index(
        checkpoint_recovery.sessions.items,
        "terminal-crash-checkpoint",
    ).?;
    var loaded = (try checkpoint_recovery.sessions.items[checkpoint_index]
        .load_checkpoint(alloc)).?;
    try std.testing.expectEqualStrings(first_payload, loaded.payload);
    loaded.deinit(alloc);
    checkpoint_recovery.deinit();

    var authority_persistence = test_persistence();
    authority_persistence.grant.actor = .human;
    authority_persistence.direct_human_model_read_only = true;
    var authority = try fixture.create_with_persistence(
        "terminal-crash-authority",
        .{ .rows = 24, .columns = 80 },
        &.{},
        authority_persistence,
    );
    fixture.profile.options.fail_at = .after_authority_write;
    try std.testing.expectError(error.InjectedCrash, authority.revoke(2));
    fixture.profile.options.fail_at = null;
    authority.deinit();
    try fixture.reopen();
    var authority_recovery = try fixture.profile.recover("host-reopen", 3);
    const authority_index = recovered_session_index(
        authority_recovery.sessions.items,
        "terminal-crash-authority",
    ).?;
    try std.testing.expect(
        authority_recovery.sessions.items[authority_index].record.authority_revoked,
    );
    try std.testing.expect(
        authority_recovery.sessions.items[authority_index]
            .record.direct_human_model_read_only,
    );
    try std.testing.expectError(
        error.AuthorityRevoked,
        authority_recovery.sessions.items[authority_index]
            .load_recovery_execution_scope(alloc),
    );
    const recovered_authority = try load_authority(
        alloc,
        try authority_recovery.sessions.items[authority_index]
            .state_capability(),
        "terminal-crash-authority",
    );
    defer recovered_authority.deinit();
    try std.testing.expect(recovered_authority.value.revoked);
    try std.testing.expect(
        recovered_authority.value.direct_human_model_read_only,
    );
    authority_recovery.deinit();

    var committed_checkpoint = try fixture.create("terminal-crash-checkpoint-record");
    try committed_checkpoint.store_checkpoint(.{
        .engine_schema_revision = 1,
        .applied_cursor = committed_checkpoint.record.output_cursor,
        .payload_len = first_payload.len,
        .checksum = contracts.checkpoint_checksum(first_payload),
    }, first_payload, 2);
    fixture.profile.options.fail_at = .after_checkpoint_record;
    try std.testing.expectError(error.InjectedCrash, committed_checkpoint.store_checkpoint(.{
        .engine_schema_revision = 1,
        .applied_cursor = committed_checkpoint.record.output_cursor,
        .payload_len = second_payload.len,
        .checksum = contracts.checkpoint_checksum(second_payload),
    }, second_payload, 3));
    fixture.profile.options.fail_at = null;
    committed_checkpoint.deinit();
    try fixture.reopen();
    var committed_recovery = try fixture.profile.recover("host-reopen", 4);
    const committed_index = recovered_session_index(
        committed_recovery.sessions.items,
        "terminal-crash-checkpoint-record",
    ).?;
    var committed_loaded = (try committed_recovery.sessions.items[committed_index]
        .load_checkpoint(alloc)).?;
    try std.testing.expectEqualStrings(second_payload, committed_loaded.payload);
    try std.testing.expectEqual(
        @as(?u64, null),
        committed_recovery.sessions.items[committed_index]
            .record.checkpoint_cleanup_generation,
    );
    committed_loaded.deinit(alloc);
    committed_recovery.deinit();

    var acknowledged = try fixture.create("terminal-crash-acknowledgement");
    const acknowledged_id = try acknowledged.append_event(.output, 2);
    fixture.profile.options.fail_at = .after_acknowledgement_record;
    try std.testing.expectError(
        error.InjectedCrash,
        acknowledged.acknowledge(acknowledged_id, 3),
    );
    fixture.profile.options.fail_at = null;
    acknowledged.deinit();
    try fixture.reopen();
    var acknowledged_recovery = try fixture.profile.recover("host-reopen", 4);
    const acknowledged_index = recovered_session_index(
        acknowledged_recovery.sessions.items,
        "terminal-crash-acknowledgement",
    ).?;
    try std.testing.expectEqual(
        acknowledged_id,
        acknowledged_recovery.sessions.items[acknowledged_index]
            .record.event_cleanup_through,
    );
    acknowledged_recovery.deinit();

    var evicted = try fixture.create("terminal-crash-eviction");
    try evicted.append("gone", 2);
    try evicted.persist_lost(3);
    fixture.profile.options.fail_at = .after_eviction_record;
    try std.testing.expectError(error.InjectedCrash, evicted.evict_completed_output());
    fixture.profile.options.fail_at = null;
    evicted.deinit();
    try fixture.reopen();
    var eviction_recovery = try fixture.profile.recover("host-reopen", 4);
    const eviction_index = recovered_session_index(
        eviction_recovery.sessions.items,
        "terminal-crash-eviction",
    ).?;
    try std.testing.expectEqual(
        @as(u64, 0),
        eviction_recovery.sessions.items[eviction_index].record.journal_payload_bytes,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        eviction_recovery.sessions.items[eviction_index]
            .record.journal_cleanup_through,
    );
    eviction_recovery.deinit();

    var events = try fixture.create("terminal-crash-events");
    fixture.profile.options.fail_at = .after_event_write;
    try std.testing.expectError(
        error.InjectedCrash,
        events.append_event(.output, 2),
    );
    fixture.profile.options.fail_at = null;
    events.deinit();
    try fixture.reopen();
    var event_recovery = try fixture.profile.recover("host-reopen", 3);
    const event_index = recovered_session_index(
        event_recovery.sessions.items,
        "terminal-crash-events",
    ).?;
    var replay = try event_recovery.sessions.items[event_index]
        .replay_events(alloc, 0, 10);
    try std.testing.expectEqual(@as(usize, 1), replay.events.len);
    try std.testing.expectEqual(contracts.HostEvent.lifecycle, replay.events[0].kind);
    replay.deinit(alloc);
    event_recovery.deinit();
}

test "missing checkpoint is durably reconciled without fabricating a screen" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-missing-checkpoint");
    defer session.deinit();
    const payload = "checkpoint";
    const envelope = contracts.CheckpointEnvelope{
        .engine_schema_revision = 1,
        .applied_cursor = session.record.output_cursor,
        .payload_len = payload.len,
        .checksum = contracts.checkpoint_checksum(payload),
    };
    try session.store_checkpoint(envelope, payload, 2);
    const name = try checkpoint_name(
        alloc,
        session.record.session_id,
        session.record.checkpoint_generation,
    );
    defer alloc.free(name);
    try (try session.state_capability()).delete(.terminal_state, name);
    try session.reconcile_checkpoint();
    try std.testing.expectEqual(
        contracts.ScreenRecovery{ .unavailable = .missing },
        session.record.screen_recovery,
    );
}

test "journal recovery validates the complete chain and retains only a verified suffix" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-corrupt-journal-chain");
    try session.append("abcdefghijkl", 2);
    const name = try journal_name(alloc, session.record.session_id, 2);
    defer alloc.free(name);
    var replacement = try (try session.state_capability()).atomicReplace(
        alloc,
        .terminal_state,
        name,
        "WXYZ",
    );
    replacement.deinit(alloc);
    session.deinit();
    try fixture.reopen();

    var recovered = try fixture.profile.recover("host-reopen", 3);
    defer recovered.deinit();
    const index = recovered_session_index(
        recovered.sessions.items,
        "terminal-corrupt-journal-chain",
    ).?;
    const durable = &recovered.sessions.items[index];
    try std.testing.expectEqual(
        contracts.RawCursor{ .segment = 1, .offset = 8 },
        durable.record.available_from,
    );
    var page = try durable.read(alloc, .{ .segment = 1, .offset = 0 }, 64);
    defer page.deinit(alloc);
    try std.testing.expect(page.gap != null);
    try std.testing.expectEqualStrings("ijkl", page.output);
}

test "completed checkpoint eviction persists an explicit retention marker first" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-completed-checkpoint");
    defer session.deinit();
    const payload = "checkpoint";
    const envelope = contracts.CheckpointEnvelope{
        .engine_schema_revision = 1,
        .applied_cursor = session.record.output_cursor,
        .payload_len = payload.len,
        .checksum = contracts.checkpoint_checksum(payload),
    };
    try session.store_checkpoint(envelope, payload, 2);
    try session.persist_lost(3);
    try session.evict_completed_checkpoint();
    try std.testing.expectEqual(
        contracts.ScreenRecovery{ .unavailable = .retention_evicted },
        session.record.screen_recovery,
    );
    var reopened = try fixture.profile.open_existing(
        "terminal-store-owner",
        "terminal-completed-checkpoint",
    );
    defer reopened.deinit();
    try std.testing.expectEqual(
        contracts.ScreenRecovery{ .unavailable = .retention_evicted },
        reopened.record.screen_recovery,
    );
}

test "host restart marks native work lost without restart and reconnect is idempotent" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    var session = try fixture.create("terminal-restart-loss");
    try session.append("durable-output", 2);
    session.deinit();

    var first = try fixture.profile.recover("host-two", 3);
    try std.testing.expectEqual(@as(usize, 1), first.sessions.items.len);
    try std.testing.expectEqual(
        contracts.Lifecycle.lost,
        first.sessions.items[0].record.lifecycle,
    );
    var page = try first.sessions.items[0].read(
        alloc,
        .{ .segment = 1, .offset = 0 },
        64,
    );
    defer page.deinit(alloc);
    try std.testing.expectEqualStrings("durable-output", page.output);
    try std.testing.expect(try first.sessions.items[0].contains(
        "durable-output",
        .{ .segment = 1, .offset = 0 },
    ));
    first.deinit();

    var second = try fixture.profile.recover("host-three", 4);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 1), second.sessions.items.len);
    try std.testing.expectEqual(
        contracts.Lifecycle.lost,
        second.sessions.items[0].record.lifecycle,
    );
}

test "recovery isolates partial corrupt and unsupported records" {
    const alloc = std.testing.allocator;
    var fixture = try TestStoreFixture.init(alloc, test_options());
    defer fixture.deinit();
    const cases = [_]struct { id: []const u8, bytes: ?[]const u8 }{
        .{ .id = "terminal-partial-record", .bytes = "{" },
        .{ .id = "terminal-corrupt-record", .bytes = "{}" },
        .{ .id = "terminal-unsupported-record", .bytes = null },
    };
    for (cases) |case| {
        var session = try fixture.create(case.id);
        const name = try record_name(alloc, case.id);
        defer alloc.free(name);
        const bytes = if (case.bytes) |value|
            try alloc.dupe(u8, value)
        else blk: {
            const rendered = try render_json(alloc, record_wire(session.record));
            const marker = std.mem.find(u8, rendered, "\"schema_version\":1") orelse
                return error.TestExpectedEqual;
            rendered[marker + "\"schema_version\":".len] = '2';
            break :blk rendered;
        };
        defer alloc.free(bytes);
        var entry = try (try session.state_capability()).atomicReplace(
            alloc,
            .terminal_state,
            name,
            bytes,
        );
        entry.deinit(alloc);
        session.deinit();
    }

    var recovered = try fixture.profile.recover("host-two", 5);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 0), recovered.sessions.items.len);
    try std.testing.expectEqual(@as(usize, 3), recovered.diagnostics.items.len);
}
