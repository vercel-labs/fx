//! Fuzz targets for the hook engine's decoders and the host's file decoders.
//! The engine in `src/hooks/` imports only the standard library and its own
//! files, so the targets that feed it bytes live here, with the host, and reach
//! it through the front door. The host's trust file and run-log decoders live
//! here too, since they are not part of the engine.

const std = @import("std");
const hooks = @import("../../hooks/hooks.zig");
const trust = @import("trust.zig");
const hook_verbs = @import("../cli/hook_verbs.zig");
const io_mod = @import("../shared/io.zig");

const config = hooks.config;
const match = hooks.match;
const protocol = hooks.protocol;
const event = hooks.event;
const answer = hooks.answer;
const limits = hooks.limits;
const testing = std.testing;

test "a hook file parses into owned hooks and diagnostics for fuzzed bytes" {
    try testing.fuzz({}, fuzzParseHookFile, .{
        .corpus = &(@import("fuzz_seed").slices(.{""}) ++ @import("fuzz_corpus").hook_file_parse.*),
    });
}

fn fuzzParseHookFile(_: void, smith: *testing.Smith) !void {
    const alloc = testing.allocator;
    var buffer: [8192]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    var file = try config.parse(alloc, bytes, .{ .layer = .profile, .workspace_root = "/Users/example/workspace" });
    defer file.deinit(alloc);

    // Whatever the bytes, each hook keeps the bounds its limits set: a timeout from 1 ms up to the longest one a
    // hook may ask for, an id and a matcher within their sizes, and no more hooks than one file may hold.
    try testing.expect(file.hooks.len <= limits.hooks_per_file);
    for (file.hooks) |hook| {
        try testing.expect(hook.timeout_ms >= 1 and hook.timeout_ms <= limits.max_timeout_ms);
        try testing.expect(hook.id.len >= 1 and hook.id.len <= limits.hook_id_bytes);
        try testing.expect(hook.matcher_text.len <= limits.matcher_bytes);
        _ = hook.matcher.matchesTool("shell");
    }
}

test "a hook matcher compiles or is refused, and a compiled matcher answers any name for fuzzed bytes" {
    try testing.fuzz({}, fuzzCompile, .{
        .corpus = &(@import("fuzz_seed").slices(.{""}) ++ @import("fuzz_corpus").hook_matcher_compile.*),
    });
}

fn fuzzCompile(_: void, smith: *testing.Smith) !void {
    const alloc = testing.allocator;
    var pattern_buffer: [1536]u8 = undefined;
    var name_buffer: [256]u8 = undefined;
    const pattern = pattern_buffer[0..@intCast(smith.slice(&pattern_buffer))];
    const name = name_buffer[0..@intCast(smith.slice(&name_buffer))];

    var matcher = match.compile(alloc, pattern) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidMatcher, error.MatcherTooLong => return,
    };
    defer matcher.deinit(alloc);

    // Any name answers without a panic. A name list answers true exactly when some non-empty part is the whole name.
    _ = matcher.matches(name);
    _ = matcher.matchesTool(name);
    switch (matcher.kind) {
        .all => try testing.expect(matcher.matches(name)),
        .names => {
            var expected = false;
            var parts = std.mem.splitScalar(u8, pattern, '|');
            while (parts.next()) |part| {
                if (part.len > 0 and std.mem.eql(u8, part, name)) expected = true;
            }
            try testing.expectEqual(expected, matcher.matches(name));
        },
        .regex => {},
    }
}

test "a hook's stdout and exit code read as one answer or failure, borrowing from the output for fuzzed bytes" {
    try testing.fuzz({}, fuzzReadOutput, .{
        .corpus = &(@import("fuzz_seed").slices(.{""}) ++ @import("fuzz_corpus").hook_output_read.*),
    });
}

fn fuzzReadOutput(_: void, smith: *testing.Smith) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    const stdout = stdout_buffer[0..@intCast(smith.slice(&stdout_buffer))];
    const stderr = stderr_buffer[0..@intCast(smith.slice(&stderr_buffer))];
    const names = [_]event.EventName{ .pre_tool_use, .stop, .user_prompt_submit, .post_tool_use };
    const name = names[smith.value(u8) % names.len];
    const on_failure: answer.OnFailure = if ((smith.value(u8) & 1) == 0) .proceed else .block;
    const code = smith.value(u8);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const result = try protocol.readOutput(arena_state.allocator(), name, on_failure, .{
        .code = code,
        .stdout = stdout,
        .stderr = stderr,
    });

    switch (result) {
        // An exit-code failure names the code it saw, and its detail is the first line of stderr.
        .failure => |failure| if (failure.kind == .exit_code) {
            try testing.expectEqual(@as(?u8, code), failure.exit_code);
            try expectWithin(stderr, failure.detail);
        },
        // Plain stdout becomes context only when it is not JSON and the exit was 0, and then it borrows from stdout.
        .answer => |value| if (value.additional_context) |context| {
            const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
            const looks_json = trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}';
            if (code == 0 and !looks_json) try expectWithin(stdout, context);
        },
    }
}

fn expectWithin(input: []const u8, borrowed: []const u8) !void {
    if (borrowed.len == 0) return;
    const start = @intFromPtr(input.ptr);
    const borrowed_start = @intFromPtr(borrowed.ptr);
    try testing.expect(borrowed_start >= start);
    try testing.expect(borrowed_start + borrowed.len <= start + input.len);
}

test "a trust file loads into digests and disabled hooks, or is refused, for fuzzed bytes" {
    try testing.fuzz({}, fuzzTrustLoad, .{
        .corpus = &(@import("fuzz_seed").slices(.{""}) ++ @import("fuzz_corpus").hook_trust_load.*),
    });
}

fn fuzzTrustLoad(_: void, smith: *testing.Smith) !void {
    const alloc = testing.allocator;
    var buffer: [8192]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(folder);
    const file_path = try std.Io.Dir.path.join(alloc, &.{ folder, "hooks-trust.json" });
    defer alloc.free(file_path);
    try io_mod.writeFileAtomic(alloc, file_path, bytes);
    try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), file_path, std.Io.File.Permissions.fromMode(0o600), .{});

    var store = trust.load(alloc, file_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.TrustFileUnsafe, error.TrustFileInvalid, error.TrustFileUnreadable => return,
    };
    defer store.deinit(alloc);
    try expectWithinTrustInput(&store, bytes.len);

    // A store that loaded and was saved again loads back as the same store.
    const saved_path = try std.Io.Dir.path.join(alloc, &.{ folder, "saved-trust.json" });
    defer alloc.free(saved_path);
    try trust.save(alloc, saved_path, &store);
    var again = try trust.load(alloc, saved_path);
    defer again.deinit(alloc);
    try expectSameTrustStore(&store, &again);
}

/// A loaded store holds at most the entries the loader allows. Each digest is 32 bytes written as 64
/// lowercase hex digits, and every text it holds is no longer than the file it came from.
fn expectWithinTrustInput(store: *const trust.Store, input_len: usize) !void {
    try testing.expect(store.entries.items.len <= trust.max_entries);
    for (store.entries.items) |entry| {
        for (entry.digest) |c| try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
        try testing.expect(entry.label.len <= input_len);
    }
    for (store.disabled.items) |item| {
        try testing.expect(item.workspace.len <= input_len);
        try testing.expect(item.id.len <= input_len);
    }
}

fn expectSameTrustStore(expected: *const trust.Store, actual: *const trust.Store) !void {
    try testing.expectEqual(expected.entries.items.len, actual.entries.items.len);
    for (expected.entries.items, actual.entries.items) |want, got| {
        try testing.expectEqualSlices(u8, &want.digest, &got.digest);
        try testing.expectEqualStrings(want.label, got.label);
    }
    try testing.expectEqual(expected.disabled.items.len, actual.disabled.items.len);
    for (expected.disabled.items, actual.disabled.items) |want, got| {
        try testing.expectEqualStrings(want.workspace, got.workspace);
        try testing.expectEqualStrings(want.id, got.id);
    }
}

test "a run-log line is read as one run, or skipped, for fuzzed bytes" {
    try testing.fuzz({}, fuzzHookLogLine, .{
        .corpus = &(@import("fuzz_seed").slices(.{""}) ++ @import("fuzz_corpus").hook_log_line.*),
    });
}

fn fuzzHookLogLine(_: void, smith: *testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const line = buffer[0..@intCast(smith.slice(&buffer))];
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entry = (try hook_verbs.parseHookLogLine(arena, line)) orelse return;

    // A line that is read as a run has every field the log writes, with the kind the read expects. A second
    // decode of the same bytes must agree with what was read.
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    try testing.expect(parsed == .object);
    const object = parsed.object;
    try testing.expectEqual(entry.time_ms, object.get("time_ms").?.integer);
    try testing.expectEqualStrings(entry.event, object.get("event").?.string);
    try testing.expectEqualStrings(entry.surface, object.get("surface").?.string);
    try testing.expectEqualStrings(entry.decision, object.get("decision").?.string);
    try testing.expectEqual(@as(i64, @intCast(entry.ran)), object.get("ran").?.integer);
    try testing.expectEqual(@as(i64, @intCast(entry.notices)), object.get("notices").?.integer);
    try expectOptionalLogText(entry.match, object, "match");
    try expectOptionalLogText(entry.session_id, object, "session_id");
    try expectOptionalLogText(entry.decided_by, object, "decided_by");
    try expectOptionalLogText(entry.reason, object, "reason");
}

/// An optional field of a run line is present, and is null or a string equal to what was read.
fn expectOptionalLogText(value: ?[]const u8, object: std.json.ObjectMap, key: []const u8) !void {
    const json_value = object.get(key) orelse return error.TestUnexpectedResult;
    switch (json_value) {
        .null => try testing.expect(value == null),
        .string => |text| {
            try testing.expect(value != null);
            try testing.expectEqualStrings(text, value.?);
        },
        else => return error.TestUnexpectedResult,
    }
}
