//! Shared MCP servers as the session sees them (8b of the plan,
//! `tests/tla/mcp_host/SharedServers.tla`): an adapter that speaks the owner's
//! wire and gives the runtime the same `engine.Event` values it gets from its
//! own engine. The runtime only routes by server name, so a shared server
//! needs no second event path.
//!
//! A shared server's calls get handles from `0x8000_0000 | n`: the engine's
//! handles count up from 1 and stay far below 2^31 in one process, so the two
//! never meet in the runtime's `calls` map.
const std = @import("std");
const mcp = @import("../../mcp/mcp.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const owner_client = @import("owner_client.zig");
const owner_wire = @import("owner_wire.zig");
const share_key = @import("share_key.zig");
const json_decode = @import("../shared/json_decode.zig");

const Allocator = std.mem.Allocator;
const engine = mcp.engine;
const tools = @import("../../mcp/protocol/tools.zig");
const wire = owner_wire;

/// The list for a server this adapter does not have, as `Engine.toolList` returns.
const empty_list: tools.List = .{};

/// The bit that keeps a shared call's handle away from the engine's.
const handle_base: engine.Handle = 0x8000_0000;

pub const Error = Allocator.Error || error{
    /// No owner answered, or it answered with another wire version.
    SharingUnavailable,
};

pub const Options = struct {
    io: std.Io,
    gpa: Allocator,
    /// The profile's folder, `~/.fx` or `$FX_HOME`.
    fx_home: []const u8,
    /// Whether this session may start an owner; a test serves one instead.
    spawn_owner: bool = true,
    /// What this session can show a 2025 question, told to the owner so a
    /// server never asks a session that cannot answer.
    ask_form: bool = true,
    ask_url: bool = true,
    /// Wakes the runtime's owner thread when a frame arrives.
    wake: owner_client.Wake,
};

/// One shared server: its key, the config the owner runs, and what the owner
/// last said about it.
pub const Slot = struct {
    name: []const u8,
    key: share_key.Key,
    config: engine.Config,
    registered: bool = false,
    phase: engine.Phase = .idle,
    version: ?[]u8 = null,
    last_error: ?[]u8 = null,
    stderr_tail: ?[]u8 = null,
    instructions: ?[]u8 = null,
    /// How the last process ended, and the stdout line that answered
    /// nothing, as the engine keeps them for a failure's text.
    exit: ?mcp.stdio.Exit = null,
    stray_line: ?[]u8 = null,
    tools_store: tools.Store = .{},
    needing: bool = false,
};

pub const Shared = struct {
    io: std.Io,
    gpa: Allocator,
    options: Options,
    client: owner_client.Client,
    slots: std.ArrayList(Slot) = .empty,
    /// The owner's id for a call, to its server.
    calls: std.AutoHashMapUnmanaged(u32, usize) = .empty,
    next_id: u32 = 1,
    /// Events built from the frame being taken; they share `arena`.
    pending: std.ArrayList(engine.Event) = .empty,
    arena: std.heap.ArenaAllocator,
    disconnected: bool = false,

    pub fn init(options: Options) Error!Shared {
        var client = owner_client.Client.init(options.io, options.gpa, options.fx_home, options.spawn_owner, options.wake) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SharingUnavailable,
        };
        errdefer client.deinit();
        return .{
            .io = options.io,
            .gpa = options.gpa,
            .options = options,
            .client = client,
            .arena = .init(options.gpa),
        };
    }

    /// Starts a slot for one shared server. The config is the engine config
    /// `config.resolve` built, so the owner runs exactly what this session
    /// would have run.
    pub fn add(s: *Shared, name: []const u8, config: engine.Config) Allocator.Error!void {
        try s.slots.append(s.gpa, .{ .name = name, .key = share_key.of(config), .config = config });
    }

    pub fn has(s: *const Shared, name: []const u8) bool {
        return s.index(name) != null;
    }

    /// Whether `handle` is a call this adapter sent to the owner.
    pub fn owns(s: *Shared, handle: engine.Handle) bool {
        return s.slotOfHandle(handle) != null;
    }

    /// The key the server registered under: its launch config's.
    pub fn keyOf(s: *const Shared, name: []const u8) ?share_key.Key {
        for (s.slots.items) |slot| if (std.mem.eql(u8, slot.name, name)) return slot.key;
        return null;
    }

    /// The config the server registered, which runs in this session when the
    /// owner cannot.
    pub fn configOf(s: *const Shared, name: []const u8) ?engine.Config {
        for (s.slots.items) |slot| if (std.mem.eql(u8, slot.name, name)) return slot.config;
        return null;
    }

    /// Drops the server's slot: this session's calls on it end as cancelled,
    /// for `take`, and the owner keeps the server for every other session
    /// until this one says goodbye.
    pub fn remove(s: *Shared, name: []const u8) void {
        const i = s.index(name) orelse return;
        const slot = &s.slots.items[i];
        // It stops using the key: the owner cancels this session's calls there
        // and stops the server once no session is left on it.
        if (slot.registered and !s.disconnected) s.client.send(.{ .unregister = .{ .key = slot.key } }) catch |err| {
            // The owner stops the server when this connection closes; say the
            // unregister that would have stopped it sooner didn't go.
            debug_trace.logf("mcp", "shared unregister not sent server={s} err={s}", .{ name, @errorName(err) });
        };
        // A call that still waits ends as cancelled for `take`, and any late
        // answer from the owner names a call the adapter no longer has.
        while (true) {
            var found: ?u32 = null;
            var it = s.calls.iterator();
            while (it.next()) |entry| if (entry.value_ptr.* == i) {
                found = entry.key_ptr.*;
                break;
            };
            const id = found orelse break;
            _ = s.calls.remove(id);
            s.pending.append(s.gpa, .{ .server = slot.name, .kind = .{ .called = .{
                .call = handle_base | id,
                .outcome = .cancelled,
                .maybe_ran = true,
                .timed_out = false,
                .answer = null,
            } } }) catch |err| {
                // This session's call on the slot would have ended here;
                // without the event its caller waits for its deadline.
                debug_trace.logf("mcp", "shared call end dropped server={s} reason=out of memory err={s}", .{ slot.name, @errorName(err) });
            };
        }
        slot.tools_store.deinit(s.gpa);
        if (slot.version) |v| s.gpa.free(v);
        if (slot.last_error) |v| s.gpa.free(v);
        if (slot.stderr_tail) |v| s.gpa.free(v);
        if (slot.instructions) |v| s.gpa.free(v);
        if (slot.stray_line) |v| s.gpa.free(v);
        _ = s.slots.orderedRemove(i);
        // The calls left point at slots after this one, which moved back.
        var rest = s.calls.valueIterator();
        while (rest.next()) |v| if (v.* > i) {
            v.* -= 1;
        };
    }

    fn index(s: *const Shared, name: []const u8) ?usize {
        for (s.slots.items, 0..) |slot, i| if (std.mem.eql(u8, slot.name, name)) return i;
        return null;
    }

    fn slotOf(s: *Shared, name: []const u8) ?*Slot {
        const i = s.index(name) orelse return null;
        return &s.slots.items[i];
    }

    fn slotOfHandle(s: *Shared, handle: engine.Handle) ?*Slot {
        if (handle & handle_base == 0) return null;
        const id: u32 = @intCast(handle & (handle_base - 1));
        const i = s.calls.get(id) orelse return null;
        return &s.slots.items[i];
    }

    /// Connects and registers the server, on the caller's thread. 3 s covers
    /// the owner's own start; the server's start is the engine's later wait.
    fn ensure(s: *Shared, name: []const u8) Error!*Slot {
        const i = s.index(name) orelse return error.SharingUnavailable;
        const slot = &s.slots.items[i];
        if (slot.registered and !s.disconnected) return slot;
        s.client.ensureReady(3_000) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                debug_trace.logf("mcp", "shared server unavailable server={s} reason={s}", .{ name, @errorName(err) });
                return error.SharingUnavailable;
            },
        };
        s.disconnected = false;
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const config = try wireConfig(arena.allocator(), slot.config);
        s.client.send(.{ .register = .{
            .key = slot.key,
            .config = config,
            .ask_form = s.options.ask_form,
            .ask_url = s.options.ask_url,
        } }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SharingUnavailable,
        };
        slot.registered = true;
        return slot;
    }

    pub fn needTools(s: *Shared, name: []const u8) Error!void {
        const slot = try s.ensure(name);
        slot.needing = true;
        s.client.send(.{ .need = .{ .key = slot.key } }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SharingUnavailable,
        };
    }

    /// The server must list again after a new login: the owner's `need` asks
    /// for a fresh list, and registers again when the connection went away
    /// first.
    pub fn reconnect(s: *Shared, name: []const u8) Error!void {
        return s.needTools(name);
    }

    /// This session stops using the server. Only its own registration goes:
    /// the owner keeps the server for every other session, and stops it when
    /// the last one leaves.
    pub fn disconnect(s: *Shared, name: []const u8) void {
        const slot = s.slotOf(name) orelse return;
        slot.registered = false;
    }

    /// The tools the owner last published for this server.
    pub fn toolList(s: *Shared, name: []const u8) *const tools.List {
        const slot = s.slotOf(name) orelse return &empty_list;
        return &slot.tools_store.current;
    }

    pub fn call(s: *Shared, name: []const u8, tool: []const u8, arguments: ?[]const u8) Error!engine.Handle {
        const slot = try s.ensure(name);
        const id = s.next_id;
        s.next_id += 1;
        try s.calls.put(s.gpa, id, s.index(name).?);
        errdefer _ = s.calls.remove(id);
        s.client.send(.{ .call = .{ .key = slot.key, .id = id, .tool = tool, .arguments = arguments } }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                _ = s.calls.remove(id);
                return error.SharingUnavailable;
            },
        };
        return handle_base | id;
    }

    /// True at once: the owner keeps the call, and the host may answer its
    /// input request or cancel it from the moment it is sent, so waiting for
    /// a second round trip would only drop answers.
    pub fn callSent(_: *const Shared, _: engine.Handle) bool {
        return true;
    }

    pub fn cancel(s: *Shared, handle: engine.Handle) void {
        const id = sharedId(handle) orelse return;
        // The session asked to end this call: say when the owner didn't hear,
        // since the call then runs on for its deadline.
        s.client.send(.{ .cancel = .{ .id = id } }) catch |err| {
            debug_trace.logf("mcp", "shared cancel not sent id={d} err={s}", .{ id, @errorName(err) });
        };
    }

    pub fn respond(s: *Shared, alloc: Allocator, handle: engine.Handle, values: []const []const u8) Allocator.Error!void {
        const id = sharedId(handle) orelse return;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        std.json.Stringify.value(values, .{}, &out.writer) catch return error.OutOfMemory;
        // The session's answer to a 2026 input request: say when the owner
        // didn't hear, since the call then ends as unsupported input.
        s.client.send(.{ .respond = .{ .id = id, .values = out.written() } }) catch |err| {
            debug_trace.logf("mcp", "shared respond not sent id={d} err={s}", .{ id, @errorName(err) });
        };
    }

    pub fn answerElicitation(s: *Shared, name: []const u8, id: mcp.core.elicitation.Id, answer: mcp.elicitation.Answer) void {
        const slot = s.slotOf(name) orelse return;
        // The user's answer to a 2025 question: say when the owner didn't hear,
        // since the server waits for it until the question is withdrawn.
        s.client.send(.{ .answer = .{ .key = slot.key, .slot = id.slot, .n = id.n, .action = answer.action, .content = answer.content } }) catch |err| {
            debug_trace.logf("mcp", "shared answer not sent server={s} err={s}", .{ name, @errorName(err) });
        };
    }

    pub fn status(s: *Shared, name: []const u8) engine.Status {
        const slot = s.slotOf(name) orelse unreachable;
        return .{
            .name = name,
            .transport = .stdio,
            .phase = slot.phase,
            .version = slot.version,
            .tools = slot.tools_store.current.len(),
            .last_error = slot.last_error,
            .exit = slot.exit,
            .stray_line = slot.stray_line,
        };
    }

    pub fn stderrTail(s: *Shared, name: []const u8, out: *[mcp.stdio.tail_max]u8) ?[]const u8 {
        _ = out;
        const slot = s.slotOf(name) orelse return null;
        return slot.stderr_tail;
    }

    pub fn instructions(s: *Shared, name: []const u8) ?[]const u8 {
        const slot = s.slotOf(name) orelse return null;
        return slot.instructions;
    }

    /// The next event, or null. Event slices stay valid until the next take,
    /// like the engine's `next`.
    pub fn take(s: *Shared) ?engine.Event {
        while (true) {
            if (s.pending.items.len > 0) return s.pending.orderedRemove(0);
            _ = s.arena.reset(.retain_capacity);
            s.pending.clearRetainingCapacity();
            var frames: std.ArrayList([]u8) = .empty;
            s.client.takeFrames(&frames);
            defer frames.deinit(s.gpa);
            if (frames.items.len == 0) {
                if (s.client.isClosed() and !s.disconnected) {
                    s.disconnected = true;
                    for (s.slots.items) |*slot| slot.registered = false;
                    s.buildSlackEvents();
                    if (s.pending.items.len > 0) continue;
                }
                return null;
            }
            for (frames.items) |payload| {
                defer s.gpa.free(payload);
                s.frame(payload);
            }
        }
    }

    /// A dropped connection: each call in flight may have run, and each
    /// listing in flight failed.
    fn buildSlackEvents(s: *Shared) void {
        var it = s.calls.iterator();
        while (it.next()) |entry| {
            s.pending.append(s.gpa, .{
                .server = s.slots.items[entry.value_ptr.*].name,
                .kind = .{ .called = .{
                    .call = handle_base | entry.key_ptr.*,
                    .outcome = .lost,
                    .maybe_ran = true,
                    .timed_out = false,
                    .answer = null,
                } },
            }) catch return;
        }
        s.calls.clearRetainingCapacity();
        for (s.slots.items) |*slot| {
            if (!slot.needing) continue;
            slot.needing = false;
            s.pending.append(s.gpa, .{ .server = slot.name, .kind = .{ .server = .{ .tools = .{ .ok = false, .fresh = false } } } }) catch return;
        }
    }

    fn frame(s: *Shared, payload: []const u8) void {
        const a = s.arena.allocator();
        const message = wire.decode(a, payload) catch {
            debug_trace.logf("mcp", "shared server frame dropped kind=unknown reason=malformed", .{});
            return;
        };
        const said = switch (message) {
            .owner => |from_owner| from_owner,
            .client => {
                debug_trace.logf("mcp", "shared server frame dropped kind=client reason=wrong direction", .{});
                return;
            },
        };
        switch (said) {
            .welcome => {},
            .phase => |update| {
                const i = s.indexByKey(update.key) orelse {
                    debug_trace.logf("mcp", "shared server frame dropped kind=phase reason=unknown key", .{});
                    return;
                };
                const slot = &s.slots.items[i];
                slot.phase = update.phase;
                // The runtime ends tool waiters and checks logins on a phase
                // event, so a failed start must reach it, not just the slot.
                s.pending.append(s.gpa, .{ .server = slot.name, .kind = .{ .phase = update.phase } }) catch return;
            },
            .status => |update| {
                const i = s.indexByKey(update.key) orelse {
                    debug_trace.logf("mcp", "shared server frame dropped kind=status reason=unknown key", .{});
                    return;
                };
                const slot = &s.slots.items[i];
                slot.phase = update.phase;
                replace(s.gpa, &slot.version, update.version);
                replace(s.gpa, &slot.last_error, update.last_error);
                replace(s.gpa, &slot.stderr_tail, update.stderr_tail);
                replace(s.gpa, &slot.instructions, update.instructions);
                slot.exit = if (update.exit_code) |code| .{ .code = code } else if (update.exit_signal) |signal| .{ .signal = signal } else null;
                replace(s.gpa, &slot.stray_line, update.stray_line);
            },
            .tools => |page| {
                const i = s.indexByKey(page.key) orelse {
                    debug_trace.logf("mcp", "shared server frame dropped kind=tools reason=unknown key", .{});
                    return;
                };
                const slot = &s.slots.items[i];
                // A listing replaces the list, even with none: an old list
                // must not outlive the server saying it has no tools. A
                // failed listing keeps the last one.
                if (page.ok) {
                    slot.tools_store.discard();
                    // The wire carries the raw tool objects; a page is a
                    // `tools/list` result, so wrap them as one.
                    const result = a.print("{{\"tools\":{s}}}", .{page.tools}) catch null;
                    const parsed = if (result) |text| tools.parsePage(text) catch null else null;
                    if (parsed) |parsed_page| {
                        // Only out of memory fails here; the session then sees
                        // the list this frame could not replace.
                        _ = slot.tools_store.addPage(s.gpa, parsed_page) catch |err| {
                            debug_trace.logf("mcp", "shared tool list dropped server={s} reason=out of memory err={s}", .{ slot.name, @errorName(err) });
                        };
                    }
                    slot.tools_store.publish();
                }
                slot.needing = false;
                s.pending.append(s.gpa, .{ .server = slot.name, .kind = .{ .server = .{ .tools = .{ .ok = page.ok, .fresh = page.fresh, .needs_auth = page.needs_auth } } } }) catch return;
            },
            .called => |called| {
                const i = s.calls.get(called.id) orelse {
                    debug_trace.logf("mcp", "shared server frame dropped kind=called reason=unknown call id={d}", .{called.id});
                    return;
                };
                _ = s.calls.remove(called.id);
                const slot = &s.slots.items[i];
                var answer: ?tools.Call = null;
                if (called.answer) |text| {
                    if (json_decode.parseFromSlice(tools.Call, a, text, .{})) |parsed| {
                        answer = parsed.value;
                    } else |_| {}
                }
                s.pending.append(s.gpa, .{ .server = slot.name, .kind = .{ .called = .{
                    .call = handle_base | called.id,
                    .outcome = called.outcome,
                    .maybe_ran = called.maybe_ran,
                    .timed_out = called.timed_out,
                    .answer = answer,
                    .oversized = called.oversized,
                    .refused_bytes = called.refused_bytes,
                    .refused_body = called.refused_body,
                } } }) catch return;
            },
            .progress => |progress| {
                const i = s.calls.get(progress.id) orelse {
                    debug_trace.logf("mcp", "shared server frame dropped kind=progress reason=unknown call id={d}", .{progress.id});
                    return;
                };
                s.pending.append(s.gpa, .{ .server = s.slots.items[i].name, .kind = .{ .progress = .{
                    .call = handle_base | progress.id,
                    .progress = progress.progress,
                    .total = progress.total,
                    .message = progress.message,
                } } }) catch return;
            },
            .input => |input| {
                const i = s.calls.get(input.id) orelse {
                    debug_trace.logf("mcp", "shared server frame dropped kind=input reason=unknown call id={d}", .{input.id});
                    return;
                };
                const parsed = json_decode.parseFromSlice([]mcp.mrtr.Request, a, input.requests, .{}) catch {
                    debug_trace.logf("mcp", "shared server frame dropped kind=input reason=malformed requests", .{});
                    return;
                };
                s.pending.append(s.gpa, .{ .server = s.slots.items[i].name, .kind = .{ .input = .{
                    .call = handle_base | input.id,
                    .requests = parsed.value,
                } } }) catch return;
            },
            .question => |question| {
                const i = s.indexByKey(question.key) orelse {
                    debug_trace.logf("mcp", "shared server frame dropped kind=question reason=unknown key", .{});
                    return;
                };
                s.pending.append(s.gpa, .{ .server = s.slots.items[i].name, .kind = .{ .server = .{ .elicit = .{
                    .id = .{ .slot = question.slot, .n = question.n },
                    .params = question.params,
                    .required = question.required,
                } } } }) catch return;
            },
            .elicitation_complete => |done| {
                const i = s.indexByKey(done.key) orelse {
                    debug_trace.logf("mcp", "shared server frame dropped kind=elicitation_complete reason=unknown key", .{});
                    return;
                };
                s.pending.append(s.gpa, .{ .server = s.slots.items[i].name, .kind = .{ .server = .{ .elicitation_complete = done.slot } } }) catch return;
            },
            .elicit_withdrawn => |gone| {
                const i = s.indexByKey(gone.key) orelse {
                    debug_trace.logf("mcp", "shared server frame dropped kind=elicit_withdrawn reason=unknown key", .{});
                    return;
                };
                s.pending.append(s.gpa, .{ .server = s.slots.items[i].name, .kind = .{ .server = .{ .elicit_withdrawn = gone.slot } } }) catch return;
            },
            .declined => {},
            .stopped_idle => |stopped| {
                const i = s.indexByKey(stopped.key) orelse {
                    debug_trace.logf("mcp", "shared server frame dropped kind=stopped_idle reason=unknown key", .{});
                    return;
                };
                s.pending.append(s.gpa, .{ .server = s.slots.items[i].name, .kind = .stopped_idle }) catch return;
            },
        }
    }

    fn indexByKey(s: *Shared, key: share_key.Key) ?usize {
        for (s.slots.items, 0..) |slot, i| if (std.mem.eql(u8, &slot.key, &key)) return i;
        return null;
    }

    pub fn deinit(s: *Shared) void {
        s.client.deinit();
        for (s.slots.items) |*slot| {
            slot.tools_store.deinit(s.gpa);
            if (slot.version) |v| s.gpa.free(v);
            if (slot.last_error) |v| s.gpa.free(v);
            if (slot.stderr_tail) |v| s.gpa.free(v);
            if (slot.instructions) |v| s.gpa.free(v);
            if (slot.stray_line) |v| s.gpa.free(v);
        }
        s.slots.deinit(s.gpa);
        s.calls.deinit(s.gpa);
        s.pending.deinit(s.gpa);
        s.arena.deinit();
    }
};

fn sharedId(handle: engine.Handle) ?u32 {
    if (handle & handle_base == 0) return null;
    return @intCast(handle & (handle_base - 1));
}

/// Replaces a slot's text, freeing what it held: a status frame may come
/// many times for one server.
fn replace(gpa: Allocator, field: *?[]u8, text: ?[]const u8) void {
    const next = dupOrNull(gpa, text);
    if (field.*) |old| gpa.free(old);
    field.* = next;
}

fn dupOrNull(gpa: Allocator, text: ?[]const u8) ?[]u8 {
    const value = text orelse return null;
    return gpa.dupe(u8, value) catch null;
}

/// The engine config as the owner's register message carries it.
fn wireConfig(a: Allocator, config: engine.Config) Allocator.Error!wire.ServerConfig {
    const stdio = config.transport.stdio;
    var env: std.ArrayList(wire.ServerConfig.Entry) = .empty;
    if (stdio.environ_map) |map| {
        var it = map.iterator();
        while (it.next()) |entry| try env.append(a, .{ .name = try a.dupe(u8, entry.key_ptr.*), .value = try a.dupe(u8, entry.value_ptr.*) });
    }
    return .{
        .argv = try a.dupe([]const u8, stdio.argv),
        .env = env.items,
        .cwd = if (stdio.cwd) |cwd| try a.dupe(u8, cwd) else null,
        .timeouts = if (config.timeouts) |t| .{
            .start_ms = t.start_ms,
            .idle_ms = t.idle_ms,
            .hard_ms = t.hard_ms,
            .reset_idle_on_progress = t.reset_idle_on_progress,
            .refresh_ms = t.refresh_ms,
            .refused_ms = t.refused_ms,
        } else null,
        .auth = .{
            .client_id = if (config.auth.client_id) |v| try a.dupe(u8, v) else null,
            .client_secret = if (config.auth.client_secret) |v| try a.dupe(u8, v) else null,
            .client_metadata_url = if (config.auth.client_metadata_url) |v| try a.dupe(u8, v) else null,
            .resource = if (config.auth.resource) |v| try a.dupe(u8, v) else null,
            .scopes = if (config.auth.scopes) |v| try a.dupe(u8, v) else null,
            .client_name = try a.dupe(u8, config.auth.client_name),
        },
    };
}

const testing = std.testing;
const owner = @import("owner.zig");
const fake_server = @import("fake_server.zig");

/// Removes a test's folder. Cleanup only: a folder that won't go leaves
/// nothing the test asserts on, and the system clears /tmp.
fn removeTestDir(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(testing.io, path) catch {}; // Cleanup only: nothing the test asserts on depends on the folder.
}

fn shortHome(alloc: Allocator, tag: []const u8) ![]u8 {
    const path = try alloc.print("/tmp/fx-shared-{s}-{d}", .{ tag, std.c.getpid() });
    removeTestDir(path);
    try std.Io.Dir.cwd().createDir(testing.io, path, .fromMode(0o700));
    return path;
}

fn serveOnThread(io: std.Io, gpa: Allocator, home: []const u8, stop: *std.atomic.Value(bool)) void {
    // An owner that ends with an error is what a test's stop asks for; the
    // test fails on the state it checks, not on this thread.
    owner.serve(io, gpa, home, stop) catch {};
}

fn waitForSocket(alloc: Allocator, home: []const u8) ![]u8 {
    const path = try std.Io.Dir.path.join(alloc, &.{ home, owner.run_dir_name, owner.socket_name });
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 5_000;
    while (std.Io.Clock.awake.now(testing.io).toMilliseconds() < deadline) {
        const address = std.Io.net.UnixAddress.init(path) catch return error.NameTooLong;
        if (address.connect(testing.io)) |stream| {
            stream.close(testing.io);
            return path;
        } else |_| {
            // Polls for the socket the test's owner thread is opening.
            testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
    }
    return error.SocketNeverAppeared;
}

fn wakeNothing(_: *anyopaque) void {}

fn sharedFor(alloc: Allocator, home: []const u8, woken: *u8) !Shared {
    return Shared.init(.{
        .io = testing.io,
        .gpa = alloc,
        .fx_home = home,
        .spawn_owner = false,
        .wake = .{ .context = woken, .wake = wakeNothing },
    });
}

/// The next event for `name`, whatever it is, or null at the deadline.
fn takeFor(s: *Shared, name: []const u8, deadline_ms: i64) ?engine.Event {
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + deadline_ms;
    while (std.Io.Clock.awake.now(testing.io).toMilliseconds() < deadline) {
        if (s.take()) |event| {
            if (std.mem.eql(u8, event.server, name)) return event;
        } else {
            // Polls for the next event from the owner, bounded above.
            testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
    }
    return null;
}

fn takeTools(s: *Shared, name: []const u8) !bool {
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 10_000;
    while (std.Io.Clock.awake.now(testing.io).toMilliseconds() < deadline) {
        const event = takeFor(s, name, 200) orelse continue;
        switch (event.kind) {
            .server => |server| switch (server) {
                .tools => |tools_event| return tools_event.ok,
                else => {},
            },
            else => {},
        }
    }
    return error.NoToolsEvent;
}

fn takeCalled(s: *Shared, name: []const u8, handle: engine.Handle) !engine.Event {
    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 10_000;
    while (std.Io.Clock.awake.now(testing.io).toMilliseconds() < deadline) {
        const event = takeFor(s, name, 200) orelse continue;
        switch (event.kind) {
            .called => |called| if (called.call == handle) return event,
            else => {},
        }
    }
    return error.NoCalledEvent;
}

fn resultContent(event: engine.Event) ![]const u8 {
    return switch (event.kind.called.answer.?) {
        .result => |result| result.content,
        else => error.NotAResult,
    };
}

fn pidOf(content: []const u8) ![]const u8 {
    const at = std.mem.find(u8, content, "pid=") orelse return error.NoPid;
    const rest = content[at + 4 ..];
    const end = std.mem.findNone(u8, rest, "0123456789") orelse rest.len;
    return rest[0..end];
}

test "a shared server lists its tools through the owner" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc, "tools");
    defer {
        removeTestDir(home);
        alloc.free(home);
    }
    var fixture: fake_server.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var stop = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, serveOnThread, .{ testing.io, alloc, home, &stop });
    var joined = false;
    defer if (!joined) {
        stop.store(true, .release);
        thread.join();
    };
    const path = try waitForSocket(alloc, home);
    defer alloc.free(path);

    var woken: u8 = 0;
    var shared = try sharedFor(alloc, home, &woken);
    defer shared.deinit();
    const argv = [_][]const u8{fixture.server};
    try shared.add("fake", .{ .name = "fake", .transport = .{ .stdio = .{ .argv = &argv } }, .timeouts = .{ .start_ms = 15_000 } });
    try shared.needTools("fake");
    try testing.expect(try takeTools(&shared, "fake"));
    try testing.expect(shared.toolList("fake").find("echo") != null);
    // Every pending event is taken before the phase is read: a status frame
    // can arrive after the tool list.
    while (shared.take()) |_| {}
    try testing.expectEqual(engine.Phase.ready, shared.status("fake").phase);

    stop.store(true, .release);
    thread.join();
    joined = true;
}

test "a call through the owner answers, and two sessions get one process" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc, "call");
    defer {
        removeTestDir(home);
        alloc.free(home);
    }
    var fixture: fake_server.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var stop = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, serveOnThread, .{ testing.io, alloc, home, &stop });
    var joined = false;
    defer if (!joined) {
        stop.store(true, .release);
        thread.join();
    };
    const path = try waitForSocket(alloc, home);
    defer alloc.free(path);

    var woken_a: u8 = 0;
    var woken_b: u8 = 0;
    var first = try sharedFor(alloc, home, &woken_a);
    var second = try sharedFor(alloc, home, &woken_b);
    const argv = [_][]const u8{fixture.server};
    try first.add("fake", .{ .name = "fake", .transport = .{ .stdio = .{ .argv = &argv } }, .timeouts = .{ .start_ms = 15_000 } });
    try second.add("fake", .{ .name = "fake", .transport = .{ .stdio = .{ .argv = &argv } }, .timeouts = .{ .start_ms = 15_000 } });
    const first_call = try first.call("fake", "echo", "{\"text\":\"pid\"}");
    const first_event = try takeCalled(&first, "fake", first_call);
    const second_call = try second.call("fake", "echo", "{\"text\":\"pid\"}");
    const second_event = try takeCalled(&second, "fake", second_call);
    try testing.expectEqualStrings(try pidOf(try resultContent(first_event)), try pidOf(try resultContent(second_event)));

    first.deinit();
    second.deinit();
    stop.store(true, .release);
    thread.join();
    joined = true;
}

test "an owner that goes away ends a call in flight as lost" {
    const alloc = testing.allocator;
    const home = try shortHome(alloc, "lost");
    defer {
        removeTestDir(home);
        alloc.free(home);
    }
    var fixture: fake_server.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var stop = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, serveOnThread, .{ testing.io, alloc, home, &stop });
    const path = try waitForSocket(alloc, home);
    defer alloc.free(path);

    var woken: u8 = 0;
    var shared = try sharedFor(alloc, home, &woken);
    defer shared.deinit();
    const argv = [_][]const u8{fixture.server};
    try shared.add("fake", .{ .name = "fake", .transport = .{ .stdio = .{ .argv = &argv } }, .timeouts = .{ .start_ms = 15_000 } });
    const handle = try shared.call("fake", "echo", "{\"text\":\"slow\"}");
    // The call must be in flight when the owner stops, and the owner tells the
    // session nothing when it takes the call.
    testing.io.sleep(.fromMilliseconds(200), .awake) catch {};
    stop.store(true, .release);
    thread.join();

    const deadline = std.Io.Clock.awake.now(testing.io).toMilliseconds() + 10_000;
    var lost = false;
    while (std.Io.Clock.awake.now(testing.io).toMilliseconds() < deadline) {
        if (shared.take()) |event| {
            switch (event.kind) {
                .called => |called| if (called.call == handle) {
                    try testing.expectEqual(engine.Outcome.lost, called.outcome);
                    lost = called.maybe_ran;
                },
                else => {},
            }
            if (lost) break;
        } else {
            // Polls for the lost call's event, bounded by the deadline above.
            testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
    }
    try testing.expect(lost);
}

test "an fx home whose socket path is too long cannot share" {
    // The adapter refuses it at start, so the session runs every server
    // itself rather than failing.
    const long = "/tmp/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/home";
    var woken: u8 = 0;
    try testing.expectError(error.SharingUnavailable, sharedFor(testing.allocator, long, &woken));
}
