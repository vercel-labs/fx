const std = @import("std");
const result_store = @import("../../core/session/result_store.zig");
const command_replay_store = @import("../../core/session/command_replay_store.zig");
const session_child_store = @import("../../core/session/session_child_store.zig");
const io_mod = @import("../../core/shared/io.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const compactor = @import("../../core/compactor/compactor.zig");

const Allocator = std.mem.Allocator;

const HandleNormalization = struct {
    trimmed: []const u8,
    suffix: []const u8,
};

pub const Input = struct {
    handle: []u8,
    selector: union(enum) {
        range: struct {
            start_byte: usize = 1,
            byte_count: usize = result_store.read_default_bytes,
        },
        query: []u8,
        /// Searches every turn, tool call and earlier compaction saved by
        /// context compaction.
        search: [][]u8,
    } = .{ .range = .{} },

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.handle);
        switch (self.selector) {
            .range => {},
            .query => |query| alloc.free(query),
            .search => |phrases| {
                for (phrases) |phrase| alloc.free(phrase);
                alloc.free(phrases);
            },
        }
        self.* = .{ .handle = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result arguments must be an object") };
    }
    const args = if (parsed.value.object.get("request")) |request| blk: {
        if (request != .object) {
            return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"request\" must be an object") };
        }
        break :blk request.object;
    } else parsed.value.object;
    if (args.get("search")) |value| return decodeSearch(ctx.allocator, value);
    const handle_value = args.get("handle") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result requires string field \"handle\"") };
    };
    if (handle_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"handle\" must be a string") };
    }

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .handle = try ctx.allocator.dupe(u8, handle_value.string) };
    errdefer input.deinit(ctx.allocator);

    if (args.get("start_byte")) |value| {
        const start_byte = parsePositiveInteger(value) orelse {
            return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"start_byte\" must be a positive integer") };
        };
        input.selector.range.start_byte = @intCast(start_byte);
    }
    if (args.get("byte_count")) |value| {
        const byte_count = parsePositiveInteger(value) orelse {
            return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"byte_count\" must be a positive integer") };
        };
        input.selector.range.byte_count = @intCast(@min(byte_count, result_store.read_max_bytes));
    }
    if (args.get("query")) |value| {
        if (value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "read_tool_result field \"query\" must be a string") };
        }
        if (value.string.len > 0) {
            input.selector = .{ .query = try ctx.allocator.dupe(u8, value.string) };
        }
    }

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn decodeSearch(alloc: Allocator, value: std.json.Value) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const invalid = std.fmt.comptimePrint("read_tool_result field \"search\" must be 1 to {d} non-empty strings", .{compactor.max_search_phrases});
    const items: []const std.json.Value = switch (value) {
        .string => (&value)[0..1],
        .array => |array| array.items,
        else => return .{ .failure = try alloc.dupe(u8, invalid) },
    };
    if (items.len == 0 or items.len > compactor.max_search_phrases) return .{ .failure = try alloc.dupe(u8, invalid) };
    for (items) |item| {
        if (item != .string or std.mem.trim(u8, item.string, " \t\r\n").len == 0) return .{ .failure = try alloc.dupe(u8, invalid) };
    }
    const input = try alloc.create(Input);
    errdefer alloc.destroy(input);
    input.* = .{ .handle = &.{} };
    const phrases = try alloc.alloc([]u8, items.len);
    var copied: usize = 0;
    errdefer {
        for (phrases[0..copied]) |phrase| alloc.free(phrase);
        alloc.free(phrases);
    }
    for (items, phrases) |item, *phrase| {
        phrase.* = try alloc.dupe(u8, item.string);
        copied += 1;
    }
    input.selector = .{ .search = phrases };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn parsePositiveInteger(value: std.json.Value) ?i64 {
    if (value != .integer or value.integer < 1) return null;
    return value.integer;
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn classifyHandleNormalization(handle: []const u8) HandleNormalization {
    const trimmed = std.mem.trim(u8, handle, " \t\r\n");
    const suffix = if ((std.mem.startsWith(u8, trimmed, "result-") or result_store.isImageHandle(trimmed)) and
        std.mem.findScalar(u8, trimmed, '.') == null)
        ".txt"
    else
        "";
    return .{ .trimmed = trimmed, .suffix = suffix };
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    if (input.selector == .search) return null;
    const normalization = classifyHandleNormalization(input.handle);
    if (normalization.trimmed.len == 0) return try ctx.allocator.dupe(u8, "read_tool_result field \"handle\" must not be empty");
    var record_buffer: compactor.RecordFileBuffer = undefined;
    if (compactor.recordFile(&record_buffer, normalization.trimmed)) |file| {
        // A turn, tool call or earlier compaction saved by compaction, opened
        // by its ID (M12, T12, L2).
        const owned = try ctx.allocator.dupe(u8, file);
        ctx.allocator.free(input.handle);
        input.handle = owned;
        return null;
    }
    if (normalization.suffix.len > 0 or !std.mem.eql(u8, input.handle, normalization.trimmed)) {
        const owned = try std.mem.concat(ctx.allocator, u8, &.{ normalization.trimmed, normalization.suffix });
        ctx.allocator.free(input.handle);
        input.handle = owned;
    }
    return null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    if (input.selector == .search) {
        const capability = ctx.session_child_capability orelse return .{
            .failure = try ctx.allocator.dupe(u8, "Nothing is saved: this session has no tool-result store."),
        };
        const queries: []const []const u8 = input.selector.search;
        const output = compactor.search(ctx.allocator, result_store.compactorStore(capability), queries) catch |err| return .{
            .failure = try ctx.allocator.print("Searching saved turns, tool calls and earlier compactions failed: {s}", .{@errorName(err)}),
        };
        return .{ .success = output };
    }
    if (result_store.isImageHandle(input.handle)) {
        const capability = ctx.session_child_capability orelse return .{
            .failure = try ctx.allocator.dupe(u8, "No active session image store is available."),
        };
        if (input.selector == .query or input.selector.range.start_byte != 1) return .{
            .failure = try ctx.allocator.dupe(u8, "Stored images are read as complete images. Use the handle without a query or byte offset."),
        };
        const images = result_store.loadToolImages(ctx.allocator, capability, input.handle) catch |err| return .{
            .failure = try formatReadFailure(ctx.allocator, input.handle, err),
        };
        errdefer @import("../../core/shared/types.zig").freeToolImages(ctx.allocator, images);
        return .{ .rich = .{
            .text = try ctx.allocator.dupe(u8, "Stored tool images attached to this result. They are sent to the model with your next request when this model accepts image input; when they cannot be sent, that request notes why and what to do instead."),
            .images = images,
            .is_error = false,
        } };
    }
    if (ctx.session_child_capability == null and
        ctx.ephemeral_command_replay == null and
        ctx.tool_result_dir == null)
    {
        return .{ .failure = try ctx.allocator.dupe(u8, "No active session tool-result store is available.") };
    }

    const output = readOutput(ctx, input) catch |err| {
        return .{ .failure = try formatReadFailure(ctx.allocator, input.handle, err) };
    };
    return .{ .success = output };
}

fn readOutput(ctx: tool_dispatch.DispatchContext, input: *Input) ![]u8 {
    if (ctx.session_child_capability) |capability| {
        const ordinary = switch (input.selector) {
            .query => |query| result_store.searchByQueryManaged(ctx.allocator, capability, input.handle, query),
            .range => |range| result_store.readByRangeManaged(ctx.allocator, capability, input.handle, range.start_byte, range.byte_count),
            .search => unreachable,
        };
        return ordinary catch |err| switch (err) {
            error.ResultHandleNotFound => switch (input.selector) {
                .query => |query| command_replay_store.searchAgentQueryManaged(
                    ctx.allocator,
                    capability,
                    input.handle,
                    query,
                    result_store.read_max_bytes,
                ),
                .range => |range| command_replay_store.readAgentPageManaged(
                    ctx.allocator,
                    capability,
                    input.handle,
                    range.start_byte,
                    range.byte_count,
                ),
                .search => unreachable,
            },
            else => return err,
        };
    }

    if (ctx.ephemeral_command_replay) |store| {
        return switch (input.selector) {
            .query => |query| command_replay_store.searchAgentQueryEphemeral(
                ctx.allocator,
                store,
                input.handle,
                query,
                result_store.read_max_bytes,
            ),
            .range => |range| command_replay_store.readAgentPageEphemeral(
                ctx.allocator,
                store,
                input.handle,
                range.start_byte,
                range.byte_count,
            ),
            .search => unreachable,
        };
    }

    const dir = ctx.tool_result_dir.?;
    return switch (input.selector) {
        .query => |query| result_store.searchByQuery(ctx.allocator, dir, input.handle, query),
        .range => |range| result_store.readByRange(ctx.allocator, dir, input.handle, range.start_byte, range.byte_count),
        .search => unreachable,
    };
}

fn formatReadFailure(alloc: Allocator, handle: []const u8, err: anyerror) ![]u8 {
    if (err == error.ResultHandleNotFound) {
        return alloc.print(
            "read_tool_result failed for handle {s}: ResultHandleNotFound. No exact match exists in the active tool-result store; handles are session-scoped and must be copied exactly from the tool result preview.",
            .{handle},
        );
    }
    return alloc.print("read_tool_result failed for handle {s}: {s}", .{ handle, @errorName(err) });
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "read_tool_result decodes range and query inputs" {
    const alloc = std.testing.allocator;
    const decoded_range = try decode(.{ .allocator = alloc }, "{\"handle\":\"h.txt\",\"start_byte\":2,\"byte_count\":9}");
    const range_input = switch (decoded_range) {
        .input => |value| value,
        .failure => return error.TestUnexpectedDecodeFailure,
    };
    defer range_input.deinit(alloc);
    const typed_range = range_input.as(Input);
    switch (typed_range.selector) {
        .range => |range| {
            try std.testing.expectEqual(@as(usize, 2), range.start_byte);
            try std.testing.expectEqual(@as(usize, 9), range.byte_count);
        },
        .query => return error.TestUnexpectedDecodeFailure,
        .search => return error.TestUnexpectedDecodeFailure,
    }

    const decoded_query = try decode(.{ .allocator = alloc }, "{\"handle\":\"h.txt\",\"query\":\"needle\"}");
    const query_input = switch (decoded_query) {
        .input => |value| value,
        .failure => return error.TestUnexpectedDecodeFailure,
    };
    defer query_input.deinit(alloc);
    const typed_query = query_input.as(Input);
    try std.testing.expectEqualStrings("h.txt", typed_query.handle);
    switch (typed_query.selector) {
        .query => |query| try std.testing.expectEqualStrings("needle", query),
        .range => return error.TestUnexpectedDecodeFailure,
        .search => return error.TestUnexpectedDecodeFailure,
    }
}

test "read_tool_result decodes nested model requests" {
    const alloc = std.testing.allocator;
    const decoded = try decode(
        .{ .allocator = alloc },
        "{\"request\":{\"handle\":\"h.txt\",\"query\":\"needle\"}}",
    );
    const input = switch (decoded) {
        .input => |value| value,
        .failure => return error.TestUnexpectedDecodeFailure,
    };
    defer input.deinit(alloc);
    const typed = input.as(Input);
    try std.testing.expectEqualStrings("h.txt", typed.handle);
    switch (typed.selector) {
        .query => |query| try std.testing.expectEqualStrings("needle", query),
        .range => return error.TestUnexpectedDecodeFailure,
        .search => return error.TestUnexpectedDecodeFailure,
    }
}

test "read_tool_result treats exact empty legacy query as range" {
    const alloc = std.testing.allocator;
    const decoded = try decode(
        .{ .allocator = alloc },
        "{\"handle\":\"h.txt\",\"start_byte\":2,\"byte_count\":9,\"query\":\"\"}",
    );
    const input = switch (decoded) {
        .input => |value| value,
        .failure => return error.TestUnexpectedDecodeFailure,
    };
    defer input.deinit(alloc);
    const typed = input.as(Input);
    switch (typed.selector) {
        .range => |range| {
            try std.testing.expectEqual(@as(usize, 2), range.start_byte);
            try std.testing.expectEqual(@as(usize, 9), range.byte_count);
        },
        .query => return error.TestUnexpectedDecodeFailure,
        .search => return error.TestUnexpectedDecodeFailure,
    }
}

test "read_tool_result admission restores only omitted stored-result suffixes" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        arguments_json: []const u8,
        expected_handle: []const u8,
    }{
        .{
            .arguments_json = "{\"handle\":\"result-web_fetch-1705079ba6e278c4-553514ccf082aeb9\"}",
            .expected_handle = "result-web_fetch-1705079ba6e278c4-553514ccf082aeb9.txt",
        },
        .{
            .arguments_json = "{\"handle\":\"result-web_fetch-1705079ba6e278c4-553514ccf082aeb9.txt\"}",
            .expected_handle = "result-web_fetch-1705079ba6e278c4-553514ccf082aeb9.txt",
        },
        .{
            .arguments_json = "{\"handle\":\"fx-command-replay-canonical.bin\"}",
            .expected_handle = "fx-command-replay-canonical.bin",
        },
        .{
            .arguments_json = "{\"handle\":\"unknown-dogfood-handle\"}",
            .expected_handle = "unknown-dogfood-handle",
        },
    };

    for (cases) |case| {
        const decoded = try decode(.{ .allocator = alloc }, case.arguments_json);
        const input = switch (decoded) {
            .input => |value| value,
            .failure => return error.TestUnexpectedDecodeFailure,
        };
        defer input.deinit(alloc);
        if (try validate(.{ .allocator = alloc }, input)) |failure| {
            defer alloc.free(failure);
            return error.TestUnexpectedDecodeFailure;
        }
        try std.testing.expectEqualStrings(case.expected_handle, input.as(Input).handle);
    }
}

test "read_tool_result admission treats an empty query as a range read" {
    const alloc = std.testing.allocator;
    const decoded = try decode(
        .{ .allocator = alloc },
        "{\"handle\":\"result-read_file-1705079ba6e278c4-553514ccf082aeb9.txt\",\"start_byte\":2,\"byte_count\":9,\"query\":\"\"}",
    );
    const input = switch (decoded) {
        .input => |value| value,
        .failure => return error.TestUnexpectedDecodeFailure,
    };
    defer input.deinit(alloc);
    try std.testing.expect((try validate(.{ .allocator = alloc }, input)) == null);
    const typed = input.as(Input);
    switch (typed.selector) {
        .range => |range| {
            try std.testing.expectEqual(@as(usize, 2), range.start_byte);
            try std.testing.expectEqual(@as(usize, 9), range.byte_count);
        },
        .query => return error.TestUnexpectedQuery,
        .search => return error.TestUnexpectedQuery,
    }
}

test "unknown read_tool_result handle returns failure for legacy and managed stores" {
    const alloc = std.testing.allocator;
    const expected = "read_tool_result failed for handle unknown-dogfood-handle: ResultHandleNotFound. No exact match exists in the active tool-result store; handles are session-scoped and must be copied exactly from the tool result preview.";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "legacy",
        std.Io.File.Permissions.fromMode(0o700),
    );
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "legacy");
    defer alloc.free(dir);

    const legacy_decoded = try decode(.{ .allocator = alloc }, "{\"handle\":\"unknown-dogfood-handle\",\"start_byte\":1,\"byte_count\":64}");
    const legacy_input = switch (legacy_decoded) {
        .input => |value| value,
        .failure => return error.TestUnexpectedDecodeFailure,
    };
    defer legacy_input.deinit(alloc);
    const legacy_result = try call(.{ .allocator = alloc, .tool_result_dir = dir }, legacy_input);
    defer legacy_result.deinit(alloc);
    switch (legacy_result) {
        .rich => return error.TestUnexpectedRichResult,
        .failure => |body| try std.testing.expectEqualStrings(expected, body),
        .success => return error.TestExpectedFailure,
    }

    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .read_only,
        .{},
    );
    defer capability.deinit();

    const managed_decoded = try decode(.{ .allocator = alloc }, "{\"handle\":\"unknown-dogfood-handle\",\"start_byte\":1,\"byte_count\":64}");
    const managed_input = switch (managed_decoded) {
        .input => |value| value,
        .failure => return error.TestUnexpectedDecodeFailure,
    };
    defer managed_input.deinit(alloc);
    const managed_result = try call(.{ .allocator = alloc, .session_child_capability = &capability }, managed_input);
    defer managed_result.deinit(alloc);
    switch (managed_result) {
        .rich => return error.TestUnexpectedRichResult,
        .failure => |body| try std.testing.expectEqualStrings(expected, body),
        .success => return error.TestExpectedFailure,
    }
}

test "read_tool_result pages and searches saved command replay handles" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const session_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(session_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{},
    );
    defer capability.deinit();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const capture = try command_replay_store.Capture.create(arena, 64 * 1024, &capability);
    try capture.appendAcceptedRequired(arena, .stdout, "TOKEN=secret-value\nneedle tail\n");
    const descriptor = (try capture.retainRequired(arena)) orelse
        return error.TestExpectedReplay;
    defer capture.releaseRetained(arena);

    var page_input = Input{
        .handle = try alloc.dupe(u8, descriptor.handle),
        .selector = .{ .range = .{
            .start_byte = 1,
            .byte_count = 4096,
        } },
    };
    defer page_input.deinit(alloc);
    const page = try readOutput(.{
        .allocator = alloc,
        .session_child_capability = &capability,
    }, &page_input);
    defer alloc.free(page);
    try std.testing.expect(std.mem.find(u8, page, "[stdout]") != null);
    try std.testing.expect(std.mem.find(u8, page, "TOKEN=secret-value") != null);
    try std.testing.expect(std.mem.find(u8, page, "[redacted]") == null);
    try std.testing.expect(std.mem.find(u8, page, "needle tail") != null);

    var query_input = Input{
        .handle = try alloc.dupe(u8, descriptor.handle),
        .selector = .{ .query = try alloc.dupe(u8, "needle") },
    };
    defer query_input.deinit(alloc);
    const query = try readOutput(.{
        .allocator = alloc,
        .session_child_capability = &capability,
    }, &query_input);
    defer alloc.free(query);
    try std.testing.expect(std.mem.find(u8, query, "needle tail") != null);
}

test "large web_search result is previewed and available through read_tool_result" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try @import("../../core/shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);
    try output.appendSlice(alloc, "search preview\nneedle from full search result\n");
    try output.appendNTimes(alloc, 'x', result_store.large_result_threshold_bytes + 64);

    const prepared = try result_store.prepare(alloc, dir, "call_search", "web_search", output.items.len, output.items, 1024);
    defer alloc.free(@constCast(prepared.model_output));
    defer alloc.free(@constCast(prepared.memory.output_handle.?));
    defer alloc.free(@constCast(prepared.memory.preview.?));
    try std.testing.expect(std.mem.find(u8, prepared.model_output, "<tool_result_preview") != null);
    try std.testing.expect(std.mem.find(u8, prepared.model_output, "Use read_tool_result") != null);

    const args_json = try alloc.print("{{\"handle\":\"{s}\",\"query\":\"needle\"}}", .{prepared.memory.output_handle.?});
    defer alloc.free(args_json);
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    const input = switch (decoded) {
        .input => |value| value,
        .failure => return error.TestUnexpectedDecodeFailure,
    };
    defer input.deinit(alloc);
    if (try validate(.{ .allocator = alloc }, input)) |failure| {
        defer alloc.free(failure);
        return error.TestUnexpectedDecodeFailure;
    }
    const result = try call(.{ .allocator = alloc, .tool_result_dir = dir }, input);
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, result.success, "needle from full search result") != null);
}

test "persisted provider search results remain readable" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try @import("../../core/shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);

    const handle = try result_store.storeLargeResult(alloc, dir, "legacy_provider_call", "perplexity_search", "historical provider search result");
    defer alloc.free(handle);

    const args_json = try alloc.print("{{\"handle\":\"{s}\"}}", .{handle});
    defer alloc.free(args_json);
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    const input = switch (decoded) {
        .input => |value| value,
        .failure => return error.TestUnexpectedDecodeFailure,
    };
    defer input.deinit(alloc);

    const result = try call(.{ .allocator = alloc, .tool_result_dir = dir }, input);
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, result.success, "historical provider search result") != null);
}

test "read_tool_result opens and searches turns and tool calls saved by compaction" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(alloc, dir, .tool_results, .writable);
    defer capability.deinit();
    const saved = [_]struct { []const u8, []const u8 }{
        .{ "T12", "T12 shell: zig build test\nCall ID: c12\n\nResult:\nall tests passed\n" },
        .{ "M3", "M3 turn: run the tests\nUser 3:\nrun the tests\n\nAssistant, final reply:\nThey pass.\n" },
    };
    for (saved) |record| {
        const id, const content = record;
        var name: compactor.RecordFileBuffer = undefined;
        var entry = try capability.atomicReplace(alloc, .tool_results, compactor.recordFile(&name, id).?, content);
        entry.deinit(alloc);
    }
    const ctx: tool_dispatch.DispatchContext = .{ .allocator = alloc, .session_child_capability = &capability };
    const requests = [_]struct { []const u8, []const u8 }{
        .{ "{\"request\":{\"handle\":\"T12\"}}", "T12" },
        .{ "{\"request\":{\"handle\":\"t12\",\"query\":\"passed\"}}", "all tests passed" },
        .{ "{\"request\":{\"handle\":\"M3\"}}", "They pass." },
        .{ "{\"request\":{\"search\":[\"zig build\",\"missing phrase\"]}}", "[1] T12 shell" },
        .{ "{\"request\":{\"search\":\"run the tests\"}}", "[1] M3 turn" },
    };
    for (requests) |request| {
        const args, const expected = request;
        const decoded = try decode(ctx, args);
        const input = switch (decoded) {
            .input => |value| value,
            .failure => |text| {
                alloc.free(text);
                return error.TestUnexpectedDecodeFailure;
            },
        };
        defer input.deinit(alloc);
        if (try validate(ctx, input)) |text| {
            alloc.free(text);
            return error.TestUnexpectedValidationFailure;
        }
        const result = try call(ctx, input);
        defer result.deinit(alloc);
        switch (result) {
            .success => |text| try std.testing.expect(std.mem.find(u8, text, expected) != null),
            else => return error.TestUnexpectedResult,
        }
    }
    for ([_][]const u8{
        "{\"request\":{\"search\":[\"a\",\"b\",\"c\",\"d\"]}}",
        "{\"request\":{\"search\":[]}}",
        "{\"request\":{\"search\":[\" \"]}}",
    }) |args| switch (try decode(ctx, args)) {
        .failure => |text| alloc.free(text),
        .input => |value| {
            value.deinit(alloc);
            return error.TestExpectedDecodeFailure;
        },
    };
}
