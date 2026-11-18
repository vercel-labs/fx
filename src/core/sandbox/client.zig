//! A Vercel Sandbox API client. It sends `api.zig` requests through a
//! `Transport`, so the network, the fake API, and tests can stand in.
const std = @import("std");
const api = @import("api.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

/// The most pages a listing may take before it is refused.
const max_list_pages = 20;

pub const Response = struct {
    status: u16,
    body: []const u8 = "",
};

/// Receives each line of a streamed answer. Returning an error stops reading.
pub const LineSink = struct {
    context: *anyopaque,
    on_line: *const fn (context: *anyopaque, line: []const u8) anyerror!void,
};

/// Lets another thread stop a request that waits on the network. A lock
/// keeps the socket and the request flag together, so an abort never misses
/// an open socket and never touches one that has closed.
pub const Abort = struct {
    mutex: std.Io.Mutex = .init,
    requested: bool = false,
    socket: ?std.posix.socket_t = null,

    /// Records the request and shuts the open socket, so a waiting read returns.
    pub fn abort(self: *Abort) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.requested = true;
        if (self.socket) |socket| _ = std.c.shutdown(socket, std.c.SHUT.RDWR);
    }

    /// True once `abort` has been called.
    pub fn wasRequested(self: *Abort) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.requested;
    }

    /// The transport calls this when its request has a socket. False means an
    /// abort came first: the transport must stop.
    pub fn attach(self: *Abort, socket: std.posix.socket_t) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.requested) return false;
        self.socket = socket;
        return true;
    }

    /// The transport calls this before the socket closes.
    pub fn detach(self: *Abort) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.socket = null;
    }
};

/// One request as the transport receives it.
pub const Call = struct {
    base_url: []const u8,
    token: []const u8,
    request: api.Request,
    /// When set, each line of a 2xx answer goes here and the body stays empty.
    lines: ?LineSink = null,
    abort: ?*Abort = null,
    /// False for a request that must never be sent twice, such as one that starts a command.
    retry_safe: bool = true,
    max_body_bytes: usize = 64 * 1024 * 1024,
};

/// Sends one call and returns its answer. The network and the fake API implement it.
pub const Transport = struct {
    context: *anyopaque,
    send: *const fn (context: *anyopaque, arena: std.mem.Allocator, call: Call) anyerror!Response,
};

/// Says why a call failed, for the user. The message lives in the caller's arena.
pub const Failure = struct {
    message: []const u8 = "",
    /// The HTTP status of a refused request, when the API answered.
    status: ?u16 = null,
};

pub const Error = error{
    SandboxApiFailed,
    SandboxExists,
    Aborted,
    /// The request was sent but its answer was lost. It may have taken effect.
    AnswerLost,
    OutOfMemory,
};

/// Receives each parsed log line of a command.
pub const LogSink = struct {
    context: *anyopaque,
    on_log: *const fn (context: *anyopaque, line: api.LogLine) anyerror!void,
};

/// How one call is sent, apart from its request.
const Shape = struct {
    retry_safe: bool = true,
    lines: ?LineSink = null,
    abort: ?*Abort = null,
};

/// The Sandbox API for one team and project.
pub const Client = struct {
    transport: Transport,
    base_url: []const u8,
    team: []const u8,
    project: []const u8,
    token: []const u8,

    /// Creates a sandbox. A 409 answer means the name is taken.
    pub fn createSandbox(self: Client, arena: std.mem.Allocator, options: api.CreateOptions, failure: *Failure) Error!api.Sandbox {
        const what = try arena.print("creating sandbox {s}", .{options.name});
        const request = api.create(arena, self.team, options) catch |err| return buildFailed(arena, what, err, failure);
        const response = try self.send(arena, what, request, .{ .retry_safe = false }, failure);
        if (response.status == 409) {
            failure.message = try arena.print("sandbox {s} already exists", .{options.name});
            return error.SandboxExists;
        }
        if (!isSuccess(response.status)) return statusFailed(arena, what, response, failure);
        return api.parseSandbox(arena, response.body) catch |err| return unreadable(arena, what, err, failure);
    }

    /// Reads a sandbox. A 404 answer returns null.
    pub fn getSandbox(self: Client, arena: std.mem.Allocator, name: []const u8, resume_stopped: bool, failure: *Failure) Error!?api.Sandbox {
        const what = try arena.print("reading sandbox {s}", .{name});
        const request = api.getNamed(arena, self.team, self.project, name, resume_stopped) catch |err| return buildFailed(arena, what, err, failure);
        const response = try self.send(arena, what, request, .{}, failure);
        if (response.status == 404) return null;
        if (!isSuccess(response.status)) return statusFailed(arena, what, response, failure);
        return api.parseSandbox(arena, response.body) catch |err| return unreadable(arena, what, err, failure);
    }

    /// Deletes a sandbox. A 404 answer means it is already gone.
    pub fn deleteSandbox(self: Client, arena: std.mem.Allocator, name: []const u8, failure: *Failure) Error!void {
        const what = try arena.print("deleting sandbox {s}", .{name});
        const request = api.delete(arena, self.team, self.project, name) catch |err| return buildFailed(arena, what, err, failure);
        const response = try self.send(arena, what, request, .{}, failure);
        if (response.status == 404 or isSuccess(response.status)) return;
        return statusFailed(arena, what, response, failure);
    }

    /// Lists the sandboxes that carry `tag`, following the pages. A listing
    /// that needs more than `max_list_pages` pages is refused.
    pub fn listByTag(self: Client, arena: std.mem.Allocator, tag: api.Pair, failure: *Failure) Error![]const api.Listed {
        const what: []const u8 = "listing sandboxes";
        var found: std.ArrayList(api.Listed) = .empty;
        var cursor: ?[]const u8 = null;
        var pages: usize = 0;
        while (pages < max_list_pages) : (pages += 1) {
            const request = api.list(arena, self.team, self.project, tag, cursor) catch |err| return buildFailed(arena, what, err, failure);
            const response = try self.send(arena, what, request, .{}, failure);
            if (!isSuccess(response.status)) return statusFailed(arena, what, response, failure);
            const listing = api.parseListing(arena, response.body) catch |err| return unreadable(arena, what, err, failure);
            try found.appendSlice(arena, listing.sandboxes);
            cursor = listing.next orelse return found.toOwnedSlice(arena);
        }
        failure.message = try arena.print("{s} failed: more than {d} pages", .{ what, max_list_pages });
        return error.SandboxApiFailed;
    }

    /// Starts a command and streams its log lines to `sink`. A start is never
    /// sent twice, because a second start would run the command again.
    pub fn runCommand(
        self: Client,
        arena: std.mem.Allocator,
        session: []const u8,
        options: api.CommandOptions,
        sink: LogSink,
        abort: ?*Abort,
        failure: *Failure,
    ) Error!void {
        const what: []const u8 = "running a command";
        const request = api.runCommand(arena, self.team, session, options) catch |err| return buildFailed(arena, what, err, failure);
        var relay: LogRelay = .{ .sink = sink, .arena = arena };
        const response = self.send(arena, what, request, .{
            .retry_safe = false,
            .lines = .{ .context = &relay, .on_line = LogRelay.onLine },
            .abort = abort,
        }, failure) catch |err| {
            if (relay.failed) |sink_error| {
                failure.message = try arena.print("{s} failed: could not record output ({s})", .{ what, @errorName(sink_error) });
                return error.SandboxApiFailed;
            }
            return err;
        };
        if (!isSuccess(response.status)) return statusFailed(arena, what, response, failure);
    }

    /// Asks a command to stop. A 404 or 409 answer means it already ended.
    pub fn kill(self: Client, arena: std.mem.Allocator, session: []const u8, command_id: []const u8, failure: *Failure) Error!void {
        const what: []const u8 = "stopping a command";
        const request = api.kill(arena, self.team, session, command_id) catch |err| return buildFailed(arena, what, err, failure);
        const response = try self.send(arena, what, request, .{}, failure);
        if (response.status == 404 or response.status == 409 or isSuccess(response.status)) return;
        return statusFailed(arena, what, response, failure);
    }

    /// Waits for a command to end and returns it.
    pub fn waitCommand(self: Client, arena: std.mem.Allocator, session: []const u8, command_id: []const u8, failure: *Failure) Error!api.Command {
        const what: []const u8 = "waiting for a command";
        const request = api.waitCommand(arena, self.team, session, command_id) catch |err| return buildFailed(arena, what, err, failure);
        const response = try self.send(arena, what, request, .{}, failure);
        if (!isSuccess(response.status)) return statusFailed(arena, what, response, failure);
        return api.parseCommand(arena, response.body) catch |err| return unreadable(arena, what, err, failure);
    }

    /// Writes a gzip tar into `cwd` in the sandbox.
    pub fn writeArchive(self: Client, arena: std.mem.Allocator, session: []const u8, gzip_tar: []const u8, cwd: []const u8, failure: *Failure) Error!void {
        const what: []const u8 = "copying files into the sandbox";
        const request = api.writeArchive(arena, self.team, session, gzip_tar, cwd) catch |err| return buildFailed(arena, what, err, failure);
        const response = try self.send(arena, what, request, .{}, failure);
        if (!isSuccess(response.status)) return statusFailed(arena, what, response, failure);
    }

    /// Reads one file from the sandbox. A 404 answer returns null.
    pub fn readFile(self: Client, arena: std.mem.Allocator, session: []const u8, path: []const u8, failure: *Failure) Error!?[]const u8 {
        const what = try arena.print("reading {s} from the sandbox", .{path});
        const request = api.readFile(arena, self.team, session, path) catch |err| return buildFailed(arena, what, err, failure);
        const response = try self.send(arena, what, request, .{}, failure);
        if (response.status == 404) return null;
        if (!isSuccess(response.status)) return statusFailed(arena, what, response, failure);
        return response.body;
    }

    /// Saves a snapshot of the session and returns its id. A snapshot is
    /// never sent twice.
    pub fn snapshot(self: Client, arena: std.mem.Allocator, session: []const u8, expiration_ms: u64, failure: *Failure) Error![]const u8 {
        const what: []const u8 = "saving a snapshot";
        const request = api.snapshot(arena, self.team, session, expiration_ms) catch |err| return buildFailed(arena, what, err, failure);
        const response = try self.send(arena, what, request, .{ .retry_safe = false }, failure);
        if (!isSuccess(response.status)) return statusFailed(arena, what, response, failure);
        return api.parseSnapshotId(response.body) catch |err| return unreadable(arena, what, err, failure);
    }

    /// Reads whether a snapshot still exists. A 404 answer means it is gone.
    pub fn snapshotExists(self: Client, arena: std.mem.Allocator, id: []const u8, failure: *Failure) Error!bool {
        const what = try arena.print("reading snapshot {s}", .{id});
        const request = api.getSnapshot(arena, self.team, self.project, id) catch |err| return buildFailed(arena, what, err, failure);
        const response = try self.send(arena, what, request, .{}, failure);
        if (response.status == 404) return false;
        if (!isSuccess(response.status)) return statusFailed(arena, what, response, failure);
        return true;
    }

    /// Stops a session.
    pub fn stopSession(self: Client, arena: std.mem.Allocator, session: []const u8, failure: *Failure) Error!void {
        const what: []const u8 = "stopping the sandbox";
        const request = api.stopSession(arena, self.team, session) catch |err| return buildFailed(arena, what, err, failure);
        const response = try self.send(arena, what, request, .{}, failure);
        if (!isSuccess(response.status)) return statusFailed(arena, what, response, failure);
    }

    fn send(
        self: Client,
        arena: std.mem.Allocator,
        what: []const u8,
        request: api.Request,
        shape: Shape,
        failure: *Failure,
    ) Error!Response {
        const call: Call = .{
            .base_url = self.base_url,
            .token = self.token,
            .request = request,
            .lines = shape.lines,
            .abort = shape.abort,
            .retry_safe = shape.retry_safe,
        };
        return self.transport.send(self.transport.context, arena, call) catch |err| transportFailed(self, arena, what, err, failure);
    }
};

/// Turns streamed lines into parsed log lines for the caller's sink.
const LogRelay = struct {
    sink: LogSink,
    arena: std.mem.Allocator,
    /// The error the sink returned, when it stopped the stream.
    failed: ?anyerror = null,

    fn onLine(context: *anyopaque, line: []const u8) anyerror!void {
        const relay: *LogRelay = @ptrCast(@alignCast(context));
        const parsed = api.parseLogLine(relay.arena, line) catch |err| switch (err) {
            error.UnexpectedAnswer => {
                debug_trace.logf("sandbox", "skipped log line: not JSON, {d} bytes", .{line.len});
                return;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        relay.sink.on_log(relay.sink.context, parsed) catch |err| {
            relay.failed = err;
            return err;
        };
    }
};

fn isSuccess(status: u16) bool {
    return status >= 200 and status < 300;
}

fn transportFailed(self: Client, arena: std.mem.Allocator, what: []const u8, err: anyerror, failure: *Failure) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.Aborted) {
        failure.message = try arena.print("{s} was stopped", .{what});
        return error.Aborted;
    }
    if (err == error.AnswerLost) {
        failure.message = try arena.print("{s}: the connection ended before the answer arrived, so it may have taken effect", .{what});
        return error.AnswerLost;
    }
    failure.message = try arena.print("{s} failed: could not reach {s} ({s})", .{ what, self.base_url, @errorName(err) });
    return error.SandboxApiFailed;
}

fn statusFailed(arena: std.mem.Allocator, what: []const u8, response: Response, failure: *Failure) Error {
    const detail = try api.errorMessage(arena, response.status, response.body);
    failure.message = try arena.print("{s} failed: {s}", .{ what, detail });
    failure.status = response.status;
    return error.SandboxApiFailed;
}

fn unreadable(arena: std.mem.Allocator, what: []const u8, err: api.ParseError, failure: *Failure) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    failure.message = try arena.print("{s} failed: the API sent an answer fx could not read", .{what});
    return error.SandboxApiFailed;
}

fn buildFailed(arena: std.mem.Allocator, what: []const u8, err: api.BuildError, failure: *Failure) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    failure.message = try arena.print("{s} failed: {s}", .{ what, @errorName(err) });
    return error.SandboxApiFailed;
}

/// One scripted answer for the fake API. `fail` makes the transport return that error.
const Scripted = struct {
    status: u16 = 200,
    body: []const u8 = "",
    lines: []const []const u8 = &.{},
    fail: ?anyerror = null,
};

/// A transport that answers from a script, in order, and records each request.
const FakeApi = struct {
    script: []const Scripted,
    next: usize = 0,
    seen: [32]Seen = undefined,
    seen_count: usize = 0,

    const Seen = struct { request: api.Request, retry_safe: bool };

    fn send(context: *anyopaque, arena: std.mem.Allocator, call: Call) anyerror!Response {
        _ = arena;
        const self: *FakeApi = @ptrCast(@alignCast(context));
        self.seen[self.seen_count] = .{ .request = call.request, .retry_safe = call.retry_safe };
        self.seen_count += 1;
        const step = self.script[self.next];
        self.next += 1;
        if (step.fail) |err| return err;
        if (call.lines) |sink| {
            for (step.lines) |line| try sink.on_line(sink.context, line);
        }
        return .{ .status = step.status, .body = step.body };
    }

    fn transport(self: *FakeApi) Transport {
        return .{ .context = self, .send = send };
    }
};

const LogRecorder = struct {
    lines: [8]api.LogLine = undefined,
    count: usize = 0,

    fn onLog(context: *anyopaque, line: api.LogLine) anyerror!void {
        const self: *LogRecorder = @ptrCast(@alignCast(context));
        self.lines[self.count] = line;
        self.count += 1;
    }
};

fn testClient(fake: *FakeApi) Client {
    return .{
        .transport = fake.transport(),
        .base_url = "https://api.test",
        .team = "team-a",
        .project = "proj",
        .token = "test-token",
    };
}

const boom = "{\"error\":{\"message\":\"boom\"}}";

test "createSandbox returns the session and maps conflicts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeApi = .{ .script = &[_]Scripted{
        .{ .status = 200, .body = "{\"sandbox\":{\"currentSessionId\":\"sbx_1\",\"status\":\"running\"}}" },
        .{ .status = 409 },
        .{ .status = 500, .body = boom },
    } };
    var failure: Failure = .{};
    const options: api.CreateOptions = .{ .name = "fx-1", .project = "proj", .persistent = false, .timeout_ms = 1000 };

    const sandbox = try testClient(&fake).createSandbox(arena, options, &failure);
    try std.testing.expectEqualStrings("sbx_1", sandbox.session_id);
    try std.testing.expect(!fake.seen[0].retry_safe);
    try std.testing.expectError(error.SandboxExists, testClient(&fake).createSandbox(arena, options, &failure));
    try std.testing.expectError(error.SandboxApiFailed, testClient(&fake).createSandbox(arena, options, &failure));
    try std.testing.expectEqualStrings("creating sandbox fx-1 failed: HTTP 500: boom", failure.message);
}

test "a refused request says its HTTP status" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeApi = .{ .script = &[_]Scripted{.{ .status = 404, .body = boom }} };
    var failure: Failure = .{};
    const options: api.CreateOptions = .{ .name = "fx-1", .project = "proj", .persistent = false, .timeout_ms = 1000 };

    try std.testing.expectError(error.SandboxApiFailed, testClient(&fake).createSandbox(arena, options, &failure));
    try std.testing.expectEqual(@as(?u16, 404), failure.status);
}

test "getSandbox treats 404 as missing and asks to resume" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeApi = .{ .script = &[_]Scripted{.{ .status = 404 }} };
    var failure: Failure = .{};

    const found = try testClient(&fake).getSandbox(arena, "sbx-1", true, &failure);
    try std.testing.expect(found == null);
    try std.testing.expect(std.mem.find(u8, fake.seen[0].request.target, "resume=true") != null);
}

test "deleteSandbox accepts 404" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeApi = .{ .script = &[_]Scripted{ .{ .status = 404 }, .{ .status = 204 } } };
    var failure: Failure = .{};

    try testClient(&fake).deleteSandbox(arena, "sbx-1", &failure);
    try testClient(&fake).deleteSandbox(arena, "sbx-1", &failure);
    try std.testing.expectEqual(api.Method.DELETE, fake.seen[0].request.method);
}

test "listByTag follows pagination" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeApi = .{ .script = &[_]Scripted{
        .{ .status = 200, .body = "{\"sandboxes\":[{\"name\":\"a\",\"status\":\"running\",\"tags\":{}},{\"name\":\"b\",\"status\":\"stopped\",\"tags\":{}}],\"pagination\":{\"next\":\"c2\"}}" },
        .{ .status = 200, .body = "{\"sandboxes\":[{\"name\":\"c\",\"status\":\"running\",\"tags\":{}}],\"pagination\":{\"next\":null}}" },
    } };
    var failure: Failure = .{};

    const found = try testClient(&fake).listByTag(arena, .{ .name = "fx", .value = "isolated" }, &failure);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("a", found[0].name);
    try std.testing.expectEqualStrings("c", found[2].name);
    try std.testing.expect(std.mem.find(u8, fake.seen[1].request.target, "cursor=c2") != null);
}

const endless_page: Scripted = .{ .status = 200, .body = "{\"sandboxes\":[],\"pagination\":{\"next\":\"more\"}}" };

test "listByTag stops after 20 pages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const endless: [max_list_pages]Scripted = @splat(endless_page);
    var fake: FakeApi = .{ .script = &endless };
    var failure: Failure = .{};

    try std.testing.expectError(error.SandboxApiFailed, testClient(&fake).listByTag(arena, .{ .name = "fx", .value = "isolated" }, &failure));
    try std.testing.expectEqualStrings("listing sandboxes failed: more than 20 pages", failure.message);
    try std.testing.expectEqual(@as(usize, max_list_pages), fake.seen_count);
}

test "runCommand streams parsed log lines in order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeApi = .{ .script = &[_]Scripted{.{ .status = 200, .lines = &[_][]const u8{
        "{\"command\":{\"id\":\"cmd_1\",\"exitCode\":null}}",
        "{\"data\":\"out1\\n\",\"stream\":\"stdout\"}",
        "not json",
        "{\"data\":\"err1\\n\",\"stream\":\"stderr\"}",
        "{\"command\":{\"id\":\"cmd_1\",\"exitCode\":3}}",
    } }} };
    var recorder: LogRecorder = .{};
    const sink: LogSink = .{ .context = &recorder, .on_log = LogRecorder.onLog };
    var failure: Failure = .{};

    try testClient(&fake).runCommand(arena, "sbx_1", .{ .args = &.{ "-lc", "echo hi" } }, sink, null, &failure);
    try std.testing.expectEqual(@as(usize, 4), recorder.count);
    switch (recorder.lines[0]) {
        .command => |command| {
            try std.testing.expectEqualStrings("cmd_1", command.id);
            try std.testing.expectEqual(@as(?i64, null), command.exit_code);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (recorder.lines[1]) {
        .output => |output| {
            try std.testing.expectEqual(api.Stream.stdout, output.stream);
            try std.testing.expectEqualStrings("out1\n", output.data);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (recorder.lines[2]) {
        .output => |output| {
            try std.testing.expectEqual(api.Stream.stderr, output.stream);
            try std.testing.expectEqualStrings("err1\n", output.data);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (recorder.lines[3]) {
        .command => |command| try std.testing.expectEqual(@as(?i64, 3), command.exit_code),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!fake.seen[0].retry_safe);
}

test "kill accepts a command that already ended" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeApi = .{ .script = &[_]Scripted{.{ .status = 409 }} };
    var failure: Failure = .{};

    try testClient(&fake).kill(arena, "sbx_1", "cmd_1", &failure);
}

test "readFile treats 404 as missing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeApi = .{ .script = &[_]Scripted{ .{ .status = 404 }, .{ .status = 200, .body = "abc" } } };
    var failure: Failure = .{};

    try std.testing.expect((try testClient(&fake).readFile(arena, "sbx_1", "/w/a.txt", &failure)) == null);
    const bytes = (try testClient(&fake).readFile(arena, "sbx_1", "/w/a.txt", &failure)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("abc", bytes);
}

test "transport errors say the API could not be reached" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeApi = .{ .script = &[_]Scripted{ .{ .fail = error.ConnectionRefused }, .{ .fail = error.Aborted }, .{ .fail = error.AnswerLost } } };
    var failure: Failure = .{};

    try std.testing.expectError(error.SandboxApiFailed, testClient(&fake).deleteSandbox(arena, "fx-1", &failure));
    try std.testing.expect(std.mem.find(u8, failure.message, "could not reach https://api.test") != null);

    var recorder: LogRecorder = .{};
    const sink: LogSink = .{ .context = &recorder, .on_log = LogRecorder.onLog };
    try std.testing.expectError(error.Aborted, testClient(&fake).runCommand(arena, "sbx_1", .{}, sink, null, &failure));
    try std.testing.expectEqualStrings("running a command was stopped", failure.message);

    try std.testing.expectError(error.AnswerLost, testClient(&fake).createSandbox(arena, .{
        .name = "fx-1",
        .project = "proj",
        .persistent = false,
        .timeout_ms = 600_000,
    }, &failure));
    try std.testing.expect(std.mem.find(u8, failure.message, "may have taken effect") != null);
}

test "every method reports a server error with its own name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const failing_step: Scripted = .{ .status = 500, .body = boom };
    const failing: [11]Scripted = @splat(failing_step);
    var fake: FakeApi = .{ .script = &failing };
    var failure: Failure = .{};
    var recorder: LogRecorder = .{};
    const sink: LogSink = .{ .context = &recorder, .on_log = LogRecorder.onLog };
    const create_options: api.CreateOptions = .{ .name = "fx-1", .project = "proj", .persistent = false, .timeout_ms = 1000 };

    try std.testing.expectError(error.SandboxApiFailed, testClient(&fake).createSandbox(arena, create_options, &failure));
    try std.testing.expectEqualStrings("creating sandbox fx-1 failed: HTTP 500: boom", failure.message);
    try std.testing.expectError(error.SandboxApiFailed, testClient(&fake).getSandbox(arena, "sbx-1", false, &failure));
    try std.testing.expectEqualStrings("reading sandbox sbx-1 failed: HTTP 500: boom", failure.message);
    try std.testing.expectError(error.SandboxApiFailed, testClient(&fake).deleteSandbox(arena, "sbx-1", &failure));
    try std.testing.expectEqualStrings("deleting sandbox sbx-1 failed: HTTP 500: boom", failure.message);
    try std.testing.expectError(error.SandboxApiFailed, testClient(&fake).listByTag(arena, .{ .name = "fx", .value = "isolated" }, &failure));
    try std.testing.expectEqualStrings("listing sandboxes failed: HTTP 500: boom", failure.message);
    try std.testing.expectError(error.SandboxApiFailed, testClient(&fake).runCommand(arena, "sbx_1", .{}, sink, null, &failure));
    try std.testing.expectEqualStrings("running a command failed: HTTP 500: boom", failure.message);
    try std.testing.expect(!fake.seen[4].retry_safe);
    try std.testing.expectError(error.SandboxApiFailed, testClient(&fake).kill(arena, "sbx_1", "cmd_1", &failure));
    try std.testing.expectEqualStrings("stopping a command failed: HTTP 500: boom", failure.message);
    try std.testing.expectError(error.SandboxApiFailed, testClient(&fake).waitCommand(arena, "sbx_1", "cmd_1", &failure));
    try std.testing.expectEqualStrings("waiting for a command failed: HTTP 500: boom", failure.message);
    try std.testing.expectError(error.SandboxApiFailed, testClient(&fake).writeArchive(arena, "sbx_1", "gz", "/w", &failure));
    try std.testing.expectEqualStrings("copying files into the sandbox failed: HTTP 500: boom", failure.message);
    try std.testing.expectError(error.SandboxApiFailed, testClient(&fake).readFile(arena, "sbx_1", "/w/a.txt", &failure));
    try std.testing.expectEqualStrings("reading /w/a.txt from the sandbox failed: HTTP 500: boom", failure.message);
    try std.testing.expectError(error.SandboxApiFailed, testClient(&fake).snapshot(arena, "sbx_1", 60000, &failure));
    try std.testing.expectEqualStrings("saving a snapshot failed: HTTP 500: boom", failure.message);
    try std.testing.expect(!fake.seen[9].retry_safe);
    try std.testing.expectError(error.SandboxApiFailed, testClient(&fake).stopSession(arena, "sbx_1", &failure));
    try std.testing.expectEqualStrings("stopping the sandbox failed: HTTP 500: boom", failure.message);
    try std.testing.expectEqual(@as(usize, 11), fake.seen_count);
}

test "successful answers are read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeApi = .{ .script = &[_]Scripted{
        .{ .status = 200, .body = "{\"command\":{\"id\":\"cmd_1\",\"exitCode\":0}}" },
        .{ .status = 200, .body = "{\"snapshotId\":\"snap_AbC123\"}" },
        .{ .status = 200 },
        .{ .status = 204 },
    } };
    var failure: Failure = .{};

    const command = try testClient(&fake).waitCommand(arena, "sbx_1", "cmd_1", &failure);
    try std.testing.expectEqualStrings("cmd_1", command.id);
    try std.testing.expectEqual(@as(?i64, 0), command.exit_code);
    const snap = try testClient(&fake).snapshot(arena, "sbx_1", 60000, &failure);
    try std.testing.expectEqualStrings("snap_AbC123", snap);
    try testClient(&fake).writeArchive(arena, "sbx_1", "gz", "/w", &failure);
    try testClient(&fake).stopSession(arena, "sbx_1", &failure);
}

test "unreadable answers and bad names are reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: FakeApi = .{ .script = &[_]Scripted{.{ .status = 200, .body = "{}" }} };
    var failure: Failure = .{};

    try std.testing.expectError(error.SandboxApiFailed, testClient(&fake).getSandbox(arena, "sbx-1", false, &failure));
    try std.testing.expectEqualStrings("reading sandbox sbx-1 failed: the API sent an answer fx could not read", failure.message);

    const bad_name: api.CreateOptions = .{ .name = "a/b", .project = "proj", .persistent = false, .timeout_ms = 1000 };
    try std.testing.expectError(error.SandboxApiFailed, testClient(&fake).createSandbox(arena, bad_name, &failure));
    try std.testing.expectEqualStrings("creating sandbox a/b failed: InvalidName", failure.message);
    try std.testing.expectEqual(@as(usize, 1), fake.seen_count);
}

fn socketPair() ![2]std.posix.socket_t {
    var handles: [2]std.posix.socket_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &handles) != 0) return error.SocketPairFailed;
    return handles;
}

fn closeSocket(handle: std.posix.socket_t) void {
    _ = std.c.close(handle);
}

test "attach after an abort refuses" {
    const pair = try socketPair();
    defer closeSocket(pair[0]);
    defer closeSocket(pair[1]);
    var abort: Abort = .{};
    abort.abort();
    try std.testing.expect(!abort.attach(pair[0]));
    try std.testing.expect(abort.wasRequested());
}

test "abort shuts an attached socket" {
    const pair = try socketPair();
    defer closeSocket(pair[0]);
    defer closeSocket(pair[1]);
    var abort: Abort = .{};
    try std.testing.expect(abort.attach(pair[0]));
    abort.abort();
    try std.testing.expect(abort.wasRequested());
    var ready = [_]std.posix.pollfd{.{ .fd = pair[0], .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expect((try std.posix.poll(&ready, 1000)) > 0);
    var buffer: [1]u8 = undefined;
    const count = std.posix.read(pair[0], &buffer) catch 0;
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "abort after detach touches nothing" {
    const pair = try socketPair();
    defer closeSocket(pair[0]);
    defer closeSocket(pair[1]);
    var abort: Abort = .{};
    try std.testing.expect(abort.attach(pair[0]));
    abort.detach();
    abort.abort();
    try std.testing.expect(abort.wasRequested());
    try std.testing.expectEqual(@as(isize, 1), std.c.write(pair[1], "x", 1));
    var buffer: [1]u8 = undefined;
    const count = try std.posix.read(pair[0], &buffer);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u8, 'x'), buffer[0]);
}
