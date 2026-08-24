const std = @import("std");
const contracts = @import("../core/remote/contracts.zig");
const endpoint_mod = @import("../core/remote/endpoint.zig");
const jsonrpc = @import("../acp/jsonrpc.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    endpoint: []const u8,
    session_id: []const u8,
    observe: bool = false,
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

const Client = struct {
    alloc: Allocator,
    wire: Wire,
    output_mutex: std.Io.Mutex = .init,
    stopping: std.atomic.Value(bool) = .init(false),
    attachment_id: [32]u8 = @splat(0),
    attachment_len: usize = 0,
    control_epoch: u64 = 0,
    next_request_id: std.atomic.Value(u64) = .init(10),
    pending_interaction: std.atomic.Value(u64) = .init(0),
    snapshot_id: [32]u8 = @splat(0),
    snapshot_chunk_count: usize = 0,
    snapshot_next_chunk: usize = 0,
    snapshot_bytes: std.ArrayList(u8) = .empty,

    fn init(alloc: Allocator, wire: Wire) Client {
        return .{ .alloc = alloc, .wire = wire };
    }

    fn deinit(self: *Client) void {
        self.stopping.store(true, .release);
        self.wire.close();
        self.snapshot_bytes.deinit(self.alloc);
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
        try jsonrpc.writeJsonStr(if (options.observe) "observer" else "controller", &attach.writer);
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
        self.control_epoch = @intCast(epoch.integer);
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

    fn renderSnapshot(self: *Client, snapshot: std.json.Value) !void {
        if (snapshot != .object) return;
        const stdout = std.Io.File.stdout();
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        defer self.output_mutex.unlock(io);
        const session_id = stringField(snapshot, "sessionId") orelse "unknown";
        const run_state = stringField(snapshot, "runState") orelse "unknown";
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

    fn renderMessage(self: *Client, message: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, message, .{}) catch return error.InvalidRemoteJson;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidRemoteMessage;
        if (parsed.value.object.get("error")) |err| return self.renderError(err);
        const method = stringField(parsed.value, "method") orelse return;
        if (std.mem.eql(u8, method, "fx/snapshot/chunk")) return self.acceptSnapshotChunk(parsed.value);
        if (!std.mem.eql(u8, method, "fx/event")) return;
        const params = parsed.value.object.get("params") orelse return error.InvalidSemanticEvent;
        if (params != .object) return error.InvalidSemanticEvent;
        const event = params.object.get("event") orelse return error.InvalidSemanticEvent;
        if (event != .object) return error.InvalidSemanticEvent;
        const event_method = stringField(event, "method") orelse return error.InvalidSemanticEvent;
        if (std.mem.eql(u8, event_method, "session/update")) {
            const event_params = event.object.get("params") orelse return error.InvalidSemanticEvent;
            if (event_params != .object) return error.InvalidSemanticEvent;
            const update = event_params.object.get("update") orelse return error.InvalidSemanticEvent;
            try self.renderUpdate(update);
        } else if (std.mem.eql(u8, event_method, "session/request_permission") or
            std.mem.eql(u8, event_method, "elicitation/create"))
        {
            const event_id = event.object.get("id") orelse return error.InvalidSemanticEvent;
            if (event_id == .integer and event_id.integer > 0) self.pending_interaction.store(@intCast(event_id.integer), .release);
            try self.renderPending(event);
        } else if (std.mem.eql(u8, event_method, "fx/operation")) {
            const op_params = event.object.get("params") orelse return error.InvalidSemanticEvent;
            try self.renderOperation(op_params);
        } else if (std.mem.eql(u8, event_method, "fx/run_state")) {
            const state_params = event.object.get("params") orelse return error.InvalidSemanticEvent;
            try self.renderRunState(state_params);
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
        if (std.mem.eql(u8, kind, "agent_message_chunk")) {
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
        try stdout.writeStreamingAll(io, "Use /allow, /always, /deny, or /respond <json>.\n");
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

    fn sendPrompt(self: *Client, text: []const u8) !void {
        const io = io_mod.getIo();
        self.output_mutex.lockUncancelable(io);
        std.Io.File.stdout().writeStreamingAll(io, "You: ") catch {};
        writeTerminalSafe(std.Io.File.stdout(), io, text) catch {};
        std.Io.File.stdout().writeStreamingAll(io, "\n") catch {};
        self.output_mutex.unlock(io);
        var operation_buffer: [32]u8 = undefined;
        const operation_id = try contracts.randomId(io_mod.getIo(), &operation_buffer);
        const request_id = self.requestId();
        var request: std.Io.Writer.Allocating = .init(self.alloc);
        defer request.deinit();
        try request.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"fx/prompt\",\"params\":{{\"attachmentId\":", .{request_id});
        try jsonrpc.writeJsonStr(self.attachmentSlice(), &request.writer);
        try request.writer.print(",\"controlEpoch\":{d},\"operationId\":", .{self.control_epoch});
        try jsonrpc.writeJsonStr(operation_id, &request.writer);
        try request.writer.writeAll(",\"prompt\":[{\"type\":\"text\",\"text\":");
        try jsonrpc.writeJsonStr(text, &request.writer);
        try request.writer.writeAll("}]}}");
        try self.send(request.writer.buffered());
    }

    fn sendSimpleMutation(self: *Client, method: []const u8, extra_json: []const u8) !void {
        const request_id = self.requestId();
        var request: std.Io.Writer.Allocating = .init(self.alloc);
        defer request.deinit();
        try request.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{request_id});
        try jsonrpc.writeJsonStr(method, &request.writer);
        try request.writer.writeAll(",\"params\":{\"attachmentId\":");
        try jsonrpc.writeJsonStr(self.attachmentSlice(), &request.writer);
        try request.writer.print(",\"controlEpoch\":{d}", .{self.control_epoch});
        if (extra_json.len > 0) {
            try request.writer.writeByte(',');
            try request.writer.writeAll(extra_json);
        }
        try request.writer.writeAll("}}");
        try self.send(request.writer.buffered());
    }

    fn respondPermission(self: *Client, option: []const u8) !void {
        const interaction_id = self.pending_interaction.load(.acquire);
        if (interaction_id == 0) return error.NoPendingInteraction;
        var extra: [512]u8 = undefined;
        const json = try std.fmt.bufPrint(
            &extra,
            "\"interactionId\":{d},\"result\":{{\"outcome\":{{\"outcome\":\"selected\",\"optionId\":\"{s}\"}}}}",
            .{ interaction_id, option },
        );
        try self.sendSimpleMutation("fx/respond", json);
        self.pending_interaction.store(0, .release);
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
    var client = Client.init(alloc, wire);
    defer client.deinit();
    try client.initializeAndAttach(options);
    var input_thread = try std.Thread.spawn(.{}, inputMain, .{&client});
    defer {
        client.stopping.store(true, .release);
        client.wire.interrupt();
        input_thread.join();
    }
    try client.readUntilEof();
}

fn inputMain(client: *Client) void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(client.alloc);
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io_mod.getIo(), &stdin_buffer);
    while (!client.stopping.load(.acquire)) {
        if (comptime @import("builtin").os.tag != .windows) {
            var poll_fds = [_]std.posix.pollfd{.{ .fd = std.Io.File.stdin().handle, .events = std.posix.POLL.IN, .revents = 0 }};
            _ = std.posix.poll(&poll_fds, 100) catch break;
            if (poll_fds[0].revents == 0) continue;
        }
        const byte = stdin_reader.interface.takeByte() catch break;
        if (byte != '\n') {
            if (line.items.len < contracts.max_frame_bytes) line.append(client.alloc, byte) catch break;
            continue;
        }
        const trimmed = std.mem.trim(u8, line.items, " \t\r\n");
        if (trimmed.len > 0 and !handleInputLine(client, trimmed)) break;
        line.clearRetainingCapacity();
    }
    if (!client.stopping.load(.acquire)) client.detach();
    client.stopping.store(true, .release);
    client.wire.interrupt();
}

fn handleInputLine(client: *Client, line: []const u8) bool {
    if (std.mem.eql(u8, line, "/detach")) return false;
    if (std.mem.eql(u8, line, "/abort")) {
        client.sendSimpleMutation("fx/abort", "") catch return false;
    } else if (std.mem.eql(u8, line, "/allow")) {
        client.respondPermission("allow_once") catch return false;
    } else if (std.mem.eql(u8, line, "/always")) {
        client.respondPermission("allow_always") catch return false;
    } else if (std.mem.eql(u8, line, "/deny")) {
        client.respondPermission("reject_once") catch return false;
    } else if (std.mem.startsWith(u8, line, "/model ")) {
        client.configure("model", std.mem.trim(u8, line[7..], " \t")) catch return false;
    } else if (std.mem.startsWith(u8, line, "/mode ")) {
        client.configure("mode", std.mem.trim(u8, line[6..], " \t")) catch return false;
    } else if (std.mem.startsWith(u8, line, "/respond ")) {
        const interaction_id = client.pending_interaction.load(.acquire);
        if (interaction_id == 0) return true;
        var extra: std.Io.Writer.Allocating = .init(client.alloc);
        defer extra.deinit();
        extra.writer.print("\"interactionId\":{d},\"result\":", .{interaction_id}) catch return false;
        extra.writer.writeAll(line[9..]) catch return false;
        client.sendSimpleMutation("fx/respond", extra.writer.buffered()) catch return false;
        client.pending_interaction.store(0, .release);
    } else {
        client.sendPrompt(line) catch return false;
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
    var client = Client.init(alloc, undefined);
    defer client.snapshot_bytes.deinit(alloc);
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
    var client = Client.init(std.testing.allocator, undefined);
    defer client.snapshot_bytes.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidSemanticEvent,
        client.renderMessage("{\"jsonrpc\":\"2.0\",\"method\":\"fx/event\",\"params\":{}}"),
    );
    try client.renderMessage("{\"jsonrpc\":\"2.0\",\"method\":\"fx/future\",\"params\":{}}");
}

test "terminal sanitizer rejects escape C0 and C1 while preserving whitespace and Unicode" {
    try std.testing.expect(!terminalSafeCodepoint(0x1b));
    try std.testing.expect(!terminalSafeCodepoint(0x00));
    try std.testing.expect(!terminalSafeCodepoint(0x85));
    try std.testing.expect(terminalSafeCodepoint('\n'));
    try std.testing.expect(terminalSafeCodepoint('\t'));
    try std.testing.expect(terminalSafeCodepoint(0x2713));
}
