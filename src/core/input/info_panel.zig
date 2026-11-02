//! State of a read-only panel in the footer, such as `/status` and
//! `/permissions` open: a title over labeled lines, built when it opens and
//! scrolled when they do not all fit. It writes nothing to the transcript.

const std = @import("std");
const output_contracts = @import("../output/output_contracts.zig");
const types = @import("../shared/types.zig");

pub const Row = output_contracts.PanelRow;

pub const Kind = enum {
    status,
    permissions,

    pub fn title(self: Kind) []const u8 {
        return switch (self) {
            .status => "Status",
            .permissions => "Permissions",
        };
    }
};

/// What a panel's rows depend on that changes with no keystroke while it is
/// open: a running turn that saves the session, ends, or gains a session
/// grant from an approval. The rows are rebuilt when these differ from the
/// ones they were built from.
pub const Facts = union(Kind) {
    status: struct {
        history_turns: usize,
        /// Null when the shell has no session.
        session_saved: ?bool,
        session_grants: usize,
    },
    permissions: struct {
        mode: types.PermissionMode,
        session_grants: usize,
        configured_rules: usize,
    },
};

/// What a rebuild needs that it must not read again, by kind.
pub const Inputs = union(Kind) {
    status: struct {
        /// The credential the profile settings select, read at open.
        preferred: ?types.CredentialSource,
        /// Why the settings could not be read at open, an error name.
        settings_error: ?[]const u8,
    },
    permissions,
};

/// A panel's rows and what they were built from. Owns everything.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    rows: []const Row,
    facts: Facts,
    inputs: Inputs,

    pub fn kind(self: *const Snapshot) Kind {
        return self.facts;
    }

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const State = struct {
    active: bool = false,
    /// The first panel line shown when they do not all fit.
    scroll: usize = 0,
    snapshot: ?Snapshot = null,

    /// Takes ownership of `snapshot`.
    pub fn open(self: *State, snapshot: Snapshot) void {
        self.close();
        self.* = .{ .active = true, .snapshot = snapshot };
    }

    /// Replaces the rows and keeps the scroll position. Takes ownership of
    /// `snapshot`.
    pub fn replace(self: *State, snapshot: Snapshot) void {
        if (self.snapshot) |*old| old.deinit();
        self.snapshot = snapshot;
    }

    pub fn close(self: *State) void {
        if (self.snapshot) |*old| old.deinit();
        self.* = .{};
    }

    pub fn title(self: *const State) []const u8 {
        return if (self.snapshot) |*snapshot| snapshot.kind().title() else "";
    }

    pub fn rows(self: *const State) []const Row {
        return if (self.snapshot) |*snapshot| snapshot.rows else &.{};
    }

    /// ↑↓ when the panel's `total_lines` do not fit its `visible_lines`.
    /// Returns whether the panel moved.
    pub fn scrollBy(self: *State, delta: i32, total_lines: usize, visible_lines: usize) bool {
        if (!self.active or delta == 0) return false;
        const last_start = total_lines -| @max(visible_lines, 1);
        const start = @min(self.scroll, last_start);
        const next = if (delta > 0) @min(start +| 1, last_start) else start -| 1;
        if (next == self.scroll) return false;
        self.scroll = next;
        return true;
    }
};
