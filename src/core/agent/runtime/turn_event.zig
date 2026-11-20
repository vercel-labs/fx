//! What the agent loop tells a front end about a running turn: one event
//! type for every front end (the TUI, `fx acp`, `fx ask`, and subagents),
//! sent through `AgentRuntimeDeps.emit`.
//!
//! An event is lent. Its payload is valid only during the `emit` call, and
//! the loop frees what it allocated once `emit` returns. A front end copies
//! what it keeps, as the TUI's queue does with `dupeWorkerEvent`.
//!
//! A front end gets the events in the order the loop emits them, so text and
//! tool lifecycle stay ordered relative to each other
//! (`tests/tla/agent_runtime/TurnEvents.tla` InOrder).
const std = @import("std");
const types = @import("../../shared/types.zig");
const worker_runtime = @import("../worker_runtime.zig");

/// Ordered text emitted by the agent runtime.
pub const TextEmission = union(enum) {
    assistant_started,
    assistant_source: []const u8,
    assistant_rendered: []const u8,
    assistant_restarted: []const u8,
    operational: []const u8,
};

/// A notice, with the plain text a front end that doesn't show semantic
/// notices shows in its place.
pub const Notice = struct {
    /// The notice for a front end that shows semantic notices, as the TUI
    /// does.
    semantic: ?types.SemanticNotice = null,
    /// The text for a front end that doesn't. Null: such a front end shows
    /// nothing.
    plain: ?[]const u8 = null,
};

/// A model request that failed with an HTTP status.
pub const HttpError = struct {
    status: std.http.Status,
    detail: []const u8,
    credential_source: ?types.CredentialSource,
};

pub const TurnEvent = union(enum) {
    /// One of the kinds the TUI's worker queue holds. The loop emits turn
    /// phase and token updates, model calls, the provider that served a
    /// request, route recovery status and its clearing, tool lifecycle, diff
    /// blocks, the end of a command's output, session grants, user feedback,
    /// the model picker, and the finished prompt. The TUI's other kinds,
    /// such as `begin_prompt`, come from the TUI itself.
    worker: worker_runtime.WorkerEvent,
    /// Assistant text, and fx's own operational lines.
    text: TextEmission,
    /// A chunk of the model's reasoning. A front end that doesn't show
    /// reasoning drops it.
    reasoning_delta: []const u8,
    notice: Notice,
    /// A source-limit notice, which a front end with a session drops when it
    /// has shown the same text already. One without shows it as a plain
    /// notice.
    context_notice: []const u8,
    /// A notice the person should see once in a live session, however many
    /// turns repeat its cause. A front end with no session to remember it in
    /// drops it.
    session_notice: []const u8,
    http_error: HttpError,
};
