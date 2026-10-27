//! The built-in `anthropic` provider (D165). Proto sends provider `anthropic`
//! through the Claude Agent SDK; proto-fx does the same through the installed
//! `claude` executable in stream-json mode, or, with an Anthropic API key,
//! through the Messages transport against api.anthropic.com.
//!
//! The key decides the mode (D166): a saved or `CLAUDE_CODE_OAUTH_TOKEN`
//! subscription token (from `claude setup-token`) runs Claude Code, a saved or
//! `ANTHROPIC_API_KEY` API key runs Messages, and with neither Claude Code
//! runs on the user's own Claude Code login (D184).
//!
//! In Claude Code mode each model request is one `claude -p` run with one
//! turn, no built-in tools, no setting sources, an isolated config directory
//! seeded with the history as a resumable session, and proto-fx's tools served
//! by a stub MCP server that never runs them (D167). The run is stopped at the
//! first message_stop; proto-fx's own loop executes the calls.
const std = @import("std");
const builtin = @import("builtin");
const anthropic_messages = @import("anthropic_messages.zig");
const codec = @import("anthropic_messages_protocol.zig");
const reducer = @import("anthropic_messages_stream.zig");
const chat_completions = @import("chat_completions.zig");
const configured_request = @import("configured_request.zig");
const wire = @import("claude_agent_wire.zig");
const executable = @import("claude_executable.zig");
const tool_stub = @import("claude_tool_stub.zig");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const classifier = @import("../core/permissions/auto_classifier.zig");
const provider_keys = @import("../core/auth/provider_keys.zig");
const secret = @import("../core/auth/secret.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const Allocator = std.mem.Allocator;

pub const provider_id = "anthropic";
/// The cheap model for titles and permission reviews, as proto's smol role.
pub const small_model = "claude-haiku-5-5";
/// Prefix of Claude subscription tokens from `claude setup-token`.
pub const subscription_token_prefix = "sk-ant-oat";
const max_line_bytes = 4 * 1024 * 1024;
const forced_tool_instruction = "Respond only by calling one of the available tools, exactly once.";
const max_stderr_tail = 2048;

pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        .title_model = definition.reviewer_model orelse small_model,
        .agent_stream = .{ .context = context, .stream_fn = stream, .build_request_fn = build, .project_replay_fn = anthropic_messages.project_replay },
        .model_catalog = chat_completions.model_catalog_provider(definition),
        .cli_model_catalog = .{ .context = context, .fetch_fn = chat_completions.fetch_cli_catalog },
        .permission_reviewer = .{ .context = context, .review_fn = review },
    };
}

/// Whether `definition` is the built-in `anthropic` provider rather than a
/// user's own Messages endpoint that happens to share the id.
pub fn owns(definition: *const definitions.Definition) bool {
    return definition.preset and std.mem.eql(u8, definition.id, provider_id);
}

pub const Mode = union(enum) {
    /// An Anthropic API key for the Messages transport. Owned.
    api_key: []u8,
    /// Claude Code, with the subscription token to hand it, or null for the
    /// user's own Claude Code login (D184). Owned.
    claude_code: ?[]u8,

    pub fn deinit(self: *Mode, alloc: Allocator) void {
        switch (self.*) {
            .api_key => |key| secret.zeroAndFree(alloc, key),
            .claude_code => |token| if (token) |value| secret.zeroAndFree(alloc, value),
        }
        self.* = undefined;
    }
};

pub const ModeSources = struct {
    /// The key `/login` saved; ownership moves into the mode.
    saved: ?[]u8 = null,
    oauth_env: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,
};

pub fn isSubscriptionToken(key: []const u8) bool {
    return std.mem.startsWith(u8, key, subscription_token_prefix);
}

/// The saved key wins over the environment; its kind picks the mode (D166).
pub fn resolveMode(alloc: Allocator, sources: ModeSources) Allocator.Error!Mode {
    if (sources.saved) |key| return if (isSubscriptionToken(key)) .{ .claude_code = key } else .{ .api_key = key };
    if (sources.oauth_env) |token| if (token.len != 0) return .{ .claude_code = try alloc.dupe(u8, token) };
    if (sources.api_key_env) |key| if (key.len != 0) return .{ .api_key = try alloc.dupe(u8, key) };
    return .{ .claude_code = null };
}

/// The environment variable that takes precedence over the user's Claude
/// Code login, if one is set.
pub fn environmentOverride() ?[]const u8 {
    for ([_][]const u8{ "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY" }) |name| {
        if (io_mod.getenv(name)) |value| if (value.len != 0) return name;
    }
    return null;
}

fn currentMode(alloc: Allocator) !Mode {
    return resolveMode(alloc, .{
        .saved = try provider_keys.load(alloc, provider_id),
        .oauth_env = io_mod.getenv("CLAUDE_CODE_OAUTH_TOKEN"),
        .api_key_env = io_mod.getenv("ANTHROPIC_API_KEY"),
    });
}

fn definition_at(raw: ?*anyopaque) *const definitions.Definition {
    return @ptrCast(@alignCast(raw.?));
}

/// The Messages body, used for capacity measurement and API key requests.
pub fn build(raw: ?*anyopaque, alloc: Allocator, request: streams.RequestData) anyerror![]u8 {
    return anthropic_messages.build(raw, alloc, request);
}

pub fn stream(raw: ?*anyopaque, alloc: Allocator, request: streams.ModelRequest) anyerror!streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const definition = definition_at(raw);
    var mode = try currentMode(alloc);
    defer mode.deinit(alloc);
    switch (mode) {
        .api_key => |key| {
            const url = try definition.messages_url(alloc);
            defer alloc.free(url);
            var headers = try configured_request.resolveHeaders(alloc, definition);
            defer headers.deinit(alloc);
            const identity = anthropic_messages.bound_identity(definition);
            return anthropic_messages.stream_endpoint(alloc, .{
                .messages_url = url,
                .key_style = .x_api_key,
                .extra_headers = headers.items,
                .options = anthropic_messages.definition_options(definition, request.model, &identity),
            }, key, request);
        },
        .claude_code => |token| return streamClaudeCode(alloc, definition, token, request),
    }
}

pub fn review(raw: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) anyerror!classifier.ParseOutcome {
    return chat_completions.review_with(raw, alloc, input, request, .{ .build_fn = build, .stream_fn = stream });
}

fn failed(alloc: Allocator, kind: streams.FailureKind, detail: []const u8) !streams.Result {
    return .{ .failed = .{ .kind = kind, .detail = try alloc.dupe(u8, detail), .ownership = .owned } };
}

/// One request through `claude -p`. Every file it needs lives in a private
/// temporary directory that is removed before returning.
fn streamClaudeCode(alloc: Allocator, definition: *const definitions.Definition, token: ?[]const u8, request: streams.ModelRequest) !streams.Result {
    if (comptime builtin.target.os.tag == .windows or builtin.target.cpu.arch.isWasm()) return error.ClaudeCodeUnsupported;
    if (request.response_format != null) return error.UnsupportedResponseFormat;
    const exe = executable.find(alloc, .current()) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return failed(alloc, .invalid_request, executable.override_env ++ " does not name an executable file."),
    } orelse return failed(alloc, .invalid_request, "Claude Code is not installed. Install the claude CLI, set " ++ executable.override_env ++ ", or use an Anthropic API key in /login.");
    defer alloc.free(exe);

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = io_mod.getIo();

    // History projects exactly as on the Messages API. A body already built
    // for measurement or by the permission reviewer is the request itself;
    // its cache breakpoints are dropped because Claude Code places its own.
    const identity = anthropic_messages.bound_identity(definition);
    var options = anthropic_messages.definition_options(definition, request.model, &identity);
    options.cache = .off;
    const body = request.prepared_request_body orelse try codec.build_request(arena, request.data(), options);

    var session_seed: [16]u8 = undefined;
    const seed: []const u8 = request.session_id orelse blk: {
        io.random(&session_seed);
        break :blk &session_seed;
    };
    const session = wire.derivedUuid(seed, std.math.maxInt(usize));
    const workspace = io_mod.realpathAlloc(arena, ".") catch try arena.dupe(u8, "/");
    var scratch = try Scratch.create(arena);
    defer scratch.remove();
    // Claude names a project directory after the path; very long paths get a
    // hashed name, so those runs start in the short scratch directory.
    const cwd = if (projectDirName(arena, workspace)) |_| workspace else |_| scratch.path;
    const project = try projectDirName(arena, cwd);

    var prepared = try wire.prepare(arena, body, .{ .session = &session, .cwd = cwd, .model = request.model, .timestamp = try isoNow(arena) });
    defer prepared.deinit(arena);
    if (request.tool_choice == .required) {
        // Claude Code cannot force a tool choice (proto's limit too), so a
        // request that needs a call, such as a permission review, says so.
        prepared.system = try std.mem.concat(arena, u8, &.{ prepared.system, if (prepared.system.len != 0) "\n\n" else "", forced_tool_instruction });
    }
    try scratch.write(arena, "system.txt", prepared.system);
    try scratch.write(arena, "tools.json", prepared.tools_json);
    if (prepared.transcript.len != 0) {
        const relative = try std.Io.Dir.path.join(arena, &.{ "config", "projects", project });
        try scratch.dir.createDirPath(io, relative);
        try scratch.write(arena, try std.mem.concat(arena, u8, &.{ relative, "/", &session, ".jsonl" }), prepared.transcript);
    } else try scratch.dir.createDirPath(io, "config");

    const argv = try arguments(arena, .{
        .exe = exe,
        .self = try std.process.executablePathAlloc(io, arena),
        .scratch = scratch.path,
        .session = &session,
        .resume_session = prepared.transcript.len != 0,
        .tools = prepared.tool_count != 0,
        .model = request.model,
        .effort = effort(request.provider_options.reasoning),
    });
    var env = try childEnvironment(arena, definition, token, scratch.path, request);
    defer env.deinit();

    const stderr_path = try std.Io.Dir.path.join(arena, &.{ scratch.path, "stderr.log" });
    var stderr_file = try std.Io.Dir.cwd().createFile(io, stderr_path, .{ .permissions = .fromMode(0o600) });
    defer stderr_file.close(io);

    try request.admission.admit();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .{ .file = stderr_file },
        // Its own group, so stopping it stops the MCP stub it started too.
        .pgid = 0,
    }) catch |err| {
        const detail = try alloc.print("Could not start Claude Code at {s}: {s}", .{ exe, @errorName(err) });
        return .{ .failed = .{ .kind = .invalid_request, .detail = detail, .ownership = .owned } };
    };
    const pid = child.id.?;
    var watch: Watch = .{ .pid = pid, .cancel_flag = request.cancel_flag, .deadline = request.deadline };
    const thread = std.Thread.spawn(.{}, Watch.run, .{&watch}) catch |err| {
        std.posix.kill(-pid, .KILL) catch {};
        child.kill(io);
        return err;
    };
    defer {
        watch.done.store(true, .seq_cst);
        thread.join();
        std.posix.kill(-pid, .KILL) catch {};
        child.kill(io);
    }

    request.delivery.markPossiblySent();
    const stdin = child.stdin.?;
    child.stdin = null;
    // A closed stdin ends Claude's input after this one message.
    stdin.writeStreamingAll(io, prepared.prompt_line) catch {};
    stdin.close(io);

    var limits: reducer.Limits = .{};
    if (request.content_capture_limit) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    const line_buffer = try arena.alloc(u8, max_line_bytes);
    var lines = child.stdout.?.readerStreaming(io, line_buffer);
    const result = translate(alloc, &lines.interface, request.data(), limits, request.events, request.cancel_flag) catch |err| {
        if (watch.reason.load(.seq_cst) == 1) return error.Cancelled;
        if (watch.reason.load(.seq_cst) == 2) return error.Timeout;
        return err;
    };
    if (result) |value| return value;
    if (watch.reason.load(.seq_cst) == 1) return error.Cancelled;
    if (watch.reason.load(.seq_cst) == 2) return error.Timeout;
    const tail = try stderrTail(arena, stderr_path);
    const detail = try alloc.print("Claude Code ended before the response finished{s}{s}", .{ if (tail.len != 0) ": " else ".", tail });
    return .{ .failed = .{ .kind = .provider_error, .detail = detail, .ownership = .owned } };
}

/// Reads stream-json until the response's message_stop, a reported
/// failure, or the end of output (null). The SSE events go through the
/// Messages reducer, so text, thinking, tool input and usage come out as on
/// the API.
pub fn translate(alloc: Allocator, lines: *std.Io.Reader, data: streams.RequestData, limits: reducer.Limits, sink: streams.EventSink, cancel_flag: *const std.atomic.Value(bool)) !?streams.Result {
    var state = try reducer.Reducer.init(alloc, data, limits);
    defer state.deinit();
    while (true) {
        const raw = lines.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.EventTooLarge,
            else => return null,
        } orelse return null;
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        switch (try wire.unwrap(alloc, raw)) {
            .ignore => {},
            .result => return null,
            .failure => |value| return .{ .failed = .{ .kind = value.kind, .detail = value.detail, .ownership = .owned } },
            .event => |event| {
                defer alloc.free(event);
                const deltas = try state.accept(event, cancel_flag.load(.seq_cst));
                if (deltas.reasoning) |text| sink.emit(.{ .reasoning_delta = text });
                if (deltas.content) |text| sink.emit(.{ .content_delta = text });
                state.emit_tool_progress(sink);
                if (state.phase == .done or state.phase == .failed) return try state.finish(cancel_flag.load(.seq_cst));
            },
        }
    }
}

/// Stops the run on cancellation or at the deadline. `reason` is 1 for a
/// cancel and 2 for the deadline.
const Watch = struct {
    pid: std.posix.pid_t,
    cancel_flag: *std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
    done: std.atomic.Value(bool) = .init(false),
    reason: std.atomic.Value(u8) = .init(0),

    fn run(self: *Watch) void {
        const io = io_mod.getIo();
        while (!self.done.load(.seq_cst)) {
            var why: u8 = 0;
            if (self.cancel_flag.load(.seq_cst)) why = 1;
            if (self.deadline) |deadline| {
                if (!std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io, .awake), .lt, deadline)) why = 2;
            }
            if (why != 0) {
                self.reason.store(why, .seq_cst);
                std.posix.kill(-self.pid, .KILL) catch {};
                return;
            }
            io.sleep(.fromMilliseconds(20), .awake) catch return;
        }
    }
};

pub const ArgumentOptions = struct {
    exe: []const u8,
    /// proto-fx itself, which serves the tool stub.
    self: []const u8,
    scratch: []const u8,
    session: []const u8,
    resume_session: bool,
    tools: bool,
    model: []const u8,
    effort: ?[]const u8,
};

/// The `claude` command line: one turn, stream-json both ways, partial
/// messages, no built-in tools, no settings files, only proto-fx's MCP
/// server, nobody to approve a tool, and proto-fx's system prompt read fresh
/// on every request.
pub fn arguments(arena: Allocator, options: ArgumentOptions) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        options.exe,                "-p",
        "--input-format",           "stream-json",
        "--output-format",          "stream-json",
        "--verbose",                "--include-partial-messages",
        "--max-turns",              "1",
        "--tools",                  "",
        "--setting-sources",        "",
        "--strict-mcp-config",      "--permission-prompts",
        "none",                     "--disable-slash-commands",
        "--system-prompt-file",     try std.Io.Dir.path.join(arena, &.{ options.scratch, "system.txt" }),
        "--system-prompt-snapshot", "off",
        "--settings",               "{\"autoMemoryEnabled\":false}",
        "--model",                  options.model,
    });
    if (options.tools) {
        const tools_path = try std.Io.Dir.path.join(arena, &.{ options.scratch, "tools.json" });
        var config: std.Io.Writer.Allocating = .init(arena);
        try config.writer.writeAll("{\"mcpServers\":{\"" ++ wire.server_name ++ "\":{\"type\":\"stdio\",\"command\":");
        try std.json.Stringify.value(options.self, .{}, &config.writer);
        try config.writer.writeAll(",\"args\":[\"" ++ tool_stub.argv_marker ++ "\",");
        try std.json.Stringify.value(tools_path, .{}, &config.writer);
        try config.writer.writeAll("]}}}");
        try argv.appendSlice(arena, &.{ "--mcp-config", config.written() });
    }
    try argv.appendSlice(arena, &.{ if (options.resume_session) "--resume" else "--session-id", options.session });
    if (options.effort) |value| try argv.appendSlice(arena, &.{ "--effort", value });
    return argv.items;
}

/// Claude's `--effort` for a reasoning effort; `minimal` rounds up to `low`.
pub fn effort(reasoning: ?types.ReasoningEffort) ?[]const u8 {
    var value = reasoning orelse return null;
    const label = value.label();
    if (std.mem.eql(u8, label, "minimal")) return "low";
    for ([_][]const u8{ "low", "medium", "high", "xhigh", "max" }) |name| if (std.mem.eql(u8, name, label)) return name;
    return null;
}

/// The child's environment: the user's, minus variables that would nest
/// it under another Claude Code or another cloud, plus the isolated config
/// directory, proto's quieting switches and the credential.
fn childEnvironment(arena: Allocator, definition: *const definitions.Definition, token: ?[]const u8, scratch: []const u8, request: streams.ModelRequest) !std.process.Environ.Map {
    var env = try io_mod.cloneEnvironMap(arena);
    errdefer env.deinit();
    try isolateEnvironment(arena, &env, try std.Io.Dir.path.join(arena, &.{ scratch, "config" }), token);
    // A models.json base URL other than Anthropic's own goes to Claude as is;
    // otherwise the user's ANTHROPIC_BASE_URL, if any, passes through.
    if (!std.mem.startsWith(u8, definition.base_url, "https://api.anthropic.com")) {
        const base = if (std.mem.endsWith(u8, definition.base_url, "/v1")) definition.base_url[0 .. definition.base_url.len - 3] else definition.base_url;
        try env.put("ANTHROPIC_BASE_URL", base);
    }
    if (definition.headers.len != 0) {
        const headers = try configured_request.resolveHeaders(arena, definition);
        var joined: std.ArrayList(u8) = .empty;
        for (headers.items) |header| {
            if (joined.items.len != 0) try joined.append(arena, '\n');
            try joined.print(arena, "{s}: {s}", .{ header.name, header.value });
        }
        try env.put("ANTHROPIC_CUSTOM_HEADERS", joined.items);
    }
    if (request.max_output_tokens) |limit| try env.put("CLAUDE_CODE_MAX_OUTPUT_TOKENS", try arena.print("{d}", .{limit}));
    if (request.provider_options.reasoning == null) try env.put("MAX_THINKING_TOKENS", "0");
    return env;
}

/// Claude Code's variable naming the config directory its sign-in belongs
/// to: its keychain entry and `.credentials.json` are found by that
/// directory, apart from `CLAUDE_CONFIG_DIR`. Empty means the default
/// `~/.claude`.
pub const secure_storage_env = "CLAUDE_SECURESTORAGE_CONFIG_DIR";

/// Points `env` at the private `config_dir` for everything Claude writes
/// (transcripts, `.claude.json`, plugin state) and adds proto's quieting
/// switches. With a token Claude uses that; without one it keeps the user's
/// own login, read from the keychain entry or credentials file of the config
/// directory the user runs Claude Code with (D184). Refreshing an expired
/// login writes the new one back there, as any Claude Code run does; nothing
/// else is written outside `config_dir`.
pub fn isolateEnvironment(arena: Allocator, env: *std.process.Environ.Map, config_dir: []const u8, token: ?[]const u8) !void {
    for ([_][]const u8{ "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_SIMPLE" }) |key| _ = env.swapRemove(key);
    if (token) |value| {
        _ = env.swapRemove("ANTHROPIC_API_KEY");
        _ = env.swapRemove("ANTHROPIC_AUTH_TOKEN");
        try env.put("CLAUDE_CODE_OAUTH_TOKEN", value);
    } else {
        // An empty variable would read as a credential and hide the login.
        for ([_][]const u8{ "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN" }) |key| {
            if (env.get(key)) |value| if (value.len == 0) {
                _ = env.swapRemove(key);
            };
        }
        if (env.get(secure_storage_env) == null) {
            const user_dir = try arena.dupe(u8, env.get("CLAUDE_CONFIG_DIR") orelse "");
            try env.put(secure_storage_env, user_dir);
        }
    }
    try env.put("CLAUDE_CONFIG_DIR", config_dir);
    try env.put("CLAUDE_AGENT_SDK_CLIENT_APP", "proto-fx");
    try env.put("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1");
    try env.put("CLAUDE_CODE_TOTAL_TOKENS_REMINDER", "off");
    try env.put("DISABLE_AUTO_COMPACT", "1");
    try env.put("ENABLE_TOOL_SEARCH", "false");
    try env.put("CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING", "1");
}

/// Claude's project directory name for `path`, or an error when the path is
/// long enough that Claude would hash it.
pub fn projectDirName(arena: Allocator, path: []const u8) ![]u8 {
    if (path.len > 200) return error.PathTooLong;
    const out = try arena.dupe(u8, path);
    for (out) |*byte| if (!std.ascii.isAlphanumeric(byte.*)) {
        byte.* = '-';
    };
    return out;
}

fn isoNow(arena: Allocator) ![]u8 {
    const now_ms = io_mod.milliTimestamp();
    const seconds: u64 = @intCast(@max(@divFloor(now_ms, 1000), 0));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return arena.print("{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,                          month_day.month.numeric(), month_day.day_index + 1,
        day.getHoursIntoDay(),                  day.getMinutesIntoHour(),  day.getSecondsIntoMinute(),
        @as(u64, @intCast(@mod(now_ms, 1000))),
    });
}

fn stderrTail(arena: Allocator, path: []const u8) ![]const u8 {
    var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{}) catch return "";
    defer file.close(io_mod.getIo());
    const bytes = io_mod.readFileToEnd(arena, &file, 1024 * 1024) catch return "";
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    return trimmed[trimmed.len - @min(trimmed.len, max_stderr_tail) ..];
}

/// A private directory under the system temporary directory, removed with
/// everything Claude wrote into it.
pub const Scratch = struct {
    path: []const u8,
    dir: std.Io.Dir,

    pub fn create(arena: Allocator) !Scratch {
        const io = io_mod.getIo();
        const base = std.mem.trimEnd(u8, io_mod.getenv("TMPDIR") orelse "/tmp", "/");
        var attempts: u8 = 0;
        while (true) : (attempts += 1) {
            var random: [8]u8 = undefined;
            io.random(&random);
            const path = try arena.print("{s}/proto-fx-claude-{s}", .{ base, std.fmt.bytesToHex(random, .lower) });
            std.Io.Dir.cwd().createDir(io, path, .fromMode(0o700)) catch |err| switch (err) {
                error.PathAlreadyExists => if (attempts < 8) continue else return err,
                else => return err,
            };
            const real = io_mod.realpathAlloc(arena, path) catch path;
            return .{ .path = real, .dir = try std.Io.Dir.openDirAbsolute(io, real, .{}) };
        }
    }

    fn write(self: *Scratch, arena: Allocator, name: []const u8, data: []const u8) !void {
        _ = arena;
        try self.dir.writeFile(io_mod.getIo(), .{ .sub_path = name, .data = data, .flags = .{ .permissions = .fromMode(0o600) } });
    }

    pub fn remove(self: *Scratch) void {
        const io = io_mod.getIo();
        self.dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, self.path) catch |err| debug_trace.logf("gateway", "claude_scratch_remove_failed err={s}", .{@errorName(err)});
    }
};

test {
    _ = @import("claude_executable.zig");
    _ = @import("claude_agent_wire.zig");
    _ = @import("claude_tool_stub.zig");
    _ = @import("claude_login.zig");
}
