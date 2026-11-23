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

    fn deinit(self: *TailCapture) void {
        self.last_text.deinit(self.alloc);
    }

    fn sink(self: *TailCapture) SemanticPresentationSink {
        return .{
            .ctx = self,
            .table = unexpectedTable,
            .code_block = unexpectedCodeBlock,
            .thematic_rule = unexpectedRule,
            .assistant_tail = capture,
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

    try std.testing.expectEqual(@as(usize, 1), capture_state.calls);
    try std.testing.expect(std.mem.find(u8, capture_state.last_text.items, "bo") != null);
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
    try std.testing.expectEqual(settled + 1, capture_state.calls);
    try std.testing.expect(std.mem.find(u8, capture_state.last_text.items, "bo") != null);

    runtime_assistant_stream.onStreamContentChunk(&stream_ctx, "**\n");
    try std.testing.expectEqual(settled + 2, capture_state.calls);
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
    try std.testing.expectEqual(@as(usize, 1), capture_state.calls);

    try runtime_assistant_stream.finishAssistantTail(&stream_ctx);
    try std.testing.expectEqual(@as(usize, 2), capture_state.calls);
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
    try std.testing.expectEqual(@as(usize, 1), capture_state.calls);
    try std.testing.expect(capture_state.last_events > 0);

    try runtime_assistant_stream.flushAssistantStream(&stream_ctx);
    try std.testing.expectEqual(@as(usize, 0), capture_state.last_events);
}
