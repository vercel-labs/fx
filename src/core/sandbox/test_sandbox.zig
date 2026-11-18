//! A fake Vercel Sandbox API for tests only. Nothing in this file ships in fx.
//! One folder stands in for the sandbox disk: every sandbox's files sit under
//! it at the same absolute paths as on this machine. Commands run on this
//! machine, in this process, and their output comes back as the API sends it.
const std = @import("std");
const client_mod = @import("client.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

/// Most sandboxes, creates, and deletes one fake holds.
pub const max_sandboxes = 8;
/// Longest body, name, or session id the fake records.
pub const max_text_bytes = 1024;

const missing_json = "{\"error\":{\"code\":\"not_found\",\"message\":\"no such sandbox\"}}";
const exists_json = "{\"error\":{\"code\":\"conflict\",\"message\":\"sandbox already exists\"}}";
const max_command_output_bytes = 1024 * 1024;

/// The output of one command run on this machine.
pub const Ran = struct {
    code: i64,
    stdout: []u8,
    stderr: []u8,
};

/// Runs `argv` in `cwd` with this process's environment.
pub fn runCommand(arena: Allocator, cwd: []const u8, argv: []const []const u8) !Ran {
    var environment = try io_mod.cloneEnvironMap(arena);
    const result = try std.process.run(arena, io_mod.getIo(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = &environment,
        .stdout_limit = .limited(max_command_output_bytes),
        .stderr_limit = .limited(max_command_output_bytes),
    });
    const code: i64 = switch (result.term) {
        .exited => |exit_code| exit_code,
        else => -1,
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

/// False when bash, git, or tar is missing, so the helper tests skip.
pub fn toolsAvailable(arena: Allocator) bool {
    const tools = [_][]const u8{ "bash", "git", "tar" };
    for (tools) |tool| {
        const ran = runCommand(arena, ".", &.{ tool, "--version" }) catch return false;
        if (ran.code != 0) return false;
    }
    return true;
}

/// A short text the fake keeps inside itself, so a recorded value needs no allocator.
pub const Text = struct {
    bytes: [max_text_bytes]u8 = undefined,
    len: usize = 0,

    pub fn get(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }

    fn set(self: *Text, text: []const u8) !void {
        if (text.len > self.bytes.len) return error.TestUnexpectedResult;
        @memcpy(self.bytes[0..text.len], text);
        self.len = text.len;
    }
};

/// One tag a sandbox carries.
const Tag = struct {
    name: Text = .{},
    value: Text = .{},
};

/// Most tags one sandbox carries in the fake.
const max_tags = 4;

/// One sandbox the fake holds.
const Slot = struct {
    name: Text = .{},
    session: Text = .{},
    tags: [max_tags]Tag = @splat(Tag{}),
    tag_count: usize = 0,
    live: bool = false,

    /// True when one tag is `filter`, written the way the list query writes it: `name%3Avalue`.
    fn hasTag(self: *const Slot, arena: Allocator, filter: []const u8) Allocator.Error!bool {
        for (self.tags[0..self.tag_count]) |tag| {
            const encoded = try arena.print("{s}%3A{s}", .{ tag.name.get(), tag.value.get() });
            if (std.mem.eql(u8, encoded, filter)) return true;
        }
        return false;
    }
};

/// Most snapshots one fake makes.
pub const max_snapshots = 8;

/// One snapshot the fake made.
pub const Snapshot = struct {
    id: Text = .{},
    gone: bool = false,
};

/// The fake API. Its counters and recorded values let a test check what fx sent.
pub const FakeSandbox = struct {
    /// The folder that stands in for every sandbox's disk.
    disk: []const u8,
    slots: [max_sandboxes]Slot = @splat(Slot{}),
    /// Every create body received, in order.
    create_bodies: [max_sandboxes]Text = undefined,
    /// Every sandbox name deleted, in order.
    deleted_names: [max_sandboxes]Text = undefined,
    creates: usize = 0,
    deletes: usize = 0,
    /// Sessions handed out. The next sandbox gets `sbx_<n + 1>`.
    sessions: usize = 0,
    gets: usize = 0,
    commands: usize = 0,
    writes: usize = 0,
    reads: usize = 0,
    /// Deletes `a.txt` after each upload, so the sandbox copy keeps differing.
    drop_upload: bool = false,
    /// Answers every command with a 500, as a failing API would.
    fail_commands: bool = false,
    /// Runs `sleep 2` instead of the command, so a helper runs past its deadline.
    slow_commands: bool = false,
    /// Answers command number `fail_after`, and every later one, with a 500. Counts from zero.
    fail_after: ?usize = null,
    /// Stores the sandbox, then answers the create with a lost connection.
    lose_create_answer: bool = false,
    /// Runs command number `fail_exit` as `sh -c "exit 1"`, so its helper fails. Counts from zero.
    fail_exit: ?usize = null,
    /// Every snapshot the fake made, in order. `gone` makes a snapshot answer 404.
    snapshots: [max_snapshots]Snapshot = @splat(Snapshot{}),
    snapshot_count: usize = 0,

    pub fn send(context: *anyopaque, arena: Allocator, call: client_mod.Call) anyerror!client_mod.Response {
        const self: *FakeSandbox = @ptrCast(@alignCast(context));
        const target = call.request.target;
        if (call.request.method == .POST and std.mem.startsWith(u8, target, "/v2/sandboxes?")) {
            return self.create(arena, call);
        }
        if (std.mem.startsWith(u8, target, "/v2/sandboxes/sessions/")) return self.sessionCall(arena, call);
        if (call.request.method == .GET and std.mem.startsWith(u8, target, "/v2/sandboxes?")) return self.list(arena, target);
        if (call.request.method == .GET and std.mem.startsWith(u8, target, "/v2/sandboxes/snapshots/")) {
            return self.getSnapshot(arena, target);
        }
        if (std.mem.startsWith(u8, target, "/v2/sandboxes/")) {
            const end = std.mem.findScalar(u8, target, '?') orelse target.len;
            const name = target["/v2/sandboxes/".len..end];
            if (call.request.method == .GET) return self.get(arena, name);
            if (call.request.method == .DELETE) return self.delete(name);
        }
        return .{ .status = 404, .body = missing_json };
    }

    fn create(self: *FakeSandbox, arena: Allocator, call: client_mod.Call) anyerror!client_mod.Response {
        if (self.creates >= max_sandboxes) return error.TestUnexpectedResult;
        try self.create_bodies[self.creates].set(call.request.body);
        self.creates += 1;
        const body = try std.json.parseFromSliceLeaky(std.json.Value, arena, call.request.body, .{});
        const name = body.object.get("name") orelse return error.TestUnexpectedResult;
        if (self.find(name.string) != null) return .{ .status = 409, .body = exists_json };
        const slot = self.freeSlot() orelse return error.TestUnexpectedResult;
        self.sessions += 1;
        const session = try arena.print("sbx_{d}", .{self.sessions});
        try self.slots[slot].name.set(name.string);
        try self.slots[slot].session.set(session);
        try self.storeTags(slot, body.object.get("tags"));
        self.slots[slot].live = true;
        if (self.lose_create_answer) return error.AnswerLost;
        return .{ .status = 200, .body = try sandboxJson(arena, session) };
    }

    /// Stores a create body's tags in `slot`.
    fn storeTags(self: *FakeSandbox, slot: usize, value: ?std.json.Value) !void {
        const tags_value = value orelse return;
        const map = switch (tags_value) {
            .object => |object| object,
            else => return error.TestUnexpectedResult,
        };
        if (map.count() > max_tags) return error.TestUnexpectedResult;
        for (map.keys(), map.values(), 0..) |key, tag_value, index| {
            try self.slots[slot].tags[index].name.set(key);
            try self.slots[slot].tags[index].value.set(tag_value.string);
        }
        self.slots[slot].tag_count = map.count();
    }

    /// Lists the live sandboxes that carry the query's tag, with their tags.
    fn list(self: *const FakeSandbox, arena: Allocator, target: []const u8) anyerror!client_mod.Response {
        const filter = tagFilter(target);
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "{\"sandboxes\":[");
        var first = true;
        for (self.slots) |slot| {
            if (!slot.live) continue;
            if (filter) |wanted| {
                if (!(try slot.hasTag(arena, wanted))) continue;
            }
            if (!first) try out.append(arena, ',');
            first = false;
            try out.appendSlice(arena, try arena.print("{{\"name\":\"{s}\",\"status\":\"running\",\"tags\":{{", .{slot.name.get()}));
            for (slot.tags[0..slot.tag_count], 0..) |tag, index| {
                if (index > 0) try out.append(arena, ',');
                try out.appendSlice(arena, try arena.print("\"{s}\":\"{s}\"", .{ tag.name.get(), tag.value.get() }));
            }
            try out.appendSlice(arena, "}}");
        }
        try out.appendSlice(arena, "]}");
        return .{ .status = 200, .body = out.items };
    }

    fn get(self: *FakeSandbox, arena: Allocator, name: []const u8) anyerror!client_mod.Response {
        self.gets += 1;
        const slot = self.find(name) orelse return .{ .status = 404, .body = missing_json };
        return .{ .status = 200, .body = try sandboxJson(arena, self.slots[slot].session.get()) };
    }

    fn delete(self: *FakeSandbox, name: []const u8) anyerror!client_mod.Response {
        if (self.deletes >= max_sandboxes) return error.TestUnexpectedResult;
        try self.deleted_names[self.deletes].set(name);
        self.deletes += 1;
        if (self.find(name)) |slot| self.slots[slot].live = false;
        return .{ .status = 200 };
    }

    fn sessionCall(self: *FakeSandbox, arena: Allocator, call: client_mod.Call) anyerror!client_mod.Response {
        const rest = call.request.target["/v2/sandboxes/sessions/".len..];
        const path = rest[0 .. std.mem.findScalar(u8, rest, '?') orelse rest.len];
        const slash = std.mem.findScalar(u8, path, '/') orelse return .{ .status = 404, .body = missing_json };
        if (self.findSession(path[0..slash]) == null) return .{ .status = 404, .body = missing_json };
        const op = path[slash + 1 ..];
        if (std.mem.eql(u8, op, "cmd")) return self.command(arena, call);
        if (std.mem.eql(u8, op, "fs/write")) return self.writeFiles(arena, call);
        if (std.mem.eql(u8, op, "fs/read")) return self.readFile(arena, call);
        if (std.mem.eql(u8, op, "snapshot")) return self.snapshotSession(arena);
        return .{ .status = 404, .body = missing_json };
    }

    fn command(self: *FakeSandbox, arena: Allocator, call: client_mod.Call) anyerror!client_mod.Response {
        if (self.fail_commands) return .{ .status = 500, .body = "{\"error\":{\"message\":\"no capacity\"}}" };
        const index = self.commands;
        if (self.fail_after) |limit| {
            if (self.commands >= limit) return .{ .status = 500, .body = "{\"error\":{\"message\":\"no capacity\"}}" };
        }
        self.commands += 1;
        const body = try std.json.parseFromSliceLeaky(std.json.Value, arena, call.request.body, .{});
        const object = body.object;
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, object.get("command").?.string);
        for (object.get("args").?.array.items) |arg| try argv.append(arena, arg.string);
        const cwd = if (object.get("cwd")) |value| value.string else "/";
        const failing_exit = if (self.fail_exit) |exit_index| exit_index == index else false;
        const ran = if (self.slow_commands)
            try runCommand(arena, cwd, &.{ "sleep", "2" })
        else if (failing_exit)
            try runCommand(arena, cwd, &.{ "sh", "-c", "exit 1" })
        else
            try runCommand(arena, cwd, argv.items);
        const sink = call.lines orelse return error.TestUnexpectedResult;
        try sink.on_line(sink.context, "{\"command\":{\"id\":\"cmd_1\",\"exitCode\":null}}");
        if (ran.stdout.len > 0) try sink.on_line(sink.context, try streamLine(arena, "stdout", ran.stdout));
        if (ran.stderr.len > 0) try sink.on_line(sink.context, try streamLine(arena, "stderr", ran.stderr));
        try sink.on_line(sink.context, try arena.print("{{\"command\":{{\"id\":\"cmd_1\",\"exitCode\":{d}}}}}", .{ran.code}));
        return .{ .status = 200 };
    }

    fn writeFiles(self: *FakeSandbox, arena: Allocator, call: client_mod.Call) anyerror!client_mod.Response {
        self.writes += 1;
        const zio = io_mod.getIo();
        const archive_path = try arena.print("{s}/upload-{d}.tgz", .{ self.disk, self.writes });
        var file = try std.Io.Dir.createFileAbsolute(zio, archive_path, .{});
        try file.writeStreamingAll(zio, call.request.body);
        file.close(zio);
        const cwd = call.request.extract_cwd orelse return error.TestUnexpectedResult;
        const ran = try runCommand(arena, ".", &.{ "tar", "-xzf", archive_path, "-C", cwd });
        if (self.drop_upload) std.Io.Dir.deleteFileAbsolute(zio, try arena.print("{s}/a.txt", .{cwd})) catch {};
        return .{ .status = if (ran.code == 0) 200 else 500 };
    }

    fn readFile(self: *FakeSandbox, arena: Allocator, call: client_mod.Call) anyerror!client_mod.Response {
        self.reads += 1;
        const body = try std.json.parseFromSliceLeaky(std.json.Value, arena, call.request.body, .{});
        const path = body.object.get("path").?.string;
        const zio = io_mod.getIo();
        var file = std.Io.Dir.openFileAbsolute(zio, path, .{}) catch return .{ .status = 404, .body = missing_json };
        defer file.close(zio);
        const bytes = try io_mod.readFileToEnd(arena, &file, 1 << 20);
        return .{ .status = 200, .body = bytes };
    }

    /// Saves a snapshot of a live session. The id is `snap_<n>`, answered with 201 as the API does.
    fn snapshotSession(self: *FakeSandbox, arena: Allocator) anyerror!client_mod.Response {
        if (self.snapshot_count >= max_snapshots) return error.TestUnexpectedResult;
        self.snapshot_count += 1;
        const id = try arena.print("snap_{d}", .{self.snapshot_count});
        try self.snapshots[self.snapshot_count - 1].id.set(id);
        return .{ .status = 201, .body = try arena.print("{{\"snapshot\":{{\"id\":\"{s}\"}}}}", .{id}) };
    }

    /// Answers a snapshot read: 200 for a snapshot that is not gone, 404 otherwise.
    fn getSnapshot(self: *FakeSandbox, arena: Allocator, target: []const u8) anyerror!client_mod.Response {
        const rest = target["/v2/sandboxes/snapshots/".len..];
        const id = rest[0 .. std.mem.findScalar(u8, rest, '?') orelse rest.len];
        for (self.snapshots[0..self.snapshot_count]) |snapshot| {
            if (snapshot.gone or !std.mem.eql(u8, snapshot.id.get(), id)) continue;
            return .{ .status = 200, .body = try arena.print("{{\"snapshot\":{{\"id\":\"{s}\"}}}}", .{id}) };
        }
        return .{ .status = 404, .body = missing_json };
    }

    /// Makes snapshot `id` answer 404 from now on, as a snapshot does after it expires.
    pub fn markSnapshotGone(self: *FakeSandbox, id: []const u8) void {
        for (self.snapshots[0..self.snapshot_count]) |*snapshot| {
            if (std.mem.eql(u8, snapshot.id.get(), id)) snapshot.gone = true;
        }
    }

    fn find(self: *const FakeSandbox, name: []const u8) ?usize {
        for (self.slots, 0..) |slot, index| {
            if (slot.live and std.mem.eql(u8, slot.name.get(), name)) return index;
        }
        return null;
    }

    fn findSession(self: *const FakeSandbox, session: []const u8) ?usize {
        for (self.slots, 0..) |slot, index| {
            if (slot.live and std.mem.eql(u8, slot.session.get(), session)) return index;
        }
        return null;
    }

    fn freeSlot(self: *const FakeSandbox) ?usize {
        for (self.slots, 0..) |slot, index| {
            if (!slot.live) return index;
        }
        return null;
    }
};

/// The tag a list query asks for, as the query writes it (`name%3Avalue`), or
/// null when the query has no tag filter.
fn tagFilter(target: []const u8) ?[]const u8 {
    const key = "tags=";
    const start = (std.mem.find(u8, target, key) orelse return null) + key.len;
    const end = std.mem.findScalarPos(u8, target, start, '&') orelse target.len;
    return target[start..end];
}

/// A client whose calls all go to `fake`.
pub fn fakeClient(fake: *FakeSandbox) client_mod.Client {
    return .{
        .transport = .{ .context = fake, .send = FakeSandbox.send },
        .base_url = "https://sandbox.test",
        .team = "team",
        .project = "project",
        .token = "token",
    };
}

fn sandboxJson(arena: Allocator, session: []const u8) ![]const u8 {
    return arena.print("{{\"sandbox\":{{\"currentSessionId\":\"{s}\",\"status\":\"running\"}}}}", .{session});
}

/// One JSON line for a command's output, with the text as a JSON string so NUL bytes are escaped.
fn streamLine(arena: Allocator, stream: []const u8, bytes: []const u8) ![]const u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(arena, bytes.len + 64);
    try std.json.Stringify.value(.{ .data = bytes, .stream = stream }, .{}, &out.writer);
    return out.written();
}
