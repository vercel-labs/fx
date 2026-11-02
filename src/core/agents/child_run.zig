//! A subagent's current run, carried by its agent: the admission that sets the
//! model, effort, and authority of its turns, and the parts of the message
//! those turns read. Main's agent never has one.

const std = @import("std");
const subagent_domain = @import("../subagent/domain.zig");
const subagent_authority = @import("../subagent/authority.zig");
const credentials = @import("../auth/credentials.zig");
const subagent_execution = @import("../subagent/execution.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const ChildRun = struct {
    /// The child's session id. Owned.
    child_id: []u8,
    /// The subagent's number in its parent, for lifecycle hooks.
    subagent_id: u64 = 0,
    /// The run's admission: model, provider, effort, permission mode, rules,
    /// grants, tools, and integrations. Owned.
    admission: subagent_domain.AdmissionSnapshot,
    /// Resolves the child's live tool authority on every tool call. Borrowed
    /// from the subagent host, which outlives every child agent.
    authority_resolver: *subagent_authority.Resolver,
    /// The system prompt with the run's `<subagent_instructions>` overlay, or
    /// empty to use the app's own. Owned.
    system_prompt: []u8 = &.{},
    /// The credential for the admission's provider when main's credential
    /// does not authorize it. Prepared off the main loop before the run is
    /// handed over. Owned.
    credential: ?credentials.Credential = null,
    /// The root user's request, for the permission reviewer. Owned.
    root_user_intent_context: []u8 = &.{},
    root_user_messages: [][]u8 = &.{},
    root_user_evidence_complete: bool = false,
    /// The run's work id, stamped on its turn in the child's log, where the
    /// parent finds the answer. Owned.
    work_id: []u8 = &.{},
    /// The slot thread's turn context while the run is in flight: it commits
    /// the finished turn and routes approvals to main's approval registry.
    /// Borrowed until `finish`.
    turn: ?*subagent_execution.TurnContext = null,
    /// Where the slot thread waits for the run to end. Borrowed until `finish`.
    completion: ?*Completion = null,
    /// The provider's last terminal error in this run, reported to the parent
    /// when the run fails.
    failure: ?types.ModelFailureDiagnostic = null,
    /// How the run's turn ended, when that is known before the turn is
    /// saved. The run ends once nothing of the turn is left to save.
    ended_as: ?types.TurnPresentationOutcome = null,
    /// Its turn was interrupted only to hand off to the user's image or
    /// `$skill`, so the work ends done rather than cancelled.
    handed_off: bool = false,
    /// The work a turn the parent didn't start opened in the parent's log,
    /// until that turn ends: the user's, or one the child's own child's
    /// report woke. Never `work_id`, which only the parent's works fill.
    /// Owned.
    turn_work_id: []u8 = &.{},

    /// True while the run's turn is in flight on the child agent.
    pub fn inFlight(self: *const ChildRun) bool {
        return self.completion != null;
    }

    /// Ends the run in flight and releases its slot thread. Neither borrowed
    /// pointer is used after this.
    /// Whether the parent agent started this run, as work it waits on, rather
    /// than the user from the subagent's own screen. Its turns are the
    /// parent's subagent turns: steering in them is the parent's feedback,
    /// never new user authority.
    pub fn startedByParent(self: *const ChildRun) bool {
        return self.work_id.len > 0;
    }

    pub fn finish(self: *ChildRun, outcome: Completion.Outcome) void {
        const completion = self.completion orelse return;
        self.turn = null;
        self.completion = null;
        completion.finish(outcome);
    }

    pub fn deinit(self: *ChildRun, alloc: Allocator) void {
        self.finish(.cancelled);
        alloc.free(self.child_id);
        alloc.free(self.work_id);
        alloc.free(self.turn_work_id);
        self.admission.deinit(alloc);
        alloc.free(self.system_prompt);
        if (self.credential) |*credential| credential.deinit(alloc);
        alloc.free(self.root_user_intent_context);
        for (self.root_user_messages) |message| alloc.free(message);
        alloc.free(self.root_user_messages);
        self.* = undefined;
    }
};

/// How a run handed to a child agent ended. The main loop writes it once; the
/// slot thread that handed the run over polls it.
pub const Completion = struct {
    mutex: std.Io.Mutex = .init,
    outcome: ?Outcome = null,
    /// Set with the outcome, so the slot thread waits without polling.
    done: std.Io.Event = .unset,

    pub const Outcome = enum { completed, failed, cancelled };

    /// Sets the outcome under the lock: the slot thread reads it under the
    /// same lock and may free this once it has, so nothing here outlives it.
    pub fn finish(self: *Completion, outcome: Outcome) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.outcome == null) self.outcome = outcome;
        self.done.set(io_mod.getIo());
    }

    pub fn result(self: *Completion) ?Outcome {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.outcome;
    }
};

fn testRun(alloc: Allocator, completion: *Completion) !ChildRun {
    return .{
        .child_id = try alloc.dupe(u8, "child"),
        .admission = try subagent_domain.captureAdmission(alloc, .{
            .parent_id = "parent",
            .source_id = "parent",
            .model = "test-model",
            .effort = .auto,
        }),
        .authority_resolver = undefined,
        .completion = completion,
    };
}

test "ending a child's run releases its slot thread once, with the first outcome" {
    const alloc = std.testing.allocator;
    var completion: Completion = .{};
    var run = try testRun(alloc, &completion);
    defer run.deinit(alloc);
    try std.testing.expect(run.inFlight());
    try std.testing.expectEqual(@as(?Completion.Outcome, null), completion.result());

    run.finish(.completed);
    try std.testing.expect(!run.inFlight());
    try std.testing.expectEqual(@as(?Completion.Outcome, .completed), completion.result());
    // A later end, such as shutdown freeing the run, changes nothing.
    run.finish(.failed);
    completion.finish(.cancelled);
    try std.testing.expectEqual(@as(?Completion.Outcome, .completed), completion.result());
}

test "freeing a child's run still in flight ends it as cancelled" {
    const alloc = std.testing.allocator;
    var completion: Completion = .{};
    var run = try testRun(alloc, &completion);
    run.deinit(alloc);
    try std.testing.expectEqual(@as(?Completion.Outcome, .cancelled), completion.result());
}
