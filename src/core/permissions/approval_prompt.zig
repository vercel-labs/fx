const std = @import("std");
const diff_mod = @import("../output/diff.zig");
const approval_decision = @import("approval_decision.zig");
const permission_request = @import("permission_request.zig");
const session_permission_state = @import("session_permission_state.zig");

const Allocator = std.mem.Allocator;

pub const Projection = struct {
    request: permission_request.PermissionRequest,
    choice_index: u8,
    amendment_choice: ?u8,
    allow_draft: []const u8,
    allow_draft_cursor: usize,
    deny_draft: []const u8,
    deny_draft_cursor: usize,
    review: ?*const diff_mod.FileReview,

    pub fn can_amend_selected_choice(self: Projection) bool {
        return self.request.amendment_allowed and
            (self.choice_index == 0 or self.choice_index == 2);
    }

    pub fn amendmentChoice(self: Projection) ?u8 {
        return self.amendment_choice;
    }

    pub fn draftForChoice(self: Projection, choice: u8) []const u8 {
        return switch (choice) {
            0 => self.allow_draft,
            2 => self.deny_draft,
            else => "",
        };
    }

    pub fn draftCursorForChoice(self: Projection, choice: u8) usize {
        return switch (choice) {
            0 => self.allow_draft_cursor,
            2 => self.deny_draft_cursor,
            else => 0,
        };
    }

    pub fn currentReview(self: Projection) ?*const diff_mod.FileReview {
        return self.review;
    }
};

pub const ApprovalPrompt = struct {
    request: ?permission_request.OwnedPermissionRequest = null,
    decision: approval_decision.State = .{},
    review: ?*const diff_mod.FileReview = null,
    review_request_id: u64 = 0,
    rule_management: ?session_permission_state.OwnedConfirmedRuleEvent = null,

    pub fn deinit(self: *ApprovalPrompt, alloc: Allocator) void {
        self.clearWithReason(alloc, "deinit");
    }

    pub fn isActive(self: ApprovalPrompt) bool {
        return self.request != null;
    }

    /// Returns a borrowed immutable view of the active prompt. Every slice in
    /// the projection remains valid only until the next prompt mutation.
    pub fn projection(self: *const ApprovalPrompt) ?Projection {
        const request = self.request orelse return null;
        return .{
            .request = request.view(),
            .choice_index = self.decision.choice_index,
            .amendment_choice = self.decision.amendmentChoice(),
            .allow_draft = self.decision.draftForChoice(0),
            .allow_draft_cursor = self.decision.draftCursorForChoice(0),
            .deny_draft = self.decision.draftForChoice(2),
            .deny_draft_cursor = self.decision.draftCursorForChoice(2),
            .review = self.currentReview(),
        };
    }

    pub fn clear(self: *ApprovalPrompt, alloc: Allocator) void {
        self.clearWithReason(alloc, "cleared");
    }

    pub fn clearWithReason(self: *ApprovalPrompt, alloc: Allocator, reason: []const u8) void {
        if (self.request) |*request| request.deinit(alloc);
        if (self.rule_management) |*event| event.deinit(alloc);
        self.rule_management = null;
        self.request = null;
        self.decision.reset(alloc, reason);
        self.clearReview();
    }

    pub fn syncRequest(
        self: *ApprovalPrompt,
        alloc: Allocator,
        request: ?permission_request.PermissionRequest,
    ) permission_request.RequestCloneError!bool {
        if (request) |value| {
            if (self.request) |*current| {
                if (permission_request.PermissionRequest.eql(current.view(), value)) return false;
            }

            const owned = try permission_request.OwnedPermissionRequest.dupe(alloc, value);
            self.clearWithReason(
                alloc,
                if (self.request != null) "request_replaced" else "request_started",
            );
            self.request = owned;
            self.decision.setConfirmationOnly(value.confirmation_only);
            return true;
        }

        if (self.request == null) return false;
        self.clearWithReason(alloc, "request_cleared");
        return true;
    }

    pub fn syncRuleManagement(
        self: *ApprovalPrompt,
        alloc: Allocator,
        request: permission_request.PermissionRequest,
        event: session_permission_state.ConfirmedRuleEvent,
    ) !void {
        if (!request.confirmation_only or request.file != null) {
            return error.InvalidRuleManagementRequest;
        }
        const owned_request = try permission_request.OwnedPermissionRequest.dupe(
            alloc,
            request,
        );
        var request_owned = true;
        errdefer if (request_owned) {
            var value = owned_request;
            value.deinit(alloc);
        };
        const owned_event = try session_permission_state.OwnedConfirmedRuleEvent.dupe(
            alloc,
            event,
        );
        self.clearWithReason(alloc, "rule_management_started");
        self.request = owned_request;
        request_owned = false;
        self.rule_management = owned_event;
        self.decision.setConfirmationOnly(true);
    }

    pub fn syncReview(self: *ApprovalPrompt, review: ?*const diff_mod.FileReview) bool {
        const request = self.request orelse {
            const changed = self.review != null or self.review_request_id != 0;
            self.clearReview();
            return changed;
        };
        if (request.file == null) {
            const changed = self.review != null or self.review_request_id != 0;
            self.clearReview();
            return changed;
        }

        if (self.review == review and self.review_request_id == request.id) return false;
        self.review = review;
        self.review_request_id = if (review == null) 0 else request.id;
        return true;
    }

    pub fn currentReview(self: ApprovalPrompt) ?*const diff_mod.FileReview {
        const request = self.request orelse return null;
        if (request.file == null or self.review_request_id != request.id) return null;
        return self.review;
    }

    pub fn isAmending(self: ApprovalPrompt) bool {
        return self.decision.isAmending();
    }

    pub fn can_amend_selected_choice(self: ApprovalPrompt) bool {
        const request = self.request orelse return false;
        return self.decision.canAmend(request.amendment_allowed);
    }

    pub fn amendmentChoice(self: ApprovalPrompt) ?u8 {
        return self.decision.amendmentChoice();
    }

    pub fn draftForChoice(self: ApprovalPrompt, choice: u8) []const u8 {
        return self.decision.draftForChoice(choice);
    }

    pub fn draftCursorForChoice(self: ApprovalPrompt, choice: u8) usize {
        return self.decision.draftCursorForChoice(choice);
    }

    pub fn clearAfterAcceptedSubmission(self: *ApprovalPrompt, alloc: Allocator) void {
        if (self.request) |*request| request.deinit(alloc);
        if (self.rule_management) |*event| event.deinit(alloc);
        self.rule_management = null;
        self.request = null;
        self.decision.resetAfterSubmission(alloc);
        self.clearReview();
    }

    fn clearReview(self: *ApprovalPrompt) void {
        self.review = null;
        self.review_request_id = 0;
    }
};

fn approvalPreview() diff_mod.FileChangePreview {
    return .{
        .path = "note.txt",
        .lines = &.{
            .{ .op = .deletion, .old_line = 2, .text = "before" },
            .{ .op = .addition, .new_line = 2, .text = "after" },
        },
        .additions = 1,
        .deletions = 1,
        .truncated = false,
    };
}

fn approvalFileRequest(
    preview: diff_mod.FileChangePreview,
) permission_request.FileApprovalRequest {
    return .{
        .kind = .edit,
        .intent = .mutation,
        .preview = preview,
        .scope = .workspace_files,
    };
}

test "approval prompt owns replaces and clears structured requests" {
    const alloc = std.testing.allocator;
    const request: permission_request.PermissionRequest = .{
        .label = "edit_file note.txt",
        .file = approvalFileRequest(approvalPreview()),
    };

    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    try std.testing.expect(try prompt.syncRequest(alloc, request));
    const stored = prompt.request.?;
    try std.testing.expectEqualStrings(request.label, stored.label);
    try std.testing.expect(diff_mod.FileChangePreview.eql(
        request.file.?.preview,
        stored.file.?.preview,
    ));

    prompt.decision.choice_index = 2;
    const stored_label_ptr = prompt.request.?.label.ptr;
    try std.testing.expect(!try prompt.syncRequest(alloc, request));
    try std.testing.expectEqual(stored_label_ptr, prompt.request.?.label.ptr);
    try std.testing.expectEqual(@as(u8, 2), prompt.decision.choice_index);

    try std.testing.expect(try prompt.syncRequest(
        alloc,
        .{ .label = "shell.run npm test" },
    ));
    try std.testing.expectEqualStrings("shell.run npm test", prompt.request.?.label);
    try std.testing.expect(prompt.request.?.file == null);
    try std.testing.expectEqual(@as(u8, 0), prompt.decision.choice_index);

    prompt.decision.choice_index = 1;
    try std.testing.expect(try prompt.syncRequest(alloc, null));
    try std.testing.expect(!prompt.isActive());
    try std.testing.expectEqual(@as(u8, 0), prompt.decision.choice_index);
    try std.testing.expect(!try prompt.syncRequest(alloc, null));
}

test "approval prompt treats byte-identical replacement ids as new requests" {
    const alloc = std.testing.allocator;
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);

    const request_a: permission_request.PermissionRequest = .{
        .id = 10,
        .label = "file_mutation",
        .file = approvalFileRequest(approvalPreview()),
    };
    try std.testing.expect(try prompt.syncRequest(alloc, request_a));
    prompt.decision.choice_index = 2;

    var request_b = request_a;
    request_b.id = 11;
    try std.testing.expect(try prompt.syncRequest(alloc, request_b));
    try std.testing.expectEqual(@as(u64, 11), prompt.request.?.id);
    try std.testing.expectEqual(@as(u8, 0), prompt.decision.choice_index);
}

test "approval prompt keeps full review request-bound" {
    const alloc = std.testing.allocator;
    var review = try diff_mod.FileReview.init(alloc, "", "one\ntwo\n");
    defer review.deinit(alloc);

    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);

    const request_a: permission_request.PermissionRequest = .{
        .id = 10,
        .label = "file_mutation",
        .file = approvalFileRequest(approvalPreview()),
    };
    try std.testing.expect(try prompt.syncRequest(alloc, request_a));
    try std.testing.expect(prompt.syncReview(&review));
    try std.testing.expect(prompt.currentReview() == &review);

    var request_b = request_a;
    request_b.id = 11;
    try std.testing.expect(try prompt.syncRequest(alloc, request_b));
    try std.testing.expect(prompt.currentReview() == null);
}

test "approval projection borrows immutable active state" {
    const alloc = std.testing.allocator;
    var review = try diff_mod.FileReview.init(alloc, "", "one\ntwo\n");
    defer review.deinit(alloc);

    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    try std.testing.expect(prompt.projection() == null);
    try std.testing.expect(try prompt.syncRequest(alloc, .{
        .id = 41,
        .label = "edit_file note.txt",
        .file = approvalFileRequest(approvalPreview()),
    }));
    try std.testing.expect(prompt.syncReview(&review));
    _ = try prompt.decision.apply(alloc, .tab, true, null);
    _ = try prompt.decision.apply(alloc, .{ .insert_ascii = 'y' }, true, null);
    _ = try prompt.decision.apply(alloc, .{ .move_choice = .previous }, true, null);
    _ = try prompt.decision.apply(alloc, .tab, true, null);
    _ = try prompt.decision.apply(alloc, .{ .insert_ascii = 'n' }, true, null);

    const projection = prompt.projection().?;
    try std.testing.expectEqual(@as(u64, 41), projection.request.id);
    try std.testing.expectEqualStrings("edit_file note.txt", projection.request.label);
    try std.testing.expectEqual(prompt.request.?.label.ptr, projection.request.label.ptr);
    try std.testing.expectEqual(@as(u8, 2), projection.choice_index);
    try std.testing.expectEqual(@as(?u8, 2), projection.amendmentChoice());
    try std.testing.expect(projection.can_amend_selected_choice());
    try std.testing.expectEqualStrings("y", projection.draftForChoice(0));
    try std.testing.expectEqualStrings("n", projection.draftForChoice(2));
    try std.testing.expectEqual(@as(usize, 1), projection.draftCursorForChoice(0));
    try std.testing.expectEqual(@as(usize, 1), projection.draftCursorForChoice(2));
    try std.testing.expect(projection.currentReview() == &review);
}

test "command approval ignores absent file review" {
    const alloc = std.testing.allocator;
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    try std.testing.expect(try prompt.syncRequest(alloc, .{
        .id = 21,
        .label = "shell.run printf '%s' command-review",
    }));

    try std.testing.expect(!prompt.syncReview(null));
    try std.testing.expect(prompt.review == null);
    try std.testing.expectEqual(@as(u64, 0), prompt.review_request_id);
}

fn checkApprovalPromptCloneAllocationFailures(alloc: Allocator) !void {
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);

    const request: permission_request.PermissionRequest = .{
        .id = 7,
        .label = "edit_file state.zig",
        .file = approvalFileRequest(approvalPreview()),
    };
    try std.testing.expect(try prompt.syncRequest(alloc, request));
}

test "approval prompt frees partial cloned request allocations" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkApprovalPromptCloneAllocationFailures,
        .{},
    );
}
