//! U03 to U05 and U10 lab: runs a script of host actions against a real
//! server process through `mcp.stdio.Process`. Requests go through the U02
//! request table and the U01 encoder, `detect` runs U04 version detection,
//! `tools` and `call` run the U05 catalog, and `listen` runs U10
//! subscriptions, so one run traces up to five machines ("stdio",
//! "request", "era", "catalog", "subscription") for TLC.
//! Everything the host sees is printed as JSON lines. Dev only; never moves
//! into fx.
//!
//! Usage: stdio_lab <trace-path> <script> [options] -- <server argv...>
//! Options: --max-attempts N, --grace-ms N, --term-ms N, --backoff-ms N,
//!          --max-line N, --idle-ms N, --hard-ms N, --protocol-version V
//!          (V adds the 2026 per-request _meta to every request, without detection),
//!          --preferred V1,V2 (modern versions, most preferred first), --legacy V,
//!          --probe-ms N, --max-pages N (the catalog's page limit)
//!
//! Script, one action per line (blank lines and lines starting with # are skipped):
//!   start | stop | reconnect
//!   detect                                       detect the era now and on every new process;
//!                                                later requests carry the chosen version
//!   era modern|legacy                            tell the stdio core the era by hand
//!   tools                                        the host needs the tool list (U05)
//!   call <name> [arguments-json]                 call a tool
//!   invalidate                                   mark the tool list stale
//!   send request|notification|response <json>   write a raw message
//!   request <method> [params-json]               send through the request table
//!   cancel <id>
//!   listen <sub> <filter>                        open subscription <sub> (0..3) with a filter: bits
//!                                                1 tools, 2 prompts, 4 resources (U10)
//!   unlisten <sub>                               cancel it: notifications/cancelled
//!   expect message|stderr|dropped|<state>|era-<era state>|catalog-idle|catalog-fresh|catalog-stale
//!          [timeout_ms]                          (default 10000)
//!   outcome <id> <outcome> [timeout_ms]          wait for a request's outcome
//!   drain <ms>                                   handle whatever arrives for that long
//!
//! Output lines: {"did":...} after each action, {"seen":...} for each thing
//! `next` returns, {"outcome":...} when a request ends, {"era":...} and
//! {"tools":...} for detection and catalog results, {"call":...} for each
//! tool call answer, {"sub":...} for what a subscription delivers, its
//! acknowledgment and its end, and one {"final":...}.
//! Exit codes: 0 the script ran, 1 an expectation wasn't met, 2 usage.

const std = @import("std");
const mcp = @import("mcp");

/// Trace code is compiled in.
pub const mcpv2_trace = true;
const core = mcp.core.stdio_conn;
const request = mcp.core.request;
const era = mcp.core.era;
const catalog = mcp.core.catalog;
const subscription = mcp.core.subscription;
const subscriptions = mcp.subscriptions;
const tools = mcp.tools;
const wire = mcp.wire;

const Options = struct {
    trace_path: []const u8,
    script_path: []const u8,
    argv: []const []const u8,
    config: core.Config = .{},
    timeouts: request.Timeouts = .{},
    max_line: usize = 16 * 1024 * 1024,
    protocol_version: ?[]const u8 = null,
    era: era.Config = .{},
    catalog: catalog.Config = .{},
};

fn parseOptions(arena: std.mem.Allocator, args: []const []const u8) !Options {
    if (args.len < 5) return error.Usage;
    var options: Options = .{ .trace_path = args[1], .script_path = args[2], .argv = &.{} };
    var i: usize = 3;
    while (i < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--")) {
            options.argv = args[i + 1 ..];
            break;
        }
        if (i + 1 >= args.len) return error.Usage;
        const flag = args[i];
        if (std.mem.eql(u8, flag, "--protocol-version")) {
            options.protocol_version = args[i + 1];
            continue;
        }
        if (std.mem.eql(u8, flag, "--legacy")) {
            options.era.legacy = try versionList(arena, args[i + 1]);
            continue;
        }
        if (std.mem.eql(u8, flag, "--preferred")) {
            options.era.preferred = try versionList(arena, args[i + 1]);
            continue;
        }
        const value = try std.fmt.parseInt(u32, args[i + 1], 10);
        if (std.mem.eql(u8, flag, "--max-attempts")) {
            options.config.max_attempts = @intCast(value);
        } else if (std.mem.eql(u8, flag, "--grace-ms")) {
            options.config.grace_ms = value;
        } else if (std.mem.eql(u8, flag, "--term-ms")) {
            options.config.term_ms = value;
        } else if (std.mem.eql(u8, flag, "--backoff-ms")) {
            options.config.backoff_ms = value;
            options.config.backoff_cap_ms = value * 4;
        } else if (std.mem.eql(u8, flag, "--max-line")) {
            options.max_line = value;
        } else if (std.mem.eql(u8, flag, "--idle-ms")) {
            options.timeouts.idle_ms = value;
        } else if (std.mem.eql(u8, flag, "--hard-ms")) {
            options.timeouts.hard_ms = value;
        } else if (std.mem.eql(u8, flag, "--probe-ms")) {
            options.era.probe_timeout_ms = value;
        } else if (std.mem.eql(u8, flag, "--max-pages")) {
            if (value == 0) return error.Usage;
            options.catalog.max_pages = value;
        } else return error.Usage;
    }
    if (options.argv.len == 0) return error.Usage;
    return options;
}

const max_ids = 64;

/// The steps call each other (a timed-out initialize steps the detector), so
/// their error set is spelled out.
const StepError = std.Io.Writer.Error || wire.EncodeError;

/// Copies each top-level field of a JSON object into the message being written.
fn writeFields(w: *wire.Writer, object: []const u8) !void {
    var stack: [512]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&stack);
    var scanner: std.json.Scanner = .initCompleteInput(fba.allocator(), object);
    defer scanner.deinit();
    if ((try scanner.next()) != .object_begin) return error.Usage;
    while (true) switch (try scanner.next()) {
        .object_end => return,
        .string => |key| {
            _ = try scanner.peekNextTokenType();
            const start = scanner.cursor;
            try scanner.skipValue();
            try w.field(key);
            try w.raw(object[start..scanner.cursor]);
        },
        // Keys written with escapes aren't needed by any script.
        else => return error.Usage,
    };
}

const Lab = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    process: *mcp.stdio.Process,
    out: *std.Io.Writer,
    trace: *mcp.trace.Writer,
    table: request.Table,
    timers: [64]struct { timer: request.Timer, due_ms: i64 } = undefined,
    timer_count: usize = 0,
    outcomes: [max_ids]?request.Outcome = @splat(null),
    /// What the request being sent is: a detection message, or an operation
    /// with the version it carries: a scripted request (`pending_method` and
    /// `pending_params`), a tool list page, or a tool call (the tool's name
    /// and arguments in `pending_method` and `pending_params`).
    pending: union(enum) { discover: u8, initialize, script: era.Version, list: era.Version, call: era.Version, listen: struct { version: era.Version, filter: subscription.Filter } } = .{ .script = .none },
    pending_method: []const u8 = "",
    pending_params: ?[]const u8 = null,
    protocol_version: ?[]const u8 = null,
    detector: era.Detector,
    client: era.Client = .{ .info = .{ .name = "mcpv2-lab", .version = "0.0.0" } },
    /// Set by `detect`: every new process detects before anything else.
    detecting: bool = false,
    /// The process generation detection last started for.
    era_generation: core.Generation = 0,
    /// The detection request in flight, if any.
    detection: ?struct { id: request.Id, initialize: bool } = null,
    /// Probe timers (U04) and expiry timers (U05).
    machine_timers: [16]struct { kind: enum { probe, expiry }, value: u64, due_ms: i64 } = undefined,
    machine_timer_count: usize = 0,
    catalog: catalog.Catalog = .init(.{}),
    store: tools.Store = .{},
    /// The process generation the catalog last started for.
    catalog_generation: core.Generation = 0,
    /// The tool list page request in flight, if any.
    list_id: ?request.Id = null,
    call_ids: std.bit_set.Static(max_ids) = .empty,
    /// U10: one server's subscriptions; the listens' ids.
    subs: subscription.Table = .init(.{ .stdio = true }),
    listen_ids: std.bit_set.Static(max_ids) = .empty,

    fn print(lab: *Lab, comptime kind: []const u8, value: anytype) !void {
        var json: std.json.Stringify = .{ .writer = lab.out };
        try json.beginObject();
        try json.objectField(kind);
        try json.write(value);
        try json.endObject();
        try lab.out.writeByte('\n');
        try lab.out.flush();
    }

    /// Steps the detector, traces it, and carries out its effects. Returns
    /// the output, or null when the detector refused the event.
    fn stepEra(lab: *Lab, event: era.Event) StepError!?era.Output {
        var out: era.Output = .{};
        lab.detector.step(event, &out) catch |err| {
            try lab.print("did", .{ .era_error = @errorName(err) });
            return null;
        };
        try era.writeTrace(lab.trace, "lab", &out);
        for (out.effects()) |effect| switch (effect) {
            .send_discover => |index| try lab.sendDetection(.{ .discover = index }),
            .send_initialize => try lab.sendDetection(.initialize),
            .send_initialized => {
                var buffer: std.Io.Writer.Allocating = .init(lab.gpa);
                defer buffer.deinit();
                try era.writeInitialized(&buffer.writer);
                lab.process.send(.notification, buffer.written()) catch {};
            },
            .arm_probe_timer => |a| lab.addTimer(.probe, a.probe, a.after_ms),
            .ready => |version| {
                lab.process.setEra(if (version == .legacy) .legacy else .modern) catch {};
                try lab.print("era", .{ .ready = lab.versionName(version) });
                // The catalog starts over for each new process, once its era is known.
                const generation = lab.process.conn.generation;
                if (lab.catalog_generation != generation) {
                    lab.catalog_generation = generation;
                    try lab.stepCatalog(.{ .process_started = if (version == .legacy) .legacy else .modern });
                }
                // SUBS-05: the listens a process exit ended go out again
                // once the new process's era is known.
                if (!lab.subs.up) try lab.stepSubs(.transport_up);
            },
            .failed => |failure| try lab.print("era", .{ .failed = @tagName(failure) }),
        };
        return out;
    }

    fn addTimer(lab: *Lab, kind: @FieldType(@TypeOf(lab.machine_timers[0]), "kind"), value: u64, after_ms: u32) void {
        lab.machine_timers[lab.machine_timer_count] = .{ .kind = kind, .value = value, .due_ms = lab.now() + after_ms };
        lab.machine_timer_count += 1;
    }

    /// Steps the catalog, traces it, and carries out its effects on the store.
    fn stepCatalog(lab: *Lab, event: catalog.Event) StepError!void {
        var out: catalog.Output = .{};
        lab.catalog.step(event, &out) catch |err| return lab.print("did", .{ .catalog_error = @errorName(err) });
        try catalog.writeTrace(lab.trace, "lab", &out);
        for (out.effects()) |effect| switch (effect) {
            .send_page => {
                lab.list_id = try lab.sendOperation(.list);
                // Never written (the table refused it): the page failed.
                if (lab.list_id == null and lab.catalog.pending != .none) try lab.stepCatalog(.page_failed);
            },
            .discard_pages => lab.store.discard(),
            .publish => |fresh| {
                lab.store.publish();
                try lab.printTools("publish", fresh);
            },
            .fail => {
                lab.store.discard();
                try lab.print("tools", .{ .event = "fail" });
            },
            .serve_last => {
                lab.store.discard();
                try lab.printTools("serve_last", false);
            },
            .serve => try lab.printTools("serve", true),
            .arm_expiry => |a| lab.addTimer(.expiry, a.generation, a.after_ms),
        };
    }

    fn printTools(lab: *Lab, event: []const u8, fresh: bool) StepError!void {
        var names: [max_ids][]const u8 = undefined;
        const count = @min(lab.store.current.len(), max_ids);
        for (names[0..count], 0..) |*name, i| name.* = lab.store.current.get(i).name;
        try lab.print("tools", .{ .event = event, .fresh = fresh, .count = lab.store.current.len(), .names = names[0..count] });
    }

    /// Reads a tool list page into the store and says what it means for the
    /// catalog. The engine takes this over in U12.
    fn pageEvent(lab: *Lab, body: @FieldType(wire.Response, "body")) StepError!catalog.Event {
        switch (body) {
            .failure => |f| return if (f.code == wire.code.invalid_params and lab.catalog.pending == .next) .invalid_cursor else .page_failed,
            .result => |r| {
                if (r.kind != .complete) return .page_failed;
                const page = tools.parsePage(r.raw) catch return .page_failed;
                const added = lab.store.addPage(lab.gpa, page) catch return .page_failed;
                if (added.invalid + added.duplicate > 0) {
                    try lab.print("tools", .{ .event = "dropped", .invalid = added.invalid, .duplicate = added.duplicate });
                }
                return .{ .page_received = .{ .more = page.next_cursor != null, .ttl_ms = page.ttl_ms, .now_ms = lab.now() } };
            },
        }
    }

    /// Classifies the answer to request `id` for the catalog: a list page, or
    /// a tool call answer.
    fn catalogAnswer(lab: *Lab, id: request.Id, body: @FieldType(wire.Response, "body")) StepError!void {
        if (lab.list_id == id) {
            lab.list_id = null;
            return lab.stepCatalog(try lab.pageEvent(body));
        }
        if (id >= max_ids or !lab.call_ids.isSet(id)) return;
        lab.call_ids.unset(id);
        const call = tools.classifyCall(body);
        switch (call) {
            .result => |r| try lab.print("call", .{ .id = id, .kind = "result", .is_error = r.is_error, .content = r.content, .structured = r.structured }),
            .failure => |f| try lab.print("call", .{ .id = id, .kind = "failure", .code = f.code }),
            else => try lab.print("call", .{ .id = id, .kind = @tagName(call) }),
        }
        if (tools.suggestsChangedList(call)) try lab.stepCatalog(.invalidated);
    }

    /// The `_meta` for an operation request: what detection chose, or else the
    /// `--protocol-version` option.
    fn metaFor(lab: *const Lab, version: era.Version, id: request.Id) wire.Meta {
        if (lab.detecting) return era.meta(lab.detector.config, lab.client, version, id);
        return .{
            .progress_token = id,
            .modern = if (lab.protocol_version) |v| .{
                .protocol_version = v,
                .client_capabilities = lab.client.capabilities,
                .client_info = lab.client.info,
            } else null,
        };
    }

    /// Sends an operation request (anything but detection) through the request
    /// table. Once `detect` was used, the detector must allow it (VER-08) and
    /// picks its version. Returns its id, or null when it wasn't sent.
    fn sendOperation(lab: *Lab, kind: enum { script, list, call }) StepError!?request.Id {
        var version: era.Version = .none;
        if (lab.detecting) {
            const sent = try lab.stepEra(.operation_sent) orelse return null;
            version = sent.meta.?;
        }
        lab.pending = switch (kind) {
            .script => .{ .script = version },
            .list => .{ .list = version },
            .call => .{ .call = version },
        };
        const id = lab.table.next_id;
        const initialize = kind == .script and std.mem.eql(u8, lab.pending_method, "initialize");
        try lab.stepRequest(.{ .send = if (initialize) .initialize else .normal });
        return if (lab.table.next_id != id) id else null;
    }

    /// Sends a listen for subscription `sub` (U10) through the request table,
    /// then tells the subscription core its id.
    fn sendListen(lab: *Lab, sub: u8, filter: subscription.Filter, resend: bool) StepError!void {
        var version: era.Version = .none;
        if (lab.detecting) {
            const sent = try lab.stepEra(.operation_sent) orelse return;
            version = sent.meta.?;
        }
        lab.pending = .{ .listen = .{ .version = version, .filter = filter } };
        const id = lab.table.next_id;
        try lab.stepRequest(.{ .send = .listen });
        if (lab.table.next_id == id or id >= max_ids) return;
        lab.listen_ids.set(id);
        try lab.stepSubs(if (resend) .{ .resent = .{ .sub = sub, .id = id } } else .{ .opened = .{ .sub = sub, .id = id, .filter = filter } });
    }

    fn stepSubs(lab: *Lab, event: subscription.Event) StepError!void {
        var out: subscription.Output = .{};
        lab.subs.step(event, &out);
        try subscription.writeTrace(lab.trace, "lab", &lab.subs, event, &out);
        for (out.effects()) |effect| switch (effect) {
            .deliver => |d| {
                try lab.print("sub", .{ .sub = d.sub, .deliver = @tagName(d.kind) });
                if (d.kind == .tools) try lab.stepCatalog(.invalidated);
            },
            .acknowledged => |a| try lab.print("sub", .{ .sub = a.sub, .acknowledged = a.filter }),
            .ended => |e| try lab.print("sub", .{ .sub = e.sub, .ended = @tagName(e.end) }),
            // SUBS-04: on stdio a cancel is notifications/cancelled.
            .cancel_listen => |id| try lab.stepRequest(.{ .cancel_requested = id }),
            // On stdio the listens go out when the process is back instead.
            .arm_retry => {},
            .relisten => |sub| try lab.sendListen(sub, lab.subs.subs[sub].asked, true),
        };
    }

    /// Sends a detection message through the request table. An abandoned
    /// probe is never cancelled: a legacy server must see nothing before
    /// initialize.
    fn sendDetection(lab: *Lab, what: @FieldType(Lab, "pending")) StepError!void {
        const id = lab.table.next_id;
        lab.pending = what;
        try lab.stepRequest(.{ .send = if (what == .initialize) .initialize else .normal });
        if (lab.table.next_id != id) lab.detection = .{ .id = id, .initialize = what == .initialize };
    }

    /// Classifies the answer to request `id` for the detector: the detection
    /// request's answer, or -32022 to an operation request.
    fn eraAnswer(lab: *Lab, id: request.Id, body: @FieldType(wire.Response, "body")) !void {
        const config = lab.detector.config;
        if (lab.detection) |pending| if (pending.id == id) {
            lab.detection = null;
            _ = try lab.stepEra(if (pending.initialize) era.classifyInitialize(config, body) else era.classifyDiscover(config, body));
            return;
        };
        if (body == .failure) if (era.classifyOperationRejection(config, body.failure)) |event| {
            _ = try lab.stepEra(event);
        };
    }

    /// Starts detection for each new process once `detect` was used.
    fn syncEra(lab: *Lab) !void {
        const c = lab.process.conn;
        if (!lab.detecting or c.state != .running or c.generation == lab.era_generation) return;
        lab.era_generation = c.generation;
        lab.detection = null;
        _ = try lab.stepEra(.process_started);
        _ = try lab.stepEra(.detect_requested);
    }

    fn versionName(lab: *const Lab, version: era.Version) []const u8 {
        return era.versionName(lab.detector.config, version) orelse "none";
    }

    fn now(lab: *Lab) i64 {
        return std.Io.Clock.awake.now(lab.io).toMilliseconds();
    }

    /// Steps the request table and carries out its effects.
    fn stepRequest(lab: *Lab, event: request.Event) StepError!void {
        var out: request.Output = .{};
        lab.table.step(event, &out) catch |err| return lab.print("did", .{ .request_error = @errorName(err) });
        try request.writeTrace(lab.trace, "lab", &out);
        var lost: ?request.Id = null;
        for (out.effects()) |effect| switch (effect) {
            .write_request => |w| lab.sendEncoded(.request, w.id) catch {
                // Not written (the connection isn't running): the request is lost.
                lost = w.id;
            },
            .send_cancel => |id| lab.sendEncoded(.notification, id) catch {},
            .deliver => |d| {
                if (d.id < max_ids) lab.outcomes[d.id] = d.outcome;
                try lab.print("outcome", .{ .id = d.id, .outcome = @tagName(d.outcome) });
                // Answers are classified where they arrive; here only a
                // detection request that ended without one.
                const unanswered = d.outcome != .result and d.outcome != .peer_error;
                if (lab.detection) |pending| if (pending.id == d.id and unanswered) {
                    lab.detection = null;
                    if (pending.initialize and d.outcome == .timed_out) _ = try lab.stepEra(.initialize_timed_out);
                };
                if (unanswered and lab.list_id == d.id) {
                    lab.list_id = null;
                    try lab.stepCatalog(.page_failed);
                }
                if (unanswered and d.id < max_ids) lab.call_ids.unset(d.id);
                // SUBS-03: a server's notifications/cancelled ended a listen.
                if (d.outcome == .ended) try lab.stepSubs(.{ .final = .{ .id = d.id, .end = .server_cancelled } });
            },
            .arm_timer => |a| {
                lab.timers[lab.timer_count] = .{ .timer = a.timer, .due_ms = lab.now() + a.after_ms };
                lab.timer_count += 1;
            },
            .disarm_timers => |id| {
                var i: usize = 0;
                while (i < lab.timer_count) {
                    if (lab.timers[i].timer.id == id) {
                        lab.timer_count -= 1;
                        lab.timers[i] = lab.timers[lab.timer_count];
                    } else i += 1;
                }
            },
        };
        if (lost) |id| try lab.stepRequest(.{ .transport_lost = id });
    }

    /// Encodes request `id` (or a cancel for it) and writes it to the server.
    fn sendEncoded(lab: *Lab, kind: core.MessageKind, id: request.Id) !void {
        var buffer: std.Io.Writer.Allocating = .init(lab.gpa);
        defer buffer.deinit();
        const config = lab.detector.config;
        if (kind == .request) switch (lab.pending) {
            .discover => |index| try era.writeDiscover(&buffer.writer, config, lab.client, index, id),
            .initialize => try era.writeInitialize(&buffer.writer, config, lab.client, id),
            .script => |version| {
                var w: wire.Writer = try .request(&buffer.writer, id, lab.pending_method, lab.metaFor(version, id));
                if (lab.pending_params) |params| try writeFields(&w, params);
                try w.end();
            },
            .list => |version| {
                const cursor = if (lab.catalog.pending == .next) lab.store.nextCursor() else null;
                try tools.writeList(&buffer.writer, id, lab.metaFor(version, id), cursor);
            },
            .call => |version| try tools.writeCall(&buffer.writer, id, lab.metaFor(version, id), lab.pending_method, lab.pending_params, .{}),
            .listen => |l| try subscriptions.writeListen(&buffer.writer, id, lab.metaFor(l.version, id), l.filter),
        } else {
            var w: wire.Writer = try .notification(&buffer.writer, "notifications/cancelled", .{});
            try w.field("requestId");
            try w.int(@intCast(id));
            try w.end();
        }
        try lab.process.send(kind, buffer.written());
    }

    /// Feeds what the host saw into the request table.
    fn handle(lab: *Lab, incoming: mcp.stdio.Incoming) !void {
        switch (incoming) {
            .message => |m| {
                try lab.print("seen", .{ .message = m.bytes });
                switch (m.message) {
                    .response => |r| if (r.id) |id| {
                        try lab.stepRequest(.{ .response_received = .{
                            .id = id,
                            .response = if (r.body == .result) .result else .peer_error,
                        } });
                        try lab.eraAnswer(id, r.body);
                        try lab.catalogAnswer(id, r.body);
                        // A result ends a listen gracefully, an error refuses it.
                        if (id < max_ids and lab.listen_ids.isSet(id)) try lab.stepSubs(.{ .final = .{ .id = id, .end = if (r.body == .result) .result else .refused } });
                    } else if (r.body == .failure and lab.detector.pending == .discover) {
                        // An error without an id during the probe means a legacy server.
                        _ = try lab.stepEra(.legacy_answer);
                    },
                    .notification => |n| if (std.mem.eql(u8, n.method, "notifications/cancelled")) {
                        if (subscriptions.cancelledId(n.params)) |id| try lab.stepRequest(.{ .server_cancel_received = id });
                    } else if (subscriptions.subscriptionId(n.params)) |sid| switch (subscriptions.notice(n.method, n.params)) {
                        // SUBS-02: on stdio the subscriptionId is the only way to tell them apart.
                        .acknowledged => |f| try lab.stepSubs(.{ .acknowledged = .{ .id = sid, .filter = f } }),
                        .changed => |kind| try lab.stepSubs(.{ .notified = .{ .id = sid, .kind = kind } }),
                        .other => {},
                    } else if (std.mem.eql(u8, n.method, "notifications/progress")) {
                        var found: [2]?[]const u8 = undefined;
                        wire.objectFields(n.params orelse "{}", &.{ "progressToken", "progress" }, &found) catch return;
                        const token = std.fmt.parseInt(request.Id, found[0] orelse return, 10) catch return;
                        const value = std.fmt.parseFloat(f64, found[1] orelse return) catch return;
                        try lab.stepRequest(.{ .progress_received = .{ .token = token, .value = value } });
                    } else if (std.mem.eql(u8, n.method, "notifications/tools/list_changed")) {
                        // Invalidates everything cached for the server.
                        try lab.stepCatalog(.invalidated);
                    },
                    .request => {},
                }
            },
            .stderr => |text| try lab.print("seen", .{ .stderr = text }),
            .dropped => |d| try lab.print("seen", .{ .dropped = @errorName(d.err) }),
            .changed => |c| {
                try lab.print("seen", .{ .state = @tagName(c.state), .lost = c.lost });
                if (c.lost) {
                    for (lab.table.slots) |slot| if (slot.used) try lab.stepRequest(.{ .transport_lost = slot.id });
                    // SUBS-05: the exit ends every listen.
                    if (lab.subs.up) try lab.stepSubs(.transport_down);
                }
                // A subscription waiting to listen again is demand.
                if (c.state == .idle and lab.subs.waiting()) lab.process.start() catch {};
            },
            .timeout => {},
        }
    }

    /// Handles one event or due timer, waiting at most until `until_ms`.
    /// Returns what arrived, or `timeout`.
    fn pump(lab: *Lab, until_ms: i64) !mcp.stdio.Incoming {
        var wait = until_ms;
        for (lab.timers[0..lab.timer_count]) |t| wait = @min(wait, t.due_ms);
        for (lab.machine_timers[0..lab.machine_timer_count]) |t| wait = @min(wait, t.due_ms);
        const incoming = try lab.process.next(@intCast(@max(0, wait - lab.now())));
        if (incoming != .timeout) {
            try lab.handle(incoming);
            try lab.syncEra();
            return incoming;
        }
        var p: usize = 0;
        while (p < lab.machine_timer_count) {
            if (lab.machine_timers[p].due_ms <= lab.now()) {
                const timer = lab.machine_timers[p];
                lab.machine_timer_count -= 1;
                lab.machine_timers[p] = lab.machine_timers[lab.machine_timer_count];
                switch (timer.kind) {
                    .probe => _ = try lab.stepEra(.{ .probe_timer_fired = @intCast(timer.value) }),
                    .expiry => try lab.stepCatalog(.{ .expired = timer.value }),
                }
            } else p += 1;
        }
        // Fire every request timer that is due.
        var i: usize = 0;
        while (i < lab.timer_count) {
            if (lab.timers[i].due_ms <= lab.now()) {
                const timer = lab.timers[i].timer;
                lab.timer_count -= 1;
                lab.timers[i] = lab.timers[lab.timer_count];
                try lab.stepRequest(.{ .timer_fired = timer });
                i = 0;
            } else i += 1;
        }
        return .timeout;
    }

    fn matches(target: []const u8, incoming: mcp.stdio.Incoming) bool {
        return switch (incoming) {
            .message => std.mem.eql(u8, target, "message"),
            .stderr => std.mem.eql(u8, target, "stderr"),
            .dropped => std.mem.eql(u8, target, "dropped"),
            .changed => |c| std.mem.eql(u8, target, @tagName(c.state)),
            .timeout => false,
        };
    }

    fn expect(lab: *Lab, target: []const u8, timeout_ms: u32) !bool {
        const until = lab.now() + timeout_ms;
        while (true) {
            if (std.meta.stringToEnum(core.State, target)) |state| {
                if (lab.process.conn.state == state) return true;
            }
            if (std.mem.startsWith(u8, target, "era-")) {
                if (std.meta.stringToEnum(era.State, target[4..])) |state| if (lab.detector.state == state) return true;
            }
            if (std.mem.eql(u8, target, "catalog-idle") and !lab.catalog.listing) return true;
            if (std.mem.startsWith(u8, target, "catalog-")) {
                if (std.meta.stringToEnum(catalog.Cache, target[8..])) |cache| if (lab.catalog.cache == cache and !lab.catalog.listing) return true;
            }
            if (lab.now() >= until) return false;
            if (matches(target, try lab.pump(until))) return true;
        }
    }

    fn awaitOutcome(lab: *Lab, id: request.Id, want: []const u8, timeout_ms: u32) !bool {
        const until = lab.now() + timeout_ms;
        while (true) {
            if (id < max_ids) if (lab.outcomes[id]) |got| return std.mem.eql(u8, @tagName(got), want);
            if (lab.now() >= until) return false;
            _ = try lab.pump(until);
        }
    }

    /// Runs one script line. Returns false when an expectation isn't met.
    fn run(lab: *Lab, line: []const u8) !bool {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const verb = words.next() orelse return true;
        const p = lab.process;
        if (std.mem.eql(u8, verb, "expect") or std.mem.eql(u8, verb, "outcome")) {
            const first = words.next() orelse return error.Usage;
            const met = if (std.mem.eql(u8, verb, "expect")) blk: {
                const timeout = if (words.next()) |t| try std.fmt.parseInt(u32, t, 10) else 10_000;
                break :blk try lab.expect(first, timeout);
            } else blk: {
                const want = words.next() orelse return error.Usage;
                const timeout = if (words.next()) |t| try std.fmt.parseInt(u32, t, 10) else 10_000;
                break :blk try lab.awaitOutcome(try std.fmt.parseInt(request.Id, first, 10), want, timeout);
            };
            try lab.print("did", .{ .expect = line, .met = met });
            return met;
        }
        if (std.mem.eql(u8, verb, "drain")) {
            const until = lab.now() + try std.fmt.parseInt(u32, words.next() orelse return error.Usage, 10);
            while (lab.now() < until) _ = try lab.pump(until);
            return true;
        }
        if (std.mem.eql(u8, verb, "detect")) {
            lab.detecting = true;
            try lab.syncEra();
            try lab.print("did", .{ .action = verb, .era = @tagName(lab.detector.state) });
            return true;
        }
        if (std.mem.eql(u8, verb, "request")) {
            lab.pending_method = words.next() orelse return error.Usage;
            const rest = std.mem.trim(u8, words.rest(), " ");
            lab.pending_params = if (rest.len > 0) rest else null;
            _ = try lab.sendOperation(.script);
            try lab.print("did", .{ .action = verb, .next_id = lab.table.next_id });
            return true;
        }
        if (std.mem.eql(u8, verb, "tools") or std.mem.eql(u8, verb, "invalidate")) {
            try lab.stepCatalog(if (verb[0] == 't') .need else .invalidated);
            try lab.print("did", .{ .action = verb, .cache = @tagName(lab.catalog.cache), .listing = lab.catalog.listing });
            return true;
        }
        if (std.mem.eql(u8, verb, "call")) {
            lab.pending_method = words.next() orelse return error.Usage;
            const rest = std.mem.trim(u8, words.rest(), " ");
            lab.pending_params = if (rest.len > 0) rest else null;
            const id = try lab.sendOperation(.call);
            if (id) |n| if (n < max_ids) lab.call_ids.set(n);
            try lab.print("did", .{ .action = verb, .id = id });
            return true;
        }
        if (std.mem.eql(u8, verb, "listen") or std.mem.eql(u8, verb, "unlisten")) {
            const sub = std.fmt.parseInt(u8, words.next() orelse return error.Usage, 10) catch return error.Usage;
            if (verb[0] == 'u') {
                try lab.stepSubs(.{ .cancel = sub });
            } else {
                const filter = std.fmt.parseInt(subscription.Filter, words.next() orelse return error.Usage, 10) catch return error.Usage;
                if (!lab.subs.canOpen(sub)) return error.Usage;
                try lab.sendListen(sub, filter, false);
            }
            try lab.print("did", .{ .action = verb, .sub = sub });
            return true;
        }
        if (std.mem.eql(u8, verb, "cancel")) {
            try lab.stepRequest(.{ .cancel_requested = try std.fmt.parseInt(request.Id, words.next() orelse return error.Usage, 10) });
            try lab.print("did", .{ .action = verb });
            return true;
        }
        const result: mcp.stdio.Error!void = if (std.mem.eql(u8, verb, "start"))
            p.start()
        else if (std.mem.eql(u8, verb, "stop"))
            p.stop()
        else if (std.mem.eql(u8, verb, "reconnect"))
            p.reconnect()
        else if (std.mem.eql(u8, verb, "era"))
            p.setEra(if (std.mem.eql(u8, words.next() orelse "", "legacy")) .legacy else .modern)
        else if (std.mem.eql(u8, verb, "send")) blk: {
            const kind = std.meta.stringToEnum(core.MessageKind, words.next() orelse "") orelse return error.Usage;
            break :blk p.send(kind, std.mem.trim(u8, words.rest(), " "));
        } else return error.Usage;
        if (result) |_| {
            try lab.print("did", .{ .action = verb, .state = @tagName(p.conn.state) });
        } else |err| {
            try lab.print("did", .{ .action = verb, .@"error" = @errorName(err) });
        }
        return true;
    }
};

/// A comma-separated version list, for --preferred and --legacy.
fn versionList(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var versions = std.mem.tokenizeScalar(u8, text, ',');
    while (versions.next()) |v| try list.append(arena, v);
    if (list.items.len == 0 or list.items.len > era.max_preferred) return error.Usage;
    return list.items;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const options = parseOptions(arena, args) catch {
        std.debug.print("usage: stdio_lab <trace-path> <script> [--max-attempts N] [--grace-ms N] [--term-ms N] " ++
            "[--backoff-ms N] [--max-line N] [--idle-ms N] [--hard-ms N] [--protocol-version V] [--preferred V1,V2] " ++
            "[--legacy V] [--probe-ms N] [--max-pages N] -- <server argv...>\n", .{});
        std.process.exit(2);
    };
    const script = try std.Io.Dir.cwd().readFileAlloc(io, options.script_path, arena, .limited(1 << 20));

    var trace_file = try std.Io.Dir.cwd().createFile(io, options.trace_path, .{});
    defer trace_file.close(io);
    var trace_buffer: [8192]u8 = undefined;
    var trace_writer = trace_file.writer(io, &trace_buffer);
    var trace: mcp.trace.Writer = .init(&trace_writer.interface);

    var out_buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);

    var process: mcp.stdio.Process = undefined;
    process.init(io, init.gpa, .{
        .argv = options.argv,
        .environ_map = init.environ_map,
        .config = options.config,
        .max_line = options.max_line,
        .trace = &trace,
        .trace_instance = "lab",
    });
    var slots: [16]request.Slot = undefined;
    var lab: Lab = .{
        .io = io,
        .gpa = init.gpa,
        .process = &process,
        .out = &stdout.interface,
        .trace = &trace,
        .table = .init(&slots, options.timeouts),
        .protocol_version = options.protocol_version,
        .detector = .init(options.era),
        .catalog = .init(options.catalog),
    };

    var ok = true;
    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        const ran = lab.run(line);
        lab.syncEra() catch {};
        if (!(ran catch |err| {
            try lab.print("did", .{ .line = line, .@"error" = @errorName(err) });
            ok = false;
            break;
        })) {
            ok = false;
            break;
        }
    }
    const c = process.conn;
    try lab.print("final", .{
        .state = @tagName(c.state),
        .generation = c.generation,
        .attempts = c.attempts,
        .term_sent = c.term_sent,
        .kill_sent = c.kill_sent,
        .errored = c.errored,
        .stderr_dropped = process.stderr_dropped.load(.monotonic),
        .spawn_error = if (process.spawn_error) |err| @errorName(err) else null,
        .in_flight = lab.table.inFlightCount(),
        .era = @tagName(lab.detector.state),
        .era_version = lab.versionName(lab.detector.version),
        .era_failure = if (lab.detector.failure) |f| @tagName(f) else null,
        .catalog = @tagName(lab.catalog.cache),
        .tools = lab.store.current.len(),
    });
    lab.store.deinit(init.gpa);
    process.deinit();
    try trace_writer.interface.flush();
    if (!ok) std.process.exit(1);
}
