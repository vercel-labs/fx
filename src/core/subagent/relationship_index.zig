const std = @import("std");
const control_store = @import("control_store.zig");
const domain = @import("domain.zig");
const io_mod = @import("../shared/io.zig");
const session_child_store = @import("../session/session_child_store.zig");
const index_codec = @import("../session/session_relationship_index_codec.zig");
const session_store = @import("../session/session_store.zig");

const Allocator = std.mem.Allocator;

const lookup_magic = "FXRELL01";
const legacy_schema_version: u32 = 1;
const schema_version: u32 = 2;
const header_file = session_child_store.subagent_relationship_index_file;
const lock_file = "subagent-relationship-index.lock";
const lock_deadline_ms: u64 = 2000;
const page_slots = index_codec.page_slots;
const no_slot = index_codec.no_slot;
const max_header_bytes = index_codec.max_header_bytes;
const max_page_bytes = index_codec.max_page_bytes;
const max_lookup_bytes: usize = 1024;

pub const max_candidate_reads: usize = 128;

pub const Error = error{
    OutOfMemory,
    SessionNotFound,
    InvalidCursor,
    StaleCursor,
    LockBusy,
    LockUnsupported,
    InvalidIndex,
    PathUnsafe,
    CommitIndeterminate,
    RecoveryRequired,
    StoreUnavailable,
    GenerationExhausted,
    SlotExhausted,
};

const Header = index_codec.Header;
const PendingKind = index_codec.PendingKind;
const Slot = index_codec.Slot;
const PageData = index_codec.PageData;
const header_magic = index_codec.header_magic;
const page_magic = index_codec.page_magic;
const encodeHeader = index_codec.encodeHeader;
const decodeHeader = index_codec.decodeHeader;
const encodePage = index_codec.encodePage;
const decodePage = index_codec.decodePage;
const decodePageInto = index_codec.decodePageInto;
const pageFileName = index_codec.pageFileName;

const Lookup = struct {
    storage_epoch: u64,
    slot: u64,
    prior_free_next: u64,
    child_id: []u8,

    fn deinit(self: *Lookup, alloc: Allocator) void {
        alloc.free(self.child_id);
        self.* = undefined;
    }
};

pub const Candidate = struct {
    child_id: []u8,
    slot: u64,

    pub fn deinit(self: *Candidate, alloc: Allocator) void {
        alloc.free(self.child_id);
        self.* = undefined;
    }
};

pub const CandidatePage = struct {
    generation: u64,
    start_offset: u64,
    next_offset: u64,
    high_watermark: u64,
    candidates: []Candidate,
    slots_read: usize,
    has_more: bool,

    pub fn deinit(self: *CandidatePage, alloc: Allocator) void {
        for (self.candidates) |*candidate| candidate.deinit(alloc);
        alloc.free(self.candidates);
        self.* = undefined;
    }
};

pub const EnsureResult = struct {
    slot: u64,
    generation: u64,
    changed: bool,
};

const Allocation = struct {
    slot: u64,
    next_free: u64,
};

pub const Cursor = struct {
    generation: u64,
    offset: u64,
};

pub const State = struct {
    generation: u64,
    high_watermark: u64,
};

pub const LookupResult = struct {
    generation: u64,
    slot: u64,
};

pub const MigrationStats = struct {
    candidate_reads: usize = 0,
    indexed_edges: usize = 0,
};

pub fn encodeCursor(alloc: Allocator, cursor: Cursor) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "v1:{x:0>16}:{x:0>16}",
        .{ cursor.generation, cursor.offset },
    );
}

pub fn parseCursor(raw: []const u8) Error!Cursor {
    if (raw.len != 38 or !std.mem.startsWith(u8, raw, "v1:") or raw[19] != ':') {
        return error.InvalidCursor;
    }
    return .{
        .generation = std.fmt.parseUnsigned(u64, raw[3..19], 16) catch
            return error.InvalidCursor,
        .offset = std.fmt.parseUnsigned(u64, raw[20..38], 16) catch
            return error.InvalidCursor,
    };
}

pub fn ensureChild(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_id: []const u8,
    child_id: []const u8,
    options: session_child_store.Options,
) Error!EnsureResult {
    domain.validateId(parent_id) catch return error.SessionNotFound;
    domain.validateId(child_id) catch return error.InvalidIndex;
    var opened = try Opened.init(alloc, sessions, parent_id, options);
    defer opened.deinit();
    var lock = try opened.acquireLock();
    defer lock.release();
    var header = try opened.loadHeader();
    try opened.recoverPending(&header);

    if (try opened.loadLookupOptional(child_id, header.storage_epoch)) |lookup_value| {
        var lookup = lookup_value;
        defer lookup.deinit(alloc);
        const slot = try opened.loadSlot(lookup.slot, header.storage_epoch);
        if (!slot.occupied or !std.mem.eql(u8, slot.childId(), child_id)) {
            return error.InvalidIndex;
        }
        return .{
            .slot = lookup.slot,
            .generation = header.generation,
            .changed = false,
        };
    }

    const allocation: Allocation = if (header.free_head != no_slot) blk: {
        const free_slot = try opened.loadSlot(
            header.free_head,
            header.storage_epoch,
        );
        if (free_slot.occupied) return error.InvalidIndex;
        break :blk .{
            .slot = header.free_head,
            .next_free = free_slot.next_free,
        };
    } else .{
        .slot = header.high_watermark,
        .next_free = no_slot,
    };
    if (allocation.slot == no_slot) return error.SlotExhausted;

    header.pending_kind = .allocate;
    header.pending_slot = allocation.slot;
    header.pending_next_free = allocation.next_free;
    header.setPendingChild(child_id);
    try opened.saveHeader(header);
    try opened.recoverPending(&header);
    return .{
        .slot = allocation.slot,
        .generation = header.generation,
        .changed = true,
    };
}

pub fn removeChild(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_id: []const u8,
    child_id: []const u8,
    options: session_child_store.Options,
) Error!bool {
    domain.validateId(parent_id) catch return error.SessionNotFound;
    domain.validateId(child_id) catch return error.InvalidIndex;
    var opened = try Opened.init(alloc, sessions, parent_id, options);
    defer opened.deinit();
    var lock = try opened.acquireLock();
    defer lock.release();
    var header = try opened.loadHeader();
    try opened.recoverPending(&header);
    const lookup_value = try opened.loadLookupOptional(
        child_id,
        header.storage_epoch,
    ) orelse return false;
    var lookup = lookup_value;
    defer lookup.deinit(alloc);
    const slot = try opened.loadSlot(lookup.slot, header.storage_epoch);
    if (!slot.occupied or !std.mem.eql(u8, slot.childId(), child_id)) {
        return error.InvalidIndex;
    }

    header.pending_kind = .free;
    header.pending_slot = lookup.slot;
    header.pending_next_free = header.free_head;
    header.setPendingChild(child_id);
    try opened.saveHeader(header);
    try opened.recoverPending(&header);
    return true;
}

pub fn bumpGeneration(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_id: []const u8,
    options: session_child_store.Options,
) Error!u64 {
    domain.validateId(parent_id) catch return error.SessionNotFound;
    var opened = try Opened.init(alloc, sessions, parent_id, options);
    defer opened.deinit();
    var lock = try opened.acquireLock();
    defer lock.release();
    var header = try opened.loadHeader();
    try opened.recoverPending(&header);
    header.generation = std.math.add(u64, header.generation, 1) catch
        return error.GenerationExhausted;
    try opened.saveHeader(header);
    return header.generation;
}

pub fn recoverForQuery(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_id: []const u8,
    options: session_child_store.Options,
) Error!void {
    domain.validateId(parent_id) catch return error.SessionNotFound;
    var read_only = try Opened.initReadOnly(
        alloc,
        sessions,
        parent_id,
        options,
    );
    const observed = read_only.loadHeader() catch |err| {
        read_only.deinit();
        return err;
    };
    read_only.deinit();
    if (observed.pending_kind == .none) return;
    try recoverUnderLock(alloc, sessions, parent_id, options);
}

pub fn repairForQuery(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_id: []const u8,
    options: session_child_store.Options,
) Error!void {
    domain.validateId(parent_id) catch return error.SessionNotFound;
    var read_only = try Opened.initReadOnly(
        alloc,
        sessions,
        parent_id,
        options,
    );
    const observed = read_only.loadHeader() catch |err| {
        read_only.deinit();
        return err;
    };
    read_only.deinit();

    var opened = Opened.init(
        alloc,
        sessions,
        parent_id,
        options,
    ) catch |err| return if (err == error.StoreUnavailable)
        error.RecoveryRequired
    else
        err;
    defer opened.deinit();
    var lock = try opened.acquireLock();
    defer lock.release();
    var current = try opened.loadHeader();
    if (!headersEqual(current, observed)) return;
    if (current.pending_kind != .none) {
        opened.recoverPending(&current) catch |err| switch (err) {
            error.InvalidIndex => {
                try opened.resetDerived(current);
                return;
            },
            else => return err,
        };
        return;
    }
    try opened.resetDerived(current);
}

fn recoverUnderLock(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_id: []const u8,
    options: session_child_store.Options,
) Error!void {
    var opened = Opened.init(
        alloc,
        sessions,
        parent_id,
        options,
    ) catch |err| return if (err == error.StoreUnavailable)
        error.RecoveryRequired
    else
        err;
    defer opened.deinit();
    var lock = try opened.acquireLock();
    defer lock.release();
    var header = try opened.loadHeader();
    opened.recoverPending(&header) catch |err| switch (err) {
        error.InvalidIndex => try opened.resetDerived(header),
        else => return err,
    };
}

pub fn page(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_id: []const u8,
    options: session_child_store.Options,
    cursor: ?Cursor,
    limit: usize,
    scan_limit: usize,
) Error!CandidatePage {
    if (limit == 0 or limit > domain.max_page_limit or
        scan_limit == 0 or scan_limit > max_candidate_reads)
    {
        return error.InvalidCursor;
    }
    var opened = try Opened.initReadOnly(alloc, sessions, parent_id, options);
    defer opened.deinit();
    const header = try opened.loadStableHeader();
    if (cursor) |value| {
        if (value.generation != header.generation) return error.StaleCursor;
        if (value.offset > header.high_watermark) return error.InvalidCursor;
    }
    const result = try opened.scanPage(
        alloc,
        header,
        if (cursor) |value| value.offset else 0,
        limit,
        scan_limit,
    );
    errdefer {
        var owned = result;
        owned.deinit(alloc);
    }
    try opened.verifyStableHeader(header);
    return result;
}

pub fn state(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_id: []const u8,
    options: session_child_store.Options,
) Error!State {
    var opened = try Opened.initReadOnly(alloc, sessions, parent_id, options);
    defer opened.deinit();
    const header = try opened.loadStableHeader();
    try opened.verifyStableHeader(header);
    return .{
        .generation = header.generation,
        .high_watermark = header.high_watermark,
    };
}

pub fn candidateAt(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_id: []const u8,
    options: session_child_store.Options,
    expected_generation: u64,
    slot_index: u64,
) Error!?Candidate {
    var opened = try Opened.initReadOnly(alloc, sessions, parent_id, options);
    defer opened.deinit();
    const header = try opened.loadStableHeader();
    if (header.generation != expected_generation) return error.StaleCursor;
    if (slot_index >= header.high_watermark) return error.InvalidCursor;
    const slot = try opened.loadSlot(slot_index, header.storage_epoch);
    if (!slot.occupied) return null;
    const result: ?Candidate = .{
        .child_id = try alloc.dupe(u8, slot.childId()),
        .slot = slot_index,
    };
    errdefer if (result) |candidate| alloc.free(candidate.child_id);
    try opened.verifyStableHeader(header);
    return result;
}

pub fn lookupSlot(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_id: []const u8,
    child_id: []const u8,
    options: session_child_store.Options,
) Error!?LookupResult {
    var opened = try Opened.initReadOnly(alloc, sessions, parent_id, options);
    defer opened.deinit();
    const header = try opened.loadStableHeader();
    const lookup_value = try opened.loadLookupOptional(
        child_id,
        header.storage_epoch,
    ) orelse {
        try opened.verifyStableHeader(header);
        return null;
    };
    var lookup = lookup_value;
    defer lookup.deinit(alloc);
    if (lookup.slot >= header.high_watermark) return error.InvalidIndex;
    const slot = try opened.loadSlot(lookup.slot, header.storage_epoch);
    if (!slot.occupied or !std.mem.eql(u8, slot.childId(), child_id)) {
        return error.InvalidIndex;
    }
    try opened.verifyStableHeader(header);
    return .{
        .generation = header.generation,
        .slot = lookup.slot,
    };
}

pub fn migrateLegacyPage(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_id: []const u8,
    options: session_child_store.Options,
) Error!MigrationStats {
    var parent_capability = sessions.openSubagentControlCapabilityWritable(
        alloc,
        parent_id,
        options,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSessionId, error.SessionNotFound => error.SessionNotFound,
        error.SessionPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => error.PathUnsafe,
        else => error.StoreUnavailable,
    };
    defer parent_capability.deinit();
    const parent_store = control_store.Store{
        .capability = &parent_capability,
        .expected_child_id = parent_id,
    };
    var parent_lock = parent_store.acquireLock() catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ControlLockBusy => error.LockBusy,
        error.ControlLockUnsupported => error.LockUnsupported,
        error.ControlPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => error.PathUnsafe,
        error.ControlStoreFailed => error.StoreUnavailable,
    };
    defer parent_lock.release();
    const continuation = try migrationCursor(
        alloc,
        sessions,
        parent_id,
        options,
    );
    var migration_page = sessions.listRelationshipMigrationCandidates(
        alloc,
        continuation,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SessionStoreUnavailable => error.StoreUnavailable,
    };
    defer migration_page.deinit(alloc);
    var stats = MigrationStats{};
    for (migration_page.ids.items) |child_id| {
        stats.candidate_reads += 1;
        if (std.mem.eql(u8, child_id, parent_id)) continue;
        var capability = sessions.openSubagentControlCapabilityReadOnly(
            alloc,
            child_id,
            options,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer capability.deinit();
        const store = control_store.Store{
            .capability = &capability,
            .expected_child_id = child_id,
        };
        var record = store.loadOptional(alloc) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer if (record) |*value| value.deinit(alloc);
        const canonical_parent = if (record) |value|
            value.parent_id orelse continue
        else
            continue;
        if (!std.mem.eql(u8, canonical_parent, parent_id)) continue;
        const ensured = try ensureChild(
            alloc,
            sessions,
            parent_id,
            child_id,
            options,
        );
        if (ensured.changed) stats.indexed_edges += 1;
    }
    try advanceMigration(
        alloc,
        sessions,
        parent_id,
        options,
        continuation,
        migration_page.cursor,
    );
    return stats;
}

/// Returns the indexed child count only when the existing migration cursor
/// proves that the current session-index snapshot has been exhausted. The
/// caller must separately serialize relationship writers through the parent
/// control lock when using this as a destructive leaf proof.
pub fn activeCountIfMigrationComplete(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_id: []const u8,
    options: session_child_store.Options,
) Error!?u64 {
    var opened = try Opened.initReadOnly(alloc, sessions, parent_id, options);
    defer opened.deinit();
    const header = try opened.loadStableHeader();
    const continuation = session_store.RelationshipMigrationCursor{
        .inode = header.migration_inode,
        .size = header.migration_size,
        .mtime_ns = header.migration_mtime_ns,
        .offset = header.migration_offset,
    };
    var migration_page = sessions.listRelationshipMigrationCandidates(
        alloc,
        continuation,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SessionStoreUnavailable => error.StoreUnavailable,
    };
    defer migration_page.deinit(alloc);
    try opened.verifyStableHeader(header);
    if (!header.active_count_known or migration_page.has_more or
        migration_page.ids.items.len != 0 or
        migration_page.cursor.inode != continuation.inode or
        migration_page.cursor.size != continuation.size or
        migration_page.cursor.mtime_ns != continuation.mtime_ns or
        migration_page.cursor.offset != continuation.offset)
    {
        return null;
    }
    return header.active_count;
}

pub fn deliveryPage(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_id: []const u8,
    options: session_child_store.Options,
    limit: usize,
    scan_limit: usize,
) Error!CandidatePage {
    if (limit == 0 or limit > domain.max_page_limit or
        scan_limit == 0 or scan_limit > max_candidate_reads)
    {
        return error.InvalidCursor;
    }
    var opened = try Opened.initReadOnly(alloc, sessions, parent_id, options);
    defer opened.deinit();
    const header = try opened.loadStableHeader();
    if (header.high_watermark == 0) {
        const result = try opened.scanPage(alloc, header, 0, limit, scan_limit);
        errdefer {
            var owned = result;
            owned.deinit(alloc);
        }
        try opened.verifyStableHeader(header);
        return result;
    }
    const start = @min(header.delivery_offset, header.high_watermark);
    var result = try opened.scanPage(
        alloc,
        header,
        start,
        limit,
        scan_limit,
    );
    errdefer result.deinit(alloc);
    if (!result.has_more and result.candidates.len < limit and result.slots_read < scan_limit and start != 0) {
        const remaining_limit = limit - result.candidates.len;
        const remaining_scan = scan_limit - result.slots_read;
        var wrapped = try opened.scanPage(
            alloc,
            header,
            0,
            remaining_limit,
            remaining_scan,
        );
        errdefer wrapped.deinit(alloc);
        const combined = try alloc.alloc(Candidate, result.candidates.len + wrapped.candidates.len);
        @memcpy(combined[0..result.candidates.len], result.candidates);
        @memcpy(combined[result.candidates.len..], wrapped.candidates);
        alloc.free(result.candidates);
        alloc.free(wrapped.candidates);
        result.candidates = combined;
        result.slots_read += wrapped.slots_read;
        result.next_offset = wrapped.next_offset;
        result.has_more = wrapped.has_more or wrapped.next_offset < start;
    }
    try opened.verifyStableHeader(header);
    return result;
}

pub fn advanceDelivery(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_id: []const u8,
    options: session_child_store.Options,
    expected_start: u64,
    next_offset: u64,
) Error!void {
    var opened = try Opened.init(alloc, sessions, parent_id, options);
    defer opened.deinit();
    var lock = try opened.acquireLock();
    defer lock.release();
    var header = try opened.loadHeader();
    try opened.recoverPending(&header);
    const current = if (header.high_watermark == 0)
        0
    else
        @min(header.delivery_offset, header.high_watermark);
    if (current != expected_start) return;
    header.delivery_offset = if (header.high_watermark == 0 or
        next_offset >= header.high_watermark)
        0
    else
        next_offset;
    try opened.saveHeader(header);
}

fn migrationCursor(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_id: []const u8,
    options: session_child_store.Options,
) Error!session_store.RelationshipMigrationCursor {
    var opened = try Opened.initReadOnly(alloc, sessions, parent_id, options);
    defer opened.deinit();
    const header = try opened.loadStableHeader();
    try opened.verifyStableHeader(header);
    return .{
        .inode = header.migration_inode,
        .size = header.migration_size,
        .mtime_ns = header.migration_mtime_ns,
        .offset = header.migration_offset,
    };
}

fn advanceMigration(
    alloc: Allocator,
    sessions: *session_store.Store,
    parent_id: []const u8,
    options: session_child_store.Options,
    expected: session_store.RelationshipMigrationCursor,
    next: session_store.RelationshipMigrationCursor,
) Error!void {
    var opened = try Opened.init(alloc, sessions, parent_id, options);
    defer opened.deinit();
    var lock = try opened.acquireLock();
    defer lock.release();
    var header = try opened.loadHeader();
    try opened.recoverPending(&header);
    if (header.migration_inode != expected.inode or
        header.migration_size != expected.size or
        header.migration_mtime_ns != expected.mtime_ns or
        header.migration_offset != expected.offset)
    {
        return;
    }
    header.migration_inode = next.inode;
    header.migration_size = next.size;
    header.migration_mtime_ns = next.mtime_ns;
    header.migration_offset = next.offset;
    try opened.saveHeader(header);
}

const Opened = struct {
    alloc: Allocator,
    capability: session_child_store.SessionChildCapability,

    fn init(
        alloc: Allocator,
        sessions: *session_store.Store,
        parent_id: []const u8,
        options: session_child_store.Options,
    ) Error!Opened {
        const capability = sessions.openSubagentControlCapabilityWritable(
            alloc,
            parent_id,
            options,
        ) catch |err| return mapOpen(err);
        return .{ .alloc = alloc, .capability = capability };
    }

    fn initReadOnly(
        alloc: Allocator,
        sessions: *session_store.Store,
        parent_id: []const u8,
        options: session_child_store.Options,
    ) Error!Opened {
        const capability = sessions.openSubagentControlCapabilityReadOnly(
            alloc,
            parent_id,
            options,
        ) catch |err| return mapOpen(err);
        return .{ .alloc = alloc, .capability = capability };
    }

    fn deinit(self: *Opened) void {
        self.capability.deinit();
        self.* = undefined;
    }

    fn acquireLock(self: *Opened) Error!io_mod.TimedAdvisoryLock {
        return self.capability.acquireTimedAdvisoryLock(
            .subagent_control,
            lock_file,
            lock_deadline_ms,
        ) catch |err| return mapLock(err);
    }

    fn loadHeader(self: *Opened) Error!Header {
        var file = self.capability.openFileReadOnly(
            self.alloc,
            .subagent_control,
            header_file,
        ) catch |err| switch (err) {
            error.FileNotFound => return .{},
            error.OutOfMemory => return error.OutOfMemory,
            error.SessionPathUnsafe => return error.PathUnsafe,
            else => return error.StoreUnavailable,
        };
        defer file.deinit();
        const bytes = file.readToEnd(self.alloc, max_header_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidIndex,
        };
        defer self.alloc.free(bytes);
        return decodeHeader(bytes);
    }

    fn loadStableHeader(self: *Opened) Error!Header {
        const header = try self.loadHeader();
        if (header.pending_kind != .none) return error.CommitIndeterminate;
        return header;
    }

    fn verifyStableHeader(self: *Opened, expected: Header) Error!void {
        const observed = try self.loadStableHeader();
        if (!headersEqual(observed, expected)) return error.StaleCursor;
    }

    fn saveHeader(self: *Opened, header: Header) Error!void {
        const bytes = try encodeHeader(self.alloc, header);
        defer self.alloc.free(bytes);
        self.replaceVerified(header_file, bytes, header) catch |err| return err;
    }

    fn replaceVerified(
        self: *Opened,
        name: []const u8,
        bytes: []const u8,
        expected_header: ?Header,
    ) Error!void {
        var entry = self.capability.atomicReplace(
            self.alloc,
            .subagent_control,
            name,
            bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SessionPathUnsafe,
            error.PrivateStatePermissionsUnsupported,
            => return error.PathUnsafe,
            error.SessionChildCommitIndeterminate => {
                if (expected_header) |expected| {
                    const observed = self.loadHeader() catch
                        return error.CommitIndeterminate;
                    if (headersEqual(observed, expected)) return;
                }
                return error.CommitIndeterminate;
            },
            else => return error.StoreUnavailable,
        };
        entry.deinit(self.alloc);
    }

    fn loadPageData(
        self: *Opened,
        number: u64,
        storage_epoch: u64,
    ) Error!PageData {
        var page_data: PageData = undefined;
        try self.loadPageDataInto(&page_data, number, storage_epoch);
        return page_data;
    }

    // noinline keeps the comptime-known error returns behind a call
    // boundary; inlined into an `Error!PageData` result location they each
    // materialize a page-sized error-union constant.
    noinline fn loadPageDataInto(
        self: *Opened,
        page_data: *PageData,
        number: u64,
        storage_epoch: u64,
    ) Error!void {
        const name = pageFileName(number);
        var file = self.capability.openFileReadOnly(
            self.alloc,
            .subagent_control,
            &name,
        ) catch |err| switch (err) {
            error.FileNotFound => {
                page_data.* = PageData.init(number, storage_epoch);
                return;
            },
            error.OutOfMemory => return error.OutOfMemory,
            error.SessionPathUnsafe => return error.PathUnsafe,
            else => return error.StoreUnavailable,
        };
        defer file.deinit();
        const bytes = file.readToEnd(self.alloc, max_page_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidIndex,
        };
        defer self.alloc.free(bytes);
        return decodePageInto(page_data, bytes, number, storage_epoch);
    }

    fn savePageData(self: *Opened, page_data: PageData) Error!void {
        const name = pageFileName(page_data.number);
        const bytes = try encodePage(self.alloc, page_data);
        defer self.alloc.free(bytes);
        var entry = self.capability.atomicReplace(
            self.alloc,
            .subagent_control,
            &name,
            bytes,
        ) catch |err| return mapReplace(err);
        entry.deinit(self.alloc);
    }

    fn loadSlot(
        self: *Opened,
        slot_index: u64,
        storage_epoch: u64,
    ) Error!Slot {
        if (slot_index == no_slot) return error.InvalidIndex;
        const page_number = slot_index / page_slots;
        const within: usize = @intCast(slot_index % page_slots);
        const page_data = try self.loadPageData(page_number, storage_epoch);
        return page_data.slots[within];
    }

    fn saveSlot(
        self: *Opened,
        slot_index: u64,
        slot: Slot,
        storage_epoch: u64,
        initialize_page: bool,
    ) Error!void {
        if (slot_index == no_slot) return error.InvalidIndex;
        const page_number = slot_index / page_slots;
        const within: usize = @intCast(slot_index % page_slots);
        var page_data = if (initialize_page)
            PageData.init(page_number, storage_epoch)
        else
            try self.loadPageData(page_number, storage_epoch);
        page_data.slots[within] = slot;
        try self.savePageData(page_data);
    }

    fn loadLookupOptional(
        self: *Opened,
        child_id: []const u8,
        storage_epoch: u64,
    ) Error!?Lookup {
        const name = lookupFileName(child_id);
        var file = self.capability.openFileReadOnly(
            self.alloc,
            .subagent_control,
            &name,
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            error.OutOfMemory => return error.OutOfMemory,
            error.SessionPathUnsafe => return error.PathUnsafe,
            else => return error.StoreUnavailable,
        };
        defer file.deinit();
        const bytes = file.readToEnd(self.alloc, max_lookup_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidIndex,
        };
        defer self.alloc.free(bytes);
        var lookup = try decodeLookup(self.alloc, bytes);
        errdefer lookup.deinit(self.alloc);
        if (!std.mem.eql(u8, lookup.child_id, child_id)) return error.InvalidIndex;
        if (lookup.storage_epoch != storage_epoch) {
            lookup.deinit(self.alloc);
            return null;
        }
        return lookup;
    }

    fn saveLookup(
        self: *Opened,
        child_id: []const u8,
        slot: u64,
        prior_free_next: u64,
        storage_epoch: u64,
    ) Error!void {
        const name = lookupFileName(child_id);
        const bytes = try encodeLookup(
            self.alloc,
            child_id,
            slot,
            prior_free_next,
            storage_epoch,
        );
        defer self.alloc.free(bytes);
        var entry = self.capability.atomicReplace(
            self.alloc,
            .subagent_control,
            &name,
            bytes,
        ) catch |err| return mapReplace(err);
        entry.deinit(self.alloc);
    }

    fn deleteLookup(self: *Opened, child_id: []const u8) Error!void {
        const name = lookupFileName(child_id);
        self.capability.delete(.subagent_control, &name) catch |err| switch (err) {
            error.FileNotFound => return,
            error.SessionPathUnsafe => return error.PathUnsafe,
            else => return error.StoreUnavailable,
        };
    }

    fn recoverPending(self: *Opened, header: *Header) Error!void {
        switch (header.pending_kind) {
            .none => {
                if (header.active_count_known) return;
                header.active_count = try self.countOccupied(header.*);
                header.active_count_known = true;
                try self.saveHeader(header.*);
                return;
            },
            .allocate => {
                // A repaired epoch reuses page filenames. Its first slot
                // rewrites the whole page before any stale slot is readable.
                const initialize_page =
                    header.pending_slot == header.high_watermark and
                    header.pending_slot % page_slots == 0;
                var slot: Slot = if (initialize_page)
                    .{}
                else
                    try self.loadSlot(
                        header.pending_slot,
                        header.storage_epoch,
                    );
                slot.setOccupied(header.pendingChild());
                try self.saveSlot(
                    header.pending_slot,
                    slot,
                    header.storage_epoch,
                    initialize_page,
                );
                try self.saveLookup(
                    header.pendingChild(),
                    header.pending_slot,
                    header.pending_next_free,
                    header.storage_epoch,
                );
                if (header.pending_slot == header.high_watermark) {
                    header.high_watermark = std.math.add(
                        u64,
                        header.high_watermark,
                        1,
                    ) catch return error.SlotExhausted;
                } else if (header.free_head == header.pending_slot) {
                    header.free_head = header.pending_next_free;
                } else {
                    return error.InvalidIndex;
                }
                if (header.active_count_known) {
                    header.active_count = std.math.add(
                        u64,
                        header.active_count,
                        1,
                    ) catch return error.InvalidIndex;
                }
            },
            .free => {
                var slot = try self.loadSlot(
                    header.pending_slot,
                    header.storage_epoch,
                );
                if (slot.occupied and
                    !std.mem.eql(u8, slot.childId(), header.pendingChild()))
                {
                    return error.InvalidIndex;
                }
                slot.setFree(header.pending_next_free);
                try self.saveSlot(
                    header.pending_slot,
                    slot,
                    header.storage_epoch,
                    false,
                );
                try self.deleteLookup(header.pendingChild());
                header.free_head = header.pending_slot;
                if (header.active_count_known) {
                    if (header.active_count == 0) return error.InvalidIndex;
                    header.active_count -= 1;
                }
            },
        }
        header.generation = std.math.add(u64, header.generation, 1) catch
            return error.GenerationExhausted;
        header.clearPending();
        if (!header.active_count_known) {
            header.active_count = try self.countOccupied(header.*);
            header.active_count_known = true;
        }
        try self.saveHeader(header.*);
    }

    fn countOccupied(self: *Opened, header: Header) Error!u64 {
        var count: u64 = 0;
        var page_number: u64 = 0;
        var offset: u64 = 0;
        while (offset < header.high_watermark) : (page_number += 1) {
            const page_data = try self.loadPageData(page_number, header.storage_epoch);
            const remaining = header.high_watermark - offset;
            const slots_to_read: usize = @intCast(@min(remaining, page_slots));
            for (page_data.slots[0..slots_to_read]) |slot| {
                if (slot.occupied) {
                    count = std.math.add(u64, count, 1) catch
                        return error.InvalidIndex;
                }
            }
            offset += @intCast(slots_to_read);
        }
        return count;
    }

    fn resetDerived(self: *Opened, previous: ?Header) Error!void {
        var random_bytes: [16]u8 = undefined;
        io_mod.getIo().random(&random_bytes);
        var storage_epoch = std.mem.readInt(u64, random_bytes[0..8], .little);
        var generation = std.mem.readInt(u64, random_bytes[8..16], .little);
        if (storage_epoch == 0 or
            (previous != null and storage_epoch == previous.?.storage_epoch))
        {
            storage_epoch = 1;
            if (previous != null and storage_epoch == previous.?.storage_epoch) {
                storage_epoch = 2;
            }
        }
        if (previous) |header| {
            if (generation == header.generation) generation +%= 1;
        }
        try self.saveHeader(.{
            .storage_epoch = storage_epoch,
            .generation = generation,
        });
    }

    fn scanPage(
        self: *Opened,
        alloc: Allocator,
        header: Header,
        start_offset: u64,
        limit: usize,
        scan_limit: usize,
    ) Error!CandidatePage {
        var candidates: std.ArrayList(Candidate) = .empty;
        errdefer {
            for (candidates.items) |*candidate| candidate.deinit(alloc);
            candidates.deinit(alloc);
        }
        var offset = start_offset;
        var slots_read: usize = 0;
        while (offset < header.high_watermark and
            candidates.items.len < limit and
            slots_read < scan_limit)
        {
            const page_number = offset / page_slots;
            const page_data = try self.loadPageData(
                page_number,
                header.storage_epoch,
            );
            const page_end = @min(
                header.high_watermark,
                std.math.mul(u64, page_number + 1, page_slots) catch
                    return error.InvalidIndex,
            );
            while (offset < page_end and
                candidates.items.len < limit and
                slots_read < scan_limit)
            {
                const within: usize = @intCast(offset % page_slots);
                const slot = page_data.slots[within];
                const current = offset;
                offset += 1;
                slots_read += 1;
                if (!slot.occupied) continue;
                const child_id = try alloc.dupe(u8, slot.childId());
                errdefer alloc.free(child_id);
                try candidates.append(alloc, .{
                    .child_id = child_id,
                    .slot = current,
                });
            }
        }
        return .{
            .generation = header.generation,
            .start_offset = start_offset,
            .next_offset = offset,
            .high_watermark = header.high_watermark,
            .candidates = try candidates.toOwnedSlice(alloc),
            .slots_read = slots_read,
            .has_more = offset < header.high_watermark,
        };
    }
};

fn encodeLookup(
    alloc: Allocator,
    child_id: []const u8,
    slot: u64,
    prior_free_next: u64,
    storage_epoch: u64,
) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeAll(lookup_magic) catch return error.OutOfMemory;
    writeInt(&out.writer, u32, schema_version) catch return error.OutOfMemory;
    writeInt(&out.writer, u64, storage_epoch) catch return error.OutOfMemory;
    writeInt(&out.writer, u64, slot) catch return error.OutOfMemory;
    writeInt(&out.writer, u64, prior_free_next) catch return error.OutOfMemory;
    writeInt(&out.writer, u16, @intCast(child_id.len)) catch return error.OutOfMemory;
    out.writer.writeAll(child_id) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn decodeLookup(alloc: Allocator, bytes: []const u8) Error!Lookup {
    var cursor = ByteCursor{ .bytes = bytes };
    if (!std.mem.eql(u8, try cursor.take(lookup_magic.len), lookup_magic)) {
        return error.InvalidIndex;
    }
    const version = try cursor.readInt(u32);
    if (version != legacy_schema_version and version != schema_version) {
        return error.InvalidIndex;
    }
    const storage_epoch = if (version == schema_version)
        try cursor.readInt(u64)
    else
        0;
    const slot = try cursor.readInt(u64);
    const prior_free_next = try cursor.readInt(u64);
    const child_len = try cursor.readInt(u16);
    if (child_len == 0 or child_len > 255) return error.InvalidIndex;
    const child = try cursor.take(child_len);
    if (!cursor.done()) return error.InvalidIndex;
    domain.validateId(child) catch return error.InvalidIndex;
    return .{
        .storage_epoch = storage_epoch,
        .slot = slot,
        .prior_free_next = prior_free_next,
        .child_id = try alloc.dupe(u8, child),
    };
}

const ByteCursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(self: *ByteCursor, len: usize) Error![]const u8 {
        const end = std.math.add(usize, self.offset, len) catch
            return error.InvalidIndex;
        if (end > self.bytes.len) return error.InvalidIndex;
        const result = self.bytes[self.offset..end];
        self.offset = end;
        return result;
    }

    fn readByte(self: *ByteCursor) Error!u8 {
        return (try self.take(1))[0];
    }

    fn readInt(self: *ByteCursor, comptime T: type) Error!T {
        const raw = try self.take(@sizeOf(T));
        return std.mem.readInt(T, raw[0..@sizeOf(T)], .little);
    }

    fn done(self: ByteCursor) bool {
        return self.offset == self.bytes.len;
    }
};

fn writeInt(writer: *std.Io.Writer, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

fn lookupFileName(child_id: []const u8) [87]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(child_id, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const prefix = "relationship-child-";
    const suffix = ".bin";
    var buffer: [prefix.len + hex.len + suffix.len]u8 = undefined;
    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len .. prefix.len + hex.len], &hex);
    @memcpy(buffer[prefix.len + hex.len ..], suffix);
    return buffer;
}

test "relationship index filenames remain canonical" {
    try std.testing.expectEqualStrings(
        "relationship-page-000000000000002a.bin",
        &pageFileName(42),
    );
    try std.testing.expectEqualStrings(
        "relationship-child-ddc9e669194254cef019a29d3619a2c16592e5d52e1a81e98b01bd52319149a3.bin",
        &lookupFileName("child"),
    );
}

fn headersEqual(a: Header, b: Header) bool {
    return a.storage_epoch == b.storage_epoch and
        a.generation == b.generation and
        a.high_watermark == b.high_watermark and
        a.active_count == b.active_count and
        a.active_count_known == b.active_count_known and
        a.free_head == b.free_head and
        a.delivery_offset == b.delivery_offset and
        a.migration_inode == b.migration_inode and
        a.migration_size == b.migration_size and
        a.migration_mtime_ns == b.migration_mtime_ns and
        a.migration_offset == b.migration_offset and
        a.pending_kind == b.pending_kind and
        a.pending_slot == b.pending_slot and
        a.pending_next_free == b.pending_next_free and
        std.mem.eql(u8, a.pendingChild(), b.pendingChild());
}

fn mapOpen(err: session_store.OpenSubagentControlError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSessionId, error.SessionNotFound => error.SessionNotFound,
        error.SessionPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => error.PathUnsafe,
        error.SessionStoreUnavailable,
        error.SessionChildStoreFailed,
        => error.StoreUnavailable,
    };
}

fn mapLock(err: session_child_store.AdvisoryLockError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.LockBusy => error.LockBusy,
        error.LockUnsupported => error.LockUnsupported,
        error.SessionPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => error.PathUnsafe,
        error.InvalidManagedChildName,
        error.SessionChildReadOnly,
        error.SessionChildStoreFailed,
        => error.StoreUnavailable,
    };
}

fn mapReplace(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SessionPathUnsafe,
        error.PrivateStatePermissionsUnsupported,
        => error.PathUnsafe,
        error.SessionChildCommitIndeterminate => error.CommitIndeterminate,
        else => error.StoreUnavailable,
    };
}

test "relationship index codec rejects malformed bytes and frees ownership" {
    const alloc = std.testing.allocator;
    var header = Header{};
    header.pending_kind = .allocate;
    header.pending_slot = 3;
    header.setPendingChild("child");
    const bytes = try encodeHeader(alloc, header);
    defer alloc.free(bytes);
    const decoded = try decodeHeader(bytes);
    try std.testing.expect(headersEqual(header, decoded));
    try std.testing.expectError(error.InvalidIndex, decodeHeader(bytes[0 .. bytes.len - 1]));

    const lookup_bytes = try encodeLookup(alloc, "child", 3, no_slot, 7);
    defer alloc.free(lookup_bytes);
    var lookup = try decodeLookup(alloc, lookup_bytes);
    defer lookup.deinit(alloc);
    try std.testing.expectEqualStrings("child", lookup.child_id);
    try std.testing.expectEqual(@as(u64, 7), lookup.storage_epoch);
}

test "relationship index codec reads schema one files into the original epoch" {
    const alloc = std.testing.allocator;
    var header_out: std.Io.Writer.Allocating = .init(alloc);
    defer header_out.deinit();
    try header_out.writer.writeAll(header_magic);
    try writeInt(&header_out.writer, u32, legacy_schema_version);
    try writeInt(&header_out.writer, u64, 9);
    try writeInt(&header_out.writer, u64, 0);
    try writeInt(&header_out.writer, u64, no_slot);
    try writeInt(&header_out.writer, u64, 0);
    try writeInt(&header_out.writer, u64, 0);
    try writeInt(&header_out.writer, u64, 0);
    try writeInt(&header_out.writer, i128, 0);
    try writeInt(&header_out.writer, u64, 0);
    try header_out.writer.writeByte(@intFromEnum(PendingKind.none));
    try writeInt(&header_out.writer, u64, no_slot);
    try writeInt(&header_out.writer, u64, no_slot);
    try writeInt(&header_out.writer, u16, 0);
    const header = try decodeHeader(header_out.written());
    try std.testing.expectEqual(@as(u64, 0), header.storage_epoch);
    try std.testing.expectEqual(@as(u64, 9), header.generation);

    var page_out: std.Io.Writer.Allocating = .init(alloc);
    defer page_out.deinit();
    try page_out.writer.writeAll(page_magic);
    try writeInt(&page_out.writer, u32, legacy_schema_version);
    try writeInt(&page_out.writer, u64, 0);
    for (0..page_slots) |_| {
        try page_out.writer.writeByte(0);
        try writeInt(&page_out.writer, u64, no_slot);
        try writeInt(&page_out.writer, u16, 0);
    }
    const page_data = try decodePage(page_out.written(), 0, 0);
    try std.testing.expectEqual(@as(u64, 0), page_data.storage_epoch);

    var lookup_out: std.Io.Writer.Allocating = .init(alloc);
    defer lookup_out.deinit();
    try lookup_out.writer.writeAll(lookup_magic);
    try writeInt(&lookup_out.writer, u32, legacy_schema_version);
    try writeInt(&lookup_out.writer, u64, 3);
    try writeInt(&lookup_out.writer, u64, no_slot);
    try writeInt(&lookup_out.writer, u16, 5);
    try lookup_out.writer.writeAll("child");
    var lookup = try decodeLookup(alloc, lookup_out.written());
    defer lookup.deinit(alloc);
    try std.testing.expectEqual(@as(u64, 0), lookup.storage_epoch);
    try std.testing.expectEqual(@as(u64, 3), lookup.slot);
}

test "relationship index decoder handles fuzzed bytes" {
    try std.testing.fuzz({}, fuzzRelationshipIndex, .{ .corpus = &.{
        "",
        header_magic,
        page_magic,
        lookup_magic,
    } });
}

fn fuzzRelationshipIndex(_: void, smith: *std.testing.Smith) !void {
    var buffer: [8192]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    _ = decodeHeader(buffer[0..len]) catch {};
    _ = decodePage(buffer[0..len], 0, 0) catch {};
    var lookup = decodeLookup(std.testing.allocator, buffer[0..len]) catch return;
    lookup.deinit(std.testing.allocator);
}
