const std = @import("std");
const child_state = @import("child_state.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const session_store = @import("../session/session_store.zig");
const catalog_cache = @import("../session/session_catalog_cache.zig");
const session_summary_codec = @import("../session/session_summary_codec.zig");

const Allocator = std.mem.Allocator;

pub const ActionableContinuation = struct {
    updated_at_ms: i64,
    id: []u8,

    pub fn deinit(self: *ActionableContinuation, alloc: Allocator) void {
        alloc.free(self.id);
        self.* = undefined;
    }

    pub fn view(self: ActionableContinuation) session_store.ResumableSessionContinuation {
        return .{ .updated_at_ms = self.updated_at_ms, .id = self.id };
    }
};

/// Lists visible sessions from the session index, newest first. It changes no
/// session; it saves the index only after replaying a committed log. The
/// index reuses fingerprint-matched rows, so a listing opens only the
/// sessions that changed since the index was last saved.
pub fn listVisiblePage(
    store: session_store.Store,
    alloc: Allocator,
    scope: session_store.SessionListScope,
    continuation: ?session_store.ResumableSessionContinuation,
    limit: usize,
) !session_store.SessionListPage {
    if (limit == 0 or limit > session_store.session_list_max_limit) return error.InvalidSessionListLimit;
    var catalog = catalog_cache.listActionableCatalogReadOnly(store, alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SessionStoreUnavailable,
    };
    defer catalog.deinit(alloc);
    var page = try session_summary_codec.sessionListPageFromSummaries(
        alloc,
        catalog.summaries.items,
        switch (scope) {
            .current_workspace => store.workspace_root,
            .all_workspaces => null,
        },
        continuation,
        limit,
    );
    page.skipped_invalid = catalog.skipped_invalid;
    return page;
}

/// Returns the newest listed session in this workspace from the index page
/// `--resume last` reads. `--resume last` also skips a session whose stale log
/// failed to replay in that listing, and a session without resumable content
/// that another process has open, so the two can differ. Caller owns the
/// summary.
pub fn latestVisibleWorkspaceSummary(
    store: session_store.Store,
    alloc: Allocator,
) !session_store.SessionSummary {
    var page = try listVisiblePage(
        store,
        alloc,
        .current_workspace,
        null,
        1,
    );
    defer page.deinit(alloc);
    if (page.summaries.items.len == 0) {
        if (page.skipped_invalid > 0) return error.NoReadableSessions;
        return error.NoSavedSessions;
    }
    return session_summary_codec.cloneSessionSummary(
        alloc,
        page.summaries.items[0],
    );
}

pub fn loadVisibleReadOnlyDetail(
    store: session_store.Store,
    alloc: Allocator,
    session_id: []const u8,
    options: session_store.ResumeOptions,
) !session_store.ReadOnlyDetail {
    const managed = child_state.hasManagedChildMarker(
        store,
        alloc,
        session_id,
    ) catch |err| switch (err) {
        error.OutOfMemory, error.InvalidSessionId => return err,
        else => return error.SessionNotFound,
    };
    if (managed) return error.SessionNotFound;

    var detail = store.loadReadOnlyAdmissionDetail(alloc, session_id, options) catch |err| switch (err) {
        error.ConversationHistoryUnavailable => return error.SessionNotFound,
        else => return err,
    };
    errdefer detail.deinit(alloc);
    if (detail.state.subagent_child) return error.SessionNotFound;
    return detail;
}

pub fn resumeForExternalPrompt(
    store: session_store.Store,
    alloc: Allocator,
    target: session_store.ResumeTarget,
    workspace_root: []const u8,
    options: session_store.ResumeOptions,
) !session_store.LoadedWritableSession {
    switch (target) {
        .id => |session_id| try ensureExternalMarkerAllowed(store, alloc, session_id),
        .last => {},
    }
    var loaded = try store.resumeTargetForWrite(
        alloc,
        target,
        workspace_root,
        options,
    );
    errdefer loaded.deinit(alloc);
    try ensureExternalMarkerAllowed(store, alloc, loaded.active_id);
    try ensureLoadedExternalPromptAllowed(&loaded);
    return loaded;
}

fn ensureExternalMarkerAllowed(
    store: session_store.Store,
    alloc: Allocator,
    session_id: []const u8,
) !void {
    const managed = child_state.hasManagedChildMarker(
        store,
        alloc,
        session_id,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SessionNotFound, error.SessionStoreUnavailable => return,
        else => return err,
    };
    if (managed) return error.OneOffSessionNotResumable;
}

fn ensureLoadedExternalPromptAllowed(
    loaded: *const session_store.LoadedWritableSession,
) !void {
    if (loaded.state.subagent_child) return error.OneOffSessionNotResumable;
}

test "managed child marker is hidden from external access" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var durable = session_codec.DurableSessionState{
        .id = try alloc.dupe(u8, "child"),
        .origin_workspace_root = try alloc.dupe(u8, workspace),
        .workspace_root = try alloc.dupe(u8, workspace),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .history = try alloc.alloc(session.HistoryTurn, 0),
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .preferences = .{
            .model = try alloc.dupe(u8, "test"),
            .effort = .auto,
            .fast_mode = false,
        },
    };
    defer durable.deinit(alloc);
    var writable = try store.startWritableSession(alloc, durable);
    writable.deinit(alloc);

    var visible = try loadVisibleReadOnlyDetail(store, alloc, "child", .{});
    visible.deinit(alloc);

    const state_store = child_state.Store{ .sessions = &store, .parent_id = "parent" };
    try state_store.markChildSession(alloc, "child");
    try std.testing.expectError(
        error.SessionNotFound,
        loadVisibleReadOnlyDetail(store, alloc, "child", .{}),
    );
    try std.testing.expectError(
        error.OneOffSessionNotResumable,
        resumeForExternalPrompt(store, alloc, .{ .id = "child" }, workspace, .{}),
    );
}

test "subagent work identity hides a partial child without owner sidecar" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var durable = session_codec.DurableSessionState{
        .id = try alloc.dupe(u8, "partial-child"),
        .origin_workspace_root = try alloc.dupe(u8, workspace),
        .workspace_root = try alloc.dupe(u8, workspace),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .history = try alloc.alloc(session.HistoryTurn, 0),
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .preferences = .{
            .model = try alloc.dupe(u8, "test"),
            .effort = .auto,
            .fast_mode = false,
        },
        .last_subagent_work_id = try alloc.dupe(u8, "work-1"),
        .subagent_child = true,
    };
    defer durable.deinit(alloc);
    var writable = try store.startWritableSession(alloc, durable);
    writable.deinit(alloc);

    try std.testing.expectError(
        error.SessionNotFound,
        loadVisibleReadOnlyDetail(store, alloc, "partial-child", .{}),
    );
    try std.testing.expectError(
        error.OneOffSessionNotResumable,
        resumeForExternalPrompt(
            store,
            alloc,
            .{ .id = "partial-child" },
            workspace,
            .{},
        ),
    );
}

test "session last skips a legacy child identified only by its first event" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.fx");
    try tmp.dir.createDirPath(std.testing.io, "workspace");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);

    var store = try session_store.Store.initFromHome(alloc, home, workspace);
    defer store.deinit(alloc);
    var parent = session_codec.DurableSessionState{
        .id = try alloc.dupe(u8, "parent"),
        .origin_workspace_root = try alloc.dupe(u8, workspace),
        .workspace_root = try alloc.dupe(u8, workspace),
        .created_at_ms = 1,
        .updated_at_ms = 1,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .history = try alloc.alloc(session.HistoryTurn, 0),
        .total_input_tokens = 0,
        .total_output_tokens = 0,
        .preferences = .{
            .model = try alloc.dupe(u8, "test"),
            .effort = .auto,
            .fast_mode = false,
        },
    };
    defer parent.deinit(alloc);
    var writable = try store.startWritableSession(alloc, parent);
    writable.deinit(alloc);
    try session_store.writeSchemaV3Fixture(alloc, store, "child", .{
        .projected_workspace = workspace,
        .workspace = workspace,
        .updated_at_ms = 1000,
        .stale_projection = false,
        .subagent_child = true,
    });

    // `fx session last` names the session `--resume last` opens, not the child.
    var latest = try latestVisibleWorkspaceSummary(store, alloc);
    defer latest.deinit(alloc);
    try std.testing.expectEqualStrings("parent", latest.id);
}
