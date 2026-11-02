//! Shipping latency gate for typed `FileIndex` fuzzy search.
//!
//! The benchmark builds a deterministic mixed file/directory inventory
//! through the production synthetic builder, then measures the complete
//! typed-result path, including final match-span reconstruction.
//!
//!     zig build run-bench-file-index -Doptimize=ReleaseFast -- 100000 500

const std = @import("std");
const file_index = @import("file_index");

const default_path_count: usize = file_index.max_indexed_files;
const default_iters_per_query: usize = 500;
const max_iters_per_query: usize = default_iters_per_query * 10;
const picker_cap: usize = 32;
const latency_budget_ns: u64 = 16_000_000;

const QueryCase = struct {
    name: []const u8,
    query: []const u8,
};

const query_cases = [_]QueryCase{
    .{ .name = "exact", .query = "src/core/workspace/file_index.zig" },
    .{ .name = "boundary", .query = "scwfi" },
    .{ .name = "low-selectivity", .query = "ae" },
    .{ .name = "long-gap", .query = "ashr" },
    .{ .name = "no-match", .query = "zzz-no-match-Ω" },
    .{ .name = "punctuation", .query = "api-route" },
    .{ .name = "unicode", .query = "ärf" },
    .{ .name = "unicode-fold", .query = "Klv" },
};

const subsystems = [_][]const u8{
    "apps",    "packages",  "libs",       "services",
    "tools",   "plugins",   "extensions", "modules",
    "infra",   "vendor",    "web",        "mobile",
    "workers", "functions",
};

const areas = [_][]const u8{
    "core",   "utils",    "components", "hooks",
    "api",    "db",       "auth",       "ui",
    "server", "client",   "cli",        "tests",
    "docs",   "internal", "shared",     "config",
};

const subareas = [_][]const u8{
    "common",   "helpers", "types",   "schemas",
    "models",   "views",   "routes",  "handlers",
    "services", "stores",  "context", "providers",
    "layouts",  "pages",   "forms",   "fields",
};

const names = [_][]const u8{
    "index", "main",    "app",      "Button",
    "Input", "Modal",   "helper",   "util",
    "types", "schema",  "model",    "view",
    "route", "handler", "service",  "store",
    "hook",  "context", "provider", "layout",
    "page",  "widget",  "icon",     "form",
    "field", "label",   "table",    "list",
    "card",  "dialog",  "menu",     "nav",
};

const extensions = [_][]const u8{
    ".ts",   ".tsx", ".js", ".jsx", ".zig",
    ".py",   ".rs",  ".go", ".md",  ".json",
    ".yaml",
};

const GeneratedInventory = struct {
    storage: []u8,
    candidates: []file_index.Candidate,

    fn deinit(self: GeneratedInventory, alloc: std.mem.Allocator) void {
        alloc.free(self.candidates);
        alloc.free(self.storage);
    }
};

fn candidateKind(candidate_index: usize) file_index.CandidateKind {
    return if (candidate_index % 2 == 0) .file else .directory;
}

fn generateInventory(alloc: std.mem.Allocator, path_count: usize) !GeneratedInventory {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    for (0..path_count) |candidate_index| {
        switch (candidate_index) {
            0 => try out.writer.writeAll("docs/Ärger-file.txt"),
            1 => try out.writer.writeAll("docs/Kelvin"),
            2 => try out.writer.writeAll("src/core/workspace/file_index.zig"),
            3 => try out.writer.writeAll("apps/web/api-route-handler"),
            else => {
                const subsystem = subsystems[candidate_index % subsystems.len];
                const area = areas[(candidate_index / subsystems.len) % areas.len];
                const depth_roll = (candidate_index / 7) % 3;
                const name = names[(candidate_index / 31) % names.len];

                try out.writer.writeAll(subsystem);
                try out.writer.writeByte('/');
                try out.writer.writeAll(area);
                try out.writer.writeByte('/');
                if (depth_roll >= 1) {
                    try out.writer.writeAll(subareas[(candidate_index / 17) % subareas.len]);
                    try out.writer.writeByte('/');
                }
                if (depth_roll >= 2) {
                    try out.writer.writeAll(subareas[(candidate_index / 23) % subareas.len]);
                    try out.writer.writeByte('/');
                }
                try out.writer.writeAll(name);
                try out.writer.print("{d}", .{candidate_index});
                if (candidateKind(candidate_index) == .file) {
                    try out.writer.writeAll(extensions[(candidate_index / 13) % extensions.len]);
                }
            },
        }
        try out.writer.writeByte(0);
    }

    const storage = try out.toOwnedSlice();
    errdefer alloc.free(storage);
    const candidates = try alloc.alloc(file_index.Candidate, path_count);
    errdefer alloc.free(candidates);

    var paths = std.mem.splitScalar(u8, storage, 0);
    for (candidates, 0..) |*candidate, candidate_index| {
        const path = paths.next() orelse return error.GeneratedCandidateCountMismatch;
        candidate.* = .{ .path = path, .kind = candidateKind(candidate_index) };
    }
    return .{ .storage = storage, .candidates = candidates };
}

fn nowNs(io: std.Io) i128 {
    return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
}

fn cmpU64(_: void, left: u64, right: u64) bool {
    return left < right;
}

fn percentile(sorted: []const u64, fraction: f64) u64 {
    if (sorted.len == 0) return 0;
    const index_float = @as(f64, @floatFromInt(sorted.len - 1)) * fraction;
    return sorted[@min(@as(usize, @intFromFloat(index_float)), sorted.len - 1)];
}

fn formatNs(nanoseconds: u64, buf: []u8) []const u8 {
    const microseconds = @as(f64, @floatFromInt(nanoseconds)) / 1_000.0;
    const milliseconds = microseconds / 1_000.0;
    if (nanoseconds < 1_000) return std.mem.print(buf, "{d}ns", .{nanoseconds}) catch "?";
    if (nanoseconds < 1_000_000) return std.mem.print(buf, "{d:.2}us", .{microseconds}) catch "?";
    return std.mem.print(buf, "{d:.2}ms", .{milliseconds}) catch "?";
}

pub fn main(init: std.process.Init) !void {
    const arena_alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena_alloc);
    const path_count = if (args.len >= 2)
        try std.fmt.parseInt(usize, std.mem.sliceTo(args[1], 0), 10)
    else
        default_path_count;
    const iters_per_query = if (args.len >= 3)
        try std.fmt.parseInt(usize, std.mem.sliceTo(args[2], 0), 10)
    else
        default_iters_per_query;
    if (path_count > file_index.max_indexed_files) return error.CandidateCountExceedsProductionCap;
    if (iters_per_query == 0 or iters_per_query > max_iters_per_query) return error.InvalidIterationCount;

    const alloc = std.heap.c_allocator;
    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(init.io, &stdout_buf);
    const out = &stdout_writer.interface;

    try out.print("=== typed file index fuzzy-search benchmark ===\n", .{});
    try out.print("candidates:       {d}\n", .{path_count});
    try out.print("result cap:       {d}\n", .{picker_cap});
    try out.print("iters per query:  {d}\n", .{iters_per_query});
    try out.print("queries:          {d}\n", .{query_cases.len});
    try out.print("total searches:   {d}\n", .{try std.math.mul(usize, iters_per_query, query_cases.len)});
    try out.flush();

    const generation_start = nowNs(init.io);
    const inventory = try generateInventory(alloc, path_count);
    defer inventory.deinit(alloc);
    const generation_ns: u64 = @intCast(nowNs(init.io) - generation_start);

    var index = file_index.FileIndex{};
    defer index.deinit(alloc);
    const build_start = nowNs(init.io);
    try index.buildFromCandidates(alloc, inventory.candidates);
    const build_ns: u64 = @intCast(nowNs(init.io) - build_start);

    var time_buf: [32]u8 = undefined;
    try out.print("generated:        {d} mixed candidates in {s}\n", .{ path_count, formatNs(generation_ns, &time_buf) });
    try out.print("indexed:          {d} candidates in {s}\n", .{ index.count(), formatNs(build_ns, &time_buf) });
    try out.flush();
    if (index.count() != path_count) return error.GeneratedCandidateCountMismatch;

    const span_capacity = try std.math.mul(usize, picker_cap, file_index.max_path_len);
    const span_storage = try alloc.alloc(file_index.MatchSpan, span_capacity);
    defer alloc.free(span_storage);

    const timing_capacity = try std.math.mul(usize, iters_per_query, query_cases.len);
    var all_timings: std.ArrayList(u64) = .empty;
    defer all_timings.deinit(alloc);
    try all_timings.ensureTotalCapacity(alloc, timing_capacity);

    var checksum: usize = 0;
    var representative_hits: usize = 0;
    try out.print("\nper-query results:\n", .{});
    try out.print("  {s:<18} {s:>6} {s:>12} {s:>12} {s:>12} {s:>12}\n", .{
        "class", "hits", "p50", "p95", "p99", "max",
    });

    for (query_cases) |query_case| {
        var timings: [max_iters_per_query]u64 = undefined;
        const timing_slice = timings[0..iters_per_query];

        for (0..8) |_| {
            var results: [picker_cap]file_index.SearchResult = undefined;
            _ = try index.searchTyped(query_case.query, &results, span_storage);
        }

        var last_hits: usize = 0;
        for (timing_slice) |*elapsed| {
            var results: [picker_cap]file_index.SearchResult = undefined;
            const started = nowNs(init.io);
            last_hits = try index.searchTyped(query_case.query, &results, span_storage);
            elapsed.* = @intCast(nowNs(init.io) - started);
            try all_timings.append(alloc, elapsed.*);
            checksum +%= last_hits;
            if (last_hits > 0) {
                checksum +%= results[0].path.len;
                checksum +%= results[0].matched_spans.len;
            }
        }
        representative_hits += last_hits;

        std.mem.sort(u64, timing_slice, {}, cmpU64);
        const p50 = percentile(timing_slice, 0.50);
        const p95 = percentile(timing_slice, 0.95);
        const p99 = percentile(timing_slice, 0.99);
        const maximum = timing_slice[timing_slice.len - 1];
        var p50_buf: [32]u8 = undefined;
        var p95_buf: [32]u8 = undefined;
        var p99_buf: [32]u8 = undefined;
        var max_buf: [32]u8 = undefined;
        try out.print("  {s:<18} {d:>6} {s:>12} {s:>12} {s:>12} {s:>12}\n", .{
            query_case.name,
            last_hits,
            formatNs(p50, &p50_buf),
            formatNs(p95, &p95_buf),
            formatNs(p99, &p99_buf),
            formatNs(maximum, &max_buf),
        });
        try out.flush();
    }

    std.mem.sort(u64, all_timings.items, {}, cmpU64);
    const overall_p50 = percentile(all_timings.items, 0.50);
    const overall_p95 = percentile(all_timings.items, 0.95);
    const overall_p99 = percentile(all_timings.items, 0.99);
    const overall_max = all_timings.items[all_timings.items.len - 1];
    var build_buf: [32]u8 = undefined;
    var p50_buf: [32]u8 = undefined;
    var p95_buf: [32]u8 = undefined;
    var p99_buf: [32]u8 = undefined;
    var max_buf: [32]u8 = undefined;
    try out.print("\noverall (across {d} searches):\n", .{all_timings.items.len});
    try out.print("  build           {s}\n", .{formatNs(build_ns, &build_buf)});
    try out.print("  representative hits {d}\n", .{representative_hits});
    try out.print("  result checksum {d}\n", .{checksum});
    try out.print("  search p50      {s}\n", .{formatNs(overall_p50, &p50_buf)});
    try out.print("  search p95      {s}\n", .{formatNs(overall_p95, &p95_buf)});
    try out.print("  search p99      {s}\n", .{formatNs(overall_p99, &p99_buf)});
    try out.print("  search max      {s}\n", .{formatNs(overall_max, &max_buf)});

    var gate_p95_buf: [32]u8 = undefined;
    const gate_passed = overall_p95 < latency_budget_ns;
    try out.print("\nlatency gate: {s} p95={s} budget=<16.00ms\n", .{
        if (gate_passed) "PASS" else "FAIL",
        formatNs(overall_p95, &gate_p95_buf),
    });
    try out.flush();
    if (!gate_passed) return error.LatencyBudgetExceeded;
}
