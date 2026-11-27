//! Personal keyboard shortcuts from the profile's top-level `shortcuts` object.
//! Each key is a chord, as the chord module parses it. Each value is one action:
//! a string holding one fx command line, such as "/fast", or an object holding
//! a saved model preset. Parsing never reads the rest of the profile. One bad
//! entry rejects the whole map, so a caller that keeps its last good map never
//! loses shortcuts to a partial edit.

const std = @import("std");
const key_chord = @import("chord.zig");
const model_provider = @import("../config/model_provider.zig");
const durable_model = @import("../shared/durable_model.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");

/// The one chord type. Config reads and writes chords only through shortcuts.zig.
pub const Chord = key_chord.Chord;

/// A key fx keeps for itself, with the reason, from the chord module's table.
pub const Reserved = key_chord.Reserved;

pub const max_model_bytes: usize = durable_model.max_bytes;

/// Longest chord text a shortcut key may hold, in bytes. This map owns the
/// limit; the settings store reads it from here.
pub const max_key_bytes: usize = 64;

/// Most shortcuts one profile may hold. A count bound, not a chord count: an
/// entry is about 1.2 KiB inline, and a map exists only when the profile sets
/// shortcuts, so the largest map is a few tens of KiB.
pub const max_entries: usize = 32;

/// Longest `command` text. It is one line typed by the user, so it shares the
/// single-line bound that model ids use.
pub const max_command_bytes: usize = durable_model.max_bytes;

/// What a chord text looks like, for the schema. It follows the chord module's
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
    ReservedChord,
};

const preset_fields = [_][]const u8{ "provider", "model", "effort", "fast_mode" };

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

/// What one shortcut runs: a fx command line, or a saved model preset.
pub const Action = union(enum) {
    command: Command,
    select_model: Preset,
};

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
/// parsed JSON, so a caller copies them before that JSON is freed. `reserved`
/// is set when the chord is a key fx keeps for itself, and says why.
pub const Problem = struct {
    chord: []const u8 = "",
    field: []const u8 = "",
    reserved: ?Reserved = null,
};

/// The reserved table entry a chord text names, in any letter case, or null.
/// The chord module's canonical names are the only spellings compared, so this
/// finds every text `Chord.parseChecked` refuses as reserved.
pub fn reservedEntry(text: []const u8) ?Reserved {
    var buffer: [max_key_bytes]u8 = undefined;
    for (key_chord.reserved) |entry| {
        const name = entry.chord.format(&buffer) orelse continue;
        if (std.ascii.eqlIgnoreCase(text, name)) return entry;
    }
    return null;
}

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
        const chord = Chord.parseChecked(field.key_ptr.*) catch |err| switch (err) {
            error.Malformed => return error.UnknownChord,
            error.Reserved => {
                problem.reserved = reservedEntry(field.key_ptr.*);
                return error.ReservedChord;
            },
        };
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

/// A string is one command line; an object is a model preset. Any other JSON
/// type is refused. The failing field is the chord's own entry, so a command
/// error names `shortcuts.<chord>` and never a field of the value.
fn parseActionChecked(value: std.json.Value, problem: *Problem) ParseError!Action {
    switch (value) {
        .string => |text| {
            const command = makeCommand(text) catch |err| return fail(problem, "", err);
            return .{ .command = command };
        },
        .object => |object| return .{ .select_model = try parsePreset(object, problem) },
        else => return fail(problem, "", error.InvalidAction),
    }
}

/// A command is "/name", then optional arguments, all on one line. Its name is
/// lowercase letters, digits, and hyphens, starting with a letter. The arguments
/// may hold any terminal-safe UTF-8.
fn makeCommand(text: []const u8) ParseError!Command {
    if (text.len < 2 or text.len > max_command_bytes) return error.InvalidCommand;
    if (text[0] != '/' or text[text.len - 1] == ' ' or !text_utils.isTerminalSafe(text)) return error.InvalidCommand;
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
    durable_model.validate(model_text) catch return error.InvalidModel;
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
    \\{"ctrl+1":{"provider":"gateway","model":"openai/gpt-5","effort":"high","fast_mode":true},"alt+m":"/model"}
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
    const map = try parseMapText("{\"ctrl+.\":\"/fast\"}");
    try std.testing.expectEqualStrings("/fast", map.find(chordOf("ctrl+.")).?.action.command.text());
}

test "empty object is an empty map" {
    const map = try parseMapText("{}");
    try std.testing.expectEqual(@as(usize, 0), map.items().len);
}

test "one bad entry rejects the whole map" {
    try std.testing.expectError(error.NotAnObject, parseMapText("[]"));
    try std.testing.expectError(error.UnknownChord, parseMapText(
        \\{"1":"/model"}
    ));
    try std.testing.expectError(error.DuplicateChord, parseMapText(
        \\{"ctrl+1":"/model","CTRL+1":"/model"}
    ));
    try std.testing.expectError(error.InvalidCommand, parseMapText(
        \\{"alt+m":"open_model_picker"}
    ));
    try std.testing.expectError(error.InvalidAction, parseMapText(
        \\{"alt+m":5}
    ));
    try std.testing.expectError(error.UnknownField, parseMapText(
        \\{"alt+m":{"action":"open_model_picker","provider":"gateway"}}
    ));
}

test "a preset needs provider, model, effort, and fast_mode" {
    try std.testing.expectError(error.MissingField, parseMapText(
        \\{"ctrl+1":{"model":"m","effort":"high","fast_mode":true}}
    ));
    try std.testing.expectError(error.MissingField, parseMapText(
        \\{"ctrl+1":{"provider":"gateway","effort":"high","fast_mode":true}}
    ));
    try std.testing.expectError(error.MissingField, parseMapText(
        \\{"ctrl+1":{"provider":"gateway","model":"m","fast_mode":true}}
    ));
    try std.testing.expectError(error.MissingField, parseMapText(
        \\{"ctrl+1":{"provider":"gateway","model":"m","effort":"high"}}
    ));
}

test "a preset rejects unknown fields and bad values" {
    try std.testing.expectError(error.UnknownField, parseMapText(
        \\{"ctrl+1":{"provider":"gateway","model":"m","effort":"high","fast_mode":true,"ultrafast_mode":true}}
    ));
    try std.testing.expectError(error.InvalidProvider, parseMapText(
        \\{"ctrl+1":{"provider":"nope provider","model":"m","effort":"high","fast_mode":true}}
    ));
    try std.testing.expectError(error.InvalidModel, parseMapText(
        \\{"ctrl+1":{"provider":"gateway","model":"","effort":"high","fast_mode":true}}
    ));
    try std.testing.expectError(error.InvalidEffort, parseMapText(
        \\{"ctrl+1":{"provider":"gateway","model":"m","effort":"high level","fast_mode":true}}
    ));
    try std.testing.expectError(error.InvalidFastMode, parseMapText(
        \\{"ctrl+1":{"provider":"gateway","model":"m","effort":"high","fast_mode":"yes"}}
    ));
}

test "the retired action field is refused, so no object is read as an action" {
    try std.testing.expectError(error.UnknownField, parseMapText(
        \\{"ctrl+1":{"action":"select_model","provider":"gateway","model":"m","effort":"high","fast_mode":true}}
    ));
    try std.testing.expectError(error.UnknownField, parseMapText(
        \\{"ctrl+2":{"action":"command","command":"/fast"}}
    ));
}

test "a map holds at most max_entries shortcuts" {
    const text = comptime blk: {
        var built: []const u8 = "{";
        for (0..max_entries + 1) |index| {
            const separator: []const u8 = if (index == 0) "" else ",";
            built = built ++ std.fmt.comptimePrint("{s}\"k{d}\":\"/model\"", .{ separator, index });
        }
        break :blk built ++ "}";
    };
    try std.testing.expectError(error.TooManyShortcuts, parseMapText(text));
}

test "a map holds exactly max_entries distinct chords" {
    const text = comptime blk: {
        var built: []const u8 = "{";
        for (0..max_entries) |index| {
            const separator: []const u8 = if (index == 0) "" else ",";
            const key: []const u8 = if (index < 26)
                &.{'a' + @as(u8, @intCast(index))}
            else
                &.{'0' + @as(u8, @intCast(index - 26))};
            built = built ++ std.fmt.comptimePrint("{s}\"alt+{s}\":\"/model\"", .{ separator, key });
        }
        break :blk built ++ "}";
    };
    const map = try parseMapText(text);
    try std.testing.expectEqual(max_entries, map.items().len);
    try std.testing.expect(map.find(chordOf("alt+a")) != null);
    try std.testing.expect(map.find(chordOf("alt+5")) != null);
}

test "a preset longer than the model limit is rejected" {
    const long_model = @as([durable_model.max_bytes + 1]u8, @splat('m'));
    const text = std.fmt.comptimePrint(
        "{{\"ctrl+1\":{{\"provider\":\"gateway\",\"model\":\"{s}\",\"effort\":\"high\",\"fast_mode\":true}}}}",
        .{long_model[0..]},
    );
    try std.testing.expectError(error.InvalidModel, parseMapText(text));
}

test "an empty map holds no entries" {
    const map: Map = .{};
    try std.testing.expect(map.items().len == 0);
}

test "a fast-mode toggle is the string /fast, and Ctrl+F is a chord in any letter case" {
    const map = try parseMapText("{\"CTRL+F\":\"/fast\"}");
    const entry = map.find(chordOf("ctrl+f")).?;
    try std.testing.expectEqualStrings("/fast", entry.action.command.text());
}

test "a command keeps its arguments whole, with punctuation and UTF-8" {
    const map = try parseMapText(
        \\{"ctrl+2":"/model gpt-5; ! ünïcode | x"}
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

test "a shortcut value is a string or a preset object, nothing else" {
    try std.testing.expectError(error.InvalidAction, parseMapText("{\"ctrl+2\":7}"));
    try std.testing.expectError(error.InvalidAction, parseMapText("{\"ctrl+2\":[\"/fast\"]}"));
    try std.testing.expectError(error.InvalidAction, parseMapText("{\"ctrl+2\":null}"));
    try std.testing.expectError(error.MissingField, parseMapText(
        \\{"ctrl+2":{"provider":"gateway"}}
    ));
}

test "a reserved chord is refused as reserved, and keeps its reason" {
    try std.testing.expectError(error.ReservedChord, parseMapText("{\"ctrl+c\":\"/fast\"}"));
    try std.testing.expectError(error.ReservedChord, parseMapText("{\"CTRL+P\":\"/model\"}"));
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"alt+m\":\"/model\",\"Ctrl+C\":\"/fast\"}", .{});
    defer parsed.deinit();
    var problem: Problem = .{};
    try std.testing.expectError(error.ReservedChord, parseJsonObjectChecked(parsed.value, &problem));
    try std.testing.expectEqualStrings("Ctrl+C", problem.chord);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "ctrl+c is reserved for fx: interrupts a running turn and exits",
        problem.reserved.?.chord.reservedMessage(&buffer).?,
    );
}

test "reservedEntry finds the reserved table entry in any letter case" {
    try std.testing.expect(reservedEntry("ctrl+c") != null);
    try std.testing.expect(reservedEntry("CTRL+P") != null);
    try std.testing.expect(reservedEntry("ctrl+f") == null);
}

test "shortcut map parses or is refused on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzShortcutMap, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            valid_text,
            "{}",
            "[]",
            "{\"alt+m\":\"/model\"}",
            "{\"ctrl+1\":{\"provider\":\"gateway\",\"model\":\"m\",\"effort\":\"high\",\"fast_mode\":true}}",
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
                try std.testing.expect(text_utils.isTerminalSafe(command.text()));
            },
            .select_model => |preset| {
                try std.testing.expect(preset.provider != .configured);
                try std.testing.expect(preset.model().len <= max_model_bytes);
                try durable_model.validate(preset.model());
                try std.testing.expect(text_utils.isTerminalSafe(preset.model()));
            },
        }
    }
}
