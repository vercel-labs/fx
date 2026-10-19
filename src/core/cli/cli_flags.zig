//! The one parser for fx's command-line flags. It reads arguments against a
//! command's `OptionDoc` list, the same list the command's help is rendered
//! from, so a flag can't be accepted without being documented.
//!
//! The parser only recognizes flags and splits off their values. Each command
//! folds the matches in order, so when a flag repeats or conflicts with
//! another, the last one wins, and each command validates its own values.

const std = @import("std");
const command_specs = @import("../slash_commands/command_specs.zig");

const OptionDoc = command_specs.OptionDoc;

/// The flag an option's help text starts with: `--model` in `--model <id>`.
pub fn flagName(doc: OptionDoc) []const u8 {
    const end = std.mem.findScalar(u8, doc.flag, ' ') orelse doc.flag.len;
    return doc.flag[0..end];
}

/// Whether the option takes a value, which its help text names after the flag.
pub fn takesValue(doc: OptionDoc) bool {
    return std.mem.findScalar(u8, doc.flag, ' ') != null;
}

/// Maps each entry of `docs` to the field of `Id` with the same name, where
/// `--full-access` is `full_access`. The `--` entry and entries that document
/// a positional argument, such as `add PATH`, map to null. Compilation fails
/// when a flag has no field or a field has no flag.
pub fn idTable(comptime Id: type, comptime docs: []const OptionDoc) [docs.len]?Id {
    comptime {
        @setEvalBranchQuota(100_000);
        var table: [docs.len]?Id = undefined;
        var used: [@typeInfo(Id).@"enum".field_names.len]bool = @splat(false);
        for (docs, 0..) |doc, index| {
            const name = flagName(doc);
            if (std.mem.eql(u8, name, "--") or name[0] != '-') {
                table[index] = null;
                continue;
            }
            const id = std.meta.stringToEnum(Id, fieldName(name)) orelse
                @compileError("no " ++ @typeName(Id) ++ " field for " ++ name);
            table[index] = id;
            used[@backingInt(id)] = true;
        }
        for (@typeInfo(Id).@"enum".field_names, used) |field_name, is_used| {
            if (!is_used) @compileError("no option documents " ++ @typeName(Id) ++ "." ++ field_name);
        }
        const result = table;
        return result;
    }
}

fn fieldName(comptime name: []const u8) []const u8 {
    comptime {
        const bare = std.mem.trimStart(u8, name, "-");
        var buffer: [bare.len]u8 = undefined;
        for (bare, 0..) |char, index| buffer[index] = if (char == '-') '_' else char;
        const result = buffer;
        return &result;
    }
}

pub const Match = struct {
    /// Index into the docs the parser was given.
    index: usize,
    /// The option's value, when it takes one. Borrowed from the arguments.
    value: ?[]const u8 = null,
};

pub const Item = union(enum) {
    option: Match,
    /// An argument that isn't a flag, including everything after `--`.
    positional: []const u8,
};

/// Why an argument was rejected. Slices borrow from the arguments and docs.
pub const Failure = union(enum) {
    unknown: struct { flag: []const u8, suggestion: ?[]const u8 },
    missing_value: []const u8,
    unexpected_value: []const u8,
    removed: struct { flag: []const u8, replacement: []const u8 },

    /// Writes one line without a newline, such as
    /// `unknown flag --verbos (did you mean --verbose?)`.
    pub fn write(self: Failure, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .unknown => |unknown| {
                try writer.print("unknown flag {s}", .{unknown.flag});
                if (unknown.suggestion) |suggestion| try writer.print(" (did you mean {s}?)", .{suggestion});
            },
            .missing_value => |flag| try writer.print("{s} needs a value", .{flag}),
            .unexpected_value => |flag| try writer.print("{s} doesn't take a value", .{flag}),
            .removed => |removed| try writer.print("{s} was removed; {s}", .{ removed.flag, removed.replacement }),
        }
    }
};

pub const Parser = struct {
    docs: []const OptionDoc,
    args: []const [:0]const u8,
    index: usize = 0,
    options_ended: bool = false,
    /// Stop at the first positional argument, `--`, or unknown flag instead
    /// of failing, leaving `index` on it. The global flags before a command
    /// use this, because whatever follows them belongs to the command.
    prefix: bool = false,
    /// Return a single-dash word that names no option as a positional
    /// instead of failing. Session IDs are base64url and can start with `-`,
    /// so the commands that take one as an operand use this.
    dash_operands: bool = false,
    /// Set when `next` returns `error.InvalidFlag`.
    failure: ?Failure = null,

    pub fn init(docs: []const OptionDoc, args: []const [:0]const u8) Parser {
        return .{ .docs = docs, .args = args };
    }

    pub fn initDashOperands(docs: []const OptionDoc, args: []const [:0]const u8) Parser {
        return .{ .docs = docs, .args = args, .dash_operands = true };
    }

    pub fn initPrefix(docs: []const OptionDoc, args: []const [:0]const u8) Parser {
        return .{ .docs = docs, .args = args, .prefix = true };
    }

    /// Returns the next option or positional argument, or null at the end.
    /// A flag that takes a value reads `--flag=value` or the next argument,
    /// even when that argument starts with `-`.
    pub fn next(self: *Parser) error{InvalidFlag}!?Item {
        while (self.index < self.args.len) {
            const arg = self.args[self.index];
            const is_flag = arg.len >= 2 and arg[0] == '-' and !std.mem.eql(u8, arg, "--");
            if (self.prefix and (!is_flag or self.find(optionName(arg)) == null)) return null;
            self.index += 1;
            if (self.options_ended) return .{ .positional = arg };
            if (std.mem.eql(u8, arg, "--")) {
                self.options_ended = true;
                continue;
            }
            if (!is_flag) return .{ .positional = arg };
            if (self.dash_operands and arg[1] != '-' and self.find(arg) == null) return .{ .positional = arg };
            return try self.option(arg);
        }
        return null;
    }

    fn optionName(arg: []const u8) []const u8 {
        if (!std.mem.startsWith(u8, arg, "--")) return arg;
        const at = std.mem.findScalar(u8, arg, '=') orelse return arg;
        return arg[0..at];
    }

    fn option(self: *Parser, arg: []const u8) error{InvalidFlag}!Item {
        const name = optionName(arg);
        const inline_value = if (name.len < arg.len) arg[name.len + 1 ..] else null;
        const index = self.find(name) orelse
            return self.fail(.{ .unknown = .{ .flag = name, .suggestion = self.closest(name) } });
        const doc = self.docs[index];
        if (doc.replacement) |replacement|
            return self.fail(.{ .removed = .{ .flag = name, .replacement = replacement } });
        if (!takesValue(doc)) {
            if (inline_value != null) return self.fail(.{ .unexpected_value = name });
            return .{ .option = .{ .index = index } };
        }
        if (inline_value) |value| return .{ .option = .{ .index = index, .value = value } };
        if (self.index >= self.args.len) return self.fail(.{ .missing_value = name });
        const value = self.args[self.index];
        self.index += 1;
        return .{ .option = .{ .index = index, .value = value } };
    }

    fn find(self: *const Parser, name: []const u8) ?usize {
        for (self.docs, 0..) |doc, index| {
            const candidate = flagName(doc);
            if (!std.mem.eql(u8, candidate, "--") and std.mem.eql(u8, candidate, name)) return index;
        }
        return null;
    }

    /// The documented flag closest to `name` within two edits, if any.
    fn closest(self: *const Parser, name: []const u8) ?[]const u8 {
        var best: ?[]const u8 = null;
        var best_distance: usize = 3;
        for (self.docs) |doc| {
            // Never suggest a removed or a deprecated spelling.
            if (doc.replacement != null or doc.hidden) continue;
            const candidate = flagName(doc);
            if (std.mem.eql(u8, candidate, "--") or candidate[0] != '-') continue;
            const distance = editDistance(name, candidate) orelse continue;
            if (distance < best_distance) {
                best = candidate;
                best_distance = distance;
            }
        }
        return best;
    }

    fn fail(self: *Parser, failure: Failure) error{InvalidFlag} {
        self.failure = failure;
        return error.InvalidFlag;
    }
};

/// Why `args` fail to parse against `docs`, or null when they parse.
pub fn firstFailure(docs: []const OptionDoc, args: []const [:0]const u8) ?Failure {
    return failureOf(.init(docs, args));
}

/// The failure `start` would hit, for a parser set up in a non-default mode.
pub fn failureOf(start: Parser) ?Failure {
    var parser = start;
    while (parser.next() catch return parser.failure) |_| {}
    return null;
}

/// The whole numbers a flag takes when its placeholder names a range, such as
/// `--limit <1-100>`; null for any other placeholder.
pub fn valueRange(doc: OptionDoc) ?struct { min: u64, max: u64 } {
    const space = std.mem.findScalarLast(u8, doc.flag, ' ') orelse return null;
    const placeholder = doc.flag[space + 1 ..];
    if (placeholder.len < 5 or placeholder[0] != '<' or placeholder[placeholder.len - 1] != '>') return null;
    const range = placeholder[1 .. placeholder.len - 1];
    const dash = std.mem.findScalar(u8, range, '-') orelse return null;
    return .{
        .min = std.fmt.parseUnsigned(u64, range[0..dash], 10) catch return null,
        .max = std.fmt.parseUnsigned(u64, range[dash + 1 ..], 10) catch return null,
    };
}

/// Writes the first value outside its flag's range, as
/// `--limit takes a whole number from 1 to 100, not abc`. False when every
/// value fits, or when the arguments don't parse.
pub fn writeRangeFailure(w: *std.Io.Writer, start: Parser) std.Io.Writer.Error!bool {
    var parser = start;
    while (parser.next() catch return false) |item| switch (item) {
        .positional => {},
        .option => |match| {
            const doc = parser.docs[match.index];
            const range = valueRange(doc) orelse continue;
            const value = match.value orelse continue;
            const number = std.fmt.parseUnsigned(u64, value, 10) catch null;
            if (number) |n| if (n >= range.min and n <= range.max) continue;
            try w.print("{s} takes a whole number from {d} to {d}, not {s}", .{ flagName(doc), range.min, range.max, value });
            return true;
        },
    };
    return false;
}

/// Levenshtein distance for names up to 64 bytes; null for longer names.
pub fn editDistance(a: []const u8, b: []const u8) ?usize {
    const max = 64;
    if (a.len > max or b.len > max) return null;
    var previous: [max + 1]usize = undefined;
    var current: [max + 1]usize = undefined;
    for (0..b.len + 1) |column| previous[column] = column;
    for (a, 0..) |a_char, row| {
        current[0] = row + 1;
        for (b, 0..) |b_char, column| {
            const substitution = previous[column] + @intFromBool(a_char != b_char);
            current[column + 1] = @min(@min(previous[column + 1] + 1, current[column] + 1), substitution);
        }
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }
    return previous[b.len];
}

const test_docs = [_]OptionDoc{
    .{ .flag = "--model <id>", .description = "" },
    .{ .flag = "--fast", .description = "" },
    .{ .flag = "--no-fast", .description = "" },
    .{ .flag = "--verbose", .description = "" },
    .{ .flag = "--old <id>", .description = "", .replacement = "use --model <id>" },
    .{ .flag = "--", .description = "" },
};

fn collect(args: []const [:0]const u8, out: []Item) !usize {
    var parser = Parser.init(&test_docs, args);
    var count: usize = 0;
    while (try parser.next()) |item| : (count += 1) out[count] = item;
    return count;
}

fn expectFailure(args: []const [:0]const u8, expected: []const u8) !void {
    var parser = Parser.init(&test_docs, args);
    while (parser.next() catch {
        var buffer: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try parser.failure.?.write(&writer);
        return std.testing.expectEqualStrings(expected, writer.buffered());
    }) |_| {}
    return error.TestExpectedError;
}

test "options take spaced and inline values and the rest is positional" {
    var items: [8]Item = undefined;
    const count = try collect(&.{ "--model", "a", "--model=b", "hello", "--fast", "--", "--no-fast", "-x" }, &items);
    try std.testing.expectEqual(@as(usize, 6), count);
    try std.testing.expectEqualStrings("a", items[0].option.value.?);
    try std.testing.expectEqualStrings("b", items[1].option.value.?);
    try std.testing.expectEqualStrings("hello", items[2].positional);
    try std.testing.expectEqual(@as(usize, 1), items[3].option.index);
    try std.testing.expectEqualStrings("--no-fast", items[4].positional);
    try std.testing.expectEqualStrings("-x", items[5].positional);
}

test "a value may start with a dash" {
    var items: [2]Item = undefined;
    _ = try collect(&.{ "--model", "-weird" }, &items);
    try std.testing.expectEqualStrings("-weird", items[0].option.value.?);
}

test "dash-operand mode keeps a dash-leading operand but still checks long flags" {
    const docs = [_]OptionDoc{
        .{ .flag = "-h", .description = "" },
        .{ .flag = "--json", .description = "" },
    };
    var parser: Parser = .initDashOperands(&docs, &.{ "-_u88j00skyI", "-h", "--json" });
    try std.testing.expectEqualStrings("-_u88j00skyI", (try parser.next()).?.positional);
    try std.testing.expectEqual(@as(usize, 0), (try parser.next()).?.option.index);
    try std.testing.expectEqual(@as(usize, 1), (try parser.next()).?.option.index);
    try std.testing.expectEqual(@as(?Item, null), try parser.next());

    var typo: Parser = .initDashOperands(&docs, &.{"--jsno"});
    try std.testing.expectError(error.InvalidFlag, typo.next());
    try std.testing.expectEqualStrings("--jsno", typo.failure.?.unknown.flag);
}

test "bad flags fail with a message that names them" {
    try expectFailure(&.{"--verbos"}, "unknown flag --verbos (did you mean --verbose?)");
    try expectFailure(&.{"--zzzzzzzz"}, "unknown flag --zzzzzzzz");
    try expectFailure(&.{"-q"}, "unknown flag -q");
    try expectFailure(&.{"--model"}, "--model needs a value");
    try expectFailure(&.{"--fast=yes"}, "--fast doesn't take a value");
    try expectFailure(&.{ "--old", "x" }, "--old was removed; use --model <id>");
}

test "a removed flag is never suggested" {
    try expectFailure(&.{"--olf"}, "unknown flag --olf");
}

test "id tables follow flag names" {
    const Id = enum { model, fast, no_fast, verbose, old };
    const table = comptime idTable(Id, &test_docs);
    try std.testing.expectEqual(Id.model, table[0].?);
    try std.testing.expectEqual(Id.no_fast, table[2].?);
    try std.testing.expectEqual(@as(?Id, null), table[5]);
}

test "edit distance" {
    try std.testing.expectEqual(@as(?usize, 0), editDistance("abc", "abc"));
    try std.testing.expectEqual(@as(?usize, 1), editDistance("--verbos", "--verbose"));
    try std.testing.expectEqual(@as(?usize, 3), editDistance("kitten", "sitting"));
}

test "prefix mode stops at the first argument it does not own" {
    const docs = [_]OptionDoc{
        .{ .flag = "--model <id>", .description = "" },
        .{ .flag = "--fast", .description = "" },
    };
    const cases = [_]struct { args: []const [:0]const u8, stop: usize }{
        .{ .args = &.{ "--model", "m", "ask", "--fast" }, .stop = 2 },
        .{ .args = &.{ "--fast", "-c" }, .stop = 1 },
        .{ .args = &.{ "--model=m", "--", "x" }, .stop = 1 },
        .{ .args = &.{ "--fast", "--fast" }, .stop = 2 },
    };
    for (cases) |case| {
        var parser: Parser = .initPrefix(&docs, case.args);
        while (try parser.next()) |_| {}
        try std.testing.expectEqual(case.stop, parser.index);
    }

    var missing: Parser = .initPrefix(&docs, &.{"--model"});
    try std.testing.expectError(error.InvalidFlag, missing.next());
    try std.testing.expectEqualStrings("--model", missing.failure.?.missing_value);
}
