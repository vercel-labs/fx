//! What the detached frontend shows of its session: it applies supervisor
//! snapshots, live frames, child transcripts, browser rows, and host command
//! results to the transcript, footer, and permission prompt. It never sends
//! anything; `remote_backend.zig` does, over `app_remote_runtime.zig`.
const std = @import("std");
const client_protocol = @import("../supervisor/protocol.zig");
const host_commands = @import("../../acp/commands.zig");
const io_mod = @import("../shared/io.zig");
const browser_mod = @import("../input/session_browser.zig");
const types = @import("../shared/types.zig");
const text_utils = @import("../shared/text_utils.zig");
const presentation = @import("../agent/assistant_presentation.zig");
const callbacks = @import("app_callbacks.zig");
const sessions = @import("app_session_runtime.zig");
const session_catalog = @import("../session/session_catalog.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const diff = @import("../output/diff.zig");
const remote_runtime = @import("app_remote_runtime.zig");
const remote_backend = @import("remote_backend.zig");
const Allocator = std.mem.Allocator;
const field = remote_runtime.field;
const string = remote_runtime.string;
const integer = remote_runtime.integer;
const boolean = remote_runtime.boolean;
const itemsOf = remote_runtime.itemsOf;
pub const SnapshotView = client_protocol.Snapshot([]const types.HistoryTurn, std.json.Value);

pub fn Runtime(comptime App: type) type {
    return struct {
        const Backend = remote_backend.Runtime(App);
        const Transport = remote_runtime.Runtime(App);

        pub fn notice(app: *App, topic: []const u8, body: []const u8) !void {
            try app.writeDomainNotice(.{ .topic = topic, .tone = .neutral, .body = body }, true);
        }

        /// Renders the result of a forwarded `fx/command`. The host owns the
        /// effect and its data; the frontend owns how it reads on screen.
        fn applyCommandResult(app: *App, result: host_commands.Response) !void {
            switch (result.command) {
                .last_reply => try applyLastReply(app, result.text orelse ""),
                .compact => if (result.compaction) |outcome| try notice(app, "session", switch (outcome) {
                    .compacted => "Context compacted.",
                    .nothing_to_compact => "No context to compact.",
                }),
                .undo => if (result.outcome) |outcome| try applyUndo(app, outcome, result.path orelse ""),
                .context => try applyContext(app, result),
                .mcp_verb, .mcp_status => try notice(app, "mcp", result.text orelse ""),
                .workspace => try notice(app, "workspace", result.text orelse ""),
                .permissions_reload => try notice(app, "permissions", "Session permissions reloaded."),
                .shell_reload => try notice(app, "shell", "The next command reloads your shell startup files. Remembered command approvals were reset."),
            }
        }

        fn applyLastReply(app: *App, text: []const u8) !void {
            if (text.len == 0) {
                try notice(app, "clipboard", "No assistant reply to copy.");
                return;
            }
            if (!copyToClipboard(app, text)) {
                try notice(app, "clipboard", "Failed to copy to clipboard.");
                return;
            }
            try notice(app, "clipboard", "Copied to clipboard.");
        }

        fn applyContext(app: *App, result: host_commands.Response) !void {
            const used = result.used orelse 0;
            const percent = result.auto_compact_percent orelse 0;
            var buf: [192]u8 = undefined;
            const body = if (result.total) |total|
                try std.mem.print(&buf, "context: {d} / {d} tokens ({d}%) · auto-compact at {d}%", .{
                    used,
                    total,
                    if (total > 0) @divTrunc(used * 100, total) else 0,
                    percent,
                })
            else
                try std.mem.print(&buf, "context: {d} tokens · auto-compact at {d}%", .{ used, percent });
            try notice(app, "context", body);
        }

        /// The host reports what happened to the file; the frontend renders the
        /// path safely, because a repository can name a file with control bytes.
        fn applyUndo(app: *App, outcome: host_commands.UndoOutcome, path: []const u8) !void {
            if (outcome == .nothing_to_undo) {
                try notice(app, "undo", "Nothing to undo.");
                return;
            }
            var safe = try text_utils.encodeTerminalSafe(app.alloc, path, std.Io.Dir.max_path_bytes);
            defer safe.deinit(app.alloc);
            const body = switch (outcome) {
                .restored => try app.alloc.print("Restored {s}", .{safe.bytes}),
                .deleted => try app.alloc.print("Deleted {s} (was newly created)", .{safe.bytes}),
                .unavailable, .nothing_to_undo => try app.alloc.print("Could not undo {s}", .{safe.bytes}),
            };
            defer app.alloc.free(body);
            try notice(app, "undo", body);
        }

        pub fn showHeartbeat(app: *App, heartbeat: client_protocol.Heartbeat) !void {
            const body = if (heartbeat.interval_ms == 0)
                try app.alloc.dupe(u8, "No heartbeat configured.")
            else
                try app.alloc.print("{s} · every {d}s · {s}", .{ if (heartbeat.paused) "Paused" else "Running", @divTrunc(heartbeat.interval_ms, 1000), heartbeat.prompt });
            defer app.alloc.free(body);
            try notice(app, "heartbeat", body);
        }

        pub fn showKernel(app: *App, kernel: client_protocol.KernelInfo) !void {
            const body = try std.json.Stringify.valueAlloc(app.alloc, kernel, .{});
            defer app.alloc.free(body);
            try notice(app, "kernel", body);
        }

        /// Clears the shown transcript for another session or child view.
        pub fn resetTranscriptContents(app: *App) void {
            app.remote.native_source_turn_id = null;
            for (app.remote.submitted_text.items) |text| app.alloc.free(text);
            app.remote.submitted_text.clearRetainingCapacity();
            app.shell.clearTranscriptPreservingWelcome(app.alloc);
            app.stream = .{};
            _ = app.shell.worker_status_state().clear();
            app.shell.render_requests.request(.transcript);
        }

        /// Also drops the pending permission prompt of the view it leaves.
        pub fn resetTranscript(app: *App) void {
            resetTranscriptContents(app);
            app.approval_prompt.clear(app.alloc);
            app.remote.pending_permission_id = null;
            app.remote.permission_response_queued = false;
            app.shell.render_requests.request(.transcript);
        }

        pub fn applySessionRows(app: *App, sessions_listed: []const client_protocol.SessionSummary) !void {
            const browser = &app.input_runtime.session_browser;
            if (!browser.active or browser.scope != .sessions) return;
            var arena: std.heap.ArenaAllocator = .init(app.alloc);
            defer arena.deinit();
            const a = arena.allocator();
            const rows = try a.alloc(browser_mod.Row, sessions_listed.len);
            const now_ms = io_mod.milliTimestamp();
            for (sessions_listed, rows) |item, *row| {
                var age_buf: [32]u8 = undefined;
                const age = session_catalog.relativeActivityAgeCompact(&age_buf, item.updated_at_ms, now_ms);
                const named = item.name.len > 0 and !std.mem.eql(u8, item.name, "session");
                const short_id = if (item.id.len > 8) item.id[0..8] else item.id;
                const active = item.status == .running or item.status == .awaiting_approval;
                row.* = .{
                    .id = item.id,
                    .parent_id = "",
                    .title = if (named) item.name else try a.print("session {s}", .{short_id}),
                    .status = @tagName(item.status),
                    .detail = "",
                    .meta = try a.dupe(u8, if (active) @tagName(item.status) else age),
                    .depth = 0,
                    .current = std.mem.eql(u8, item.id, app.remote.current_id),
                };
            }
            try browser.replaceRows(app.alloc, rows);
        }

        pub fn applyChildRows(app: *App, children: []const client_protocol.Child) !void {
            const browser = &app.input_runtime.session_browser;
            if (!browser.active or browser.scope != .subagents) return;
            var arena: std.heap.ArenaAllocator = .init(app.alloc);
            defer arena.deinit();
            const rows = try arena.allocator().alloc(browser_mod.Row, children.len);
            for (children, rows) |item, *row| {
                row.* = .{
                    .id = item.id,
                    .parent_id = item.parent_id,
                    .title = if (item.name.len > 0) item.name else item.id,
                    .status = item.status,
                    .detail = item.detail,
                    .meta = item.status,
                    .depth = item.depth,
                    .current = std.mem.eql(u8, item.id, app.remote.current_id),
                };
            }
            try browser.replaceRows(app.alloc, rows);
        }

        pub fn applyChildSnapshot(app: *App, value: client_protocol.ChildHistory(std.json.Value)) !void {
            const remote = &app.remote;
            if (remote.child_id.len == 0 or !std.mem.eql(u8, remote.child_id, value.child_id)) return;
            const live_active = value.live_active;
            const reset = value.live_reset or remote.child_history_count == null or
                !std.mem.eql(u8, value.work_id, remote.child_work_id) or value.live_sequence < remote.child_sequence or
                live_active != remote.child_live_active;
            if (reset) {
                const history = value.history orelse {
                    // Ask for a complete baseline rather than joining unrelated tails.
                    remote.child_history_count = null;
                    return Transport.refreshChild(app);
                };
                const owned_work = try app.alloc.dupe(u8, value.work_id);
                errdefer app.alloc.free(owned_work);
                const active_prompt = value.active_prompt orelse "";
                const owned_prompt = try app.alloc.dupe(u8, active_prompt);
                errdefer app.alloc.free(owned_prompt);
                resetTranscriptContents(app);
                try sessions.Runtime(App).replayRemoteHistory(app, history);
                remote.native_turn_offset = app.shell.finalizedToolTurnWatermark() + 1;
                const outcome = if (live_active) value.status else value.last_outcome orelse value.status;
                const body = try app.alloc.print("{s} · {s} · read-only child transcript · left returns to parent", .{ value.name, outcome });
                defer app.alloc.free(body);
                try notice(app, "subagent", body);
                if (!live_active) if (value.last_failure) |failure| try notice(app, "subagent", failure);
                if (live_active and active_prompt.len > 0) try app.writeUserPromptCard(.{ .text = @constCast(active_prompt) });
                if (value.oldest_live_sequence > 1) {
                    try notice(app, "subagent", "Earlier live output exceeded the preview buffer. The complete transcript will load when this work finishes.");
                }
                if (remote.child_work_id.len > 0) app.alloc.free(remote.child_work_id);
                remote.child_work_id = owned_work;
                if (remote.child_prompt.len > 0) app.alloc.free(remote.child_prompt);
                remote.child_prompt = owned_prompt;
                remote.child_history_count = history.len;
                remote.child_sequence = 0;
                if (live_active) app.stream.turn_started_ms = io_mod.milliTimestamp();
            }
            const status = value.status;
            remote.child_status_len = @min(status.len, remote.child_status.len);
            @memcpy(remote.child_status[0..remote.child_status_len], status[0..remote.child_status_len]);
            remote.child_live_active = live_active;
            app.stream.active = childIsRunning(app);
            if (std.mem.eql(u8, status, "awaiting_approval")) {
                if (app.stream.waiting_since_ms == 0) app.stream.waiting_since_ms = io_mod.milliTimestamp();
            } else if (app.stream.waiting_since_ms != 0) {
                app.stream.turn_started_ms += io_mod.milliTimestamp() - app.stream.waiting_since_ms;
                app.stream.waiting_since_ms = 0;
            }
            const live_events = itemsOf(value.live_events);
            for (live_events) |entry| {
                const event_sequence: u64 = @intCast(@max(0, integer(entry, "sequence") orelse 0));
                if (event_sequence <= remote.child_sequence) continue;
                if (string(entry, "text")) |text| {
                    _ = try app.shell.streamAssistantChunk(app.alloc, &app.metrics, text);
                    app.stream.phase = .generating;
                } else if (field(entry, "event")) |event| {
                    try applyNativeEvent(app, event);
                }
                remote.child_sequence = event_sequence;
            }
            remote.child_sequence = @max(remote.child_sequence, value.live_sequence);
            try callbacks.Bindings(App).worker_tool_lifecycle_presenter(app).finish_batch(app.alloc);
            if (reset or live_events.len > 0) app.shell.render_requests.request(.transcript);
        }

        fn nativeLifecycleId(app: *App, id: types.ToolLifecycleId) !types.ToolLifecycleId {
            return .{ .turn_id = std.math.add(u64, app.remote.native_turn_offset, id.turn_id) catch return error.InvalidNativeTurnId, .call_id = id.call_id };
        }

        fn beginNativeTurn(app: *App, source_turn_id: u64) void {
            if (app.remote.native_source_turn_id == source_turn_id) return;
            app.remote.native_source_turn_id = source_turn_id;
            app.stream = .{ .active = true, .turn_started_ms = io_mod.milliTimestamp() };
            _ = app.shell.worker_status_state().clear();
            app.shell.render_requests.requestAnimationReset();
            app.shell.render_requests.request(.footer);
        }

        /// A host sends a tool's status as plain text; the transcript marks
        /// its status rows, as the local terminal's own tool labels are.
        fn withStatusMarker(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
            if (text.len == 0) return text;
            return std.mem.concat(arena, u8, &.{ "● ", text });
        }

        /// Native root and child frames share fx's owned presentation reducer.
        /// The offset is fixed for the displayed history baseline: user echoes
        /// (including steering) must not change an in-flight tool's identity.
        fn applyNativeEvent(app: *App, event: std.json.Value) !void {
            if (field(event, "tool_lifecycle")) |value| {
                var parsed = try std.json.parseFromValue(types.ToolLifecycleEvent, app.alloc, value, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();
                var lifecycle = parsed.value;
                switch (lifecycle) {
                    .provisional => |*started| {
                        beginNativeTurn(app, started.id.turn_id);
                        started.id = try nativeLifecycleId(app, started.id);
                        if (started.presentation_group_id) |*group| group.turn_id = started.id.turn_id;
                    },
                    .authoritative_started => |*started| {
                        beginNativeTurn(app, started.id.turn_id);
                        started.id = try nativeLifecycleId(app, started.id);
                        if (started.presentation_group_id) |*group| group.turn_id = started.id.turn_id;
                    },
                    .progress => |*progress| {
                        progress.id = try nativeLifecycleId(app, progress.id);
                        if (app.shell.toolActivityRecord(progress.id) == null) return;
                        progress.text = try withStatusMarker(parsed.arena.allocator(), progress.text);
                    },
                    .terminal => |*terminal| {
                        terminal.id = try nativeLifecycleId(app, terminal.id);
                        if (app.shell.toolActivityRecord(terminal.id) == null) return;
                        terminal.outcome.summary = try withStatusMarker(parsed.arena.allocator(), terminal.outcome.summary);
                    },
                    .turn_finished => |*finished| finished.turn_id = (try nativeLifecycleId(app, .{ .turn_id = finished.turn_id, .call_id = "" })).turn_id,
                }
                const transition = try callbacks.Bindings(App).worker_tool_lifecycle_presenter(app).apply(app.alloc, lifecycle);
                if (transition.applied_activity_kind) |kind| {
                    app.stream.chunks += 1;
                    switch (kind) {
                        .read => app.stream.read_count += 1,
                        .write => app.stream.write_count += 1,
                        .edit => app.stream.edit_count += 1,
                        .open => app.stream.open_count += 1,
                        .command => app.stream.command_count += 1,
                        .subagent => app.stream.subagent_count += 1,
                        .ask => {},
                    }
                }
                switch (lifecycle) {
                    .provisional, .authoritative_started, .progress => app.stream.phase = .running,
                    .terminal => {},
                    .turn_finished => app.stream.active = false,
                }
                app.stream.last_activity_kind = transition.snapshot.focused_activity_kind;
                if (transition.focus_changed()) app.shell.render_requests.requestAnimationReset();
            } else if (field(event, "command_output")) |value| {
                var parsed = try std.json.parseFromValue(worker_runtime.CommandOutputChunk, app.alloc, value, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();
                const id = if (parsed.value.lifecycle_id) |source| try nativeLifecycleId(app, source) else null;
                if (id) |identity| if (app.shell.toolActivityRecord(identity) == null) return;
                try app.writeCommandOutputChunkForLifecycle(id, parsed.value.stream, parsed.value.text, true);
            } else if (field(event, "command_output_complete")) |value| {
                var parsed = try std.json.parseFromValue(?types.ToolLifecycleId, app.alloc, value, .{});
                defer parsed.deinit();
                const id = if (parsed.value) |source| try nativeLifecycleId(app, source) else null;
                if (id) |identity| if (app.shell.toolActivityRecord(identity) == null) return;
                try app.flushCommandOutputSummaryForLifecycle(id, true);
            } else if (field(event, "turn_phase_update")) |value| {
                var parsed = try std.json.parseFromValue(types.TurnPhaseUpdate, app.alloc, value, .{});
                defer parsed.deinit();
                beginNativeTurn(app, parsed.value.turn_id);
                if (parsed.value.step_id >= app.stream.phase_step_id) {
                    app.stream.phase = parsed.value.phase;
                    app.stream.phase_step_id = parsed.value.step_id;
                }
            } else if (field(event, "turn_token_update")) |value| {
                var parsed = try std.json.parseFromValue(types.TurnTokenProgress, app.alloc, value, .{});
                defer parsed.deinit();
                app.stream.token_progress = parsed.value;
            } else if (field(event, "assistant_presentation")) |value| {
                var parsed = try std.json.parseFromValue(presentation.Event, app.alloc, value, .{});
                defer parsed.deinit();
                switch (parsed.value) {
                    .text => |text| _ = try app.shell.streamAssistantChunk(app.alloc, &app.metrics, text),
                    .table => |table| {
                        var owned = try table.clone(app.alloc);
                        errdefer owned.deinit(app.alloc);
                        try app.appendAssistantTable(owned);
                    },
                    .code_block => |block| {
                        var owned = try block.clone(app.alloc);
                        errdefer owned.deinit(app.alloc);
                        try app.appendAssistantCodeBlock(owned);
                    },
                    .thematic_rule => try app.appendAssistantThematicRule(),
                }
            } else if (field(event, "diff_block")) |value| {
                var parsed = try std.json.parseFromValue(diff.DiffEntryPayload, app.alloc, value, .{});
                defer parsed.deinit();
                const owned = try worker_runtime.dupeWorkerEvent(std.heap.c_allocator, .{ .diff_block = parsed.value });
                try app.registerAndEmitDiffBlock(owned.diff_block);
            } else if (field(event, "append_user_feedback")) |value| {
                if (value == .string) try app.writeUserPromptCard(.{ .text = @constCast(value.string) });
            } else if (field(event, "semantic_notice") orelse field(event, "error_text")) |value| {
                var parsed = try std.json.parseFromValue(types.SemanticNotice, app.alloc, value, .{});
                defer parsed.deinit();
                try app.writeDomainNotice(parsed.value, true);
            } else if (field(event, "route_recovery_status")) |value| {
                var parsed = try std.json.parseFromValue(types.RouteRecoveryStatus, app.alloc, value, .{});
                defer parsed.deinit();
                app.shell.worker_status_state().set_route_recovery(parsed.value, io_mod.milliTimestamp());
            } else if (field(event, "clear_route_recovery_status") != null) {
                _ = app.shell.worker_status_state().clear_route_recovery();
            }
        }

        pub fn applySnapshot(app: *App, value: SnapshotView) !void {
            const remote = &app.remote;
            const changed = if (remote.incarnation.len > 0) !std.mem.eql(u8, remote.incarnation, value.incarnation) else remote.sequence > 0;
            if (remote.incarnation.len == 0 or changed) {
                const owned = try app.alloc.dupe(u8, value.incarnation);
                if (remote.incarnation.len > 0) app.alloc.free(remote.incarnation);
                remote.incarnation = owned;
            }
            if (changed) {
                // Never replay a command after a connection's execution owner changes.
                remote.dropQueued();
                try Backend.switchSession(app, value.session_id);
                remote.reconnect_notice = true;
                return;
            }
            if (remote.current_id.len == 0) remote.current_id = try app.alloc.dupe(u8, value.session_id);
            if (value.history) |history| {
                resetTranscript(app);
                try sessions.Runtime(App).replayRemoteHistory(app, history);
                remote.native_turn_offset = app.shell.finalizedToolTurnWatermark() + 1;
                remote.sequence = value.history_sequence orelse 0;
            }
            const summary = value.session;
            if (!std.mem.eql(u8, summary.cwd, remote.cwd)) {
                const owned = try app.alloc.dupe(u8, summary.cwd);
                errdefer app.alloc.free(owned);
                const label = try text_utils.encodeTerminalSafeInline(app.alloc, std.Io.Dir.path.basename(summary.cwd), 128);
                if (remote.cwd.len > 0) app.alloc.free(remote.cwd);
                if (remote.workspace_label.len > 0) app.alloc.free(remote.workspace_label);
                remote.cwd = owned;
                remote.workspace_label = label.bytes;
            }
            if (!std.mem.eql(u8, summary.name, app.session_title.items)) {
                try sessions.Runtime(App).setCachedSessionTitle(app, summary.name);
            }
            if (!std.mem.eql(u8, summary.model, remote.model)) {
                const owned = try app.alloc.dupe(u8, summary.model);
                if (remote.model.len > 0) app.alloc.free(remote.model);
                remote.model = owned;
            }
            remote.permission_mode = types.PermissionMode.parse(summary.mode) orelse remote.permission_mode;
            // The inactive local engine mirrors the attached projection for settings panels.
            app.permission_engine.mode = remote.permission_mode;
            const running = summary.status == .running or summary.status == .awaiting_approval;
            for (value.events) |event| {
                if (event.sequence <= remote.sequence) continue;
                if (remote.child_id.len == 0) try applyFrame(app, event.frame);
                remote.sequence = event.sequence;
            }
            if (remote.child_id.len == 0) {
                try callbacks.Bindings(App).worker_tool_lifecycle_presenter(app).finish_batch(app.alloc);
                if (summary.status == .awaiting_approval) {
                    if (app.stream.waiting_since_ms == 0) app.stream.waiting_since_ms = io_mod.milliTimestamp();
                } else if (app.stream.waiting_since_ms != 0) {
                    app.stream.turn_started_ms += io_mod.milliTimestamp() - app.stream.waiting_since_ms;
                    app.stream.waiting_since_ms = 0;
                }
            }
            const submission_queued = remote.submissionQueued();
            app.stream.active = if (remote.child_id.len > 0) childIsRunning(app) else running or submission_queued;
            if (remote.reconnect_notice) {
                remote.reconnect_notice = false;
                try notice(app, "session", "Supervisor restarted; restored this session. Unsent requests were not replayed.");
            }
            if (!remote.permission_response_queued) {
                if (value.pending.len == 0) {
                    remote.pending_permission_id = null;
                    app.approval_prompt.clear(app.alloc);
                } else for (value.pending) |frame| {
                    if (std.mem.eql(u8, string(frame, "method") orelse "", "session/request_permission")) {
                        try showPermission(app, frame);
                        break;
                    }
                }
            }
        }

        fn childIsRunning(app: *App) bool {
            const status = app.remote.child_status[0..app.remote.child_status_len];
            return app.remote.child_live_active or std.mem.eql(u8, status, "running") or std.mem.eql(u8, status, "awaiting_approval");
        }

        fn applyFrame(app: *App, frame: std.json.Value) !void {
            const method = string(frame, "method") orelse return;
            if (std.mem.eql(u8, method, client_protocol.replay_gap_method)) {
                try notice(app, "session", "Some live output exceeded the replay buffer. Reopen this session after its turn finishes to load the complete saved transcript.");
                return;
            }
            if (std.mem.eql(u8, method, "fx/mcp_notice")) {
                const params = field(frame, "params") orelse return;
                if (string(params, "session_id")) |id| if (!std.mem.eql(u8, id, app.remote.current_id)) return;
                const text = string(params, "text") orelse return;
                try app.writeDomainNotice(.{
                    .topic = "mcp",
                    .tone = if (boolean(params, "warning")) .warning else .neutral,
                    .body = text,
                }, true);
                app.shell.render_requests.request(.footer);
                return;
            }
            if (std.mem.eql(u8, method, client_protocol.command_result_method)) {
                const params = field(frame, "params") orelse return;
                var result = try std.json.parseFromValue(client_protocol.CommandResult(host_commands.Response), app.alloc, params, .{ .ignore_unknown_fields = true });
                defer result.deinit();
                if (!result.value.ok) {
                    const message = result.value.@"error" orelse "The session command failed";
                    try app.writeDomainNotice(.{ .topic = "session", .tone = .@"error", .body = message }, true);
                } else if (result.value.result) |payload| {
                    try applyCommandResult(app, payload);
                }
                app.shell.render_requests.request(.footer);
                return;
            }
            if (std.mem.eql(u8, method, "proto/native_presentation")) {
                const params = field(frame, "params") orelse return;
                if (string(params, "session_id")) |id| if (!std.mem.eql(u8, id, app.remote.current_id)) return;
                if (string(params, "text")) |text| {
                    _ = try app.shell.streamAssistantChunk(app.alloc, &app.metrics, text);
                    app.stream.phase = .generating;
                } else if (field(params, "event")) |event| {
                    try applyNativeEvent(app, event);
                }
                app.shell.render_requests.request(.transcript);
                app.shell.render_requests.request(.footer);
                return;
            }
            // The host's own session updates still carry the user prompts it
            // ran (heartbeats, other clients, steering) and its notices.
            if (!std.mem.eql(u8, method, "session/update")) return;
            const params = field(frame, "params") orelse return;
            const update = field(params, "update") orelse return;
            const kind = string(update, "sessionUpdate") orelse return;
            if (std.mem.eql(u8, kind, "user_message_chunk")) {
                const content = field(update, "content") orelse return;
                const text = string(content, "text") orelse return;
                // This frontend already showed the prompts it sent.
                for (app.remote.submitted_text.items, 0..) |own, i| if (std.mem.eql(u8, own, text)) {
                    app.alloc.free(app.remote.submitted_text.orderedRemove(i));
                    return;
                };
                try app.writeUserPromptCard(.{ .text = @constCast(text) });
            } else if (std.mem.eql(u8, kind, "notice")) {
                try app.writeDomainNotice(.{ .topic = "session", .tone = .neutral, .body = string(update, "title") orelse "" }, true);
            }
        }

        pub fn showPermission(app: *App, frame: std.json.Value) !void {
            const id: u64 = @intCast(integer(frame, "id") orelse return);
            if (app.approval_prompt.request) |request| if (request.id == id) return;
            app.remote.pending_permission_id = @intCast(id);
            const params = field(frame, "params") orelse return;
            const tool = field(params, "toolCall") orelse return;
            var label: std.Io.Writer.Allocating = .init(app.alloc);
            defer label.deinit();
            try label.writer.writeAll(string(tool, "title") orelse "Tool needs permission");
            if (field(tool, "rawInput")) |arguments| {
                try label.writer.writeAll(" · ");
                try std.json.Stringify.value(arguments, .{}, &label.writer);
            }
            _ = try app.approval_prompt.syncRequest(app.alloc, .{ .id = id, .label = label.written(), .amendment_allowed = false });
            app.shell.render_requests.request(.modal);
        }
    };
}

/// Test hosts and embedders need not offer a clipboard; production hosts do.
fn copyToClipboard(app: anytype, text: []const u8) bool {
    const Host = @TypeOf(app.*);
    return if (comptime @hasDecl(Host, "clipboard"))
        app.clipboard().copy(text) catch false
    else
        false;
}

const NativePresentationTestApp = struct {
    alloc: Allocator = std.testing.allocator,
    remote: remote_runtime.State = .{ .native_turn_offset = 100 },
    stream: types.StreamState = .{ .active = true },
    user_prompt_count: usize = 0,
    reject_semantic: bool = false,
    metrics: types.Metrics = .{},
    shell: @import("../../ui/transcript/runtime.zig").TranscriptRuntime = .{},

    pub fn writeCommandOutputChunkForLifecycle(self: *@This(), id: ?types.ToolLifecycleId, stream: @import("../tooling/command_output_content.zig").Stream, text: []const u8, record: bool) !void {
        try self.shell.writeCommandOutputChunkForLifecycle(self.alloc, &self.metrics, .{}, id, stream, text, record);
    }
    pub fn flushCommandOutputSummaryForLifecycle(self: *@This(), id: ?types.ToolLifecycleId, record: bool) !void {
        try self.shell.flushCommandOutputSummaryForLifecycle(self.alloc, &self.metrics, .{}, id, record);
    }
    pub fn appendAssistantTable(self: *@This(), table: presentation.TablePayload) !void {
        if (self.reject_semantic) return error.TestAppendRejected;
        _ = try self.shell.appendAssistantTableOwned(self.alloc, table);
    }
    pub fn appendAssistantCodeBlock(self: *@This(), block: presentation.CodeBlockPayload) !void {
        if (self.reject_semantic) return error.TestAppendRejected;
        _ = try self.shell.appendAssistantCodeBlockOwned(self.alloc, block);
    }
    pub fn appendAssistantThematicRule(self: *@This()) !void {
        _ = try self.shell.appendAssistantThematicRule(self.alloc);
    }
    pub fn registerAndEmitDiffBlock(_: *@This(), payload: diff.DiffEntryPayload) !void {
        diff.freeDiffEntryPayload(std.heap.c_allocator, payload);
    }
    pub fn writeUserPromptCard(self: *@This(), _: types.UserTurn) !void {
        self.user_prompt_count += 1;
    }
    pub fn writeDomainNotice(self: *@This(), value: types.SemanticNotice, record: bool) !void {
        try self.shell.writeNotice(self.alloc, &self.metrics, value, record);
    }
    fn apply(self: *@This(), json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, json, .{});
        defer parsed.deinit();
        try Runtime(@This()).applyNativeEvent(self, parsed.value);
    }
    fn statusText(self: *@This(), id: types.ToolLifecycleId) ![]const u8 {
        const record = self.shell.toolActivityRecord(id) orelse return error.TestExpectedTool;
        for (self.shell.entries.items) |entry| {
            if (entry == .raw_bytes and entry.raw_bytes.id == record.entry_id) return entry.raw_bytes.bytes;
        }
        return error.TestExpectedStatus;
    }

    fn frame(self: *@This(), json: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, json, .{});
        defer parsed.deinit();
        try Runtime(@This()).applyFrame(self, parsed.value);
    }
};

test "child live native events retain tool output and isolate view turn identities" {
    var app: NativePresentationTestApp = .{};
    defer app.shell.deinit(app.alloc);
    defer app.remote.deinit(app.alloc);
    try app.apply("{\"assistant_presentation\":{\"text\":\"child prose\\n\"}}");
    try app.apply("{\"tool_lifecycle\":{\"authoritative_started\":{\"id\":{\"turn_id\":1,\"call_id\":\"call\"},\"reconciles_provisional_call_id\":null,\"tool_name\":\"shell\",\"activity_kind\":\"command\",\"arguments_json\":\"{\\\"action\\\":\\\"run\\\",\\\"command\\\":\\\"printf child\\\"}\"}}}");
    const id: types.ToolLifecycleId = .{ .turn_id = 101, .call_id = "call" };
    try std.testing.expect(app.shell.toolActivityRecord(id) != null);
    try std.testing.expectEqual(types.TurnPhase.running, app.stream.phase);
    try app.apply("{\"command_output\":{\"lifecycle_id\":{\"turn_id\":1,\"call_id\":\"call\"},\"stream\":\"stdout\",\"text\":\"child stdout\\n\"}}");
    try app.apply("{\"command_output_complete\":{\"turn_id\":1,\"call_id\":\"call\"}}");
    try app.apply("{\"tool_lifecycle\":{\"terminal\":{\"id\":{\"turn_id\":1,\"call_id\":\"call\"},\"outcome\":{\"kind\":\"completed\",\"summary\":\"Ran printf child\"},\"result\":\"child stdout\\n\"}}}");
    try std.testing.expect(std.mem.find(u8, try app.statusText(id), "Ran printf child") != null);
    const record = app.shell.toolActivityRecord(id).?;
    const detail = app.shell.toolDetailForEntry(record.entry_id).?;
    try std.testing.expectEqualStrings("child stdout\n", detail.result.?);
    try std.testing.expect(detail.command_output_entry_id != null);
    try app.apply("{\"turn_phase_update\":{\"turn_id\":1,\"step_id\":2,\"phase\":\"generating\"}}");
    try std.testing.expectEqual(types.TurnPhase.generating, app.stream.phase);
    app.shell.clearTranscript(app.alloc);
    app.remote.native_turn_offset = 200;
    // A retained tail with no start must not recreate a tool from another view.
    try app.apply("{\"tool_lifecycle\":{\"terminal\":{\"id\":{\"turn_id\":1,\"call_id\":\"call\"},\"outcome\":{\"kind\":\"completed\",\"summary\":\"stale\"}}}}");
    try std.testing.expect(app.shell.toolActivityRecord(id) == null);
    try std.testing.expect(app.shell.toolActivityRecord(.{ .turn_id = 201, .call_id = "call" }) == null);
}

test "root native presentation preserves tool detail through steering and resets turn metrics" {
    var app: NativePresentationTestApp = .{};
    defer app.shell.deinit(app.alloc);
    defer app.remote.deinit(app.alloc);
    app.remote.current_id = try app.alloc.dupe(u8, "root");
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","text":"NATIVE_ONLY\n"}}
    );
    const native_text_bytes = app.shell.transcript.items.len;
    try app.frame(
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"text":"NATIVE_ONLY\n"}}}}
    );
    try std.testing.expectEqual(native_text_bytes, app.shell.transcript.items.len);
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"turn_phase_update":{"turn_id":7,"step_id":8,"phase":"thinking"}}}}
    );
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"turn_token_update":{"input_tokens":5,"output_tokens":13}}}}
    );
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"tool_lifecycle":{"authoritative_started":{"id":{"turn_id":7,"call_id":"shell-1"},"reconciles_provisional_call_id":null,"tool_name":"shell","activity_kind":"command","arguments_json":"{\"action\":\"run\",\"command\":\"printf root\"}"}}}}}
    );
    const id: types.ToolLifecycleId = .{ .turn_id = 107, .call_id = "shell-1" };
    try std.testing.expect(app.shell.toolActivityRecord(id) != null);
    try std.testing.expectEqual(@as(usize, 1), app.stream.command_count);
    try std.testing.expectEqual(@as(u64, 13), app.stream.token_progress.output_tokens);
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"tool_lifecycle":{"progress":{"id":{"turn_id":7,"call_id":"shell-1"},"text":"Running printf root"}}}}}
    );
    try std.testing.expect(std.mem.find(u8, try app.statusText(id), "Running printf root") != null);
    // The host sent plain text; the frontend marks the status row.
    try std.testing.expect(std.mem.startsWith(u8, try app.statusText(id), "●"));
    // ACP tool cards are not part of the native lane and change nothing.
    try app.frame(
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"duplicate","name":"shell","title":"generic shell","kind":"execute"}}}
    );
    try std.testing.expectEqual(@as(usize, 1), app.shell.toolActivityRecordCount());
    try app.frame(
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"tool_call_update","toolCallId":"shell-1","status":"completed","content":[]}}}
    );
    try std.testing.expectEqual(@import("../output/activity_runtime.zig").ToolLifecyclePhase.authoritative, app.shell.toolActivityRecord(id).?.phase);
    // Steering keeps the ACP user echo, without changing native lifecycle keys.
    try app.frame(
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"user_message_chunk","content":{"text":"steer"}}}}
    );
    try std.testing.expectEqual(@as(usize, 1), app.user_prompt_count);
    try std.testing.expectEqual(@as(u64, 100), app.remote.native_turn_offset);
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"command_output":{"lifecycle_id":{"turn_id":7,"call_id":"shell-1"},"stream":"stdout","text":"root stdout\n"}}}}
    );
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"command_output_complete":{"turn_id":7,"call_id":"shell-1"}}}}
    );
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"tool_lifecycle":{"terminal":{"id":{"turn_id":7,"call_id":"shell-1"},"outcome":{"kind":"failed","summary":"Failed printf root"},"result":"root stdout\n"}}}}}
    );
    const detail = app.shell.toolDetailForEntry(app.shell.toolActivityRecord(id).?.entry_id).?;
    try std.testing.expect(std.mem.find(u8, try app.statusText(id), "Failed printf root") != null);
    try std.testing.expectEqual(types.ToolOutcomeKind.failed, detail.outcome.?);
    try std.testing.expectEqualStrings("root stdout\n", detail.result.?);
    try std.testing.expect(detail.command_output_entry_id != null);
    // Permission feedback owns a separate native user card (not a steering echo).
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"append_user_feedback":"Use another command"}}}
    );
    try std.testing.expectEqual(@as(usize, 2), app.user_prompt_count);
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"turn_phase_update":{"turn_id":8,"step_id":1,"phase":"generating"}}}}
    );
    try std.testing.expectEqual(types.TurnPhase.generating, app.stream.phase);
    try std.testing.expectEqual(@as(u64, 1), app.stream.phase_step_id);
    try std.testing.expectEqual(@as(usize, 0), app.stream.command_count);
    try std.testing.expectEqual(@as(u64, 0), app.stream.token_progress.output_tokens);
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"tool_lifecycle":{"authoritative_started":{"id":{"turn_id":8,"call_id":"read-1"},"reconciles_provisional_call_id":null,"tool_name":"read_file","activity_kind":"read","arguments_json":"{\"path\":\"main.zig\"}"}}}}}
    );
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"tool_lifecycle":{"authoritative_started":{"id":{"turn_id":8,"call_id":"write-1"},"reconciles_provisional_call_id":null,"tool_name":"write_file","activity_kind":"write","arguments_json":"{}"}}}}}
    );
    try app.frame(
        \\{"method":"proto/native_presentation","params":{"session_id":"root","event":{"tool_lifecycle":{"authoritative_started":{"id":{"turn_id":8,"call_id":"child-1"},"reconciles_provisional_call_id":null,"tool_name":"subagent","activity_kind":"subagent","arguments_json":"{}"}}}}}
    );
    try std.testing.expectEqual(@as(usize, 1), app.stream.read_count);
    try std.testing.expectEqual(@as(usize, 1), app.stream.write_count);
    try std.testing.expectEqual(@as(usize, 1), app.stream.subagent_count);
    try std.testing.expectEqual(types.ToolActivityKind.subagent, app.shell.toolActivityRecord(.{ .turn_id = 108, .call_id = "child-1" }).?.activity_kind);
    // Structured append transfers ownership only on success; rejection must not
    // leak the bridge's cloned payload (checked by std.testing.allocator).
    app.reject_semantic = true;
    try std.testing.expectError(error.TestAppendRejected, app.apply(
        \\{"assistant_presentation":{"table":{"rows":[{"cells":["heading"]}],"alignments":["left"],"column_count":1}}}
    ));
    try std.testing.expectError(error.TestAppendRejected, app.apply(
        \\{"assistant_presentation":{"code_block":{"language":"zig","code":"const x = 1;"}}}
    ));
}

test "own prompt echoes are skipped once while other prompts get a card" {
    var app: NativePresentationTestApp = .{};
    defer app.shell.deinit(app.alloc);
    defer app.remote.deinit(app.alloc);
    try app.remote.submitted_text.append(app.alloc, try app.alloc.dupe(u8, "mine"));
    const echo =
        \\{"method":"session/update","params":{"update":{"sessionUpdate":"user_message_chunk","content":{"text":"mine"}}}}
    ;
    try app.frame(echo);
    try std.testing.expectEqual(@as(usize, 0), app.user_prompt_count);
    // A heartbeat or another client can send the same words later.
    try app.frame(echo);
    try std.testing.expectEqual(@as(usize, 1), app.user_prompt_count);
}

test "host command results render from their typed fields" {
    var app: NativePresentationTestApp = .{};
    defer app.shell.deinit(app.alloc);
    defer app.remote.deinit(app.alloc);
    try app.frame(
        \\{"method":"fx/command_result","params":{"name":"undo","ok":true,"result":{"command":"undo","outcome":"restored","path":"notes\u001b[31m.md"}}}
    );
    try app.frame(
        \\{"method":"fx/command_result","params":{"name":"context","ok":true,"result":{"command":"context","used":500,"total":1000,"auto_compact_percent":80}}}
    );
    try app.frame(
        \\{"method":"fx/command_result","params":{"name":"compact","ok":false,"error":"The session is busy"}}
    );
    const shown = app.shell.transcript.items;
    try std.testing.expect(std.mem.find(u8, shown, "Restored notes") != null);
    try std.testing.expect(std.mem.find(u8, shown, "\x1b[31m.md") == null);
    try std.testing.expect(std.mem.find(u8, shown, "context: 500 / 1000 tokens (50%)") != null);
    try std.testing.expect(std.mem.find(u8, shown, "The session is busy") != null);
}
