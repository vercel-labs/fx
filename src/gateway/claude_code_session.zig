//! The live half of the Claude Code provider: one `claude` process per fx
//! session, the socket its MCP bridge connects back to, and the model step
//! that turns Claude Code's agent loop into fx's one-step contract.
//!
//! A step writes what is new in fx's history to the process: tool results
//! answer the `tools/call` requests Claude Code is holding open, and user
//! text goes to its stdin. It then reads Claude Code's stream until the
//! assistant message ends. A message with tool uses ends the step with those
//! calls; fx runs them through its own loop and permissions, and the next
//! step carries their results. A message without them ends the turn.
//!
//! When a request's history does not extend what the process has seen
//! (`claude_code_wire.planDelta`), the session starts over: with `--resume`
//! when an earlier reply recorded a Claude session that the history still
//! starts with, and otherwise as a new Claude session whose first message
//! holds the history as a transcript.
//!
//! fx never reads Claude Code's files or credentials. Everything goes
//! through the `claude` binary's documented flags and its stream-json input
//! and output.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../core/shared/io.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const self_exe = @import("../core/shared/self_exe.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const function_tools = @import("function_tools.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const wire = @import("claude_code_wire.zig");

const Allocator = std.mem.Allocator;
const posix = std.posix;

/// Sessions live for the process, so they use the process allocator, as
/// `src/core/mcp_host/mcp_call_bridge.zig` does.
const gpa = std.heap.c_allocator;

/// The argument that starts fx as the bridge (`claude_code.runBridge`).
pub const bridge_mode = "--fx-internal-claude-code-bridge";

/// Live `claude` processes kept at once. Starting another stops the one
/// used longest ago; its conversation resumes when it is next used.
const max_live_sessions = 8;
/// How long Claude Code waits for one tool call: longer than any wait for a
/// permission prompt, so fx, not Claude Code, decides when a call ends.
const tool_timeout_ms = "86400000";
const poll_ms = 100;
/// After an interrupt, how long to wait for the turn's end before stopping
/// the process.
const interrupt_grace_ms: i64 = 10_000;
const max_line_bytes = 64 * 1024 * 1024;
const stderr_tail_bytes = 2048;

pub const not_installed_message =
    "Claude Code is not installed or `claude` is not on PATH. Install it from https://claude.com/claude-code, " ++
    "run `claude` once and sign in with /login, then try again.";
pub const not_signed_in_message =
    "Claude Code is not signed in. Run `claude` in a terminal and sign in with /login, then try again.";

// ---------------------------------------------------------------------------
// Registry

const registry = struct {
    var mutex: std.Io.Mutex = .init;
    var sessions: std.ArrayList(*Session) = .empty;
    var exiting: bool = false;
    /// Processes started and not yet stopped, so a program that never
    /// started one exits without touching the registry.
    var live: std.atomic.Value(usize) = .init(0);
};

/// Stops every `claude` process this fx started and removes their private
/// directories. For a program about to exit; safe from any thread. A
/// process whose session is mid-step gets SIGTERM and is left to exit.
pub fn stopAll() void {
    if (registry.live.load(.acquire) == 0) return;
    const io = io_mod.getIo();
    registry.mutex.lockUncancelable(io);
    registry.exiting = true;
    const list = registry.sessions.items;
    registry.mutex.unlock(io);
    for (list) |session| {
        if (session.proc) |proc| proc.signal(.TERM);
    }
    for (list) |session| {
        if (!session.step_lock.tryLock()) continue;
        defer session.step_lock.unlock(io);
        session.stopProcess();
    }
}

fn acquire(key: []const u8) !*Session {
    const io = io_mod.getIo();
    registry.mutex.lockUncancelable(io);
    var found: ?*Session = null;
    for (registry.sessions.items) |session| {
        if (std.mem.eql(u8, session.key, key)) found = session;
    }
    if (found == null) {
        const session = try gpa.create(Session);
        errdefer gpa.destroy(session);
        session.* = .{ .key = try gpa.dupe(u8, key) };
        registry.sessions.append(gpa, session) catch |err| {
            gpa.free(session.key);
            registry.mutex.unlock(io);
            return err;
        };
        found = session;
    }
    registry.mutex.unlock(io);
    const session = found.?;
    session.step_lock.lockUncancelable(io);
    session.last_used_ms = io_mod.milliTimestamp();
    return session;
}

fn release(session: *Session) void {
    session.step_lock.unlock(io_mod.getIo());
}

/// Stops the process of the session used longest ago when too many run.
fn evictIdle(current: *Session) void {
    const io = io_mod.getIo();
    registry.mutex.lockUncancelable(io);
    var live: usize = 0;
    var oldest: ?*Session = null;
    for (registry.sessions.items) |session| {
        if (session.proc == null) continue;
        live += 1;
        if (session == current) continue;
        if (oldest == null or session.last_used_ms < oldest.?.last_used_ms) oldest = session;
    }
    registry.mutex.unlock(io);
    if (live < max_live_sessions) return;
    const victim = oldest orelse return;
    // A session in a step keeps its process; it is stopped next time.
    if (!victim.step_lock.tryLock()) return;
    defer victim.step_lock.unlock(io);
    victim.stopProcess();
}

// ---------------------------------------------------------------------------
// Process

const Incoming = union(enum) {
    stdout: []u8,
    call: OwnedCall,
    cancelled: []u8,
    stdout_closed,
    bridge_closed,

    fn deinit(self: Incoming) void {
        switch (self) {
            .stdout => |line| gpa.free(line),
            .call => |call| call.deinit(),
            .cancelled => |id| gpa.free(id),
            .stdout_closed, .bridge_closed => {},
        }
    }
};

const OwnedCall = struct {
    id_json: []u8,
    tool_use_id: []u8,

    fn deinit(self: OwnedCall) void {
        gpa.free(self.id_json);
        gpa.free(self.tool_use_id);
    }
};

/// A tool result fx has, kept until Claude Code asks for it.
const Answer = struct {
    tool_use_id: []u8,
    text: []u8,
    is_error: bool,

    fn deinit(self: Answer) void {
        gpa.free(self.tool_use_id);
        gpa.free(self.text);
    }
};

pub const Launch = struct {
    model: []const u8,
    effort: ?[]const u8 = null,
    system_prompt: []const u8,
    session_id: [36]u8,
    resume_session: bool,
    /// Null for a process without fx's tools.
    tools_json: ?[]const u8,
    /// A one-shot call: no session file, and the reply follows a schema
    /// when one is given.
    one_shot: bool = false,
    json_schema: ?[]const u8 = null,
};

const Proc = struct {
    pid: posix.pid_t,
    stdin: ?std.Io.File,
    /// Shared with the reader tasks; guarded by `mutex`.
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queue: std.ArrayList(Incoming) = .empty,
    stdout_task: ?std.Io.Future(void) = null,
    stderr_task: ?std.Io.Future(void) = null,
    bridge_task: ?std.Io.Future(void) = null,
    stderr_tail: [stderr_tail_bytes]u8 = undefined,
    stderr_len: usize = 0,
    // The bridge.
    dir_path: ?[]u8 = null,
    socket_path: ?[]u8 = null,
    listener: ?std.Io.net.Server = null,
    token: [32]u8 = undefined,
    /// The bridge connection; writes take `mutex`.
    conn: ?posix.socket_t = null,
    stop: std.atomic.Value(bool) = .init(false),
    /// The current `tools/list` result and its names; guarded by `mutex`.
    tools_json: ?[]u8 = null,
    tools_hash: u64 = 0,
    names: wire.ToolNames = .{},
    exited: bool = false,

    fn signal(self: *Proc, sig: posix.SIG) void {
        posix.kill(-self.pid, sig) catch posix.kill(self.pid, sig) catch {};
    }

    fn push(self: *Proc, item: Incoming) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.queue.append(gpa, item) catch {
            item.deinit();
            return;
        };
        self.cond.broadcast(io);
    }

    /// The next item, or null after `timeout_ms`.
    fn next(self: *Proc, timeout_ms: u32) ?Incoming {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.queue.items.len == 0) {
            self.cond.waitTimeout(io, &self.mutex, .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } }) catch {};
        }
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    fn writeStdin(self: *Proc, bytes: []const u8) !void {
        const file = self.stdin orelse return error.ProcessGone;
        file.writeStreamingAll(io_mod.getIo(), bytes) catch return error.ProcessGone;
    }

    /// Writes one line to the bridge. Callers hold no lock.
    fn writeBridge(self: *Proc, bytes: []const u8) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.writeBridgeLocked(bytes);
    }

    fn writeBridgeLocked(self: *Proc, bytes: []const u8) bool {
        const fd = self.conn orelse return false;
        var sent: usize = 0;
        while (sent < bytes.len) {
            const rc = std.c.write(fd, bytes[sent..].ptr, bytes.len - sent);
            if (rc < 0) {
                if (posix.errno(rc) == .INTR) continue;
                return false;
            }
            sent += @intCast(rc);
        }
        return true;
    }

    fn stderrText(self: *Proc) []const u8 {
        return std.mem.trim(u8, self.stderr_tail[0..self.stderr_len], " \t\r\n");
    }

    /// Replaces the tools Claude Code sees. Tells it when they changed.
    fn setTools(self: *Proc, functions: []const function_tools.Function) !void {
        // The names outlive the step, so they and the list use `gpa`.
        var names: wire.ToolNames = .{};
        errdefer names.deinit(gpa);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try wire.writeToolsList(gpa, &out.writer, functions, &names);
        const hash = std.hash.Wyhash.hash(0, out.written());
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.tools_json != null and hash == self.tools_hash) {
            names.deinit(gpa);
            return;
        }
        const changed = self.tools_json != null;
        if (self.tools_json) |old| gpa.free(old);
        self.tools_json = try out.toOwnedSlice();
        self.tools_hash = hash;
        self.names.deinit(gpa);
        self.names = names;
        if (changed and self.conn != null) {
            var line: std.Io.Writer.Allocating = .init(gpa);
            defer line.deinit();
            try wire.writeToolsChanged(&line.writer);
            _ = self.writeBridgeLocked(line.written());
        }
    }

    /// The fx name of a tool Claude Code called, owned by `alloc`.
    fn fxToolName(self: *Proc, alloc: Allocator, called: []const u8) ![]const u8 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.names.fxName(called)) |name| return alloc.dupe(u8, name);
        const bare = if (std.mem.startsWith(u8, called, wire.tool_prefix)) called[wire.tool_prefix.len..] else called;
        return alloc.dupe(u8, bare);
    }

    /// Stops the process and everything it started, and frees `self`.
    fn destroy(self: *Proc) void {
        const io = io_mod.getIo();
        self.stop.store(true, .release);
        if (self.stdin) |file| file.close(io);
        self.stdin = null;
        if (!self.exited) {
            self.signal(.TERM);
            const deadline = io_mod.milliTimestamp() + 2000;
            while (true) {
                var status: c_int = 0;
                const result = std.c.waitpid(self.pid, &status, std.c.W.NOHANG);
                if (result == self.pid or result == -1) break;
                if (io_mod.milliTimestamp() > deadline) {
                    self.signal(.KILL);
                    _ = std.c.waitpid(self.pid, &status, 0);
                    break;
                }
                io.sleep(.fromMilliseconds(20), .awake) catch {};
            }
            self.exited = true;
        }
        if (self.stdout_task) |*task| task.await(io);
        if (self.stderr_task) |*task| task.await(io);
        if (self.bridge_task) |*task| task.await(io);
        if (self.conn) |fd| _ = std.c.close(fd);
        self.conn = null;
        if (self.listener) |*listener| listener.deinit(io);
        if (self.socket_path) |path| {
            std.Io.Dir.cwd().deleteFile(io, path) catch {};
            gpa.free(path);
        }
        if (self.dir_path) |path| {
            std.Io.Dir.cwd().deleteTree(io, path) catch {};
            gpa.free(path);
        }
        for (self.queue.items) |item| item.deinit();
        self.queue.deinit(gpa);
        if (self.tools_json) |json| gpa.free(json);
        self.names.deinit(gpa);
        gpa.destroy(self);
        _ = registry.live.fetchSub(1, .acq_rel);
    }
};

fn readStdout(proc: *Proc, file: std.Io.File) void {
    const io = io_mod.getIo();
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    const reader = &file_reader.interface;
    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    while (true) {
        line.clearRetainingCapacity();
        _ = reader.streamDelimiterLimit(&line.writer, '\n', .limited(max_line_bytes)) catch break;
        const at_end = if (reader.discardDelimiterInclusive('\n')) |_| false else |_| true;
        const bytes = std.mem.trim(u8, line.written(), " \r");
        if (bytes.len > 0) {
            const owned = gpa.dupe(u8, bytes) catch break;
            proc.push(.{ .stdout = owned });
        }
        if (at_end) break;
    }
    proc.push(.stdout_closed);
}

fn readStderr(proc: *Proc, file: std.Io.File) void {
    const io = io_mod.getIo();
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&buffer}) catch break;
        if (n == 0) break;
        debug_trace.logf("claude-code", "stderr {s}", .{buffer[0..n]});
        proc.mutex.lockUncancelable(io);
        defer proc.mutex.unlock(io);
        const keep = @min(n, stderr_tail_bytes);
        const chunk = buffer[n - keep .. n];
        if (proc.stderr_len + keep > stderr_tail_bytes) {
            const drop = proc.stderr_len + keep - stderr_tail_bytes;
            @memmove(proc.stderr_tail[0 .. proc.stderr_len - drop], proc.stderr_tail[drop..proc.stderr_len]);
            proc.stderr_len -= drop;
        }
        @memcpy(proc.stderr_tail[proc.stderr_len..][0..keep], chunk);
        proc.stderr_len += keep;
    }
}

/// Accepts the bridge's connection and serves what Claude Code asks of the
/// MCP server, until the process stops. `tools/call` goes to the step.
fn serveBridge(proc: *Proc) void {
    const io = io_mod.getIo();
    const listener = &proc.listener.?;
    var buffered: std.ArrayList(u8) = .empty;
    defer buffered.deinit(gpa);
    var authenticated = false;
    while (!proc.stop.load(.acquire)) {
        const fd = proc.conn orelse {
            var fds = [_]posix.pollfd{.{ .fd = listener.socket.handle, .events = posix.POLL.IN, .revents = 0 }};
            const ready = posix.poll(&fds, poll_ms) catch return;
            if (ready == 0) continue;
            const stream = listener.accept(io) catch continue;
            proc.mutex.lockUncancelable(io);
            proc.conn = stream.socket.handle;
            proc.mutex.unlock(io);
            authenticated = false;
            buffered.clearRetainingCapacity();
            continue;
        };
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, poll_ms) catch return;
        if (ready == 0) continue;
        var chunk: [16 * 1024]u8 = undefined;
        const rc = std.c.recv(fd, &chunk, chunk.len, 0);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR or posix.errno(rc) == .AGAIN) continue;
        }
        if (rc <= 0) {
            proc.mutex.lockUncancelable(io);
            proc.conn = null;
            proc.mutex.unlock(io);
            _ = std.c.close(fd);
            if (authenticated) proc.push(.bridge_closed);
            continue;
        }
        buffered.appendSlice(gpa, chunk[0..@intCast(rc)]) catch return;
        while (std.mem.findScalar(u8, buffered.items, '\n')) |end| {
            const line = std.mem.trim(u8, buffered.items[0..end], " \r");
            if (!authenticated) {
                authenticated = std.mem.eql(u8, line, &proc.token);
                if (!authenticated) {
                    debug_trace.logf("claude-code", "bridge connection refused: wrong token", .{});
                    proc.mutex.lockUncancelable(io);
                    proc.conn = null;
                    proc.mutex.unlock(io);
                    _ = std.c.close(fd);
                    buffered.clearRetainingCapacity();
                    break;
                }
            } else if (line.len > 0) handleBridgeLine(proc, line);
            const rest = buffered.items.len - end - 1;
            @memmove(buffered.items[0..rest], buffered.items[end + 1 ..]);
            buffered.shrinkRetainingCapacity(rest);
        }
    }
}

fn handleBridgeLine(proc: *Proc, line: []const u8) void {
    const io = io_mod.getIo();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const incoming = wire.parseMcpLine(arena, line) catch {
        debug_trace.logf("claude-code", "bridge line unreadable", .{});
        return;
    };
    var reply: std.Io.Writer.Allocating = .init(arena);
    switch (incoming) {
        .initialize => |init| wire.writeInitializeResult(&reply.writer, init.id_json, init.protocol_version) catch return,
        .tools_list => |id| {
            proc.mutex.lockUncancelable(io);
            defer proc.mutex.unlock(io);
            wire.writeResult(&reply.writer, id, proc.tools_json orelse "{\"tools\":[]}") catch return;
            _ = proc.writeBridgeLocked(reply.written());
            return;
        },
        .ping => |id| wire.writeResult(&reply.writer, id, "{}") catch return,
        .unknown_request => |id| wire.writeMethodNotFound(&reply.writer, id) catch return,
        .tools_call => |call| {
            const owned: OwnedCall = .{
                .id_json = gpa.dupe(u8, call.id_json) catch return,
                .tool_use_id = gpa.dupe(u8, call.tool_use_id orelse "") catch return,
            };
            proc.push(.{ .call = owned });
            return;
        },
        .cancelled => |id| {
            if (id) |value| proc.push(.{ .cancelled = gpa.dupe(u8, value) catch return });
            return;
        },
        .ignored => return,
    }
    _ = proc.writeBridge(reply.written());
}

pub const StartError = error{ ClaudeNotInstalled, ProcessGone, OutOfMemory } || anyerror;

/// Starts `claude` for `launch`. The process owns its private directory,
/// which holds the system prompt, the MCP configuration, and the socket.
fn startProcess(alloc: Allocator, launch: Launch) StartError!*Proc {
    const io = io_mod.getIo();
    const proc = try gpa.create(Proc);
    proc.* = .{ .pid = 0, .stdin = null };
    var started = false;
    errdefer if (!started) {
        if (proc.listener) |*listener| listener.deinit(io);
        if (proc.dir_path) |path| {
            std.Io.Dir.cwd().deleteTree(io, path) catch {};
            gpa.free(path);
        }
        if (proc.socket_path) |path| gpa.free(path);
        if (proc.tools_json) |json| gpa.free(json);
        gpa.destroy(proc);
    };

    var suffix: [8]u8 = undefined;
    io.random(&suffix);
    const hex = std.fmt.bytesToHex(suffix, .lower);
    const tmp = std.mem.trimEnd(u8, io_mod.getenv("TMPDIR") orelse "/tmp", "/");
    // A Unix socket path is at most 104 bytes on macOS.
    const base = if (tmp.len + 40 < 100) tmp else "/tmp";
    proc.dir_path = try gpa.print("{s}/fx-cc-{s}", .{ base, &hex });
    try std.Io.Dir.cwd().createDir(io, proc.dir_path.?, .fromMode(0o700));

    const prompt_path = try alloc.print("{s}/system-prompt.md", .{proc.dir_path.?});
    try writePrivateFile(prompt_path, launch.system_prompt);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{
        "claude",               "-p",
        "--input-format",       "stream-json",
        "--output-format",      "stream-json",
        "--verbose",            "--include-partial-messages",
        "--tools",              "",
        "--strict-mcp-config",  "--setting-sources",
        "",                     "--disable-slash-commands",
        "--permission-mode",    "dontAsk",
        "--system-prompt-file", prompt_path,
        "--model",              launch.model,
    });
    if (launch.effort) |effort| try argv.appendSlice(alloc, &.{ "--effort", effort });
    if (launch.one_shot) {
        try argv.append(alloc, "--no-session-persistence");
        if (launch.json_schema) |schema| try argv.appendSlice(alloc, &.{ "--json-schema", schema });
    } else if (launch.resume_session) {
        try argv.appendSlice(alloc, &.{ "--resume", try alloc.dupe(u8, &launch.session_id) });
    } else {
        try argv.appendSlice(alloc, &.{ "--session-id", try alloc.dupe(u8, &launch.session_id) });
    }

    if (launch.tools_json != null) {
        proc.socket_path = try gpa.print("{s}/s", .{proc.dir_path.?});
        const address = try std.Io.net.UnixAddress.init(proc.socket_path.?);
        proc.listener = try address.listen(io, .{});
        var token_bytes: [16]u8 = undefined;
        io.random(&token_bytes);
        proc.token = std.fmt.bytesToHex(token_bytes, .lower);
        const exe = try self_exe.pathForPeerReexec(alloc);
        var config: std.Io.Writer.Allocating = .init(alloc);
        try config.writer.writeAll("{\"mcpServers\":{\"" ++ wire.server_name ++ "\":{\"type\":\"stdio\",\"command\":");
        try std.json.Stringify.value(exe, .{}, &config.writer);
        try config.writer.writeAll(",\"args\":");
        try std.json.Stringify.value(&[_][]const u8{ bridge_mode, proc.socket_path.?, &proc.token }, .{}, &config.writer);
        try config.writer.writeAll("}}}");
        const config_path = try alloc.print("{s}/mcp.json", .{proc.dir_path.?});
        try writePrivateFile(config_path, config.written());
        try argv.appendSlice(alloc, &.{ "--mcp-config", config_path, "--allowedTools", "mcp__" ++ wire.server_name });
        proc.tools_json = try gpa.dupe(u8, launch.tools_json.?);
        proc.tools_hash = std.hash.Wyhash.hash(0, launch.tools_json.?);
    }

    var env = try io_mod.cloneEnvironMap(alloc);
    try env.put("MCP_TOOL_TIMEOUT", tool_timeout_ms);
    // Claude Code's own memory of other conversations stays out of fx's.
    try env.put("CLAUDE_CODE_DISABLE_AUTO_MEMORY", "1");

    debug_trace.logf("claude-code", "starting claude model={s} session={s} resume={} one_shot={}", .{ launch.model, &launch.session_id, launch.resume_session, launch.one_shot });
    const child = std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        // Its own process group: the terminal's Ctrl-C is fx's to handle.
        .pgid = 0,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.ClaudeNotInstalled,
        else => return err,
    };
    proc.pid = child.id.?;
    proc.stdin = child.stdin;
    started = true;
    _ = registry.live.fetchAdd(1, .acq_rel);
    errdefer proc.destroy();
    proc.stdout_task = try io.concurrent(readStdout, .{ proc, child.stdout.? });
    proc.stderr_task = try io.concurrent(readStderr, .{ proc, child.stderr.? });
    if (proc.listener != null) proc.bridge_task = try io.concurrent(serveBridge, .{proc});
    {
        registry.mutex.lockUncancelable(io);
        defer registry.mutex.unlock(io);
        if (registry.exiting) proc.signal(.TERM);
    }
    return proc;
}

fn writePrivateFile(path: []const u8, bytes: []const u8) !void {
    const io = io_mod.getIo();
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .permissions = .fromMode(0o600), .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

// ---------------------------------------------------------------------------
// Session

const Pending = struct {
    tool_use_id: []u8,
    hash: u64,
};

const Session = struct {
    key: []u8,
    step_lock: std.Io.Mutex = .init,
    last_used_ms: i64 = 0,
    proc: ?*Proc = null,
    session_id: [36]u8 = undefined,
    /// What the process has seen, as units of fx's history.
    seen: std.ArrayList(wire.Unit) = .empty,
    /// Calls the process waits on.
    pending: std.ArrayList(Pending) = .empty,
    /// `tools/call` requests that came before fx had their results.
    arrived: std.ArrayList(OwnedCall) = .empty,
    /// Results fx has for calls Claude Code has not asked for yet.
    answers: std.ArrayList(Answer) = .empty,
    config_hash: u64 = 0,
    /// The process was started with `--resume` and has not answered yet.
    resume_unconfirmed: bool = false,
    /// A Claude session `--resume` could not continue; it is not tried again.
    failed_resume: ?[36]u8 = null,

    fn stopProcess(self: *Session) void {
        if (self.proc) |proc| proc.destroy();
        self.proc = null;
        self.clearCalls();
    }

    fn clearCalls(self: *Session) void {
        for (self.pending.items) |pending| gpa.free(pending.tool_use_id);
        self.pending.clearRetainingCapacity();
        for (self.arrived.items) |call| call.deinit();
        self.arrived.clearRetainingCapacity();
        for (self.answers.items) |stored| stored.deinit();
        self.answers.clearRetainingCapacity();
    }

    fn setSeen(self: *Session, list: []const wire.Unit) !void {
        self.seen.clearRetainingCapacity();
        try self.seen.appendSlice(gpa, list);
    }

    fn pendingHashes(self: *Session, alloc: Allocator) ![]u64 {
        const hashes = try alloc.alloc(u64, self.pending.items.len);
        for (self.pending.items, hashes) |pending, *hash| hash.* = pending.hash;
        return hashes;
    }

    /// Answers a call now when Claude Code is waiting on it, or keeps the
    /// result until it asks.
    fn answer(self: *Session, alloc: Allocator, tool_use_id: []const u8, text: []const u8, is_error: bool) !void {
        const proc = self.proc.?;
        for (self.arrived.items, 0..) |call, index| {
            if (!std.mem.eql(u8, call.tool_use_id, tool_use_id)) continue;
            var line: std.Io.Writer.Allocating = .init(alloc);
            try wire.writeToolCallResult(&line.writer, call.id_json, text, is_error);
            _ = proc.writeBridge(line.written());
            call.deinit();
            _ = self.arrived.orderedRemove(index);
            return;
        }
        const owned_id = try gpa.dupe(u8, tool_use_id);
        errdefer gpa.free(owned_id);
        const owned_text = try gpa.dupe(u8, text);
        errdefer gpa.free(owned_text);
        try self.answers.append(gpa, .{ .tool_use_id = owned_id, .text = owned_text, .is_error = is_error });
    }

    /// A `tools/call` came: answers it at once when fx has the result.
    fn takeCall(self: *Session, alloc: Allocator, call: OwnedCall) !void {
        for (self.answers.items, 0..) |stored, index| {
            if (!std.mem.eql(u8, stored.tool_use_id, call.tool_use_id)) continue;
            var line: std.Io.Writer.Allocating = .init(alloc);
            try wire.writeToolCallResult(&line.writer, call.id_json, stored.text, stored.is_error);
            _ = self.proc.?.writeBridge(line.written());
            stored.deinit();
            _ = self.answers.orderedRemove(index);
            call.deinit();
            return;
        }
        self.arrived.append(gpa, call) catch |err| {
            call.deinit();
            return err;
        };
    }

    fn dropArrived(self: *Session, id_json: []const u8) void {
        for (self.arrived.items, 0..) |call, index| {
            if (!std.mem.eql(u8, call.id_json, id_json)) continue;
            call.deinit();
            _ = self.arrived.orderedRemove(index);
            return;
        }
    }
};

// ---------------------------------------------------------------------------
// Steps

pub const StepInput = struct {
    request: stream_provider.ModelRequest,
    effort: ?[]const u8,
};

/// One model step for an fx session's conversation.
pub fn agentStep(alloc: Allocator, input: StepInput) anyerror!stream_provider.Result {
    const request = input.request;
    const session = try acquire(request.session_id orelse "");
    defer release(session);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const functions = try function_tools.select_functions(arena, request.tools, request.tool_choice, request.vision_mode);
    var tools_out: std.Io.Writer.Allocating = .init(arena);
    var scratch_names: wire.ToolNames = .{};
    try wire.writeToolsList(arena, &tools_out.writer, functions.items, &scratch_names);
    const system_prompt = try joinInstructions(arena, request.instructions);
    const config_hash = configHash(request.model, input.effort, system_prompt);
    const request_units = try wire.units(arena, request.messages);

    var plan: ?wire.DeltaPlan = null;
    if (session.proc != null and !session.proc.?.exited) {
        plan = wire.planDelta(session.seen.items, request_units, try session.pendingHashes(arena));
        if (plan.? == .diverged) {
            debug_trace.logf("claude-code", "history diverged reason={t}; starting over", .{plan.?.diverged});
            plan = null;
        }
    }

    if (plan != null and session.config_hash != config_hash) {
        // The model, effort, or system prompt changed: the same Claude
        // session continues in a process started with the new settings,
        // once it is not waiting on tool calls.
        if (session.pending.items.len == 0) {
            session.stopProcess();
            session.proc = startProcess(arena, .{
                .model = request.model,
                .effort = input.effort,
                .system_prompt = system_prompt,
                .session_id = session.session_id,
                .resume_session = true,
                .tools_json = tools_out.written(),
            }) catch |err| return startFailure(alloc, err);
            session.config_hash = config_hash;
        }
    }

    var seed_text: ?[]const u8 = null;
    if (plan == null) {
        session.stopProcess();
        evictIdle(session);
        var start = startPlan(arena, request.messages, request_units, session.failed_resume);
        session.session_id = start.session_id;
        session.proc = startProcess(arena, .{
            .model = request.model,
            .effort = input.effort,
            .system_prompt = system_prompt,
            .session_id = start.session_id,
            .resume_session = start.resumed,
            .tools_json = tools_out.written(),
        }) catch |err| return startFailure(alloc, err);
        session.config_hash = config_hash;
        session.resume_unconfirmed = start.resumed;
        try session.setSeen(request_units[0..start.seen]);
        if (start.resumed) {
            plan = wire.planDelta(session.seen.items, request_units, &.{});
            if (plan.? == .diverged) start.resumed = false;
        }
        if (!start.resumed) {
            // A new Claude session: what it hasn't seen goes in its first
            // message, as a transcript when there is history.
            var text: std.Io.Writer.Allocating = .init(arena);
            const latest_from = trailingUserStart(request.messages);
            if (latest_from == 0) {
                try wire.writeUserText(&text.writer, request.messages);
            } else {
                try wire.writeSeededPrompt(arena, &text.writer, request.messages[0..latest_from], request.messages[latest_from..]);
            }
            seed_text = text.written();
            try session.setSeen(request_units);
            plan = null;
        }
    }
    const proc = session.proc.?;
    try proc.setTools(functions.items);

    try request.admission.admit();
    if (seed_text) |text| {
        var line: std.Io.Writer.Allocating = .init(arena);
        try wire.writeUserMessage(&line.writer, text);
        proc.writeStdin(line.written()) catch return processFailure(alloc, session, "Claude Code stopped before it took the request.");
    } else if (plan) |delta| {
        try sendDelta(arena, session, request.messages, request_units, delta.extend);
        try session.setSeen(request_units);
    }
    request.delivery.markPossiblySent();
    return readStep(alloc, arena, session, request);
}

const StartPlan = struct {
    session_id: [36]u8,
    resumed: bool,
    /// Units of the history the resumed session has seen.
    seen: usize,
};

/// Chooses how a session without a usable process starts: resuming the
/// Claude session the latest matching reply recorded, or a new one.
fn startPlan(arena: Allocator, messages: []const types.ChatMessage, request_units: []const wire.Unit, skip: ?[36]u8) StartPlan {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        const replay = messages[index].provider_replay orelse continue;
        const record = wire.parseReplay(arena, replay.parts_json) orelse continue;
        if (skip) |id| if (std.mem.eql(u8, &id, record.session_id)) continue;
        if (record.units > request_units.len) continue;
        if (wire.digest(request_units[0..record.units]) != record.digest) continue;
        const delta = wire.planDelta(request_units[0..record.units], request_units, &.{});
        if (delta == .diverged) continue;
        var id: [36]u8 = undefined;
        @memcpy(&id, record.session_id);
        return .{ .session_id = id, .resumed = true, .seen = record.units };
    }
    var bytes: [16]u8 = undefined;
    io_mod.getIo().random(&bytes);
    return .{ .session_id = wire.formatSessionId(bytes), .resumed = false, .seen = 0 };
}

/// Where the trailing run of user and system messages starts.
fn trailingUserStart(messages: []const types.ChatMessage) usize {
    var index = messages.len;
    while (index > 0 and (messages[index - 1].role == .user or messages[index - 1].role == .system)) index -= 1;
    return index;
}

fn sendDelta(
    arena: Allocator,
    session: *Session,
    messages: []const types.ChatMessage,
    request_units: []const wire.Unit,
    delta: @FieldType(wire.DeltaPlan, "extend"),
) !void {
    const proc = session.proc.?;
    for (request_units[delta.first..delta.results_end]) |unit| {
        const message = messages[unit.message_index];
        for (session.pending.items, 0..) |pending, index| {
            if (pending.hash != unit.hash) continue;
            const failed = message.tool_result_status == .failure;
            try session.answer(arena, pending.tool_use_id, message.content orelse "", failed);
            gpa.free(pending.tool_use_id);
            _ = session.pending.orderedRemove(index);
            break;
        }
    }
    // Calls fx answered with nothing, such as ones a cancel left unrun.
    for (session.pending.items) |pending| {
        try session.answer(arena, pending.tool_use_id, "This tool call was not run.", true);
        gpa.free(pending.tool_use_id);
    }
    session.pending.clearRetainingCapacity();

    var first_user = messages.len;
    for (request_units[delta.results_end..]) |unit| first_user = @min(first_user, unit.message_index);
    if (first_user < messages.len) {
        var text: std.Io.Writer.Allocating = .init(arena);
        try wire.writeUserText(&text.writer, messages[first_user..]);
        if (text.written().len > 0) {
            var line: std.Io.Writer.Allocating = .init(arena);
            try wire.writeUserMessage(&line.writer, text.written());
            try proc.writeStdin(line.written());
        }
    }
}

const ToolBlock = struct {
    index: usize,
    id: []const u8,
    name: []const u8,
    input: std.ArrayList(u8) = .empty,
};

/// Reads Claude Code's stream until the step ends.
fn readStep(alloc: Allocator, arena: Allocator, session: *Session, request: stream_provider.ModelRequest) !stream_provider.Result {
    const proc = session.proc.?;
    const io = io_mod.getIo();
    var content: std.ArrayList(u8) = .empty;
    var blocks: std.ArrayList(ToolBlock) = .empty;
    var inputs: std.StringHashMapUnmanaged([]const u8) = .empty;
    var counts: wire.Counts = .{};
    var error_kind: ?[]const u8 = null;
    var rate_limited = false;
    var interrupted_at: ?i64 = null;
    var stop_error: ?anyerror = null;

    while (true) {
        if (interrupted_at == null) {
            if (request.cancel_flag.load(.seq_cst)) stop_error = error.Cancelled;
            if (request.deadline) |deadline| {
                if (deadline.durationFromNow(io).raw.nanoseconds <= 0) stop_error = error.Timeout;
            }
            if (stop_error != null) {
                var line: std.Io.Writer.Allocating = .init(arena);
                try wire.writeInterrupt(&line.writer, "fx-interrupt");
                proc.writeStdin(line.written()) catch {};
                interrupted_at = io_mod.milliTimestamp();
            }
        } else if (io_mod.milliTimestamp() - interrupted_at.? > interrupt_grace_ms) {
            session.stopProcess();
            return stop_error.?;
        }

        const item = proc.next(poll_ms) orelse continue;
        defer switch (item) {
            .stdout => |line| gpa.free(line),
            .cancelled => |id| gpa.free(id),
            .call, .stdout_closed, .bridge_closed => {},
        };
        switch (item) {
            .call => |call| try session.takeCall(arena, call),
            .cancelled => |id| session.dropArrived(id),
            .stdout_closed => {
                proc.exited = isExited(proc.pid);
                if (stop_error) |err| {
                    session.stopProcess();
                    return err;
                }
                const stderr_text = try arena.dupe(u8, proc.stderrText());
                return processFailure(alloc, session, if (stderr_text.len > 0) stderr_text else "Claude Code exited before it finished the step.");
            },
            .bridge_closed => {
                if (session.pending.items.len > 0 or session.arrived.items.len > 0) {
                    return processFailure(alloc, session, "Claude Code's connection to fx's tools closed.");
                }
            },
            .stdout => |line| {
                const parsed = wire.parseStdoutLine(arena, line) catch {
                    debug_trace.logf("claude-code", "unreadable line bytes={d}", .{line.len});
                    continue;
                };
                switch (parsed) {
                    .init => |init| if (init.session_id) |id| {
                        if (wire.validSessionId(id)) @memcpy(&session.session_id, id);
                    },
                    .message_start => |start| {
                        session.resume_unconfirmed = false;
                        counts = start.usage;
                        content.clearRetainingCapacity();
                        blocks.clearRetainingCapacity();
                        inputs = .empty;
                    },
                    .block_start => |start| if (start.kind == .tool_use) {
                        const id = try arena.dupe(u8, start.tool_id orelse "");
                        const name = try proc.fxToolName(arena, start.tool_name orelse "");
                        try blocks.append(arena, .{ .index = start.index, .id = id, .name = name });
                        if (stop_error == null) request.events.emit(.{ .tool_started = .{ .id = id, .name = name } });
                    },
                    .text_delta => |text| {
                        try content.appendSlice(arena, text);
                        if (stop_error == null and text.len > 0) request.events.emit(.{ .content_delta = text });
                    },
                    .thinking_delta => |text| if (stop_error == null and text.len > 0) request.events.emit(.{ .reasoning_delta = text }),
                    .input_delta => |delta| for (blocks.items) |*block| {
                        if (block.index == delta.index) try block.input.appendSlice(arena, delta.partial_json);
                    },
                    .assistant => |message| {
                        if (message.error_kind) |kind| error_kind = try arena.dupe(u8, kind);
                        for (message.tool_uses) |use| try inputs.put(arena, try arena.dupe(u8, use.id), try arena.dupe(u8, use.input_json));
                    },
                    .message_delta => |delta| counts.merge(delta.usage),
                    .message_stop => if (blocks.items.len > 0 and stop_error == null and error_kind == null) {
                        return toolStep(alloc, session, content.items, blocks.items, &inputs, counts);
                    },
                    .rate_limited => rate_limited = true,
                    .result => |result| {
                        if (stop_error) |err| return err;
                        if (result.is_error or error_kind != null) {
                            const class = wire.classifyFailure(error_kind, result.text);
                            return turnFailure(alloc, session, class, result.text, rate_limited);
                        }
                        return finalStep(alloc, session, content.items, counts, result);
                    },
                    .block_stop, .control_response, .other => {},
                }
            },
        }
    }
}

fn isExited(pid: posix.pid_t) bool {
    var status: c_int = 0;
    const result = std.c.waitpid(pid, &status, std.c.W.NOHANG);
    return result == pid or result == -1;
}

fn toolStep(
    alloc: Allocator,
    session: *Session,
    content: []const u8,
    blocks: []const ToolBlock,
    inputs: *const std.StringHashMapUnmanaged([]const u8),
    counts: wire.Counts,
) !stream_provider.Result {
    const calls = try alloc.alloc(types.ToolCall, blocks.len);
    var filled: usize = 0;
    errdefer {
        for (calls[0..filled]) |call| {
            alloc.free(call.id);
            alloc.free(call.name);
            alloc.free(call.arguments_json);
        }
        alloc.free(calls);
    }
    for (blocks) |block| {
        const arguments = inputs.get(block.id) orelse if (block.input.items.len > 0) block.input.items else "{}";
        const id = try alloc.dupe(u8, block.id);
        errdefer alloc.free(id);
        const name = try alloc.dupe(u8, block.name);
        errdefer alloc.free(name);
        calls[filled] = .{ .id = id, .name = name, .arguments_json = try alloc.dupe(u8, arguments) };
        filled += 1;
    }
    for (blocks) |block| {
        const owned = try gpa.dupe(u8, block.id);
        session.pending.append(gpa, .{ .tool_use_id = owned, .hash = wire.hashText(block.id) }) catch |err| {
            gpa.free(owned);
            return err;
        };
        try session.seen.append(gpa, .{ .kind = .call, .hash = wire.hashText(block.id), .message_index = 0 });
    }
    return .{ .completed = .{
        .completion = .{
            .content = if (content.len > 0) try alloc.dupe(u8, content) else null,
            .tool_calls = calls,
            .finish_reason = .tool_calls,
            .usage = counts.usage(),
        },
        .ownership = .owned,
    } };
}

fn finalStep(alloc: Allocator, session: *Session, content: []const u8, counts: wire.Counts, result: wire.Result) !stream_provider.Result {
    session.clearCalls();
    const replay = try wire.writeReplay(alloc, .{
        .session_id = &session.session_id,
        .units = session.seen.items.len,
        .digest = wire.digest(session.seen.items),
    });
    errdefer alloc.free(replay);
    const text = if (content.len > 0) content else (result.text orelse "");
    const finish: types.ProviderFinishReason = if (result.stop_reason) |reason|
        (if (std.mem.eql(u8, reason, "max_tokens")) .length else if (std.mem.eql(u8, reason, "refusal")) .content_filter else .stop)
    else
        .stop;
    return .{ .completed = .{
        .completion = .{
            .content = if (text.len > 0) try alloc.dupe(u8, text) else null,
            .finish_reason = finish,
            .finish_reason_raw = .init(result.stop_reason orelse "end_turn"),
            .usage = counts.usage(),
            .provider_state_json = replay,
        },
        .ownership = .owned,
    } };
}

fn turnFailure(alloc: Allocator, session: *Session, class: wire.FailureClass, text: ?[]const u8, rate_limited: bool) !stream_provider.Result {
    if (session.resume_unconfirmed and class != .not_signed_in and class != .usage_limit) session.failed_resume = session.session_id;
    // The process's transcript now ends in a failed turn; the next request
    // starts from fx's history.
    session.stopProcess();
    const kind: stream_provider.FailureKind = switch (class) {
        .not_signed_in => .unauthorized,
        .usage_limit => .quota_exhausted,
        .billing => .forbidden,
        .invalid_request => .invalid_request,
        .overloaded => .unavailable,
        .other => if (rate_limited) .quota_exhausted else .provider_error,
    };
    const detail = switch (class) {
        .not_signed_in => try alloc.dupe(u8, not_signed_in_message),
        else => try alloc.print("Claude Code: {s}", .{text orelse "the request failed"}),
    };
    return .{ .failed = .{ .kind = kind, .detail = detail, .ownership = .owned } };
}

fn processFailure(alloc: Allocator, session: *Session, text: []const u8) !stream_provider.Result {
    if (session.resume_unconfirmed) session.failed_resume = session.session_id;
    const detail = try alloc.print("Claude Code: {s}", .{text});
    session.stopProcess();
    return .{ .failed = .{ .kind = .provider_error, .detail = detail, .ownership = .owned } };
}

fn startFailure(alloc: Allocator, err: anyerror) !stream_provider.Result {
    if (err == error.OutOfMemory or err == error.Canceled) return err;
    const detail = if (err == error.ClaudeNotInstalled)
        try alloc.dupe(u8, not_installed_message)
    else
        try alloc.print("Claude Code could not start: {s}", .{@errorName(err)});
    return .{ .failed = .{ .kind = .unavailable, .detail = detail, .ownership = .owned } };
}

fn joinInstructions(arena: Allocator, instructions: []const types.ChatMessage) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (instructions) |message| {
        const text = message.content orelse continue;
        if (text.len == 0) continue;
        if (out.written().len > 0) try out.writer.writeAll("\n\n");
        try out.writer.writeAll(text);
    }
    if (out.written().len == 0) try out.writer.writeAll("You are a helpful assistant.");
    return out.written();
}

fn configHash(model: []const u8, effort: ?[]const u8, system_prompt: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(1);
    hasher.update(model);
    hasher.update(&.{0});
    hasher.update(effort orelse "");
    hasher.update(&.{0});
    hasher.update(system_prompt);
    return hasher.final();
}

// ---------------------------------------------------------------------------
// One-shot calls

pub const OneShot = struct {
    model: []const u8,
    system_prompt: []const u8,
    prompt: []const u8,
    json_schema: ?[]const u8 = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    deadline: ?std.Io.Clock.Timestamp = null,
};

pub const OneShotReply = union(enum) {
    text: []u8,
    structured: []u8,
    failed: stream_provider.Failure,
};

/// Runs one prompt through a short-lived `claude -p` with no tools and no
/// saved session, for fx's side calls: titles, summaries, and permission
/// reviews. The reply is owned by `alloc`.
pub fn oneShot(alloc: Allocator, input: OneShot) anyerror!OneShotReply {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var id_bytes: [16]u8 = undefined;
    io_mod.getIo().random(&id_bytes);
    const proc = startProcess(arena, .{
        .model = input.model,
        .system_prompt = input.system_prompt,
        .session_id = wire.formatSessionId(id_bytes),
        .resume_session = false,
        .tools_json = null,
        .one_shot = true,
        .json_schema = input.json_schema,
    }) catch |err| {
        const failure = try startFailure(alloc, err);
        return .{ .failed = failure.failed };
    };
    defer proc.destroy();
    var line: std.Io.Writer.Allocating = .init(arena);
    try wire.writeUserMessage(&line.writer, input.prompt);
    proc.writeStdin(line.written()) catch {};
    if (proc.stdin) |file| file.close(io_mod.getIo());
    proc.stdin = null;

    var content: std.ArrayList(u8) = .empty;
    var error_kind: ?[]const u8 = null;
    while (true) {
        if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        if (input.deadline) |deadline| {
            if (deadline.durationFromNow(io_mod.getIo()).raw.nanoseconds <= 0) return error.Timeout;
        }
        const item = proc.next(poll_ms) orelse continue;
        defer item.deinit();
        switch (item) {
            .stdout_closed => return .{ .failed = .{
                .kind = .provider_error,
                .detail = try alloc.print("Claude Code: {s}", .{if (proc.stderrText().len > 0) proc.stderrText() else "exited before it replied"}),
                .ownership = .owned,
            } },
            .stdout => |text| {
                const parsed = wire.parseStdoutLine(arena, text) catch continue;
                switch (parsed) {
                    .text_delta => |delta| try content.appendSlice(arena, delta),
                    .assistant => |message| if (message.error_kind) |kind| {
                        error_kind = try arena.dupe(u8, kind);
                    },
                    .result => |result| {
                        if (result.is_error or error_kind != null) {
                            const class = wire.classifyFailure(error_kind, result.text);
                            return .{ .failed = .{
                                .kind = switch (class) {
                                    .not_signed_in => .unauthorized,
                                    .usage_limit => .quota_exhausted,
                                    .overloaded => .unavailable,
                                    else => .provider_error,
                                },
                                .detail = if (class == .not_signed_in)
                                    try alloc.dupe(u8, not_signed_in_message)
                                else
                                    try alloc.print("Claude Code: {s}", .{result.text orelse "the request failed"}),
                                .ownership = .owned,
                            } };
                        }
                        if (result.structured_json) |json| return .{ .structured = try alloc.dupe(u8, json) };
                        const text_out = if (content.items.len > 0) content.items else (result.text orelse "");
                        return .{ .text = try alloc.dupe(u8, text_out) };
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

test "claude code: the trailing user run starts after the last tool result" {
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "a" },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "c", .name = "t", .arguments_json = "{}" }} },
        .{ .role = .tool, .tool_call_id = "c", .content = "r" },
        .{ .role = .system, .content = "note", .context_note = true },
        .{ .role = .user, .content = "b" },
    };
    try std.testing.expectEqual(@as(usize, 3), trailingUserStart(&messages));
    try std.testing.expectEqual(@as(usize, 0), trailingUserStart(messages[0..1]));
    try std.testing.expectEqual(@as(usize, 3), trailingUserStart(messages[0..3]));
}

test "claude code: a start resumes the latest reply whose history still matches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = [_]types.ChatMessage{.{ .role = .user, .content = "one" }};
    const first_units = try wire.units(arena, &first);
    const id = wire.formatSessionId(@splat(7));
    const replay = try wire.writeReplay(arena, .{ .session_id = &id, .units = first_units.len, .digest = wire.digest(first_units) });
    const source: @import("../core/config/model_provider.zig").ProviderSelection = .{ .provider = .gateway, .model = "m" };
    const messages = [_]types.ChatMessage{
        first[0],
        .{ .role = .assistant, .content = "ok", .provider_replay = .{ .source = source, .parts_json = replay } },
        .{ .role = .user, .content = "two" },
    };
    const request_units = try wire.units(arena, &messages);
    const plan = startPlan(arena, &messages, request_units, null);
    try std.testing.expect(plan.resumed);
    try std.testing.expectEqualStrings(&id, &plan.session_id);
    try std.testing.expectEqual(@as(usize, 1), plan.seen);

    const rewritten = [_]types.ChatMessage{ .{ .role = .user, .content = "changed" }, messages[1], messages[2] };
    const rewritten_units = try wire.units(arena, &rewritten);
    try std.testing.expect(!startPlan(arena, &rewritten, rewritten_units, null).resumed);
    try std.testing.expect(!startPlan(arena, &messages, request_units, id).resumed);
}
