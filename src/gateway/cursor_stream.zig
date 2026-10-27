//! Reduces Cursor's server messages into proto-fx stream events and one
//! completion, and produces the client replies the run needs (D203):
//!
//! - text and thinking deltas stream as content and reasoning;
//! - MCP tool calls stream their arguments as `tool_input_delta` and are
//!   handed off: Cursor gets proto's handoff text as the call's result, the
//!   model ends the turn, and proto-fx's own loop runs the call and sends the
//!   result in the next request, as proto does with `externalToolExecutor`;
//! - Cursor's own tools (read, shell, write and the rest) are refused, as
//!   proto refuses them when it has no handler, so every tool runs through
//!   proto-fx's tools and permissions;
//! - KV blob requests are served from the request's blob store, and
//!   interaction queries get proto's answers.
const std = @import("std");
const msg = @import("cursor_messages.zig");
const pb = @import("cursor_protobuf.zig");
const request_mod = @import("cursor_request.zig");
const chat = @import("chat_completions_protocol.zig");
const streams = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const Allocator = std.mem.Allocator;

pub const Limits = struct {
    content_bytes: usize = 16 * 1024 * 1024,
    reasoning_bytes: usize = 16 * 1024 * 1024,
    argument_bytes: usize = 4 * 1024 * 1024,
};

const Tool = struct {
    id: []u8,
    name: []u8,
    /// The envelope call id streamed updates refer to, if any.
    call_id: []u8,
    arguments: std.ArrayList(u8) = .empty,
    announced: bool = false,
    emitted: usize = 0,
    /// Arguments came whole from a decoded call rather than streamed text.
    settled: bool = false,

    fn deinit(self: *Tool, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        alloc.free(self.call_id);
        self.arguments.deinit(alloc);
    }
};

pub const Reducer = struct {
    alloc: Allocator,
    request: streams.RequestData,
    limits: Limits,
    /// Blobs Cursor asks for, and blobs it stores during the run. Borrowed.
    blobs: *request_mod.BlobStore,
    /// The reply to `request_context_args`. Borrowed.
    request_context: []const u8,
    /// Holds blobs Cursor sets.
    blob_arena: std.heap.ArenaAllocator,
    content: std.ArrayList(u8) = .empty,
    reasoning_bytes: usize = 0,
    tools: std.ArrayList(Tool) = .empty,
    usage: msg.TurnUsage = .{},
    estimated_output: u64 = 0,
    turn_ended: bool = false,
    /// Owned client messages waiting to be sent.
    replies: std.ArrayList([]u8) = .empty,

    pub fn init(alloc: Allocator, request: streams.RequestData, blobs: *request_mod.BlobStore, request_context: []const u8, limits: Limits) Reducer {
        return .{ .alloc = alloc, .request = request, .limits = limits, .blobs = blobs, .request_context = request_context, .blob_arena = .init(alloc) };
    }

    pub fn deinit(self: *Reducer) void {
        for (self.tools.items) |*tool| tool.deinit(self.alloc);
        self.tools.deinit(self.alloc);
        self.content.deinit(self.alloc);
        self.freeReplies();
        self.replies.deinit(self.alloc);
        self.blob_arena.deinit();
    }

    /// Replies produced since the last call; the caller sends them and then
    /// calls `freeReplies`.
    pub fn pendingReplies(self: *const Reducer) []const []u8 {
        return self.replies.items;
    }

    pub fn freeReplies(self: *Reducer) void {
        for (self.replies.items) |message| self.alloc.free(message);
        self.replies.clearRetainingCapacity();
    }

    fn reply(self: *Reducer, message: []u8) !void {
        errdefer self.alloc.free(message);
        try self.replies.append(self.alloc, message);
    }

    /// Applies one server message. `scratch` is freed by the caller after
    /// the call returns.
    pub fn accept(self: *Reducer, scratch: Allocator, message: msg.ServerMessage, sink: streams.EventSink) !void {
        switch (message) {
            .text_delta => |text| if (text.len != 0) {
                if (text.len > self.limits.content_bytes - self.content.items.len) return error.ContentTooLarge;
                try self.content.appendSlice(self.alloc, text);
                sink.emit(.{ .content_delta = text });
            },
            .thinking_delta => |text| if (text.len != 0) {
                if (text.len > self.limits.reasoning_bytes - self.reasoning_bytes) return error.ReplayTooLarge;
                self.reasoning_bytes += text.len;
                sink.emit(.{ .reasoning_delta = text });
            },
            .tool_call_started => |update| if (update.mcp) |call| {
                const tool = try self.toolFor(update.call_id, call, update.tool_call_id);
                try self.settleFrom(scratch, tool, call);
            },
            .partial_tool_call => |update| {
                const tool = self.byCallId(update.call_id) orelse blk: {
                    const call = update.mcp orelse return;
                    break :blk try self.toolFor(update.call_id, call, update.tool_call_id);
                };
                if (!tool.settled and update.args_text.len != 0) {
                    const current = tool.arguments.items;
                    const chunk = if (std.mem.startsWith(u8, update.args_text, current)) update.args_text[current.len..] else update.args_text;
                    if (chunk.len > self.limits.argument_bytes - current.len) return error.ArgumentsTooLarge;
                    try tool.arguments.appendSlice(self.alloc, chunk);
                }
            },
            .tool_call_completed => |update| if (update.mcp) |call| {
                const tool = self.byCallId(update.call_id) orelse try self.toolFor(update.call_id, call, update.tool_call_id);
                try self.settleFrom(scratch, tool, call);
            },
            .token_delta => |count| self.estimated_output +|= count,
            .turn_ended => |usage| {
                self.usage = usage;
                self.turn_ended = true;
            },
            .kv_get => |kv| {
                const data = if (kv.blob_id.len == 32) self.blobs.get(kv.blob_id[0..32].*) else null;
                try self.reply(try msg.getBlobResult(self.alloc, kv.id, data));
            },
            .kv_set => |kv| {
                if (kv.blob_id.len == 32) {
                    const arena = self.blob_arena.allocator();
                    try self.blobs.put(arena, kv.blob_id[0..32].*, try arena.dupe(u8, kv.data));
                }
                try self.reply(try msg.setBlobResult(self.alloc, kv.id));
            },
            .exec => |exec| try self.answerExec(scratch, exec),
            .interaction_query => |query| try self.answerQuery(query.id, query.field),
            .thinking_completed, .heartbeat, .checkpoint, .ignored => {},
        }
        self.emitToolProgress(sink);
    }

    fn byCallId(self: *Reducer, call_id: []const u8) ?*Tool {
        if (call_id.len == 0) return null;
        for (self.tools.items) |*tool| if (std.mem.eql(u8, tool.call_id, call_id)) return tool;
        return null;
    }

    fn byToolId(self: *Reducer, id: []const u8) ?*Tool {
        if (id.len == 0) return null;
        for (self.tools.items) |*tool| if (std.mem.eql(u8, tool.id, id)) return tool;
        return null;
    }

    /// The tool for a call, created on first sight. Its id is the call's
    /// tool_call_id, else the envelope's, else the envelope call id.
    fn toolFor(self: *Reducer, call_id: []const u8, call: msg.McpCall, envelope_id: []const u8) !*Tool {
        const id = if (call.tool_call_id.len != 0) call.tool_call_id else if (envelope_id.len != 0) envelope_id else call_id;
        if (id.len == 0) return error.MissingToolCallId;
        if (self.byToolId(id)) |tool| {
            if (tool.call_id.len == 0 and call_id.len != 0) {
                self.alloc.free(tool.call_id);
                tool.call_id = try self.alloc.dupe(u8, call_id);
            }
            return tool;
        }
        const name = call.displayName();
        if (name.len == 0) return error.MissingToolName;
        var tool: Tool = .{
            .id = try self.alloc.dupe(u8, id),
            .name = undefined,
            .call_id = undefined,
        };
        errdefer self.alloc.free(tool.id);
        tool.name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(tool.name);
        tool.call_id = try self.alloc.dupe(u8, call_id);
        errdefer self.alloc.free(tool.call_id);
        try self.tools.append(self.alloc, tool);
        return &self.tools.items[self.tools.items.len - 1];
    }

    /// Takes a decoded call's arguments when it carries any: they are the
    /// complete arguments, where streamed text may be partial.
    fn settleFrom(self: *Reducer, scratch: Allocator, tool: *Tool, call: msg.McpCall) !void {
        if (call.args.len == 0) return;
        var out: std.Io.Writer.Allocating = .init(scratch);
        try call.writeArgsJson(scratch, &out.writer);
        const decoded = out.written();
        if (std.mem.eql(u8, decoded, tool.arguments.items)) {
            tool.settled = true;
            return;
        }
        if (decoded.len > self.limits.argument_bytes) return error.ArgumentsTooLarge;
        // Streamed text that prefixes the decoded arguments keeps streaming;
        // otherwise the decoded arguments replace it silently, since the
        // display already holds the streamed chunks.
        const extends = std.mem.startsWith(u8, decoded, tool.arguments.items);
        tool.arguments.clearRetainingCapacity();
        try tool.arguments.appendSlice(self.alloc, decoded);
        if (!extends and tool.emitted != 0) tool.emitted = decoded.len;
        tool.settled = true;
    }

    fn emitToolProgress(self: *Reducer, sink: streams.EventSink) void {
        for (self.tools.items, 0..) |*tool, index| {
            if (!tool.announced) {
                tool.announced = true;
                sink.emit(.{ .tool_started = .{ .id = tool.id, .name = tool.name } });
            }
            if (tool.arguments.items.len > tool.emitted) {
                sink.emit(.{ .tool_input_delta = .{ .id = tool.id, .index = index, .chunk = tool.arguments.items[tool.emitted..] } });
                tool.emitted = tool.arguments.items.len;
            }
        }
    }

    fn answerExec(self: *Reducer, scratch: Allocator, exec: msg.Exec) !void {
        const alloc = self.alloc;
        const field: u32 = @backingInt(exec.case);
        const path = (try pb.findBytes(exec.args, 1)) orelse "";
        switch (exec.case) {
            .request_context => {
                var success = pb.Writer.init(scratch);
                try success.bytesField(1, self.request_context);
                var result = pb.Writer.init(scratch);
                try result.bytesField(1, success.bytes.items);
                try self.reply(try msg.execResult(alloc, exec.id, exec.exec_id, field, result.bytes.items));
            },
            .mcp => {
                const call = exec.mcp.?;
                if (call.approval_only) {
                    // proto-fx's own permission check runs when it executes.
                    try self.reply(try msg.execResult(alloc, exec.id, exec.exec_id, field, try msg.mcpApproved(scratch)));
                    return;
                }
                const tool = try self.toolFor("", call, "");
                try self.settleFrom(scratch, tool, call);
                try self.reply(try msg.execResult(alloc, exec.id, exec.exec_id, field, try msg.mcpTextResult(scratch, msg.handoff_message)));
            },
            // ReadResult, LsResult and DiagnosticsResult all reject in field 3.
            .read, .redacted_read, .ls, .diagnostics => try self.reply(try msg.execResult(alloc, exec.id, exec.exec_id, field, try msg.pathRejection(scratch, 3, path, msg.native_tool_refusal))),
            .write, .delete => try self.reply(try msg.execResult(alloc, exec.id, exec.exec_id, field, try msg.pathRejection(scratch, 6, path, msg.native_tool_refusal))),
            .grep => try self.reply(try msg.execResult(alloc, exec.id, exec.exec_id, field, try msg.textOneof(scratch, 2, msg.native_tool_refusal))),
            .fetch => try self.reply(try msg.execResult(alloc, exec.id, exec.exec_id, field, try msg.pathRejection(scratch, 2, path, msg.native_tool_refusal))),
            .shell, .background_shell_spawn, .shell_stream => {
                const command = (try pb.findBytes(exec.args, 1)) orelse "";
                const directory = (try pb.findBytes(exec.args, 2)) orelse "";
                const rejected = try msg.shellRejected(scratch, command, directory, msg.native_tool_refusal);
                var wrapped = pb.Writer.init(scratch);
                // ShellResult.rejected = 4, BackgroundShellSpawnResult.rejected = 3,
                // ShellStream.rejected = 5.
                try wrapped.bytesField(switch (exec.case) {
                    .shell => 4,
                    .background_shell_spawn => 3,
                    else => 5,
                }, rejected);
                try self.reply(try msg.execResult(alloc, exec.id, exec.exec_id, field, wrapped.bytes.items));
                if (exec.case == .shell_stream) try self.reply(try msg.execStreamClose(alloc, exec.id));
            },
            else => {
                try self.reply(try msg.execThrow(alloc, exec.id, "Not implemented by this client", "not_implemented"));
                try self.reply(try msg.execStreamClose(alloc, exec.id));
            },
        }
    }

    /// proto's `handleInteractionQuery`: Cursor's hosted search and fetch are
    /// approved, questions, mode switches and plans are refused, and an
    /// unknown query is approved through field 1 of its response.
    fn answerQuery(self: *Reducer, id: u64, field: u32) !void {
        const alloc = self.alloc;
        var response = pb.Writer.init(alloc);
        defer response.deinit();
        switch (field) {
            0, 8 => return,
            3 => {
                var rejected = pb.Writer.init(alloc);
                defer rejected.deinit();
                try rejected.bytesField(1, "Interactive questions are not implemented by this client");
                var result = pb.Writer.init(alloc);
                defer result.deinit();
                try result.bytesField(3, rejected.bytes.items);
                try response.bytesField(1, result.bytes.items);
            },
            4 => {
                var rejected = pb.Writer.init(alloc);
                defer rejected.deinit();
                try rejected.bytesField(1, "Mode switches are not implemented by this client");
                try response.bytesField(2, rejected.bytes.items);
            },
            7 => {
                var failure = pb.Writer.init(alloc);
                defer failure.deinit();
                try failure.bytesField(1, "Plan files are not implemented by this client");
                var result = pb.Writer.init(alloc);
                defer result.deinit();
                try result.bytesField(2, failure.bytes.items);
                try response.bytesField(1, result.bytes.items);
            },
            else => try response.emptyField(1),
        }
        try self.reply(try msg.interactionResponse(alloc, id, field, response.bytes.items));
    }

    /// The completion once the turn has ended.
    pub fn finish(self: *Reducer) !streams.Result {
        if (!self.turn_ended) return error.IncompleteStream;
        if (self.request.tool_choice == .required and self.tools.items.len == 0) return error.RequiredToolMissing;
        for (self.tools.items) |*tool| {
            if (std.mem.trim(u8, tool.arguments.items, " \t\r\n").len == 0) {
                tool.arguments.clearRetainingCapacity();
                try tool.arguments.appendSlice(self.alloc, "{}");
            }
            try chat.check_json_depth(tool.arguments.items);
        }
        const calls = try self.alloc.alloc(types.ToolCall, self.tools.items.len);
        errdefer self.alloc.free(calls);
        var moved: usize = 0;
        errdefer for (calls[0..moved]) |call| self.alloc.free(call.arguments_json);
        for (self.tools.items, calls) |*tool, *call| {
            call.* = .{ .id = tool.id, .name = tool.name, .arguments_json = try tool.arguments.toOwnedSlice(self.alloc) };
            moved += 1;
        }
        const content = if (self.content.items.len != 0) try self.content.toOwnedSlice(self.alloc) else null;
        for (self.tools.items) |*tool| {
            tool.id = &.{};
            tool.name = &.{};
        }
        const usage = self.usage;
        return .{ .completed = .{
            .completion = .{
                .content = content,
                .tool_calls = calls,
                .finish_reason = if (calls.len != 0) .tool_calls else .stop,
                .usage = .{
                    .input_tokens = usage.input,
                    .output_tokens = usage.output orelse if (self.estimated_output != 0) self.estimated_output else null,
                    .cache_read_tokens = usage.cache_read,
                    .cache_write_tokens = usage.cache_write,
                    .reasoning_tokens = usage.reasoning,
                },
            },
            .ownership = .owned,
        } };
    }
};
