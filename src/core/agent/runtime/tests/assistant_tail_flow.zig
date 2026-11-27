const std = @import("std");
const assistant_presentation = @import("../../assistant_presentation.zig");
const runtime_assistant_stream = @import("../assistant_stream.zig");
const test_support = @import("support.zig");

const Event = assistant_presentation.Event;
const SemanticPresentationSink = runtime_assistant_stream.SemanticPresentationSink;
const StreamChunkContext = runtime_assistant_stream.StreamChunkContext;
const FakeAgentRuntimeDeps = test_support.FakeAgentRuntimeDeps;

const TailCapture = struct {
    alloc: std.mem.Allocator,
    calls: usize = 0,
    last_events: usize = 0,
    last_text: std.ArrayList(u8) = .empty,
    history: std.ArrayList([]u8) = .empty,

    fn deinit(self: *TailCapture) void {
        self.last_text.deinit(self.alloc);
        for (self.history.items) |entry| self.alloc.free(entry);
        self.history.deinit(self.alloc);
    }

    fn sink(self: *TailCapture) SemanticPresentationSink {
        return .{
            .ctx = self,
            .table = unexpectedTable,
            .code_block = unexpectedCodeBlock,
            .thematic_rule = unexpectedRule,
            .assistant_tail = capture,
            .paced_steps = true,
        };
    }

    fn capture(raw: *anyopaque, alloc: std.mem.Allocator, events: []Event) !void {
        const self: *TailCapture = @ptrCast(@alignCast(raw));
        defer assistant_presentation.freeEventSlice(alloc, events);
        self.calls += 1;
        self.last_events = events.len;
        self.last_text.clearRetainingCapacity();
        for (events) |event| switch (event) {
            .text => |text| try self.last_text.appendSlice(self.alloc, text),
            else => {},
        };
        try self.history.append(self.alloc, try self.alloc.dupe(u8, self.last_text.items));
    }

    fn unexpectedTable(_: *anyopaque, _: assistant_presentation.TablePayload) !void {
        @panic("tail test saw a committed table");
    }

    fn unexpectedCodeBlock(_: *anyopaque, _: assistant_presentation.CodeBlockPayload) !void {
        @panic("tail test saw a committed code block");
    }

    fn unexpectedRule(_: *anyopaque) !void {
        @panic("tail test saw a committed rule");
    }
};

test "the stream sends the open line as a tail and not as committed text" {
    const alloc = std.testing.allocator;
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var deps = hooks.deps();
    var capture_state = TailCapture{ .alloc = alloc };
    defer capture_state.deinit();
    var stream_ctx = StreamChunkContext{
        .hooks = &deps,
        .turn_id = 1,
        .alloc = alloc,
        .semantic_presentation = capture_state.sink(),
    };
    defer stream_ctx.deinit();

    runtime_assistant_stream.onStreamContentChunk(&stream_ctx, "Plain **bo");

    try std.testing.expectEqual(@as(usize, 0), hooks.texts.items.len);
    try std.testing.expectEqual(@as(usize, 2), capture_state.calls);
    try std.testing.expectEqualStrings("Plain ", capture_state.history.items[0]);
    try std.testing.expectEqualStrings("Plain \x1b[1mbo\x1b[22m", capture_state.history.items[1]);
    try std.testing.expect(std.mem.find(u8, capture_state.last_text.items, "**") == null);
}

test "the stream sends a tail only when it changes" {
    const alloc = std.testing.allocator;
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var deps = hooks.deps();
    var capture_state = TailCapture{ .alloc = alloc };
    defer capture_state.deinit();
    var stream_ctx = StreamChunkContext{
        .hooks = &deps,
        .turn_id = 1,
        .alloc = alloc,
        .semantic_presentation = capture_state.sink(),
    };
    defer stream_ctx.deinit();

    runtime_assistant_stream.onStreamContentChunk(&stream_ctx, "Done.\n");
    try runtime_assistant_stream.flushAssistantStream(&stream_ctx);
    const settled = capture_state.calls;
    try runtime_assistant_stream.flushAssistantStream(&stream_ctx);
    try std.testing.expectEqual(settled, capture_state.calls);

    runtime_assistant_stream.onStreamContentChunk(&stream_ctx, "Plain **bo");
    try std.testing.expectEqual(settled + 2, capture_state.calls);
    try std.testing.expectEqualStrings("Plain ", capture_state.history.items[settled]);
    try std.testing.expectEqualStrings("Plain \x1b[1mbo\x1b[22m", capture_state.history.items[settled + 1]);

    runtime_assistant_stream.onStreamContentChunk(&stream_ctx, "**\n");
    try std.testing.expectEqual(settled + 3, capture_state.calls);
    try std.testing.expectEqualStrings("Plain \x1b[1mbo\x1b[22m\n", capture_state.history.items[settled + 2]);

    try runtime_assistant_stream.flushAssistantStream(&stream_ctx);
    try std.testing.expectEqual(settled + 4, capture_state.calls);
    try std.testing.expectEqual(@as(usize, 0), capture_state.last_events);

    try runtime_assistant_stream.flushAssistantStream(&stream_ctx);
    try std.testing.expectEqual(settled + 4, capture_state.calls);
}

test "the stream ends with an empty tail" {
    const alloc = std.testing.allocator;
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var deps = hooks.deps();
    var capture_state = TailCapture{ .alloc = alloc };
    defer capture_state.deinit();
    var stream_ctx = StreamChunkContext{
        .hooks = &deps,
        .turn_id = 1,
        .alloc = alloc,
        .semantic_presentation = capture_state.sink(),
    };
    defer stream_ctx.deinit();

    runtime_assistant_stream.onStreamContentChunk(&stream_ctx, "Plain **bo");
    try std.testing.expectEqual(@as(usize, 2), capture_state.calls);
    try std.testing.expectEqualStrings("Plain ", capture_state.history.items[0]);
    try std.testing.expectEqualStrings("Plain \x1b[1mbo\x1b[22m", capture_state.history.items[1]);

    try runtime_assistant_stream.finishAssistantTail(&stream_ctx);
    try std.testing.expectEqual(@as(usize, 3), capture_state.calls);
    try std.testing.expectEqual(@as(usize, 0), capture_state.last_events);
}

test "a tool boundary flush sends an empty tail" {
    const alloc = std.testing.allocator;
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var deps = hooks.deps();
    var capture_state = TailCapture{ .alloc = alloc };
    defer capture_state.deinit();
    var stream_ctx = StreamChunkContext{
        .hooks = &deps,
        .turn_id = 1,
        .alloc = alloc,
        .semantic_presentation = capture_state.sink(),
    };
    defer stream_ctx.deinit();

    runtime_assistant_stream.onStreamContentChunk(&stream_ctx, "Plain **bo");
    try std.testing.expectEqual(@as(usize, 2), capture_state.calls);
    try std.testing.expectEqualStrings("Plain ", capture_state.history.items[0]);
    try std.testing.expectEqualStrings("Plain \x1b[1mbo\x1b[22m", capture_state.history.items[1]);
    try std.testing.expect(capture_state.last_events > 0);

    try runtime_assistant_stream.flushAssistantStream(&stream_ctx);
    try std.testing.expectEqual(@as(usize, 3), capture_state.calls);
    try std.testing.expectEqual(@as(usize, 0), capture_state.last_events);
}

test "a sink with no tail consumer gets no tail and builds no preview" {
    const alloc = std.testing.allocator;
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var deps = hooks.deps();
    var capture_state = TailCapture{ .alloc = alloc };
    defer capture_state.deinit();
    var consuming_ctx = StreamChunkContext{
        .hooks = &deps,
        .turn_id = 1,
        .alloc = alloc,
        .semantic_presentation = capture_state.sink(),
    };
    defer consuming_ctx.deinit();
    runtime_assistant_stream.onStreamContentChunk(&consuming_ctx, "Plain **bo");
    try std.testing.expectEqual(@as(usize, 2), consuming_ctx.tail_previews_built);

    var no_tail_owner: u8 = 0;
    var silent_ctx = StreamChunkContext{
        .hooks = &deps,
        .turn_id = 1,
        .alloc = alloc,
        .semantic_presentation = .{
            .ctx = &no_tail_owner,
            .table = TailCapture.unexpectedTable,
            .code_block = TailCapture.unexpectedCodeBlock,
            .thematic_rule = TailCapture.unexpectedRule,
            .assistant_tail = null,
        },
    };
    defer silent_ctx.deinit();
    runtime_assistant_stream.onStreamContentChunk(&silent_ctx, "Plain **bo");
    try runtime_assistant_stream.finishAssistantTail(&silent_ctx);
    try std.testing.expectEqual(@as(usize, 0), silent_ctx.tail_previews_built);
    try std.testing.expectEqual(@as(usize, 0), silent_ctx.sent_tail.items.len);
}
