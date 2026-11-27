//! Decodes a mod's `mod.json` from bytes. This module does no I/O: the caller
//! reads the file. Every slice and the providers tree live in the arena the
//! caller passes in.

const std = @import("std");

pub const max_bytes: usize = 64 * 1024;
pub const max_mods: usize = 32;
pub const max_name_bytes: usize = 64;
pub const max_version_bytes: usize = 64;
pub const max_description_bytes: usize = 512;

const known_fields = [_][]const u8{ "name", "version", "description", "providers" };

pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    /// Empty when the file has no description.
    description: []const u8,
    /// The `providers` object, or null when the file has none. Its connections
    /// are decoded later by the configured provider registry.
    providers: ?std.json.Value,
};

pub const DecodeError = error{
    TooLarge,
    NotJson,
    NotObject,
    UnknownField,
    MissingName,
    BadName,
    MissingVersion,
    BadVersion,
    BadDescription,
    BadProviders,
} || std.mem.Allocator.Error;

/// Decodes one `mod.json`. Every slice and the providers tree live in `arena`.
pub fn decode(arena: std.mem.Allocator, bytes: []const u8) DecodeError!Manifest {
    if (bytes.len > max_bytes) return error.TooLarge;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotJson,
    };
    if (root != .object) return error.NotObject;
    const fields = root.object;
    try rejectUnknownFields(fields);
    return .{
        .name = try requiredName(fields),
        .version = try requiredVersion(fields),
        .description = try optionalDescription(fields),
        .providers = try optionalProviders(fields),
    };
}

/// The rule for a mod's name, its link name and its store folder prefix: 1 to
/// `max_name_bytes` bytes of `a-z`, `0-9` and `-`, not starting with `-`. The
/// name never holds a `.`, so it can never end in `.off`, the suffix a
/// disabled mod's folder uses.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    if (name[0] == '-') return false;
    for (name) |byte| {
        if (!isNameByte(byte)) return false;
    }
    return true;
}

/// One plain sentence for the person, for each refusal.
pub fn message(err: DecodeError) []const u8 {
    return switch (err) {
        error.TooLarge => std.fmt.comptimePrint("mod.json is larger than {d} KiB.", .{max_bytes / 1024}),
        error.NotJson => "mod.json is not valid JSON.",
        error.NotObject => "mod.json must hold one JSON object.",
        error.UnknownField => "mod.json has a field fx does not know.",
        error.MissingName => "mod.json needs a name.",
        error.BadName => std.fmt.comptimePrint(
            "The mod name uses lowercase letters, digits and hyphens only, does not start with a hyphen, and is at most {d} characters.",
            .{max_name_bytes},
        ),
        error.MissingVersion => "mod.json needs a version.",
        error.BadVersion => std.fmt.comptimePrint(
            "The mod version uses letters, digits, dots, plus signs and hyphens only, and is at most {d} characters.",
            .{max_version_bytes},
        ),
        error.BadDescription => std.fmt.comptimePrint(
            "The mod description must be plain text of at most {d} bytes, with no control or bidirectional formatting characters.",
            .{max_description_bytes},
        ),
        error.BadProviders => std.fmt.comptimePrint("The mod providers must be an object with at most {d} entries.", .{max_mods}),
        error.OutOfMemory => "fx ran out of memory while it read mod.json.",
    };
}

fn isNameByte(byte: u8) bool {
    return std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'z') or byte == '-';
}

fn validVersion(version: []const u8) bool {
    if (version.len == 0 or version.len > max_version_bytes) return false;
    for (version) |byte| {
        if (!isVersionByte(byte)) return false;
    }
    return true;
}

fn isVersionByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '+' or byte == '-';
}

/// Plain text: valid UTF-8 with no C0 or DEL control, no C1 control, and no
/// bidirectional formatting character. The text is refused, not escaped.
fn validDescription(text: []const u8) bool {
    if (text.len > max_description_bytes) return false;
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    var codepoints = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (codepoints.nextCodepoint()) |codepoint| {
        if (isRefusedCodepoint(codepoint)) return false;
    }
    return true;
}

fn isRefusedCodepoint(codepoint: u21) bool {
    return codepoint < 0x20 or
        codepoint == 0x7f or
        (codepoint >= 0x80 and codepoint <= 0x9f) or
        (codepoint >= 0x202a and codepoint <= 0x202e) or
        (codepoint >= 0x2066 and codepoint <= 0x2069);
}

fn rejectUnknownFields(fields: std.json.ObjectMap) DecodeError!void {
    var entries = fields.iterator();
    while (entries.next()) |entry| {
        if (!isKnownField(entry.key_ptr.*)) return error.UnknownField;
    }
}

fn isKnownField(key: []const u8) bool {
    for (known_fields) |known| {
        if (std.mem.eql(u8, key, known)) return true;
    }
    return false;
}

fn requiredName(fields: std.json.ObjectMap) DecodeError![]const u8 {
    const name = stringField(fields, "name") orelse return error.MissingName;
    if (!validName(name)) return error.BadName;
    return name;
}

fn requiredVersion(fields: std.json.ObjectMap) DecodeError![]const u8 {
    const version = stringField(fields, "version") orelse return error.MissingVersion;
    if (!validVersion(version)) return error.BadVersion;
    return version;
}

fn optionalDescription(fields: std.json.ObjectMap) DecodeError![]const u8 {
    const value = fields.get("description") orelse return "";
    if (value != .string or !validDescription(value.string)) return error.BadDescription;
    return value.string;
}

fn optionalProviders(fields: std.json.ObjectMap) DecodeError!?std.json.Value {
    const value = fields.get("providers") orelse return null;
    if (value != .object or value.object.count() > max_mods) return error.BadProviders;
    return value;
}

fn stringField(fields: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = fields.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn expectRefused(expected: DecodeError, text: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(expected, decode(arena_state.allocator(), text));
}

fn providersText(arena: std.mem.Allocator, count: usize) ![]const u8 {
    var text: []const u8 = "{\"name\":\"glm\",\"version\":\"1\",\"providers\":{";
    for (0..count) |i| {
        const separator = if (i == 0) "" else ",";
        text = try arena.print("{s}{s}\"p{d}\":{{}}", .{ text, separator, i });
    }
    return arena.print("{s}}}}}", .{text});
}

test "a minimal manifest decodes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const manifest = try decode(arena_state.allocator(), "{\"name\":\"glm\",\"version\":\"1.0.0\"}");
    try std.testing.expectEqualStrings("glm", manifest.name);
    try std.testing.expectEqualStrings("1.0.0", manifest.version);
    try std.testing.expectEqualStrings("", manifest.description);
    try std.testing.expect(manifest.providers == null);
}

test "a full manifest decodes with its description and providers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const manifest = try decode(arena_state.allocator(),
        \\{"name":"glm","version":"1.0.0-rc.1+build","description":"GLM coding plan",
        \\ "providers":{"glm":{"protocol":"openai","base_url":"https://example.com/v1"}}}
    );
    try std.testing.expectEqualStrings("1.0.0-rc.1+build", manifest.version);
    try std.testing.expectEqualStrings("GLM coding plan", manifest.description);
    try std.testing.expectEqual(@as(usize, 1), manifest.providers.?.object.count());
}

test "bytes over the size limit are refused before any parsing" {
    const text = try std.testing.allocator.alloc(u8, max_bytes + 1);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');
    try expectRefused(error.TooLarge, text);
}

test "bytes at the size limit still decode" {
    const text = try std.testing.allocator.alloc(u8, max_bytes);
    defer std.testing.allocator.free(text);
    const head = "{\"name\":\"glm\",\"version\":\"1\"}";
    @memset(text, ' ');
    @memcpy(text[0..head.len], head);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const manifest = try decode(arena_state.allocator(), text);
    try std.testing.expectEqualStrings("glm", manifest.name);
}

test "text that is not JSON, or has a duplicate key, is refused as not JSON" {
    try expectRefused(error.NotJson, "");
    try expectRefused(error.NotJson, "{\"name\":");
    try expectRefused(error.NotJson, "{\"name\":\"glm\",\"name\":\"glm\",\"version\":\"1\"}");
}

test "a top level that is not an object is refused" {
    try expectRefused(error.NotObject, "[\"glm\"]");
    try expectRefused(error.NotObject, "\"glm\"");
    try expectRefused(error.NotObject, "null");
}

test "a field fx does not know is refused" {
    try expectRefused(error.UnknownField, "{\"name\":\"glm\",\"version\":\"1\",\"extra\":true}");
}

test "a missing or non-string name is refused as missing" {
    try expectRefused(error.MissingName, "{\"version\":\"1\"}");
    try expectRefused(error.MissingName, "{\"name\":7,\"version\":\"1\"}");
}

test "a name that breaks the name rule is refused as bad" {
    try expectRefused(error.BadName, "{\"name\":\"\",\"version\":\"1\"}");
    try expectRefused(error.BadName, "{\"name\":\"-glm\",\"version\":\"1\"}");
    try expectRefused(error.BadName, "{\"name\":\"GLM\",\"version\":\"1\"}");
    try expectRefused(error.BadName, "{\"name\":\"glm.off\",\"version\":\"1\"}");
}

test "the name rule accepts 1 to 64 bytes of lowercase letters, digits and hyphens" {
    const name_64: [max_name_bytes]u8 = @splat('a');
    const name_65: [max_name_bytes + 1]u8 = @splat('a');
    try std.testing.expect(validName("a"));
    try std.testing.expect(validName("0-glm"));
    try std.testing.expect(validName(&name_64));
    try std.testing.expect(!validName(&name_65));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("-glm"));
    try std.testing.expect(!validName("GLM"));
    try std.testing.expect(!validName("gl.m"));
    try std.testing.expect(!validName("gl_m"));
}

test "a missing or non-string version is refused as missing" {
    try expectRefused(error.MissingVersion, "{\"name\":\"glm\"}");
    try expectRefused(error.MissingVersion, "{\"name\":\"glm\",\"version\":2}");
}

test "a version outside its rule is refused as bad" {
    try expectRefused(error.BadVersion, "{\"name\":\"glm\",\"version\":\"\"}");
    try expectRefused(error.BadVersion, "{\"name\":\"glm\",\"version\":\"1 2\"}");
    try expectRefused(error.BadVersion, "{\"name\":\"glm\",\"version\":\"1/2\"}");
    try expectRefused(error.BadVersion, "{\"name\":\"glm\",\"version\":\"\\u001b\"}");
}

test "the version rule accepts 1 to 64 bytes of letters, digits, dots, plus signs and hyphens" {
    const version_64: [max_version_bytes]u8 = @splat('1');
    const version_65: [max_version_bytes + 1]u8 = @splat('1');
    try std.testing.expect(validVersion("1.0.0-rc.1+build.7"));
    try std.testing.expect(validVersion(&version_64));
    try std.testing.expect(!validVersion(&version_65));
    try std.testing.expect(!validVersion(""));
    try std.testing.expect(!validVersion("1_0"));
}

test "the description rule refuses controls, bidi formatting and invalid UTF-8" {
    try std.testing.expect(validDescription("GLM coding plan, the café one"));
    try std.testing.expect(!validDescription("\x1b[31m"));
    try std.testing.expect(!validDescription("line\nbreak"));
    try std.testing.expect(!validDescription("\x7f"));
    try std.testing.expect(!validDescription("\u{85}"));
    try std.testing.expect(!validDescription("a\u{202e}b"));
    try std.testing.expect(!validDescription("a\u{2066}b"));
    try std.testing.expect(!validDescription("\xff"));
}

test "a description with a terminal control or a bidi character is refused" {
    try expectRefused(error.BadDescription, "{\"name\":\"glm\",\"version\":\"1\",\"description\":\"\\u001b[31mred\"}");
    try expectRefused(error.BadDescription, "{\"name\":\"glm\",\"version\":\"1\",\"description\":\"a\u{202e}b\"}");
}

test "a non-string description is refused" {
    try expectRefused(error.BadDescription, "{\"name\":\"glm\",\"version\":\"1\",\"description\":3}");
}

test "a description is kept at 512 bytes and refused at 513" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const at_limit: [max_description_bytes]u8 = @splat('a');
    const over_limit: [max_description_bytes + 1]u8 = @splat('a');
    const kept = try alloc.print("{{\"name\":\"glm\",\"version\":\"1\",\"description\":\"{s}\"}}", .{at_limit[0..]});
    const manifest = try decode(alloc, kept);
    try std.testing.expectEqual(max_description_bytes, manifest.description.len);
    const too_long = try alloc.print("{{\"name\":\"glm\",\"version\":\"1\",\"description\":\"{s}\"}}", .{over_limit[0..]});
    try std.testing.expectError(error.BadDescription, decode(alloc, too_long));
}

test "providers must be an object" {
    try expectRefused(error.BadProviders, "{\"name\":\"glm\",\"version\":\"1\",\"providers\":[]}");
    try expectRefused(error.BadProviders, "{\"name\":\"glm\",\"version\":\"1\",\"providers\":null}");
    try expectRefused(error.BadProviders, "{\"name\":\"glm\",\"version\":\"1\",\"providers\":\"glm\"}");
}

test "providers hold at most max_mods entries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const full = try decode(alloc, try providersText(alloc, max_mods));
    try std.testing.expectEqual(max_mods, full.providers.?.object.count());
    try std.testing.expectError(error.BadProviders, decode(alloc, try providersText(alloc, max_mods + 1)));
}

test "every refusal has a plain sentence for the person" {
    const refusals = [_]DecodeError{
        error.TooLarge,
        error.NotJson,
        error.NotObject,
        error.UnknownField,
        error.MissingName,
        error.BadName,
        error.MissingVersion,
        error.BadVersion,
        error.BadDescription,
        error.BadProviders,
        error.OutOfMemory,
    };
    for (refusals) |err| {
        const sentence = message(err);
        try std.testing.expect(sentence.len > 0);
        try std.testing.expect(sentence[sentence.len - 1] == '.');
    }
    try std.testing.expectEqualStrings("mod.json is larger than 64 KiB.", message(error.TooLarge));
    try std.testing.expectEqualStrings("mod.json has a field fx does not know.", message(error.UnknownField));
}

test "mod.json decodes or is refused on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzDecode, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{\"name\":\"glm\",\"version\":\"1.0.0\"}",
            "{\"name\":\"glm\",\"version\":\"1\",\"description\":\"GLM coding plan\",\"providers\":{}}",
            "{\"name\":\"-glm\",\"version\":\"1\"}",
            "{\"name\":\"glm\",\"version\":\"1\",\"description\":\"\\u001b[31m\"}",
            "{\"name\":\"glm\",\"name\":\"glm\",\"version\":\"1\"}",
            "[]",
        }) ++ @import("fuzz_corpus").mod_json.*),
    });
}

fn fuzzDecode(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buffer: [4096]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    const manifest = decode(arena_state.allocator(), bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    try std.testing.expect(validName(manifest.name));
    try std.testing.expect(validVersion(manifest.version));
    try std.testing.expect(validDescription(manifest.description));
}
