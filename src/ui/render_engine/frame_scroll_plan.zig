const std = @import("std");

pub const FrameDocumentAppendClear = union(enum) {
    remainder,
    rows: u16,
};

pub const FrameDocumentAppend = struct {
    /// Terminal-wire bytes; every LF must be preceded by CR.
    bytes: []const u8 = &.{},
    start_row: u16 = 1,
    start_col: u16 = 1,
    /// Source continuation after an occupied right margin, not a row replay.
    start_pending_wrap: bool = false,
    clear: FrameDocumentAppendClear = .remainder,
    reset_replay: bool = false,

    pub fn isEmpty(self: FrameDocumentAppend) bool {
        return self.bytes.len == 0;
    }

    pub fn validatedStartCol(self: FrameDocumentAppend, target_cols: u16, target_rows: u16) !u16 {
        if (target_cols == 0 or target_rows == 0 or
            self.start_row == 0 or self.start_row > target_rows)
        {
            return error.InvalidFrameScrollPlan;
        }
        return @min(@max(self.start_col, 1), target_cols);
    }

    pub fn validatedClearBottom(self: FrameDocumentAppend, target_rows: u16) !?u16 {
        if (target_rows == 0 or self.start_row == 0 or self.start_row > target_rows) {
            return error.InvalidFrameScrollPlan;
        }
        return switch (self.clear) {
            .remainder => null,
            .rows => |rows| if (rows == 0)
                error.InvalidFrameScrollPlan
            else
                self.start_row + @min(rows, target_rows - self.start_row + 1) - 1,
        };
    }
};

pub const AcceptedScrollRows = struct {
    preserved_release_rows: u16,
    inline_advance_rows: u32,
};

pub const FrameScrollCommit = struct {
    physical_terminal_scroll_rows: u16,
    planned_terminal_scroll_rows: u16,
    expected_terminal_scroll_rows: u16,
    accepted_terminal_scroll_rows: u16,
    unplanned_terminal_scroll_rows: u16,
    accepted_rows: AcceptedScrollRows,

    pub fn complete(self: FrameScrollCommit) bool {
        return self.physical_terminal_scroll_rows >= self.expected_terminal_scroll_rows and
            self.unplanned_terminal_scroll_rows == 0;
    }

    pub fn matchesPlan(self: FrameScrollCommit, plan: FrameScrollPlan) bool {
        return std.meta.eql(
            self,
            plan.commitWithExpectedRows(
                self.physical_terminal_scroll_rows,
                self.expected_terminal_scroll_rows,
            ),
        );
    }
};

pub const TerminalMovementRows = struct {
    planned_scroll_rows: u16,
    materialized_scroll_rows: u16,
    alignment_scroll_rows: u16,
    expected_scroll_rows: u16,

    pub fn emittedScrollRows(self: TerminalMovementRows) u16 {
        return self.materialized_scroll_rows + self.alignment_scroll_rows;
    }

    pub fn resolve(
        planned_scroll_rows: u16,
        materialized_scroll_rows: u16,
        reset_replay: bool,
    ) !TerminalMovementRows {
        if (reset_replay) {
            return .{
                .planned_scroll_rows = planned_scroll_rows,
                .materialized_scroll_rows = materialized_scroll_rows,
                .alignment_scroll_rows = 0,
                .expected_scroll_rows = materialized_scroll_rows,
            };
        }
        if (materialized_scroll_rows > planned_scroll_rows) {
            return error.InvalidFrameScrollPlan;
        }
        return .{
            .planned_scroll_rows = planned_scroll_rows,
            .materialized_scroll_rows = materialized_scroll_rows,
            .alignment_scroll_rows = planned_scroll_rows - materialized_scroll_rows,
            .expected_scroll_rows = planned_scroll_rows,
        };
    }
};

pub const FrameScrollPlan = struct {
    prior_owned_top: u16,
    requested_release_rows: u16,
    requested_inline_advance_rows: u32,
    preserved_release_rows: u16,
    terminal_scroll_rows: u16,
    remaining_inline_advance_rows: u32,
    post_scroll_owned_top: u16,
    /// First body row after sticky chrome (1 = no sticky). Used to evict
    /// sticky rows via DL before full-terminal newline release so umbrella
    /// chrome does not enter scrollback, while body rows still do.
    scroll_region_top: u16 = 1,
    /// Absolute top row of sticky chrome when active (0 = none). Paired with
    /// scroll_region_top so eviction deletes only sticky rows, not lookback.
    sticky_top_row: u16 = 0,

    pub fn none(terminal_rows: u16, current_owned_top: u16) FrameScrollPlan {
        return merge(terminal_rows, current_owned_top, 0, 0);
    }

    pub fn stickyRows(self: FrameScrollPlan) u16 {
        if (self.sticky_top_row == 0 or self.scroll_region_top <= self.sticky_top_row) return 0;
        return self.scroll_region_top - self.sticky_top_row;
    }

    pub fn validate(self: FrameScrollPlan, terminal_rows: u16) !void {
        var expected = merge(
            terminal_rows,
            self.prior_owned_top,
            self.requested_release_rows,
            self.requested_inline_advance_rows,
        );
        expected.scroll_region_top = self.scroll_region_top;
        expected.sticky_top_row = self.sticky_top_row;
        if (!std.meta.eql(self, expected)) return error.InvalidFrameScrollPlan;
    }

    pub fn acceptedPreservedRows(self: FrameScrollPlan, committed_terminal_scroll_rows: u16) u16 {
        return self.acceptedRows(committed_terminal_scroll_rows).preserved_release_rows;
    }

    pub fn acceptedInlineRows(self: FrameScrollPlan, committed_terminal_scroll_rows: u16) u32 {
        return self.acceptedRows(committed_terminal_scroll_rows).inline_advance_rows;
    }

    pub fn acceptedRows(self: FrameScrollPlan, committed_terminal_scroll_rows: u16) AcceptedScrollRows {
        return self.commit(committed_terminal_scroll_rows).accepted_rows;
    }

    pub fn commit(self: FrameScrollPlan, committed_terminal_scroll_rows: u16) FrameScrollCommit {
        return self.commitWithExpectedRows(
            committed_terminal_scroll_rows,
            self.terminal_scroll_rows,
        );
    }

    pub fn commitWithExpectedRows(
        self: FrameScrollPlan,
        committed_terminal_scroll_rows: u16,
        expected_terminal_scroll_rows: u16,
    ) FrameScrollCommit {
        std.debug.assert(expected_terminal_scroll_rows >= self.terminal_scroll_rows);
        const accepted_terminal_scroll_rows = @min(
            committed_terminal_scroll_rows,
            self.terminal_scroll_rows,
        );
        const accepted_rows = splitTerminalScrollRows(
            self.preserved_release_rows,
            self.requested_inline_advance_rows,
            accepted_terminal_scroll_rows,
        );
        return .{
            .physical_terminal_scroll_rows = committed_terminal_scroll_rows,
            .planned_terminal_scroll_rows = self.terminal_scroll_rows,
            .expected_terminal_scroll_rows = expected_terminal_scroll_rows,
            .accepted_terminal_scroll_rows = accepted_terminal_scroll_rows,
            .unplanned_terminal_scroll_rows = committed_terminal_scroll_rows -| expected_terminal_scroll_rows,
            .accepted_rows = accepted_rows,
        };
    }
};

pub fn merge(
    terminal_rows: u16,
    current_owned_top: u16,
    requested_release_rows: u16,
    inline_advance_rows: u32,
) FrameScrollPlan {
    const prior_owned_top = normalizeOwnedTop(current_owned_top, terminal_rows);
    const preserved_release_capacity = preservedReleaseCapacity(prior_owned_top);
    const release_floor_rows = @min(requested_release_rows, preserved_release_capacity);
    const terminal_scroll_rows = plannedTerminalScrollRows(
        terminal_rows,
        release_floor_rows,
        inline_advance_rows,
    );
    const row_split = splitTerminalScrollRows(
        preserved_release_capacity,
        inline_advance_rows,
        terminal_scroll_rows,
    );
    return .{
        .prior_owned_top = prior_owned_top,
        .requested_release_rows = release_floor_rows,
        .requested_inline_advance_rows = inline_advance_rows,
        .preserved_release_rows = row_split.preserved_release_rows,
        .terminal_scroll_rows = terminal_scroll_rows,
        .remaining_inline_advance_rows = inline_advance_rows -| row_split.inline_advance_rows,
        .post_scroll_owned_top = prior_owned_top -| row_split.preserved_release_rows,
    };
}

pub fn normalizeOwnedTop(owned_top: u16, terminal_rows: u16) u16 {
    if (terminal_rows == 0) return 0;
    if (owned_top == 0) return 1;
    return @min(owned_top, terminal_rows);
}

fn preservedReleaseCapacity(prior_owned_top: u16) u16 {
    return prior_owned_top -| 1;
}

fn plannedTerminalScrollRows(
    terminal_rows: u16,
    release_floor_rows: u16,
    inline_advance_rows: u32,
) u16 {
    if (terminal_rows == 0) return 0;
    return @intCast(@min(
        @as(u32, release_floor_rows) + inline_advance_rows,
        @as(u32, std.math.maxInt(u16)),
    ));
}

fn splitTerminalScrollRows(
    preserved_release_capacity: u16,
    requested_inline_advance_rows: u32,
    terminal_scroll_rows: u16,
) AcceptedScrollRows {
    const preserved_release_rows = @min(preserved_release_capacity, terminal_scroll_rows);
    const inline_advance_rows = @min(
        requested_inline_advance_rows,
        @as(u32, terminal_scroll_rows -| preserved_release_rows),
    );
    return .{
        .preserved_release_rows = preserved_release_rows,
        .inline_advance_rows = inline_advance_rows,
    };
}

test "merge prefers preserved release above inline advancement" {
    const plan = merge(10, 5, 3, 1);

    try std.testing.expectEqual(@as(u16, 5), plan.prior_owned_top);
    try std.testing.expectEqual(@as(u16, 3), plan.requested_release_rows);
    try std.testing.expectEqual(@as(u16, 1), plan.requested_inline_advance_rows);
    try std.testing.expectEqual(@as(u16, 4), plan.preserved_release_rows);
    try std.testing.expectEqual(@as(u16, 4), plan.terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 1), plan.remaining_inline_advance_rows);
    try std.testing.expectEqual(@as(u16, 1), plan.post_scroll_owned_top);
    try plan.validate(10);
}

test "none uses the canonical merge path" {
    try std.testing.expectEqual(merge(10, 99, 0, 0), FrameScrollPlan.none(10, 99));
    try std.testing.expectEqual(merge(0, 5, 0, 0), FrameScrollPlan.none(0, 5));
}

test "merge keeps equal preserved and inline advancement counts" {
    const plan = merge(10, 5, 2, 2);

    try std.testing.expectEqual(@as(u16, 4), plan.preserved_release_rows);
    try std.testing.expectEqual(@as(u16, 4), plan.terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 2), plan.remaining_inline_advance_rows);
    try std.testing.expectEqual(@as(u16, 1), plan.post_scroll_owned_top);
    try plan.validate(10);
}

test "merge adds preserved release and inline advancement" {
    const plan = merge(10, 5, 1, 3);

    try std.testing.expectEqual(@as(u16, 1), plan.requested_release_rows);
    try std.testing.expectEqual(@as(u16, 4), plan.preserved_release_rows);
    try std.testing.expectEqual(@as(u16, 4), plan.terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 3), plan.remaining_inline_advance_rows);
    try std.testing.expectEqual(@as(u16, 1), plan.post_scroll_owned_top);
    try plan.validate(10);
}

test "merge advances inline history after row one is owned" {
    const plan = merge(10, 1, 0, 3);

    try std.testing.expectEqual(@as(u16, 0), plan.preserved_release_rows);
    try std.testing.expectEqual(@as(u16, 3), plan.terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 1), plan.post_scroll_owned_top);
    try plan.validate(10);
}

test "merge does not clamp document movement to terminal height" {
    const plan = merge(4, 1, 0, 7);

    try std.testing.expectEqual(@as(u16, 7), plan.terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), plan.remaining_inline_advance_rows);
    try std.testing.expectEqual(@as(u16, 1), plan.post_scroll_owned_top);
    try plan.validate(4);
}

test "document append validates target geometry and clamps start column" {
    const append = FrameDocumentAppend{
        .bytes = "row\n",
        .start_row = 4,
        .start_col = 99,
    };

    try std.testing.expectEqual(@as(u16, 8), try append.validatedStartCol(8, 4));
    try std.testing.expectEqual(@as(u16, 1), try (FrameDocumentAppend{
        .bytes = "row\n",
        .start_row = 4,
        .start_col = 0,
    }).validatedStartCol(8, 4));
    try std.testing.expectError(
        error.InvalidFrameScrollPlan,
        (FrameDocumentAppend{
            .bytes = "row\n",
            .start_row = 5,
            .start_col = 1,
        }).validatedStartCol(8, 4),
    );
    try std.testing.expectError(
        error.InvalidFrameScrollPlan,
        append.validatedStartCol(0, 4),
    );
    try std.testing.expectEqual(@as(?u16, 4), try (FrameDocumentAppend{
        .start_row = 3,
        .clear = .{ .rows = 2 },
    }).validatedClearBottom(4));
    try std.testing.expectEqual(@as(?u16, 4), try (FrameDocumentAppend{
        .start_row = 3,
        .clear = .{ .rows = 3 },
    }).validatedClearBottom(4));
    try std.testing.expectError(error.InvalidFrameScrollPlan, (FrameDocumentAppend{
        .start_row = 3,
        .clear = .{ .rows = 0 },
    }).validatedClearBottom(4));
}

test "merge chunks inline advancement above u16 terminal movement limit" {
    const requested_rows: u32 = 100_000;
    const plan = merge(24, 1, 0, requested_rows);

    try std.testing.expectEqual(requested_rows, plan.requested_inline_advance_rows);
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), plan.terminal_scroll_rows);
    try std.testing.expectEqual(
        requested_rows - std.math.maxInt(u16),
        plan.remaining_inline_advance_rows,
    );
    try std.testing.expectEqual(
        @as(u32, std.math.maxInt(u16)),
        plan.acceptedInlineRows(plan.terminal_scroll_rows),
    );
    try plan.validate(24);
}

test "merge preserves inline debt for zero height terminal" {
    const plan = merge(0, 5, 0, 7);

    try std.testing.expectEqual(@as(u16, 0), plan.prior_owned_top);
    try std.testing.expectEqual(@as(u16, 0), plan.terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 7), plan.remaining_inline_advance_rows);
    try std.testing.expectEqual(@as(u16, 0), plan.post_scroll_owned_top);
    try plan.validate(0);
}

test "merge saturates zero and one based ownership boundaries" {
    const zero = merge(10, 0, 99, 0);
    const above_height = merge(10, 99, 99, 0);

    try std.testing.expectEqual(@as(u16, 1), zero.prior_owned_top);
    try std.testing.expectEqual(@as(u16, 0), zero.requested_release_rows);
    try std.testing.expectEqual(@as(u16, 1), zero.post_scroll_owned_top);
    try zero.validate(10);

    try std.testing.expectEqual(@as(u16, 10), above_height.prior_owned_top);
    try std.testing.expectEqual(@as(u16, 9), above_height.requested_release_rows);
    try std.testing.expectEqual(@as(u16, 1), above_height.post_scroll_owned_top);
    try above_height.validate(10);
}

test "accepted rows acknowledge release before inline advancement" {
    const plan = merge(10, 5, 3, 4);

    const partial = plan.acceptedRows(2);
    try std.testing.expectEqual(@as(u16, 2), partial.preserved_release_rows);
    try std.testing.expectEqual(@as(u32, 0), partial.inline_advance_rows);
    try std.testing.expectEqual(@as(u16, 2), plan.acceptedPreservedRows(2));
    try std.testing.expectEqual(@as(u32, 0), plan.acceptedInlineRows(2));

    const split = plan.acceptedRows(5);
    try std.testing.expectEqual(@as(u16, 4), split.preserved_release_rows);
    try std.testing.expectEqual(@as(u32, 1), split.inline_advance_rows);
    try std.testing.expectEqual(@as(u16, 4), plan.acceptedPreservedRows(5));
    try std.testing.expectEqual(@as(u32, 1), plan.acceptedInlineRows(5));

    const overflow = plan.acceptedRows(99);
    try std.testing.expectEqual(@as(u16, 4), overflow.preserved_release_rows);
    try std.testing.expectEqual(@as(u32, 3), overflow.inline_advance_rows);
    try std.testing.expectEqual(@as(u32, 3), plan.acceptedInlineRows(99));

    const commit = plan.commit(99);
    try std.testing.expectEqual(@as(u16, 99), commit.physical_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 7), commit.planned_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 7), commit.expected_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 7), commit.accepted_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 92), commit.unplanned_terminal_scroll_rows);
    try std.testing.expect(!commit.complete());
}

test "accepted rows cap physical movement at planned scroll rows" {
    const idle = merge(10, 5, 0, 0);
    const idle_commit = idle.commit(4);

    try std.testing.expectEqual(@as(u16, 4), idle_commit.physical_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), idle_commit.planned_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), idle_commit.expected_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), idle_commit.accepted_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 4), idle_commit.unplanned_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), idle_commit.accepted_rows.preserved_release_rows);
    try std.testing.expectEqual(@as(u32, 0), idle_commit.accepted_rows.inline_advance_rows);
    try std.testing.expect(!idle_commit.complete());
}

test "unplanned physical rows do not complete the scroll ledger" {
    const plan = merge(10, 5, 3, 4);
    const commit = plan.commit(plan.terminal_scroll_rows + 1);

    try std.testing.expectEqual(@as(u16, 8), commit.physical_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 7), commit.planned_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 7), commit.expected_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 7), commit.accepted_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 1), commit.unplanned_terminal_scroll_rows);
    try std.testing.expect(!commit.complete());
}

test "expected physical movement can complete without inline advancement" {
    const plan = merge(10, 1, 0, 0);
    const commit = plan.commitWithExpectedRows(3, 3);

    try std.testing.expectEqual(@as(u16, 3), commit.physical_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), commit.planned_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 3), commit.expected_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), commit.accepted_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), commit.unplanned_terminal_scroll_rows);
    try std.testing.expect(commit.complete());
}

test "inline movement consumes preserved prefix before transcript advancement" {
    const plan = merge(10, 6, 0, 3);

    try std.testing.expectEqual(@as(u16, 0), plan.requested_release_rows);
    try std.testing.expectEqual(@as(u16, 3), plan.terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 3), plan.preserved_release_rows);
    try std.testing.expectEqual(@as(u32, 3), plan.remaining_inline_advance_rows);
    try std.testing.expectEqual(@as(u16, 3), plan.post_scroll_owned_top);

    const partial = plan.acceptedRows(2);
    try std.testing.expectEqual(@as(u16, 2), partial.preserved_release_rows);
    try std.testing.expectEqual(@as(u32, 0), partial.inline_advance_rows);

    const complete = plan.acceptedRows(plan.terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 3), complete.preserved_release_rows);
    try std.testing.expectEqual(@as(u32, 0), complete.inline_advance_rows);
}

test "terminal movement rows resolve append materialization and alignment" {
    const normal = try TerminalMovementRows.resolve(5, 2, false);
    try std.testing.expectEqual(@as(u16, 5), normal.planned_scroll_rows);
    try std.testing.expectEqual(@as(u16, 2), normal.materialized_scroll_rows);
    try std.testing.expectEqual(@as(u16, 3), normal.alignment_scroll_rows);
    try std.testing.expectEqual(@as(u16, 5), normal.expected_scroll_rows);

    try std.testing.expectError(
        error.InvalidFrameScrollPlan,
        TerminalMovementRows.resolve(1, 2, false),
    );

    const replay = try TerminalMovementRows.resolve(0, 4, true);
    try std.testing.expectEqual(@as(u16, 0), replay.planned_scroll_rows);
    try std.testing.expectEqual(@as(u16, 4), replay.materialized_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), replay.alignment_scroll_rows);
    try std.testing.expectEqual(@as(u16, 4), replay.expected_scroll_rows);
}

test "validate rejects requested release above owned prefix" {
    const plan = FrameScrollPlan{
        .prior_owned_top = 2,
        .requested_release_rows = 2,
        .requested_inline_advance_rows = 0,
        .preserved_release_rows = 1,
        .terminal_scroll_rows = 1,
        .remaining_inline_advance_rows = 0,
        .post_scroll_owned_top = 1,
    };

    try std.testing.expectError(error.InvalidFrameScrollPlan, plan.validate(10));
}

test "validate rejects prior ownership above terminal height" {
    const plan = FrameScrollPlan{
        .prior_owned_top = 11,
        .requested_release_rows = 1,
        .requested_inline_advance_rows = 0,
        .preserved_release_rows = 1,
        .terminal_scroll_rows = 1,
        .remaining_inline_advance_rows = 0,
        .post_scroll_owned_top = 10,
    };

    try std.testing.expectError(error.InvalidFrameScrollPlan, plan.validate(10));
}

test "validate rejects non canonical terminal movement rows" {
    var plan = merge(10, 5, 2, 3);
    plan.terminal_scroll_rows = 4;

    try std.testing.expectError(error.InvalidFrameScrollPlan, plan.validate(10));
}

test "validate rejects non canonical preserved release rows" {
    var plan = merge(10, 5, 2, 3);
    plan.preserved_release_rows = 3;

    try std.testing.expectError(error.InvalidFrameScrollPlan, plan.validate(10));
}

test "validate rejects non canonical remaining inline debt" {
    var plan = merge(10, 5, 2, 3);
    plan.remaining_inline_advance_rows = 1;

    try std.testing.expectError(error.InvalidFrameScrollPlan, plan.validate(10));
}

test "validate rejects non canonical post scroll ownership" {
    var plan = merge(10, 5, 2, 3);
    plan.post_scroll_owned_top = 2;

    try std.testing.expectError(error.InvalidFrameScrollPlan, plan.validate(10));
}

test "validate accepts canonical merged plan" {
    const plan = merge(10, 5, 2, 3);

    try plan.validate(10);
}
