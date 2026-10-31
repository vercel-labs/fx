//! Differential tests for the frozen prefix (`frozen_prefix.zig`): a runtime
//! that resumes after it must prepare exactly what the same runtime prepares
//! when it renders every entry.

const std = @import("std");
const runtime_mod = @import("runtime.zig");
const transcript_store = @import("store.zig");
const source_preparation = @import("source_preparation.zig");
const frozen_prefix = @import("frozen_prefix.zig");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");
const types = @import("../../core/shared/types.zig");

const TranscriptRuntime = runtime_mod.TranscriptRuntime;
const Allocator = std.mem.Allocator;

fn testRuntime() TranscriptRuntime {
    return .{
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
        .owned_top_row = 1,
        .has_committed_frame = true,
    };
}

/// Prepares `runtime` with its frozen prefix, then again with an empty one,
/// which renders every entry, and expects both preparations and both plain
/// renders to match. Returns whether the first one resumed.
fn expectSameAsFull(alloc: Allocator, runtime: *TranscriptRuntime) !bool {
    const store = runtime.borrowedFrozenPrefix();
    const resumable = store.valid(
        .prepared,
        runtime.entries.items,
        &.{},
        runtime.layout.cols,
        runtime.command_output_render.styles,
        frozen_prefix.boundary(runtime.entries.items),
    ) != null or store.slots[@backingInt(frozen_prefix.Mode.prepared)] != null;
    var resumed = try source_preparation.prepareTranscriptSource(runtime, alloc, null);
    defer resumed.deinit(alloc);
    const plain = try transcript_store.renderPlainEntries(runtime, alloc, runtime.layout.cols);
    defer alloc.free(plain);

    var empty: frozen_prefix.FrozenPrefix = .{};
    defer empty.deinit();
    const previous = runtime.frozen_prefix_source;
    runtime.frozen_prefix_source = &empty;
    defer runtime.frozen_prefix_source = previous;
    var full = try source_preparation.prepareTranscriptSource(runtime, alloc, null);
    defer full.deinit(alloc);
    const plain_full = try transcript_blocks.renderEntriesToBytes(
        alloc,
        runtime.entries.items,
        runtime.layout.cols,
        runtime.command_output_render.styles,
    );
    defer alloc.free(plain_full);

    try std.testing.expectEqualDeep(full, resumed);
    try std.testing.expectEqualStrings(plain_full, plain);
    return resumable;
}

fn finishTurn(alloc: Allocator, runtime: *TranscriptRuntime, metrics: *types.Metrics, prompt: []const u8, answer: []const u8) !void {
    const text = try alloc.dupe(u8, prompt);
    defer alloc.free(text);
    _ = try runtime.writeUserPromptCard(alloc, metrics, .{ .text = text }, runtime.entries.items.len > 0, &.{});
    _ = try expectSameAsFull(alloc, runtime);
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "● Read notes.txt\n", .tool_status);
    _ = try expectSameAsFull(alloc, runtime);
    _ = try runtime.appendAssistantTurnEntry(alloc);
    _ = try runtime.streamAssistantChunk(alloc, metrics, answer);
    _ = try expectSameAsFull(alloc, runtime);
    _ = try runtime.appendTurnSummaryEntry(alloc, .{ .turn_duration_ms = 1200 });
    _ = try expectSameAsFull(alloc, runtime);
}

test "a runtime resuming after its frozen prefix prepares what a full render prepares" {
    const alloc = std.testing.allocator;
    var runtime = testRuntime();
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "fx v0 · Run /help for commands\n", .welcome);
    try finishTurn(alloc, &runtime, &metrics, "Read the notes", "Here is **a** summary of the notes.");
    const first_tool = runtime.entries.items[2].id();
    try finishTurn(alloc, &runtime, &metrics, "Run a command", "TURN_TWO_DONE with a line long enough to wrap at sixty columns.");
    try finishTurn(alloc, &runtime, &metrics, "Say the final words", "TURN_THREE_DONE");

    // The prefix covers the finished turns, and the next preparation resumes.
    const slot = runtime.frozen_prefix.slots[@backingInt(frozen_prefix.Mode.prepared)] orelse return error.NoPrefix;
    try std.testing.expectEqual(frozen_prefix.boundary(runtime.entries.items), slot.state.entry_count);
    try std.testing.expect(runtime.frozen_prefix.slots[@backingInt(frozen_prefix.Mode.plain)] != null);
    try std.testing.expect(runtime.frozen_prefix.lines(.prepared) != null);
    const hits = runtime.frozen_prefix.hits;
    _ = try expectSameAsFull(alloc, &runtime);
    // Both the prepared and the plain render resumed.
    try std.testing.expect(runtime.frozen_prefix.hits >= hits + 2);

    // A live turn after the prefix.
    const text = try alloc.dupe(u8, "Keep going");
    defer alloc.free(text);
    _ = try runtime.writeUserPromptCard(alloc, &metrics, .{ .text = text }, true, &.{});
    const notice = try runtime.appendReplaceableSemanticNotice(alloc, .{ .topic = "context", .tone = .neutral, .body = "Preparing compaction" });
    _ = try expectSameAsFull(alloc, &runtime);
    _ = try runtime.replaceSemanticNotice(alloc, notice, .{ .topic = "context", .tone = .success, .body = "Compacted" });
    _ = try expectSameAsFull(alloc, &runtime);

    // An entry inside the prefix changes in place: the prefix no longer
    // matches, and the preparation renders everything again.
    _ = try runtime.updateRawBytesEntry(alloc, first_tool, "● Read notes.txt (2 lines)\n");
    _ = try expectSameAsFull(alloc, &runtime);
    _ = try expectSameAsFull(alloc, &runtime);

    // A new width.
    runtime.layout.cols = 60;
    _ = try expectSameAsFull(alloc, &runtime);
    _ = try expectSameAsFull(alloc, &runtime);
    runtime.layout.cols = 80;
    _ = try expectSameAsFull(alloc, &runtime);
}

/// Drives `runtime` through up to 60 operations `draws` chooses and checks
/// every step against a full render.
fn driveRuntime(alloc: Allocator, draws: anytype) !void {
    var runtime = testRuntime();
    defer runtime.deinit(alloc);
    var metrics: types.Metrics = .{};
    var raw_ids: [64]u32 = undefined;
    var raw_count: usize = 0;
    var assistant_open = false;
    const steps = 1 + draws.below(60);
    for (0..steps) |step| {
        var line_buffer: [96]u8 = undefined;
        switch (draws.below(10)) {
            0 => {
                const text = try std.mem.print(&line_buffer, "Prompt number {d}", .{step});
                const owned = try alloc.dupe(u8, text);
                defer alloc.free(owned);
                _ = try runtime.writeUserPromptCard(alloc, &metrics, .{ .text = owned }, runtime.entries.items.len > 0, &.{});
                assistant_open = false;
            },
            1, 2 => {
                const text = try std.mem.print(&line_buffer, "● Read file{d}.txt\n", .{step});
                const id = try runtime.appendRawTranscriptEntryClassified(alloc, text, .tool_status);
                if (raw_count < raw_ids.len) {
                    raw_ids[raw_count] = id;
                    raw_count += 1;
                }
                assistant_open = false;
            },
            3, 4 => {
                if (!assistant_open) {
                    _ = try runtime.appendAssistantTurnEntry(alloc);
                    assistant_open = true;
                }
                const text = try std.mem.print(&line_buffer, "word{d} and **bold** text that runs on for a while ", .{step});
                _ = try runtime.streamAssistantChunk(alloc, &metrics, text);
            },
            5 => {
                _ = try runtime.appendTurnSummaryEntry(alloc, .{ .turn_duration_ms = step * 100 });
                assistant_open = false;
            },
            6 => if (raw_count > 0) {
                const text = try std.mem.print(&line_buffer, "● Edited file{d}.txt +{d}\n", .{ step, step });
                _ = try runtime.updateRawBytesEntry(alloc, raw_ids[draws.below(raw_count)], text);
            },
            7 => {
                _ = try runtime.appendSemanticNotice(alloc, .{ .topic = "version", .tone = .neutral, .body = "0.0.16" });
                assistant_open = false;
            },
            8 => runtime.layout.cols = @intCast(30 + draws.below(90)),
            else => {
                _ = try runtime.appendRawTranscriptEntryClassified(alloc, "hello\nworld\n", .command_output);
                assistant_open = false;
            },
        }
        _ = try expectSameAsFull(alloc, &runtime);
    }
}

const SeededDraws = struct {
    random: std.Random,

    fn below(self: SeededDraws, n: usize) usize {
        return self.random.uintLessThan(usize, n);
    }
};

const FuzzDraws = struct {
    smith: *std.testing.Smith,

    fn below(self: FuzzDraws, n: usize) usize {
        return self.smith.indexWithHash(n, 0x66726f7a);
    }
};

fn fuzzRuntime(_: void, smith: *std.testing.Smith) !void {
    try driveRuntime(std.testing.allocator, FuzzDraws{ .smith = smith });
}

/// A fuzz corpus entry: the draws `driveRuntime` reads, one little-endian u64
/// each, as the fuzzer's input format holds them.
fn corpusOf(comptime values: []const u64) []const u8 {
    comptime {
        var bytes: [values.len * 8]u8 = undefined;
        for (values, 0..) |value, index| std.mem.writeInt(u64, bytes[index * 8 ..][0..8], value, .little);
        const final = bytes;
        return &final;
    }
}

test "a runtime resuming after its frozen prefix matches a full render on arbitrary edits" {
    try std.testing.fuzz({}, fuzzRuntime, .{
        .corpus = &(.{
            // Two finished turns, a tool line in the first edited in place, a
            // new width, then a third turn with command output and a notice.
            comptime corpusOf(&.{ 16, 0, 1, 3, 3, 5, 0, 1, 6, 0, 5, 8, 40, 4, 5, 9, 1, 5, 7, 0 }),
        } ++ @import("fuzz_corpus").frozen_prefix.*),
    });
}

test "a runtime resuming after its frozen prefix matches a full render on seeded random edits" {
    var prng: std.Random.DefaultPrng = .init(20261030);
    for (0..150) |_| try driveRuntime(std.testing.allocator, SeededDraws{ .random = prng.random() });
}
