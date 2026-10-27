//! read_file end to end through dispatch, one test per target kind, with
//! fixtures generated in the test.
const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const read_file = @import("../filesystem/read_file.zig");
const archive = @import("archive.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;

const tool = tool_dispatch.Tool{
    .name = "read_file",
    .description = "Read file dispatch test fixture.",
    .model_schema = .{ .name = "read_file", .description = "Read file dispatch test fixture." },
    .executor_kind = .read_file,
    .activity_kind = .read,
    .permission_target_kind = .path_existing,
    .decode = read_file.decode,
    .validate = read_file.validate,
    .call = read_file.call,
    .reads_only_fn = read_file.readsOnly,
    .irreversible_fn = read_file.isIrreversible,
};

fn read(alloc: Allocator, root: []const u8, path: []const u8) !tool_dispatch.DispatchResult {
    var args: std.Io.Writer.Allocating = .init(alloc);
    defer args.deinit();
    try std.json.Stringify.value(.{ .path = path }, .{}, &args.writer);
    return tool_dispatch.dispatchToolCall(.{ .allocator = alloc, .permission_mode = .auto, .workspace_root = root }, .{ .tools = &.{tool} }, .{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = args.written(),
    });
}

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,

    fn init(alloc: Allocator) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".") };
    }

    fn deinit(self: *Fixture, alloc: Allocator) void {
        alloc.free(self.root);
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, path: []const u8, data: []const u8) !void {
        if (std.Io.Dir.path.dirname(path)) |parent| try self.tmp.dir.createDirPath(testing.io, parent);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.find(u8, haystack, needle) == null) {
        std.debug.print("missing {s} in:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedEqual;
    }
}

test "read_file path selectors pick ranges and raw text" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    try fx.write("a.txt", "one\ntwo\nthree\nfour\nfive\n");

    const ranged = try read(alloc, fx.root, "a.txt:2-3");
    defer ranged.deinit(alloc);
    try testing.expectEqualStrings("<path>a.txt</path>\n<content>\n2\ttwo\n3\tthree\n... [showing 2 of 5 lines; use start_line/line_count to read more.]\n</content>", ranged.body);

    const multi = try read(alloc, fx.root, "a.txt:1-1,4+1");
    defer multi.deinit(alloc);
    try expectContains(multi.body, "1\tone\n4\tfour\n... [showing 2 of 5 lines");

    const raw = try read(alloc, fx.root, "a.txt:raw:4-");
    defer raw.deinit(alloc);
    try expectContains(raw.body, "<content>\nfour\nfive\n");
}

test "read_file lists a directory" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    try fx.write("src/main.zig", "x");
    try fx.write("README.md", "x");
    const result = try read(alloc, fx.root, "src");
    defer result.deinit(alloc);
    try testing.expectEqual(.success, result.status);
    try expectContains(result.body, "Directory src · 1 file, 0 folders");
    try expectContains(result.body, "main.zig");
}

test "read_file reads a zip member and lists a tar" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    const zip = try archive.buildStoredZip(alloc, &.{ .{ "docs/guide.md", "# Guide\nstep 1\nstep 2\n" }, .{ "nb.ipynb", "{\"cells\":[{\"cell_type\":\"code\",\"source\":\"x = 1\"}]}" } });
    defer alloc.free(zip);
    try fx.write("bundle.zip", zip);

    const member = try read(alloc, fx.root, "bundle.zip:docs/guide.md:2");
    defer member.deinit(alloc);
    try expectContains(member.body, "<path>bundle.zip:docs/guide.md</path>\n<content>\n2\tstep 1\n3\tstep 2\n");

    const slash = try read(alloc, fx.root, "bundle.zip/nb.ipynb");
    defer slash.deinit(alloc);
    try expectContains(slash.body, "# %% [code] cell:0");

    const missing = try read(alloc, fx.root, "bundle.zip:nope.txt");
    defer missing.deinit(alloc);
    try testing.expectEqual(.failure, missing.status);

    const tar = try archive.buildTar(alloc, &.{.{ "a/b.txt", "b\n" }});
    defer alloc.free(tar);
    try fx.write("t.tar", tar);
    const listing = try read(alloc, fx.root, "t.tar");
    defer listing.deinit(alloc);
    try expectContains(listing.body, "Archive t.tar · 1 member");
}

test "read_file renders notebooks unless raw" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    try fx.write("n.ipynb", "{\"cells\":[{\"cell_type\":\"markdown\",\"source\":[\"# Hi\"]}]}");
    const cells = try read(alloc, fx.root, "n.ipynb");
    defer cells.deinit(alloc);
    try expectContains(cells.body, "2\t# %% [markdown] cell:0\n3\t# Hi\n");
    const raw = try read(alloc, fx.root, "n.ipynb:raw");
    defer raw.deinit(alloc);
    try expectContains(raw.body, "{\"cells\"");
}

test "read_file summarizes a long code file read without a range" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    var source: std.Io.Writer.Allocating = .init(alloc);
    defer source.deinit();
    for (0..90) |i| try source.writer.print("fn f{d}() void {{\n    a();\n    b();\n    c();\n    d();\n}}\n", .{i});
    try fx.write("big.zig", source.written());

    const folded = try read(alloc, fx.root, "big.zig");
    defer folded.deinit(alloc);
    try expectContains(folded.body, "1-6\tfn f0() void { … }\n7-12\tfn f1() void { … }\n");
    try expectContains(folded.body, "[structural summary: 180 of 540 lines shown");
    try testing.expect(!folded.tool_result_memory.?.model_view_covers_full_file.?);

    const ranged = try read(alloc, fx.root, "big.zig:1-3");
    defer ranged.deinit(alloc);
    try expectContains(ranged.body, "2\t    a();");
}

test "read_file permission targets drop selectors and map URLs to web_fetch domains" {
    const permissions = @import("../../core/permissions/permissions.zig");
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit(alloc);
    try fx.write("app.db", "x");
    try fx.write("bundle.zip", "x");
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_][2][]const u8{
        .{ "{\"path\":\"https://Example.com/docs:3-9\"}", "domain:example.com" },
        .{ "{\"path\":\"app.db:users:7\"}", "app.db" },
        .{ "{\"path\":\"bundle.zip:src/a.txt:1-4\"}", "bundle.zip" },
        .{ "{\"path\":\"skill://review/notes.md\"}", "skill://review/notes.md" },
    };
    for (cases) |case| {
        const target = try permissions.permissionTargetForCall(arena, fx.root, .{ .id = "1", .name = "read_file", .arguments_json = case[0] }, .path_existing);
        try testing.expect(std.mem.endsWith(u8, target, case[1]));
    }
}
