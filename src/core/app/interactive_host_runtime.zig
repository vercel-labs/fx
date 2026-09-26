const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const approval_ui = @import("../../ui/footer/approval_ui.zig");
const model_projection = @import("interactive_model_projection.zig");

const max_frame_bytes = 1024 * 1024;

pub const Runtime = struct {
    initialized: bool = false,
    fd: ?std.posix.fd_t = null,
    input: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    snapshot_hash: ?u64 = null,
    revision: u64 = 0,
    enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    source_lock: std.Io.Mutex = .init,
    source: std.ArrayList(u8) = .empty,
    current_user: std.ArrayList(u8) = .empty,
    source_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    published_source_generation: u64 = 0,
    history_json: std.ArrayList(u8) = .empty,
    scratch: []u8 = &.{},
    history_count: ?usize = null,
    compaction_count: usize = 0,
    source_truncated: bool = false,
    history_truncated: bool = false,

    pub fn beginPrompt(self: *Runtime, alloc: std.mem.Allocator, text: []const u8) !void {
        if (comptime builtin.os.tag == .wasi) return;
        if (!self.enabled.load(.acquire)) return;
        self.source_lock.lockUncancelable(io_mod.getIo());
        defer self.source_lock.unlock(io_mod.getIo());
        self.source.clearRetainingCapacity();
        self.source_truncated = false;
        _ = self.source_generation.fetchAdd(1, .release);
        self.current_user.clearRetainingCapacity();
        try self.current_user.appendSlice(alloc, text);
    }

    pub fn appendSource(self: *Runtime, alloc: std.mem.Allocator, text: []const u8) !void {
        if (comptime builtin.os.tag == .wasi) return;
        if (!self.enabled.load(.acquire)) return;
        self.source_lock.lockUncancelable(io_mod.getIo());
        defer self.source_lock.unlock(io_mod.getIo());
        if (self.source.items.len + text.len > 64 * 1024) {
            self.source_truncated = true;
            return;
        }
        try self.source.appendSlice(alloc, text);
        _ = self.source_generation.fetchAdd(1, .release);
    }

    pub fn deinit(self: *Runtime, alloc: std.mem.Allocator) void {
        if (self.fd) |fd| _ = std.c.close(fd);
        self.input.deinit(alloc);
        self.output.deinit(alloc);
        self.source.deinit(alloc);
        self.current_user.deinit(alloc);
        self.history_json.deinit(alloc);
        if (self.scratch.len != 0) alloc.free(self.scratch);
    }

    fn initialize(self: *Runtime) void {
        if (self.initialized) return;
        self.initialized = true;
        if (comptime builtin.os.tag == .wasi) return;
        const value = io_mod.getenv("FX_INTERACTION_FD") orelse return;
        const fd = std.fmt.parseInt(std.posix.fd_t, value, 10) catch return;
        if (fd < 3) return;
        if (std.c.fcntl(fd, std.c.F.SETFD, @as(usize, std.c.FD_CLOEXEC)) < 0) return;
        self.fd = fd;
        self.enabled.store(true, .release);
    }

    fn disconnect(self: *Runtime) void {
        self.enabled.store(false, .release);
        if (self.fd) |fd| _ = std.c.close(fd);
        self.fd = null;
    }

    fn flush(self: *Runtime) void {
        const fd = self.fd orelse return;
        while (self.sent < self.output.items.len) {
            const remaining = self.output.items[self.sent..];
            const count = std.c.send(fd, remaining.ptr, remaining.len, std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL);
            if (count < 0) {
                if (std.posix.errno(count) == .INTR) continue;
                if (std.posix.errno(count) != .AGAIN) self.disconnect();
                return;
            }
            if (count == 0) return;
            self.sent += @intCast(count);
        }
        self.output.clearRetainingCapacity();
        self.sent = 0;
    }

    pub fn collect(self: *Runtime, comptime App: type, app: *App) !void {
        if (comptime builtin.os.tag == .wasi) return;
        self.initialize();
        const fd = self.fd orelse return;
        var buffer: [8192]u8 = undefined;
        for (0..16) |_| {
            const count = std.c.recv(fd, &buffer, buffer.len, std.posix.MSG.DONTWAIT);
            if (count < 0) {
                if (std.posix.errno(count) == .INTR) continue;
                if (std.posix.errno(count) != .AGAIN) self.disconnect();
                break;
            }
            if (count == 0) {
                self.disconnect();
                break;
            }
            if (self.input.items.len + @as(usize, @intCast(count)) > max_frame_bytes) {
                self.disconnect();
                return;
            }
            try self.input.appendSlice(app.alloc, buffer[0..@intCast(count)]);
            while (std.mem.findScalar(u8, self.input.items, '\n')) |end| {
                try dispatch(self, App, app, self.input.items[0..end]);
                const remaining = self.input.items.len - end - 1;
                std.mem.copyForwards(u8, self.input.items[0..remaining], self.input.items[end + 1 ..]);
                self.input.items.len = remaining;
            }
        }
        self.flush();
    }

    pub fn publish(self: *Runtime, comptime App: type, app: *App, changed: bool) !void {
        self.publishInner(App, app, changed) catch |err| {
            if (err != error.WriteFailed) return err;
            self.output.clearRetainingCapacity();
            self.sent = 0;
            self.revision +%= 1;
            const fallback = try std.fmt.allocPrint(app.alloc, "{{\"type\":\"snapshot\",\"version\":1,\"revision\":{d},\"composer\":{{\"text\":\"\",\"cursor\":0,\"protected\":false}},\"model\":{{\"active\":false}},\"commands\":[],\"transcript\":[],\"permission\":null,\"busy\":false,\"transcript_truncated\":true,\"unsupported_screen\":\"display_limit\"}}\n", .{self.revision});
            defer app.alloc.free(fallback);
            try self.output.appendSlice(app.alloc, fallback);
            self.flush();
        };
    }

    fn publishInner(self: *Runtime, comptime App: type, app: *App, changed: bool) !void {
        if (comptime builtin.os.tag == .wasi) return;
        self.initialize();
        if (self.fd == null) return;
        self.flush();
        if (self.output.items.len != 0) return;
        const source_generation = self.source_generation.load(.acquire);
        const history_changed = self.history_count != app.session.historyLen() or self.compaction_count != app.session.compactionCount();
        if (!changed and !history_changed and self.snapshot_hash != null and source_generation == self.published_source_generation) return;
        self.published_source_generation = source_generation;
        if (history_changed) {
            var history_output = std.Io.Writer.Allocating.init(app.alloc);
            defer history_output.deinit();
            var first_history = true;
            const history = app.session.agent.history.items;
            const start = historyStart(history);
            self.history_truncated = start != 0;
            for (history[start..]) |turn| {
                switch (turn) {
                    .assistant => |entry| {
                        self.history_truncated = self.history_truncated or entry.user.text.len > 8192 or entry.assistant.len > 8192;
                        try writeMessage(&history_output.writer, &first_history, "user", boundedText(entry.user.text));
                        try writeMessage(&history_output.writer, &first_history, "assistant", boundedText(entry.assistant));
                    },
                    .interrupted => |entry| {
                        self.history_truncated = self.history_truncated or entry.user.text.len > 8192;
                        try writeMessage(&history_output.writer, &first_history, "user", boundedText(entry.user.text));
                        if (entry.assistant) |text| {
                            self.history_truncated = self.history_truncated or text.len > 8192;
                            try writeMessage(&history_output.writer, &first_history, "assistant", boundedText(text));
                        }
                    },
                    .compacted_summary => {},
                }
            }
            self.history_json.clearRetainingCapacity();
            try self.history_json.appendSlice(app.alloc, history_output.written());
            self.history_count = history.len;
            self.compaction_count = app.session.compactionCount();
        }
        if (self.scratch.len == 0) self.scratch = try app.alloc.alloc(u8, max_frame_bytes);
        var output = FixedOutput{ .writer = .fixed(self.scratch) };
        try output.writer.writeAll("{\"type\":\"snapshot\",\"version\":1,\"composer\":");
        const protected_input = app.auth.apiKeyEntryActive();
        try std.json.Stringify.value(.{
            .text = if (protected_input) "" else app.input_runtime.edit_state.input.items,
            .cursor = if (protected_input) @as(usize, 0) else app.input_runtime.edit_state.cursor,
            .protected = protected_input,
        }, .{}, &output.writer);
        try output.writer.writeAll(",\"model\":");
        var buffer: model_projection.Buffer = .{};
        try model_projection.writeJson(model_projection.project(App, app, &buffer), &output.writer);
        try output.writer.writeAll(",\"commands\":");
        try model_projection.writeCommandsJson(app.slashRegistry(), &output.writer);
        try output.writer.writeAll(",\"permission\":");
        if (app.approval_prompt.projection()) |approval| {
            try output.writer.writeAll("{\"id\":");
            try std.json.Stringify.value(approval.request.id, .{}, &output.writer);
            try output.writer.writeAll(",\"label\":");
            try std.json.Stringify.value(boundedText(approval.request.label), .{}, &output.writer);
            try output.writer.writeAll(",\"explanation\":");
            try std.json.Stringify.value(if (approval.request.explanation) |text| boundedText(text) else null, .{}, &output.writer);
            try output.writer.writeAll(",\"truncated\":");
            try std.json.Stringify.value(permissionDisplayTruncated(approval.request), .{}, &output.writer);
            try output.writer.writeAll(",\"request\":");
            var request = approval.request;
            request.label = boundedText(request.label);
            if (request.command) |text| request.command = boundedText(text);
            if (request.explanation) |text| request.explanation = boundedText(text);
            if (request.tool_arguments_preview) |text| request.tool_arguments_preview = boundedText(text);
            try std.json.Stringify.value(request, .{}, &output.writer);
            try output.writer.writeAll(",\"choices\":[");
            const count: u8 = if (approval.request.confirmation_only) 2 else 3;
            for (0..count) |index| {
                if (index != 0) try output.writer.writeByte(',');
                try std.json.Stringify.value(.{ .id = index + 1, .label = approval_ui.approvalChoiceLabel(approval, @intCast(index)) }, .{}, &output.writer);
            }
            try output.writer.writeAll("]}");
        } else try output.writer.writeAll("null");
        try output.writer.writeAll(",\"busy\":");
        try std.json.Stringify.value(app.stream.active, .{}, &output.writer);
        try output.writer.writeAll(",\"transcript\":[");
        try output.writer.writeAll(self.history_json.items);
        var first = self.history_json.items.len == 0;
        if (app.stream.active) {
            self.source_lock.lockUncancelable(io_mod.getIo());
            defer self.source_lock.unlock(io_mod.getIo());
            if (self.current_user.items.len != 0) try writeMessage(&output.writer, &first, "user", boundedText(self.current_user.items));
            if (self.source.items.len != 0) try writeMessage(&output.writer, &first, "assistant", self.source.items);
        }
        try output.writer.writeAll("],\"transcript_truncated\":");
        self.source_lock.lockUncancelable(io_mod.getIo());
        const source_truncated = self.source_truncated or self.current_user.items.len > 8192;
        self.source_lock.unlock(io_mod.getIo());
        try std.json.Stringify.value(self.history_truncated or source_truncated, .{}, &output.writer);
        try output.writer.writeAll(",\"unsupported_screen\":");
        const unsupported: ?[]const u8 = if (app.question_prompt.isActive()) "question" else if (app.auth.apiKeyEntryActive()) "authentication" else if (app.input_runtime.picker.activeProviderPickerQuery(&app.input_runtime.edit_state) != null) "provider" else if (app.input_runtime.help_menu.active) "help" else if (app.input_runtime.settings_menu.active) "settings" else if (app.mcp.menu.active) "mcp" else if (app.model_cache.menu.active) "model_catalog" else if (app.session_persistence.session_picker.active) "sessions" else if (app.skills.menuVisible()) "skills" else if (app.input_runtime.usage_menu.active) "usage" else if (app.input_runtime.workspace_menu.active) "workspace" else if (app.input_runtime.statusline_menu.active) "statusline" else null;
        try std.json.Stringify.value(unsupported, .{}, &output.writer);
        try output.writer.writeAll(",\"notices\":[");
        var first_notice = true;
        const entries = app.shell.entries.items;
        for (entries[entries.len -| 32..]) |entry| {
            if (entry == .semantic_notice) {
                const notice = entry.semantic_notice;
                if (!first_notice) try output.writer.writeByte(',');
                first_notice = false;
                try std.json.Stringify.value(.{ .id = notice.id, .topic = notice.topic, .body = boundedTextLimit(notice.body, 1024), .truncated = notice.body.len > 1024, .tone = notice.tone }, .{}, &output.writer);
            }
        }
        try output.writer.writeByte(']');
        if (output.written().len > max_frame_bytes - 64) return error.WriteFailed;
        const hash = std.hash.Wyhash.hash(0, output.written());
        if (self.snapshot_hash == hash) return;
        self.revision +%= 1;
        try output.writer.print(",\"revision\":{d}}}\n", .{self.revision});
        try self.output.appendSlice(app.alloc, output.written());
        self.snapshot_hash = hash;
        self.flush();
    }
};

fn dispatch(host: *Runtime, comptime App: type, app: *App, bytes: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, app.alloc, bytes, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const object = parsed.value.object;
    const kind = object.get("type") orelse return;
    if (kind != .string) return;
    if (std.mem.eql(u8, kind.string, "dismiss")) {
        try App.loopHandleByte(app, 27);
        return;
    }
    if (std.mem.eql(u8, kind.string, "cancel")) {
        try App.loopHandleByte(app, 3);
        return;
    }
    if (std.mem.eql(u8, kind.string, "permission")) {
        const request = app.approval_prompt.request orelse return;
        const id = object.get("id") orelse return;
        const choice = object.get("choice") orelse return;
        if (id != .integer or id.integer < 0 or id.integer != request.id) return;
        const max_choice: i64 = if (request.confirmation_only) 2 else 3;
        if (choice != .integer or choice.integer < 1 or choice.integer > max_choice) return;
        try App.loopHandleByte(app, @intCast('0' + choice.integer));
        return;
    }
    if (app.auth.apiKeyEntryActive() or app.approval_prompt.isActive() or app.question_prompt.isActive()) return;
    if (std.mem.eql(u8, kind.string, "input")) {
        const text = object.get("text") orelse return;
        if (text != .string or text.string.len > 64 * 1024) return;
        try app.input_runtime.textReplacementState().replace(app.alloc, text.string);
        app.input_runtime.picker.reconcileInlinePickerAfterEdit(&app.input_runtime.edit_state);
        app.shell.render_requests.request(.footer);
    } else if (std.mem.eql(u8, kind.string, "submit")) {
        try App.loopHandleByte(app, '\r');
    } else if (std.mem.eql(u8, kind.string, "model")) {
        const revision = object.get("revision") orelse return;
        if (revision != .integer or revision.integer < 0 or revision.integer != host.revision) return;
        const action = object.get("action") orelse return;
        if (action != .string) return;
        const tag = std.meta.stringToEnum(std.meta.Tag(model_projection.Action), action.string) orelse return;
        const intent: model_projection.Action = switch (tag) {
            .open => .open,
            .accept => .accept,
            .back => .back,
            .dismiss => .dismiss,
            .move => blk: {
                const delta = object.get("delta") orelse return;
                if (delta != .integer) return;
                break :blk .{ .move = std.math.cast(i32, delta.integer) orelse return };
            },
        };
        if (intent == .accept) {
            if (object.get("index")) |index| {
                var buffer: model_projection.Buffer = .{};
                const snapshot = model_projection.project(App, app, &buffer);
                if (index != .integer or index.integer < 0 or index.integer >= snapshot.items.len) return;
                const delta = index.integer - @as(i64, @intCast(snapshot.selected_index));
                _ = try model_projection.apply(App, app, .{ .move = std.math.cast(i32, delta) orelse return });
            }
        }
        _ = try model_projection.apply(App, app, intent);
    }
}

fn writeMessage(writer: *std.Io.Writer, first: *bool, role: []const u8, text: []const u8) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try std.json.Stringify.value(.{ .role = role, .text = text }, .{}, writer);
}

fn boundedText(text: []const u8) []const u8 {
    return boundedTextLimit(text, 8192);
}

fn boundedTextLimit(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end: usize = limit;
    while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}

test "interactive source capture is opt in and keeps raw markdown" {
    var runtime: Runtime = .{};
    defer runtime.deinit(std.testing.allocator);
    try runtime.appendSource(std.testing.allocator, "ignored");
    try std.testing.expectEqual(@as(usize, 0), runtime.source.items.len);
    runtime.enabled.store(true, .release);
    try runtime.beginPrompt(std.testing.allocator, "hello");
    try runtime.appendSource(std.testing.allocator, "**hello**\n");
    try runtime.appendSource(std.testing.allocator, "`code`");
    try std.testing.expectEqualStrings("**hello**\n`code`", runtime.source.items);
    try runtime.beginPrompt(std.testing.allocator, "next");
    try std.testing.expectEqual(@as(usize, 0), runtime.source.items.len);
    try std.testing.expectEqualStrings("next", runtime.current_user.items);
}

test "interactive bounded history preserves utf8 boundaries" {
    var text: [8196]u8 = @splat('a');
    @memcpy(text[8191..8195], "\xf0\x9f\x98\x80");
    try std.testing.expectEqual(@as(usize, 8191), boundedText(&text).len);
}

const FixedOutput = struct {
    writer: std.Io.Writer,

    fn written(self: *FixedOutput) []u8 {
        return self.writer.buffered();
    }
};

fn historyStart(history: []const @import("../shared/types.zig").HistoryTurn) usize {
    var start = history.len;
    var bytes: usize = 0;
    while (start > 0 and history.len - start < 32) {
        const estimate: usize = switch (history[start - 1]) {
            .assistant => |entry| 128 + 6 * (boundedText(entry.user.text).len + boundedText(entry.assistant).len),
            .interrupted => |entry| 128 + 6 * (boundedText(entry.user.text).len + if (entry.assistant) |text| boundedText(text).len else @as(usize, 0)),
            .compacted_summary => 0,
        };
        if (bytes + estimate > 128 * 1024) break;
        bytes += estimate;
        start -= 1;
    }
    return start;
}

test "interactive history budget retains recent bounded turns" {
    const types = @import("../shared/types.zig");
    var text: [8192]u8 = @splat('x');
    const turn: types.HistoryTurn = .{ .assistant = .{ .user = .{ .text = &text }, .assistant = &text } };
    const history = [_]types.HistoryTurn{turn} ** 32;
    try std.testing.expectEqual(@as(usize, 31), historyStart(&history));
}

pub fn secureInherited() !void {
    if (comptime builtin.os.tag == .wasi) return;
    const value = io_mod.getenv("FX_INTERACTION_FD") orelse return;
    const fd = std.fmt.parseInt(std.posix.fd_t, value, 10) catch return;
    if (fd < 3) return;
    if (std.c.fcntl(fd, std.c.F.SETFD, @as(usize, std.c.FD_CLOEXEC)) < 0) return error.InteractionDescriptorUnavailable;
}

fn permissionDisplayTruncated(request: @import("../permissions/permission_request.zig").PermissionRequest) bool {
    if (request.label.len > 8192) return true;
    if (request.command) |text| if (text.len > 8192) return true;
    if (request.explanation) |text| if (text.len > 8192) return true;
    if (request.tool_arguments_preview) |text| if (text.len > 8192) return true;
    return false;
}

test "interactive permission display marks every clipped field" {
    const text: [8193]u8 = @splat('x');
    try std.testing.expect(!permissionDisplayTruncated(.{ .label = text[0..8192] }));
    try std.testing.expect(permissionDisplayTruncated(.{ .label = &text }));
    try std.testing.expect(permissionDisplayTruncated(.{ .label = "request", .command = &text }));
    try std.testing.expect(permissionDisplayTruncated(.{ .label = "request", .explanation = &text }));
    try std.testing.expect(permissionDisplayTruncated(.{ .label = "request", .tool_arguments_preview = &text }));
}
