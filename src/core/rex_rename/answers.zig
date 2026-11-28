//! Reads the JSON that `rex` prints. Each input is outside bytes: a reader
//! returns null or false for anything it does not expect, and never fails.

const std = @import("std");
const plan = @import("plan.zig");

/// `rex skill status --json` lists a few agents, so its answer is small.
pub const max_status_bytes = 64 * 1024;
/// `rex session inspect --json` describes every window and pane of a session.
pub const max_inspect_bytes = 1024 * 1024;

/// True when `rex skill status --json` says that at least one agent names its
/// session. Rex stores that choice in the files `rex skill setup` installs.
/// `scratch` holds the parse and can be freed after the call.
pub fn sessionNamingOn(scratch: std.mem.Allocator, status_json: []const u8) bool {
    const root = parseObject(scratch, status_json) orelse return false;
    const harnesses = root.get("harnesses") orelse return false;
    if (harnesses != .array) return false;
    for (harnesses.array.items) |harness| {
        if (harness != .object) continue;
        const naming = harness.object.get("session_naming") orelse continue;
        if (naming == .bool and naming.bool) return true;
    }
    return false;
}

/// The session's label in `rex session inspect --json`, copied into `out`.
/// Null when the label is missing, not a string, or longer than Rex allows.
/// `scratch` holds the parse and can be freed after the call.
pub fn sessionLabel(scratch: std.mem.Allocator, inspect_json: []const u8, out: *[plan.max_label_bytes]u8) ?[]const u8 {
    const root = parseObject(scratch, inspect_json) orelse return null;
    const label = root.get("label") orelse return null;
    if (label != .string) return null;
    const text = label.string;
    if (text.len > out.len) return null;
    if (!std.unicode.utf8ValidateSlice(text)) return null;
    @memcpy(out[0..text.len], text);
    return out[0..text.len];
}

/// The top-level object of `bytes`, or null for anything else. `std.json`
/// keeps its own stack, so deep nesting cannot overflow fx's.
fn parseObject(scratch: std.mem.Allocator, bytes: []const u8) ?std.json.ObjectMap {
    const value = std.json.parseFromSliceLeaky(std.json.Value, scratch, bytes, .{}) catch return null;
    return if (value == .object) value.object else null;
}

const status_on =
    \\{"scope":"user","harnesses":[
    \\{"id":"claude","detected":true,"session_naming":false,"items":[]},
    \\{"id":"pi","detected":false,"session_naming":true,"items":[{"kind":"skill","state":"current"}]}]}
;
const status_off =
    \\{"scope":"user","harnesses":[{"id":"claude","detected":true,"session_naming":false},{"id":"codex","detected":true}]}
;

test "the rename option is on when one agent in Rex's status names sessions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(sessionNamingOn(a, status_on));
    try std.testing.expect(!sessionNamingOn(a, status_off));
    try std.testing.expect(!sessionNamingOn(a, "{\"harnesses\":[]}"));
    try std.testing.expect(!sessionNamingOn(a, "{\"harnesses\":[{\"session_naming\":\"true\"}]}"));
    try std.testing.expect(!sessionNamingOn(a, "{\"harnesses\":{\"session_naming\":true}}"));
    try std.testing.expect(!sessionNamingOn(a, "{\"session_naming\":true}"));
    try std.testing.expect(!sessionNamingOn(a, "[]"));
    try std.testing.expect(!sessionNamingOn(a, ""));
    try std.testing.expect(!sessionNamingOn(a, "Error: unknown command \"skill\" for \"rex\""));
    try std.testing.expect(!sessionNamingOn(a, status_on[0 .. status_on.len - 2]));
}

test "the session label comes from the top of Rex's session view" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: [plan.max_label_bytes]u8 = undefined;
    const view =
        \\{"revision":1,"session_id":"session:1","label":"morning-atoll","windows":[
        \\{"window_id":"window:1","label":"Window 1","layers":[{"blocks":[{"label":"shell"}]}]}]}
    ;
    try std.testing.expectEqualStrings("morning-atoll", sessionLabel(a, view, &out).?);
    try std.testing.expectEqualStrings("caf\u{e9} \"x\"", sessionLabel(a, "{\"label\":\"caf\\u00e9 \\\"x\\\"\"}", &out).?);
    // Only the session's own label counts, not a window's or a pane's.
    try std.testing.expect(sessionLabel(a, "{\"windows\":[{\"label\":\"Window 1\"}]}", &out) == null);
    try std.testing.expect(sessionLabel(a, "{\"label\":7}", &out) == null);
    try std.testing.expect(sessionLabel(a, "[\"label\"]", &out) == null);
    try std.testing.expect(sessionLabel(a, "{\"label\":\"x\"", &out) == null);
    try std.testing.expect(sessionLabel(a, "{\"label\":\"\\ud800\"}", &out) == null);
}

test "a session label longer than Rex allows is refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: [plan.max_label_bytes]u8 = undefined;
    var long: [plan.max_label_bytes + 20]u8 = undefined;
    const prefix = "{\"label\":\"";
    @memcpy(long[0..prefix.len], prefix);
    @memset(long[prefix.len .. long.len - 2], 'z');
    @memcpy(long[long.len - 2 ..], "\"}");
    try std.testing.expect(sessionLabel(arena.allocator(), &long, &out) == null);
}

fn fuzzAnswers(_: void, smith: *std.testing.Smith) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const bytes = buffer[0..@intCast(smith.slice(&buffer))];
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = sessionNamingOn(arena.allocator(), bytes);
    var out: [plan.max_label_bytes]u8 = undefined;
    if (sessionLabel(arena.allocator(), bytes, &out)) |label| {
        // A label fx reads came from the bytes, so it is valid text and fits.
        try std.testing.expect(label.len <= plan.max_label_bytes);
        try std.testing.expect(std.unicode.utf8ValidateSlice(label));
    }
}

test "Rex answer readers tolerate arbitrary bytes" {
    try std.testing.fuzz({}, fuzzAnswers, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            status_on,
            "{\"label\":\"morning-atoll\",\"windows\":[]}",
            "{\"label\":\"\\ud800\"}",
            "{\"harnesses\":[[[[[[[[[[[[[[[[[[[[",
            "\xff\x00{",
        }) ++ @import("fuzz_corpus").rex_rename_answers.*),
    });
}
