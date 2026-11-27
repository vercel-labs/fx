const std = @import("std");

/// Returns the human-readable body from established tool result envelopes.
/// Malformed or unfamiliar output stays literal so presentation never hides
/// tool evidence it cannot identify safely.
pub fn contentForDisplay(body: []const u8) []const u8 {
    var rest = body;
    if (std.mem.startsWith(u8, rest, "<path>")) {
        const path_close = std.mem.find(u8, rest, "</path>") orelse return body;
        rest = std.mem.trimStart(u8, rest[path_close + "</path>".len ..], "\r\n");
    }
    if (!std.mem.startsWith(u8, rest, "<content>")) return body;
    rest = std.mem.trimStart(u8, rest["<content>".len..], "\r\n");
    if (!std.mem.endsWith(u8, rest, "</content>")) return body;
    return std.mem.trimEnd(u8, rest[0 .. rest.len - "</content>".len], "\r\n");
}

/// What a read_file result says between its `<path>` and its `<content>`.
const read_path_end = "</path>\n<content>";

/// The file a read_file result says it read, such as "src/main.zig" in
/// "<path>src/main.zig</path>\n<content>...": the file core resolved the
/// call's path to, with symlinks followed, relative to the workspace for a
/// file in it. Null for any other text, and when the result holds the mark
/// after the path more than once, as a file name or the file's text can, so
/// the path it names is not sure.
pub fn readPathOfResult(output: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, output, "<path>")) return null;
    const end = std.mem.find(u8, output, read_path_end) orelse return null;
    if (std.mem.find(u8, output[end + 1 ..], read_path_end) != null) return null;
    const path = output["<path>".len..end];
    return if (path.len == 0) null else path;
}

test "a read_file result names the file it read only when its path is sure" {
    try std.testing.expectEqualStrings("src/main.zig", readPathOfResult("<path>src/main.zig</path>\n<content>\n1\tconst a = 1;\n</content>").?);
    try std.testing.expectEqualStrings("/private/tmp/notes (draft).md", readPathOfResult("<path>/private/tmp/notes (draft).md</path>\n<content>binary or non-utf8 file omitted (3 bytes)</content>").?);
    for ([_][]const u8{
        "plain output",
        "<path></path>\n<content>\n</content>",
        "<path>src/main.zig</path>",
        // A file named to fake the mark, or text that repeats it.
        "<path>safe.md</path>\n<content>x.md</path>\n<content>\n1\ta\n</content>",
        "<path>a.md</path>\n<content>\n1\t</path>\n<content>\n</content>",
    }) |output| {
        try std.testing.expect(readPathOfResult(output) == null);
    }
}

test "contentForDisplay unwraps path and content result" {
    try std.testing.expectEqualStrings(
        "1\talpha\n2\tbeta",
        contentForDisplay("<path>README.md</path>\n<content>\n1\talpha\n2\tbeta\n</content>"),
    );
}

test "contentForDisplay preserves unknown or malformed output" {
    const raw = "<path>README.md</path>\n<content>missing close";
    try std.testing.expectEqualStrings(raw, contentForDisplay(raw));
    try std.testing.expectEqualStrings("plain output", contentForDisplay("plain output"));
}
