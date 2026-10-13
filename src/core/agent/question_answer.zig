const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

const EncodeError = Allocator.Error || std.Io.Writer.Error || error{
    AnswerCountMismatch,
};

/// Encodes ordered question entries and answers as an owned JSON result.
/// The caller owns the returned slice and must free it with `alloc`.
pub fn encodeJson(
    alloc: Allocator,
    entries: []const types.QuestionBatchEntry,
    answers: []const []const u8,
) EncodeError![]u8 {
    if (entries.len != answers.len) return error.AnswerCountMismatch;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("[");
    for (entries, 0..) |entry, index| {
        if (index > 0) try out.writer.writeAll(",");
        try out.writer.writeAll("{\"question\":");
        try std.json.Stringify.value(entry.question, .{}, &out.writer);
        try out.writer.writeAll(",\"answer\":");
        try std.json.Stringify.value(answers[index], .{}, &out.writer);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]");

    return out.toOwnedSlice();
}

/// Decodes a successful question result. Returned strings borrow from `output`
/// or allocations in `arena`; both must outlive the returned answers.
pub fn decodeJson(
    arena: Allocator,
    output: []const u8,
) Allocator.Error!?[]const types.QuestionAnswer {
    const root = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        output,
        .{},
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };

    if (root != .array) return null;
    const items = root.array.items;
    if (items.len < 1 or items.len > 4) return null;

    const answers = try arena.alloc(types.QuestionAnswer, items.len);
    for (items, 0..) |item, index| {
        if (item != .object) return null;
        const question = item.object.get("question") orelse return null;
        const answer = item.object.get("answer") orelse return null;
        if (question != .string or answer != .string) return null;
        answers[index] = .{
            .question = question.string,
            .answer = answer.string,
        };
    }

    return answers;
}

test "question answers preserve order and JSON escaping" {
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Which depth?", .options = &.{} },
        .{ .question = "Ship it?", .options = &.{} },
    };
    const answers = [_][]const u8{ "Thorough", "Yes\nnow" };

    const encoded = try encodeJson(std.testing.allocator, &entries, &answers);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings(
        "[{\"question\":\"Which depth?\",\"answer\":\"Thorough\"},{\"question\":\"Ship it?\",\"answer\":\"Yes\\nnow\"}]",
        encoded,
    );

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const decoded = (try decodeJson(arena_state.allocator(), encoded)).?;
    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqualStrings("Which depth?", decoded[0].question);
    try std.testing.expectEqualStrings("Thorough", decoded[0].answer);
    try std.testing.expectEqualStrings("Ship it?", decoded[1].question);
    try std.testing.expectEqualStrings("Yes\nnow", decoded[1].answer);
}

test "question answer decoding rejects non-result payloads" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect((try decodeJson(arena, "(user cancelled the question)")) == null);
    try std.testing.expect((try decodeJson(arena, "[]")) == null);
    try std.testing.expect((try decodeJson(arena, "[{\"question\":\"Q\"}]")) == null);
    try std.testing.expect((try decodeJson(arena, "[{\"question\":\"Q\",\"answer\":1}]")) == null);
    try std.testing.expect((try decodeJson(arena, "[{\"question\":\"Q\",\"answer\":\"A\"}] trailing")) == null);
}

test "question answer codec exposes structural and allocation failures" {
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Continue?", .options = &.{} },
    };
    try std.testing.expectError(
        error.AnswerCountMismatch,
        encodeJson(std.testing.allocator, &entries, &.{}),
    );

    var failing = std.testing.FailingAllocator.init(
        testing_allocator.no_resize,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        decodeJson(failing.allocator(), "[{\"question\":\"Q\",\"answer\":\"A\"}]"),
    );
}
