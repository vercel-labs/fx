//! The app's side of monitors (`src/core/monitor/`): once a second the main
//! loop looks at each monitor's command, and when it printed something or
//! ended and the monitor's pace allows, posts one event to the main agent as
//! a message, the way a subagent's message arrives. An idle agent starts a
//! turn; a busy one takes it at its next step. A quiet monitor costs a read
//! of one counter, no model call.

const std = @import("std");
const command_contract = @import("../execution/command_contract.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const monitor = @import("../monitor/monitor.zig");
const app_session_runtime = @import("app_session_runtime.zig");

const event = monitor.event;
const saved = monitor.saved;

pub fn Runtime(comptime App: type) type {
    return struct {
        const Session = app_session_runtime.Runtime(App);

        /// Tells the agent which monitors a restart ended, once the session
        /// that held them is open again: Ctrl+G and a crash leave the record
        /// that a normal quit removes. fx starts none of them by itself.
        pub fn noteLeftRunning(app: *App) void {
            const home = io_mod.homeDir() orelse return;
            const id = Session.activeSessionId(&app.main_agent) orelse return;
            var loaded = saved.load(app.alloc, home, id) orelse return;
            defer loaded.deinit();
            const registry = &app.main_agent.monitors;
            const text = saved.note(registry.alloc, loaded.entries) catch return;
            registry.setRestartNote(text);
            // The note is the record's last use: the monitors are not running,
            // and the agent starts the ones it wants.
            saved.clear(app.alloc, home, id);
            debug_trace.logf("monitor", "event=restart_noted count={d}", .{loaded.entries.len});
        }

        /// Removes the session's record after a quit the user chose, so the
        /// next resume has nothing to restart.
        pub fn clearRecord(app: *App) void {
            const home = io_mod.homeDir() orelse return;
            const id = Session.activeSessionId(&app.main_agent) orelse return;
            saved.clear(app.alloc, home, id);
        }

        /// Saves the record when the monitors changed, and posts the restart
        /// note and the events that are due. Runs on the main loop each pass.
        pub fn tick(app: *App) void {
            const agent = &app.main_agent;
            const registry = &agent.monitors;
            const now_ms = io_mod.milliTimestamp();
            stopDeparted(app, registry);
            saveChange(app, registry, now_ms);
            postRestartNote(app, agent, registry, now_ms);
            if (!registry.takePoll(now_ms)) return;
            const seen = registry.seen(app.alloc) catch |err| {
                debug_trace.logf("monitor", "event=poll_dropped reason={s}", .{@errorName(err)});
                return;
            };
            defer {
                for (seen) |item| item.deinit(app.alloc);
                app.alloc.free(seen);
            }
            for (seen) |item| poll(app, agent, registry, item, now_ms);
        }

        /// Stops the monitors of a session that is no longer open, in the
        /// background so the loop never waits on a command, and removes that
        /// session's record.
        fn stopDeparted(app: *App, registry: *monitor.Registry) void {
            const departed = (registry.followSession(Session.activeSessionId(&app.main_agent)) catch return) orelse return;
            debug_trace.logf("monitor", "event=session_changed count={d}", .{departed.ids.len});
            if (io_mod.homeDir()) |home| saved.clear(app.alloc, home, departed.session);
            const runtime = &app.main_agent.managed_executions;
            const ids = departed.ids;
            registry.alloc.free(departed.session);
            runtime.startBackground(stopAll, .{ runtime, registry.alloc, ids }) catch |err| {
                // No thread to stop them on: stop them here, once.
                debug_trace.logf("monitor", "event=stop_inline reason={s}", .{@errorName(err)});
                stopAll(runtime, registry.alloc, ids);
            };
            app.writeDomainNotice(.{
                .topic = "monitor",
                .tone = .neutral,
                .body = "monitors of the earlier conversation were stopped",
            }, true) catch |err| debug_trace.logf("monitor", "event=notice_failed err={s}", .{@errorName(err)});
        }

        /// Stops each command and frees `ids`. Runs on a background task.
        fn stopAll(runtime: *managed_execution.Runtime, alloc: std.mem.Allocator, ids: [][]u8) void {
            defer {
                for (ids) |id| alloc.free(id);
                alloc.free(ids);
            }
            for (ids) |id| {
                var stopped = runtime.stop(alloc, id, false) catch |err| {
                    debug_trace.logf("monitor", "event=stop_failed id={s} err={s}", .{ id, @errorName(err) });
                    continue;
                };
                defer stopped.deinit(alloc);
                commitRead(runtime, id, stopped.reservation_id);
                debug_trace.logf("monitor", "event=stop id={s} reason=session_changed", .{id});
            }
        }

        fn saveChange(app: *App, registry: *monitor.Registry, now_ms: i64) void {
            if (!registry.hasUnsaved() or !registry.saveDue(now_ms)) return;
            const home = io_mod.homeDir() orelse return;
            const id = Session.activeSessionId(&app.main_agent) orelse return;
            const entries = (registry.takeChange(app.alloc) catch return) orelse return;
            defer {
                monitor.freeEntries(app.alloc, entries);
                app.alloc.free(entries);
            }
            saved.save(app.alloc, home, id, entries) catch |err| {
                debug_trace.logf("monitor", "event=record_save_failed err={s}", .{@errorName(err)});
                registry.markUnsaved();
                return;
            };
            debug_trace.logf("monitor", "event=record_saved count={d}", .{entries.len});
        }

        fn postRestartNote(app: *App, agent: anytype, registry: *monitor.Registry, now_ms: i64) void {
            const text = registry.takeRestartNote(now_ms) orelse return;
            const framed = event.frame(app.alloc, "fx", "restart", text) catch {
                registry.setRestartNote(text);
                return;
            };
            defer app.alloc.free(framed);
            app.postAgentMessage(agent, framed, .child, .report) catch |err| {
                debug_trace.logf("monitor", "event=restart_note_deferred err={s}", .{@errorName(err)});
                registry.setRestartNote(text);
                return;
            };
            registry.alloc.free(text);
            app.writeDomainNotice(.{
                .topic = "monitor",
                .tone = .neutral,
                .body = "monitors ended when fx restarted; the agent can start them again",
            }, true) catch |err| debug_trace.logf("monitor", "event=restart_notice_failed err={s}", .{@errorName(err)});
        }

        fn poll(app: *App, agent: anytype, registry: *monitor.Registry, item: monitor.Seen, now_ms: i64) void {
            const runtime = &agent.managed_executions;
            const state = runtime.stateFor(item.id) orelse {
                // Its entry is gone, so nothing is left to read or stop.
                _ = registry.remove(item.id);
                debug_trace.logf("monitor", "event=stop id={s} reason=entry_gone", .{item.id});
                return;
            };
            const ended = state != .running;
            const waiting = runtime.pendingOutputBytesFor(item.id) orelse 0;
            if (!ended and waiting == 0) return;
            if (!event.due(now_ms, item.last_event_ms, ended)) return;
            post(app, agent, registry, item, now_ms);
        }

        fn post(app: *App, agent: anytype, registry: *monitor.Registry, item: monitor.Seen, now_ms: i64) void {
            const runtime = &agent.managed_executions;
            // The agent may have stopped it since the loop listed it: its stop
            // is the answer, so no end event follows.
            if (!registry.contains(item.id)) return;
            // An agent that stops for fx's restart takes no more mail: the
            // output waits in the entry.
            if (agent.worker.yield_requested.load(.seq_cst)) return;
            // A busy or stopping command is looked at again next second.
            var prepared = runtime.wait(app.alloc, item.id, 0, null) catch |err| {
                debug_trace.logf("monitor", "event=read_deferred id={s} reason={s}", .{ item.id, @errorName(err) });
                return;
            };
            defer prepared.deinit(app.alloc);
            const snapshot = prepared.snapshot;
            const running = snapshot.state == .running;
            const text = eventText(app, snapshot) catch |err| {
                cancelRead(runtime, item.id, prepared.reservation_id);
                debug_trace.logf("monitor", "event=read_deferred id={s} reason={s}", .{ item.id, @errorName(err) });
                return;
            };
            defer app.alloc.free(text.body);
            const hash = event.textHash(text.body);
            // The same words again are no news: the output is taken, the
            // agent is not woken, and the monitor waits out the gap.
            if (running and item.last_hash == hash) {
                commitRead(runtime, item.id, prepared.reservation_id);
                registry.markEvent(item.id, now_ms, hash);
                debug_trace.logf("monitor", "event=dropped id={s} reason=repeat bytes={d}", .{ item.id, text.body.len });
                return;
            }
            // Blank lines only: nothing to say, so take them off the entry
            // instead of reading them again each second.
            if (running and text.body.len == 0) {
                commitRead(runtime, item.id, prepared.reservation_id);
                return;
            }
            const framed = event.frame(app.alloc, item.label, item.id, text.body) catch {
                cancelRead(runtime, item.id, prepared.reservation_id);
                return;
            };
            defer app.alloc.free(framed);
            app.postAgentMessage(agent, framed, .child, .report) catch |err| {
                cancelRead(runtime, item.id, prepared.reservation_id);
                debug_trace.logf("monitor", "event=post_deferred id={s} reason={s}", .{ item.id, @errorName(err) });
                return;
            };
            commitRead(runtime, item.id, prepared.reservation_id);
            registry.markEvent(item.id, now_ms, hash);
            debug_trace.logf("monitor", "event=event id={s} bytes={d} more_lines={d} ended={}", .{ item.id, text.body.len, text.more_lines, !running });
            if (!running) {
                _ = registry.remove(item.id);
                debug_trace.logf("monitor", "event=stop id={s} reason=command_ended", .{item.id});
            }
        }

        /// Gives a read's output back to the entry, so a later event carries it.
        fn cancelRead(runtime: *managed_execution.Runtime, id: []const u8, reservation_id: u64) void {
            runtime.cancelDelivery(id, reservation_id) catch |err|
                debug_trace.logf("monitor", "event=cancel_failed id={s} err={s}", .{ id, @errorName(err) });
        }

        /// Takes a read's output off the entry once the agent has it.
        fn commitRead(runtime: *managed_execution.Runtime, id: []const u8, reservation_id: u64) void {
            runtime.commitDelivery(id, reservation_id) catch |err|
                debug_trace.logf("monitor", "event=commit_failed id={s} err={s}", .{ id, @errorName(err) });
        }

        const Text = struct { body: []u8, more_lines: usize };

        /// The words of one event: the new output, and for the last event
        /// how the command ended. Caller frees `body`.
        fn eventText(app: *App, snapshot: managed_execution.Snapshot) !Text {
            const composed = try event.compose(app.alloc, snapshot.output_delta);
            if (snapshot.state == .running) return .{ .body = composed.text, .more_lines = composed.more_lines };
            defer composed.deinit(app.alloc);
            const ending = try event.endedText(app.alloc, endedOf(snapshot.state));
            defer app.alloc.free(ending);
            const body = if (composed.text.len == 0)
                try app.alloc.dupe(u8, ending)
            else
                try app.alloc.print("{s}\n{s}", .{ composed.text, ending });
            return .{ .body = body, .more_lines = composed.more_lines };
        }

        fn endedOf(state: managed_execution.SnapshotState) event.Ended {
            return switch (state) {
                .running => .unknown,
                .completed => |status| fromStatus(status),
                .stopped => |status| if (status) |known| fromStatus(known) else .unknown,
                .lost => .unknown,
            };
        }

        fn fromStatus(status: command_contract.CommandStatus) event.Ended {
            return switch (status) {
                .exit_code => |code| .{ .exit_code = code },
                .signal => |number| .{ .signal = number },
                .finished, .indeterminate => .unknown,
            };
        }
    };
}
