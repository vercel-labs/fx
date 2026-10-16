//! U12 lab: runs a script of host actions against `mcp.engine`, playing the
//! host: its permission answers, its stderr sink, and what it does with each
//! event. One run traces every server's machines into one file, the engine
//! gate's under the server's name and each server's under "<name>.". Dev
//! only; never moves into fx.
//!
//! Usage: engine_lab <trace-path> <script> [--deny TOOL]... [--capabilities JSON]
//!          [--max-attempts N] [--no-listen] [--preferred V1,V2] [--probe-ms N]
//!          [--timeout-ms IDLE] [--hard-ms N]
//!          [--define NAME=VALUE]... (each {NAME} in the script becomes VALUE)
//!
//! Script, one action per line (blank lines and lines starting with # are skipped):
//!   server <name> stdio <argv-json>        declare a server; before the first action
//!   server <name> http <url>               they are the engine's, after it `reload` uses them
//!   tools <name> | disconnect <name> | reconnect <name>
//!   call <name> <tool> [arguments-json]    calls are numbered from 1 in this order
//!   cancel <k> | respond <k> <values-json-array>
//!   elicit <name> <slot> accept|decline|cancel [content-json]
//!   reload <name>...                       the declared servers to keep or add, in order
//!   status
//!   expect <tag-prefix> [timeout_ms]       an event whose tag starts so, seen and not yet
//!                                          expected, or the next one (default 10000)
//!   drain <ms>                             handle whatever arrives for that long; what was
//!                                          seen is no longer expected
//!
//! Event tags: <server>.phase.<phase>, <server>.called.<k>.<outcome>,
//! <server>.input.<k>, <server>.<server event>[.ok|.fail], for example
//! "a.tools.ok" or "b.elicit". Output lines: {"did":...}, {"allow":...},
//! {"event":...}, {"status":[...]}, and one {"final":...} with the stderr
//! lines each server's sink took. Exit: 0 the script ran, 1 an expectation
//! wasn't met, 2 usage.

const std = @import("std");
const mcp = @import("mcp");
const engine = mcp.engine;

/// Trace code is compiled in.
pub const mcpv2_trace = true;

const max_servers = 8;

const Declared = struct {
    name: []const u8,
    transport: engine.Transport,
    /// Lines the stderr sink took, from reader tasks.
    logged: std.atomic.Value(u32) = .init(0),
};

const Lab = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    deny: []const []const u8,
    declared: [max_servers]Declared = undefined,
    count: usize = 0,
    e: ?*engine.Engine = null,
    /// Engine handles by call number.
    calls: std.ArrayList(engine.Handle) = .empty,
    /// The 2025 elicitations shown, in order; scripts name them from 1.
    elicits: std.ArrayList(mcp.core.elicitation.Id) = .empty,
    /// Tags of events no `expect` has claimed yet, so a script needn't
    /// know in which order two servers answer.
    unclaimed: std.ArrayList([]const u8) = .empty,

    fn print(lab: *Lab, comptime kind: []const u8, value: anytype) !void {
        var json: std.json.Stringify = .{ .writer = lab.out };
        try json.beginObject();
        try json.objectField(kind);
        try json.write(value);
        try json.endObject();
        try lab.out.writeByte('\n');
        try lab.out.flush();
    }

    fn allow(context: *anyopaque, server: []const u8, tool: []const u8, arguments: ?[]const u8) bool {
        const lab: *Lab = @ptrCast(@alignCast(context));
        _ = arguments;
        var ok = true;
        for (lab.deny) |d| ok = ok and !std.mem.eql(u8, d, tool);
        lab.print("allow", .{ .server = server, .tool = tool, .ok = ok }) catch {};
        return ok;
    }

    fn log(context: *anyopaque, server: []const u8, line: []const u8) void {
        const lab: *Lab = @ptrCast(@alignCast(context));
        _ = line;
        for (lab.declared[0..lab.count]) |*d| if (std.mem.eql(u8, d.name, server)) {
            _ = d.logged.fetchAdd(1, .monotonic);
        };
    }

    fn configs(lab: *Lab, names: []const []const u8) ![]engine.Config {
        const list = try lab.arena.alloc(engine.Config, names.len);
        for (names, list) |name, *c| {
            const d = lab.find(name) orelse return error.UnknownServer;
            c.* = .{ .name = d.name, .transport = d.transport };
        }
        return list;
    }

    fn find(lab: *Lab, name: []const u8) ?*Declared {
        var i = lab.count;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, lab.declared[i].name, name)) return &lab.declared[i];
        }
        return null;
    }

    fn number(lab: *const Lab, handle: engine.Handle) usize {
        for (lab.calls.items, 1..) |h, k| if (h == handle) return k;
        return 0;
    }

    fn tag(lab: *Lab, event: engine.Event) ![]const u8 {
        const s = event.server;
        return switch (event.kind) {
            .phase => |p| lab.arena.print("{s}.phase.{s}", .{ s, @tagName(p) }),
            .called => |c| lab.arena.print("{s}.called.{d}.{s}", .{ s, lab.number(c.call), @tagName(c.outcome) }),
            .input => |q| lab.arena.print("{s}.input.{d}", .{ s, lab.number(q.call) }),
            .server => |v| switch (v) {
                .tools => |t| lab.arena.print("{s}.tools.{s}", .{ s, if (t.ok) "ok" else "fail" }),
                else => lab.arena.print("{s}.{s}", .{ s, @tagName(v) }),
            },
        };
    }

    /// Prints one event, keeps its tag, and returns it.
    fn show(lab: *Lab, event: engine.Event) ![]const u8 {
        const t = try lab.tag(event);
        try lab.unclaimed.append(lab.arena, t);
        const e = lab.e.?;
        switch (event.kind) {
            .called => |c| {
                const answer: ?[]const u8 = if (c.answer) |a| switch (a) {
                    .result => |r| r.content,
                    .failure => |f| try lab.arena.print("error {d}", .{f.code}),
                    else => @tagName(a),
                } else null;
                try lab.print("event", .{ .tag = t, .maybe_ran = c.maybe_ran, .timed_out = c.timed_out, .answer = answer });
            },
            .input => |q| try lab.print("event", .{ .tag = t, .requests = q.requests.len }),
            .server => |v| switch (v) {
                .tools => {
                    const list = try e.toolList(event.server);
                    const names = try lab.arena.alloc([]const u8, list.len());
                    for (names, 0..) |*n, i| n.* = list.get(i).name;
                    try lab.print("event", .{ .tag = t, .names = names });
                },
                .elicit => |x| {
                    try lab.elicits.append(lab.gpa, x.id);
                    try lab.print("event", .{ .tag = t, .k = lab.elicits.items.len, .required = x.required });
                },
                .failed => |f| try lab.print("event", .{ .tag = t, .why = switch (f) {
                    .era => |why| @tagName(why),
                    else => @tagName(f),
                } }),
                else => try lab.print("event", .{ .tag = t }),
            },
            .phase => try lab.print("event", .{ .tag = t }),
        }
        return t;
    }

    fn claim(lab: *Lab, want: []const u8) bool {
        for (lab.unclaimed.items, 0..) |t, i| if (std.mem.startsWith(u8, t, want)) {
            _ = lab.unclaimed.orderedRemove(i);
            return true;
        };
        return false;
    }

    fn status(lab: *Lab) !void {
        const e = lab.e.?;
        const list = try lab.arena.alloc(engine.Status, e.len());
        for (list, 0..) |*s, i| s.* = e.status(i);
        try lab.print("status", list);
    }

    fn run(lab: *Lab, line: []const u8) !bool {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const action = words.next() orelse return true;
        if (std.mem.eql(u8, action, "server")) {
            const name = try lab.arena.dupe(u8, words.next() orelse return error.Usage);
            const kind = words.next() orelse return error.Usage;
            const rest = std.mem.trim(u8, words.rest(), " ");
            const transport: engine.Transport = if (std.mem.eql(u8, kind, "http"))
                .{ .http = .{ .url = try lab.arena.dupe(u8, rest) } }
            else
                .{ .stdio = .{ .argv = try std.json.parseFromSliceLeaky([]const []const u8, lab.arena, rest, .{}) } };
            if (lab.count == max_servers) return error.Usage;
            lab.declared[lab.count] = .{ .name = name, .transport = transport };
            lab.count += 1;
            try lab.print("did", .{ .action = "server", .name = name });
            return true;
        }
        const e = lab.e.?;
        if (std.mem.eql(u8, action, "tools")) {
            try e.needTools(words.next() orelse return error.Usage);
        } else if (std.mem.eql(u8, action, "disconnect")) {
            try e.disconnect(words.next() orelse return error.Usage);
        } else if (std.mem.eql(u8, action, "reconnect")) {
            try e.reconnect(words.next() orelse return error.Usage);
        } else if (std.mem.eql(u8, action, "call")) {
            const server = words.next() orelse return error.Usage;
            const tool = words.next() orelse return error.Usage;
            const args = std.mem.trim(u8, words.rest(), " ");
            const handle = try e.call(server, tool, if (args.len > 0) args else null);
            try lab.calls.append(lab.gpa, handle);
            try lab.print("did", .{ .action = "call", .k = lab.calls.items.len });
            return true;
        } else if (std.mem.eql(u8, action, "cancel")) {
            const k = try std.fmt.parseInt(usize, words.next() orelse return error.Usage, 10);
            try e.cancel(lab.calls.items[k - 1]);
        } else if (std.mem.eql(u8, action, "respond")) {
            const k = try std.fmt.parseInt(usize, words.next() orelse return error.Usage, 10);
            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lab.arena, words.rest(), .{});
            const values = try lab.arena.alloc([]const u8, parsed.array.items.len);
            for (parsed.array.items, values) |v, *out| out.* = try std.json.Stringify.valueAlloc(lab.arena, v, .{});
            try e.respond(lab.calls.items[k - 1], values);
        } else if (std.mem.eql(u8, action, "elicit")) {
            const server = words.next() orelse return error.Usage;
            const k = try std.fmt.parseInt(usize, words.next() orelse return error.Usage, 10);
            if (k == 0 or k > lab.elicits.items.len) return error.Usage;
            const verb = words.next() orelse return error.Usage;
            const content = std.mem.trim(u8, words.rest(), " ");
            const act = std.meta.stringToEnum(mcp.core.elicitation.Action, verb) orelse return error.Usage;
            e.answerElicitation(server, lab.elicits.items[k - 1], .{ .action = act, .content = if (content.len > 0) content else null }) catch |err| {
                try lab.print("did", .{ .action = "elicit", .@"error" = @errorName(err) });
                return true;
            };
        } else if (std.mem.eql(u8, action, "reload")) {
            var names: std.ArrayList([]const u8) = .empty;
            while (words.next()) |name| try names.append(lab.arena, name);
            try e.reload(try lab.configs(names.items));
        } else if (std.mem.eql(u8, action, "status")) {
            try lab.status();
            return true;
        } else if (std.mem.eql(u8, action, "expect")) {
            const want = words.next() orelse return error.Usage;
            const ms = if (words.next()) |t| try std.fmt.parseInt(u32, t, 10) else 10_000;
            const deadline = now(e) + ms;
            var claimed = lab.claim(want);
            while (!claimed and now(e) < deadline) {
                const event = try e.next(@intCast(@max(0, deadline - now(e)))) orelse break;
                _ = try lab.show(event);
                claimed = lab.claim(want);
            }
            if (claimed) {
                try lab.print("did", .{ .action = "expect", .expect = want, .met = true });
                return true;
            }
            try lab.print("did", .{ .action = "expect", .expect = want, .met = false });
            return false;
        } else if (std.mem.eql(u8, action, "drain")) {
            const ms = try std.fmt.parseInt(u32, words.next() orelse return error.Usage, 10);
            const deadline = now(e) + ms;
            while (now(e) < deadline) {
                const event = try e.next(@intCast(@max(0, deadline - now(e)))) orelse break;
                _ = try lab.show(event);
            }
            lab.unclaimed.clearRetainingCapacity();
        } else return error.Usage;
        try lab.print("did", .{ .action = action });
        return true;
    }
};

fn now(e: *const engine.Engine) i64 {
    return std.Io.Clock.awake.now(e.io).toMilliseconds();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout.interface;

    if (args.len < 3) {
        std.debug.print("usage: engine_lab <trace-path> <script> [options]\n", .{});
        std.process.exit(2);
    }
    var deny: std.ArrayList([]const u8) = .empty;
    var options: engine.Options = .{ .client = .{ .info = .{ .name = "mcpv2-engine-lab", .version = "0.0.0" } } };
    var preferred: ?[]const []const u8 = null;
    var defines: std.ArrayList([2][]const u8) = .empty;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        const value = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, flag, "--no-listen")) {
            options.listen_tools = false;
            continue;
        }
        i += 1;
        if (std.mem.eql(u8, flag, "--deny")) {
            try deny.append(arena, value);
        } else if (std.mem.eql(u8, flag, "--capabilities")) {
            options.client.capabilities = value;
        } else if (std.mem.eql(u8, flag, "--max-attempts")) {
            options.gate.max_attempts = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, flag, "--stable-ms")) {
            options.gate.stable_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--define")) {
            const eq = std.mem.findScalar(u8, value, '=') orelse {
                std.debug.print("engine_lab: --define needs NAME=VALUE\n", .{});
                std.process.exit(2);
            };
            try defines.append(arena, .{ try arena.print("{{{s}}}", .{value[0..eq]}), value[eq + 1 ..] });
        } else if (std.mem.eql(u8, flag, "--probe-ms")) {
            options.era.probe_timeout_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--timeout-ms")) {
            options.timeouts.idle_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--hard-ms")) {
            options.timeouts.hard_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--preferred")) {
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, value, ',');
            while (it.next()) |v| try list.append(arena, v);
            preferred = list.items;
        } else {
            std.debug.print("engine_lab: unknown option {s}\n", .{flag});
            std.process.exit(2);
        }
    }
    if (preferred) |p| options.era.preferred = p;

    const trace_file = try std.Io.Dir.cwd().createFile(io, args[1], .{});
    defer trace_file.close(io);
    var trace_buffer: [16 * 1024]u8 = undefined;
    var trace_writer = trace_file.writer(io, &trace_buffer);
    var tracer: mcp.trace.Writer = .init(&trace_writer.interface);
    options.trace = &tracer;

    var script = try std.Io.Dir.cwd().readFileAlloc(io, args[2], arena, .limited(1 << 20));
    for (defines.items) |d| script = try std.mem.replaceOwned(u8, arena, script, d[0], d[1]);
    var lab: Lab = .{ .gpa = gpa, .arena = arena, .out = out, .deny = deny.items };
    var e: engine.Engine = undefined;
    var ok = true;
    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        if (lab.e == null and !std.mem.startsWith(u8, line, "server ")) {
            var names: std.ArrayList([]const u8) = .empty;
            for (lab.declared[0..lab.count]) |d| try names.append(arena, d.name);
            try e.init(io, gpa, .{ .context = &lab, .allow = Lab.allow, .log = Lab.log }, options, try lab.configs(names.items));
            lab.e = &e;
        }
        const met = lab.run(line) catch |err| blk: {
            try lab.print("did", .{ .line = line, .@"error" = @errorName(err) });
            break :blk false;
        };
        trace_writer.interface.flush() catch {};
        if (!met) {
            ok = false;
            break;
        }
    }
    if (lab.e != null) {
        try lab.status();
        e.deinit();
    }
    trace_writer.interface.flush() catch {};
    const Logged = struct { name: []const u8, lines: u32 };
    const logged = try arena.alloc(Logged, lab.count);
    for (lab.declared[0..lab.count], logged) |*d, *l| l.* = .{ .name = d.name, .lines = d.logged.load(.monotonic) };
    try lab.print("final", .{ .ok = ok, .logged = logged });
    lab.calls.deinit(gpa);
    lab.elicits.deinit(gpa);
    std.process.exit(if (ok) 0 else 1);
}
