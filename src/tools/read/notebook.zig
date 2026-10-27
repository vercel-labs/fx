//! Jupyter notebooks as text: each cell under a `# %% [kind] cell:N` marker,
//! as proto writes them, followed by a short summary of its outputs. Stream
//! and plain-text outputs keep their first lines; images and other rich
//! outputs are named, not inlined.
const std = @import("std");

const Allocator = std.mem.Allocator;

const output_lines_kept: usize = 6;
const output_line_bytes: usize = 200;

pub fn isNotebookPath(path: []const u8) bool {
    return path.len > 6 and std.ascii.eqlIgnoreCase(path[path.len - 6 ..], ".ipynb");
}

/// Renders notebook JSON as cell text. Caller owns the result.
pub fn render(alloc: Allocator, json_bytes: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_bytes, .{}) catch return error.InvalidNotebook;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidNotebook;
    const cells_value = parsed.value.object.get("cells") orelse return error.InvalidNotebook;
    if (cells_value != .array) return error.InvalidNotebook;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    const language = notebookLanguage(parsed.value.object);
    try w.print("Notebook · {d} cells{s}{s}\n", .{ cells_value.array.items.len, if (language.len > 0) " · " else "", language });
    for (cells_value.array.items, 0..) |cell, index| {
        if (cell != .object) return error.InvalidNotebook;
        const kind = stringField(cell.object, "cell_type") orelse "raw";
        try w.print("# %% [{s}] cell:{d}", .{ kind, index });
        if (cell.object.get("execution_count")) |count| if (count == .integer) try w.print(" · [{d}]", .{count.integer});
        try w.writeByte('\n');
        try writeSource(w, cell.object.get("source"));
        if (cell.object.get("outputs")) |outputs| if (outputs == .array) {
            for (outputs.array.items) |output| if (output == .object) try writeOutput(w, output.object);
        };
    }
    return out.toOwnedSlice();
}

fn notebookLanguage(root: std.json.ObjectMap) []const u8 {
    const metadata = root.get("metadata") orelse return "";
    if (metadata != .object) return "";
    const info = metadata.object.get("language_info") orelse return "";
    if (info != .object) return "";
    return stringField(info.object, "name") orelse "";
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

/// Writes a cell source, a string or a list of line strings, ending in a newline.
fn writeSource(w: *std.Io.Writer, source: ?std.json.Value) !void {
    const value = source orelse return;
    var wrote_any = false;
    var last_newline = true;
    switch (value) {
        .string => |text| {
            try w.writeAll(text);
            wrote_any = text.len > 0;
            last_newline = text.len == 0 or text[text.len - 1] == '\n';
        },
        .array => |items| for (items.items) |item| if (item == .string) {
            try w.writeAll(item.string);
            if (item.string.len > 0) {
                wrote_any = true;
                last_newline = item.string[item.string.len - 1] == '\n';
            }
        },
        else => {},
    }
    if (wrote_any and !last_newline) try w.writeByte('\n');
}

fn writeOutput(w: *std.Io.Writer, output: std.json.ObjectMap) !void {
    const kind = stringField(output, "output_type") orelse return;
    if (std.mem.eql(u8, kind, "stream")) {
        try w.print("# > {s}\n", .{stringField(output, "name") orelse "stream"});
        try writeQuoted(w, output.get("text"));
        return;
    }
    if (std.mem.eql(u8, kind, "error")) {
        try w.print("# > error {s}: {s}\n", .{ stringField(output, "ename") orelse "Error", stringField(output, "evalue") orelse "" });
        return;
    }
    const data_value = output.get("data") orelse return;
    if (data_value != .object) return;
    const data = data_value.object;
    try w.print("# > {s}", .{kind});
    var it = data.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "text/plain")) continue;
        try w.print("{s}{s}", .{ if (first) " · " else ", ", entry.key_ptr.* });
        first = false;
    }
    try w.writeByte('\n');
    if (data.get("text/plain")) |text| try writeQuoted(w, text);
}

/// The first lines of an output text, each prefixed `#   `.
fn writeQuoted(w: *std.Io.Writer, value: ?std.json.Value) !void {
    var joined: [8192]u8 = undefined;
    var len: usize = 0;
    const v = value orelse return;
    switch (v) {
        .string => |text| len = copyInto(&joined, 0, text),
        .array => |items| for (items.items) |item| if (item == .string) {
            len = copyInto(&joined, len, item.string);
        },
        else => return,
    }
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, joined[0..len], "\n"), '\n');
    var shown: usize = 0;
    var hidden: usize = 0;
    while (lines.next()) |line| {
        if (shown == output_lines_kept) {
            hidden += 1;
            continue;
        }
        shown += 1;
        const clipped = if (line.len > output_line_bytes) line[0..output_line_bytes] else line;
        try w.print("#   {s}{s}\n", .{ clipped, if (line.len > output_line_bytes) "…" else "" });
    }
    if (hidden > 0) try w.print("#   … {d} more lines\n", .{hidden});
}

fn copyInto(buf: []u8, at: usize, text: []const u8) usize {
    const n = @min(buf.len - at, text.len);
    @memcpy(buf[at..][0..n], text[0..n]);
    return at + n;
}

test "notebook cells render with markers and summarized outputs" {
    const alloc = std.testing.allocator;
    const json =
        \\{"metadata":{"language_info":{"name":"python"}},"nbformat":4,"nbformat_minor":5,"cells":[
        \\{"cell_type":"markdown","metadata":{},"source":["# Title\n","Intro"]},
        \\{"cell_type":"code","execution_count":3,"metadata":{},"source":"print('hi')\n1+1",
        \\ "outputs":[{"output_type":"stream","name":"stdout","text":["hi\n"]},
        \\ {"output_type":"execute_result","execution_count":3,"data":{"text/plain":["2"],"image/png":"AAAA"},"metadata":{}},
        \\ {"output_type":"error","ename":"ValueError","evalue":"bad","traceback":[]}]}
        \\]}
    ;
    const text = try render(alloc, json);
    defer alloc.free(text);
    try std.testing.expectEqualStrings(
        \\Notebook · 2 cells · python
        \\# %% [markdown] cell:0
        \\# Title
        \\Intro
        \\# %% [code] cell:1 · [3]
        \\print('hi')
        \\1+1
        \\# > stdout
        \\#   hi
        \\# > execute_result · image/png
        \\#   2
        \\# > error ValueError: bad
        \\
    , text);
    try std.testing.expectError(error.InvalidNotebook, render(alloc, "{\"cells\":3}"));
}
