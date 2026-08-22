const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const host = @import("../hosts/js_host_attached_api.zig");
const provider_runtime = @import("provider_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const types = @import("../shared/types.zig");
const hooks = @import("../hooks/hooks.zig");

const max_commands_per_tick: usize = 32;

const AttachedTurnState = enum {
    queued,
    active,
    finished,
};

const Command = struct {
    version: u32,
    id: u64,
    type: []const u8,
    prompt: ?[]const u8 = null,
    turnId: ?u64 = null,
};

pub const State = struct {
    last_state: std.ArrayList(u8) = .empty,
    attached_turns: std.AutoHashMapUnmanaged(u64, AttachedTurnState) = .empty,
    next_terminal_turn_id: u64 = 1,
    next_turn_id: u64 = 1_000_000,

    pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
        self.last_state.deinit(alloc);
        self.attached_turns.deinit(alloc);
    }
};

pub fn Runtime(comptime App: type) type {
    const SessionRuntime = app_session_runtime.Runtime(App);

    return struct {
        pub fn reserveTerminalTurnId(app: *App) u64 {
            const turn_id = app.attached_api.next_terminal_turn_id;
            app.attached_api.next_terminal_turn_id += 1;
            if (app.attached_api.next_terminal_turn_id >= 1_000_000) {
                app.attached_api.next_terminal_turn_id = 1;
            }
            return turn_id;
        }

        pub fn noteReservedTurnId(app: *App, turn_id: u64) void {
            if (turn_id < 1_000_000) {
                if (turn_id >= app.attached_api.next_terminal_turn_id) {
                    app.attached_api.next_terminal_turn_id = turn_id + 1;
                }
                return;
            }
            if (turn_id <= 9_007_199_254_740_991 and turn_id >= app.attached_api.next_turn_id) {
                app.attached_api.next_turn_id = turn_id + 1;
            }
        }

        pub fn collect(app: *App) void {
            syncState(app) catch |err| logFailure("state", err);
            for (0..max_commands_per_tick) |_| {
                const encoded = host.next(app.alloc) catch |err| {
                    logFailure("read", err);
                    return;
                } orelse return;
                defer app.alloc.free(encoded);
                handleCommand(app, encoded) catch |err| logFailure("command", err);
            }
        }

        pub fn publishWorkerEvent(app: *App, event: worker_runtime.WorkerEvent) void {
            const active_turn_id = app.worker.activeTurnId();
            switch (event) {
                .begin_prompt => |prompt| publishUserMessage(app, active_turn_id, prompt.text),
                .begin_prompt_with_skill_bindings => |begin| publishUserMessage(app, active_turn_id, begin.prompt.text),
                .append_user_feedback => |text| publishUserMessage(app, active_turn_id, text),
                .assistant_presentation => |presentation| publishPresentation(app, active_turn_id, presentation),
                .semantic_notice => |notice| publishNotice(app, active_turn_id, notice),
                .error_text => |notice| publishNotice(app, active_turn_id, notice),
                .route_recovery_status => |status| publishRecovery(app, active_turn_id, status),
                .command_output => |chunk| publishCommandOutput(app, active_turn_id, chunk),
                .tool_lifecycle => |lifecycle| publishToolLifecycle(app, lifecycle),
                else => {},
            }
        }

        pub fn publishAttentionRequired(app: *App, turn_id: u64, kind: hooks.AttentionKind) void {
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            writeUpdateStart(app, turn_id, &out.writer) catch return;
            out.writer.writeAll("{\"sessionUpdate\":\"attention_required\",\"kind\":") catch return;
            writeJson(@tagName(kind), &out.writer) catch return;
            out.writer.writeAll("}}") catch return;
            emit(out.written()) catch |err| logFailure("attention", err);
        }

        fn handleCommand(app: *App, encoded: []const u8) !void {
            const parsed = std.json.parseFromSlice(Command, app.alloc, encoded, .{
                .ignore_unknown_fields = true,
            }) catch {
                try emitControlError(app, null, "invalid_request", "control command must be valid JSON");
                return;
            };
            defer parsed.deinit();
            const command = parsed.value;
            if (command.version != 1) {
                try emitControlError(app, command.id, "unsupported_version", "control command version must be 1");
                return;
            }

            if (std.mem.eql(u8, command.type, "session.prompt")) {
                pruneFinishedTurns(app);
                const prompt = command.prompt orelse {
                    try emitControlError(app, command.id, "invalid_prompt", "session.prompt requires prompt text");
                    return;
                };
                if (prompt.len == 0) {
                    try emitControlError(app, command.id, "invalid_prompt", "prompt text must not be empty");
                    return;
                }
                if (app.pending_images.items.len != 0) {
                    try emitControlError(app, command.id, "terminal_draft_has_images", "submit or clear terminal images before using session.prompt");
                    return;
                }

                // A completed turn may still be held by the terminal pacer.
                // Commit that semantic boundary before snapshotting shared history.
                try app.pacer.flushPresentationAtBoundary(
                    app.alloc,
                    io_mod.nanoTimestamp(),
                    app.pacerCallbacks(),
                );

                const turn_id = app.attached_api.next_turn_id;
                app.attached_api.next_turn_id +%= 1;
                if (app.attached_api.next_turn_id < 1_000_000 or app.attached_api.next_turn_id > 9_007_199_254_740_991) {
                    app.attached_api.next_turn_id = 1_000_000;
                }
                try app.attached_api.attached_turns.put(app.alloc, turn_id, .queued);
                const accepted = app.enqueueAttachedPrompt(prompt, turn_id) catch |err| {
                    _ = app.attached_api.attached_turns.remove(turn_id);
                    try emitControlError(app, command.id, "prompt_rejected", @errorName(err));
                    return;
                };
                if (!accepted) {
                    _ = app.attached_api.attached_turns.remove(turn_id);
                    try emitControlError(app, command.id, "prompt_rejected", "prompt was not accepted");
                    return;
                }
                try emitControlResult(app, command.id, "{\"accepted\":true,\"turnId\":", turn_id);
                syncState(app) catch |err| logFailure("state", err);
                return;
            }

            if (std.mem.eql(u8, command.type, "session.cancel")) {
                const turn_id = command.turnId orelse {
                    try emitControlError(app, command.id, "invalid_turn", "session.cancel requires turnId");
                    return;
                };
                const turn_state = app.attached_api.attached_turns.get(turn_id) orelse {
                    try emitControlError(app, command.id, "not_owned", "the attached API can cancel only its own turns");
                    return;
                };
                if (turn_state == .queued) {
                    try emitControlError(app, command.id, "not_active", "only the active attached turn can be cancelled");
                    return;
                }
                if (turn_state == .finished) {
                    try emitControlResult(app, command.id, "{\"cancelled\":true,\"turnId\":", turn_id);
                    return;
                }
                const active_turn_id = app.worker.activeTurnId();
                if (active_turn_id != 0 and active_turn_id != turn_id) {
                    try emitControlError(app, command.id, "not_active", "only the active attached turn can be cancelled");
                    return;
                }
                if (active_turn_id == turn_id) app.worker.requestCancel();
                try emitControlResult(app, command.id, "{\"cancelled\":true,\"turnId\":", turn_id);
                return;
            }

            if (std.mem.eql(u8, command.type, "session.state")) {
                try emitControlState(app, command.id);
                return;
            }

            try emitControlError(app, command.id, "unknown_command", "unsupported control command");
        }

        fn syncState(app: *App) !void {
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            try writeState(app, null, &out.writer);
            if (std.mem.eql(u8, app.attached_api.last_state.items, out.written())) return;
            try emit(out.written());
            app.attached_api.last_state.clearRetainingCapacity();
            try app.attached_api.last_state.appendSlice(app.alloc, out.written());
        }

        fn emitControlState(app: *App, id: u64) !void {
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            try writeState(app, id, &out.writer);
            try emit(out.written());
        }

        fn writeState(app: *App, control_id: ?u64, writer: *std.Io.Writer) !void {
            if (control_id) |id| {
                try writer.print("{{\"type\":\"control.response\",\"version\":1,\"id\":{d},\"result\":", .{id});
            }
            try writer.writeAll("{\"type\":\"session.state\",\"version\":1,\"sessionId\":");
            try writeOptionalJson(SessionRuntime.activeSessionId(app), writer);
            try writer.writeAll(",\"workspaceRoot\":");
            try writeJson(app.workspace_root, writer);
            try writer.writeAll(",\"model\":");
            try writeJson(provider_runtime.model(app), writer);
            try writer.writeAll(",\"permissionMode\":");
            try writeJson(@tagName(app.permission_engine.mode), writer);
            try writer.print(",\"activeTurnId\":{d},\"queuedPromptCount\":{d},\"historyTurnCount\":{d}}}", .{
                app.worker.activeTurnId(),
                app.worker.queuePreview().count,
                app.session.historyLen(),
            });
            if (control_id != null) try writer.writeByte('}');
        }

        fn emitControlResult(app: *App, id: u64, prefix: []const u8, turn_id: u64) !void {
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            try out.writer.print("{{\"type\":\"control.response\",\"version\":1,\"id\":{d},\"result\":", .{id});
            try out.writer.writeAll(prefix);
            try out.writer.print("{d}}}}}", .{turn_id});
            try emit(out.written());
        }

        fn emitControlError(app: *App, id: ?u64, code: []const u8, message: []const u8) !void {
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            try out.writer.writeAll("{\"type\":\"control.response\",\"version\":1,\"id\":");
            if (id) |value| try out.writer.print("{d}", .{value}) else try out.writer.writeAll("null");
            try out.writer.writeAll(",\"error\":{\"code\":");
            try writeJson(code, &out.writer);
            try out.writer.writeAll(",\"message\":");
            try writeJson(message, &out.writer);
            try out.writer.writeAll("}}");
            try emit(out.written());
        }

        fn publishUserMessage(app: *App, turn_id: u64, text: []const u8) void {
            const attached = app.attached_api.attached_turns.getPtr(turn_id);
            if (attached) |state| state.* = .active;
            syncState(app) catch |err| logFailure("state", err);
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            writeUpdateStart(app, turn_id, &out.writer) catch return;
            out.writer.writeAll("{\"sessionUpdate\":\"user_message\",\"source\":") catch return;
            const source = if (attached != null) "structured" else "terminal";
            writeJson(source, &out.writer) catch return;
            out.writer.writeAll(",\"content\":{\"type\":\"text\",\"text\":") catch return;
            writeJson(text, &out.writer) catch return;
            out.writer.writeAll("}}}") catch return;
            emit(out.written()) catch |err| logFailure("user", err);
        }

        fn publishPresentation(app: *App, turn_id: u64, presentation: @import("../agent/assistant_presentation.zig").Event) void {
            switch (presentation) {
                .text => |text| publishTextUpdate(app, turn_id, "agent_message_chunk", text),
                .code_block => |block| {
                    var out: std.Io.Writer.Allocating = .init(app.alloc);
                    defer out.deinit();
                    writeUpdateStart(app, turn_id, &out.writer) catch return;
                    out.writer.writeAll("{\"sessionUpdate\":\"agent_code_block\",\"language\":") catch return;
                    writeJson(block.language, &out.writer) catch return;
                    out.writer.writeAll(",\"code\":") catch return;
                    writeJson(block.code, &out.writer) catch return;
                    out.writer.writeAll("}}") catch return;
                    emit(out.written()) catch |err| logFailure("code", err);
                },
                .table => |table| {
                    var out: std.Io.Writer.Allocating = .init(app.alloc);
                    defer out.deinit();
                    writeUpdateStart(app, turn_id, &out.writer) catch return;
                    out.writer.writeAll("{\"sessionUpdate\":\"agent_table\",\"rows\":[") catch return;
                    for (table.rows, 0..) |row, row_index| {
                        if (row_index != 0) out.writer.writeByte(',') catch return;
                        out.writer.writeByte('[') catch return;
                        for (row.cells, 0..) |cell, cell_index| {
                            if (cell_index != 0) out.writer.writeByte(',') catch return;
                            writeJson(cell, &out.writer) catch return;
                        }
                        out.writer.writeByte(']') catch return;
                    }
                    out.writer.writeAll("],\"alignments\":[") catch return;
                    for (table.alignments, 0..) |alignment, index| {
                        if (index != 0) out.writer.writeByte(',') catch return;
                        writeJson(@tagName(alignment), &out.writer) catch return;
                    }
                    out.writer.writeAll("]}}") catch return;
                    emit(out.written()) catch |err| logFailure("table", err);
                },
                .thematic_rule => publishSimpleUpdate(app, turn_id, "agent_thematic_rule"),
            }
        }

        fn publishToolLifecycle(app: *App, lifecycle: types.ToolLifecycleEvent) void {
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            switch (lifecycle) {
                .provisional => |event| {
                    writeUpdateStart(app, event.id.turn_id, &out.writer) catch return;
                    out.writer.writeAll("{\"sessionUpdate\":\"tool_call\",\"phase\":\"provisional\",\"callId\":") catch return;
                    writeJson(event.id.call_id, &out.writer) catch return;
                    out.writer.writeAll(",\"toolName\":") catch return;
                    tryWriteOptionalJson(event.tool_name, &out.writer) orelse return;
                    out.writer.writeAll(",\"activityKind\":") catch return;
                    writeJson(@tagName(event.activity_kind), &out.writer) catch return;
                    out.writer.writeAll("}}") catch return;
                },
                .authoritative_started => |event| {
                    writeUpdateStart(app, event.id.turn_id, &out.writer) catch return;
                    out.writer.writeAll("{\"sessionUpdate\":\"tool_call\",\"phase\":\"started\",\"callId\":") catch return;
                    writeJson(event.id.call_id, &out.writer) catch return;
                    out.writer.writeAll(",\"toolName\":") catch return;
                    writeJson(event.tool_name, &out.writer) catch return;
                    out.writer.writeAll(",\"activityKind\":") catch return;
                    writeJson(@tagName(event.activity_kind), &out.writer) catch return;
                    out.writer.writeAll(",\"argumentsJson\":") catch return;
                    tryWriteOptionalJson(event.arguments_json, &out.writer) orelse return;
                    out.writer.writeAll("}}") catch return;
                },
                .progress => |event| {
                    writeUpdateStart(app, event.id.turn_id, &out.writer) catch return;
                    out.writer.writeAll("{\"sessionUpdate\":\"tool_call_update\",\"phase\":\"progress\",\"callId\":") catch return;
                    writeJson(event.id.call_id, &out.writer) catch return;
                    out.writer.writeAll(",\"text\":") catch return;
                    writeJson(event.text, &out.writer) catch return;
                    out.writer.writeAll("}}") catch return;
                },
                .terminal => |event| {
                    writeUpdateStart(app, event.id.turn_id, &out.writer) catch return;
                    out.writer.writeAll("{\"sessionUpdate\":\"tool_call_update\",\"phase\":\"terminal\",\"callId\":") catch return;
                    writeJson(event.id.call_id, &out.writer) catch return;
                    out.writer.writeAll(",\"outcome\":") catch return;
                    writeJson(@tagName(event.outcome.kind), &out.writer) catch return;
                    out.writer.writeAll(",\"summary\":") catch return;
                    writeJson(event.outcome.summary, &out.writer) catch return;
                    out.writer.writeAll(",\"result\":") catch return;
                    tryWriteOptionalJson(event.result, &out.writer) orelse return;
                    out.writer.writeAll("}}") catch return;
                },
                .turn_finished => |event| {
                    writeUpdateStart(app, event.turn_id, &out.writer) catch return;
                    out.writer.writeAll("{\"sessionUpdate\":\"turn_finished\",\"outcome\":") catch return;
                    writeJson(@tagName(event.outcome), &out.writer) catch return;
                    out.writer.writeAll("}}") catch return;
                    if (app.attached_api.attached_turns.getPtr(event.turn_id)) |state| {
                        state.* = .finished;
                    }
                },
            }
            emit(out.written()) catch |err| logFailure("tool", err);
        }

        fn publishCommandOutput(app: *App, turn_id: u64, chunk: worker_runtime.CommandOutputChunk) void {
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            const event_turn_id = if (chunk.lifecycle_id) |id| id.turn_id else turn_id;
            writeUpdateStart(app, event_turn_id, &out.writer) catch return;
            out.writer.writeAll("{\"sessionUpdate\":\"command_output\",\"stream\":") catch return;
            writeJson(@tagName(chunk.stream), &out.writer) catch return;
            out.writer.writeAll(",\"text\":") catch return;
            writeJson(chunk.text, &out.writer) catch return;
            out.writer.writeAll("}}") catch return;
            emit(out.written()) catch |err| logFailure("command_output", err);
        }

        fn publishNotice(app: *App, turn_id: u64, notice: types.SemanticNotice) void {
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            writeUpdateStart(app, turn_id, &out.writer) catch return;
            out.writer.writeAll("{\"sessionUpdate\":\"notice\",\"topic\":") catch return;
            writeJson(notice.topic, &out.writer) catch return;
            out.writer.writeAll(",\"tone\":") catch return;
            writeJson(@tagName(notice.tone), &out.writer) catch return;
            out.writer.writeAll(",\"body\":") catch return;
            writeJson(notice.body, &out.writer) catch return;
            out.writer.writeAll("}}") catch return;
            emit(out.written()) catch |err| logFailure("notice", err);
        }

        fn publishRecovery(app: *App, turn_id: u64, status: types.RouteRecoveryStatus) void {
            var label: [types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
            publishTextUpdate(app, turn_id, "model_recovery", status.label(&label));
        }

        fn publishTextUpdate(app: *App, turn_id: u64, update_type: []const u8, text: []const u8) void {
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            writeUpdateStart(app, turn_id, &out.writer) catch return;
            out.writer.writeAll("{\"sessionUpdate\":") catch return;
            writeJson(update_type, &out.writer) catch return;
            out.writer.writeAll(",\"content\":{\"type\":\"text\",\"text\":") catch return;
            writeJson(text, &out.writer) catch return;
            out.writer.writeAll("}}}") catch return;
            emit(out.written()) catch |err| logFailure("text", err);
        }

        fn publishSimpleUpdate(app: *App, turn_id: u64, update_type: []const u8) void {
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            writeUpdateStart(app, turn_id, &out.writer) catch return;
            out.writer.writeAll("{\"sessionUpdate\":") catch return;
            writeJson(update_type, &out.writer) catch return;
            out.writer.writeAll("}}") catch return;
            emit(out.written()) catch |err| logFailure("simple", err);
        }

        fn writeUpdateStart(app: *App, turn_id: u64, writer: *std.Io.Writer) !void {
            try writer.writeAll("{\"type\":\"session.update\",\"version\":1,\"sessionId\":");
            try writeOptionalJson(SessionRuntime.activeSessionId(app), writer);
            try writer.print(",\"turnId\":{d},\"update\":", .{turn_id});
        }

        fn pruneFinishedTurns(app: *App) void {
            var finished_ids: [64]u64 = undefined;
            while (true) {
                var count: usize = 0;
                var iterator = app.attached_api.attached_turns.iterator();
                while (iterator.next()) |entry| {
                    if (entry.value_ptr.* != .finished) continue;
                    finished_ids[count] = entry.key_ptr.*;
                    count += 1;
                    if (count == finished_ids.len) break;
                }
                for (finished_ids[0..count]) |turn_id| {
                    _ = app.attached_api.attached_turns.remove(turn_id);
                }
                if (count < finished_ids.len) return;
            }
        }
    };
}

fn writeJson(value: anytype, writer: *std.Io.Writer) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeOptionalJson(value: ?[]const u8, writer: *std.Io.Writer) !void {
    if (value) |text| try writeJson(text, writer) else try writer.writeAll("null");
}

fn tryWriteOptionalJson(value: ?[]const u8, writer: *std.Io.Writer) ?void {
    writeOptionalJson(value, writer) catch return null;
}

fn emit(event: []const u8) !void {
    try host.emit(event);
}

fn logFailure(stage: []const u8, err: anyerror) void {
    debug_trace.logf("attached_api", "{s} failed err={s}", .{ stage, @errorName(err) });
}

test "attached control command accepts versioned prompts" {
    const parsed = try std.json.parseFromSlice(
        Command,
        std.testing.allocator,
        "{\"version\":1,\"id\":7,\"type\":\"session.prompt\",\"prompt\":\"hello\"}",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 7), parsed.value.id);
    try std.testing.expectEqualStrings("session.prompt", parsed.value.type);
    try std.testing.expectEqualStrings("hello", parsed.value.prompt.?);
}
