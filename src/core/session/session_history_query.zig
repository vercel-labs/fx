const std = @import("std");
const lexical_relevance = @import("../shared/lexical_relevance.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const session = @import("session.zig");
const session_codec = @import("session_codec.zig");
const session_history_provider = @import("session_history_provider.zig");
const session_store = @import("session_store.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const max_sessions_scanned: usize = session_store.session_list_max_limit;
const max_turns_scanned: usize = 10_000;
const max_searchable_bytes: usize = 2 * 1024 * 1024;
const max_excerpt_bytes: usize = 320;
const reference_prefix = "fxhr1";

const Match = struct {
    reference: []u8,
    session_id: []u8,
    relation: Relation,
    excerpt: []u8,
    score: lexical_relevance.Score,

    fn deinit(self: *Match, alloc: Allocator) void {
        alloc.free(self.reference);
        alloc.free(self.session_id);
        alloc.free(self.excerpt);
        self.* = undefined;
    }
};

const Ranked = struct {
    matches: [session_history_provider.max_search_results]Match = undefined,
    count: usize = 0,
    truncated: bool = false,

    fn deinit(self: *Ranked, alloc: Allocator) void {
        for (self.matches[0..self.count]) |*match| match.deinit(alloc);
        self.* = .{};
    }

    fn accepts(self: *Ranked, score: lexical_relevance.Score, limit: usize) bool {
        if (self.count < limit) return true;
        self.truncated = true;
        return lexical_relevance.order(score, self.matches[limit - 1].score) == .gt;
    }

    fn insert(self: *Ranked, alloc: Allocator, candidate: Match, limit: usize) void {
        var insertion_index: usize = 0;
        while (insertion_index < self.count and
            lexical_relevance.order(candidate.score, self.matches[insertion_index].score) != .gt)
        {
            insertion_index += 1;
        }

        if (self.count < limit) {
            var move_index = self.count;
            while (move_index > insertion_index) : (move_index -= 1) {
                self.matches[move_index] = self.matches[move_index - 1];
            }
            self.matches[insertion_index] = candidate;
            self.count += 1;
            return;
        }

        self.matches[limit - 1].deinit(alloc);
        var move_index = limit - 1;
        while (move_index > insertion_index) : (move_index -= 1) {
            self.matches[move_index] = self.matches[move_index - 1];
        }
        self.matches[insertion_index] = candidate;
    }
};

const ScoredMatch = struct {
    excerpt_source: []const u8,
    score: lexical_relevance.Score,
};

const Relation = enum {
    current,
    other,
};

pub fn searchAlloc(
    alloc: Allocator,
    scratch_alloc: Allocator,
    store: *const session_store.Store,
    current_session_id: ?[]const u8,
    query_text: []const u8,
    limit: usize,
) ![]u8 {
    if (limit == 0 or limit > session_history_provider.max_search_results) return error.InvalidSearchLimit;
    if (query_text.len > session_history_provider.max_search_query_bytes) return error.QueryTooLong;
    const trimmed_query = std.mem.trim(u8, query_text, " \t\r\n");
    if (trimmed_query.len == 0) return error.EmptyQuery;
    const query = try lexical_relevance.prepare(trimmed_query);

    var page = try store.listSessionPage(
        scratch_alloc,
        .current_workspace,
        null,
        max_sessions_scanned,
    );
    defer page.deinit(scratch_alloc);

    var state_arena = std.heap.ArenaAllocator.init(scratch_alloc);
    defer state_arena.deinit();

    var ranked = Ranked{};
    defer ranked.deinit(alloc);
    var turns_scanned: usize = 0;
    var searchable_bytes: usize = 0;
    var scan_truncated = page.has_more or page.skipped_invalid != 0;

    for (page.summaries.items) |summary| {
        if (turns_scanned >= max_turns_scanned) {
            scan_truncated = true;
            break;
        }
        scan_session: {
            defer _ = state_arena.reset(.retain_capacity);
            const state_alloc = state_arena.allocator();
            var state = store.loadReadOnly(state_alloc, summary.id) catch {
                scan_truncated = true;
                break :scan_session;
            };
            defer state.deinit(state_alloc);
            if (!std.mem.eql(u8, state.workspace_root, store.workspace_root)) {
                scan_truncated = true;
                break :scan_session;
            }
            const relation = relationFor(current_session_id, state.id);

            var reverse_index = state.history.len;
            while (reverse_index > 0) {
                reverse_index -= 1;
                if (turns_scanned >= max_turns_scanned) {
                    scan_truncated = true;
                    break;
                }
                turns_scanned += 1;
                const turn = state.history[reverse_index];
                if (turn == .compacted_summary) continue;
                const turn_bytes = turnSearchBytes(turn);
                if (turn_bytes > max_searchable_bytes - searchable_bytes) {
                    scan_truncated = true;
                    continue;
                }
                searchable_bytes += turn_bytes;
                const scored = scoreTurn(
                    &query,
                    state.id,
                    turn,
                ) orelse continue;
                if (!ranked.accepts(scored.score, limit)) continue;
                const candidate = try materializeMatch(
                    alloc,
                    scored,
                    store.workspace_root,
                    state.id,
                    reverse_index,
                    turn,
                    relation,
                    query.raw,
                );
                ranked.insert(alloc, candidate, limit);
            }
        }
    }

    return renderSearch(
        alloc,
        &ranked,
        scan_truncated,
    );
}

pub fn readAlloc(
    alloc: Allocator,
    scratch_alloc: Allocator,
    store: *const session_store.Store,
    current_session_id: ?[]const u8,
    reference: []const u8,
    include_execution: bool,
) ![]u8 {
    const parsed = try parseReference(reference);
    var state_arena = std.heap.ArenaAllocator.init(scratch_alloc);
    defer state_arena.deinit();
    const state_alloc = state_arena.allocator();
    var state = store.loadReadOnly(state_alloc, parsed.session_id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.HistoryReferenceUnavailable,
    };
    defer state.deinit(state_alloc);
    if (!std.mem.eql(u8, state.workspace_root, store.workspace_root)) {
        return error.HistoryReferenceUnavailable;
    }
    if (parsed.turn_index >= state.history.len) return error.HistoryReferenceUnavailable;
    const turn = state.history[parsed.turn_index];
    if (turn == .compacted_summary) return error.HistoryReferenceUnavailable;
    const expected = try referenceAlloc(
        state_alloc,
        store.workspace_root,
        state.id,
        parsed.turn_index,
        turn,
    );
    defer state_alloc.free(expected);
    if (!std.mem.eql(u8, reference, expected)) return error.HistoryReferenceUnavailable;

    return renderRecord(
        alloc,
        state.id,
        relationFor(current_session_id, state.id),
        turn,
        include_execution,
    );
}

fn relationFor(current_session_id: ?[]const u8, session_id: []const u8) Relation {
    const current = current_session_id orelse return .other;
    return if (std.mem.eql(u8, current, session_id)) .current else .other;
}

fn scoreTurn(
    query: *const lexical_relevance.PreparedQuery,
    session_id: []const u8,
    turn: session.HistoryTurn,
) ?ScoredMatch {
    const user = turnUser(turn);
    var relevance = lexical_relevance.ScoreAccumulator.init(query, &.{session_id});
    var excerpt_source: ?[]const u8 = null;

    if (relevance.add_strong_field(query, user)) {
        excerpt_source = user;
    }
    if (turnAssistant(turn)) |assistant| {
        if (relevance.add_strong_field(query, assistant)) {
            if (excerpt_source == null) excerpt_source = assistant;
        }
    }
    const execution = turnExecution(turn);
    for (execution.tool_steps) |step| {
        if (step.assistant) |assistant| {
            if (relevance.add_strong_field(query, assistant)) {
                if (excerpt_source == null) excerpt_source = assistant;
            }
        }
        for (step.tool_calls) |call| {
            if (relevance.add_weak_field(query, call.name)) {
                if (excerpt_source == null) excerpt_source = call.name;
            }
            if (relevance.add_weak_field(query, call.arguments_json)) {
                if (excerpt_source == null) excerpt_source = call.arguments_json;
            }
        }
        for (step.tool_results) |result| {
            if (relevance.add_weak_field(query, result.tool_name)) {
                if (excerpt_source == null) excerpt_source = result.tool_name;
            }
            if (result.preview) |preview| {
                if (relevance.add_weak_field(query, preview)) {
                    if (excerpt_source == null) excerpt_source = preview;
                }
            }
        }
    }
    for (execution.files) |file| {
        if (relevance.add_weak_field(query, file.path)) {
            if (excerpt_source == null) excerpt_source = file.path;
        }
        if (file.new_path) |new_path| {
            if (relevance.add_weak_field(query, new_path)) {
                if (excerpt_source == null) excerpt_source = new_path;
            }
        }
    }
    const score = relevance.finish(query) orelse return null;
    return .{ .excerpt_source = excerpt_source orelse user, .score = score };
}

fn materializeMatch(
    result_alloc: Allocator,
    scored: ScoredMatch,
    workspace_root: []const u8,
    session_id: []const u8,
    turn_index: usize,
    turn: session.HistoryTurn,
    relation: Relation,
    raw_query: []const u8,
) !Match {
    const reference = try referenceAlloc(
        result_alloc,
        workspace_root,
        session_id,
        turn_index,
        turn,
    );
    errdefer result_alloc.free(reference);
    const owned_session_id = try result_alloc.dupe(u8, session_id);
    errdefer result_alloc.free(owned_session_id);
    const excerpt = try excerptAlloc(result_alloc, scored.excerpt_source, raw_query);

    return .{
        .reference = reference,
        .session_id = owned_session_id,
        .relation = relation,
        .excerpt = excerpt,
        .score = scored.score,
    };
}

fn turnUser(turn: session.HistoryTurn) []const u8 {
    return switch (turn) {
        .assistant => |entry| entry.user.text,
        .background_command => |entry| entry.user.text,
        .interrupted => |entry| entry.user.text,
        .compacted_summary => "",
    };
}

fn turnAssistant(turn: session.HistoryTurn) ?[]const u8 {
    return switch (turn) {
        .assistant => |entry| entry.assistant,
        .background_command => |entry| entry.assistant,
        .interrupted => |entry| entry.assistant,
        .compacted_summary => null,
    };
}

fn turnExecution(turn: session.HistoryTurn) types.ExecutionMemory {
    return switch (turn) {
        .assistant => |entry| entry.execution,
        .background_command => |entry| entry.execution,
        .interrupted => |entry| entry.execution,
        .compacted_summary => .{},
    };
}

fn turnSearchBytes(turn: session.HistoryTurn) usize {
    var total = turnUser(turn).len;
    if (turnAssistant(turn)) |assistant| total +|= assistant.len;
    const execution = turnExecution(turn);
    for (execution.tool_steps) |step| {
        if (step.assistant) |assistant| total +|= assistant.len;
        for (step.tool_calls) |call| {
            total +|= call.name.len;
            total +|= call.arguments_json.len;
        }
        for (step.tool_results) |result| {
            total +|= result.tool_name.len;
            if (result.preview) |preview| total +|= preview.len;
        }
    }
    for (execution.files) |file| {
        total +|= file.path.len;
        if (file.new_path) |new_path| total +|= new_path.len;
    }
    return total;
}

fn excerptAlloc(alloc: Allocator, text: []const u8, raw_query: []const u8) ![]u8 {
    if (text.len <= max_excerpt_bytes) return alloc.dupe(u8, text);
    const match_start = findIgnoreCase(text, raw_query) orelse 0;
    const half = max_excerpt_bytes / 2;
    var start = match_start -| half;
    if (start + max_excerpt_bytes > text.len) start = text.len - max_excerpt_bytes;
    start = text_utils.utf8ForwardBoundary(text, start);
    const end = text_utils.utf8BackwardBoundary(
        text,
        @min(text.len, start + max_excerpt_bytes),
    );
    const leading: usize = if (start > 0) 3 else 0;
    const trailing: usize = if (end < text.len) 3 else 0;
    const result = try alloc.alloc(u8, leading + end - start + trailing);
    var offset: usize = 0;
    if (leading != 0) {
        @memcpy(result[0..3], "...");
        offset = 3;
    }
    @memcpy(result[offset..][0 .. end - start], text[start..end]);
    offset += end - start;
    if (trailing != 0) @memcpy(result[offset..][0..3], "...");
    return result;
}

fn findIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var index: usize = 0;
    while (index <= haystack.len - needle.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    }
    return null;
}

const ParsedReference = struct {
    session_id: []const u8,
    turn_index: usize,
};

fn parseReference(reference: []const u8) !ParsedReference {
    if (reference.len == 0 or reference.len > session_history_provider.max_read_reference_bytes)
        return error.InvalidHistoryReference;
    var fields = std.mem.splitScalar(u8, reference, ':');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidHistoryReference, reference_prefix)) {
        return error.InvalidHistoryReference;
    }
    const session_id = fields.next() orelse return error.InvalidHistoryReference;
    const turn_index = std.fmt.parseInt(
        usize,
        fields.next() orelse return error.InvalidHistoryReference,
        10,
    ) catch return error.InvalidHistoryReference;
    const digest = fields.next() orelse return error.InvalidHistoryReference;
    if (fields.next() != null or digest.len != 64) return error.InvalidHistoryReference;
    session_store.validateSessionId(session_id) catch return error.InvalidHistoryReference;
    for (digest) |byte| {
        if (!std.ascii.isHex(byte)) return error.InvalidHistoryReference;
    }
    return .{ .session_id = session_id, .turn_index = turn_index };
}

fn referenceAlloc(
    alloc: Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    turn_index: usize,
    turn: session.HistoryTurn,
) ![]u8 {
    var buffer: [512]u8 = undefined;
    var hashing: std.Io.Writer.Hashing(std.crypto.hash.sha2.Sha256) = .init(&buffer);
    try hashing.writer.writeAll("fx.session-history-reference.v1\x00");
    try hashing.writer.writeAll(workspace_root);
    try hashing.writer.writeByte(0);
    try hashing.writer.writeAll(session_id);
    try hashing.writer.writeByte(0);
    try hashing.writer.print("{d}", .{turn_index});
    try hashing.writer.writeByte(0);
    try session_codec.writeHistoryTurn(&hashing.writer, turn);
    try hashing.writer.flush();
    const digest = std.fmt.bytesToHex(hashing.hasher.finalResult(), .lower);
    return std.fmt.allocPrint(
        alloc,
        "{s}:{s}:{d}:{s}",
        .{ reference_prefix, session_id, turn_index, &digest },
    );
}

fn renderSearch(
    alloc: Allocator,
    ranked: *const Ranked,
    scan_truncated: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"kind\":\"session_history_search\",\"workspace_scope\":\"same_project\",\"content_authority\":\"untrusted_historical_context\",\"hits\":[");
    for (ranked.matches[0..ranked.count], 0..) |match, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"reference\":");
        try std.json.Stringify.value(match.reference, .{}, &out.writer);
        try out.writer.writeAll(",\"session_id\":");
        try std.json.Stringify.value(match.session_id, .{}, &out.writer);
        try out.writer.writeAll(",\"session_relation\":");
        try std.json.Stringify.value(@tagName(match.relation), .{}, &out.writer);
        try out.writer.writeAll(",\"excerpt\":");
        try std.json.Stringify.value(match.excerpt, .{}, &out.writer);
        try out.writer.writeByte('}');
    }
    try out.writer.print(
        "],\"truncated\":{s}",
        .{
            if (ranked.truncated or scan_truncated) "true" else "false",
        },
    );
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn renderRecord(
    alloc: Allocator,
    session_id: []const u8,
    relation: Relation,
    turn: session.HistoryTurn,
    include_execution: bool,
) ![]u8 {
    const execution = turnExecution(turn);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"kind\":\"session_history_record\",\"workspace_scope\":\"same_project\",\"content_authority\":\"untrusted_historical_context\",\"session_id\":");
    try std.json.Stringify.value(session_id, .{}, &out.writer);
    try out.writer.writeAll(",\"session_relation\":");
    try std.json.Stringify.value(@tagName(relation), .{}, &out.writer);
    try out.writer.writeAll(",\"turn_kind\":");
    try std.json.Stringify.value(@tagName(turn), .{}, &out.writer);
    try out.writer.writeAll(",\"conversation\":{\"user\":");
    try std.json.Stringify.value(turnUser(turn), .{}, &out.writer);
    try out.writer.writeAll(",\"assistant\":");
    try std.json.Stringify.value(turnAssistant(turn), .{}, &out.writer);
    try out.writer.writeByte('}');
    if (include_execution) {
        var evidence = execution;
        evidence.turn_summary = null;
        try out.writer.writeAll(",\"execution\":");
        try session_codec.writeExecutionMemory(&out.writer, evidence);
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

test "session history references bind workspace session index and content" {
    const turn: session.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("remember the blue deployment") },
        .assistant = @constCast("I will keep the deployment blue."),
    } };
    const first = try referenceAlloc(std.testing.allocator, "/workspace/a", "session.one", 3, turn);
    defer std.testing.allocator.free(first);
    const same = try referenceAlloc(std.testing.allocator, "/workspace/a", "session.one", 3, turn);
    defer std.testing.allocator.free(same);
    const other_workspace = try referenceAlloc(std.testing.allocator, "/workspace/b", "session.one", 3, turn);
    defer std.testing.allocator.free(other_workspace);

    try std.testing.expectEqualStrings(first, same);
    try std.testing.expect(!std.mem.eql(u8, first, other_workspace));
    const parsed = try parseReference(first);
    try std.testing.expectEqualStrings("session.one", parsed.session_id);
    try std.testing.expectEqual(@as(usize, 3), parsed.turn_index);
}

test "session history relation is computed from the host session id" {
    try std.testing.expectEqual(Relation.current, relationFor("active", "active"));
    try std.testing.expectEqual(Relation.other, relationFor("active", "older"));
    try std.testing.expectEqual(Relation.other, relationFor(null, "older"));
}

fn testState(
    alloc: Allocator,
    id: []const u8,
    workspace_root: []const u8,
    updated_at_ms: i64,
    user_text: []const u8,
    assistant_text: []const u8,
) !session_codec.DurableSessionState {
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const origin = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(origin);
    const workspace = try alloc.dupe(u8, workspace_root);
    errdefer alloc.free(workspace);
    const model = try alloc.dupe(u8, "test/model");
    errdefer alloc.free(model);
    const history = try alloc.alloc(session.HistoryTurn, 1);
    errdefer alloc.free(history);
    const user = try alloc.dupe(u8, user_text);
    errdefer alloc.free(user);
    const assistant = try alloc.dupe(u8, assistant_text);
    errdefer alloc.free(assistant);
    history[0] = .{ .assistant = .{
        .user = .{ .text = user },
        .assistant = assistant,
    } };
    return .{
        .id = owned_id,
        .origin_workspace_root = origin,
        .workspace_root = workspace,
        .created_at_ms = updated_at_ms,
        .updated_at_ms = updated_at_ms,
        .conversation_language = session.ConversationLanguage.literal("en"),
        .preferences = .{
            .model = model,
            .effort = types.ReasoningEffort.literal("medium"),
            .fast_mode = false,
        },
        .history = history,
        .total_input_tokens = 0,
        .total_output_tokens = 0,
    };
}

test "session history search and read expose current versus other within one workspace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "project-a");
    try tmp.dir.createDirPath(io_mod.getIo(), "project-b");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const project_a = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "project-a");
    defer alloc.free(project_a);
    const project_b = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "project-b");
    defer alloc.free(project_b);

    var store_a = try session_store.Store.initFromHome(alloc, home, project_a);
    defer store_a.deinit(alloc);
    var store_b = try session_store.Store.initFromHome(alloc, home, project_b);
    defer store_b.deinit(alloc);

    var current = try testState(alloc, "current-session", project_a, 30, "Use cobalt for the deploy", "Cobalt is selected.");
    defer current.deinit(alloc);
    var older = try testState(alloc, "older-session", project_a, 20, "Did we choose cobalt?", "Yes, keep cobalt.");
    defer older.deinit(alloc);
    var outside = try testState(alloc, "outside-session", project_b, 40, "Cobalt belongs elsewhere", "Do not expose it.");
    defer outside.deinit(alloc);
    var current_writer = try store_a.startWritableSession(alloc, current);
    _ = try current_writer.commitStateReplacement(
        alloc,
        current,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    current_writer.deinit(alloc);
    var older_writer = try store_a.startWritableSession(alloc, older);
    _ = try older_writer.commitStateReplacement(
        alloc,
        older,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    older_writer.deinit(alloc);
    var outside_writer = try store_b.startWritableSession(alloc, outside);
    _ = try outside_writer.commitStateReplacement(
        alloc,
        outside,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    outside_writer.deinit(alloc);

    const search = try searchAlloc(alloc, alloc, &store_a, "current-session", "cobalt", 10);
    defer alloc.free(search);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, search, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("truncated").?.bool);
    const hits = parsed.value.object.get("hits").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    var saw_current = false;
    var other_reference: ?[]const u8 = null;
    for (hits) |hit| {
        const object = hit.object;
        const id = object.get("session_id").?.string;
        const relation = object.get("session_relation").?.string;
        try std.testing.expect(!std.mem.eql(u8, id, "outside-session"));
        if (std.mem.eql(u8, id, "current-session")) {
            saw_current = std.mem.eql(u8, relation, "current");
        } else if (std.mem.eql(u8, id, "older-session")) {
            try std.testing.expectEqualStrings("other", relation);
            other_reference = object.get("reference").?.string;
        }
    }
    try std.testing.expect(saw_current);
    const record = try readAlloc(
        alloc,
        alloc,
        &store_a,
        "current-session",
        other_reference orelse return error.TestExpectedEqual,
        false,
    );
    defer alloc.free(record);
    try std.testing.expect(std.mem.find(u8, record, "\"session_relation\":\"other\"") != null);
    try std.testing.expect(std.mem.find(u8, record, "Did we choose cobalt?") != null);
    try std.testing.expect(std.mem.find(u8, record, "\"execution\"") == null);
    const record_with_execution = try readAlloc(
        alloc,
        alloc,
        &store_a,
        "current-session",
        other_reference orelse return error.TestExpectedEqual,
        true,
    );
    defer alloc.free(record_with_execution);
    try std.testing.expect(std.mem.find(
        u8,
        record_with_execution,
        "\"execution\":{\"schema_version\":5",
    ) != null);

    const outside_reference = try referenceAlloc(
        alloc,
        project_b,
        "outside-session",
        0,
        outside.history[0],
    );
    defer alloc.free(outside_reference);
    try std.testing.expectError(
        error.HistoryReferenceUnavailable,
        readAlloc(alloc, alloc, &store_a, "current-session", outside_reference, false),
    );
}

test "session history search does not reward repeated query tokens across fields" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "project");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const project = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "project");
    defer alloc.free(project);
    var store = try session_store.Store.initFromHome(alloc, home, project);
    defer store.deinit(alloc);

    var older = try testState(
        alloc,
        "older-repetitive",
        project,
        20,
        "alpha beta",
        "alpha beta",
    );
    defer older.deinit(alloc);
    var newer = try testState(
        alloc,
        "newer-concise",
        project,
        30,
        "alpha",
        "beta",
    );
    defer newer.deinit(alloc);
    var older_writer = try store.startWritableSession(alloc, older);
    _ = try older_writer.commitStateReplacement(
        alloc,
        older,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    older_writer.deinit(alloc);
    var newer_writer = try store.startWritableSession(alloc, newer);
    _ = try newer_writer.commitStateReplacement(
        alloc,
        newer,
        .recovery,
        .retry_expected_tail,
        .{},
    );
    newer_writer.deinit(alloc);

    const result = try searchAlloc(alloc, alloc, &store, null, "alpha beta", 8);
    defer alloc.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    const hits = parsed.value.object.get("hits").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqualStrings(
        "newer-concise",
        hits[0].object.get("session_id").?.string,
    );
    try std.testing.expectEqualStrings(
        "older-repetitive",
        hits[1].object.get("session_id").?.string,
    );
}

test "session history search scratch remains bounded across session count" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "project");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const project = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "project");
    defer alloc.free(project);
    var store = try session_store.Store.initFromHome(alloc, home, project);
    defer store.deinit(alloc);

    for (0..max_sessions_scanned) |index| {
        var id_buffer: [32]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "bounded-{d}", .{index});
        var state = try testState(
            alloc,
            id,
            project,
            @intCast(index + 1),
            "ordinary project conversation",
            "ordinary response",
        );
        defer state.deinit(alloc);
        var writer = try store.startWritableSession(alloc, state);
        _ = try writer.commitStateReplacement(
            alloc,
            state,
            .recovery,
            .retry_expected_tail,
            .{},
        );
        writer.deinit(alloc);
    }

    var scratch: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    scratch.backing_allocator = alloc;
    scratch.requested_memory_limit = 512 * 1024;
    defer std.testing.expectEqual(
        std.heap.Check.ok,
        scratch.deinit(),
    ) catch @panic("session history scratch leak");
    const result = try searchAlloc(
        alloc,
        scratch.allocator(),
        &store,
        null,
        "absent sentinel",
        8,
    );
    defer alloc.free(result);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("truncated").?.bool);
    try std.testing.expectEqual(@as(usize, 0), scratch.total_requested_bytes);
}
