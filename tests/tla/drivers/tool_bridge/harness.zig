//! A JSON-lines shell around the real file path of the experimental bash
//! tool's `fx tool edit` and `fx tool write`, for the Bun driver in
//! tests/tla/drivers/tool_bridge/.
//!
//! The driver copies this file to the root of a work folder that holds a copy
//! of src/, so each import below is a real file of this tree. The bridge core
//! (`core.zig`), the file change (`file_mutation.zig` prepare and apply, with
//! its file-changed check), and the change tracker (`change_tracker.zig`) run
//! as written. The rest is glue that stands where `bridge.zig` (the prompt
//! re-check in `authorizeGated`, the withdraw and cancel effects) and
//! `tool_runtime.zig` (the file authorization and the publish after a commit)
//! stand, and the environment of the model: the program's own writes, another
//! process's write, the program's end or kill, and the socket hang-up.
//!
//! Each input line is one event: {"event":"send","i":1}. The first output line
//! is the state after start, and each later line is the state after one event,
//! as {"state":{...},"out":[...]}. An event whose guard does not hold is
//! refused: the state does not change and `out` says so.
const std = @import("std");
const core = @import("src/core/tool_bridge/core.zig");
const file_mutation = @import("src/core/tooling/file_mutation.zig");
const contract = @import("src/core/tooling/file_mutation_contract.zig");
const change_tracker = @import("src/core/workspace/change_tracker.zig");
const permissions = @import("src/core/permissions/permissions.zig");
const types = @import("src/core/shared/types.zig");
const io_mod = @import("src/core/shared/io.zig");
const tools = @import("src/builtins/tools.zig");
const write_file = @import("src/tools/filesystem/write_file.zig");

const model_ids = 2;
const max_rows = 3;
const max_raw = 1;
const max_other = 1;
const file_name = "app.txt";

const token_main: core.Token = @splat(0x11);
const token_child: core.Token = @splat(0x22);
const child_owner: core.OwnerId = @fromBackingInt(@intCast(1));

const Stage = enum { none, sent, prepared, prompt, allowed, denied, applied, stale, dropped };
const Prog = enum { running, ended, killed };

const Req = struct {
    core_id: ?core.RequestId = null,
    stage: Stage = .none,
    pre: u32 = 0,
    args: []const u8 = "",
    authorization: ?contract.FileExecutionAuthorization = null,
    pushed: usize = 0,
    cancel: std.atomic.Value(bool) = .init(false),
};

const Pair = struct { id: u32, pre: u32 };
const Triple = struct { id: u32, pre: u32, post: u32 };
const Flags = struct { stale: bool = false, afterGone: bool = false, askedAfterGone: bool = false };

const ReqJson = struct { stage: []const u8, pre: u32 };
const StateJson = struct {
    prog: []const u8,
    seen: bool,
    call: []const u8,
    history: []const []const u8,
    raw: u32,
    other: u32,
    req: [model_ids]ReqJson,
    reviewed: []const Pair,
    prompt: u32,
    tracker: []const Triple,
    rows: []const u32,
    flags: Flags,
    diffDone: bool,
};
const LineJson = struct { state: StateJson, out: []const []const u8 };
const Input = struct { event: []const u8, i: ?u32 = null };

const Harness = struct {
    alloc: std.mem.Allocator,
    root: []const u8,
    path: []const u8,
    state: core.State,
    reqs: [model_ids]Req = .{ .{}, .{} },
    prog: Prog = .running,
    seen: bool = false,
    call_open: bool = true,
    history: std.ArrayList([]const u8) = .empty,
    raw: u32 = 0,
    other: u32 = 0,
    reviewed: std.ArrayList(Pair) = .empty,
    prompt: u32 = 0,
    tracker: std.ArrayList(Triple) = .empty,
    rows: std.ArrayList(u32) = .empty,
    flags: Flags = .{},
    ops: change_tracker.ChangeTracker = .{},
    notes: std.ArrayList([]const u8) = .empty,

    fn version(self: *const Harness) u32 {
        return @intCast(self.history.items.len);
    }

    fn note(self: *Harness, comptime fmt: []const u8, args: anytype) anyerror!void {
        try self.notes.append(self.alloc, try self.alloc.print(fmt, args));
    }

    fn indexOfCore(self: *const Harness, id: core.RequestId) ?usize {
        for (self.reqs, 0..) |req, k| {
            if (req.core_id) |own| {
                if (own == id) return k;
            }
        }
        return null;
    }

    fn anyInFlight(self: *const Harness) bool {
        for (self.reqs) |req| {
            switch (req.stage) {
                .sent, .prepared, .prompt, .allowed => return true,
                else => {},
            }
        }
        return false;
    }

    fn runCore(self: *Harness, event: core.Event) anyerror!void {
        const out = core.step(self.state, event);
        self.state = out.state;
        for (out.effects()) |effect| try self.onEffect(effect);
    }

    /// The shell's side of each effect the core returns.
    fn onEffect(self: *Harness, effect: core.Effect) anyerror!void {
        switch (effect) {
            .refuse => |reason| try self.note("bridge refused: {s}", .{@tagName(reason)}),
            .authorize => {},
            .call => |work| {
                const k = self.indexOfCore(work.id) orelse return error.UnknownRequest;
                self.reqs[k].stage = .allowed;
            },
            .withdraw => {},
            .cancel => |id| {
                const k = self.indexOfCore(id) orelse return error.UnknownRequest;
                self.reqs[k].cancel.store(true, .seq_cst);
            },
            .reply => |reply| try self.runCore(.{ .reply_done = .{ .id = reply.id, .delivery = .delivered } }),
            .log => |log| try self.note("dropped: {s}", .{@tagName(log.drop)}),
        }
    }

    fn start(self: *Harness) anyerror!void {
        try self.runCore(.{ .started = token_main });
        try self.runCore(.{ .owner_added = .{ .owner = child_owner, .token = token_child } });
    }

    fn denyLeft(self: *Harness, k: usize) anyerror!void {
        self.reqs[k].stage = .dropped;
        try self.runCore(.{ .authorized = .{ .id = self.reqs[k].core_id.?, .decision = .deny } });
    }

    fn send(self: *Harness, k: usize) anyerror!bool {
        if (self.prog != .running or self.reqs[k].stage != .none) return false;
        const before = self.state.next;
        try self.runCore(.{ .request = .{ .token = token_child, .version = core.protocol_version } });
        if (self.state.next == before) return false;
        self.reqs[k].core_id = @fromBackingInt(@intCast(before));
        self.reqs[k].stage = .sent;
        return true;
    }

    /// fx reads the file and builds the edit on the version it reads, as the
    /// file authorization does after the bridge's prompt re-check.
    fn prepare(self: *Harness, k: usize) anyerror!bool {
        if (self.reqs[k].stage != .sent) return false;
        if (!core.awaitingPermission(&self.state, self.reqs[k].core_id.?)) {
            try self.denyLeft(k);
            return true;
        }
        const content = try self.alloc.print("fx{d} from v{d}", .{ k + 1, self.version() });
        const args = try self.alloc.print("{{\"path\":\"{s}\",\"content\":\"{s}\"}}", .{ file_name, content });
        const call: types.ToolCall = .{ .id = "bridge", .name = "write_file", .arguments_json = args };
        const decoded = try tools.write_file.decode(.{ .allocator = self.alloc }, args);
        const input = switch (decoded) {
            .input => |tool_input| try write_file.takeFileMutationInput(tool_input, self.alloc),
            .failure => return error.InvalidToolArguments,
        };
        const policy = switch (try permissions.evaluateFileMutationTargets(self.alloc, self.root, input, .ask, .{}, &.{}, &.{})) {
            .evaluated => |evaluated| evaluated,
            else => return error.PolicyDenied,
        };
        const prepared = switch (try file_mutation.prepare(self.alloc, call, input, policy, .plain)) {
            .prepared => |value| value,
            .semantic_failure => return error.SemanticFailure,
        };
        self.reqs[k].pre = self.version();
        self.reqs[k].args = args;
        self.reqs[k].authorization = .{ .input = input, .policy_targets = policy, .prepared = prepared };
        self.reqs[k].stage = .prepared;
        return true;
    }

    fn addReviewed(self: *Harness, id: u32, pre: u32) anyerror!void {
        for (self.reviewed.items) |pair| {
            if (pair.id == id and pair.pre == pre) return;
        }
        try self.reviewed.append(self.alloc, .{ .id = id, .pre = pre });
    }

    /// The review's allow. A request that left during the review gets no call.
    fn autoAllow(self: *Harness, k: usize) anyerror!bool {
        if (self.reqs[k].stage != .prepared) return false;
        try self.runCore(.{ .authorized = .{ .id = self.reqs[k].core_id.?, .decision = .allow } });
        if (self.reqs[k].stage == .prepared) {
            self.reqs[k].stage = .dropped;
        } else if (self.reqs[k].stage == .allowed) {
            try self.addReviewed(@intCast(k + 1), self.reqs[k].pre);
        }
        return true;
    }

    /// The shell opens the prompt only if the request still waits for it.
    fn ask(self: *Harness, k: usize) anyerror!bool {
        if (self.reqs[k].stage != .prepared or self.prompt != 0) return false;
        if (!core.awaitingPermission(&self.state, self.reqs[k].core_id.?)) {
            try self.denyLeft(k);
            return true;
        }
        self.reqs[k].stage = .prompt;
        self.prompt = @intCast(k + 1);
        if (self.seen) self.flags.askedAfterGone = true;
        return true;
    }

    /// The person answers the open prompt. A prompt whose program left runs nothing.
    fn answer(self: *Harness, k: usize, allow: bool) anyerror!bool {
        if (self.reqs[k].stage != .prompt or self.prompt != k + 1) return false;
        self.prompt = 0;
        if (allow) {
            try self.addReviewed(@intCast(k + 1), self.reqs[k].pre);
            self.reqs[k].stage = .dropped;
            try self.runCore(.{ .authorized = .{ .id = self.reqs[k].core_id.?, .decision = .allow } });
        } else {
            self.reqs[k].stage = .denied;
            try self.runCore(.{ .authorized = .{ .id = self.reqs[k].core_id.?, .decision = .deny } });
        }
        return true;
    }

    fn reviewUnavailable(self: *Harness, k: usize) anyerror!bool {
        if (self.reqs[k].stage != .prepared) return false;
        self.reqs[k].stage = .denied;
        try self.runCore(.{ .authorized = .{ .id = self.reqs[k].core_id.?, .decision = .deny } });
        return true;
    }

    /// The real apply, with its file-changed check, on the call the request
    /// was prepared for. A cancelled request is not written.
    fn apply(self: *Harness, k: usize) anyerror!bool {
        const req = &self.reqs[k];
        if (req.stage != .allowed) return false;
        const before = self.version();
        const call: types.ToolCall = .{ .id = "bridge", .name = "write_file", .arguments_json = req.args };
        const result = try file_mutation.apply(self.alloc, self.alloc, call, req.authorization.?, &req.cancel);
        switch (result) {
            .committed => {
                self.flags.stale = self.flags.stale or before != req.pre;
                self.flags.afterGone = self.flags.afterGone or self.seen;
                try self.history.append(self.alloc, "fx");
                try self.recordTracker(k, before);
                req.stage = .applied;
                try self.runCore(.{ .call_finished = .{ .id = req.core_id.?, .outcome = .ok } });
            },
            .rejected => |rejected| switch (rejected.reason) {
                .stale_preimage => {
                    req.stage = .stale;
                    try self.runCore(.{ .call_finished = .{ .id = req.core_id.?, .outcome = .tool_error } });
                },
                .cancelled => {
                    req.stage = .dropped;
                    try self.runCore(.{ .call_finished = .{ .id = req.core_id.?, .outcome = .failed } });
                },
                else => return error.UnexpectedRejection,
            },
        }
        return true;
    }

    /// The change tracker gets the committed change: one undo entry and its
    /// version pair. `pushed` counts the entries the push added.
    fn recordTracker(self: *Harness, k: usize, pre: u32) anyerror!void {
        const path = try self.alloc.dupe(u8, self.path);
        const before_len = self.ops.stack.items.len;
        try self.ops.pushOperation(self.alloc, .{ .kind = .write, .path = path, .previous_content = null, .timestamp_ms = 0 });
        self.reqs[k].pushed = self.ops.stack.items.len - before_len;
        for (self.tracker.items) |triple| {
            if (triple.id == k + 1 and triple.pre == pre) return;
        }
        try self.tracker.append(self.alloc, .{ .id = @intCast(k + 1), .pre = pre, .post = pre + 1 });
    }

    /// The transcript row for a committed change, once.
    fn publish(self: *Harness, k: usize) anyerror!bool {
        const req = &self.reqs[k];
        if (req.stage != .applied or self.rows.items.len >= max_rows) return false;
        for (self.rows.items) |row| {
            if (row == k + 1) return false;
        }
        var count: usize = 0;
        while (count < req.pushed) : (count += 1) {
            try self.rows.append(self.alloc, @intCast(k + 1));
        }
        return true;
    }

    fn withdraw(self: *Harness, k: usize) anyerror!bool {
        if (!self.seen) return false;
        const req = &self.reqs[k];
        switch (req.stage) {
            .sent, .prepared => {
                req.stage = .dropped;
                try self.runCore(.{ .authorized = .{ .id = req.core_id.?, .decision = .deny } });
            },
            .allowed => {
                req.stage = .dropped;
                try self.runCore(.{ .call_finished = .{ .id = req.core_id.?, .outcome = .failed } });
            },
            else => return false,
        }
        return true;
    }

    /// The socket hangs up: the bridge learns each in-flight request's client left.
    fn hangup(self: *Harness) anyerror!bool {
        if (self.prog == .running or self.seen) return false;
        self.seen = true;
        for (0..model_ids) |k| {
            const req = self.reqs[k];
            switch (req.stage) {
                .sent, .prepared, .prompt, .allowed => try self.runCore(.{ .client_gone = req.core_id.? }),
                else => {},
            }
        }
        return true;
    }

    fn close(self: *Harness) anyerror!bool {
        if (!self.seen or !self.call_open or self.anyInFlight()) return false;
        self.call_open = false;
        try self.runCore(.{ .owner_removed = child_owner });
        return true;
    }

    fn end(self: *Harness) bool {
        if (self.prog != .running or self.anyInFlight()) return false;
        self.prog = .ended;
        return true;
    }

    fn kill(self: *Harness) bool {
        if (self.prog != .running) return false;
        self.prog = .killed;
        return true;
    }

    /// Another write to the file in place, as a program or another process
    /// writes it: the same file, with new content.
    fn writeInPlace(self: *Harness, content: []const u8) anyerror!void {
        const zio = io_mod.getIo();
        var file = try std.Io.Dir.cwd().createFile(zio, self.path, .{});
        defer file.close(zio);
        try file.writeStreamingAll(zio, content);
    }

    fn rawWrite(self: *Harness) anyerror!bool {
        if (self.prog != .running or self.raw >= max_raw) return false;
        try self.history.append(self.alloc, "prog");
        self.raw += 1;
        try self.writeInPlace(try self.alloc.print("v{d}", .{self.version()}));
        return true;
    }

    fn otherWrite(self: *Harness) anyerror!bool {
        if (self.other >= max_other) return false;
        try self.history.append(self.alloc, "other");
        self.other += 1;
        try self.writeInPlace(try self.alloc.print("v{d}", .{self.version()}));
        return true;
    }

    fn perform(self: *Harness, input: Input) anyerror!bool {
        const name = input.event;
        if (std.mem.eql(u8, name, "raw_write")) return self.rawWrite();
        if (std.mem.eql(u8, name, "other_write")) return self.otherWrite();
        if (std.mem.eql(u8, name, "end")) return self.end();
        if (std.mem.eql(u8, name, "kill")) return self.kill();
        if (std.mem.eql(u8, name, "hangup")) return self.hangup();
        if (std.mem.eql(u8, name, "close")) return self.close();
        const k = try modelIndex(input.i);
        if (std.mem.eql(u8, name, "send")) return self.send(k);
        if (std.mem.eql(u8, name, "prepare")) return self.prepare(k);
        if (std.mem.eql(u8, name, "auto_allow")) return self.autoAllow(k);
        if (std.mem.eql(u8, name, "ask")) return self.ask(k);
        if (std.mem.eql(u8, name, "user_allow")) return self.answer(k, true);
        if (std.mem.eql(u8, name, "user_deny")) return self.answer(k, false);
        if (std.mem.eql(u8, name, "review_unavailable")) return self.reviewUnavailable(k);
        if (std.mem.eql(u8, name, "apply")) return self.apply(k);
        if (std.mem.eql(u8, name, "publish")) return self.publish(k);
        if (std.mem.eql(u8, name, "withdraw")) return self.withdraw(k);
        return error.UnknownEvent;
    }

    fn stateJson(self: *const Harness) StateJson {
        var reqs: [model_ids]ReqJson = undefined;
        for (self.reqs, 0..) |req, k| reqs[k] = .{ .stage = @tagName(req.stage), .pre = req.pre };
        return .{
            .prog = @tagName(self.prog),
            .seen = self.seen,
            .call = if (self.call_open) "open" else "closed",
            .history = self.history.items,
            .raw = self.raw,
            .other = self.other,
            .req = reqs,
            .reviewed = self.reviewed.items,
            .prompt = self.prompt,
            .tracker = self.tracker.items,
            .rows = self.rows.items,
            .flags = self.flags,
            .diffDone = false,
        };
    }
};

fn modelIndex(value: ?u32) !usize {
    const id = value orelse return error.MissingRequestId;
    if (id < 1 or id > model_ids) return error.BadRequestId;
    return id - 1;
}

fn writeLine(writer: *std.Io.Writer, harness: *const Harness, notes: []const []const u8) !void {
    const line: LineJson = .{ .state = harness.stateJson(), .out = notes };
    try std.json.Stringify.value(line, .{ .emit_null_optional_fields = false }, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    io_mod.setIo(io);
    const alloc = init.gpa;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3 or !std.mem.eql(u8, args[1], "--root")) return error.Usage;
    const root = args[2];
    var harness: Harness = .{
        .alloc = arena,
        .root = root,
        .path = try std.Io.Dir.path.join(arena, &.{ root, file_name }),
        .state = core.State.init(core.default_capacity),
    };

    var in_buffer: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &in_buffer);
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);

    try harness.start();
    try writeLine(&stdout.interface, &harness, &.{});
    while (try stdin.interface.takeDelimiter('\n')) |raw| {
        const text = std.mem.trim(u8, raw, " \r\t");
        if (text.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Input, arena, text, .{ .ignore_unknown_fields = true });
        harness.notes.clearRetainingCapacity();
        if (!try harness.perform(parsed.value)) try harness.note("refused: {s}", .{parsed.value.event});
        try writeLine(&stdout.interface, &harness, harness.notes.items);
    }
}
