//! One conversation's own state. The app that shows an agent owns the screen,
//! the terminal, and every shared service; an agent holds none of them.

const std = @import("std");
const types = @import("../shared/types.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const change_tracker = @import("../workspace/change_tracker.zig");
const context_contract = @import("../workspace/context_contract.zig");
const diff = @import("../output/diff.zig");
const approval_prompt = @import("../permissions/approval_prompt.zig");
const question_prompt = @import("../agent/question_prompt.zig");
const input_submit_runtime = @import("../app/input_submit_runtime.zig");
const session_runtime = @import("../session/session.zig");
const app_session_runtime = @import("../app/app_session_runtime.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const child_run_mod = @import("child_run.zig");
const profiles = @import("../profiles/profiles.zig");
const tool_set = @import("../tooling/tool_set.zig");

/// How many history turns an agent's session keeps in memory.
pub const max_history_turns: usize = 8;

/// What an agent is to its host: a top-level fx instance, or a subagent an
/// instance or another subagent started.
pub const Role = enum { instance, subagent };

pub const Agent = struct {
    /// The app that owns this agent, opaque because this folder never
    /// imports the app. Set when the app creates the agent; null for the
    /// first instance, which the app finds as its `main_agent` field.
    app: ?*anyopaque = null,
    session: session_runtime.SessionRuntime = session_runtime.SessionRuntime.init(max_history_turns),
    session_persistence: app_session_runtime.Persistence = .{},
    worker_thread: ?std.Thread = null,
    worker: worker_runtime.WorkerRuntime = .{},
    stream: types.StreamState = .{},
    approval_prompt: approval_prompt.ApprovalPrompt = .{},
    question_prompt: question_prompt.QuestionPrompt = .{},
    /// The work id the next prompt queued for this agent carries: main's
    /// message to a subagent, so its saved turn can be found. Set only
    /// while that prompt is queued. Borrowed.
    prompt_work_id: ?[]const u8 = null,
    /// This agent's own permission mode. An instance's is always set: at
    /// startup or launch, then from its screen. A subagent's is null
    /// until chosen on its screen. Written under the app's permission
    /// authority lock, which its readers on other threads take.
    permission_mode: ?types.PermissionMode = null,
    /// An instance's session approvals: what "always" allowed in its current
    /// session. A subagent records none; its go to the first
    /// instance's, as before instances. Each entry owns its strings,
    /// allocated with the app's allocator. Guarded by the app's permission
    /// authority lock.
    session_grants: std.ArrayList(types.PermissionGrant) = .empty,
    submission: input_submit_runtime.State = .{},
    pending_images: std.ArrayList(types.ImageAttachment) = .empty,
    next_image_id: usize = 1,
    managed_executions: managed_execution.Runtime = managed_execution.Runtime.init(std.heap.c_allocator),
    change_tracker: change_tracker.ChangeTracker = .{},
    context_snapshot: context_contract.GatheredContextSnapshot = .{},
    effort: types.ReasoningEffort = .auto,
    diff_entries: std.ArrayList(diff.DiffEntry) = .empty,
    next_diff_id: u32 = 1,
    /// Resolved display title for this agent's session. The agent owns these
    /// bytes; empty means no title has been derived or restored yet.
    session_title: std.ArrayList(u8) = .empty,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    total_web_search_requests: u64 = 0,
    /// A top-level instance, every one alike, or a subagent.
    role: Role = .instance,
    /// A subagent's current run, which sets its turns' model, effort, and
    /// authority. Null for an instance. Owned.
    child_run: ?child_run_mod.ChildRun = null,
    /// The profile this agent runs in, `main` until one is loaded.
    profile: profiles.Held = .{},
    /// fx's tools narrowed to `profile`, in its arena, or null for all of them.
    profile_tools: ?tool_set.ToolSet = null,
};
