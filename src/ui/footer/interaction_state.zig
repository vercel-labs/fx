const std = @import("std");
const approval_decision = @import("../../core/permissions/approval_decision.zig");
const approval_prompt = @import("../../core/permissions/approval_prompt.zig");
const permission_request = @import("../../core/permissions/permission_request.zig");
const types = @import("../../core/shared/types.zig");
const input_action = @import("../../core/input/input_action.zig");
const ui_input = @import("../input/runtime.zig");

const Allocator = std.mem.Allocator;
const ApprovalPrompt = approval_prompt.ApprovalPrompt;

pub const approval_chrome_rows: u16 = 3;
pub const approval_panel_rows_compact: u16 = 8;
pub const approval_panel_rows_spacious: u16 = 11;
pub const approval_spacious_min_terminal_rows: u16 = 34;
pub const approval_once_label = "1. Yes";
pub const approval_always_file_label = "2. Yes, and don't ask again for this request";
pub const approval_deny_label = "3. No";
pub const approval_hint = "1–3 Choose now    ↑↓ or Tab Options    Enter Confirm    Esc Cancel";
pub const approval_amendment_hint = "1–3 Choose now    ↑↓ Options    Tab Amend    Enter Confirm    Esc Cancel";
pub const approval_hint_compact = "1–3 Choose now    Enter Confirm    Esc Cancel";
pub const approval_hint_minimal = "Enter Confirm    Esc Cancel";
// Ordered widest-first; every variant keeps the enter/esc controls so narrow
// terminals never lose the submit and cancel instructions.
pub const approval_hint_variants = [_][]const u8{ approval_hint, approval_hint_compact, approval_hint_minimal };
pub const approval_amendment_hint_variants = [_][]const u8{ approval_amendment_hint, approval_hint_compact, approval_hint_minimal };

pub const ApprovalScreenCommit = struct {
    request_id: u64,
    rows: u16,
    cols: u16,
    file_identity_visible: bool,
    all_decision_controls_visible: bool,
    changed_or_notice_visible: bool,
    document_scrollable: bool,
};

pub const ApprovalScreenState = struct {
    document_scroll_rows: usize = 0,
    screen_commit: ?ApprovalScreenCommit = null,
    changed_or_notice_observed: bool = false,
    file_document_hydrated: bool = false,

    pub fn clear(self: *ApprovalScreenState) void {
        self.* = .{};
    }

    pub fn scrollDocument(self: *ApprovalScreenState, delta: i32) void {
        if (delta < 0) {
            const amount: usize = @intCast(-@as(i64, delta));
            self.document_scroll_rows -|= amount;
        } else {
            self.document_scroll_rows +|= @intCast(delta);
        }
    }

    pub fn clampDocumentScroll(self: *ApprovalScreenState, max_scroll_rows: usize) void {
        self.document_scroll_rows = @min(self.document_scroll_rows, max_scroll_rows);
    }

    pub fn invalidateScreenCommit(self: *ApprovalScreenState) void {
        self.screen_commit = null;
    }

    pub fn markFileDocumentHydrated(self: *ApprovalScreenState) void {
        self.file_document_hydrated = true;
    }

    pub fn recordScreenCommit(
        self: *ApprovalScreenState,
        request_id: u64,
        commit: ApprovalScreenCommit,
    ) void {
        if (request_id != commit.request_id) return;
        self.screen_commit = commit;
        self.changed_or_notice_observed = self.changed_or_notice_observed or
            commit.changed_or_notice_visible;
    }
};

fn applyApprovalByteForTest(
    prompt: *ApprovalPrompt,
    alloc: Allocator,
    byte: u8,
    max_len: ?usize,
) !approval_decision.Event {
    const action = ui_input.approvalActionFromByte(byte) orelse return .none;
    const amendment_allowed: ?bool = if (prompt.request) |request|
        request.amendment_allowed
    else
        null;
    return prompt.decision.apply(
        alloc,
        action,
        amendment_allowed,
        max_len,
    );
}

test "command approval retains its committed screen state across review sync" {
    const alloc = std.testing.allocator;
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    var screen = ApprovalScreenState{};
    const request: permission_request.PermissionRequest = .{
        .id = 21,
        .label = "shell.run printf '%s' command-review",
    };
    try std.testing.expect(try prompt.syncRequest(alloc, request));
    screen.scrollDocument(6);
    screen.recordScreenCommit(request.id, .{
        .request_id = request.id,
        .rows = 14,
        .cols = 80,
        .file_identity_visible = false,
        .all_decision_controls_visible = true,
        .changed_or_notice_visible = false,
        .document_scrollable = true,
    });

    try std.testing.expect(!prompt.syncReview(null));
    try std.testing.expect(prompt.review == null);
    try std.testing.expectEqual(@as(usize, 6), screen.document_scroll_rows);
    try std.testing.expectEqual(request.id, screen.screen_commit.?.request_id);
    try std.testing.expect(screen.screen_commit.?.document_scrollable);
}

test "approval prompt enters amendment with tab and submits selected decision" {
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(std.testing.allocator);

    try std.testing.expect(try prompt.syncRequest(std.testing.allocator, .{ .label = "shell.run npm run dev" }));
    try std.testing.expect(prompt.isActive());
    try std.testing.expect(prompt.can_amend_selected_choice());

    try std.testing.expectEqual(
        approval_decision.Event.redraw,
        try applyApprovalByteForTest(&prompt, std.testing.allocator, '\t', null),
    );
    try std.testing.expectEqual(@as(u8, 0), prompt.decision.choice_index);
    try std.testing.expect(prompt.isAmending());
    for ("amend") |byte| {
        try std.testing.expectEqual(
            approval_decision.Event.redraw,
            try applyApprovalByteForTest(&prompt, std.testing.allocator, byte, null),
        );
    }
    try std.testing.expectEqualStrings("amend", prompt.decision.selectedDraft());

    const event = try applyApprovalByteForTest(
        &prompt,
        std.testing.allocator,
        '\n',
        null,
    );
    switch (event) {
        .decision => |decision| try std.testing.expectEqual(types.ToolPermissionDecision.once, decision),
        else => return error.TestExpectedEqual,
    }
}

test "approval amendment bounded typing rejects without changing its draft" {
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(std.testing.allocator);

    try std.testing.expect(try prompt.syncRequest(std.testing.allocator, .{
        .label = "shell.run npm test",
    }));
    _ = try applyApprovalByteForTest(&prompt, std.testing.allocator, '\t', null);
    try std.testing.expectEqual(
        approval_decision.Event.redraw,
        try applyApprovalByteForTest(&prompt, std.testing.allocator, 'a', 1),
    );
    try std.testing.expectEqual(
        approval_decision.Event.limit_exceeded,
        try applyApprovalByteForTest(&prompt, std.testing.allocator, 'b', 1),
    );
    try std.testing.expectEqual(
        approval_decision.InsertResult.limit_exceeded,
        try prompt.decision.insertAmendmentSlice(std.testing.allocator, "é", 2),
    );
    try std.testing.expectEqualStrings("a", prompt.decision.selectedDraft());
    try std.testing.expectEqual(@as(usize, 1), prompt.draftCursorForChoice(0));
    try std.testing.expectEqual(@as(u8, 0), prompt.decision.choice_index);
}

test "approval prompt preserves amendment drafts while moving choices" {
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(std.testing.allocator);

    try std.testing.expect(try prompt.syncRequest(std.testing.allocator, .{ .label = "shell.run npm test" }));
    _ = try applyApprovalByteForTest(&prompt, std.testing.allocator, '\t', null);
    _ = try applyApprovalByteForTest(&prompt, std.testing.allocator, 'y', null);
    _ = try applyApprovalByteForTest(&prompt, std.testing.allocator, 'e', null);
    _ = try applyApprovalByteForTest(&prompt, std.testing.allocator, 's', null);

    _ = try prompt.decision.apply(
        std.testing.allocator,
        .{ .move_choice = .next },
        true,
        null,
    );
    try std.testing.expect(!prompt.isAmending());
    try std.testing.expect(!prompt.can_amend_selected_choice());
    try std.testing.expectEqualStrings("yes", prompt.draftForChoice(0));

    _ = try prompt.decision.apply(
        std.testing.allocator,
        .{ .move_choice = .next },
        true,
        null,
    );
    try std.testing.expectEqual(@as(u8, 2), prompt.decision.choice_index);
    try std.testing.expect(prompt.can_amend_selected_choice());
    _ = try applyApprovalByteForTest(&prompt, std.testing.allocator, '\t', null);
    _ = try applyApprovalByteForTest(&prompt, std.testing.allocator, 'n', null);
    _ = try applyApprovalByteForTest(&prompt, std.testing.allocator, 'o', null);
    try std.testing.expectEqualStrings("no", prompt.decision.selectedDraft());

    _ = try prompt.decision.apply(
        std.testing.allocator,
        .{ .move_choice = .next },
        true,
        null,
    );
    try std.testing.expectEqual(@as(u8, 0), prompt.decision.choice_index);
    try std.testing.expectEqualStrings("yes", prompt.decision.selectedDraft());
}

test "non-amendable approval keeps tab choice navigation" {
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(std.testing.allocator);

    try std.testing.expect(try prompt.syncRequest(std.testing.allocator, .{
        .label = "shell.run sleep 30",
        .amendment_allowed = false,
    }));
    for ([_]u8{ 1, 2, 0 }) |expected_choice| {
        try std.testing.expect(!prompt.can_amend_selected_choice());
        try std.testing.expectEqual(
            approval_decision.Event.redraw,
            try applyApprovalByteForTest(&prompt, std.testing.allocator, '\t', null),
        );
        try std.testing.expectEqual(expected_choice, prompt.decision.choice_index);
        try std.testing.expect(!prompt.isAmending());
    }
    try std.testing.expectEqual(
        approval_decision.Event.none,
        try applyApprovalByteForTest(&prompt, std.testing.allocator, 'x', null),
    );
}

test "approval prompt digits submit their mapped decisions" {
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(std.testing.allocator);

    try std.testing.expect(try prompt.syncRequest(std.testing.allocator, .{ .label = "shell.run curl -I https://example.com" }));

    const cases = [_]struct {
        byte: u8,
        expected: types.ToolPermissionDecision,
    }{
        .{ .byte = '1', .expected = .once },
        .{ .byte = '2', .expected = .always },
        .{ .byte = '3', .expected = .deny },
    };
    for (cases) |case| {
        switch (try applyApprovalByteForTest(
            &prompt,
            std.testing.allocator,
            case.byte,
            null,
        )) {
            .decision => |decision| try std.testing.expectEqual(case.expected, decision),
            else => return error.TestExpectedDecision,
        }
    }
}

test "approval prompt ignores inert printable bytes without changing choice" {
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(std.testing.allocator);

    try std.testing.expect(try prompt.syncRequest(std.testing.allocator, .{ .label = "shell.run curl -I https://example.com" }));
    prompt.decision.choice_index = 1;

    for ("typing a reply 0456789 YP hjkl") |byte| {
        try std.testing.expectEqual(
            approval_decision.Event.none,
            try applyApprovalByteForTest(&prompt, std.testing.allocator, byte, null),
        );
        try std.testing.expectEqual(@as(u8, 1), prompt.decision.choice_index);
    }
}

test "approval prompt ignores printable shortcut bytes" {
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(std.testing.allocator);

    try std.testing.expect(try prompt.syncRequest(std.testing.allocator, .{ .label = "shell.run curl -I https://example.com" }));

    for ("0456789yYpPhjkl") |byte| {
        try std.testing.expectEqual(
            approval_decision.Event.none,
            try applyApprovalByteForTest(&prompt, std.testing.allocator, byte, null),
        );
        try std.testing.expectEqual(@as(u8, 0), prompt.decision.choice_index);
    }
}

test "approval prompt treats Ctrl+C as deny without exiting" {
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(std.testing.allocator);

    try std.testing.expect(try prompt.syncRequest(std.testing.allocator, .{ .label = "write_file README.md" }));

    const event = try applyApprovalByteForTest(
        &prompt,
        std.testing.allocator,
        3,
        null,
    );
    switch (event) {
        .decision => |decision| try std.testing.expectEqual(types.ToolPermissionDecision.deny, decision),
        else => return error.TestExpectedEqual,
    }
}

test "kitty-protocol Ctrl+C decodes to byte 3" {
    const input_runtime = @import("../input/runtime.zig");
    var stage: u8 = 1;
    var param: u16 = 0;
    var param2: u16 = 0;

    try std.testing.expectEqual(@as(?input_action.Action, null), input_runtime.consumeInputEscapeByte(&stage, &param, &param2, '['));
    try std.testing.expectEqual(@as(?input_action.Action, null), input_runtime.consumeInputEscapeByte(&stage, &param, &param2, '9'));
    try std.testing.expectEqual(@as(?input_action.Action, null), input_runtime.consumeInputEscapeByte(&stage, &param, &param2, '9'));
    try std.testing.expectEqual(@as(?input_action.Action, null), input_runtime.consumeInputEscapeByte(&stage, &param, &param2, ';'));
    try std.testing.expectEqual(@as(?input_action.Action, null), input_runtime.consumeInputEscapeByte(&stage, &param, &param2, '5'));

    const action = input_runtime.consumeInputEscapeByte(&stage, &param, &param2, 'u');
    switch (action.?) {
        .remapped_byte => |b| try std.testing.expectEqual(@as(u8, 3), b),
        else => return error.TestExpectedRemappedByte,
    }
}
