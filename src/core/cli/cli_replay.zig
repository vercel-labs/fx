//! `di replay <tape>` implementation.
//!
//! This module keeps tape parsing and virtual-terminal replay isolated from
//! the top-level CLI dispatch.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const output_contracts = @import("../output/output_contracts.zig");
const record_tape = @import("../workspace/record_tape.zig");
const vt_emulator = @import("../terminal/engine.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    path: []const u8 = "",
    frames: bool = false,
    json: bool = false,
    golden_path: ?[]const u8 = null,
    frames_dir: ?[]const u8 = null,
};

pub const Error = error{
    MissingTapePath,
    TooManyArgs,
    UnknownFlag,
    MissingGoldenPath,
    MissingFramesDirPath,
} || std.mem.Allocator.Error;

pub fn parseArgs(args: []const [:0]const u8) Error!Options {
    var opts: Options = .{};
    var positional_seen = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--frames")) {
            opts.frames = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--golden")) {
            i += 1;
            if (i >= args.len) return Error.MissingGoldenPath;
            opts.golden_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--frames-dir")) {
            i += 1;
            if (i >= args.len) return Error.MissingFramesDirPath;
            opts.frames_dir = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return Error.UnknownFlag;
        if (positional_seen) return Error.TooManyArgs;
        opts.path = arg;
        positional_seen = true;
    }
    if (!positional_seen) return Error.MissingTapePath;
    return opts;
}

pub fn run(alloc: std.mem.Allocator, args: []const [:0]const u8) !u8 {
    var output: ProcessOutput = .{};
    return runWithOutput(alloc, args, &output);
}

fn runWithOutput(alloc: Allocator, args: []const [:0]const u8, output: anytype) !u8 {
    const opts = parseArgs(args) catch |err| {
        return replyParseError(alloc, output, err, argsContainJson(args));
    };

    debug_trace.configureFromEnv(alloc, ".");
    defer debug_trace.shutdown();
    debug_trace.logf("render", "replay_start json={s} frames={s} golden={s} frames_dir={s}", .{
        if (opts.json) "true" else "false",
        if (opts.frames) "true" else "false",
        if (opts.golden_path != null) "true" else "false",
        if (opts.frames_dir != null) "true" else "false",
    });

    const file = std.Io.Dir.cwd().openFile(io_mod.getIo(), opts.path, .{}) catch |err| {
        return replyFormattedError(alloc, output, opts.json, @errorName(err), 512, "di replay: cannot open {s}: {s}\n", .{ opts.path, @errorName(err) }, "di replay: open failed\n");
    };
    var file_mut = file;
    defer file_mut.close(io_mod.getIo());

    const bytes = io_mod.readFileToEnd(alloc, &file_mut, 64 * 1024 * 1024) catch |err| {
        return replyFormattedError(alloc, output, opts.json, @errorName(err), 256, "di replay: read failed: {s}\n", .{@errorName(err)}, "di replay: read failed\n");
    };
    defer alloc.free(bytes);

    var parser = record_tape.Parser.init(bytes) catch |err| {
        return replyFormattedError(alloc, output, opts.json, @errorName(err), 256, "di replay: bad tape: {s}\n", .{@errorName(err)}, "di replay: bad tape\n");
    };
    debug_trace.logf("render", "replay_header cols={d} rows={d} version_bytes={d}", .{
        parser.header.cols,
        parser.header.rows,
        parser.header.version.len,
    });

    var summary: std.Io.Writer.Allocating = .init(alloc);
    defer summary.deinit();

    var grid = try vt_emulator.Grid.init(alloc, parser.header.cols, parser.header.rows);
    defer grid.deinit();

    if (opts.json) {
        try summary.writer.print(
            "{{\"cols\":{d},\"rows\":{d},\"epoch_ms\":{d},\"version\":",
            .{ parser.header.cols, parser.header.rows, parser.header.epoch_ms },
        );
        try std.json.Stringify.value(parser.header.version, .{}, &summary.writer);
        try summary.writer.writeAll(",\"frames\":[");
    }

    var frame_count: usize = 0;
    var resize_count: usize = 0;
    var stdout_bytes: usize = 0;
    var first_json_frame = true;
    var elapsed_ms: i64 = 0;
    var markers: std.ArrayList([]const u8) = .empty;
    defer markers.deinit(alloc);
    var ignored_incomplete_tail = false;

    if (opts.frames_dir) |dir| {
        prepareFramesDir(alloc, dir) catch |err| {
            return replyFormattedError(alloc, output, opts.json, @errorName(err), 512, "di replay: cannot prepare frames dir {s}: {s}\n", .{ dir, @errorName(err) }, "di replay: cannot prepare frames dir\n");
        };
    }

    while (true) {
        const maybe_frame = parser.next() catch |err| switch (err) {
            error.TruncatedFrameHeader, error.TruncatedFramePayload => {
                ignored_incomplete_tail = true;
                break;
            },
        };
        const frame = maybe_frame orelse break;
        frame_count += 1;
        elapsed_ms += frame.delta_ms;

        switch (frame.kind) {
            .stdout => {
                stdout_bytes += frame.payload.len;
                try grid.feed(frame.payload);
            },
            .resize => {
                if (frame.payload.len >= 4) {
                    const cols = std.mem.readInt(u16, frame.payload[0..2], .little);
                    const rows = std.mem.readInt(u16, frame.payload[2..4], .little);
                    try grid.resize(cols, rows);
                    resize_count += 1;
                }
            },
            .marker => try markers.append(alloc, frame.payload),
            .stdin, .sigint => {},
            _ => {},
        }

        if (opts.json) {
            if (!first_json_frame) try summary.writer.writeAll(",");
            first_json_frame = false;
            try summary.writer.print("{{\"delta_ms\":{d},\"kind\":", .{frame.delta_ms});
            try std.json.Stringify.value(frameKindName(frame.kind), .{}, &summary.writer);
            try summary.writer.print(",\"len\":{d}}}", .{frame.payload.len});
        }

        if (opts.frames and frame.kind != .marker) {
            const header_text = try std.fmt.allocPrint(alloc, "\n--- frame {d} ({s}, +{d}ms) ---\n", .{ frame_count, frameKindName(frame.kind), frame.delta_ms });
            defer alloc.free(header_text);
            try output.writeStdout(header_text);
            var snapshot: std.ArrayList(u8) = .empty;
            defer snapshot.deinit(alloc);
            try grid.snapshot(&snapshot);
            try output.writeStdout(snapshot.items);
        }

        if (opts.frames_dir) |dir| {
            writeFrameArtifacts(alloc, dir, frame_count, frame, elapsed_ms, grid, markers.items) catch |err| {
                return replyFormattedError(alloc, output, opts.json, @errorName(err), 512, "di replay: cannot write frame artifacts to {s}: {s}\n", .{ dir, @errorName(err) }, "di replay: cannot write frame artifacts\n");
            };
        }
    }
    debug_trace.logf("frame_diff", "replay_complete frames={d} resizes={d} stdout_bytes={d}", .{
        frame_count,
        resize_count,
        stdout_bytes,
    });

    if (opts.json) {
        try summary.writer.print(
            "],\"frame_count\":{d},\"resize_count\":{d},\"stdout_bytes\":{d}}}\n",
            .{ frame_count, resize_count, stdout_bytes },
        );
        try output.writeStdout(summary.written());
    }
    if (ignored_incomplete_tail) {
        try output.writeStderr("di replay: ignored incomplete final tape frame\n");
    }

    if (opts.frames_dir) |dir| {
        writeFramesManifest(alloc, dir, parser.header, frame_count, resize_count, stdout_bytes) catch |err| {
            return replyFormattedError(alloc, output, opts.json, @errorName(err), 512, "di replay: cannot write frames manifest to {s}: {s}\n", .{ dir, @errorName(err) }, "di replay: cannot write frames manifest\n");
        };
    }

    var final: std.ArrayList(u8) = .empty;
    defer final.deinit(alloc);
    try grid.snapshot(&final);

    if (opts.golden_path) |out_path| {
        var out_file = std.Io.Dir.cwd().createFile(io_mod.getIo(), out_path, .{ .truncate = true }) catch |err| {
            return replyFormattedError(alloc, output, opts.json, @errorName(err), 256, "di replay: cannot write {s}: {s}\n", .{ out_path, @errorName(err) }, "di replay: write failed\n");
        };
        defer out_file.close(io_mod.getIo());
        try out_file.writeStreamingAll(io_mod.getIo(), final.items);
        return 0;
    }

    if (!opts.frames and !opts.json) {
        try output.writeStdout(final.items);
    }
    return 0;
}

fn frameKindName(kind: record_tape.Kind) []const u8 {
    const raw = @intFromEnum(kind);
    inline for (std.meta.fields(record_tape.Kind)) |field| {
        if (raw == field.value) return field.name;
    }
    return "unknown";
}

fn prepareFramesDir(alloc: Allocator, root: []const u8) !void {
    try io_mod.makeDirRecursive(root);
    const frames_path = try std.fs.path.join(alloc, &.{ root, "frames" });
    defer alloc.free(frames_path);
    try io_mod.makeDirRecursive(frames_path);
}

fn writeFrameArtifacts(
    alloc: Allocator,
    root: []const u8,
    index: usize,
    frame: record_tape.ReplayFrame,
    elapsed_ms: i64,
    grid: vt_emulator.Grid,
    markers: []const []const u8,
) !void {
    var snapshot: std.ArrayList(u8) = .empty;
    defer snapshot.deinit(alloc);
    try grid.snapshot(&snapshot);

    const stem = try std.fmt.allocPrint(alloc, "{d:0>4}", .{index});
    defer alloc.free(stem);
    const json_name = try std.fmt.allocPrint(alloc, "{s}.json", .{stem});
    defer alloc.free(json_name);
    const grid_name = try std.fmt.allocPrint(alloc, "{s}.grid.txt", .{stem});
    defer alloc.free(grid_name);
    const json_path = try std.fs.path.join(alloc, &.{ root, "frames", json_name });
    defer alloc.free(json_path);
    const grid_path = try std.fs.path.join(alloc, &.{ root, "frames", grid_name });
    defer alloc.free(grid_path);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print(
        "{{\"index\":{d},\"delta_ms\":{d},\"elapsed_ms\":{d},\"kind\":",
        .{ index, frame.delta_ms, elapsed_ms },
    );
    try std.json.Stringify.value(frameKindName(frame.kind), .{}, &out.writer);
    try out.writer.print(
        ",\"payload_len\":{d},\"size\":{{\"cols\":{d},\"rows\":{d}}},\"cursor\":{{\"row\":{d},\"col\":{d},\"visible\":{s}}},\"footer_candidates\":",
        .{
            frame.payload.len,
            grid.cols,
            grid.rows,
            grid.cursor_row,
            grid.cursor_col,
            if (grid.cursor_visible) "true" else "false",
        },
    );
    try writeFooterCandidates(&out.writer, alloc, snapshot.items);
    try out.writer.writeAll(",\"visible_markers\":");
    try writeVisibleMarkers(&out.writer, snapshot.items, markers);
    try out.writer.writeAll("}\n");

    try writeFile(json_path, out.written());
    try writeFile(grid_path, snapshot.items);
}

fn writeFramesManifest(
    alloc: Allocator,
    root: []const u8,
    header: record_tape.ReplayHeader,
    frame_count: usize,
    resize_count: usize,
    stdout_bytes: usize,
) !void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print(
        "{{\"cols\":{d},\"rows\":{d},\"epoch_ms\":{d},\"version\":",
        .{ header.cols, header.rows, header.epoch_ms },
    );
    try std.json.Stringify.value(header.version, .{}, &out.writer);
    try out.writer.print(
        ",\"frame_count\":{d},\"resize_count\":{d},\"stdout_bytes\":{d},\"frames_dir\":\"frames\"}}\n",
        .{ frame_count, resize_count, stdout_bytes },
    );

    const manifest_path = try std.fs.path.join(alloc, &.{ root, "manifest.json" });
    defer alloc.free(manifest_path);
    try writeFile(manifest_path, out.written());
}

fn writeFooterCandidates(writer: anytype, alloc: Allocator, snapshot: []const u8) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);

    var it = std.mem.splitScalar(u8, snapshot, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(alloc, line);
    }

    try writer.writeByte('[');
    var first = true;
    for (lines.items, 0..) |line, i| {
        if (!isInputSnapshotRow(line)) continue;
        if (i == 0 or i + 1 >= lines.items.len) continue;
        if (!isDividerSnapshotRow(lines.items[i - 1]) or !isDividerSnapshotRow(lines.items[i + 1])) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print(
            "{{\"top_divider\":{d},\"input\":{d},\"bottom_divider\":{d}}}",
            .{ i, i + 1, i + 2 },
        );
    }
    try writer.writeByte(']');
}

fn writeVisibleMarkers(writer: anytype, snapshot: []const u8, markers: []const []const u8) !void {
    try writer.writeByte('[');
    var first = true;
    for (markers) |marker| {
        if (marker.len == 0) continue;
        if (std.mem.find(u8, snapshot, marker) == null) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try std.json.Stringify.value(marker, .{}, writer);
    }
    try writer.writeByte(']');
}

fn isInputSnapshotRow(line: []const u8) bool {
    const text = trimSnapshotFrame(line);
    return std.mem.startsWith(u8, text, "❯") or
        std.mem.startsWith(u8, text, ">") or
        (std.mem.startsWith(u8, text, "[") and std.mem.find(u8, text, "] ❯") != null) or
        (std.mem.startsWith(u8, text, "[") and std.mem.find(u8, text, "] >") != null);
}

fn isDividerSnapshotRow(line: []const u8) bool {
    const text = trimSnapshotFrame(line);
    return std.mem.find(u8, text, "──") != null or
        std.mem.find(u8, text, "━━") != null or
        std.mem.find(u8, text, "══") != null;
}

fn trimSnapshotFrame(line: []const u8) []const u8 {
    if (line.len >= 2 and line[0] == '|' and line[line.len - 1] == '|') {
        return std.mem.trimEnd(u8, line[1 .. line.len - 1], " ");
    }
    return std.mem.trimEnd(u8, line, " ");
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const zio = io_mod.getIo();
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.createFileAbsolute(zio, path, .{ .truncate = true })
    else
        try std.Io.Dir.cwd().createFile(zio, path, .{ .truncate = true });
    defer file.close(zio);
    try file.writeStreamingAll(zio, bytes);
}

fn replyFormattedError(
    alloc: Allocator,
    output: anytype,
    json: bool,
    code: []const u8,
    comptime buffer_len: usize,
    comptime fmt: []const u8,
    args: anytype,
    fallback: []const u8,
) !u8 {
    var buf: [buffer_len]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fallback;
    return replyError(alloc, output, json, code, msg);
}

fn replyError(
    alloc: Allocator,
    output: anytype,
    json: bool,
    code: []const u8,
    message: []const u8,
) !u8 {
    if (!json) {
        output.writeStderr(message) catch {};
        return 1;
    }
    const rendered = try (output_contracts.CommandFailureSnapshot{
        .kind = "replay",
        .message = std.mem.trimEnd(u8, message, "\r\n"),
        .code = code,
    }).renderJson(alloc);
    defer alloc.free(rendered);
    output.writeStdout(rendered) catch {};
    output.writeStdout("\n") catch {};
    return 1;
}

fn replyParseError(
    alloc: Allocator,
    output: anytype,
    err: Error,
    json: bool,
) !u8 {
    const msg = switch (err) {
        Error.MissingTapePath => "di replay: missing tape path\nusage: di replay <tape> [--frames] [--json] [--golden <path>] [--frames-dir <path>]\n",
        Error.TooManyArgs => "di replay: too many positional arguments\n",
        Error.UnknownFlag => "di replay: unknown flag\n",
        Error.MissingGoldenPath => "di replay: --golden requires a path\n",
        Error.MissingFramesDirPath => "di replay: --frames-dir requires a path\n",
        else => "di replay: argument error\n",
    };
    return replyError(alloc, output, json, @errorName(err), msg);
}

fn argsContainJson(args: []const [:0]const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}

const ProcessOutput = struct {
    fn writeStdout(_: *@This(), text: []const u8) !void {
        try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
    }

    fn writeStderr(_: *@This(), text: []const u8) !void {
        try std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), text);
    }
};

const CaptureOutput = struct {
    stdout: std.Io.Writer.Allocating,
    stderr: std.Io.Writer.Allocating,

    fn init(alloc: Allocator) CaptureOutput {
        return .{
            .stdout = .init(alloc),
            .stderr = .init(alloc),
        };
    }

    fn deinit(self: *@This()) void {
        self.stdout.deinit();
        self.stderr.deinit();
    }

    fn writeStdout(self: *@This(), text: []const u8) !void {
        try self.stdout.writer.writeAll(text);
    }

    fn writeStderr(self: *@This(), text: []const u8) !void {
        try self.stderr.writer.writeAll(text);
    }
};

fn buildTape(alloc: Allocator, cols: u16, rows: u16, version: []const u8, frames: []const TestFrame) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.writeAll(record_tape.magic);
    var header: [2 + 2 + 8 + 1]u8 = undefined;
    std.mem.writeInt(u16, header[0..2], cols, .little);
    std.mem.writeInt(u16, header[2..4], rows, .little);
    std.mem.writeInt(i64, header[4..12], 123456789, .little);
    header[12] = @intCast(@min(version.len, @as(usize, 255)));
    try out.writer.writeAll(&header);
    try out.writer.writeAll(version[0..@min(version.len, 255)]);

    for (frames) |frame| {
        var frame_header: [9]u8 = undefined;
        std.mem.writeInt(i32, frame_header[0..4], frame.delta_ms, .little);
        frame_header[4] = @intFromEnum(frame.kind);
        std.mem.writeInt(u32, frame_header[5..9], @intCast(frame.payload.len), .little);
        try out.writer.writeAll(&frame_header);
        try out.writer.writeAll(frame.payload);
    }

    return try out.toOwnedSlice();
}

const TestFrame = struct {
    delta_ms: i32,
    kind: record_tape.Kind,
    payload: []const u8,
};

fn resizePayload(cols: u16, rows: u16) [4]u8 {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], cols, .little);
    std.mem.writeInt(u16, payload[2..4], rows, .little);
    return payload;
}

fn unknownKind(raw: u8) record_tape.Kind {
    return @enumFromInt(raw);
}

fn writeTestFile(path: []const u8, content: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn readTestFile(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
}

fn testPath(alloc: Allocator, dir: std.Io.Dir, name: []const u8) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, dir, ".");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, name });
}

fn runCaptured(alloc: Allocator, args: []const [:0]const u8, capture: *CaptureOutput) !u8 {
    return runWithOutput(alloc, args, capture);
}

const testing = std.testing;

test "parseArgs requires a positional tape path" {
    try testing.expectError(Error.MissingTapePath, parseArgs(&.{}));
    try testing.expectError(Error.MissingTapePath, parseArgs(&.{ "--frames", "--json" }));
    const opts = try parseArgs(&.{"tape.fxtape"});
    try testing.expectEqualStrings("tape.fxtape", opts.path);
    try testing.expect(!opts.frames);
}

test "parseArgs accepts supported flags" {
    const opts = try parseArgs(&.{ "--frames", "t.fxtape", "--json", "--golden", "out.txt", "--frames-dir", "frames-out" });
    try testing.expectEqualStrings("t.fxtape", opts.path);
    try testing.expect(opts.frames);
    try testing.expect(opts.json);
    try testing.expectEqualStrings("out.txt", opts.golden_path.?);
    try testing.expectEqualStrings("frames-out", opts.frames_dir.?);
}

test "parseArgs rejects invalid forms" {
    try testing.expectError(Error.TooManyArgs, parseArgs(&.{ "a.fxtape", "b.fxtape" }));
    try testing.expectError(Error.UnknownFlag, parseArgs(&.{ "a.fxtape", "--unknown" }));
    try testing.expectError(Error.MissingGoldenPath, parseArgs(&.{ "a.fxtape", "--golden" }));
    try testing.expectError(Error.MissingFramesDirPath, parseArgs(&.{ "a.fxtape", "--frames-dir" }));
}

test "minimal stdout tape replays to final grid snapshot" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tape_path = try testPath(alloc, tmp.dir, "stdout.fxtape");
    defer alloc.free(tape_path);

    const tape = try buildTape(alloc, 5, 2, "vtest", &.{
        .{ .delta_ms = 0, .kind = .stdout, .payload = "hi" },
    });
    defer alloc.free(tape);
    try writeTestFile(tape_path, tape);
    const tape_arg = try alloc.dupeZ(u8, tape_path);
    defer alloc.free(tape_arg);

    var capture = CaptureOutput.init(alloc);
    defer capture.deinit();

    const exit_code = try runCaptured(alloc, &.{tape_arg}, &capture);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("|hi   |\n|     |\n", capture.stdout.written());
    try testing.expectEqualStrings("", capture.stderr.written());
}

test "frames mode prints non-marker frame snapshots only" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tape_path = try testPath(alloc, tmp.dir, "frames.fxtape");
    defer alloc.free(tape_path);

    const tape = try buildTape(alloc, 4, 1, "vtest", &.{
        .{ .delta_ms = 3, .kind = .marker, .payload = "ignored" },
        .{ .delta_ms = 7, .kind = .stdout, .payload = "ok" },
    });
    defer alloc.free(tape);
    try writeTestFile(tape_path, tape);
    const tape_arg = try alloc.dupeZ(u8, tape_path);
    defer alloc.free(tape_arg);

    var capture = CaptureOutput.init(alloc);
    defer capture.deinit();

    const exit_code = try runCaptured(alloc, &.{ tape_arg, "--frames" }, &capture);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, capture.stdout.written(), "\n--- frame 2 (stdout, +7ms) ---\n") != null);
    try testing.expect(std.mem.find(u8, capture.stdout.written(), "marker") == null);
    try testing.expect(std.mem.find(u8, capture.stdout.written(), "|ok  |\n") != null);
}

test "json summary reports frame resize and stdout metadata" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tape_path = try testPath(alloc, tmp.dir, "summary.fxtape");
    defer alloc.free(tape_path);

    const resize = resizePayload(2, 2);
    const tape = try buildTape(alloc, 4, 1, "vtest", &.{
        .{ .delta_ms = 1, .kind = .stdout, .payload = "ab" },
        .{ .delta_ms = 2, .kind = .resize, .payload = &resize },
    });
    defer alloc.free(tape);
    try writeTestFile(tape_path, tape);
    const tape_arg = try alloc.dupeZ(u8, tape_path);
    defer alloc.free(tape_arg);

    var capture = CaptureOutput.init(alloc);
    defer capture.deinit();

    const exit_code = try runCaptured(alloc, &.{ tape_arg, "--json" }, &capture);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(std.mem.find(u8, capture.stdout.written(), "\"frame_count\":2") != null);
    try testing.expect(std.mem.find(u8, capture.stdout.written(), "\"resize_count\":1") != null);
    try testing.expect(std.mem.find(u8, capture.stdout.written(), "\"stdout_bytes\":2") != null);
}

test "json output escapes metadata strings" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tape_path = try testPath(alloc, tmp.dir, "escape.fxtape");
    defer alloc.free(tape_path);

    const version = "v\"\\\n\t" ++ [_]u8{1};
    const tape = try buildTape(alloc, 3, 1, version, &.{
        .{ .delta_ms = 0, .kind = .stdout, .payload = "x" },
    });
    defer alloc.free(tape);
    try writeTestFile(tape_path, tape);
    const tape_arg = try alloc.dupeZ(u8, tape_path);
    defer alloc.free(tape_arg);

    var capture = CaptureOutput.init(alloc);
    defer capture.deinit();

    const exit_code = try runCaptured(alloc, &.{ tape_arg, "--json" }, &capture);
    try testing.expectEqual(@as(u8, 0), exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trim(u8, capture.stdout.written(), " \t\r\n"), .{});
    defer parsed.deinit();
}

test "json output includes unknown frame metadata without altering grid" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tape_path = try testPath(alloc, tmp.dir, "unknown-json.fxtape");
    defer alloc.free(tape_path);

    const tape = try buildTape(alloc, 3, 1, "vtest", &.{
        .{ .delta_ms = 5, .kind = unknownKind(200), .payload = "ignored" },
    });
    defer alloc.free(tape);
    try writeTestFile(tape_path, tape);
    const tape_arg = try alloc.dupeZ(u8, tape_path);
    defer alloc.free(tape_arg);

    var capture = CaptureOutput.init(alloc);
    defer capture.deinit();

    const exit_code = try runCaptured(alloc, &.{ tape_arg, "--json" }, &capture);
    try testing.expectEqual(@as(u8, 0), exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trim(u8, capture.stdout.written(), " \t\r\n"), .{});
    defer parsed.deinit();
    const frames = parsed.value.object.get("frames").?.array.items;
    try testing.expectEqual(@as(usize, 1), frames.len);
    try testing.expectEqualStrings("unknown", frames[0].object.get("kind").?.string);
    try testing.expectEqualStrings("{\"cols\":3,\"rows\":1,\"epoch_ms\":123456789,\"version\":\"vtest\",\"frames\":[{\"delta_ms\":5,\"kind\":\"unknown\",\"len\":7}],\"frame_count\":1,\"resize_count\":0,\"stdout_bytes\":0}\n", capture.stdout.written());
}

test "json replay recovers an incomplete final frame through stderr" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tape_path = try testPath(alloc, tmp.dir, "truncated-tail.fxtape");
    defer alloc.free(tape_path);
    const tape = try buildTape(alloc, 4, 1, "vtest", &.{
        .{ .delta_ms = 0, .kind = .stdout, .payload = "ok" },
    });
    defer alloc.free(tape);

    var truncated: std.ArrayList(u8) = .empty;
    defer truncated.deinit(alloc);
    try truncated.appendSlice(alloc, tape);
    try truncated.appendSlice(alloc, &.{ 1, 2, 3 });
    try writeTestFile(tape_path, truncated.items);

    const tape_arg = try alloc.dupeZ(u8, tape_path);
    defer alloc.free(tape_arg);
    var capture = CaptureOutput.init(alloc);
    defer capture.deinit();

    const exit_code = try runCaptured(alloc, &.{ tape_arg, "--json" }, &capture);
    try testing.expectEqual(@as(u8, 0), exit_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, std.mem.trim(u8, capture.stdout.written(), " \t\r\n"), .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("frame_count").?.integer);
    try testing.expectEqualStrings("di replay: ignored incomplete final tape frame\n", capture.stderr.written());
}

test "frames mode prints unknown frame snapshots without trapping" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tape_path = try testPath(alloc, tmp.dir, "unknown-frames.fxtape");
    defer alloc.free(tape_path);

    const tape = try buildTape(alloc, 3, 1, "vtest", &.{
        .{ .delta_ms = 8, .kind = unknownKind(201), .payload = "ignored" },
    });
    defer alloc.free(tape);
    try writeTestFile(tape_path, tape);
    const tape_arg = try alloc.dupeZ(u8, tape_path);
    defer alloc.free(tape_arg);

    var capture = CaptureOutput.init(alloc);
    defer capture.deinit();

    const exit_code = try runCaptured(alloc, &.{ tape_arg, "--frames" }, &capture);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("\n--- frame 1 (unknown, +8ms) ---\n|   |\n", capture.stdout.written());
}

test "golden path writes final snapshot and suppresses final stdout" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tape_path = try testPath(alloc, tmp.dir, "golden.fxtape");
    defer alloc.free(tape_path);
    const golden_path = try testPath(alloc, tmp.dir, "golden.txt");
    defer alloc.free(golden_path);

    const tape = try buildTape(alloc, 4, 1, "vtest", &.{
        .{ .delta_ms = 0, .kind = .stdout, .payload = "ok" },
    });
    defer alloc.free(tape);
    try writeTestFile(tape_path, tape);
    const tape_arg = try alloc.dupeZ(u8, tape_path);
    defer alloc.free(tape_arg);
    const golden_arg = try alloc.dupeZ(u8, golden_path);
    defer alloc.free(golden_arg);

    var capture = CaptureOutput.init(alloc);
    defer capture.deinit();

    const exit_code = try runCaptured(alloc, &.{ tape_arg, "--golden", golden_arg }, &capture);
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("", capture.stdout.written());

    const golden = try readTestFile(alloc, golden_path);
    defer alloc.free(golden);
    try testing.expectEqualStrings("|ok  |\n", golden);
}

test "frames-dir writes manifest and per-frame grid artifacts" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tape_path = try testPath(alloc, tmp.dir, "frames-dir.fxtape");
    defer alloc.free(tape_path);
    const frames_dir = try testPath(alloc, tmp.dir, "frames-dir-out");
    defer alloc.free(frames_dir);

    const resize = resizePayload(6, 2);
    const tape = try buildTape(alloc, 5, 2, "vtest", &.{
        .{ .delta_ms = 1, .kind = .stdout, .payload = "hello" },
        .{ .delta_ms = 2, .kind = .marker, .payload = "hello" },
        .{ .delta_ms = 3, .kind = .resize, .payload = &resize },
    });
    defer alloc.free(tape);
    try writeTestFile(tape_path, tape);
    const tape_arg = try alloc.dupeZ(u8, tape_path);
    defer alloc.free(tape_arg);
    const frames_dir_arg = try alloc.dupeZ(u8, frames_dir);
    defer alloc.free(frames_dir_arg);

    var capture = CaptureOutput.init(alloc);
    defer capture.deinit();

    const exit_code = try runCaptured(alloc, &.{ tape_arg, "--frames-dir", frames_dir_arg }, &capture);
    try testing.expectEqual(@as(u8, 0), exit_code);

    const manifest_path = try std.fs.path.join(alloc, &.{ frames_dir, "manifest.json" });
    defer alloc.free(manifest_path);
    const frame_json_path = try std.fs.path.join(alloc, &.{ frames_dir, "frames", "0001.json" });
    defer alloc.free(frame_json_path);
    const frame_grid_path = try std.fs.path.join(alloc, &.{ frames_dir, "frames", "0001.grid.txt" });
    defer alloc.free(frame_grid_path);

    const manifest = try readTestFile(alloc, manifest_path);
    defer alloc.free(manifest);
    try testing.expect(std.mem.find(u8, manifest, "\"frame_count\":3") != null);
    try testing.expect(std.mem.find(u8, manifest, "\"resize_count\":1") != null);
    try testing.expect(std.mem.find(u8, manifest, "\"stdout_bytes\":5") != null);

    const frame_json = try readTestFile(alloc, frame_json_path);
    defer alloc.free(frame_json);
    try testing.expect(std.mem.find(u8, frame_json, "\"index\":1") != null);
    try testing.expect(std.mem.find(u8, frame_json, "\"kind\":\"stdout\"") != null);
    try testing.expect(std.mem.find(u8, frame_json, "\"cursor\"") != null);
    try testing.expect(std.mem.find(u8, frame_json, "\"footer_candidates\"") != null);
    try testing.expect(std.mem.find(u8, frame_json, "\"visible_markers\"") != null);

    const frame_grid = try readTestFile(alloc, frame_grid_path);
    defer alloc.free(frame_grid);
    try testing.expectEqualStrings("|hello|\n|     |\n", frame_grid);
}

test "run missing tape path returns current stderr" {
    const alloc = testing.allocator;
    var capture = CaptureOutput.init(alloc);
    defer capture.deinit();

    const exit_code = try runCaptured(alloc, &.{}, &capture);
    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.startsWith(u8, capture.stderr.written(), "di replay: missing tape path\n"));
}

test "json failures use stdout for missing arguments files and malformed tapes" {
    const alloc = std.testing.allocator;

    var missing_arg = CaptureOutput.init(alloc);
    defer missing_arg.deinit();
    try testing.expectEqual(
        @as(u8, 1),
        try runCaptured(alloc, &.{"--json"}, &missing_arg),
    );
    try testing.expectEqual(@as(usize, 0), missing_arg.stderr.written().len);
    try testing.expect(std.mem.find(u8, missing_arg.stdout.written(), "\"code\":\"MissingTapePath\"") != null);

    var missing_file = CaptureOutput.init(alloc);
    defer missing_file.deinit();
    try testing.expectEqual(
        @as(u8, 1),
        try runCaptured(alloc, &.{ "/definitely/missing/fx-replay.fxtape", "--json" }, &missing_file),
    );
    try testing.expectEqual(@as(usize, 0), missing_file.stderr.written().len);
    var missing_json = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        std.mem.trim(u8, missing_file.stdout.written(), " \t\r\n"),
        .{},
    );
    defer missing_json.deinit();
    try testing.expectEqualStrings("replay", missing_json.value.object.get("kind").?.string);
    try testing.expectEqualStrings("FileNotFound", missing_json.value.object.get("code").?.string);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(alloc, tmp.dir, "bad-json.fxtape");
    defer alloc.free(path);
    try writeTestFile(path, "not a tape");
    const path_arg: [:0]u8 = try alloc.dupeZ(u8, path);
    defer alloc.free(path_arg);
    var malformed = CaptureOutput.init(alloc);
    defer malformed.deinit();
    try testing.expectEqual(
        @as(u8, 1),
        try runCaptured(alloc, &.{ path_arg, "--json" }, &malformed),
    );
    try testing.expectEqual(@as(usize, 0), malformed.stderr.written().len);
    var malformed_json = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        std.mem.trim(u8, malformed.stdout.written(), " \t\r\n"),
        .{},
    );
    defer malformed_json.deinit();
    try testing.expectEqualStrings("replay", malformed_json.value.object.get("kind").?.string);
}

test "run malformed tape returns bad tape stderr" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tape_path = try testPath(alloc, tmp.dir, "malformed.fxtape");
    defer alloc.free(tape_path);
    try writeTestFile(tape_path, "not a tape");
    const tape_arg = try alloc.dupeZ(u8, tape_path);
    defer alloc.free(tape_arg);

    var capture = CaptureOutput.init(alloc);
    defer capture.deinit();

    const exit_code = try runCaptured(alloc, &.{tape_arg}, &capture);
    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expect(std.mem.startsWith(u8, capture.stderr.written(), "di replay: bad tape"));
}
