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
const output_log = monitor.output_log;

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
            output_log.removeSession(app.alloc, home, id);
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
            if (io_mod.homeDir()) |home| {
                saved.clear(app.alloc, home, departed.session);
                output_log.removeSession(app.alloc, home, departed.session);
            }
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
            const framed = event.frame(app.alloc, "fx", "restart", text, null) catch {
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
            if (!item.ended) {
                const state = runtime.stateFor(item.id) orelse {
                    // Its entry is gone, so nothing is left to read or stop.
                    _ = registry.remove(item.id);
                    debug_trace.logf("monitor", "event=stop id={s} reason=entry_gone", .{item.id});
                    return;
                };
                const ended = state != .running;
                const waiting = runtime.pendingOutputBytesFor(item.id) orelse 0;
                const due = event.due(now_ms, item.last_event_ms, ended, monitor.gapMs());
                // Output is read each second, so the file keeps all of it and
                // the entry's bounded buffer never drops any between events.
                // The words of an event wait for its turn.
                if (ended or waiting > 0 or (due and registry.hasPending(item.id))) {
                    read(app, agent, registry, item, now_ms, due);
                }
            }
            flush(app, agent, registry, item.id, now_ms);
        }

        /// Reads what the command printed and keeps all of it in the
        /// monitor's file. When the monitor's pace allows an event, holds the
        /// event made of the output since the last one; before that, keeps
        /// the words for it. The agent gets held events in `flush`, when it
        /// can take them.
        fn read(app: *App, agent: anytype, registry: *monitor.Registry, item: monitor.Seen, now_ms: i64, due: bool) void {
            const runtime = &agent.managed_executions;
            // The agent may have stopped it since the loop listed it: its stop
            // is the answer, so no end event follows.
            if (!registry.contains(item.id)) return;
            // A busy or stopping command is looked at again next second.
            var prepared = runtime.wait(app.alloc, item.id, 0, null) catch |err| {
                debug_trace.logf("monitor", "event=read_deferred id={s} reason={s}", .{ item.id, @errorName(err) });
                return;
            };
            defer prepared.deinit(app.alloc);
            const snapshot = prepared.snapshot;
            const running = snapshot.state == .running;
            if (running and !due) {
                const listed = registry.appendPending(item.id, snapshot.output_delta) catch |err| {
                    cancelRead(runtime, item.id, prepared.reservation_id);
                    debug_trace.logf("monitor", "event=read_deferred id={s} reason={s}", .{ item.id, @errorName(err) });
                    return;
                };
                if (!listed) {
                    cancelRead(runtime, item.id, prepared.reservation_id);
                    return;
                }
                finishRead(app, runtime, item.id, prepared.reservation_id, snapshot.output_delta);
                return;
            }
            const pending = registry.copyPending(app.alloc, item.id) catch |err| {
                cancelRead(runtime, item.id, prepared.reservation_id);
                debug_trace.logf("monitor", "event=read_deferred id={s} reason={s}", .{ item.id, @errorName(err) });
                return;
            };
            defer if (pending) |bytes| app.alloc.free(bytes);
            // The event's words: what was kept since the last event, then
            // what this read took.
            var words = snapshot;
            var joined: ?[]u8 = null;
            defer if (joined) |bytes| app.alloc.free(bytes);
            if (pending) |bytes| {
                joined = std.mem.concat(app.alloc, u8, &.{ bytes, snapshot.output_delta }) catch |err| {
                    cancelRead(runtime, item.id, prepared.reservation_id);
                    debug_trace.logf("monitor", "event=read_deferred id={s} reason={s}", .{ item.id, @errorName(err) });
                    return;
                };
                words.output_delta = joined.?;
            }
            const text = eventText(app, words) catch |err| {
                cancelRead(runtime, item.id, prepared.reservation_id);
                debug_trace.logf("monitor", "event=read_deferred id={s} reason={s}", .{ item.id, @errorName(err) });
                return;
            };
            defer app.alloc.free(text.body);
            const hash = event.textHash(text.body);
            // The same words again are no news: the output is taken, the
            // agent is not woken, and the monitor waits out the gap.
            if (running and item.last_hash == hash) {
                registry.clearPending(item.id);
                finishRead(app, runtime, item.id, prepared.reservation_id, snapshot.output_delta);
                registry.markEvent(item.id, now_ms, hash);
                debug_trace.logf("monitor", "event=dropped id={s} reason=repeat bytes={d}", .{ item.id, text.body.len });
                return;
            }
            // Blank lines only: nothing to say, so take them off the entry
            // instead of reading them again each second.
            if (running and text.body.len == 0) {
                registry.clearPending(item.id);
                finishRead(app, runtime, item.id, prepared.reservation_id, snapshot.output_delta);
                return;
            }
            const dropped = registry.pushHeld(item.id, text.body, now_ms, !running) catch |err| {
                cancelRead(runtime, item.id, prepared.reservation_id);
                debug_trace.logf("monitor", "event=read_deferred id={s} reason={s}", .{ item.id, @errorName(err) });
                return;
            };
            registry.clearPending(item.id);
            finishRead(app, runtime, item.id, prepared.reservation_id, snapshot.output_delta);
            registry.markEvent(item.id, now_ms, hash);
            debug_trace.logf("monitor", "event=held id={s} bytes={d} more_lines={d} dropped_before={d} ended={}", .{ item.id, text.body.len, text.more_lines, dropped orelse 0, !running });
        }

        /// Posts the events a monitor holds as one message, when the agent can
        /// take it: nothing of this monitor's waits in its queue, and it is not
        /// stopping for fx's restart. Otherwise they stay held, the newest
        /// twenty, and the file keeps everything.
        fn flush(app: *App, agent: anytype, registry: *monitor.Registry, id: []const u8, now_ms: i64) void {
            if (!registry.hasHeld(id)) return;
            if (agent.worker.yield_requested.load(.seq_cst)) return;
            if (agent.worker.agentMessageCount() >= monitor.max_queued_events) return;
            if (!agent.worker.reserveAgentMessage()) return;
            const batch = (registry.takeHeld(id) catch {
                agent.worker.releaseAgentMessage();
                return;
            }) orelse {
                agent.worker.releaseAgentMessage();
                return;
            };
            const label = labelOf(app, registry, id);
            defer if (label) |text| app.alloc.free(text);
            const body = event.digest(app.alloc, batch.events, batch.dropped, now_ms) catch {
                agent.worker.releaseAgentMessage();
                registry.restoreHeld(id, batch);
                return;
            };
            defer app.alloc.free(body);
            const file = outputFile(app, id);
            defer if (file) |path| app.alloc.free(path);
            const framed = event.frame(app.alloc, label orelse id, id, body, file) catch {
                agent.worker.releaseAgentMessage();
                registry.restoreHeld(id, batch);
                return;
            };
            defer app.alloc.free(framed);
            // The place held above is spent by the post, whatever happens.
            app.postAgentMessage(agent, framed, .child, .message) catch |err| {
                debug_trace.logf("monitor", "event=post_deferred id={s} reason={s}", .{ id, @errorName(err) });
                registry.restoreHeld(id, batch);
                return;
            };
            debug_trace.logf("monitor", "event=event id={s} events={d} dropped={d} bytes={d} ended={}", .{ id, batch.events.len, batch.dropped, body.len, batch.ended });
            const ended = batch.ended;
            monitor.freeBatch(app.alloc, batch);
            if (ended) {
                _ = registry.remove(id);
                debug_trace.logf("monitor", "event=stop id={s} reason=command_ended", .{id});
            }
        }

        /// The monitor's label, copied. Caller frees it.
        fn labelOf(app: *App, registry: *monitor.Registry, id: []const u8) ?[]u8 {
            const seen = registry.seen(app.alloc) catch return null;
            defer {
                for (seen) |item| item.deinit(app.alloc);
                app.alloc.free(seen);
            }
            for (seen) |item| {
                if (std.mem.eql(u8, item.id, id)) return app.alloc.dupe(u8, item.label) catch null;
            }
            return null;
        }

        /// The path of the file that holds everything monitor `id` printed, or
        /// null when the session or the profile folder is unknown.
        fn outputFile(app: *App, id: []const u8) ?[]u8 {
            const home = io_mod.homeDir() orelse return null;
            const session = Session.activeSessionId(&app.main_agent) orelse return null;
            return output_log.filePath(app.alloc, home, session, id) catch null;
        }

        fn logOutput(app: *App, id: []const u8, output: []const u8) void {
            if (output.len == 0) return;
            const home = io_mod.homeDir() orelse return;
            const session = Session.activeSessionId(&app.main_agent) orelse return;
            output_log.append(app.alloc, home, session, id, output) catch |err|
                debug_trace.logf("monitor", "event=log_failed id={s} err={s}", .{ id, @errorName(err) });
        }

        /// Gives a read's output back to the entry, so a later event carries it.
        fn cancelRead(runtime: *managed_execution.Runtime, id: []const u8, reservation_id: u64) void {
            runtime.cancelDelivery(id, reservation_id) catch |err|
                debug_trace.logf("monitor", "event=cancel_failed id={s} err={s}", .{ id, @errorName(err) });
        }

        /// Writes a read's output to the monitor's file, then takes it off
        /// the entry. Only a read that is kept gets here, so the file never
        /// holds a read twice.
        fn finishRead(app: *App, runtime: *managed_execution.Runtime, id: []const u8, reservation_id: u64, output: []const u8) void {
            logOutput(app, id, output);
            commitRead(runtime, id, reservation_id);
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
