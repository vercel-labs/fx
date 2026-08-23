const std = @import("std");
const app_lifecycle = @import("app_lifecycle.zig");
const app_render_runtime = @import("app_render_runtime.zig");
const types = @import("../shared/types.zig");

pub const State = struct {
    active: bool = false,
    confirming: bool = false,
    history_index: usize = 0,
    entry_id: u32 = 0,

    pub fn reset(self: *State) void {
        self.* = .{};
    }
};

const Candidate = struct {
    history_index: usize,
    entry_id: u32,
};

fn turnHasTextPrompt(turn: types.HistoryTurn) bool {
    return switch (turn) {
        .assistant => |value| value.user.text.len > 0 and value.user.images.len == 0,
        .background_command => |value| value.user.text.len > 0 and value.user.images.len == 0,
        .interrupted => |value| value.user.text.len > 0 and value.user.images.len == 0,
        .compacted_summary => false,
    };
}

fn candidateAtReverseOffset(app: anytype, requested: usize) ?Candidate {
    var history_index = app.session.history.items.len;
    var entry_index = app.shell.entries.items.len;
    var offset: usize = 0;

    while (history_index > 0 and entry_index > 0) {
        history_index -= 1;
        if (!turnHasTextPrompt(app.session.history.items[history_index])) continue;

        while (entry_index > 0) {
            entry_index -= 1;
            const entry = app.shell.entries.items[entry_index];
            if (entry != .user_turn or entry.user_turn.turn.text.len == 0) continue;
            if (offset == requested) return .{
                .history_index = history_index,
                .entry_id = entry.user_turn.id,
            };
            offset += 1;
            break;
        }
    }
    return null;
}

fn selectedReverseOffset(app: anytype) usize {
    var offset: usize = 0;
    while (candidateAtReverseOffset(app, offset)) |candidate| : (offset += 1) {
        if (candidate.history_index == app.chat_rewind.history_index) return offset;
    }
    return 0;
}

fn selectCandidate(app: anytype, candidate: Candidate) void {
    app.chat_rewind.history_index = candidate.history_index;
    app.chat_rewind.entry_id = candidate.entry_id;
    app.shell.setRewindSelectedEntry(candidate.entry_id);
    var viewport = app.shell.snapshotFullTranscriptViewport();
    viewport.follow_tail = false;
    viewport.anchor_entry_id = candidate.entry_id;
    viewport.anchor_pending = true;
    viewport.bookmark_pending = false;
    app.shell.restoreFullTranscriptViewport(viewport);
}

pub fn begin(app: anytype) !bool {
    if (comptime @hasField(@TypeOf(app.*), "stream")) {
        if (app.stream.active) return false;
    }
    if (comptime @hasField(@TypeOf(app.*), "worker")) {
        if (app.worker.queuedPromptCount() > 0) return false;
    }
    const candidate = candidateAtReverseOffset(app, 0) orelse return false;
    if (app.terminal.alternate_screen_owner != .none) return false;
    if (app.approval_prompt.isActive()) return false;

    app.chat_rewind = .{ .active = true };
    errdefer {
        app.chat_rewind.reset();
        app.shell.setRewindSelectedEntry(null);
    }
    try app_lifecycle.openFullTranscript(
        app.alloc,
        &app.terminal,
        &app.shell,
        &app.metrics,
    );
    selectCandidate(app, candidate);
    app_render_runtime.Runtime(@TypeOf(app.*)).requestActiveSurfaceFrame(app, .modal);
    return true;
}

pub fn move(app: anytype, toward_older: bool) void {
    if (!app.chat_rewind.active) return;
    app.chat_rewind.confirming = false;
    const current = selectedReverseOffset(app);
    const requested = if (toward_older) current +| 1 else current -| 1;
    const candidate = candidateAtReverseOffset(app, requested) orelse return;
    selectCandidate(app, candidate);
    app_render_runtime.Runtime(@TypeOf(app.*)).requestActiveSurfaceFrame(app, .modal);
}

pub fn cancel(app: anytype) !void {
    if (!app.chat_rewind.active) return;
    app.chat_rewind.reset();
    app.shell.setRewindSelectedEntry(null);
    try app_lifecycle.closeFullTranscript(
        app.alloc,
        &app.terminal,
        &app.shell,
        &app.metrics,
    );
}

pub fn enter(app: anytype) !void {
    if (!app.chat_rewind.active) return;
    if (!app.chat_rewind.confirming) {
        app.chat_rewind.confirming = true;
        app_render_runtime.Runtime(@TypeOf(app.*)).requestActiveSurfaceFrame(app, .modal);
        return;
    }

    const history_index = app.chat_rewind.history_index;
    const prompt = try app.chatRewindPromptCopy(history_index);
    defer app.alloc.free(prompt);
    app.chat_rewind.reset();
    app.shell.setRewindSelectedEntry(null);
    try app_lifecycle.closeFullTranscript(
        app.alloc,
        &app.terminal,
        &app.shell,
        &app.metrics,
    );
    try app.commitChatRewind(history_index);
    app.input_runtime.inputResetState().clearCurrent(app.alloc);
    try app.input_runtime.edit_state.setText(app.alloc, prompt);
    app.shell.render_requests.request(.footer);
}
