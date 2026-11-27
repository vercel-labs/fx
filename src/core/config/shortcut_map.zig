//! Personal keyboard shortcuts from the profile's top-level `shortcuts` object.
//! Each key is a chord, as the key module parses it; each value is one action:
//! a saved model preset, the model picker, a fast-mode toggle, or one fx
//! command line. Parsing never reads the rest of the profile. One bad entry
//! rejects the whole map, so a caller that keeps its last good map never loses
//! shortcuts to a partial edit.

const std = @import("std");
const key_chord = @import("../input/key_chord.zig");
const model_provider = @import("model_provider.zig");
const settings_store = @import("settings_store.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");

/// The one chord type. Config reads and writes chords only through the key module.
pub const Chord = key_chord.Chord;

pub const max_model_bytes: usize = settings_store.max_model_bytes;

/// Longest chord text a shortcut key may hold, in bytes. Also the buffer a
/// caller formats a canonical chord into.
pub const max_key_bytes: usize = 64;

/// Most shortcuts one profile may hold. A count bound, not a chord count: an
/// entry is about 1.2 KiB inline, and a map exists only when the profile sets
/// shortcuts, so the largest map is a few tens of KiB.
pub const max_entries: usize = 32;

/// Longest `command` text. It is one line typed by the user, so it shares the
/// single-line bound that model ids use.
pub const max_command_bytes: usize = settings_store.max_model_bytes;

/// What a chord text looks like, for the schema. It follows the key module's
/// own grammar; the parser is the rule that counts.
pub const key_grammar_description = "A key chord: the modifiers ctrl, alt, shift, and super, each at most once and in any order, joined with +, then one key, such as ctrl+f, Alt+Shift+Left, or ctrl+. A plain key with no modifier is typing, not a chord.";

pub const ParseError = error{
    NotAnObject,
    TooManyShortcuts,
    UnknownChord,
    DuplicateChord,
    InvalidAction,
    UnknownAction,
    UnknownField,
    MissingField,
    InvalidProvider,
    InvalidModel,
    InvalidEffort,
    InvalidFastMode,
    InvalidCommand,
};

const preset_fields = [_][]const u8{ "action", "provider", "model", "effort", "fast_mode" };

pub const Preset = struct {
    provider: model_provider.ProviderId,
    model_bytes: [max_model_bytes]u8,
    model_len: u16,
    effort: types.ReasoningEffort,
    fast_mode: bool,

    pub fn model(self: *const Preset) []const u8 {
        return self.model_bytes[0..self.model_len];
    }
};

/// One fx slash command and its arguments, as one line. The text goes to fx's
/// command router, never to a shell, so arguments may hold any terminal-safe UTF-8.
pub const Command = struct {
    len: u16 = 0,
    bytes: [max_command_bytes]u8 = @splat(0),

    /// The command with its leading "/", borrowed from `self`.
    pub fn text(self: *const Command) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// The two canonical actions. Saved and written profiles use only these.
pub const Action = union(enum) {
    command: Command,
    select_model: Preset,
};

/// Input-only names from the first shortcut format, each with the one slash
/// command it means. Both consumers read this table: the parser turns a name
/// into its command, and the setter writes the canonical `command` JSON.
const legacy_aliases = [_]struct { name: []const u8, command: []const u8 }{
    .{ .name = "open_model_picker", .command = "/model" },
    .{ .name = "toggle_fast_mode", .command = "/fast" },
};

const canonical_command_format = "{{\"action\":\"command\",\"command\":\"{s}\"}}";

fn legacyAliasCommand(name: []const u8) ?[]const u8 {
    for (legacy_aliases) |alias| {
        if (std.mem.eql(u8, alias.name, name)) return alias.command;
    }
    return null;
}

/// The canonical JSON for a legacy action name, or null for any other name.
/// Callers validate the whole action with `parseAction` first. The text is
/// built at compile time from the same command the parser uses.
pub fn canonicalActionJson(name: []const u8) ?[]const u8 {
    inline for (legacy_aliases) |alias| {
        if (std.mem.eql(u8, alias.name, name)) {
            return comptime std.fmt.comptimePrint(canonical_command_format, .{alias.command});
        }
    }
    return null;
}

pub const Entry = struct {
    chord: Chord,
    action: Action,
};

pub const Map = struct {
    entries_len: usize = 0,
    entries: [max_entries]Entry = undefined,

    pub fn items(self: *const Map) []const Entry {
        return self.entries[0..self.entries_len];
    }

    pub fn find(self: *const Map, chord: Chord) ?*const Entry {
        for (self.items()) |*entry| {
            if (entry.chord.eql(chord)) return entry;
        }
        return null;
    }
};

/// Where a rejected `shortcuts` value went wrong. Slices borrow from the
/// parsed JSON, so a caller copies them before that JSON is freed.
pub const Problem = struct {
    chord: []const u8 = "",
    field: []const u8 = "",
};

pub fn parseJsonObject(value: std.json.Value) ParseError!Map {
    var ignored: Problem = .{};
    return parseJsonObjectChecked(value, &ignored);
}

/// Like `parseJsonObject`, and records the chord and field that failed.
pub fn parseJsonObjectChecked(value: std.json.Value, problem: *Problem) ParseError!Map {
    if (value != .object) return error.NotAnObject;
    if (value.object.count() > max_entries) return error.TooManyShortcuts;

    var map: Map = .{};
    var iterator = value.object.iterator();
    while (iterator.next()) |field| {
        problem.* = .{ .chord = field.key_ptr.* };
        if (field.key_ptr.*.len > max_key_bytes) return error.UnknownChord;
        const chord = Chord.parse(field.key_ptr.*) orelse return error.UnknownChord;
        if (map.find(chord) != null) return error.DuplicateChord;
        const action = try parseActionChecked(field.value_ptr.*, problem);
        map.entries[map.entries_len] = .{ .chord = chord, .action = action };
        map.entries_len += 1;
    }
    return map;
}

/// One entry's action, the grammar `parseJsonObject` uses for each value.
pub fn parseAction(value: std.json.Value) ParseError!Action {
    var ignored: Problem = .{};
    return parseActionChecked(value, &ignored);
}

fn parseActionChecked(value: std.json.Value, problem: *Problem) ParseError!Action {
    if (value != .object) return error.InvalidAction;
    const name = value.object.get("action") orelse return fail(problem, "action", error.MissingField);
    if (name != .string) return fail(problem, "action", error.InvalidAction);

    if (legacyAliasCommand(name.string)) |command_text| {
        for (value.object.keys()) |key| {
            if (!std.mem.eql(u8, key, "action")) return fail(problem, key, error.UnknownField);
        }
        return .{ .command = try makeCommand(command_text) };
    }
    if (std.mem.eql(u8, name.string, "command")) {
        for (value.object.keys()) |key| {
            if (!std.mem.eql(u8, key, "action") and !std.mem.eql(u8, key, "command")) return fail(problem, key, error.UnknownField);
        }
        const text = value.object.get("command") orelse return fail(problem, "command", error.MissingField);
        if (text != .string) return fail(problem, "command", error.InvalidCommand);
        return .{ .command = makeCommand(text.string) catch |err| return fail(problem, "command", err) };
    }
    if (std.mem.eql(u8, name.string, "select_model")) {
        return .{ .select_model = try parsePreset(value.object, problem) };
    }
    return fail(problem, "action", error.UnknownAction);
}

/// A command is "/name", then optional arguments, all on one line. Its name is
/// lowercase letters, digits, and hyphens, starting with a letter. The arguments
/// may hold any terminal-safe UTF-8.
fn makeCommand(text: []const u8) ParseError!Command {
    if (text.len < 2 or text.len > max_command_bytes) return error.InvalidCommand;
    if (text[0] != '/' or text[text.len - 1] == ' ' or !terminalSafeText(text)) return error.InvalidCommand;
    const name_end = std.mem.findScalar(u8, text, ' ') orelse text.len;
    const name = text[1..name_end];
    if (name.len == 0 or !std.ascii.isLower(name[0])) return error.InvalidCommand;
    for (name) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '-') return error.InvalidCommand;
    }
    var command: Command = .{ .len = @intCast(text.len) };
    @memcpy(command.bytes[0..text.len], text);
    return command;
}

/// Valid UTF-8 with no control character: no C0 byte, no DEL, and no C1
/// code point (U+0080 through U+009F, encoded as 0xC2 0x80 through 0xC2 0x9F).
fn terminalSafeText(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    for (text, 0..) |byte, index| {
        if (byte < 0x20 or byte == 0x7f) return false;
        if (byte == 0xc2 and index + 1 < text.len and text[index + 1] >= 0x80 and text[index + 1] <= 0x9f) return false;
    }
    return true;
}

/// Records the field that failed, so the caller can name it, and returns `err`.
fn fail(problem: *Problem, field: []const u8, err: ParseError) ParseError {
    problem.field = field;
    return err;
}

fn parsePreset(object: std.json.ObjectMap, problem: *Problem) ParseError!Preset {
    for (object.keys()) |key| {
        if (!containsField(key)) return fail(problem, key, error.UnknownField);
    }

    const provider_value = object.get("provider") orelse return fail(problem, "provider", error.MissingField);
    if (provider_value != .string) return fail(problem, "provider", error.InvalidProvider);
    const provider = model_provider.parse(provider_value.string) orelse return fail(problem, "provider", error.InvalidProvider);
    if (provider == .configured) return fail(problem, "provider", error.InvalidProvider);

    const model_value = object.get("model") orelse return fail(problem, "model", error.MissingField);
    if (model_value != .string) return fail(problem, "model", error.InvalidModel);

    const effort_value = object.get("effort") orelse return fail(problem, "effort", error.MissingField);
    if (effort_value != .string) return fail(problem, "effort", error.InvalidEffort);
    const effort = types.ReasoningEffort.parse(effort_value.string) orelse return fail(problem, "effort", error.InvalidEffort);

    const fast_value = object.get("fast_mode") orelse return fail(problem, "fast_mode", error.MissingField);
    if (fast_value != .bool) return fail(problem, "fast_mode", error.InvalidFastMode);

    return makePreset(provider, model_value.string, effort, fast_value.bool) catch |err| return fail(problem, "model", err);
}

/// The one rule for a preset's fields.
fn makePreset(
    provider: model_provider.ProviderId,
    model_text: []const u8,
    effort: types.ReasoningEffort,
    fast_mode: bool,
) ParseError!Preset {
    if (provider == .configured) return error.InvalidProvider;
    settings_store.validateModel(model_text) catch return error.InvalidModel;
    if (!text_utils.isTerminalSafe(model_text)) return error.InvalidModel;

    var preset: Preset = .{
        .provider = provider,
        .model_bytes = undefined,
        .model_len = @intCast(model_text.len),
        .effort = effort,
        .fast_mode = fast_mode,
    };
    @memcpy(preset.model_bytes[0..model_text.len], model_text);
    return preset;
}

fn containsField(key: []const u8) bool {
    for (preset_fields) |field| {
        if (std.mem.eql(u8, field, key)) return true;
    }
    return false;
}

fn parseMapText(text: []const u8) !Map {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();
    return parseJsonObject(parsed.value);
}

fn chordOf(text: []const u8) Chord {
    return Chord.parse(text).?;
}

const valid_text =
    \\{"ctrl+1":{"action":"select_model","provider":"gateway","model":"openai/gpt-5","effort":"high","fast_mode":true},"alt+m":{"action":"open_model_picker"}}
;

test "a chord parses the terminal keys with modifiers, in any case and modifier order" {
    try std.testing.expect(chordOf("ctrl+1").eql(chordOf("CTRL+1")));
    try std.testing.expect(chordOf("ctrl+f").eql(chordOf("Ctrl+F")));
    try std.testing.expect(chordOf("ctrl+.").eql(chordOf("CTRL+.")));
    try std.testing.expect(chordOf("ctrl++").eql(chordOf("ctrl++")));
    try std.testing.expect(chordOf("shift+ctrl+left").eql(chordOf("Ctrl+Shift+Left")));
    try std.testing.expect(Chord.parse("1") == null);
    try std.testing.expect(Chord.parse("f") == null);
    try std.testing.expect(Chord.parse("") == null);
    try std.testing.expect(Chord.parse("ctrl+") == null);
    try std.testing.expect(Chord.parse("ctrl+ab") == null);
    try std.testing.expect(Chord.parse("ctrl+ctrl+a") == null);
    try std.testing.expect(Chord.parse("bogus+a") == null);
}

test "a chord formats to the canonical spelling in modifier order" {
    var buffer: [max_key_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("ctrl+1", chordOf("CTRL+1").format(&buffer).?);
    try std.testing.expectEqualStrings("alt+m", chordOf("Alt+M").format(&buffer).?);
    try std.testing.expectEqualStrings("ctrl+shift+left", chordOf("Shift+Ctrl+Left").format(&buffer).?);
    try std.testing.expectEqualStrings("ctrl+.", chordOf("CTRL+.").format(&buffer).?);
}

test "map reads both action kinds and finds each chord" {
    const map = try parseMapText(valid_text);
    try std.testing.expectEqual(@as(usize, 2), map.items().len);

    const ctrl_one = map.find(chordOf("ctrl+1")).?;
    const preset = ctrl_one.action.select_model;
    try std.testing.expectEqualStrings("openai/gpt-5", preset.model());
    try std.testing.expectEqualStrings("high", preset.effort.label());
    try std.testing.expect(preset.fast_mode);
    try std.testing.expect(preset.provider == .gateway);

    const alt_m = map.find(chordOf("alt+m")).?;
    try std.testing.expectEqualStrings("/model", alt_m.action.command.text());
    try std.testing.expect(map.find(chordOf("ctrl+2")) == null);
}

test "a chord with a dot is a key, and the map keeps it" {
    const map = try parseMapText("{\"ctrl+.\":{\"action\":\"toggle_fast_mode\"}}");
    try std.testing.expectEqualStrings("/fast", map.find(chordOf("ctrl+.")).?.action.command.text());
}

test "empty object is an empty map" {
    const map = try parseMapText("{}");
    try std.testing.expectEqual(@as(usize, 0), map.items().len);
}

test "one bad entry rejects the whole map" {
    try std.testing.expectError(error.NotAnObject, parseMapText("[]"));
    try std.testing.expectError(error.UnknownChord, parseMapText(
        \\{"1":{"action":"open_model_picker"}}
    ));
    try std.testing.expectError(error.DuplicateChord, parseMapText(
        \\{"ctrl+1":{"action":"open_model_picker"},"CTRL+1":{"action":"open_model_picker"}}
    ));
    try std.testing.expectError(error.UnknownAction, parseMapText(
        \\{"alt+m":{"action":"run_shell"}}
    ));
    try std.testing.expectError(error.InvalidAction, parseMapText(
        \\{"alt+m":"open_model_picker"}
    ));
    try std.testing.expectError(error.UnknownField, parseMapText(
        \\{"alt+m":{"action":"open_model_picker","provider":"gateway"}}
    ));
}

test "a preset needs provider, model, effort, and fast_mode" {
    try std.testing.expectError(error.MissingField, parseMapText(
        \\{"ctrl+1":{"action":"select_model","model":"m","effort":"high","fast_mode":true}}
    ));
    try std.testing.expectError(error.MissingField, parseMapText(
        \\{"ctrl+1":{"action":"select_model","provider":"gateway","effort":"high","fast_mode":true}}
    ));
    try std.testing.expectError(error.MissingField, parseMapText(
        \\{"ctrl+1":{"action":"select_model","provider":"gateway","model":"m","fast_mode":true}}
    ));
    try std.testing.expectError(error.MissingField, parseMapText(
        \\{"ctrl+1":{"action":"select_model","provider":"gateway","model":"m","effort":"high"}}
    ));
}

test "a preset rejects unknown fields and bad values" {
    try std.testing.expectError(error.UnknownField, parseMapText(
        \\{"ctrl+1":{"action":"select_model","provider":"gateway","model":"m","effort":"high","fast_mode":true,"ultrafast_mode":true}}
    ));
    try std.testing.expectError(error.InvalidProvider, parseMapText(
        \\{"ctrl+1":{"action":"select_model","provider":"nope provider","model":"m","effort":"high","fast_mode":true}}
    ));
    try std.testing.expectError(error.InvalidModel, parseMapText(
        \\{"ctrl+1":{"action":"select_model","provider":"gateway","model":"","effort":"high","fast_mode":true}}
    ));
    try std.testing.expectError(error.InvalidEffort, parseMapText(
        \\{"ctrl+1":{"action":"select_model","provider":"gateway","model":"m","effort":"high level","fast_mode":true}}
    ));
    try std.testing.expectError(error.InvalidFastMode, parseMapText(
        \\{"ctrl+1":{"action":"select_model","provider":"gateway","model":"m","effort":"high","fast_mode":"yes"}}
    ));
}

test "a map holds at most max_entries shortcuts" {
    const text = comptime blk: {
        var built: []const u8 = "{";
        for (0..max_entries + 1) |index| {
            const separator: []const u8 = if (index == 0) "" else ",";
            built = built ++ std.fmt.comptimePrint("{s}\"k{d}\":{{\"action\":\"open_model_picker\"}}", .{ separator, index });
        }
        break :blk built ++ "}";
    };
    try std.testing.expectError(error.TooManyShortcuts, parseMapText(text));
}

test "a preset longer than the model limit is rejected" {
    const long_model = @as([settings_store.max_model_bytes + 1]u8, @splat('m'));
    const text = std.fmt.comptimePrint(
        "{{\"ctrl+1\":{{\"action\":\"select_model\",\"provider\":\"gateway\",\"model\":\"{s}\",\"effort\":\"high\",\"fast_mode\":true}}}}",
        .{long_model[0..]},
    );
    try std.testing.expectError(error.InvalidModel, parseMapText(text));
}

test "an empty map holds no entries" {
    const map: Map = .{};
    try std.testing.expect(map.items().len == 0);
}

test "legacy aliases parse to the canonical command, byte for byte" {
    const alias_model = try parseMapText("{\"alt+m\":{\"action\":\"open_model_picker\"}}");
    const canonical_model = try parseMapText("{\"alt+m\":{\"action\":\"command\",\"command\":\"/model\"}}");
    try std.testing.expect(std.meta.eql(alias_model.find(chordOf("alt+m")).?.action, canonical_model.find(chordOf("alt+m")).?.action));

    const alias_fast = try parseMapText("{\"ctrl+.\":{\"action\":\"toggle_fast_mode\"}}");
    const canonical_fast = try parseMapText("{\"ctrl+.\":{\"action\":\"command\",\"command\":\"/fast\"}}");
    try std.testing.expect(std.meta.eql(alias_fast.find(chordOf("ctrl+.")).?.action, canonical_fast.find(chordOf("ctrl+.")).?.action));
}

test "canonical JSON is written only for legacy names" {
    try std.testing.expectEqualStrings("{\"action\":\"command\",\"command\":\"/model\"}", canonicalActionJson("open_model_picker").?);
    try std.testing.expectEqualStrings("{\"action\":\"command\",\"command\":\"/fast\"}", canonicalActionJson("toggle_fast_mode").?);
    try std.testing.expect(canonicalActionJson("command") == null);
    try std.testing.expect(canonicalActionJson("select_model") == null);
}

test "toggle_fast_mode is a bare action, and Ctrl+F is a chord in any letter case" {
    const map = try parseMapText("{\"CTRL+F\":{\"action\":\"toggle_fast_mode\"}}");
    const entry = map.find(chordOf("ctrl+f")).?;
    try std.testing.expectEqualStrings("/fast", entry.action.command.text());
    try std.testing.expectError(error.UnknownField, parseMapText(
        \\{"ctrl+f":{"action":"toggle_fast_mode","fast_mode":true}}
    ));
}

test "a command keeps its arguments whole, with punctuation and UTF-8" {
    const map = try parseMapText(
        \\{"ctrl+2":{"action":"command","command":"/model gpt-5; ! ünïcode | x"}}
    );
    const entry = map.find(chordOf("ctrl+2")).?;
    try std.testing.expectEqualStrings("/model gpt-5; ! ünïcode | x", entry.action.command.text());
}

test "a command is one slash line of terminal-safe text" {
    const refused = [_][]const u8{ "", "/", "fast", "/Fast", "/ fast", "/fast ", "/fast\n", "/fast\x1b[2J", "/fast\x7f", "/fast\xc2\x9b", "/fast\xff", "/-fast" };
    for (refused) |text| try std.testing.expectError(error.InvalidCommand, makeCommand(text));
    const accepted = [_][]const u8{ "/fast", "/model gpt-5", "/a-1 é ü ; !" };
    for (accepted) |text| try std.testing.expectEqualStrings(text, (try makeCommand(text)).text());
}

test "a command rejects missing, extra, and non-string fields" {
    try std.testing.expectError(error.MissingField, parseMapText(
        \\{"ctrl+2":{"action":"command"}}
    ));
    try std.testing.expectError(error.UnknownField, parseMapText(
        \\{"ctrl+2":{"action":"command","command":"/fast","fast_mode":true}}
    ));
    try std.testing.expectError(error.InvalidCommand, parseMapText(
        \\{"ctrl+2":{"action":"command","command":7}}
    ));
}

test "shortcut map parses or is refused on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzShortcutMap, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            valid_text,
            "{}",
            "[]",
            "{\"alt+m\":{\"action\":\"open_model_picker\"}}",
            "{\"ctrl+1\":{\"action\":\"select_model\",\"provider\":\"gateway\",\"model\":\"m\",\"effort\":\"high\",\"fast_mode\":true}}",
            "\xff\x00{",
        }) ++ @import("fuzz_corpus").shortcut_map.*),
    });
}

/// Whatever bytes the profile holds, the map is refused or keeps its laws:
/// each chord is canonical and appears once, and each action keeps its own
/// rules for models and commands.
fn fuzzShortcutMap(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    var parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{}) catch return;
    defer parsed.deinit();
    var problem: Problem = .{};
    const map = parseJsonObjectChecked(parsed.value, &problem) catch return;
    try expectMapLaws(map);
}

fn expectMapLaws(map: Map) !void {
    try std.testing.expect(map.items().len <= max_entries);
    var buffer: [max_key_bytes]u8 = undefined;
    for (map.items(), 0..) |entry, index| {
        const canonical = entry.chord.format(&buffer) orelse return error.TestUnexpectedResult;
        try std.testing.expect(chordOf(canonical).eql(entry.chord));
        for (map.items()[index + 1 ..]) |other| {
            try std.testing.expect(!other.chord.eql(entry.chord));
        }
        switch (entry.action) {
            .command => |command| {
                try std.testing.expect(command.text().len > 1 and command.text()[0] == '/');
                try std.testing.expect(terminalSafeText(command.text()));
            },
            .select_model => |preset| {
                try std.testing.expect(preset.provider != .configured);
                try std.testing.expect(preset.model().len <= max_model_bytes);
                try settings_store.validateModel(preset.model());
                try std.testing.expect(text_utils.isTerminalSafe(preset.model()));
            },
        }
    }
}
