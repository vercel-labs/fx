//! The Vercel calls that setup makes (U5, U6, U8, R5): the account, the teams,
//! the projects and the sandbox project. Each call returns an `Outcome`, and
//! the caller maps it to E6, E8 or E9. Every path segment and query value that
//! comes from user or API text is escaped here, and every value the API returns
//! is bounded before a caller sees it. The arena a call is given owns everything
//! it returns.

const std = @import("std");
const transport = @import("transport.zig");
const credentials = @import("credentials.zig");
const reply = @import("reply.zig");
const json_decode = @import("../../shared/json_decode.zig");

const Allocator = std.mem.Allocator;

/// The most teams one listing returns (U5).
pub const max_teams: usize = 300;
/// The most team pages one listing reads. A page holds up to `team_page_limit` teams.
pub const max_team_pages: usize = 16;
pub const team_page_limit: usize = 100;
pub const project_page_limit: usize = 20;
/// The most bytes one setup reply may hold. Real list entries are large, and a page of
/// projects can be several MiB (U5). Every other REST reply keeps the transport's limit.
pub const setup_reply_bytes: usize = 8 * 1024 * 1024;
/// The sandbox project that setup creates, or reuses on a 409 (U6, U8).
pub const sandbox_project_name = "fx-sandbox";
pub const max_id_bytes: usize = 128;
pub const max_name_bytes: usize = 256;
pub const max_cursor_bytes: usize = 64;
/// The most items one reply may hold.
pub const max_reply_items: usize = 300;

/// What one call needs: where it goes, the login, the call's cancel flag, and
/// where its trace lines go.
pub const Link = struct {
    base: transport.BaseUrl,
    token: credentials.Token,
    cancel_flag: *std.atomic.Value(bool),
    trace: credentials.Trace,
};

pub const User = struct {
    id: []const u8,
};

pub const Team = struct {
    id: []const u8,
    slug: []const u8,
    name: []const u8,
};

pub const Project = struct {
    id: []const u8,
    name: []const u8,
};

/// A failed step: the step's name and a short reason. `describe` makes the text for E9.
pub const Failure = struct {
    step: []const u8,
    reason: Reason,

    pub const Reason = union(enum) {
        status: u16,
        timeout,
        transport,
        too_large,
        bad_reply,
    };
};

/// The result of one call. The caller maps `rejected` to E6, `failed` to E9, and
/// `canceled` to a call that ends with no mark (U7). `not_found` is the caller's to map.
pub fn Outcome(comptime T: type) type {
    return union(enum) {
        ok: T,
        /// 401 or 403: the login is rejected.
        rejected,
        /// 404: the object is not there.
        not_found,
        /// The call's cancel flag was set.
        canceled,
        failed: Failure,
    };
}

/// The account of the login. The result holds the user's id (R5).
pub fn getUser(arena: Allocator, link: Link) Allocator.Error!Outcome(User) {
    const fetched = try fetch(arena, link, "user", .GET, "/v2/user", null);
    return settle(User, arena, "user", fetched, parseUser);
}

/// The teams of the account, in the order the API returns them, up to `max_teams`.
/// A listing that reaches `max_team_pages` pages returns the teams it has read.
pub fn listTeams(arena: Allocator, link: Link) Allocator.Error!Outcome([]const Team) {
    var teams: std.ArrayList(Team) = .empty;
    var cursor: ?[]const u8 = null;
    var pages: usize = 0;
    while (pages < max_team_pages) : (pages += 1) {
        const path = if (cursor) |value|
            try arena.print("/v2/teams?limit={d}&until={s}", .{ team_page_limit, try escapeComponent(arena, value) })
        else
            try arena.print("/v2/teams?limit={d}", .{team_page_limit});
        const fetched = try fetch(arena, link, "teams", .GET, path, null);
        const page = switch (try settle(TeamsPage, arena, "teams", fetched, parseTeamsPage)) {
            .ok => |value| value,
            .rejected => return .rejected,
            .not_found => return .not_found,
            .canceled => return .canceled,
            .failed => |failure| return .{ .failed = failure },
        };
        if (page.teams.len == 0 and page.next != null) return failedAs([]const Team, "teams", .bad_reply);
        for (page.teams) |team| {
            if (teams.items.len == max_teams) break;
            try teams.append(arena, team);
        }
        if (teams.items.len == max_teams) break;
        const next = page.next orelse break;
        if (cursor) |previous| {
            if (std.mem.eql(u8, previous, next)) return failedAs([]const Team, "teams", .bad_reply);
        }
        cursor = next;
    }
    return .{ .ok = teams.items };
}

/// One team by its slug. A slug is path text, so it is escaped.
pub fn getTeamBySlug(arena: Allocator, link: Link, slug: []const u8) Allocator.Error!Outcome(Team) {
    if (slug.len == 0) return failedAs(Team, "team", .bad_reply);
    const path = try arena.print("/v2/teams/{s}", .{try escapeComponent(arena, slug)});
    const fetched = try fetch(arena, link, "team", .GET, path, null);
    return settle(Team, arena, "team", fetched, parseTeamReply);
}

/// The first `project_page_limit` projects of a team, newest first.
pub fn listProjects(arena: Allocator, link: Link, team_id: []const u8) Allocator.Error!Outcome([]const Project) {
    if (team_id.len == 0) return failedAs([]const Project, "projects", .bad_reply);
    const path = try arena.print("/v10/projects?teamId={s}&limit={d}", .{ try escapeComponent(arena, team_id), project_page_limit });
    const fetched = try fetch(arena, link, "projects", .GET, path, null);
    return settle([]const Project, arena, "projects", fetched, parseProjectsPage);
}

/// One project of a team by its name. A name is path text, so it is escaped.
pub fn getProjectByName(arena: Allocator, link: Link, team_id: []const u8, name: []const u8) Allocator.Error!Outcome(Project) {
    if (team_id.len == 0 or name.len == 0) return failedAs(Project, "project", .bad_reply);
    const path = try arena.print("/v9/projects/{s}?teamId={s}", .{ try escapeComponent(arena, name), try escapeComponent(arena, team_id) });
    const fetched = try fetch(arena, link, "project", .GET, path, null);
    return settle(Project, arena, "project", fetched, parseProjectReply);
}

/// Creates the sandbox project (U8). A 409 means it exists, so the existing
/// `sandbox_project_name` project is read and returned.
pub fn createProject(arena: Allocator, link: Link, team_id: []const u8) Allocator.Error!Outcome(Project) {
    if (team_id.len == 0) return failedAs(Project, "create project", .bad_reply);
    const path = try arena.print("/v11/projects?teamId={s}", .{try escapeComponent(arena, team_id)});
    const fetched = try fetch(arena, link, "create project", .POST, path, "{\"name\":\"" ++ sandbox_project_name ++ "\"}");
    switch (fetched) {
        .conflict => return getProjectByName(arena, link, team_id, sandbox_project_name),
        else => return settle(Project, arena, "create project", fetched, parseProjectReply),
    }
}

/// The E9 reason text: `{step}: {reason}`. The caller adds the rest of the line.
pub fn describe(buffer: []u8, failure: Failure) []const u8 {
    const text = switch (failure.reason) {
        .status => |code| std.mem.print(buffer, "{s}: HTTP {d}", .{ failure.step, code }),
        .timeout => std.mem.print(buffer, "{s}: timed out", .{failure.step}),
        .transport => std.mem.print(buffer, "{s}: the request failed", .{failure.step}),
        .too_large => std.mem.print(buffer, "{s}: the reply was too large", .{failure.step}),
        .bad_reply => std.mem.print(buffer, "{s}: unexpected reply", .{failure.step}),
    };
    return text catch failure.step;
}

/// `text` as one path segment or one query value. Every byte outside the RFC
/// 3986 unreserved set becomes %XX, so a `/`, `?`, `#`, `&`, `=`, `%` or space
/// cannot change the path or the query.
pub fn escapeComponent(arena: Allocator, text: []const u8) Allocator.Error![]u8 {
    const hex = "0123456789ABCDEF";
    var out: std.ArrayList(u8) = .empty;
    for (text) |byte| {
        if (isUnreserved(byte)) {
            try out.append(arena, byte);
        } else {
            try out.append(arena, '%');
            try out.append(arena, hex[byte >> 4]);
            try out.append(arena, hex[byte & 0x0f]);
        }
    }
    return out.toOwnedSlice(arena);
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

// --- Requests and outcomes -------------------------------------------------

const Fetched = union(enum) {
    body: []const u8,
    rejected,
    not_found,
    conflict,
    canceled,
    failed: Failure,
};

fn failed(step: []const u8, reason: Failure.Reason) Fetched {
    return .{ .failed = .{ .step = step, .reason = reason } };
}

fn failedAs(comptime T: type, step: []const u8, reason: Failure.Reason) Outcome(T) {
    return .{ .failed = .{ .step = step, .reason = reason } };
}

fn fetch(
    arena: Allocator,
    link: Link,
    step: []const u8,
    method: std.http.Method,
    path: []const u8,
    body: ?[]const u8,
) Allocator.Error!Fetched {
    const response = transport.request(arena, link.cancel_flag, link.base, link.token, link.trace, .{
        .step = step,
        .method = method,
        .path = path,
        .body = body,
        .max_bytes = setup_reply_bytes,
    }) catch |err| return requestFailure(step, err);
    if (response.status >= 200 and response.status <= 299) return .{ .body = response.body };
    return switch (response.status) {
        401, 403 => .rejected,
        404 => .not_found,
        409 => .conflict,
        else => failed(step, .{ .status = response.status }),
    };
}

fn requestFailure(step: []const u8, err: transport.RequestError) Allocator.Error!Fetched {
    switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return .canceled,
        error.Timeout => return failed(step, .timeout),
        error.BodyTooLarge => return failed(step, .too_large),
        error.TransportFailed, error.InvalidPath => return failed(step, .transport),
    }
}

fn settle(
    comptime T: type,
    arena: Allocator,
    step: []const u8,
    fetched: Fetched,
    comptime parse: fn (Allocator, []const u8) ParseError!T,
) Allocator.Error!Outcome(T) {
    switch (fetched) {
        .body => |bytes| {
            const value = parse(arena, bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadReply => return failedAs(T, step, .bad_reply),
            };
            return .{ .ok = value };
        },
        .rejected => return .rejected,
        .not_found => return .not_found,
        .conflict => return failedAs(T, step, .{ .status = 409 }),
        .canceled => return .canceled,
        .failed => |failure| return .{ .failed = failure },
    }
}

// --- Reply parsing -----------------------------------------------------------

const ParseError = reply.ParseError;
const parseRoot = reply.parseRoot;
const objectOf = reply.objectOf;
const requiredText = reply.requiredText;

const TeamsPage = struct {
    teams: []const Team,
    next: ?[]const u8,
};

// The fields fx reads from a setup reply. A field is an optional JSON value so `requiredText`
// checks its type and length; a field fx does not read is not in these structs, so it is
// skipped while parsing, never kept (U5).
const UserEntry = struct { id: ?std.json.Value = null };
const UserReply = struct { user: ?UserEntry = null };
const TeamEntry = struct {
    id: ?std.json.Value = null,
    slug: ?std.json.Value = null,
    name: ?std.json.Value = null,
};
const TeamsPageReply = struct {
    teams: ?[]const TeamEntry = null,
    pagination: ?std.json.Value = null,
};
const ProjectEntry = struct {
    id: ?std.json.Value = null,
    name: ?std.json.Value = null,
};
const ProjectsPageReply = struct { projects: ?[]const ProjectEntry = null };

/// Parses a setup reply into its typed fields, skipping every other field.
fn parseSetup(comptime T: type, arena: Allocator, bytes: []const u8) ParseError!T {
    return json_decode.parseFromSliceLeaky(T, arena, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadReply,
    };
}

fn parseUser(arena: Allocator, bytes: []const u8) ParseError!User {
    const user = (try parseSetup(UserReply, arena, bytes)).user orelse return error.BadReply;
    return .{ .id = try requiredText(arena, user.id, max_id_bytes) };
}

fn teamFrom(arena: Allocator, entry: TeamEntry) ParseError!Team {
    return .{
        .id = try requiredText(arena, entry.id, max_id_bytes),
        .slug = try requiredText(arena, entry.slug, max_name_bytes),
        .name = try requiredText(arena, entry.name, max_name_bytes),
    };
}

fn parseTeamReply(arena: Allocator, bytes: []const u8) ParseError!Team {
    return teamFrom(arena, try parseSetup(TeamEntry, arena, bytes));
}

fn parseTeamsPage(arena: Allocator, bytes: []const u8) ParseError!TeamsPage {
    const page = try parseSetup(TeamsPageReply, arena, bytes);
    const items = page.teams orelse return error.BadReply;
    if (items.len > max_reply_items) return error.BadReply;
    const teams = try arena.alloc(Team, items.len);
    for (items, 0..) |item, index| {
        teams[index] = try teamFrom(arena, item);
    }
    return .{ .teams = teams, .next = try cursorOf(arena, page.pagination) };
}

/// The `pagination.next` cursor. Absent or null means the last page. A number or
/// a string is a cursor. Anything else is a bad reply.
fn cursorOf(arena: Allocator, pagination: ?std.json.Value) ParseError!?[]const u8 {
    const value = pagination orelse return null;
    switch (value) {
        .null => return null,
        else => {},
    }
    const next = (try objectOf(value)).get("next") orelse return null;
    switch (next) {
        .null => return null,
        .integer => |number| {
            if (number < 0) return error.BadReply;
            return try arena.print("{d}", .{number});
        },
        .string => return try requiredText(arena, next, max_cursor_bytes),
        else => return error.BadReply,
    }
}

fn projectFrom(arena: Allocator, entry: ProjectEntry) ParseError!Project {
    return .{
        .id = try requiredText(arena, entry.id, max_id_bytes),
        .name = try requiredText(arena, entry.name, max_name_bytes),
    };
}

fn parseProjectReply(arena: Allocator, bytes: []const u8) ParseError!Project {
    return projectFrom(arena, try parseSetup(ProjectEntry, arena, bytes));
}

fn parseProjectsPage(arena: Allocator, bytes: []const u8) ParseError![]const Project {
    const items = (try parseSetup(ProjectsPageReply, arena, bytes)).projects orelse return error.BadReply;
    if (items.len > max_reply_items) return error.BadReply;
    const projects = try arena.alloc(Project, items.len);
    for (items, 0..) |item, index| {
        projects[index] = try projectFrom(arena, item);
    }
    return projects;
}

// --- Tests -----------------------------------------------------------------

const test_server = @import("test_server.zig");

fn originFor(buffer: []u8, port_number: u16) ![]const u8 {
    return std.mem.print(buffer, "http://127.0.0.1:{d}", .{port_number});
}

fn linkTo(origin: []const u8, cancel: *std.atomic.Value(bool), trace: credentials.Trace) Link {
    return .{
        .base = transport.resolveBaseUrl(origin),
        .token = .{ .value = "vca_fake_api_token" },
        .cancel_flag = cancel,
        .trace = trace,
    };
}

fn expectOk(comptime T: type, outcome: Outcome(T)) !T {
    return switch (outcome) {
        .ok => |value| value,
        else => error.TestUnexpectedResult,
    };
}

fn expectFailed(comptime T: type, outcome: Outcome(T), step: []const u8, reason: Failure.Reason) !void {
    switch (outcome) {
        .failed => |failure| {
            try std.testing.expectEqualStrings(step, failure.step);
            try std.testing.expectEqualDeep(reason, failure.reason);
        },
        else => return error.TestUnexpectedResult,
    }
}

fn teamsPageBody(arena: Allocator, first: usize, count: usize, next: ?usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"teams\":[");
    var index: usize = first;
    while (index < first + count) : (index += 1) {
        if (index != first) try out.append(arena, ',');
        const item = try arena.print("{{\"id\":\"team_{d}\",\"slug\":\"fake-{d}\",\"name\":\"Fake {d}\"}}", .{ index, index, index });
        try out.appendSlice(arena, item);
    }
    const cursor: []const u8 = if (next) |value| try arena.print("{d}", .{value}) else "null";
    const tail = try arena.print("],\"pagination\":{{\"count\":{d},\"next\":{s}}}}}", .{ count, cursor });
    try out.appendSlice(arena, tail);
    return out.toOwnedSlice(arena);
}

test "getUser reads the user id from the reply, and the token stays off the trace" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var server: test_server.Server = .{ .replies = &.{.{ .status = "200 OK", .body = "{\"user\":{\"id\":\"user_fake_1\",\"username\":\"fake\"}}" }} };
    try server.listen();
    defer server.close();
    try server.start();
    var origin_buffer: [64]u8 = undefined;
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    const link = linkTo(try originFor(&origin_buffer, server.port()), &cancel, capture.trace());
    const user = try expectOk(User, try getUser(arena_state.allocator(), link));
    server.close();
    try std.testing.expectEqualStrings("user_fake_1", user.id);
    try std.testing.expectEqualStrings("GET /v2/user HTTP/1.1", server.line(0));
    try std.testing.expect(std.mem.find(u8, capture.captured(), "vca_fake_api_token") == null);
}

test "a 401 and a 403 both give rejected, and a rejected call is not retried" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var server: test_server.Server = .{ .replies = &.{
        .{ .status = "401 Unauthorized", .body = "{\"error\":{\"code\":\"unauthorized\"}}" },
        .{ .status = "403 Forbidden", .body = "{\"error\":{\"code\":\"forbidden\"}}" },
    } };
    try server.listen();
    defer server.close();
    try server.start();
    var origin_buffer: [64]u8 = undefined;
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    const link = linkTo(try originFor(&origin_buffer, server.port()), &cancel, capture.trace());
    try std.testing.expect((try getUser(arena_state.allocator(), link)) == .rejected);
    try std.testing.expect((try getUser(arena_state.allocator(), link)) == .rejected);
    server.close();
    try std.testing.expectEqual(@as(usize, 2), server.served);
}

test "a reply with an empty, missing or non-string id is refused as a bad reply" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var server: test_server.Server = .{ .replies = &.{
        .{ .status = "200 OK", .body = "{\"user\":{\"id\":\"\"}}" },
        .{ .status = "200 OK", .body = "{\"user\":{}}" },
        .{ .status = "200 OK", .body = "{\"user\":{\"id\":7}}" },
    } };
    try server.listen();
    defer server.close();
    try server.start();
    var origin_buffer: [64]u8 = undefined;
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    const link = linkTo(try originFor(&origin_buffer, server.port()), &cancel, capture.trace());
    for (0..3) |_| {
        try expectFailed(User, try getUser(arena_state.allocator(), link), "user", .bad_reply);
    }
}

test "a teams listing follows pagination.next, and stops at 300 teams" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const page1 = try teamsPageBody(arena, 0, 120, 1000);
    const page2 = try teamsPageBody(arena, 120, 120, 2000);
    const page3 = try teamsPageBody(arena, 240, 120, 3000);
    const replies = [_]test_server.Reply{
        .{ .status = "200 OK", .body = page1 },
        .{ .status = "200 OK", .body = page2 },
        .{ .status = "200 OK", .body = page3 },
    };
    var server: test_server.Server = .{ .replies = &replies };
    try server.listen();
    defer server.close();
    try server.start();
    var origin_buffer: [64]u8 = undefined;
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    const link = linkTo(try originFor(&origin_buffer, server.port()), &cancel, capture.trace());
    const teams = try expectOk([]const Team, try listTeams(arena, link));
    server.close();
    try std.testing.expectEqual(max_teams, teams.len);
    try std.testing.expectEqualStrings("team_299", teams[299].id);
    try std.testing.expectEqual(@as(usize, 3), server.served);
    try std.testing.expectEqualStrings("GET /v2/teams?limit=100 HTTP/1.1", server.line(0));
    try std.testing.expectEqualStrings("GET /v2/teams?limit=100&until=1000 HTTP/1.1", server.line(1));
    try std.testing.expectEqualStrings("GET /v2/teams?limit=100&until=2000 HTTP/1.1", server.line(2));
}

test "a teams listing with no pagination.next makes one request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const single = try teamsPageBody(arena, 0, 2, null);
    const replies = [_]test_server.Reply{.{ .status = "200 OK", .body = single }};
    var server: test_server.Server = .{ .replies = &replies };
    try server.listen();
    defer server.close();
    try server.start();
    var origin_buffer: [64]u8 = undefined;
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    const link = linkTo(try originFor(&origin_buffer, server.port()), &cancel, capture.trace());
    const teams = try expectOk([]const Team, try listTeams(arena, link));
    server.close();
    try std.testing.expectEqual(@as(usize, 2), teams.len);
    try std.testing.expectEqual(@as(usize, 1), server.served);
}

test "a teams cursor that does not move is refused as a bad reply" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = try teamsPageBody(arena, 0, 1, 1000);
    const second = try teamsPageBody(arena, 1, 1, 1000);
    const replies = [_]test_server.Reply{
        .{ .status = "200 OK", .body = first },
        .{ .status = "200 OK", .body = second },
    };
    var server: test_server.Server = .{ .replies = &replies };
    try server.listen();
    defer server.close();
    try server.start();
    var origin_buffer: [64]u8 = undefined;
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    const link = linkTo(try originFor(&origin_buffer, server.port()), &cancel, capture.trace());
    try expectFailed([]const Team, try listTeams(arena, link), "teams", .bad_reply);
    server.close();
    try std.testing.expectEqual(@as(usize, 2), server.served);
}

test "a 404 on getTeamBySlug is not found, and the slug is escaped in the path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var server: test_server.Server = .{ .replies = &.{.{ .status = "404 Not Found", .body = "{\"error\":{\"code\":\"not_found\"}}" }} };
    try server.listen();
    defer server.close();
    try server.start();
    var origin_buffer: [64]u8 = undefined;
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    const link = linkTo(try originFor(&origin_buffer, server.port()), &cancel, capture.trace());
    try std.testing.expect((try getTeamBySlug(arena_state.allocator(), link, "a/b?c#d%e")) == .not_found);
    server.close();
    try std.testing.expectEqualStrings("GET /v2/teams/a%2Fb%3Fc%23d%25e HTTP/1.1", server.line(0));
}

test "listProjects and getProjectByName escape the team id and the name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var server: test_server.Server = .{ .replies = &.{
        .{ .status = "200 OK", .body = "{\"projects\":[],\"pagination\":{\"count\":0,\"next\":null}}" },
        .{ .status = "200 OK", .body = "{\"id\":\"prj_1\",\"name\":\"web/x?#%\"}" },
    } };
    try server.listen();
    defer server.close();
    try server.start();
    var origin_buffer: [64]u8 = undefined;
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    const link = linkTo(try originFor(&origin_buffer, server.port()), &cancel, capture.trace());
    const projects = try expectOk([]const Project, try listProjects(arena_state.allocator(), link, "team_a&x=1"));
    try std.testing.expectEqual(@as(usize, 0), projects.len);
    const project = try expectOk(Project, try getProjectByName(arena_state.allocator(), link, "team_a&x=1", "web/x?#%"));
    server.close();
    try std.testing.expectEqualStrings("prj_1", project.id);
    try std.testing.expectEqualStrings("GET /v10/projects?teamId=team_a%26x%3D1&limit=20 HTTP/1.1", server.line(0));
    try std.testing.expectEqualStrings("GET /v9/projects/web%2Fx%3F%23%25?teamId=team_a%26x%3D1 HTTP/1.1", server.line(1));
}

test "a setup reply of 1 MiB is read whole (U5)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const padding = try arena.alloc(u8, 1024 * 1024);
    @memset(padding, 'x');
    const body = try arena.print("{{\"user\":{{\"id\":\"usr_1\",\"pad\":\"{s}\"}}}}", .{padding});
    var server: test_server.Server = .{ .replies = &.{.{ .body = body }} };
    try server.listen();
    try server.start();
    defer server.close();
    var origin_buffer: [64]u8 = undefined;
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    const link = linkTo(try originFor(&origin_buffer, server.port()), &cancel, capture.trace());
    const user = try expectOk(User, try getUser(arena, link));
    try std.testing.expectEqualStrings("usr_1", user.id);
}

/// Counts the bytes its backing allocator holds at once, so a test can bound a parse's peak (U5).
const PeakCounter = struct {
    backing: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *PeakCounter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PeakCounter = @ptrCast(@alignCast(ptr));
        const memory = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live += len;
        self.peak = @max(self.peak, self.live);
        return memory;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PeakCounter = @ptrCast(@alignCast(ptr));
        self.live -= memory.len;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "a projects reply of twenty 200 KiB entries parses within three times its size (U5)" {
    var body: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer body.deinit();
    try body.writer.writeAll("{\"projects\":[");
    for (0..20) |index| {
        if (index > 0) try body.writer.writeAll(",");
        try body.writer.print("{{\"id\":\"prj_{d}\",\"name\":\"p{d}\",\"description\":\"", .{ index, index });
        try body.writer.splatByteAll('x', 200 * 1024);
        try body.writer.writeAll("\",\"extra\":{\"a\":[1,2,3]}}");
    }
    try body.writer.writeAll("]}");
    const bytes = body.written();

    var counter: PeakCounter = .{ .backing = std.testing.allocator };
    var arena_state = std.heap.ArenaAllocator.init(counter.allocator());
    defer arena_state.deinit();
    const projects = try parseProjectsPage(arena_state.allocator(), bytes);
    try std.testing.expectEqual(@as(usize, 20), projects.len);
    try std.testing.expect(counter.peak < 3 * bytes.len);
}

test "createProject on a 409 returns the existing sandbox project" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var server: test_server.Server = .{ .replies = &.{
        .{ .status = "409 Conflict", .body = "{\"error\":{\"code\":\"conflict\",\"message\":\"project exists\"}}" },
        .{ .status = "200 OK", .body = "{\"id\":\"prj_existing\",\"name\":\"fx-sandbox\"}" },
    } };
    try server.listen();
    defer server.close();
    try server.start();
    var origin_buffer: [64]u8 = undefined;
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    const link = linkTo(try originFor(&origin_buffer, server.port()), &cancel, capture.trace());
    const project = try expectOk(Project, try createProject(arena_state.allocator(), link, "team_1"));
    server.close();
    try std.testing.expectEqualStrings("prj_existing", project.id);
    try std.testing.expectEqualStrings("POST /v11/projects?teamId=team_1 HTTP/1.1", server.line(0));
    try std.testing.expectEqualStrings("GET /v9/projects/fx-sandbox?teamId=team_1 HTTP/1.1", server.line(1));
}

test "createProject on a 200 returns the new project" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var server: test_server.Server = .{ .replies = &.{.{ .status = "200 OK", .body = "{\"id\":\"prj_new\",\"name\":\"fx-sandbox\",\"createdAt\":1}" }} };
    try server.listen();
    defer server.close();
    try server.start();
    var origin_buffer: [64]u8 = undefined;
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    const link = linkTo(try originFor(&origin_buffer, server.port()), &cancel, capture.trace());
    const project = try expectOk(Project, try createProject(arena_state.allocator(), link, "team_1"));
    server.close();
    try std.testing.expectEqualStrings("prj_new", project.id);
    try std.testing.expectEqual(@as(usize, 1), server.served);
}

test "a 500 is a failed step with its status, and describe names the step" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var server: test_server.Server = .{ .replies = &.{.{ .status = "500 Internal Server Error", .body = "{}" }} };
    try server.listen();
    defer server.close();
    try server.start();
    var origin_buffer: [64]u8 = undefined;
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    const link = linkTo(try originFor(&origin_buffer, server.port()), &cancel, capture.trace());
    const outcome = try getUser(arena_state.allocator(), link);
    server.close();
    try expectFailed(User, outcome, "user", .{ .status = 500 });
    var text_buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("user: HTTP 500", describe(&text_buffer, outcome.failed));
}

test "getUser with a cancel already set sends nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var server: test_server.Server = .{ .replies = &.{.{ .status = "200 OK", .body = "{}" }} };
    try server.listen();
    defer server.close();
    try server.start();
    var origin_buffer: [64]u8 = undefined;
    var cancel = std.atomic.Value(bool).init(true);
    var capture: credentials.CaptureTrace = .{};
    const link = linkTo(try originFor(&origin_buffer, server.port()), &cancel, capture.trace());
    try std.testing.expect((try getUser(arena_state.allocator(), link)) == .canceled);
    server.close();
    try std.testing.expectEqual(@as(usize, 0), server.served);
}

test "an empty slug, team id or name is refused without a request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var server: test_server.Server = .{ .replies = &.{.{ .status = "200 OK", .body = "{}" }} };
    try server.listen();
    defer server.close();
    try server.start();
    var origin_buffer: [64]u8 = undefined;
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    const link = linkTo(try originFor(&origin_buffer, server.port()), &cancel, capture.trace());
    const arena = arena_state.allocator();
    try expectFailed(Team, try getTeamBySlug(arena, link, ""), "team", .bad_reply);
    try expectFailed([]const Project, try listProjects(arena, link, ""), "projects", .bad_reply);
    try expectFailed(Project, try getProjectByName(arena, link, "team_1", ""), "project", .bad_reply);
    server.close();
    try std.testing.expectEqual(@as(usize, 0), server.served);
}

test "escapeComponent escapes every byte outside the unreserved set" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("a%2Fb%3Fc%23d%25e", try escapeComponent(arena, "a/b?c#d%e"));
    try std.testing.expectEqualStrings("AZaz09-._~", try escapeComponent(arena, "AZaz09-._~"));
    try std.testing.expectEqualStrings("%C3%A9%20x%26y%3Dz", try escapeComponent(arena, "é x&y=z"));
}

test "describe names the step and the reason" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("teams: timed out", describe(&buffer, .{ .step = "teams", .reason = .timeout }));
    try std.testing.expectEqualStrings("teams: the request failed", describe(&buffer, .{ .step = "teams", .reason = .transport }));
    try std.testing.expectEqualStrings("teams: the reply was too large", describe(&buffer, .{ .step = "teams", .reason = .too_large }));
    try std.testing.expectEqualStrings("teams: unexpected reply", describe(&buffer, .{ .step = "teams", .reason = .bad_reply }));
    try std.testing.expectEqualStrings("teams: HTTP 503", describe(&buffer, .{ .step = "teams", .reason = .{ .status = 503 } }));
}

const reply_seeds = .{
    "A{\"user\":{\"id\":\"user_fake_1\",\"username\":\"fake-user\",\"email\":\"fake@example.com\"}}",
    "B{\"teams\":[{\"id\":\"team_fake_1\",\"slug\":\"fake-one\",\"name\":\"Fake One\"}],\"pagination\":{\"count\":1,\"next\":null}}",
    "B{\"teams\":[{\"id\":\"team_fake_2\",\"slug\":\"fake-two\",\"name\":\"Fake Two\"}],\"pagination\":{\"count\":1,\"next\":1700000000000}}",
    "C{\"projects\":[{\"id\":\"prj_fake_1\",\"name\":\"fake-web\",\"createdAt\":1700000000000}],\"pagination\":{\"count\":1,\"next\":null}}",
    "D{\"id\":\"prj_fake_2\",\"name\":\"fx-sandbox\",\"createdAt\":1700000000001}",
    "E{\"id\":\"team_fake_1\",\"slug\":\"fake-one\",\"name\":\"Fake One\"}",
};

fn expectBoundedId(id: []const u8) !void {
    try std.testing.expect(id.len > 0 and id.len <= max_id_bytes);
}

fn expectBoundedText(text: []const u8, max: usize) !void {
    try std.testing.expect(text.len > 0 and text.len <= max);
}

fn refusedOnly(err: ParseError) !void {
    return switch (err) {
        error.BadReply => {},
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// The first byte picks the parser (A user, B teams page, C projects page,
/// D project, E team, by the byte's value mod 5). The rest is the reply.
fn fuzzSetupReply(_: void, smith: *std.testing.Smith) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = try arena.alloc(u8, transport.max_response_bytes + 1);
    const len = smith.slice(raw);
    if (len == 0) return;
    const body = raw[1..len];
    switch (raw[0] % 5) {
        0 => {
            const user = parseUser(arena, body) catch |err| return refusedOnly(err);
            try expectBoundedId(user.id);
        },
        1 => {
            const page = parseTeamsPage(arena, body) catch |err| return refusedOnly(err);
            try std.testing.expect(page.teams.len <= max_reply_items);
            for (page.teams) |team| {
                try expectBoundedId(team.id);
                try expectBoundedText(team.slug, max_name_bytes);
                try expectBoundedText(team.name, max_name_bytes);
            }
            if (page.next) |next| try expectBoundedText(next, max_cursor_bytes);
        },
        2 => {
            const projects = parseProjectsPage(arena, body) catch |err| return refusedOnly(err);
            try std.testing.expect(projects.len <= max_reply_items);
            for (projects) |project| {
                try expectBoundedId(project.id);
                try expectBoundedText(project.name, max_name_bytes);
            }
        },
        3 => {
            const project = parseProjectReply(arena, body) catch |err| return refusedOnly(err);
            try expectBoundedId(project.id);
            try expectBoundedText(project.name, max_name_bytes);
        },
        4 => {
            const team = parseTeamReply(arena, body) catch |err| return refusedOnly(err);
            try expectBoundedId(team.id);
            try expectBoundedText(team.slug, max_name_bytes);
            try expectBoundedText(team.name, max_name_bytes);
        },
        else => {},
    }
}

test "a setup API reply parses or is refused, and a parsed id is non-empty and bounded, on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzSetupReply, .{
        .corpus = &(@import("fuzz_seed").slices(reply_seeds) ++ @import("fuzz_corpus").vercel_setup_reply.*),
    });
}
