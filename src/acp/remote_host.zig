const std = @import("std");
const builtin = @import("builtin");
const acp_server = @import("server.zig");
const acp_types = @import("types.zig");
const jsonrpc = @import("jsonrpc.zig");
const prompt_projection = @import("prompt_projection.zig");
const contracts = @import("../core/remote/contracts.zig");
const endpoint_mod = @import("../core/remote/endpoint.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;
const Endpoint = endpoint_mod.Endpoint;

fn writeSanitizedJsonValue(alloc: Allocator, writer: *std.Io.Writer, value: std.json.Value) !void {
    switch (value) {
        .string => |text| {
            const sanitized = try contracts.sanitizeSemanticAlloc(alloc, text);
            defer alloc.free(sanitized);
            try jsonrpc.writeJsonStr(sanitized, writer);
        },
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                try writeSanitizedJsonValue(alloc, writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |object| {
            try writer.writeByte('{');
            var iterator = object.iterator();
            var index: usize = 0;
            while (iterator.next()) |entry| : (index += 1) {
                if (index > 0) try writer.writeByte(',');
                try jsonrpc.writeJsonStr(entry.key_ptr.*, writer);
                try writer.writeByte(':');
                try writeSanitizedJsonValue(alloc, writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
        else => try std.json.Stringify.value(value, .{}, writer),
    }
}

pub const ServeOptions = struct {
    listen: []const u8,
    tailscale_capability: []const u8 = contracts.default_capability,
};

const BytePipe = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    bytes: std.ArrayList(u8) = .empty,
    read_offset: usize = 0,
    closed: bool = false,

    fn init(alloc: Allocator) BytePipe {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *BytePipe) void {
        self.bytes.deinit(self.alloc);
        self.* = undefined;
    }

    fn append(self: *BytePipe, bytes: []const u8) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed) return error.PipeClosed;
        const pending = self.bytes.items.len - self.read_offset;
        const next_len = std.math.add(usize, pending, bytes.len) catch return error.PipeCapacityExceeded;
        if (next_len > contracts.max_frame_bytes * 2) return error.PipeCapacityExceeded;
        if (self.read_offset > 0) {
            const remaining = self.bytes.items.len - self.read_offset;
            std.mem.copyForwards(u8, self.bytes.items[0..remaining], self.bytes.items[self.read_offset..]);
            self.bytes.items.len = remaining;
            self.read_offset = 0;
        }
        try self.bytes.appendSlice(self.alloc, bytes);
        self.changed.signal(io);
    }

    fn close(self: *BytePipe) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.changed.broadcast(io);
        self.mutex.unlock(io);
    }

    fn read(raw: ?*anyopaque, destination: []u8) usize {
        const self: *BytePipe = @ptrCast(@alignCast(raw.?));
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.read_offset == self.bytes.items.len and !self.closed) {
            self.changed.waitUncancelable(io, &self.mutex);
        }
        if (self.read_offset == self.bytes.items.len) return 0;
        const count = @min(destination.len, self.bytes.items.len - self.read_offset);
        @memcpy(destination[0..count], self.bytes.items[self.read_offset .. self.read_offset + count]);
        self.read_offset += count;
        if (self.read_offset == self.bytes.items.len) {
            self.bytes.clearRetainingCapacity();
            self.read_offset = 0;
        }
        return count;
    }
};

const OutboundQueue = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    messages: std.ArrayList([]u8) = .empty,
    bytes: usize = 0,
    closed: bool = false,
    overflowed: bool = false,
    overflow_context: ?*anyopaque = null,
    overflow_fn: ?*const fn (*anyopaque) void = null,

    fn init(alloc: Allocator) OutboundQueue {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *OutboundQueue) void {
        for (self.messages.items) |message| self.alloc.free(message);
        self.messages.deinit(self.alloc);
        self.* = undefined;
    }

    fn enqueue(self: *OutboundQueue, bytes: []const u8) !void {
        if (bytes.len == 0 or bytes.len > contracts.max_frame_bytes) return error.FrameTooLarge;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        if (self.closed) {
            self.mutex.unlock(io);
            return error.ConnectionClosed;
        }
        if (self.messages.items.len >= contracts.max_outbound_messages or
            self.bytes > contracts.max_outbound_bytes -| bytes.len)
        {
            self.overflowed = true;
            self.closed = true;
            self.changed.broadcast(io);
            const overflow_context = self.overflow_context;
            const overflow_fn = self.overflow_fn;
            self.mutex.unlock(io);
            if (overflow_context) |context| if (overflow_fn) |notify| notify(context);
            return error.OutboundCapacityExceeded;
        }
        defer self.mutex.unlock(io);
        const owned = try self.alloc.dupe(u8, bytes);
        errdefer self.alloc.free(owned);
        try self.messages.append(self.alloc, owned);
        self.bytes += owned.len;
        self.changed.signal(io);
    }

    fn enqueueBlocking(self: *OutboundQueue, bytes: []const u8) !void {
        if (bytes.len == 0 or bytes.len > contracts.max_frame_bytes) return error.FrameTooLarge;
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.closed and (self.messages.items.len >= contracts.max_outbound_messages or
            self.bytes > contracts.max_outbound_bytes -| bytes.len))
            self.changed.waitUncancelable(io, &self.mutex);
        if (self.closed) return error.ConnectionClosed;
        const owned = try self.alloc.dupe(u8, bytes);
        errdefer self.alloc.free(owned);
        try self.messages.append(self.alloc, owned);
        self.bytes += owned.len;
        self.changed.signal(io);
    }

    fn take(self: *OutboundQueue) ?[]u8 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.messages.items.len == 0 and !self.closed) {
            self.changed.waitUncancelable(io, &self.mutex);
        }
        if (self.messages.items.len == 0) return null;
        const message = self.messages.orderedRemove(0);
        self.bytes -= message.len;
        self.changed.broadcast(io);
        return message;
    }

    fn close(self: *OutboundQueue) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.changed.broadcast(io);
        self.mutex.unlock(io);
    }

    fn interruptOwner(self: *OutboundQueue) void {
        if (self.overflow_context) |context| if (self.overflow_fn) |notify| notify(context);
    }

    fn callback(raw: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *OutboundQueue = @ptrCast(@alignCast(raw.?));
        try self.enqueue(bytes);
    }
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

const UnixWire = struct {
    stream: std.Io.net.Stream,
    read_buffer: [64 * 1024]u8 = undefined,
    write_buffer: [64 * 1024]u8 = undefined,
    reader: std.Io.net.Stream.Reader = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    write_mutex: std.Io.Mutex = .init,
    closed: std.atomic.Value(bool) = .init(false),

    fn init(self: *UnixWire, stream: std.Io.net.Stream) void {
        self.* = .{ .stream = stream };
        self.reader = stream.reader(io_mod.getIo(), &self.read_buffer);
        self.writer = stream.writer(io_mod.getIo(), &self.write_buffer);
    }

    fn wire(self: *UnixWire) Wire {
        return .{ .context = self, .read_fn = read, .write_fn = write, .interrupt_fn = interrupt, .close_fn = close };
    }

    fn read(raw: *anyopaque, alloc: Allocator) !?[]u8 {
        const self: *UnixWire = @ptrCast(@alignCast(raw));
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

    fn write(raw: *anyopaque, bytes_value: []const u8) !void {
        const self: *UnixWire = @ptrCast(@alignCast(raw));
        const bytes = std.mem.trimEnd(u8, bytes_value, "\r\n");
        const io = io_mod.getIo();
        self.write_mutex.lockUncancelable(io);
        defer self.write_mutex.unlock(io);
        try self.writer.interface.writeAll(bytes);
        try self.writer.interface.writeByte('\n');
        try self.writer.interface.flush();
    }

    fn interrupt(raw: *anyopaque) void {
        const self: *UnixWire = @ptrCast(@alignCast(raw));
        self.stream.shutdown(io_mod.getIo(), .both) catch {};
    }

    fn close(raw: *anyopaque) void {
        const self: *UnixWire = @ptrCast(@alignCast(raw));
        if (self.closed.swap(true, .acq_rel)) return;
        self.stream.shutdown(io_mod.getIo(), .both) catch {};
        self.stream.close(io_mod.getIo());
    }
};

const Projection = struct {
    complete: bool = true,
    history: std.ArrayList(contracts.HistoryItem) = .empty,
    assistant_partial: std.ArrayList(u8) = .empty,
    tools: std.ArrayList(contracts.ToolRecord) = .empty,
    run_state: contracts.RunState = .idle,
    config_json: []u8 = &.{},
    current_model: ?[]u8 = null,
    current_mode: ?[]u8 = null,
    available_modes: std.ArrayList([]u8) = .empty,
    pending: ?contracts.PendingInteraction = null,

    fn deinit(self: *Projection, alloc: Allocator) void {
        for (self.history.items) |*item| item.deinit(alloc);
        self.history.deinit(alloc);
        self.assistant_partial.deinit(alloc);
        for (self.tools.items) |*tool| tool.deinit(alloc);
        self.tools.deinit(alloc);
        if (self.config_json.len > 0) alloc.free(self.config_json);
        if (self.current_model) |value| alloc.free(value);
        if (self.current_mode) |value| alloc.free(value);
        for (self.available_modes.items) |value| alloc.free(value);
        self.available_modes.deinit(alloc);
        if (self.pending) |*pending| pending.deinit(alloc);
        self.* = .{};
    }

    fn installConfig(self: *Projection, alloc: Allocator, result: std.json.Value) !void {
        if (result != .object) return;
        if (result.object.get("configOptions")) |options| if (options == .array) {
            for (options.array.items) |option| {
                if (option != .object) continue;
                const id = stringField(option, "id") orelse continue;
                const current = stringField(option, "currentValue") orelse continue;
                if (std.mem.eql(u8, id, "model")) {
                    try replaceOptional(alloc, &self.current_model, current);
                } else if (std.mem.eql(u8, id, "mode")) {
                    try replaceOptional(alloc, &self.current_mode, current);
                    if (option.object.get("options")) |mode_options| if (mode_options == .array) {
                        for (mode_options.array.items) |mode_option| {
                            if (mode_option != .object) continue;
                            const value = stringField(mode_option, "value") orelse continue;
                            try self.appendAvailableMode(alloc, value);
                        }
                    };
                }
            }
        };
        if (result.object.get("modes")) |modes| if (modes == .object) {
            if (stringField(modes, "currentModeId")) |current| try replaceOptional(alloc, &self.current_mode, current);
            if (modes.object.get("availableModes")) |mode_options| if (mode_options == .array) {
                for (mode_options.array.items) |mode_option| {
                    if (mode_option != .object) continue;
                    const value = stringField(mode_option, "id") orelse continue;
                    try self.appendAvailableMode(alloc, value);
                }
            };
        };
    }

    fn appendAvailableMode(self: *Projection, alloc: Allocator, value: []const u8) !void {
        for (self.available_modes.items) |existing| if (std.mem.eql(u8, existing, value)) return;
        const owned = try contracts.sanitizeSemanticAlloc(alloc, value);
        errdefer alloc.free(owned);
        try self.available_modes.append(alloc, owned);
    }

    fn supportsMode(self: *Projection, value: []const u8) bool {
        for (self.available_modes.items) |mode| if (std.mem.eql(u8, mode, value)) return true;
        return false;
    }

    fn findTool(self: *Projection, id: []const u8) ?*contracts.ToolRecord {
        for (self.tools.items) |*tool| if (std.mem.eql(u8, tool.id, id)) return tool;
        return null;
    }

    fn replaceOwned(alloc: Allocator, target: *[]u8, value: []const u8) !void {
        const replacement = try contracts.sanitizeSemanticAlloc(alloc, value);
        if (target.len > 0) alloc.free(target.*);
        target.* = replacement;
    }

    fn replaceOptional(alloc: Allocator, target: *?[]u8, value: ?[]const u8) !void {
        const replacement = if (value) |text| try contracts.sanitizeSemanticAlloc(alloc, text) else null;
        if (target.*) |old| alloc.free(old);
        target.* = replacement;
    }

    fn consumeUpdate(self: *Projection, alloc: Allocator, root: std.json.Value, replaying: bool) !void {
        if (!self.complete) return error.ProjectionUnavailable;
        const params = root.object.get("params") orelse return;
        if (params != .object) return;
        const update = params.object.get("update") orelse return;
        if (update != .object) return;
        const kind_value = update.object.get("sessionUpdate") orelse return;
        if (kind_value != .string) return;
        const kind = kind_value.string;
        if (std.mem.eql(u8, kind, "user_message_chunk")) {
            const text = contentText(update) orelse return;
            const owned = try contracts.sanitizeSemanticAlloc(alloc, text);
            errdefer alloc.free(owned);
            try self.history.append(alloc, .{ .role = .user, .text = owned });
        } else if (std.mem.eql(u8, kind, "agent_message_chunk")) {
            const text = contentText(update) orelse return;
            if (replaying or self.run_state == .idle) {
                const owned = try contracts.sanitizeSemanticAlloc(alloc, text);
                errdefer alloc.free(owned);
                try self.history.append(alloc, .{ .role = .assistant, .text = owned });
            } else {
                const sanitized = try contracts.sanitizeSemanticAlloc(alloc, text);
                defer alloc.free(sanitized);
                try self.assistant_partial.appendSlice(alloc, sanitized);
            }
        } else if (std.mem.eql(u8, kind, "tool_call")) {
            const raw_id = stringField(update, "toolCallId") orelse return;
            const id = try contracts.sanitizeSemanticAlloc(alloc, raw_id);
            defer alloc.free(id);
            const title = stringField(update, "title") orelse "Tool call";
            const tool_kind = stringField(update, "kind") orelse "other";
            const status = stringField(update, "status") orelse "pending";
            if (self.findTool(id)) |tool| {
                try replaceOwned(alloc, &tool.title, title);
                try replaceOwned(alloc, &tool.kind, tool_kind);
                try replaceOwned(alloc, &tool.status, status);
            } else {
                if (self.tools.items.len >= contracts.max_tools_per_actor) {
                    self.complete = false;
                    return error.ToolProjectionCapacityExceeded;
                }
                const owned_id = try contracts.sanitizeSemanticAlloc(alloc, id);
                errdefer alloc.free(owned_id);
                const owned_title = try contracts.sanitizeSemanticAlloc(alloc, title);
                errdefer alloc.free(owned_title);
                const owned_kind = try contracts.sanitizeSemanticAlloc(alloc, tool_kind);
                errdefer alloc.free(owned_kind);
                const owned_status = try contracts.sanitizeSemanticAlloc(alloc, status);
                errdefer alloc.free(owned_status);
                try self.tools.append(alloc, .{
                    .id = owned_id,
                    .title = owned_title,
                    .kind = owned_kind,
                    .status = owned_status,
                });
            }
        } else if (std.mem.eql(u8, kind, "tool_call_update")) {
            const raw_id = stringField(update, "toolCallId") orelse return;
            const id = try contracts.sanitizeSemanticAlloc(alloc, raw_id);
            defer alloc.free(id);
            const status = stringField(update, "status") orelse "in_progress";
            const text = nestedContentText(update);
            if (self.findTool(id)) |tool| {
                try replaceOwned(alloc, &tool.status, status);
                if (std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "failed"))
                    try replaceOptional(alloc, &tool.result, text)
                else
                    try replaceOptional(alloc, &tool.progress, text);
            } else {
                self.complete = false;
                return error.ToolProjectionOutOfOrder;
            }
        } else if (std.mem.eql(u8, kind, "session_info_update")) {
            if (update.object.get("_meta")) |meta| if (meta == .object) {
                if (meta.object.get("fx")) |fx| if (fx == .object) {
                    if (fx.object.get("modelResponseRecovery")) |recovery| {
                        if (recovery == .object) self.run_state = .paused;
                    }
                };
            };
        }
    }

    fn contentText(update: std.json.Value) ?[]const u8 {
        const content = update.object.get("content") orelse return null;
        if (content != .object) return null;
        return stringField(content, "text");
    }

    fn nestedContentText(update: std.json.Value) ?[]const u8 {
        const content = update.object.get("content") orelse return null;
        if (content != .array or content.array.items.len == 0) return null;
        const first = content.array.items[0];
        if (first != .object) return null;
        const wrapper = first.object.get("content") orelse return null;
        if (wrapper != .object) return null;
        return stringField(wrapper, "text");
    }

    fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
        const field = value.object.get(key) orelse return null;
        return if (field == .string) field.string else null;
    }
};

const Attachment = struct {
    id: [32]u8,
    role: contracts.Role,
    control_epoch: u64,
    queue: *OutboundQueue,
    buffering: bool = true,
    buffered: std.ArrayList([]u8) = .empty,
    buffered_bytes: usize = 0,

    fn deinit(self: *Attachment, alloc: Allocator) void {
        for (self.buffered.items) |event| alloc.free(event);
        self.buffered.deinit(alloc);
        self.* = undefined;
    }

    fn idSlice(self: *const Attachment) []const u8 {
        return &self.id;
    }

    fn enqueue(self: *Attachment, alloc: Allocator, message: []const u8) !void {
        if (message.len == 0 or message.len > contracts.max_frame_bytes) {
            self.queue.close();
            self.queue.interruptOwner();
            return error.FrameTooLarge;
        }
        if (!self.buffering) return self.queue.enqueue(message);
        if (self.buffered.items.len >= contracts.max_outbound_messages or
            self.buffered_bytes > contracts.max_outbound_bytes -| message.len)
        {
            self.queue.close();
            self.queue.interruptOwner();
            return error.OutboundCapacityExceeded;
        }
        const copy = try alloc.dupe(u8, message);
        errdefer alloc.free(copy);
        try self.buffered.append(alloc, copy);
        self.buffered_bytes += copy.len;
    }

    fn activate(self: *Attachment, alloc: Allocator) !void {
        while (self.buffered.items.len > 0) {
            const message = self.buffered.orderedRemove(0);
            self.buffered_bytes -= message.len;
            self.queue.enqueue(message) catch |err| {
                alloc.free(message);
                self.queue.close();
                self.queue.interruptOwner();
                return err;
            };
            alloc.free(message);
        }
        self.buffering = false;
    }
};

const ConfigureWait = struct {
    kind: []const u8,
    value: []const u8,
    done: bool = false,
    succeeded: bool = false,
};

const PendingRoute = struct {
    internal_id: u64,
    operation_index: ?usize = null,
    configure_wait: ?*ConfigureWait = null,
};

const Actor = struct {
    alloc: Allocator,
    cfg: acp_server.Config,
    session_id: []u8,
    pipe: BytePipe,
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    ready: bool = false,
    failed: bool = false,
    replaying: bool = true,
    stopping: bool = false,
    revision: u64 = 0,
    control_epoch: u64 = 0,
    primary_id: ?[32]u8 = null,
    takeover_id: ?[32]u8 = null,
    projection: Projection = .{},
    attachments: [contracts.max_attachments_per_actor]?*Attachment = @splat(null),
    operations: std.ArrayList(contracts.OperationRecord) = .empty,
    pending_routes: std.ArrayList(PendingRoute) = .empty,
    active_operation_internal_id: ?u64 = null,
    next_internal_id: u64 = 10,

    fn create(alloc: Allocator, cfg: acp_server.Config, session_id: []const u8) !*Actor {
        const owned_session_id = try alloc.dupe(u8, session_id);
        const actor = alloc.create(Actor) catch |err| {
            alloc.free(owned_session_id);
            return err;
        };
        actor.* = .{
            .alloc = alloc,
            .cfg = cfg,
            .session_id = owned_session_id,
            .pipe = BytePipe.init(alloc),
        };
        actor.thread = std.Thread.spawn(.{}, runMain, .{actor}) catch |err| {
            actor.pipe.deinit();
            alloc.free(owned_session_id);
            alloc.destroy(actor);
            return err;
        };
        actor.sendRaw("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1,\"clientCapabilities\":{\"fxRemoteAttach\":true,\"elicitation\":{\"form\":{},\"url\":{}}}}}\n") catch |err| {
            actor.destroy();
            return err;
        };
        var load: std.Io.Writer.Allocating = .init(alloc);
        defer load.deinit();
        load.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/load\",\"params\":{\"sessionId\":") catch |err| {
            actor.destroy();
            return err;
        };
        jsonrpc.writeJsonStr(session_id, &load.writer) catch |err| {
            actor.destroy();
            return err;
        };
        load.writer.writeAll(",\"mcpServers\":[]}}\n") catch |err| {
            actor.destroy();
            return err;
        };
        actor.sendRaw(load.writer.buffered()) catch |err| {
            actor.destroy();
            return err;
        };

        const io = io_mod.getIo();
        actor.mutex.lockUncancelable(io);
        while (!actor.ready and !actor.failed) actor.changed.waitUncancelable(io, &actor.mutex);
        const failed = actor.failed;
        actor.mutex.unlock(io);
        if (failed) {
            actor.destroy();
            return error.SessionLoadFailed;
        }
        return actor;
    }

    fn beginShutdown(self: *Actor) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.stopping = true;
        self.changed.broadcast(io);
        self.mutex.unlock(io);
        self.pipe.close();
    }

    fn destroy(self: *Actor) void {
        self.beginShutdown();
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        for (self.attachments) |maybe_attachment| {
            if (maybe_attachment) |attachment| {
                attachment.queue.close();
                attachment.queue.interruptOwner();
            }
        }
        while (true) {
            var active = false;
            for (self.attachments) |attachment| active = active or attachment != null;
            if (!active) break;
            self.changed.waitUncancelable(io, &self.mutex);
        }
        self.mutex.unlock(io);
        self.pipe.close();
        if (self.thread) |thread| thread.join();
        self.projection.deinit(self.alloc);
        for (self.operations.items) |*operation| operation.deinit(self.alloc);
        self.operations.deinit(self.alloc);
        self.pending_routes.deinit(self.alloc);
        self.pipe.deinit();
        self.alloc.free(self.session_id);
        const alloc = self.alloc;
        self.* = undefined;
        alloc.destroy(self);
    }

    fn runMain(self: *Actor) void {
        acp_server.runWithTransport(
            self.alloc,
            self.cfg,
            jsonrpc.Reader.initCallback(&self.pipe, BytePipe.read),
            jsonrpc.Writer.initCallback(self, outputCallback),
        ) catch {
            const io = io_mod.getIo();
            self.mutex.lockUncancelable(io);
            self.failed = true;
            self.changed.broadcast(io);
            self.mutex.unlock(io);
        };
    }

    fn sendRaw(self: *Actor, bytes: []const u8) !void {
        try self.pipe.append(bytes);
    }

    fn outputCallback(raw: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *Actor = @ptrCast(@alignCast(raw.?));
        const message = std.mem.trim(u8, bytes, "\r\n");
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, message, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;

        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.stopping) return;

        if (parsed.value.object.get("method") == null) if (parsed.value.object.get("id")) |id_value| {
            if (id_value == .integer and id_value.integer == 1) {
                if (parsed.value.object.get("error") != null) {
                    self.failed = true;
                    self.changed.broadcast(io);
                }
                return;
            }
            if (id_value == .integer and id_value.integer == 2) {
                if (parsed.value.object.get("error") != null) {
                    self.failed = true;
                } else {
                    if (parsed.value.object.get("result")) |result| {
                        var out: std.Io.Writer.Allocating = .init(self.alloc);
                        defer out.deinit();
                        try writeSanitizedJsonValue(self.alloc, &out.writer, result);
                        if (self.projection.config_json.len > 0) self.alloc.free(self.projection.config_json);
                        self.projection.config_json = try out.toOwnedSlice();
                        try self.projection.installConfig(self.alloc, result);
                    }
                    self.replaying = false;
                    self.ready = true;
                }
                self.changed.broadcast(io);
                return;
            }
            if (id_value == .integer and id_value.integer > 0) {
                try self.handleInternalResponse(@intCast(id_value.integer), parsed.value);
                return;
            }
        };

        if (!self.projection.complete) return;
        if (parsed.value.object.get("method")) |method_value| if (method_value == .string) {
            const method = method_value.string;
            var run_state_changed = false;
            if (std.mem.eql(u8, method, "session/update")) {
                self.projection.consumeUpdate(self.alloc, parsed.value, self.replaying) catch |err| switch (err) {
                    error.ToolProjectionCapacityExceeded, error.ToolProjectionOutOfOrder => {
                        self.failProjectionLocked();
                        return;
                    },
                    else => return err,
                };
            } else if (std.mem.eql(u8, method, "session/request_permission") or
                std.mem.eql(u8, method, "elicitation/create"))
            {
                if (parsed.value.object.get("id")) |request_id| if (request_id == .integer and request_id.integer > 0) {
                    if (self.projection.pending) |*pending| pending.deinit(self.alloc);
                    const params = parsed.value.object.get("params") orelse .null;
                    var out: std.Io.Writer.Allocating = .init(self.alloc);
                    defer out.deinit();
                    try writeSanitizedJsonValue(self.alloc, &out.writer, params);
                    const owned_method = try self.alloc.dupe(u8, method);
                    errdefer self.alloc.free(owned_method);
                    const owned_params = try out.toOwnedSlice();
                    errdefer self.alloc.free(owned_params);
                    self.projection.pending = .{
                        .id = @intCast(request_id.integer),
                        .method = owned_method,
                        .params_json = owned_params,
                    };
                    self.projection.run_state = .waiting_input;
                    run_state_changed = true;
                };
            }
            var sanitized_event: std.Io.Writer.Allocating = .init(self.alloc);
            defer sanitized_event.deinit();
            try writeSanitizedJsonValue(self.alloc, &sanitized_event.writer, parsed.value);
            self.revision +|= 1;
            try self.broadcastEvent(sanitized_event.writer.buffered());
            if (run_state_changed) try self.publishRunState();
        };
    }

    fn failProjectionLocked(self: *Actor) void {
        self.projection.complete = false;
        for (self.attachments) |maybe_attachment| {
            const attachment = maybe_attachment orelse continue;
            attachment.queue.close();
            attachment.queue.interruptOwner();
        }
    }

    fn handleInternalResponse(self: *Actor, internal_id: u64, root: std.json.Value) !void {
        var route_index: ?usize = null;
        for (self.pending_routes.items, 0..) |route, index| {
            if (route.internal_id == internal_id) {
                route_index = index;
                break;
            }
        }
        const index = route_index orelse return;
        const route = self.pending_routes.orderedRemove(index);
        if (route.configure_wait) |waiter| {
            defer {
                waiter.done = true;
                self.changed.broadcast(io_mod.getIo());
            }
            const authoritative_success = root.object.get("result") != null and root.object.get("error") == null;
            if (authoritative_success) {
                if (std.mem.eql(u8, waiter.kind, "mode"))
                    try Projection.replaceOptional(self.alloc, &self.projection.current_mode, waiter.value)
                else
                    try Projection.replaceOptional(self.alloc, &self.projection.current_model, waiter.value);
                self.revision +|= 1;
                var event: std.Io.Writer.Allocating = .init(self.alloc);
                defer event.deinit();
                try event.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"fx/configuration\",\"params\":{\"kind\":");
                try jsonrpc.writeJsonStr(waiter.kind, &event.writer);
                try event.writer.writeAll(",\"value\":");
                const projected_value = if (std.mem.eql(u8, waiter.kind, "mode")) self.projection.current_mode.? else self.projection.current_model.?;
                try jsonrpc.writeJsonStr(projected_value, &event.writer);
                try event.writer.writeAll("}}");
                try self.broadcastEvent(event.writer.buffered());
                waiter.succeeded = true;
            }
            return;
        }
        if (route.operation_index) |operation_index| {
            if (operation_index >= self.operations.items.len) return;
            const operation = &self.operations.items[operation_index];
            if (root.object.get("result")) |result| {
                var out: std.Io.Writer.Allocating = .init(self.alloc);
                defer out.deinit();
                try writeSanitizedJsonValue(self.alloc, &out.writer, result);
                operation.result_json = try out.toOwnedSlice();
                operation.state = if (result == .object and
                    Projection.stringField(result, "stopReason") != null and
                    std.mem.eql(u8, Projection.stringField(result, "stopReason").?, "cancelled"))
                    .cancelled
                else
                    .completed;
            } else if (root.object.get("error")) |err| {
                var out: std.Io.Writer.Allocating = .init(self.alloc);
                defer out.deinit();
                try writeSanitizedJsonValue(self.alloc, &out.writer, err);
                operation.error_json = try out.toOwnedSlice();
                operation.state = .failed;
            }
            if (self.active_operation_internal_id == internal_id) {
                self.active_operation_internal_id = null;
                if (self.projection.assistant_partial.items.len > 0) {
                    const partial = try self.alloc.dupe(u8, self.projection.assistant_partial.items);
                    errdefer self.alloc.free(partial);
                    try self.projection.history.append(self.alloc, .{ .role = .assistant, .text = partial });
                    self.projection.assistant_partial.clearRetainingCapacity();
                }
                if (self.projection.pending) |*pending| pending.deinit(self.alloc);
                self.projection.pending = null;
                self.projection.run_state = .idle;
            }
            self.revision +|= 1;
            var event: std.Io.Writer.Allocating = .init(self.alloc);
            defer event.deinit();
            try event.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"fx/operation\",\"params\":");
            try self.writeOperationJson(&event.writer, operation.*);
            try event.writer.writeByte('}');
            try self.broadcastEvent(event.writer.buffered());
            if (self.active_operation_internal_id == null and self.projection.run_state == .idle)
                try self.publishRunState();
        }
    }

    fn publishUserMessage(self: *Actor, text: []const u8) !void {
        self.revision +|= 1;
        var event: std.Io.Writer.Allocating = .init(self.alloc);
        defer event.deinit();
        try event.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"user_message_chunk\",\"content\":{\"type\":\"text\",\"text\":");
        try jsonrpc.writeJsonStr(text, &event.writer);
        try event.writer.writeAll("}}}}");
        try self.broadcastEvent(event.writer.buffered());
    }

    fn publishRunState(self: *Actor) !void {
        self.revision +|= 1;
        var event: std.Io.Writer.Allocating = .init(self.alloc);
        defer event.deinit();
        try event.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"fx/run_state\",\"params\":{\"state\":");
        try jsonrpc.writeJsonStr(@tagName(self.projection.run_state), &event.writer);
        try event.writer.writeAll("}}");
        try self.broadcastEvent(event.writer.buffered());
    }

    fn broadcastEvent(self: *Actor, event_json: []const u8) !void {
        for (self.attachments) |maybe_attachment| {
            const attachment = maybe_attachment orelse continue;
            var out: std.Io.Writer.Allocating = .init(self.alloc);
            defer out.deinit();
            try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"fx/event\",\"params\":{\"attachmentId\":");
            try jsonrpc.writeJsonStr(attachment.idSlice(), &out.writer);
            try out.writer.print(",\"revision\":{d},\"event\":", .{self.revision});
            try out.writer.writeAll(event_json);
            try out.writer.writeAll("}}\n");
            attachment.enqueue(self.alloc, out.writer.buffered()) catch {
                attachment.queue.close();
            };
        }
    }

    fn attach(self: *Actor, queue: *OutboundQueue, role: contracts.Role) !*Attachment {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.attachLocked(queue, role);
    }

    fn effectiveControllerId(self: *const Actor) ?[32]u8 {
        return self.takeover_id orelse self.primary_id;
    }

    fn writeOptionalAttachmentId(writer: *std.Io.Writer, id: ?[32]u8) !void {
        if (id) |value| try jsonrpc.writeJsonStr(&value, writer) else try writer.writeAll("null");
    }

    fn failControlPublication(self: *Actor, skip: ?*Attachment) void {
        for (self.attachments) |maybe_attachment| {
            const target = maybe_attachment orelse continue;
            if (skip != null and target == skip.?) continue;
            target.queue.close();
            target.queue.interruptOwner();
        }
    }

    fn publishControlState(self: *Actor, skip: ?*Attachment) !void {
        self.revision +|= 1;
        var event: std.Io.Writer.Allocating = .init(self.alloc);
        defer event.deinit();
        try event.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"fx/control_changed\",\"params\":{\"controlEpoch\":");
        try event.writer.print("{d},\"controllerAttachmentId\":", .{self.control_epoch});
        try writeOptionalAttachmentId(&event.writer, self.effectiveControllerId());
        try event.writer.writeAll(",\"primaryAttachmentId\":");
        try writeOptionalAttachmentId(&event.writer, self.primary_id);
        try event.writer.writeAll("}}");
        for (self.attachments) |maybe_attachment| {
            const target = maybe_attachment orelse continue;
            if (skip != null and target == skip.?) continue;
            var out: std.Io.Writer.Allocating = .init(self.alloc);
            defer out.deinit();
            try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"fx/event\",\"params\":{\"attachmentId\":");
            try jsonrpc.writeJsonStr(target.idSlice(), &out.writer);
            try out.writer.print(",\"revision\":{d},\"event\":", .{self.revision});
            try out.writer.writeAll(event.writer.buffered());
            try out.writer.writeAll("}}\n");
            target.enqueue(self.alloc, out.writer.buffered()) catch {
                target.queue.close();
                target.queue.interruptOwner();
            };
        }
    }

    fn attachLocked(self: *Actor, queue: *OutboundQueue, role: contracts.Role) !*Attachment {
        if (self.stopping) return error.ActorStopping;
        if (!self.projection.complete) return error.ProjectionUnavailable;
        if (role == .primary and self.primary_id != null) return error.PrimaryBusy;
        if (role == .controller and self.takeover_id != null) return error.ControllerBusy;
        const slot = for (&self.attachments) |*entry| {
            if (entry.* == null) break entry;
        } else return error.AttachmentCapacityExceeded;
        var id_buffer: [32]u8 = undefined;
        _ = try contracts.randomId(io_mod.getIo(), &id_buffer);
        const attachment = try self.alloc.create(Attachment);
        var control_changed = false;
        switch (role) {
            .observer => {},
            .primary => {
                self.primary_id = id_buffer;
                control_changed = true;
            },
            .controller => {
                self.takeover_id = id_buffer;
                control_changed = true;
            },
        }
        if (control_changed) self.control_epoch +|= 1;
        attachment.* = .{
            .id = id_buffer,
            .role = role,
            .control_epoch = self.control_epoch,
            .queue = queue,
        };
        slot.* = attachment;
        if (control_changed) self.publishControlState(attachment) catch {
            // The state and attachment are already committed. Existing clients
            // cannot safely continue across the missing revision, so fail them
            // closed while the new attachment receives the same state in its
            // authoritative snapshot.
            self.failControlPublication(attachment);
        };
        return attachment;
    }

    fn detach(self: *Actor, attachment: *Attachment) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        for (&self.attachments) |*slot| {
            if (slot.* == attachment) {
                slot.* = null;
                break;
            }
        }
        var control_changed = false;
        if (self.primary_id) |primary_id| if (std.mem.eql(u8, &primary_id, attachment.idSlice())) {
            self.primary_id = null;
            control_changed = true;
        };
        if (self.takeover_id) |takeover_id| if (std.mem.eql(u8, &takeover_id, attachment.idSlice())) {
            self.takeover_id = null;
            control_changed = true;
        };
        if (control_changed) {
            self.control_epoch +|= 1;
            self.publishControlState(null) catch self.failControlPublication(null);
        }
        self.changed.broadcast(io);
        self.mutex.unlock(io);
        attachment.deinit(self.alloc);
        self.alloc.destroy(attachment);
    }

    fn validateController(self: *Actor, attachment: *Attachment, attachment_id: []const u8, epoch: u64) !void {
        if (!std.mem.eql(u8, attachment.idSlice(), attachment_id)) return error.StaleAttachment;
        if (attachment.role == .observer) return error.NotController;
        if (epoch != self.control_epoch) return error.StaleControlEpoch;
        const current = self.effectiveControllerId() orelse return error.NotController;
        if (!std.mem.eql(u8, &current, attachment.idSlice())) return error.NotController;
    }

    fn evictOldestTerminalOperation(self: *Actor) !void {
        for (self.operations.items, 0..) |operation, index| {
            if (operation.state == .running or operation.state == .accepted) continue;
            for (self.pending_routes.items) |*route| {
                if (route.operation_index) |route_index| {
                    if (route_index == index) return error.OperationCapacityExceeded;
                    if (route_index > index) route.operation_index = route_index - 1;
                }
            }
            var removed = self.operations.orderedRemove(index);
            removed.deinit(self.alloc);
            return;
        }
        return error.OperationCapacityExceeded;
    }

    fn beginPrompt(
        self: *Actor,
        attachment: *Attachment,
        attachment_id: []const u8,
        epoch: u64,
        operation_id: []const u8,
        prompt_value: std.json.Value,
        operation_writer: *std.Io.Writer,
    ) !bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.validateController(attachment, attachment_id, epoch);
        if (operation_id.len == 0 or operation_id.len > 128) return error.InvalidOperationId;
        const sanitized_operation_id = try contracts.sanitizeSemanticAlloc(self.alloc, operation_id);
        defer self.alloc.free(sanitized_operation_id);
        if (!std.mem.eql(u8, sanitized_operation_id, operation_id)) return error.InvalidOperationId;
        var prompt_json: std.Io.Writer.Allocating = .init(self.alloc);
        defer prompt_json.deinit();
        try std.json.Stringify.value(prompt_value, .{}, &prompt_json.writer);
        const digest = contracts.operationDigest("fx/prompt", prompt_json.writer.buffered());
        for (self.operations.items) |operation| {
            if (!std.mem.eql(u8, operation.id, operation_id)) continue;
            if (!std.mem.eql(u8, &operation.payload_digest, &digest)) return error.OperationIdConflict;
            try self.writeOperationJson(operation_writer, operation);
            return true;
        }
        if (self.active_operation_internal_id != null) return error.PromptAlreadyActive;
        if (self.operations.items.len >= contracts.max_operations_per_actor) try self.evictOldestTerminalOperation();
        const operation_index = self.operations.items.len;
        const owned_operation_id = try self.alloc.dupe(u8, operation_id);
        self.operations.append(self.alloc, .{
            .id = owned_operation_id,
            .payload_digest = digest,
            .state = .running,
        }) catch |err| {
            self.alloc.free(owned_operation_id);
            return err;
        };
        var operation_added = true;
        var history_added = false;
        var accepted_prompt_text: ?[]const u8 = null;
        var route_added = false;
        errdefer {
            if (route_added) _ = self.pending_routes.pop();
            if (history_added) {
                var item = self.projection.history.pop().?;
                item.deinit(self.alloc);
            }
            if (operation_added) {
                var operation = self.operations.pop().?;
                operation.deinit(self.alloc);
            }
            self.active_operation_internal_id = null;
            self.projection.run_state = .idle;
        }
        const projected_text = try prompt_projection.project_text_alloc(self.alloc, prompt_value);
        defer self.alloc.free(projected_text);
        const owned_text = try contracts.sanitizeSemanticAlloc(self.alloc, projected_text);
        self.projection.history.append(self.alloc, .{ .role = .user, .text = owned_text }) catch |err| {
            self.alloc.free(owned_text);
            return err;
        };
        history_added = true;
        accepted_prompt_text = owned_text;
        const internal_id = self.next_internal_id;
        self.next_internal_id +|= 1;
        try self.pending_routes.append(self.alloc, .{ .internal_id = internal_id, .operation_index = operation_index });
        route_added = true;
        self.active_operation_internal_id = internal_id;
        self.projection.run_state = .running;
        var request: std.Io.Writer.Allocating = .init(self.alloc);
        defer request.deinit();
        try request.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/prompt\",\"params\":{{\"sessionId\":", .{internal_id});
        try jsonrpc.writeJsonStr(self.session_id, &request.writer);
        try request.writer.writeAll(",\"prompt\":");
        try request.writer.writeAll(prompt_json.writer.buffered());
        try request.writer.writeAll("}}\n");
        try self.sendRaw(request.writer.buffered());
        try self.writeOperationJson(operation_writer, self.operations.items[operation_index]);
        operation_added = false;
        history_added = false;
        route_added = false;
        if (accepted_prompt_text) |text| try self.publishUserMessage(text);
        try self.publishRunState();
        return false;
    }

    fn abort(self: *Actor, attachment: *Attachment, attachment_id: []const u8, epoch: u64) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.validateController(attachment, attachment_id, epoch);
        const internal_id = self.next_internal_id;
        self.next_internal_id +|= 1;
        var request: [256]u8 = undefined;
        const frame = try std.fmt.bufPrint(&request, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/cancel\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n", .{ internal_id, self.session_id });
        try self.sendRaw(frame);
    }

    fn respond(
        self: *Actor,
        attachment: *Attachment,
        attachment_id: []const u8,
        epoch: u64,
        interaction_id: u64,
        result: ?std.json.Value,
        err: ?std.json.Value,
    ) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.validateController(attachment, attachment_id, epoch);
        const pending = self.projection.pending orelse return error.NoPendingInteraction;
        if (pending.id != interaction_id) return error.StaleInteraction;
        var response: std.Io.Writer.Allocating = .init(self.alloc);
        defer response.deinit();
        try response.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},", .{interaction_id});
        if (result) |value| {
            try response.writer.writeAll("\"result\":");
            try std.json.Stringify.value(value, .{}, &response.writer);
        } else if (err) |value| {
            try response.writer.writeAll("\"error\":");
            try std.json.Stringify.value(value, .{}, &response.writer);
        } else return error.InvalidResponse;
        try response.writer.writeAll("}\n");
        try self.sendRaw(response.writer.buffered());
        if (self.projection.pending) |*owned| owned.deinit(self.alloc);
        self.projection.pending = null;
        self.projection.run_state = .running;
        try self.publishRunState();
    }

    fn configure(
        self: *Actor,
        attachment: *Attachment,
        attachment_id: []const u8,
        epoch: u64,
        kind: []const u8,
        value: []const u8,
    ) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.validateController(attachment, attachment_id, epoch);
        if (self.active_operation_internal_id != null or self.projection.run_state != .idle)
            return error.ConfigurationBusy;
        if (std.mem.eql(u8, kind, "mode") and !self.projection.supportsMode(value))
            return error.InvalidConfiguration;
        const internal_id = self.next_internal_id;
        self.next_internal_id +|= 1;
        var request: std.Io.Writer.Allocating = .init(self.alloc);
        defer request.deinit();
        try request.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{internal_id});
        if (std.mem.eql(u8, kind, "mode")) {
            try jsonrpc.writeJsonStr("session/set_mode", &request.writer);
            try request.writer.writeAll(",\"params\":{\"modeId\":");
        } else if (std.mem.eql(u8, kind, "model")) {
            try jsonrpc.writeJsonStr("session/set_config_option", &request.writer);
            try request.writer.writeAll(",\"params\":{\"configId\":\"model\",\"value\":");
        } else return error.InvalidConfiguration;
        try jsonrpc.writeJsonStr(value, &request.writer);
        try request.writer.writeAll("}}\n");
        var waiter = ConfigureWait{ .kind = kind, .value = value };
        try self.pending_routes.append(self.alloc, .{ .internal_id = internal_id, .configure_wait = &waiter });
        var route_added = true;
        defer if (route_added) {
            for (self.pending_routes.items, 0..) |route, index| {
                if (route.internal_id == internal_id) {
                    _ = self.pending_routes.orderedRemove(index);
                    break;
                }
            }
        };
        try self.sendRaw(request.writer.buffered());
        while (!waiter.done and !self.failed and !self.stopping) self.changed.waitUncancelable(io, &self.mutex);
        if (!waiter.done) return error.ConfigurationRejected;
        route_added = false;
        if (!waiter.succeeded) return error.ConfigurationRejected;
    }

    fn writeSnapshotJson(self: *Actor, writer: *std.Io.Writer, snapshot_id: []const u8) !void {
        if (!self.projection.complete) return error.ProjectionUnavailable;
        try writer.writeAll("{\"schemaVersion\":1,\"snapshotId\":");
        try jsonrpc.writeJsonStr(snapshot_id, writer);
        try writer.writeAll(",\"sessionId\":");
        try jsonrpc.writeJsonStr(self.session_id, writer);
        try writer.print(",\"revision\":{d},\"runState\":", .{self.revision});
        try jsonrpc.writeJsonStr(@tagName(self.projection.run_state), writer);
        try writer.writeAll(",\"control\":{\"controlEpoch\":");
        try writer.print("{d},\"controllerAttachmentId\":", .{self.control_epoch});
        try writeOptionalAttachmentId(writer, self.effectiveControllerId());
        try writer.writeAll(",\"primaryAttachmentId\":");
        try writeOptionalAttachmentId(writer, self.primary_id);
        try writer.writeAll("},\"history\":[");
        for (self.projection.history.items, 0..) |item, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.writeAll("{\"role\":");
            try jsonrpc.writeJsonStr(@tagName(item.role), writer);
            try writer.writeAll(",\"text\":");
            try jsonrpc.writeJsonStr(item.text, writer);
            try writer.writeByte('}');
        }
        try writer.writeAll("],\"assistantPartial\":");
        try jsonrpc.writeJsonStr(self.projection.assistant_partial.items, writer);
        try writer.writeAll(",\"tools\":[");
        for (self.projection.tools.items, 0..) |tool, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.writeAll("{\"id\":");
            try jsonrpc.writeJsonStr(tool.id, writer);
            try writer.writeAll(",\"title\":");
            try jsonrpc.writeJsonStr(tool.title, writer);
            try writer.writeAll(",\"kind\":");
            try jsonrpc.writeJsonStr(tool.kind, writer);
            try writer.writeAll(",\"status\":");
            try jsonrpc.writeJsonStr(tool.status, writer);
            if (tool.progress) |progress| {
                try writer.writeAll(",\"progress\":");
                try jsonrpc.writeJsonStr(progress, writer);
            }
            if (tool.result) |result| {
                try writer.writeAll(",\"result\":");
                try jsonrpc.writeJsonStr(result, writer);
            }
            try writer.writeByte('}');
        }
        try writer.writeAll("],\"queued\":[],\"configuration\":{\"model\":");
        if (self.projection.current_model) |model| try jsonrpc.writeJsonStr(model, writer) else try writer.writeAll("null");
        try writer.writeAll(",\"mode\":");
        if (self.projection.current_mode) |mode| try jsonrpc.writeJsonStr(mode, writer) else try writer.writeAll("null");
        try writer.writeAll(",\"acp\":");
        if (self.projection.config_json.len > 0) try writer.writeAll(self.projection.config_json) else try writer.writeAll("{}");
        try writer.writeAll("},\"pendingInteraction\":");
        if (self.projection.pending) |pending| {
            try writer.writeAll("{\"id\":");
            try writer.print("{d},\"method\":", .{pending.id});
            try jsonrpc.writeJsonStr(pending.method, writer);
            try writer.writeAll(",\"params\":");
            try writer.writeAll(pending.params_json);
            try writer.writeByte('}');
        } else try writer.writeAll("null");
        try writer.writeAll(",\"operations\":[");
        for (self.operations.items, 0..) |operation, index| {
            if (index > 0) try writer.writeByte(',');
            try self.writeOperationJson(writer, operation);
        }
        try writer.writeAll("]}");
    }

    fn writeOperationJson(self: *Actor, writer: *std.Io.Writer, operation: contracts.OperationRecord) !void {
        _ = self;
        try writer.writeAll("{\"operationId\":");
        try jsonrpc.writeJsonStr(operation.id, writer);
        try writer.writeAll(",\"state\":");
        try jsonrpc.writeJsonStr(@tagName(operation.state), writer);
        if (operation.result_json) |result| {
            try writer.writeAll(",\"result\":");
            try writer.writeAll(result);
        }
        if (operation.error_json) |err| {
            try writer.writeAll(",\"error\":");
            try writer.writeAll(err);
        }
        try writer.writeByte('}');
    }
};

const TaskToken = struct {
    index: usize,
    generation: u64,
};

const Host = struct {
    alloc: Allocator,
    cfg: acp_server.Config,
    mutex: std.Io.Mutex = .init,
    actors: [contracts.max_actors]?*Actor = @splat(null),
    connections: [64]?*Connection = @splat(null),
    task_streams: [64]?std.Io.net.Stream = @splat(null),
    task_generations: [64]u64 = @splat(0),
    next_task_generation: u64 = 1,
    stopping: bool = false,
    changed: std.Io.Condition = .init,

    fn init(alloc: Allocator, cfg: acp_server.Config) Host {
        return .{ .alloc = alloc, .cfg = cfg };
    }

    fn deinit(self: *Host) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.stopping = true;
        for (self.actors) |maybe_actor| if (maybe_actor) |session_actor| session_actor.beginShutdown();
        for (self.connections) |connection| if (connection) |active| {
            active.queue.close();
            active.wire.interrupt();
        };
        for (self.task_streams) |stream| if (stream) |active| active.shutdown(io, .both) catch {};
        while (true) {
            var active = false;
            for (self.connections) |connection| active = active or connection != null;
            for (self.task_streams) |stream| active = active or stream != null;
            if (!active) break;
            self.changed.waitUncancelable(io, &self.mutex);
        }
        self.mutex.unlock(io);
        for (&self.actors) |*slot| {
            if (slot.*) |session_actor| session_actor.destroy();
            slot.* = null;
        }
        self.* = undefined;
    }

    fn registerTask(self: *Host, stream: std.Io.net.Stream) !TaskToken {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.stopping) return error.HostStopping;
        for (&self.task_streams, 0..) |*slot, index| if (slot.* == null) {
            var generation = self.next_task_generation;
            self.next_task_generation +%= 1;
            if (generation == 0) {
                generation = self.next_task_generation;
                self.next_task_generation +%= 1;
            }
            slot.* = stream;
            self.task_generations[index] = generation;
            return .{ .index = index, .generation = generation };
        };
        return error.ConnectionCapacityExceeded;
    }

    fn unregisterTask(self: *Host, token: TaskToken) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        if (self.task_generations[token.index] == token.generation) {
            self.task_streams[token.index] = null;
            self.task_generations[token.index] = 0;
            self.changed.broadcast(io);
        }
        self.mutex.unlock(io);
    }

    fn promoteTask(self: *Host, token: TaskToken, connection: *Connection) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.stopping) return error.HostStopping;
        if (self.task_generations[token.index] != token.generation or self.task_streams[token.index] == null)
            return error.StaleTaskToken;
        for (&self.connections) |*slot| if (slot.* == null) {
            slot.* = connection;
            self.task_streams[token.index] = null;
            self.task_generations[token.index] = 0;
            self.changed.broadcast(io);
            return;
        };
        return error.ConnectionCapacityExceeded;
    }

    fn promoteOwnedTask(self: *Host, token: *?TaskToken, connection: *Connection) !void {
        const owned = token.* orelse return error.StaleTaskToken;
        try self.promoteTask(owned, connection);
        token.* = null;
    }

    fn finalizeConnection(self: *Host, connection: *Connection) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        var registered_slot: ?*?*Connection = null;
        for (&self.connections) |*slot| if (slot.* == connection) {
            registered_slot = slot;
            break;
        };
        const slot = registered_slot orelse {
            self.mutex.unlock(io);
            @panic("finalizing an unregistered remote connection");
        };
        connection.deinit();
        slot.* = null;
        self.changed.broadcast(io);
        self.mutex.unlock(io);
    }

    fn actor(self: *Host, session_id: []const u8) !*Actor {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.stopping) return error.HostStopping;
        for (self.actors) |maybe_actor| {
            const existing = maybe_actor orelse continue;
            if (std.mem.eql(u8, existing.session_id, session_id)) return existing;
        }
        const slot = for (&self.actors) |*entry| {
            if (entry.* == null) break entry;
        } else return error.ActorCapacityExceeded;
        const created = try Actor.create(self.alloc, self.cfg, session_id);
        slot.* = created;
        return created;
    }
};

const Connection = struct {
    alloc: Allocator,
    host: *Host,
    wire: Wire,
    principal: contracts.Principal,
    queue: OutboundQueue,
    writer_thread: ?std.Thread = null,
    writer: jsonrpc.Writer,
    actor: ?*Actor = null,
    attachment: ?*Attachment = null,
    pending_snapshot: bool = false,
    allow_primary: bool = false,

    fn run(alloc: Allocator, host: *Host, wire: Wire, principal: contracts.Principal, allow_primary: bool, task_token: *?TaskToken) !void {
        var connection = Connection{
            .alloc = alloc,
            .host = host,
            .wire = wire,
            .principal = principal,
            .queue = OutboundQueue.init(alloc),
            .allow_primary = allow_primary,
            .writer = undefined,
        };
        connection.queue.overflow_context = &connection;
        connection.queue.overflow_fn = interrupt;
        connection.writer = jsonrpc.Writer.initCallback(&connection.queue, OutboundQueue.callback);
        host.promoteOwnedTask(task_token, &connection) catch |err| {
            connection.deinit();
            return err;
        };
        defer host.finalizeConnection(&connection);
        connection.writer_thread = try std.Thread.spawn(.{}, writerMain, .{&connection});
        while (try wire.read(alloc)) |message| {
            defer alloc.free(message);
            try connection.dispatch(message);
        }
    }

    fn deinit(self: *Connection) void {
        if (self.actor) |actor| if (self.attachment) |attachment| actor.detach(attachment);
        self.attachment = null;
        self.actor = null;
        self.queue.close();
        self.wire.interrupt();
        if (self.writer_thread) |thread| thread.join();
        self.wire.close();
        self.queue.deinit();
        self.principal.deinit(self.alloc);
        self.* = undefined;
    }

    fn writerMain(self: *Connection) void {
        while (self.queue.take()) |message| {
            self.wire.write(message) catch {
                self.alloc.free(message);
                self.queue.close();
                self.wire.interrupt();
                return;
            };
            self.alloc.free(message);
        }
    }

    fn interrupt(raw: *anyopaque) void {
        const self: *Connection = @ptrCast(@alignCast(raw));
        self.wire.interrupt();
    }

    fn dispatch(self: *Connection, bytes: []const u8) !void {
        var message = jsonrpc.parseMessage(self.alloc, bytes) catch {
            return self.writer.writeError(self.alloc, null, .{ .code = jsonrpc.ErrorCode.parse_error, .message = "Parse error" });
        };
        defer jsonrpc.freeMessage(self.alloc, &message);
        if (message.isResponse()) return error.UnexpectedClientResponse;
        const id = message.id;
        if (std.mem.eql(u8, message.method, "initialize")) {
            var canonical: std.Io.Writer.Allocating = .init(self.alloc);
            defer canonical.deinit();
            try acp_types.writeInitializeResponse(&canonical.writer);
            const base = canonical.writer.buffered();
            if (base.len == 0 or base[base.len - 1] != '}') return error.InvalidInitializeResponse;
            var response: std.Io.Writer.Allocating = .init(self.alloc);
            defer response.deinit();
            try response.writer.writeAll(base[0 .. base.len - 1]);
            try response.writer.writeAll(",\"_meta\":{\"fx\":{\"remoteAttach\":true,\"maxFrameBytes\":8388608,\"roles\":[\"observer\",\"controller\"]}}}");
            return self.writer.writeResponse(self.alloc, id, response.writer.buffered());
        }
        if (std.mem.eql(u8, message.method, "fx/attach")) return self.handleAttach(id, message.params_raw);
        const actor = self.actor orelse return self.writer.writeError(self.alloc, id, .{ .code = jsonrpc.ErrorCode.invalid_request, .message = "Attach first" });
        const attachment = self.attachment orelse return error.InvalidAttachmentState;
        if (std.mem.eql(u8, message.method, "fx/detach")) {
            var parsed = self.parseParams(message.params_raw) catch return self.invalidMutation(id, error.InvalidParams);
            defer parsed.deinit();
            const requested_id = Projection.stringField(parsed.value, "attachmentId") orelse
                return self.invalidMutation(id, error.InvalidParams);
            if (!std.mem.eql(u8, requested_id, attachment.idSlice()))
                return self.invalidMutation(id, error.StaleAttachment);
            try self.writer.writeResponse(self.alloc, id, "{\"detached\":true}");
            actor.detach(attachment);
            self.actor = null;
            self.attachment = null;
            return;
        }
        if (std.mem.eql(u8, message.method, "fx/snapshot/ack")) return self.ackSnapshot(id, actor, attachment, message.params_raw);
        if (std.mem.eql(u8, message.method, "fx/status")) return self.writeStatus(id, actor, attachment);
        if (std.mem.eql(u8, message.method, "fx/operation/inspect")) return self.inspectOperation(id, actor, message.params_raw);
        if (std.mem.eql(u8, message.method, "fx/prompt")) return self.handlePrompt(id, actor, attachment, message.params_raw);
        if (std.mem.eql(u8, message.method, "fx/abort")) return self.handleAbort(id, actor, attachment, message.params_raw);
        if (std.mem.eql(u8, message.method, "fx/respond")) return self.handleRespond(id, actor, attachment, message.params_raw);
        if (std.mem.eql(u8, message.method, "fx/configure")) return self.handleConfigure(id, actor, attachment, message.params_raw);
        return self.writer.writeError(self.alloc, id, .{ .code = jsonrpc.ErrorCode.method_not_found, .message = "Method not found" });
    }

    fn parseParams(self: *Connection, raw: ?[]const u8) !std.json.Parsed(std.json.Value) {
        return std.json.parseFromSlice(std.json.Value, self.alloc, raw orelse "null", .{}) catch error.InvalidParams;
    }

    fn handleAttach(self: *Connection, id: ?jsonrpc.RequestId, raw: ?[]const u8) !void {
        if (self.attachment != null) return self.writer.writeError(self.alloc, id, .{ .code = jsonrpc.ErrorCode.invalid_request, .message = "Already attached" });
        var parsed = self.parseParams(raw) catch return self.invalidMutation(id, error.InvalidParams);
        defer parsed.deinit();
        if (parsed.value != .object) return self.invalidMutation(id, error.InvalidParams);
        const session_id = Projection.stringField(parsed.value, "sessionId") orelse return self.invalidMutation(id, error.InvalidParams);
        const role_name = Projection.stringField(parsed.value, "role") orelse "controller";
        const role = contracts.Role.parse(role_name) orelse return self.invalidMutation(id, error.InvalidParams);
        if (role == .primary and !self.allow_primary) return self.writer.writeError(self.alloc, id, .{ .code = jsonrpc.ErrorCode.invalid_request, .message = "Primary attachment requires a local Unix endpoint" });
        if (!self.principal.authorizes(role, session_id)) return self.writer.writeError(self.alloc, id, .{ .code = jsonrpc.ErrorCode.invalid_request, .message = "Not authorized" });
        const actor = self.host.actor(session_id) catch return self.writer.writeError(self.alloc, id, .{ .code = jsonrpc.ErrorCode.invalid_params, .message = "Session unavailable" });
        const io = io_mod.getIo();
        var snapshot: std.Io.Writer.Allocating = .init(self.alloc);
        defer snapshot.deinit();
        actor.mutex.lockUncancelable(io);
        var actor_locked = true;
        defer if (actor_locked) actor.mutex.unlock(io);
        const attachment = actor.attachLocked(&self.queue, role) catch |err| {
            return self.writer.writeError(self.alloc, id, .{
                .code = jsonrpc.ErrorCode.invalid_request,
                .message = if (err == error.ControllerBusy) "Controller already attached" else if (err == error.PrimaryBusy) "Primary attachment already connected" else "Attachment unavailable",
            });
        };
        var attached = true;
        errdefer if (attached) {
            if (actor_locked) {
                actor.mutex.unlock(io);
                actor_locked = false;
            }
            actor.detach(attachment);
        };
        try actor.writeSnapshotJson(&snapshot.writer, attachment.idSlice());
        if (snapshot.writer.buffered().len > contracts.max_snapshot_bytes) return error.SnapshotTooLarge;
        const snapshot_revision = actor.revision;
        const snapshot_control_epoch = actor.control_epoch;
        const snapshot_controller_id = actor.effectiveControllerId();
        const snapshot_primary_id = actor.primary_id;
        actor.mutex.unlock(io);
        actor_locked = false;

        var result: std.Io.Writer.Allocating = .init(self.alloc);
        defer result.deinit();
        try result.writer.writeAll("{\"attachmentId\":");
        try jsonrpc.writeJsonStr(attachment.idSlice(), &result.writer);
        try result.writer.writeAll(",\"role\":");
        try jsonrpc.writeJsonStr(@tagName(role), &result.writer);
        try result.writer.print(",\"controlEpoch\":{d},\"controllerAttachmentId\":", .{snapshot_control_epoch});
        try Actor.writeOptionalAttachmentId(&result.writer, snapshot_controller_id);
        try result.writer.writeAll(",\"primaryAttachmentId\":");
        try Actor.writeOptionalAttachmentId(&result.writer, snapshot_primary_id);
        try result.writer.writeByte(',');
        const chunked = snapshot.writer.buffered().len > contracts.max_frame_bytes - 2048;
        if (chunked) {
            const chunk_count = std.math.divCeil(usize, snapshot.writer.buffered().len, contracts.snapshot_chunk_bytes) catch unreachable;
            try result.writer.print("\"snapshotTransfer\":{{\"snapshotId\":\"{s}\",\"revision\":{d},\"chunkCount\":{d},\"encoding\":\"base64\"}}}}", .{ attachment.idSlice(), snapshot_revision, chunk_count });
        } else {
            try result.writer.writeAll("\"snapshot\":");
            try result.writer.writeAll(snapshot.writer.buffered());
            try result.writer.writeByte('}');
        }
        self.actor = actor;
        self.attachment = attachment;
        attached = false;
        try self.writer.writeResponse(self.alloc, id, result.writer.buffered());
        if (chunked) {
            self.pending_snapshot = true;
            try self.sendSnapshotChunks(attachment, snapshot.writer.buffered(), snapshot_revision);
        } else {
            actor.mutex.lockUncancelable(io);
            attachment.activate(self.alloc) catch attachment.queue.close();
            actor.mutex.unlock(io);
        }
    }

    fn sendSnapshotChunks(self: *Connection, attachment: *Attachment, snapshot: []const u8, revision: u64) !void {
        const chunk_count = std.math.divCeil(usize, snapshot.len, contracts.snapshot_chunk_bytes) catch unreachable;
        for (0..chunk_count) |index| {
            const start = index * contracts.snapshot_chunk_bytes;
            const end = @min(snapshot.len, start + contracts.snapshot_chunk_bytes);
            const encoded_len = std.base64.standard.Encoder.calcSize(end - start);
            const encoded = try self.alloc.alloc(u8, encoded_len);
            defer self.alloc.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, snapshot[start..end]);
            var frame: std.Io.Writer.Allocating = .init(self.alloc);
            defer frame.deinit();
            try frame.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"fx/snapshot/chunk\",\"params\":{\"snapshotId\":");
            try jsonrpc.writeJsonStr(attachment.idSlice(), &frame.writer);
            try frame.writer.print(",\"revision\":{d},\"index\":{d},\"chunkCount\":{d},\"encoding\":\"base64\",\"data\":", .{ revision, index, chunk_count });
            try jsonrpc.writeJsonStr(encoded, &frame.writer);
            try frame.writer.writeAll("}}");
            try self.queue.enqueueBlocking(frame.writer.buffered());
        }
    }

    fn ackSnapshot(self: *Connection, id: ?jsonrpc.RequestId, actor: *Actor, attachment: *Attachment, raw: ?[]const u8) !void {
        var parsed = self.parseParams(raw) catch return self.invalidMutation(id, error.InvalidParams);
        defer parsed.deinit();
        const attachment_id = Projection.stringField(parsed.value, "attachmentId") orelse return self.invalidMutation(id, error.InvalidParams);
        const snapshot_id = Projection.stringField(parsed.value, "snapshotId") orelse return self.invalidMutation(id, error.InvalidParams);
        if (!self.pending_snapshot or !std.mem.eql(u8, attachment_id, attachment.idSlice()) or
            !std.mem.eql(u8, snapshot_id, attachment.idSlice()))
            return self.invalidMutation(id, error.StaleAttachment);
        const io = io_mod.getIo();
        actor.mutex.lockUncancelable(io);
        attachment.activate(self.alloc) catch |err| {
            actor.mutex.unlock(io);
            return self.invalidMutation(id, err);
        };
        actor.mutex.unlock(io);
        self.pending_snapshot = false;
        try self.writer.writeResponse(self.alloc, id, "{\"accepted\":true}");
    }

    fn mutationFields(value: std.json.Value) !struct { attachment_id: []const u8, epoch: u64 } {
        if (value != .object) return error.InvalidParams;
        const attachment_id = Projection.stringField(value, "attachmentId") orelse return error.InvalidParams;
        const epoch_value = value.object.get("controlEpoch") orelse return error.InvalidParams;
        if (epoch_value != .integer or epoch_value.integer < 0) return error.InvalidParams;
        return .{ .attachment_id = attachment_id, .epoch = @intCast(epoch_value.integer) };
    }

    fn handlePrompt(self: *Connection, id: ?jsonrpc.RequestId, actor: *Actor, attachment: *Attachment, raw: ?[]const u8) !void {
        var parsed = self.parseParams(raw) catch return self.invalidMutation(id, error.InvalidParams);
        defer parsed.deinit();
        const mutation = mutationFields(parsed.value) catch return self.invalidMutation(id, error.InvalidParams);
        const operation_id = Projection.stringField(parsed.value, "operationId") orelse return self.invalidMutation(id, error.InvalidParams);
        const prompt = parsed.value.object.get("prompt") orelse return self.invalidMutation(id, error.InvalidParams);
        var operation: std.Io.Writer.Allocating = .init(self.alloc);
        defer operation.deinit();
        const replayed = actor.beginPrompt(attachment, mutation.attachment_id, mutation.epoch, operation_id, prompt, &operation.writer) catch |err| return self.invalidMutation(id, err);
        var result: std.Io.Writer.Allocating = .init(self.alloc);
        defer result.deinit();
        try result.writer.print("{{\"replayed\":{s},\"operation\":", .{if (replayed) "true" else "false"});
        try result.writer.writeAll(operation.writer.buffered());
        try result.writer.writeByte('}');
        try self.writer.writeResponse(self.alloc, id, result.writer.buffered());
    }

    fn handleAbort(self: *Connection, id: ?jsonrpc.RequestId, actor: *Actor, attachment: *Attachment, raw: ?[]const u8) !void {
        var parsed = self.parseParams(raw) catch return self.invalidMutation(id, error.InvalidParams);
        defer parsed.deinit();
        const mutation = mutationFields(parsed.value) catch return self.invalidMutation(id, error.InvalidParams);
        actor.abort(attachment, mutation.attachment_id, mutation.epoch) catch |err| return self.invalidMutation(id, err);
        try self.writer.writeResponse(self.alloc, id, "{\"accepted\":true}");
    }

    fn handleRespond(self: *Connection, id: ?jsonrpc.RequestId, actor: *Actor, attachment: *Attachment, raw: ?[]const u8) !void {
        var parsed = self.parseParams(raw) catch return self.invalidMutation(id, error.InvalidParams);
        defer parsed.deinit();
        const mutation = mutationFields(parsed.value) catch return self.invalidMutation(id, error.InvalidParams);
        const interaction_value = parsed.value.object.get("interactionId") orelse return self.invalidMutation(id, error.InvalidParams);
        if (interaction_value != .integer or interaction_value.integer <= 0) return self.invalidMutation(id, error.InvalidParams);
        actor.respond(
            attachment,
            mutation.attachment_id,
            mutation.epoch,
            @intCast(interaction_value.integer),
            parsed.value.object.get("result"),
            parsed.value.object.get("error"),
        ) catch |err| return self.invalidMutation(id, err);
        try self.writer.writeResponse(self.alloc, id, "{\"accepted\":true}");
    }

    fn handleConfigure(self: *Connection, id: ?jsonrpc.RequestId, actor: *Actor, attachment: *Attachment, raw: ?[]const u8) !void {
        var parsed = self.parseParams(raw) catch return self.invalidMutation(id, error.InvalidParams);
        defer parsed.deinit();
        const mutation = mutationFields(parsed.value) catch return self.invalidMutation(id, error.InvalidParams);
        const kind = Projection.stringField(parsed.value, "kind") orelse return self.invalidMutation(id, error.InvalidParams);
        const value = Projection.stringField(parsed.value, "value") orelse return self.invalidMutation(id, error.InvalidParams);
        actor.configure(attachment, mutation.attachment_id, mutation.epoch, kind, value) catch |err| return self.invalidMutation(id, err);
        try self.writer.writeResponse(self.alloc, id, "{\"accepted\":true}");
    }

    fn invalidMutation(self: *Connection, id: ?jsonrpc.RequestId, err: anyerror) !void {
        const message = switch (err) {
            error.StaleAttachment => "Stale attachment",
            error.NotController => "Controller required",
            error.StaleControlEpoch => "Stale control epoch",
            error.OperationIdConflict => "Operation ID conflicts with an earlier payload",
            error.PromptAlreadyActive => "Another prompt is active",
            error.OperationCapacityExceeded => "Operation reconciliation window is full",
            error.InvalidConfiguration => "Invalid configuration",
            error.ConfigurationBusy => "Configuration changes require an idle session",
            error.ConfigurationRejected => "Configuration rejected",
            error.StaleInteraction => "Stale interaction",
            error.NoPendingInteraction => "No pending interaction",
            else => "Invalid mutation",
        };
        try self.writer.writeError(self.alloc, id, .{ .code = jsonrpc.ErrorCode.invalid_params, .message = message });
    }

    fn inspectOperation(self: *Connection, id: ?jsonrpc.RequestId, actor: *Actor, raw: ?[]const u8) !void {
        var parsed = self.parseParams(raw) catch return self.invalidMutation(id, error.InvalidParams);
        defer parsed.deinit();
        if (parsed.value != .object) return self.invalidMutation(id, error.InvalidParams);
        const operation_id = Projection.stringField(parsed.value, "operationId") orelse return self.invalidMutation(id, error.InvalidParams);
        const io = io_mod.getIo();
        actor.mutex.lockUncancelable(io);
        defer actor.mutex.unlock(io);
        for (actor.operations.items) |operation| {
            if (!std.mem.eql(u8, operation.id, operation_id)) continue;
            var result: std.Io.Writer.Allocating = .init(self.alloc);
            defer result.deinit();
            try actor.writeOperationJson(&result.writer, operation);
            return self.writer.writeResponse(self.alloc, id, result.writer.buffered());
        }
        try self.writer.writeError(self.alloc, id, .{ .code = jsonrpc.ErrorCode.invalid_params, .message = "Operation not found" });
    }

    fn writeStatus(self: *Connection, id: ?jsonrpc.RequestId, actor: *Actor, attachment: *Attachment) !void {
        const io = io_mod.getIo();
        actor.mutex.lockUncancelable(io);
        defer actor.mutex.unlock(io);
        var result: std.Io.Writer.Allocating = .init(self.alloc);
        defer result.deinit();
        try result.writer.writeAll("{\"attachmentId\":");
        try jsonrpc.writeJsonStr(attachment.idSlice(), &result.writer);
        try result.writer.writeAll(",\"role\":");
        try jsonrpc.writeJsonStr(@tagName(attachment.role), &result.writer);
        try result.writer.print(",\"controlEpoch\":{d},\"controllerAttachmentId\":", .{actor.control_epoch});
        try Actor.writeOptionalAttachmentId(&result.writer, actor.effectiveControllerId());
        try result.writer.print(",\"revision\":{d},\"runState\":", .{actor.revision});
        try jsonrpc.writeJsonStr(@tagName(actor.projection.run_state), &result.writer);
        try result.writer.writeByte('}');
        try self.writer.writeResponse(self.alloc, id, result.writer.buffered());
    }
};

pub fn run(alloc: Allocator, cfg: acp_server.Config, options: ServeOptions) !void {
    if (options.tailscale_capability.len == 0 or options.tailscale_capability.len > 256 or
        std.mem.findPosLinear(u8, options.tailscale_capability, 0, "/cap/") == null)
        return error.InvalidCapabilityName;
    const endpoint = try endpoint_mod.parse(options.listen, true);
    var host = Host.init(alloc, cfg);
    defer host.deinit();
    switch (endpoint) {
        .unix => |path| try runUnix(alloc, &host, path),
        .websocket => |websocket| try runWebSocket(alloc, &host, websocket, options.tailscale_capability),
    }
}

fn runUnix(alloc: Allocator, host: *Host, path: []const u8) !void {
    var parent_dir = try openPrivateSocketParent(path);
    defer parent_dir.dir.close(io_mod.getIo());
    var authority_lock = parent_dir.dir.createFile(io_mod.getIo(), "agent.lock", .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.ServerAlreadyRunning,
        else => return err,
    };
    defer authority_lock.close(io_mod.getIo());
    try parent_dir.dir.setFilePermissions(
        io_mod.getIo(),
        "agent.lock",
        std.Io.File.Permissions.fromMode(0o600),
        .{ .follow_symlinks = false },
    );
    const endpoint_name = std.fs.path.basename(path);
    const existing = parent_dir.dir.statFile(io_mod.getIo(), endpoint_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing != null) return error.UnsafeExistingEndpoint;
    const address = try std.Io.net.UnixAddress.init(path);
    var server = try address.listen(io_mod.getIo(), .{});
    defer server.deinit(io_mod.getIo());
    try announceUnix(path);
    defer parent_dir.dir.deleteFile(io_mod.getIo(), endpoint_name) catch {};
    try parent_dir.dir.setFilePermissions(io_mod.getIo(), endpoint_name, std.Io.File.Permissions.fromMode(0o600), .{ .follow_symlinks = false });
    while (true) {
        const stream = try server.accept(io_mod.getIo());
        setSocketSendTimeout(stream.socket.handle);
        const task_token = host.registerTask(stream) catch |err| {
            stream.close(io_mod.getIo());
            if (err == error.ConnectionCapacityExceeded) continue;
            return err;
        };
        const task = alloc.create(UnixTask) catch |err| {
            host.unregisterTask(task_token);
            stream.close(io_mod.getIo());
            return err;
        };
        task.* = .{ .alloc = alloc, .host = host, .stream = stream, .task_token = task_token };
        var thread = std.Thread.spawn(.{}, UnixTask.run, .{task}) catch |err| {
            host.unregisterTask(task_token);
            stream.close(io_mod.getIo());
            alloc.destroy(task);
            return err;
        };
        thread.detach();
    }
}

fn openPrivateSocketParent(path: []const u8) !io_mod.VerifiedDir {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidEndpoint;
    const io = io_mod.getIo();
    var dir = io_mod.openDirAbsoluteNoFollow(parent, .{}) catch |err| switch (err) {
        error.SymLinkLoop, error.NotDir, error.FileNotFound => return error.PrivateRuntimeDirectoryRequired,
        else => return err,
    };
    errdefer dir.close(io);
    const stat = try dir.stat(io);
    if (stat.kind != .directory or stat.permissions.toMode() & 0o777 != 0o700)
        return error.PrivateRuntimeDirectoryRequired;
    if (try directoryOwner(dir) != std.c.getuid()) return error.PrivateRuntimeDirectoryRequired;
    return .{ .dir = dir };
}

fn directoryOwner(dir: std.Io.Dir) !std.c.uid_t {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const linux = std.os.linux;
            var stat = std.mem.zeroes(linux.Statx);
            switch (linux.errno(linux.statx(dir.handle, "", linux.AT.EMPTY_PATH, .{ .UID = true }, &stat))) {
                .SUCCESS => if (stat.mask.UID) break :blk stat.uid else return error.PrivateRuntimeDirectoryRequired,
                else => return error.PrivateRuntimeDirectoryRequired,
            }
        },
        .macos => blk: {
            var stat = std.mem.zeroes(std.c.Stat);
            switch (std.c.errno(std.c.fstat(dir.handle, &stat))) {
                .SUCCESS => break :blk stat.uid,
                else => return error.PrivateRuntimeDirectoryRequired,
            }
        },
        else => return error.PrivateRuntimeDirectoryRequired,
    };
}

fn announceUnix(path: []const u8) !void {
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io_mod.getIo(), "fx serve: listening on unix://");
    try stdout.writeStreamingAll(io_mod.getIo(), path);
    try stdout.writeStreamingAll(io_mod.getIo(), "\n");
}

const UnixTask = struct {
    alloc: Allocator,
    host: *Host,
    stream: std.Io.net.Stream,
    task_token: ?TaskToken,

    fn run(self: *UnixTask) void {
        defer self.alloc.destroy(self);
        defer if (self.task_token) |token| self.host.unregisterTask(token);
        if (!peerMatchesCurrentUser(self.stream.socket.handle)) {
            self.stream.close(io_mod.getIo());
            return;
        }
        var wire_state: UnixWire = undefined;
        wire_state.init(self.stream);
        var principal = contracts.Principal{
            .control_sessions = self.alloc.alloc([]u8, 1) catch {
                wire_state.wire().close();
                return;
            },
        };
        principal.control_sessions[0] = self.alloc.dupe(u8, "*") catch {
            self.alloc.free(principal.control_sessions);
            wire_state.wire().close();
            return;
        };
        Connection.run(self.alloc, self.host, wire_state.wire(), principal, true, &self.task_token) catch {};
    }
};

fn setSocketSendTimeout(handle: std.Io.net.Socket.Handle) void {
    if (comptime builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const timeout = std.posix.timeval{ .sec = contracts.socket_send_timeout_seconds, .usec = 0 };
        std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
    }
}

fn peerMatchesCurrentUser(handle: std.Io.net.Socket.Handle) bool {
    if (comptime builtin.os.tag == .linux) {
        const UCred = extern struct {
            pid: std.c.pid_t,
            uid: std.c.uid_t,
            gid: std.c.gid_t,
        };
        var credentials: UCred = undefined;
        var credentials_len: std.c.socklen_t = @sizeOf(UCred);
        if (std.c.getsockopt(handle, std.c.SOL.SOCKET, std.c.SO.PEERCRED, &credentials, &credentials_len) != 0) return false;
        return credentials_len == @sizeOf(UCred) and credentials.uid == std.c.getuid();
    }
    if (comptime builtin.os.tag == .macos) {
        var uid: std.c.uid_t = undefined;
        var gid: std.c.gid_t = undefined;
        const Peer = struct {
            extern "c" fn getpeereid(socket: std.c.fd_t, effective_uid: *std.c.uid_t, effective_gid: *std.c.gid_t) c_int;
        };
        if (Peer.getpeereid(handle, &uid, &gid) != 0) return false;
        return uid == std.c.getuid();
    }
    return false;
}

fn runWebSocket(
    alloc: Allocator,
    host: *Host,
    endpoint: @FieldType(Endpoint, "websocket"),
    capability: []const u8,
) !void {
    if (endpoint.secure or !std.mem.eql(u8, endpoint.host, "127.0.0.1"))
        return error.NonLoopbackWebSocket;
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", endpoint.port);
    var server = try address.listen(io_mod.getIo(), .{ .reuse_address = true });
    defer server.deinit(io_mod.getIo());
    var endpoint_text: [512]u8 = undefined;
    const listening = try std.fmt.bufPrint(&endpoint_text, "fx serve: listening on ws://127.0.0.1:{d}{s}\n", .{ endpoint.port, endpoint.path });
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), listening);
    while (true) {
        const stream = try server.accept(io_mod.getIo());
        setSocketSendTimeout(stream.socket.handle);
        const task_token = host.registerTask(stream) catch |err| {
            stream.close(io_mod.getIo());
            if (err == error.ConnectionCapacityExceeded) continue;
            return err;
        };
        const task = alloc.create(WebSocketTask) catch |err| {
            host.unregisterTask(task_token);
            stream.close(io_mod.getIo());
            return err;
        };
        task.* = .{
            .alloc = alloc,
            .host = host,
            .stream = stream,
            .path = endpoint.path,
            .capability = capability,
            .task_token = task_token,
        };
        var thread = std.Thread.spawn(.{}, WebSocketTask.run, .{task}) catch |err| {
            host.unregisterTask(task_token);
            stream.close(io_mod.getIo());
            alloc.destroy(task);
            return err;
        };
        thread.detach();
    }
}

fn validClosePayload(payload: []const u8) bool {
    if (payload.len == 0) return true;
    if (payload.len == 1) return false;
    const code = std.mem.readInt(u16, payload[0..2], .big);
    const valid_code = (code >= 1000 and code <= 1014 and code != 1004 and code != 1005 and
        code != 1006) or (code >= 3000 and code <= 4999);
    return valid_code and std.unicode.utf8ValidateSlice(payload[2..]);
}

const WebSocketWire = struct {
    stream: std.Io.net.Stream,
    websocket: std.http.Server.WebSocket,
    write_mutex: std.Io.Mutex = .init,
    closed: std.atomic.Value(bool) = .init(false),

    fn wire(self: *WebSocketWire) Wire {
        return .{ .context = self, .read_fn = read, .write_fn = write, .interrupt_fn = interrupt, .close_fn = close };
    }

    fn read(raw: *anyopaque, alloc: Allocator) !?[]u8 {
        const self: *WebSocketWire = @ptrCast(@alignCast(raw));
        const reader = self.websocket.input;
        while (true) {
            const first = reader.takeByte() catch return null;
            const second = reader.takeByte() catch return error.TruncatedFrame;
            const fin = first & 0x80 != 0;
            const opcode = first & 0x0f;
            const control = opcode >= 8;
            if (!fin or first & 0x70 != 0 or second & 0x80 == 0) return error.InvalidWebSocketFrame;
            if (opcode != 1 and opcode != 8 and opcode != 9 and opcode != 10) return error.InvalidWebSocketFrame;
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
            const mask = try reader.takeArray(4);
            const payload = try alloc.alloc(u8, length);
            reader.readSliceAll(payload) catch {
                alloc.free(payload);
                return error.TruncatedFrame;
            };
            for (payload, 0..) |*byte, index| byte.* ^= mask[index % 4];
            if (opcode == 8) {
                const valid = validClosePayload(payload);
                alloc.free(payload);
                if (!valid) return error.InvalidWebSocketFrame;
                return null;
            }
            if (opcode == 9) {
                const io = io_mod.getIo();
                self.write_mutex.lockUncancelable(io);
                self.websocket.writeMessage(payload, .pong) catch |err| {
                    self.write_mutex.unlock(io);
                    alloc.free(payload);
                    return err;
                };
                self.write_mutex.unlock(io);
                alloc.free(payload);
                continue;
            }
            if (opcode == 10) {
                alloc.free(payload);
                continue;
            }
            if (!std.unicode.utf8ValidateSlice(payload)) {
                alloc.free(payload);
                return error.InvalidUtf8;
            }
            return payload;
        }
    }

    fn write(raw: *anyopaque, bytes_value: []const u8) !void {
        const self: *WebSocketWire = @ptrCast(@alignCast(raw));
        const bytes = std.mem.trimEnd(u8, bytes_value, "\r\n");
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        const io = io_mod.getIo();
        self.write_mutex.lockUncancelable(io);
        defer self.write_mutex.unlock(io);
        try self.websocket.writeMessage(bytes, .text);
    }

    fn interrupt(raw: *anyopaque) void {
        const self: *WebSocketWire = @ptrCast(@alignCast(raw));
        self.stream.shutdown(io_mod.getIo(), .both) catch {};
    }

    fn close(raw: *anyopaque) void {
        const self: *WebSocketWire = @ptrCast(@alignCast(raw));
        if (self.closed.swap(true, .acq_rel)) return;
        self.stream.shutdown(io_mod.getIo(), .both) catch {};
        self.stream.close(io_mod.getIo());
    }
};

const WebSocketTask = struct {
    alloc: Allocator,
    host: *Host,
    stream: std.Io.net.Stream,
    path: []const u8,
    capability: []const u8,
    task_token: ?TaskToken,

    fn run(self: *WebSocketTask) void {
        defer self.alloc.destroy(self);
        defer if (self.task_token) |token| self.host.unregisterTask(token);
        self.runFallible() catch {
            self.stream.close(io_mod.getIo());
        };
    }

    fn runFallible(self: *WebSocketTask) !void {
        const read_buffer = try self.alloc.alloc(u8, contracts.max_upgrade_header_bytes);
        defer self.alloc.free(read_buffer);
        var write_buffer: [64 * 1024]u8 = undefined;
        var reader = self.stream.reader(io_mod.getIo(), read_buffer);
        var writer = self.stream.writer(io_mod.getIo(), &write_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = server.receiveHead() catch return error.InvalidHttpUpgrade;
        if (!std.mem.eql(u8, request.head.target, self.path)) {
            try request.respond("not found\n", .{ .status = .not_found, .keep_alive = false });
            return;
        }
        var capability_header: ?[]const u8 = null;
        var capability_count: usize = 0;
        var connection_count: usize = 0;
        var connection_ok = false;
        var upgrade_count: usize = 0;
        var upgrade_ok = false;
        var version_ok = false;
        var version_count: usize = 0;
        var key_count: usize = 0;
        var unsupported_extension = false;
        var unsupported_protocol = false;
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "tailscale-app-capabilities")) {
                capability_count += 1;
                capability_header = header.value;
            } else if (std.ascii.eqlIgnoreCase(header.name, "connection")) {
                connection_count += 1;
                connection_ok = std.ascii.eqlIgnoreCase(std.mem.trim(u8, header.value, " \t"), "upgrade");
            } else if (std.ascii.eqlIgnoreCase(header.name, "upgrade")) {
                upgrade_count += 1;
                upgrade_ok = std.ascii.eqlIgnoreCase(std.mem.trim(u8, header.value, " \t"), "websocket");
            } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-version")) {
                version_count += 1;
                version_ok = std.mem.eql(u8, header.value, "13");
            } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-key")) {
                key_count += 1;
            } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-extensions")) {
                unsupported_extension = true;
            } else if (std.ascii.eqlIgnoreCase(header.name, "sec-websocket-protocol")) {
                unsupported_protocol = true;
            }
        }
        const upgrade = request.upgradeRequested();
        const key = switch (upgrade) {
            .websocket => |maybe_key| maybe_key orelse {
                try request.respond("bad websocket upgrade\n", .{ .status = .bad_request, .keep_alive = false });
                return;
            },
            else => {
                try request.respond("bad websocket upgrade\n", .{ .status = .bad_request, .keep_alive = false });
                return;
            },
        };
        if (!connection_ok or connection_count != 1 or !upgrade_ok or upgrade_count != 1 or
            !version_ok or version_count != 1 or key_count != 1 or !validWebSocketKey(key) or
            unsupported_extension or unsupported_protocol or capability_count != 1)
        {
            try request.respond("forbidden\n", .{ .status = .forbidden, .keep_alive = false });
            return;
        }
        var principal = contracts.parseCapabilityHeader(
            self.alloc,
            capability_header orelse "",
            self.capability,
        ) catch {
            try request.respond("forbidden\n", .{ .status = .forbidden, .keep_alive = false });
            return;
        };
        var principal_owned = true;
        defer if (principal_owned) principal.deinit(self.alloc);
        var websocket = try request.respondWebSocket(.{ .key = key });
        try websocket.flush();
        var wire_state = WebSocketWire{ .stream = self.stream, .websocket = websocket };
        principal_owned = false;
        Connection.run(self.alloc, self.host, wire_state.wire(), principal, false, &self.task_token) catch {};
    }

    fn validWebSocketKey(key: []const u8) bool {
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(key) catch return false;
        if (decoded_len != 16) return false;
        var decoded: [16]u8 = undefined;
        std.base64.standard.Decoder.decode(&decoded, key) catch return false;
        return true;
    }
};

test "websocket key validation requires one canonical 16-byte value" {
    try std.testing.expect(WebSocketTask.validWebSocketKey("AQEBAQEBAQEBAQEBAQEBAQ=="));
    try std.testing.expect(!WebSocketTask.validWebSocketKey("not-base64"));
    try std.testing.expect(!WebSocketTask.validWebSocketKey("AQEBAQ=="));
}

test "outbound queue enforces message and byte limits" {
    var queue = OutboundQueue.init(std.testing.allocator);
    defer queue.deinit();
    const oversized = try std.testing.allocator.alloc(u8, contracts.max_frame_bytes + 1);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(error.FrameTooLarge, queue.enqueue(oversized));
    for (0..contracts.max_outbound_messages) |_| try queue.enqueue("x");
    try std.testing.expectError(error.OutboundCapacityExceeded, queue.enqueue("x"));
    try std.testing.expect(queue.overflowed);
    queue.close();
}

test "attachment buffering enforces exact frame and aggregate boundaries" {
    const alloc = std.testing.allocator;
    var queue = OutboundQueue.init(alloc);
    defer queue.deinit();
    var attachment = Attachment{
        .id = @splat('a'),
        .role = .observer,
        .control_epoch = 0,
        .queue = &queue,
    };
    defer attachment.deinit(alloc);
    try std.testing.expectError(error.FrameTooLarge, attachment.enqueue(alloc, ""));

    var second_queue = OutboundQueue.init(alloc);
    defer second_queue.deinit();
    var boundary = Attachment{
        .id = @splat('b'),
        .role = .observer,
        .control_epoch = 0,
        .queue = &second_queue,
    };
    defer boundary.deinit(alloc);
    const exact = try alloc.alloc(u8, contracts.max_frame_bytes);
    defer alloc.free(exact);
    @memset(exact, 'x');
    try boundary.enqueue(alloc, exact);
    try std.testing.expectEqual(contracts.max_frame_bytes, boundary.buffered_bytes);
    try std.testing.expectError(error.OutboundCapacityExceeded, boundary.enqueue(alloc, "x"));
    try std.testing.expect(second_queue.closed);
}

test "connection task capacity rejects only the newest task and recovers" {
    var host = Host.init(std.testing.allocator, undefined);
    var tokens: [64]TaskToken = undefined;
    for (&tokens) |*token| token.* = try host.registerTask(undefined);
    try std.testing.expectError(error.ConnectionCapacityExceeded, host.registerTask(undefined));
    host.unregisterTask(tokens[0]);
    tokens[0] = try host.registerTask(undefined);
    for (tokens) |token| host.unregisterTask(token);
}

test "promotion transfers task ownership and late unregister cannot clear a reused slot" {
    var host = Host.init(std.testing.allocator, undefined);
    const first = try host.registerTask(undefined);
    var owned: ?TaskToken = first;
    var connection: Connection = undefined;
    try host.promoteOwnedTask(&owned, &connection);
    try std.testing.expect(owned == null);
    const replacement = try host.registerTask(undefined);
    try std.testing.expectEqual(first.index, replacement.index);
    host.unregisterTask(first);
    try std.testing.expect(host.task_streams[replacement.index] != null);
    try std.testing.expectEqual(replacement.generation, host.task_generations[replacement.index]);
    host.unregisterTask(replacement);
    for (&host.connections) |*slot| {
        if (slot.* == &connection) slot.* = null;
    }
}

test "host shutdown and connection finalization serialize queue and wire destruction" {
    const alloc = std.testing.allocator;
    const TestWire = struct {
        interrupted: std.atomic.Value(bool) = .init(false),
        closed: std.atomic.Value(bool) = .init(false),

        fn wire(self: *@This()) Wire {
            return .{
                .context = self,
                .read_fn = read,
                .write_fn = write,
                .interrupt_fn = interrupt,
                .close_fn = close,
            };
        }

        fn read(_: *anyopaque, _: Allocator) !?[]u8 {
            return null;
        }

        fn write(_: *anyopaque, _: []const u8) !void {}

        fn interrupt(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.interrupted.store(true, .release);
        }

        fn close(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.closed.store(true, .release);
        }
    };
    var wire_state = TestWire{};
    var host = Host.init(alloc, undefined);
    var connection = Connection{
        .alloc = alloc,
        .host = &host,
        .wire = wire_state.wire(),
        .principal = .{
            .observe_sessions = try alloc.alloc([]u8, 0),
            .control_sessions = try alloc.alloc([]u8, 0),
        },
        .queue = OutboundQueue.init(alloc),
        .writer = undefined,
    };
    connection.queue.overflow_context = &connection;
    connection.queue.overflow_fn = Connection.interrupt;
    connection.writer = jsonrpc.Writer.initCallback(&connection.queue, OutboundQueue.callback);
    connection.writer_thread = try std.Thread.spawn(.{}, Connection.writerMain, .{&connection});
    host.connections[0] = &connection;

    const Finalizer = struct {
        fn run(target: *Host, active: *Connection, state: *TestWire) void {
            while (!state.interrupted.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
            target.finalizeConnection(active);
        }
    };
    var finalizer = try std.Thread.spawn(.{}, Finalizer.run, .{ &host, &connection, &wire_state });
    host.deinit();
    finalizer.join();
    try std.testing.expect(wire_state.interrupted.load(.acquire));
    try std.testing.expect(wire_state.closed.load(.acquire));
}

test "slow attachment overflow does not harm another observer or actor" {
    const alloc = std.testing.allocator;
    var actor = Actor{
        .alloc = alloc,
        .cfg = undefined,
        .session_id = try alloc.dupe(u8, "session"),
        .pipe = BytePipe.init(alloc),
    };
    defer {
        actor.projection.deinit(alloc);
        actor.operations.deinit(alloc);
        actor.pending_routes.deinit(alloc);
        actor.pipe.deinit();
        alloc.free(actor.session_id);
    }
    var slow_queue = OutboundQueue.init(alloc);
    defer slow_queue.deinit();
    var healthy_queue = OutboundQueue.init(alloc);
    defer healthy_queue.deinit();
    const slow = try actor.attachLocked(&slow_queue, .observer);
    defer actor.detach(slow);
    const healthy = try actor.attachLocked(&healthy_queue, .observer);
    defer actor.detach(healthy);
    slow.buffering = false;
    healthy.buffering = false;
    for (0..contracts.max_outbound_messages) |_| try slow_queue.enqueue("occupied");
    actor.revision = 1;
    try actor.broadcastEvent("{\"jsonrpc\":\"2.0\",\"method\":\"test/event\",\"params\":{}}");
    try std.testing.expect(slow_queue.closed);
    try std.testing.expect(!healthy_queue.closed);
    const delivered = healthy_queue.take().?;
    defer alloc.free(delivered);
    try std.testing.expect(std.mem.find(u8, delivered, "test/event") != null);
}

test "primary control yields to takeover and returns after detach" {
    const alloc = std.testing.allocator;
    var actor = Actor{
        .alloc = alloc,
        .cfg = undefined,
        .session_id = try alloc.dupe(u8, "session"),
        .pipe = BytePipe.init(alloc),
    };
    defer {
        actor.projection.deinit(alloc);
        actor.operations.deinit(alloc);
        actor.pending_routes.deinit(alloc);
        actor.pipe.deinit();
        alloc.free(actor.session_id);
    }
    var primary_queue = OutboundQueue.init(alloc);
    defer primary_queue.deinit();
    var takeover_queue = OutboundQueue.init(alloc);
    defer takeover_queue.deinit();

    const primary = try actor.attachLocked(&primary_queue, .primary);
    primary.buffering = false;
    const primary_epoch = actor.control_epoch;
    try actor.validateController(primary, primary.idSlice(), primary_epoch);

    const takeover = try actor.attachLocked(&takeover_queue, .controller);
    takeover.buffering = false;
    try std.testing.expect(actor.control_epoch > primary_epoch);
    try std.testing.expectError(
        error.NotController,
        actor.validateController(primary, primary.idSlice(), actor.control_epoch),
    );
    try actor.validateController(takeover, takeover.idSlice(), actor.control_epoch);
    try std.testing.expect(primary_queue.messages.items.len > 0);
    try std.testing.expect(std.mem.find(u8, primary_queue.messages.items[primary_queue.messages.items.len - 1], "fx/control_changed") != null);

    actor.detach(takeover);
    try actor.validateController(primary, primary.idSlice(), actor.control_epoch);
    try std.testing.expect(std.mem.find(u8, primary_queue.messages.items[primary_queue.messages.items.len - 1], "fx/control_changed") != null);
    actor.detach(primary);
}

test "control publication failure closes clients that can miss the revision" {
    const alloc = std.testing.allocator;
    var actor = Actor{
        .alloc = alloc,
        .cfg = undefined,
        .session_id = try alloc.dupe(u8, "session"),
        .pipe = BytePipe.init(alloc),
    };
    defer {
        actor.projection.deinit(alloc);
        actor.operations.deinit(alloc);
        actor.pending_routes.deinit(alloc);
        actor.pipe.deinit();
        alloc.free(actor.session_id);
    }
    var observer_queue = OutboundQueue.init(alloc);
    defer observer_queue.deinit();
    var primary_queue = OutboundQueue.init(alloc);
    defer primary_queue.deinit();
    const observer = try actor.attachLocked(&observer_queue, .observer);
    const primary = try actor.attachLocked(&primary_queue, .primary);

    actor.failControlPublication(primary);
    try std.testing.expect(observer_queue.closed);
    try std.testing.expect(!primary_queue.closed);

    actor.detach(primary);
    actor.detach(observer);
}

test "accepted prompt projects canonical text once across idempotent replay" {
    const alloc = std.testing.allocator;
    var actor = Actor{
        .alloc = alloc,
        .cfg = undefined,
        .session_id = try alloc.dupe(u8, "session"),
        .pipe = BytePipe.init(alloc),
    };
    defer {
        actor.projection.deinit(alloc);
        for (actor.operations.items) |*operation| operation.deinit(alloc);
        actor.operations.deinit(alloc);
        actor.pending_routes.deinit(alloc);
        actor.pipe.deinit();
        alloc.free(actor.session_id);
    }
    var queue = OutboundQueue.init(alloc);
    defer queue.deinit();
    const controller = try actor.attachLocked(&queue, .controller);
    defer actor.detach(controller);
    controller.buffering = false;

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "[{\"type\":\"resource\",\"resource\":{\"uri\":\"https://example.com/context.md\",\"text\":\"context\"}},{\"type\":\"text\",\"text\":\"first\"},{\"type\":\"text\",\"text\":\"second\"}]",
        .{},
    );
    defer parsed.deinit();
    var first_operation: std.Io.Writer.Allocating = .init(alloc);
    defer first_operation.deinit();
    const first_replayed = try actor.beginPrompt(
        controller,
        controller.idSlice(),
        controller.control_epoch,
        "operation-1",
        parsed.value,
        &first_operation.writer,
    );
    try std.testing.expect(!first_replayed);
    try std.testing.expect(std.mem.find(u8, first_operation.writer.buffered(), "\"operationId\":\"operation-1\"") != null);
    try std.testing.expectEqual(@as(usize, 1), actor.projection.history.items.len);
    try std.testing.expectEqualStrings(
        "File: https://example.com/context.md\ncontext\nfirst\nsecond",
        actor.projection.history.items[0].text,
    );

    var user_events: usize = 0;
    for (queue.messages.items) |message| {
        if (std.mem.find(u8, message, "user_message_chunk") != null) user_events += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), user_events);
    const messages_before_replay = queue.messages.items.len;

    var replay_operation: std.Io.Writer.Allocating = .init(alloc);
    defer replay_operation.deinit();
    const replayed = try actor.beginPrompt(
        controller,
        controller.idSlice(),
        controller.control_epoch,
        "operation-1",
        parsed.value,
        &replay_operation.writer,
    );
    try std.testing.expect(replayed);
    try std.testing.expectEqualStrings(first_operation.writer.buffered(), replay_operation.writer.buffered());
    try std.testing.expectEqual(@as(usize, 1), actor.projection.history.items.len);
    try std.testing.expectEqual(messages_before_replay, queue.messages.items.len);

    // A replay response owns its serialized bytes before the actor unlocks.
    // Filling and then evicting the source record cannot invalidate the reply.
    actor.operations.items[0].state = .completed;
    actor.pending_routes.clearRetainingCapacity();
    actor.active_operation_internal_id = null;
    for (1..contracts.max_operations_per_actor) |index| {
        const operation_id = try std.fmt.allocPrint(alloc, "terminal-{d}", .{index});
        try actor.operations.append(alloc, .{
            .id = operation_id,
            .payload_digest = @splat(0),
            .state = .completed,
        });
    }
    var capacity_replay: std.Io.Writer.Allocating = .init(alloc);
    defer capacity_replay.deinit();
    try std.testing.expect(try actor.beginPrompt(
        controller,
        controller.idSlice(),
        actor.control_epoch,
        "operation-1",
        parsed.value,
        &capacity_replay.writer,
    ));
    try std.testing.expectEqual(contracts.max_operations_per_actor, actor.operations.items.len);
    try actor.evictOldestTerminalOperation();
    try std.testing.expect(std.mem.find(u8, capacity_replay.writer.buffered(), "\"operationId\":\"operation-1\"") != null);
    try std.testing.expect(!std.mem.eql(u8, actor.operations.items[0].id, "operation-1"));
}

test "projection and nested event serialization strip terminal controls" {
    const alloc = std.testing.allocator;
    var projection = Projection{ .run_state = .running };
    defer projection.deinit(alloc);
    const updates = [_][]const u8{
        "{\"params\":{\"update\":{\"sessionUpdate\":\"user_message_chunk\",\"content\":{\"text\":\"user\\u001b[31m\\u0000\"}}}}",
        "{\"params\":{\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"text\":\"assistant\\u001b[32m\"}}}}",
        "{\"params\":{\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"tool\\u001b-id\",\"title\":\"title\\u0085bad\",\"kind\":\"execute\",\"status\":\"pending\"}}}",
        "{\"params\":{\"update\":{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"tool\\u001b-id\",\"status\":\"in_progress\",\"content\":[{\"content\":{\"text\":\"progress\\u001b[2J\"}}]}}}",
    };
    for (updates) |encoded| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded, .{});
        defer parsed.deinit();
        try projection.consumeUpdate(alloc, parsed.value, false);
    }
    try std.testing.expectEqualStrings("user[31m", projection.history.items[0].text);
    try std.testing.expectEqualStrings("assistant[32m", projection.assistant_partial.items);
    try std.testing.expectEqualStrings("tool-id", projection.tools.items[0].id);
    try std.testing.expectEqualStrings("titlebad", projection.tools.items[0].title);
    try std.testing.expectEqualStrings("progress[2J", projection.tools.items[0].progress.?);

    var nested = try std.json.parseFromSlice(std.json.Value, alloc, "{\"method\":\"session/update\",\"params\":{\"text\":\"live\\u001b[9m\"}}", .{});
    defer nested.deinit();
    var serialized: std.Io.Writer.Allocating = .init(alloc);
    defer serialized.deinit();
    try writeSanitizedJsonValue(alloc, &serialized.writer, nested.value);
    try std.testing.expect(std.mem.find(u8, serialized.writer.buffered(), "\\u001b") == null);
    try std.testing.expect(std.mem.find(u8, serialized.writer.buffered(), "live[9m") != null);
}

test "tool projection exhaustion closes attachments and rejects incomplete reattach snapshots" {
    const alloc = std.testing.allocator;
    var actor = Actor{
        .alloc = alloc,
        .cfg = undefined,
        .session_id = try alloc.dupe(u8, "session"),
        .pipe = BytePipe.init(alloc),
    };
    defer {
        actor.projection.deinit(alloc);
        actor.operations.deinit(alloc);
        actor.pending_routes.deinit(alloc);
        actor.pipe.deinit();
        alloc.free(actor.session_id);
    }
    var first_queue = OutboundQueue.init(alloc);
    defer first_queue.deinit();
    const first = try actor.attachLocked(&first_queue, .observer);

    for (0..contracts.max_tools_per_actor + 1) |index| {
        const encoded = try std.fmt.allocPrint(
            alloc,
            "{{\"params\":{{\"update\":{{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"tool-{d}\",\"title\":\"Tool\",\"kind\":\"execute\",\"status\":\"pending\"}}}}}}",
            .{index},
        );
        defer alloc.free(encoded);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded, .{});
        defer parsed.deinit();
        if (index < contracts.max_tools_per_actor) {
            try actor.projection.consumeUpdate(alloc, parsed.value, false);
        } else {
            try std.testing.expectError(
                error.ToolProjectionCapacityExceeded,
                actor.projection.consumeUpdate(alloc, parsed.value, false),
            );
        }
    }
    actor.failProjectionLocked();
    try std.testing.expect(!actor.projection.complete);
    try std.testing.expect(first_queue.closed);
    actor.detach(first);

    var replacement_queue = OutboundQueue.init(alloc);
    defer replacement_queue.deinit();
    try std.testing.expectError(error.ProjectionUnavailable, actor.attachLocked(&replacement_queue, .observer));
    var snapshot: std.Io.Writer.Allocating = .init(alloc);
    defer snapshot.deinit();
    try std.testing.expectError(error.ProjectionUnavailable, actor.writeSnapshotJson(&snapshot.writer, "replacement"));
}

test "snapshot reconstructs assistant partial and running tool" {
    const alloc = std.testing.allocator;
    var actor = Actor{
        .alloc = alloc,
        .cfg = undefined,
        .session_id = try alloc.dupe(u8, "session"),
        .pipe = BytePipe.init(alloc),
    };
    defer {
        actor.projection.deinit(alloc);
        actor.operations.deinit(alloc);
        actor.pending_routes.deinit(alloc);
        actor.pipe.deinit();
        alloc.free(actor.session_id);
    }
    actor.projection.run_state = .running;
    try actor.projection.assistant_partial.appendSlice(alloc, "partial answer");
    try actor.projection.tools.append(alloc, .{
        .id = try alloc.dupe(u8, "tool-1"),
        .title = try alloc.dupe(u8, "Running tool"),
        .kind = try alloc.dupe(u8, "execute"),
        .status = try alloc.dupe(u8, "in_progress"),
        .progress = try alloc.dupe(u8, "halfway"),
    });
    var snapshot: std.Io.Writer.Allocating = .init(alloc);
    defer snapshot.deinit();
    try actor.writeSnapshotJson(&snapshot.writer, "snapshot-test");
    try std.testing.expect(std.mem.find(u8, snapshot.writer.buffered(), "\"snapshotId\":\"snapshot-test\"") != null);
    try std.testing.expect(std.mem.find(u8, snapshot.writer.buffered(), "partial answer") != null);
    try std.testing.expect(std.mem.find(u8, snapshot.writer.buffered(), "in_progress") != null);
    try std.testing.expect(std.mem.find(u8, snapshot.writer.buffered(), "halfway") != null);
}

test "registration snapshot boundary buffers only post-snapshot revisions" {
    const alloc = std.testing.allocator;
    var actor = Actor{
        .alloc = alloc,
        .cfg = undefined,
        .session_id = try alloc.dupe(u8, "session"),
        .pipe = BytePipe.init(alloc),
    };
    defer {
        actor.projection.deinit(alloc);
        actor.operations.deinit(alloc);
        actor.pending_routes.deinit(alloc);
        actor.pipe.deinit();
        alloc.free(actor.session_id);
    }
    var queue = OutboundQueue.init(alloc);
    defer queue.deinit();
    const attachment = try actor.attachLocked(&queue, .observer);
    defer actor.detach(attachment);
    var snapshot: std.Io.Writer.Allocating = .init(alloc);
    defer snapshot.deinit();
    try actor.writeSnapshotJson(&snapshot.writer, "snapshot-test");
    try std.testing.expect(std.mem.find(u8, snapshot.writer.buffered(), "\"snapshotId\":\"snapshot-test\"") != null);
    try std.testing.expect(std.mem.find(u8, snapshot.writer.buffered(), "\"revision\":0") != null);
    actor.revision = 1;
    try actor.broadcastEvent("{\"jsonrpc\":\"2.0\",\"method\":\"test/event\",\"params\":{}}");
    try std.testing.expectEqual(@as(usize, 1), attachment.buffered.items.len);
    try std.testing.expect(std.mem.find(u8, attachment.buffered.items[0], "\"revision\":1") != null);
}

test "snapshot above one frame is transferred in bounded ordered chunks" {
    const alloc = std.testing.allocator;
    const snapshot = try alloc.alloc(u8, contracts.max_frame_bytes + 17);
    defer alloc.free(snapshot);
    @memset(snapshot, 's');
    @memcpy(snapshot[contracts.snapshot_chunk_bytes - 1 .. contracts.snapshot_chunk_bytes + 2], "✓");
    var connection = Connection{
        .alloc = alloc,
        .host = undefined,
        .wire = undefined,
        .principal = .{},
        .queue = OutboundQueue.init(alloc),
        .writer = undefined,
    };
    defer connection.queue.deinit();
    var attachment = Attachment{
        .id = @splat('c'),
        .role = .observer,
        .control_epoch = 0,
        .queue = &connection.queue,
    };
    defer attachment.deinit(alloc);
    const Sender = struct {
        fn run(target: *Connection, target_attachment: *Attachment, bytes: []const u8) void {
            target.sendSnapshotChunks(target_attachment, bytes, 9) catch target.queue.close();
        }
    };
    var sender = try std.Thread.spawn(.{}, Sender.run, .{ &connection, &attachment, snapshot });
    const count = std.math.divCeil(usize, snapshot.len, contracts.snapshot_chunk_bytes) catch unreachable;
    var rebuilt: std.ArrayList(u8) = .empty;
    defer rebuilt.deinit(alloc);
    for (0..count) |expected_index| {
        const frame = connection.queue.take().?;
        defer alloc.free(frame);
        try std.testing.expect(frame.len <= contracts.max_frame_bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame, .{});
        defer parsed.deinit();
        const params = parsed.value.object.get("params").?;
        try std.testing.expectEqual(@as(i64, @intCast(expected_index)), params.object.get("index").?.integer);
        try std.testing.expectEqualStrings("base64", Projection.stringField(params, "encoding").?);
        const encoded = Projection.stringField(params, "data").?;
        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
        const old_len = rebuilt.items.len;
        try rebuilt.resize(alloc, old_len + decoded_len);
        try std.base64.standard.Decoder.decode(rebuilt.items[old_len..], encoded);
    }
    sender.join();
    try std.testing.expectEqualSlices(u8, snapshot, rebuilt.items);
}

test "rejected authoritative configuration response leaves projection unchanged" {
    const alloc = std.testing.allocator;
    var actor = Actor{
        .alloc = alloc,
        .cfg = undefined,
        .session_id = try alloc.dupe(u8, "session"),
        .pipe = BytePipe.init(alloc),
    };
    defer {
        actor.projection.deinit(alloc);
        actor.operations.deinit(alloc);
        actor.pending_routes.deinit(alloc);
        actor.pipe.deinit();
        alloc.free(actor.session_id);
    }
    actor.projection.current_mode = try alloc.dupe(u8, "ask");
    var waiter = ConfigureWait{ .kind = "mode", .value = "code" };
    try actor.pending_routes.append(alloc, .{ .internal_id = 44, .configure_wait = &waiter });
    var response = try std.json.parseFromSlice(std.json.Value, alloc, "{\"error\":{\"code\":-32602,\"message\":\"rejected\"}}", .{});
    defer response.deinit();
    try actor.handleInternalResponse(44, response.value);
    try std.testing.expect(waiter.done);
    try std.testing.expect(!waiter.succeeded);
    try std.testing.expectEqualStrings("ask", actor.projection.current_mode.?);
    try std.testing.expectEqual(@as(u64, 0), actor.revision);
}

test "configuration is rejected during active work without retaining the controller" {
    const alloc = std.testing.allocator;
    var actor = Actor{
        .alloc = alloc,
        .cfg = undefined,
        .session_id = try alloc.dupe(u8, "session"),
        .pipe = BytePipe.init(alloc),
    };
    defer {
        actor.projection.deinit(alloc);
        actor.operations.deinit(alloc);
        actor.pending_routes.deinit(alloc);
        actor.pipe.deinit();
        alloc.free(actor.session_id);
    }
    actor.projection.current_mode = try alloc.dupe(u8, "ask");
    try actor.projection.available_modes.append(alloc, try alloc.dupe(u8, "ask"));
    try actor.projection.available_modes.append(alloc, try alloc.dupe(u8, "code"));
    actor.projection.run_state = .running;
    actor.active_operation_internal_id = 55;

    var first_queue = OutboundQueue.init(alloc);
    defer first_queue.deinit();
    const first = try actor.attachLocked(&first_queue, .controller);
    try std.testing.expectError(
        error.ConfigurationBusy,
        actor.configure(first, first.idSlice(), first.control_epoch, "mode", "code"),
    );
    try std.testing.expectEqual(@as(usize, 0), actor.pending_routes.items.len);
    actor.detach(first);

    var replacement_queue = OutboundQueue.init(alloc);
    defer replacement_queue.deinit();
    const replacement = try actor.attachLocked(&replacement_queue, .controller);
    actor.detach(replacement);
}

test "actor shutdown wakes a pending configuration and removes its route" {
    const alloc = std.testing.allocator;
    var actor = Actor{
        .alloc = alloc,
        .cfg = undefined,
        .session_id = try alloc.dupe(u8, "session"),
        .pipe = BytePipe.init(alloc),
    };
    defer {
        actor.projection.deinit(alloc);
        actor.operations.deinit(alloc);
        actor.pending_routes.deinit(alloc);
        actor.pipe.deinit();
        alloc.free(actor.session_id);
    }
    actor.projection.current_mode = try alloc.dupe(u8, "ask");
    try actor.projection.available_modes.append(alloc, try alloc.dupe(u8, "ask"));
    try actor.projection.available_modes.append(alloc, try alloc.dupe(u8, "code"));
    var queue = OutboundQueue.init(alloc);
    defer queue.deinit();
    const attachment = try actor.attachLocked(&queue, .controller);
    defer actor.detach(attachment);

    const Context = struct {
        actor: *Actor,
        attachment: *Attachment,
        result: ?anyerror = null,

        fn run(self: *@This()) void {
            self.actor.configure(
                self.attachment,
                self.attachment.idSlice(),
                self.attachment.control_epoch,
                "mode",
                "code",
            ) catch |err| {
                self.result = err;
                return;
            };
        }
    };
    var context = Context{ .actor = &actor, .attachment = attachment };
    var configure_thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    var route_registered = false;
    for (0..1000) |_| {
        const io = io_mod.getIo();
        actor.mutex.lockUncancelable(io);
        route_registered = actor.pending_routes.items.len == 1;
        actor.mutex.unlock(io);
        if (route_registered) break;
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(route_registered);
    actor.beginShutdown();
    configure_thread.join();
    const configure_error = context.result orelse return error.ExpectedConfigurationRejection;
    try std.testing.expectEqualStrings("ConfigurationRejected", @errorName(configure_error));
    try std.testing.expectEqual(@as(usize, 0), actor.pending_routes.items.len);
}

test "operation window evicts oldest terminal record and preserves active records" {
    const alloc = std.testing.allocator;
    var actor = Actor{
        .alloc = alloc,
        .cfg = undefined,
        .session_id = try alloc.dupe(u8, "session"),
        .pipe = BytePipe.init(alloc),
    };
    defer {
        for (actor.operations.items) |*operation| operation.deinit(alloc);
        actor.operations.deinit(alloc);
        actor.pending_routes.deinit(alloc);
        actor.pipe.deinit();
        alloc.free(actor.session_id);
    }
    for (0..contracts.max_operations_per_actor) |index| {
        const id = try std.fmt.allocPrint(alloc, "operation-{d}", .{index});
        errdefer alloc.free(id);
        try actor.operations.append(alloc, .{ .id = id, .payload_digest = @splat(0), .state = if (index == 1) .running else .completed });
    }
    try actor.evictOldestTerminalOperation();
    try actor.operations.append(alloc, .{
        .id = try alloc.dupe(u8, "operation-128"),
        .payload_digest = @splat(1),
        .state = .running,
    });
    try std.testing.expectEqual(contracts.max_operations_per_actor, actor.operations.items.len);
    try std.testing.expectEqualStrings("operation-1", actor.operations.items[0].id);
    try std.testing.expectEqualStrings("operation-128", actor.operations.items[contracts.max_operations_per_actor - 1].id);
}

test "pending interaction survives controller detach and exact replacement response" {
    const alloc = std.testing.allocator;
    var actor = Actor{
        .alloc = alloc,
        .cfg = undefined,
        .session_id = try alloc.dupe(u8, "session"),
        .pipe = BytePipe.init(alloc),
    };
    defer {
        actor.projection.deinit(alloc);
        actor.operations.deinit(alloc);
        actor.pending_routes.deinit(alloc);
        actor.pipe.deinit();
        alloc.free(actor.session_id);
    }
    actor.ready = true;
    actor.projection.pending = .{
        .id = 41,
        .method = try alloc.dupe(u8, "session/request_permission"),
        .params_json = try alloc.dupe(u8, "{\"options\":[]}"),
    };
    actor.projection.run_state = .waiting_input;

    var first_queue = OutboundQueue.init(alloc);
    defer first_queue.deinit();
    const first = try actor.attach(&first_queue, .controller);
    const first_id = first.id;
    const first_epoch = first.control_epoch;
    actor.detach(first);
    try std.testing.expectEqual(@as(u64, 41), actor.projection.pending.?.id);

    var second_queue = OutboundQueue.init(alloc);
    defer second_queue.deinit();
    const second = try actor.attach(&second_queue, .controller);
    defer actor.detach(second);
    var result = try std.json.parseFromSlice(std.json.Value, alloc, "{\"outcome\":{\"outcome\":\"selected\",\"optionId\":\"allow_once\"}}", .{});
    defer result.deinit();
    try std.testing.expectError(
        error.StaleAttachment,
        actor.respond(second, &first_id, first_epoch, 41, result.value, null),
    );
    try std.testing.expectError(
        error.StaleInteraction,
        actor.respond(second, second.idSlice(), second.control_epoch, 42, result.value, null),
    );
    try actor.respond(second, second.idSlice(), second.control_epoch, 41, result.value, null);
    try std.testing.expect(actor.projection.pending == null);
    try std.testing.expectEqual(contracts.RunState.running, actor.projection.run_state);
}
