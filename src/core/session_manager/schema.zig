//! The line envelope owned by the manager.
//!
//! Every line starts with the same header, in this exact order:
//!   {"v":1,"seq":7,"ts":1727400000000,"kind":"turn_committed"
//! Kind fields follow, then `,"crc":"........"}` and a newline (log.zig).
//! Because the manager writes the header in one canonical form, it is parsed
//! positionally: no JSON parser runs on the hot path.

const std = @import("std");

/// The format version this manager writes and fully understands. A line
/// with a newer `v` makes the session read-only.
pub const version: u32 = 1;

/// Every kind the manager knows. The manager owns this set; fx content
/// lives inside `data` and `value` fields and is never interpreted here.
pub const Kind = enum {
    session_created,
    turn_started,
    item,
    compacted,
    turn_committed,
    turn_interrupted,
    set,
    child_spawned,
    child_finished,
    snapshot,
    closed,
};

pub const Header = struct {
    v: u32,
    seq: u64,
    ts_ms: u64,
    /// Borrowed from the line.
    kind_name: []const u8,
    /// Null when this version does not know the kind; the fold skips it.
    kind: ?Kind,
    /// Bytes of the line taken by the header, through the kind's closing quote.
    len: usize,
};

pub const HeaderError = error{BadHeader};

const max_kind_name_bytes = 32;

/// Appends the canonical header for one line.
pub fn appendHeader(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    seq: u64,
    ts_ms: u64,
    kind: Kind,
) error{OutOfMemory}!void {
    try out.print(gpa, "{{\"v\":{d},\"seq\":{d},\"ts\":{d},\"kind\":\"{s}\"", .{
        version, seq, ts_ms, @tagName(kind),
    });
}

/// Parses the header at the start of `line`. Strict: the exact field order,
/// decimal numbers without leading zeros, `v` and `seq` at least 1, and a
/// kind name of 1 to 32 lowercase letters or underscores.
pub fn parseHeader(line: []const u8) HeaderError!Header {
    var p: Cursor = .{ .bytes = line };
    try p.literal("{\"v\":");
    const v = try p.uint(u32);
    try p.literal(",\"seq\":");
    const seq = try p.uint(u64);
    try p.literal(",\"ts\":");
    const ts_ms = try p.uint(u64);
    try p.literal(",\"kind\":\"");
    const name_start = p.at;
    while (p.at < line.len and isKindChar(line[p.at])) p.at += 1;
    const name = line[name_start..p.at];
    try p.literal("\"");
    if (v == 0 or seq == 0) return error.BadHeader;
    if (name.len == 0 or name.len > max_kind_name_bytes) return error.BadHeader;
    return .{
        .v = v,
        .seq = seq,
        .ts_ms = ts_ms,
        .kind_name = name,
        .kind = std.meta.stringToEnum(Kind, name),
        .len = p.at,
    };
}

fn isKindChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or c == '_';
}

// ---------------------------------------------------------------------------
// Kind fields: the bytes between `kind` and `crc`

pub const Role = enum { root, child };
pub const Host = enum { app, ask, acp, sdk, child };
/// Hosts end a turn with `cancel` or `failed` (D21); the manager writes
/// `closed` on close and `crash` on reopen.
pub const Reason = enum { cancel, failed, closed, crash };
/// How a child's work item ended (D22). Hosts never write `lost`.
pub const Outcome = enum { ok, failed, cancelled, interrupted, lost };
/// `language` is the conversation language fx keeps per session, a JSON
/// string such as `"es"` or `"und-Latn"` (D18); the index lists it.
/// `client_prompt` (a JSON string) and `tool_identities` are an ACP
/// client's settings (D46). `moved_files` records a session moved off fx's
/// side folder: its value names the blob that maps old handles to blobs,
/// and its line lists every moved blob (D47). `compaction_records` names
/// the blob that maps fx's compactor record names to blobs, and its line
/// lists the map and the records it adds (D50).
pub const SetKey = enum { prefs, title, permissions, usage, workspace, language, client_prompt, tool_identities, moved_files, compaction_records };

pub const ForkOrigin = struct { id: []const u8, seq: u64 };

/// The fields of one line, by kind. Slices are borrowed. `data`, `value`
/// and `state` are raw JSON, stored and returned byte for byte.
pub const Body = union(Kind) {
    session_created: Created,
    turn_started: Turn,
    item: Piece,
    compacted: Compacted,
    turn_committed: Turn,
    turn_interrupted: Interrupted,
    set: Setting,
    child_spawned: WorkItem,
    child_finished: Finished,
    snapshot: Snapshot,
    closed: void,

    pub const Created = struct {
        id: []const u8,
        workspace: []const u8,
        role: Role,
        host: Host,
        parent: ?[]const u8 = null,
        forked_from: ?ForkOrigin = null,
    };
    pub const Turn = struct { turn: u64 };
    pub const Piece = struct {
        turn: u64,
        /// fx's name for the piece (`steering`, `tool_call`, ...); checked
        /// by `validItemType`, never interpreted (D17).
        type: []const u8,
        data: []const u8,
        /// Hashes of the blobs this piece refers to; each exists before the line.
        blobs: []const []const u8 = &.{},
    };
    pub const Compacted = struct { turn: ?u64, data: []const u8 };
    pub const Interrupted = struct { turn: u64, reason: Reason };
    pub const Setting = struct {
        key: SetKey,
        value: []const u8,
        /// Hashes of the blobs this setting refers to, under the item's
        /// rule; allowed outside a turn (D47).
        blobs: []const []const u8 = &.{},
    };

    /// The blobs a line refers to: an item's or a setting's, else none.
    pub fn blobRefs(body: Body) []const []const u8 {
        return switch (body) {
            .item => |piece| piece.blobs,
            .set => |s| s.blobs,
            else => &.{},
        };
    }
    /// `data` is fx's raw JSON about the child or the work (D22).
    pub const WorkItem = struct { child: []const u8, work_id: []const u8, data: ?[]const u8 = null };
    pub const Finished = struct { child: []const u8, work_id: []const u8, outcome: Outcome, data: ?[]const u8 = null };
    pub const Snapshot = struct { covers_seq: u64, state: []const u8, compaction_offset: ?u64 };
};

/// Appends the fields of `body`. Strings must be valid UTF-8 and raw values
/// valid JSON; L4 checks both before anything reaches here.
pub fn appendBody(gpa: std.mem.Allocator, out: *std.ArrayList(u8), body: Body) error{OutOfMemory}!void {
    var w: FieldWriter = .{ .gpa = gpa, .out = out };
    switch (body) {
        .session_created => |c| {
            try w.string("id", c.id);
            try w.string("workspace", c.workspace);
            try w.string("role", @tagName(c.role));
            try w.string("host", @tagName(c.host));
            if (c.parent) |parent| try w.string("parent", parent);
            if (c.forked_from) |origin| {
                try w.key("forked_from");
                try out.appendSlice(gpa, "{\"id\":");
                try appendJsonString(gpa, out, origin.id);
                try out.print(gpa, ",\"seq\":{d}}}", .{origin.seq});
            }
        },
        .turn_started, .turn_committed => |t| try w.number("turn", t.turn),
        .item => |p| {
            try w.number("turn", p.turn);
            try w.string("type", p.type);
            try w.raw("data", p.data);
            try w.blobList(p.blobs);
        },
        .compacted => |c| {
            if (c.turn) |turn| try w.number("turn", turn);
            try w.raw("data", c.data);
        },
        .turn_interrupted => |i| {
            try w.number("turn", i.turn);
            try w.string("reason", @tagName(i.reason));
        },
        .set => |s| {
            try w.string("key", @tagName(s.key));
            try w.raw("value", s.value);
            try w.blobList(s.blobs);
        },
        .child_spawned => |c| {
            try w.string("child", c.child);
            try w.string("work_id", c.work_id);
            if (c.data) |data| try w.raw("data", data);
        },
        .child_finished => |c| {
            try w.string("child", c.child);
            try w.string("work_id", c.work_id);
            try w.string("outcome", @tagName(c.outcome));
            if (c.data) |data| try w.raw("data", data);
        },
        .snapshot => |s| {
            try w.number("covers_seq", s.covers_seq);
            try w.raw("state", s.state);
            if (s.compaction_offset) |offset| try w.number("compaction_offset", offset);
        },
        .closed => {},
    }
}

pub const BodyError = error{ BadBody, OutOfMemory };

/// Parses the fields of a line of `kind`. Unknown fields are ignored.
/// Returned slices point into `fields` or into `arena`.
pub fn parseBody(arena: std.mem.Allocator, kind: Kind, fields: []const u8) BodyError!Body {
    return bodyOf(kind, try Fields.parse(arena, fields));
}

/// `parseBody` for a whole checked line, newline included. The line is a
/// JSON object up to its newline, so its fields are read in place rather
/// than copied; the header and `crc` fields are never body field names.
pub fn parseLineBody(arena: std.mem.Allocator, kind: Kind, line: []const u8) BodyError!Body {
    if (line.len == 0 or line[line.len - 1] != '\n') return error.BadBody;
    return bodyOf(kind, try Fields.parseObject(arena, line[0 .. line.len - 1]));
}

fn bodyOf(kind: Kind, f: Fields) BodyError!Body {
    return switch (kind) {
        .session_created => .{ .session_created = .{
            .id = try f.req([]const u8, "id"),
            .workspace = try f.req([]const u8, "workspace"),
            .role = try f.req(Role, "role"),
            .host = try f.req(Host, "host"),
            .parent = try f.opt([]const u8, "parent"),
            .forked_from = try f.opt(ForkOrigin, "forked_from"),
        } },
        .turn_started => .{ .turn_started = .{ .turn = try f.req(u64, "turn") } },
        .turn_committed => .{ .turn_committed = .{ .turn = try f.req(u64, "turn") } },
        .item => .{ .item = .{
            .turn = try f.req(u64, "turn"),
            .type = try f.req([]const u8, "type"),
            .data = try f.rawReq("data"),
            .blobs = try f.opt([]const []const u8, "blobs") orelse &.{},
        } },
        .compacted => .{ .compacted = .{ .turn = try f.opt(u64, "turn"), .data = try f.rawReq("data") } },
        .turn_interrupted => .{ .turn_interrupted = .{
            .turn = try f.req(u64, "turn"),
            .reason = try f.req(Reason, "reason"),
        } },
        .set => .{ .set = .{
            .key = try f.req(SetKey, "key"),
            .value = try f.rawReq("value"),
            .blobs = try f.opt([]const []const u8, "blobs") orelse &.{},
        } },
        .child_spawned => .{ .child_spawned = .{
            .child = try f.req([]const u8, "child"),
            .work_id = try f.req([]const u8, "work_id"),
            .data = f.raw("data"),
        } },
        .child_finished => .{ .child_finished = .{
            .child = try f.req([]const u8, "child"),
            .work_id = try f.req([]const u8, "work_id"),
            .outcome = try f.req(Outcome, "outcome"),
            .data = f.raw("data"),
        } },
        .snapshot => .{ .snapshot = .{
            .covers_seq = try f.req(u64, "covers_seq"),
            .state = try f.rawReq("state"),
            .compaction_offset = try f.opt(u64, "compaction_offset"),
        } },
        .closed => .closed,
    };
}

/// The top-level fields of a JSON object fragment, as raw value slices.
pub const Fields = struct {
    arena: std.mem.Allocator,
    names: []const []const u8,
    values: []const []const u8,

    /// `fields` is empty or `,"a":1,"b":...` as written by `appendBody`.
    pub fn parse(arena: std.mem.Allocator, fields: []const u8) BodyError!Fields {
        if (fields.len == 0) return .{ .arena = arena, .names = &.{}, .values = &.{} };
        if (fields[0] != ',') return error.BadBody;
        const object = try arena.alloc(u8, fields.len + 1);
        object[0] = '{';
        @memcpy(object[1..fields.len], fields[1..]);
        object[fields.len] = '}';
        return parseObject(arena, object);
    }

    /// `object` is a complete JSON object; slices point into it.
    pub fn parseObject(arena: std.mem.Allocator, object: []const u8) BodyError!Fields {
        return splitObject(arena, object) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Unusual => parseObjectStrict(arena, object),
        };
    }

    const max_split_fields = 24;

    /// The fast path of `parseObject`, for objects as this module writes
    /// them: no whitespace, unescaped names, at most `max_split_fields`.
    /// It finds each value's end without tokenizing it, which holds because
    /// every raw value was validated when appended and every line is
    /// checked by its CRC before it is parsed. Anything else is `Unusual`
    /// and goes to the strict path, so results and errors do not change.
    fn splitObject(arena: std.mem.Allocator, object: []const u8) (error{ OutOfMemory, Unusual })!Fields {
        var names: [max_split_fields][]const u8 = undefined;
        var values: [max_split_fields][]const u8 = undefined;
        var n: usize = 0;
        if (object.len < 2 or object[0] != '{' or object[object.len - 1] != '}') return error.Unusual;
        var i: usize = 1;
        if (object.len == 2) return .{ .arena = arena, .names = &.{}, .values = &.{} };
        while (true) {
            if (n == max_split_fields or object[i] != '"') return error.Unusual;
            const name_end = std.mem.findScalarPos(u8, object, i + 1, '"') orelse return error.Unusual;
            const name = object[i + 1 .. name_end];
            if (std.mem.findScalar(u8, name, '\\') != null) return error.Unusual;
            i = name_end + 1;
            if (i >= object.len or object[i] != ':') return error.Unusual;
            i += 1;
            const value_end = valueEnd(object, i) orelse return error.Unusual;
            if (value_end == i) return error.Unusual;
            names[n] = name;
            values[n] = object[i..value_end];
            n += 1;
            i = value_end;
            if (i == object.len - 1) break;
            if (object[i] != ',') return error.Unusual;
            i += 1;
        }
        return .{ .arena = arena, .names = try rawCopy([]const u8, arena, names[0..n]), .values = try rawCopy([]const u8, arena, values[0..n]) };
    }

    /// Where the value starting at `i` ends, or null for bytes this writer
    /// never produces.
    fn valueEnd(bytes: []const u8, i: usize) ?usize {
        if (i >= bytes.len) return null;
        switch (bytes[i]) {
            '"' => return stringEnd(bytes, i),
            '{', '[' => {
                var depth: usize = 0;
                var j = i;
                while (j < bytes.len) {
                    switch (bytes[j]) {
                        '"' => {
                            j = stringEnd(bytes, j) orelse return null;
                            continue;
                        },
                        '{', '[' => depth += 1,
                        '}', ']' => {
                            depth -= 1;
                            if (depth == 0) return j + 1;
                        },
                        else => {},
                    }
                    j += 1;
                }
                return null;
            },
            else => {
                // A number, `true`, `false` or `null`: up to the next
                // delimiter of the enclosing object.
                var j = i;
                while (j < bytes.len and bytes[j] != ',' and bytes[j] != '}') j += 1;
                return if (j < bytes.len) j else null;
            },
        }
    }

    /// Just past the closing quote of the string opening at `open`: the next
    /// quote not escaped by an odd run of backslashes.
    fn stringEnd(bytes: []const u8, open: usize) ?usize {
        var from = open + 1;
        while (true) {
            const quote = std.mem.findScalarPos(u8, bytes, from, '"') orelse return null;
            var run: usize = 0;
            while (quote - run > open + 1 and bytes[quote - run - 1] == '\\') run += 1;
            if (run % 2 == 0) return quote + 1;
            from = quote + 1;
        }
    }

    /// `arena.dupe` without the safety fill: every element is copied.
    fn rawCopy(comptime T: type, arena: std.mem.Allocator, items: []const T) error{OutOfMemory}![]const T {
        if (items.len == 0) return &.{};
        const bytes = arena.rawAlloc(items.len * @sizeOf(T), .of(T), @returnAddress()) orelse return error.OutOfMemory;
        const copy: [*]T = @ptrCast(@alignCast(bytes));
        @memcpy(copy[0..items.len], items);
        return copy[0..items.len];
    }

    fn parseObjectStrict(arena: std.mem.Allocator, object: []const u8) BodyError!Fields {
        var names: std.ArrayList([]const u8) = .empty;
        var values: std.ArrayList([]const u8) = .empty;
        var scanner = std.json.Scanner.initCompleteInput(arena, object);
        if ((scanner.next() catch return error.BadBody) != .object_begin) return error.BadBody;
        while (true) {
            const token = scanner.nextAlloc(arena, .alloc_if_needed) catch return error.BadBody;
            const field_name = switch (token) {
                .object_end => break,
                .string => |s| s,
                .allocated_string => |s| s,
                else => return error.BadBody,
            };
            const start = scanner.cursor;
            scanner.skipValue() catch return error.BadBody;
            const value = std.mem.trimStart(u8, object[start..scanner.cursor], ": \t\r\n");
            try names.append(arena, field_name);
            try values.append(arena, value);
        }
        return .{ .arena = arena, .names = names.items, .values = values.items };
    }

    pub fn raw(f: Fields, field_name: []const u8) ?[]const u8 {
        for (f.names, f.values) |n, v| {
            if (std.mem.eql(u8, n, field_name)) return v;
        }
        return null;
    }

    pub fn rawReq(f: Fields, field_name: []const u8) BodyError![]const u8 {
        return f.raw(field_name) orelse error.BadBody;
    }

    pub fn req(f: Fields, comptime T: type, field_name: []const u8) BodyError!T {
        return (try f.opt(T, field_name)) orelse error.BadBody;
    }

    pub fn opt(f: Fields, comptime T: type, field_name: []const u8) BodyError!?T {
        const value = f.raw(field_name) orelse return null;
        if (std.mem.eql(u8, value, "null")) return null;
        if (fastValue(T, value)) |fast| return fast;
        return std.json.parseFromSliceLeaky(T, f.arena, value, .{}) catch error.BadBody;
    }
};

/// The elements of a complete JSON array, as raw slices into `array`, so
/// nested raw values keep their exact bytes.
pub fn rawElements(arena: std.mem.Allocator, array: []const u8) BodyError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var scanner = std.json.Scanner.initCompleteInput(arena, array);
    if ((scanner.next() catch return error.BadBody) != .array_begin) return error.BadBody;
    while ((scanner.peekNextTokenType() catch return error.BadBody) != .array_end) {
        const start = scanner.cursor;
        scanner.skipValue() catch return error.BadBody;
        try out.append(arena, std.mem.trimStart(u8, array[start..scanner.cursor], ", \t\r\n"));
    }
    return out.items;
}

/// Pure: `value` decoded without a second JSON parse, for the common shapes
/// the parser already validated: a plain unsigned integer, a boolean, or a
/// string with no escapes (its bytes are its content). Null means "take
/// the full parse", which then decides, so results never differ.
fn fastValue(comptime T: type, value: []const u8) ?T {
    switch (@typeInfo(T)) {
        .int => |int| {
            if (int.signedness != .unsigned or value.len == 0 or value.len > 19) return null;
            for (value) |c| if (c < '0' or c > '9') return null;
            if (value.len > 1 and value[0] == '0') return null;
            return std.fmt.parseInt(T, value, 10) catch null;
        },
        .bool => return if (std.mem.eql(u8, value, "true")) true else if (std.mem.eql(u8, value, "false")) false else null,
        .@"enum" => return std.meta.stringToEnum(T, plainString(value) orelse return null),
        .pointer => |ptr| {
            if (ptr.size != .slice or ptr.child != u8 or !ptr.is_const) return null;
            return plainString(value);
        },
        else => return null,
    }
}

/// The content of a JSON string that needs no unescaping, or null.
fn plainString(value: []const u8) ?[]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return null;
    const inner = value[1 .. value.len - 1];
    if (std.mem.findScalar(u8, inner, '\\') != null) return null;
    return inner;
}

const FieldWriter = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),

    fn key(w: FieldWriter, name: []const u8) error{OutOfMemory}!void {
        try w.out.append(w.gpa, ',');
        try appendJsonString(w.gpa, w.out, name);
        try w.out.append(w.gpa, ':');
    }

    fn string(w: FieldWriter, name: []const u8, value: []const u8) error{OutOfMemory}!void {
        try w.key(name);
        try appendJsonString(w.gpa, w.out, value);
    }

    fn number(w: FieldWriter, name: []const u8, value: u64) error{OutOfMemory}!void {
        try w.key(name);
        try w.out.print(w.gpa, "{d}", .{value});
    }

    /// `"blobs":[...]`, written only when there is at least one.
    fn blobList(w: FieldWriter, hashes: []const []const u8) error{OutOfMemory}!void {
        if (hashes.len == 0) return;
        try w.key("blobs");
        try w.out.append(w.gpa, '[');
        for (hashes, 0..) |hash, i| {
            if (i > 0) try w.out.append(w.gpa, ',');
            try appendJsonString(w.gpa, w.out, hash);
        }
        try w.out.append(w.gpa, ']');
    }

    fn raw(w: FieldWriter, name: []const u8, value: []const u8) error{OutOfMemory}!void {
        try w.key(name);
        try w.out.appendSlice(w.gpa, value);
    }
};

/// Appends `s` as a JSON string. `s` must be valid UTF-8.
pub fn appendJsonString(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) error{OutOfMemory}!void {
    std.debug.assert(std.unicode.utf8ValidateSlice(s));
    try out.append(gpa, '"');
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const escape: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        if (escape == null and c >= 0x20) continue;
        try out.appendSlice(gpa, s[start..i]);
        if (escape) |e| {
            try out.appendSlice(gpa, e);
        } else {
            try out.print(gpa, "\\u{x:0>4}", .{c});
        }
        start = i + 1;
    }
    try out.appendSlice(gpa, s[start..]);
    try out.append(gpa, '"');
}

// ---------------------------------------------------------------------------
// Session ids

/// v1's id alphabet, so converted sessions keep their ids, minus the names
/// the v2 layout reserves: a leading `.` (`.tmp`, `.trash`) and the index files.
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 255 or id[0] == '.') return false;
    if (std.mem.eql(u8, id, "index.jsonl") or std.mem.eql(u8, id, "index.lock")) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-') return false;
    }
    return true;
}

pub const new_id_len = 12;

/// Length of a blob name: a SHA-256 hash in lowercase hex.
pub const blob_hash_len = 64;

/// Pure: an item type is 1 to 32 of `a-z`, `0-9` and `_` (D17). The name is
/// fx's; the manager checks only its form.
pub fn validItemType(name: []const u8) bool {
    if (name.len == 0 or name.len > max_item_type_len) return false;
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}

pub const max_item_type_len = 32;

pub fn validBlobHash(hash: []const u8) bool {
    if (hash.len != blob_hash_len) return false;
    for (hash) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

/// The blob name for `bytes`.
pub fn blobHash(bytes: []const u8) [blob_hash_len]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// A fresh id: 9 random bytes as base64url, as v1 does.
pub fn newId(io: std.Io, out: *[new_id_len]u8) void {
    var random_bytes: [9]u8 = undefined;
    io.random(&random_bytes);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, &random_bytes);
}

const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,

    fn literal(c: *Cursor, expected: []const u8) HeaderError!void {
        if (!std.mem.startsWith(u8, c.bytes[c.at..], expected)) return error.BadHeader;
        c.at += expected.len;
    }

    fn uint(c: *Cursor, comptime T: type) HeaderError!T {
        const start = c.at;
        var value: T = 0;
        while (c.at < c.bytes.len and std.ascii.isDigit(c.bytes[c.at])) : (c.at += 1) {
            const digit: T = c.bytes[c.at] - '0';
            value = std.math.mul(T, value, 10) catch return error.BadHeader;
            value = std.math.add(T, value, digit) catch return error.BadHeader;
        }
        const digits = c.at - start;
        if (digits == 0) return error.BadHeader;
        if (digits > 1 and c.bytes[start] == '0') return error.BadHeader;
        return value;
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "header round trip" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendHeader(testing.allocator, &out, 7, 1727400000000, .turn_committed);
    try testing.expectEqualStrings(
        "{\"v\":1,\"seq\":7,\"ts\":1727400000000,\"kind\":\"turn_committed\"",
        out.items,
    );
    try out.appendSlice(testing.allocator, ",\"turn\":1");
    const h = try parseHeader(out.items);
    try testing.expectEqual(@as(u32, 1), h.v);
    try testing.expectEqual(@as(u64, 7), h.seq);
    try testing.expectEqual(@as(u64, 1727400000000), h.ts_ms);
    try testing.expectEqual(Kind.turn_committed, h.kind.?);
    try testing.expectEqualStrings("turn_committed", h.kind_name);
    try testing.expectEqualStrings(",\"turn\":1", out.items[h.len..]);
}

test "unknown kinds parse with a null kind" {
    const h = try parseHeader("{\"v\":1,\"seq\":3,\"ts\":0,\"kind\":\"future_kind\"}");
    try testing.expectEqual(@as(?Kind, null), h.kind);
    try testing.expectEqualStrings("future_kind", h.kind_name);
}

test "malformed headers are rejected" {
    const bad = [_][]const u8{
        "",
        "{\"v\":1}",
        "{\"seq\":1,\"v\":1,\"ts\":0,\"kind\":\"item\"",
        "{\"v\":0,\"seq\":1,\"ts\":0,\"kind\":\"item\"",
        "{\"v\":1,\"seq\":0,\"ts\":0,\"kind\":\"item\"",
        "{\"v\":01,\"seq\":1,\"ts\":0,\"kind\":\"item\"",
        "{\"v\":1,\"seq\":-1,\"ts\":0,\"kind\":\"item\"",
        "{\"v\":1,\"seq\":1,\"ts\":0,\"kind\":\"\"",
        "{\"v\":1,\"seq\":1,\"ts\":0,\"kind\":\"Item\"",
        "{\"v\":1,\"seq\":1,\"ts\":0,\"kind\":\"item",
        "{\"v\":1,\"seq\":18446744073709551616,\"ts\":0,\"kind\":\"item\"",
        "{\"v\":1,\"seq\":1,\"ts\":0,\"kind\":\"abcdefghijklmnopqrstuvwxyzabcdefg\"",
        " {\"v\":1,\"seq\":1,\"ts\":0,\"kind\":\"item\"",
    };
    for (bad) |line| try testing.expectError(error.BadHeader, parseHeader(line));
}

fn roundTrip(arena: std.mem.Allocator, body: Body) !Body {
    var out: std.ArrayList(u8) = .empty;
    try appendBody(arena, &out, body);
    return parseBody(arena, std.meta.activeTag(body), out.items);
}

test "every kind's fields round trip, raw values byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const created = (try roundTrip(arena, .{ .session_created = .{
        .id = "abc",
        .workspace = "/Users/me/my \"project\"\n",
        .role = .child,
        .host = .acp,
        .parent = "p1",
        .forked_from = .{ .id = "src", .seq = 9 },
    } })).session_created;
    try testing.expectEqualStrings("/Users/me/my \"project\"\n", created.workspace);
    try testing.expectEqual(Role.child, created.role);
    try testing.expectEqualStrings("p1", created.parent.?);
    try testing.expectEqual(@as(u64, 9), created.forked_from.?.seq);

    // Whitespace, key order and number spelling inside opaque JSON survive.
    const data = "{ \"b\": 1.50, \"a\": [1e3, \"\\u00e9\"] }";
    const item = (try roundTrip(arena, .{ .item = .{ .turn = 4, .type = "steering", .data = data } })).item;
    try testing.expectEqualStrings("steering", item.type);
    try testing.expectEqualStrings(data, item.data);
    try testing.expectEqual(@as(usize, 0), item.blobs.len);
    const hash = blobHash("body");
    const with_blob = (try roundTrip(arena, .{ .item = .{ .turn = 4, .type = "tool_result", .data = "{}", .blobs = &.{&hash} } })).item;
    try testing.expectEqualStrings(&hash, with_blob.blobs[0]);
    try testing.expect(validBlobHash(with_blob.blobs[0]));
    try testing.expect(!validBlobHash("../etc"));

    const set = (try roundTrip(arena, .{ .set = .{ .key = .title, .value = "\"hello\"" } })).set;
    try testing.expectEqual(SetKey.title, set.key);
    try testing.expectEqualStrings("\"hello\"", set.value);
    try testing.expectEqual(@as(usize, 0), set.blobs.len);
    const moved = (try roundTrip(arena, .{ .set = .{ .key = .moved_files, .value = "{}", .blobs = &.{&hash} } })).set;
    try testing.expectEqual(SetKey.moved_files, moved.key);
    try testing.expectEqualStrings(&hash, moved.blobs[0]);
    const records = (try roundTrip(arena, .{ .set = .{ .key = .compaction_records, .value = "{}", .blobs = &.{&hash} } })).set;
    try testing.expectEqual(SetKey.compaction_records, records.key);
    try testing.expectEqualStrings(&hash, records.blobs[0]);

    const compacted = (try roundTrip(arena, .{ .compacted = .{ .turn = null, .data = "{}" } })).compacted;
    try testing.expectEqual(@as(?u64, null), compacted.turn);

    const finished = (try roundTrip(arena, .{ .child_finished = .{
        .child = "c",
        .work_id = "w1",
        .outcome = .lost,
    } })).child_finished;
    try testing.expectEqual(Outcome.lost, finished.outcome);
    try testing.expectEqual(@as(?[]const u8, null), finished.data);

    const spawned = (try roundTrip(arena, .{ .child_spawned = .{
        .child = "c",
        .work_id = "w2",
        .data = "{\"name\":\"reviewer\"}",
    } })).child_spawned;
    try testing.expectEqualStrings("{\"name\":\"reviewer\"}", spawned.data.?);

    const cancelled = (try roundTrip(arena, .{ .child_finished = .{
        .child = "c",
        .work_id = "w2",
        .outcome = .cancelled,
        .data = "[1,2]",
    } })).child_finished;
    try testing.expectEqual(Outcome.cancelled, cancelled.outcome);
    try testing.expectEqualStrings("[1,2]", cancelled.data.?);

    const failed = (try roundTrip(arena, .{ .turn_interrupted = .{ .turn = 2, .reason = .failed } })).turn_interrupted;
    try testing.expectEqual(Reason.failed, failed.reason);

    const snap = (try roundTrip(arena, .{ .snapshot = .{
        .covers_seq = 12,
        .state = "{\"x\":1}",
        .compaction_offset = 400,
    } })).snapshot;
    try testing.expectEqualStrings("{\"x\":1}", snap.state);
    try testing.expectEqual(@as(?u64, 400), snap.compaction_offset);

    try testing.expectEqual(Body.closed, try roundTrip(arena, .closed));
}

test "a body missing a required field is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.BadBody, parseBody(arena, .item, ",\"turn\":1"));
    try testing.expectError(error.BadBody, parseBody(arena, .set, ",\"key\":\"nope\",\"value\":1"));
    try testing.expectError(error.BadBody, parseBody(arena, .turn_started, "\"turn\":1"));
}

test "control characters are escaped as JSON" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendJsonString(testing.allocator, &out, "a\x01\"\\b");
    try testing.expectEqualStrings("\"a\\u0001\\\"\\\\b\"", out.items);
}

test "ids follow v1's alphabet and avoid the reserved names" {
    try testing.expect(validId("_-UIdxIkuoLH"));
    try testing.expect(validId("1786460757753-1786460757753277000-ef75d8fd94fdab1"));
    for ([_][]const u8{ "", ".", "..", ".tmp", ".trash", "index.jsonl", "index.lock", "a/b", "a b" }) |id| {
        try testing.expect(!validId(id));
    }
    var id: [new_id_len]u8 = undefined;
    newId(testing.io, &id);
    try testing.expect(validId(&id));
}

test "header parsing never panics on arbitrary bytes" {
    try testing.fuzz({}, fuzzHeader, .{ .corpus = &.{
        "{\"v\":1,\"seq\":1,\"ts\":0,\"kind\":\"item\"",
        "{\"v\":99999999999,\"seq\":1",
    } });
}

fn fuzzHeader(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [256]u8 = undefined;
    const len = smith.slice(&buffer);
    const bytes = buffer[0..len];
    if (parseHeader(bytes)) |h| {
        try testing.expect(h.len <= bytes.len);
        try testing.expect(h.seq >= 1 and h.v >= 1);
    } else |_| {}
}

test "Fields fast paths decode exactly what the full parse decodes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const E = enum { app, ask };
    const Cases = struct {
        fn check(comptime T: type, a: std.mem.Allocator, raw: []const u8) !void {
            const full: ?T = std.json.parseFromSliceLeaky(T, a, raw, .{}) catch null;
            const fast = fastValue(T, raw);
            if (fast) |got| {
                const want = full orelse return error.FastAcceptedInvalid;
                if (T == []const u8) try std.testing.expectEqualStrings(want, got) else try std.testing.expectEqual(want, got);
            }
        }
    };
    for ([_][]const u8{ "0", "7", "18446744073709551615", "18446744073709551616", "01", "-1", "1.5", "1e3", "" }) |raw| try Cases.check(u64, arena, raw);
    for ([_][]const u8{ "true", "false", "null", "1" }) |raw| try Cases.check(bool, arena, raw);
    for ([_][]const u8{ "\"app\"", "\"ask\"", "\"sdk\"", "\"a\\u0070p\"", "3" }) |raw| try Cases.check(E, arena, raw);
    for ([_][]const u8{ "\"plain\"", "\"\"", "\"with \\\"quote\\\" inside\"", "\"tab\\t\"", "\"caf\u{e9}\"" }) |raw| try Cases.check([]const u8, arena, raw);
    // Every fast answer above was checked; these must take the fast path.
    try std.testing.expectEqual(@as(?u64, 42), fastValue(u64, "42"));
    try std.testing.expectEqualStrings("plain", fastValue([]const u8, "\"plain\"").?);
    try std.testing.expect(fastValue([]const u8, "\"a\\nb\"") == null);
}

test "validItemType: short lowercase names only" {
    for ([_][]const u8{ "user", "assistant", "tool_call", "tool_result", "steering", "a", "v2", "x" ** 32 }) |name| {
        try testing.expect(validItemType(name));
    }
    for ([_][]const u8{ "", "x" ** 33, "Steering", "tool-call", "tool call", "caf\u{e9}", "a/b", "\"q\"" }) |name| {
        try testing.expect(!validItemType(name));
    }
}

test "an item line without a type is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.BadBody, parseBody(arena_state.allocator(), .item, ",\"turn\":1,\"data\":{}"));
}
