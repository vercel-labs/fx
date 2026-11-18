//! Requests and answers for the Vercel Sandbox REST API. This file builds
//! each request and reads each answer. It performs no I/O, so the network
//! code only sends the bytes it gets here.
const std = @import("std");
const config = @import("config.zig");

const json_type = "application/json";
const max_excerpt_bytes = 200;
const max_id_len = 128;
const max_path_len = 4096;
const hex_digits = "0123456789ABCDEF";

/// The HTTP method of a request.
pub const Method = enum { GET, POST, DELETE };

/// One request: a method, a path with its query, and an optional body.
pub const Request = struct {
    method: Method,
    /// The path and query, starting with `/`.
    target: []const u8,
    content_type: ?[]const u8 = null,
    body: []const u8 = "",
    /// The `x-cwd` header for `fs/write`.
    extract_cwd: ?[]const u8 = null,
};

/// A name and a value, used for tags and environment variables.
pub const Pair = struct { name: []const u8, value: []const u8 };

/// What to create. The source, network, vCPUs, and tags are optional.
pub const CreateOptions = struct {
    name: []const u8,
    project: []const u8,
    persistent: bool,
    timeout_ms: u64,
    source: config.Source = .default,
    network: ?config.Network = null,
    vcpus: ?u32 = null,
    tags: []const Pair = &.{},
};

/// One command for a session. Unset fields are left out of the body.
pub const CommandOptions = struct {
    command: []const u8 = "bash",
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    env: []const Pair = &.{},
    sudo: bool = false,
    wait: bool = true,
    logs: bool = true,
    timeout_ms: ?u64 = null,
};

/// Why a request cannot be built.
pub const BuildError = error{ InvalidName, InvalidPath, RecipeNotBuilt, OutOfMemory };

/// Why an answer cannot be read.
pub const ParseError = error{ UnexpectedAnswer, OutOfMemory };

/// A sandbox as the API reports it.
pub const Sandbox = struct {
    session_id: []const u8,
    status: []const u8,
};

/// A command as the API reports it. `exit_code` is null while it runs.
pub const Command = struct {
    id: []const u8,
    exit_code: ?i64,
};

/// The stream that output came from.
pub const Stream = enum { stdout, stderr };

/// One line of a command's ND-JSON answer.
pub const LogLine = union(enum) {
    command: Command,
    output: struct { stream: Stream, data: []const u8 },
    failure: struct { code: []const u8, message: []const u8 },
    /// A line fx does not need, such as an unknown stream.
    other,
};

/// One sandbox in a listing.
pub const Listed = struct {
    name: []const u8,
    status: []const u8,
    owner: ?[]const u8,
};

/// One page of a listing. `next` is the cursor for the next page, if any.
pub const Listing = struct {
    sandboxes: []const Listed,
    next: ?[]const u8,
};

/// A `{name: value}` object, written in order. Used for tags and environment.
const PairsJson = struct {
    pairs: []const Pair,

    pub fn jsonStringify(self: PairsJson, writer: *std.json.Stringify) !void {
        try writer.beginObject();
        for (self.pairs) |pair| {
            try writer.objectField(pair.name);
            try writer.write(pair.value);
        }
        try writer.endObject();
    }
};

const ResourcesJson = struct { vcpus: u32 };

const SourceJson = struct {
    type: []const u8,
    snapshotId: []const u8,
};

const NetworkJson = struct {
    mode: []const u8,
    allowedDomains: ?[]const []const u8 = null,
};

const CreateBody = struct {
    name: []const u8,
    projectId: []const u8,
    persistent: bool,
    timeout: u64,
    tags: ?PairsJson = null,
    resources: ?ResourcesJson = null,
    source: ?SourceJson = null,
    image: ?[]const u8 = null,
    networkPolicy: ?NetworkJson = null,
};

const CommandBody = struct {
    command: []const u8,
    args: []const []const u8,
    cwd: ?[]const u8 = null,
    env: ?PairsJson = null,
    sudo: ?bool = null,
    wait: bool,
    logs: bool,
    timeout: ?u64 = null,
};

const KillBody = struct { signal: u32 };
const ReadBody = struct { path: []const u8 };
const SnapshotBody = struct { expiration: u64 };

/// The request that creates a sandbox. It never sends an environment.
pub fn create(arena: std.mem.Allocator, team: []const u8, options: CreateOptions) BuildError!Request {
    if (!isSafeId(options.name)) return error.InvalidName;
    switch (options.source) {
        .recipe => return error.RecipeNotBuilt,
        else => {},
    }
    var body: CreateBody = .{
        .name = options.name,
        .projectId = options.project,
        .persistent = options.persistent,
        .timeout = options.timeout_ms,
    };
    if (options.tags.len > 0) body.tags = .{ .pairs = options.tags };
    if (options.vcpus) |vcpus| body.resources = .{ .vcpus = vcpus };
    switch (options.source) {
        .default, .recipe => {},
        .image => |image| body.image = image,
        .snapshot => |id| body.source = .{ .type = "snapshot", .snapshotId = id },
    }
    if (options.network) |network| body.networkPolicy = networkJson(network);
    return .{
        .method = .POST,
        .target = try arena.print("/v2/sandboxes?slug={s}", .{try percentEncode(arena, team)}),
        .content_type = json_type,
        .body = try stringify(arena, body),
    };
}

/// The request that reads one sandbox. `resume_stopped` starts it when stopped.
pub fn getNamed(
    arena: std.mem.Allocator,
    team: []const u8,
    project: []const u8,
    name: []const u8,
    resume_stopped: bool,
) BuildError!Request {
    if (!isSafeId(name)) return error.InvalidName;
    const resume_text: []const u8 = if (resume_stopped) "true" else "false";
    return .{
        .method = .GET,
        .target = try arena.print("/v2/sandboxes/{s}?projectId={s}&resume={s}&slug={s}", .{
            name,
            try percentEncode(arena, project),
            resume_text,
            try percentEncode(arena, team),
        }),
    };
}

/// The request that deletes one sandbox.
pub fn delete(arena: std.mem.Allocator, team: []const u8, project: []const u8, name: []const u8) BuildError!Request {
    if (!isSafeId(name)) return error.InvalidName;
    return .{
        .method = .DELETE,
        .target = try arena.print("/v2/sandboxes/{s}?projectId={s}&slug={s}", .{
            name,
            try percentEncode(arena, project),
            try percentEncode(arena, team),
        }),
    };
}

/// The request for one page of the sandboxes that carry `tag`.
pub fn list(
    arena: std.mem.Allocator,
    team: []const u8,
    project: []const u8,
    tag: Pair,
    cursor: ?[]const u8,
) BuildError!Request {
    const tag_text = try percentEncode(arena, try arena.print("{s}:{s}", .{ tag.name, tag.value }));
    const cursor_part: []const u8 = if (cursor) |value|
        try arena.print("&cursor={s}", .{try percentEncode(arena, value)})
    else
        "";
    return .{
        .method = .GET,
        .target = try arena.print("/v2/sandboxes?project={s}&tags={s}&limit=50{s}&slug={s}", .{
            try percentEncode(arena, project),
            tag_text,
            cursor_part,
            try percentEncode(arena, team),
        }),
    };
}

/// The request that starts a command in a session.
pub fn runCommand(arena: std.mem.Allocator, team: []const u8, session: []const u8, options: CommandOptions) BuildError!Request {
    if (!isSafeId(session)) return error.InvalidName;
    var body: CommandBody = .{
        .command = options.command,
        .args = options.args,
        .cwd = options.cwd,
        .wait = options.wait,
        .logs = options.logs,
        .timeout = options.timeout_ms,
    };
    if (options.env.len > 0) body.env = .{ .pairs = options.env };
    if (options.sudo) body.sudo = true;
    return .{
        .method = .POST,
        .target = try arena.print("/v2/sandboxes/sessions/{s}/cmd?slug={s}", .{
            session,
            try percentEncode(arena, team),
        }),
        .content_type = json_type,
        .body = try stringify(arena, body),
    };
}

/// The request that stops a running command with signal 15.
pub fn kill(arena: std.mem.Allocator, team: []const u8, session: []const u8, command_id: []const u8) BuildError!Request {
    if (!isSafeId(session) or !isSafeId(command_id)) return error.InvalidName;
    return .{
        .method = .POST,
        .target = try arena.print("/v2/sandboxes/sessions/{s}/cmd/{s}/kill?slug={s}", .{
            session,
            command_id,
            try percentEncode(arena, team),
        }),
        .content_type = json_type,
        .body = try stringify(arena, KillBody{ .signal = 15 }),
    };
}

/// The request that waits for a command to finish and reads its exit code.
pub fn waitCommand(arena: std.mem.Allocator, team: []const u8, session: []const u8, command_id: []const u8) BuildError!Request {
    if (!isSafeId(session) or !isSafeId(command_id)) return error.InvalidName;
    return .{
        .method = .GET,
        .target = try arena.print("/v2/sandboxes/sessions/{s}/cmd/{s}?wait=true&slug={s}", .{
            session,
            command_id,
            try percentEncode(arena, team),
        }),
    };
}

/// The request that writes a gzip tar into `cwd` in a session.
pub fn writeArchive(
    arena: std.mem.Allocator,
    team: []const u8,
    session: []const u8,
    gzip_tar: []const u8,
    cwd: []const u8,
) BuildError!Request {
    if (!isSafeId(session)) return error.InvalidName;
    if (!isSafePath(cwd)) return error.InvalidPath;
    return .{
        .method = .POST,
        .target = try arena.print("/v2/sandboxes/sessions/{s}/fs/write?slug={s}", .{
            session,
            try percentEncode(arena, team),
        }),
        .content_type = "application/gzip",
        .body = gzip_tar,
        .extract_cwd = cwd,
    };
}

/// The request that reads one file from a session. The answer is the raw bytes.
pub fn readFile(arena: std.mem.Allocator, team: []const u8, session: []const u8, path: []const u8) BuildError!Request {
    if (!isSafeId(session)) return error.InvalidName;
    if (!isSafePath(path)) return error.InvalidPath;
    return .{
        .method = .POST,
        .target = try arena.print("/v2/sandboxes/sessions/{s}/fs/read?slug={s}", .{
            session,
            try percentEncode(arena, team),
        }),
        .content_type = json_type,
        .body = try stringify(arena, ReadBody{ .path = path }),
    };
}

/// The request that snapshots a session. The snapshot expires after `expiration_ms`.
pub fn snapshot(arena: std.mem.Allocator, team: []const u8, session: []const u8, expiration_ms: u64) BuildError!Request {
    if (!isSafeId(session)) return error.InvalidName;
    return .{
        .method = .POST,
        .target = try arena.print("/v2/sandboxes/sessions/{s}/snapshot?slug={s}", .{
            session,
            try percentEncode(arena, team),
        }),
        .content_type = json_type,
        .body = try stringify(arena, SnapshotBody{ .expiration = expiration_ms }),
    };
}

/// The request that reads one snapshot. A 404 answer means it is gone.
pub fn getSnapshot(arena: std.mem.Allocator, team: []const u8, project: []const u8, snapshot_id: []const u8) BuildError!Request {
    if (!isSafeId(snapshot_id)) return error.InvalidName;
    return .{
        .method = .GET,
        .target = try arena.print("/v2/sandboxes/snapshots/{s}?project={s}&slug={s}", .{
            snapshot_id,
            try percentEncode(arena, project),
            try percentEncode(arena, team),
        }),
    };
}

/// The request that stops a session.
pub fn stopSession(arena: std.mem.Allocator, team: []const u8, session: []const u8) BuildError!Request {
    if (!isSafeId(session)) return error.InvalidName;
    return .{
        .method = .POST,
        .target = try arena.print("/v2/sandboxes/sessions/{s}/stop?slug={s}", .{
            session,
            try percentEncode(arena, team),
        }),
    };
}

/// Reads the sandbox that a create or get answer describes.
pub fn parseSandbox(arena: std.mem.Allocator, body: []const u8) ParseError!Sandbox {
    const root = try parseObject(arena, body);
    const sandbox_value = root.get("sandbox") orelse return error.UnexpectedAnswer;
    const sandbox = objectOf(sandbox_value) orelse return error.UnexpectedAnswer;
    const session_id = stringOf(sandbox.get("currentSessionId")) orelse return error.UnexpectedAnswer;
    return .{
        .session_id = session_id,
        .status = stringOf(sandbox.get("status")) orelse "",
    };
}

/// Reads a `{"command":{..}}` answer.
pub fn parseCommand(arena: std.mem.Allocator, body: []const u8) ParseError!Command {
    const root = try parseObject(arena, body);
    const value = root.get("command") orelse return error.UnexpectedAnswer;
    const command = objectOf(value) orelse return error.UnexpectedAnswer;
    return commandOf(command);
}

/// Reads one line of a command's ND-JSON answer. A blank line is `.other`.
pub fn parseLogLine(arena: std.mem.Allocator, line: []const u8) ParseError!LogLine {
    const text = std.mem.trim(u8, line, " \t\r\n");
    if (text.len == 0) return .other;
    const root = try parseObject(arena, text);
    if (root.get("command")) |value| {
        const command = objectOf(value) orelse return error.UnexpectedAnswer;
        return .{ .command = try commandOf(command) };
    }
    const data = root.get("data") orelse return .other;
    if (objectOf(data)) |failure| {
        const code = stringOf(failure.get("code")) orelse return .other;
        return .{ .failure = .{
            .code = code,
            .message = stringOf(failure.get("message")) orelse "",
        } };
    }
    const payload = stringOf(data) orelse return .other;
    const stream = stringOf(root.get("stream")) orelse return .other;
    if (std.mem.eql(u8, stream, "stdout")) return .{ .output = .{ .stream = .stdout, .data = payload } };
    if (std.mem.eql(u8, stream, "stderr")) return .{ .output = .{ .stream = .stderr, .data = payload } };
    return .other;
}

/// The first `snap_` id in the answer. The id is a slice of `body`.
pub fn parseSnapshotId(body: []const u8) ParseError![]const u8 {
    const prefix = "snap_";
    var start: usize = 0;
    while (std.mem.find(u8, body[start..], prefix)) |offset| {
        const begin = start + offset;
        const digits_start = begin + prefix.len;
        var end = digits_start;
        while (end < body.len and isAlnum(body[end])) end += 1;
        if (end > digits_start) return body[begin..end];
        start = digits_start;
    }
    return error.UnexpectedAnswer;
}

/// Reads a sandbox listing page.
pub fn parseListing(arena: std.mem.Allocator, body: []const u8) ParseError!Listing {
    const root = try parseObject(arena, body);
    const value = root.get("sandboxes") orelse return error.UnexpectedAnswer;
    const items = switch (value) {
        .array => |array| array.items,
        else => return error.UnexpectedAnswer,
    };
    const sandboxes = try arena.alloc(Listed, items.len);
    for (items, 0..) |item, index| {
        const entry = objectOf(item) orelse return error.UnexpectedAnswer;
        sandboxes[index] = .{
            .name = stringOf(entry.get("name")) orelse return error.UnexpectedAnswer,
            .status = stringOf(entry.get("status")) orelse "",
            .owner = ownerOf(entry),
        };
    }
    var next: ?[]const u8 = null;
    if (root.get("pagination")) |pagination_value| {
        if (objectOf(pagination_value)) |pagination| next = stringOf(pagination.get("next"));
    }
    return .{ .sandboxes = sandboxes, .next = next };
}

/// The message to show for an error answer: the API's message, or a short
/// excerpt of the body when there is none.
pub fn errorMessage(arena: std.mem.Allocator, status: u16, body: []const u8) error{OutOfMemory}![]const u8 {
    if (try serverMessage(arena, body)) |message| {
        return arena.print("HTTP {d}: {s}", .{ status, try sanitize(arena, message[0..excerptEnd(message)]) });
    }
    const excerpt = try sanitize(arena, body[0..excerptEnd(body)]);
    if (excerpt.len == 0) return arena.print("HTTP {d}", .{status});
    return arena.print("HTTP {d}: {s}", .{ status, excerpt });
}

/// The end of the body excerpt: at most `max_excerpt_bytes`, cut before a
/// UTF-8 character that the limit would split.
fn excerptEnd(body: []const u8) usize {
    if (body.len <= max_excerpt_bytes) return body.len;
    var end: usize = max_excerpt_bytes;
    while (end > 0 and (body[end] & 0xc0) == 0x80) end -= 1;
    return end;
}

/// A copy of `text` with every control byte replaced by `?`.
fn sanitize(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    const out = try arena.alloc(u8, text.len);
    for (text, 0..) |byte, index| {
        out[index] = if (byte < 0x20 or byte == 0x7f) '?' else byte;
    }
    return out;
}

fn serverMessage(arena: std.mem.Allocator, body: []const u8) error{OutOfMemory}!?[]const u8 {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const root = objectOf(value) orelse return null;
    const error_value = root.get("error") orelse return null;
    const error_object = objectOf(error_value) orelse return null;
    return stringOf(error_object.get("message"));
}

/// Builds the network policy JSON for a sandbox.
fn networkJson(network: config.Network) NetworkJson {
    return switch (network) {
        .deny_all => .{ .mode = "deny-all" },
        .allow_all => .{ .mode = "allow-all" },
        .allow => |domains| .{ .mode = "custom", .allowedDomains = domains },
    };
}

/// Writes `value` as JSON. Optional fields that are null are left out.
fn stringify(arena: std.mem.Allocator, value: anytype) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &out.writer) catch
        return error.OutOfMemory;
    return try out.toOwnedSlice();
}

/// Percent-encodes `text` for a query value. Only unreserved characters stay.
fn percentEncode(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    var length: usize = 0;
    for (text) |byte| length += if (isUnreserved(byte)) 1 else 3;
    const out = try arena.alloc(u8, length);
    var index: usize = 0;
    for (text) |byte| {
        if (isUnreserved(byte)) {
            out[index] = byte;
            index += 1;
        } else {
            out[index] = '%';
            out[index + 1] = hex_digits[byte >> 4];
            out[index + 2] = hex_digits[byte & 0x0f];
            index += 3;
        }
    }
    return out;
}

fn isUnreserved(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// True when `text` is 1 to 128 letters, digits, `_`, or `-`: safe in a path.
fn isSafeId(text: []const u8) bool {
    if (text.len == 0 or text.len > max_id_len) return false;
    for (text) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

/// True when `text` is an absolute path of at most 4096 bytes with no control bytes.
fn isSafePath(text: []const u8) bool {
    if (text.len == 0 or text.len > max_path_len or text[0] != '/') return false;
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn isAlnum(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9' => true,
        else => false,
    };
}

fn parseObject(arena: std.mem.Allocator, text: []const u8) ParseError!std.json.ObjectMap {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnexpectedAnswer,
    };
    return objectOf(value) orelse return error.UnexpectedAnswer;
}

fn objectOf(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => null,
    };
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    return switch (found) {
        .string => |text| text,
        else => null,
    };
}

fn integerOf(value: ?std.json.Value) ?i64 {
    const found = value orelse return null;
    return switch (found) {
        .integer => |number| number,
        else => null,
    };
}

fn commandOf(object: std.json.ObjectMap) ParseError!Command {
    const id = stringOf(object.get("id")) orelse return error.UnexpectedAnswer;
    return .{ .id = id, .exit_code = integerOf(object.get("exitCode")) };
}

fn ownerOf(entry: std.json.ObjectMap) ?[]const u8 {
    const tags_value = entry.get("tags") orelse return null;
    const tags = objectOf(tags_value) orelse return null;
    return stringOf(tags.get("owner"));
}

fn parseTestBody(arena: std.mem.Allocator, body: []const u8) !std.json.ObjectMap {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    return objectOf(value) orelse return error.TestUnexpectedResult;
}

/// Fails when `object` has a key that is not in `allowed`.
fn expectKeysWithin(object: std.json.ObjectMap, allowed: []const []const u8) !void {
    var keys = object.iterator();
    while (keys.next()) |entry| {
        var found = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "create sends the source, network, resources, and tags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const request = try create(arena, "team-a", .{
        .name = "fx-1",
        .project = "proj",
        .persistent = false,
        .timeout_ms = 600000,
        .source = .{ .snapshot = "snap_AbC" },
        .network = .{ .allow = &.{ "a.com", "*.b.com" } },
        .vcpus = 8,
        .tags = &.{ .{ .name = "fx", .value = "isolated" }, .{ .name = "owner", .value = "host:1" } },
    });
    try std.testing.expectEqual(Method.POST, request.method);
    try std.testing.expectEqualStrings("/v2/sandboxes?slug=team-a", request.target);
    try std.testing.expectEqualStrings(json_type, request.content_type.?);

    const root = try parseTestBody(arena, request.body);
    try expectKeysWithin(root, &.{ "name", "projectId", "persistent", "timeout", "tags", "resources", "source", "networkPolicy" });
    try std.testing.expectEqualStrings("fx-1", root.get("name").?.string);
    try std.testing.expectEqualStrings("proj", root.get("projectId").?.string);
    try std.testing.expectEqual(false, root.get("persistent").?.bool);
    try std.testing.expectEqual(@as(i64, 600000), root.get("timeout").?.integer);
    const source = root.get("source").?.object;
    try std.testing.expectEqualStrings("snapshot", source.get("type").?.string);
    try std.testing.expectEqualStrings("snap_AbC", source.get("snapshotId").?.string);
    const policy = root.get("networkPolicy").?.object;
    try std.testing.expectEqualStrings("custom", policy.get("mode").?.string);
    const domains = policy.get("allowedDomains").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), domains.len);
    try std.testing.expectEqualStrings("a.com", domains[0].string);
    try std.testing.expectEqualStrings("*.b.com", domains[1].string);
    try std.testing.expectEqual(@as(i64, 8), root.get("resources").?.object.get("vcpus").?.integer);
    try std.testing.expectEqualStrings("host:1", root.get("tags").?.object.get("owner").?.string);
    try std.testing.expect(root.get("env") == null);
    try std.testing.expect(root.get("image") == null);
}

test "create maps deny and allow-all networks and an image" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const deny = try create(arena, "t", .{ .name = "a", .project = "p", .persistent = true, .timeout_ms = 1, .network = .deny_all });
    const deny_root = try parseTestBody(arena, deny.body);
    try std.testing.expectEqualStrings("deny-all", deny_root.get("networkPolicy").?.object.get("mode").?.string);
    try std.testing.expect(deny_root.get("networkPolicy").?.object.get("allowedDomains") == null);

    const open = try create(arena, "t", .{ .name = "a", .project = "p", .persistent = true, .timeout_ms = 1, .network = .allow_all });
    const open_root = try parseTestBody(arena, open.body);
    try std.testing.expectEqualStrings("allow-all", open_root.get("networkPolicy").?.object.get("mode").?.string);

    const image = try create(arena, "t", .{ .name = "a", .project = "p", .persistent = true, .timeout_ms = 1, .source = .{ .image = "node24" } });
    const image_root = try parseTestBody(arena, image.body);
    try std.testing.expectEqualStrings("node24", image_root.get("image").?.string);
    try std.testing.expect(image_root.get("source") == null);

    const plain = try create(arena, "t", .{ .name = "a", .project = "p", .persistent = true, .timeout_ms = 1 });
    const plain_root = try parseTestBody(arena, plain.body);
    try std.testing.expect(plain_root.get("source") == null);
    try std.testing.expect(plain_root.get("image") == null);
    try std.testing.expect(plain_root.get("networkPolicy") == null);
    try std.testing.expect(plain_root.get("resources") == null);
}

test "create refuses a recipe source" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.RecipeNotBuilt, create(arena, "t", .{
        .name = "a",
        .project = "p",
        .persistent = false,
        .timeout_ms = 1,
        .source = .{ .recipe = "/r.sh" },
    }));
}

test "paths refuse unsafe names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "a/b", "..", "", "x?y" }) |name| {
        try std.testing.expectError(error.InvalidName, getNamed(arena, "t", "p", name, true));
    }
    const too_long = try arena.alloc(u8, 129);
    @memset(too_long, 'a');
    try std.testing.expectError(error.InvalidName, getNamed(arena, "t", "p", too_long, true));
    const longest = try arena.alloc(u8, 128);
    @memset(longest, 'a');
    _ = try getNamed(arena, "t", "p", longest, false);

    try std.testing.expectError(error.InvalidName, kill(arena, "t", "sbx_1", "cmd 1"));
    try std.testing.expectError(error.InvalidName, waitCommand(arena, "t", "../x", "cmd_1"));
    try std.testing.expectError(error.InvalidName, runCommand(arena, "t", "", .{}));
    try std.testing.expectError(error.InvalidName, create(arena, "t", .{
        .name = "a/b",
        .project = "p",
        .persistent = false,
        .timeout_ms = 1,
    }));
    try std.testing.expectError(error.InvalidPath, writeArchive(arena, "t", "sbx_1", "gz", "relative"));
    try std.testing.expectError(error.InvalidPath, writeArchive(arena, "t", "sbx_1", "gz", "/w\r\nx-evil: 1"));
    try std.testing.expectError(error.InvalidPath, readFile(arena, "t", "sbx_1", "/a\x00b"));
}

test "queries are percent-encoded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const request = try list(arena, "my team", "p", .{ .name = "fx", .value = "isolated" }, "c/1");
    try std.testing.expectEqual(Method.GET, request.method);
    try std.testing.expectEqualStrings(
        "/v2/sandboxes?project=p&tags=fx%3Aisolated&limit=50&cursor=c%2F1&slug=my%20team",
        request.target,
    );
    try std.testing.expectEqualStrings("", request.body);
}

test "command bodies omit unset fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain = try runCommand(arena, "team-a", "sbx_1", .{ .args = &.{ "-lc", "echo hi" } });
    try std.testing.expectEqual(Method.POST, plain.method);
    try std.testing.expectEqualStrings("/v2/sandboxes/sessions/sbx_1/cmd?slug=team-a", plain.target);
    const plain_root = try parseTestBody(arena, plain.body);
    try expectKeysWithin(plain_root, &.{ "command", "args", "cwd", "env", "sudo", "wait", "logs", "timeout" });
    try std.testing.expectEqualStrings("bash", plain_root.get("command").?.string);
    try std.testing.expectEqual(@as(usize, 2), plain_root.get("args").?.array.items.len);
    try std.testing.expectEqual(true, plain_root.get("wait").?.bool);
    try std.testing.expectEqual(true, plain_root.get("logs").?.bool);
    for ([_][]const u8{ "cwd", "env", "sudo", "timeout" }) |key| {
        try std.testing.expect(plain_root.get(key) == null);
    }

    const full = try runCommand(arena, "team-a", "sbx_1", .{
        .args = &.{ "-lc", "echo hi" },
        .cwd = "/w",
        .env = &.{.{ .name = "A", .value = "1" }},
        .sudo = true,
        .timeout_ms = 5000,
    });
    const full_root = try parseTestBody(arena, full.body);
    try std.testing.expectEqualStrings("/w", full_root.get("cwd").?.string);
    try std.testing.expectEqualStrings("1", full_root.get("env").?.object.get("A").?.string);
    try std.testing.expectEqual(true, full_root.get("sudo").?.bool);
    try std.testing.expectEqual(@as(i64, 5000), full_root.get("timeout").?.integer);
}

test "fs requests carry their headers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const archive = try writeArchive(arena, "team-a", "sbx_1", "gz-bytes", "/w");
    try std.testing.expectEqual(Method.POST, archive.method);
    try std.testing.expectEqualStrings("/v2/sandboxes/sessions/sbx_1/fs/write?slug=team-a", archive.target);
    try std.testing.expectEqualStrings("application/gzip", archive.content_type.?);
    try std.testing.expectEqualStrings("/w", archive.extract_cwd.?);
    try std.testing.expectEqualStrings("gz-bytes", archive.body);

    const read = try readFile(arena, "team-a", "sbx_1", "/w/a.txt");
    try std.testing.expectEqualStrings("/v2/sandboxes/sessions/sbx_1/fs/read?slug=team-a", read.target);
    try std.testing.expectEqualStrings("{\"path\":\"/w/a.txt\"}", read.body);
    try std.testing.expect(read.extract_cwd == null);
}

test "sandbox, command, and snapshot requests have their exact targets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resumed = try getNamed(arena, "team-a", "proj", "sbx-1", true);
    try std.testing.expectEqual(Method.GET, resumed.method);
    try std.testing.expectEqualStrings("/v2/sandboxes/sbx-1?projectId=proj&resume=true&slug=team-a", resumed.target);

    const stopped = try getNamed(arena, "team-a", "proj", "sbx-1", false);
    try std.testing.expectEqualStrings("/v2/sandboxes/sbx-1?projectId=proj&resume=false&slug=team-a", stopped.target);

    const removed = try delete(arena, "team-a", "proj", "sbx-1");
    try std.testing.expectEqual(Method.DELETE, removed.method);
    try std.testing.expectEqualStrings("/v2/sandboxes/sbx-1?projectId=proj&slug=team-a", removed.target);

    const killed = try kill(arena, "team-a", "sbx_1", "cmd_1");
    try std.testing.expectEqualStrings("/v2/sandboxes/sessions/sbx_1/cmd/cmd_1/kill?slug=team-a", killed.target);
    try std.testing.expectEqualStrings("{\"signal\":15}", killed.body);

    const waited = try waitCommand(arena, "team-a", "sbx_1", "cmd_1");
    try std.testing.expectEqual(Method.GET, waited.method);
    try std.testing.expectEqualStrings("/v2/sandboxes/sessions/sbx_1/cmd/cmd_1?wait=true&slug=team-a", waited.target);
    try std.testing.expectEqualStrings("", waited.body);

    const snap = try snapshot(arena, "team-a", "sbx_1", 60000);
    try std.testing.expectEqualStrings("/v2/sandboxes/sessions/sbx_1/snapshot?slug=team-a", snap.target);
    try std.testing.expectEqualStrings("{\"expiration\":60000}", snap.body);

    const stop = try stopSession(arena, "team-a", "sbx_1");
    try std.testing.expectEqual(Method.POST, stop.method);
    try std.testing.expectEqualStrings("/v2/sandboxes/sessions/sbx_1/stop?slug=team-a", stop.target);
    try std.testing.expectEqualStrings("", stop.body);
}

test "a snapshot read has its exact target and refuses unsafe ids" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const read = try getSnapshot(arena, "team-a", "proj", "snap_AbC");
    try std.testing.expectEqual(Method.GET, read.method);
    try std.testing.expectEqualStrings("/v2/sandboxes/snapshots/snap_AbC?project=proj&slug=team-a", read.target);
    try std.testing.expectError(error.InvalidName, getSnapshot(arena, "team-a", "proj", "snap/../x"));
}

test "log lines parse into commands, output, and failures" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    switch (try parseLogLine(arena, "{\"command\":{\"id\":\"cmd_1\",\"exitCode\":null}}")) {
        .command => |command| {
            try std.testing.expectEqualStrings("cmd_1", command.id);
            try std.testing.expectEqual(@as(?i64, null), command.exit_code);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (try parseLogLine(arena, "{\"data\":\"out1\\n\",\"stream\":\"stdout\"}")) {
        .output => |output| {
            try std.testing.expectEqual(Stream.stdout, output.stream);
            try std.testing.expectEqualStrings("out1\n", output.data);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (try parseLogLine(arena, "{\"data\":\"err1\\n\",\"stream\":\"stderr\"}")) {
        .output => |output| {
            try std.testing.expectEqual(Stream.stderr, output.stream);
            try std.testing.expectEqualStrings("err1\n", output.data);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (try parseLogLine(arena, "{\"command\":{\"id\":\"cmd_1\",\"exitCode\":3}}")) {
        .command => |command| try std.testing.expectEqual(@as(?i64, 3), command.exit_code),
        else => return error.TestUnexpectedResult,
    }
    switch (try parseLogLine(arena, "{\"data\":{\"code\":\"sandbox_stream_closed\",\"message\":\"stream closed early\"},\"stream\":\"stdout\"}")) {
        .failure => |failure| {
            try std.testing.expectEqualStrings("sandbox_stream_closed", failure.code);
            try std.testing.expectEqualStrings("stream closed early", failure.message);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (try parseLogLine(arena, "  ")) {
        .other => {},
        else => return error.TestUnexpectedResult,
    }
    switch (try parseLogLine(arena, "{\"data\":\"x\",\"stream\":\"system\"}")) {
        .other => {},
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectError(error.UnexpectedAnswer, parseLogLine(arena, "not json"));
}

test "answers parse sandboxes, commands, snapshots, and listings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sandbox = try parseSandbox(arena, "{\"sandbox\":{\"currentSessionId\":\"sbx_1\",\"status\":\"running\"}}");
    try std.testing.expectEqualStrings("sbx_1", sandbox.session_id);
    try std.testing.expectEqualStrings("running", sandbox.status);
    try std.testing.expectError(error.UnexpectedAnswer, parseSandbox(arena, "{}"));

    const killed = try parseCommand(arena, "{\"command\":{\"id\":\"cmd_9\",\"exitCode\":143}}");
    try std.testing.expectEqualStrings("cmd_9", killed.id);
    try std.testing.expectEqual(@as(?i64, 143), killed.exit_code);

    try std.testing.expectEqualStrings("snap_AbC123", try parseSnapshotId("{\"snapshotId\":\"snap_AbC123\"}"));
    try std.testing.expectEqualStrings("snap_Xy9", try parseSnapshotId("created snap_Xy9 ok"));
    try std.testing.expectError(error.UnexpectedAnswer, parseSnapshotId("no id here"));

    const listing = try parseListing(arena, "{\"sandboxes\":[{\"name\":\"a\",\"status\":\"running\",\"tags\":{\"owner\":\"host:1\"}},{\"name\":\"b\",\"status\":\"stopped\",\"tags\":{}}],\"pagination\":{\"count\":2,\"next\":\"cur2\"}}");
    try std.testing.expectEqual(@as(usize, 2), listing.sandboxes.len);
    try std.testing.expectEqualStrings("host:1", listing.sandboxes[0].owner.?);
    try std.testing.expect(listing.sandboxes[1].owner == null);
    try std.testing.expectEqualStrings("cur2", listing.next.?);

    const last = try parseListing(arena, "{\"sandboxes\":[],\"pagination\":{\"next\":null}}");
    try std.testing.expectEqual(@as(usize, 0), last.sandboxes.len);
    try std.testing.expect(last.next == null);
}

test "error messages are short and readable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "HTTP 403: Not allowed",
        try errorMessage(arena, 403, "{\"error\":{\"code\":\"forbidden\",\"message\":\"Not allowed\"}}"),
    );
    try std.testing.expectEqualStrings("HTTP 502", try errorMessage(arena, 502, ""));

    const long_body = try arena.alloc(u8, 300);
    @memset(long_body, 'x');
    const message = try errorMessage(arena, 500, long_body);
    try std.testing.expect(std.mem.startsWith(u8, message, "HTTP 500"));
    try std.testing.expect(message.len <= 220);

    const red = try errorMessage(arena, 500, "bad\x1b[31mred");
    try std.testing.expectEqualStrings("HTTP 500: bad?[31mred", red);
    try std.testing.expect(std.mem.find(u8, red, "\x1b") == null);

    const split = try arena.alloc(u8, 201);
    @memset(split[0..199], 'x');
    @memcpy(split[199..], "\xc3\xa9");
    const cut = try errorMessage(arena, 500, split);
    try std.testing.expectEqual(@as(usize, "HTTP 500: ".len + 199), cut.len);
    try std.testing.expect(std.mem.endsWith(u8, cut, "x"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));

    const long_message_text = try arena.alloc(u8, 300);
    @memset(long_message_text, 'y');
    const long_message_body = try arena.print("{{\"error\":{{\"message\":\"{s}\"}}}}", .{long_message_text});
    const long_message = try errorMessage(arena, 403, long_message_body);
    try std.testing.expectEqual(@as(usize, "HTTP 403: ".len + 200), long_message.len);
}
