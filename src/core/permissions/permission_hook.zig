//! Profile-configured command that may answer an open interactive permission
//! prompt. The terminal prompt stays open while the command runs, and the first
//! accepted answer wins. The command can allow the exact action once or deny it;
//! every failure is no opinion, which leaves the decision with the human.

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const diff_mod = @import("../output/diff.zig");
const file_mutation_contract = @import("../tooling/file_mutation_contract.zig");
const io_mod = @import("../shared/io.zig");
const permission_prompter = @import("permission_prompter.zig");
const permission_request = @import("permission_request.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const setting_key = "permission_hook";
/// Builds that cannot start a thread or a process never run the hook.
pub const supported = !builtin.single_threaded and std.process.can_spawn;
/// The hook never starts in the workspace, so a repository cannot supply the
/// program or the modules that answer its own prompts.
const hook_working_directory = "/";
const default_timeout_ms: u32 = 300_000;
pub const min_timeout_ms: u32 = 1_000;
pub const max_timeout_ms: u32 = 3_600_000;
pub const max_command_args: usize = 32;
const max_command_arg_bytes: usize = 4 * 1024;
const max_input_bytes: usize = 1024 * 1024;
const max_output_bytes: usize = 64 * 1024;
const max_reason_bytes: usize = 4 * 1024;
const input_version: u32 = 1;
const poll_interval_ns: u64 = 25 * std.time.ns_per_ms;
const input_drain_grace_ms: i64 = 100;

/// Owned hook settings parsed from the profile.
pub const Config = struct {
    command: []const []const u8,
    timeout_ms: u32 = default_timeout_ms,

    pub fn deinit(self: *Config, alloc: Allocator) void {
        for (self.command) |arg| alloc.free(arg);
        alloc.free(self.command);
        self.* = undefined;
    }
};

pub const ConfigError = error{
    OutOfMemory,
    InvalidPermissionHookType,
    InvalidPermissionHookCommand,
    InvalidPermissionHookTimeout,
    UnknownPermissionHookField,
};

/// Parses the `permission_hook` profile object. Caller owns the result.
pub fn parseConfig(alloc: Allocator, value: std.json.Value) ConfigError!Config {
    if (value != .object) return error.InvalidPermissionHookType;
    var fields = value.object.iterator();
    while (fields.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.eql(u8, key, "command") and !std.mem.eql(u8, key, "timeout_ms")) {
            return error.UnknownPermissionHookField;
        }
    }

    const command_value = value.object.get("command") orelse
        return error.InvalidPermissionHookCommand;
    if (command_value != .array) return error.InvalidPermissionHookCommand;
    const items = command_value.array.items;
    if (items.len == 0 or items.len > max_command_args) return error.InvalidPermissionHookCommand;
    if (items[0] != .string or !std.fs.path.isAbsolute(items[0].string)) {
        return error.InvalidPermissionHookCommand;
    }
    for (items) |item| {
        if (item != .string) return error.InvalidPermissionHookCommand;
        if (item.string.len == 0 or item.string.len > max_command_arg_bytes) {
            return error.InvalidPermissionHookCommand;
        }
        if (std.mem.findScalar(u8, item.string, 0) != null) return error.InvalidPermissionHookCommand;
    }

    const timeout_ms = if (value.object.get("timeout_ms")) |timeout_value| blk: {
        if (timeout_value != .integer) return error.InvalidPermissionHookTimeout;
        if (timeout_value.integer < min_timeout_ms or timeout_value.integer > max_timeout_ms) {
            return error.InvalidPermissionHookTimeout;
        }
        break :blk @as(u32, @intCast(timeout_value.integer));
    } else default_timeout_ms;

    const command = try alloc.alloc([]const u8, items.len);
    var filled: usize = 0;
    errdefer {
        for (command[0..filled]) |arg| alloc.free(arg);
        alloc.free(command);
    }
    for (items, command) |item, *arg| {
        arg.* = try alloc.dupe(u8, item.string);
        filled += 1;
    }
    return .{ .command = command, .timeout_ms = timeout_ms };
}

/// Borrowed hook settings plus the prompt scope sent to the command.
pub const Binding = struct {
    config: *const Config,
    workspace_root: []const u8,
    session_id: ?[]const u8 = null,
};

/// The command's answer. `deny` owns its terminal-safe reason, which may be empty.
const Verdict = union(enum) {
    no_opinion,
    allow,
    deny: []u8,

    fn deinit(self: *Verdict, alloc: Allocator) void {
        switch (self.*) {
            .deny => |reason| alloc.free(reason),
            .no_opinion, .allow => {},
        }
        self.* = .no_opinion;
    }
};

/// Maps the command's stdout to a verdict. Anything but a well-formed allow or
/// deny is no opinion. Unknown response fields are ignored.
fn parseVerdict(alloc: Allocator, output: []const u8) Allocator.Error!Verdict {
    if (output.len == 0 or output.len > max_output_bytes) return .no_opinion;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, output, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .no_opinion,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .no_opinion;
    const decision = parsed.value.object.get("decision") orelse return .no_opinion;
    if (decision != .string) return .no_opinion;
    if (std.mem.eql(u8, decision.string, "allow")) return .allow;
    if (!std.mem.eql(u8, decision.string, "deny")) return .no_opinion;

    const reason = if (parsed.value.object.get("reason")) |reason_value| switch (reason_value) {
        .string => |text| text,
        .null => "",
        else => return .no_opinion,
    } else "";
    if (reason.len > max_reason_bytes or !std.unicode.utf8ValidateSlice(reason)) return .no_opinion;
    const encoded = try text_utils.encodeTerminalSafe(alloc, reason, max_reason_bytes);
    return .{ .deny = encoded.bytes };
}

const EncodeError = error{
    OutOfMemory,
    InvalidToolArguments,
    RequestTooLarge,
};

const ToolDocument = struct {
    name: []const u8,
    call_id: []const u8,
    arguments: std.json.Value,
};

const FileLineDocument = struct {
    op: diff_mod.PreviewOp,
    text: []const u8,
};

const FileDocument = struct {
    kind: file_mutation_contract.Kind,
    intent: permission_request.FileApprovalIntent,
    path: []const u8,
    external_tree: ?[]const u8,
    additions: usize,
    deletions: usize,
    truncated: bool,
    lines: []const FileLineDocument,
};

const PromptDocument = struct {
    label: []const u8,
    command: ?[]const u8,
    explanation: ?[]const u8,
    tool_arguments_preview: ?[]const u8,
    file: ?FileDocument,
};

const RequestDocument = struct {
    version: u32 = input_version,
    event: []const u8 = "permission_request",
    request_id: u64,
    session_id: ?[]const u8,
    workspace_root: []const u8,
    origin: []const u8,
    tool: ToolDocument,
    prompt: PromptDocument,
    choices: []const []const u8 = &.{ "allow", "deny" },
};

/// Encodes the stdin document for one open prompt. Caller owns the bytes.
fn encodeRequest(
    alloc: Allocator,
    binding: Binding,
    request: permission_request.PermissionRequest,
    call: types.ToolCall,
) EncodeError![]u8 {
    if (call.arguments_json.len > max_input_bytes) return error.RequestTooLarge;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const arguments = std.json.parseFromSliceLeaky(std.json.Value, arena, call.arguments_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolArguments,
    };
    const document: RequestDocument = .{
        .request_id = request.id,
        .session_id = binding.session_id,
        .workspace_root = binding.workspace_root,
        .origin = switch (request.origin) {
            .active_session => "session",
            .subagent => "subagent",
        },
        .tool = .{
            .name = call.name,
            .call_id = call.id,
            .arguments = arguments,
        },
        .prompt = .{
            .label = request.label,
            .command = request.command,
            .explanation = request.explanation,
            .tool_arguments_preview = request.tool_arguments_preview,
            .file = if (request.file) |file| try fileDocument(arena, file) else null,
        },
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    std.json.Stringify.value(document, .{}, &out.writer) catch return error.OutOfMemory;
    if (out.written().len > max_input_bytes) return error.RequestTooLarge;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn fileDocument(
    arena: Allocator,
    file: permission_request.FileApprovalRequest,
) Allocator.Error!FileDocument {
    const lines = try arena.alloc(FileLineDocument, file.preview.lines.len);
    for (file.preview.lines, lines) |line, *document| {
        document.* = .{ .op = line.op, .text = line.text };
    }
    return .{
        .kind = file.kind,
        .intent = file.intent,
        .path = file.preview.path,
        .external_tree = switch (file.scope) {
            .workspace_files => null,
            .external_tree => |root| root,
        },
        .additions = file.preview.additions,
        .deletions = file.preview.deletions,
        .truncated = file.preview.truncated,
        .lines = lines,
    };
}

/// Runs the command with `input` on stdin until it exits, the timeout passes,
/// or `cancel` is set. Returns no opinion for every failure.
fn run(
    alloc: Allocator,
    config: *const Config,
    input: []const u8,
    cancel: *const std.atomic.Value(bool),
) Allocator.Error!Verdict {
    const output = (try runProcess(alloc, config, input, cancel)) orelse return .no_opinion;
    defer alloc.free(output);
    return parseVerdict(alloc, output);
}

fn runProcess(
    alloc: Allocator,
    config: *const Config,
    input: []const u8,
    cancel: *const std.atomic.Value(bool),
) Allocator.Error!?[]u8 {
    const zio = io_mod.getIo();
    const deadline_ms = io_mod.milliTimestamp() + @as(i64, config.timeout_ms);
    var child = std.process.spawn(zio, .{
        .argv = config.command,
        .cwd = .{ .path = hook_working_directory },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = own_process_group,
    }) catch |err| {
        debug_trace.logf("permission", "event=permission_hook_spawn_failed error={s}", .{@errorName(err)});
        return null;
    };
    const process_group = child.id.?;
    const input_writer = InputWriter.start(child.stdin.?, input) catch |err| {
        debug_trace.logf("permission", "event=permission_hook_writer_failed error={s}", .{@errorName(err)});
        stopAndReapLeader(&child, process_group);
        return null;
    };
    child.stdin = null;
    var leader_reaped = false;
    defer {
        if (leader_reaped) {
            if (!input_writer.waitForDone(input_drain_grace_ms)) signalProcessGroup(process_group);
        } else {
            stopAndReapLeader(&child, process_group);
        }
        input_writer.finish(input_drain_grace_ms);
    }

    var reader_buffer: std.Io.File.MultiReader.Buffer(1) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(alloc, zio, reader_buffer.toStreams(), &.{child.stdout.?});
    defer multi_reader.deinit();
    const stdout_reader = multi_reader.reader(0);
    const poll_timeout: std.Io.Timeout = .{
        .duration = .{ .raw = .{ .nanoseconds = poll_interval_ns }, .clock = .awake },
    };
    while (true) {
        if (stopRequested(cancel, deadline_ms)) return null;
        const keep_reading = if (multi_reader.fill(1024, poll_timeout))
            true
        else |err| switch (err) {
            error.EndOfStream => false,
            error.Timeout => true,
            else => return null,
        };
        if (stdout_reader.buffered().len > max_output_bytes) {
            debug_trace.logf("permission", "event=permission_hook_output_too_large", .{});
            return null;
        }
        if (!keep_reading) break;
    }
    multi_reader.checkAnyError() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };

    const term = waitForExit(&child, deadline_ms, cancel) orelse return null;
    leader_reaped = true;
    switch (term) {
        .exited => |code| if (code != 0) {
            debug_trace.logf("permission", "event=permission_hook_exit code={d}", .{code});
            return null;
        },
        .signal, .stopped, .unknown => return null,
    }
    return try multi_reader.toOwnedSlice(0);
}

fn stopRequested(cancel: *const std.atomic.Value(bool), deadline_ms: i64) bool {
    if (cancel.load(.acquire)) return true;
    if (io_mod.milliTimestamp() >= deadline_ms) {
        debug_trace.logf("permission", "event=permission_hook_timeout", .{});
        return true;
    }
    return false;
}

const own_process_group: ?std.posix.pid_t = if (builtin.os.tag == .windows) null else 0;

/// Feeds stdin from its own thread so a command that never reads cannot block
/// the caller. The write fails once every reader of the pipe is gone. A reader
/// that left the process group can hold the pipe open without reading, so the
/// writer owns a copy of the input and outlives the caller when abandoned; the
/// last of the thread and the caller to release it frees it.
const InputWriter = struct {
    file: std.Io.File,
    input: []u8,
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),
    holders: std.atomic.Value(u8) = .init(2),

    fn start(file: std.Io.File, input: []const u8) (Allocator.Error || std.Thread.SpawnError)!*InputWriter {
        const alloc = std.heap.c_allocator;
        const self = try alloc.create(InputWriter);
        errdefer alloc.destroy(self);
        self.* = .{ .file = file, .input = try alloc.dupe(u8, input) };
        errdefer alloc.free(self.input);
        self.thread = try std.Thread.spawn(.{}, writeInput, .{self});
        return self;
    }

    fn writeInput(self: *InputWriter) void {
        const zio = io_mod.getIo();
        self.file.writeStreamingAll(zio, self.input) catch {};
        self.file.close(zio);
        self.done.store(true, .release);
        self.release();
    }

    fn waitForDone(self: *const InputWriter, grace_ms: i64) bool {
        const deadline_ms = io_mod.milliTimestamp() + grace_ms;
        while (!self.done.load(.acquire)) {
            if (io_mod.milliTimestamp() >= deadline_ms) return false;
            io_mod.sleep(5 * std.time.ns_per_ms);
        }
        return true;
    }

    /// Joins the writer once stdin is written or closed. A write still blocked
    /// after `grace_ms` is abandoned, so the caller's release never waits on a
    /// process fx no longer controls.
    fn finish(self: *InputWriter, grace_ms: i64) void {
        if (self.waitForDone(grace_ms)) {
            self.thread.join();
        } else {
            debug_trace.logf("permission", "event=permission_hook_writer_abandoned", .{});
            self.thread.detach();
        }
        self.release();
    }

    fn release(self: *InputWriter) void {
        if (self.holders.fetchSub(1, .acq_rel) != 1) return;
        const alloc = std.heap.c_allocator;
        alloc.free(self.input);
        alloc.destroy(self);
    }
};

/// Kills the command's process group, then reaps its leader. A cancelled wait
/// releases the child's id without reaping, so the leader is then reaped by pid.
fn stopAndReapLeader(child: *std.process.Child, process_group: std.process.Child.Id) void {
    signalProcessGroup(process_group);
    signalLeader(process_group);
    if (child.id != null) {
        child.kill(io_mod.getIo());
    } else {
        reapProcess(process_group);
    }
}

fn signalProcessGroup(process_group: std.process.Child.Id) void {
    if (comptime builtin.os.tag == .windows) return;
    std.posix.kill(-process_group, .KILL) catch {};
}

/// Covers a leader that moved itself into another process group.
fn signalLeader(pid: std.process.Child.Id) void {
    if (comptime builtin.os.tag == .windows) return;
    std.posix.kill(pid, .KILL) catch {};
}

fn reapProcess(pid: std.process.Child.Id) void {
    if (comptime builtin.os.tag == .windows) return;
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) switch (std.posix.errno(std.posix.system.waitpid(pid, &status, 0))) {
        .INTR => continue,
        else => return,
    };
}

const ExitEvent = union(enum) {
    exited: anyerror!std.process.Child.Term,
    stopped: anyerror!void,
};

fn waitForChild(child: *std.process.Child) anyerror!std.process.Child.Term {
    return child.wait(io_mod.getIo());
}

fn waitForStop(cancel: *const std.atomic.Value(bool), deadline_ms: i64) anyerror!void {
    while (!stopRequested(cancel, deadline_ms)) {
        try io_mod.getIo().sleep(.fromNanoseconds(poll_interval_ns), .awake);
    }
}

/// Waits for exit after stdout closed, so a command that closes stdout and keeps
/// running still honors the timeout and cancellation.
fn waitForExit(
    child: *std.process.Child,
    deadline_ms: i64,
    cancel: *const std.atomic.Value(bool),
) ?std.process.Child.Term {
    var select_buffer: [2]ExitEvent = undefined;
    var select: std.Io.Select(ExitEvent) = .init(io_mod.getIo(), &select_buffer);
    select.concurrent(.exited, waitForChild, .{child}) catch return null;
    select.concurrent(.stopped, waitForStop, .{ cancel, deadline_ms }) catch {
        select.cancelDiscard();
        return null;
    };
    const event = select.await() catch {
        select.cancelDiscard();
        return null;
    };
    select.cancelDiscard();
    return switch (event) {
        .exited => |result| result catch null,
        .stopped => null,
    };
}

/// Runs the hook for one open prompt and submits its answer to that prompt.
/// Lives on the stack of the admission call that opened the prompt; `finish`
/// must run before it goes out of scope.
pub const Race = struct {
    binding: Binding,
    call: types.ToolCall,
    cancel: std.atomic.Value(bool) = .init(false),
    input: ?[]u8 = null,
    answer: ?permission_prompter.Answer = null,
    thread: ?std.Thread = null,

    pub fn init(binding: Binding, call: types.ToolCall) Race {
        return .{ .binding = binding, .call = call };
    }

    pub fn responder(self: *Race) permission_prompter.Responder {
        return .{ .context = @ptrCast(self), .open_fn = open };
    }

    /// Stops the command if it is still running and waits for its thread.
    pub fn finish(self: *Race) void {
        self.cancel.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.input) |input| std.heap.c_allocator.free(input);
        self.input = null;
    }

    fn open(
        raw: *anyopaque,
        request: permission_request.PermissionRequest,
        answer: permission_prompter.Answer,
    ) void {
        const self: *Race = @ptrCast(@alignCast(raw));
        if (self.thread != null or request.confirmation_only) return;
        const input = encodeRequest(std.heap.c_allocator, self.binding, request, self.call) catch |err| {
            debug_trace.logf("permission", "event=permission_hook_skipped request_id={d} reason={s}", .{ request.id, @errorName(err) });
            return;
        };
        self.input = input;
        self.answer = answer;
        self.thread = std.Thread.spawn(.{}, runAndAnswer, .{self}) catch |err| {
            debug_trace.logf("permission", "event=permission_hook_thread_failed error={s}", .{@errorName(err)});
            std.heap.c_allocator.free(input);
            self.input = null;
            self.answer = null;
            return;
        };
        debug_trace.logf("permission", "event=permission_hook_started request_id={d}", .{request.id});
    }

    fn runAndAnswer(self: *Race) void {
        const alloc = std.heap.c_allocator;
        var verdict = run(
            alloc,
            self.binding.config,
            self.input.?,
            &self.cancel,
        ) catch .no_opinion;
        defer verdict.deinit(alloc);
        const answer = self.answer.?;
        debug_trace.logf("permission", "event=permission_hook_verdict request_id={d} verdict={s}", .{ answer.request_id, @tagName(verdict) });
        if (self.cancel.load(.acquire)) return;
        const response = switch (verdict) {
            .no_opinion => return,
            .allow => permission_request.OwnedPermissionResponse.init(alloc, .once, null),
            .deny => |reason| permission_request.OwnedPermissionResponse.init(
                alloc,
                .deny,
                if (reason.len == 0) null else alloc.dupe(u8, reason) catch null,
            ),
        };
        const accepted = answer.submit(response);
        debug_trace.logf("permission", "event=permission_hook_answer request_id={d} accepted={}", .{ answer.request_id, accepted });
    }
};

fn testConfig(alloc: Allocator, json: []const u8) !Config {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    return parseConfig(alloc, parsed.value);
}

fn expectConfigError(expected: ConfigError, json: []const u8) !void {
    try std.testing.expectError(expected, testConfig(std.testing.allocator, json));
}

test "parseConfig accepts an argv command and a bounded timeout" {
    var config = try testConfig(
        std.testing.allocator,
        "{\"command\":[\"/usr/local/bin/approve\",\"--fx\"],\"timeout_ms\":120000}",
    );
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), config.command.len);
    try std.testing.expectEqualStrings("/usr/local/bin/approve", config.command[0]);
    try std.testing.expectEqualStrings("--fx", config.command[1]);
    try std.testing.expectEqual(@as(u32, 120_000), config.timeout_ms);
}

test "parseConfig defaults the timeout" {
    var config = try testConfig(std.testing.allocator, "{\"command\":[\"/usr/local/bin/approve\"]}");
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(default_timeout_ms, config.timeout_ms);
}

test "parseConfig rejects malformed settings" {
    try expectConfigError(error.InvalidPermissionHookType, "\"/usr/local/bin/approve\"");
    try expectConfigError(error.InvalidPermissionHookType, "[\"approve\"]");
    try expectConfigError(error.InvalidPermissionHookCommand, "{}");
    try expectConfigError(error.InvalidPermissionHookCommand, "{\"command\":\"approve --fx\"}");
    try expectConfigError(error.InvalidPermissionHookCommand, "{\"command\":[]}");
    try expectConfigError(error.InvalidPermissionHookCommand, "{\"command\":[\"\"]}");
    try expectConfigError(error.InvalidPermissionHookCommand, "{\"command\":[\"/bin/approve\",7]}");
    try expectConfigError(error.InvalidPermissionHookCommand, "{\"command\":[\"/bin/appr\\u0000ove\"]}");
    try expectConfigError(error.InvalidPermissionHookCommand, "{\"command\":[7]}");
    try expectConfigError(error.InvalidPermissionHookCommand, "{\"command\":[\"approve\"]}");
    try expectConfigError(error.InvalidPermissionHookCommand, "{\"command\":[\"./approve.sh\"]}");
    try expectConfigError(error.InvalidPermissionHookCommand, "{\"command\":[\"bin/approve\",\"--fx\"]}");
    try expectConfigError(error.InvalidPermissionHookTimeout, "{\"command\":[\"/bin/approve\"],\"timeout_ms\":\"60000\"}");
    try expectConfigError(error.InvalidPermissionHookTimeout, "{\"command\":[\"/bin/approve\"],\"timeout_ms\":999}");
    try expectConfigError(error.InvalidPermissionHookTimeout, "{\"command\":[\"/bin/approve\"],\"timeout_ms\":3600001}");
    try expectConfigError(error.InvalidPermissionHookTimeout, "{\"command\":[\"/bin/approve\"],\"timeout_ms\":1.5}");
    try expectConfigError(error.UnknownPermissionHookField, "{\"command\":[\"/bin/approve\"],\"shell\":true}");
}

test "parseConfig bounds the argv" {
    const alloc = std.testing.allocator;
    var json: std.Io.Writer.Allocating = .init(alloc);
    defer json.deinit();
    try json.writer.writeAll("{\"command\":[\"/bin/approve\"");
    for (0..max_command_args) |_| try json.writer.writeAll(",\"arg\"");
    try json.writer.writeAll("]}");
    try expectConfigError(error.InvalidPermissionHookCommand, json.written());

    const long_arg = try alloc.alloc(u8, max_command_arg_bytes + 1);
    defer alloc.free(long_arg);
    @memset(long_arg, 'a');
    const long_json = try std.fmt.allocPrint(alloc, "{{\"command\":[\"/bin/approve\",\"{s}\"]}}", .{long_arg});
    defer alloc.free(long_json);
    try expectConfigError(error.InvalidPermissionHookCommand, long_json);
}

fn expectVerdict(expected: std.meta.Tag(Verdict), output: []const u8) !void {
    var verdict = try parseVerdict(std.testing.allocator, output);
    defer verdict.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected, std.meta.activeTag(verdict));
}

test "parseVerdict maps allow deny and none" {
    try expectVerdict(.allow, "{\"decision\":\"allow\"}\n");
    try expectVerdict(.no_opinion, "{\"decision\":\"none\"}");
    try expectVerdict(.allow, "{\"decision\":\"allow\",\"source\":\"phone\"}");

    var denied = try parseVerdict(std.testing.allocator, "{\"decision\":\"deny\",\"reason\":\"Denied from phone\"}");
    defer denied.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Denied from phone", denied.deny);

    var bare = try parseVerdict(std.testing.allocator, "{\"decision\":\"deny\"}");
    defer bare.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", bare.deny);
}

test "parseVerdict treats every malformed answer as no opinion" {
    try expectVerdict(.no_opinion, "");
    try expectVerdict(.no_opinion, "allow");
    try expectVerdict(.no_opinion, "{\"decision\":\"allow\"");
    try expectVerdict(.no_opinion, "[\"allow\"]");
    try expectVerdict(.no_opinion, "{}");
    try expectVerdict(.no_opinion, "{\"decision\":true}");
    try expectVerdict(.no_opinion, "{\"decision\":\"always\"}");
    try expectVerdict(.no_opinion, "{\"decision\":\"ALLOW\"}");
    try expectVerdict(.no_opinion, "{\"decision\":\"deny\",\"reason\":42}");
    try expectVerdict(.no_opinion, "{\"decision\":\"deny\",\"decision\":\"allow\"}");
    try expectVerdict(.no_opinion, "{\"decision\":\"allow\"}{\"decision\":\"deny\"}");

    const alloc = std.testing.allocator;
    const long_reason = try alloc.alloc(u8, max_reason_bytes + 1);
    defer alloc.free(long_reason);
    @memset(long_reason, 'r');
    const long_json = try std.fmt.allocPrint(alloc, "{{\"decision\":\"deny\",\"reason\":\"{s}\"}}", .{long_reason});
    defer alloc.free(long_json);
    try expectVerdict(.no_opinion, long_json);

    const oversized = try alloc.alloc(u8, max_output_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, ' ');
    @memcpy(oversized[0.."{\"decision\":\"allow\"}".len], "{\"decision\":\"allow\"}");
    try expectVerdict(.no_opinion, oversized);
}

test "parseVerdict makes a deny reason terminal safe" {
    var verdict = try parseVerdict(std.testing.allocator, "{\"decision\":\"deny\",\"reason\":\"no\\u001b[2Jthanks\"}");
    defer verdict.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.findScalar(u8, verdict.deny, 0x1b) == null);
}

test "encodeRequest carries the prompt the human sees and the exact call" {
    const alloc = std.testing.allocator;
    const command = [_][]const u8{"approve"};
    const config: Config = .{ .command = &command };
    const encoded = try encodeRequest(
        alloc,
        .{ .config = &config, .workspace_root = "/work", .session_id = "session-1" },
        .{
            .id = 7,
            .label = "Run touch marker.txt",
            .command = "touch marker.txt",
        },
        .{
            .id = "call_1",
            .name = "shell",
            .arguments_json = "{\"request\":{\"action\":\"run\",\"command\":\"touch marker.txt\"}}",
        },
    );
    defer alloc.free(encoded);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), root.get("version").?.integer);
    try std.testing.expectEqualStrings("permission_request", root.get("event").?.string);
    try std.testing.expectEqual(@as(i64, 7), root.get("request_id").?.integer);
    try std.testing.expectEqualStrings("session-1", root.get("session_id").?.string);
    try std.testing.expectEqualStrings("/work", root.get("workspace_root").?.string);
    try std.testing.expectEqualStrings("session", root.get("origin").?.string);
    const tool = root.get("tool").?.object;
    try std.testing.expectEqualStrings("shell", tool.get("name").?.string);
    try std.testing.expectEqualStrings("call_1", tool.get("call_id").?.string);
    try std.testing.expectEqualStrings(
        "touch marker.txt",
        tool.get("arguments").?.object.get("request").?.object.get("command").?.string,
    );
    const prompt = root.get("prompt").?.object;
    try std.testing.expectEqualStrings("Run touch marker.txt", prompt.get("label").?.string);
    try std.testing.expectEqualStrings("touch marker.txt", prompt.get("command").?.string);
    try std.testing.expect(prompt.get("file").? == .null);
    try std.testing.expectEqual(@as(usize, 2), root.get("choices").?.array.items.len);
}

test "encodeRequest refuses arguments that are not JSON" {
    const command = [_][]const u8{"approve"};
    const config: Config = .{ .command = &command };
    try std.testing.expectError(error.InvalidToolArguments, encodeRequest(
        std.testing.allocator,
        .{ .config = &config, .workspace_root = "/work" },
        .{ .label = "shell" },
        .{ .id = "call_1", .name = "shell", .arguments_json = "{not json" },
    ));
}

const TestHook = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    script_path: []u8,
    argv: [2][]const u8,
    config: Config,

    fn init(alloc: Allocator, script: []const u8, timeout_ms: u32) !TestHook {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "hook.sh", .data = script });
        const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        errdefer alloc.free(root);
        const script_path = try std.fs.path.join(alloc, &.{ root, "hook.sh" });
        return .{
            .tmp = tmp,
            .root = root,
            .script_path = script_path,
            .argv = .{ "/bin/sh", script_path },
            .config = .{ .command = &.{}, .timeout_ms = timeout_ms },
        };
    }

    fn bind(self: *TestHook) void {
        self.config.command = &self.argv;
    }

    fn deinit(self: *TestHook, alloc: Allocator) void {
        alloc.free(self.script_path);
        alloc.free(self.root);
        self.tmp.cleanup();
    }

    fn runWith(self: *TestHook, alloc: Allocator, input: []const u8, cancel: *const std.atomic.Value(bool)) !Verdict {
        self.bind();
        return run(alloc, &self.config, input, cancel);
    }
};

fn runTestHook(script: []const u8, timeout_ms: u32, input: []const u8) !Verdict {
    const alloc = std.testing.allocator;
    var hook = try TestHook.init(alloc, script, timeout_ms);
    defer hook.deinit(alloc);
    var cancel: std.atomic.Value(bool) = .init(false);
    return hook.runWith(alloc, input, &cancel);
}

test "run passes the document on stdin and reads an allow" {
    var verdict = try runTestHook(
        \\input=$(cat)
        \\case "$input" in
        \\  *'"request_id":7'*) printf '{"decision":"allow"}\n' ;;
        \\  *) printf '{"decision":"deny","reason":"missing input"}\n' ;;
        \\esac
    , 10_000, "{\"request_id\":7}");
    defer verdict.deinit(std.testing.allocator);
    try std.testing.expectEqual(Verdict.allow, verdict);
}

test "run reads a deny with its reason" {
    var verdict = try runTestHook(
        \\cat >/dev/null
        \\printf '{"decision":"deny","reason":"Denied from phone"}'
    , 10_000, "{}");
    defer verdict.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Denied from phone", verdict.deny);
}

test "run ignores an answer from a command that exits non-zero" {
    var verdict = try runTestHook(
        \\printf '{"decision":"allow"}'
        \\exit 3
    , 10_000, "{}");
    defer verdict.deinit(std.testing.allocator);
    try std.testing.expectEqual(Verdict.no_opinion, verdict);
}

test "run starts the command outside the workspace" {
    var verdict = try runTestHook(
        \\cat >/dev/null
        \\if [ "$(pwd -P)" = / ]; then
        \\  printf '{"decision":"allow"}'
        \\else
        \\  printf '{"decision":"deny","reason":"started in %s"}' "$(pwd -P)"
        \\fi
    , 10_000, "{}");
    defer verdict.deinit(std.testing.allocator);
    try std.testing.expectEqual(Verdict.allow, verdict);
}

test "run treats a missing command as no opinion" {
    const alloc = std.testing.allocator;
    const argv = [_][]const u8{"/nonexistent/fx-permission-hook"};
    const config: Config = .{ .command = &argv, .timeout_ms = 1_000 };
    var cancel: std.atomic.Value(bool) = .init(false);
    var verdict = try run(alloc, &config, "{}", &cancel);
    defer verdict.deinit(alloc);
    try std.testing.expectEqual(Verdict.no_opinion, verdict);
}

test "run stops a command that outlives its timeout" {
    const started = io_mod.milliTimestamp();
    var verdict = try runTestHook(
        \\sleep 30
        \\printf '{"decision":"allow"}'
    , min_timeout_ms, "{}");
    defer verdict.deinit(std.testing.allocator);
    try std.testing.expectEqual(Verdict.no_opinion, verdict);
    try std.testing.expect(io_mod.milliTimestamp() - started < 10_000);
}

const ProcessProbe = struct {
    tmp: std.testing.TmpDir,
    root: []u8,

    fn init(alloc: Allocator) !ProcessProbe {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".") };
    }

    fn deinit(self: *ProcessProbe, alloc: Allocator) void {
        alloc.free(self.root);
        self.tmp.cleanup();
    }

    fn pid(self: *ProcessProbe, name: []const u8) !std.posix.pid_t {
        var buffer: [32]u8 = undefined;
        const bytes = try self.tmp.dir.readFile(io_mod.getIo(), name, &buffer);
        return std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, bytes, " \n"), 10);
    }
};

fn expectReaped(pid: std.posix.pid_t) !void {
    std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
        error.ProcessNotFound => return,
        else => return err,
    };
    return error.TestProcessNotReaped;
}

fn expectProcessExited(pid: std.posix.pid_t) !void {
    for (0..200) |_| {
        std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => {},
        };
        if (testProcessIsZombie(pid)) return;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    return error.TestProcessStillRunning;
}

fn testProcessIsZombie(pid: std.posix.pid_t) bool {
    if (comptime builtin.os.tag != .linux) return false;
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/stat", .{pid}) catch return false;
    var stat_buffer: [512]u8 = undefined;
    const stat = std.Io.Dir.cwd().readFile(io_mod.getIo(), path, &stat_buffer) catch return false;
    const name_end = std.mem.findScalarLast(u8, stat, ')') orelse return false;
    return stat.len > name_end + 2 and stat[name_end + 2] == 'Z';
}

test "run kills and reaps a command that closes stdout and keeps running" {
    const alloc = std.testing.allocator;
    var probe = try ProcessProbe.init(alloc);
    defer probe.deinit(alloc);
    const script = try std.fmt.allocPrint(alloc,
        \\echo $$ > '{0s}/leader'
        \\sleep 30 >/dev/null &
        \\echo $! > '{0s}/descendant'
        \\printf '{{"decision":"allow"}}'
        \\exec >&-
        \\wait
    , .{probe.root});
    defer alloc.free(script);

    const started = io_mod.milliTimestamp();
    var verdict = try runTestHook(script, min_timeout_ms, "{}");
    defer verdict.deinit(alloc);
    try std.testing.expectEqual(Verdict.no_opinion, verdict);
    try std.testing.expect(io_mod.milliTimestamp() - started < 10_000);
    try expectReaped(try probe.pid("leader"));
    try expectProcessExited(try probe.pid("descendant"));
}

test "run returns when a reader outside the process group holds stdin" {
    const alloc = std.testing.allocator;
    var probe = try ProcessProbe.init(alloc);
    defer probe.deinit(alloc);
    std.Io.Dir.cwd().access(io_mod.getIo(), "/usr/bin/perl", .{}) catch return error.SkipZigTest;
    const script = try std.fmt.allocPrint(alloc,
        \\/usr/bin/perl -MPOSIX -e 'setsid(); open(my $f, ">", $ARGV[0]); close($f); sleep 8; 1 while <STDIN>' '{0s}/ready' <&0 >/dev/null 2>&1 &
        \\echo $! > '{0s}/escaped'
        \\i=0
        \\while [ ! -e '{0s}/ready' ] && [ "$i" -lt 500 ]; do sleep 0.01; i=$((i + 1)); done
        \\exit 0
    , .{probe.root});
    defer alloc.free(script);
    const input = try alloc.alloc(u8, 512 * 1024);
    defer alloc.free(input);
    @memset(input, ' ');

    const started = io_mod.milliTimestamp();
    var verdict = try runTestHook(script, 10_000, input);
    defer verdict.deinit(alloc);
    const elapsed = io_mod.milliTimestamp() - started;
    _ = try probe.pid("escaped");
    try probe.tmp.dir.access(io_mod.getIo(), "ready", .{});
    try std.testing.expectEqual(Verdict.no_opinion, verdict);
    try std.testing.expect(elapsed < 6_000);
}

test "run stops a command that never reads a large stdin" {
    const alloc = std.testing.allocator;
    const input = try alloc.alloc(u8, 512 * 1024);
    defer alloc.free(input);
    @memset(input, ' ');
    const started = io_mod.milliTimestamp();
    var verdict = try runTestHook("sleep 30\n", min_timeout_ms, input);
    defer verdict.deinit(alloc);
    try std.testing.expectEqual(Verdict.no_opinion, verdict);
    try std.testing.expect(io_mod.milliTimestamp() - started < 10_000);
}

test "run refuses oversized output" {
    var verdict = try runTestHook(
        \\cat >/dev/null
        \\printf '{"decision":"allow"}'
        \\head -c 70000 /dev/zero | tr '\0' ' '
    , 10_000, "{}");
    defer verdict.deinit(std.testing.allocator);
    try std.testing.expectEqual(Verdict.no_opinion, verdict);
}

test "run stops promptly when cancelled" {
    const alloc = std.testing.allocator;
    var hook = try TestHook.init(alloc, "sleep 30\n", max_timeout_ms);
    defer hook.deinit(alloc);
    var cancel: std.atomic.Value(bool) = .init(true);
    const started = io_mod.milliTimestamp();
    var verdict = try hook.runWith(alloc, "{}", &cancel);
    defer verdict.deinit(alloc);
    try std.testing.expectEqual(Verdict.no_opinion, verdict);
    try std.testing.expect(io_mod.milliTimestamp() - started < 10_000);
}

const RecordingAnswer = struct {
    mutex: std.Io.Mutex = .init,
    submitted: std.atomic.Value(u32) = .init(0),
    decision: ?types.ToolPermissionDecision = null,
    feedback: ?[]u8 = null,

    fn answer(self: *RecordingAnswer, request_id: u64) permission_prompter.Answer {
        return .{ .context = @ptrCast(self), .request_id = request_id, .submit_fn = submit };
    }

    fn submit(raw: *anyopaque, _: u64, response: permission_request.OwnedPermissionResponse) bool {
        const self: *RecordingAnswer = @ptrCast(@alignCast(raw));
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        var owned = response;
        self.decision = owned.decision;
        if (owned.feedback) |feedback| self.feedback = std.testing.allocator.dupe(u8, feedback) catch null;
        owned.deinit();
        _ = self.submitted.fetchAdd(1, .release);
        return true;
    }

    fn deinit(self: *RecordingAnswer) void {
        if (self.feedback) |feedback| std.testing.allocator.free(feedback);
    }

    fn waitForSubmission(self: *RecordingAnswer) !void {
        const deadline = io_mod.milliTimestamp() + 10_000;
        while (self.submitted.load(.acquire) == 0) {
            if (io_mod.milliTimestamp() > deadline) return error.TestTimedOut;
            io_mod.sleep(10 * std.time.ns_per_ms);
        }
    }
};

const RaceEnd = union(enum) {
    submission,
    hook_exit,
    leader_started: *ProcessProbe,
};

fn raceWithScript(script: []const u8, answer: *RecordingAnswer, end: RaceEnd) !void {
    const alloc = std.testing.allocator;
    var hook = try TestHook.init(alloc, script, 10_000);
    defer hook.deinit(alloc);
    hook.bind();
    var race = Race.init(
        .{ .config = &hook.config, .workspace_root = hook.root },
        .{ .id = "call_1", .name = "shell", .arguments_json = "{}" },
    );
    defer race.finish();
    const responder = race.responder();
    responder.open_fn(responder.context, .{ .id = 3, .label = "Run touch marker.txt" }, answer.answer(3));
    switch (end) {
        .submission => try answer.waitForSubmission(),
        .hook_exit => {
            race.thread.?.join();
            race.thread = null;
        },
        .leader_started => |probe| try waitForProbeFile(probe, "leader"),
    }
}

fn waitForProbeFile(probe: *ProcessProbe, name: []const u8) !void {
    const deadline = io_mod.milliTimestamp() + 10_000;
    while (true) {
        if (probe.pid(name)) |_| return else |_| {}
        if (io_mod.milliTimestamp() > deadline) return error.TestTimedOut;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
}

test "race submits a hook allow as a single approval" {
    var answer: RecordingAnswer = .{};
    defer answer.deinit();
    try raceWithScript("cat >/dev/null\nprintf '{\"decision\":\"allow\"}'\n", &answer, .submission);
    try std.testing.expectEqual(@as(u32, 1), answer.submitted.load(.acquire));
    try std.testing.expectEqual(types.ToolPermissionDecision.once, answer.decision.?);
    try std.testing.expect(answer.feedback == null);
}

test "race submits a hook deny with its reason as feedback" {
    var answer: RecordingAnswer = .{};
    defer answer.deinit();
    try raceWithScript("cat >/dev/null\nprintf '{\"decision\":\"deny\",\"reason\":\"not now\"}'\n", &answer, .submission);
    try std.testing.expectEqual(types.ToolPermissionDecision.deny, answer.decision.?);
    try std.testing.expectEqualStrings("not now", answer.feedback.?);
}

test "race submits nothing without an opinion" {
    var answer: RecordingAnswer = .{};
    defer answer.deinit();
    try raceWithScript("cat >/dev/null\nprintf '{\"decision\":\"none\"}'\nexit 0\n", &answer, .hook_exit);
    try std.testing.expectEqual(@as(u32, 0), answer.submitted.load(.acquire));
}

test "race finish kills a slow hook without submitting" {
    const alloc = std.testing.allocator;
    var probe = try ProcessProbe.init(alloc);
    defer probe.deinit(alloc);
    const script = try std.fmt.allocPrint(alloc,
        \\echo $$ > '{0s}/leader'
        \\exec >&-
        \\sleep 30
    , .{probe.root});
    defer alloc.free(script);

    var answer: RecordingAnswer = .{};
    defer answer.deinit();
    const started = io_mod.milliTimestamp();
    try raceWithScript(script, &answer, .{ .leader_started = &probe });
    try std.testing.expect(io_mod.milliTimestamp() - started < 10_000);
    try std.testing.expectEqual(@as(u32, 0), answer.submitted.load(.acquire));
    try expectReaped(try probe.pid("leader"));
}

test "race ignores confirmation-only prompts" {
    var answer: RecordingAnswer = .{};
    defer answer.deinit();
    const command = [_][]const u8{"/bin/false"};
    const config: Config = .{ .command = &command };
    var race = Race.init(
        .{ .config = &config, .workspace_root = "/" },
        .{ .id = "call_1", .name = "shell", .arguments_json = "{}" },
    );
    defer race.finish();
    const responder = race.responder();
    responder.open_fn(responder.context, .{ .id = 4, .label = "Remember allow", .confirmation_only = true }, answer.answer(4));
    try std.testing.expect(race.thread == null);
}
