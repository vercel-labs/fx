const std = @import("std");
const TranscriptRuntime = @import("benchmark_exports").TranscriptRuntime;

const Kind = enum { baseline, candidate };
const call_ids = [_][]const u8{ "first", "second" };
const samples_per_batch = 100;
const comparison_batches = 9;
const growth_batches = 5;
const ratio_scale = 1_000;
const max_ratio = 2 * ratio_scale;
const Harness = struct {
    transcript: TranscriptRuntime = .{ .max_retained_transcript_bytes = 256 },
    kind: Kind,
    entry_ids: [call_ids.len]u32 = undefined,

    fn init(alloc: std.mem.Allocator, kind: Kind) !Harness {
        var self = Harness{ .kind = kind };
        errdefer self.transcript.deinit(alloc);
        _ = try self.transcript.appendSemanticNotice(alloc, .{
            .topic = "system",
            .tone = .information,
            .body = "unrelated output retained near the configured transcript cap",
        });
        for (call_ids, 0..) |call_id, index| switch (kind) {
            .baseline => self.entry_ids[index] =
                try self.transcript.appendRawTranscriptEntryClassified(
                    alloc,
                    "● read_file\n",
                    .tool_status,
                ),
            .candidate => _ = try self.transcript.applyToolLifecycle(
                alloc,
                .{ .authoritative_started = .{
                    .id = .{ .turn_id = 1, .call_id = call_id },
                    .reconciles_provisional_call_id = null,
                    .tool_name = "read_file",
                    .activity_kind = .read,
                } },
            ),
        };
        return self;
    }

    fn update(self: *Harness, alloc: std.mem.Allocator, index: usize) !void {
        const slot = index % call_ids.len;
        switch (self.kind) {
            .baseline => {
                if (!try self.transcript.updateRawBytesEntry(
                    alloc,
                    self.entry_ids[slot],
                    "● Reading progress\n",
                )) return error.MissingBaselineTranscriptEntry;
            },
            .candidate => _ = try self.transcript.applyToolLifecycle(
                alloc,
                .{ .progress = .{
                    .id = .{ .turn_id = 1, .call_id = call_ids[slot] },
                    .text = "● Reading progress",
                } },
            ),
        }
    }
};
fn runUpdates(harness: *Harness, alloc: std.mem.Allocator, count: usize) !void {
    for (0..count) |index| try harness.update(alloc, index);
}

/// Times one update with the monotonic clock. Tests pass their own clock.
const Clock = struct {
    io: std.Io,

    fn time(self: Clock, harness: *Harness, alloc: std.mem.Allocator, index: usize) !u64 {
        const started = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        try harness.update(alloc, index);
        return @intCast(std.Io.Timestamp.now(self.io, .awake).nanoseconds - started);
    }
};

fn p95(samples: []u64) u64 {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return samples[94];
}

fn measureP95(clock: anytype, harness: *Harness, alloc: std.mem.Allocator) !u64 {
    var samples: [samples_per_batch]u64 = undefined;
    for (&samples, 0..) |*sample, index| sample.* = try clock.time(harness, alloc, index);
    return p95(&samples);
}

/// Times updates on both harnesses in alternation within one window, so a
/// slowdown during the window, such as a move to a slower CPU core, affects
/// both sets of samples alike.
fn measurePairedP95(
    clock: anytype,
    first: *Harness,
    second: *Harness,
    alloc: std.mem.Allocator,
) ![2]u64 {
    var first_samples: [samples_per_batch]u64 = undefined;
    var second_samples: [samples_per_batch]u64 = undefined;
    for (&first_samples, &second_samples, 0..) |*first_sample, *second_sample, index| {
        if (index % 2 == 0) {
            first_sample.* = try clock.time(first, alloc, index);
            second_sample.* = try clock.time(second, alloc, index);
        } else {
            second_sample.* = try clock.time(second, alloc, index);
            first_sample.* = try clock.time(first, alloc, index);
        }
    }
    return .{ p95(&first_samples), p95(&second_samples) };
}

fn ratio(numerator: u64, denominator: u64) u64 {
    if (denominator == 0) return std.math.maxInt(u64);
    return @intCast(@min(
        @as(u128, numerator) * ratio_scale / denominator,
        std.math.maxInt(u64),
    ));
}
fn comparisonRatio(io: std.Io, alloc: std.mem.Allocator, reverse: bool) !u64 {
    var baseline = try Harness.init(alloc, .baseline);
    defer baseline.transcript.deinit(alloc);
    var candidate = try Harness.init(alloc, .candidate);
    defer candidate.transcript.deinit(alloc);
    try runUpdates(&baseline, alloc, 200);
    try runUpdates(&candidate, alloc, 200);

    var baseline_p95: u64 = undefined;
    var candidate_p95: u64 = undefined;
    const clock: Clock = .{ .io = io };
    if (reverse) {
        candidate_p95 = try measureP95(clock, &candidate, alloc);
        baseline_p95 = try measureP95(clock, &baseline, alloc);
    } else {
        baseline_p95 = try measureP95(clock, &baseline, alloc);
        candidate_p95 = try measureP95(clock, &candidate, alloc);
    }
    return ratio(candidate_p95, baseline_p95);
}
/// Measures a fresh fixture and one with 5,000 more updates of history in
/// the same window, so the ratio reflects the history and not a change in
/// CPU speed between two separate windows.
fn measure_growth(io: std.Io, alloc: std.mem.Allocator) !GrowthObservation {
    var fresh = try Harness.init(alloc, .candidate);
    defer fresh.transcript.deinit(alloc);
    var grown = try Harness.init(alloc, .candidate);
    defer grown.transcript.deinit(alloc);
    try runUpdates(&fresh, alloc, 200);
    try runUpdates(&grown, alloc, 5_200);
    const initial, const final = try measurePairedP95(Clock{ .io = io }, &fresh, &grown, alloc);
    return GrowthObservation.capture(&grown, initial, final);
}

const Gate = struct {
    median: u64,
    breaches: usize,
    passed: bool,
};

const GrowthObservation = struct {
    initial_p95_ns: u64,
    final_p95_ns: u64,
    entries: usize = 0,
    records: usize = 0,
    active: usize = 0,
    pins: usize = 0,
    details: usize = 0,
    retained_bytes: usize = 0,

    fn capture(harness: *const Harness, initial: u64, final: u64) GrowthObservation {
        const transcript = &harness.transcript;
        return .{
            .initial_p95_ns = initial,
            .final_p95_ns = final,
            .entries = transcript.entries.items.len,
            .records = transcript.toolActivityRecordCount(),
            .active = transcript.activeToolActivityCount(),
            .pins = transcript.lifecyclePinCount(),
            .details = transcript.tool_details.items.len,
            .retained_bytes = transcript.retainedStructuredBytesForCommandOutput(),
        };
    }

    fn factor(self: GrowthObservation) u64 {
        return ratio(self.final_p95_ns, self.initial_p95_ns);
    }

    fn valid_work(self: GrowthObservation) bool {
        return self.entries == 3 and self.records == 2 and self.active == 2 and
            self.pins == 2 and self.details == 2 and self.retained_bytes == 108;
    }

    fn write(self: *const GrowthObservation, writer: *std.Io.Writer, batch: usize) std.Io.Writer.Error!void {
        try writer.print(
            "growth_batch={d} initial_p95_ns={d} final_p95_ns={d} " ++
                "entries={d} records={d} active={d} pins={d} details={d} retained_bytes={d}\n",
            .{
                batch,
                self.initial_p95_ns,
                self.final_p95_ns,
                self.entries,
                self.records,
                self.active,
                self.pins,
                self.details,
                self.retained_bytes,
            },
        );
    }
};
fn evaluate(ratios: []u64, breach_quorum: usize) Gate {
    var breaches: usize = 0;
    for (ratios) |value| if (value > max_ratio) {
        breaches += 1;
    };
    std.mem.sort(u64, ratios, {}, std.sort.asc(u64));
    const midpoint = ratios[ratios.len / 2];
    return .{
        .median = midpoint,
        .breaches = breaches,
        .passed = midpoint <= max_ratio or breaches < breach_quorum,
    };
}
pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.c_allocator;
    var comparison_ratios: [comparison_batches]u64 = undefined;
    for (&comparison_ratios, 0..) |*value, index| {
        value.* = try comparisonRatio(init.io, alloc, index % 2 == 1);
    }
    var growth_ratios: [growth_batches]u64 = undefined;
    var growth_observations: [growth_batches]GrowthObservation = undefined;
    var valid_work = true;
    for (&growth_ratios, &growth_observations) |*value, *observation| {
        observation.* = try measure_growth(init.io, alloc);
        value.* = observation.factor();
        valid_work = valid_work and observation.valid_work();
    }
    const comparison = evaluate(&comparison_ratios, 5);
    const growth = evaluate(&growth_ratios, 3);

    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.print(
        "comparison_median_ratio={d}.{d:0>3}x breaches={d}/{d} passed={any}\n" ++
            "growth_median_ratio={d}.{d:0>3}x breaches={d}/{d} passed={any}\n",
        .{
            comparison.median / ratio_scale,
            comparison.median % ratio_scale,
            comparison.breaches,
            comparison_batches,
            comparison.passed,
            growth.median / ratio_scale,
            growth.median % ratio_scale,
            growth.breaches,
            growth_batches,
            growth.passed,
        },
    );
    if (!comparison.passed or !growth.passed or !valid_work) {
        for (&growth_observations, 1..) |*observation, batch| {
            try observation.write(&writer.interface, batch);
        }
    }
    try writer.interface.flush();
    if (!valid_work) return error.UiActivityFixtureChanged;
    if (!comparison.passed or !growth.passed) return error.UiActivityProgressRegression;
}

test "benchmark gate handles isolated and repeated timing breaches" {
    var isolated = [_]u64{ 1_000, 1_100, 2_500, 1_050, 1_000 };
    var repeated = [_]u64{ 2_100, 2_200, 1_900, 2_300, 2_400 };
    try std.testing.expect(evaluate(&isolated, 3).passed);
    try std.testing.expect(!evaluate(&repeated, 3).passed);
}

test "growth observation checks the warmed activity fixture" {
    const alloc = std.testing.allocator;
    var harness = try Harness.init(alloc, .candidate);
    defer harness.transcript.deinit(alloc);
    try runUpdates(&harness, alloc, 5_400);
    const observed = GrowthObservation.capture(&harness, 500, 1_500);
    try std.testing.expect(observed.valid_work());
    try std.testing.expectEqual(@as(u64, 3_000), observed.factor());

    _ = try harness.transcript.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = .{ .turn_id = 1, .call_id = "unexpected" },
        .reconciles_provisional_call_id = null,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    try std.testing.expect(!GrowthObservation.capture(&harness, 500, 1_500).valid_work());
}

test "paired growth measurement cancels a slowdown during the window" {
    const SlowingClock = struct {
        calls: usize = 0,

        fn time(self: *@This(), harness: *Harness, alloc: std.mem.Allocator, index: usize) !u64 {
            try harness.update(alloc, index);
            self.calls += 1;
            // The machine runs 2.5 times slower for the second half of the window.
            return if (self.calls > samples_per_batch) 2_500 else 1_000;
        }
    };
    const alloc = std.testing.allocator;
    var fresh = try Harness.init(alloc, .candidate);
    defer fresh.transcript.deinit(alloc);
    var grown = try Harness.init(alloc, .candidate);
    defer grown.transcript.deinit(alloc);
    try runUpdates(&grown, alloc, 5_000);

    var clock: SlowingClock = .{};
    const initial, const final = try measurePairedP95(&clock, &fresh, &grown, alloc);
    try std.testing.expectEqual(@as(usize, 2 * samples_per_batch), clock.calls);
    try std.testing.expectEqual(@as(u64, ratio_scale), ratio(final, initial));
}

test "evaluating growth ratios preserves original timing evidence" {
    const observations = [_]GrowthObservation{
        .{ .initial_p95_ns = 100, .final_p95_ns = 300 },
        .{ .initial_p95_ns = 200, .final_p95_ns = 200 },
        .{ .initial_p95_ns = 300, .final_p95_ns = 900 },
        .{ .initial_p95_ns = 400, .final_p95_ns = 800 },
        .{ .initial_p95_ns = 500, .final_p95_ns = 1_500 },
    };
    var ratios: [growth_batches]u64 = undefined;
    for (observations, &ratios) |observation, *value| value.* = observation.factor();
    try std.testing.expect(!evaluate(&ratios, 3).passed);
    try std.testing.expectEqual(@as(u64, 1_000), ratios[0]);
    try std.testing.expectEqual(@as(u64, 100), observations[0].initial_p95_ns);
    try std.testing.expectEqual(@as(u64, 300), observations[0].final_p95_ns);
    try std.testing.expectEqual(@as(u64, 1_500), observations[4].final_p95_ns);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try observations[0].write(&out.writer, 1);
    try std.testing.expectEqualStrings(
        "growth_batch=1 initial_p95_ns=100 final_p95_ns=300 " ++
            "entries=0 records=0 active=0 pins=0 details=0 retained_bytes=0\n",
        out.written(),
    );
}
