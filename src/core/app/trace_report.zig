//! The `/trace` report: a private diagnostic snapshot of one fx session,
//! written as JSON Lines so that a program can read it.
//!
//! ## Format
//!
//! A trace is UTF-8 text with one JSON object per line, each line ending in
//! `\n`. Every object is a record, and its first key is `type`. The first
//! record is the `fx_trace` header and the last is `end`; a file without an
//! `end` record was cut off while it was written. Records come in the order
//! below. A section with a list writes one summary record and then one record
//! per item.
//!
//! Conventions for every record:
//!
//! - A time is two fields: `<name>` is ISO 8601 UTC with milliseconds, such as
//!   `2026-11-11T19:14:21.123Z`, and `<name>_ms` is Unix time in
//!   milliseconds. Both are left out when the time is unknown.
//! - A field with no value is left out; no field is `null`.
//! - Counts, sizes, and durations are integers; durations end in `_ms`.
//! - `source` is `parent` for the main agent, or `subagent` with a
//!   `subagent_id`.
//! - Text that may hold user, model, tool, or terminal content is marked
//!   "masked": obvious secrets in it are replaced with `[redacted]`. A byte that
//!   is not valid UTF-8 in any string is written as the text `\xNN`.
//! - Internal search tool names are written as `web_search`.
//!
//! A reader skips record types and fields it does not know. Adding a type or a
//! field keeps `format_version`; removing or renaming one, or changing what a
//! field means, raises it.
//!
//! ## Records
//!
//! - `fx_trace`: `format_version` (1), `fx_version`, `git_commit`,
//!   `written_at`, and `notice`, the privacy warning.
//! - `summary`: `os`, `arch`, `build` (`Debug`, `ReleaseSafe`, `ReleaseFast`,
//!   or `ReleaseSmall`), `model`, `fast_mode`, `permission_mode`, `workspace`.
//! - `current_state`: `session_id`, `session_dir`, `agent_step_limit`,
//!   `effort`, `input_tokens`, `output_tokens`, `web_search_requests`; `auth`
//!   {`source`, `refreshable`, `gateway_team`}; `process` {`pid`, `open_fds`,
//!   and `memory` {`pid`, `ppid`, `rss_kib`, `vsz_kib`, `elapsed`, `stat`}, or
//!   `memory_lines` with the `ps` output when it has another shape}; `worker`
//!   {`processing`, `queued`, `cancel_requested`, `pending_permission`
//!   (masked)}; `pending_questions` {`count`, `questions`: the first 3 as
//!   {`question` (masked), `options`, a count}}; `pending_images` {`count`,
//!   `images`: the first 3 as {`media_type`, `path` (masked)}};
//!   `project_context` {`enabled`, `loaded`, `bytes`}; `fx_trace`, whether
//!   `FX_TRACE` is on; `trace_log` (masked), the debug log path; `stream`
//!   {`active`, `chunks`, `reads`, `lists`, `writes`, `edits`, `commands`,
//!   `subagents`, `last_activity`}; `terminal` {`cols`, `rows`}; `metrics`
//!   {`ansi_bytes`, `full_redraws`, `debounced_resizes`, `footer_updates`,
//!   `stream_chunks`}.
//! - `problems`: `count`, then that many `problem` records, each with a `kind`:
//!   `active_turn` {`processing`, `stream_active`, `queued`}: the trace was
//!   taken during a turn, so it may be partial; `interrupted_turn`
//!   {`in_flight_tool`, `completed_tools`, a count}; `session_title`
//!   {`status`, `reason`, `detail`}; `network_call`, for the newest 3 failed
//!   calls, with `call` holding the `network_call` fields; `tool_call`, for
//!   the newest 5 calls that did not succeed, with `call` {`at`, `name`,
//!   `outcome`, `duration_ms`, `source`}; `compaction` {`event`, `turn_id`, `detail`}, for the newest 3
//!   failures; `mcp_server` {`issue` (`failed`, `retrying`, `missing_env`,
//!   `invalid_env`, or `needs_login`), `name`, `variable`, `error` (masked)};
//!   `model_catalog` {`event`, `detail`}, for the newest 3 failures.
//! - `last_shutdown`: `status` (`recorded`, `none`, or `unreadable`),
//!   `total_ms`, `recorded_at`, and `stages`, a list of {`name`, `step_ms`}.
//! - `compaction`: `retained`, `failed`, `overwritten_before`, the events the
//!   bounded ring dropped; then a `compaction_event` per retained event:
//!   `at`, `sequence`, `event`, `turn_id`, `step_id`, `subagent_id`, `failed`,
//!   `detail`, and `truncated`, whether the detail was cut when recorded.
//!   These are recorded even when `FX_TRACE` is off, and hold internal
//!   counters and names only, so they are not masked.
//! - `interrupted_turn`, only when the last turn was interrupted by the user:
//!   `in_flight_tool`, `in_flight_args` (masked, the first 1200 bytes),
//!   `in_flight_args_bytes`, and `completed_tools`, a list of names.
//! - `session_title`: `setting`, `title` (masked; left out when there is
//!   none), and `generation` {`status`, `session`, `model`, `reason`,
//!   `detail`, `elapsed_ms`}.
//! - `network`: `retained`, `ok`, `errors`, `avg_ms`, `min_ms`, `max_ms`;
//!   `session` {`calls`, `ok`, `errors`, `total_ms`}, totals that the bounded
//!   ring does not limit; `complete`, whether the ring holds every call, and
//!   when it does not, `oldest_retained_at`; `turns_retained`,
//!   `turns_evicted`. Then a `network_turn` per retained turn: `turn_id`,
//!   `calls`, `errors`, `subagent_calls`, `total_ms`, `first_started_at`.
//!   Then a `network_call` per retained call, oldest first: `at`, `model`,
//!   `kind`, `source`, `error`, `status`, `duration_ms`, `response_bytes`,
//!   `input_tokens`, `output_tokens`, `web_search_requests` (web search calls
//!   only), `stop_reason`, `provider_stop_reason`, `turn_id`, `step_id`, and
//!   the masked `gateway_error`, `gateway_schema`, and `request_shape`.
//! - `model_catalog`: `cache` {`state`, `entries`, `last_attempt_age_ms`, and
//!   after a failure `failure`, `retryable`, `http_status`,
//!   `anonymous_fallback`}; `selected_model` {`model`, `image_input`,
//!   `vision`, `file_input`, `tool_use`, `context_window`}; `events`. Then a
//!   `model_catalog_event` per event: `at`, `sequence`, `event`, `failed`,
//!   `detail`, `truncated`. Catalog events are recorded even when `FX_TRACE`
//!   is off.
//! - `tool_calls`: `retained`, `outcomes` {`succeeded`, `rejected`,
//!   `command_failed`, `tool_failed`, `runtime_failed`}, `total_ms`, `session`
//!   {`calls`, `outcomes`, `total_ms`}, `complete`, and `web_search_retained`.
//!   Then a `tool_call` per retained local call, oldest first: `at`, `name`,
//!   `outcome`, `duration_ms`, `source`, `args` (masked), `args_bytes`,
//!   `args_omitted_bytes`; a call that succeeded has `result_preview` (masked,
//!   its first useful line, at most 180 bytes) and `result_bytes`, and any
//!   other call has `result` (masked), `result_bytes`, and
//!   `result_omitted_bytes`. A `web_fetch` call has no arguments or result.
//!   Then a `web_search_call` per provider-run search: `status` (`ok`, `err`,
//!   or `pending`).
//! - `permissions`: `grants`; then a `permission_grant` per grant: `tool`,
//!   `target`.
//! - `runtime_context`: `term`, `term_program`, `lang` (each left out when
//!   unset), `tmux`, `cmux`, `mcp_servers`; then an `mcp_server` per server:
//!   `name`, `state`, `transport`, `tools`, `signed_in`, `needs_login`,
//!   `error` (masked).
//! - `renderer_state`: `layout`, `cursor`, `transcript`, `projection`,
//!   `replaceable`, and `shadow_grid` with `visible_rows`, a list of {`row`,
//!   `text` (masked)}; `shadow_grid` is left out when fx has none.
//! - `renderer_events`: `retained`, `capacity`, `overwritten_before`; then a
//!   `renderer_event` per event: `at`, `sequence`, `kind`, `detail` (masked),
//!   `truncated`. These are internal rendering decisions, not what the
//!   terminal showed.
//! - `transcript`: `entries` in the transcript and `emitted`; then a
//!   `transcript_entry` per entry that has text: `at`, `kind` (`raw`, `user`,
//!   `assistant`, `assistant_table`, `assistant_code_block`,
//!   `assistant_thematic_rule`, or `semantic_notice`), and `text` (masked),
//!   with ANSI escapes, blank lines, and banner lines removed.
//! - `trace_log`, only when a debug trace log is set and not empty: `path`
//!   (masked), `bytes` read from its end (at most 6 KiB), `older_lines_cut`,
//!   `lines`; then a `trace_log_line` per line, at most 80: `text` (masked).
//! - `end`: `records`, the number of records before it.
//!
//! ## Adding a record type
//!
//! Pick a snake_case `type`, add it to the list above, and write it in
//! `build` with `begin`, the field helpers of `Records`, and `end`. A summary
//! record whose counts are known only after its items are written collects
//! them in a `Buffer` first, as `writeProblems` does.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const agents = @import("../agents/agents.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const app_lifecycle = @import("app_lifecycle.zig");
const provider_runtime = @import("provider_runtime.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const diagnostics = @import("../workspace/diagnostics.zig");
const permissions = @import("../permissions/permissions.zig");
const display_width = @import("../shared/display_width.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_presentation = @import("../tooling/tool_presentation.zig");
const types = @import("../shared/types.zig");
const assistant_presentation = @import("../agent/assistant_presentation.zig");
const transcript_blocks = @import("../../ui/render_engine/transcript_blocks.zig");

pub const format_version: u32 = 1;

const notice_text = "Private diagnostic report. It may include prompts, file paths, command output, and file snippets.";
const tool_args_max_bytes: usize = 1200;
const result_preview_max_bytes: usize = 180;
const pending_items_shown: usize = 3;
const trace_tail_bytes: usize = 6 * 1024;
const trace_max_lines: usize = 80;

/// Writes trace records, one JSON object per line. `begin` starts a record
/// with its `type`, the field helpers add typed fields, and `end` finishes
/// the line. Every string goes through `text` or `masked`, which make it valid
/// UTF-8, because `std.json.Stringify` writes a byte slice that is not valid
/// UTF-8 as an array of numbers instead of a string.
const Records = struct {
    out: *std.Io.Writer,
    arena: std.mem.Allocator,
    json: std.json.Stringify,
    count: usize = 0,

    fn init(out: *std.Io.Writer, arena: std.mem.Allocator) Records {
        return .{ .out = out, .arena = arena, .json = .{ .writer = out } };
    }

    fn begin(self: *Records, comptime record_type: []const u8) !void {
        self.json = .{ .writer = self.out };
        try self.json.beginObject();
        try self.json.objectField("type");
        try self.json.write(record_type);
    }

    fn end(self: *Records) !void {
        try self.json.endObject();
        try self.out.writeByte('\n');
        self.count += 1;
    }

    fn beginObject(self: *Records, name: []const u8) !void {
        try self.json.objectField(name);
        try self.json.beginObject();
    }

    fn endObject(self: *Records) !void {
        try self.json.endObject();
    }

    fn beginArray(self: *Records, name: []const u8) !void {
        try self.json.objectField(name);
        try self.json.beginArray();
    }

    fn endArray(self: *Records) !void {
        try self.json.endArray();
    }

    /// Starts an object inside an array.
    fn beginItem(self: *Records) !void {
        try self.json.beginObject();
    }

    fn endItem(self: *Records) !void {
        try self.json.endObject();
    }

    /// A string inside an array.
    fn itemText(self: *Records, value: []const u8) !void {
        try self.json.write(try validUtf8(self.arena, value));
    }

    fn text(self: *Records, name: []const u8, value: []const u8) !void {
        try self.json.objectField(name);
        try self.json.write(try validUtf8(self.arena, value));
    }

    /// Text with obvious secrets replaced by `[redacted]`.
    fn masked(self: *Records, name: []const u8, value: []const u8) !void {
        try self.text(name, try text_utils.maskSecrets(self.arena, value));
    }

    /// Text that is left out when it is empty.
    fn optionalText(self: *Records, name: []const u8, value: []const u8) !void {
        if (value.len > 0) try self.text(name, value);
    }

    /// Masked text that is left out when it is empty.
    fn optionalMasked(self: *Records, name: []const u8, value: []const u8) !void {
        if (value.len > 0) try self.masked(name, value);
    }

    fn number(self: *Records, name: []const u8, value: anytype) !void {
        // Text goes through `text`, which makes it valid UTF-8.
        comptime std.debug.assert(@typeInfo(@TypeOf(value)) == .int or @typeInfo(@TypeOf(value)) == .comptime_int);
        try self.json.objectField(name);
        try self.json.write(value);
    }

    fn boolean(self: *Records, name: []const u8, value: bool) !void {
        try self.json.objectField(name);
        try self.json.write(value);
    }

    /// A time as `<name>` (ISO 8601 UTC) and `<name>_ms`; nothing when unknown.
    fn time(self: *Records, comptime name: []const u8, ms: i64) !void {
        if (ms <= 0) return;
        var buf: [40]u8 = undefined;
        try self.text(name, try formatUtc(&buf, ms));
        try self.number(name ++ "_ms", ms);
    }

    /// Writes the source of a call: the parent agent or a subagent.
    fn source(self: *Records, subagent_id: u64) !void {
        if (subagent_id == 0) return self.text("source", "parent");
        try self.text("source", "subagent");
        try self.number("subagent_id", subagent_id);
    }

    /// Adds records that a `Buffer` collected.
    fn appendBuffer(self: *Records, buffer: *Buffer) !void {
        try self.out.writeAll(buffer.bytes.written());
        self.count += buffer.records.count;
    }
};

/// Records collected before the summary record that counts them.
const Buffer = struct {
    bytes: std.Io.Writer.Allocating,
    records: Records,

    fn create(arena: std.mem.Allocator) !*Buffer {
        const buffer = try arena.create(Buffer);
        buffer.bytes = .init(arena);
        buffer.records = .init(&buffer.bytes.writer, arena);
        return buffer;
    }
};

fn validUtf8(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(value)) return value;
    return text_utils.dupeValidUtf8(arena, value);
}

fn formatUtc(buf: []u8, ms: i64) ![]const u8 {
    const secs: u64 = @intCast(@divFloor(ms, 1000));
    const ms_part: u64 = @intCast(@mod(ms, 1000));
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day_seconds = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.mem.print(buf, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
        ms_part,
    });
}

/// Returns the trace as JSONL bytes that the caller owns.
pub fn build(app: anytype) ![]u8 {
    const App = @TypeOf(app.*);
    var arena_state = std.heap.ArenaAllocator.init(app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.Io.Writer.Allocating = .init(app.alloc);
    defer out.deinit();
    var records = Records.init(&out.writer, arena);
    const r = &records;

    const agent = agents.screenAgentOf(app);
    const history = agent.session.agent.history.items;
    const permission_view = app_permission_runtime.Runtime(App).viewOf(app, agent);

    try writeHeader(r, App.app_version, io_mod.milliTimestamp());
    try writeSummary(r, app, permissions.permissionModeLabel(permission_view.mode));
    try writeCurrentState(r, app);
    try writeProblems(r, app);
    try writeLastShutdown(r, app_lifecycle.readLastShutdownReport(arena));
    try writeCompaction(r);
    try writeInterruptedTurn(r, history);
    try writeSessionTitle(r, app);
    try writeNetwork(r);
    try writeModelCatalog(r, app);
    try writeToolCalls(r, history);
    try writePermissions(r, permission_view.grants.items);
    try writeRuntimeContext(r, app);
    try writeRendererState(r, app);
    try writeRendererEvents(r);
    try writeTranscript(r, app.shell.notebook.entries.items);
    if (debug_trace.activeLogPath() orelse io_mod.getenv("FX_TRACE_LOG")) |path| {
        try writeTraceLog(r, path);
    }
    try writeEnd(r);
    return out.toOwnedSlice();
}

fn writeHeader(r: *Records, fx_version: []const u8, now_ms: i64) !void {
    try r.begin("fx_trace");
    try r.number("format_version", format_version);
    try r.text("fx_version", fx_version);
    try r.text("git_commit", build_options.git_commit);
    try r.time("written_at", now_ms);
    try r.text("notice", notice_text);
    try r.end();
}

fn writeEnd(r: *Records) !void {
    const before = r.count;
    try r.begin("end");
    try r.number("records", before);
    try r.end();
}

fn buildModeName() []const u8 {
    return switch (builtin.optimize) {
        .debug => "Debug",
        .safe => "ReleaseSafe",
        .fast => "ReleaseFast",
        .small => "ReleaseSmall",
    };
}

fn writeSummary(r: *Records, app: anytype, permission_mode: []const u8) !void {
    try r.begin("summary");
    try r.text("os", @tagName(builtin.target.os.tag));
    try r.text("arch", @tagName(builtin.target.cpu.arch));
    try r.text("build", buildModeName());
    try r.text("model", provider_runtime.model(app));
    try r.boolean("fast_mode", app.fast_mode);
    try r.text("permission_mode", permission_mode);
    try r.text("workspace", app.workspace_root);
    try r.end();
}

noinline fn writeCurrentState(r: *Records, app: anytype) !void {
    const App = @TypeOf(app.*);
    const agent = agents.screenAgentOf(app);
    try r.begin("current_state");
    if (comptime agents.hasAgentField(App, "session_persistence")) {
        const Sessions = app_session_runtime.Runtime(App);
        if (Sessions.activeSessionId(agent)) |id| try r.text("session_id", id);
        if (try Sessions.activeSessionDisplayPath(agent, r.arena)) |dir| try r.text("session_dir", dir);
    }
    if (comptime @hasField(App, "agent_step_limit")) try r.number("agent_step_limit", app.agent_step_limit);
    if (comptime agents.hasAgentField(App, "effort")) try r.text("effort", agent.effort.label());
    if (comptime agents.hasAgentField(App, "total_input_tokens") and agents.hasAgentField(App, "total_output_tokens")) {
        try r.number("input_tokens", agents.loadTotal(&agent.total_input_tokens));
        try r.number("output_tokens", agents.loadTotal(&agent.total_output_tokens));
    }
    if (comptime agents.hasAgentField(App, "total_web_search_requests")) {
        try r.number("web_search_requests", agents.loadTotal(&agent.total_web_search_requests));
    }
    try writeAuthState(r, app);
    try writeProcess(r);
    if (comptime agents.hasAgentField(App, "worker")) {
        if (agent.worker.snapshotState(r.arena) catch null) |state| {
            defer state.deinit(r.arena);
            try r.beginObject("worker");
            try r.boolean("processing", state.processing);
            try r.number("queued", state.queued_count);
            try r.boolean("cancel_requested", state.cancel_requested);
            if (state.pending_permission_request) |request| try r.masked("pending_permission", request.label);
            try r.endObject();
        }
        if (agent.worker.snapshotPendingQuestionBatch(r.arena) catch null) |questions| {
            defer questions.deinit(r.arena);
            try r.beginObject("pending_questions");
            try r.number("count", questions.entries.len);
            try r.beginArray("questions");
            for (questions.entries[0..@min(questions.entries.len, pending_items_shown)]) |entry| {
                try r.beginItem();
                try r.masked("question", entry.question);
                try r.number("options", entry.options.len);
                try r.endItem();
            }
            try r.endArray();
            try r.endObject();
        }
    }
    if (comptime agents.hasAgentField(App, "pending_images")) {
        const images = agent.pending_images.items;
        if (images.len > 0) {
            try r.beginObject("pending_images");
            try r.number("count", images.len);
            try r.beginArray("images");
            for (images[0..@min(images.len, pending_items_shown)]) |image| {
                try r.beginItem();
                try r.text("media_type", image.media_type);
                try r.masked("path", image.path);
                try r.endItem();
            }
            try r.endArray();
            try r.endObject();
        }
    }
    if (comptime @hasField(App, "context_enabled") and agents.hasAgentField(App, "context_snapshot")) {
        const context_bytes = agent.context_snapshot.modelVisibleBytes();
        try r.beginObject("project_context");
        try r.boolean("enabled", app.context_enabled);
        try r.boolean("loaded", context_bytes.len > 0);
        try r.number("bytes", context_bytes.len);
        try r.endObject();
    }
    try r.boolean("fx_trace", envTruthy("FX_TRACE"));
    if (debug_trace.activeLogPath() orelse io_mod.getenv("FX_TRACE_LOG")) |path| try r.masked("trace_log", path);
    if (comptime agents.hasAgentField(App, "stream")) {
        const stream = &agent.stream;
        try r.beginObject("stream");
        try r.boolean("active", stream.active);
        try r.number("chunks", stream.chunks);
        try r.number("reads", stream.read_count);
        try r.number("lists", stream.list_count);
        try r.number("writes", stream.write_count);
        try r.number("edits", stream.edit_count);
        try r.number("commands", stream.command_count);
        try r.number("subagents", stream.subagent_count);
        if (stream.last_activity_kind) |kind| try r.text("last_activity", @tagName(kind));
        try r.endObject();
    }
    try r.beginObject("terminal");
    try r.number("cols", app.shell.layout.cols);
    try r.number("rows", app.shell.layout.rows);
    try r.endObject();
    try r.beginObject("metrics");
    try r.number("ansi_bytes", app.metrics.ansi_bytes);
    try r.number("full_redraws", app.metrics.full_redraws);
    try r.number("debounced_resizes", app.metrics.debounced_resizes);
    try r.number("footer_updates", app.metrics.footer_line_updates);
    try r.number("stream_chunks", app.metrics.stream_chunks);
    try r.endObject();
    try r.end();
}

fn envTruthy(name: []const u8) bool {
    const raw = io_mod.getenv(name) orelse return false;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return std.ascii.eqlIgnoreCase(trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.ascii.eqlIgnoreCase(trimmed, "on");
}

/// Writes the `auth` object of `current_state`.
fn writeAuthState(r: *Records, app: anytype) !void {
    const App = @TypeOf(app.*);
    if (comptime !@hasField(App, "auth")) return;
    const auth_view = app.auth.view();
    try r.beginObject("auth");
    try r.text("source", auth_view.activeSourceLabel());
    try r.boolean("refreshable", auth_view.refreshable);
    try r.text("gateway_team", auth_view.gatewayTeamStatus().label());
    try r.endObject();
}

fn writeProcess(r: *Records) !void {
    const pid = std.c.getpid();
    try r.beginObject("process");
    try r.number("pid", pid);
    if (countOpenFileDescriptors()) |fd_count| try r.number("open_fds", fd_count);
    if (processMemorySnapshot(r.arena, pid) catch null) |ps_output| try writeProcessMemory(r, ps_output);
    try r.endObject();
}

/// Writes `ps -o pid,ppid,rss,vsz,etime,stat` output as `memory`, or as
/// `memory_lines` when it has another shape.
fn writeProcessMemory(r: *Records, ps_output: []const u8) !void {
    const trimmed = std.mem.trim(u8, ps_output, " \t\r\n");
    if (trimmed.len == 0) return;
    if (parsePsMemory(trimmed)) |memory| {
        try r.beginObject("memory");
        try r.number("pid", memory.pid);
        try r.number("ppid", memory.ppid);
        try r.number("rss_kib", memory.rss_kib);
        try r.number("vsz_kib", memory.vsz_kib);
        try r.text("elapsed", memory.elapsed);
        try r.text("stat", memory.stat);
        try r.endObject();
        return;
    }
    try r.beginArray("memory_lines");
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |line| try r.itemText(std.mem.trimEnd(u8, line, " \t\r"));
    try r.endArray();
}

const PsMemory = struct {
    pid: i64,
    ppid: i64,
    rss_kib: u64,
    vsz_kib: u64,
    elapsed: []const u8,
    stat: []const u8,
};

fn parsePsMemory(text: []const u8) ?PsMemory {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const header = lines.next() orelse return null;
    const values = lines.next() orelse return null;
    if (lines.next() != null) return null;
    var names = std.mem.tokenizeAny(u8, header, " \t\r");
    for ([_][]const u8{ "PID", "PPID", "RSS", "VSZ", "ELAPSED", "STAT" }) |expected| {
        const name = names.next() orelse return null;
        if (!std.mem.eql(u8, name, expected)) return null;
    }
    if (names.next() != null) return null;
    var fields = std.mem.tokenizeAny(u8, values, " \t\r");
    const memory: PsMemory = .{
        .pid = std.fmt.parseInt(i64, fields.next() orelse return null, 10) catch return null,
        .ppid = std.fmt.parseInt(i64, fields.next() orelse return null, 10) catch return null,
        .rss_kib = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null,
        .vsz_kib = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null,
        .elapsed = fields.next() orelse return null,
        .stat = fields.next() orelse return null,
    };
    if (fields.next() != null) return null;
    return memory;
}

fn countOpenFileDescriptors() ?usize {
    const fd_dir = switch (builtin.target.os.tag) {
        .linux => "/proc/self/fd",
        .macos => "/dev/fd",
        else => return null,
    };
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), fd_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io_mod.getIo());

    var count: usize = 0;
    var it = dir.iterate();
    while (it.next(io_mod.getIo()) catch return null) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        count += 1;
    }
    return count;
}

fn processMemorySnapshot(alloc: std.mem.Allocator, pid: std.c.pid_t) ![]u8 {
    const pid_text = try alloc.print("{d}", .{pid});
    defer alloc.free(pid_text);
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ "ps", "-o", "pid,ppid,rss,vsz,etime,stat", "-p", pid_text },
    });
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        alloc.free(result.stdout);
        return error.ProcessSnapshotFailed;
    }
    return result.stdout;
}

/// Writes the `problems` record and a `problem` record for each problem.
noinline fn writeProblems(r: *Records, app: anytype) !void {
    const later = try Buffer.create(r.arena);
    const p = &later.records;
    try writeActiveTurnProblem(p, app);
    try writeInterruptedTurnProblem(p, agents.screenAgentOf(app).session.agent.history.items);
    try writeSessionTitleProblem(p, app);
    try writeNetworkProblems(p);
    try writeToolProblems(p);
    try writeCompactionProblems(p);
    try writeMcpHostProblems(p, app);
    try writeModelCatalogProblems(p);

    try r.begin("problems");
    try r.number("count", p.count);
    try r.end();
    try r.appendBuffer(later);
}

fn beginProblem(p: *Records, comptime kind: []const u8) !void {
    try p.begin("problem");
    try p.text("kind", kind);
}

fn writeActiveTurnProblem(p: *Records, app: anytype) !void {
    const agent = agents.screenAgentOf(app);
    const snapshot = agent.worker.snapshotState(p.arena) catch return;
    defer snapshot.deinit(p.arena);
    if (!snapshot.processing and !agent.stream.active) return;
    try beginProblem(p, "active_turn");
    try p.boolean("processing", snapshot.processing);
    try p.boolean("stream_active", agent.stream.active);
    try p.number("queued", snapshot.queued_count);
    try p.end();
}

fn writeInterruptedTurnProblem(p: *Records, history: []const types.HistoryTurn) !void {
    const entry = lastInterruptedTurn(history) orelse return;
    try beginProblem(p, "interrupted_turn");
    if (entry.tool_call) |call| try p.text("in_flight_tool", traceToolDisplayName(call.name));
    try p.number("completed_tools", entry.completed_tool_names.len);
    try p.end();
}

fn writeSessionTitleProblem(p: *Records, app: anytype) !void {
    const App = @TypeOf(app.*);
    if (comptime !agents.hasAgentField(App, "session_persistence")) return;
    const Persistence = @TypeOf(agents.screenAgentOf(app).session_persistence);
    if (comptime !@hasField(Persistence, "title_generation")) return;
    const TitleGeneration = @TypeOf(agents.screenAgentOf(app).session_persistence.title_generation);
    if (comptime !@hasField(TitleGeneration, "last")) return;
    const last = &agents.screenAgentOf(app).session_persistence.title_generation.last;
    if (last.status != .failed and last.status != .dropped) return;
    try beginProblem(p, "session_title");
    try p.text("status", @tagName(last.status));
    if (last.reason) |reason| try p.text("reason", @tagName(reason));
    try p.optionalText("detail", last.detail);
    try p.end();
}

fn writeNetworkProblems(p: *Records) !void {
    const calls = try p.arena.alloc(diagnostics.NetworkCall, diagnostics.network_ring_capacity);
    const count = diagnostics.snapshotNetworkCalls(calls);
    var reported: usize = 0;
    var index = count;
    while (index > 0 and reported < 3) {
        index -= 1;
        const call = &calls[index];
        if (!call.isError()) continue;
        reported += 1;
        try beginProblem(p, "network_call");
        try p.beginObject("call");
        try writeNetworkCallFields(p, call);
        try p.endObject();
        try p.end();
    }
}

fn writeToolProblems(p: *Records) !void {
    const calls = try p.arena.alloc(diagnostics.ToolCallMetric, diagnostics.tool_call_ring_capacity);
    const count = diagnostics.snapshotToolCalls(calls);
    var reported: usize = 0;
    var index = count;
    while (index > 0 and reported < 5) {
        index -= 1;
        const call = &calls[index];
        if (call.outcome == .succeeded) continue;
        reported += 1;
        try beginProblem(p, "tool_call");
        try p.beginObject("call");
        try writeToolCallFields(p, call);
        try p.endObject();
        try p.end();
    }
}

fn writeCompactionProblems(p: *Records) !void {
    const events = try p.arena.alloc(diagnostics.CompactionEvent, diagnostics.compaction_ring_capacity);
    const count = diagnostics.snapshotCompactionEvents(events);
    var reported: usize = 0;
    var index = count;
    while (index > 0 and reported < 3) {
        index -= 1;
        const event = &events[index];
        if (!event.failed) continue;
        reported += 1;
        try beginProblem(p, "compaction");
        try p.text("event", event.name());
        if (event.turn_id != 0) try p.number("turn_id", event.turn_id);
        if (event.detail_len > 0) try p.text("detail", try neutralized(p.arena, event.detail()));
        try p.end();
    }
}

/// The MCP servers that need someone to act: down, retrying, missing a
/// variable, or waiting for a login.
fn writeMcpHostProblems(p: *Records, app: anytype) !void {
    if (comptime !@hasDecl(@TypeOf(app.*), "mcpHostStatuses")) return;
    const statuses = (try app.mcpHostStatuses(p.arena)) orelse return;
    for (statuses) |s| {
        const issue = switch (s.state) {
            .failed => "failed",
            .retrying => "retrying",
            .missing_env => "missing_env",
            .invalid_env => "invalid_env",
            else => if (s.needs_login) "needs_login" else continue,
        };
        try beginProblem(p, "mcp_server");
        try p.text("issue", issue);
        try p.text("name", s.name);
        if (s.missing) |variable| try p.text("variable", variable);
        if (s.last_error) |err| try p.masked("error", err);
        try p.end();
    }
}

/// Failed model-catalog loads, capability lookup misses, and image gate
/// rejections, so an unverifiable capability is never reported as no problem.
fn writeModelCatalogProblems(p: *Records) !void {
    var events: [diagnostics.model_catalog_ring_capacity]diagnostics.ModelCatalogEvent = undefined;
    const count = diagnostics.snapshotModelCatalogEvents(&events);
    var reported: usize = 0;
    var index = count;
    while (index > 0 and reported < 3) {
        index -= 1;
        const event = &events[index];
        if (!event.failed) continue;
        reported += 1;
        try beginProblem(p, "model_catalog");
        try p.text("event", event.name());
        try p.optionalText("detail", event.detail());
        try p.end();
    }
}

/// `contents` is the saved last-shutdown report, or null when there is none.
fn writeLastShutdown(r: *Records, contents: ?[]const u8) !void {
    try r.begin("last_shutdown");
    const report = contents orelse {
        try r.text("status", "none");
        return r.end();
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, r.arena, report, .{}) catch {
        try r.text("status", "unreadable");
        return r.end();
    };
    if (parsed != .object) {
        try r.text("status", "unreadable");
        return r.end();
    }
    const root = parsed.object;
    try r.text("status", "recorded");
    if (root.get("total_ms")) |value| if (value == .integer) try r.number("total_ms", value.integer);
    if (root.get("recorded_at_ms")) |value| if (value == .integer) try r.time("recorded_at", value.integer);
    if (root.get("stages")) |stages| if (stages == .array) {
        try r.beginArray("stages");
        for (stages.array.items) |stage| {
            if (stage != .object) continue;
            try r.beginItem();
            if (stage.object.get("name")) |name| if (name == .string) try r.text("name", name.string);
            if (stage.object.get("step_ms")) |step| if (step == .integer) try r.number("step_ms", step.integer);
            try r.endItem();
        }
        try r.endArray();
    };
    try r.end();
}

/// The always-on compaction decisions and failures, so a shared trace
/// explains what compaction did even when FX_TRACE was off.
fn writeCompaction(r: *Records) !void {
    const events = try r.arena.alloc(diagnostics.CompactionEvent, diagnostics.compaction_ring_capacity);
    const count = diagnostics.snapshotCompactionEvents(events);
    var failed: usize = 0;
    for (events[0..count]) |*event| {
        if (event.failed) failed += 1;
    }
    try r.begin("compaction");
    try r.number("retained", count);
    try r.number("failed", failed);
    try r.number("overwritten_before", if (count > 0) events[0].sequence -| 1 else 0);
    try r.end();
    for (events[0..count]) |*event| {
        try r.begin("compaction_event");
        try r.time("at", event.timestamp_ms);
        try r.number("sequence", event.sequence);
        try r.text("event", event.name());
        if (event.turn_id != 0) try r.number("turn_id", event.turn_id);
        if (event.step_id != 0) try r.number("step_id", event.step_id);
        if (event.subagent_id != 0) try r.number("subagent_id", event.subagent_id);
        try r.boolean("failed", event.failed);
        // Compaction events carry internal counters and enum names only,
        // never user payloads, so they are not masked.
        if (event.detail_len > 0) try r.text("detail", try neutralized(r.arena, event.detail()));
        try r.boolean("truncated", event.truncated);
        try r.end();
    }
}

fn lastInterruptedTurn(items: []const types.HistoryTurn) ?types.InterruptedHistoryTurn {
    if (items.len == 0) return null;
    return switch (items[items.len - 1]) {
        .interrupted => |entry| entry,
        else => null,
    };
}

fn writeInterruptedTurn(r: *Records, history: []const types.HistoryTurn) !void {
    const entry = lastInterruptedTurn(history) orelse return;
    try r.begin("interrupted_turn");
    if (entry.tool_call) |call| {
        try r.text("in_flight_tool", traceToolDisplayName(call.name));
        if (call.arguments_json.len > 0) {
            try r.masked("in_flight_args", text_utils.utf8PrefixByBytes(call.arguments_json, tool_args_max_bytes));
            try r.number("in_flight_args_bytes", call.arguments_json.len);
        }
    }
    try r.beginArray("completed_tools");
    for (entry.completed_tool_names) |name| try r.itemText(traceToolDisplayName(name));
    try r.endArray();
    try r.end();
}

/// The retained session title outcome, so a shared trace can explain why a
/// session has no generated title even when FX_TRACE was off.
fn writeSessionTitle(r: *Records, app: anytype) !void {
    const App = @TypeOf(app.*);
    if (comptime !agents.hasAgentField(App, "session_persistence")) return;
    const agent = agents.screenAgentOf(app);
    const Persistence = @TypeOf(agent.session_persistence);
    if (comptime !@hasField(Persistence, "title_generation")) return;
    const TitleGeneration = @TypeOf(agent.session_persistence.title_generation);
    if (comptime !@hasField(TitleGeneration, "last")) return;

    try r.begin("session_title");
    if (comptime @hasField(App, "session_title_generation")) try r.boolean("setting", app.session_title_generation);
    if (comptime agents.hasAgentField(App, "session_title")) {
        if (agent.session_title.items.len > 0) try r.masked("title", agent.session_title.items);
    }
    const generation = &agent.session_persistence.title_generation;
    try r.beginObject("generation");
    if (generation.task) |task| {
        try r.text("status", "running");
        try r.text("session", task.session_id);
        try r.text("model", task.model);
        if (task.started_at_ms > 0) {
            const elapsed = io_mod.milliTimestamp() - task.started_at_ms;
            if (elapsed >= 0) try r.number("elapsed_ms", elapsed);
        }
    } else {
        const last = &generation.last;
        try r.text("status", @tagName(last.status));
        try r.optionalText("session", last.sessionId());
        try r.optionalText("model", last.model());
        if (last.reason) |reason| try r.text("reason", @tagName(reason));
        try r.optionalText("detail", last.detail);
        if (last.elapsed_ms >= 0) try r.number("elapsed_ms", last.elapsed_ms);
    }
    try r.endObject();
    try r.end();
}

fn writeNetworkCallFields(r: *Records, call: *const diagnostics.NetworkCall) !void {
    try r.time("at", call.started_at_ms);
    try r.text("model", call.model());
    try r.text("kind", @tagName(call.kind));
    try r.source(call.subagent_id);
    try r.optionalText("error", call.errorName());
    if (call.status != 0) try r.number("status", call.status);
    try r.number("duration_ms", call.duration_ms);
    try r.number("response_bytes", call.response_bytes);
    try r.number("input_tokens", call.input_tokens);
    try r.number("output_tokens", call.output_tokens);
    if (call.is_web_search) try r.number("web_search_requests", call.web_search_requests);
    try r.optionalText("stop_reason", call.terminalStopReason());
    try r.optionalText("provider_stop_reason", call.providerStopReason());
    if (call.turn_id != 0) try r.number("turn_id", call.turn_id);
    if (call.step_id != 0) try r.number("step_id", call.step_id);
    // Gateway text comes from outside fx, so it is masked like tool output.
    try r.optionalMasked("gateway_error", call.gatewayErrorMessage());
    try r.optionalMasked("gateway_schema", call.gatewaySchemaDiagnostic());
    try r.optionalMasked("request_shape", call.gatewayRequestShape());
}

/// Session-wide totals, the per-turn rollup, and whether the bounded ring
/// still holds every call, so a trace is never read as the whole session
/// when the ring has dropped older calls.
noinline fn writeNetwork(r: *Records) !void {
    const calls = try r.arena.alloc(diagnostics.NetworkCall, diagnostics.network_ring_capacity);
    const count = diagnostics.snapshotNetworkCalls(calls);
    var ok_count: u64 = 0;
    var error_count: u64 = 0;
    var total_ms: u64 = 0;
    var max_ms: u32 = 0;
    var min_ms: u32 = std.math.maxInt(u32);
    for (calls[0..count]) |*call| {
        if (call.isError()) error_count += 1 else ok_count += 1;
        total_ms += call.duration_ms;
        max_ms = @max(max_ms, call.duration_ms);
        min_ms = @min(min_ms, call.duration_ms);
    }
    const lifetime = diagnostics.networkLifetimeStats();
    var rollups: [diagnostics.network_turn_rollup_capacity]diagnostics.NetworkTurnRollup = undefined;
    const rollup_count = diagnostics.snapshotNetworkTurnRollups(&rollups);
    const complete = count == 0 or lifetime.total_calls <= count;

    try r.begin("network");
    try r.number("retained", count);
    try r.number("ok", ok_count);
    try r.number("errors", error_count);
    if (count > 0) {
        try r.number("avg_ms", total_ms / count);
        try r.number("min_ms", min_ms);
        try r.number("max_ms", max_ms);
    }
    try r.beginObject("session");
    try r.number("calls", lifetime.total_calls);
    try r.number("ok", lifetime.ok_calls);
    try r.number("errors", lifetime.error_calls);
    try r.number("total_ms", lifetime.total_duration_ms);
    try r.endObject();
    try r.boolean("complete", complete);
    if (!complete) try r.time("oldest_retained_at", calls[0].started_at_ms);
    try r.number("turns_retained", rollup_count);
    try r.number("turns_evicted", lifetime.evicted_turns);
    try r.end();

    for (rollups[0..rollup_count]) |*rollup| {
        try r.begin("network_turn");
        try r.number("turn_id", rollup.turn_id);
        try r.number("calls", rollup.calls);
        try r.number("errors", rollup.error_calls);
        try r.number("subagent_calls", rollup.subagent_calls);
        try r.number("total_ms", rollup.total_duration_ms);
        try r.time("first_started_at", rollup.first_started_at_ms);
        try r.end();
    }
    for (calls[0..count]) |*call| {
        try r.begin("network_call");
        try writeNetworkCallFields(r, call);
        try r.end();
    }
}

/// Catalog cache state, the selected model's resolved capabilities, and the
/// always-on catalog events, so a shared trace explains why an image or a
/// capability-dependent feature was rejected.
fn writeModelCatalog(r: *Records, app: anytype) !void {
    const App = @TypeOf(app.*);
    var events: [diagnostics.model_catalog_ring_capacity]diagnostics.ModelCatalogEvent = undefined;
    const count = diagnostics.snapshotModelCatalogEvents(&events);

    try r.begin("model_catalog");
    if (comptime @hasField(App, "model_cache")) {
        const snapshot = app.model_cache.snapshotForTrace();
        try r.beginObject("cache");
        try r.text("state", snapshot.state);
        try r.number("entries", snapshot.entries);
        if (snapshot.last_attempt_age_ms) |age_ms| try r.number("last_attempt_age_ms", @max(age_ms, 0));
        if (snapshot.failure_category) |category| {
            try r.text("failure", category);
            try r.boolean("retryable", snapshot.failure_retryable);
            if (snapshot.failure_http_status) |status| try r.number("http_status", @backingInt(status));
            try r.boolean("anonymous_fallback", snapshot.anonymous_fallback);
        }
        try r.endObject();
    }
    if (comptime @hasDecl(App, "resolvedModelCapabilities")) {
        const model = provider_runtime.model(app);
        const capabilities = app.resolvedModelCapabilities(model);
        try r.beginObject("selected_model");
        try r.text("model", model);
        try r.text("image_input", @tagName(capabilities.image_input_support));
        try r.boolean("vision", capabilities.supports_vision);
        try r.boolean("file_input", capabilities.supports_file_input);
        try r.boolean("tool_use", capabilities.supports_tool_use);
        if (capabilities.context_window) |window| try r.number("context_window", window);
        try r.endObject();
    }
    try r.number("events", count);
    try r.end();

    for (events[0..count]) |*event| {
        try r.begin("model_catalog_event");
        try r.time("at", event.timestamp_ms);
        try r.number("sequence", event.sequence);
        try r.text("event", event.name());
        try r.boolean("failed", event.failed);
        try r.optionalText("detail", event.detail());
        try r.boolean("truncated", event.truncated);
        try r.end();
    }
}

fn traceToolDisplayName(tool_name: []const u8) []const u8 {
    return if (tool_presentation.isProviderSearchAlias(tool_name))
        "web_search"
    else
        tool_name;
}

fn isTraceToolTokenByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn providerSearchAliasPrefixLen(token: []const u8) ?usize {
    var end: usize = 1;
    while (end <= token.len) : (end += 1) {
        if (!tool_presentation.isProviderSearchAlias(token[0..end])) continue;
        if (end == token.len or token[end] == '_') return end;
    }
    return null;
}

fn writeTraceTextNeutralized(writer: *std.Io.Writer, text: []const u8) !void {
    var token_start: usize = 0;
    var scan_index: usize = 0;
    var written_through: usize = 0;
    while (scan_index < text.len) {
        if (!isTraceToolTokenByte(text[scan_index])) {
            scan_index += 1;
            continue;
        }
        token_start = scan_index;
        while (scan_index < text.len and isTraceToolTokenByte(text[scan_index])) : (scan_index += 1) {}
        const alias_len = providerSearchAliasPrefixLen(text[token_start..scan_index]) orelse continue;
        try writer.writeAll(text[written_through..token_start]);
        try writer.writeAll("web_search");
        written_through = token_start + alias_len;
    }
    try writer.writeAll(text[written_through..]);
}

/// `text` with internal search tool names written as `web_search`.
fn neutralized(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeTraceTextNeutralized(&out.writer, text);
    return out.written();
}

fn writeToolCallFields(r: *Records, call: *const diagnostics.ToolCallMetric) !void {
    try r.time("at", call.started_at_ms);
    try r.text("name", traceToolDisplayName(call.name()));
    try r.text("outcome", @tagName(call.outcome));
    try r.number("duration_ms", call.duration_ms);
    try r.source(call.subagent_id);
}

fn writeOutcomeCounts(r: *Records, counts: []const u64) !void {
    try r.beginObject("outcomes");
    for (std.enums.values(diagnostics.ToolCallOutcome)) |outcome| {
        try r.number(@tagName(outcome), counts[@backingInt(outcome)]);
    }
    try r.endObject();
}

const ProviderToolCallSummary = struct {
    call_id: []const u8,
    status: ?types.PersistedToolStatus,
};

fn findPersistedToolResult(
    execution: types.ExecutionMemory,
    call_id: []const u8,
) ?types.PersistedToolResult {
    for (execution.tool_steps) |step| {
        for (step.tool_results) |result| {
            if (std.mem.eql(u8, result.tool_call_id, call_id)) return result;
        }
    }
    return null;
}

fn projectProviderToolCalls(
    history: []const types.HistoryTurn,
    output: []ProviderToolCallSummary,
) usize {
    if (output.len == 0) return 0;

    var count: usize = 0;
    for (history) |turn| {
        const execution: types.ExecutionMemory = switch (turn) {
            .assistant => |entry| entry.execution,
            .interrupted => |entry| entry.execution,
            .compacted_summary => continue,
        };
        for (execution.tool_steps) |step| {
            for (step.tool_calls) |call| {
                if (call.provenance != .provider_executed or
                    !tool_presentation.isProviderSearchAlias(call.name)) continue;
                const summary: ProviderToolCallSummary = .{
                    .call_id = call.id,
                    .status = if (findPersistedToolResult(execution, call.id)) |result|
                        result.status
                    else
                        null,
                };
                if (count < output.len) {
                    output[count] = summary;
                    count += 1;
                } else {
                    @memmove(
                        output[0 .. output.len - 1],
                        output[1..],
                    );
                    output[output.len - 1] = summary;
                }
            }
        }
    }
    return count;
}

fn providerToolStatusLabel(status: ?types.PersistedToolStatus) []const u8 {
    return if (status) |value| switch (value) {
        .success => "ok",
        .failure => "err",
    } else "pending";
}

noinline fn writeToolCalls(r: *Records, history: []const types.HistoryTurn) !void {
    const calls = try r.arena.alloc(diagnostics.ToolCallMetric, diagnostics.tool_call_ring_capacity);
    const count = diagnostics.snapshotToolCalls(calls);
    var provider_calls: [diagnostics.tool_call_ring_capacity]ProviderToolCallSummary = undefined;
    const provider_count = projectProviderToolCalls(history, &provider_calls);

    var outcome_counts: [std.enums.values(diagnostics.ToolCallOutcome).len]u64 = @splat(0);
    var total_ms: u64 = 0;
    for (calls[0..count]) |*call| {
        outcome_counts[@backingInt(call.outcome)] += 1;
        total_ms += call.duration_ms;
    }
    const lifetime = diagnostics.toolCallLifetimeStats();

    try r.begin("tool_calls");
    try r.number("retained", count);
    try writeOutcomeCounts(r, &outcome_counts);
    try r.number("total_ms", total_ms);
    try r.beginObject("session");
    try r.number("calls", lifetime.total_calls);
    try writeOutcomeCounts(r, &lifetime.outcome_counts);
    try r.number("total_ms", lifetime.total_duration_ms);
    try r.endObject();
    try r.boolean("complete", lifetime.total_calls <= count);
    try r.number("web_search_retained", provider_count);
    try r.end();

    for (calls[0..count]) |*call| {
        try r.begin("tool_call");
        try writeToolCallFields(r, call);
        try writeToolPayload(r, "args", call.args(), call.args_len, call.args_total_bytes);
        if (call.outcome == .succeeded) {
            try writeToolResultPreview(r, call.result(), call.result_total_bytes);
        } else {
            try writeToolPayload(r, "result", call.result(), call.result_len, call.result_total_bytes);
        }
        try r.end();
    }
    for (provider_calls[0..provider_count]) |call| {
        try r.begin("web_search_call");
        try r.text("status", providerToolStatusLabel(call.status));
        try r.end();
    }
}

/// Writes `<name>` (masked), `<name>_bytes`, and `<name>_omitted_bytes` when
/// the ring kept only the first `body_len` of `total_bytes`.
fn writeToolPayload(r: *Records, comptime name: []const u8, body: []const u8, body_len: u16, total_bytes: u32) !void {
    if (total_bytes == 0) return;
    // The ring cuts at a byte count; a character it cut in two is left out.
    const kept = if (total_bytes > body_len) withoutCutCharacter(body) else body;
    const masked = try text_utils.maskSecrets(r.arena, std.mem.trim(u8, kept, " \t\r\n"));
    const trimmed = std.mem.trim(u8, masked, " \t\r\n");
    if (trimmed.len == 0) return;
    try r.text(name, trimmed);
    try r.number(name ++ "_bytes", total_bytes);
    if (total_bytes > kept.len) try r.number(name ++ "_omitted_bytes", total_bytes - kept.len);
}

/// `text` without a UTF-8 sequence that a cut at its end left incomplete.
fn withoutCutCharacter(text: []const u8) []const u8 {
    var start = text.len;
    var steps: usize = 0;
    while (start > 0 and steps < 4) : (steps += 1) {
        start -= 1;
        const byte = text[start];
        if (byte & 0b1100_0000 == 0b1000_0000) continue;
        const len = std.unicode.utf8ByteSequenceLength(byte) catch return text;
        return if (start + len > text.len) text[0..start] else text;
    }
    return text;
}

fn writeToolResultPreview(r: *Records, body: []const u8, total_bytes: u32) !void {
    if (total_bytes == 0) return;
    const masked = try text_utils.maskSecrets(r.arena, std.mem.trim(u8, body, " \t\r\n"));
    const trimmed = std.mem.trim(u8, masked, " \t\r\n");
    if (trimmed.len == 0) return;
    try r.text("result_preview", text_utils.utf8PrefixByBytes(firstUsefulPreviewLine(trimmed), result_preview_max_bytes));
    try r.number("result_bytes", total_bytes);
}

fn firstUsefulPreviewLine(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, ":")) continue;
        return trimmed;
    }
    return text;
}

fn writePermissions(r: *Records, grants: []const types.PermissionGrant) !void {
    try r.begin("permissions");
    try r.number("grants", grants.len);
    try r.end();
    for (grants) |grant| {
        try r.begin("permission_grant");
        try r.text("tool", traceToolDisplayName(grant.tool_name));
        try r.text("target", grant.target_path);
        try r.end();
    }
}

fn writeRuntimeContext(r: *Records, app: anytype) !void {
    try r.begin("runtime_context");
    if (io_mod.getenv("TERM")) |value| try r.text("term", value);
    if (io_mod.getenv("TERM_PROGRAM")) |value| try r.text("term_program", value);
    if (io_mod.getenv("LANG")) |value| try r.text("lang", value);
    try r.boolean("tmux", io_mod.getenv("TMUX") != null);
    try r.boolean("cmux", io_mod.getenv("CMUX_WORKSPACE_ID") != null);
    if (comptime !@hasDecl(@TypeOf(app.*), "mcpHostStatuses")) {
        try r.number("mcp_servers", 0);
        return r.end();
    }
    const statuses = (try app.mcpHostStatuses(r.arena)) orelse &.{};
    try r.number("mcp_servers", statuses.len);
    try r.end();
    for (statuses) |s| {
        try r.begin("mcp_server");
        try r.text("name", s.name);
        try r.text("state", @tagName(s.state));
        try r.text("transport", @tagName(s.transport));
        try r.number("tools", s.tools);
        try r.boolean("signed_in", s.signed_in);
        try r.boolean("needs_login", s.needs_login);
        if (s.last_error) |err| try r.masked("error", err);
        try r.end();
    }
}

noinline fn writeRendererState(r: *Records, app: anytype) !void {
    const shell = &app.shell;
    const commit = shell.transcriptCommitDiagnostic();
    try r.begin("renderer_state");
    try r.beginObject("layout");
    try r.number("cols", shell.layout.cols);
    try r.number("rows", shell.layout.rows);
    try r.number("content_bottom", shell.layout.content_bottom);
    try r.number("divider_top", shell.layout.divider_top_row);
    try r.number("input_row", shell.layout.input_row);
    try r.endObject();
    try r.beginObject("cursor");
    try r.number("row", shell.cursor_row);
    try r.number("col", shell.cursor_col);
    try r.number("viewport_top", shell.viewport_top_row);
    try r.number("owned_top", shell.owned_top_row);
    try r.number("last_visible_top", shell.last_visible_transcript_top_row);
    try r.number("last_start_line", shell.last_visible_transcript_start_line);
    try r.number("partial_skip", shell.last_visible_transcript_partial_skip_rows);
    try r.endObject();
    try r.beginObject("transcript");
    try r.number("bytes", shell.notebook.transcript.items.len);
    try r.number("entries", shell.notebook.entries.items.len);
    try r.number("last_rendered_cols", shell.notebook.last_rendered_cols);
    try r.boolean("dirty", shell.transcript_band_dirty);
    try r.boolean("has_painted", shell.has_painted_transcript);
    try r.text("commit_state", @tagName(commit.state));
    if (commit.stable_start_line) |line| try r.number("committed_start_line", line);
    try r.boolean("pending_compact", shell.pending_scroll_compact);
    try r.endObject();
    try r.beginObject("projection");
    try r.number("view", commit.visual_offset);
    try r.number("history", commit.history_visual_offset);
    try r.number("total_rows", commit.total_visual_rows);
    try r.number("source_bytes", commit.source_bytes);
    try r.boolean("recovery", shell.normalBufferRecoveryPending());
    try r.boolean("catchup", shell.historyCatchupPending());
    try r.endObject();
    try r.beginObject("replaceable");
    try r.boolean("active", shell.notebook.replaceable_last_line);
    try r.number("row", shell.replaceable_row);
    try r.number("start", shell.notebook.replaceable_start);
    try r.endObject();
    if (shell.shadow_vt) |grid| {
        try r.beginObject("shadow_grid");
        try r.number("cols", grid.cols);
        try r.number("rows", grid.rows);
        try r.number("cursor_row", grid.cursor_row);
        try r.number("cursor_col", grid.cursor_col);
        try r.boolean("cursor_visible", grid.cursor_visible);
        try r.boolean("sync_active", grid.sync_active);
        try r.beginArray("visible_rows");
        var row: u16 = 1;
        while (row <= grid.rows) : (row += 1) {
            // rowTextTrimmed appends with the grid's own allocator.
            var row_text: std.ArrayList(u8) = .empty;
            defer row_text.deinit(grid.alloc);
            try grid.rowTextTrimmed(row, &row_text);
            const trimmed = std.mem.trimEnd(u8, row_text.items, " \t\r");
            if (trimmed.len == 0) continue;
            try r.beginItem();
            try r.number("row", row);
            try r.masked("text", trimmed);
            try r.endItem();
        }
        try r.endArray();
        try r.endObject();
    }
    try r.end();
}

noinline fn writeRendererEvents(r: *Records) !void {
    const events = try r.arena.alloc(diagnostics.RenderEvent, diagnostics.render_ring_capacity);
    const count = diagnostics.snapshotRenderEvents(events);
    try r.begin("renderer_events");
    try r.number("retained", count);
    try r.number("capacity", diagnostics.render_ring_capacity);
    try r.number("overwritten_before", if (count > 0) events[0].sequence -| 1 else 0);
    try r.end();
    for (events[0..count]) |*event| {
        try r.begin("renderer_event");
        try r.time("at", event.timestamp_ms);
        try r.number("sequence", event.sequence);
        try r.text("kind", @tagName(event.kind));
        try r.masked("detail", event.detail());
        try r.boolean("truncated", event.truncated);
        try r.end();
    }
}

/// Writes the `transcript` record and a `transcript_entry` per entry that
/// has text after filtering.
noinline fn writeTranscript(r: *Records, entries: anytype) !void {
    const later = try Buffer.create(r.arena);
    for (entries) |entry| try writeTranscriptEntry(&later.records, entry);
    try r.begin("transcript");
    try r.number("entries", entries.len);
    try r.number("emitted", later.records.count);
    try r.end();
    try r.appendBuffer(later);
}

fn writeTranscriptEntry(r: *Records, entry: anytype) !void {
    const arena = r.arena;
    const kind: []const u8 = switch (entry) {
        .raw_bytes => "raw",
        .user_turn => "user",
        .assistant_turn => "assistant",
        .assistant_table => "assistant_table",
        .assistant_code_block => "assistant_code_block",
        .assistant_thematic_rule => "assistant_thematic_rule",
        .semantic_notice => "semantic_notice",
    };
    const text: []const u8 = switch (entry) {
        .raw_bytes => |e| e.bytes,
        .user_turn => |e| e.turn.text,
        .assistant_turn => |e| e.segments.text.items,
        .assistant_table => |e| blk: {
            var table_text: std.ArrayList(u8) = .empty;
            try assistant_presentation.renderTablePayload(arena, e.table, &table_text);
            break :blk table_text.items;
        },
        .assistant_code_block => |e| blk: {
            var code_text: std.ArrayList(u8) = .empty;
            try assistant_presentation.renderCodeBlockPayload(arena, e.block, &code_text);
            break :blk code_text.items;
        },
        .assistant_thematic_rule => blk: {
            var rule_text: std.ArrayList(u8) = .empty;
            try assistant_presentation.writeHorizontalRule(arena, &rule_text);
            break :blk rule_text.items;
        },
        .semantic_notice => |e| try transcript_blocks.renderSemanticNotice(
            arena,
            .{
                .topic = e.topic,
                .tone = e.tone,
                .body = e.body,
                .visibility = e.visibility,
            },
            .{},
            std.math.maxInt(u16),
        ),
    };
    if (text.len == 0) return;

    const body = switch (entry) {
        .assistant_thematic_rule => try thematicRuleText(arena, text),
        else => try timelineText(arena, text),
    };
    if (body.len == 0) return;

    try r.begin("transcript_entry");
    try r.time("at", entry.createdAtMs());
    try r.text("kind", kind);
    try r.text("text", body);
    try r.end();
}

/// The entry's lines without ANSI escapes, blank lines, or banner lines,
/// with obvious secrets masked, joined by line breaks.
fn timelineText(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const stripped = try stripAnsiEscapes(arena, text);
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, stripped, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (isBannerNoiseLine(trimmed)) continue;
        if (out.items.len > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, try text_utils.maskSecrets(arena, trimmed));
    }
    return out.items;
}

fn thematicRuleText(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const stripped = try stripAnsiEscapes(arena, text);
    return std.mem.trimEnd(u8, stripped, " \t\r\n");
}

fn isBannerNoiseLine(line: []const u8) bool {
    if (line.len == 0) return true;
    if (std.mem.find(u8, line, "\xe2\x96\x91") != null) return true;
    for (line) |c| {
        if (std.ascii.isAlphanumeric(c)) return false;
    }
    return true;
}

fn stripAnsiEscapes(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, input.len);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == 0x1b and i + 1 < input.len) {
            i = display_width.ansiSequenceEnd(input, i);
            continue;
        }
        if (c == '\r') {
            i += 1;
            continue;
        }
        try out.append(alloc, c);
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}

/// Writes the end of the debug trace log at `path`; nothing when it cannot be
/// read or is empty.
fn writeTraceLog(r: *Records, path: []const u8) !void {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return;
    defer file.close(io_mod.getIo());
    const stat = file.stat(io_mod.getIo()) catch return;
    const total_size: usize = @intCast(stat.size);
    if (total_size == 0) return;

    const read_size = @min(total_size, trace_tail_bytes);
    const offset: u64 = total_size - read_size;
    const buf = try r.arena.alloc(u8, read_size);
    const n = file.readPositionalAll(io_mod.getIo(), buf, offset) catch return;
    if (n == 0) return;

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try lines.append(r.arena, trimmed);
    }
    const start = lines.items.len -| trace_max_lines;

    try r.begin("trace_log");
    try r.masked("path", path);
    try r.number("bytes", n);
    try r.boolean("older_lines_cut", offset > 0);
    try r.number("lines", lines.items.len - start);
    try r.end();
    for (lines.items[start..]) |line| {
        try r.begin("trace_log_line");
        try r.text("text", try neutralized(r.arena, try text_utils.maskSecrets(r.arena, line)));
        try r.end();
    }
}

fn traceFilePermissions() std.Io.File.Permissions {
    return switch (builtin.target.os.tag) {
        .windows => .default_file,
        else => std.Io.File.Permissions.fromMode(0o600),
    };
}

/// Writes `contents` to a new private `fx-trace-<UTC time>-<random>.jsonl`
/// in the temp folder and returns its path, which the caller owns.
pub fn writeFile(alloc: std.mem.Allocator, contents: []const u8) ![]u8 {
    const tmp_dir = io_mod.getenv("TMPDIR") orelse "/tmp";
    const trimmed = std.mem.trimEnd(u8, tmp_dir, "/");
    const now_ms = io_mod.milliTimestamp();
    const now_secs: i64 = @max(@divFloor(now_ms, 1000), 0);
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now_secs) };
    const day_seconds = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var attempts: u8 = 0;
    while (attempts < 8) : (attempts += 1) {
        var random_bytes: [6]u8 = undefined;
        io_mod.getIo().random(&random_bytes);
        const random_hex = std.fmt.bytesToHex(random_bytes, .lower);
        const path = try alloc.print("{s}/fx-trace-{d}-{d:0>2}-{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{s}.jsonl", .{
            trimmed,
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            random_hex,
        });
        errdefer alloc.free(path);

        var file = std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{
            .truncate = false,
            .exclusive = true,
            .permissions = traceFilePermissions(),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                alloc.free(path);
                continue;
            },
            else => return err,
        };
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), contents);
        try file.sync(io_mod.getIo());

        return path;
    }
    return error.PathAlreadyExists;
}

// Tests read the records back the way a program would: each line on its own,
// with std.json.

const TestTrace = struct {
    arena: std.heap.ArenaAllocator,
    records: []const std.json.ObjectMap,

    /// Parses `bytes` as records and checks each is one line holding one
    /// JSON object whose first key is a string `type`.
    fn parse(bytes: []const u8) !TestTrace {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var list: std.ArrayList(std.json.ObjectMap) = .empty;
        if (bytes.len > 0) {
            try std.testing.expect(bytes[bytes.len - 1] == '\n');
            var lines = std.mem.splitScalar(u8, bytes[0 .. bytes.len - 1], '\n');
            while (lines.next()) |line| {
                const value = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch |err| {
                    std.debug.print("trace test: {s} in line\n  {s}\n", .{ @errorName(err), line });
                    return err;
                };
                try std.testing.expect(value == .object);
                const keys = value.object.keys();
                try std.testing.expect(keys.len > 0);
                try std.testing.expectEqualStrings("type", keys[0]);
                try std.testing.expect(value.object.get("type").? == .string);
                try list.append(a, value.object);
            }
        }
        return .{ .arena = arena, .records = list.items };
    }

    fn deinit(self: *TestTrace) void {
        self.arena.deinit();
    }

    fn count(self: *const TestTrace, record_type: []const u8) usize {
        var n: usize = 0;
        for (self.records) |record| {
            if (std.mem.eql(u8, record.get("type").?.string, record_type)) n += 1;
        }
        return n;
    }

    /// The `index`th record of a type; fails when there is none.
    fn nth(self: *const TestTrace, record_type: []const u8, index: usize) !std.json.ObjectMap {
        var seen: usize = 0;
        for (self.records) |record| {
            if (!std.mem.eql(u8, record.get("type").?.string, record_type)) continue;
            if (seen == index) return record;
            seen += 1;
        }
        std.debug.print("trace test: no {s} record number {d}\n", .{ record_type, index });
        return error.TestRecordMissing;
    }

    fn one(self: *const TestTrace, record_type: []const u8) !std.json.ObjectMap {
        try std.testing.expectEqual(@as(usize, 1), self.count(record_type));
        return self.nth(record_type, 0);
    }
};

fn fieldProblem(key: []const u8, err: anyerror) anyerror {
    std.debug.print("trace test: field {s}: {s}\n", .{ key, @errorName(err) });
    return err;
}

/// Fails, naming the field, when `record` has `key`.
fn expectAbsent(record: std.json.ObjectMap, key: []const u8) !void {
    if (record.get(key) != null) return fieldProblem(key, error.TestFieldPresent);
}

/// Fails, printing both, when `actual` does not start with `prefix`.
fn expectStartsWith(actual: []const u8, prefix: []const u8) !void {
    if (std.mem.startsWith(u8, actual, prefix)) return;
    std.debug.print("trace test: expected a start of\n  {s}\nfound\n  {s}\n", .{ prefix, actual });
    return error.TestUnexpectedResult;
}

fn expectEndsWith(actual: []const u8, suffix: []const u8) !void {
    if (std.mem.endsWith(u8, actual, suffix)) return;
    std.debug.print("trace test: expected an end of\n  {s}\nfound\n  {s}\n", .{ suffix, actual });
    return error.TestUnexpectedResult;
}

/// Fails, printing where, when `needle` is in `haystack`.
fn expectNotIn(haystack: []const u8, needle: []const u8) !void {
    const at = std.mem.find(u8, haystack, needle) orelse return;
    const from = at -| 160;
    std.debug.print("trace test: found {s} at {d}: {s}\n", .{ needle, at, haystack[from..@min(haystack.len, at + needle.len + 40)] });
    return error.TestUnexpectedResult;
}

fn testString(record: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = record.get(key) orelse return fieldProblem(key, error.TestFieldMissing);
    if (value != .string) return fieldProblem(key, error.TestFieldNotString);
    return value.string;
}

fn testInt(record: std.json.ObjectMap, key: []const u8) !i64 {
    const value = record.get(key) orelse return fieldProblem(key, error.TestFieldMissing);
    if (value != .integer) return fieldProblem(key, error.TestFieldNotInteger);
    return value.integer;
}

fn testBool(record: std.json.ObjectMap, key: []const u8) !bool {
    const value = record.get(key) orelse return fieldProblem(key, error.TestFieldMissing);
    if (value != .bool) return fieldProblem(key, error.TestFieldNotBool);
    return value.bool;
}

fn testObject(record: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    const value = record.get(key) orelse return fieldProblem(key, error.TestFieldMissing);
    if (value != .object) return fieldProblem(key, error.TestFieldNotObject);
    return value.object;
}

/// Writes records into memory for a test; `trace()` parses them.
const TestWriter = struct {
    arena: std.heap.ArenaAllocator,
    out: std.Io.Writer.Allocating,
    records: Records,

    fn create() !*TestWriter {
        const self = try std.testing.allocator.create(TestWriter);
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.out = .init(self.arena.allocator());
        self.records = .init(&self.out.writer, self.arena.allocator());
        return self;
    }

    fn destroy(self: *TestWriter) void {
        self.arena.deinit();
        std.testing.allocator.destroy(self);
    }

    fn trace(self: *TestWriter) !TestTrace {
        return TestTrace.parse(self.out.written());
    }
};

test "trace records stay one JSON line each, with type first and text kept as a string" {
    const w = try TestWriter.create();
    defer w.destroy();
    const hostile = "quote \" backslash \\ cr \r lf \n tab \t nul \x00 unit \x1f del \x7f sep \u{2028} " ++
        "bad \xff lone \xc3 overlong \xc0\x80 surrogate \xed\xa0\x80 cut \xf0\x9f\x98";
    try w.records.begin("probe");
    try w.records.text("plain", hostile);
    try w.records.text("empty", "");
    try w.records.beginArray("items");
    try w.records.itemText(hostile);
    try w.records.endArray();
    try w.records.end();
    try w.records.begin("second");
    try w.records.number("n", @as(u64, std.math.maxInt(u32)));
    try w.records.end();

    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, w.out.written(), "\n"));
    var trace = try w.trace();
    defer trace.deinit();
    try std.testing.expectEqual(@as(usize, 2), trace.records.len);
    const probe = try trace.one("probe");
    const expected = try text_utils.dupeValidUtf8(trace.arena.allocator(), hostile);
    try std.testing.expectEqualStrings(expected, try testString(probe, "plain"));
    try std.testing.expect(std.mem.find(u8, expected, "\\xff") != null);
    try std.testing.expectEqualStrings(expected, probe.get("items").?.array.items[0].string);
    try std.testing.expectEqualStrings("", try testString(probe, "empty"));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(u32)), try testInt(try trace.one("second"), "n"));
}

test "trace header and end records frame the file" {
    const w = try TestWriter.create();
    defer w.destroy();
    try writeHeader(&w.records, "9.9.9", 1_700_000_000_123);
    try w.records.begin("middle");
    try w.records.end();
    try writeEnd(&w.records);

    var trace = try w.trace();
    defer trace.deinit();
    const header = trace.records[0];
    try std.testing.expectEqualStrings("fx_trace", try testString(header, "type"));
    try std.testing.expectEqual(@as(i64, 1), try testInt(header, "format_version"));
    try std.testing.expectEqualStrings("9.9.9", try testString(header, "fx_version"));
    try std.testing.expectEqualStrings(build_options.git_commit, try testString(header, "git_commit"));
    try std.testing.expectEqualStrings("2023-11-14T22:13:20.123Z", try testString(header, "written_at"));
    try std.testing.expectEqual(@as(i64, 1_700_000_000_123), try testInt(header, "written_at_ms"));
    try std.testing.expectEqualStrings(notice_text, try testString(header, "notice"));
    const last = trace.records[trace.records.len - 1];
    try std.testing.expectEqualStrings("end", try testString(last, "type"));
    try std.testing.expectEqual(@as(i64, 2), try testInt(last, "records"));
}

test "trace times leave out unknown values" {
    const w = try TestWriter.create();
    defer w.destroy();
    try w.records.begin("times");
    try w.records.time("zero", 0);
    try w.records.time("negative", -5);
    try w.records.time("at", 1);
    try w.records.end();
    var trace = try w.trace();
    defer trace.deinit();
    const record = try trace.one("times");
    try expectAbsent(record, "zero");
    try expectAbsent(record, "zero_ms");
    try expectAbsent(record, "negative");
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.001Z", try testString(record, "at"));
}

test "trace process memory reads ps output and keeps other shapes as lines" {
    const parsed = parsePsMemory("  PID  PPID    RSS      VSZ     ELAPSED STAT\n 4242     1  12345 4123456       01:02 S+").?;
    try std.testing.expectEqual(@as(i64, 4242), parsed.pid);
    try std.testing.expectEqual(@as(i64, 1), parsed.ppid);
    try std.testing.expectEqual(@as(u64, 12345), parsed.rss_kib);
    try std.testing.expectEqual(@as(u64, 4123456), parsed.vsz_kib);
    try std.testing.expectEqualStrings("01:02", parsed.elapsed);
    try std.testing.expectEqualStrings("S+", parsed.stat);
    try std.testing.expect(parsePsMemory("PID PPID RSS VSZ ELAPSED STAT\n1 2 x 4 01:02 S") == null);
    try std.testing.expect(parsePsMemory("PID PPID RSS VSZ ELAPSED\n1 2 3 4 01:02") == null);

    const w = try TestWriter.create();
    defer w.destroy();
    try w.records.begin("current_state");
    try w.records.beginObject("process");
    try writeProcessMemory(&w.records, "  UID PID\n  501 4242\n");
    try w.records.endObject();
    try w.records.end();
    var trace = try w.trace();
    defer trace.deinit();
    const process = try testObject(try trace.one("current_state"), "process");
    const lines = process.get("memory_lines").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("UID PID", lines[0].string);
    try expectAbsent(process, "memory");
}

test "trace renderer events are available without opt-in file logging" {
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();
    debug_trace.shutdown();
    diagnostics.recordRenderEvent(.transition, "release_past_finality history={d} releasable={d}", .{ 21, 20 });
    diagnostics.recordRenderEvent(.commit, "token AI_GATEWAY_API_KEY=abcdefghijklmnop", .{});
    const w = try TestWriter.create();
    defer w.destroy();
    try writeRendererEvents(&w.records);
    try std.testing.expect(debug_trace.activeLogPath() == null);

    var trace = try w.trace();
    defer trace.deinit();
    const summary = try trace.one("renderer_events");
    try std.testing.expectEqual(@as(i64, 2), try testInt(summary, "retained"));
    try std.testing.expectEqual(@as(i64, diagnostics.render_ring_capacity), try testInt(summary, "capacity"));
    try std.testing.expectEqual(@as(i64, 0), try testInt(summary, "overwritten_before"));
    const first = try trace.nth("renderer_event", 0);
    try std.testing.expectEqual(@as(i64, 1), try testInt(first, "sequence"));
    try std.testing.expectEqualStrings("transition", try testString(first, "kind"));
    try std.testing.expectEqualStrings("release_past_finality history=21 releasable=20", try testString(first, "detail"));
    try std.testing.expect(!try testBool(first, "truncated"));
    try std.testing.expect((try testString(first, "at")).len > 0);
    const second = try trace.nth("renderer_event", 1);
    try std.testing.expectEqualStrings("token AI_GATEWAY_API_KEY=[redacted]", try testString(second, "detail"));
}

test "trace renderer events report what the full ring dropped" {
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();
    for (0..diagnostics.render_ring_capacity + 1) |index| {
        diagnostics.recordRenderEvent(.redraw, "index={d}", .{index});
    }
    const w = try TestWriter.create();
    defer w.destroy();
    try writeRendererEvents(&w.records);
    var trace = try w.trace();
    defer trace.deinit();
    const summary = try trace.one("renderer_events");
    try std.testing.expectEqual(@as(i64, diagnostics.render_ring_capacity), try testInt(summary, "retained"));
    try std.testing.expectEqual(@as(i64, 1), try testInt(summary, "overwritten_before"));
    try std.testing.expectEqual(diagnostics.render_ring_capacity, trace.count("renderer_event"));
    try std.testing.expectEqualStrings("index=1", try testString(try trace.nth("renderer_event", 0), "detail"));
}

const TestTranscriptEntry = @import("../../ui/transcript/runtime.zig").TranscriptEntry;
const worker_runtime = @import("../agent/worker_runtime.zig");

test "trace transcript keeps semantic table, code block, and thematic rule contents" {
    const alloc = std.testing.allocator;
    var entries: std.ArrayList(TestTranscriptEntry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit(alloc);
    }
    const table = try assistant_presentation.parseTablePayload(
        alloc,
        "| Name | Count |\n" ++
            "|------|------:|\n" ++
            "| api | 7 |\n",
    );
    try entries.append(alloc, .{ .assistant_table = .{ .id = 1, .table = table } });
    try entries.append(alloc, .{ .assistant_code_block = .{ .id = 2, .block = .{
        .language = try alloc.dupe(u8, "zig"),
        .code = try alloc.dupe(u8, "const value = 1;\n"),
    } } });
    try entries.append(alloc, .{ .assistant_thematic_rule = .{ .id = 3 } });

    const w = try TestWriter.create();
    defer w.destroy();
    try writeTranscript(&w.records, entries.items);
    var trace = try w.trace();
    defer trace.deinit();
    const summary = try trace.one("transcript");
    try std.testing.expectEqual(@as(i64, 3), try testInt(summary, "entries"));
    try std.testing.expectEqual(@as(i64, 3), try testInt(summary, "emitted"));
    const table_entry = try trace.nth("transcript_entry", 0);
    try std.testing.expectEqualStrings("assistant_table", try testString(table_entry, "kind"));
    try std.testing.expect(std.mem.find(u8, try testString(table_entry, "text"), "api") != null);
    try std.testing.expect(std.mem.find(u8, try testString(table_entry, "text"), "[structured table]") == null);
    const code_entry = try trace.nth("transcript_entry", 1);
    try std.testing.expectEqualStrings("assistant_code_block", try testString(code_entry, "kind"));
    try std.testing.expect(std.mem.find(u8, try testString(code_entry, "text"), "const value = 1;") != null);
    const rule_entry = try trace.nth("transcript_entry", 2);
    try std.testing.expectEqualStrings("assistant_thematic_rule", try testString(rule_entry, "kind"));
    try std.testing.expectEqual(@as(usize, 60), std.mem.count(u8, try testString(rule_entry, "text"), "\xe2\x94\x80"));
}

test "trace transcript strips escapes, drops banner lines, masks secrets, and counts empty entries" {
    var entries = [_]TestTranscriptEntry{
        .{ .raw_bytes = .{ .id = 1, .created_at_ms = 1_700_000_000_000, .bytes = "\x1b[1mbold\x1b[0m line\r\n\n   \n\xe2\x96\x91\xe2\x96\x91 banner\n----\nexport AI_GATEWAY_API_KEY=abcdefghijklmnop\n" } },
        .{ .raw_bytes = .{ .id = 2, .bytes = "\n  \n----\n" } },
        .{ .raw_bytes = .{ .id = 3, .bytes = "" } },
    };
    const w = try TestWriter.create();
    defer w.destroy();
    try writeTranscript(&w.records, &entries);
    var trace = try w.trace();
    defer trace.deinit();
    const summary = try trace.one("transcript");
    try std.testing.expectEqual(@as(i64, 3), try testInt(summary, "entries"));
    try std.testing.expectEqual(@as(i64, 1), try testInt(summary, "emitted"));
    const entry = try trace.one("transcript_entry");
    try std.testing.expectEqualStrings("raw", try testString(entry, "kind"));
    try std.testing.expectEqualStrings("2023-11-14T22:13:20.000Z", try testString(entry, "at"));
    try std.testing.expectEqualStrings("bold line\nexport AI_GATEWAY_API_KEY=[redacted]", try testString(entry, "text"));
}

test "trace compaction records events without file tracing" {
    const compactor = @import("../compactor/compactor.zig");
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();

    const empty = try TestWriter.create();
    defer empty.destroy();
    try writeCompaction(&empty.records);
    var empty_trace = try empty.trace();
    defer empty_trace.deinit();
    const none = try empty_trace.one("compaction");
    try std.testing.expectEqual(@as(i64, 0), try testInt(none, "retained"));
    try std.testing.expectEqual(@as(i64, 0), try testInt(none, "overwritten_before"));
    try std.testing.expectEqual(@as(usize, 0), empty_trace.count("compaction_event"));

    compactor.traceEvent(.{ .turn_id = 10, .step_id = 176 }, .decision, "decision=compact estimated_tokens={d}", .{279466});
    compactor.traceFailure(.{ .turn_id = 10 }, .retention_exhausted, "estimated_tokens={d} via exa_search", .{59000});

    const w = try TestWriter.create();
    defer w.destroy();
    try writeCompaction(&w.records);
    try writeCompactionProblems(&w.records);
    var trace = try w.trace();
    defer trace.deinit();
    const summary = try trace.one("compaction");
    try std.testing.expectEqual(@as(i64, 2), try testInt(summary, "retained"));
    try std.testing.expectEqual(@as(i64, 1), try testInt(summary, "failed"));
    const decision = try trace.nth("compaction_event", 0);
    try std.testing.expectEqualStrings("decision", try testString(decision, "event"));
    try std.testing.expectEqual(@as(i64, 10), try testInt(decision, "turn_id"));
    try std.testing.expectEqual(@as(i64, 176), try testInt(decision, "step_id"));
    try std.testing.expect(!try testBool(decision, "failed"));
    try std.testing.expectEqualStrings("decision=compact estimated_tokens=279466", try testString(decision, "detail"));
    const failure = try trace.nth("compaction_event", 1);
    try std.testing.expectEqualStrings("retention_exhausted", try testString(failure, "event"));
    try std.testing.expect(try testBool(failure, "failed"));
    try expectAbsent(failure, "step_id");
    try std.testing.expectEqualStrings("estimated_tokens=59000 via web_search", try testString(failure, "detail"));
    const problem = try trace.one("problem");
    try std.testing.expectEqualStrings("compaction", try testString(problem, "kind"));
    try std.testing.expectEqualStrings("retention_exhausted", try testString(problem, "event"));
    try std.testing.expectEqual(@as(i64, 10), try testInt(problem, "turn_id"));

    diagnostics.resetForTest();
    for (0..diagnostics.compaction_ring_capacity + 3) |index| {
        compactor.traceEvent(.{ .turn_id = 11 }, .decision, "decision=compact index={d}", .{index});
    }
    const wrapped = try TestWriter.create();
    defer wrapped.destroy();
    try writeCompaction(&wrapped.records);
    var wrapped_trace = try wrapped.trace();
    defer wrapped_trace.deinit();
    try std.testing.expectEqual(@as(i64, 3), try testInt(try wrapped_trace.one("compaction"), "overwritten_before"));
    try std.testing.expectEqual(diagnostics.compaction_ring_capacity, wrapped_trace.count("compaction_event"));
}

test "trace model catalog records events and its problems" {
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();
    const StubApp = struct {};
    var stub: StubApp = .{};

    const empty = try TestWriter.create();
    defer empty.destroy();
    try writeModelCatalog(&empty.records, &stub);
    var empty_trace = try empty.trace();
    defer empty_trace.deinit();
    const none = try empty_trace.one("model_catalog");
    try std.testing.expectEqual(@as(i64, 0), try testInt(none, "events"));
    try expectAbsent(none, "cache");

    diagnostics.recordModelCatalogEvent(true, .load, "outcome=failed category={s} status={d}", .{ "transport", @as(u16, 503) });
    diagnostics.recordModelCatalogEvent(true, .lookup, "outcome=cache_failed model={s}", .{"moonshotai/kimi-k3"});
    diagnostics.recordModelCatalogEvent(false, .load, "outcome=ready entries={d}", .{41});
    diagnostics.recordModelCatalogEvent(true, .image_gate, "model={s} image_support=unknown err=ModelImageCapabilityUnavailable", .{"moonshotai/kimi-k3"});

    const w = try TestWriter.create();
    defer w.destroy();
    try writeModelCatalog(&w.records, &stub);
    var trace = try w.trace();
    defer trace.deinit();
    try std.testing.expectEqual(@as(i64, 4), try testInt(try trace.one("model_catalog"), "events"));
    const load = try trace.nth("model_catalog_event", 0);
    try std.testing.expectEqualStrings("load", try testString(load, "event"));
    try std.testing.expect(try testBool(load, "failed"));
    try std.testing.expectEqualStrings("outcome=failed category=transport status=503", try testString(load, "detail"));
    try std.testing.expectEqual(@as(i64, 1), try testInt(load, "sequence"));
    const ready = try trace.nth("model_catalog_event", 2);
    try std.testing.expect(!try testBool(ready, "failed"));
    const gate = try trace.nth("model_catalog_event", 3);
    try std.testing.expectEqualStrings("image_gate", try testString(gate, "event"));
    try std.testing.expectEqualStrings("model=moonshotai/kimi-k3 image_support=unknown err=ModelImageCapabilityUnavailable", try testString(gate, "detail"));

    const problems = try TestWriter.create();
    defer problems.destroy();
    try writeModelCatalogProblems(&problems.records);
    try std.testing.expectEqual(@as(usize, 3), problems.records.count);
    var problem_trace = try problems.trace();
    defer problem_trace.deinit();
    const newest = try problem_trace.nth("problem", 0);
    try std.testing.expectEqualStrings("model_catalog", try testString(newest, "kind"));
    try std.testing.expectEqualStrings("image_gate", try testString(newest, "event"));
    try std.testing.expectEqualStrings("load", try testString(try problem_trace.nth("problem", 2), "event"));
    try expectNotIn(problems.out.written(), "outcome=ready");
}

test "trace model catalog records cache state and failure detail" {
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();
    const Snapshot = struct {
        state: []const u8,
        entries: usize,
        last_attempt_age_ms: ?i64,
        failure_category: ?[]const u8,
        failure_http_status: ?std.http.Status,
        failure_retryable: bool,
        anonymous_fallback: bool,
    };
    const CacheStub = struct {
        snapshot: Snapshot,
        fn snapshotForTrace(self: *@This()) Snapshot {
            return self.snapshot;
        }
    };
    const StubApp = struct { model_cache: CacheStub };

    var stub: StubApp = .{ .model_cache = .{ .snapshot = .{
        .state = "failed",
        .entries = 0,
        .last_attempt_age_ms = null,
        .failure_category = "transport",
        .failure_http_status = .service_unavailable,
        .failure_retryable = true,
        .anonymous_fallback = true,
    } } };
    const failed = try TestWriter.create();
    defer failed.destroy();
    try writeModelCatalog(&failed.records, &stub);
    var failed_trace = try failed.trace();
    defer failed_trace.deinit();
    const failed_cache = try testObject(try failed_trace.one("model_catalog"), "cache");
    try std.testing.expectEqualStrings("failed", try testString(failed_cache, "state"));
    try std.testing.expectEqual(@as(i64, 0), try testInt(failed_cache, "entries"));
    try std.testing.expectEqualStrings("transport", try testString(failed_cache, "failure"));
    try std.testing.expect(try testBool(failed_cache, "retryable"));
    try std.testing.expectEqual(@as(i64, 503), try testInt(failed_cache, "http_status"));
    try std.testing.expect(try testBool(failed_cache, "anonymous_fallback"));
    try expectAbsent(failed_cache, "last_attempt_age_ms");

    stub.model_cache.snapshot = .{
        .state = "ready",
        .entries = 41,
        .last_attempt_age_ms = 12_500,
        .failure_category = null,
        .failure_http_status = null,
        .failure_retryable = false,
        .anonymous_fallback = false,
    };
    const ready = try TestWriter.create();
    defer ready.destroy();
    try writeModelCatalog(&ready.records, &stub);
    var ready_trace = try ready.trace();
    defer ready_trace.deinit();
    const ready_cache = try testObject(try ready_trace.one("model_catalog"), "cache");
    try std.testing.expectEqual(@as(i64, 41), try testInt(ready_cache, "entries"));
    try std.testing.expectEqual(@as(i64, 12_500), try testInt(ready_cache, "last_attempt_age_ms"));
    try expectAbsent(ready_cache, "failure");
    try expectAbsent(ready_cache, "retryable");
}

test "trace report file uses a private randomized jsonl path" {
    const alloc = std.testing.allocator;
    const path = try writeFile(alloc, "{\"type\":\"end\",\"records\":0}\n");
    defer alloc.free(path);
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};
    const second = try writeFile(alloc, "x\n");
    defer alloc.free(second);
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, second) catch {};

    try std.testing.expect(std.mem.find(u8, path, "fx-trace-") != null);
    try expectEndsWith(path, ".jsonl");
    try std.testing.expect(!std.mem.eql(u8, path, second));
    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(u64, 27), stat.size);
    if (builtin.target.os.tag != .windows) {
        try std.testing.expectEqual(@as(std.posix.mode_t, 0), stat.permissions.toMode() & 0o077);
    }
}

test "trace auth state keeps missing and loaded status text" {
    const alloc = std.testing.allocator;
    const auth_runtime = @import("../auth/auth_runtime.zig");
    const credentials = @import("../auth/credentials.zig");
    var app = struct { auth: auth_runtime.Runtime = .{} }{};
    defer app.auth.deinit(alloc);

    const missing = try TestWriter.create();
    defer missing.destroy();
    try missing.records.begin("current_state");
    try writeAuthState(&missing.records, &app);
    try missing.records.end();
    try std.testing.expectEqualStrings(
        "{\"type\":\"current_state\",\"auth\":{\"source\":\"missing\",\"refreshable\":false,\"gateway_team\":\"unknown\"}}\n",
        missing.out.written(),
    );

    var credential = credentials.Credential{
        .token = try alloc.dupe(u8, "token"),
        .source = .fx_login,
    };
    defer credential.deinit(alloc);
    _ = app.auth.adoptCredential(alloc, &credential);
    const loaded = try TestWriter.create();
    defer loaded.destroy();
    try loaded.records.begin("current_state");
    try writeAuthState(&loaded.records, &app);
    try loaded.records.end();
    try std.testing.expectEqualStrings(
        "{\"type\":\"current_state\",\"auth\":{\"source\":\"fx login\",\"refreshable\":true,\"gateway_team\":\"unset\"}}\n",
        loaded.out.written(),
    );
}

test "trace session title reports the retained generation outcome" {
    const alloc = std.testing.allocator;
    var app = struct {
        main_agent: struct {
            session_persistence: app_session_runtime.Persistence = .{},
            session_title: std.ArrayList(u8) = .empty,
        } = .{},
        session_title_generation: bool = true,

        pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
            return &self.main_agent;
        }
    }{};
    defer app.agent().session_persistence.deinit(alloc);
    defer app.agent().session_title.deinit(alloc);

    const idle = try TestWriter.create();
    defer idle.destroy();
    try writeSessionTitle(&idle.records, &app);
    var idle_trace = try idle.trace();
    defer idle_trace.deinit();
    const idle_record = try idle_trace.one("session_title");
    try std.testing.expect(try testBool(idle_record, "setting"));
    try expectAbsent(idle_record, "title");
    try std.testing.expectEqualStrings("none", try testString(try testObject(idle_record, "generation"), "status"));

    const generation = &app.agent().session_persistence.title_generation;
    generation.last.status = .failed;
    generation.last.reason = .transport_error;
    generation.last.detail = "ConnectionRefused";
    generation.last.elapsed_ms = 15001;
    const model = "openai/gpt-5.6-luna";
    @memcpy(generation.last.model_buf[0..model.len], model);
    generation.last.model_len = model.len;
    const session_id = "abc123sess";
    @memcpy(generation.last.session_buf[0..session_id.len], session_id);
    generation.last.session_len = session_id.len;

    const failed = try TestWriter.create();
    defer failed.destroy();
    try writeSessionTitle(&failed.records, &app);
    try writeSessionTitleProblem(&failed.records, &app);
    var failed_trace = try failed.trace();
    defer failed_trace.deinit();
    const failed_generation = try testObject(try failed_trace.one("session_title"), "generation");
    try std.testing.expectEqualStrings("failed", try testString(failed_generation, "status"));
    try std.testing.expectEqualStrings("abc123sess", try testString(failed_generation, "session"));
    try std.testing.expectEqualStrings("openai/gpt-5.6-luna", try testString(failed_generation, "model"));
    try std.testing.expectEqualStrings("transport_error", try testString(failed_generation, "reason"));
    try std.testing.expectEqualStrings("ConnectionRefused", try testString(failed_generation, "detail"));
    try std.testing.expectEqual(@as(i64, 15001), try testInt(failed_generation, "elapsed_ms"));
    const problem = try failed_trace.one("problem");
    try std.testing.expectEqualStrings("session_title", try testString(problem, "kind"));
    try std.testing.expectEqualStrings("failed", try testString(problem, "status"));
    try std.testing.expectEqualStrings("transport_error", try testString(problem, "reason"));

    generation.last.status = .installed;
    generation.last.reason = null;
    generation.last.detail = "";
    try app.agent().session_title.appendSlice(alloc, "Fix renderer lag PASSWORD=abcdefghijklmnop");
    const installed = try TestWriter.create();
    defer installed.destroy();
    try writeSessionTitle(&installed.records, &app);
    try writeSessionTitleProblem(&installed.records, &app);
    var installed_trace = try installed.trace();
    defer installed_trace.deinit();
    const installed_record = try installed_trace.one("session_title");
    try std.testing.expectEqualStrings("Fix renderer lag PASSWORD=[redacted]", try testString(installed_record, "title"));
    try std.testing.expectEqualStrings("installed", try testString(try testObject(installed_record, "generation"), "status"));
    try std.testing.expectEqual(@as(usize, 0), installed_trace.count("problem"));
}

test "trace tool calls keep outcomes and mask obvious secrets" {
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();
    const fixtures = [_]struct {
        name: []const u8,
        outcome: diagnostics.ToolCallOutcome,
        args: []const u8,
        result: []const u8,
        subagent_id: u64 = 0,
    }{
        .{ .name = "read_file", .outcome = .succeeded, .args = "{\"path\":\"README.md\"}", .result = "read ok" },
        .{ .name = "edit_file", .outcome = .rejected, .args = "{}", .result = "not unique" },
        .{ .name = "shell", .outcome = .command_failed, .args = "{}", .result = "exit 7" },
        .{ .name = "read_file", .outcome = .tool_failed, .args = "{}", .result = "missing" },
        .{ .name = "run_command", .outcome = .runtime_failed, .args = "{\"command\":\"AI_GATEWAY_API_KEY=abcdefghijklmnop zig build\"}", .result = "failed with PASSWORD=abcdefghijklmnop", .subagent_id = 3 },
    };
    for (fixtures, 0..) |fixture, index| {
        var call: diagnostics.ToolCallMetric = .{
            .started_at_ms = @intCast(1000 + index),
            .duration_ms = @intCast(index + 1),
            .outcome = fixture.outcome,
            .subagent_id = fixture.subagent_id,
        };
        call.setName(fixture.name);
        call.setArgs(fixture.args);
        call.setResult(fixture.result);
        diagnostics.recordToolCall(call);
    }

    const w = try TestWriter.create();
    defer w.destroy();
    try writeToolCalls(&w.records, &.{});
    try writeToolProblems(&w.records);
    var trace = try w.trace();
    defer trace.deinit();
    try expectNotIn(w.out.written(), "abcdefghijklmnop");

    const summary = try trace.one("tool_calls");
    try std.testing.expectEqual(@as(i64, 5), try testInt(summary, "retained"));
    const outcomes = try testObject(summary, "outcomes");
    inline for (.{ "succeeded", "rejected", "command_failed", "tool_failed", "runtime_failed" }) |name| {
        try std.testing.expectEqual(@as(i64, 1), try testInt(outcomes, name));
    }
    try std.testing.expectEqual(@as(i64, 15), try testInt(summary, "total_ms"));
    try std.testing.expectEqual(@as(i64, 5), try testInt(try testObject(summary, "session"), "calls"));
    try std.testing.expect(try testBool(summary, "complete"));
    try std.testing.expectEqual(@as(usize, 5), trace.count("tool_call"));

    const first = try trace.nth("tool_call", 0);
    try std.testing.expectEqualStrings("read_file", try testString(first, "name"));
    try std.testing.expectEqualStrings("succeeded", try testString(first, "outcome"));
    try std.testing.expectEqualStrings("parent", try testString(first, "source"));
    try expectAbsent(first, "subagent_id");
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", try testString(first, "args"));
    try std.testing.expectEqualStrings("read ok", try testString(first, "result_preview"));
    try expectAbsent(first, "result");
    const failed = try trace.nth("tool_call", 4);
    try std.testing.expectEqualStrings("run_command", try testString(failed, "name"));
    try std.testing.expectEqualStrings("runtime_failed", try testString(failed, "outcome"));
    try std.testing.expectEqualStrings("subagent", try testString(failed, "source"));
    try std.testing.expectEqual(@as(i64, 3), try testInt(failed, "subagent_id"));
    try std.testing.expectEqual(@as(i64, 5), try testInt(failed, "duration_ms"));
    try expectStartsWith(try testString(failed, "args"), "{\"command\":\"AI_GATEWAY_API_KEY=[redacted]");
    try std.testing.expectEqualStrings("failed with PASSWORD=[redacted]", try testString(failed, "result"));
    try expectAbsent(failed, "result_preview");

    // Problems list the four failures, newest first.
    try std.testing.expectEqual(@as(usize, 4), trace.count("problem"));
    const newest = try trace.nth("problem", 0);
    try std.testing.expectEqualStrings("tool_call", try testString(newest, "kind"));
    const newest_call = try testObject(newest, "call");
    try std.testing.expectEqualStrings("run_command", try testString(newest_call, "name"));
    try std.testing.expectEqualStrings("runtime_failed", try testString(newest_call, "outcome"));
    try std.testing.expectEqualStrings("edit_file", try testString(try testObject(try trace.nth("problem", 3), "call"), "name"));
}

test "trace successful tool calls keep only a short result preview" {
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();
    var call: diagnostics.ToolCallMetric = .{ .started_at_ms = 3000, .duration_ms = 1, .outcome = .succeeded };
    call.setName("read_file");
    call.setArgs("{\"path\":\"README.md\"}");
    call.setResult("<path>README.md</path>\n<content>\n# fx\n\nlong body line\n</content>");
    diagnostics.recordToolCall(call);
    var long: diagnostics.ToolCallMetric = .{ .started_at_ms = 3001, .duration_ms = 1, .outcome = .succeeded };
    long.setName("shell");
    long.setResult(text_utils.repeat("\xc3\xa9", 200));
    diagnostics.recordToolCall(long);

    const w = try TestWriter.create();
    defer w.destroy();
    try writeToolCalls(&w.records, &.{});
    var trace = try w.trace();
    defer trace.deinit();
    const record = try trace.nth("tool_call", 0);
    try std.testing.expectEqualStrings("# fx", try testString(record, "result_preview"));
    try expectNotIn(w.out.written(), "<path>README.md</path>");
    try expectNotIn(w.out.written(), "long body line");
    const long_record = try trace.nth("tool_call", 1);
    const preview = try testString(long_record, "result_preview");
    try std.testing.expectEqual(result_preview_max_bytes, preview.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(preview));
    try std.testing.expectEqual(@as(i64, 400), try testInt(long_record, "result_bytes"));
    try expectAbsent(long_record, "args");
}

test "trace tool payloads cut at the ring's bound keep whole characters" {
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();
    const exact: [tool_args_max_bytes]u8 = @splat('a');
    const over: [tool_args_max_bytes + 1]u8 = @splat('b');
    // 1199 bytes of 'c', then a three-byte character that the ring cuts after its first byte.
    const cut = text_utils.repeat("c", tool_args_max_bytes - 1) ++ "\xe2\x94\x80";
    for ([_][]const u8{ &exact, &over, cut }, 0..) |args, index| {
        var call: diagnostics.ToolCallMetric = .{ .started_at_ms = @intCast(10 + index), .outcome = .rejected };
        call.setName("edit_file");
        call.setArgs(args);
        call.setResult("x");
        diagnostics.recordToolCall(call);
    }
    const w = try TestWriter.create();
    defer w.destroy();
    try writeToolCalls(&w.records, &.{});
    var trace = try w.trace();
    defer trace.deinit();

    const whole = try trace.nth("tool_call", 0);
    try std.testing.expectEqual(tool_args_max_bytes, (try testString(whole, "args")).len);
    try std.testing.expectEqual(@as(i64, tool_args_max_bytes), try testInt(whole, "args_bytes"));
    try expectAbsent(whole, "args_omitted_bytes");
    const one_over = try trace.nth("tool_call", 1);
    try std.testing.expectEqual(tool_args_max_bytes, (try testString(one_over, "args")).len);
    try std.testing.expectEqual(@as(i64, tool_args_max_bytes + 1), try testInt(one_over, "args_bytes"));
    try std.testing.expectEqual(@as(i64, 1), try testInt(one_over, "args_omitted_bytes"));
    const split = try trace.nth("tool_call", 2);
    const split_args = try testString(split, "args");
    try std.testing.expectEqual(tool_args_max_bytes - 1, split_args.len);
    try expectNotIn(split_args, "\\x");
    try std.testing.expectEqual(@as(i64, tool_args_max_bytes + 2), try testInt(split, "args_bytes"));
    try std.testing.expectEqual(@as(i64, 3), try testInt(split, "args_omitted_bytes"));
}

test "trace web_fetch calls carry no URL or result" {
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();
    var call: diagnostics.ToolCallMetric = .{ .started_at_ms = 4000, .duration_ms = 3, .outcome = .succeeded };
    call.setName("web_fetch");
    call.setArgs("{\"url\":\"https://example.com/docs\"}");
    call.setResult("<content>\nFETCHED_PAGE_SECRET_RAW\nEXTRACTED_RESULT_SECRET\n</content>");
    diagnostics.recordToolCall(call);

    const w = try TestWriter.create();
    defer w.destroy();
    try writeToolCalls(&w.records, &.{});
    var trace = try w.trace();
    defer trace.deinit();
    const record = try trace.one("tool_call");
    try std.testing.expectEqualStrings("web_fetch", try testString(record, "name"));
    try std.testing.expectEqualStrings("parent", try testString(record, "source"));
    for ([_][]const u8{ "args", "args_bytes", "result", "result_preview", "result_bytes" }) |key| {
        try expectAbsent(record, key);
    }
    for ([_][]const u8{ "example.com", "FETCHED_PAGE_SECRET_RAW", "EXTRACTED_RESULT_SECRET" }) |secret| {
        try expectNotIn(w.out.written(), secret);
    }
}

test "trace web search calls hide provider names and payloads" {
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();
    var calls = [_]types.ToolCall{
        .{ .id = "call_exa", .name = "exa_search", .arguments_json = "{\"query\":\"PROVIDER_ARGUMENT_SECRET\"}", .provenance = .provider_executed },
        .{ .id = "call_parallel", .name = "parallel_search", .arguments_json = "{}", .provenance = .provider_executed },
        .{ .id = "call_pending", .name = "perplexity_search", .arguments_json = "{}", .provenance = .provider_executed },
        .{ .id = "call_local", .name = "read_file", .arguments_json = "{}", .provenance = .fx_local },
    };
    var results = [_]types.PersistedToolResult{
        .{
            .tool_call_id = @constCast("call_parallel"),
            .tool_name = @constCast("parallel_search"),
            .status = .failure,
            .output = @constCast("PROVIDER_RESULT_SECRET"),
            .output_bytes = 22,
            .stored_output_bytes = 22,
            .provider_native = true,
        },
        .{
            .tool_call_id = @constCast("call_exa"),
            .tool_name = @constCast("exa_search"),
            .status = .success,
            .output = @constCast("{\"results\":[]}"),
            .output_bytes = 14,
            .stored_output_bytes = 14,
            .provider_native = true,
        },
    };
    var steps = [_]types.ToolExecutionStep{.{ .tool_calls = &calls, .tool_results = &results }};
    const history = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("search") },
        .assistant = @constCast("answer"),
        .execution = .{ .tool_steps = &steps },
    } }};

    const w = try TestWriter.create();
    defer w.destroy();
    try writeToolCalls(&w.records, &history);
    var trace = try w.trace();
    defer trace.deinit();
    const summary = try trace.one("tool_calls");
    try std.testing.expectEqual(@as(i64, 0), try testInt(summary, "retained"));
    try std.testing.expectEqual(@as(i64, 3), try testInt(summary, "web_search_retained"));
    try std.testing.expectEqualStrings("ok", try testString(try trace.nth("web_search_call", 0), "status"));
    try std.testing.expectEqualStrings("err", try testString(try trace.nth("web_search_call", 1), "status"));
    try std.testing.expectEqualStrings("pending", try testString(try trace.nth("web_search_call", 2), "status"));
    for ([_][]const u8{ "call_", "exa_search", "parallel_search", "perplexity_search", "read_file", "PROVIDER_ARGUMENT_SECRET", "PROVIDER_RESULT_SECRET" }) |hidden| {
        try expectNotIn(w.out.written(), hidden);
    }
}

test "trace text normalizes internal search aliases" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeTraceTextNeutralized(
        &out.writer,
        "name=exa_search call_id=exa_search_0 fallback=parallel_search legacy=perplexity_search visible=web_search",
    );
    try std.testing.expectEqualStrings(
        "name=web_search call_id=web_search_0 fallback=web_search legacy=web_search visible=web_search",
        out.written(),
    );
}

test "trace provider tool projection keeps the most recent bounded calls" {
    var calls: [diagnostics.tool_call_ring_capacity + 1]types.ToolCall = undefined;
    for (&calls, 0..) |*call, index| {
        call.* = .{
            .id = if (index == 0) "oldest" else if (index + 1 == calls.len) "newest" else "middle",
            .name = "exa_search",
            .arguments_json = "{}",
            .provenance = .provider_executed,
        };
    }
    var steps = [_]types.ToolExecutionStep{.{ .tool_calls = &calls }};
    const history = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("search") },
        .assistant = @constCast("answer"),
        .execution = .{ .tool_steps = &steps },
    } }};
    var summaries: [diagnostics.tool_call_ring_capacity]ProviderToolCallSummary = undefined;
    const count = projectProviderToolCalls(&history, &summaries);
    try std.testing.expectEqual(diagnostics.tool_call_ring_capacity, count);
    try std.testing.expectEqualStrings("middle", summaries[0].call_id);
    try std.testing.expectEqualStrings("newest", summaries[count - 1].call_id);
}

test "trace network calls keep web search counts, stop reasons, and schema diagnostics" {
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();
    var search: diagnostics.NetworkCall = .{
        .kind = .web_search,
        .started_at_ms = 3000,
        .duration_ms = 11,
        .status = 200,
        .input_tokens = 12,
        .output_tokens = 34,
        .is_web_search = true,
        .web_search_requests = 2,
        .subagent_id = 4,
    };
    search.setModel("gateway/native-search-worker");
    search.setTerminalStopReason("max_tokens");
    diagnostics.recordNetworkCall(search);
    var stopped: diagnostics.NetworkCall = .{ .started_at_ms = 3500, .duration_ms = 9, .status = 200 };
    stopped.setModel("google/gemini-4-argon");
    stopped.setTerminalStopReason("other");
    stopped.setProviderStopReason("UNEXPECTED_TOOL_CALL");
    diagnostics.recordNetworkCall(stopped);
    var refused: diagnostics.NetworkCall = .{
        .started_at_ms = 5000,
        .duration_ms = 17,
        .status = 400,
        .response_bytes = 91,
        .turn_id = 12,
        .step_id = 34,
    };
    refused.setModel("zai/glm-5.2-fast");
    refused.setError("GatewayBadRequest");
    refused.setGatewayErrorMessage("Invalid input");
    refused.setGatewaySchemaDiagnostic("path=prompt.0.content expected=string received=array");
    refused.setGatewayRequestShape("bytes=123 prompt_count=1 prompt.0 role=system content=array tools=array tools_count=0 toolChoice=auto");
    diagnostics.recordNetworkCall(refused);

    const w = try TestWriter.create();
    defer w.destroy();
    try writeNetwork(&w.records);
    try writeNetworkProblems(&w.records);
    var trace = try w.trace();
    defer trace.deinit();

    const summary = try trace.one("network");
    try std.testing.expectEqual(@as(i64, 3), try testInt(summary, "retained"));
    try std.testing.expectEqual(@as(i64, 2), try testInt(summary, "ok"));
    try std.testing.expectEqual(@as(i64, 1), try testInt(summary, "errors"));
    try std.testing.expectEqual(@as(i64, 12), try testInt(summary, "avg_ms"));
    try std.testing.expectEqual(@as(i64, 9), try testInt(summary, "min_ms"));
    try std.testing.expectEqual(@as(i64, 17), try testInt(summary, "max_ms"));

    const first = try trace.nth("network_call", 0);
    try std.testing.expectEqualStrings("web_search", try testString(first, "kind"));
    try std.testing.expectEqual(@as(i64, 2), try testInt(first, "web_search_requests"));
    try std.testing.expectEqualStrings("max_tokens", try testString(first, "stop_reason"));
    try std.testing.expectEqualStrings("subagent", try testString(first, "source"));
    try std.testing.expectEqual(@as(i64, 4), try testInt(first, "subagent_id"));
    try std.testing.expectEqual(@as(i64, 12), try testInt(first, "input_tokens"));
    try std.testing.expectEqual(@as(i64, 34), try testInt(first, "output_tokens"));
    try expectAbsent(first, "provider_stop_reason");
    const second = try trace.nth("network_call", 1);
    try std.testing.expectEqualStrings("gateway", try testString(second, "kind"));
    try std.testing.expectEqualStrings("other", try testString(second, "stop_reason"));
    try std.testing.expectEqualStrings("UNEXPECTED_TOOL_CALL", try testString(second, "provider_stop_reason"));
    try expectAbsent(second, "web_search_requests");
    const third = try trace.nth("network_call", 2);
    try std.testing.expectEqual(@as(i64, 400), try testInt(third, "status"));
    try std.testing.expectEqualStrings("GatewayBadRequest", try testString(third, "error"));
    try std.testing.expectEqual(@as(i64, 12), try testInt(third, "turn_id"));
    try std.testing.expectEqual(@as(i64, 34), try testInt(third, "step_id"));
    try std.testing.expectEqual(@as(i64, 91), try testInt(third, "response_bytes"));
    try std.testing.expectEqualStrings("Invalid input", try testString(third, "gateway_error"));
    try std.testing.expectEqualStrings("path=prompt.0.content expected=string received=array", try testString(third, "gateway_schema"));
    try expectStartsWith(try testString(third, "request_shape"), "bytes=123 prompt_count=1 prompt.0 role=system content=array");

    const problem = try trace.one("problem");
    try std.testing.expectEqualStrings("network_call", try testString(problem, "kind"));
    const problem_call = try testObject(problem, "call");
    try std.testing.expectEqual(@as(i64, 400), try testInt(problem_call, "status"));
    try std.testing.expectEqualStrings("zai/glm-5.2-fast", try testString(problem_call, "model"));
    try std.testing.expectEqualStrings("gateway", try testString(problem_call, "kind"));
}

test "trace network section reports session totals and window coverage" {
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();
    // More calls than the ring holds, so coverage must admit the eviction.
    var i: u64 = 0;
    while (i < diagnostics.network_ring_capacity + 2) : (i += 1) {
        var call: diagnostics.NetworkCall = .{
            .started_at_ms = 1_000 + @as(i64, @intCast(i)) * 1_000,
            .duration_ms = 100,
            .status = if (i == 0) 500 else 200,
            .turn_id = if (i < 2) 1 else 2,
        };
        call.setModel("openai/gpt-5.6-sol");
        diagnostics.recordNetworkCall(call);
    }
    const w = try TestWriter.create();
    defer w.destroy();
    try writeNetwork(&w.records);
    var trace = try w.trace();
    defer trace.deinit();
    const total = diagnostics.network_ring_capacity + 2;
    const summary = try trace.one("network");
    try std.testing.expectEqual(@as(i64, diagnostics.network_ring_capacity), try testInt(summary, "retained"));
    const session = try testObject(summary, "session");
    try std.testing.expectEqual(@as(i64, total), try testInt(session, "calls"));
    try std.testing.expectEqual(@as(i64, total - 1), try testInt(session, "ok"));
    try std.testing.expectEqual(@as(i64, 1), try testInt(session, "errors"));
    try std.testing.expectEqual(@as(i64, total * 100), try testInt(session, "total_ms"));
    try std.testing.expect(!try testBool(summary, "complete"));
    try std.testing.expectEqual(@as(i64, 3_000), try testInt(summary, "oldest_retained_at_ms"));
    try std.testing.expectEqual(@as(i64, 2), try testInt(summary, "turns_retained"));
    const turn_one = try trace.nth("network_turn", 0);
    try std.testing.expectEqual(@as(i64, 1), try testInt(turn_one, "turn_id"));
    try std.testing.expectEqual(@as(i64, 2), try testInt(turn_one, "calls"));
    try std.testing.expectEqual(@as(i64, 1), try testInt(turn_one, "errors"));
    const turn_two = try trace.nth("network_turn", 1);
    try std.testing.expectEqual(@as(i64, 32), try testInt(turn_two, "calls"));
    try std.testing.expectEqual(@as(i64, 0), try testInt(turn_two, "errors"));
    try std.testing.expectEqual(diagnostics.network_ring_capacity, trace.count("network_call"));
}

test "trace network section states complete coverage when nothing was evicted" {
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();
    const empty = try TestWriter.create();
    defer empty.destroy();
    try writeNetwork(&empty.records);
    var empty_trace = try empty.trace();
    defer empty_trace.deinit();
    const none = try empty_trace.one("network");
    try std.testing.expectEqual(@as(i64, 0), try testInt(none, "retained"));
    try std.testing.expect(try testBool(none, "complete"));
    try expectAbsent(none, "avg_ms");
    try expectAbsent(none, "min_ms");

    diagnostics.recordNetworkCall(.{ .started_at_ms = 5_000, .duration_ms = 10, .status = 200, .turn_id = 3 });
    const w = try TestWriter.create();
    defer w.destroy();
    try writeNetwork(&w.records);
    var trace = try w.trace();
    defer trace.deinit();
    const summary = try trace.one("network");
    try std.testing.expectEqual(@as(i64, 1), try testInt(try testObject(summary, "session"), "calls"));
    try std.testing.expect(try testBool(summary, "complete"));
    try expectAbsent(summary, "oldest_retained_at");
}

test "trace tool section reports session totals and window coverage" {
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();
    var i: u64 = 0;
    while (i < diagnostics.tool_call_ring_capacity + 2) : (i += 1) {
        var call: diagnostics.ToolCallMetric = .{
            .started_at_ms = 1_000 + @as(i64, @intCast(i)) * 100,
            .duration_ms = 50,
            .outcome = if (i == 0) .rejected else .succeeded,
        };
        call.setName("shell");
        diagnostics.recordToolCall(call);
    }
    const w = try TestWriter.create();
    defer w.destroy();
    try writeToolCalls(&w.records, &.{});
    var trace = try w.trace();
    defer trace.deinit();
    const total = diagnostics.tool_call_ring_capacity + 2;
    const summary = try trace.one("tool_calls");
    const session = try testObject(summary, "session");
    try std.testing.expectEqual(@as(i64, total), try testInt(session, "calls"));
    const session_outcomes = try testObject(session, "outcomes");
    try std.testing.expectEqual(@as(i64, total - 1), try testInt(session_outcomes, "succeeded"));
    try std.testing.expectEqual(@as(i64, 1), try testInt(session_outcomes, "rejected"));
    try std.testing.expectEqual(@as(i64, 0), try testInt(session_outcomes, "runtime_failed"));
    try std.testing.expectEqual(@as(i64, total * 50), try testInt(session, "total_ms"));
    try std.testing.expect(!try testBool(summary, "complete"));
    try std.testing.expectEqual(@as(i64, 0), try testInt(try testObject(summary, "outcomes"), "rejected"));

    diagnostics.resetForTest();
    var ok_call: diagnostics.ToolCallMetric = .{ .started_at_ms = 9_000, .duration_ms = 5, .outcome = .succeeded };
    ok_call.setName("read_file");
    diagnostics.recordToolCall(ok_call);
    const fresh = try TestWriter.create();
    defer fresh.destroy();
    try writeToolCalls(&fresh.records, &.{});
    var fresh_trace = try fresh.trace();
    defer fresh_trace.deinit();
    try std.testing.expect(try testBool(try fresh_trace.one("tool_calls"), "complete"));
}

test "trace last shutdown reads a report or says why it cannot" {
    const cases = [_]struct { contents: ?[]const u8, status: []const u8 }{
        .{ .contents = null, .status = "none" },
        .{ .contents = "not json", .status = "unreadable" },
        .{ .contents = "[1,2]", .status = "unreadable" },
        .{ .contents = "\"text\"", .status = "unreadable" },
        .{ .contents = "{\"total_ms\":\"slow\",\"recorded_at_ms\":null,\"stages\":{\"name\":1}}", .status = "recorded" },
    };
    for (cases) |case| {
        const w = try TestWriter.create();
        defer w.destroy();
        try writeLastShutdown(&w.records, case.contents);
        var trace = try w.trace();
        defer trace.deinit();
        const record = try trace.one("last_shutdown");
        try std.testing.expectEqualStrings(case.status, try testString(record, "status"));
        try expectAbsent(record, "total_ms");
        try expectAbsent(record, "recorded_at");
        try expectAbsent(record, "stages");
    }

    const w = try TestWriter.create();
    defer w.destroy();
    try writeLastShutdown(&w.records,
        \\{"total_ms":42,"recorded_at_ms":1700000000000,"stages":[{"name":"flush","step_ms":12},{"name":7,"step_ms":"x"},3,{"name":"exit","step_ms":30}]}
    );
    var trace = try w.trace();
    defer trace.deinit();
    const record = try trace.one("last_shutdown");
    try std.testing.expectEqualStrings("recorded", try testString(record, "status"));
    try std.testing.expectEqual(@as(i64, 42), try testInt(record, "total_ms"));
    try std.testing.expectEqualStrings("2023-11-14T22:13:20.000Z", try testString(record, "recorded_at"));
    const stages = record.get("stages").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), stages.len);
    try std.testing.expectEqualStrings("flush", try testString(stages[0].object, "name"));
    try std.testing.expectEqual(@as(i64, 12), try testInt(stages[0].object, "step_ms"));
    try std.testing.expectEqual(@as(usize, 0), stages[1].object.count());
    try std.testing.expectEqualStrings("exit", try testString(stages[2].object, "name"));
}

test "trace interrupted turn keeps the in-flight tool and masks its arguments" {
    var args_buf: [tool_args_max_bytes + 40]u8 = @splat('x');
    const secret = "{\"command\":\"PASSWORD=abcdefghijklmnop make\",\"pad\":\"";
    @memcpy(args_buf[0..secret.len], secret);
    var read_name = "read_file".*;
    var search_name = "parallel_search".*;
    var completed_names = [_][]u8{ &read_name, &search_name };
    const history = [_]types.HistoryTurn{.{ .interrupted = .{
        .user = .{ .text = @constCast("go") },
        .tool_call = .{ .id = "call_1", .name = "exa_search", .arguments_json = &args_buf },
        .completed_tool_names = &completed_names,
    } }};
    const w = try TestWriter.create();
    defer w.destroy();
    try writeInterruptedTurn(&w.records, &history);
    try writeInterruptedTurnProblem(&w.records, &history);
    try writeInterruptedTurn(&w.records, &.{});
    var trace = try w.trace();
    defer trace.deinit();
    try expectNotIn(w.out.written(), "abcdefghijklmnop");
    const record = try trace.one("interrupted_turn");
    try std.testing.expectEqualStrings("web_search", try testString(record, "in_flight_tool"));
    const args = try testString(record, "in_flight_args");
    try expectStartsWith(args, "{\"command\":\"PASSWORD=[redacted]");
    try std.testing.expectEqual(@as(i64, tool_args_max_bytes + 40), try testInt(record, "in_flight_args_bytes"));
    const completed = record.get("completed_tools").?.array.items;
    try std.testing.expectEqualStrings("read_file", completed[0].string);
    try std.testing.expectEqualStrings("web_search", completed[1].string);
    const problem = try trace.one("problem");
    try std.testing.expectEqualStrings("interrupted_turn", try testString(problem, "kind"));
    try std.testing.expectEqualStrings("web_search", try testString(problem, "in_flight_tool"));
    try std.testing.expectEqual(@as(i64, 2), try testInt(problem, "completed_tools"));
}

test "trace permissions and MCP servers become records with errors masked" {
    const Status = struct {
        name: []const u8,
        state: enum { ready, failed, retrying, missing_env, invalid_env, idle },
        transport: enum { http, stdio },
        tools: usize,
        signed_in: bool,
        needs_login: bool,
        last_error: ?[]const u8 = null,
        missing: ?[]const u8 = null,
    };
    const StubApp = struct {
        statuses: []const Status,
        pub fn mcpHostStatuses(self: *@This(), _: std.mem.Allocator) !?[]const Status {
            return self.statuses;
        }
    };
    var stub: StubApp = .{ .statuses = &.{
        .{ .name = "ok", .state = .ready, .transport = .http, .tools = 3, .signed_in = true, .needs_login = false },
        .{ .name = "login", .state = .idle, .transport = .http, .tools = 0, .signed_in = false, .needs_login = true },
        .{ .name = "down", .state = .failed, .transport = .stdio, .tools = 0, .signed_in = false, .needs_login = false, .last_error = "token=abcdefghijklmnop refused" },
        .{ .name = "env", .state = .missing_env, .transport = .stdio, .tools = 0, .signed_in = false, .needs_login = false, .missing = "API_TOKEN" },
    } };
    const grants = [_]types.PermissionGrant{
        .{ .tool_name = @constCast("exa_search"), .target_path = @constCast("*") },
        .{ .tool_name = @constCast("shell"), .target_path = @constCast("zig build") },
    };
    const w = try TestWriter.create();
    defer w.destroy();
    try writePermissions(&w.records, &grants);
    try writeRuntimeContext(&w.records, &stub);
    try writeMcpHostProblems(&w.records, &stub);
    var trace = try w.trace();
    defer trace.deinit();
    try expectNotIn(w.out.written(), "abcdefghijklmnop");

    try std.testing.expectEqual(@as(i64, 2), try testInt(try trace.one("permissions"), "grants"));
    const first_grant = try trace.nth("permission_grant", 0);
    try std.testing.expectEqualStrings("web_search", try testString(first_grant, "tool"));
    try std.testing.expectEqualStrings("*", try testString(first_grant, "target"));
    try std.testing.expectEqualStrings("zig build", try testString(try trace.nth("permission_grant", 1), "target"));

    const context = try trace.one("runtime_context");
    try std.testing.expectEqual(@as(i64, 4), try testInt(context, "mcp_servers"));
    _ = try testBool(context, "tmux");
    _ = try testBool(context, "cmux");
    const ready = try trace.nth("mcp_server", 0);
    try std.testing.expectEqualStrings("ok", try testString(ready, "name"));
    try std.testing.expectEqualStrings("ready", try testString(ready, "state"));
    try std.testing.expectEqualStrings("http", try testString(ready, "transport"));
    try std.testing.expectEqual(@as(i64, 3), try testInt(ready, "tools"));
    try std.testing.expect(try testBool(ready, "signed_in"));
    try expectAbsent(ready, "error");
    try std.testing.expectEqualStrings("token=[redacted] refused", try testString(try trace.nth("mcp_server", 2), "error"));

    try std.testing.expectEqual(@as(usize, 3), trace.count("problem"));
    const login = try trace.nth("problem", 0);
    try std.testing.expectEqualStrings("mcp_server", try testString(login, "kind"));
    try std.testing.expectEqualStrings("needs_login", try testString(login, "issue"));
    try std.testing.expectEqualStrings("login", try testString(login, "name"));
    const down = try trace.nth("problem", 1);
    try std.testing.expectEqualStrings("failed", try testString(down, "issue"));
    try std.testing.expectEqualStrings("token=[redacted] refused", try testString(down, "error"));
    const env = try trace.nth("problem", 2);
    try std.testing.expectEqualStrings("missing_env", try testString(env, "issue"));
    try std.testing.expectEqualStrings("API_TOKEN", try testString(env, "variable"));

    const NoHost = struct {};
    var no_host: NoHost = .{};
    const bare = try TestWriter.create();
    defer bare.destroy();
    try writeRuntimeContext(&bare.records, &no_host);
    var bare_trace = try bare.trace();
    defer bare_trace.deinit();
    try std.testing.expectEqual(@as(i64, 0), try testInt(try bare_trace.one("runtime_context"), "mcp_servers"));
}

test "trace log tail keeps the newest lines, masked, and skips logs it cannot read" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    const missing_path = try alloc.print("{s}/missing.log", .{dir});
    defer alloc.free(missing_path);
    const empty_path = try alloc.print("{s}/empty.log", .{dir});
    defer alloc.free(empty_path);
    const big_path = try alloc.print("{s}/big.log", .{dir});
    defer alloc.free(big_path);
    (try tmp.dir.createFile(io_mod.getIo(), "empty.log", .{})).close(io_mod.getIo());
    {
        var big: std.Io.Writer.Allocating = .init(alloc);
        defer big.deinit();
        for (0..400) |index| try big.writer.print("line {d} exa_search AI_GATEWAY_API_KEY=abcdefghijklmnop\n", .{index});
        var file = try tmp.dir.createFile(io_mod.getIo(), "big.log", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), big.written());
    }

    const w = try TestWriter.create();
    defer w.destroy();
    try writeTraceLog(&w.records, missing_path);
    try writeTraceLog(&w.records, empty_path);
    try std.testing.expectEqual(@as(usize, 0), w.records.count);
    try writeTraceLog(&w.records, big_path);
    var trace = try w.trace();
    defer trace.deinit();
    const summary = try trace.one("trace_log");
    try std.testing.expectEqualStrings(big_path, try testString(summary, "path"));
    try std.testing.expectEqual(@as(i64, trace_tail_bytes), try testInt(summary, "bytes"));
    try std.testing.expect(try testBool(summary, "older_lines_cut"));
    try std.testing.expectEqual(@as(i64, trace_max_lines), try testInt(summary, "lines"));
    try std.testing.expectEqual(trace_max_lines, trace.count("trace_log_line"));
    const last = try trace.nth("trace_log_line", trace_max_lines - 1);
    try std.testing.expectEqualStrings("line 399 web_search AI_GATEWAY_API_KEY=[redacted]", try testString(last, "text"));
    try expectNotIn(w.out.written(), "abcdefghijklmnop");
}

/// Seeded text made of pieces that stress JSON escaping, UTF-8 repair, and
/// secret masking, with an occasional raw byte.
fn randomTraceText(random: std.Random, buf: []u8) []const u8 {
    const pieces = [_][]const u8{
        "a",    " ",        "\"",           "\\",       "\n",         "\r",        "\t",               "\x00",     "\x1f",
        "\x7f", "/",        "{",            "]",        "\u{e9}",     "\u{754c}",  "\u{1f600}",        "\u{2028}", "\xff",
        "\xc3", "\xe2\x94", "\xed\xa0\x80", "\xc0\x80", "exa_search", "PASSWORD=", "abcdefghijklmnop", "Bearer ",  "sk-",
    };
    var len: usize = 0;
    const count = random.uintAtMost(usize, 24);
    var byte: [1]u8 = undefined;
    for (0..count) |_| {
        const piece: []const u8 = if (random.uintLessThan(u8, 8) == 0) blk: {
            byte[0] = random.int(u8);
            break :blk &byte;
        } else pieces[random.uintLessThan(usize, pieces.len)];
        if (len + piece.len > buf.len) break;
        @memcpy(buf[len..][0..piece.len], piece);
        len += piece.len;
    }
    return buf[0..len];
}

test "trace text fields read back as the masked, valid UTF-8 text for seeded random input" {
    // The seeds are fixed, so a failure replays; the failing seed is printed.
    const base_seed: u64 = 0x7472_6163_656a_736c;
    for (0..2000) |iteration| {
        const seed = base_seed +% iteration;
        var prng = std.Random.DefaultPrng.init(seed);
        var buf: [256]u8 = undefined;
        const input = randomTraceText(prng.random(), &buf);
        checkTextRoundTrip(input) catch |err| {
            std.debug.print("trace property failed for seed 0x{x}\n", .{seed});
            return err;
        };
    }
}

/// Writes `input` through every string helper and checks what a reader gets.
fn checkTextRoundTrip(input: []const u8) !void {
    const w = try TestWriter.create();
    defer w.destroy();
    try w.records.begin("probe");
    try w.records.text("plain", input);
    try w.records.masked("masked", input);
    try w.records.text("neutral", try neutralized(w.records.arena, input));
    try w.records.beginArray("items");
    try w.records.itemText(input);
    try w.records.endArray();
    try w.records.end();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.out.written(), "\n"));

    var trace = try w.trace();
    defer trace.deinit();
    const a = trace.arena.allocator();
    const record = try trace.one("probe");
    const plain = try text_utils.dupeValidUtf8(a, input);
    try std.testing.expectEqualStrings(plain, try testString(record, "plain"));
    try std.testing.expectEqualStrings(plain, record.get("items").?.array.items[0].string);
    const masked = try text_utils.dupeValidUtf8(a, try text_utils.maskSecrets(a, input));
    try std.testing.expectEqualStrings(masked, try testString(record, "masked"));
    const neutral = try testString(record, "neutral");
    try std.testing.expect(std.mem.count(u8, neutral, "web_search") >= std.mem.count(u8, input, "web_search"));
    if (std.unicode.utf8ValidateSlice(input)) try std.testing.expectEqualStrings(input, try testString(record, "plain"));
}

fn fuzzRecordText(_: void, smith: *std.testing.Smith) !void {
    var buffer: [2048]u8 = undefined;
    const len = smith.slice(&buffer);
    try checkTextRoundTrip(buffer[0..len]);
}

test "trace records stay one valid JSON line for fuzzed text" {
    try std.testing.fuzz({}, fuzzRecordText, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "plain words",
            "quote \" backslash \\ line\nbreak\r\ttab \x00\x1f\x7f",
            "caf\xc3\xa9 \xe2\x80 \xff\xfe \xc0\x80 \xed\xa0\x80 \xf0\x9f\x98",
            "AI_GATEWAY_API_KEY=abcdefghijklmnop exa_search \u{2028}",
        }) ++ @import("fuzz_corpus").trace_record_text.*),
    });
}

test "trace stays well formed with every ring full and a long transcript" {
    const alloc = std.testing.allocator;
    const compactor = @import("../compactor/compactor.zig");
    diagnostics.resetForTest();
    defer diagnostics.resetForTest();
    const hostile = "AI_GATEWAY_API_KEY=abcdefghijklmnop \"quoted\" \\ \xff\xc3 \u{2028}\n";
    const big = text_utils.repeat(hostile, 30);
    // Compaction and catalog details hold internal values only and are not
    // masked, so their text has no secret.
    const plain_big = text_utils.repeat("\"quoted\" \\ \xff\xc3 \u{2028}\n", 30);
    for (0..diagnostics.tool_call_ring_capacity + 1) |index| {
        var call: diagnostics.ToolCallMetric = .{
            .started_at_ms = @intCast(1_000 + index),
            .duration_ms = 7,
            .outcome = if (index % 2 == 0) .succeeded else .tool_failed,
        };
        call.setName("shell");
        call.setArgs(big);
        call.setResult(big);
        diagnostics.recordToolCall(call);
    }
    for (0..diagnostics.network_ring_capacity + 1) |index| {
        var call: diagnostics.NetworkCall = .{
            .started_at_ms = @intCast(2_000 + index),
            .duration_ms = 3,
            .status = if (index % 3 == 0) 503 else 200,
            .turn_id = index + 1,
        };
        call.setModel("openai/gpt-5.6-sol");
        call.setGatewayErrorMessage(hostile);
        call.setGatewayRequestShape(big);
        diagnostics.recordNetworkCall(call);
    }
    for (0..diagnostics.render_ring_capacity + 1) |index| diagnostics.recordRenderEvent(.commit, "{d} {s}", .{ index, big });
    for (0..diagnostics.compaction_ring_capacity + 1) |index| compactor.traceFailure(.{ .turn_id = index + 1 }, .retention_exhausted, "{d} {s}", .{ index, plain_big });
    // Each index comes first: the catalog ring folds identical events, and
    // a detail is cut at its bound.
    for (0..diagnostics.model_catalog_ring_capacity + 1) |index| diagnostics.recordModelCatalogEvent(true, .lookup, "{d} {s}", .{ index, plain_big });

    const entry_count = 10_000;
    const entries = try alloc.alloc(TestTranscriptEntry, entry_count);
    defer alloc.free(entries);
    for (entries, 0..) |*entry, index| {
        entry.* = .{ .raw_bytes = .{
            .id = @intCast(index + 1),
            .created_at_ms = @intCast(1_700_000_000_000 + index),
            .bytes = hostile ++ "\x1b[31mred\x1b[0m line\n",
        } };
    }
    var app = struct {
        main_agent: struct {
            worker: worker_runtime.WorkerRuntime = .{},
            stream: struct { active: bool = false } = .{},
            session: struct { agent: struct { history: std.ArrayList(types.HistoryTurn) = .empty } = .{} } = .{},
        } = .{},
        pub fn agent(self: anytype) @TypeOf(&self.main_agent) {
            return &self.main_agent;
        }
    }{};
    defer app.agent().worker.deinit(alloc);

    const started = io_mod.milliTimestamp();
    const w = try TestWriter.create();
    defer w.destroy();
    try writeHeader(&w.records, "stress", started);
    try writeProblems(&w.records, &app);
    try writeCompaction(&w.records);
    try writeNetwork(&w.records);
    try writeModelCatalog(&w.records, &struct {}{});
    try writeToolCalls(&w.records, &.{});
    try writeRendererEvents(&w.records);
    try writeTranscript(&w.records, entries);
    try writeEnd(&w.records);
    const elapsed = io_mod.milliTimestamp() - started;

    var trace = try w.trace();
    defer trace.deinit();
    std.debug.print("trace stress: {d} records, {d} bytes, written in {d} ms\n", .{ trace.records.len, w.out.written().len, elapsed });
    try expectNotIn(w.out.written(), "abcdefghijklmnop");
    try std.testing.expectEqual(@as(i64, @intCast(trace.records.len - 1)), try testInt(trace.records[trace.records.len - 1], "records"));
    try std.testing.expectEqual(diagnostics.tool_call_ring_capacity, trace.count("tool_call"));
    try std.testing.expectEqual(diagnostics.network_ring_capacity, trace.count("network_call"));
    try std.testing.expectEqual(diagnostics.render_ring_capacity, trace.count("renderer_event"));
    try std.testing.expectEqual(diagnostics.compaction_ring_capacity, trace.count("compaction_event"));
    try std.testing.expectEqual(diagnostics.model_catalog_ring_capacity, trace.count("model_catalog_event"));
    try std.testing.expectEqual(@as(usize, entry_count), trace.count("transcript_entry"));
    try std.testing.expectEqual(@as(i64, 1), try testInt(try trace.one("renderer_events"), "overwritten_before"));
    try std.testing.expectEqual(@as(i64, 1), try testInt(try trace.one("compaction"), "overwritten_before"));
    try std.testing.expect(!try testBool(try trace.one("tool_calls"), "complete"));
    try std.testing.expect(!try testBool(try trace.one("network"), "complete"));
    // 3 network, 5 tool, 3 compaction, and 3 catalog problems.
    try std.testing.expectEqual(@as(i64, 14), try testInt(try trace.one("problems"), "count"));
    try std.testing.expectEqual(@as(usize, 14), trace.count("problem"));
    const last_entry = try trace.nth("transcript_entry", entry_count - 1);
    const last_text = try testString(last_entry, "text");
    try expectStartsWith(last_text, "AI_GATEWAY_API_KEY=[redacted]");
    try std.testing.expect(std.mem.find(u8, last_text, "\\xff\\xc3") != null);
    try expectEndsWith(last_text, "\nred line");
}
