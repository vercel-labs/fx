//! Keyboard chords: one key with the modifiers a terminal report names.
//! This file is the one spelling of a chord, shared by config and the decoder.

const std = @import("std");

pub const Named = enum {
    enter,
    tab,
    backspace,
    space,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    delete,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const Key = union(enum) {
    char: u8,
    named: Named,
};

pub const Chord = struct {
    key: Key,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,

    pub fn eql(self: Chord, other: Chord) bool {
        return std.meta.eql(self, other);
    }

    /// Parses `ctrl+f`, `Alt+Shift+Left`, `ctrl+/`, or `ctrl++`: modifiers in
    /// any order, each named once, then a key. Text keys (letters, digits,
    /// punctuation, Enter, Tab, Backspace, Space) need ctrl, alt, or super, so a
    /// chord never takes plain typing.
    /// Parses a chord a profile may bind. A reserved key is refused here, so every
    /// caller that parses a binding (the setter and the loader) refuses it too.
    pub fn parse(text: []const u8) ?Chord {
        const chord = parseSyntax(text) orelse return null;
        if (chord.reservedReason() != null) return null;
        return chord;
    }

    /// Like `parse`, but names why a binding is refused.
    pub fn parseChecked(text: []const u8) ParseError!Chord {
        const chord = parseSyntax(text) orelse return error.Malformed;
        if (chord.reservedReason() != null) return error.Reserved;
        return chord;
    }

    /// Why fx keeps this key for itself, or null when a profile may bind it.
    pub fn reservedReason(self: Chord) ?[]const u8 {
        for (reserved) |entry| {
            if (entry.chord.eql(self)) return entry.why;
        }
        return null;
    }

    /// `ctrl+c is reserved for fx: interrupts a running turn and exits`, written into `buf`.
    pub fn reservedMessage(self: Chord, buf: []u8) ?[]const u8 {
        const why = self.reservedReason() orelse return null;
        const name = self.format(buf) orelse return null;
        var len = name.len;
        len = appendText(buf, len, " is reserved for fx: ") orelse return null;
        len = appendText(buf, len, why) orelse return null;
        return buf[0..len];
    }

    fn parseSyntax(text: []const u8) ?Chord {
        var modifier_text: []const u8 = "";
        var has_modifiers = false;
        var key: Key = undefined;
        if (std.mem.endsWith(u8, text, "++")) {
            key = .{ .char = '+' };
            modifier_text = text[0 .. text.len - 2];
            has_modifiers = true;
        } else if (std.mem.findScalarLast(u8, text, '+')) |separator| {
            key = parseKey(text[separator + 1 ..]) orelse return null;
            modifier_text = text[0..separator];
            has_modifiers = true;
        } else {
            key = parseKey(text) orelse return null;
        }
        var chord: Chord = .{ .key = key };
        if (has_modifiers) {
            var modifiers = std.mem.splitScalar(u8, modifier_text, '+');
            while (modifiers.next()) |name| {
                if (!setModifier(&chord, name)) return null;
            }
        }
        if (!chordIsAllowed(chord)) return null;
        return chord;
    }

    /// Writes the canonical spelling, `ctrl+alt+shift+super+key`, into `buf`.
    pub fn format(self: Chord, buf: []u8) ?[]const u8 {
        var len: usize = 0;
        if (self.ctrl) len = appendText(buf, len, "ctrl+") orelse return null;
        if (self.alt) len = appendText(buf, len, "alt+") orelse return null;
        if (self.shift) len = appendText(buf, len, "shift+") orelse return null;
        if (self.super) len = appendText(buf, len, "super+") orelse return null;
        len = switch (self.key) {
            .char => |char| appendText(buf, len, &[_]u8{char}) orelse return null,
            .named => |named| appendText(buf, len, @tagName(named)) orelse return null,
        };
        return buf[0..len];
    }
};

pub const ParseError = error{ Malformed, Reserved };

/// A key fx keeps for itself. Each has its own handler in fx, and a profile
/// binding it would shadow that handler. Composer editing keys (Ctrl+A, Ctrl+E,
/// Ctrl+F, Ctrl+K, and the rest) are not here: a bound chord takes them only
/// while the composer owns the keyboard, which is how Ctrl+F can switch fast mode.
pub const Reserved = struct {
    chord: Chord,
    why: []const u8,
};

pub const reserved = [_]Reserved{
    .{ .chord = .{ .key = .{ .char = 'c' }, .ctrl = true }, .why = "interrupts a running turn and exits" },
    .{ .chord = .{ .key = .{ .char = 'd' }, .ctrl = true }, .why = "exits fx" },
    .{ .chord = .{ .key = .{ .char = 'g' }, .ctrl = true }, .why = "restarts for an upgrade, or cancels the waiting restart" },
    .{ .chord = .{ .key = .{ .char = 'o' }, .ctrl = true }, .why = "opens the full transcript" },
    .{ .chord = .{ .key = .{ .char = 'p' }, .ctrl = true }, .why = "opens the model catalog" },
    .{ .chord = .{ .key = .{ .char = 't' }, .ctrl = true }, .why = "cycles the reasoning effort" },
    .{ .chord = .{ .key = .{ .char = 'x' }, .ctrl = true }, .why = "opens the agent list" },
    .{ .chord = .{ .key = .{ .named = .enter }, .ctrl = true }, .why = "submits the prompt" },
    .{ .chord = .{ .key = .{ .named = .enter }, .alt = true }, .why = "inserts a newline" },
};

fn chordIsAllowed(chord: Chord) bool {
    if (!needsTextModifier(chord.key)) return true;
    return chord.ctrl or chord.alt or chord.super;
}

// Text keys without a modifier are typing, so they never form a chord.
fn needsTextModifier(key: Key) bool {
    return switch (key) {
        .char => true,
        .named => |named| switch (named) {
            .enter, .tab, .backspace, .space => true,
            else => false,
        },
    };
}

fn setModifier(chord: *Chord, name: []const u8) bool {
    const flag: *bool = if (std.ascii.eqlIgnoreCase(name, "ctrl"))
        &chord.ctrl
    else if (std.ascii.eqlIgnoreCase(name, "alt"))
        &chord.alt
    else if (std.ascii.eqlIgnoreCase(name, "shift"))
        &chord.shift
    else if (std.ascii.eqlIgnoreCase(name, "super"))
        &chord.super
    else
        return false;
    if (flag.*) return false;
    flag.* = true;
    return true;
}

fn parseKey(text: []const u8) ?Key {
    if (text.len == 1 and isGraphic(text[0])) {
        return .{ .char = std.ascii.toLower(text[0]) };
    }
    for (std.meta.tags(Named)) |named| {
        if (std.ascii.eqlIgnoreCase(text, @tagName(named))) return .{ .named = named };
    }
    return null;
}

// Printable ASCII other than the space, which has its own name.
fn isGraphic(byte: u8) bool {
    return byte >= 0x21 and byte <= 0x7e;
}

fn appendText(buf: []u8, len: usize, text: []const u8) ?usize {
    if (buf.len - len < text.len) return null;
    @memcpy(buf[len..][0..text.len], text);
    return len + text.len;
}

/// The chord a raw control byte names: Ctrl+A through Ctrl+Z. The bytes that
/// also name Tab, Enter, Backspace, or a line feed have no chord, and neither
/// do ESC and the bytes 28 to 31, which terminals send for several keys.
pub fn fromControlByte(byte: u8) ?Chord {
    if (byte == 8 or byte == 9 or byte == 10 or byte == 13) return null;
    if (byte < 1 or byte > 26) return null;
    return .{ .key = .{ .char = byte + ('a' - 1) }, .ctrl = true };
}

/// ESC then a printable key is Alt+that key. An uppercase letter adds Shift.
/// ESC `[` and ESC `O` start CSI and SS3 reports, so they have no chord.
pub fn fromLegacyAlt(byte: u8) ?Chord {
    if (byte == ' ') return .{ .key = .{ .named = .space }, .alt = true };
    if (byte == '[' or byte == 'O') return null;
    if (!isGraphic(byte)) return null;
    return .{
        .key = .{ .char = std.ascii.toLower(byte) },
        .alt = true,
        .shift = std.ascii.isUpper(byte),
    };
}

/// A CSI u or modifyOtherKeys report of a printable key, Enter, Tab,
/// Backspace, or Space. A meta prefix has no chord, because it is ambiguous.
pub fn fromKitty(keycode: u16, modifiers: u16, meta_prefixed: bool) ?Chord {
    if (meta_prefixed) return null;
    const key = keyFromKeycode(keycode) orelse return null;
    return withModifiers(key, modifiers);
}

/// A CSI arrow, Home, or End, with or without modifiers: `ESC[1;5C` is
/// Ctrl+Right and `ESC[1;2D` is Shift+Left.
pub fn fromNavigationFinal(final: u8, modifiers: u16, meta_prefixed: bool) ?Chord {
    if (meta_prefixed) return null;
    const named: Named = switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        else => return null,
    };
    return withModifiers(.{ .named = named }, modifiers);
}

/// An SS3 key: arrows, Home, End, and F1 through F4 (`ESC O P` to `ESC O S`).
pub fn fromSs3Final(final: u8, meta_prefixed: bool) ?Chord {
    if (meta_prefixed) return null;
    const function: ?Named = switch (final) {
        'P' => .f1,
        'Q' => .f2,
        'R' => .f3,
        'S' => .f4,
        else => null,
    };
    if (function) |named| return withModifiers(.{ .named = named }, 0);
    return fromNavigationFinal(final, 0, false);
}

/// A CSI `~` key, with or without modifiers: `ESC[3;5~` is Ctrl+Delete and
/// `ESC[15~` is F5.
pub fn fromTildeCode(code: u16, modifiers: u16, meta_prefixed: bool) ?Chord {
    if (meta_prefixed) return null;
    const named: Named = switch (code) {
        1, 7 => .home,
        3 => .delete,
        4, 8 => .end,
        5 => .page_up,
        6 => .page_down,
        11 => .f1,
        12 => .f2,
        13 => .f3,
        14 => .f4,
        15 => .f5,
        17 => .f6,
        18 => .f7,
        19 => .f8,
        20 => .f9,
        21 => .f10,
        23 => .f11,
        24 => .f12,
        else => return null,
    };
    return withModifiers(.{ .named = named }, modifiers);
}

fn keyFromKeycode(keycode: u16) ?Key {
    if (keycode >= 0x80) return null;
    const byte: u8 = @intCast(keycode);
    if (isGraphic(byte)) return .{ .char = std.ascii.toLower(byte) };
    return switch (byte) {
        13 => .{ .named = .enter },
        9 => .{ .named = .tab },
        127 => .{ .named = .backspace },
        ' ' => .{ .named = .space },
        else => null,
    };
}

// Lock bits (Caps and Num) are not modifiers. Hyper and Meta have no chord
// spelling, so a report that names either has no chord.
fn withModifiers(key: Key, modifiers: u16) ?Chord {
    const bits = modifiers & 0x3F;
    if ((bits & 0x30) != 0) return null;
    const chord: Chord = .{
        .key = key,
        .shift = (bits & 1) != 0,
        .alt = (bits & 2) != 0,
        .ctrl = (bits & 4) != 0,
        .super = (bits & 8) != 0,
    };
    if (!chordIsAllowed(chord)) return null;
    return chord;
}

test "chord parses any order and case, and rejects typing and repeated modifiers" {
    try std.testing.expect(Chord.parse("Ctrl+F").?.eql(.{ .key = .{ .char = 'f' }, .ctrl = true }));
    try std.testing.expect(Chord.parse("shift+ctrl+f").?.eql(Chord.parse("CTRL+SHIFT+F").?));
    try std.testing.expect(Chord.parse("alt+shift+left").?.eql(.{ .key = .{ .named = .left }, .alt = true, .shift = true }));
    try std.testing.expect(Chord.parse("shift+left") != null);
    try std.testing.expect(Chord.parse("f5") != null);
    try std.testing.expect(Chord.parse("ctrl+/") != null);
    try std.testing.expect(Chord.parse("ctrl+super+1") != null);

    try std.testing.expect(Chord.parse("f") == null);
    try std.testing.expect(Chord.parse("shift+f") == null);
    try std.testing.expect(Chord.parse("shift+enter") == null);
    try std.testing.expect(Chord.parse("ctrl+") == null);
    try std.testing.expect(Chord.parse("+f") == null);
    try std.testing.expect(Chord.parse("ctrl+ctrl+f") == null);
    try std.testing.expect(Chord.parse("ctrl+ff") == null);
    try std.testing.expect(Chord.parse("hyper+f") == null);
}

test "reserved keys are refused by parse, and the chords next to them still bind" {
    for (reserved) |entry| {
        var buf: [64]u8 = undefined;
        const text = entry.chord.format(&buf).?;
        try std.testing.expect(Chord.parse(text) == null);
        try std.testing.expectError(error.Reserved, Chord.parseChecked(text));
    }
    try std.testing.expect(Chord.parse("ctrl+f") != null);
    try std.testing.expect(Chord.parse("ctrl+shift+c") != null);
    try std.testing.expect(Chord.parse("ctrl+2") != null);
    try std.testing.expect(Chord.parse("ctrl+k") != null);
    try std.testing.expect(Chord.parse("alt+m") != null);
    try std.testing.expectError(error.Malformed, Chord.parseChecked("f"));
}

test "reservedMessage names the chord and why fx keeps it" {
    var buf: [128]u8 = undefined;
    const ctrl_c: Chord = .{ .key = .{ .char = 'c' }, .ctrl = true };
    try std.testing.expectEqualStrings(
        "ctrl+c is reserved for fx: interrupts a running turn and exits",
        ctrl_c.reservedMessage(&buf).?,
    );
    const ctrl_f: Chord = .{ .key = .{ .char = 'f' }, .ctrl = true };
    try std.testing.expect(ctrl_f.reservedMessage(&buf) == null);
}

test "the decoder still names Ctrl+C, so the runtime can refuse it as a defense" {
    try std.testing.expect(fromControlByte(3).?.eql(.{ .key = .{ .char = 'c' }, .ctrl = true }));
    try std.testing.expect(fromControlByte(3).?.reservedReason() != null);
}

test "bare function and navigation keys round-trip, and bare text keys stay refused" {
    var buf: [32]u8 = undefined;
    for (std.meta.tags(Named)) |named| {
        const chord: Chord = .{ .key = .{ .named = named } };
        const text = chord.format(&buf).?;
        if (needsTextModifier(chord.key)) {
            try std.testing.expect(Chord.parse(text) == null);
        } else {
            try std.testing.expect(Chord.parse(text).?.eql(chord));
        }
    }
    try std.testing.expect(Chord.parse("f12").?.eql(.{ .key = .{ .named = .f12 } }));
    try std.testing.expect(Chord.parse("left").?.eql(.{ .key = .{ .named = .left } }));
    try std.testing.expect(Chord.parse("enter") == null);
}

test "chord formats its canonical spelling and round-trips the plus key" {
    var buf: [32]u8 = undefined;
    const parsed = Chord.parse("Shift+Ctrl+F").?;
    try std.testing.expectEqualStrings("ctrl+shift+f", parsed.format(&buf).?);
    try std.testing.expectEqualStrings("alt+page_down", Chord.parse("alt+page_down").?.format(&buf).?);
    const plus = Chord.parse("ctrl++").?;
    try std.testing.expectEqualStrings("ctrl++", plus.format(&buf).?);
    try std.testing.expect(Chord.parse("ctrl++").?.eql(plus));
    var short: [4]u8 = undefined;
    try std.testing.expect(parsed.format(&short) == null);
}

test "control bytes name Ctrl+letter except the bytes that also name a key" {
    try std.testing.expect(fromControlByte(6).?.eql(.{ .key = .{ .char = 'f' }, .ctrl = true }));
    try std.testing.expect(fromControlByte(1) != null);
    try std.testing.expect(fromControlByte(26) != null);
    for ([_]u8{ 0, 8, 9, 10, 13, 27, 28, 31, 127 }) |byte| {
        try std.testing.expect(fromControlByte(byte) == null);
    }
}

test "legacy ESC plus a printable key is Alt, with Shift for uppercase" {
    try std.testing.expect(fromLegacyAlt('m').?.eql(.{ .key = .{ .char = 'm' }, .alt = true }));
    try std.testing.expect(fromLegacyAlt('M').?.eql(.{ .key = .{ .char = 'm' }, .alt = true, .shift = true }));
    try std.testing.expect(fromLegacyAlt('/').?.eql(.{ .key = .{ .char = '/' }, .alt = true }));
    try std.testing.expect(fromLegacyAlt('[') == null);
    try std.testing.expect(fromLegacyAlt('O') == null);
    try std.testing.expect(fromLegacyAlt('\r') == null);
}

test "CSI u reports name the exact chord and near misses have none" {
    try std.testing.expect(fromKitty(102, 4, false).?.eql(.{ .key = .{ .char = 'f' }, .ctrl = true }));
    try std.testing.expect(fromKitty(102, 12, false).?.eql(.{ .key = .{ .char = 'f' }, .ctrl = true, .super = true }));
    try std.testing.expect(fromKitty(102, 68, false).?.eql(.{ .key = .{ .char = 'f' }, .ctrl = true }));
    try std.testing.expect(fromKitty(13, 4, false).?.eql(.{ .key = .{ .named = .enter }, .ctrl = true }));
    try std.testing.expect(fromKitty(47, 4, false).?.eql(.{ .key = .{ .char = '/' }, .ctrl = true }));

    try std.testing.expect(fromKitty(102, 4, true) == null);
    try std.testing.expect(fromKitty(102, 0, false) == null);
    try std.testing.expect(fromKitty(102, 1, false) == null);
    try std.testing.expect(fromKitty(102, 20, false) == null);
    try std.testing.expect(fromKitty(102, 48, false) == null);
    try std.testing.expect(fromKitty(57400, 4, false) == null);
}

test "navigation, SS3, and tilde keys carry their modifiers and function keys" {
    try std.testing.expect(fromNavigationFinal('C', 4, false).?.eql(.{ .key = .{ .named = .right }, .ctrl = true }));
    try std.testing.expect(fromNavigationFinal('D', 1, false).?.eql(.{ .key = .{ .named = .left }, .shift = true }));
    try std.testing.expect(fromNavigationFinal('A', 0, false).?.eql(.{ .key = .{ .named = .up } }));
    try std.testing.expect(fromNavigationFinal('C', 4, true) == null);
    try std.testing.expect(fromSs3Final('P', false).?.eql(.{ .key = .{ .named = .f1 } }));
    try std.testing.expect(fromSs3Final('S', false).?.eql(.{ .key = .{ .named = .f4 } }));
    try std.testing.expect(fromTildeCode(3, 4, false).?.eql(.{ .key = .{ .named = .delete }, .ctrl = true }));
    try std.testing.expect(fromTildeCode(3, 0, false).?.eql(.{ .key = .{ .named = .delete } }));
    try std.testing.expect(fromTildeCode(15, 0, false).?.eql(.{ .key = .{ .named = .f5 } }));
    try std.testing.expect(fromTildeCode(24, 2, false).?.eql(.{ .key = .{ .named = .f12 }, .alt = true }));
    try std.testing.expect(fromTildeCode(200, 0, false) == null);
}
