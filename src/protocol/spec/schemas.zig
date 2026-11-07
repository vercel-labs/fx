//! Tests for the files of the `sh.fx` specification in this folder. The copy of ACP's version 1
//! schema in `acp/v1/` must match agent-client-protocol commit `7ec5185c18ca` byte for byte, and
//! every schema file must parse as a JSON object. `sh-fx.schema.json` must use the JSON Schema
//! draft of ACP's schema and state the naming rules of `sh-fx.md`, and the names and JSON
//! examples in `sh-fx.md` must follow those rules and parse. `README.md` in this folder says how
//! to move the ACP copy to a newer commit.

const std = @import("std");

const SpecFile = struct {
    path: []const u8,
    bytes: []const u8,
};

fn specFile(comptime path: []const u8) SpecFile {
    return .{ .path = path, .bytes = @embedFile(path) };
}

const acp_license = specFile("acp/v1/LICENSE");
const acp_meta = specFile("acp/v1/meta.json");
const acp_meta_unstable = specFile("acp/v1/meta.unstable.json");
const acp_schema = specFile("acp/v1/schema.json");
const acp_schema_unstable = specFile("acp/v1/schema.unstable.json");
const fx_schema = specFile("sh-fx.schema.json");
const fx_spec = specFile("sh-fx.md");

const PinnedFile = struct {
    file: SpecFile,
    /// The lowercase hex SHA-256 of the file at the pinned ACP commit.
    sha256: *const [64]u8,
};

const pinned_files = [_]PinnedFile{
    .{
        .file = acp_license,
        .sha256 = "f250d08cee4549b22b3b4aaaf3a743473336fd280316df5d0340717e5127a221",
    },
    .{
        .file = acp_meta,
        .sha256 = "061edb6efa8fb2aa2792459a86ec7268de5fe665bba48b2ffe7939df01481f88",
    },
    .{
        .file = acp_meta_unstable,
        .sha256 = "dc99f7006087ad5d32e40c019326854b379eaa95963a6497c366f2a371966f0d",
    },
    .{
        .file = acp_schema,
        .sha256 = "e747a7bec3c02708b70885bf3cccac5c72fa421390dd7e85758fd61e33b1ae21",
    },
    .{
        .file = acp_schema_unstable,
        .sha256 = "cff9aa6f463eccfff38c0918fc57ada6efd1952a2b7868baba432b5dc8aaeb59",
    },
};

const json_files = [_]SpecFile{ acp_meta, acp_meta_unstable, acp_schema, acp_schema_unstable, fx_schema };

/// Returns the field `name` of `value`, or null when `value` is not an object or has no such field.
fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    const found = field(value, name) orelse return null;
    return if (found == .string) found.string else null;
}

/// Reports whether `values` is an object with `want` among its string values. ACP's `meta.json`
/// lists methods this way, keyed by a Rust identifier, such as `"session_prompt": "session/prompt"`.
fn hasStringValue(values: std.json.Value, want: []const u8) bool {
    if (values != .object) return false;
    for (values.object.values()) |value| {
        if (value == .string and std.mem.eql(u8, value.string, want)) return true;
    }
    return false;
}

/// The regular expressions that `sh-fx.schema.json` gives for sh.fx names. Zig has no regular
/// expression engine, so `isMethodName` and `isKeyName` check the same forms by hand.
const method_name_pattern = "^_sh\\.fx/[a-z][a-z0-9_]*(/[a-z][a-z0-9_]*)+$";
const key_name_pattern = "^sh\\.fx/[a-z][A-Za-z0-9]*$";

/// Reports whether `name` is `_sh.fx/` followed by two or more snake_case segments.
fn isMethodName(name: []const u8) bool {
    const rest = std.mem.cutPrefix(u8, name, "_sh.fx/") orelse return false;
    var segments = std.mem.splitScalar(u8, rest, '/');
    var count: usize = 0;
    while (segments.next()) |segment| : (count += 1) {
        if (segment.len == 0 or !std.ascii.isLower(segment[0])) return false;
        for (segment[1..]) |c| {
            if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_') return false;
        }
    }
    return count >= 2;
}

/// Reports whether `name` is `sh.fx/` followed by one camelCase segment, the form of capability
/// names and `_meta` keys.
fn isKeyName(name: []const u8) bool {
    const rest = std.mem.cutPrefix(u8, name, "sh.fx/") orelse return false;
    if (rest.len == 0 or !std.ascii.isLower(rest[0])) return false;
    for (rest[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c)) return false;
    }
    return true;
}

fn parseSpecFile(file: SpecFile) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, file.bytes, .{}) catch |err| {
        std.debug.print("{s} does not parse as JSON\n", .{file.path});
        return err;
    };
}

test "the ACP copy matches the files of the pinned commit" {
    for (pinned_files) |pinned| {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(pinned.file.bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        std.testing.expectEqualStrings(pinned.sha256, &hex) catch |err| {
            std.debug.print("{s} differs from the pinned ACP commit\n", .{pinned.file.path});
            return err;
        };
    }
}

test "every schema file parses as a JSON object" {
    for (json_files) |file| {
        const parsed = try parseSpecFile(file);
        defer parsed.deinit();
        if (parsed.value != .object) {
            std.debug.print("{s} is not a JSON object\n", .{file.path});
            return error.TestUnexpectedResult;
        }
    }
}

test "ACP's method lists are version 1 and the unstable list includes every stable method" {
    const stable = try parseSpecFile(acp_meta);
    defer stable.deinit();
    const unstable = try parseSpecFile(acp_meta_unstable);
    defer unstable.deinit();

    for ([_]std.json.Value{ stable.value, unstable.value }) |meta| {
        const version = field(meta, "version") orelse return error.TestUnexpectedResult;
        try std.testing.expect(version == .integer and version.integer == 1);
    }
    try std.testing.expect(hasStringValue(field(stable.value, "agentMethods") orelse .null, "session/prompt"));
    try std.testing.expect(hasStringValue(field(stable.value, "clientMethods") orelse .null, "session/update"));

    for ([_][]const u8{ "agentMethods", "clientMethods", "protocolMethods" }) |list| {
        const stable_list = field(stable.value, list) orelse return error.TestUnexpectedResult;
        const unstable_list = field(unstable.value, list) orelse return error.TestUnexpectedResult;
        try std.testing.expect(stable_list == .object);
        for (stable_list.object.values()) |method| {
            try std.testing.expect(method == .string);
            if (!hasStringValue(unstable_list, method.string)) {
                std.debug.print("{s} is stable but missing from the unstable {s}\n", .{ method.string, list });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "the unstable ACP schema includes every stable type" {
    const stable = try parseSpecFile(acp_schema);
    defer stable.deinit();
    const unstable = try parseSpecFile(acp_schema_unstable);
    defer unstable.deinit();

    const stable_defs = field(stable.value, "$defs") orelse return error.TestUnexpectedResult;
    const unstable_defs = field(unstable.value, "$defs") orelse return error.TestUnexpectedResult;
    try std.testing.expect(stable_defs == .object and unstable_defs == .object);
    try std.testing.expect(stable_defs.object.count() > 0);
    for (stable_defs.object.keys()) |name| {
        if (!unstable_defs.object.contains(name)) {
            std.debug.print("{s} is a stable type but missing from the unstable schema\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}

test "sh-fx.schema.json uses the JSON Schema draft of ACP's schema" {
    const acp = try parseSpecFile(acp_schema);
    defer acp.deinit();
    const fx = try parseSpecFile(fx_schema);
    defer fx.deinit();

    const acp_draft = stringField(acp.value, "$schema") orelse return error.TestUnexpectedResult;
    const fx_draft = stringField(fx.value, "$schema") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(acp_draft, fx_draft);

    const fx_defs = field(fx.value, "$defs") orelse return error.TestUnexpectedResult;
    try std.testing.expect(fx_defs == .object);
}

test "the sh.fx name checks accept the documented forms and reject others" {
    for ([_][]const u8{
        "_sh.fx/session/steer",
        "_sh.fx/session/follow_up",
        "_sh.fx/session/steer2",
        "_sh.fx/journal/append",
    }) |name| try std.testing.expect(isMethodName(name));
    for ([_][]const u8{
        "_sh.fx/steer",
        "sh.fx/session/steer",
        "_sh.fx/Session/steer",
        "_sh.fx/session/followUp",
        "_sh.fx/session/",
        "_sh.fx//steer",
        "_sh.fx/session/steer/",
        "_sh.fx/session/2steer",
    }) |name| try std.testing.expect(!isMethodName(name));

    for ([_][]const u8{ "sh.fx/steering", "sh.fx/journalSeq", "sh.fx/steering2" }) |name| {
        try std.testing.expect(isKeyName(name));
    }
    for ([_][]const u8{
        "sh.fx/journal_seq",
        "sh.fx/JournalSeq",
        "_sh.fx/steering",
        "sh.fx/",
        "sh.fx/a/b",
        "fx/steering",
        "sh.fx/2steering",
    }) |name| try std.testing.expect(!isKeyName(name));
}

test "sh-fx.schema.json gives the name patterns that the name checks implement" {
    const parsed = try parseSpecFile(fx_schema);
    defer parsed.deinit();
    const defs = field(parsed.value, "$defs") orelse return error.TestUnexpectedResult;

    for ([_]struct { type_name: []const u8, pattern: []const u8 }{
        .{ .type_name = "MethodName", .pattern = method_name_pattern },
        .{ .type_name = "CapabilityName", .pattern = key_name_pattern },
        .{ .type_name = "MetaKey", .pattern = key_name_pattern },
    }) |expected| {
        const def = field(defs, expected.type_name) orelse {
            std.debug.print("sh-fx.schema.json has no {s} type\n", .{expected.type_name});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqualStrings("string", stringField(def, "type") orelse "");
        try std.testing.expectEqualStrings(expected.pattern, stringField(def, "pattern") orelse "");
    }
}

/// Returns the type in `defs` that a local reference such as `#/$defs/Capability` names, or null.
fn localDef(defs: std.json.Value, ref: []const u8) ?std.json.Value {
    const name = std.mem.cutPrefix(u8, ref, "#/$defs/") orelse return null;
    return field(defs, name);
}

test "every capability in sh-fx.schema.json has an sh.fx name and an object value" {
    const parsed = try parseSpecFile(fx_schema);
    defer parsed.deinit();
    const defs = field(parsed.value, "$defs") orelse return error.TestUnexpectedResult;

    for ([_][]const u8{ "AgentCapabilitiesMeta", "ClientCapabilitiesMeta" }) |type_name| {
        const def = field(defs, type_name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("object", stringField(def, "type") orelse "");
        const properties = field(def, "properties") orelse return error.TestUnexpectedResult;
        try std.testing.expect(properties == .object);
        for (properties.object.keys(), properties.object.values()) |name, value| {
            if (!isKeyName(name)) {
                std.debug.print("{s} lists {s}, which is not an sh.fx capability name\n", .{ type_name, name });
                return error.TestUnexpectedResult;
            }
            const ref = stringField(value, "$ref") orelse "";
            const target = localDef(defs, ref) orelse {
                std.debug.print("{s} gives {s} the unknown type \"{s}\"\n", .{ type_name, name, ref });
                return error.TestUnexpectedResult;
            };
            try std.testing.expectEqualStrings("object", stringField(target, "type") orelse "");
        }
    }
    const capability = field(defs, "Capability") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("object", stringField(capability, "type") orelse "");
}

/// Checks that each `$ref` under `value` names a type of sh-fx.schema.json or of ACP's schema, and
/// counts the references in `refs`.
fn checkRefs(
    value: std.json.Value,
    fx_defs: std.json.Value,
    acp_defs: std.json.Value,
    refs: *usize,
) error{TestUnexpectedResult}!void {
    switch (value) {
        .object => |object| for (object.keys(), object.values()) |key, child| {
            if (!std.mem.eql(u8, key, "$ref")) {
                try checkRefs(child, fx_defs, acp_defs, refs);
                continue;
            }
            const ref = if (child == .string) child.string else "";
            const found = if (std.mem.cutPrefix(u8, ref, "acp/v1/schema.json#/$defs/")) |name|
                field(acp_defs, name)
            else
                localDef(fx_defs, ref);
            if (found == null) {
                std.debug.print("sh-fx.schema.json refers to \"{s}\", which names no type\n", .{ref});
                return error.TestUnexpectedResult;
            }
            refs.* += 1;
        },
        .array => |array| for (array.items) |child| try checkRefs(child, fx_defs, acp_defs, refs),
        else => {},
    }
}

test "every $ref in sh-fx.schema.json names a type that exists" {
    const fx = try parseSpecFile(fx_schema);
    defer fx.deinit();
    const acp = try parseSpecFile(acp_schema);
    defer acp.deinit();
    const fx_defs = field(fx.value, "$defs") orelse return error.TestUnexpectedResult;
    const acp_defs = field(acp.value, "$defs") orelse return error.TestUnexpectedResult;
    var refs: usize = 0;
    try checkRefs(fx.value, fx_defs, acp_defs, &refs);
    try std.testing.expect(refs > 0);
}

test "every JSON example in sh-fx.md parses as a JSON object" {
    const fence = "```json\n";
    var examples: usize = 0;
    var rest = fx_spec.bytes;
    while (std.mem.find(u8, rest, fence)) |start| {
        const body = rest[start + fence.len ..];
        const end = std.mem.find(u8, body, "\n```") orelse {
            std.debug.print("sh-fx.md has a JSON example that never closes\n", .{});
            return error.TestUnexpectedResult;
        };
        examples += 1;
        const parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, body[0..end], .{}) catch |err| {
            std.debug.print("JSON example {d} in sh-fx.md does not parse\n", .{examples});
            return err;
        };
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        rest = body[end..];
    }
    try std.testing.expect(examples > 0);
}

/// Returns the text of the `## ` section of `doc` titled `title`, up to the next `## ` heading.
fn section(doc: []const u8, comptime title: []const u8) ?[]const u8 {
    const heading = "\n## " ++ title ++ "\n";
    const start = (std.mem.find(u8, doc, heading) orelse return null) + heading.len;
    const end = if (std.mem.find(u8, doc[start..], "\n## ")) |offset| start + offset else doc.len;
    return doc[start..end];
}

/// Returns the text inside one pair of backticks that wraps all of `cell`, or null.
fn codeCell(cell: []const u8) ?[]const u8 {
    if (cell.len < 3 or cell[0] != '`' or cell[cell.len - 1] != '`') return null;
    const inner = cell[1 .. cell.len - 1];
    return if (std.mem.findScalar(u8, inner, '`') == null) inner else null;
}

test "the table of names in use today gives each name one valid new name" {
    const table = section(fx_spec.bytes, "Names in use today") orelse {
        std.debug.print("sh-fx.md has no \"Names in use today\" section\n", .{});
        return error.TestUnexpectedResult;
    };
    const meta = try parseSpecFile(acp_meta);
    defer meta.deinit();
    const agent_methods = field(meta.value, "agentMethods") orelse return error.TestUnexpectedResult;
    const client_methods = field(meta.value, "clientMethods") orelse return error.TestUnexpectedResult;

    var olds: [64][]const u8 = undefined;
    var news: [64][]const u8 = undefined;
    var rows: usize = 0;
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "|")) continue;
        if (std.mem.startsWith(u8, line, "| Today |") or std.mem.startsWith(u8, line, "| --- |")) continue;
        var cells: [6][]const u8 = undefined;
        var count: usize = 0;
        var parts = std.mem.splitScalar(u8, line, '|');
        while (parts.next()) |part| : (count += 1) {
            if (count == cells.len) break;
            cells[count] = std.mem.trim(u8, part, " ");
        }
        const old = if (count == cells.len) codeCell(cells[1]) else null;
        const new = if (count == cells.len) codeCell(cells[3]) else null;
        if (old == null or new == null or rows == olds.len) {
            std.debug.print("sh-fx.md has a malformed row in its names table: {s}\n", .{line});
            return error.TestUnexpectedResult;
        }
        try checkNameRow(old.?, new.?, cells[2], agent_methods, client_methods, olds[0..rows], news[0..rows]);
        olds[rows] = old.?;
        news[rows] = new.?;
        rows += 1;
    }
    try std.testing.expect(rows > 0);
}

/// Checks one row of the names table: a known direction, an old name that is not already an sh.fx
/// name, a new name that is an sh.fx method or a standard ACP method sent the same way, and names
/// that no earlier row used.
fn checkNameRow(
    old: []const u8,
    new: []const u8,
    direction: []const u8,
    agent_methods: std.json.Value,
    client_methods: std.json.Value,
    seen_olds: []const []const u8,
    seen_news: []const []const u8,
) !void {
    const to_fx = std.mem.cutPrefix(u8, direction, "client to fx, ");
    const kind = to_fx orelse std.mem.cutPrefix(u8, direction, "fx to client, ") orelse "";
    if (!std.mem.eql(u8, kind, "request") and !std.mem.eql(u8, kind, "notification")) {
        std.debug.print("{s} has the unknown direction \"{s}\"\n", .{ old, direction });
        return error.TestUnexpectedResult;
    }
    const standard = hasStringValue(if (to_fx != null) agent_methods else client_methods, new);
    if (isMethodName(old) or !(isMethodName(new) or standard)) {
        std.debug.print("{s} maps to {s}, which is not a valid new name\n", .{ old, new });
        return error.TestUnexpectedResult;
    }
    for (seen_olds, seen_news) |seen_old, seen_new| {
        if (std.mem.eql(u8, seen_old, old) or std.mem.eql(u8, seen_new, new)) {
            std.debug.print("{s} or {s} appears twice in the names table\n", .{ old, new });
            return error.TestUnexpectedResult;
        }
    }
}

const KeyKind = enum { meta_key, capability, removed };

fn keyKind(cell: []const u8) ?KeyKind {
    if (std.mem.eql(u8, cell, "`_meta` key")) return .meta_key;
    if (std.mem.eql(u8, cell, "capability")) return .capability;
    if (std.mem.eql(u8, cell, "removed")) return .removed;
    return null;
}

test "the table of keys in use today gives each key one valid new name" {
    const table = section(fx_spec.bytes, "Keys in use today") orelse {
        std.debug.print("sh-fx.md has no \"Keys in use today\" section\n", .{});
        return error.TestUnexpectedResult;
    };
    const Row = struct { today: []const u8, where: []const u8, new: []const u8, kind: KeyKind };
    var rows: [64]Row = undefined;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "|")) continue;
        if (std.mem.startsWith(u8, line, "| Today |") or std.mem.startsWith(u8, line, "| --- |")) continue;
        var cells: [7][]const u8 = undefined;
        var cell_count: usize = 0;
        var parts = std.mem.splitScalar(u8, line, '|');
        while (parts.next()) |part| : (cell_count += 1) {
            if (cell_count == cells.len) break;
            cells[cell_count] = std.mem.trim(u8, part, " ");
        }
        const today = if (cell_count == cells.len) codeCell(cells[1]) else null;
        const kind = if (cell_count == cells.len) keyKind(cells[4]) else null;
        if (today == null or kind == null or count == rows.len) {
            std.debug.print("sh-fx.md has a malformed row in its keys table: {s}\n", .{line});
            return error.TestUnexpectedResult;
        }
        const new: []const u8 = switch (kind.?) {
            .removed => if (std.mem.eql(u8, cells[3], "-")) "-" else {
                std.debug.print("{s} is removed but still names \"{s}\"\n", .{ today.?, cells[3] });
                return error.TestUnexpectedResult;
            },
            .meta_key, .capability => name: {
                const name = codeCell(cells[3]) orelse "";
                if (!isKeyName(name)) {
                    std.debug.print("{s} maps to \"{s}\", which is not an sh.fx key\n", .{ today.?, cells[3] });
                    return error.TestUnexpectedResult;
                }
                break :name name;
            },
        };
        for (rows[0..count]) |seen| {
            const same_place = std.mem.eql(u8, seen.today, today.?) and std.mem.eql(u8, seen.where, cells[2]);
            const same_name = kind.? != .removed and seen.kind == kind.? and std.mem.eql(u8, seen.new, new);
            if (same_place or same_name) {
                std.debug.print("{s} ({s}) repeats a row of the keys table\n", .{ today.?, cells[2] });
                return error.TestUnexpectedResult;
            }
        }
        rows[count] = .{ .today = today.?, .where = cells[2], .new = new, .kind = kind.? };
        count += 1;
    }
    try std.testing.expect(count > 0);
}

test "every sh.fx name in sh-fx.md follows the naming rules" {
    var names: usize = 0;
    var spans = std.mem.splitScalar(u8, fx_spec.bytes, '`');
    var inside = false;
    while (spans.next()) |span| : (inside = !inside) {
        if (!inside) continue;
        // Skip the bare prefixes and placeholder forms such as `sh.fx/<name>`.
        if (std.mem.endsWith(u8, span, "/") or std.mem.findScalar(u8, span, '<') != null) continue;
        const ok = if (std.mem.startsWith(u8, span, "_sh.fx/"))
            isMethodName(span)
        else if (std.mem.startsWith(u8, span, "sh.fx/"))
            isKeyName(span)
        else
            continue;
        names += 1;
        if (!ok) {
            std.debug.print("sh-fx.md names {s}, which breaks the naming rules\n", .{span});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(names > 0);
}

test "the Schema section lists each type of sh-fx.schema.json once" {
    const table = section(fx_spec.bytes, "Schema") orelse {
        std.debug.print("sh-fx.md has no \"Schema\" section\n", .{});
        return error.TestUnexpectedResult;
    };
    const parsed = try parseSpecFile(fx_schema);
    defer parsed.deinit();
    const defs = field(parsed.value, "$defs") orelse return error.TestUnexpectedResult;

    var listed: [64][]const u8 = undefined;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "| `")) continue;
        var parts = std.mem.splitScalar(u8, line, '|');
        _ = parts.next();
        const name = codeCell(std.mem.trim(u8, parts.next() orelse "", " ")) orelse "";
        if (field(defs, name) == null or count == listed.len) {
            std.debug.print("the Schema section lists \"{s}\", which sh-fx.schema.json doesn't define\n", .{name});
            return error.TestUnexpectedResult;
        }
        for (listed[0..count]) |seen| {
            if (std.mem.eql(u8, seen, name)) {
                std.debug.print("the Schema section lists {s} twice\n", .{name});
                return error.TestUnexpectedResult;
            }
        }
        listed[count] = name;
        count += 1;
    }
    if (count != defs.object.count()) {
        std.debug.print("the Schema section lists {d} of the {d} types in sh-fx.schema.json\n", .{ count, defs.object.count() });
        return error.TestUnexpectedResult;
    }
}

/// Returns the quoted values in the first column of the table in `doc` whose header row starts
/// with `header`, without their backticks and quotes.
fn tableValues(doc: []const u8, comptime header: []const u8, out: [][]const u8) ![]const []const u8 {
    const start = std.mem.find(u8, doc, "\n" ++ header) orelse {
        std.debug.print("sh-fx.md has no table that starts with {s}\n", .{header});
        return error.TestUnexpectedResult;
    };
    var lines = std.mem.splitScalar(u8, doc[start + 1 ..], '\n');
    _ = lines.next(); // The header row.
    _ = lines.next(); // The `| --- |` row.
    var count: usize = 0;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "|")) break;
        var parts = std.mem.splitScalar(u8, line, '|');
        _ = parts.next();
        const cell = codeCell(std.mem.trim(u8, parts.next() orelse "", " ")) orelse "";
        if (cell.len < 3 or cell[0] != '"' or cell[cell.len - 1] != '"' or count == out.len) {
            std.debug.print("the table under {s} has a malformed row: {s}\n", .{ header, line });
            return error.TestUnexpectedResult;
        }
        out[count] = cell[1 .. cell.len - 1];
        count += 1;
    }
    return out[0..count];
}

test "the value tables in sh-fx.md give the values of the schema's enums" {
    const parsed = try parseSpecFile(fx_schema);
    defer parsed.deinit();
    const defs = field(parsed.value, "$defs") orelse return error.TestUnexpectedResult;
    const tables = .{
        .{ "| `sh.fx/delivery` |", "PromptDelivery" },
        .{ "| `sh.fx/steeringDelivery` |", "SteeringDelivery" },
        .{ "| `sh.fx/replay` |", "Replay" },
        .{ "| `sh.fx/state` |", "SessionState" },
    };
    inline for (tables) |table| {
        var buffer: [16][]const u8 = undefined;
        const values = try tableValues(fx_spec.bytes, table[0], &buffer);
        const def = field(defs, table[1]) orelse return error.TestUnexpectedResult;
        const want = field(def, "enum") orelse return error.TestUnexpectedResult;
        try std.testing.expect(want == .array);
        if (want.array.items.len != values.len) {
            std.debug.print("the table under {s} gives {d} values, and {s} has {d}\n", .{ table[0], values.len, table[1], want.array.items.len });
            return error.TestUnexpectedResult;
        }
        for (want.array.items, values) |value, got| {
            try std.testing.expect(value == .string);
            try std.testing.expectEqualStrings(value.string, got);
        }
    }
}
