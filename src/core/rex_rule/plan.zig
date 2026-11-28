//! The decisions for fx's Rex resume rule.
//!
//! fx adds one `require("fx")` line to Rex's init.lua and writes fx.lua, which
//! names fx's resume command. `decide` turns what fx observed into one `Step`,
//! and the caller carries it out. This file performs no I/O, reads no clock,
//! and never allocates: the edits and the fx.lua text go into buffers that the
//! caller passes in. It imports only `std`.

const std = @import("std");

pub const max_init_bytes: usize = 1024 * 1024;
pub const require_line = "require(\"fx\") -- fx resume rule; turn it off with the rex_resume_rule setting";
pub const fx_lua_first_line = "-- Written by fx. fx owns this file and its Rex resume rule.";

pub const InitState = enum { missing, plain, not_plain, read_only, too_big, not_text };
pub const FxLuaState = enum { missing, ours, foreign, not_plain };
pub const RecordState = enum { none, trusted, no_rule, other };
pub const LineState = enum { absent, ours, foreign };

pub const Observation = struct {
    setting_on: bool,
    added_before: bool, // fx's state file says fx added the rule for this config file before
    record: RecordState, // Rex's answer about fx's own record
    init: InitState,
    line: LineState, // .absent when init is .missing
    mentions_fx_rule: bool, // init.lua text contains "resume.trust.fx"
    fx_lua: FxLuaState,
    check_ok: bool, // `rex config check` passed before any change
};

pub const Skip = enum {
    setting_off,
    trusted,
    record_not_no_rule,
    init_not_plain,
    init_read_only,
    init_too_big,
    init_not_text,
    config_broken,
    user_rule,
    foreign_line,
    foreign_fx_lua,
    user_removed,
};

pub const Step = union(enum) { skip: Skip, add, remove };

const fx_rule_key = "resume.trust.fx";
const fx_path_rule_key = "resume.trust.fx_path";
const fx_program = "fx";
const fx_lua_second_line = "-- Turn it off with the rex_resume_rule setting in fx's settings.json.\n";
const newline_lf = "\n";
const newline_crlf = "\r\n";

/// Each prefix that starts a Lua require of the fx module, not counting ours.
const foreign_prefixes = [_][]const u8{
    "require(\"fx\")",
    "require('fx')",
    "require \"fx\"",
    "require 'fx'",
    "require\"fx\"",
    "require'fx'",
};

pub fn decide(obs: Observation) Step {
    if (!obs.setting_on) {
        if (obs.line == .ours and obs.init == .plain) return .remove;
        return .{ .skip = .setting_off };
    }
    if (obs.record == .trusted) return .{ .skip = .trusted };
    if (obs.record != .no_rule) return .{ .skip = .record_not_no_rule };
    if (initSkip(obs.init)) |skip| return .{ .skip = skip };
    if (!obs.check_ok) return .{ .skip = .config_broken };
    if (obs.mentions_fx_rule) return .{ .skip = .user_rule };
    if (obs.line == .foreign) return .{ .skip = .foreign_line };
    if (obs.fx_lua == .foreign or obs.fx_lua == .not_plain) return .{ .skip = .foreign_fx_lua };
    if (obs.added_before and obs.line == .absent) return .{ .skip = .user_removed };
    return .add;
}

fn initSkip(init: InitState) ?Skip {
    return switch (init) {
        .missing, .plain => null,
        .not_plain => .init_not_plain,
        .read_only => .init_read_only,
        .too_big => .init_too_big,
        .not_text => .init_not_text,
    };
}

pub fn scanLine(text: []const u8) LineState {
    var foreign = false;
    var start: usize = 0;
    while (true) {
        const end = lineEnd(text, start);
        const line = text[start..end];
        if (isOurLine(line)) return .ours;
        if (isForeignLine(line)) foreign = true;
        if (end == text.len) break;
        start = end + 1;
    }
    return if (foreign) .foreign else .absent;
}

pub fn mentionsFxRule(text: []const u8) bool {
    return std.mem.find(u8, text, fx_rule_key) != null;
}

pub fn isText(text: []const u8) bool {
    return std.unicode.utf8ValidateSlice(text) and std.mem.findScalar(u8, text, 0) == null;
}

/// The number of bytes `addLine` writes for `text`.
pub fn addedLen(text: []const u8) usize {
    if (scanLine(text) == .ours) return text.len;
    return text.len + require_line.len + newlineFor(text).len;
}

/// Writes `text` with our line added into `out`, which must hold `addedLen(text)`
/// bytes, and returns the written part. Text that already has our line is copied.
pub fn addLine(text: []const u8, out: []u8) []const u8 {
    std.debug.assert(out.len >= addedLen(text));
    var at: usize = 0;
    put(out, &at, text);
    if (scanLine(text) == .ours) return out[0..at];
    if (endsWithNewline(text)) {
        put(out, &at, require_line);
        put(out, &at, newlineFor(text));
    } else {
        put(out, &at, newlineFor(text));
        put(out, &at, require_line);
    }
    return out[0..at];
}

/// Writes `text` with its first line of ours removed into `out`, which must hold
/// `text.len` bytes, and returns the written part. This is the inverse of `addLine`.
pub fn removeLine(text: []const u8, out: []u8) []const u8 {
    std.debug.assert(out.len >= text.len);
    var at: usize = 0;
    if (ourLineCut(text)) |cut| {
        put(out, &at, text[0..cut.start]);
        put(out, &at, text[cut.end..]);
    } else {
        put(out, &at, text);
    }
    return out[0..at];
}

pub fn isOurFxLua(text: []const u8) bool {
    return std.mem.eql(u8, withoutCr(text[0..lineEnd(text, 0)]), fx_lua_first_line);
}

/// Writes fx.lua into `out`, or returns null when `out` is too small.
pub fn fxLua(out: []u8, exe_path: ?[]const u8, sessions_dir: []const u8) ?[]const u8 {
    var sink: Sink = .{ .out = out };
    writeFxLua(&sink, exe_path, sessions_dir) catch return null;
    return out[0..sink.len];
}

const SinkError = error{NoSpace};

/// A fixed buffer that reports when a write does not fit.
const Sink = struct {
    out: []u8,
    len: usize = 0,

    fn bytes(self: *Sink, text: []const u8) SinkError!void {
        if (text.len > self.out.len - self.len) return error.NoSpace;
        @memcpy(self.out[self.len..][0..text.len], text);
        self.len += text.len;
    }
};

fn writeFxLua(sink: *Sink, exe_path: ?[]const u8, sessions_dir: []const u8) SinkError!void {
    try sink.bytes(fx_lua_first_line ++ "\n");
    try sink.bytes(fx_lua_second_line);
    try writeResumeRule(sink, fx_rule_key, fx_program, sessions_dir);
    const exe = exe_path orelse return;
    if (std.mem.eql(u8, exe, fx_program)) return;
    try writeResumeRule(sink, fx_path_rule_key, exe, sessions_dir);
}

fn writeResumeRule(sink: *Sink, key: []const u8, program: []const u8, sessions_dir: []const u8) SinkError!void {
    try sink.bytes("rex.set(");
    try writeLuaString(sink, key);
    try sink.bytes(", { command = { ");
    try writeLuaString(sink, program);
    try sink.bytes(", \"--resume\", rex.match.under(");
    try writeLuaString(sink, sessions_dir);
    try sink.bytes(") } })\n");
}

/// Writes `text` as a double-quoted Lua string. Every byte outside the plain
/// set becomes `\ddd`, so no byte can end the string or start an escape.
fn writeLuaString(sink: *Sink, text: []const u8) SinkError!void {
    try sink.bytes("\"");
    for (text) |byte| {
        if (isPlainLuaByte(byte)) {
            try sink.bytes(&[_]u8{byte});
        } else {
            try sink.bytes(&[_]u8{ '\\', '0' + byte / 100, '0' + (byte / 10) % 10, '0' + byte % 10 });
        }
    }
    try sink.bytes("\"");
}

fn isPlainLuaByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '/' or byte == '.' or byte == '_' or byte == '-';
}

fn isOurLine(line: []const u8) bool {
    return std.mem.eql(u8, withoutCr(line), require_line);
}

fn isForeignLine(line: []const u8) bool {
    if (isOurLine(line)) return false;
    const trimmed = std.mem.trimStart(u8, line, " \t");
    for (foreign_prefixes) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) return true;
    }
    return false;
}

fn withoutCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

/// The end of the line that starts at `start`: the index of its "\n", or the
/// text length when no newline follows.
fn lineEnd(text: []const u8, start: usize) usize {
    return std.mem.findScalarPos(u8, text, start, '\n') orelse text.len;
}

/// The newline `addLine` uses: "\r\n" when the first newline in `text` is CRLF.
fn newlineFor(text: []const u8) []const u8 {
    const first = std.mem.findScalar(u8, text, '\n') orelse return newline_lf;
    if (first >= 1 and text[first - 1] == '\r') return newline_crlf;
    return newline_lf;
}

fn endsWithNewline(text: []const u8) bool {
    return text.len == 0 or text[text.len - 1] == '\n';
}

fn put(out: []u8, at: *usize, bytes: []const u8) void {
    @memcpy(out[at.*..][0..bytes.len], bytes);
    at.* += bytes.len;
}

const Cut = struct {
    start: usize,
    end: usize,
};

fn ourLineCut(text: []const u8) ?Cut {
    var start: usize = 0;
    while (true) {
        const end = lineEnd(text, start);
        if (isOurLine(text[start..end])) return cutOf(text, start, end);
        if (end == text.len) return null;
        start = end + 1;
    }
}

/// Our line runs from `start` to `end`. A newline after it goes with it. A last
/// line has no newline of its own, so the newline before it goes instead.
fn cutOf(text: []const u8, start: usize, end: usize) Cut {
    if (end < text.len) return .{ .start = start, .end = end + 1 };
    if (start == 0) return .{ .start = 0, .end = end };
    return .{ .start = separatorStart(text, start - 1), .end = end };
}

/// `newline_at` is the "\n" before a last line. It is the CRLF that `addLine`
/// wrote only when `addLine` would choose CRLF for the text before it. A "\r"
/// before it that belongs to that text stays.
fn separatorStart(text: []const u8, newline_at: usize) usize {
    if (newline_at >= 1 and text[newline_at - 1] == '\r' and
        std.mem.eql(u8, newlineFor(text[0 .. newline_at - 1]), newline_crlf))
    {
        return newline_at - 1;
    }
    return newline_at;
}

test "decide removes our line when fx is off and init.lua is plain" {
    var obs = fresh;
    obs.setting_on = false;
    obs.line = .ours;
    try expectStep(.remove, decide(obs));
}

test "decide skips when fx is off and the line is not ours" {
    var obs = fresh;
    obs.setting_on = false;
    try expectSkip(.setting_off, decide(obs));
    obs.line = .ours;
    obs.init = .not_plain;
    try expectSkip(.setting_off, decide(obs));
}

test "decide skips a trusted record" {
    var obs = fresh;
    obs.record = .trusted;
    try expectSkip(.trusted, decide(obs));
}

test "decide skips any record that is not a no_rule record" {
    var obs = fresh;
    obs.record = .none;
    try expectSkip(.record_not_no_rule, decide(obs));
    obs.record = .other;
    try expectSkip(.record_not_no_rule, decide(obs));
}

test "decide skips init.lua that fx cannot edit" {
    var obs = fresh;
    obs.init = .not_plain;
    try expectSkip(.init_not_plain, decide(obs));
    obs.init = .read_only;
    try expectSkip(.init_read_only, decide(obs));
    obs.init = .too_big;
    try expectSkip(.init_too_big, decide(obs));
    obs.init = .not_text;
    try expectSkip(.init_not_text, decide(obs));
}

test "decide adds the rule when init.lua is missing" {
    var obs = fresh;
    obs.init = .missing;
    try expectStep(.add, decide(obs));
}

test "decide skips when the config check failed before any change" {
    var obs = fresh;
    obs.check_ok = false;
    try expectSkip(.config_broken, decide(obs));
}

test "decide skips when the user already wrote a resume.trust.fx rule" {
    var obs = fresh;
    obs.mentions_fx_rule = true;
    try expectSkip(.user_rule, decide(obs));
}

test "decide skips a foreign require of fx" {
    var obs = fresh;
    obs.line = .foreign;
    try expectSkip(.foreign_line, decide(obs));
}

test "decide skips a fx.lua that is foreign or not plain" {
    var obs = fresh;
    obs.fx_lua = .foreign;
    try expectSkip(.foreign_fx_lua, decide(obs));
    obs.fx_lua = .not_plain;
    try expectSkip(.foreign_fx_lua, decide(obs));
}

test "decide skips when the user removed fx's line after fx added it" {
    var obs = fresh;
    obs.added_before = true;
    try expectSkip(.user_removed, decide(obs));
}

test "decide adds the rule when fx added it before and the line is still there" {
    var obs = fresh;
    obs.added_before = true;
    obs.line = .ours;
    obs.fx_lua = .ours;
    try expectStep(.add, decide(obs));
}

test "decide adds the rule to a plain init.lua with no rule yet" {
    try expectStep(.add, decide(fresh));
}

const fresh: Observation = .{
    .setting_on = true,
    .added_before = false,
    .record = .no_rule,
    .init = .plain,
    .line = .absent,
    .mentions_fx_rule = false,
    .fx_lua = .missing,
    .check_ok = true,
};

fn expectStep(expected: Step, actual: Step) !void {
    try std.testing.expectEqualDeep(expected, actual);
}

fn expectSkip(expected: Skip, actual: Step) !void {
    try std.testing.expectEqualDeep(Step{ .skip = expected }, actual);
}

test "scanLine finds our line, with or without a CR" {
    try std.testing.expectEqual(LineState.ours, scanLine(require_line));
    try std.testing.expectEqual(LineState.ours, scanLine(require_line ++ "\r"));
    try std.testing.expectEqual(LineState.ours, scanLine("a\r\n" ++ require_line ++ "\r\nb\n"));
}

test "scanLine finds every foreign spelling of require fx" {
    const spellings = [_][]const u8{
        "require(\"fx\")\n",
        "require('fx')\n",
        "require \"fx\"\n",
        "require 'fx'\n",
        "require\"fx\"\n",
        "require'fx'\n",
        "  \trequire \"fx\" -- mine\n",
    };
    for (spellings) |text| {
        try std.testing.expectEqual(LineState.foreign, scanLine(text));
    }
}

test "scanLine reports absent for other text" {
    try std.testing.expectEqual(LineState.absent, scanLine(""));
    try std.testing.expectEqual(LineState.absent, scanLine("print('hi')\n"));
    try std.testing.expectEqual(LineState.absent, scanLine("-- require(\"fx\") in a comment\n"));
}

test "scanLine lets ours win over a foreign line" {
    try std.testing.expectEqual(LineState.ours, scanLine("require('fx')\n" ++ require_line ++ "\n"));
}

test "addLine writes our line into empty text" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(require_line ++ "\n", addLine("", &buffer));
}

test "addLine adds our line after text that ends with a newline" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("a\n" ++ require_line ++ "\n", addLine("a\n", &buffer));
}

test "addLine adds a newline before our line when the text has none at the end" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("a\n" ++ require_line, addLine("a", &buffer));
}

test "addLine uses CRLF when the first line ending is CRLF" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("a\r\nb\r\n" ++ require_line ++ "\r\n", addLine("a\r\nb\r\n", &buffer));
    try std.testing.expectEqualStrings("a\r\nb\r\n" ++ require_line, addLine("a\r\nb", &buffer));
}

test "addLine copies text that already has our line" {
    var buffer: [256]u8 = undefined;
    const text = "a\n" ++ require_line ++ "\n";
    try std.testing.expectEqualStrings(text, addLine(text, &buffer));
    try std.testing.expectEqual(text.len, addedLen(text));
}

test "removeLine undoes addLine for every text shape" {
    const texts = [_][]const u8{ "", "a", "a\n", "a\r\nb", "a\r\nb\r\n", "x\r", "a\nb\r", "a\r\nb\r" };
    var added: [512]u8 = undefined;
    var removed: [512]u8 = undefined;
    for (texts) |text| {
        const with_line = addLine(text, &added);
        try std.testing.expectEqualStrings(text, removeLine(with_line, &removed));
    }
}

test "removeLine takes our line out of the middle and leaves the rest" {
    var buffer: [256]u8 = undefined;
    const text = "a\n" ++ require_line ++ "\nb\n";
    try std.testing.expectEqualStrings("a\nb\n", removeLine(text, &buffer));
}

test "removeLine leaves text without our line unchanged" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("a\r\nb", removeLine("a\r\nb", &buffer));
}

test "removeLine keeps a CR that belongs to the text before an added LF" {
    var buffer: [256]u8 = undefined;
    const text = "x\r" ++ "\n" ++ require_line;
    try std.testing.expectEqualStrings("x\r", removeLine(text, &buffer));
}

test "addedLen matches the bytes addLine writes" {
    var buffer: [256]u8 = undefined;
    const texts = [_][]const u8{ "", "a", "a\n", "a\r\nb" };
    for (texts) |text| {
        try std.testing.expectEqual(addLine(text, &buffer).len, addedLen(text));
    }
}

test "isOurFxLua checks the first line, ignoring a trailing CR" {
    try std.testing.expect(isOurFxLua(fx_lua_first_line ++ "\n"));
    try std.testing.expect(isOurFxLua(fx_lua_first_line ++ "\r\nrex.set"));
    try std.testing.expect(!isOurFxLua("-- Written by someone else.\n"));
    try std.testing.expect(!isOurFxLua(""));
}

test "isText accepts UTF-8 without NUL and refuses the rest" {
    try std.testing.expect(isText("plain"));
    try std.testing.expect(isText("caf\xc3\xa9\n"));
    try std.testing.expect(!isText("bad \xff"));
    try std.testing.expect(!isText("a\x00b"));
}

test "mentionsFxRule finds the rule key in either name" {
    try std.testing.expect(mentionsFxRule("rex.set(\"resume.trust.fx\", {})"));
    try std.testing.expect(mentionsFxRule("rex.set(\"resume.trust.fx_path\", {})"));
    try std.testing.expect(!mentionsFxRule("rex.set(\"resume.trust.other\", {})"));
}

test "luaString quotes and escapes every byte outside the plain set" {
    var buffer: [64]u8 = undefined;
    var sink: Sink = .{ .out = &buffer };
    try writeLuaString(&sink, "/a b\"c");
    try std.testing.expectEqualStrings("\"/a\\032b\\034c\"", buffer[0..sink.len]);
}

test "luaString escapes a quote, backslash, newline, ]], space, and non-ASCII bytes" {
    var buffer: [128]u8 = undefined;
    var sink: Sink = .{ .out = &buffer };
    try writeLuaString(&sink, "\"\\\n]] \xc3\xa9");
    try std.testing.expectEqualStrings(
        "\"\\034\\092\\010\\093\\093\\032\\195\\169\"",
        buffer[0..sink.len],
    );
}

test "fxLua writes the rules for a full exe path" {
    var buffer: [1024]u8 = undefined;
    const text = fxLua(&buffer, "/Users/example/.local/bin/fx", "/Users/example/.fx/sessions/v2").?;
    try std.testing.expectEqualStrings(
        \\-- Written by fx. fx owns this file and its Rex resume rule.
        \\-- Turn it off with the rex_resume_rule setting in fx's settings.json.
        \\rex.set("resume.trust.fx", { command = { "fx", "--resume", rex.match.under("/Users/example/.fx/sessions/v2") } })
        \\rex.set("resume.trust.fx_path", { command = { "/Users/example/.local/bin/fx", "--resume", rex.match.under("/Users/example/.fx/sessions/v2") } })
        \\
    , text);
}

test "fxLua leaves out the fx_path rule when the exe is null or fx" {
    var buffer: [1024]u8 = undefined;
    const expected =
        \\-- Written by fx. fx owns this file and its Rex resume rule.
        \\-- Turn it off with the rex_resume_rule setting in fx's settings.json.
        \\rex.set("resume.trust.fx", { command = { "fx", "--resume", rex.match.under("/Users/example/.fx/sessions/v2") } })
        \\
    ;
    try std.testing.expectEqualStrings(expected, fxLua(&buffer, null, "/Users/example/.fx/sessions/v2").?);
    try std.testing.expectEqualStrings(expected, fxLua(&buffer, "fx", "/Users/example/.fx/sessions/v2").?);
}

test "fxLua returns null when the buffer is too small" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), fxLua(&buffer, null, "/Users/example/.fx/sessions/v2"));
}

const max_fuzz_text_bytes: usize = 4096;
const max_newline_len: usize = 2;
const line_edit_capacity = max_fuzz_text_bytes + require_line.len + max_newline_len;

fn fuzzLineEdits(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_fuzz_text_bytes]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    const text = buffer[0..len];
    if (!isText(text) or scanLine(text) != .absent) return;

    var added: [line_edit_capacity]u8 = undefined;
    const once = addLine(text, &added);
    try std.testing.expectEqual(addedLen(text), once.len);
    try std.testing.expectEqual(LineState.ours, scanLine(once));

    var removed: [line_edit_capacity]u8 = undefined;
    try std.testing.expectEqualStrings(text, removeLine(once, &removed));

    var again: [line_edit_capacity]u8 = undefined;
    try std.testing.expectEqualStrings(once, addLine(once, &again));
}

test "rex_rule line edits round-trip" {
    try std.testing.fuzz({}, fuzzLineEdits, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "a",
            "a\n",
            "a\r\nb",
            "a\r",
        }) ++ @import("fuzz_corpus").rex_rule_line.*),
    });
}
