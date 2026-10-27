//! `proto-fx read <target> [--json]`: runs the read_file tool once from the
//! current folder and prints what the model would read. The person at the
//! terminal is the authority, so no permission prompt applies; URL reads
//! still pass the web_fetch URL policy.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const output_contracts = @import("../output/output_contracts.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const builtin_tools = @import("../../builtins/tools.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    target: []const u8,
    format: output_contracts.OutputFormat = .text,
};

pub const ParseError = error{ MissingReadTarget, InvalidReadOption };

/// `--` ends option parsing, so a target may start with a dash.
pub fn parseArgs(args: []const [:0]const u8) ParseError!Options {
    var options: Options = .{ .target = "" };
    var options_done = false;
    for (args) |arg_z| {
        const arg: []const u8 = arg_z;
        if (!options_done and std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--")) {
                options_done = true;
            } else if (std.mem.eql(u8, arg, "--json")) {
                options.format = .json;
            } else return error.InvalidReadOption;
            continue;
        }
        if (options.target.len > 0) return error.InvalidReadOption;
        options.target = arg;
    }
    if (options.target.len == 0) return error.MissingReadTarget;
    return options;
}

pub const Result = struct {
    output: []u8,
    format: output_contracts.OutputFormat,
    succeeded: bool,
};

/// Reads `options.target` relative to `workspace_root`. Caller owns `output`.
pub fn run(alloc: Allocator, options: Options, workspace_root: []const u8) !Result {
    const spec = builtin_tools.read_file;
    const ctx: tool_dispatch.DispatchContext = .{
        .allocator = alloc,
        .permission_mode = .yolo,
        .workspace_root = workspace_root,
    };
    var args: std.Io.Writer.Allocating = .init(alloc);
    defer args.deinit();
    try std.json.Stringify.value(.{ .path = options.target }, .{}, &args.writer);

    const result: tool_dispatch.ToolResult = switch (try spec.decode(ctx, args.written())) {
        .failure => |body| .{ .failure = body },
        .input => |input| blk: {
            defer input.deinit(alloc);
            if (spec.validate) |validate| if (try validate(ctx, input)) |message| break :blk .{ .failure = message };
            break :blk try spec.call(ctx, input);
        },
    };
    defer result.deinit(alloc);

    var images: std.ArrayList(output_contracts.ReadSnapshot.Image) = .empty;
    defer images.deinit(alloc);
    const content, const ok = switch (result) {
        .success => |body| .{ body, true },
        .failure => |body| .{ body, false },
        .rich => |rich| blk: {
            for (rich.images) |image| try images.append(alloc, .{ .mime_type = image.mime_type, .data_bytes = image.data.len });
            break :blk .{ rich.text, !rich.is_error };
        },
    };
    const snapshot = output_contracts.ReadSnapshot{ .target = options.target, .ok = ok, .content = content, .images = images.items };
    return .{ .output = try snapshot.render(alloc, options.format), .format = options.format, .succeeded = ok };
}

/// The current folder, the workspace a CLI read resolves against. Caller owns it.
pub fn currentWorkspace(alloc: Allocator) ![]u8 {
    return io_mod.realpathAlloc(alloc, ".");
}

test "read arguments take one target and --json" {
    const options = try parseArgs(&.{ "--json", "src/main.zig:1-5" });
    try std.testing.expectEqualStrings("src/main.zig:1-5", options.target);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, options.format);
    try std.testing.expectEqualStrings("-odd", (try parseArgs(&.{ "--", "-odd" })).target);
    try std.testing.expectError(error.MissingReadTarget, parseArgs(&.{"--json"}));
    try std.testing.expectError(error.InvalidReadOption, parseArgs(&.{ "a", "b" }));
    try std.testing.expectError(error.InvalidReadOption, parseArgs(&.{ "a", "--fast" }));
}

test "read runs the tool and renders one snapshot" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "alpha\nbeta\n" });
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const text = try run(alloc, .{ .target = "notes.txt:2" }, root);
    defer alloc.free(text.output);
    try std.testing.expect(text.succeeded);
    try std.testing.expectEqualStrings("<path>notes.txt</path>\n<content>\n2\tbeta\n... [showing 1 of 2 lines; use start_line/line_count to read more.]\n</content>\n", text.output);
    const missing = try run(alloc, .{ .target = "nope.txt", .format = .json }, root);
    defer alloc.free(missing.output);
    try std.testing.expect(!missing.succeeded);
    try std.testing.expect(std.mem.startsWith(u8, missing.output, "{\"target\":\"nope.txt\",\"ok\":false,"));
}
