//! Version detection core. Events are the client's actions, and effects are
//! the detection messages to send. Pure: no I/O, clock, allocation, or globals.
//!
//! The client's versions live in `Config`. A server's version lists arrive as
//! a `Listed` mask over them, so the core never stores the server's strings.
//! The `classify*` functions turn a server's answer into an event, and the
//! `write*` functions build the detection messages.

const std = @import("std");
const trace = @import("../io/trace.zig");
const wire = @import("../protocol/wire.zig");

pub const max_preferred = 8;

pub const State = enum { unknown, probing, initializing, modern, legacy, failed };

pub const Config = struct {
    /// Modern versions, most preferred first.
    preferred: []const []const u8 = &.{"2026-07-28"},
    /// The 2025-era versions `initialize` may agree on, newest first. The
    /// first is the one offered.
    legacy: []const []const u8 = &.{ "2025-11-25", "2025-06-18", "2025-03-26" },
    probe_timeout_ms: u32 = 10_000,
};

/// Which of the client's versions a server listed.
pub const Listed = struct {
    /// Bit i stands for `Config.preferred[i]`.
    preferred: u8 = 0,
    legacy: bool = false,

    pub fn has(listed: Listed, index: usize) bool {
        return listed.preferred & (@as(u8, 1) << @intCast(index)) != 0;
    }
};

/// A version as the core sees it: one of the client's, by index, or another.
pub const Version = union(enum) {
    none,
    /// Index into `Config.legacy`.
    legacy: u8,
    /// Index into `Config.preferred`.
    preferred: u8,
    other,
};

/// The version string for `version`, if it is one of the client's.
pub fn versionName(config: Config, version: Version) ?[]const u8 {
    return switch (version) {
        .legacy => |i| config.legacy[i],
        .preferred => |i| config.preferred[i],
        .none, .other => null,
    };
}

pub const Failure = enum {
    /// The server lists no version the client supports.
    no_shared_version,
    /// -32020 or -32021: a modern server that won't serve this client.
    rejected,
    /// A server that answered like a modern one stopped answering.
    went_quiet,
    /// initialize was answered with a version other than the legacy one.
    unsupported_version,
    /// initialize was rejected, or never answered.
    initialize_failed,
};

pub const Event = union(enum) {
    /// A new server process is running.
    process_started,
    detect_requested,
    discover_result: Listed,
    /// The probe got -32022.
    unsupported_version: Listed,
    /// The probe got -32020 or -32021.
    modern_rejection,
    /// The probe got any other error, or an error without an id.
    legacy_answer,
    /// HTTP only: the probe got 404 with -32601, from a modern server
    /// that doesn't implement discovery. It is served with the probe's version.
    discover_not_implemented,
    /// The probe's timer. A timer from an earlier probe changes nothing.
    probe_timer_fired: u32,
    /// The version initialize was answered with.
    initialize_result: Version,
    /// initialize was rejected; true when the error hints at a modern server.
    initialize_error: bool,
    initialize_timed_out,
    /// An operation request is about to go out; `Output.meta` says what it carries.
    operation_sent,
    /// An operation request got -32022.
    operation_version_rejected: Listed,
};

pub const Effect = union(enum) {
    /// Send server/discover with `Config.preferred[index]`.
    send_discover: u8,
    send_initialize,
    send_initialized,
    arm_probe_timer: struct { probe: u32, after_ms: u32 },
    /// Requests may go out, on a modern server with this version or on a legacy one.
    ready: Version,
    failed: Failure,
};

/// The version an operation request carried, for the trace.
pub const Meta = union(enum) {
    unset,
    none,
    preferred: u8,
};

pub const Pending = enum { none, discover, initialize };

/// The model's variables after a step, for the trace.
pub const Projection = struct {
    version: Version,
    pending: Pending,
    modern_seen: bool,
    process: u32,
    last_meta: Meta,
};

pub const Transition = struct {
    event: []const u8,
    from: State,
    to: State,
    listed: ?Listed = null,
    result_version: ?Version = null,
    hint: ?bool = null,
    /// The event isn't enabled in the model here, so nothing changed.
    ignored: bool = false,
    state: Projection,
};

pub const max_effects = 2;

pub const Output = struct {
    effect_buffer: [max_effects]Effect = undefined,
    effect_count: usize = 0,
    /// For `operation_sent`: the version the request carries.
    meta: ?Version = null,
    /// Null for a timer from an earlier probe, which is no model step.
    transition: ?Transition = null,

    pub fn effects(output: *const Output) []const Effect {
        return output.effect_buffer[0..output.effect_count];
    }

    fn push(output: *Output, effect: Effect) void {
        std.debug.assert(output.effect_count < max_effects);
        output.effect_buffer[output.effect_count] = effect;
        output.effect_count += 1;
    }
};

pub const StepError = error{
    /// Operation requests wait until detection finishes.
    NotReady,
};

pub const Detector = struct {
    config: Config,
    state: State = .unknown,
    version: Version = .none,
    tried: [max_preferred]u8 = @splat(0),
    pending: Pending = .none,
    advertised: Listed = .{},
    process: u32 = 0,
    last_meta: Meta = .unset,
    modern_seen: bool = false,
    /// Counts probes, so a timer from an earlier one is recognized.
    probe: u32 = 0,
    failure: ?Failure = null,

    pub fn init(config: Config) Detector {
        std.debug.assert(config.preferred.len > 0 and config.preferred.len <= max_preferred);
        return .{ .config = config };
    }

    pub fn ready(d: *const Detector) bool {
        return d.state == .modern or d.state == .legacy;
    }

    /// Applies one event. Resets `out` first. Errors leave the detector unchanged.
    pub fn step(d: *Detector, event: Event, out: *Output) StepError!void {
        out.* = .{};
        const from = d.state;
        var ignored = false;
        switch (event) {
            .process_started => d.* = .{ .config = d.config, .process = d.process + 1, .probe = d.probe },
            .detect_requested => {
                if (d.state == .unknown and d.process > 0) d.startProbe(0, out) else ignored = true;
            },
            .discover_result => |listed| {
                if (d.pending != .discover) {
                    ignored = true;
                } else {
                    d.advertised = listed;
                    d.modern_seen = true;
                    if (d.firstShared(listed)) |index| {
                        d.becomeReady(.{ .preferred = index }, out);
                    } else if (listed.legacy) d.startInitialize(out) else d.fail(.no_shared_version, out);
                }
            },
            .unsupported_version => |listed| {
                if (d.pending != .discover) {
                    ignored = true;
                } else {
                    d.advertised = listed;
                    d.modern_seen = true;
                    if (d.nextCandidate(listed)) |index| {
                        d.startProbe(index, out);
                    } else if (listed.legacy) d.startInitialize(out) else d.fail(.no_shared_version, out);
                }
            },
            .modern_rejection => {
                if (d.pending != .discover) {
                    ignored = true;
                } else {
                    d.modern_seen = true;
                    d.fail(.rejected, out);
                }
            },
            .legacy_answer => {
                if (d.pending == .discover) d.legacyAnswer(out) else ignored = true;
            },
            .discover_not_implemented => {
                if (d.pending != .discover) {
                    ignored = true;
                } else {
                    d.modern_seen = true;
                    d.becomeReady(d.version, out);
                }
            },
            .probe_timer_fired => |probe| {
                // A timer from an earlier probe, or for one already answered, is no step.
                if (probe != d.probe or d.pending != .discover) return;
                d.legacyAnswer(out);
            },
            .initialize_result => |version| {
                if (d.pending != .initialize) {
                    ignored = true;
                } else if (version == .legacy) {
                    out.push(.send_initialized);
                    d.becomeReady(version, out);
                } else d.fail(.unsupported_version, out);
            },
            .initialize_error => |hint| {
                if (d.pending != .initialize) {
                    ignored = true;
                } else if (hint and d.tried[0] < 2) {
                    // A modern server that missed the probe; probe once more.
                    // Detection always starts with the first preferred version,
                    // so its two-probe limit allows exactly one fall forward.
                    d.modern_seen = true;
                    d.startProbe(0, out);
                } else d.fail(.initialize_failed, out);
            },
            .initialize_timed_out => {
                if (d.pending == .initialize) d.fail(.initialize_failed, out) else ignored = true;
            },
            .operation_sent => {
                if (!d.ready()) return error.NotReady;
                d.last_meta = switch (d.state) {
                    .modern => .{ .preferred = d.version.preferred },
                    else => .none,
                };
                out.meta = if (d.state == .modern) d.version else .none;
            },
            .operation_version_rejected => |listed| {
                if (d.state != .modern) {
                    ignored = true;
                } else {
                    d.advertised = listed;
                    // Never switch eras mid-process.
                    if (d.nextCandidate(listed)) |index| {
                        d.tried[index] += 1;
                        d.version = .{ .preferred = index };
                        d.last_meta = .unset;
                        out.push(.{ .ready = d.version });
                    } else d.fail(.no_shared_version, out);
                }
            },
        }
        out.transition = .{
            .event = @tagName(event),
            .from = from,
            .to = d.state,
            .listed = switch (event) {
                .discover_result, .unsupported_version, .operation_version_rejected => |listed| listed,
                else => null,
            },
            .result_version = if (event == .initialize_result) event.initialize_result else null,
            .hint = if (event == .initialize_error) event.initialize_error else null,
            .ignored = ignored,
            .state = .{
                .version = d.version,
                .pending = d.pending,
                .modern_seen = d.modern_seen,
                .process = d.process,
                .last_meta = d.last_meta,
            },
        };
    }

    /// The first preferred version the server listed and hasn't been tried;
    /// else the current version, tried once, if listed (a server that rejects
    /// a version it lists gets one retry).
    fn nextCandidate(d: *const Detector, listed: Listed) ?u8 {
        for (0..d.config.preferred.len) |i| {
            if (listed.has(i) and d.tried[i] == 0) return @intCast(i);
        }
        return switch (d.version) {
            .preferred => |i| if (listed.has(i) and d.tried[i] == 1) i else null,
            else => null,
        };
    }

    fn firstShared(d: *const Detector, listed: Listed) ?u8 {
        for (0..d.config.preferred.len) |i| {
            if (listed.has(i)) return @intCast(i);
        }
        return null;
    }

    fn startProbe(d: *Detector, index: u8, out: *Output) void {
        d.state = .probing;
        d.version = .{ .preferred = index };
        d.tried[index] += 1;
        d.pending = .discover;
        d.probe += 1;
        out.push(.{ .send_discover = index });
        out.push(.{ .arm_probe_timer = .{ .probe = d.probe, .after_ms = d.config.probe_timeout_ms } });
    }

    /// Fall back to initialize.
    fn startInitialize(d: *Detector, out: *Output) void {
        d.state = .initializing;
        d.version = .{ .legacy = 0 };
        d.pending = .initialize;
        out.push(.send_initialize);
    }

    /// The server is legacy, unless it already answered like a modern one in
    /// this process and didn't list the legacy version.
    fn legacyAnswer(d: *Detector, out: *Output) void {
        if (d.modern_seen and !d.advertised.legacy) d.fail(.went_quiet, out) else d.startInitialize(out);
    }

    fn becomeReady(d: *Detector, version: Version, out: *Output) void {
        d.state = if (version == .legacy) .legacy else .modern;
        d.version = version;
        d.pending = .none;
        out.push(.{ .ready = version });
    }

    fn fail(d: *Detector, failure: Failure, out: *Output) void {
        d.state = .failed;
        d.pending = .none;
        d.failure = failure;
        out.push(.{ .failed = failure });
    }
};

/// The client versions a JSON array of strings lists.
pub fn listedIn(config: Config, array: []const u8) wire.DecodeError!Listed {
    var listed: Listed = .{};
    for (config.legacy) |version| listed.legacy = listed.legacy or try wire.arrayHasString(array, version);
    for (config.preferred, 0..) |version, i| {
        if (try wire.arrayHasString(array, version)) listed.preferred |= @as(u8, 1) << @intCast(i);
    }
    return listed;
}

/// The versions in the `supported` list of a -32022 error's data, if any.
fn supportedIn(config: Config, failure: wire.Failure) Listed {
    var found: [1]?[]const u8 = undefined;
    wire.objectFields(failure.data orelse return .{}, &.{"supported"}, &found) catch return .{};
    return listedIn(config, found[0] orelse return .{}) catch .{};
}

/// The event for the answer to the current probe. A result without a
/// `supportedVersions` list isn't a DiscoverResult, so it counts as legacy,
/// like every error that isn't a recognized modern one.
pub fn classifyDiscover(config: Config, body: @FieldType(wire.Response, "body")) Event {
    switch (body) {
        .result => |result| {
            var found: [1]?[]const u8 = undefined;
            wire.objectFields(result.raw, &.{"supportedVersions"}, &found) catch return .legacy_answer;
            return .{ .discover_result = listedIn(config, found[0] orelse return .legacy_answer) catch return .legacy_answer };
        },
        .failure => |failure| return switch (failure.code) {
            wire.code.unsupported_protocol_version => .{ .unsupported_version = supportedIn(config, failure) },
            wire.code.header_mismatch, wire.code.missing_required_client_capability => .modern_rejection,
            else => .legacy_answer,
        },
    }
}

/// The event for an HTTP answer to the current probe: its status, and the
/// JSON-RPC message in its body, if any. A 404 with -32601 is a modern server
/// without discovery; a body that isn't a JSON-RPC message counts as
/// legacy.
pub fn classifyDiscoverHttp(config: Config, status: u16, body: ?@FieldType(wire.Response, "body")) Event {
    const b = body orelse return .legacy_answer;
    if (status == 404 and b == .failure and b.failure.code == wire.code.method_not_found) return .discover_not_implemented;
    return classifyDiscover(config, b);
}

/// The event for the answer to initialize. An error hints at a modern server
/// when it is a recognized modern error, or names a preferred version in its
/// supported list or message.
pub fn classifyInitialize(config: Config, body: @FieldType(wire.Response, "body")) Event {
    switch (body) {
        .result => |result| {
            var found: [1]?[]const u8 = undefined;
            wire.objectFields(result.raw, &.{"protocolVersion"}, &found) catch return .{ .initialize_result = .other };
            const version = wire.plainString(found[0] orelse return .{ .initialize_result = .other }) orelse return .{ .initialize_result = .other };
            for (config.legacy, 0..) |v, i| {
                if (std.mem.eql(u8, version, v)) return .{ .initialize_result = .{ .legacy = @intCast(i) } };
            }
            for (config.preferred, 0..) |v, i| {
                if (std.mem.eql(u8, version, v)) return .{ .initialize_result = .{ .preferred = @intCast(i) } };
            }
            return .{ .initialize_result = .other };
        },
        .failure => |failure| {
            const modern_code = switch (failure.code) {
                wire.code.unsupported_protocol_version, wire.code.header_mismatch, wire.code.missing_required_client_capability => true,
                else => false,
            };
            var named = supportedIn(config, failure).preferred != 0;
            for (config.preferred) |v| named = named or std.mem.find(u8, failure.message, v) != null;
            return .{ .initialize_error = modern_code or named };
        },
    }
}

/// The event for -32022 in reply to an operation request.
pub fn classifyOperationRejection(config: Config, failure: wire.Failure) ?Event {
    if (failure.code != wire.code.unsupported_protocol_version) return null;
    return .{ .operation_version_rejected = supportedIn(config, failure) };
}

/// Who the client is, for the detection messages and per-request `_meta`.
pub const Client = struct {
    info: wire.Implementation,
    /// A JSON object; `{}` declares no capabilities.
    capabilities: []const u8 = "{}",
};

/// The `_meta` for a request: the 2026 fields when `version` is a preferred
/// version, only the progress token otherwise. The progress token
/// is the request id.
pub fn meta(config: Config, client: Client, version: Version, id: wire.RequestId) wire.Meta {
    return .{
        .progress_token = id,
        .modern = switch (version) {
            .preferred => |i| .{
                .protocol_version = config.preferred[i],
                .client_capabilities = client.capabilities,
                .client_info = client.info,
            },
            else => null,
        },
    };
}

pub fn writeDiscover(out: *std.Io.Writer, config: Config, client: Client, index: u8, id: wire.RequestId) wire.EncodeError!void {
    var w: wire.Writer = try .request(out, id, "server/discover", meta(config, client, .{ .preferred = index }, id));
    try w.end();
}

/// The newest legacy version, the client's capabilities, and who it is.
pub fn writeInitialize(out: *std.Io.Writer, config: Config, client: Client, id: wire.RequestId) wire.EncodeError!void {
    var w: wire.Writer = try .request(out, id, "initialize", meta(config, client, .{ .legacy = 0 }, id));
    try w.field("protocolVersion");
    try w.string(config.legacy[0]);
    try w.field("capabilities");
    try w.raw(client.capabilities);
    try w.field("clientInfo");
    try w.json.write(client.info);
    try w.end();
}

pub fn writeInitialized(out: *std.Io.Writer) wire.EncodeError!void {
    var w: wire.Writer = try .notification(out, "notifications/initialized", .{});
    try w.end();
}

fn versionCode(version: Version) i64 {
    return switch (version) {
        .none => -1,
        .legacy => 0,
        .preferred => |i| @as(i64, i) + 1,
        .other => -2,
    };
}

/// Writes the step in `out` as one trace line for machine "era". Versions
/// are written as codes: -1 none, 0 legacy, k for preferred version k (from
/// 1), -2 another; a listed set is a bitmask over the preferred versions.
pub fn writeTrace(writer: *trace.Writer, instance: []const u8, out: *const Output) std.Io.Writer.Error!void {
    const t = out.transition orelse return;
    const s = t.state;
    var fields: [10]trace.Field = undefined;
    var count: usize = 0;
    if (t.listed) |listed| {
        fields[0] = .{ .name = "listed", .value = .{ .int = listed.preferred } };
        fields[1] = .{ .name = "listed_legacy", .value = .{ .boolean = listed.legacy } };
        count = 2;
    }
    if (t.result_version) |v| {
        fields[count] = .{ .name = "result_version", .value = .{ .int = versionCode(v) } };
        count += 1;
    }
    if (t.hint) |hint| {
        fields[count] = .{ .name = "hint", .value = .{ .boolean = hint } };
        count += 1;
    }
    const projected = [_]trace.Field{
        .{ .name = "ignored", .value = .{ .boolean = t.ignored } },
        .{ .name = "version", .value = .{ .int = versionCode(s.version) } },
        .{ .name = "pending", .value = .{ .string = @tagName(s.pending) } },
        .{ .name = "modern_seen", .value = .{ .boolean = s.modern_seen } },
        .{ .name = "process", .value = .{ .int = s.process } },
        .{ .name = "last_meta", .value = .{ .int = switch (s.last_meta) {
            .unset => -3,
            .none => -1,
            .preferred => |i| @as(i64, i) + 1,
        } } },
    };
    @memcpy(fields[count..][0..projected.len], &projected);
    count += projected.len;
    var effect_names: [max_effects][]const u8 = undefined;
    for (out.effects(), 0..) |effect, index| effect_names[index] = @tagName(effect);
    try writer.write(.{
        .machine = "era",
        .instance = instance,
        .event = t.event,
        .from = @tagName(t.from),
        .to = @tagName(t.to),
        .effects = effect_names[0..out.effect_count],
        .data = fields[0..count],
    });
}

const testing = std.testing;

const test_config: Config = .{ .preferred = &.{ "2026-07-28", "2027-01-01" }, .probe_timeout_ms = 50 };

/// What the server and the client have done this process, rebuilt from the
/// core's effects. Tests offer only answers to what is pending, and check the
/// model's invariants from the effects alone.
const World = struct {
    processes: u32 = 0,
    pending: Pending = .none,
    /// Armed probe timers that haven't fired, by probe number. Timers are
    /// never cancelled, so earlier ones can still fire.
    timers: u64 = 0,
    /// Fall forwards this process.
    forwards: u8 = 0,
    probes: [max_preferred]u8 = @splat(0),
    /// The server answered like a modern one.
    modern_answer: bool = false,
    last_listed: Listed = .{},
    ready: ?Version = null,
    ready_era: ?State = null,
    initialized: u8 = 0,
    /// Modern without discovery: the server hasn't listed its versions.
    unlisted: bool = false,
};

const Move = Event;

fn apply(d: *Detector, w: *World, event: Event) !bool {
    // The environment offers only answers to what is pending.
    switch (event) {
        .process_started => if (w.processes >= 2) return false,
        .discover_result, .unsupported_version, .modern_rejection, .legacy_answer, .discover_not_implemented => if (w.pending != .discover) return false,
        .probe_timer_fired => |n| if (n >= 64 or w.timers & (@as(u64, 1) << @intCast(n)) == 0) return false,
        .initialize_result, .initialize_error, .initialize_timed_out => if (w.pending != .initialize) return false,
        else => {},
    }
    const before = d.*;
    var out: Output = .{};
    d.step(event, &out) catch |err| switch (err) {
        error.NotReady => {
            // LegacyOrder: operation requests wait for detection.
            try testing.expect(!before.ready());
            try testing.expectEqual(before, d.*);
            return true;
        },
    };
    switch (event) {
        .process_started => w.* = .{ .processes = w.processes + 1, .timers = w.timers },
        .discover_result, .unsupported_version => |listed| {
            w.modern_answer = true;
            w.last_listed = listed;
            w.unlisted = false;
            w.pending = .none;
        },
        .discover_not_implemented => {
            w.modern_answer = true;
            w.unlisted = true;
            w.pending = .none;
        },
        .modern_rejection => {
            w.modern_answer = true;
            w.pending = .none;
        },
        .legacy_answer, .initialize_result, .initialize_error, .initialize_timed_out => w.pending = .none,
        .probe_timer_fired => |n| {
            w.timers &= ~(@as(u64, 1) << @intCast(n));
            // Only the current probe's timer answers anything.
            if (n == before.probe and before.pending == .discover) w.pending = .none;
        },
        .operation_version_rejected => |listed| if (before.state == .modern) {
            w.last_listed = listed;
            w.unlisted = false;
        },
        else => {},
    }
    if (event == .initialize_error and event.initialize_error) w.modern_answer = true;

    for (out.effects()) |effect| switch (effect) {
        .send_discover => |i| {
            if (event == .initialize_error) {
                w.forwards += 1;
                try testing.expect(w.forwards <= 1);
            }
            w.pending = .discover;
            w.probes[i] += 1;
            // ProbesBounded.
            try testing.expect(w.probes[i] <= 2);
        },
        .send_initialize => {
            // NoFallbackAfterModern.
            if (w.modern_answer) try testing.expect(w.last_listed.legacy);
            w.pending = .initialize;
        },
        .send_initialized => {
            try testing.expect(event == .initialize_result and event.initialize_result == .legacy);
            w.initialized += 1;
        },
        .arm_probe_timer => |a| {
            try testing.expect(a.probe < 64);
            w.timers |= @as(u64, 1) << @intCast(a.probe);
        },
        .ready => |v| {
            const era: State = if (v == .legacy) .legacy else .modern;
            // EraSticky.
            if (w.ready_era) |e| try testing.expectEqual(e, era);
            w.ready_era = era;
            w.ready = v;
            // ChosenSupported.
            switch (v) {
                .preferred => |i| try testing.expect(w.last_listed.has(i) or w.unlisted),
                .legacy => try testing.expect(event == .initialize_result and event.initialize_result == .legacy),
                else => return error.TestUnexpectedResult,
            }
        },
        .failed => {},
    };
    if (d.state == .legacy) try testing.expectEqual(@as(u8, 1), w.initialized);
    // LegacyOrder and VersionOnEveryRequest: only after detection, with the version in use.
    if (event == .operation_sent) try testing.expect(w.ready != null);
    if (event == .operation_sent) try testing.expectEqual(if (d.state == .modern) w.ready.? else Version.none, out.meta.?);

    // Where the model has no choice, the core must act.
    switch (event) {
        .discover_result => |listed| if (before.pending == .discover and listed.preferred != 0) try testing.expectEqual(State.modern, d.state),
        .legacy_answer => if (before.pending == .discover and !before.modern_seen) try testing.expectEqual(State.initializing, d.state),
        .discover_not_implemented => if (before.pending == .discover) try testing.expectEqual(State.modern, d.state),
        .probe_timer_fired => |n| if (n == before.probe and before.pending == .discover) {
            try testing.expect(d.state != .probing or d.probe != before.probe);
        } else {
            // A timer from an earlier probe is no step at all.
            try testing.expect(out.transition == null);
            try testing.expectEqual(before, d.*);
        },
        .initialize_result => |v| if (v == .legacy) try testing.expectEqual(State.legacy, d.state),
        .initialize_timed_out => try testing.expectEqual(State.failed, d.state),
        else => {},
    }
    if (out.transition) |t| {
        if (t.ignored) {
            try testing.expectEqual(before, d.*);
            try testing.expectEqual(@as(usize, 0), out.effect_count);
        }
    }
    return true;
}

fn candidateMoves(buffer: []Event) []Event {
    var n: usize = 0;
    const fixed = [_]Event{
        .process_started,              .detect_requested,                          .modern_rejection,                             .legacy_answer,
        .{ .probe_timer_fired = 1 },   .{ .probe_timer_fired = 2 },                .{ .probe_timer_fired = 3 },                   .{ .probe_timer_fired = 4 },
        .{ .probe_timer_fired = 5 },   .{ .initialize_result = .{ .legacy = 0 } }, .{ .initialize_result = .{ .preferred = 0 } }, .{ .initialize_result = .other },
        .{ .initialize_error = true }, .{ .initialize_error = false },             .initialize_timed_out,                         .operation_sent,
        .discover_not_implemented,
    };
    for (fixed) |m| {
        buffer[n] = m;
        n += 1;
    }
    for (0..8) |mask| {
        const listed: Listed = .{ .preferred = @intCast(mask & 3), .legacy = mask & 4 != 0 };
        for ([_]Event{ .{ .discover_result = listed }, .{ .unsupported_version = listed }, .{ .operation_version_rejected = listed } }) |m| {
            buffer[n] = m;
            n += 1;
        }
    }
    return buffer[0..n];
}

fn explore(d: Detector, w: World, depth: usize, moves: []const Event, steps: *usize) !void {
    if (depth == 0) return;
    for (moves) |move| {
        var dc = d;
        var wc = w;
        if (!try apply(&dc, &wc, move)) continue;
        steps.* += 1;
        try explore(dc, wc, depth - 1, moves, steps);
    }
}

test "every answer sequence up to depth 7 keeps the model's invariants" {
    var buffer: [49]Event = undefined;
    const moves = candidateMoves(&buffer);
    var steps: usize = 0;
    try explore(.init(test_config), .{}, 7, moves, &steps);
    try testing.expect(steps > 100_000);
}

test "random long runs keep the model's invariants, and detection always ends (ReachesEra)" {
    var buffer: [49]Event = undefined;
    const moves = candidateMoves(&buffer);
    var prng: std.Random.DefaultPrng = .init(0xe2a);
    const random = prng.random();
    for (0..2_000) |_| {
        var d: Detector = .init(test_config);
        var w: World = .{};
        for (0..random.uintLessThan(usize, 60)) |_| _ = try apply(&d, &w, moves[random.uintLessThan(usize, moves.len)]);
        // Only the fair moves from here: probe timers fire, initialize times out.
        for (0..16) |_| {
            if (d.state != .probing and d.state != .initializing) break;
            if (d.pending == .discover) _ = try apply(&d, &w, .{ .probe_timer_fired = d.probe }) else _ = try apply(&d, &w, .initialize_timed_out);
        }
        try testing.expect(d.state != .probing and d.state != .initializing);
    }
}

test "a modern server is found with server/discover and its first shared version" {
    var d: Detector = .init(test_config);
    var out: Output = .{};
    try d.step(.process_started, &out);
    try d.step(.detect_requested, &out);
    try testing.expectEqualSlices(Effect, &.{ .{ .send_discover = 0 }, .{ .arm_probe_timer = .{ .probe = 1, .after_ms = 50 } } }, out.effects());
    try d.step(.{ .discover_result = .{ .preferred = 0b10 } }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .ready = .{ .preferred = 1 } }}, out.effects());
    try d.step(.operation_sent, &out);
    try testing.expectEqual(Version{ .preferred = 1 }, out.meta.?);
}

test "-32022 retries with a listed version, and names only the legacy one to fall back" {
    var d: Detector = .init(test_config);
    var out: Output = .{};
    try d.step(.process_started, &out);
    try d.step(.detect_requested, &out);
    try d.step(.{ .unsupported_version = .{ .preferred = 0b10 } }, &out);
    try testing.expectEqual(Effect{ .send_discover = 1 }, out.effects()[0]);
    try d.step(.{ .unsupported_version = .{ .legacy = true } }, &out);
    try testing.expectEqualSlices(Effect, &.{.send_initialize}, out.effects());
    try d.step(.{ .initialize_result = .{ .legacy = 0 } }, &out);
    try testing.expectEqualSlices(Effect, &.{ .send_initialized, .{ .ready = .{ .legacy = 0 } } }, out.effects());
}

test "initialize may agree on an older 2025 version, which the detector keeps" {
    var d: Detector = .init(.{});
    var out: Output = .{};
    try d.step(.process_started, &out);
    try d.step(.detect_requested, &out);
    try d.step(.legacy_answer, &out);
    try testing.expectEqualSlices(Effect, &.{.send_initialize}, out.effects());
    const answer = classifyInitialize(d.config, (try wire.decode("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"protocolVersion\":\"2025-03-26\"}}")).response.body);
    try d.step(answer, &out);
    try testing.expectEqualSlices(Effect, &.{ .send_initialized, .{ .ready = .{ .legacy = 2 } } }, out.effects());
    try testing.expectEqualStrings("2025-03-26", versionName(d.config, d.version).?);
    // 2025 requests carry no version in `_meta`; over HTTP it goes in the header.
    try d.step(.operation_sent, &out);
    try testing.expectEqual(Version.none, out.meta.?);
}

test "a legacy server is found by any other error, no answer, or an error without an id" {
    for ([_]Event{ .legacy_answer, .{ .probe_timer_fired = 1 } }) |answer| {
        var d: Detector = .init(test_config);
        var out: Output = .{};
        try d.step(.process_started, &out);
        try d.step(.detect_requested, &out);
        try d.step(answer, &out);
        try testing.expectEqualSlices(Effect, &.{.send_initialize}, out.effects());
        // A late answer to the abandoned probe changes nothing.
        try d.step(.{ .discover_result = .{ .preferred = 1 } }, &out);
        try testing.expect(out.transition.?.ignored);
        try d.step(.{ .initialize_result = .{ .preferred = 0 } }, &out);
        try testing.expectEqual(Effect{ .failed = .unsupported_version }, out.effects()[0]);
    }
}

test "-32020 and -32021 fail without falling back; a modern server that goes quiet fails" {
    var d: Detector = .init(test_config);
    var out: Output = .{};
    try d.step(.process_started, &out);
    try d.step(.detect_requested, &out);
    try d.step(.modern_rejection, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .failed = .rejected }}, out.effects());

    var quiet: Detector = .init(test_config);
    try quiet.step(.process_started, &out);
    try quiet.step(.detect_requested, &out);
    try quiet.step(.{ .unsupported_version = .{ .preferred = 1 } }, &out);
    try quiet.step(.{ .probe_timer_fired = 1 }, &out);
    try testing.expect(out.transition == null);
    try quiet.step(.{ .probe_timer_fired = 2 }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .failed = .went_quiet }}, out.effects());
}

test "initialize rejected by a modern server probes once more" {
    var d: Detector = .init(test_config);
    var out: Output = .{};
    try d.step(.process_started, &out);
    try d.step(.detect_requested, &out);
    try d.step(.{ .probe_timer_fired = 1 }, &out);
    try d.step(.{ .initialize_error = true }, &out);
    try testing.expectEqual(Effect{ .send_discover = 0 }, out.effects()[0]);
    try d.step(.{ .discover_result = .{ .preferred = 1 } }, &out);
    try testing.expectEqual(State.modern, d.state);

    var once: Detector = .init(test_config);
    try once.step(.process_started, &out);
    try once.step(.detect_requested, &out);
    try once.step(.legacy_answer, &out);
    try once.step(.{ .initialize_error = false }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .failed = .initialize_failed }}, out.effects());
}

test "a new process detects again; nothing goes out before detection finishes" {
    var d: Detector = .init(test_config);
    var out: Output = .{};
    try testing.expectError(error.NotReady, d.step(.operation_sent, &out));
    try d.step(.process_started, &out);
    try d.step(.detect_requested, &out);
    try d.step(.{ .discover_result = .{ .preferred = 1 } }, &out);
    try d.step(.process_started, &out);
    try testing.expectEqual(State.unknown, d.state);
    try testing.expectError(error.NotReady, d.step(.operation_sent, &out));
}

test "classifies answers by their content" {
    const cases = [_]struct { []const u8, Event }{
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"supportedVersions\":[\"2027-01-01\",\"2025-11-25\"]}}", .{ .discover_result = .{ .preferred = 0b10, .legacy = true } } },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", .legacy_answer },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"x\",\"data\":{\"supported\":[\"2026-07-28\"]}}}", .{ .unsupported_version = .{ .preferred = 1 } } },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"x\"}}", .{ .unsupported_version = .{} } },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32021,\"message\":\"x\"}}", .modern_rejection },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}", .legacy_answer },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32001,\"message\":\"x\"}}", .legacy_answer },
    };
    for (cases) |case| try testing.expectEqual(case[1], classifyDiscover(test_config, (try wire.decode(case[0])).response.body));

    const init_cases = [_]struct { []const u8, Event }{
        .{ "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"protocolVersion\":\"2025-11-25\"}}", .{ .initialize_result = .{ .legacy = 0 } } },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"protocolVersion\":\"2025-06-18\"}}", .{ .initialize_result = .{ .legacy = 1 } } },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"protocolVersion\":\"2025-03-26\"}}", .{ .initialize_result = .{ .legacy = 2 } } },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"protocolVersion\":\"2024-11-05\"}}", .{ .initialize_result = .other } },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}", .{ .initialize_error = false } },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32602,\"message\":\"use 2026-07-28\"}}", .{ .initialize_error = true } },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32022,\"message\":\"x\"}}", .{ .initialize_error = true } },
    };
    for (init_cases) |case| try testing.expectEqual(case[1], classifyInitialize(test_config, (try wire.decode(case[0])).response.body));
}

test "over HTTP, 404 with -32601 to the probe is a modern server without discovery" {
    const not_found = (try wire.decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}")).response.body;
    try testing.expectEqual(Event.discover_not_implemented, classifyDiscoverHttp(test_config, 404, not_found));
    try testing.expectEqual(Event.legacy_answer, classifyDiscoverHttp(test_config, 200, not_found));
    try testing.expectEqual(Event.legacy_answer, classifyDiscoverHttp(test_config, 400, null));
    var d: Detector = .init(test_config);
    var out: Output = .{};
    try d.step(.process_started, &out);
    try d.step(.detect_requested, &out);
    try d.step(.discover_not_implemented, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .ready = .{ .preferred = 0 } }}, out.effects());
    // The first request learns the real versions.
    try d.step(.{ .operation_version_rejected = .{ .preferred = 0b10 } }, &out);
    try testing.expectEqualSlices(Effect, &.{.{ .ready = .{ .preferred = 1 } }}, out.effects());
}

test "writes the detection messages" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const client: Client = .{ .info = .{ .name = "fx", .version = "1.0.0" } };
    try writeDiscover(&out.writer, test_config, client, 0, 1);
    try out.writer.writeByte('\n');
    try writeInitialize(&out.writer, test_config, client, 2);
    try out.writer.writeByte('\n');
    try writeInitialized(&out.writer);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{\"_meta\":{\"progressToken\":1," ++
            "\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}," ++
            "\"io.modelcontextprotocol/clientInfo\":{\"name\":\"fx\",\"version\":\"1.0.0\"}}}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{\"_meta\":{\"progressToken\":2}," ++
            "\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"fx\",\"version\":\"1.0.0\"}}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}",
        out.written(),
    );
}
