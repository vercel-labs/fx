//! The sandbox lifecycle of the built-in runner (spec V3, V4, L5): the state file
//! `{S}/sandbox.json`, the create, resume and size calls, first-use setup, and
//! the generation marker `R/.git/fx-generation` with its manifest. Outside code
//! imports `vercel.zig`, not this file.

const std = @import("std");
const io_mod = @import("../../shared/io.zig");
const credentials = @import("credentials.zig");
const transport = @import("transport.zig");
const stream = @import("stream.zig");
const journal = @import("journal.zig");
const reply = @import("reply.zig");
const api = @import("api.zig");
const attempt = @import("attempt.zig");
const test_server = @import("test_server.zig");

const Allocator = std.mem.Allocator;

/// The session timeout a created sandbox asks for, in milliseconds (V3).
pub const session_timeout_ms: i64 = 2_700_000;
/// Memory per vCPU in a size PATCH, in MiB (V3: M = N x 2048).
pub const memory_mib_per_vcpu: u32 = 2048;
/// The largest vCPU count a reply or a size PATCH may carry.
pub const max_vcpus: u32 = 1024;
/// The largest `sandbox.json` read, in bytes.
pub const max_state_bytes: usize = 16 * 1024;
/// The largest `manifest.json` read, and the largest one written, in bytes (V5).
pub const max_manifest_bytes: usize = 64 * 1024 * 1024;
/// The most command output kept, in bytes.
pub const max_output_bytes: usize = 4 * 1024;
/// The longest failure detail, in bytes.
pub const max_detail_bytes: usize = 256;
/// The longest user name `id -un` may answer, in bytes.
pub const max_user_bytes: usize = 64;
/// Random bytes in a new generation, before hex encoding.
pub const generation_random_bytes: usize = 16;
/// The longest generation marker read back, in bytes.
pub const max_generation_bytes: usize = 128;

const state_file = "sandbox.json";
const manifest_file = "manifest.json";
const pending_dir = "pending";
const marker_suffix = "/.git/fx-generation";
const no_detail = "no detail";

pub const Error = std.mem.Allocator.Error || error{Refused};

pub fn Outcome(comptime T: type) type {
    return union(enum) {
        ok: T,
        failed: Failure,
    };
}

/// Why a step stopped. `status` is the HTTP status, or 0 when no answer arrived.
pub const Failure = struct {
    step: []const u8,
    status: u16,
    detail: []const u8,
};

pub const State = struct {
    name: []const u8,
    session_id: []const u8,
    expires_at_ms: i64,
    vcpus: u32,
    vcpus_requested: ?u32,
};

/// `kept`: the manifest's generation matched the marker. `reset`: the manifest and
/// `pending/` were cleared, so every file is pushed again.
pub const Generation = enum { kept, reset };

pub const Size = struct {
    wanted: u32,
    now: u32,
};

pub const Rejected = struct {
    wanted: u32,
    detail: []const u8,
};

pub const SizeNote = union(enum) {
    none,
    applies_next_session: Size,
    failed: Rejected,
};

pub const Session = struct {
    state: State,
    generation: Generation,
    size_note: SizeNote,
};

pub const Context = struct {
    /// An arena the caller frees. Results and failure details live as long as it.
    alloc: Allocator,
    cancel: *std.atomic.Value(bool),
    base: transport.BaseUrl,
    token: credentials.Token,
    trace: credentials.Trace,
    team_id: []const u8,
    project_id: []const u8,
    /// The sandbox name, `fx-{repo_key}` (L5).
    name: []const u8,
    /// R: the repository root, which is also its path in the sandbox.
    repo_root: []const u8,
    /// S: the state folder that holds `sandbox.json` and `manifest.json`.
    state_dir: *io_mod.VerifiedDir,
    /// The configured size, or null when none is set.
    vcpus: ?u32 = null,
    /// Set after a failed size PATCH. It is not sent again in this process (V3).
    patch_failed: bool = false,
    /// Set when `manifest.json` could not be parsed and was reset (V5, N26).
    manifest_reset: bool = false,
    /// The pending records a reset cleared without a bring-back (V4, N28).
    pending_cleared: usize = 0,
    /// The last refusal. `Error.Refused` leaves it here for `ensure` and `runCommand`.
    failure: Failure = .{ .step = "", .status = 0, .detail = "" },
    /// Tests only: the generation a new marker gets, in place of a random one.
    generation_override: ?[]const u8 = null,
    /// Set when a fold set a damaged journal aside. The run prints N31 for it (V9).
    journal_set_aside: bool = false,
    /// The run's mode. An isolated run never resumes a session (I3).
    mode: attempt.Mode = .remote,
    /// What the operation in progress has already used of its recovery budget (V3, V5).
    used: attempt.Used = .{},
    /// True while a new sandbox's first use runs (V4). A recovery inside it keeps only the
    /// resumed session: the first use that is still running sets the folder and the generation.
    first_use_open: bool = false,
};

pub const Command = struct {
    /// The step name the trace and a failure report show.
    step: []const u8,
    command: []const u8,
    args: []const []const u8,
    cwd: ?[]const u8 = null,
    sudo: bool = false,
};

pub const Output = struct {
    exit_code: i64,
    stdout: []const u8,
};

/// Brings the sandbox to a usable session (V3), records its size (V3), and reports
/// whether the manifest kept its generation (V4). A missing `sandbox.json` creates the
/// sandbox; an unreadable or malformed one is rebuilt through create or resume.
pub fn ensure(ctx: *Context) Outcome(Session) {
    return settle(Session, ctx, establish(ctx));
}

/// Runs one command as the session step `kind`. The plan in `attempt.zig` decides whether a 404 or
/// 410 recovers the session and runs the command again.
pub fn runCommand(ctx: *Context, session: *Session, command: Command, kind: attempt.Step) Outcome(Output) {
    return settle(Output, ctx, runCommandInner(ctx, session, command, kind));
}

pub fn settle(comptime T: type, ctx: *Context, result: Error!T) Outcome(T) {
    const value = result catch |err| return .{ .failed = switch (err) {
        error.Refused => ctx.failure,
        error.OutOfMemory => .{ .step = "sandbox", .status = 0, .detail = "out of memory" },
    } };
    return .{ .ok = value };
}

/// V3 and the size of V3, without the outcome wrapper. Callers that hold the V2 lock use this.
pub fn establish(ctx: *Context) Error!Session {
    var session: Session = if (try loadState(ctx)) |state| blk: {
        var loaded: Session = .{ .state = state, .generation = .kept, .size_note = .none };
        // V3: a record whose expiry has passed resumes before the first session call.
        if (ctx.mode == .remote and state.expires_at_ms <= io_mod.milliTimestamp()) try recover(ctx, &loaded);
        break :blk loaded;
    } else blk: {
        const obtained = try createFirst(ctx);
        var fresh: Session = .{ .state = obtained.state, .generation = .kept, .size_note = .none };
        ctx.first_use_open = obtained.created;
        defer ctx.first_use_open = false;
        fresh.generation = try complete(ctx, &fresh, obtained.created);
        break :blk fresh;
    };
    try applySize(ctx, &session);
    return session;
}

fn runCommandInner(ctx: *Context, session: *Session, command: Command, kind: attempt.Step) Error!Output {
    return execCommand(ctx, session.state.session_id, command) catch |err| {
        if (err != error.Refused) return err;
        switch (attempt.plan(kind, ctx.mode, attempt.statusOutcome(ctx.failure.status), ctx.used)) {
            .resume_session => {
                ctx.used.recovered = true;
                try recover(ctx, session);
                return execCommand(ctx, session.state.session_id, command);
            },
            else => return err,
        }
    };
}

/// A session call answered 404 or 410: one resume GET, creating the sandbox once if it is gone.
pub fn recover(ctx: *Context, session: *Session) Error!void {
    const obtained = try resumeOrCreate(ctx);
    session.state = obtained.state;
    // A resumed session inside a first use keeps its folder and generation for that first use,
    // which is still running and sets them (V4). Without this, the marker check would write into
    // a folder the cut-short first use never made.
    if (ctx.first_use_open and !obtained.created) return saveState(ctx, session.state);
    session.generation = try complete(ctx, session, obtained.created);
}

const Obtained = struct {
    state: State,
    created: bool,
};

/// V3 with no state file: create. A 409 means the sandbox exists, so one resume GET.
fn createFirst(ctx: *Context) Error!Obtained {
    const created = createSandbox(ctx) catch |err| {
        if (err != error.Refused or ctx.failure.status != 409) return err;
        return resumeOrCreate(ctx);
    };
    return .{ .state = created, .created = true };
}

/// One resume GET. A 404 means the sandbox was deleted, so it is created once.
fn resumeOrCreate(ctx: *Context) Error!Obtained {
    const resumed = resumeSandbox(ctx) catch |err| {
        if (err != error.Refused or ctx.failure.status != 404) return err;
        return .{ .state = try createSandbox(ctx), .created = true };
    };
    return .{ .state = resumed, .created = false };
}

/// Saves the state, sets up a new sandbox's first use, and checks the marker (V4).
fn complete(ctx: *Context, session: *Session, created: bool) Error!Generation {
    try saveState(ctx, session.state);
    if (created) try firstUse(ctx, session);
    return checkGeneration(ctx, session);
}

/// First use of a sandbox (V4): the user, the folder owned by that user, then the repository
/// and a new generation.
fn firstUse(ctx: *Context, session: *Session) Error!void {
    try ensureRoot(ctx, session);
    _ = try startGeneration(ctx, session);
}

/// The folder R, owned by the session's user. It touches neither the manifest nor `pending/`.
fn ensureRoot(ctx: *Context, session: *Session) Error!void {
    const who = try runCommandInner(ctx, session, .{ .step = "user", .command = "id", .args = &.{"-un"} }, .user);
    if (who.exit_code != 0) return refuse(ctx, "user", 0, "id -un failed");
    const user = std.mem.trim(u8, who.stdout, " \r\n\t");
    if (!validUser(user)) return refuse(ctx, "user", 0, "the user name is not valid");
    const setup = try runCommandInner(ctx, session, .{
        .step = "setup",
        .command = "bash",
        .args = &.{ "-c", "mkdir -p \"$1\" && chown \"$2\" \"$1\"", "fx", ctx.repo_root, user },
        .sudo = true,
    }, .setup);
    if (setup.exit_code != 0) return refuse(ctx, "setup", 0, "the sandbox folder could not be set up");
}

/// I3: the folder and the git repository an isolated sandbox needs before its push. Unlike
/// `firstUse` it never clears the repository's manifest or `pending/`. An isolated sandbox is never
/// recovered: a resume would name the persistent sandbox's create body, so a 404 or 410 refuses.
pub fn prepareIsolatedRoot(ctx: *Context, session: *Session) Error!void {
    try ensureRoot(ctx, session);
    const init = try runCommandInner(ctx, session, .{
        .step = "setup",
        .command = "bash",
        .args = &.{ "-c", "cd \"$1\" && git init -q", "fx", ctx.repo_root },
    }, .setup);
    if (init.exit_code != 0) return refuse(ctx, "setup", 0, "the repository could not be set up");
}

/// Clears the manifest and `pending/`, writes a new generation to the marker as the
/// session user, and records it in the manifest (V4).
fn startGeneration(ctx: *Context, session: *Session) Error![]const u8 {
    try resetManifest(ctx);
    const generation = try freshGeneration(ctx);
    const write = try runCommandInner(ctx, session, .{
        .step = "generation",
        .command = "bash",
        .args = &.{ "-c", "cd \"$1\" && git init -q && printf %s \"$2\" > .git/fx-generation", "fx", ctx.repo_root, generation },
    }, .generation);
    if (write.exit_code != 0) return refuse(ctx, "generation", 0, "the marker could not be written");
    const fresh = emptyManifestFor(generation);
    try commitManifest(ctx, &fresh);
    return generation;
}

/// Reads the marker with `cat` (V4). A missing marker is a nonzero exit. A marker that
/// does not match the manifest clears it, and a new generation is written.
fn checkGeneration(ctx: *Context, session: *Session) Error!Generation {
    const marker = try ctx.alloc.print("{s}{s}", .{ ctx.repo_root, marker_suffix });
    const read = try runCommandInner(ctx, session, .{ .step = "generation", .command = "cat", .args = &.{marker} }, .marker);
    const seen: ?[]const u8 = if (read.exit_code == 0) validGeneration(std.mem.trim(u8, read.stdout, " \r\n\t")) else null;
    const expected = (try readManifest(ctx)).generation;
    if (seen != null and expected != null and std.mem.eql(u8, seen.?, expected.?)) return .kept;
    _ = try startGeneration(ctx, session);
    return .reset;
}

/// A fs/write of one tar.gz body into R (V5). `x-cwd` names R, and the body goes with its
/// length. The answer comes back unread, so the caller decides what it means.
pub fn writeArchive(ctx: *Context, session: *Session, length: u64, source: *std.Io.Reader) Error!transport.Response {
    const path = try ctx.alloc.print("/v2/sandboxes/sessions/{s}/fs/write?teamId={s}", .{
        try escaped(ctx, session.state.session_id),
        try escaped(ctx, ctx.team_id),
    });
    const headers = [_]std.http.Header{.{ .name = "x-cwd", .value = ctx.repo_root }};
    return stream.callBuffered(ctx.alloc, ctx.cancel, ctx.base, ctx.token, ctx.trace, .{
        .step = "push",
        .method = .POST,
        .path = path,
        .headers = &headers,
        .body = .{ .sized = .{ .len = length, .source = source } },
        .content_type = "application/gzip",
        .limits = stream.fsWriteLimits(length),
    }) catch |err| return refuseError(ctx, "push", err);
}

/// Whether a fs/write answer says R is missing: a 400 whose `error.stderr` says `Cannot open` (V5).
/// A body that does not parse is not that answer. An allocation failure here reads as "not that
/// answer", and the caller then refuses the push with the status.
pub fn cannotOpen(alloc: Allocator, response: transport.Response) bool {
    if (response.status != 400) return false;
    const root = reply.parseRoot(alloc, response.body) catch return false;
    const object = reply.objectOf(root) catch return false;
    const error_object = reply.objectOf(object.get("error") orelse return false) catch return false;
    const stderr = switch (error_object.get("stderr") orelse return false) {
        .string => |text| text,
        else => return false,
    };
    return std.mem.find(u8, stderr, "Cannot open") != null;
}

/// R is missing (a fs/write answered `Cannot open`): the first-use steps run again (V4, V5).
/// That clears the manifest, so the next push sends everything.
pub fn repairRoot(ctx: *Context, session: *Session) Error!void {
    try firstUse(ctx, session);
    session.generation = .reset;
}

fn validGeneration(text: []const u8) ?[]const u8 {
    if (text.len == 0 or text.len > max_generation_bytes) return null;
    return text;
}

fn validUser(user: []const u8) bool {
    if (user.len == 0 or user.len > max_user_bytes) return false;
    for (user) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return true;
}

const SizeAction = enum { keep, clear_request, patch };

/// The size decision of V3: a size that is reported, or requested and not yet reported,
/// needs no call.
fn sizeAction(wanted: u32, state: State, patch_failed: bool) SizeAction {
    if (wanted == state.vcpus) return if (state.vcpus_requested == null) .keep else .clear_request;
    if (state.vcpus_requested == wanted) return .keep;
    if (patch_failed) return .keep;
    return .patch;
}

fn applySize(ctx: *Context, session: *Session) Error!void {
    const wanted = ctx.vcpus orelse return;
    switch (sizeAction(wanted, session.state, ctx.patch_failed)) {
        .keep => {},
        .clear_request => {
            session.state.vcpus_requested = null;
            try saveState(ctx, session.state);
        },
        .patch => {
            const answer = patchWithRecovery(ctx, session, wanted) catch |err| {
                if (err != error.Refused) return err;
                // V13: a rejected login stops the run before exec; it is not a size note.
                if (attempt.loginRejected(ctx.failure.status)) return err;
                ctx.patch_failed = true;
                session.size_note = .{ .failed = .{ .wanted = wanted, .detail = ctx.failure.detail } };
                return;
            };
            if (answer.expires_at_ms) |expires| session.state.expires_at_ms = expires;
            session.state.vcpus = answer.vcpus;
            session.state.vcpus_requested = if (answer.vcpus == wanted) null else wanted;
            if (answer.vcpus != wanted) {
                session.size_note = .{ .applies_next_session = .{ .wanted = wanted, .now = answer.vcpus } };
            }
            try saveState(ctx, session.state);
        },
    }
}

/// The size PATCH with V3's recovery: a 404 or 410 recovers the session once, then the PATCH runs again.
fn patchWithRecovery(ctx: *Context, session: *Session, wanted: u32) Error!Answer {
    return patchSize(ctx, wanted) catch |err| {
        if (err != error.Refused) return err;
        switch (attempt.plan(.patch, ctx.mode, attempt.statusOutcome(ctx.failure.status), ctx.used)) {
            .resume_session => {
                ctx.used.recovered = true;
                try recover(ctx, session);
                return patchSize(ctx, wanted);
            },
            else => return err,
        }
    };
}

/// The detail of a session that ended before the start request. The sandbox refusal and the exec
/// refusal both print it, so it is defined once (R1.8).
pub const session_ended_detail = "the session ended before the command started; run it again";
/// The detail of a call that Vercel refused for its login (V13). The N11 line does not print it.
pub const login_rejected_detail = "the login was rejected";

/// The extend before exec (V12). A 404 or 410 that the run's one resume can cover is resumed once,
/// and the extend runs again. A 404 or 410 the run cannot resume refuses the run before the start
/// request (N1). A 401 or 403 refuses the run with N11 (V13). Any other answer goes back to the caller for its note (V12).
pub fn extendBeforeExec(ctx: *Context, session: *Session) (stream.StreamError || Error)!u16 {
    var status = try extendOnce(ctx, session);
    while (true) {
        // V13: a rejected login stops the run before exec, with N11.
        if (attempt.loginRejected(status)) return refuse(ctx, "extend", status, login_rejected_detail);
        switch (attempt.plan(.extend, ctx.mode, attempt.statusOutcome(status), ctx.used)) {
            .resume_session => {
                ctx.used.recovered = true;
                try recover(ctx, session);
                status = try extendOnce(ctx, session);
            },
            .refuse => |reason| {
                if (reason == .session_ended) return refuse(ctx, "extend", status, session_ended_detail);
                return status;
            },
            else => return status,
        }
    }
}

fn extendOnce(ctx: *Context, session: *Session) (stream.StreamError || Error)!u16 {
    const status = try extendTime(ctx.alloc, ctx.cancel, ctx.base, ctx.token, ctx.trace, ctx.team_id, session.state.session_id);
    if (status == 404 or status == 410) markGone(ctx);
    return status;
}

/// The path of one call on a session: `/v2/sandboxes/sessions/{session}/{rest}?{query}teamId={team}`.
/// `rest` is already escaped, and `query` is empty or ends in `&`. Every session call builds
/// its path here, so the shape is written once (R1.8).
pub fn sessionPath(alloc: Allocator, team_id: []const u8, session_id: []const u8, rest: []const u8, query: []const u8) Allocator.Error![]u8 {
    const session = try api.escapeComponent(alloc, session_id);
    defer alloc.free(session);
    const team = try api.escapeComponent(alloc, team_id);
    defer alloc.free(team);
    return alloc.print("/v2/sandboxes/sessions/{s}/{s}?{s}teamId={s}", .{ session, rest, query, team });
}

/// The `cmd` path of one session, shared by every command request (V4, V6, V9).
pub fn commandPath(ctx: *Context, session_id: []const u8) Allocator.Error![]u8 {
    return sessionPath(ctx.alloc, ctx.team_id, session_id, "cmd", "");
}

/// The manifest's temp files start with this name prefix (V5), for stale cleanup.
pub const manifest_temp_prefix = ".manifest.json.tmp.";

/// V12: an exec or a push extends the session when less than this remains (30 minutes).
pub const extend_below_ms: i64 = 30 * 60 * 1000;
/// V12: the time one extend call adds (1,800,000 ms).
pub const extend_duration_ms: i64 = 30 * 60 * 1000;

const ExtendBody = struct {
    duration: i64,
};

/// `POST …/extend-timeout` (V12). Returns the status; a caller reports a failure as one `fx:` line.
/// An ordinary call: its deadline is the buffered call's (V11).
pub fn extendTime(alloc: Allocator, cancel: *std.atomic.Value(bool), base: transport.BaseUrl, token: credentials.Token, trace: credentials.Trace, team_id: []const u8, session_id: []const u8) stream.StreamError!u16 {
    const path = try sessionPath(alloc, team_id, session_id, "extend-timeout", "");
    defer alloc.free(path);
    const body = try encodeJson(alloc, ExtendBody{ .duration = extend_duration_ms });
    defer alloc.free(body);
    var source: std.Io.Reader = .fixed(body);
    const response = try stream.callBuffered(alloc, cancel, base, token, trace, .{
        .step = "extend",
        .method = .POST,
        .path = path,
        .body = .{ .sized = .{ .len = body.len, .source = &source } },
        .limits = stream.buffered_limits,
    });
    defer response.deinit(alloc);
    return response.status;
}

const KillBody = struct {
    signal: u8,
};

/// `POST …/cmd/{id}/kill` with `signal` (V10). Returns the status.
pub fn killCommand(alloc: Allocator, cancel: *std.atomic.Value(bool), base: transport.BaseUrl, token: credentials.Token, trace: credentials.Trace, team_id: []const u8, session_id: []const u8, id: []const u8, signal: u8, limits: stream.Limits) stream.StreamError!u16 {
    const escaped_id = try api.escapeComponent(alloc, id);
    defer alloc.free(escaped_id);
    const rest = try alloc.print("cmd/{s}/kill", .{escaped_id});
    defer alloc.free(rest);
    const path = try sessionPath(alloc, team_id, session_id, rest, "");
    defer alloc.free(path);
    const body = try encodeJson(alloc, KillBody{ .signal = signal });
    defer alloc.free(body);
    var source: std.Io.Reader = .fixed(body);
    const response = try stream.callBuffered(alloc, cancel, base, token, trace, .{
        .step = "kill",
        .method = .POST,
        .path = path,
        .body = .{ .sized = .{ .len = body.len, .source = &source } },
        .limits = limits,
    });
    defer response.deinit(alloc);
    return response.status;
}

fn execCommand(ctx: *Context, session_id: []const u8, command: Command) Error!Output {
    const path = try commandPath(ctx, session_id);
    const body = try encodeJsonOmitNulls(ctx.alloc, CommandBody{
        .command = command.command,
        .args = command.args,
        .cwd = command.cwd,
        .sudo = if (command.sudo) true else null,
    });
    var source: std.Io.Reader = .fixed(body);
    const line_stream = stream.open(ctx.alloc, ctx.cancel, ctx.base, ctx.token, ctx.trace, .{
        .step = command.step,
        .method = .POST,
        .path = path,
        .body = .{ .sized = .{ .len = body.len, .source = &source } },
        .limits = stream.exec_limits,
    }) catch |err| return refuseError(ctx, command.step, err);
    defer line_stream.close();
    if (line_stream.status != 200) return refuse(ctx, command.step, line_stream.status, "the command was refused");
    return readOutput(ctx, command.step, line_stream);
}

fn readOutput(ctx: *Context, step: []const u8, line_stream: *stream.Stream) Error!Output {
    var stdout: std.ArrayList(u8) = .empty;
    var exit_code: ?i64 = null;
    while (line_stream.nextLine() catch |err| return refuseError(ctx, step, err)) |bytes| {
        switch (try commandLine(ctx, step, bytes)) {
            .output => |chunk| if (std.mem.eql(u8, chunk.stream, "stdout")) {
                if (stdout.items.len + chunk.data.len > max_output_bytes) {
                    return refuse(ctx, step, 0, "the command output is too large");
                }
                try stdout.appendSlice(ctx.alloc, chunk.data);
            },
            .exit => |code| exit_code = code,
            .running => {},
        }
    }
    const code = exit_code orelse return refuse(ctx, step, 0, "the command did not finish");
    return .{ .exit_code = code, .stdout = try stdout.toOwnedSlice(ctx.alloc) };
}

const Chunk = struct {
    stream: []const u8,
    data: []const u8,
};

const Line = union(enum) {
    output: Chunk,
    exit: i64,
    running,
};

fn commandLine(ctx: *Context, step: []const u8, bytes: []const u8) Error!Line {
    return parseLine(ctx.alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadReply => return refuse(ctx, step, 0, "the command output is malformed"),
    };
}

/// One line of a command's stream: an output chunk, the exit code, or a command line
/// that has not finished. Outside bytes, so every field is checked.
fn parseLine(arena: Allocator, bytes: []const u8) reply.ParseError!Line {
    const object = try reply.objectOf(try reply.parseRoot(arena, bytes));
    if (object.get("command")) |command_value| {
        const command = try reply.objectOf(command_value);
        return switch (command.get("exitCode") orelse return error.BadReply) {
            .integer => |code| .{ .exit = code },
            .null => .running,
            else => error.BadReply,
        };
    }
    const name = switch (object.get("stream") orelse return error.BadReply) {
        .string => |text| text,
        else => return error.BadReply,
    };
    const data = switch (object.get("data") orelse return error.BadReply) {
        .string => |text| text,
        else => return error.BadReply,
    };
    return .{ .output = .{ .stream = name, .data = data } };
}

fn createSandbox(ctx: *Context) Error!State {
    const path = try ctx.alloc.print("/v3/sandboxes?teamId={s}", .{try escaped(ctx, ctx.team_id)});
    const body = try encodeJsonOmitNulls(ctx.alloc, CreateBody{
        .name = ctx.name,
        .projectId = ctx.project_id,
        .timeout = session_timeout_ms,
        .resources = if (ctx.vcpus) |vcpus| .{ .vcpus = vcpus } else null,
    });
    const answer = try answerOf(ctx, "create", try callJson(ctx, "create", .POST, path, body));
    return stateOf(ctx, "create", answer);
}

fn resumeSandbox(ctx: *Context) Error!State {
    const path = try ctx.alloc.print("/v2/sandboxes/{s}?projectId={s}&resume=true&teamId={s}", .{
        try escaped(ctx, ctx.name),
        try escaped(ctx, ctx.project_id),
        try escaped(ctx, ctx.team_id),
    });
    const answer = try answerOf(ctx, "resume", try callJson(ctx, "resume", .GET, path, null));
    return stateOf(ctx, "resume", answer);
}

fn patchSize(ctx: *Context, wanted: u32) Error!Answer {
    if (wanted < 1 or wanted > max_vcpus) return refuse(ctx, "size", 0, "the size is out of range");
    const path = try ctx.alloc.print("/v2/sandboxes/{s}?projectId={s}&teamId={s}", .{
        try escaped(ctx, ctx.name),
        try escaped(ctx, ctx.project_id),
        try escaped(ctx, ctx.team_id),
    });
    const body = try sizeBody(ctx.alloc, wanted);
    return answerOf(ctx, "size", try callJson(ctx, "size", .PATCH, path, body));
}

/// The size PATCH body. The range is checked by the caller, so the product cannot overflow.
fn sizeBody(alloc: Allocator, wanted: u32) Allocator.Error![]u8 {
    return encodeJson(alloc, SizeBody{ .resources = .{
        .vcpus = wanted,
        .memory = wanted * memory_mib_per_vcpu,
    } });
}

fn stateOf(ctx: *Context, step: []const u8, answer: Answer) Error!State {
    const session_id = answer.session_id orelse return refuse(ctx, step, answer.status, "the answer has no session");
    const expires = answer.expires_at_ms orelse return refuse(ctx, step, answer.status, "the answer has no expiry");
    return .{
        .name = ctx.name,
        .session_id = session_id,
        .expires_at_ms = expires,
        .vcpus = answer.vcpus,
        .vcpus_requested = null,
    };
}

const Answer = struct {
    status: u16 = 0,
    vcpus: u32,
    session_id: ?[]const u8,
    expires_at_ms: ?i64,
};

/// A sandbox answer. A non-2xx status is a refusal, with the message from its body.
fn answerOf(ctx: *Context, step: []const u8, response: transport.Response) Error!Answer {
    if (response.status < 200 or response.status > 299) return refuseStatus(ctx, step, response);
    var problem: reply.Problem = .{};
    var answer = parseSandbox(ctx.alloc, response.body, &problem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadReply => {
            const reason = try problem.describe(ctx.alloc);
            return refuse(ctx, step, response.status, try ctx.alloc.print("{s}: the answer is malformed: {s}", .{ step, reason }));
        },
    };
    answer.status = response.status;
    return answer;
}

pub fn refuseStatus(ctx: *Context, step: []const u8, response: transport.Response) Error {
    const message = try errorMessage(ctx.alloc, response.body);
    const names_vcpus = response.status == 400 and
        (std.mem.find(u8, response.body, "vcpus") != null or std.mem.find(u8, response.body, "resources") != null);
    const detail = if (names_vcpus) try ctx.alloc.print("vcpus: {s}", .{message}) else message;
    return refuse(ctx, step, response.status, detail);
}

/// The `error.message` of an error answer, bounded. Any other body has no detail.
fn errorMessage(alloc: Allocator, body: []const u8) Allocator.Error![]const u8 {
    const root = reply.parseRoot(alloc, body) catch |err| return detailFallback(err);
    const object = reply.objectOf(root) catch |err| return detailFallback(err);
    const error_value = object.get("error") orelse return no_detail;
    const error_object = reply.objectOf(error_value) catch |err| return detailFallback(err);
    return reply.requiredText(alloc, error_object.get("message"), max_detail_bytes) catch |err| detailFallback(err);
}

fn detailFallback(err: reply.ParseError) Allocator.Error![]const u8 {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadReply => no_detail,
    };
}

/// A sandbox answer, read in the order fx needs its fields. A field that fails is recorded in
/// `problem` by its path, so the N1 line can name it (V3).
fn parseSandbox(arena: Allocator, bytes: []const u8, problem: *reply.Problem) reply.ParseError!Answer {
    const root = try reply.rootOf(arena, bytes, problem);
    const sandbox = try reply.objectField(root.get("sandbox"), "sandbox", problem);
    var answer: Answer = .{
        .vcpus = try vcpuCount(sandbox.get("vcpus"), "sandbox.vcpus", problem),
        .session_id = null,
        .expires_at_ms = null,
    };
    if (sandbox.get("expiresAt")) |value| answer.expires_at_ms = try reply.integerField(value, "sandbox.expiresAt", problem);
    if (root.get("session")) |session_value| {
        const session = try reply.objectField(session_value, "session", problem);
        answer.session_id = try reply.textField(arena, session.get("id"), "session.id", api.max_id_bytes, problem);
        if (answer.expires_at_ms == null) {
            const started = try reply.integerField(session.get("startedAt"), "session.startedAt", problem);
            const timeout = try reply.integerField(session.get("timeout"), "session.timeout", problem);
            answer.expires_at_ms = std.math.add(i64, started, timeout) catch return problem.fail("session.timeout", .out_of_range);
        }
    }
    return answer;
}

fn integerOf(value: std.json.Value) reply.ParseError!i64 {
    return switch (value) {
        .integer => |integer| integer,
        else => error.BadReply,
    };
}

/// A size from 1 to `max_vcpus`. `field` is the path the problem names when it fails.
fn vcpuCount(value: ?std.json.Value, field: []const u8, problem: *reply.Problem) reply.ParseError!u32 {
    const number = try reply.integerField(value, field, problem);
    if (number < 1 or number > max_vcpus) return problem.fail(field, .out_of_range);
    return @intCast(number);
}

fn parseState(arena: Allocator, bytes: []const u8) reply.ParseError!State {
    var problem: reply.Problem = .{};
    const object = try reply.objectOf(try reply.parseRoot(arena, bytes));
    const expires = try integerOf(object.get("expires_at_ms") orelse return error.BadReply);
    if (expires < 0) return error.BadReply;
    const requested: ?u32 = if (object.get("vcpus_requested")) |value| switch (value) {
        .null => null,
        else => try vcpuCount(value, "vcpus_requested", &problem),
    } else null;
    return .{
        .name = try reply.requiredText(arena, object.get("name"), api.max_name_bytes),
        .session_id = try reply.requiredText(arena, object.get("session_id"), api.max_id_bytes),
        .expires_at_ms = expires,
        .vcpus = try vcpuCount(object.get("vcpus"), "vcpus", &problem),
        .vcpus_requested = requested,
    };
}

/// A call's JSON body. Its reply is read through the bounded buffered call (V11).
fn callJson(ctx: *Context, step: []const u8, method: std.http.Method, path: []const u8, body: ?[]const u8) Error!transport.Response {
    var source: std.Io.Reader = .fixed(body orelse "");
    const sent: stream.Body = if (body) |bytes| .{ .sized = .{ .len = bytes.len, .source = &source } } else .none;
    return stream.callBuffered(ctx.alloc, ctx.cancel, ctx.base, ctx.token, ctx.trace, .{
        .step = step,
        .method = method,
        .path = path,
        .body = sent,
    }) catch |err| return refuseError(ctx, step, err);
}

fn escaped(ctx: *Context, text: []const u8) Allocator.Error![]u8 {
    return api.escapeComponent(ctx.alloc, text);
}

/// A failure that is not an HTTP answer: an allocation failure passes up, anything else is refused.
pub fn refuseError(ctx: *Context, step: []const u8, err: anyerror) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.Refused) return error.Refused;
    if (err == error.Canceled) return refuse(ctx, step, 0, "Cancelled");
    return refuse(ctx, step, 0, @errorName(err));
}

pub fn refuse(ctx: *Context, step: []const u8, status: u16, detail: []const u8) error{Refused} {
    ctx.failure = .{ .step = step, .status = status, .detail = detail };
    if (status == 404 or status == 410) markGone(ctx);
    return error.Refused;
}

/// V3: a session call answered 404 or 410, so the session is dead. Its record is marked expired (expiry 0)
/// as soon as the answer is seen, so a run that stops or fails after this still leaves the next run to resume
/// before its first call. A recovery writes the new record. Best effort: a record that cannot be read or
/// written keeps its expiry, and the next call's 410 recovers as before. The caller owns `alloc`, and no
/// other thread may write the record meanwhile.
pub fn markExpiredIn(state_dir: *io_mod.VerifiedDir, alloc: Allocator) void {
    const bytes = (readVerified(alloc, state_dir, state_file, max_state_bytes) catch return) orelse return;
    var state = parseState(alloc, bytes) catch return;
    state.expires_at_ms = 0;
    const encoded = encodeJson(alloc, state) catch return;
    io_mod.durableReplaceVerified(alloc, state_dir, state_file, encoded) catch return;
}

/// `markExpiredIn` for this run's record. Only remote runs have one (I3).
pub fn markGone(ctx: *Context) void {
    if (ctx.mode != .remote) return;
    markExpiredIn(ctx.state_dir, ctx.alloc);
}

const CreateBody = struct {
    name: []const u8,
    projectId: []const u8,
    persistent: bool = true,
    timeout: i64,
    resources: ?CreateResources = null,
    networkPolicy: ?NetworkBody = null,
};

/// The `networkPolicy` of an isolated sandbox (I2): `mode` is `deny-all`, `allow-all` or `custom`.
pub const NetworkBody = struct {
    mode: []const u8,
    allowedDomains: ?[]const []const u8 = null,
};

/// I2: the create call of an isolated run, a sandbox that is not persistent and has its network policy.
pub fn createIsolated(ctx: *Context, network: NetworkBody) Error!State {
    const path = try ctx.alloc.print("/v3/sandboxes?teamId={s}", .{try escaped(ctx, ctx.team_id)});
    const body = try encodeJsonOmitNulls(ctx.alloc, CreateBody{
        .name = ctx.name,
        .projectId = ctx.project_id,
        .persistent = false,
        .timeout = session_timeout_ms,
        .resources = if (ctx.vcpus) |vcpus| .{ .vcpus = vcpus } else null,
        .networkPolicy = network,
    });
    const answer = try answerOf(ctx, "create", try callJson(ctx, "create", .POST, path, body));
    return stateOf(ctx, "create", answer);
}

/// I4 and I1: deletes one sandbox of this project by name. A refused delete is an error.
pub fn deleteSandboxNamed(ctx: *Context, name: []const u8) Error!void {
    const path = try ctx.alloc.print("/v2/sandboxes/{s}?projectId={s}&teamId={s}", .{
        try escaped(ctx, name),
        try escaped(ctx, ctx.project_id),
        try escaped(ctx, ctx.team_id),
    });
    const response = try callJson(ctx, "delete", .DELETE, path, null);
    if (response.status < 200 or response.status > 299) return refuseStatus(ctx, "delete", response);
}

/// I1: one page of this project's sandboxes whose names start with `prefix`, in name order. `cursor`
/// is the `pagination.next` of the page before, or null for the first page.
pub fn listIsolatedPage(ctx: *Context, prefix: []const u8, cursor: ?[]const u8) Error!transport.Response {
    const team = try escaped(ctx, ctx.team_id);
    const project = try escaped(ctx, ctx.project_id);
    const name_prefix = try escaped(ctx, prefix);
    const path = if (cursor) |until|
        try ctx.alloc.print("/v2/sandboxes?project={s}&sortBy=name&namePrefix={s}&until={s}&teamId={s}", .{ project, name_prefix, try escaped(ctx, until), team })
    else
        try ctx.alloc.print("/v2/sandboxes?project={s}&sortBy=name&namePrefix={s}&teamId={s}", .{ project, name_prefix, team });
    return callJson(ctx, "list", .GET, path, null);
}

const CreateResources = struct {
    vcpus: u32,
};

const SizeResources = struct {
    vcpus: u32,
    memory: u32,
};

const SizeBody = struct {
    resources: SizeResources,
};

pub const CommandBody = struct {
    command: []const u8,
    args: []const []const u8,
    cwd: ?[]const u8 = null,
    env: struct {} = .{},
    wait: bool = true,
    logs: bool = true,
    sudo: ?bool = null,
};

/// Encodes one JSON value. Allocation failure is the only error the encoder has.
fn encodeJson(alloc: Allocator, value: anytype) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    std.json.Stringify.value(value, .{}, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

/// `encodeJson` with null optional fields left out, as the Vercel API expects.
pub fn encodeJsonOmitNulls(alloc: Allocator, value: anytype) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

fn loadState(ctx: *Context) Error!?State {
    const bytes = (readVerified(ctx.alloc, ctx.state_dir, state_file, max_state_bytes) catch |err| return refuseError(ctx, "state", err)) orelse return null;
    return parseState(ctx.alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadReply => null,
    };
}

fn saveState(ctx: *Context, state: State) Error!void {
    const bytes = try encodeJson(ctx.alloc, state);
    io_mod.durableReplaceVerified(ctx.alloc, ctx.state_dir, state_file, bytes) catch |err| return refuseError(ctx, "state", err);
}

pub const FileRecord = struct {
    size: u64,
    mtime_ns: i64,
    sha256: []const u8,
};

pub const FileMap = std.array_hash_map.String(FileRecord);

/// `manifest.json` (V5): the generation the remote folder was last synced to, and the
/// files pushed. A file that is missing, malformed, or over the entry limit is read as
/// empty, so the next push sends everything again.
/// One file a bring-back recorded, or one file under a bring-back root at run start (V9).
pub const BringBackFile = struct {
    rel: []const u8,
    size: u64,
    mtime_ns: i64,
};

pub const Manifest = struct {
    generation: ?[]const u8,
    files: FileMap,
    /// The SHA-256 (hex) of the ignore rules last written to `R/.git/info/exclude` (V5).
    excludes: ?[]const u8,
    /// Paths over one run's caps, to bring back at the next run (V9).
    pending_back: []const []const u8,
    /// What a bring-back last wrote at each path, so a later bring-back may write over it (V9).
    brought: FileMap,
    /// `size mtime` of each file over the size limit that N8 already counted (V9).
    skipped: []const []const u8,
    /// The SHA-256 (hex) of the bring-back roots last written to `.git/fx-bring-back` (V9).
    bring_back_roots: ?[]const u8,
    /// The SHA-256 (hex) of the pending names last written to `.git/fx-pending-back` (V9).
    pending_sha: ?[]const u8 = null,
};

pub const max_manifest_files: usize = 100_000;
/// The most files one bring-back streams and writes (V9). The script applies it before it streams,
/// and files past it are deferred to the next run.
pub const max_back_files: usize = 2_000;
/// The most bytes one bring-back streams and writes, by file size (V9).
pub const max_back_bytes: u64 = 64 * 1024 * 1024;
/// The largest file a bring-back brings back (V9). A bigger one is only reported, as `skipped`.
pub const max_back_file_bytes: u64 = 64 * 1024 * 1024;
/// The most names `manifest.pending_back` keeps (V9). Past it, files are only counted (N8).
pub const max_pending_names: usize = 10_000;
/// The most `brought` records a manifest keeps; the oldest go first (V9).
pub const max_brought_entries: usize = 20_000;
/// The longest repository path the manifest and the bring-back accept, in bytes.
pub const max_repo_path_bytes: usize = 1024;
/// The most files one bring-back baseline holds: the same limit as an `include` walk (V9).
pub const max_baseline_files: usize = 10_000;
const max_skipped_text_bytes: usize = 128;
const sha256_hex_bytes: usize = 64;

pub fn readManifest(ctx: *Context) Error!Manifest {
    const bytes = (readVerified(ctx.alloc, ctx.state_dir, manifest_file, max_manifest_bytes) catch |err| return refuseError(ctx, "manifest", err)) orelse return emptyManifest();
    return parseManifest(ctx.alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadReply => {
            ctx.manifest_reset = true;
            return emptyManifest();
        },
    };
}

/// The refusal for a manifest the reader would not accept (V5): more files than
/// `max_manifest_files`, or an encoding over `max_manifest_bytes`. Null when the reader accepts it,
/// so the runner never writes a sync record it cannot read back.
pub fn sizeRefusal(alloc: Allocator, manifest: *const Manifest) Allocator.Error!?[]const u8 {
    return refusalWithin(alloc, manifest, max_manifest_files, max_manifest_bytes);
}

fn refusalWithin(alloc: Allocator, manifest: *const Manifest, max_files: usize, max_bytes: usize) Allocator.Error!?[]const u8 {
    const files = manifest.files.count();
    if (files > max_files) {
        return try alloc.print("{d} files, more than the {d} a sync record can hold", .{ files, max_files });
    }
    const bytes = try encodeManifest(alloc, manifest);
    if (bytes.len > max_bytes) {
        return try alloc.print("{d} files make a sync record of {d} bytes, more than the {d} it can hold", .{ files, bytes.len, max_bytes });
    }
    return null;
}

/// The manifest of a new generation: nothing pushed, brought, or skipped yet.
fn emptyManifestFor(generation: []const u8) Manifest {
    var manifest = emptyManifest();
    manifest.generation = generation;
    return manifest;
}

/// The manifest of a sandbox that has no sync record yet, for an isolated push (I3).
pub fn emptyManifest() Manifest {
    return .{
        .generation = null,
        .files = .empty,
        .excludes = null,
        .pending_back = &.{},
        .brought = .empty,
        .skipped = &.{},
        .bring_back_roots = null,
    };
}

fn parseManifest(arena: Allocator, bytes: []const u8) reply.ParseError!Manifest {
    if (bytes.len > max_manifest_bytes) return error.BadReply;
    var scanner = std.json.Scanner.initCompleteInput(arena, bytes);
    defer scanner.deinit();
    switch (try nextToken(arena, &scanner)) {
        .object_begin => {},
        else => return error.BadReply,
    }
    var manifest = emptyManifest();
    while (try memberName(arena, &scanner)) |name| {
        try applyMember(arena, &manifest, &scanner, name);
    }
    switch (try nextToken(arena, &scanner)) {
        .end_of_document => {},
        else => return error.BadReply,
    }
    return manifest;
}

const ManifestMember = enum { files, brought, generation, excludes, bring_back_roots, pending_sha, pending_back, skipped };
const RecordMember = enum { size, mtime_ns, sha256 };

/// Reads the value of one manifest member under its field's rules (V5). An unknown member is skipped
/// after its syntax is checked.
fn applyMember(arena: Allocator, manifest: *Manifest, scanner: *std.json.Scanner, name: []const u8) reply.ParseError!void {
    const member = std.meta.stringToEnum(ManifestMember, name) orelse return skipValue(scanner);
    switch (member) {
        .files => try parseRecords(arena, scanner, &manifest.files),
        .brought => try parseRecords(arena, scanner, &manifest.brought),
        .generation => manifest.generation = try textValue(arena, scanner, max_generation_bytes),
        .excludes => manifest.excludes = try textValue(arena, scanner, sha256_hex_bytes),
        .bring_back_roots => manifest.bring_back_roots = try textValue(arena, scanner, sha256_hex_bytes),
        .pending_sha => manifest.pending_sha = try textValue(arena, scanner, sha256_hex_bytes),
        .pending_back => manifest.pending_back = try textArray(arena, scanner, max_pending_names, max_repo_path_bytes),
        .skipped => manifest.skipped = try textArray(arena, scanner, max_manifest_files, max_skipped_text_bytes),
    }
}

/// A JSON object of path to file record, as `files` and `brought` hold them. A repeated object replaces
/// the earlier one, as the object reader's last-wins rule did. Records are read one at a time from the
/// token stream, so no tree of a record outlives it (V5).
fn parseRecords(arena: Allocator, scanner: *std.json.Scanner, files: *FileMap) reply.ParseError!void {
    switch (try nextToken(arena, scanner)) {
        .object_begin => {},
        else => return error.BadReply,
    }
    files.clearRetainingCapacity();
    var count: usize = 0;
    while (try memberName(arena, scanner)) |path| {
        count += 1;
        if (count > max_manifest_files) return error.BadReply;
        try files.put(arena, path, try recordOf(arena, scanner));
    }
}

/// One file record: its size, mtime and SHA-256, under the rules the object reader enforced (V5).
fn recordOf(arena: Allocator, scanner: *std.json.Scanner) reply.ParseError!FileRecord {
    switch (try nextToken(arena, scanner)) {
        .object_begin => {},
        else => return error.BadReply,
    }
    var size: ?u64 = null;
    var mtime_ns: ?i64 = null;
    var sha256: ?[]const u8 = null;
    while (try memberName(arena, scanner)) |name| {
        const member = std.meta.stringToEnum(RecordMember, name) orelse {
            try skipValue(scanner);
            continue;
        };
        switch (member) {
            .size => size = try unsignedToken(try nextToken(arena, scanner)),
            .mtime_ns => mtime_ns = try integerToken(try nextToken(arena, scanner)),
            .sha256 => sha256 = try textValue(arena, scanner, sha256_hex_bytes),
        }
    }
    const digest = sha256 orelse return error.BadReply;
    if (digest.len != sha256_hex_bytes) return error.BadReply;
    return .{
        .size = size orelse return error.BadReply,
        .mtime_ns = mtime_ns orelse return error.BadReply,
        .sha256 = digest,
    };
}

/// The next value, read as one required text (V5).
fn textValue(arena: Allocator, scanner: *std.json.Scanner, max: usize) reply.ParseError![]const u8 {
    return textOf(arena, try nextToken(arena, scanner), max);
}

/// A required text: a JSON string that is not empty and at most `max` bytes. It is copied out of the
/// reply, so it outlives the reply's bytes (V5).
fn textOf(arena: Allocator, token: std.json.Token, max: usize) reply.ParseError![]const u8 {
    const text = switch (token) {
        .string => |value| value,
        .allocated_string => |value| value,
        else => return error.BadReply,
    };
    if (text.len == 0 or text.len > max) return error.BadReply;
    return arena.dupe(u8, text);
}

/// A JSON array of at most `max_items` texts, each at most `max_bytes` long (V5).
fn textArray(arena: Allocator, scanner: *std.json.Scanner, max_items: usize, max_bytes: usize) reply.ParseError![]const []const u8 {
    switch (try nextToken(arena, scanner)) {
        .array_begin => {},
        else => return error.BadReply,
    }
    var texts: std.ArrayList([]const u8) = .empty;
    while (true) {
        const token = try nextToken(arena, scanner);
        switch (token) {
            .array_end => return texts.toOwnedSlice(arena),
            else => {},
        }
        if (texts.items.len == max_items) return error.BadReply;
        try texts.append(arena, try textOf(arena, token, max_bytes));
    }
}

/// A JSON integer that fits i64, read from its token. Any other number is a bad reply, as `integerOf` is.
fn integerToken(token: std.json.Token) reply.ParseError!i64 {
    const text = switch (token) {
        .number => |value| value,
        .allocated_number => |value| value,
        else => return error.BadReply,
    };
    return std.fmt.parseInt(i64, text, 10) catch error.BadReply;
}

fn unsignedToken(token: std.json.Token) reply.ParseError!u64 {
    const number = try integerToken(token);
    if (number < 0) return error.BadReply;
    return @intCast(number);
}

/// The next token of the manifest text. A bad token is a bad reply, and memory stays a memory error (V5).
fn nextToken(arena: Allocator, scanner: *std.json.Scanner) reply.ParseError!std.json.Token {
    return scanner.nextAlloc(arena, .alloc_if_needed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadReply,
    };
}

/// The next member name of an object, or null at its end (V5).
fn memberName(arena: Allocator, scanner: *std.json.Scanner) reply.ParseError!?[]const u8 {
    switch (try nextToken(arena, scanner)) {
        .object_end => return null,
        .string => |text| return text,
        .allocated_string => |text| return text,
        else => return error.BadReply,
    }
}

fn skipValue(scanner: *std.json.Scanner) reply.ParseError!void {
    scanner.skipValue() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadReply,
    };
}

fn unsignedOf(value: ?std.json.Value) reply.ParseError!u64 {
    const number = try integerOf(value orelse return error.BadReply);
    if (number < 0) return error.BadReply;
    return @intCast(number);
}

/// Writes `manifest.json` by durable replace (V5). Only a push that succeeded writes it.
pub fn commitManifest(ctx: *Context, manifest: *const Manifest) Error!void {
    if (manifest.generation == null) return refuse(ctx, "manifest", 0, "the manifest has no generation");
    const bytes = try encodeManifest(ctx.alloc, manifest);
    io_mod.durableReplaceVerified(ctx.alloc, ctx.state_dir, manifest_file, bytes) catch |err| return refuseError(ctx, "manifest", err);
}

pub fn encodeManifest(alloc: Allocator, manifest: *const Manifest) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    writeManifestJson(&out.writer, manifest) catch return error.OutOfMemory;
    return out.written();
}

/// A manifest without a generation omits the key, which the reader reads back as no generation. An
/// empty string is not a generation the reader accepts, so it is never written.
fn writeManifestJson(w: *std.Io.Writer, manifest: *const Manifest) !void {
    try w.writeAll("{");
    if (manifest.generation) |generation| {
        try w.writeAll("\"generation\":");
        try std.json.Stringify.value(generation, .{}, w);
        try w.writeAll(",");
    }
    try w.writeAll("\"pending_back\":");
    try std.json.Stringify.value(manifest.pending_back, .{}, w);
    try w.writeAll(",\"files\":");
    try writeRecords(w, &manifest.files);
    try w.writeAll(",\"brought\":");
    try writeRecords(w, &manifest.brought);
    try w.writeAll(",\"skipped\":");
    try std.json.Stringify.value(manifest.skipped, .{}, w);
    if (manifest.excludes) |hex| {
        try w.writeAll(",\"excludes\":");
        try std.json.Stringify.value(hex, .{}, w);
    }
    if (manifest.bring_back_roots) |hex| {
        try w.writeAll(",\"bring_back_roots\":");
        try std.json.Stringify.value(hex, .{}, w);
    }
    if (manifest.pending_sha) |hex| {
        try w.writeAll(",\"pending_sha\":");
        try std.json.Stringify.value(hex, .{}, w);
    }
    try w.writeAll("}");
}

fn writeRecords(w: *std.Io.Writer, files: *const FileMap) !void {
    try w.writeAll("{");
    var first = true;
    var entries = files.iterator();
    while (entries.next()) |entry| {
        if (!first) try w.writeAll(",");
        first = false;
        try std.json.Stringify.value(entry.key_ptr.*, .{}, w);
        try w.print(":{{\"size\":{d},\"mtime_ns\":{d},\"sha256\":", .{ entry.value_ptr.size, entry.value_ptr.mtime_ns });
        try std.json.Stringify.value(entry.value_ptr.sha256, .{}, w);
        try w.writeAll("}");
    }
    try w.writeAll("}");
}

/// The prefix of a run's stamp file in `R/.git` (V6): `fx-stamp-` and the run id.
pub const stamp_prefix = "fx-stamp-";
const run_id_hex_bytes: usize = 16;
const max_pending_bytes: usize = 4 * 1024 * 1024;

/// A run id is 16 lowercase hex digits, so its stamp is one plain file name.
pub fn validRunIdHex(run_id: []const u8) bool {
    if (run_id.len != run_id_hex_bytes) return false;
    for (run_id) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// The stamp name for a run id: `fx-stamp-` and the id.
pub fn stampName(alloc: Allocator, run_id: []const u8) Allocator.Error![]const u8 {
    return alloc.print("{s}{s}", .{ stamp_prefix, run_id });
}

/// True when `name` is a stamp name this module makes.
pub fn validStampName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, stamp_prefix)) return false;
    return validRunIdHex(name[stamp_prefix.len..]);
}

/// A run that ended without a bring-back (V9), as `{S}/pending/{run_id}` holds it.
pub const PendingWrite = struct {
    run_id: []const u8,
    started_ms: i64,
    /// The bring-back baseline of the run, when its command finished and its bring-back failed.
    /// Null for a run that ended 143 or 255: its bring-back outputs never come back from it.
    baseline: ?[]const BringBackFile,
};

pub const Pending = struct {
    run_id: []const u8,
    stamp: []const u8,
    started_ms: i64,
    baseline: ?[]const BringBackFile,
};

const PendingJson = struct {
    stamp: []const u8,
    started_ms: i64,
    baseline: ?[]const BringBackFile,
};

pub fn writePending(ctx: *Context, write: PendingWrite) Error!void {
    if (!validRunIdHex(write.run_id)) return refuse(ctx, "pending", 0, "the run id is not valid");
    const stamp = try stampName(ctx.alloc, write.run_id);
    var out: std.Io.Writer.Allocating = .init(ctx.alloc);
    std.json.Stringify.value(PendingJson{ .stamp = stamp, .started_ms = write.started_ms, .baseline = write.baseline }, .{}, &out.writer) catch return error.OutOfMemory;
    var dir = io_mod.openOrCreateVerifiedPrivateDir(ctx.state_dir, pending_dir) catch |err| return refuseError(ctx, "pending", err);
    defer dir.close();
    io_mod.durableReplaceVerified(ctx.alloc, &dir, write.run_id, out.written()) catch |err| return refuseError(ctx, "pending", err);
}

/// Every pending run that parses, in `pending/` (V9). A file that does not parse is left out.
pub fn readPending(arena: Allocator, ctx: *Context) Error![]const Pending {
    var dir = (io_mod.openVerifiedPrivateDirIfPresent(ctx.state_dir, pending_dir) catch |err| return refuseError(ctx, "pending", err)) orelse return &.{};
    defer dir.close();
    const io = io_mod.getIo();
    var list: std.ArrayList(Pending) = .empty;
    var entries = dir.dir.iterate();
    while (entries.next(io) catch null) |entry| {
        if (entry.kind != .file or !validRunIdHex(entry.name)) continue;
        const bytes = (readVerified(arena, &dir, entry.name, max_pending_bytes) catch |err| return refuseError(ctx, "pending", err)) orelse continue;
        var parsed = parsePending(arena, bytes) catch continue;
        if (!std.mem.eql(u8, parsed.stamp, try stampName(arena, entry.name))) continue;
        parsed.run_id = try arena.dupe(u8, entry.name);
        try list.append(arena, parsed);
    }
    return list.items;
}

/// One pending file's JSON (V9). The run id is its file name, so it is set by the caller.
fn parsePending(arena: Allocator, bytes: []const u8) reply.ParseError!Pending {
    const object = try reply.objectOf(try reply.parseRoot(arena, bytes));
    const stamp = try reply.requiredText(arena, object.get("stamp"), stamp_prefix.len + run_id_hex_bytes);
    if (!validStampName(stamp)) return error.BadReply;
    const started_ms = try integerOf(object.get("started_ms") orelse return error.BadReply);
    var baseline: ?[]const BringBackFile = null;
    if (object.get("baseline")) |value| switch (value) {
        .null => {},
        .array => |items| baseline = try baselineOf(arena, items.items),
        else => return error.BadReply,
    };
    return .{ .run_id = "", .stamp = stamp, .started_ms = started_ms, .baseline = baseline };
}

fn baselineOf(arena: Allocator, items: []const std.json.Value) reply.ParseError![]const BringBackFile {
    if (items.len > max_baseline_files) return error.BadReply;
    const files = try arena.alloc(BringBackFile, items.len);
    for (items, files) |item, *file| {
        const object = try reply.objectOf(item);
        file.* = .{
            .rel = try reply.requiredText(arena, object.get("rel"), max_repo_path_bytes),
            .size = try unsignedOf(object.get("size")),
            .mtime_ns = try integerOf(object.get("mtime_ns") orelse return error.BadReply),
        };
    }
    return files;
}

/// Removes one pending run once its stamp is covered or missing (V9). A missing file is not an error.
pub fn removePending(ctx: *Context, run_id: []const u8) Error!void {
    var dir = (io_mod.openVerifiedPrivateDirIfPresent(ctx.state_dir, pending_dir) catch |err| return refuseError(ctx, "pending", err)) orelse return;
    defer dir.close();
    dir.dir.deleteFile(io_mod.getIo(), run_id) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return refuseError(ctx, "pending", err),
    };
}

fn resetManifest(ctx: *Context) Error!void {
    const io = io_mod.getIo();
    ctx.state_dir.dir.deleteFile(io, manifest_file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return refuseError(ctx, "manifest", err),
    };
    ctx.pending_cleared += try pendingCount(ctx);
    ctx.state_dir.dir.deleteTree(io, pending_dir) catch |err| return refuseError(ctx, "pending", err);
}

/// The number of pending records in `pending/`, which a reset clears (N28). It only counts: the
/// reset that follows deletes the folder whatever its permissions, so the count does not verify them.
fn pendingCount(ctx: *Context) Error!usize {
    const io = io_mod.getIo();
    var dir = ctx.state_dir.dir.openDir(io, pending_dir, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return refuseError(ctx, "pending", err),
    };
    defer dir.close(io);
    var count: usize = 0;
    var entries = dir.iterate();
    while (entries.next(io) catch |err| return refuseError(ctx, "pending", err)) |_| count += 1;
    return count;
}

/// A new generation: the test override, or 16 random bytes in hex.
pub fn freshGeneration(ctx: *Context) Allocator.Error![]const u8 {
    if (ctx.generation_override) |text| return text;
    var random_bytes: [generation_random_bytes]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    const hex = std.fmt.bytesToHex(random_bytes, .lower);
    return ctx.alloc.dupe(u8, &hex);
}

/// Keeps the newest `max_brought_entries` records and drops the oldest (V9). A dropped record
/// only makes a later run keep that Mac file (N9).
pub fn trimBrought(brought: *FileMap) void {
    while (brought.count() > max_brought_entries) brought.orderedRemoveAt(0);
}

/// Applies one bring-back record to the manifest, the way the write did (V9): a tracked file's
/// `files` record is replaced, and any other file goes to `brought`.
pub fn applyBackRecord(alloc: Allocator, manifest: *Manifest, record: journal.Record) Allocator.Error!void {
    const file_record: FileRecord = .{
        .size = record.size,
        .mtime_ns = record.mtime_ns,
        .sha256 = try alloc.dupe(u8, record.sha256),
    };
    switch (record.kind) {
        .files => try manifest.files.put(alloc, record.rel, file_record),
        .brought => {
            _ = manifest.brought.fetchOrderedRemove(record.rel);
            try manifest.brought.put(alloc, record.rel, file_record);
            trimBrought(&manifest.brought);
        },
    }
}

/// Folds a journal that a crash left into the manifest, then removes it (V9). It runs under the
/// lock, before anything reads the manifest, so the next read sees every record the journal holds.
pub fn foldJournal(ctx: *Context) Error!void {
    const bytes = (readVerified(ctx.alloc, ctx.state_dir, journal.file_name, journal.max_bytes) catch |err| return refuseError(ctx, "journal", err)) orelse return;
    const parsed = journal.parse(ctx.alloc, bytes) catch |err| switch (err) {
        error.BadJournal => return setJournalAside(ctx),
        error.OutOfMemory => return error.OutOfMemory,
    };
    var manifest = try readManifest(ctx);
    for (parsed.records) |record| try applyBackRecord(ctx.alloc, &manifest, record);
    try commitManifest(ctx, &manifest);
    journal.remove(ctx.state_dir) catch |err| return refuseError(ctx, "journal", err);
}

/// Moves a damaged journal aside, so later runs are not refused (V9). Its records are not applied,
/// so the files it listed count as changed on this machine at the next run (N9, N31).
fn setJournalAside(ctx: *Context) Error!void {
    ctx.state_dir.dir.rename(journal.file_name, ctx.state_dir.dir, journal.damaged_file_name, io_mod.getIo()) catch |err| return refuseError(ctx, "journal", err);
    ctx.journal_set_aside = true;
}

/// Reads a file of the state folder without following a link. A missing file is null.
fn readVerified(alloc: Allocator, dir: *io_mod.VerifiedDir, name: []const u8, max: usize) !?[]u8 {
    var file = io_mod.openExistingReadOnlyRegularFile(dir.dir, name, .no_follow) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    return try io_mod.readFileToEnd(alloc, &file, max);
}

const token_text = "fx-test-token";
const repo_root = "/vercel/sandbox/repo";
const generation_fresh = "fresh-generation";

const create_answer = "{\"sandbox\":{\"name\":\"fx-test\",\"vcpus\":4},\"session\":{\"id\":\"sess_1\",\"startedAt\":1000,\"timeout\":2700000}}";
const resume_answer = "{\"sandbox\":{\"name\":\"fx-test\",\"vcpus\":4,\"expiresAt\":9000},\"session\":{\"id\":\"sess_2\",\"startedAt\":2000,\"timeout\":2700000}}";
const gone_body = "{\"error\":{\"code\":\"not_found\",\"message\":\"sandbox not found\"}}";
const forbidden_body = "{\"error\":{\"code\":\"forbidden\",\"message\":\"Not authorized\"}}";
const conflict_body = "{\"error\":{\"code\":\"conflict\",\"message\":\"a sandbox with this name exists\"}}";
const user_out = "{\"stream\":\"stdout\",\"data\":\"fx\\n\"}\n{\"command\":{\"id\":\"cmd_1\",\"exitCode\":0}}\n";
const exit_zero = "{\"command\":{\"id\":\"cmd_2\",\"exitCode\":0}}\n";
const exit_one = "{\"command\":{\"id\":\"cmd_3\",\"exitCode\":1}}\n";
const marker_fresh = "{\"stream\":\"stdout\",\"data\":\"fresh-generation\\n\"}\n{\"command\":{\"id\":\"cmd_4\",\"exitCode\":0}}\n";
const marker_other = "{\"stream\":\"stdout\",\"data\":\"other-generation\\n\"}\n{\"command\":{\"id\":\"cmd_5\",\"exitCode\":0}}\n";
const ok_out = "{\"stream\":\"stdout\",\"data\":\"ok\\n\"}\n{\"command\":{\"id\":\"cmd_6\",\"exitCode\":0}}\n";
const size_answer = "{\"sandbox\":{\"name\":\"fx-test\",\"vcpus\":4,\"expiresAt\":7000}}";

fn baseFor(buffer: []u8, port: u16) !transport.BaseUrl {
    return transport.resolveBaseUrl(try std.mem.print(buffer, "http://127.0.0.1:{d}", .{port}));
}

fn contextFor(
    arena: Allocator,
    cancel: *std.atomic.Value(bool),
    base: transport.BaseUrl,
    capture: *credentials.CaptureTrace,
    state_dir: *io_mod.VerifiedDir,
) Context {
    return .{
        .alloc = arena,
        .cancel = cancel,
        .base = base,
        .token = .{ .value = token_text },
        .trace = capture.trace(),
        .team_id = "team_fake",
        .project_id = "prj_fake",
        .name = "fx-test",
        .repo_root = repo_root,
        .state_dir = state_dir,
        .generation_override = generation_fresh,
    };
}

fn expectOk(comptime T: type, outcome: Outcome(T)) !T {
    return switch (outcome) {
        .ok => |value| value,
        .failed => error.UnexpectedFailure,
    };
}

fn expectFailed(comptime T: type, outcome: Outcome(T)) !Failure {
    return switch (outcome) {
        .ok => error.UnexpectedSuccess,
        .failed => |failure| failure,
    };
}

fn seedState(arena: Allocator, dir: *io_mod.VerifiedDir, state: State) !void {
    const bytes = try encodeJson(arena, state);
    try io_mod.durableReplaceVerified(arena, dir, state_file, bytes);
}

fn seedManifest(arena: Allocator, dir: *io_mod.VerifiedDir, generation: []const u8) !void {
    const fresh = emptyManifestFor(generation);
    const bytes = try encodeManifest(arena, &fresh);
    try io_mod.durableReplaceVerified(arena, dir, manifest_file, bytes);
}

fn existingState(arena: Allocator) State {
    _ = arena;
    return .{
        .name = "fx-test",
        .session_id = "sess_old",
        .expires_at_ms = 9_000_000_000_000,
        .vcpus = 4,
        .vcpus_requested = null,
    };
}

/// A record whose expiry has passed: its session must resume before the first call (V3).
fn expiredState(arena: Allocator) State {
    var state = existingState(arena);
    state.expires_at_ms = 1;
    return state;
}

test "a missing sandbox.json creates the sandbox, sets up its first use, and keeps a matching marker (V3, V4)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();

    var server: test_server.Server = .{ .replies = &.{
        .{ .body = create_answer },
        .{ .mode = .lines_then_close, .body = user_out },
        .{ .mode = .lines_then_close, .body = exit_zero },
        .{ .mode = .lines_then_close, .body = exit_zero },
        .{ .mode = .lines_then_close, .body = marker_fresh },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);

    const session = try expectOk(Session, ensure(&ctx));
    try std.testing.expectEqualStrings("sess_1", session.state.session_id);
    try std.testing.expectEqual(@as(i64, 2_701_000), session.state.expires_at_ms);
    try std.testing.expectEqual(Generation.kept, session.generation);
    server.close();
    try std.testing.expectEqual(@as(usize, 5), server.servedCount());
    try std.testing.expect(std.mem.startsWith(u8, server.head(0), "POST /v3/sandboxes?teamId=team_fake HTTP/1.1"));
    const manifest = (try readVerified(arena, &state_dir, manifest_file, max_manifest_bytes)).?;
    try std.testing.expect(std.mem.find(u8, manifest, "\"generation\":\"fresh-generation\"") != null);
}

test "a 409 on create gives one resume GET, and a marker that is missing is written again (V3, V4)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();

    var server: test_server.Server = .{ .replies = &.{
        .{ .status = "409 Conflict", .body = conflict_body },
        .{ .body = resume_answer },
        .{ .mode = .lines_then_close, .body = exit_one },
        .{ .mode = .lines_then_close, .body = exit_zero },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);

    const session = try expectOk(Session, ensure(&ctx));
    try std.testing.expectEqualStrings("sess_2", session.state.session_id);
    try std.testing.expectEqual(Generation.reset, session.generation);
    server.close();
    try std.testing.expectEqual(@as(usize, 4), server.servedCount());
    try std.testing.expect(std.mem.find(u8, server.head(1), "resume=true") != null);
}

test "a session call that answers 404 or 410 does one resume GET, then runs the step once more (V3)" {
    try sessionGoneRecovers("404 Not Found");
    try sessionGoneRecovers("410 Gone");
}

fn sessionGoneRecovers(status_line: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedState(arena, &state_dir, existingState(arena));
    try seedManifest(arena, &state_dir, generation_fresh);

    var server: test_server.Server = .{ .replies = &.{
        .{ .status = status_line, .body = gone_body },
        .{ .body = resume_answer },
        .{ .mode = .lines_then_close, .body = marker_fresh },
        .{ .mode = .lines_then_close, .body = ok_out },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);

    var session = try expectOk(Session, ensure(&ctx));
    const output = try expectOk(Output, runCommand(&ctx, &session, .{ .step = "probe", .command = "true", .args = &.{} }, .user));
    try std.testing.expectEqualStrings("ok\n", output.stdout);
    try std.testing.expectEqualStrings("sess_2", session.state.session_id);
    try std.testing.expectEqual(Generation.kept, session.generation);
    server.close();
    try std.testing.expectEqual(@as(usize, 4), server.servedCount());
    try std.testing.expect(std.mem.find(u8, server.head(0), "/v2/sandboxes/sessions/sess_old/cmd") != null);
    try std.testing.expect(std.mem.find(u8, server.head(1), "GET /v2/sandboxes/fx-test?projectId=prj_fake&resume=true") != null);
    try std.testing.expect(std.mem.find(u8, server.head(3), "/v2/sandboxes/sessions/sess_2/cmd") != null);
}

test "V13: a size PATCH answered 401 or 403 refuses the run before exec, and is not a note (V13)" {
    try sizePatchRejected("401 Unauthorized", 401);
    try sizePatchRejected("403 Forbidden", 403);
}

fn sizePatchRejected(status_line: []const u8, status: u16) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedState(arena, &state_dir, existingState(arena));

    var server: test_server.Server = .{ .replies = &.{
        .{ .status = status_line, .body = forbidden_body },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);
    ctx.vcpus = 8;

    const failure = try expectFailed(Session, ensure(&ctx));
    try std.testing.expectEqual(status, failure.status);
}

test "V13: an extend answered 401 or 403 before exec refuses the run with that status (V13)" {
    try extendRejected("401 Unauthorized", 401);
    try extendRejected("403 Forbidden", 403);
}

fn extendRejected(status_line: []const u8, status: u16) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedState(arena, &state_dir, existingState(arena));

    var server: test_server.Server = .{ .replies = &.{
        .{ .status = status_line, .body = forbidden_body },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);
    var session: Session = .{ .state = existingState(arena), .generation = .kept, .size_note = .none };

    try std.testing.expectError(error.Refused, extendBeforeExec(&ctx, &session));
    try std.testing.expectEqual(status, ctx.failure.status);
}

test "a record whose expiry has passed resumes before the first session call, then the step runs (V3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedState(arena, &state_dir, expiredState(arena));
    try seedManifest(arena, &state_dir, generation_fresh);

    var server: test_server.Server = .{ .replies = &.{
        .{ .body = resume_answer },
        .{ .mode = .lines_then_close, .body = marker_fresh },
        .{ .mode = .lines_then_close, .body = ok_out },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);

    var session = try expectOk(Session, ensure(&ctx));
    _ = try expectOk(Output, runCommand(&ctx, &session, .{ .step = "probe", .command = "true", .args = &.{} }, .user));
    try std.testing.expectEqualStrings("sess_2", session.state.session_id);
    server.close();
    try std.testing.expectEqual(@as(usize, 3), server.servedCount());
    try std.testing.expect(std.mem.find(u8, server.head(0), "GET /v2/sandboxes/fx-test?projectId=prj_fake&resume=true") != null);
    try std.testing.expect(std.mem.find(u8, server.head(2), "/v2/sandboxes/sessions/sess_2/cmd") != null);
}

test "a session call that answers 410 after the run's recovery is spent marks the record expired, so the next run resumes first (V3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedState(arena, &state_dir, existingState(arena));
    try seedManifest(arena, &state_dir, generation_fresh);

    var server: test_server.Server = .{ .replies = &.{
        .{ .status = "410 Gone", .body = gone_body },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);
    ctx.used.recovered = true;

    var session = try expectOk(Session, ensure(&ctx));
    const failure = try expectFailed(Output, runCommand(&ctx, &session, .{ .step = "probe", .command = "true", .args = &.{} }, .user));
    try std.testing.expectEqual(@as(u16, 410), failure.status);
    server.close();
    const marked = (try loadState(&ctx)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 0), marked.expires_at_ms);
    try std.testing.expectEqualStrings("sess_old", marked.session_id);
}

test "an extend answered 410 marks the record at once, even when the resume after it fails (V3, V12)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedState(arena, &state_dir, existingState(arena));

    var server: test_server.Server = .{ .replies = &.{
        .{ .status = "410 Gone", .body = gone_body },
        .{ .status = "500 Internal Server Error", .body = "{}" },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);
    var session: Session = .{ .state = existingState(arena), .generation = .kept, .size_note = .none };

    try std.testing.expectError(error.Refused, extendBeforeExec(&ctx, &session));
    server.close();
    const marked = (try loadState(&ctx)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 0), marked.expires_at_ms);
}

test "a resume that answers 404 creates the sandbox once, sets up its first use, and runs the step once more (V3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedState(arena, &state_dir, existingState(arena));

    var server: test_server.Server = .{ .replies = &.{
        .{ .status = "404 Not Found", .body = gone_body },
        .{ .status = "404 Not Found", .body = gone_body },
        .{ .body = create_answer },
        .{ .mode = .lines_then_close, .body = user_out },
        .{ .mode = .lines_then_close, .body = exit_zero },
        .{ .mode = .lines_then_close, .body = exit_zero },
        .{ .mode = .lines_then_close, .body = marker_fresh },
        .{ .mode = .lines_then_close, .body = ok_out },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);

    var session = try expectOk(Session, ensure(&ctx));
    _ = try expectOk(Output, runCommand(&ctx, &session, .{ .step = "probe", .command = "true", .args = &.{} }, .user));
    try std.testing.expectEqualStrings("sess_1", session.state.session_id);
    server.close();
    try std.testing.expectEqual(@as(usize, 8), server.servedCount());
    try std.testing.expect(std.mem.startsWith(u8, server.head(2), "POST /v3/sandboxes?teamId=team_fake HTTP/1.1"));
}

test "a create that answers 409, a resume that answers 404, and a second create that answers 409 is an error, not a loop (V3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();

    var server: test_server.Server = .{ .replies = &.{
        .{ .status = "409 Conflict", .body = conflict_body },
        .{ .status = "404 Not Found", .body = gone_body },
        .{ .status = "409 Conflict", .body = conflict_body },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);

    const failure = try expectFailed(Session, ensure(&ctx));
    try std.testing.expectEqualStrings("create", failure.step);
    try std.testing.expectEqual(@as(u16, 409), failure.status);
    server.close();
    try std.testing.expectEqual(@as(usize, 3), server.servedCount());
}

test "an exec command that answers 404 resumes once and runs once more, and a second 404 is refused and marks the record (V3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedState(arena, &state_dir, existingState(arena));
    try seedManifest(arena, &state_dir, generation_fresh);

    var server: test_server.Server = .{ .replies = &.{
        .{ .status = "404 Not Found", .body = gone_body },
        .{ .body = resume_answer },
        .{ .mode = .lines_then_close, .body = marker_fresh },
        .{ .status = "410 Gone", .body = gone_body },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);
    var session: Session = .{ .state = existingState(arena), .generation = .kept, .size_note = .none };

    const failure = try expectFailed(Output, runCommand(&ctx, &session, .{ .step = "exec", .command = "true", .args = &.{} }, .exec));
    try std.testing.expectEqualStrings("sess_2", session.state.session_id);
    try std.testing.expectEqualStrings("exec", failure.step);
    try std.testing.expectEqual(@as(u16, 410), failure.status);
    server.close();
    try std.testing.expectEqual(@as(usize, 4), server.servedCount());
    const marked = (try loadState(&ctx)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 0), marked.expires_at_ms);
}

test "a create that names vcpus in a 400 is refused with that detail, and nothing is written (N1)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();

    var server: test_server.Server = .{ .replies = &.{
        .{ .status = "400 Bad Request", .body = "{\"error\":{\"code\":\"bad_request\",\"message\":\"`resources.vcpus` should be even\"}}" },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);
    ctx.vcpus = 3;

    const failure = try expectFailed(Session, ensure(&ctx));
    try std.testing.expectEqualStrings("create", failure.step);
    try std.testing.expectEqual(@as(u16, 400), failure.status);
    try std.testing.expect(std.mem.startsWith(u8, failure.detail, "vcpus: "));
    server.close();
    try std.testing.expect((try readVerified(arena, &state_dir, state_file, max_state_bytes)) == null);
}

test "a create answer without a session is refused, and nothing is written (V3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();

    var server: test_server.Server = .{ .replies = &.{.{ .body = "{\"sandbox\":{\"name\":\"fx-test\",\"vcpus\":4}}" }} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);

    const failure = try expectFailed(Session, ensure(&ctx));
    try std.testing.expectEqualStrings("create", failure.step);
    try std.testing.expectEqualStrings("the answer has no session", failure.detail);
    try std.testing.expect((try readVerified(arena, &state_dir, state_file, max_state_bytes)) == null);
}

test "a malformed sandbox.json is rebuilt through create, and the rebuilt file is valid (V3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try io_mod.durableReplaceVerified(arena, &state_dir, state_file, "not json");

    var server: test_server.Server = .{ .replies = &.{
        .{ .body = create_answer },
        .{ .mode = .lines_then_close, .body = user_out },
        .{ .mode = .lines_then_close, .body = exit_zero },
        .{ .mode = .lines_then_close, .body = exit_zero },
        .{ .mode = .lines_then_close, .body = marker_fresh },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);

    const session = try expectOk(Session, ensure(&ctx));
    try std.testing.expectEqualStrings("sess_1", session.state.session_id);
    const rebuilt = (try readVerified(arena, &state_dir, state_file, max_state_bytes)).?;
    try std.testing.expectEqualStrings("sess_1", (try parseState(arena, rebuilt)).session_id);
}

test "a size that differs is patched with memory 2048 MiB per vCPU, and the note says it applies next session (V3, N18)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedState(arena, &state_dir, existingState(arena));

    var server: test_server.Server = .{ .replies = &.{.{ .body = size_answer }} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);
    ctx.vcpus = 8;

    const session = try expectOk(Session, ensure(&ctx));
    try std.testing.expectEqual(@as(?u32, 8), session.state.vcpus_requested);
    switch (session.size_note) {
        .applies_next_session => |size| {
            try std.testing.expectEqual(@as(u32, 8), size.wanted);
            try std.testing.expectEqual(@as(u32, 4), size.now);
        },
        else => return error.UnexpectedSizeNote,
    }
    server.close();
    try std.testing.expectEqual(@as(usize, 1), server.servedCount());
    try std.testing.expect(std.mem.startsWith(u8, server.head(0), "PATCH /v2/sandboxes/fx-test?projectId=prj_fake&teamId=team_fake HTTP/1.1"));
}

test "a size already requested is not sent again (V3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    var requested = existingState(arena);
    requested.vcpus_requested = 8;
    try seedState(arena, &state_dir, requested);

    var server: test_server.Server = .{ .replies = &.{.{ .body = size_answer }} };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);
    ctx.vcpus = 8;

    _ = try expectOk(Session, ensure(&ctx));
    server.close();
    try std.testing.expectEqual(@as(usize, 0), server.servedCount());
}

test "a failed size PATCH is not sent again in this process, and its note names the size (V3, N18)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedState(arena, &state_dir, existingState(arena));

    var server: test_server.Server = .{ .replies = &.{
        .{ .status = "400 Bad Request", .body = "{\"error\":{\"code\":\"bad_request\",\"message\":\"resources.vcpus should be even\"}}" },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);
    ctx.vcpus = 8;

    const first = try expectOk(Session, ensure(&ctx));
    switch (first.size_note) {
        .failed => |rejected| {
            try std.testing.expectEqual(@as(u32, 8), rejected.wanted);
            try std.testing.expect(rejected.detail.len > 0);
        },
        else => return error.UnexpectedSizeNote,
    }
    _ = try expectOk(Session, ensure(&ctx));
    server.close();
    try std.testing.expectEqual(@as(usize, 1), server.servedCount());
}

/// Counts the bytes requested from `child`, and the most held at once, so a test can bound the
/// memory a parse holds (V5).
const CountingAllocator = struct {
    child: Allocator,
    held: usize = 0,
    peak: usize = 0,

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn grew(self: *CountingAllocator, bytes: usize) void {
        self.held += bytes;
        if (self.held > self.peak) self.peak = self.held;
    }

    fn resized(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            self.grew(new_len - old_len);
        } else {
            self.held -= old_len - new_len;
        }
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ptr));
        const memory = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.grew(len);
        return memory;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ptr));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.resized(memory.len, new_len);
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ptr));
        const moved = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.resized(memory.len, new_len);
        return moved;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ptr));
        self.child.rawFree(memory, alignment, ret_addr);
        self.held -= memory.len;
    }
};

test "a sync record at the file and byte limits is written, read back, and bounded in memory (V5)" {
    var build_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer build_state.deinit();
    const build = build_state.allocator();
    var manifest = emptyManifest();
    manifest.generation = "generation-1";
    const sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const block = "abcdefgh";
    const tail = block ++ block ++ block ++ block ++ block ++ block ++ block ++ block ++ block ++ block ++ block ++ "abc";
    var index: usize = 0;
    while (index < max_manifest_files) : (index += 1) {
        const rel = try build.print("zig-out/cache/objects/{d:0>6}/{s}", .{ index, tail });
        try manifest.files.put(build, rel, .{ .size = index, .mtime_ns = 1_700_000_000_000_000_000 + @as(i64, @intCast(index)), .sha256 = sha });
    }
    index = 0;
    while (index < max_brought_entries) : (index += 1) {
        const rel = try build.print("out/{d}", .{index});
        try manifest.brought.put(build, rel, .{ .size = 1, .mtime_ns = 2, .sha256 = sha });
    }
    const bytes = try encodeManifest(build, &manifest);
    try std.testing.expect(bytes.len <= max_manifest_bytes);

    var counting: CountingAllocator = .{ .child = std.heap.page_allocator };
    var read_state = std.heap.ArenaAllocator.init(counting.allocator());
    defer read_state.deinit();
    const parsed = try parseManifest(read_state.allocator(), bytes);
    try std.testing.expectEqual(max_manifest_files, parsed.files.count());
    try std.testing.expectEqual(max_brought_entries, parsed.brought.count());
    try std.testing.expect(counting.peak + bytes.len <= 256 * 1024 * 1024);
}

test "a sync record near the byte limit, with long paths, parses within the 256 MiB bound (V5)" {
    var build_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer build_state.deinit();
    const build = build_state.allocator();
    var manifest = emptyManifest();
    manifest.generation = "generation-1";
    const sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const tail: [451]u8 = @splat('x');
    var index: usize = 0;
    while (index < max_manifest_files) : (index += 1) {
        const rel = try build.print("zig-out/cache/objects/{d:0>6}/{s}", .{ index, tail[0..] });
        try manifest.files.put(build, rel, .{ .size = index, .mtime_ns = 1_700_000_000_000_000_000 + @as(i64, @intCast(index)), .sha256 = sha });
    }
    index = 0;
    while (index < max_brought_entries) : (index += 1) {
        const rel = try build.print("out/{d}", .{index});
        try manifest.brought.put(build, rel, .{ .size = 1, .mtime_ns = 2, .sha256 = sha });
    }
    const bytes = try encodeManifest(build, &manifest);
    try std.testing.expect(bytes.len <= max_manifest_bytes);

    var counting: CountingAllocator = .{ .child = std.heap.page_allocator };
    var read_state = std.heap.ArenaAllocator.init(counting.allocator());
    defer read_state.deinit();
    const parsed = try parseManifest(read_state.allocator(), bytes);
    try std.testing.expectEqual(max_manifest_files, parsed.files.count());
    try std.testing.expect(counting.peak + bytes.len <= 256 * 1024 * 1024);
}

test "a sync record over its file or byte limit is refused with its file count (V5)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var manifest = emptyManifest();
    manifest.generation = "generation-1";
    const sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try manifest.files.put(arena, "a", .{ .size = 1, .mtime_ns = 1, .sha256 = sha });
    try manifest.files.put(arena, "b", .{ .size = 1, .mtime_ns = 1, .sha256 = sha });
    try manifest.files.put(arena, "c", .{ .size = 1, .mtime_ns = 1, .sha256 = sha });
    try std.testing.expect((try refusalWithin(arena, &manifest, 3, max_manifest_bytes)) == null);
    const by_files = (try refusalWithin(arena, &manifest, 2, max_manifest_bytes)).?;
    try std.testing.expectEqualStrings("3 files, more than the 2 a sync record can hold", by_files);
    const by_bytes = (try refusalWithin(arena, &manifest, max_manifest_files, 100)).?;
    try std.testing.expect(std.mem.startsWith(u8, by_bytes, "3 files make a sync record of "));
}

test "a manifest of 2,000 brought records reads back, past the reply size limit (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var manifest = emptyManifest();
    manifest.generation = "generation-1";
    const sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    for (0..2000) |index| {
        const rel = try std.fmt.allocPrint(arena, "zig-out/bin/file-{d:0>5}-padding-padding-padding-padding-padding.txt", .{index});
        try manifest.brought.put(arena, rel, .{ .size = 1, .mtime_ns = 2, .sha256 = sha });
    }
    const bytes = try encodeManifest(arena, &manifest);
    try std.testing.expect(bytes.len > transport.max_response_bytes);
    const back = try parseManifest(arena, bytes);
    try std.testing.expectEqual(@as(usize, 2000), back.brought.count());
    try std.testing.expectEqualStrings("generation-1", back.generation.?);
}

/// The first byte picks the reader (0 sandbox.json, 1 manifest.json, 2 a pending record).
fn fuzzStateFiles(_: void, smith: *std.testing.Smith) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = try arena.alloc(u8, max_state_bytes + 1);
    const len = smith.slice(raw);
    if (len == 0) return;
    const body = raw[1..len];
    switch (raw[0] % 4) {
        0 => {
            const state = parseState(arena, body) catch |err| return refusedOnly(err);
            try std.testing.expect(state.name.len > 0 and state.session_id.len > 0);
        },
        1 => {
            const manifest = parseManifest(arena, body) catch |err| return refusedOnly(err);
            const bytes = try encodeManifest(arena, &manifest);
            const again = try parseManifest(arena, bytes);
            try std.testing.expectEqual(manifest.files.count(), again.files.count());
            try std.testing.expectEqual(manifest.brought.count(), again.brought.count());
            try std.testing.expectEqual(manifest.pending_back.len, again.pending_back.len);
        },
        3 => {
            const parsed = journal.parse(arena, body) catch |err| switch (err) {
                error.BadJournal => return,
                error.OutOfMemory => return error.OutOfMemory,
            };
            for (parsed.records) |record| {
                const line = try journal.encodeLine(arena, record);
                const again = try journal.parse(arena, line);
                try std.testing.expectEqual(@as(usize, 1), again.records.len);
                try std.testing.expectEqualStrings(record.rel, again.records[0].rel);
            }
        },
        else => {
            const pending = parsePending(arena, body) catch |err| return refusedOnly(err);
            try std.testing.expect(validStampName(pending.stamp));
        },
    }
}

fn refusedOnly(err: reply.ParseError) !void {
    return switch (err) {
        error.BadReply => {},
        error.OutOfMemory => error.OutOfMemory,
    };
}

test "the real create, resume and size answers arrive whole through the buffered call and parse (V3)" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { bytes: []const u8, chunked: bool }{
        .{ .bytes = @embedFile("testdata/real-create-answer.json"), .chunked = false },
        .{ .bytes = @embedFile("testdata/real-get-answer.json"), .chunked = true },
        .{ .bytes = @embedFile("testdata/real-patch-answer.json"), .chunked = false },
    };
    for (cases) |case| {
        var server: test_server.Server = .{ .replies = &.{.{ .mode = if (case.chunked) .chunked else .reply, .body = case.bytes }} };
        try server.listen();
        try server.start();
        defer server.close();
        var origin_buffer: [64]u8 = undefined;
        const origin = try std.fmt.bufPrint(&origin_buffer, "http://127.0.0.1:{d}", .{server.port()});
        var cancel = std.atomic.Value(bool).init(false);
        var capture: credentials.CaptureTrace = .{};
        const response = try stream.callBuffered(alloc, &cancel, transport.resolveBaseUrl(origin), .{ .value = transport.test_token }, capture.trace(), .{
            .step = "resume",
            .method = .GET,
            .path = "/v2/sandboxes/fx-0123456789abcdef?projectId=prj_1&teamId=team_1",
            .body = .none,
        });
        defer alloc.free(response.body);
        try std.testing.expectEqual(@as(u16, 200), response.status);
        try std.testing.expectEqualSlices(u8, case.bytes, response.body);
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        var problem: reply.Problem = .{};
        _ = try parseSandbox(arena_state.allocator(), response.body, &problem);
    }
}

test "a sandbox answer that cannot be read names the first field that failed, never a value (V3, N1)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { bytes: []const u8, text: []const u8 }{
        // a body that is not a JSON object
        .{ .bytes = "not json", .text = "the body is not JSON" },
        .{ .bytes = "[1]", .text = "the body is not an object" },
        // a missing field
        .{ .bytes = "{}", .text = "sandbox is missing" },
        .{ .bytes = "{\"sandbox\":{}}", .text = "sandbox.vcpus is missing" },
        .{ .bytes = "{\"sandbox\":{\"vcpus\":2},\"session\":{\"id\":\"sbx_1\",\"timeout\":1000}}", .text = "session.startedAt is missing" },
        // a field of the wrong type
        .{ .bytes = "{\"sandbox\":5}", .text = "sandbox is not an object" },
        .{ .bytes = "{\"sandbox\":{\"vcpus\":\"2\"}}", .text = "sandbox.vcpus is not an integer" },
        .{ .bytes = "{\"sandbox\":{\"vcpus\":2},\"session\":{\"id\":7,\"startedAt\":1,\"timeout\":1}}", .text = "session.id is not a string" },
        .{ .bytes = "{\"sandbox\":{\"vcpus\":2},\"session\":{\"id\":\"sbx_1\",\"startedAt\":\"1\",\"timeout\":1}}", .text = "session.startedAt is not an integer" },
        .{ .bytes = "{\"sandbox\":{\"vcpus\":2,\"expiresAt\":\"1\"}}", .text = "sandbox.expiresAt is not an integer" },
        // a text that is empty
        .{ .bytes = "{\"sandbox\":{\"vcpus\":2},\"session\":{\"id\":\"\",\"startedAt\":1,\"timeout\":1}}", .text = "session.id is empty" },
        // a value out of range
        .{ .bytes = "{\"sandbox\":{\"vcpus\":0}}", .text = "sandbox.vcpus is out of range" },
        .{ .bytes = "{\"sandbox\":{\"vcpus\":2000}}", .text = "sandbox.vcpus is out of range" },
        .{ .bytes = "{\"sandbox\":{\"vcpus\":2},\"session\":{\"id\":\"sbx_1\",\"startedAt\":9223372036854775807,\"timeout\":10}}", .text = "session.timeout is out of range" },
    };
    for (cases) |case| {
        var problem: reply.Problem = .{};
        try std.testing.expectError(error.BadReply, parseSandbox(arena, case.bytes, &problem));
        try std.testing.expectEqualStrings(case.text, try problem.describe(arena));
    }
}

/// The sandbox answers of create, resume and PATCH are one JSON shape (V3).
fn fuzzSandboxAnswer(_: void, smith: *std.testing.Smith) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = try arena.alloc(u8, transport.max_response_bytes);
    const len = smith.slice(raw);
    var problem: reply.Problem = .{};
    const answer = parseSandbox(arena, raw[0..len], &problem) catch |err| return refusedOnly(err);
    try std.testing.expect(answer.vcpus >= 1 and answer.vcpus <= max_vcpus);
    if (answer.session_id) |id| try std.testing.expect(id.len > 0 and id.len <= api.max_id_bytes);
}

test "a sandbox answer parses or is refused, and a parsed size and session id are bounded, on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzSandboxAnswer, .{
        .corpus = &@import("fuzz_corpus").vercel_sandbox_answer.*,
    });
}

test "sandbox.json, manifest.json, the journal and a pending record parse or are refused, and a parsed one writes back to the same records, on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzStateFiles, .{
        .corpus = &@import("fuzz_corpus").vercel_state_files.*,
    });
}

test "a journal of three records and a torn fourth folds into the manifest at the next start, then is removed (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, 9);
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);

    const sha_one = "1111111111111111" ++ "1111111111111111" ++ "1111111111111111" ++ "1111111111111111";
    const sha_two = "2222222222222222" ++ "2222222222222222" ++ "2222222222222222" ++ "2222222222222222";
    var manifest = emptyManifest();
    manifest.generation = "generation-1";
    try manifest.files.put(arena, "c.txt", .{ .size = 1, .mtime_ns = 1, .sha256 = "0000000000000000" ++ "0000000000000000" ++ "0000000000000000" ++ "0000000000000000" });
    try commitManifest(&ctx, &manifest);

    const records = [_]journal.Record{
        .{ .kind = .brought, .rel = "a.txt", .size = 10, .mtime_ns = 11, .sha256 = sha_one },
        .{ .kind = .brought, .rel = "b.txt", .size = 20, .mtime_ns = 21, .sha256 = sha_one },
        .{ .kind = .files, .rel = "c.txt", .size = 30, .mtime_ns = 31, .sha256 = sha_two },
    };
    var bytes: std.ArrayList(u8) = .empty;
    for (records) |record| try bytes.appendSlice(arena, try journal.encodeLine(arena, record));
    try bytes.appendSlice(arena, "{\"k\":\"b\",\"p\":\"d.txt\",\"s\"");
    try state_dir.dir.writeFile(io_mod.getIo(), .{ .sub_path = journal.file_name, .data = bytes.items });

    try foldJournal(&ctx);

    var folded = try readManifest(&ctx);
    try std.testing.expectEqual(@as(usize, 2), folded.brought.count());
    try std.testing.expectEqualStrings(sha_one, folded.brought.get("b.txt").?.sha256);
    try std.testing.expectEqualStrings(sha_two, folded.files.get("c.txt").?.sha256);
    try std.testing.expect(folded.brought.get("d.txt") == null);
    try std.testing.expectError(error.FileNotFound, state_dir.dir.statFile(io_mod.getIo(), journal.file_name, .{}));
}

test "a journal with a damaged complete line is set aside, its records are not applied, and later folds go on (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = io_mod.getIo();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, 9);
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);

    var manifest = emptyManifest();
    manifest.generation = "generation-1";
    try commitManifest(&ctx, &manifest);

    const sha_one = "1111111111111111" ++ "1111111111111111" ++ "1111111111111111" ++ "1111111111111111";
    const good = try journal.encodeLine(arena, .{ .kind = .brought, .rel = "a.txt", .size = 1, .mtime_ns = 2, .sha256 = sha_one });
    const bytes = try arena.print("{s}not a record\n", .{good});
    try state_dir.dir.writeFile(io, .{ .sub_path = journal.file_name, .data = bytes });

    _ = try foldJournal(&ctx);
    _ = try foldJournal(&ctx);

    const folded = try readManifest(&ctx);
    try std.testing.expect(folded.brought.get("a.txt") == null);
    try std.testing.expectError(error.FileNotFound, state_dir.dir.statFile(io, journal.file_name, .{}));
    _ = try state_dir.dir.statFile(io, "manifest.journal.damaged", .{});
    try std.testing.expect(ctx.journal_set_aside);
}

test "a manifest without a generation writes back as one the reader accepts (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var manifest = emptyManifest();
    const bytes = try encodeManifest(arena, &manifest);
    const back = try parseManifest(arena, bytes);
    try std.testing.expectEqual(@as(?[]const u8, null), back.generation);
}

test "a manifest with the most pending names reads back, so the reader's limit is the writer's (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var manifest = emptyManifest();
    manifest.generation = "generation-1";
    const names = try arena.alloc([]const u8, max_pending_names);
    for (names, 0..) |*name, index| {
        name.* = try std.fmt.allocPrint(arena, "zig-out/bin/pending-{d:0>5}-padding-padding.txt", .{index});
    }
    manifest.pending_back = names;
    const bytes = try encodeManifest(arena, &manifest);
    const back = try parseManifest(arena, bytes);
    try std.testing.expectEqual(max_pending_names, back.pending_back.len);
    try std.testing.expectEqualStrings(names[max_pending_names - 1], back.pending_back[max_pending_names - 1]);
}

test "a reset counts the pending records it clears, for the N28 note (V4)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, transport.resolveBaseUrl(null), &capture, &state_dir);
    try writePending(&ctx, .{ .run_id = "0123456789abcdef", .started_ms = 1, .baseline = null });
    try writePending(&ctx, .{ .run_id = "fedcba9876543210", .started_ms = 2, .baseline = null });
    try resetManifest(&ctx);
    try std.testing.expectEqual(@as(usize, 2), ctx.pending_cleared);
    try std.testing.expectEqual(@as(usize, 0), try pendingCount(&ctx));
}

test "a pending run is written with its stamp and baseline, read back, and removed (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, transport.resolveBaseUrl(null), &capture, &state_dir);
    const baseline = [_]BringBackFile{.{ .rel = "out/app", .size = 7, .mtime_ns = 9 }};
    try writePending(&ctx, .{ .run_id = "0123456789abcdef", .started_ms = 42, .baseline = &baseline });
    try writePending(&ctx, .{ .run_id = "fedcba9876543210", .started_ms = 7, .baseline = null });

    const pending = try readPending(arena, &ctx);
    try std.testing.expectEqual(@as(usize, 2), pending.len);
    for (pending) |entry| {
        if (std.mem.eql(u8, entry.run_id, "0123456789abcdef")) {
            try std.testing.expectEqualStrings("fx-stamp-0123456789abcdef", entry.stamp);
            try std.testing.expectEqual(@as(i64, 42), entry.started_ms);
            try std.testing.expectEqualStrings("out/app", entry.baseline.?[0].rel);
            try std.testing.expectEqual(@as(u64, 7), entry.baseline.?[0].size);
        } else {
            try std.testing.expectEqualStrings("fx-stamp-fedcba9876543210", entry.stamp);
            try std.testing.expect(entry.baseline == null);
        }
    }
    try removePending(&ctx, "0123456789abcdef");
    try std.testing.expectEqual(@as(usize, 1), (try readPending(arena, &ctx)).len);
    try std.testing.expect(!validStampName("fx-stamp-../x"));
    try std.testing.expect(validStampName("fx-stamp-0123456789abcdef"));
}

test "a marker that differs clears the manifest and pending, and writes a fresh marker (V4)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state_dir.close();
    try seedState(arena, &state_dir, existingState(arena));
    try seedManifest(arena, &state_dir, "old-generation");
    const io = io_mod.getIo();
    try state_dir.dir.createDirPath(io, pending_dir);

    var server: test_server.Server = .{ .replies = &.{
        .{ .status = "404 Not Found", .body = gone_body },
        .{ .body = resume_answer },
        .{ .mode = .lines_then_close, .body = marker_other },
        .{ .mode = .lines_then_close, .body = exit_zero },
        .{ .mode = .lines_then_close, .body = ok_out },
    } };
    try server.listen();
    try server.start();
    defer server.close();
    var buffer: [64]u8 = undefined;
    const base = try baseFor(&buffer, server.port());
    var cancel = std.atomic.Value(bool).init(false);
    var capture: credentials.CaptureTrace = .{};
    var ctx = contextFor(arena, &cancel, base, &capture, &state_dir);

    var session: Session = .{ .state = existingState(arena), .generation = .kept, .size_note = .none };
    _ = try expectOk(Output, runCommand(&ctx, &session, .{ .step = "probe", .command = "true", .args = &.{} }, .user));
    try std.testing.expectEqual(Generation.reset, session.generation);
    server.close();
    const manifest = (try readVerified(arena, &state_dir, manifest_file, max_manifest_bytes)).?;
    try std.testing.expect(std.mem.find(u8, manifest, "fresh-generation") != null);
    try std.testing.expect(std.mem.find(u8, manifest, "old-generation") == null);
    try std.testing.expectError(error.FileNotFound, state_dir.dir.access(io, pending_dir, .{}));
}

test "the marker check passes the repository path as one argument, never inside a script (V4)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const body = try encodeJsonOmitNulls(arena_state.allocator(), CommandBody{
        .command = "cat",
        .args = &.{repo_root ++ marker_suffix},
    });
    try std.testing.expect(std.mem.find(u8, body, "\"command\":\"cat\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"args\":[\"" ++ repo_root ++ marker_suffix ++ "\"]") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"cwd\"") == null);
}

test "the size PATCH sends memory as 2048 MiB per vCPU (V3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const body = try sizeBody(arena_state.allocator(), 8);
    try std.testing.expectEqualStrings("{\"resources\":{\"vcpus\":8,\"memory\":16384}}", body);
}

test "the size decision needs no call for a size already reported or requested, and patches otherwise (V3)" {
    const reported: State = .{ .name = "n", .session_id = "s", .expires_at_ms = 0, .vcpus = 4, .vcpus_requested = null };
    var requested = reported;
    requested.vcpus_requested = 8;
    var cleared = reported;
    cleared.vcpus_requested = 4;
    try std.testing.expectEqual(SizeAction.keep, sizeAction(4, reported, false));
    try std.testing.expectEqual(SizeAction.clear_request, sizeAction(4, cleared, false));
    try std.testing.expectEqual(SizeAction.patch, sizeAction(8, reported, false));
    try std.testing.expectEqual(SizeAction.keep, sizeAction(8, requested, false));
    try std.testing.expectEqual(SizeAction.keep, sizeAction(8, reported, true));
}

test "a state file round-trips, and a file that is not a state is refused (V3)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const state: State = .{ .name = "fx-abc", .session_id = "sess_9", .expires_at_ms = 42, .vcpus = 2, .vcpus_requested = null };
    const bytes = try encodeJson(arena, state);
    const back = try parseState(arena, bytes);
    try std.testing.expectEqualStrings("fx-abc", back.name);
    try std.testing.expectEqual(@as(i64, 42), back.expires_at_ms);
    try std.testing.expectEqual(@as(?u32, null), back.vcpus_requested);
    try std.testing.expectError(error.BadReply, parseState(arena, "{\"name\":\"fx-abc\"}"));
}

test "a user name must be plain text, and an empty or odd one is refused (V4)" {
    try std.testing.expect(validUser("ubuntu"));
    try std.testing.expect(validUser("svc.user-1"));
    try std.testing.expect(!validUser(""));
    try std.testing.expect(!validUser("bad name"));
    try std.testing.expect(!validUser("x;rm"));
}
