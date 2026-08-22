//! Reproducible pure and VT workload for active-session file-diff approval review.
//!
//!     zig build run-bench-approval-review -Doptimize=ReleaseSafe -- combined 100 1

const std = @import("std");
const fx = @import("benchmark_exports");

const approval_prompt = fx.approval_prompt;
const approval_screen = fx.approval_screen;
const diff_mod = fx.diff;
const interaction_state = fx.interaction_state;
const transcript_blocks = fx.transcript_blocks;
const vt_emulator = fx.vt_emulator;

const Allocator = std.mem.Allocator;
const TranscriptRuntime = fx.TranscriptRuntime;
const TranscriptEntry = transcript_blocks.TranscriptEntry;
const seed: u64 = 0xF17ED1FF20260805;
const standard_cols: u16 = 120;
const standard_rows: u16 = 40;
const spaced_chrome_rows: usize = 11;
const compact_chrome_rows: usize = 8;
const separator_rows: usize = 2;
const max_runs: usize = 1_000;

const transcript_head = "FX_TRANSCRIPT_HEAD_SENTINEL";
const transcript_middle = "FX_TRANSCRIPT_MIDDLE_SENTINEL";
const transcript_tail = "FX_TRANSCRIPT_TAIL_SENTINEL";
const diff_head = "FX_DIFF_HEAD_SENTINEL";
const diff_middle = "FX_DIFF_MIDDLE_SENTINEL";
const diff_tail = "FX_DIFF_TAIL_SENTINEL";
const payload_head = "FX_LARGE_PAYLOAD_HEAD_SENTINEL";
const payload_tail = "FX_LARGE_PAYLOAD_TAIL_SENTINEL";

const Scenario = enum {
    transcript,
    diff,
    combined,
    payload,
    edge,

    fn parse(value: []const u8) !Scenario {
        inline for (std.meta.fields(Scenario)) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return error.InvalidScenario;
    }
};

const ScenarioConfig = struct {
    transcript_lines: usize,
    diff_lines: usize,
    small_result_records: usize,
    large_payloads: bool,
};

fn scenarioConfig(scenario: Scenario) ScenarioConfig {
    return switch (scenario) {
        .transcript => .{
            .transcript_lines = 50_000,
            .diff_lines = 24,
            .small_result_records = 512,
            .large_payloads = false,
        },
        .diff => .{
            .transcript_lines = 24,
            .diff_lines = 50_000,
            .small_result_records = 16,
            .large_payloads = false,
        },
        .combined => .{
            .transcript_lines = 50_000,
            .diff_lines = 50_000,
            .small_result_records = 512,
            .large_payloads = false,
        },
        .payload => .{
            .transcript_lines = 2_048,
            .diff_lines = 24,
            .small_result_records = 1_000,
            .large_payloads = true,
        },
        .edge => .{
            .transcript_lines = 3,
            .diff_lines = 3,
            .small_result_records = 0,
            .large_payloads = false,
        },
    };
}

const FixtureStats = struct {
    logical_lines: usize = 0,
    rendered_lines: usize = 0,
    record_count: usize = 0,
    total_bytes: usize = 0,
    largest_record: usize = 0,
    diff_bytes: usize = 0,
    tool_output_bytes: usize = 0,
    transcript_rows: usize = 0,
    review_rows: usize = 0,
    digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined,
};

const Fixture = struct {
    scenario: Scenario,
    runtime: TranscriptRuntime,
    after_text: []u8,
    review: diff_mod.FileReview,
    stats: FixtureStats,

    fn init(alloc: Allocator, scenario: Scenario) !Fixture {
        const config = scenarioConfig(scenario);
        var runtime = TranscriptRuntime{ .layout = layout(standard_cols, standard_rows) };
        errdefer runtime.deinit(alloc);

        var stats = FixtureStats{};
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        try generateTranscript(alloc, config, &runtime.entries, &stats, &hasher);

        const after_text = try generateDiff(alloc, config.diff_lines, &stats, &hasher);
        errdefer alloc.free(after_text);
        var review = try diff_mod.FileReview.init(alloc, "", after_text);
        errdefer review.deinit(alloc);

        var transcript = try runtime.prepareTranscriptSource(alloc, null);
        defer transcript.deinit(alloc);
        stats.transcript_rows = visualRowCount(transcript.bytes, standard_cols);
        stats.review_rows = review.rowCount();
        stats.rendered_lines = stats.transcript_rows + separator_rows +
            stats.review_rows + spaced_chrome_rows;
        stats.record_count = runtime.entries.items.len;
        stats.diff_bytes = after_text.len;
        stats.total_bytes += after_text.len;
        hasher.update("\x00DIFF\x00");
        hasher.update(after_text);
        hasher.final(&stats.digest);

        _ = visualRowForMarker(transcript.bytes, standard_cols, transcript_middle) orelse
            return error.MissingTranscriptMiddleSentinel;

        return .{
            .scenario = scenario,
            .runtime = runtime,
            .after_text = after_text,
            .review = review,
            .stats = stats,
        };
    }

    fn projection(self: *const Fixture) approval_prompt.Projection {
        return .{
            .request = fileRequest(),
            .choice_index = 0,
            .amendment_choice = null,
            .allow_draft = "",
            .allow_draft_cursor = 0,
            .deny_draft = "",
            .deny_draft_cursor = 0,
            .review = &self.review,
        };
    }

    fn deinit(self: *Fixture, alloc: Allocator) void {
        self.review.deinit(alloc);
        alloc.free(self.after_text);
        self.runtime.deinit(alloc);
        self.* = undefined;
    }
};

const raw_classes = [_]transcript_blocks.RawEntryClass{
    .welcome,
    .turn_summary,
    .tool_status,
    .command_output,
    .diff_block,
    .question_resolution,
    .subagent_status,
    .unknown_raw,
};

fn generateTranscript(
    alloc: Allocator,
    config: ScenarioConfig,
    entries: *std.ArrayList(TranscriptEntry),
    stats: *FixtureStats,
    hasher: *std.crypto.hash.sha2.Sha256,
) !void {
    const lines_per_record: usize = 32;
    var line_index: usize = 0;
    while (line_index < config.transcript_lines) {
        const record_index = entries.items.len;
        const record_end = @min(config.transcript_lines, line_index + lines_per_record);
        var record: std.Io.Writer.Allocating = .init(alloc);
        errdefer record.deinit();
        while (line_index < record_end) : (line_index += 1) {
            try writeTranscriptLine(
                &record.writer,
                line_index,
                config.transcript_lines,
            );
        }
        const bytes = try record.toOwnedSlice();
        errdefer alloc.free(bytes);
        const class = raw_classes[record_index % raw_classes.len];
        try entries.append(alloc, .{ .raw_bytes = .{
            .id = @intCast(record_index + 1),
            .created_at_ms = @intCast(record_index),
            .bytes = bytes,
            .class = class,
        } });
        hasher.update(bytes);
        hasher.update("\x00RECORD\x00");
        stats.total_bytes += bytes.len;
        stats.largest_record = @max(stats.largest_record, bytes.len);
        if (class == .command_output) stats.tool_output_bytes += bytes.len;
    }
    stats.logical_lines += config.transcript_lines;

    for (0..config.small_result_records) |result_index| {
        var record: std.Io.Writer.Allocating = .init(alloc);
        errdefer record.deinit();
        try record.writer.print(
            "tool streamed chunk {d:0>4}: start retry empty-output completion Ω界 e\xcc\x81\n",
            .{result_index},
        );
        const bytes = try record.toOwnedSlice();
        errdefer alloc.free(bytes);
        try entries.append(alloc, .{ .raw_bytes = .{
            .id = @intCast(entries.items.len + 1),
            .created_at_ms = @intCast(entries.items.len),
            .bytes = bytes,
            .class = .command_output,
        } });
        hasher.update(bytes);
        hasher.update("\x00STREAM\x00");
        stats.total_bytes += bytes.len;
        stats.tool_output_bytes += bytes.len;
        stats.largest_record = @max(stats.largest_record, bytes.len);
        stats.logical_lines += 1;
    }

    if (config.large_payloads) {
        try appendLargePayload(alloc, entries, stats, hasher, 3 * 1024 * 1024, 0);
        try appendLargePayload(alloc, entries, stats, hasher, 2 * 1024 * 1024, 1);
    }
}

fn writeTranscriptLine(
    writer: *std.Io.Writer,
    index: usize,
    line_count: usize,
) !void {
    const sentinel = if (index == 0)
        transcript_head
    else if (index == line_count / 2)
        transcript_middle
    else if (index + 1 == line_count)
        transcript_tail
    else
        "";
    if (index % 211 == 0 and index != 0) {
        try writer.writeByte('\n');
        return;
    }
    const kinds = [_][]const u8{
        "user",         "assistant",    "reasoning",  "context",    "approval",
        "cancellation", "interruption", "tool-start", "tool-chunk", "tool-completion",
        "tool-retry",   "tool-error",   "tool-empty", "file-write", "diff",
    };
    try writer.print(
        "{s} line={d:0>5} seed={x} {s} ASCII Ω界 e\xcc\x81 zwj=\xe2\x80\x8d ansi=\x1b[31mred\x1b[0m",
        .{ kinds[index % kinds.len], index + 1, seed, sentinel },
    );
    if (index % 257 == 0) {
        try writer.writeAll(" wrapped=");
        for (0..320) |_| try writer.writeByte('w');
    }
    try writer.writeByte('\n');
}

fn appendLargePayload(
    alloc: Allocator,
    entries: *std.ArrayList(TranscriptEntry),
    stats: *FixtureStats,
    hasher: *std.crypto.hash.sha2.Sha256,
    target_bytes: usize,
    payload_index: usize,
) !void {
    var record: std.Io.Writer.Allocating = .init(alloc);
    errdefer record.deinit();
    try record.writer.print("{s}-{d}\n", .{ payload_head, payload_index });
    const pattern = "streamed-tool-payload ASCII Ω界 combining=e\xcc\x81 zero=\xe2\x80\x8d chunk\n";
    while (record.written().len + pattern.len < target_bytes) {
        try record.writer.writeAll(pattern);
    }
    try record.writer.print("{s}-{d}\n", .{ payload_tail, payload_index });
    const bytes = try record.toOwnedSlice();
    errdefer alloc.free(bytes);
    try entries.append(alloc, .{ .raw_bytes = .{
        .id = @intCast(entries.items.len + 1),
        .created_at_ms = @intCast(entries.items.len),
        .bytes = bytes,
        .class = .command_output,
    } });
    hasher.update(bytes);
    hasher.update("\x00PAYLOAD\x00");
    stats.total_bytes += bytes.len;
    stats.tool_output_bytes += bytes.len;
    stats.largest_record = @max(stats.largest_record, bytes.len);
    stats.logical_lines += std.mem.count(u8, bytes, "\n");
}

fn generateDiff(
    alloc: Allocator,
    line_count: usize,
    stats: *FixtureStats,
    hasher: *std.crypto.hash.sha2.Sha256,
) ![]u8 {
    stats.logical_lines += line_count;
    _ = hasher;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (0..line_count) |index| {
        const sentinel = if (index == 0)
            diff_head
        else if (index == line_count / 2)
            diff_middle
        else if (index + 1 == line_count)
            diff_tail
        else
            "";
        const variants = [_][]const u8{
            "plain",
            "unicode-Ω界",
            "combining-e\xcc\x81",
            "zero-\xe2\x80\x8d",
            "ansi-\x1b[32mgreen\x1b[0m",
            "truncated-\x1b[38;5",
            "blank-next",
        };
        try out.writer.print(
            "diff-{d:0>5} {s} {s}\n",
            .{ index + 1, variants[index % variants.len], sentinel },
        );
    }
    return out.toOwnedSlice();
}

const preview_lines = [_]diff_mod.PreviewLine{.{
    .op = .addition,
    .new_line = 1,
    .text = "changed",
}};

fn fileRequest() fx.permission_request.PermissionRequest {
    return .{
        .id = 0xA990,
        .label = "write_file approval-review-profile.txt",
        .file = .{
            .kind = .edit,
            .intent = .mutation,
            .preview = .{
                .path = "approval-review-profile.txt",
                .lines = &preview_lines,
                .additions = 1,
                .deletions = 0,
                .truncated = false,
            },
            .scope = .workspace_files,
        },
    };
}

fn layout(cols: u16, rows: u16) fx.types.Layout {
    return .{
        .rows = rows,
        .cols = cols,
        .content_bottom = 1,
        .divider_top_row = 1,
        .input_row = 1,
        .divider_bottom_row = 1,
        .hint_row = 1,
    };
}

fn visualRowCount(bytes: []const u8, cols: u16) usize {
    var rows: usize = 0;
    var line_start: usize = 0;
    while (line_start < bytes.len) {
        const newline = std.mem.findScalar(u8, bytes[line_start..], '\n');
        const line_end = if (newline) |offset| line_start + offset else bytes.len;
        rows += transcript_blocks.visualRowsForLine(bytes[line_start..line_end], cols);
        if (newline == null) break;
        line_start = line_end + 1;
    }
    return rows;
}

fn visualRowForMarker(
    bytes: []const u8,
    cols: u16,
    marker: []const u8,
) ?usize {
    var rows: usize = 0;
    var line_start: usize = 0;
    while (line_start < bytes.len) {
        const newline = std.mem.findScalar(u8, bytes[line_start..], '\n');
        const line_end = if (newline) |offset| line_start + offset else bytes.len;
        const line = bytes[line_start..line_end];
        if (std.mem.find(u8, line, marker) != null) return rows;
        rows += transcript_blocks.visualRowsForLine(line, cols);
        if (newline == null) break;
        line_start = line_end + 1;
    }
    return null;
}

fn scrollToDocumentRow(
    state: *interaction_state.ApprovalScreenState,
    document_rows: usize,
    visible_rows: u16,
    target_row: usize,
) void {
    const tail_start = document_rows -| @as(usize, visible_rows);
    state.document_scroll_rows = tail_start -| target_row;
}

const DocumentTarget = enum {
    tail,
    transcript_head,
    transcript_middle,
    diff_head,
    diff_middle,
};

fn setDocumentTarget(
    fixture: *const Fixture,
    state: *interaction_state.ApprovalScreenState,
    transcript: []const u8,
    active_layout: fx.types.Layout,
    target: DocumentTarget,
) !void {
    if (target == .tail) {
        state.document_scroll_rows = 0;
        return;
    }

    const transcript_rows = visualRowCount(transcript, active_layout.cols);
    const review_rows = fixture.review.rowCount();
    const review_start = transcript_rows + if (transcript_rows > 0 and review_rows > 0)
        separator_rows
    else
        0;
    const chrome_rows = if (active_layout.rows >= 15)
        spaced_chrome_rows
    else
        compact_chrome_rows;
    const document_rows = review_start + review_rows + chrome_rows;
    const target_row = switch (target) {
        .tail => unreachable,
        .transcript_head => visualRowForMarker(
            transcript,
            active_layout.cols,
            transcript_head,
        ) orelse return error.MissingTranscriptHeadSentinel,
        .transcript_middle => visualRowForMarker(
            transcript,
            active_layout.cols,
            transcript_middle,
        ) orelse return error.MissingTranscriptMiddleSentinel,
        .diff_head => review_start,
        .diff_middle => review_start + scenarioConfig(fixture.scenario).diff_lines / 2,
    };
    scrollToDocumentRow(state, document_rows, active_layout.rows, target_row);
}

const PhaseResult = struct {
    paint_ns: u64,
    vt_ns: u64,
    terminal_bytes: usize,
    csi_sequences: usize,
};

fn runPhase(
    io: std.Io,
    alloc: Allocator,
    fixture: *Fixture,
    state: *interaction_state.ApprovalScreenState,
    active_layout: fx.types.Layout,
    clear_display: bool,
    target: DocumentTarget,
    expected_marker: ?[]const u8,
    require_ready: bool,
) !PhaseResult {
    const paint_started = std.Io.Timestamp.now(io, .awake).nanoseconds;
    fixture.runtime.layout = active_layout;
    var transcript_source: ?fx.TranscriptPreparationSource = null;
    defer if (transcript_source) |*source| source.deinit(alloc);
    const transcript_document: approval_screen.TranscriptDocument = switch (try approval_screen.transcriptDocumentPlan(
        fixture.projection(),
        state,
        fixture.runtime.entries.items,
        active_layout,
    )) {
        .none => .none,
        .progressive => |present| .{ .progressive = present },
        .projected => blk: {
            transcript_source = try fixture.runtime.prepareTranscriptSource(alloc, null);
            try setDocumentTarget(fixture, state, transcript_source.?.bytes, active_layout, target);
            break :blk .{ .projected = transcript_source.?.bytes };
        },
    };
    var painted = try approval_screen.paint(
        alloc,
        fixture.projection(),
        state,
        transcript_document,
        active_layout,
        clear_display,
    );
    const paint_ns: u64 = @intCast(
        std.Io.Timestamp.now(io, .awake).nanoseconds - paint_started,
    );
    defer painted.deinit(alloc);

    if (require_ready) {
        if (!painted.file_identity_visible or
            !painted.all_decision_controls_visible or
            !painted.changed_or_notice_visible)
        {
            return error.ApprovalFrameNotReady;
        }
    }

    const vt_started = std.Io.Timestamp.now(io, .awake).nanoseconds;
    var grid = try vt_emulator.Grid.init(alloc, active_layout.cols, active_layout.rows);
    defer grid.deinit();
    try grid.feed(painted.bytes);
    var snapshot: std.ArrayList(u8) = .empty;
    defer snapshot.deinit(alloc);
    try grid.snapshot(&snapshot);
    const vt_ns: u64 = @intCast(
        std.Io.Timestamp.now(io, .awake).nanoseconds - vt_started,
    );

    if (expected_marker) |marker| {
        if (std.mem.find(u8, snapshot.items, marker) == null) {
            return error.FinalBoundarySentinelMissing;
        }
    }

    return .{
        .paint_ns = paint_ns,
        .vt_ns = vt_ns,
        .terminal_bytes = painted.bytes.len,
        .csi_sequences = std.mem.count(u8, painted.bytes, "\x1b["),
    };
}

fn emitPhase(
    writer: *std.Io.Writer,
    scenario: Scenario,
    run_index: usize,
    phase: []const u8,
    result: PhaseResult,
) !void {
    try writer.print(
        "{{\"kind\":\"sample\",\"scenario\":\"{s}\",\"run\":{d}," ++
            "\"phase\":\"{s}\",\"paint_ns\":{d},\"vt_ns\":{d}," ++
            "\"terminal_bytes\":{d},\"csi_sequences\":{d}}}\n",
        .{
            @tagName(scenario),
            run_index,
            phase,
            result.paint_ns,
            result.vt_ns,
            result.terminal_bytes,
            result.csi_sequences,
        },
    );
}

fn runCycle(
    io: std.Io,
    alloc: Allocator,
    writer: ?*std.Io.Writer,
    fixture: *Fixture,
    run_index: usize,
    verify: bool,
) !void {
    var state = interaction_state.ApprovalScreenState{};
    var result = try runPhase(
        io,
        alloc,
        fixture,
        &state,
        layout(standard_cols, standard_rows),
        true,
        .tail,
        if (verify) diff_tail else null,
        true,
    );
    if (writer) |out| try emitPhase(out, fixture.scenario, run_index, "cold_tail_ready", result);

    result = try runPhase(
        io,
        alloc,
        fixture,
        &state,
        layout(standard_cols, standard_rows),
        false,
        .transcript_head,
        if (verify) transcript_head else null,
        false,
    );
    if (writer) |out| try emitPhase(out, fixture.scenario, run_index, "navigate_transcript_head", result);

    result = try runPhase(
        io,
        alloc,
        fixture,
        &state,
        layout(standard_cols, standard_rows),
        false,
        .transcript_middle,
        if (verify) transcript_middle else null,
        false,
    );
    if (writer) |out| try emitPhase(out, fixture.scenario, run_index, "navigate_transcript_middle", result);

    result = try runPhase(
        io,
        alloc,
        fixture,
        &state,
        layout(standard_cols, standard_rows),
        false,
        .diff_head,
        if (verify) diff_head else null,
        false,
    );
    if (writer) |out| try emitPhase(out, fixture.scenario, run_index, "navigate_diff_head", result);

    result = try runPhase(
        io,
        alloc,
        fixture,
        &state,
        layout(standard_cols, standard_rows),
        false,
        .diff_middle,
        if (verify) diff_middle else null,
        false,
    );
    if (writer) |out| try emitPhase(out, fixture.scenario, run_index, "navigate_diff_middle", result);

    state.document_scroll_rows = 0;
    result = try runPhase(
        io,
        alloc,
        fixture,
        &state,
        layout(48, 12),
        false,
        .tail,
        null,
        false,
    );
    if (writer) |out| try emitPhase(out, fixture.scenario, run_index, "resize_narrow", result);

    state.document_scroll_rows = 0;
    result = try runPhase(
        io,
        alloc,
        fixture,
        &state,
        layout(180, 50),
        false,
        .tail,
        if (verify) diff_tail else null,
        true,
    );
    if (writer) |out| try emitPhase(out, fixture.scenario, run_index, "resize_wide_warm", result);
}

fn emitFixture(writer: *std.Io.Writer, fixture: Fixture, runs: usize) !void {
    const digest_hex = std.fmt.bytesToHex(fixture.stats.digest, .lower);
    try writer.print(
        "{{\"kind\":\"fixture\",\"scenario\":\"{s}\",\"seed\":\"0x{x}\"," ++
            "\"logical_lines\":{d},\"rendered_lines\":{d},\"record_count\":{d}," ++
            "\"total_bytes\":{d},\"largest_record\":{d},\"diff_bytes\":{d}," ++
            "\"tool_output_bytes\":{d},\"transcript_rows\":{d}," ++
            "\"review_rows\":{d},\"operation_count\":{d},\"fixture_sha256\":\"{s}\"}}\n",
        .{
            @tagName(fixture.scenario),
            seed,
            fixture.stats.logical_lines,
            fixture.stats.rendered_lines,
            fixture.stats.record_count,
            fixture.stats.total_bytes,
            fixture.stats.largest_record,
            fixture.stats.diff_bytes,
            fixture.stats.tool_output_bytes,
            fixture.stats.transcript_rows,
            fixture.stats.review_rows,
            runs * 7,
            digest_hex[0..],
        },
    );
}

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const scenario = if (args.len >= 2)
        try Scenario.parse(std.mem.sliceTo(args[1], 0))
    else
        .edge;
    const runs = if (args.len >= 3)
        try std.fmt.parseInt(usize, std.mem.sliceTo(args[2], 0), 10)
    else
        1;
    const warmups = if (args.len >= 4)
        try std.fmt.parseInt(usize, std.mem.sliceTo(args[3], 0), 10)
    else
        1;
    if (runs == 0 or runs > max_runs or warmups > max_runs) {
        return error.InvalidRunCount;
    }

    var fixture = try Fixture.init(alloc, scenario);
    defer fixture.deinit(alloc);

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout.interface;
    try emitFixture(out, fixture, runs);
    try out.flush();

    for (0..warmups) |warmup| {
        try runCycle(init.io, alloc, null, &fixture, warmup, warmup == 0);
    }
    for (0..runs) |run_index| {
        try runCycle(
            init.io,
            alloc,
            out,
            &fixture,
            run_index,
            warmups == 0 and run_index == 0,
        );
        try out.flush();
    }
}

test "scenario ladder preserves requested independent scale minima" {
    const transcript_config = scenarioConfig(.transcript);
    try std.testing.expect(transcript_config.transcript_lines >= 50_000);
    try std.testing.expect(transcript_config.diff_lines < 50_000);

    const diff_config = scenarioConfig(.diff);
    try std.testing.expect(diff_config.diff_lines >= 50_000);
    try std.testing.expect(diff_config.transcript_lines < 50_000);

    const combined_config = scenarioConfig(.combined);
    try std.testing.expect(combined_config.transcript_lines >= 50_000);
    try std.testing.expect(combined_config.diff_lines >= 50_000);

    const payload_config = scenarioConfig(.payload);
    try std.testing.expect(payload_config.large_payloads);
    try std.testing.expect(payload_config.small_result_records >= 1_000);
}

test "edge fixture reaches transcript and diff sentinels through the final VT grid" {
    var fixture = try Fixture.init(std.testing.allocator, .edge);
    defer fixture.deinit(std.testing.allocator);
    try runCycle(
        std.testing.io,
        std.testing.allocator,
        null,
        &fixture,
        0,
        true,
    );
}
