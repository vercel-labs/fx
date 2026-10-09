//! The AI Gateway usage snapshot on disk, `~/.fx/usage-gateway.json`, and
//! the fetch that renews it. A snapshot is written only after AI Gateway
//! answered every period, so a failed refresh keeps the last good one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const durable = @import("durable.zig");
const host = @import("../host.zig");
const history = @import("../gateway_history.zig");

pub const file_name = "usage-gateway.json";
const profile_dir_name = ".fx";

/// The stored snapshot for `identity`, or null when there is none, it is
/// unsafe or unreadable, or it holds another identity's numbers. A bad file
/// is left for the next refresh to replace. Rows live in `arena`.
pub fn read(io: Io, home: Io.Dir, arena: Allocator, identity: history.Identity) ?history.Snapshot {
    var dir = (durable.openDirNoFollow(io, home, profile_dir_name) catch return null) orelse return null;
    defer dir.close(io);
    const file = (durable.openRegularFile(io, dir, file_name, .read_only) catch return null) orelse return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    durable.checkPrivateFile(stat) catch return null;
    if (stat.size > history.max_snapshot_bytes) return null;
    const bytes = arena.alloc(u8, @intCast(stat.size)) catch return null;
    const read_len = file.readPositionalAll(io, bytes, 0) catch return null;
    if (read_len != bytes.len) return null;
    const snapshot = history.decode(arena, bytes) catch return null;
    if (!std.mem.eql(u8, &snapshot.identity, &identity)) return null;
    return snapshot;
}

pub const WriteError = durable.ReplaceError || Allocator.Error || error{WriteFailed};

/// Replaces the stored snapshot with `snapshot`, private to the user.
pub fn write(io: Io, home: Io.Dir, gpa: Allocator, snapshot: history.Snapshot) WriteError!void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    history.encode(&out.writer, snapshot) catch return error.OutOfMemory;
    var dir = durable.openOrCreatePrivateDir(io, home, profile_dir_name) catch return error.WriteFailed;
    defer dir.close(io);
    try durable.replace(io, dir, file_name, out.written(), .{});
}

/// What a fetch sends with each report query.
pub const Credential = struct {
    /// The bearer token, or null for host-managed auth.
    secret: ?[]const u8,
    team: ?[]const u8,
    /// The `gatewayUser` tag whose usage to report.
    user: []const u8,
};

pub const Failure = enum {
    /// The host does not trust the origin with a credential.
    untrusted_origin,
    /// No answer, or one too large to read.
    transport,
    /// HTTP 429.
    rate_limited,
    /// HTTP 5xx.
    server,
    /// Another status AI Gateway should not send for a report.
    rejected,
    /// A 200 whose body is not a usage report.
    invalid_report,
    out_of_memory,
};

pub const Outcome = union(enum) {
    /// AI Gateway answered every period.
    fetched: history.Snapshot,
    /// AI Gateway refused usage reports for this credential (401 or 403):
    /// a snapshot with no rows that remembers it.
    refused: history.Snapshot,
    /// No usable answer. The stored snapshot, if any, stands.
    failed: Failure,
    canceled,
};

/// The most bytes one report body may take.
pub const max_body_bytes = 128 * 1024;

/// Asks AI Gateway for every period's per-model usage of `credential.user`
/// at `now_ms`, one query each, through the host's transport. Rows live in
/// `arena`; `body` is scratch space of at least `max_body_bytes`.
pub fn fetch(
    arena: Allocator,
    lookup: host.Lookup,
    origin: []const u8,
    credential: Credential,
    now_ms: i64,
    cancel: *const std.atomic.Value(bool),
    body: []u8,
) Outcome {
    if (!lookup.trusted(origin)) return .{ .failed = .untrusted_origin };
    const today = history.utcDay(now_ms);
    var snapshot: history.Snapshot = .{
        .identity = history.identityOf(credential.user, credential.team),
        .fetched_at_ms = now_ms,
        .today = today,
    };
    for (history.Period.all, 0..) |period, index| {
        var path: [history.max_query_bytes]u8 = undefined;
        const request: host.Lookup.Request = .{
            .origin = origin,
            .path = history.queryPath(&path, period, today, credential.user),
            .team = credential.team,
            .secret = credential.secret,
            .cancel = cancel,
        };
        const response = lookup.fetch(&request, body) catch |err| switch (err) {
            error.Canceled => return .canceled,
            error.Transport, error.BodyTooLarge => return .{ .failed = .transport },
        };
        switch (response.status) {
            200 => {},
            401, 403 => {
                snapshot.refused = true;
                snapshot.periods = .{ &.{}, &.{}, &.{} };
                return .{ .refused = snapshot };
            },
            429 => return .{ .failed = .rate_limited },
            500...599 => return .{ .failed = .server },
            else => return .{ .failed = .rejected },
        }
        snapshot.periods[index] = history.parseRows(arena, body[0..response.body_len]) catch |err| switch (err) {
            error.OutOfMemory => return .{ .failed = .out_of_memory },
            error.InvalidReport => return .{ .failed = .invalid_report },
        };
    }
    return .{ .fetched = snapshot };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const FakeGateway = struct {
    trust: bool = true,
    answers: []const Answer,
    used: usize = 0,
    paths: [3][history.max_query_bytes]u8 = undefined,
    path_lens: [3]usize = .{ 0, 0, 0 },
    team: ?[]const u8 = null,
    secret: ?[]const u8 = null,

    const Answer = union(enum) {
        status: u16,
        body: []const u8,
        transport,
        canceled,
    };

    fn lookup(f: *FakeGateway) host.Lookup {
        return .{ .context = f, .vtable = &.{ .trusted = trusted, .fetch = fetchFake } };
    }

    fn trusted(context: *anyopaque, _: []const u8) bool {
        const f: *FakeGateway = @ptrCast(@alignCast(context));
        return f.trust;
    }

    fn fetchFake(context: *anyopaque, request: *const host.Lookup.Request, body: []u8) host.Lookup.FetchError!host.Lookup.Response {
        const f: *FakeGateway = @ptrCast(@alignCast(context));
        const index = f.used;
        f.used += 1;
        @memcpy(f.paths[index][0..request.path.len], request.path);
        f.path_lens[index] = request.path.len;
        f.team = request.team;
        f.secret = request.secret;
        switch (f.answers[index]) {
            .status => |status| return .{ .status = status, .body_len = 0 },
            .transport => return error.Transport,
            .canceled => return error.Canceled,
            .body => |text| {
                @memcpy(body[0..text.len], text);
                return .{ .status = 200, .body_len = text.len };
            },
        }
    }

    fn path(f: *const FakeGateway, index: usize) []const u8 {
        return f.paths[index][0..f.path_lens[index]];
    }
};

const user = "fx_9258b1e31293f24fa6d43e84fc60ca53";
const one_row =
    \\{"results":[{"model":"openai/gpt-4.1-nano","total_cost":0.25,"input_tokens":100,"output_tokens":10,"cached_input_tokens":20,"cache_creation_input_tokens":0,"reasoning_tokens":3,"request_count":2}]}
;
// 2026-10-09 05:00 UTC.
const test_now_ms: i64 = 1_791_504_000_000 + 5 * std.time.ms_per_hour;

fn runFetch(arena: Allocator, gateway: *FakeGateway) Outcome {
    var cancel: std.atomic.Value(bool) = .init(false);
    const body = arena.alloc(u8, max_body_bytes) catch unreachable;
    return fetch(arena, gateway.lookup(), "https://ai-gateway.vercel.sh", .{ .secret = "vck_x", .team = "team_1", .user = user }, test_now_ms, &cancel, body);
}

test "a fetch asks for each period once and maps every answer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ok: FakeGateway = .{ .answers = &.{ .{ .body = one_row }, .{ .body = one_row }, .{ .body = "{\"results\":[]}" } } };
    const fetched = runFetch(arena, &ok).fetched;
    try testing.expectEqual(@as(usize, 3), ok.used);
    try testing.expectEqualStrings("/v1/report?start_date=2026-10-09&end_date=2026-10-09&group_by=model&user_id=" ++ user, ok.path(0));
    try testing.expectEqualStrings("/v1/report?start_date=2026-10-03&end_date=2026-10-09&group_by=model&user_id=" ++ user, ok.path(1));
    try testing.expectEqualStrings("/v1/report?start_date=2026-09-10&end_date=2026-10-09&group_by=model&user_id=" ++ user, ok.path(2));
    try testing.expectEqualStrings("team_1", ok.team.?);
    try testing.expectEqualStrings("vck_x", ok.secret.?);
    try testing.expectEqual(test_now_ms, fetched.fetched_at_ms);
    try testing.expectEqual(@as(u64, 120), fetched.periods[0][0].input_tokens);
    try testing.expectEqual(@as(usize, 0), fetched.periods[2].len);
    try testing.expectEqualSlices(u8, &history.identityOf(user, "team_1"), &fetched.identity);

    // A refusal on any period ends the fetch and keeps no rows.
    var refused: FakeGateway = .{ .answers = &.{ .{ .body = one_row }, .{ .status = 403 } } };
    const no = runFetch(arena, &refused).refused;
    try testing.expect(no.refused);
    try testing.expectEqual(@as(usize, 0), no.periods[0].len);
    try testing.expectEqual(@as(usize, 2), refused.used);

    const cases = [_]struct { answer: FakeGateway.Answer, want: Failure }{
        .{ .answer = .{ .status = 429 }, .want = .rate_limited },
        .{ .answer = .{ .status = 502 }, .want = .server },
        .{ .answer = .{ .status = 404 }, .want = .rejected },
        .{ .answer = .transport, .want = .transport },
        .{ .answer = .{ .body = "{\"data\":[]}" }, .want = .invalid_report },
    };
    for (cases) |case| {
        var gateway: FakeGateway = .{ .answers = &.{case.answer} };
        try testing.expectEqual(case.want, runFetch(arena, &gateway).failed);
        try testing.expectEqual(@as(usize, 1), gateway.used);
    }
    var canceled: FakeGateway = .{ .answers = &.{.canceled} };
    try testing.expect(runFetch(arena, &canceled) == .canceled);
    var untrusted: FakeGateway = .{ .trust = false, .answers = &.{} };
    try testing.expectEqual(Failure.untrusted_origin, runFetch(arena, &untrusted).failed);
    try testing.expectEqual(@as(usize, 0), untrusted.used);
}

test "the stored snapshot belongs to one identity and survives only whole" {
    var home = testing.tmpDir(.{ .iterate = true });
    defer home.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const identity = history.identityOf(user, null);

    try testing.expectEqual(null, read(testing.io, home.dir, arena, identity));
    var gateway: FakeGateway = .{ .answers = &.{ .{ .body = one_row }, .{ .body = one_row }, .{ .body = one_row } } };
    var cancel: std.atomic.Value(bool) = .init(false);
    const body = try arena.alloc(u8, max_body_bytes);
    const fetched = fetch(arena, gateway.lookup(), "https://ai-gateway.vercel.sh", .{ .secret = null, .team = null, .user = user }, test_now_ms, &cancel, body).fetched;
    try write(testing.io, home.dir, testing.allocator, fetched);

    const stored = read(testing.io, home.dir, arena, identity).?;
    try testing.expectEqual(test_now_ms, stored.fetched_at_ms);
    try testing.expectEqualStrings("openai/gpt-4.1-nano", stored.periods[1][0].model);
    try testing.expectEqual(@as(u64, 13), stored.periods[2][0].output_tokens);
    // Another key or team sees nothing.
    try testing.expectEqual(null, read(testing.io, home.dir, arena, history.identityOf("fx_other", null)));
    try testing.expectEqual(null, read(testing.io, home.dir, arena, history.identityOf(user, "team_1")));

    var fx_dir = try home.dir.openDir(testing.io, profile_dir_name, .{});
    defer fx_dir.close(testing.io);
    const stat = try fx_dir.statFile(testing.io, file_name, .{});
    try testing.expectEqual(@as(u32, 0o600), durable.modeOf(stat.permissions) & 0o777);

    // A file others can read, or a torn one, reads as none.
    const bytes = try fx_dir.readFileAlloc(testing.io, file_name, arena, .limited(history.max_snapshot_bytes));
    try fx_dir.deleteFile(testing.io, file_name);
    try fx_dir.writeFile(testing.io, .{ .sub_path = file_name, .data = bytes, .flags = .{ .permissions = .fromMode(0o644) } });
    try testing.expectEqual(null, read(testing.io, home.dir, arena, identity));
    try fx_dir.deleteFile(testing.io, file_name);
    try fx_dir.writeFile(testing.io, .{ .sub_path = file_name, .data = bytes, .flags = .{ .permissions = .fromMode(0o600) } });
    try testing.expect(read(testing.io, home.dir, arena, identity) != null);
    try fx_dir.writeFile(testing.io, .{ .sub_path = file_name, .data = bytes[0 .. bytes.len / 2], .flags = .{ .permissions = .fromMode(0o600) } });
    try testing.expectEqual(null, read(testing.io, home.dir, arena, identity));
}
