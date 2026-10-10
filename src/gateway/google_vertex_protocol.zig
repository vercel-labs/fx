const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const sse = @import("sse.zig");
const configured_provider = @import("../core/config/configured_provider.zig");
const model_provider = @import("../core/config/model_provider.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    provider: ?*const configured_provider.Definition = null,
};

pub const Error = error{
    OutOfMemory,
    InvalidProviderPrompt,
    InvalidModel,
    UnsupportedProviderOption,
    UnsupportedVision,
    UnsupportedResponseFormat,
    UnsupportedReplay,
    InvalidProviderState,
    ReplayTooLarge,
    UnsupportedToolProvenance,
    InvalidOutputLimit,
    InvalidToolSelection,
    InvalidToolSchema,
    InvalidToolCallId,
    InvalidToolName,
    InvalidToolArguments,
    InvalidToolHistory,
    ImageUnavailable,
    RequiredToolMissing,
    UnexpectedToolCall,
    InvalidChunk,
    ConflictingIdentity,
    InvalidFinishReason,
    InconsistentFinishReason,
    IncompleteStream,
    StreamClosed,
    ProviderError,
    OutputTruncated,
    ContentFiltered,
    Refused,
    EventTooLarge,
    StreamTooLarge,
    TooManyEvents,
    TooManyTools,
    IdentityTooLarge,
    ArgumentsTooLarge,
    ContentTooLarge,
    JsonTooDeep,
    Cancelled,
    ReadFailed,
    WriteFailed,
};

pub const Limits = struct {
    event_bytes: usize = 16 * 1024 * 1024,
    total_wire_bytes: usize = 64 * 1024 * 1024,
    events: usize = 100_000,
    identity_bytes: usize = 256,
    content_bytes: usize = 16 * 1024 * 1024,
};

const max_selected_tools = 256;
const max_name_bytes = 128;
const max_history_arguments_bytes = 1024 * 1024;
const max_json_depth = 64;

const Function = struct {
    name: []const u8,
    description: []const u8,
    schema: union(enum) {
        builtin: model_tool_schema.ObjectSchema,
        dynamic: std.json.Value,
    },
};

fn validate_name(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_name_bytes) return error.InvalidToolName;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') return error.InvalidToolName;
}

fn append_function(alloc: Allocator, functions: *std.ArrayList(Function), function: Function) Error!void {
    try validate_name(function.name);
    if (functions.items.len == max_selected_tools) return error.TooManyTools;
    for (functions.items) |prior| if (std.mem.eql(u8, prior.name, function.name)) return error.InvalidToolSelection;
    try functions.append(alloc, function);
}

fn select_functions(alloc: Allocator, tools: stream_provider.ToolSelection, choice: types.ToolChoice) Error!std.ArrayList(Function) {
    if (choice == .none) return std.ArrayList(Function).initCapacity(alloc, 0);
    var functions: std.ArrayList(Function) = .empty;
    errdefer functions.deinit(alloc);

    for (tools.advertised_functions) |schema| {
        try append_function(alloc, &functions, .{
            .name = schema.name,
            .description = schema.description,
            .schema = .{ .builtin = schema.input_schema },
        });
    }

    for (tools.additional_functions) |schema| {
        try append_function(alloc, &functions, .{
            .name = schema.name,
            .description = schema.description,
            .schema = .{ .builtin = schema.input_schema },
        });
    }

    for (tools.selected_dynamic) |dynamic| {
        try append_function(alloc, &functions, .{
            .name = dynamic.name,
            .description = dynamic.description,
            .schema = .{ .dynamic = dynamic.input_schema },
        });
    }

    return functions;
}

pub fn build_request(alloc: Allocator, input: stream_provider.RequestData, options: Options) Error![]u8 {
    _ = options;
    if (input.model.len == 0) return error.InvalidModel;

    var functions = try select_functions(alloc, input.tools, input.tool_choice);
    defer functions.deinit(alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    write_vertex_request(&out.writer, alloc, input, functions.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProviderPrompt,
    };

    return out.toOwnedSlice();
}

fn write_vertex_request(
    writer: *std.Io.Writer,
    alloc: Allocator,
    request: stream_provider.RequestData,
    functions: []const Function,
) !void {
    try writer.writeAll("{");
    var wrote_field = false;

    // 1. systemInstruction
    if (request.instructions.len > 0) {
        try writer.writeAll("\"systemInstruction\":{\"parts\":[");
        for (request.instructions, 0..) |inst, idx| {
            if (idx > 0) try writer.writeByte(',');
            try writer.writeAll("{\"text\":");
            try std.json.Stringify.value(inst.content orelse "", .{}, writer);
            try writer.writeByte('}');
        }
        try writer.writeAll("]}");
        wrote_field = true;
    }

    // 2. contents
    if (wrote_field) try writer.writeByte(',');
    try writer.writeAll("\"contents\":[");
    var turn_count: usize = 0;
    var i: usize = 0;
    const messages = request.messages;

    while (i < messages.len) {
        const msg = messages[i];

        // Group contiguous tool messages into a single user message with functionResponse parts
        if (msg.role == .tool) {
            if (turn_count > 0) try writer.writeByte(',');
            turn_count += 1;
            try writer.writeAll("{\"role\":\"user\",\"parts\":[");
            var part_idx: usize = 0;
            while (i < messages.len and messages[i].role == .tool) : (i += 1) {
                const tool_msg = messages[i];
                if (part_idx > 0) try writer.writeByte(',');
                part_idx += 1;
                try writer.writeAll("{\"functionResponse\":{\"name\":");
                try std.json.Stringify.value(tool_msg.tool_name orelse "", .{}, writer);
                try writer.writeAll(",\"response\":{\"output\":");
                try std.json.Stringify.value(tool_msg.content orelse "", .{}, writer);
                try writer.writeAll("}}}");
            }
            try writer.writeAll("]}");
            continue;
        }

        if (turn_count > 0) try writer.writeByte(',');
        turn_count += 1;

        if (msg.role == .user) {
            try writer.writeAll("{\"role\":\"user\",\"parts\":[");
            var part_written = false;
            if (msg.content) |text| {
                if (text.len > 0) {
                    try writer.writeAll("{\"text\":");
                    try std.json.Stringify.value(text, .{}, writer);
                    try writer.writeByte('}');
                    part_written = true;
                }
            }
            for (msg.images) |img| {
                if (part_written) try writer.writeByte(',');
                var snapshot = image_attachments.loadVerifiedSnapshot(alloc, img, .{}) catch return error.ImageUnavailable;
                defer snapshot.deinit(alloc);
                try writer.writeAll("{\"inlineData\":{\"mimeType\":");
                try std.json.Stringify.value(snapshot.media_type, .{}, writer);
                try writer.writeAll(",\"data\":");
                const encoded_len = std.base64.standard.Encoder.calcSize(snapshot.bytes.len);
                const encoded = try alloc.alloc(u8, encoded_len);
                defer alloc.free(encoded);
                _ = std.base64.standard.Encoder.encode(encoded, snapshot.bytes);
                try std.json.Stringify.value(encoded, .{}, writer);
                try writer.writeAll("}}");
                part_written = true;
            }
            if (!part_written) {
                try writer.writeAll("{\"text\":\"\"}");
            }
            try writer.writeAll("]}");
        } else if (msg.role == .assistant) {
            try writer.writeAll("{\"role\":\"model\",\"parts\":[");
            var part_written = false;

            if (msg.content) |text| {
                if (text.len > 0) {
                    try writer.writeAll("{\"text\":");
                    try std.json.Stringify.value(text, .{}, writer);
                    try writer.writeByte('}');
                    part_written = true;
                }
            }

            for (msg.tool_calls) |call| {
                if (part_written) try writer.writeByte(',');
                part_written = true;
                try writer.writeAll("{\"functionCall\":{\"name\":");
                try std.json.Stringify.value(call.name, .{}, writer);
                try writer.writeAll(",\"args\":");
                const args_trimmed = std.mem.trim(u8, call.arguments_json, " \t\r\n");
                if (args_trimmed.len > 0 and args_trimmed[0] == '{') {
                    try writer.writeAll(args_trimmed);
                } else {
                    try writer.writeAll("{}");
                }
                try writer.writeByte('}');

                if (extract_thought_signature(alloc, msg.provider_replay, call.name)) |sig| {
                    defer alloc.free(sig);
                    try writer.writeAll(",\"thoughtSignature\":");
                    try std.json.Stringify.value(sig, .{}, writer);
                }
                try writer.writeByte('}');
            }

            if (!part_written) {
                try writer.writeAll("{\"text\":\"\"}");
            }
            try writer.writeAll("]}");
        }

        i += 1;
    }
    try writer.writeAll("]");

    // 3. tools
    if (functions.len > 0 and request.tool_choice != .none) {
        try writer.writeAll(",\"tools\":[{\"functionDeclarations\":[");
        for (functions, 0..) |func, idx| {
            if (idx > 0) try writer.writeByte(',');
            try writer.writeAll("{\"name\":");
            try std.json.Stringify.value(func.name, .{}, writer);
            try writer.writeAll(",\"description\":");
            try model_tool_schema.writeCappedDescriptionJsonString(alloc, writer, func.description);
            try writer.writeAll(",\"parameters\":");
            switch (func.schema) {
                .builtin => |s| try model_tool_schema.writeObjectSchema(alloc, writer, s),
                .dynamic => |val| try std.json.Stringify.value(val, .{}, writer),
            }
            try writer.writeByte('}');
        }
        try writer.writeAll("]}]");

        try writer.writeAll(",\"toolConfig\":{\"functionCallingConfig\":{\"mode\":");
        switch (request.tool_choice) {
            .auto => try writer.writeAll("\"AUTO\""),
            .required => try writer.writeAll("\"ANY\""),
            .none => try writer.writeAll("\"NONE\""),
        }
        try writer.writeAll("}}");
    }

    // 4. generationConfig
    const level: []const u8 = if (request.provider_options.reasoning) |effort| blk: {
        const l = effort.label();
        if (std.mem.eql(u8, l, "low")) break :blk "low";
        if (std.mem.eql(u8, l, "medium")) break :blk "medium";
        break :blk "high";
    } else "high";

    try writer.print(",\"generationConfig\":{{\"temperature\":0.0,\"thinkingConfig\":{{\"thinkingLevel\":\"{s}\"}}}}", .{level});
    try writer.writeByte('}');
}

fn extract_thought_signature(
    alloc: Allocator,
    replay: ?types.ProviderReplay,
    tool_name: []const u8,
) ?[]const u8 {
    const rep = replay orelse return null;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, rep.parts_json, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const vertex_sigs = parsed.value.object.get("vertex_signatures") orelse return null;
    if (vertex_sigs != .array) return null;

    for (vertex_sigs.array.items) |item| {
        if (item != .object) continue;
        const name_val = item.object.get("name") orelse continue;
        const sig_val = item.object.get("sig") orelse continue;
        if (name_val == .string and sig_val == .string) {
            if (std.mem.eql(u8, name_val.string, tool_name)) {
                return alloc.dupe(u8, sig_val.string) catch null;
            }
        }
    }
    return null;
}

pub fn project_replay(
    alloc: Allocator,
    replay: ?types.ProviderReplay,
    calls: []const types.ToolCall,
    text: bool,
    reasoning: bool,
) Allocator.Error!?types.ProviderReplay {
    _ = alloc;
    _ = calls;
    _ = text;
    _ = reasoning;
    if (replay) |rep| {
        return rep;
    }
    return null;
}

pub fn redact_error_detail(alloc: Allocator, raw: []const u8, credential: []const u8) Allocator.Error![]u8 {
    if (raw.len > 64 * 1024 or credential.len > 16 * 1024) return alloc.dupe(u8, "Provider error details exceeded the local limit");
    const detail = try alloc.dupe(u8, raw);
    errdefer alloc.free(detail);
    if (credential.len > 0) {
        var remaining = detail;
        while (std.mem.find(u8, remaining, credential)) |index| {
            @memset(remaining[index..][0..credential.len], '*');
            remaining = remaining[index + credential.len ..];
        }
    }
    return detail;
}

pub const Deltas = struct {
    content: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
};

pub const Reducer = struct {
    alloc: Allocator,
    limits: Limits,
    content: std.ArrayList(u8) = .empty,
    reasoning_delta: std.ArrayList(u8) = .empty,
    tools: std.ArrayList(types.ToolCall) = .empty,
    signatures: std.ArrayList(ToolSig) = .empty,
    usage: types.Usage = .{},
    finish_reason: ?types.ProviderFinishReason = null,
    phase: enum { receiving, finished, done, closed } = .receiving,
    tool_counter: usize = 0,

    const ToolSig = struct {
        name: []u8,
        sig: []u8,
    };

    pub fn init(alloc: Allocator, request: stream_provider.RequestData, limits: Limits) Error!Reducer {
        _ = request;
        return Reducer{
            .alloc = alloc,
            .limits = limits,
        };
    }

    pub fn deinit(self: *Reducer) void {
        self.content.deinit(self.alloc);
        self.reasoning_delta.deinit(self.alloc);
        for (self.tools.items) |*tool| {
            self.alloc.free(tool.id);
            self.alloc.free(tool.name);
            self.alloc.free(tool.arguments_json);
        }
        self.tools.deinit(self.alloc);
        for (self.signatures.items) |*ts| {
            self.alloc.free(ts.name);
            self.alloc.free(ts.sig);
        }
        self.signatures.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn accept(self: *Reducer, data: []const u8, cancelled: bool) Error!Deltas {
        if (cancelled) return error.Cancelled;
        if (self.phase == .closed or self.phase == .done) return error.StreamClosed;
        const trimmed = std.mem.trim(u8, data, " \t\r\n");
        if (trimmed.len == 0) return .{};

        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, trimmed, .{}) catch return error.InvalidChunk;
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidChunk;
        const root = parsed.value.object;

        if (root.get("error")) |_| return error.ProviderError;

        // Parse usageMetadata
        if (root.get("usageMetadata")) |u_val| {
            if (u_val == .object) {
                if (u_val.object.get("promptTokenCount")) |pt| {
                    if (pt == .integer) self.usage.input_tokens = @intCast(pt.integer);
                }
                if (u_val.object.get("candidatesTokenCount")) |ct| {
                    if (ct == .integer) self.usage.output_tokens = @intCast(ct.integer);
                }
            }
        }

        var deltas = Deltas{};

        const candidates = root.get("candidates") orelse return deltas;
        if (candidates != .array or candidates.array.items.len == 0) return deltas;
        const cand = candidates.array.items[0];
        if (cand != .object) return deltas;

        if (cand.object.get("finishReason")) |fr| {
            if (fr == .string) {
                if (std.mem.eql(u8, fr.string, "STOP")) {
                    self.finish_reason = if (self.tools.items.len > 0) .tool_calls else .stop;
                } else if (std.mem.eql(u8, fr.string, "MAX_TOKENS")) {
                    self.finish_reason = .length;
                } else if (std.mem.eql(u8, fr.string, "SAFETY") or std.mem.eql(u8, fr.string, "RECITATION")) {
                    return error.ContentFiltered;
                }
            }
        }

        const content_obj = cand.object.get("content") orelse return deltas;
        if (content_obj != .object) return deltas;
        const parts = content_obj.object.get("parts") orelse return deltas;
        if (parts != .array) return deltas;

        for (parts.array.items) |part| {
            if (part != .object) continue;

            // 1. Text or Thought
            if (part.object.get("text")) |t_val| {
                if (t_val == .string and t_val.string.len > 0) {
                    const is_thought = if (part.object.get("thought")) |th| (th == .bool and th.bool) else false;
                    if (is_thought) {
                        self.reasoning_delta.clearRetainingCapacity();
                        try self.reasoning_delta.appendSlice(self.alloc, t_val.string);
                        deltas.reasoning = self.reasoning_delta.items;
                    } else {
                        const start = self.content.items.len;
                        try self.content.appendSlice(self.alloc, t_val.string);
                        deltas.content = self.content.items[start..];
                    }
                }
            }

            // 2. Function Call
            if (part.object.get("functionCall")) |fc| {
                if (fc == .object) {
                    const fn_name = fc.object.get("name") orelse continue;
                    if (fn_name != .string) continue;

                    const args_val = fc.object.get("args") orelse std.json.Value{ .object = .empty };
                    const args_json = try std.json.Stringify.valueAlloc(self.alloc, args_val, .{});
                    defer self.alloc.free(args_json);

                    const id_str = if (fc.object.get("id")) |id_val|
                        (if (id_val == .string) try self.alloc.dupe(u8, id_val.string) else null)
                    else
                        null;
                    const final_id = id_str orelse try std.fmt.allocPrint(self.alloc, "call_{d}", .{self.tool_counter});
                    self.tool_counter += 1;

                    // Extract thoughtSignature
                    if (part.object.get("thoughtSignature")) |sig_val| {
                        if (sig_val == .string and sig_val.string.len > 0) {
                            try self.signatures.append(self.alloc, .{
                                .name = try self.alloc.dupe(u8, fn_name.string),
                                .sig = try self.alloc.dupe(u8, sig_val.string),
                            });
                        }
                    }

                    try self.tools.append(self.alloc, .{
                        .id = final_id,
                        .name = try self.alloc.dupe(u8, fn_name.string),
                        .arguments_json = try self.alloc.dupe(u8, args_json),
                        .provenance = .fx_local,
                        .final_identity = .valid,
                        .argument_integrity = .valid,
                    });
                }
            }
        }

        return deltas;
    }

    pub fn finish(self: *Reducer, cancelled: bool) Error!stream_provider.Result {
        if (cancelled) return error.Cancelled;
        self.phase = .done;

        // Build provider_state_json containing vertex_signatures
        var state_json: ?[]const u8 = null;
        if (self.signatures.items.len > 0) {
            var state_out: std.Io.Writer.Allocating = .init(self.alloc);
            defer state_out.deinit();
            try state_out.writer.writeAll("{\"vertex_signatures\":[");
            for (self.signatures.items, 0..) |ts, idx| {
                if (idx > 0) try state_out.writer.writeByte(',');
                try state_out.writer.writeAll("{\"name\":");
                try std.json.Stringify.value(ts.name, .{}, &state_out.writer);
                try state_out.writer.writeAll(",\"sig\":");
                try std.json.Stringify.value(ts.sig, .{}, &state_out.writer);
                try state_out.writer.writeByte('}');
            }
            try state_out.writer.writeAll("]}");
            state_json = try state_out.toOwnedSlice();
        }

        const effective_finish_reason: types.ProviderFinishReason = if (self.tools.items.len > 0)
            .tool_calls
        else
            (self.finish_reason orelse .stop);

        return .{
            .completed = .{
                .completion = .{
                    .content = if (self.content.items.len > 0) try self.alloc.dupe(u8, self.content.items) else null,
                    .tool_calls = try self.tools.toOwnedSlice(self.alloc),
                    .provider_state_json = state_json,
                    .finish_reason = effective_finish_reason,
                    .usage = self.usage,
                },
                .ownership = .owned,
            },
        };
    }
};

pub fn consume_stream(
    alloc: Allocator,
    source: *std.Io.Reader,
    request: stream_provider.RequestData,
    limits: Limits,
    events: ?stream_provider.EventSink,
    cancel_flag: *const std.atomic.Value(bool),
) Error!stream_provider.Result {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    var reducer = try Reducer.init(alloc, request, limits);
    defer reducer.deinit();

    var framing = sse.Reader{ .max_event_bytes = limits.event_bytes };
    defer framing.deinit(alloc);

    while (true) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        const data = framing.next(alloc, source, cancel_flag) catch |err| switch (err) {
            error.StreamTooLarge => return error.StreamTooLarge,
            else => return err,
        };
        const chunk = data orelse break; // EOF terminates Vertex stream
        const deltas = try reducer.accept(chunk, cancel_flag.load(.seq_cst));

        if (events) |sink| {
            if (deltas.reasoning) |thought| {
                if (cancel_flag.load(.seq_cst)) return error.Cancelled;
                sink.emit(.{ .reasoning_delta = thought });
            }
            if (deltas.content) |text| {
                if (cancel_flag.load(.seq_cst)) return error.Cancelled;
                sink.emit(.{ .content_delta = text });
            }
        }
    }

    return reducer.finish(cancel_flag.load(.seq_cst));
}

test "vertex protocol builds request with systemInstruction, tools, and contents" {
    const alloc = std.testing.allocator;
    const test_func = [_]model_tool_schema.FunctionSchema{
        .{
            .name = "read_file",
            .description = "Read a file",
            .input_schema = .{
                .properties = &.{.{ .name = "path", .json_type = .string }},
                .required = &.{"path"},
            },
        },
    };
    const req: stream_provider.RequestData = .{
        .model = "gemini-3.8-flash",
        .instructions = &.{.{ .role = .system, .content = "You are an assistant." }},
        .messages = &.{
            .{ .role = .user, .content = "Read main.zig" },
        },
        .tools = .{
            .advertised_functions = &test_func,
        },
        .tool_choice = .auto,
        .provider_options = .{},
    };
    const payload = try build_request(alloc, req, .{});
    defer alloc.free(payload);

    try std.testing.expect(std.mem.find(u8, payload, "\"systemInstruction\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"You are an assistant.\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"functionDeclarations\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"AUTO\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"Read main.zig\"") != null);
}

test "vertex protocol reducer parses text, thought, and functionCall with thoughtSignature" {
    const alloc = std.testing.allocator;
    const req: stream_provider.RequestData = .{
        .model = "gemini-3.8-flash",
        .messages = &.{},
        .tool_choice = .auto,
        .provider_options = .{},
    };
    var reducer = try Reducer.init(alloc, req, .{});
    defer reducer.deinit();

    // 1. Text chunk
    const chunk1 = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hello \"}]}}]}";
    const delta1 = try reducer.accept(chunk1, false);
    try std.testing.expectEqualStrings("Hello ", delta1.content.?);
    try std.testing.expect(delta1.reasoning == null);

    // 2. Thought chunk
    const chunk2 = "{\"candidates\":[{\"content\":{\"parts\":[{\"thought\":true,\"text\":\"Thinking...\"}]}}]}";
    const delta2 = try reducer.accept(chunk2, false);
    try std.testing.expectEqualStrings("Thinking...", delta2.reasoning.?);
    try std.testing.expect(delta2.content == null);

    // 3. Function call chunk with thoughtSignature
    const chunk3 = "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"read_file\",\"args\":{\"path\":\"main.zig\"}},\"thoughtSignature\":\"SIG_TEST_ABC\"}]}}],\"usageMetadata\":{\"promptTokenCount\":42,\"candidatesTokenCount\":15}}";
    const delta3 = try reducer.accept(chunk3, false);
    try std.testing.expect(delta3.content == null);
    try std.testing.expect(delta3.reasoning == null);

    // 4. Finish
    const result = try reducer.finish(false);
    defer {
        var res = result;
        res.deinit(alloc);
    }

    try std.testing.expectEqualStrings("Hello ", result.completed.completion.content.?);
    try std.testing.expectEqual(@as(usize, 1), result.completed.completion.tool_calls.len);
    try std.testing.expectEqualStrings("read_file", result.completed.completion.tool_calls[0].name);
    try std.testing.expectEqual(@as(u64, 42), result.completed.completion.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 15), result.completed.completion.usage.output_tokens);

    // Verify thoughtSignature saved in provider_state_json
    const state_json = result.completed.completion.provider_state_json.?;
    try std.testing.expect(std.mem.find(u8, state_json, "SIG_TEST_ABC") != null);

    // 5. Verify thoughtSignature replay in subsequent turn
    const replay: types.ProviderReplay = .{
        .source = .{ .provider = model_provider.parse("configured").?, .model = "gemini-3.8-flash" },
        .parts_json = state_json,
    };
    const next_req: stream_provider.RequestData = .{
        .model = "gemini-3.8-flash",
        .messages = &.{
            .{
                .role = .assistant,
                .content = "I will read the file.",
                .tool_calls = result.completed.completion.tool_calls,
                .provider_replay = replay,
            },
            .{
                .role = .tool,
                .tool_name = "read_file",
                .content = "const std = @import(\"std\");",
            },
        },
        .tool_choice = .auto,
        .provider_options = .{},
    };
    const next_payload = try build_request(alloc, next_req, .{});
    defer alloc.free(next_payload);

    try std.testing.expect(std.mem.find(u8, next_payload, "\"thoughtSignature\":\"SIG_TEST_ABC\"") != null);
    try std.testing.expect(std.mem.find(u8, next_payload, "\"functionResponse\"") != null);
    try std.testing.expect(std.mem.find(u8, next_payload, "\"const std = @import(\\\"std\\\");\"") != null);
}
