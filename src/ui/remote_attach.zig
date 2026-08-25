const std = @import("std");
const contracts = @import("../core/remote/contracts.zig");
const endpoint_mod = @import("../core/remote/endpoint.zig");
const app_lifecycle = @import("../core/app/app_lifecycle.zig");
const jsonrpc = @import("../acp/jsonrpc.zig");
const display_width = @import("../core/shared/display_width.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const input_presentation = @import("footer/input_presentation.zig");
const shell_runtime = @import("shell_runtime.zig");
const transcript_blocks = @import("render_engine/transcript_blocks.zig");
const ui_render = @import("render.zig");
const user_message_card = @import("assistant/user_message_card.zig");
const visual_layout = @import("input/visual_layout.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    endpoint: []const u8,
    session_id: []const u8,
    observe: bool = false,
    primary: bool = false,
};

const Wire = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque, Allocator) anyerror!?[]u8,
    write_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    interrupt_fn: *const fn (*anyopaque) void,
    close_fn: *const fn (*anyopaque) void,

    fn read(self: Wire, alloc: Allocator) !?[]u8 {
        return self.read_fn(self.context, alloc);
    }

    fn write(self: Wire, bytes: []const u8) !void {
        return self.write_fn(self.context, bytes);
    }

    fn interrupt(self: Wire) void {
        self.interrupt_fn(self.context);
    }

    fn close(self: Wire) void {
        self.close_fn(self.context);
    }
};

const UnixClientWire = struct {
    stream: std.Io.net.Stream,
    read_buffer: [64 * 1024]u8 = undefined,
    write_buffer: [64 * 1024]u8 = undefined,
    reader: std.Io.net.Stream.Reader = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    write_mutex: std.Io.Mutex = .init,
    closed: std.atomic.Value(bool) = .init(false),

    fn init(self: *UnixClientWire, stream: std.Io.net.Stream) void {
        self.* = .{ .stream = stream };
        self.reader = stream.reader(io_mod.getIo(), &self.read_buffer);
        self.writer = stream.writer(io_mod.getIo(), &self.write_buffer);
    }

    fn wire(self: *UnixClientWire) Wire {
        return .{ .context = self, .read_fn = read, .write_fn = write, .interrupt_fn = interrupt, .close_fn = close };
    }

    fn read(raw: *anyopaque, alloc: Allocator) !?[]u8 {
        const self: *UnixClientWire = @ptrCast(@alignCast(raw));
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(alloc);
        while (true) {
            const byte = self.reader.interface.takeByte() catch |err| switch (err) {
                error.EndOfStream, error.ReadFailed => return if (line.items.len == 0) null else error.TruncatedFrame,
            };
            if (byte == '\n') {
                if (line.items.len == 0) continue;
                return try line.toOwnedSlice(alloc);
            }
            if (line.items.len >= contracts.max_frame_bytes) return error.FrameTooLarge;
            try line.append(alloc, byte);
        }
    }

    fn write(raw: *anyopaque, message: []const u8) !void {
        const self: *UnixClientWire = @ptrCast(@alignCast(raw));
        const io = io_mod.getIo();
        self.write_mutex.lockUncancelable(io);
        defer self.write_mutex.unlock(io);
        try self.writer.interface.writeAll(message);
        try self.writer.interface.writeByte('\n');
        try self.writer.interface.flush();
    }

    fn interrupt(raw: *anyopaque) void {
        const self: *UnixClientWire = @ptrCast(@alignCast(raw));
        self.stream.shutdown(io_mod.getIo(), .both) catch {};
    }

    fn close(raw: *anyopaque) void {
        const self: *UnixClientWire = @ptrCast(@alignCast(raw));
        if (self.closed.swap(true, .acq_rel)) return;
        self.stream.shutdown(io_mod.getIo(), .both) catch {};
        self.stream.close(io_mod.getIo());
    }
};

fn validClosePayload(payload: []const u8) bool {
    if (payload.len == 0) return true;
    if (payload.len == 1) return false;
    const code = std.mem.readInt(u16, payload[0..2], .big);
    const valid_code = (code >= 1000 and code <= 1014 and code != 1004 and code != 1005 and
        code != 1006) or (code >= 3000 and code <= 4999);
    return valid_code and std.unicode.utf8ValidateSlice(payload[2..]);
}

const WebSocketClientWire = struct {
    alloc: Allocator,
    http_client: std.http.Client,
    connection: ?*std.http.Client.Connection = null,
    write_mutex: std.Io.Mutex = .init,
    closed: std.atomic.Value(bool) = .init(false),

    fn connect(alloc: Allocator, endpoint: @FieldType(endpoint_mod.Endpoint, "websocket")) !*WebSocketClientWire {
        const self = try alloc.create(WebSocketClientWire);
        self.* = .{
            .alloc = alloc,
            .http_client = .{ .allocator = alloc, .io = io_mod.getIo() },
        };
        errdefer {
            self.http_client.deinit();
            alloc.destroy(self);
        }
        const uri_text = try std.fmt.allocPrint(
            alloc,
            "{s}://{s}:{d}{s}",
            .{ if (endpoint.secure) "https" else "http", endpoint.host, endpoint.port, endpoint.path },
        );
        defer alloc.free(uri_text);
        const uri = try std.Uri.parse(uri_text);
        var entropy: [16]u8 = undefined;
        try io_mod.getIo().randomSecure(&entropy);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &entropy);
        const extra_headers = [_]std.http.Header{
            .{ .name = "upgrade", .value = "websocket" },
            .{ .name = "sec-websocket-key", .value = &key },
            .{ .name = "sec-websocket-version", .value = "13" },
        };
        var request = try self.http_client.request(.GET, uri, .{
            .keep_alive = true,
            .redirect_behavior = .not_allowed,
            .headers = .{
                .connection = .{ .override = "Upgrade" },
                .accept_encoding = .omit,
            },
            .extra_headers = &extra_headers,
        });
        errdefer request.deinit();
        try request.sendBodiless();
        var redirect_buffer: [1]u8 = undefined;
        const response = try request.receiveHead(&redirect_buffer);
        if (response.head.status != .switching_protocols) return error.WebSocketUpgradeRejected;
        var accept_value: ?[]const u8 = null;
        var accept_count: usize = 0;
        var connection_count: usize = 0;
        var connection_ok = false;
        var upgrade_count: usize = 0;
        var upgrade_ok = false;
        var headers = response.head.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-accept")) {
                accept_count += 1;
                accept_value = header.value;
            } else if (std.ascii.eqlIgnoreCase(header.name, "connection")) {
                connection_count += 1;
                connection_ok = std.ascii.eqlIgnoreCase(std.mem.trim(u8, header.value, " \t"), "upgrade");
            } else if (std.ascii.eqlIgnoreCase(header.name, "upgrade")) {
                upgrade_count += 1;
                upgrade_ok = std.ascii.eqlIgnoreCase(std.mem.trim(u8, header.value, " \t"), "websocket");
            }
        }
        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(&key);
        sha1.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        sha1.final(&digest);
        var expected: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&expected, &digest);
        if (accept_count != 1 or accept_value == null or !std.mem.eql(u8, accept_value.?, &expected) or
            connection_count != 1 or !connection_ok or upgrade_count != 1 or !upgrade_ok)
            return error.InvalidWebSocketAccept;
        self.connection = request.connection.?;
        request.connection = null;
        request.deinit();
        return self;
    }

    fn destroy(self: *WebSocketClientWire) void {
        self.closeImpl();
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    fn wire(self: *WebSocketClientWire) Wire {
        return .{ .context = self, .read_fn = read, .write_fn = write, .interrupt_fn = interrupt, .close_fn = close };
    }

    fn read(raw: *anyopaque, alloc: Allocator) !?[]u8 {
        const self: *WebSocketClientWire = @ptrCast(@alignCast(raw));
        const connection = self.connection orelse return null;
        const reader = connection.reader();
        while (true) {
            const first = reader.takeByte() catch return null;
            const second = reader.takeByte() catch return null;
            const fin = first & 0x80 != 0;
            const opcode = first & 0x0f;
            const control = opcode >= 8;
            if (!fin or first & 0x70 != 0 or second & 0x80 != 0 or
                (opcode != 1 and opcode != 8 and opcode != 9 and opcode != 10))
                return error.InvalidWebSocketFrame;
            var length: usize = second & 0x7f;
            if (length == 126) {
                length = try reader.takeInt(u16, .big);
                if (length < 126) return error.InvalidWebSocketFrame;
            } else if (length == 127) {
                const wide = try reader.takeInt(u64, .big);
                if (wide <= std.math.maxInt(u16) or wide & (@as(u64, 1) << 63) != 0) return error.InvalidWebSocketFrame;
                length = std.math.cast(usize, wide) orelse return error.FrameTooLarge;
            }
            if ((control and length > 125) or length > contracts.max_frame_bytes) return error.FrameTooLarge;
            const payload = try alloc.alloc(u8, length);
            reader.readSliceAll(payload) catch {
                alloc.free(payload);
                return error.TruncatedFrame;
            };
            if (opcode == 8) {
                const valid = validClosePayload(payload);
                alloc.free(payload);
                if (!valid) return error.InvalidWebSocketFrame;
                return null;
            }
            if (opcode == 9) {
                self.writeFrame(payload, 10) catch |err| {
                    alloc.free(payload);
                    return err;
                };
                alloc.free(payload);
                continue;
            }
            if (opcode == 10) {
                alloc.free(payload);
                continue;
            }
            if (!std.unicode.utf8ValidateSlice(payload)) {
                alloc.free(payload);
                return error.InvalidWebSocketFrame;
            }
            return payload;
        }
    }

    fn write(raw: *anyopaque, message: []const u8) !void {
        const self: *WebSocketClientWire = @ptrCast(@alignCast(raw));
        try self.writeFrame(message, 1);
    }

    fn writeFrame(self: *WebSocketClientWire, message: []const u8, opcode: u8) !void {
        if (message.len > contracts.max_frame_bytes or (opcode >= 8 and message.len > 125)) return error.FrameTooLarge;
        if (opcode == 1 and !std.unicode.utf8ValidateSlice(message)) return error.InvalidUtf8;
        const connection = self.connection orelse return error.ConnectionClosed;
        const io = io_mod.getIo();
        self.write_mutex.lockUncancelable(io);
        defer self.write_mutex.unlock(io);
        const writer = connection.writer();
        try writer.writeByte(0x80 | opcode);
        if (message.len <= 125) {
            try writer.writeByte(0x80 | @as(u8, @intCast(message.len)));
        } else if (message.len <= std.math.maxInt(u16)) {
            try writer.writeByte(0x80 | 126);
            try writer.writeInt(u16, @intCast(message.len), .big);
        } else {
            try writer.writeByte(0x80 | 127);
            try writer.writeInt(u64, message.len, .big);
        }
        var mask_bytes: [4]u8 = undefined;
        try io.randomSecure(&mask_bytes);
        try writer.writeAll(&mask_bytes);
        const masked = try self.alloc.dupe(u8, message);
        defer self.alloc.free(masked);
        for (masked, 0..) |*byte, index| byte.* ^= mask_bytes[index % 4];
        try writer.writeAll(masked);
        try writer.flush();
    }

    fn interrupt(raw: *anyopaque) void {
        const self: *WebSocketClientWire = @ptrCast(@alignCast(raw));
        if (self.connection) |connection| {
            connection.stream_reader.stream.shutdown(io_mod.getIo(), .both) catch {};
        }
    }

    fn close(raw: *anyopaque) void {
        const self: *WebSocketClientWire = @ptrCast(@alignCast(raw));
        self.closeImpl();
    }

    fn closeImpl(self: *WebSocketClientWire) void {
        if (self.closed.swap(true, .acq_rel)) return;
        if (self.connection) |connection| {
            connection.closing = true;
            self.http_client.connection_pool.release(connection, io_mod.getIo());
            self.connection = null;
        }
        self.http_client.deinit();
    }
};

const OperationSummary = struct {
    id: []u8,
    state: []u8,
    detail: ?[]u8 = null,

    fn deinit(self: *OperationSummary, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.state);
        if (self.detail) |detail| alloc.free(detail);
        self.* = undefined;
    }
};

const RemoteProjection = struct {
    alloc: Allocator,
    session_id: []u8 = &.{},
    revision: u64 = 0,
    run_state: []u8 = &.{},
    model: ?[]u8 = null,
    mode: ?[]u8 = null,
    history: std.ArrayList(contracts.HistoryItem) = .empty,
    assistant_partial: std.ArrayList(u8) = .empty,
    tools: std.ArrayList(contracts.ToolRecord) = .empty,
    pending: ?contracts.PendingInteraction = null,
    operations: std.ArrayList(OperationSummary) = .empty,
    last_error: ?[]u8 = null,
    retained_bytes: usize = 0,

    fn init(alloc: Allocator) RemoteProjection {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *RemoteProjection) void {
        self.clear();
        self.history.deinit(self.alloc);
        self.assistant_partial.deinit(self.alloc);
        self.tools.deinit(self.alloc);
        self.operations.deinit(self.alloc);
        self.* = undefined;
    }

    fn clear(self: *RemoteProjection) void {
        if (self.session_id.len > 0) self.alloc.free(self.session_id);
        self.session_id = &.{};
        if (self.run_state.len > 0) self.alloc.free(self.run_state);
        self.run_state = &.{};
        if (self.model) |value| self.alloc.free(value);
        self.model = null;
        if (self.mode) |value| self.alloc.free(value);
        self.mode = null;
        for (self.history.items) |*item| item.deinit(self.alloc);
        self.history.clearRetainingCapacity();
        self.assistant_partial.clearRetainingCapacity();
        for (self.tools.items) |*tool| tool.deinit(self.alloc);
        self.tools.clearRetainingCapacity();
        if (self.pending) |*pending| pending.deinit(self.alloc);
        self.pending = null;
        for (self.operations.items) |*operation| operation.deinit(self.alloc);
        self.operations.clearRetainingCapacity();
        if (self.last_error) |value| self.alloc.free(value);
        self.last_error = null;
        self.retained_bytes = 0;
        self.revision = 0;
    }

    fn ensureRetainedBytes(self: *const RemoteProjection, removed: usize, added: usize) !void {
        const base = self.retained_bytes -| removed;
        if (added > contracts.max_snapshot_bytes -| base) return error.RemoteProjectionCapacityExceeded;
    }

    fn commitRetainedBytes(self: *RemoteProjection, removed: usize, added: usize) void {
        self.retained_bytes = self.retained_bytes -| removed +| added;
    }

    fn replaceString(self: *RemoteProjection, target: *[]u8, value: []const u8) !void {
        const replacement = try contracts.sanitizeSemanticAlloc(self.alloc, value);
        errdefer self.alloc.free(replacement);
        try self.ensureRetainedBytes(target.len, replacement.len);
        const old_len = target.len;
        if (old_len > 0) self.alloc.free(target.*);
        target.* = replacement;
        self.commitRetainedBytes(old_len, replacement.len);
    }

    fn replaceOptional(self: *RemoteProjection, target: *?[]u8, value: ?[]const u8) !void {
        const replacement = if (value) |text| try contracts.sanitizeSemanticAlloc(self.alloc, text) else null;
        errdefer if (replacement) |owned| self.alloc.free(owned);
        const old_len = if (target.*) |old| old.len else 0;
        const new_len = if (replacement) |owned| owned.len else 0;
        try self.ensureRetainedBytes(old_len, new_len);
        if (target.*) |old| self.alloc.free(old);
        target.* = replacement;
        self.commitRetainedBytes(old_len, new_len);
    }

    fn installSnapshot(self: *RemoteProjection, snapshot: std.json.Value) !void {
        if (snapshot != .object) return error.InvalidAttachResponse;
        self.clear();
        errdefer self.clear();
        const session_id = stringField(snapshot, "sessionId") orelse return error.InvalidAttachResponse;
        const state = stringField(snapshot, "runState") orelse return error.InvalidAttachResponse;
        const revision = snapshot.object.get("revision") orelse return error.InvalidAttachResponse;
        if (revision != .integer or revision.integer < 0) return error.InvalidAttachResponse;
        self.session_id = try contracts.sanitizeSemanticAlloc(self.alloc, session_id);
        try self.ensureRetainedBytes(0, self.session_id.len);
        self.commitRetainedBytes(0, self.session_id.len);
        self.run_state = try contracts.sanitizeSemanticAlloc(self.alloc, state);
        try self.ensureRetainedBytes(0, self.run_state.len);
        self.commitRetainedBytes(0, self.run_state.len);
        self.revision = @intCast(revision.integer);

        const history = snapshot.object.get("history") orelse return error.InvalidAttachResponse;
        if (history != .array) return error.InvalidAttachResponse;
        for (history.array.items) |item| {
            if (item != .object) return error.InvalidAttachResponse;
            const role_text = stringField(item, "role") orelse return error.InvalidAttachResponse;
            const text = stringField(item, "text") orelse return error.InvalidAttachResponse;
            const role = std.meta.stringToEnum(contracts.HistoryRole, role_text) orelse return error.InvalidAttachResponse;
            const owned = try contracts.sanitizeSemanticAlloc(self.alloc, text);
            errdefer self.alloc.free(owned);
            try self.ensureRetainedBytes(0, owned.len);
            try self.history.append(self.alloc, .{ .role = role, .text = owned });
            self.commitRetainedBytes(0, owned.len);
        }
        if (stringField(snapshot, "assistantPartial")) |partial| {
            const safe = try contracts.sanitizeSemanticAlloc(self.alloc, partial);
            defer self.alloc.free(safe);
            try self.ensureRetainedBytes(0, safe.len);
            try self.assistant_partial.appendSlice(self.alloc, safe);
            self.commitRetainedBytes(0, safe.len);
        }
        if (snapshot.object.get("tools")) |tools| {
            if (tools != .array) return error.InvalidAttachResponse;
            for (tools.array.items) |tool| try self.appendTool(tool);
        }
        if (snapshot.object.get("configuration")) |configuration| {
            if (configuration != .object) return error.InvalidAttachResponse;
            try self.replaceOptional(&self.model, stringField(configuration, "model"));
            try self.replaceOptional(&self.mode, stringField(configuration, "mode"));
        }
        if (snapshot.object.get("pendingInteraction")) |pending| {
            if (pending != .null) try self.installPending(pending);
        }
        if (snapshot.object.get("operations")) |operations| {
            if (operations != .array) return error.InvalidAttachResponse;
            for (operations.array.items) |operation| try self.upsertOperation(operation, .hydrate);
        }
    }

    fn appendTool(self: *RemoteProjection, tool: std.json.Value) !void {
        if (tool != .object) return error.InvalidSemanticEvent;
        if (self.tools.items.len >= contracts.max_tools_per_actor) return error.ToolProjectionCapacityExceeded;
        const id = stringField(tool, "id") orelse stringField(tool, "toolCallId") orelse return error.InvalidSemanticEvent;
        const title = stringField(tool, "title") orelse "Tool call";
        const kind = stringField(tool, "kind") orelse "other";
        const status = stringField(tool, "status") orelse "pending";
        const owned_id = try contracts.sanitizeSemanticAlloc(self.alloc, id);
        errdefer self.alloc.free(owned_id);
        const owned_title = try contracts.sanitizeSemanticAlloc(self.alloc, title);
        errdefer self.alloc.free(owned_title);
        const owned_kind = try contracts.sanitizeSemanticAlloc(self.alloc, kind);
        errdefer self.alloc.free(owned_kind);
        const owned_status = try contracts.sanitizeSemanticAlloc(self.alloc, status);
        errdefer self.alloc.free(owned_status);
        const progress = if (stringField(tool, "progress")) |value| try contracts.sanitizeSemanticAlloc(self.alloc, value) else null;
        errdefer if (progress) |value| self.alloc.free(value);
        const result = if (stringField(tool, "result")) |value| try contracts.sanitizeSemanticAlloc(self.alloc, value) else null;
        errdefer if (result) |value| self.alloc.free(value);
        const retained = owned_id.len + owned_title.len + owned_kind.len + owned_status.len +
            (if (progress) |value| value.len else 0) + (if (result) |value| value.len else 0);
        try self.ensureRetainedBytes(0, retained);
        try self.tools.append(self.alloc, .{
            .id = owned_id,
            .title = owned_title,
            .kind = owned_kind,
            .status = owned_status,
            .progress = progress,
            .result = result,
        });
        self.commitRetainedBytes(0, retained);
    }

    fn findTool(self: *RemoteProjection, id: []const u8) ?*contracts.ToolRecord {
        for (self.tools.items) |*tool| if (std.mem.eql(u8, tool.id, id)) return tool;
        return null;
    }

    fn consumeUpdate(self: *RemoteProjection, update: std.json.Value) !void {
        if (update != .object) return error.InvalidSemanticEvent;
        const kind = stringField(update, "sessionUpdate") orelse return error.InvalidSemanticEvent;
        if (std.mem.eql(u8, kind, "user_message_chunk")) {
            const content = update.object.get("content") orelse return error.InvalidSemanticEvent;
            const text = stringField(content, "text") orelse return error.InvalidSemanticEvent;
            const owned = try contracts.sanitizeSemanticAlloc(self.alloc, text);
            errdefer self.alloc.free(owned);
            try self.ensureRetainedBytes(0, owned.len);
            try self.history.append(self.alloc, .{ .role = .user, .text = owned });
            self.commitRetainedBytes(0, owned.len);
        } else if (std.mem.eql(u8, kind, "agent_message_chunk")) {
            const content = update.object.get("content") orelse return error.InvalidSemanticEvent;
            const text = stringField(content, "text") orelse return error.InvalidSemanticEvent;
            const safe = try contracts.sanitizeSemanticAlloc(self.alloc, text);
            defer self.alloc.free(safe);
            try self.ensureRetainedBytes(0, safe.len);
            if (std.mem.eql(u8, self.run_state, "idle")) {
                const owned = try self.alloc.dupe(u8, safe);
                errdefer self.alloc.free(owned);
                try self.history.append(self.alloc, .{ .role = .assistant, .text = owned });
            } else try self.assistant_partial.appendSlice(self.alloc, safe);
            self.commitRetainedBytes(0, safe.len);
        } else if (std.mem.eql(u8, kind, "tool_call")) {
            const id = stringField(update, "toolCallId") orelse return error.InvalidSemanticEvent;
            if (self.findTool(id)) |tool| {
                try self.replaceString(&tool.title, stringField(update, "title") orelse "Tool call");
                try self.replaceString(&tool.kind, stringField(update, "kind") orelse "other");
                try self.replaceString(&tool.status, stringField(update, "status") orelse "pending");
            } else try self.appendTool(update);
        } else if (std.mem.eql(u8, kind, "tool_call_update")) {
            const id = stringField(update, "toolCallId") orelse return error.InvalidSemanticEvent;
            const tool = self.findTool(id) orelse return error.ToolProjectionOutOfOrder;
            const status = stringField(update, "status") orelse "in_progress";
            try self.replaceString(&tool.status, status);
            const detail = semanticToolContentText(update);
            if (std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "failed"))
                try self.replaceOptional(&tool.result, detail)
            else
                try self.replaceOptional(&tool.progress, detail);
        }
    }

    fn installPending(self: *RemoteProjection, pending: std.json.Value) !void {
        if (pending != .object) return error.InvalidSemanticEvent;
        const id = pending.object.get("id") orelse return error.InvalidSemanticEvent;
        const method = stringField(pending, "method") orelse return error.InvalidSemanticEvent;
        const params = pending.object.get("params") orelse return error.InvalidSemanticEvent;
        if (id != .integer or id.integer <= 0) return error.InvalidSemanticEvent;
        var encoded: std.Io.Writer.Allocating = .init(self.alloc);
        defer encoded.deinit();
        try std.json.Stringify.value(params, .{}, &encoded.writer);
        const params_json = try encoded.toOwnedSlice();
        errdefer self.alloc.free(params_json);
        const owned_method = try contracts.sanitizeSemanticAlloc(self.alloc, method);
        errdefer self.alloc.free(owned_method);
        const old_len = if (self.pending) |current| current.method.len + current.params_json.len else 0;
        const new_len = owned_method.len + params_json.len;
        try self.ensureRetainedBytes(old_len, new_len);
        if (self.pending) |*old| old.deinit(self.alloc);
        self.pending = .{ .id = @intCast(id.integer), .method = owned_method, .params_json = params_json };
        self.commitRetainedBytes(old_len, new_len);
    }

    fn clearPending(self: *RemoteProjection) void {
        if (self.pending) |*pending| {
            const removed = pending.method.len + pending.params_json.len;
            pending.deinit(self.alloc);
            self.commitRetainedBytes(removed, 0);
        }
        self.pending = null;
    }

    fn operationIsTerminal(state: []const u8) bool {
        return !std.mem.eql(u8, state, "accepted") and !std.mem.eql(u8, state, "running");
    }

    fn evictOldestTerminalOperation(self: *RemoteProjection) !void {
        for (self.operations.items, 0..) |operation, index| {
            if (!operationIsTerminal(operation.state)) continue;
            const removed = operation.id.len + operation.state.len +
                (if (operation.detail) |detail| detail.len else 0);
            var owned = self.operations.orderedRemove(index);
            owned.deinit(self.alloc);
            self.commitRetainedBytes(removed, 0);
            return;
        }
        return error.OperationProjectionCapacityExceeded;
    }

    const OperationUpdateMode = enum { hydrate, live };

    fn upsertOperation(self: *RemoteProjection, operation: std.json.Value, mode: OperationUpdateMode) !void {
        if (operation != .object) return error.InvalidSemanticEvent;
        const id = stringField(operation, "operationId") orelse return error.InvalidSemanticEvent;
        const state = stringField(operation, "state") orelse return error.InvalidSemanticEvent;
        var existing: ?*OperationSummary = null;
        for (self.operations.items) |*candidate| if (std.mem.eql(u8, candidate.id, id)) {
            existing = candidate;
            break;
        };
        const detail_value = operation.object.get("error") orelse operation.object.get("result");
        var detail: ?[]u8 = null;
        if (detail_value) |value| {
            var encoded: std.Io.Writer.Allocating = .init(self.alloc);
            defer encoded.deinit();
            try std.json.Stringify.value(value, .{}, &encoded.writer);
            const raw = try encoded.toOwnedSlice();
            defer self.alloc.free(raw);
            detail = try contracts.sanitizeSemanticAlloc(self.alloc, raw);
        }
        errdefer if (detail) |value| self.alloc.free(value);
        if (existing) |record| {
            try self.replaceString(&record.state, state);
            const old_detail_len = if (record.detail) |old| old.len else 0;
            const new_detail_len = if (detail) |owned| owned.len else 0;
            try self.ensureRetainedBytes(old_detail_len, new_detail_len);
            if (record.detail) |old| self.alloc.free(old);
            record.detail = detail;
            detail = null;
            self.commitRetainedBytes(old_detail_len, new_detail_len);
        } else {
            if (self.operations.items.len >= contracts.max_operations_per_actor)
                try self.evictOldestTerminalOperation();
            const owned_id = try contracts.sanitizeSemanticAlloc(self.alloc, id);
            errdefer self.alloc.free(owned_id);
            const owned_state = try contracts.sanitizeSemanticAlloc(self.alloc, state);
            errdefer self.alloc.free(owned_state);
            const retained = owned_id.len + owned_state.len + (if (detail) |owned| owned.len else 0);
            try self.ensureRetainedBytes(0, retained);
            try self.operations.append(self.alloc, .{ .id = owned_id, .state = owned_state, .detail = detail });
            detail = null;
            self.commitRetainedBytes(0, retained);
        }
        if (mode == .live and operationIsTerminal(state)) {
            if (self.assistant_partial.items.len > 0) {
                const owned = try self.assistant_partial.toOwnedSlice(self.alloc);
                errdefer self.alloc.free(owned);
                try self.history.append(self.alloc, .{ .role = .assistant, .text = owned });
            }
            self.clearPending();
        }
    }

    fn applyEventEnvelope(self: *RemoteProjection, attachment_id: []const u8, params: std.json.Value) !std.json.Value {
        if (params != .object) return error.InvalidSemanticEvent;
        const event_attachment = stringField(params, "attachmentId") orelse return error.InvalidSemanticEvent;
        if (!std.mem.eql(u8, event_attachment, attachment_id)) return error.StaleAttachmentEvent;
        const revision = params.object.get("revision") orelse return error.InvalidSemanticEvent;
        if (revision != .integer or revision.integer < 0) return error.InvalidSemanticEvent;
        const next_revision: u64 = @intCast(revision.integer);
        if (next_revision != self.revision +| 1) return error.RemoteRevisionGap;
        const event = params.object.get("event") orelse return error.InvalidSemanticEvent;
        if (event != .object) return error.InvalidSemanticEvent;
        const method = stringField(event, "method") orelse return error.InvalidSemanticEvent;
        if (std.mem.eql(u8, method, "session/update")) {
            const event_params = event.object.get("params") orelse return error.InvalidSemanticEvent;
            if (event_params != .object) return error.InvalidSemanticEvent;
            const update = event_params.object.get("update") orelse return error.InvalidSemanticEvent;
            try self.consumeUpdate(update);
        } else if (std.mem.eql(u8, method, "session/request_permission") or std.mem.eql(u8, method, "elicitation/create")) {
            try self.installPending(event);
        } else if (std.mem.eql(u8, method, "fx/operation")) {
            const operation = event.object.get("params") orelse return error.InvalidSemanticEvent;
            try self.upsertOperation(operation, .live);
        } else if (std.mem.eql(u8, method, "fx/run_state")) {
            const state_params = event.object.get("params") orelse return error.InvalidSemanticEvent;
            const state = stringField(state_params, "state") orelse return error.InvalidSemanticEvent;
            try self.replaceString(&self.run_state, state);
            if (std.mem.eql(u8, state, "idle")) self.clearPending();
        } else if (std.mem.eql(u8, method, "fx/configuration")) {
            const configuration = event.object.get("params") orelse return error.InvalidSemanticEvent;
            const kind = stringField(configuration, "kind") orelse return error.InvalidSemanticEvent;
            const value = stringField(configuration, "value") orelse return error.InvalidSemanticEvent;
            if (std.mem.eql(u8, kind, "model"))
                try self.replaceOptional(&self.model, value)
            else if (std.mem.eql(u8, kind, "mode"))
                try self.replaceOptional(&self.mode, value);
        }
        self.revision = next_revision;
        return event;
    }

    fn setError(self: *RemoteProjection, message: []const u8) !void {
        try self.replaceOptional(&self.last_error, message);
    }
};

const TuiState = struct {
    terminal: shell_runtime.TerminalState = .{},
    active: bool = false,
    rows: u16 = 0,
    cols: u16 = 0,
    composer: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    welcome_committed: bool = false,
    committed_history_items: usize = 0,
    committed_tool_ids: std.ArrayList([]u8) = .empty,
    rendered_hard_row_widths: std.ArrayList(usize) = .empty,
    cursor_hard_row: usize = 0,
    cursor_hard_col: usize = 0,
    escape_state: enum { none, escape, csi } = .none,
    csi: [8]u8 = @splat(0),
    csi_len: usize = 0,
    paste_active: bool = false,
    paste_end_match_len: usize = 0,
    paste_start: usize = 0,
    paste_bytes: usize = 0,
    paste_rejected: bool = false,
    abnormal_handlers_installed: bool = false,

    fn deinit(self: *TuiState, alloc: Allocator) void {
        self.composer.deinit(alloc);
        for (self.committed_tool_ids.items) |id| alloc.free(id);
        self.committed_tool_ids.deinit(alloc);
        self.rendered_hard_row_widths.deinit(alloc);
    }
};

fn freeScreenLines(alloc: Allocator, lines: *std.ArrayList([]u8)) void {
    for (lines.items) |line| alloc.free(line);
    lines.deinit(alloc);
}

fn appendScreenLine(alloc: Allocator, lines: *std.ArrayList([]u8), text: []const u8) !void {
    try lines.append(alloc, try alloc.dupe(u8, text));
}

fn appendSpaces(alloc: Allocator, output: *std.ArrayList(u8), count: usize) !void {
    try output.appendNTimes(alloc, ' ', count);
}

fn tabCells(width: usize) usize {
    return 8 - (width % 8);
}

fn appendContinuationPrefix(
    alloc: Allocator,
    line: *std.ArrayList(u8),
    prefix: []const u8,
    cols: usize,
) !usize {
    const clipped = display_width.prefixByWidth(prefix, cols);
    const width = display_width.visibleWidth(clipped);
    if (width >= cols) return 0;
    try line.appendSlice(alloc, clipped);
    return width;
}

fn appendWrappedScreenText(
    alloc: Allocator,
    lines: *std.ArrayList([]u8),
    prefix: []const u8,
    continuation_prefix: []const u8,
    text: []const u8,
    cols: usize,
) !void {
    if (cols == 0) return;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    const first_prefix = display_width.prefixByWidth(prefix, cols);
    try line.appendSlice(alloc, first_prefix);
    var width = display_width.visibleWidth(first_prefix);
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == '\n' or byte == '\r') {
            try appendScreenLine(alloc, lines, line.items);
            line.clearRetainingCapacity();
            width = try appendContinuationPrefix(alloc, &line, continuation_prefix, cols);
            index += 1;
            continue;
        }
        if (byte == '\t') {
            var cells = tabCells(width);
            if (width + cells > cols) {
                try appendScreenLine(alloc, lines, line.items);
                line.clearRetainingCapacity();
                width = try appendContinuationPrefix(alloc, &line, continuation_prefix, cols);
                cells = tabCells(width);
            }
            const available = cols -| width;
            const emitted = @min(cells, available);
            try appendSpaces(alloc, &line, emitted);
            width += emitted;
            index += 1;
            continue;
        }
        const unit = display_width.displayUnitAt(text, index);
        if (unit.byte_len == 0) break;
        if (unit.cell_width == 0) {
            index += unit.byte_len;
            continue;
        }
        if (width + unit.cell_width > cols) {
            try appendScreenLine(alloc, lines, line.items);
            line.clearRetainingCapacity();
            width = try appendContinuationPrefix(alloc, &line, continuation_prefix, cols);
        }
        if (width + unit.cell_width <= cols) {
            try line.appendSlice(alloc, text[index .. index + unit.byte_len]);
            width += unit.cell_width;
        }
        index += unit.byte_len;
    }
    try appendScreenLine(alloc, lines, line.items);
}

fn appendSingleLineScreenText(
    alloc: Allocator,
    output: *std.ArrayList(u8),
    text: []const u8,
    cols: usize,
) !void {
    var width: usize = 0;
    var index: usize = 0;
    while (index < text.len and width < cols) {
        const byte = text[index];
        if (byte == '\n' or byte == '\r') {
            try output.append(alloc, ' ');
            width += 1;
            index += 1;
            continue;
        }
        if (byte == '\t') {
            const emitted = @min(tabCells(width), cols - width);
            try appendSpaces(alloc, output, emitted);
            width += emitted;
            index += 1;
            continue;
        }
        const unit = display_width.displayUnitAt(text, index);
        if (unit.byte_len == 0) break;
        if (unit.cell_width == 0) {
            index += unit.byte_len;
            continue;
        }
        if (width + unit.cell_width > cols) break;
        try output.appendSlice(alloc, text[index .. index + unit.byte_len]);
        width += unit.cell_width;
        index += unit.byte_len;
    }
}

fn nextDisplayBoundary(text: []const u8, cursor: usize) usize {
    if (cursor >= text.len) return text.len;
    const unit = display_width.displayUnitAt(text, cursor);
    if (unit.byte_len == 0) return text.len;
    return @min(cursor + unit.byte_len, text.len);
}

fn previousDisplayBoundary(text: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var index: usize = 0;
    var previous: usize = 0;
    while (index < cursor) {
        previous = index;
        const unit = display_width.displayUnitAt(text, index);
        if (unit.byte_len == 0) break;
        const next = @min(index + unit.byte_len, text.len);
        if (next >= cursor) return index;
        index = next;
    }
    return previous;
}

fn pendingSupportsPermissionShortcuts(method: []const u8) bool {
    return std.mem.eql(u8, method, "session/request_permission");
}

fn pendingInputInstructions(method: []const u8) []const u8 {
    return if (pendingSupportsPermissionShortcuts(method))
        "Use /allow, /always, /deny, or /respond <json>.\n"
    else
        "Use /respond <json>.\n";
}

fn pendingTuiHint(method: []const u8, compact: bool) []const u8 {
    if (pendingSupportsPermissionShortcuts(method)) return if (compact)
        " Input required · /allow · /always · /deny"
    else
        " /allow · /always · /deny · /respond <json> · /detach";
    return if (compact)
        " Input required · /respond <json>"
    else
        " /respond <json> · /detach";
}

const Client = struct {
    alloc: Allocator,
    wire: Wire,
    interactive: bool,
    intent: contracts.Role,
    authority: std.atomic.Value(bool) = .init(false),
    projection: RemoteProjection,
    tui: TuiState = .{},
    output_mutex: std.Io.Mutex = .init,
    stopping: std.atomic.Value(bool) = .init(false),
    attachment_id: [32]u8 = @splat(0),
    attachment_len: usize = 0,
    control_epoch: std.atomic.Value(u64) = .init(0),
    next_request_id: std.atomic.Value(u64) = .init(10),
    pending_interaction: std.atomic.Value(u64) = .init(0),
    pending_prompt_request: std.atomic.Value(u64) = .init(0),
    submitted_prompt: ?[]u8 = null,
    snapshot_id: [32]u8 = @splat(0),
    snapshot_chunk_count: usize = 0,
    snapshot_next_chunk: usize = 0,
    snapshot_bytes: std.ArrayList(u8) = .empty,

    fn init(alloc: Allocator, wire: Wire, interactive: bool, intent: contracts.Role) Client {
        return .{
            .alloc = alloc,
            .wire = wire,
            .interactive = interactive,
            .intent = intent,
            .projection = RemoteProjection.init(alloc),
        };
    }

    fn hasAuthority(self: *const Client) bool {
        return self.authority.load(.acquire);
    }

    fn deinit(self: *Client) void {
        self.stopping.store(true, .release);
        self.leaveTui();
        self.wire.close();
        self.snapshot_bytes.deinit(self.alloc);
        if (self.submitted_prompt) |prompt| self.alloc.free(prompt);
        self.projection.deinit();
        self.tui.deinit(self.alloc);
        self.* = undefined;
    }

    fn send(self: *Client, message: []const u8) !void {
        if (message.len == 0 or message.len > contracts.max_frame_bytes) return error.FrameTooLarge;
        try self.wire.write(message);
    }

    fn readMessage(self: *Client, alloc: Allocator) !?[]u8 {
        return self.wire.read(alloc);
    }

    fn requestId(self: *Client) u64 {
        return self.next_request_id.fetchAdd(1, .acq_rel);
    }

    fn initializeAndAttach(self: *Client, options: Options) !void {
        try self.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1}}");
        try self.waitForResponse(1, false);
        var attach: std.Io.Writer.Allocating = .init(self.alloc);
        defer attach.deinit();
        try attach.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"fx/attach\",\"params\":{\"sessionId\":");
        try jsonrpc.writeJsonStr(options.session_id, &attach.writer);
        try attach.writer.writeAll(",\"role\":");
        const role: contracts.Role = if (options.observe) .observer else if (options.primary) .primary else .controller;
        try jsonrpc.writeJsonStr(@tagName(role), &attach.writer);
        try attach.writer.writeAll("}}");
        try self.send(attach.writer.buffered());
        try self.waitForResponse(2, true);
    }

    fn waitForResponse(self: *Client, expected_id: i64, attach: bool) !void {
        while (try self.readMessage(self.alloc)) |message| {
            defer self.alloc.free(message);
            var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, message, .{}) catch return error.InvalidRemoteJson;
            defer parsed.deinit();
            if (parsed.value != .object) return error.InvalidRemoteMessage;
            const id = parsed.value.object.get("id") orelse continue;
            if (id != .integer or id.integer != expected_id) continue;
            if (parsed.value.object.get("error")) |err| {
                try self.renderError(err);
                return error.RemoteRequestFailed;
            }
            if (attach) {
                const result = parsed.value.object.get("result") orelse return error.InvalidAttachResponse;
                try self.installAttach(result);
            }
            return;
        }
        return error.ConnectionClosed;
    }

    fn installAttach(self: *Client, result: std.json.Value) !void {
        if (result != .object) return error.InvalidAttachResponse;
        const id = stringField(result, "attachmentId") orelse return error.InvalidAttachResponse;
        if (id.len != self.attachment_id.len) return error.InvalidAttachResponse;
        @memcpy(&self.attachment_id, id);
        self.attachment_len = id.len;
        const epoch = result.object.get("controlEpoch") orelse return error.InvalidAttachResponse;
        if (epoch != .integer or epoch.integer < 0) return error.InvalidAttachResponse;
        self.control_epoch.store(@intCast(epoch.integer), .release);
        self.installControlState(result) catch return error.InvalidAttachResponse;
        if (result.object.get("snapshot")) |snapshot| {
            try self.renderSnapshot(snapshot);
            return;
        }
        const transfer = result.object.get("snapshotTransfer") orelse return error.InvalidAttachResponse;
        if (transfer != .object) return error.InvalidAttachResponse;
        const snapshot_id = stringField(transfer, "snapshotId") orelse return error.InvalidAttachResponse;
        const encoding = stringField(transfer, "encoding") orelse return error.InvalidAttachResponse;
        const chunk_count = transfer.object.get("chunkCount") orelse return error.InvalidAttachResponse;
        if (!std.mem.eql(u8, encoding, "base64") or snapshot_id.len != self.snapshot_id.len or chunk_count != .integer or chunk_count.integer <= 0 or chunk_count.integer > 64)
            return error.InvalidAttachResponse;
        @memcpy(&self.snapshot_id, snapshot_id);
        self.snapshot_chunk_count = @intCast(chunk_count.integer);
        self.snapshot_next_chunk = 0;
        self.snapshot_bytes.clearRetainingCapacity();
    }

    fn attachmentSlice(self: *const Client) []const u8 {
        return self.attachment_id[0..self.attachment_len];
    }

    fn installControlState(self: *Client, value: std.json.Value) !void {
        if (value != .object) return error.InvalidControlState;
        const epoch = value.object.get("controlEpoch") orelse return error.InvalidControlState;
        if (epoch != .integer or epoch.integer < 0) return error.InvalidControlState;
        self.control_epoch.store(@intCast(epoch.integer), .release);
        const owner = value.object.get("controllerAttachmentId") orelse return error.InvalidControlState;
        const owns_control = owner == .string and std.mem.eql(u8, owner.string, self.attachmentSlice());
        self.authority.store(owns_control, .release);
    }

    fn renderSnapshot(self: *Client, snapshot: std.json.Value) !void {
        if (snapshot != .object) return error.InvalidAttachResponse;
        const stdout = std.Io.File.stdout();
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        defer self.output_mutex.unlock(io);
        try self.projection.installSnapshot(snapshot);
        if (snapshot.object.get("control")) |control| try self.installControlState(control);
        self.pending_interaction.store(if (self.projection.pending) |pending| pending.id else 0, .release);
        if (self.interactive) {
            if (self.tui.active) try self.renderTuiUnlocked();
            return;
        }
        const session_id = self.projection.session_id;
        const run_state = self.projection.run_state;
        try stdout.writeStreamingAll(io, "Attached to ");
        try writeTerminalSafe(stdout, io, session_id);
        try stdout.writeStreamingAll(io, " (");
        try writeTerminalSafe(stdout, io, run_state);
        try stdout.writeStreamingAll(io, ")\n");
        if (snapshot.object.get("history")) |history| if (history == .array) {
            for (history.array.items) |item| {
                if (item != .object) continue;
                const role = stringField(item, "role") orelse "notice";
                const text = stringField(item, "text") orelse "";
                const label = if (std.mem.eql(u8, role, "user")) "You: " else if (std.mem.eql(u8, role, "assistant")) "fx: " else "Notice: ";
                try stdout.writeStreamingAll(io, label);
                try writeTerminalSafe(stdout, io, text);
                try stdout.writeStreamingAll(io, "\n");
            }
        };
        if (snapshot.object.get("assistantPartial")) |partial| if (partial == .string and partial.string.len > 0) {
            try stdout.writeStreamingAll(io, "fx: ");
            try writeTerminalSafe(stdout, io, partial.string);
            try stdout.writeStreamingAll(io, "\n");
        };
        if (snapshot.object.get("tools")) |tools| if (tools == .array) {
            for (tools.array.items) |tool| try self.renderToolUnlocked(tool);
        };
        if (snapshot.object.get("pendingInteraction")) |pending| if (pending == .object) {
            try self.renderPendingUnlocked(pending);
        };
    }

    fn completePromptAdmission(self: *Client, response_id: u64, accepted: bool) void {
        if (self.pending_prompt_request.load(.acquire) != response_id) return;
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        if (self.pending_prompt_request.load(.acquire) != response_id) {
            self.output_mutex.unlock(io);
            return;
        }
        if (accepted) if (self.submitted_prompt) |submitted| {
            const draft = std.mem.trim(u8, self.tui.composer.items, " \t\r\n");
            if (std.mem.eql(u8, draft, submitted)) {
                self.tui.composer.clearRetainingCapacity();
                self.tui.cursor = 0;
            }
        };
        if (self.submitted_prompt) |submitted| self.alloc.free(submitted);
        self.submitted_prompt = null;
        self.pending_prompt_request.store(0, .release);
        if (self.interactive) self.renderTuiUnlocked() catch {};
        self.output_mutex.unlock(io);
    }

    fn trackPromptAdmission(self: *Client, request_id: u64, text: []const u8) !void {
        const owned = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(owned);
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        defer self.output_mutex.unlock(io);
        if (self.pending_prompt_request.load(.acquire) != 0) return error.PromptAdmissionPending;
        if (self.submitted_prompt) |submitted| self.alloc.free(submitted);
        self.submitted_prompt = owned;
        self.pending_prompt_request.store(request_id, .release);
    }

    fn renderMessage(self: *Client, message: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, message, .{}) catch return error.InvalidRemoteJson;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidRemoteMessage;
        const response_id: ?u64 = if (parsed.value.object.get("id")) |id|
            if (id == .integer and id.integer >= 0) @intCast(id.integer) else null
        else
            null;
        if (parsed.value.object.get("error")) |err| {
            if (response_id) |id| self.completePromptAdmission(id, false);
            return self.renderError(err);
        }
        if (parsed.value.object.get("result") != null) {
            if (response_id) |id| self.completePromptAdmission(id, true);
            return;
        }
        const method = stringField(parsed.value, "method") orelse return;
        if (std.mem.eql(u8, method, "fx/snapshot/chunk")) return self.acceptSnapshotChunk(parsed.value);
        if (!std.mem.eql(u8, method, "fx/event")) return;
        const params = parsed.value.object.get("params") orelse return error.InvalidSemanticEvent;
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        const event = self.projection.applyEventEnvelope(self.attachmentSlice(), params) catch |err| {
            self.output_mutex.unlock(io);
            return err;
        };
        self.pending_interaction.store(if (self.projection.pending) |pending| pending.id else 0, .release);
        const event_method = stringField(event, "method") orelse {
            self.output_mutex.unlock(io);
            return error.InvalidSemanticEvent;
        };
        if (std.mem.eql(u8, event_method, "fx/control_changed")) {
            const control = event.object.get("params") orelse {
                self.output_mutex.unlock(io);
                return error.InvalidControlState;
            };
            self.installControlState(control) catch |err| {
                self.output_mutex.unlock(io);
                return err;
            };
        }
        if (self.interactive) {
            const render_result = self.renderTuiUnlocked();
            self.output_mutex.unlock(io);
            return render_result;
        }
        self.output_mutex.unlock(io);
        if (std.mem.eql(u8, event_method, "session/update")) {
            const event_params = event.object.get("params") orelse return error.InvalidSemanticEvent;
            if (event_params != .object) return error.InvalidSemanticEvent;
            const update = event_params.object.get("update") orelse return error.InvalidSemanticEvent;
            try self.renderUpdate(update);
        } else if (std.mem.eql(u8, event_method, "session/request_permission") or
            std.mem.eql(u8, event_method, "elicitation/create"))
        {
            try self.renderPending(event);
        } else if (std.mem.eql(u8, event_method, "fx/operation")) {
            const op_params = event.object.get("params") orelse return error.InvalidSemanticEvent;
            try self.renderOperation(op_params);
        } else if (std.mem.eql(u8, event_method, "fx/run_state")) {
            const state_params = event.object.get("params") orelse return error.InvalidSemanticEvent;
            try self.renderRunState(state_params);
        } else if (std.mem.eql(u8, event_method, "fx/configuration")) {
            const configuration = event.object.get("params") orelse return error.InvalidSemanticEvent;
            const kind = stringField(configuration, "kind") orelse "configuration";
            const value = stringField(configuration, "value") orelse "updated";
            self.output_mutex.lockUncancelable(io);
            defer self.output_mutex.unlock(io);
            try std.Io.File.stdout().writeStreamingAll(io, "\n");
            try writeTerminalSafe(std.Io.File.stdout(), io, kind);
            try std.Io.File.stdout().writeStreamingAll(io, ": ");
            try writeTerminalSafe(std.Io.File.stdout(), io, value);
            try std.Io.File.stdout().writeStreamingAll(io, "\n");
        }
    }

    fn acceptSnapshotChunk(self: *Client, root: std.json.Value) !void {
        const params = root.object.get("params") orelse return error.InvalidSnapshotChunk;
        if (params != .object) return error.InvalidSnapshotChunk;
        const snapshot_id = stringField(params, "snapshotId") orelse return error.InvalidSnapshotChunk;
        const index = params.object.get("index") orelse return error.InvalidSnapshotChunk;
        const chunk_count = params.object.get("chunkCount") orelse return error.InvalidSnapshotChunk;
        const encoding = stringField(params, "encoding") orelse return error.InvalidSnapshotChunk;
        const data = stringField(params, "data") orelse return error.InvalidSnapshotChunk;
        if (!std.mem.eql(u8, encoding, "base64") or !std.mem.eql(u8, snapshot_id, &self.snapshot_id) or index != .integer or chunk_count != .integer or
            index.integer < 0 or @as(usize, @intCast(index.integer)) != self.snapshot_next_chunk or
            chunk_count.integer != self.snapshot_chunk_count)
            return error.InvalidSnapshotChunk;
        try self.appendBase64SnapshotChunk(data);
        self.snapshot_next_chunk += 1;
        if (self.snapshot_next_chunk != self.snapshot_chunk_count) return;
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, self.snapshot_bytes.items, .{});
        defer parsed.deinit();
        try self.renderSnapshot(parsed.value);
        var ack: std.Io.Writer.Allocating = .init(self.alloc);
        defer ack.deinit();
        try ack.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"fx/snapshot/ack\",\"params\":{{\"attachmentId\":", .{self.requestId()});
        try jsonrpc.writeJsonStr(self.attachmentSlice(), &ack.writer);
        try ack.writer.writeAll(",\"snapshotId\":");
        try jsonrpc.writeJsonStr(&self.snapshot_id, &ack.writer);
        try ack.writer.writeAll("}}");
        try self.send(ack.writer.buffered());
        self.snapshot_bytes.clearRetainingCapacity();
    }

    fn appendBase64SnapshotChunk(self: *Client, data: []const u8) !void {
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data) catch return error.InvalidSnapshotChunk;
        if (decoded_len > contracts.snapshot_chunk_bytes or
            self.snapshot_bytes.items.len > contracts.max_snapshot_bytes -| decoded_len)
            return error.InvalidSnapshotChunk;
        const old_len = self.snapshot_bytes.items.len;
        try self.snapshot_bytes.resize(self.alloc, old_len + decoded_len);
        errdefer self.snapshot_bytes.shrinkRetainingCapacity(old_len);
        std.base64.standard.Decoder.decode(self.snapshot_bytes.items[old_len..], data) catch
            return error.InvalidSnapshotChunk;
    }

    fn renderUpdate(self: *Client, update: std.json.Value) !void {
        if (update != .object) return error.InvalidSemanticEvent;
        const kind = stringField(update, "sessionUpdate") orelse return error.InvalidSemanticEvent;
        const stdout = std.Io.File.stdout();
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        defer self.output_mutex.unlock(io);
        if (std.mem.eql(u8, kind, "user_message_chunk")) {
            if (update.object.get("content")) |content| if (content == .object) {
                if (stringField(content, "text")) |text| {
                    try stdout.writeStreamingAll(io, "You: ");
                    try writeTerminalSafe(stdout, io, text);
                    try stdout.writeStreamingAll(io, "\n");
                }
            };
        } else if (std.mem.eql(u8, kind, "agent_message_chunk")) {
            if (update.object.get("content")) |content| if (content == .object) {
                if (stringField(content, "text")) |text| try writeTerminalSafe(stdout, io, text);
            };
        } else if (std.mem.eql(u8, kind, "tool_call")) {
            try self.renderToolUnlocked(update);
        } else if (std.mem.eql(u8, kind, "tool_call_update")) {
            const id = stringField(update, "toolCallId") orelse "tool";
            const status = stringField(update, "status") orelse "updated";
            try stdout.writeStreamingAll(io, "\nTool ");
            try writeTerminalSafe(stdout, io, id);
            try stdout.writeStreamingAll(io, ": ");
            try writeTerminalSafe(stdout, io, status);
            try stdout.writeStreamingAll(io, "\n");
            if (toolContentText(update)) |text| {
                try stdout.writeStreamingAll(io, "  ");
                try writeTerminalSafe(stdout, io, text);
                try stdout.writeStreamingAll(io, "\n");
            }
        }
    }

    fn renderTool(self: *Client, tool: std.json.Value) !void {
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        defer self.output_mutex.unlock(io);
        try self.renderToolUnlocked(tool);
    }

    fn renderToolUnlocked(_: *Client, tool: std.json.Value) !void {
        if (tool != .object) return;
        const id = stringField(tool, "id") orelse stringField(tool, "toolCallId") orelse "tool";
        const title = stringField(tool, "title") orelse "Tool call";
        const status = stringField(tool, "status") orelse "unknown";
        const stdout = std.Io.File.stdout();
        const io = io_mod.getIo();
        try stdout.writeStreamingAll(io, "Tool ");
        try writeTerminalSafe(stdout, io, id);
        try stdout.writeStreamingAll(io, ": ");
        try writeTerminalSafe(stdout, io, title);
        try stdout.writeStreamingAll(io, " [");
        try writeTerminalSafe(stdout, io, status);
        try stdout.writeStreamingAll(io, "]\n");
        if (stringField(tool, "progress") orelse stringField(tool, "result")) |detail| {
            try stdout.writeStreamingAll(io, "  ");
            try writeTerminalSafe(stdout, io, detail);
            try stdout.writeStreamingAll(io, "\n");
        }
    }

    fn toolContentText(update: std.json.Value) ?[]const u8 {
        if (update != .object) return null;
        const content = update.object.get("content") orelse return null;
        if (content != .array or content.array.items.len == 0) return null;
        const first = content.array.items[0];
        if (first != .object) return null;
        const nested = first.object.get("content") orelse return null;
        return stringField(nested, "text");
    }

    fn renderPending(self: *Client, pending: std.json.Value) !void {
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        defer self.output_mutex.unlock(io);
        try self.renderPendingUnlocked(pending);
    }

    fn renderPendingUnlocked(self: *Client, pending: std.json.Value) !void {
        if (pending != .object) return error.InvalidSemanticEvent;
        const stdout = std.Io.File.stdout();
        const io = io_mod.getIo();
        if (pending.object.get("id")) |id| if (id == .integer and id.integer > 0)
            self.pending_interaction.store(@intCast(id.integer), .release);
        try stdout.writeStreamingAll(io, "Input required");
        if (stringField(pending, "method")) |method| {
            try stdout.writeStreamingAll(io, " (");
            try writeTerminalSafe(stdout, io, method);
            try stdout.writeStreamingAll(io, ")");
        }
        try stdout.writeStreamingAll(io, ":\n");
        const params = pending.object.get("params") orelse pending;
        if (params == .object) {
            if (params.object.get("toolCall")) |tool_call| if (tool_call == .object) {
                const title = stringField(tool_call, "title") orelse stringField(tool_call, "toolCallId") orelse "Tool call";
                try stdout.writeStreamingAll(io, "  Tool: ");
                try writeTerminalSafe(stdout, io, title);
                try stdout.writeStreamingAll(io, "\n");
            };
            if (stringField(params, "title") orelse stringField(params, "message")) |detail| {
                try stdout.writeStreamingAll(io, "  ");
                try writeTerminalSafe(stdout, io, detail);
                try stdout.writeStreamingAll(io, "\n");
            }
            if (params.object.get("options")) |options| if (options == .array) {
                try stdout.writeStreamingAll(io, "  Choices:\n");
                for (options.array.items) |option| {
                    if (option != .object) continue;
                    const name = stringField(option, "name") orelse stringField(option, "optionId") orelse continue;
                    try stdout.writeStreamingAll(io, "    - ");
                    try writeTerminalSafe(stdout, io, name);
                    if (stringField(option, "optionId")) |option_id| {
                        try stdout.writeStreamingAll(io, " [");
                        try writeTerminalSafe(stdout, io, option_id);
                        try stdout.writeStreamingAll(io, "]");
                    }
                    try stdout.writeStreamingAll(io, "\n");
                }
            };
        }
        const method = stringField(pending, "method") orelse "";
        try stdout.writeStreamingAll(io, pendingInputInstructions(method));
    }

    fn renderRunState(self: *Client, params: std.json.Value) !void {
        if (params != .object) return error.InvalidSemanticEvent;
        const state = stringField(params, "state") orelse return error.InvalidSemanticEvent;
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        defer self.output_mutex.unlock(io);
        const stdout = std.Io.File.stdout();
        try stdout.writeStreamingAll(io, "\nStatus: ");
        try writeTerminalSafe(stdout, io, state);
        try stdout.writeStreamingAll(io, "\n");
    }

    fn renderOperation(self: *Client, operation: std.json.Value) !void {
        if (operation != .object) return error.InvalidSemanticEvent;
        const id = stringField(operation, "operationId") orelse "operation";
        const state = stringField(operation, "state") orelse "unknown";
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        defer self.output_mutex.unlock(io);
        const stdout = std.Io.File.stdout();
        try stdout.writeStreamingAll(io, "\nOperation ");
        try writeTerminalSafe(stdout, io, id);
        try stdout.writeStreamingAll(io, ": ");
        try writeTerminalSafe(stdout, io, state);
        try stdout.writeStreamingAll(io, "\n");
    }

    fn renderError(self: *Client, err: std.json.Value) !void {
        const message = if (err == .object) stringField(err, "message") orelse "Remote error" else "Remote error";
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        defer self.output_mutex.unlock(io);
        if (self.interactive) {
            try self.projection.setError(message);
            try self.renderTuiUnlocked();
            return;
        }
        try std.Io.File.stderr().writeStreamingAll(io, "fx attach: ");
        try writeTerminalSafe(std.Io.File.stderr(), io, message);
        try std.Io.File.stderr().writeStreamingAll(io, "\n");
    }

    fn readUntilEof(self: *Client) !void {
        while (!self.stopping.load(.acquire)) {
            const message = try self.readMessage(self.alloc);
            const bytes = message orelse return;
            self.renderMessage(bytes) catch |err| {
                self.alloc.free(bytes);
                return err;
            };
            self.alloc.free(bytes);
        }
    }

    fn enterTui(self: *Client) !void {
        if (!self.interactive or self.tui.active) return;
        try self.tui.terminal.ensureInteractive();
        try self.tui.terminal.captureOriginalTermios();
        app_lifecycle.installAbnormalExitHandlers(io_mod.getenv("TMUX"), &self.tui.terminal);
        self.tui.abnormal_handlers_installed = true;
        errdefer if (self.tui.abnormal_handlers_installed) {
            app_lifecycle.uninstallAbnormalExitHandlers();
            self.tui.abnormal_handlers_installed = false;
        };
        try self.tui.terminal.enableRawMode();
        self.tui.active = true;
        errdefer self.leaveTui();
        try std.Io.File.stdout().writeStreamingAll(
            io_mod.getIo(),
            "\x1b[?2004h\x1b[?25l",
        );
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        defer self.output_mutex.unlock(io);
        try self.refreshTuiGeometryUnlocked();
        try self.renderTuiUnlocked();
    }

    fn leaveTui(self: *Client) void {
        if (!self.tui.active) return;
        self.tui.active = false;
        std.Io.File.stdout().writeStreamingAll(
            io_mod.getIo(),
            "\x1b[0m\x1b]8;;\x1b\\\x1b[?2026l\x1b[?2004l\x1b[?25h\x1b[999B\r\n",
        ) catch {};
        self.tui.terminal.disableRawMode();
        if (self.tui.abnormal_handlers_installed) {
            app_lifecycle.uninstallAbnormalExitHandlers();
            self.tui.abnormal_handlers_installed = false;
        }
    }

    fn refreshTuiGeometryUnlocked(self: *Client) !void {
        var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const request: c_int = @intCast(std.c.T.IOCGWINSZ);
        if (std.c.ioctl(std.posix.STDOUT_FILENO, request, &size) == -1 or size.row == 0 or size.col == 0)
            return;
        self.tui.rows = @max(size.row, 1);
        self.tui.cols = @max(size.col, 1);
    }

    fn refreshTuiGeometry(self: *Client) !void {
        if (!self.tui.active) return;
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        defer self.output_mutex.unlock(io);
        const old_rows = self.tui.rows;
        const old_cols = self.tui.cols;
        try self.refreshTuiGeometryUnlocked();
        if (old_rows != self.tui.rows or old_cols != self.tui.cols) try self.renderTuiUnlocked();
    }

    fn pendingSummary(self: *Client, buffer: *std.Io.Writer.Allocating) !void {
        const pending = self.projection.pending orelse return;
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, pending.params_json, .{}) catch {
            try buffer.writer.print("Input required ({s})", .{pending.method});
            return;
        };
        defer parsed.deinit();
        const params = parsed.value;
        const title = if (params == .object)
            stringField(params, "title") orelse stringField(params, "message")
        else
            null;
        if (title) |text| {
            try buffer.writer.writeAll(text);
        } else if (params == .object) {
            if (params.object.get("toolCall")) |tool_call| {
                try buffer.writer.writeAll("Permission: ");
                try buffer.writer.writeAll(stringField(tool_call, "title") orelse stringField(tool_call, "toolCallId") orelse "tool call");
            } else try buffer.writer.print("Input required ({s})", .{pending.method});
        } else {
            try buffer.writer.print("Input required ({s})", .{pending.method});
        }
    }

    fn toolIsTerminal(status: []const u8) bool {
        return std.mem.eql(u8, status, "completed") or
            std.mem.eql(u8, status, "failed") or
            std.mem.eql(u8, status, "cancelled");
    }

    fn toolWasCommitted(self: *const Client, id: []const u8) bool {
        for (self.tui.committed_tool_ids.items) |committed| {
            if (std.mem.eql(u8, committed, id)) return true;
        }
        return false;
    }

    fn hardRowPhysicalRows(width: usize, cols: usize) usize {
        if (cols == 0 or width == 0) return 1;
        return std.math.divCeil(usize, width, cols) catch unreachable;
    }

    fn hardRowPhysicalStart(self: *const Client, hard_row: usize, cols: usize) usize {
        var physical_row: usize = 0;
        for (self.tui.rendered_hard_row_widths.items[0..@min(hard_row, self.tui.rendered_hard_row_widths.items.len)]) |width| {
            physical_row += hardRowPhysicalRows(width, cols);
        }
        return physical_row;
    }

    fn erasePreviousMutableUnlocked(self: *Client, stdout: std.Io.File, io: std.Io) !void {
        if (self.tui.rendered_hard_row_widths.items.len == 0) return;
        const cols: usize = @max(self.tui.cols, 1);
        const hard_row = @min(self.tui.cursor_hard_row, self.tui.rendered_hard_row_widths.items.len - 1);
        const distance = self.hardRowPhysicalStart(hard_row, cols) + self.tui.cursor_hard_col / cols;
        if (distance > 0) {
            var up: [32]u8 = undefined;
            try stdout.writeStreamingAll(io, try std.fmt.bufPrint(&up, "\x1b[{d}A", .{distance}));
        }
        try stdout.writeStreamingAll(io, "\r\x1b[J");
        self.tui.rendered_hard_row_widths.clearRetainingCapacity();
        self.tui.cursor_hard_row = 0;
        self.tui.cursor_hard_col = 0;
    }

    fn recordHardRow(self: *Client, width: usize) !void {
        try self.tui.rendered_hard_row_widths.append(self.alloc, width);
    }

    fn renderTuiUnlocked(self: *Client) !void {
        if (!self.tui.active) return;
        try self.refreshTuiGeometryUnlocked();
        const cols = @max(self.tui.cols, 1);
        const rows: usize = @max(self.tui.rows, 1);
        const stdout = std.Io.File.stdout();
        const io = io_mod.getIo();

        try stdout.writeStreamingAll(io, "\x1b[?2026h\x1b[?25l");
        try self.erasePreviousMutableUnlocked(stdout, io);

        // Finalized rows leave the mutable region exactly once. The cursor at
        // the end becomes the next mutable anchor, so later input, events, and
        // resizes never repaint committed scrollback.
        if (!self.tui.welcome_committed) {
            const welcome = try ui_render.welcomeMessage(self.alloc);
            defer self.alloc.free(welcome);
            try stdout.writeStreamingAll(io, welcome);
            self.tui.welcome_committed = true;
        }
        while (self.tui.committed_history_items < self.projection.history.items.len) {
            const item = self.projection.history.items[self.tui.committed_history_items];
            switch (item.role) {
                .user => {
                    const card = try user_message_card.buildUserPromptCard(self.alloc, item.text, &.{}, cols);
                    defer self.alloc.free(card);
                    try stdout.writeStreamingAll(io, card);
                    try stdout.writeStreamingAll(io, "\n");
                },
                .assistant => {
                    const text = try transcript_blocks.wrapAssistantText(self.alloc, item.text, cols);
                    defer self.alloc.free(text);
                    try stdout.writeStreamingAll(io, text);
                    try stdout.writeStreamingAll(io, "\n\n");
                },
                .notice => {
                    try stdout.writeStreamingAll(io, ui_render.system_notice_label_style);
                    try stdout.writeStreamingAll(io, "Note ");
                    try stdout.writeStreamingAll(io, ui_render.reset_style);
                    try writeTerminalSafe(stdout, io, item.text);
                    try stdout.writeStreamingAll(io, "\n\n");
                },
            }
            self.tui.committed_history_items += 1;
        }
        for (self.projection.tools.items) |tool| {
            if (!toolIsTerminal(tool.status) or self.toolWasCommitted(tool.id)) continue;
            var summary: std.Io.Writer.Allocating = .init(self.alloc);
            defer summary.deinit();
            try summary.writer.print("{s} [{s}]", .{ tool.title, tool.status });
            var committed_lines: std.ArrayList([]u8) = .empty;
            defer freeScreenLines(self.alloc, &committed_lines);
            try appendWrappedScreenText(self.alloc, &committed_lines, "• ", "  ", summary.writer.buffered(), cols);
            if (tool.result orelse tool.progress) |detail|
                try appendWrappedScreenText(self.alloc, &committed_lines, "  ", "  ", detail, cols);
            try stdout.writeStreamingAll(io, ui_render.dim_style);
            for (committed_lines.items) |line| {
                try writeTerminalSafe(stdout, io, line);
                try stdout.writeStreamingAll(io, "\n");
            }
            try stdout.writeStreamingAll(io, ui_render.reset_style);
            try stdout.writeStreamingAll(io, "\n");
            const committed_id = try self.alloc.dupe(u8, tool.id);
            self.tui.committed_tool_ids.append(self.alloc, committed_id) catch |err| {
                self.alloc.free(committed_id);
                return err;
            };
        }
        try stdout.writeStreamingAll(io, "\r");

        const show_composer = self.intent != .observer;
        var composed: ?input_presentation.ComposedInputRows = null;
        defer if (composed) |*value| value.deinit(self.alloc);
        var composer_cursor_row: usize = 0;
        var composer_cursor_col: u16 = 1;
        if (show_composer) {
            const source = visual_layout.Source{
                .input = self.tui.composer.items,
                .cursor = self.tui.cursor,
                .terminal_cols = cols,
            };
            const summary = visual_layout.summarize(source, null);
            const row_limit = @max(@as(usize, 1), rows / 2);
            const window = visual_layout.visibleWindow(summary.cursor.row_index, summary.total_rows, row_limit);
            composed = try input_presentation.composeVisibleInputRows(self.alloc, source, window);
            composer_cursor_row = summary.cursor.row_index -| window.first_row;
            composer_cursor_col = visual_layout.terminalColumn(summary.cursor, cols);
        }
        const composer_rows = if (composed) |*value| value.rows.items.len else 0;
        const pending_rows: usize = @intFromBool(self.projection.pending != null);
        const fixed_mutable_rows = composer_rows + pending_rows + 1;
        // Keep one physical row unused so repaint line feeds cannot scroll the
        // mutable anchor into terminal scrollback before it is erased.
        const mutable_text_budget = rows -| @min(rows, fixed_mutable_rows + 1);

        var mutable_lines: std.ArrayList([]u8) = .empty;
        defer freeScreenLines(self.alloc, &mutable_lines);
        if (self.projection.assistant_partial.items.len > 0) {
            try appendWrappedScreenText(
                self.alloc,
                &mutable_lines,
                "",
                "",
                self.projection.assistant_partial.items,
                cols,
            );
        }
        for (self.projection.tools.items) |tool| {
            if (toolIsTerminal(tool.status)) continue;
            var summary: std.Io.Writer.Allocating = .init(self.alloc);
            defer summary.deinit();
            try summary.writer.print("• {s} [{s}]", .{ tool.title, tool.status });
            if (tool.progress) |progress| try summary.writer.print(" · {s}", .{progress});
            try appendWrappedScreenText(self.alloc, &mutable_lines, "", "  ", summary.writer.buffered(), cols);
        }
        const visible_start = mutable_lines.items.len -| @min(mutable_lines.items.len, mutable_text_budget);
        var mutable_row: usize = 0;
        for (mutable_lines.items[visible_start..]) |line| {
            try writeTerminalSafe(stdout, io, line);
            try self.recordHardRow(display_width.visibleWidth(line));
            try stdout.writeStreamingAll(io, "\r\n");
            mutable_row += 1;
        }
        if (self.projection.pending != null) {
            var pending: std.Io.Writer.Allocating = .init(self.alloc);
            defer pending.deinit();
            try pending.writer.writeAll("Input required · ");
            try self.pendingSummary(&pending);
            try stdout.writeStreamingAll(io, ui_render.warning_style);
            const clipped = display_width.prefixByWidth(pending.writer.buffered(), cols);
            try writeTerminalSafe(stdout, io, clipped);
            try stdout.writeStreamingAll(io, ui_render.reset_style);
            try self.recordHardRow(display_width.visibleWidth(clipped));
            try stdout.writeStreamingAll(io, "\r\n");
            mutable_row += 1;
        }

        const composer_start_row = mutable_row;
        if (composed) |*value| for (value.rows.items) |row| {
            try stdout.writeStreamingAll(io, row.items);
            try self.recordHardRow(display_width.visibleWidthIgnoringAnsi(row.items));
            try stdout.writeStreamingAll(io, "\r\n");
            mutable_row += 1;
        };

        var status_buf: [1024]u8 = undefined;
        const model = self.projection.model orelse "remote";
        const status = ui_render.buildHintLine(
            !std.mem.eql(u8, self.projection.run_state, "idle"),
            self.projection.pending != null,
            true,
            model,
            .auto,
            0,
            null,
            false,
            false,
            .auto,
            false,
            .{},
            cols,
            &status_buf,
        );
        var status_line: std.Io.Writer.Allocating = .init(self.alloc);
        defer status_line.deinit();
        try status_line.writer.writeAll(status);
        try status_line.writer.writeAll(if (self.hasAuthority())
            " · remote control"
        else if (self.intent == .primary)
            " · controlled remotely · read-only"
        else
            " · read-only");
        try status_line.writer.print(" · {s}", .{self.projection.run_state});
        if (self.projection.pending) |pending| try status_line.writer.writeAll(if (pendingSupportsPermissionShortcuts(pending.method))
            " · /allow · /always · /deny"
        else
            " · /respond <json>");
        if (self.projection.last_error) |message| try status_line.writer.print(" · {s}", .{message});
        const clipped_status = display_width.prefixByWidthIgnoringAnsi(status_line.writer.buffered(), cols);
        try stdout.writeStreamingAll(io, ui_render.statusline_style);
        try stdout.writeStreamingAll(io, clipped_status);
        try stdout.writeStreamingAll(io, ui_render.reset_style);
        const status_row = mutable_row;
        const status_width = display_width.visibleWidthIgnoringAnsi(clipped_status);
        try self.recordHardRow(status_width);

        if (show_composer and self.hasAuthority() and composer_rows > 0) {
            const target_row = composer_start_row + composer_cursor_row;
            const target_col = @as(usize, composer_cursor_col -| 1);
            const status_physical_row = self.hardRowPhysicalStart(status_row, cols) +
                (if (status_width == 0) 0 else (status_width - 1) / cols);
            const target_physical_row = self.hardRowPhysicalStart(target_row, cols) + target_col / cols;
            const up_rows = status_physical_row -| target_physical_row;
            var cursor: [64]u8 = undefined;
            const sequence = if (up_rows > 0)
                try std.fmt.bufPrint(&cursor, "\x1b[{d}A\x1b[{d}G\x1b[?25h\x1b[?2026l", .{ up_rows, target_col % cols + 1 })
            else
                try std.fmt.bufPrint(&cursor, "\x1b[{d}G\x1b[?25h\x1b[?2026l", .{target_col % cols + 1});
            try stdout.writeStreamingAll(io, sequence);
            self.tui.cursor_hard_row = target_row;
            self.tui.cursor_hard_col = target_col;
        } else {
            self.tui.cursor_hard_row = status_row;
            self.tui.cursor_hard_col = if (status_width < cols) status_width else cols - 1;
            try stdout.writeStreamingAll(io, "\x1b[?25l\x1b[?2026l");
        }
    }

    fn setInteractiveError(self: *Client, message: []const u8) void {
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        self.projection.setError(message) catch {};
        self.renderTuiUnlocked() catch {};
        self.output_mutex.unlock(io);
    }

    fn reportInputError(self: *Client, message: []const u8) void {
        if (self.interactive) {
            self.setInteractiveError(message);
            return;
        }
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        std.Io.File.stderr().writeStreamingAll(io, "fx attach: ") catch {};
        writeTerminalSafe(std.Io.File.stderr(), io, message) catch {};
        std.Io.File.stderr().writeStreamingAll(io, "\n") catch {};
        self.output_mutex.unlock(io);
    }

    fn submitComposer(self: *Client) bool {
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        if (self.pending_prompt_request.load(.acquire) != 0) {
            self.output_mutex.unlock(io);
            self.setInteractiveError("Prompt admission is still pending");
            return true;
        }
        if (!std.unicode.utf8ValidateSlice(self.tui.composer.items)) {
            self.output_mutex.unlock(io);
            self.setInteractiveError("Composer contains invalid UTF-8");
            return true;
        }
        const text = self.alloc.dupe(u8, self.tui.composer.items) catch {
            self.output_mutex.unlock(io);
            return false;
        };
        self.output_mutex.unlock(io);
        defer self.alloc.free(text);
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return true;
        var was_prompt = false;
        const keep_running = handleInputLine(self, trimmed, &was_prompt);
        if (!was_prompt) {
            self.output_mutex.lockUncancelable(io);
            self.tui.composer.clearRetainingCapacity();
            self.tui.cursor = 0;
            self.renderTuiUnlocked() catch {};
            self.output_mutex.unlock(io);
        }
        return keep_running;
    }

    fn redrawTui(self: *Client) void {
        if (!self.tui.active) return;
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        self.renderTuiUnlocked() catch {};
        self.output_mutex.unlock(io);
    }

    fn beginPaste(self: *Client) void {
        self.tui.paste_active = true;
        self.tui.paste_end_match_len = 0;
        self.tui.paste_start = self.tui.cursor;
        self.tui.paste_bytes = 0;
        self.tui.paste_rejected = false;
    }

    fn finishPaste(self: *Client) void {
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        const start = self.tui.paste_start;
        const end = @min(start +| self.tui.paste_bytes, self.tui.composer.items.len);
        const invalid = self.tui.paste_rejected or
            !std.unicode.utf8ValidateSlice(self.tui.composer.items[start..end]);
        if (invalid) {
            self.tui.composer.replaceRange(self.alloc, start, end - start, &.{}) catch {};
            self.tui.cursor = start;
        }
        self.tui.paste_active = false;
        self.tui.paste_end_match_len = 0;
        self.tui.paste_bytes = 0;
        self.tui.paste_rejected = false;
        self.output_mutex.unlock(io);
        if (invalid) self.setInteractiveError("Paste rejected: invalid UTF-8 or input limit exceeded");
    }

    fn insertComposerByte(self: *Client, byte: u8, pasted: bool) void {
        if (self.tui.composer.items.len >= contracts.max_frame_bytes) {
            if (pasted) self.tui.paste_rejected = true;
            return;
        }
        self.tui.composer.insert(self.alloc, self.tui.cursor, byte) catch {
            if (pasted) self.tui.paste_rejected = true;
            return;
        };
        self.tui.cursor += 1;
        if (pasted) self.tui.paste_bytes += 1;
    }

    fn insertPastedByte(self: *Client, byte: u8) void {
        if (self.tui.paste_rejected) return;
        const normalized = if (byte == '\r') '\n' else byte;
        if (normalized != '\n' and normalized != '\t' and normalized < 0x20) return;
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        self.insertComposerByte(normalized, true);
        self.output_mutex.unlock(io);
    }

    fn processPasteByte(self: *Client, byte: u8) void {
        const end_marker = "\x1b[201~";
        if (self.tui.paste_end_match_len == 0) {
            if (byte == end_marker[0]) {
                self.tui.paste_end_match_len = 1;
            } else self.insertPastedByte(byte);
            return;
        }
        if (byte == end_marker[self.tui.paste_end_match_len]) {
            self.tui.paste_end_match_len += 1;
            if (self.tui.paste_end_match_len == end_marker.len) self.finishPaste();
            return;
        }

        // A non-marker escape is untrusted C0 input, but bytes after that ESC
        // are ordinary paste payload and must not be swallowed.
        const matched = self.tui.paste_end_match_len;
        self.tui.paste_end_match_len = 0;
        for (end_marker[1..matched]) |matched_byte| self.insertPastedByte(matched_byte);
        if (byte == end_marker[0])
            self.tui.paste_end_match_len = 1
        else
            self.insertPastedByte(byte);
    }

    fn processTuiByte(self: *Client, byte: u8) bool {
        if (!self.hasAuthority()) {
            if (byte == 3 or byte == 4) return false;
            if (self.intent == .observer and (byte == 'q' or byte == 'Q')) return false;
            return true;
        }
        if (self.tui.paste_active) {
            self.processPasteByte(byte);
            return true;
        }
        if (self.tui.escape_state == .escape) {
            self.tui.escape_state = if (byte == '[') .csi else .none;
            self.tui.csi_len = 0;
            return true;
        }
        if (self.tui.escape_state == .csi) {
            if (self.tui.csi_len < self.tui.csi.len) {
                self.tui.csi[self.tui.csi_len] = byte;
                self.tui.csi_len += 1;
            }
            if ((byte >= 'A' and byte <= 'Z') or byte == '~') {
                const sequence = self.tui.csi[0..self.tui.csi_len];
                self.tui.escape_state = .none;
                if (std.mem.eql(u8, sequence, "200~")) {
                    self.beginPaste();
                    return true;
                }
                const io = io_mod.getIo();
                self.output_mutex.lockUncancelable(io);
                if (std.mem.eql(u8, sequence, "D"))
                    self.tui.cursor = previousDisplayBoundary(self.tui.composer.items, self.tui.cursor)
                else if (std.mem.eql(u8, sequence, "C"))
                    self.tui.cursor = nextDisplayBoundary(self.tui.composer.items, self.tui.cursor)
                else if (std.mem.eql(u8, sequence, "H") or std.mem.eql(u8, sequence, "1~"))
                    self.tui.cursor = 0
                else if (std.mem.eql(u8, sequence, "F") or std.mem.eql(u8, sequence, "4~"))
                    self.tui.cursor = self.tui.composer.items.len
                else if (std.mem.eql(u8, sequence, "3~") and self.tui.cursor < self.tui.composer.items.len) {
                    const end = nextDisplayBoundary(self.tui.composer.items, self.tui.cursor);
                    self.tui.composer.replaceRange(self.alloc, self.tui.cursor, end - self.tui.cursor, &.{}) catch {};
                }
                self.output_mutex.unlock(io);
            }
            return true;
        }
        if (byte == 0x1b) {
            self.tui.escape_state = .escape;
            return true;
        }
        if (byte == '\r' or byte == '\n') return self.submitComposer();
        if (byte == 3) {
            const io = io_mod.getIo();
            self.output_mutex.lockUncancelable(io);
            const running = !std.mem.eql(u8, self.projection.run_state, "idle");
            self.output_mutex.unlock(io);
            if (running) {
                self.sendSimpleMutation("fx/abort", "") catch |err| self.setInteractiveError(@errorName(err));
                return true;
            }
            return false;
        }
        if (byte == 4) {
            if (self.tui.composer.items.len == 0) return false;
            return true;
        }
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        defer self.output_mutex.unlock(io);
        switch (byte) {
            1 => self.tui.cursor = 0,
            5 => self.tui.cursor = self.tui.composer.items.len,
            12 => {},
            21 => {
                self.tui.composer.clearRetainingCapacity();
                self.tui.cursor = 0;
            },
            0x7f, 0x08 => if (self.tui.cursor > 0) {
                const start = previousDisplayBoundary(self.tui.composer.items, self.tui.cursor);
                self.tui.composer.replaceRange(self.alloc, start, self.tui.cursor - start, &.{}) catch {};
                self.tui.cursor = start;
            },
            else => if (byte >= 0x20) self.insertComposerByte(byte, false),
        }
        return true;
    }

    fn sendPrompt(self: *Client, text: []const u8) !u64 {
        var operation_buffer: [32]u8 = undefined;
        const operation_id = try contracts.randomId(io_mod.getIo(), &operation_buffer);
        const request_id = self.requestId();
        var request: std.Io.Writer.Allocating = .init(self.alloc);
        defer request.deinit();
        try request.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"fx/prompt\",\"params\":{{\"attachmentId\":", .{request_id});
        try jsonrpc.writeJsonStr(self.attachmentSlice(), &request.writer);
        try request.writer.print(",\"controlEpoch\":{d},\"operationId\":", .{self.control_epoch.load(.acquire)});
        try jsonrpc.writeJsonStr(operation_id, &request.writer);
        try request.writer.writeAll(",\"prompt\":[{\"type\":\"text\",\"text\":");
        try jsonrpc.writeJsonStr(text, &request.writer);
        try request.writer.writeAll("}]}}");
        try self.trackPromptAdmission(request_id, text);
        self.send(request.writer.buffered()) catch |err| {
            self.completePromptAdmission(request_id, false);
            return err;
        };
        return request_id;
    }

    fn sendSimpleMutation(self: *Client, method: []const u8, extra_json: []const u8) !void {
        const request_id = self.requestId();
        var request: std.Io.Writer.Allocating = .init(self.alloc);
        defer request.deinit();
        try request.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{request_id});
        try jsonrpc.writeJsonStr(method, &request.writer);
        try request.writer.writeAll(",\"params\":{\"attachmentId\":");
        try jsonrpc.writeJsonStr(self.attachmentSlice(), &request.writer);
        try request.writer.print(",\"controlEpoch\":{d}", .{self.control_epoch.load(.acquire)});
        if (extra_json.len > 0) {
            try request.writer.writeByte(',');
            try request.writer.writeAll(extra_json);
        }
        try request.writer.writeAll("}}");
        try self.send(request.writer.buffered());
    }

    fn respondPermission(self: *Client, option: []const u8) !void {
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        const interaction_id = self.pending_interaction.load(.acquire);
        const permission_pending = if (self.projection.pending) |pending|
            pendingSupportsPermissionShortcuts(pending.method)
        else
            false;
        self.output_mutex.unlock(io);
        if (interaction_id == 0 or !permission_pending) return error.NoPendingPermission;
        var extra: [512]u8 = undefined;
        const json = try std.fmt.bufPrint(
            &extra,
            "\"interactionId\":{d},\"result\":{{\"outcome\":{{\"outcome\":\"selected\",\"optionId\":\"{s}\"}}}}",
            .{ interaction_id, option },
        );
        try self.sendSimpleMutation("fx/respond", json);
    }

    fn configure(self: *Client, kind: []const u8, value: []const u8) !void {
        var extra: std.Io.Writer.Allocating = .init(self.alloc);
        defer extra.deinit();
        try extra.writer.writeAll("\"kind\":");
        try jsonrpc.writeJsonStr(kind, &extra.writer);
        try extra.writer.writeAll(",\"value\":");
        try jsonrpc.writeJsonStr(value, &extra.writer);
        try self.sendSimpleMutation("fx/configure", extra.writer.buffered());
    }

    fn detach(self: *Client) void {
        var request: std.Io.Writer.Allocating = .init(self.alloc);
        defer request.deinit();
        request.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"fx/detach\",\"params\":{{\"attachmentId\":", .{self.requestId()}) catch return;
        jsonrpc.writeJsonStr(self.attachmentSlice(), &request.writer) catch return;
        request.writer.writeAll("}}") catch return;
        self.send(request.writer.buffered()) catch {};
    }
};

pub fn run(alloc: Allocator, options: Options) !void {
    const endpoint = try endpoint_mod.parse(options.endpoint, false);
    switch (endpoint) {
        .unix => |path| {
            const address = try std.Io.net.UnixAddress.init(path);
            const stream = try address.connect(io_mod.getIo());
            var wire_state: UnixClientWire = undefined;
            wire_state.init(stream);
            return runWithWire(alloc, options, wire_state.wire());
        },
        .websocket => |websocket| {
            const wire_state = try WebSocketClientWire.connect(alloc, websocket);
            defer wire_state.destroy();
            return runWithWire(alloc, options, wire_state.wire());
        },
    }
}

fn runWithWire(alloc: Allocator, options: Options, wire: Wire) !void {
    const interactive = std.c.isatty(std.posix.STDIN_FILENO) != 0 and
        std.c.isatty(std.posix.STDOUT_FILENO) != 0;
    const intent: contracts.Role = if (options.observe) .observer else if (options.primary) .primary else .controller;
    var client = Client.init(alloc, wire, interactive, intent);
    defer client.deinit();
    try client.initializeAndAttach(options);
    if (interactive) try client.enterTui();
    var input_thread = try std.Thread.spawn(.{}, inputMain, .{&client});
    defer {
        client.stopping.store(true, .release);
        client.wire.interrupt();
        input_thread.join();
    }
    try client.readUntilEof();
}

fn inputMain(client: *Client) void {
    if (client.interactive)
        inputMainTui(client)
    else
        inputMainLines(client);
    if (!client.stopping.load(.acquire)) client.detach();
    client.stopping.store(true, .release);
    client.wire.interrupt();
}

fn pollStdin(timeout_ms: i32) ?std.posix.pollfd {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    _ = std.posix.poll(&poll_fds, timeout_ms) catch return null;
    return poll_fds[0];
}

fn inputMainTui(client: *Client) void {
    var buffer: [256]u8 = undefined;
    while (!client.stopping.load(.acquire)) {
        const ready = pollStdin(50) orelse break;
        if (ready.revents == 0) {
            client.refreshTuiGeometry() catch break;
            continue;
        }
        if (ready.revents & std.posix.POLL.IN == 0) break;
        const count = std.posix.read(std.posix.STDIN_FILENO, &buffer) catch break;
        if (count == 0) break;
        for (buffer[0..count]) |byte| {
            if (!client.processTuiByte(byte)) return;
        }
        if (!client.tui.paste_active) client.redrawTui();
        client.refreshTuiGeometry() catch break;
    }
}

fn inputMainLines(client: *Client) void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(client.alloc);
    var overflowed = false;
    var buffer: [4096]u8 = undefined;
    while (!client.stopping.load(.acquire)) {
        const ready = pollStdin(100) orelse break;
        if (ready.revents == 0) continue;
        const count = std.posix.read(std.posix.STDIN_FILENO, &buffer) catch break;
        if (count == 0) break;
        for (buffer[0..count]) |byte| {
            if (byte != '\n') {
                if (!overflowed) {
                    if (line.items.len >= contracts.max_frame_bytes)
                        overflowed = true
                    else
                        line.append(client.alloc, byte) catch return;
                }
                continue;
            }
            if (overflowed) {
                if (!client.interactive) {
                    const io = io_mod.getIo();
                    client.output_mutex.lockUncancelable(io);
                    std.Io.File.stderr().writeStreamingAll(io, "fx attach: input exceeds frame limit\n") catch {};
                    client.output_mutex.unlock(io);
                }
            } else {
                const trimmed = std.mem.trim(u8, line.items, " \t\r\n");
                if (trimmed.len > 0 and !handleInputLine(client, trimmed, null)) return;
            }
            line.clearRetainingCapacity();
            overflowed = false;
        }
    }
}

fn handleInputLine(client: *Client, line: []const u8, was_prompt: ?*bool) bool {
    if (std.mem.eql(u8, line, "/detach")) return false;
    if (!client.hasAuthority()) {
        client.reportInputError("This presentation is read-only while another controller is attached; use /detach to leave");
        return true;
    }
    if (std.mem.eql(u8, line, "/abort")) {
        client.sendSimpleMutation("fx/abort", "") catch |err| {
            client.reportInputError(@errorName(err));
            return true;
        };
    } else if (std.mem.eql(u8, line, "/allow")) {
        client.respondPermission("allow_once") catch |err| {
            client.reportInputError(@errorName(err));
            return true;
        };
    } else if (std.mem.eql(u8, line, "/always")) {
        client.respondPermission("allow_always") catch |err| {
            client.reportInputError(@errorName(err));
            return true;
        };
    } else if (std.mem.eql(u8, line, "/deny")) {
        client.respondPermission("reject_once") catch |err| {
            client.reportInputError(@errorName(err));
            return true;
        };
    } else if (std.mem.startsWith(u8, line, "/model ")) {
        client.configure("model", std.mem.trim(u8, line[7..], " \t")) catch |err| {
            client.reportInputError(@errorName(err));
            return true;
        };
    } else if (std.mem.startsWith(u8, line, "/mode ")) {
        client.configure("mode", std.mem.trim(u8, line[6..], " \t")) catch |err| {
            client.reportInputError(@errorName(err));
            return true;
        };
    } else if (std.mem.startsWith(u8, line, "/respond ")) {
        const interaction_id = client.pending_interaction.load(.acquire);
        if (interaction_id == 0) {
            client.reportInputError("No remote interaction is pending");
            return true;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, client.alloc, line[9..], .{}) catch {
            client.reportInputError("/respond requires valid JSON");
            return true;
        };
        defer parsed.deinit();
        var extra: std.Io.Writer.Allocating = .init(client.alloc);
        defer extra.deinit();
        extra.writer.print("\"interactionId\":{d},\"result\":", .{interaction_id}) catch return false;
        std.json.Stringify.value(parsed.value, .{}, &extra.writer) catch return false;
        client.sendSimpleMutation("fx/respond", extra.writer.buffered()) catch |err| {
            client.reportInputError(@errorName(err));
            return true;
        };
    } else {
        if (was_prompt) |value| value.* = true;
        _ = client.sendPrompt(line) catch |err| {
            client.reportInputError(@errorName(err));
            return true;
        };
    }
    return true;
}

fn writeTerminalSafe(file: std.Io.File, io: std.Io, text: []const u8) !void {
    var view = std.unicode.Utf8View.init(text) catch return;
    var iterator = view.iterator();
    while (iterator.nextCodepointSlice()) |slice| {
        const codepoint = std.unicode.utf8Decode(slice) catch continue;
        if (terminalSafeCodepoint(codepoint)) try file.writeStreamingAll(io, slice);
    }
}

fn terminalSafeCodepoint(codepoint: u21) bool {
    return codepoint == '\n' or codepoint == '\t' or
        (codepoint >= 0x20 and !(codepoint >= 0x7f and codepoint <= 0x9f));
}

fn semanticToolContentText(update: std.json.Value) ?[]const u8 {
    if (update != .object) return null;
    const content = update.object.get("content") orelse return null;
    if (content != .array or content.array.items.len == 0) return null;
    const first = content.array.items[0];
    if (first != .object) return null;
    const nested = first.object.get("content") orelse return null;
    return stringField(nested, "text");
}

fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

test "base64 snapshot chunks reassemble multibyte UTF-8 across the old boundary" {
    const alloc = std.testing.allocator;
    const original = try alloc.alloc(u8, contracts.snapshot_chunk_bytes + 3);
    defer alloc.free(original);
    @memset(original, 'a');
    @memcpy(original[contracts.snapshot_chunk_bytes - 1 .. contracts.snapshot_chunk_bytes + 2], "✓");
    var client = Client.init(alloc, undefined, false, .controller);
    defer {
        client.snapshot_bytes.deinit(alloc);
        client.projection.deinit();
        client.tui.deinit(alloc);
    }
    for ([_][]const u8{ original[0..contracts.snapshot_chunk_bytes], original[contracts.snapshot_chunk_bytes..] }) |chunk| {
        const encoded_len = std.base64.standard.Encoder.calcSize(chunk.len);
        const encoded = try alloc.alloc(u8, encoded_len);
        defer alloc.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, chunk);
        try client.appendBase64SnapshotChunk(encoded);
    }
    try std.testing.expectEqualSlices(u8, original, client.snapshot_bytes.items);
    try std.testing.expect(std.unicode.utf8ValidateSlice(client.snapshot_bytes.items));
}

test "known malformed semantic event is a protocol error" {
    var client = Client.init(std.testing.allocator, undefined, false, .controller);
    defer {
        client.snapshot_bytes.deinit(std.testing.allocator);
        client.projection.deinit();
        client.tui.deinit(std.testing.allocator);
    }
    try std.testing.expectError(
        error.InvalidSemanticEvent,
        client.renderMessage("{\"jsonrpc\":\"2.0\",\"method\":\"fx/event\",\"params\":{}}"),
    );
    try client.renderMessage("{\"jsonrpc\":\"2.0\",\"method\":\"fx/future\",\"params\":{}}");
}

test "remote projection installs snapshot and fences revisioned events" {
    const alloc = std.testing.allocator;
    var projection = RemoteProjection.init(alloc);
    defer projection.deinit();
    var snapshot = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"sessionId\":\"session-1\",\"revision\":4,\"runState\":\"idle\",\"history\":[{\"role\":\"assistant\",\"text\":\"before\"}],\"assistantPartial\":\"\",\"tools\":[],\"configuration\":{\"model\":\"model-1\",\"mode\":\"ask\"},\"pendingInteraction\":null,\"operations\":[]}",
        .{},
    );
    defer snapshot.deinit();
    try projection.installSnapshot(snapshot.value);
    try std.testing.expectEqual(@as(u64, 4), projection.revision);
    try std.testing.expectEqualStrings("before", projection.history.items[0].text);
    try std.testing.expectEqualStrings("model-1", projection.model.?);

    var event = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"attachmentId\":\"attachment-1\",\"revision\":5,\"event\":{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"user_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"after\"}}}}}",
        .{},
    );
    defer event.deinit();
    _ = try projection.applyEventEnvelope("attachment-1", event.value);
    try std.testing.expectEqual(@as(u64, 5), projection.revision);
    try std.testing.expectEqualStrings("after", projection.history.items[1].text);
    try std.testing.expectError(error.RemoteRevisionGap, projection.applyEventEnvelope("attachment-1", event.value));
    try std.testing.expectError(error.StaleAttachmentEvent, projection.applyEventEnvelope("other-attachment", event.value));
}

test "snapshot operation hydration preserves current partial and pending interaction" {
    const alloc = std.testing.allocator;
    var projection = RemoteProjection.init(alloc);
    defer projection.deinit();
    var snapshot = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"sessionId\":\"session-1\",\"revision\":9,\"runState\":\"running\",\"history\":[],\"assistantPartial\":\"CURRENT_PARTIAL\",\"tools\":[],\"configuration\":{},\"pendingInteraction\":{\"id\":42,\"method\":\"elicitation/create\",\"params\":{\"message\":\"current question\"}},\"operations\":[{\"operationId\":\"old\",\"state\":\"completed\"},{\"operationId\":\"current\",\"state\":\"running\"}]}",
        .{},
    );
    defer snapshot.deinit();

    try projection.installSnapshot(snapshot.value);
    try std.testing.expectEqualStrings("CURRENT_PARTIAL", projection.assistant_partial.items);
    try std.testing.expectEqual(@as(usize, 0), projection.history.items.len);
    try std.testing.expectEqual(@as(u64, 42), projection.pending.?.id);
    try std.testing.expectEqualStrings("current", projection.operations.items[1].id);
    try std.testing.expectEqualStrings("running", projection.operations.items[1].state);

    var completed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"attachmentId\":\"attachment-1\",\"revision\":10,\"event\":{\"method\":\"fx/operation\",\"params\":{\"operationId\":\"current\",\"state\":\"completed\"}}}",
        .{},
    );
    defer completed.deinit();
    _ = try projection.applyEventEnvelope("attachment-1", completed.value);
    try std.testing.expectEqual(@as(usize, 0), projection.assistant_partial.items.len);
    try std.testing.expectEqualStrings("CURRENT_PARTIAL", projection.history.items[0].text);
    try std.testing.expect(projection.pending == null);
}

test "remote projection evicts its oldest terminal operation at host capacity" {
    const alloc = std.testing.allocator;
    var projection = RemoteProjection.init(alloc);
    defer projection.deinit();
    for (0..contracts.max_operations_per_actor + 1) |index| {
        var encoded: std.Io.Writer.Allocating = .init(alloc);
        defer encoded.deinit();
        try encoded.writer.print(
            "{{\"operationId\":\"operation-{d}\",\"state\":\"completed\"}}",
            .{index},
        );
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded.writer.buffered(), .{});
        defer parsed.deinit();
        try projection.upsertOperation(parsed.value, .live);
    }
    try std.testing.expectEqual(contracts.max_operations_per_actor, projection.operations.items.len);
    try std.testing.expectEqualStrings("operation-1", projection.operations.items[0].id);
    try std.testing.expectEqualStrings(
        "operation-128",
        projection.operations.items[projection.operations.items.len - 1].id,
    );
}

test "remote projection fails closed at cumulative semantic byte limit" {
    const alloc = std.testing.allocator;
    var projection = RemoteProjection.init(alloc);
    defer projection.deinit();
    projection.retained_bytes = contracts.max_snapshot_bytes - 2;
    try std.testing.expectError(
        error.RemoteProjectionCapacityExceeded,
        projection.replaceOptional(&projection.last_error, "three"),
    );
    try std.testing.expect(projection.last_error == null);
    projection.retained_bytes = 0;
    try projection.replaceOptional(&projection.last_error, "three");
    try std.testing.expectEqual(@as(usize, 5), projection.retained_bytes);
    try projection.replaceOptional(&projection.last_error, "x");
    try std.testing.expectEqual(@as(usize, 1), projection.retained_bytes);
}

test "remote primary authority transitions preserve its draft" {
    const alloc = std.testing.allocator;
    var client = Client.init(alloc, undefined, true, .primary);
    defer {
        client.snapshot_bytes.deinit(alloc);
        client.projection.deinit();
        client.tui.deinit(alloc);
    }
    @memcpy(&client.attachment_id, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    client.attachment_len = client.attachment_id.len;
    try client.tui.composer.appendSlice(alloc, "preserved draft");
    client.tui.cursor = client.tui.composer.items.len;

    var owned = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"controlEpoch\":1,\"controllerAttachmentId\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}",
        .{},
    );
    defer owned.deinit();
    try client.installControlState(owned.value);
    try std.testing.expect(client.hasAuthority());

    var taken = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"controlEpoch\":2,\"controllerAttachmentId\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}",
        .{},
    );
    defer taken.deinit();
    try client.installControlState(taken.value);
    try std.testing.expect(!client.hasAuthority());
    try std.testing.expect(client.processTuiByte('q'));
    try std.testing.expect(client.processTuiByte('Q'));
    try std.testing.expectEqualStrings("preserved draft", client.tui.composer.items);

    var restored = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"controlEpoch\":3,\"controllerAttachmentId\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}",
        .{},
    );
    defer restored.deinit();
    try client.installControlState(restored.value);
    try std.testing.expect(client.hasAuthority());
    try std.testing.expectEqual(@as(u64, 3), client.control_epoch.load(.acquire));
    try std.testing.expectEqualStrings("preserved draft", client.tui.composer.items);

    try client.trackPromptAdmission(9, "preserved draft");
    client.completePromptAdmission(9, false);
    try std.testing.expectEqualStrings("preserved draft", client.tui.composer.items);
    try std.testing.expectEqual(@as(u64, 0), client.pending_prompt_request.load(.acquire));

    try client.trackPromptAdmission(10, "preserved draft");
    try client.tui.composer.appendSlice(alloc, " edited");
    client.completePromptAdmission(10, true);
    try std.testing.expectEqualStrings("preserved draft edited", client.tui.composer.items);

    client.tui.composer.clearRetainingCapacity();
    try client.tui.composer.appendSlice(alloc, "preserved draft");
    client.tui.cursor = client.tui.composer.items.len;
    try client.trackPromptAdmission(11, "preserved draft");
    client.completePromptAdmission(11, true);
    try std.testing.expectEqualStrings("", client.tui.composer.items);
    try std.testing.expectEqual(@as(u64, 0), client.pending_prompt_request.load(.acquire));
}

test "remote composer edits UTF-8 boundaries and observers cannot compose" {
    const alloc = std.testing.allocator;
    var controller = Client.init(alloc, undefined, true, .controller);
    controller.authority.store(true, .release);
    defer {
        controller.snapshot_bytes.deinit(alloc);
        controller.projection.deinit();
        controller.tui.deinit(alloc);
    }
    for ("a✓c") |byte| try std.testing.expect(controller.processTuiByte(byte));
    try std.testing.expect(controller.processTuiByte(0x1b));
    try std.testing.expect(controller.processTuiByte('['));
    try std.testing.expect(controller.processTuiByte('D'));
    try std.testing.expect(controller.processTuiByte(0x7f));
    try std.testing.expectEqualStrings("ac", controller.tui.composer.items);
    try std.testing.expectEqual(@as(usize, 1), controller.tui.cursor);

    for ([_][]const u8{ "👍🏽", "🇺🇸", "1️⃣", "👨‍👩‍👧‍👦" }) |cluster| {
        controller.tui.composer.clearRetainingCapacity();
        controller.tui.cursor = 0;
        try controller.tui.composer.append(alloc, 'a');
        try controller.tui.composer.appendSlice(alloc, cluster);
        try controller.tui.composer.append(alloc, 'b');
        controller.tui.cursor = controller.tui.composer.items.len;
        for ("\x1b[D") |byte| try std.testing.expect(controller.processTuiByte(byte));
        try std.testing.expect(controller.processTuiByte(0x7f));
        try std.testing.expectEqualStrings("ab", controller.tui.composer.items);
        try std.testing.expectEqual(@as(usize, 1), controller.tui.cursor);
    }

    controller.tui.composer.clearRetainingCapacity();
    controller.tui.cursor = 0;
    for ("\x1b[200~line one\x03\nline two\x04\x1b[201~") |byte|
        try std.testing.expect(controller.processTuiByte(byte));
    try std.testing.expectEqualStrings("line one\nline two", controller.tui.composer.items);
    try std.testing.expect(!controller.tui.paste_active);

    controller.tui.composer.clearRetainingCapacity();
    controller.tui.cursor = 0;
    for ("\x1b[200~before\x1b[20Xafter\x1b[201~") |byte|
        try std.testing.expect(controller.processTuiByte(byte));
    try std.testing.expectEqualStrings("before[20Xafter", controller.tui.composer.items);
    try std.testing.expect(!controller.tui.paste_active);
    try std.testing.expectEqual(@as(usize, 0), controller.tui.paste_end_match_len);

    var observer = Client.init(alloc, undefined, true, .observer);
    defer {
        observer.snapshot_bytes.deinit(alloc);
        observer.projection.deinit();
        observer.tui.deinit(alloc);
    }
    try std.testing.expect(observer.processTuiByte('x'));
    try std.testing.expectEqual(@as(usize, 0), observer.tui.composer.items.len);
    try std.testing.expect(!observer.processTuiByte('q'));
}

test "remote terminal layout projects semantic controls within row width" {
    const alloc = std.testing.allocator;
    var lines: std.ArrayList([]u8) = .empty;
    defer freeScreenLines(alloc, &lines);
    try appendWrappedScreenText(alloc, &lines, "You  ", "     ", "wide\tmessage\nnext\rline", 12);
    try std.testing.expect(lines.items.len > 1);
    for (lines.items) |line| {
        try std.testing.expect(display_width.visibleWidth(line) <= 12);
        try std.testing.expect(std.mem.findScalar(u8, line, '\t') == null);
        try std.testing.expect(std.mem.findScalar(u8, line, '\r') == null);
        try std.testing.expect(std.mem.findScalar(u8, line, '\n') == null);
    }

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try appendSingleLineScreenText(alloc, &row, "model\tname\nerror\rpending", 16);
    try std.testing.expect(display_width.visibleWidth(row.items) <= 16);
    try std.testing.expectEqualStrings("model   name err", row.items);
}

test "remote semantic model error and pending rows flatten controls" {
    const alloc = std.testing.allocator;
    var client = Client.init(alloc, undefined, true, .controller);
    defer {
        client.snapshot_bytes.deinit(alloc);
        client.projection.deinit();
        client.tui.deinit(alloc);
    }
    var snapshot = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"sessionId\":\"session\",\"revision\":1,\"runState\":\"waiting_input\",\"history\":[],\"assistantPartial\":\"\",\"tools\":[],\"configuration\":{\"model\":\"model\\tname\\nnext\",\"mode\":\"ask\"},\"pendingInteraction\":{\"id\":7,\"method\":\"session/request_permission\",\"params\":{\"title\":\"pending\\tchoice\\nnow\"}},\"operations\":[]}",
        .{},
    );
    defer snapshot.deinit();
    try client.projection.installSnapshot(snapshot.value);
    try client.projection.setError("bad\terror\nnow");

    var values: [3]std.Io.Writer.Allocating = .{
        .init(alloc),
        .init(alloc),
        .init(alloc),
    };
    defer for (&values) |*value| value.deinit();
    try values[0].writer.print("fx attach · {s}", .{client.projection.model.?});
    try client.pendingSummary(&values[1]);
    try values[2].writer.writeAll(client.projection.last_error.?);
    for (&values) |*value| {
        var row: std.ArrayList(u8) = .empty;
        defer row.deinit(alloc);
        try appendSingleLineScreenText(alloc, &row, value.writer.buffered(), 80);
        try std.testing.expect(std.mem.findScalar(u8, row.items, '\t') == null);
        try std.testing.expect(std.mem.findScalar(u8, row.items, '\n') == null);
        try std.testing.expect(std.mem.findScalar(u8, row.items, '\r') == null);
        try std.testing.expect(display_width.visibleWidth(row.items) <= 80);
    }
}

test "remote permission shortcuts reject elicitation without sending" {
    const alloc = std.testing.allocator;
    try std.testing.expect(pendingSupportsPermissionShortcuts("session/request_permission"));
    try std.testing.expect(!pendingSupportsPermissionShortcuts("elicitation/create"));
    try std.testing.expect(std.mem.find(u8, pendingInputInstructions("elicitation/create"), "/allow") == null);
    try std.testing.expect(std.mem.find(u8, pendingTuiHint("elicitation/create", false), "/allow") == null);
    try std.testing.expect(std.mem.find(u8, pendingTuiHint("session/request_permission", true), "/allow") != null);

    var client = Client.init(alloc, undefined, false, .controller);
    defer {
        client.snapshot_bytes.deinit(alloc);
        client.projection.deinit();
        client.tui.deinit(alloc);
    }
    var snapshot = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"sessionId\":\"session\",\"revision\":1,\"runState\":\"waiting_input\",\"history\":[],\"assistantPartial\":\"\",\"tools\":[],\"configuration\":{},\"pendingInteraction\":{\"id\":7,\"method\":\"elicitation/create\",\"params\":{\"message\":\"Choose\"}},\"operations\":[]}",
        .{},
    );
    defer snapshot.deinit();
    try client.projection.installSnapshot(snapshot.value);
    client.pending_interaction.store(7, .release);
    try std.testing.expectError(error.NoPendingPermission, client.respondPermission("allow_once"));
}

test "terminal sanitizer rejects escape C0 and C1 while preserving whitespace and Unicode" {
    try std.testing.expect(!terminalSafeCodepoint(0x1b));
    try std.testing.expect(!terminalSafeCodepoint(0x00));
    try std.testing.expect(!terminalSafeCodepoint(0x85));
    try std.testing.expect(terminalSafeCodepoint('\n'));
    try std.testing.expect(terminalSafeCodepoint('\t'));
    try std.testing.expect(terminalSafeCodepoint(0x2713));
}
