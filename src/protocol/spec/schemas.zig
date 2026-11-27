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
const method_name_pattern = "^_sh\\.fx/[a-z][a-z0-9_]*/[a-z][a-z0-9_]*$";
const key_name_pattern = "^sh\\.fx/[a-z][A-Za-z0-9]*$";

/// Reports whether `name` is `_sh.fx/` followed by an `<area>/<action>` pair of snake_case segments.
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
    return count == 2;
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

test "isMethodName accepts the documented method names and rejects others" {
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
        "_sh.fx/a/b/c",
    }) |name| try std.testing.expect(!isMethodName(name));
}

test "isKeyName accepts the documented key names and rejects others" {
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

test "the name patterns in sh-fx.schema.json equal this file's pattern constants" {
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

/// Checks one entry of a capability map: a `$ref` to the `Capability` type.
fn expectCapabilityValue(value: std.json.Value) !void {
    try std.testing.expect(value == .object);
    try std.testing.expectEqualStrings("#/$defs/Capability", stringField(value, "$ref") orelse "");
}

test "the capability maps in sh-fx.schema.json check sh.fx keys and leave other keys open" {
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
            try expectCapabilityValue(value);
        }

        const property_names = field(def, "propertyNames") orelse return error.TestUnexpectedResult;
        const if_pattern = stringField(field(property_names, "if") orelse .null, "pattern") orelse "";
        const then_pattern = stringField(field(property_names, "then") orelse .null, "pattern") orelse "";
        try std.testing.expectEqualStrings("^sh\\.fx/", if_pattern);
        try std.testing.expectEqualStrings(key_name_pattern, then_pattern);

        const pattern_properties = field(def, "patternProperties") orelse return error.TestUnexpectedResult;
        try std.testing.expect(pattern_properties == .object and pattern_properties.object.count() == 1);
        try std.testing.expectEqualStrings("^sh\\.fx/", pattern_properties.object.keys()[0]);
        try expectCapabilityValue(pattern_properties.object.values()[0]);
    }
    const capability = field(defs, "Capability") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("object", stringField(capability, "type") orelse "");
}

/// Fails on the first key of a `_meta` object under `value` that is not an sh.fx key name.
fn expectMetaKeyNames(value: std.json.Value) !void {
    switch (value) {
        .object => |object| {
            for (object.keys(), object.values()) |key, child| {
                if (std.mem.eql(u8, key, "_meta")) try expectMetaObjectKeys(child);
                try expectMetaKeyNames(child);
            }
        },
        .array => |array| for (array.items) |child| try expectMetaKeyNames(child),
        else => {},
    }
}

fn expectMetaObjectKeys(meta: std.json.Value) !void {
    if (meta != .object) {
        std.debug.print("sh-fx.md has a _meta value that is not a JSON object\n", .{});
        return error.TestUnexpectedResult;
    }
    for (meta.object.keys()) |key| {
        if (!isKeyName(key)) {
            std.debug.print("sh-fx.md has the _meta key {s}, which is not an sh.fx key name\n", .{key});
            return error.TestUnexpectedResult;
        }
    }
}

test "every JSON example in sh-fx.md parses as a JSON object with sh.fx _meta keys" {
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
        try expectMetaKeyNames(parsed.value);
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

/// The most rows the names table in sh-fx.md may have. The test keeps them in fixed arrays.
const max_names_table_rows: usize = 64;

/// The cells in each row of the names table, not counting the empty text outside its bars.
const names_table_cells: usize = 4;

/// The most rows the keys table in sh-fx.md may have. The test keeps them in fixed arrays.
const max_keys_table_rows: usize = 64;

/// The cells in each row of the keys table, not counting the empty text outside its bars.
const keys_table_cells: usize = 5;

/// One row of a table in sh-fx.md: its whole line, for an error message, and its trimmed cells.
fn TableRow(comptime cells_per_row: usize) type {
    return struct {
        line: []const u8,
        cells: [cells_per_row][]const u8,
    };
}

/// Returns the trimmed cells of one table row, or null unless the line has an opening bar, a closing
/// bar, exactly `cells_per_row` cells between them, and no empty cell.
fn tableRowCells(comptime cells_per_row: usize, line: []const u8) ?[cells_per_row][]const u8 {
    var parts = std.mem.splitScalar(u8, line, '|');
    const opening = parts.next() orelse return null;
    if (std.mem.trim(u8, opening, " ").len != 0) return null;
    var cells: [cells_per_row][]const u8 = undefined;
    for (&cells) |*cell| {
        const part = parts.next() orelse return null;
        cell.* = std.mem.trim(u8, part, " ");
        if (cell.*.len == 0) return null;
    }
    const closing = parts.next() orelse return null;
    if (std.mem.trim(u8, closing, " ").len != 0) return null;
    if (parts.next() != null) return null;
    return cells;
}

/// What a table check got wrong. For `error.MalformedTableRow`, `line` is the row, so the test that
/// calls the check can show it. The checks print nothing themselves.
const TableFailure = struct {
    line: []const u8 = "",
};

/// Splits the rows of a table in sh-fx.md into cells and returns how many rows it has. A line with no
/// bar is text and is skipped, and so are the header and the separator line. Any other line is a row,
/// so a row without an outer bar is checked and not skipped.
fn splitTable(
    comptime cells_per_row: usize,
    table: []const u8,
    rows: []TableRow(cells_per_row),
    failure: *TableFailure,
) !usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        if (std.mem.findScalar(u8, line, '|') == null) continue;
        if (std.mem.startsWith(u8, line, "| Today |") or std.mem.startsWith(u8, line, "| --- |")) continue;
        if (count == rows.len) return error.TableTooLong;
        const cells = tableRowCells(cells_per_row, line) orelse {
            failure.line = line;
            return error.MalformedTableRow;
        };
        rows[count] = .{ .line = line, .cells = cells };
        count += 1;
    }
    if (count == 0) return error.TableHasNoRows;
    return count;
}

/// Checks every row of the names table and returns how many rows it has.
fn checkNamesTable(
    table: []const u8,
    agent_methods: std.json.Value,
    client_methods: std.json.Value,
    failure: *TableFailure,
) !usize {
    var rows: [max_names_table_rows]TableRow(names_table_cells) = undefined;
    const count = try splitTable(names_table_cells, table, &rows, failure);
    var olds: [max_names_table_rows][]const u8 = undefined;
    var news: [max_names_table_rows][]const u8 = undefined;
    for (rows[0..count], 0..) |row, index| {
        const old = codeCell(row.cells[0]);
        const new = codeCell(row.cells[2]);
        if (old == null or new == null) {
            failure.line = row.line;
            return error.MalformedTableRow;
        }
        try checkNameRow(old.?, new.?, row.cells[1], agent_methods, client_methods, olds[0..index], news[0..index]);
        olds[index] = old.?;
        news[index] = new.?;
    }
    return count;
}

/// Checks a names table against the method lists in ACP's `meta.json` and returns its row count.
fn checkNamesTableAgainstAcp(table: []const u8, failure: *TableFailure) !usize {
    const meta = try parseSpecFile(acp_meta);
    defer meta.deinit();
    const agent_methods = field(meta.value, "agentMethods") orelse return error.TestUnexpectedResult;
    const client_methods = field(meta.value, "clientMethods") orelse return error.TestUnexpectedResult;
    return checkNamesTable(table, agent_methods, client_methods, failure);
}

/// Expects `checkNamesTableAgainstAcp` to fail with `expected` on `table`.
fn expectNamesTableError(expected: anyerror, table: []const u8) !void {
    var failure: TableFailure = .{};
    try std.testing.expectError(expected, checkNamesTableAgainstAcp(table, &failure));
}

/// Prints why a table check failed. The test that calls the check prints it, because the checks print
/// nothing themselves. `max_rows` is the row cap of the table.
fn printTableFailure(name: []const u8, max_rows: usize, err: anyerror, failure: TableFailure) void {
    switch (err) {
        error.MalformedTableRow => std.debug.print("sh-fx.md has a malformed row in its {s}: {s}\n", .{ name, failure.line }),
        error.TableTooLong => std.debug.print("sh-fx.md {s} has more than {d} rows, which is more than this test holds\n", .{ name, max_rows }),
        error.TableHasNoRows => std.debug.print("sh-fx.md {s} has no rows\n", .{name}),
        error.RemovedKeyNamesNewName, error.NotAnShFxKey, error.RepeatedKeyRow => std.debug.print("sh-fx.md {s} row fails {s}: {s}\n", .{ name, @errorName(err), failure.line }),
        else => {},
    }
}

/// Returns a names table of `count` rows, each with its own names, for the row cap.
fn namesTableWithRows(comptime count: usize) []const u8 {
    @setEvalBranchQuota(100_000);
    var table: []const u8 = "";
    for (0..count) |index| {
        table = table ++ std.fmt.comptimePrint(
            "| `libfx/op{d}` | client to fx, request | `_sh.fx/session/op{d}` | Does one thing |\n",
            .{ index, index },
        );
    }
    return table;
}

test "the table of names in use today gives each name one valid new name" {
    const table = section(fx_spec.bytes, "Names in use today") orelse {
        std.debug.print("sh-fx.md has no \"Names in use today\" section\n", .{});
        return error.TestUnexpectedResult;
    };
    var failure: TableFailure = .{};
    _ = checkNamesTableAgainstAcp(table, &failure) catch |err| {
        printTableFailure("names table", max_names_table_rows, err, failure);
        return err;
    };
}

test "a names table row has both outer bars and exactly four cells" {
    try std.testing.expect(tableRowCells(names_table_cells, "| `libfx/steer` | client to fx, request | `_sh.fx/session/steer` | Adds text |") != null);
    for ([_][]const u8{
        "| `libfx/steer` | client to fx, request | `_sh.fx/session/steer` | Adds text | extra",
        "| `libfx/steer` | client to fx, request | `_sh.fx/session/steer` | Adds | text",
        "`libfx/steer` | client to fx, request | `_sh.fx/session/steer` | Adds text |",
    }) |line| try std.testing.expect(tableRowCells(names_table_cells, line) == null);
}

test "a names table rejects a row without an opening bar" {
    try expectNamesTableError(error.MalformedTableRow, "`libfx/steer` | client to fx, request | `_sh.fx/session/steer` | Adds text |");
}

test "a names table rejects a row without a closing bar" {
    try expectNamesTableError(error.MalformedTableRow, "| `libfx/steer` | client to fx, request | `_sh.fx/session/steer` | Adds text");
}

test "a names table rejects a row with an extra cell" {
    try expectNamesTableError(error.MalformedTableRow, "| `libfx/steer` | client to fx, request | `_sh.fx/session/steer` | Adds text | extra |");
}

test "a names table rejects a row with an empty cell" {
    try expectNamesTableError(error.MalformedTableRow, "| `libfx/steer` | client to fx, request |  | Adds text |");
}

test "a names table with no rows fails" {
    try expectNamesTableError(error.TableHasNoRows, "");
}

test "a names table rejects a repeated name" {
    try expectNamesTableError(error.TestUnexpectedResult,
        \\| `libfx/steer` | client to fx, request | `_sh.fx/session/steer` | Adds text |
        \\| `libfx/steer` | client to fx, request | `_sh.fx/session/other` | Adds text |
        \\
    );
}

test "a names table rejects an unknown direction" {
    try expectNamesTableError(error.TestUnexpectedResult, "| `libfx/steer` | client to server, request | `_sh.fx/session/steer` | Adds text |");
}

test "a names table of exactly the row cap passes and one more row fails" {
    var failure: TableFailure = .{};
    const rows = try checkNamesTableAgainstAcp(comptime namesTableWithRows(max_names_table_rows), &failure);
    try std.testing.expectEqual(max_names_table_rows, rows);
    try expectNamesTableError(error.TableTooLong, comptime namesTableWithRows(max_names_table_rows + 1));
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

/// Checks every row of the keys table and returns how many rows it has.
fn checkKeysTable(table: []const u8, failure: *TableFailure) !usize {
    var rows: [max_keys_table_rows]TableRow(keys_table_cells) = undefined;
    const count = try splitTable(keys_table_cells, table, &rows, failure);
    const Seen = struct { today: []const u8, where: []const u8, new: []const u8, kind: KeyKind };
    var seen: [max_keys_table_rows]Seen = undefined;
    for (rows[0..count], 0..) |row, index| {
        const cells = row.cells;
        const today = codeCell(cells[0]);
        const kind = keyKind(cells[3]);
        if (today == null or kind == null) {
            failure.line = row.line;
            return error.MalformedTableRow;
        }
        const new: []const u8 = switch (kind.?) {
            .removed => if (std.mem.eql(u8, cells[2], "-")) "-" else {
                failure.line = row.line;
                return error.RemovedKeyNamesNewName;
            },
            .meta_key, .capability => name: {
                const name = codeCell(cells[2]) orelse "";
                if (!isKeyName(name)) {
                    failure.line = row.line;
                    return error.NotAnShFxKey;
                }
                break :name name;
            },
        };
        for (seen[0..index]) |earlier| {
            const same_place = std.mem.eql(u8, earlier.today, today.?) and std.mem.eql(u8, earlier.where, cells[1]);
            const same_name = kind.? != .removed and earlier.kind == kind.? and std.mem.eql(u8, earlier.new, new);
            if (same_place or same_name) {
                failure.line = row.line;
                return error.RepeatedKeyRow;
            }
        }
        seen[index] = .{ .today = today.?, .where = cells[1], .new = new, .kind = kind.? };
    }
    return count;
}

/// Expects `checkKeysTable` to fail with `expected` on `table`.
fn expectKeysTableError(expected: anyerror, table: []const u8) !void {
    var failure: TableFailure = .{};
    try std.testing.expectError(expected, checkKeysTable(table, &failure));
}

/// Returns a keys table of `count` rows, each with its own names, for the row cap.
fn keysTableWithRows(comptime count: usize) []const u8 {
    @setEvalBranchQuota(100_000);
    var table: []const u8 = "";
    for (0..count) |index| {
        table = table ++ std.fmt.comptimePrint(
            "| `_meta.fx.op{d}` | `session/new` params | `sh.fx/op{d}` | `_meta` key | Does one thing |\n",
            .{ index, index },
        );
    }
    return table;
}

test "the table of keys in use today gives each key one valid new name" {
    const table = section(fx_spec.bytes, "Keys in use today") orelse {
        std.debug.print("sh-fx.md has no \"Keys in use today\" section\n", .{});
        return error.TestUnexpectedResult;
    };
    var failure: TableFailure = .{};
    _ = checkKeysTable(table, &failure) catch |err| {
        printTableFailure("keys table", max_keys_table_rows, err, failure);
        return err;
    };
}

test "a keys table of exactly the row cap passes and one more row fails" {
    var failure: TableFailure = .{};
    const rows = try checkKeysTable(comptime keysTableWithRows(max_keys_table_rows), &failure);
    try std.testing.expectEqual(max_keys_table_rows, rows);
    try expectKeysTableError(error.TableTooLong, comptime keysTableWithRows(max_keys_table_rows + 1));
}

test "a keys table rejects a row without an opening bar" {
    try expectKeysTableError(error.MalformedTableRow, "`_meta.fx.steer` | `session/prompt` params | `sh.fx/steer` | `_meta` key | Makes a prompt a steer |");
}

test "a keys table rejects a row without a closing bar" {
    try expectKeysTableError(error.MalformedTableRow, "| `_meta.fx.steer` | `session/prompt` params | `sh.fx/steer` | `_meta` key | Makes a prompt a steer");
}

test "a keys table rejects a row with an extra cell" {
    try expectKeysTableError(error.MalformedTableRow, "| `_meta.fx.steer` | `session/prompt` params | `sh.fx/steer` | `_meta` key | Makes a prompt a steer | extra |");
}

test "a keys table rejects a row with an empty cell" {
    try expectKeysTableError(error.MalformedTableRow, "| `_meta.fx.steer` | `session/prompt` params |  | `_meta` key | Makes a prompt a steer |");
}

test "a keys table with no rows fails" {
    try expectKeysTableError(error.TableHasNoRows, "");
    try expectKeysTableError(error.TableHasNoRows, "| Today | Where | New | Kind | What it carries |\n| --- | --- | --- | --- | --- |\n");
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
