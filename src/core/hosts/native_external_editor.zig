const std = @import("std");
const command_lex = @import("../shell_command/command_lex.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const host = @import("host.zig");

const Allocator = std.mem.Allocator;
const EditResult = host.ExternalEditor.EditResult;
const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);

pub const external_editor: host.ExternalEditor = .{ .edit_fn = edit };

fn edit(
    _: ?*anyopaque,
    alloc: Allocator,
    seed: []const u8,
    max_bytes: usize,
) Allocator.Error!EditResult {
    const command = configuredEditorCommand() orelse {
        return .{ .failed = .{ .reason = .missing_editor } };
    };
    return editWithCommand(alloc, command, temporaryRoot(), seed, max_bytes);
}

fn configuredEditorCommand() ?[]const u8 {
    return selectEditorCommand(
        io_mod.getenv("VISUAL"),
        io_mod.getenv("EDITOR"),
    );
}

fn selectEditorCommand(visual: ?[]const u8, editor: ?[]const u8) ?[]const u8 {
    if (visual) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len > 0) return value;
    }
    if (editor) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len > 0) return value;
    }
    return null;
}

fn temporaryRoot() []const u8 {
    const configured = io_mod.getenv("TMPDIR") orelse return "/tmp";
    if (configured.len == 0 or !std.Io.Dir.path.isAbsolute(configured)) return "/tmp";
    return configured;
}

fn editWithCommand(
    alloc: Allocator,
    command: []const u8,
    temp_root: []const u8,
    seed: []const u8,
    max_bytes: usize,
) Allocator.Error!EditResult {
    if (command_lex.unsafe_compound_indicator(command)) {
        return .{ .failed = .{ .reason = .invalid_command } };
    }

    var parsed = command_lex.tokenize_argv(alloc, command) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failed = .{ .reason = .invalid_command } },
    };
    defer parsed.deinit(alloc);
    if (parsed.tokens.len == 0) return .{ .failed = .{ .reason = .invalid_command } };
    for (parsed.tokens) |token| {
        if (std.mem.eql(u8, token.raw, token.value) and
            (command_lex.redirection_kind(token.value) != null or
                std.mem.eql(u8, token.value, "|")))
        {
            return .{ .failed = .{ .reason = .invalid_command } };
        }
    }

    const zio = io_mod.getIo();
    var temp_dir = std.Io.Dir.openDirAbsolute(zio, temp_root, .{}) catch |err| {
        debug_trace.logf("input", "external editor temp directory failed err={s}", .{@errorName(err)});
        return .{ .failed = .{ .reason = .editor_failed } };
    };
    defer temp_dir.close(zio);

    var random_bytes: [16]u8 = undefined;
    zio.random(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);
    var name_buf: [64]u8 = undefined;
    const temp_name = std.fmt.bufPrint(&name_buf, "fx-editor-{s}.md", .{suffix}) catch {
        return .{ .failed = .{ .reason = .editor_failed } };
    };
    const temp_path = try std.Io.Dir.path.join(alloc, &.{ temp_root, temp_name });
    var owns_temp_path = true;
    defer if (owns_temp_path) alloc.free(temp_path);

    var remove_temp = false;
    defer if (remove_temp) {
        temp_dir.deleteFile(zio, temp_name) catch |err| {
            debug_trace.logf("input", "external editor temp cleanup failed err={s}", .{@errorName(err)});
        };
    };

    {
        var file = temp_dir.createFile(zio, temp_name, .{
            .exclusive = true,
            .permissions = private_file_permissions,
        }) catch |err| {
            debug_trace.logf("input", "external editor temp create failed err={s}", .{@errorName(err)});
            return .{ .failed = .{ .reason = .editor_failed } };
        };
        remove_temp = true;
        defer file.close(zio);
        file.writeStreamingAll(zio, seed) catch |err| {
            debug_trace.logf("input", "external editor seed write failed err={s}", .{@errorName(err)});
            return .{ .failed = .{ .reason = .editor_failed } };
        };
    }

    const argv = try alloc.alloc([]const u8, parsed.tokens.len + 1);
    defer alloc.free(argv);
    for (parsed.tokens, 0..) |token, index| argv[index] = token.value;
    argv[parsed.tokens.len] = temp_path;

    var child = std.process.spawn(zio, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        debug_trace.logf("input", "external editor spawn failed err={s}", .{@errorName(err)});
        return .{ .failed = .{ .reason = .editor_failed } };
    };
    defer child.kill(zio);
    const term = child.wait(zio) catch |err| {
        debug_trace.logf("input", "external editor wait failed err={s}", .{@errorName(err)});
        return .{ .failed = .{ .reason = .editor_failed } };
    };
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                debug_trace.logf("input", "external editor canceled exit_code={d}", .{code});
                return .canceled;
            }
        },
        .signal => |signal| {
            debug_trace.logf("input", "external editor failed signal={d}", .{@intFromEnum(signal)});
            return .{ .failed = .{ .reason = .editor_failed } };
        },
        .stopped => |signal| {
            debug_trace.logf("input", "external editor failed stopped={d}", .{@intFromEnum(signal)});
            return .{ .failed = .{ .reason = .editor_failed } };
        },
        .unknown => |status| {
            debug_trace.logf("input", "external editor failed status={d}", .{status});
            return .{ .failed = .{ .reason = .editor_failed } };
        },
    }

    var output_file = temp_dir.openFile(zio, temp_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |err| {
        debug_trace.logf("input", "external editor output open failed err={s}", .{@errorName(err)});
        return keepEditedFile(.editor_failed, temp_path, &owns_temp_path, &remove_temp);
    };
    defer output_file.close(zio);
    const stat = output_file.stat(zio) catch |err| {
        debug_trace.logf("input", "external editor output stat failed err={s}", .{@errorName(err)});
        return keepEditedFile(.editor_failed, temp_path, &owns_temp_path, &remove_temp);
    };
    if (stat.kind != .file or stat.nlink != 1) {
        debug_trace.logf("input", "external editor output rejected kind={s} nlink={d}", .{ @tagName(stat.kind), stat.nlink });
        return keepEditedFile(.output_invalid, temp_path, &owns_temp_path, &remove_temp);
    }

    const output = io_mod.readFileToEnd(alloc, &output_file, max_bytes) catch |err| switch (err) {
        error.StreamTooLong => return keepEditedFile(.output_too_large, temp_path, &owns_temp_path, &remove_temp),
        else => {
            debug_trace.logf("input", "external editor output read failed err={s}", .{@errorName(err)});
            return keepEditedFile(.editor_failed, temp_path, &owns_temp_path, &remove_temp);
        },
    };
    if (!std.unicode.utf8ValidateSlice(output) or std.mem.findScalar(u8, output, 0) != null) {
        debug_trace.logf("input", "external editor output rejected reason=invalid_text", .{});
        alloc.free(output);
        return keepEditedFile(.output_invalid, temp_path, &owns_temp_path, &remove_temp);
    }

    temp_dir.deleteFile(zio, temp_name) catch |err| {
        debug_trace.logf(
            "input",
            "external editor temp cleanup failed path={s} err={s}",
            .{ temp_path, @errorName(err) },
        );
    };
    remove_temp = false;
    return .{ .edited = output };
}

fn keepEditedFile(
    reason: host.ExternalEditor.FailureReason,
    temp_path: []u8,
    owns_temp_path: *bool,
    remove_temp: *bool,
) EditResult {
    debug_trace.logf(
        "input",
        "external editor output kept reason={s} path={s}",
        .{ @tagName(reason), temp_path },
    );
    owns_temp_path.* = false;
    remove_temp.* = false;
    return .{ .failed = .{ .reason = reason, .kept_path = temp_path } };
}

test "external editor command selection prefers VISUAL and skips empty values" {
    try std.testing.expectEqualStrings("nvim -f", selectEditorCommand("nvim -f", "vi").?);
    try std.testing.expectEqualStrings("vi", selectEditorCommand("  ", "vi").?);
    try std.testing.expect(selectEditorCommand(null, "\t") == null);
}

test "external editor command parser accepts argv quoting and rejects shell syntax" {
    const alloc = std.testing.allocator;
    var parsed = try command_lex.tokenize_argv(alloc, "code --wait 'profile name'");
    defer parsed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), parsed.tokens.len);
    try std.testing.expectEqualStrings("profile name", parsed.tokens[2].value);

    const invalid_commands = [_][]const u8{
        "vi && touch nope",
        "vi > output",
        "vi | cat",
    };
    for (invalid_commands) |command| {
        var result = try editWithCommand(alloc, command, "/tmp", "seed", 1024);
        defer result.deinit(alloc);
        try std.testing.expectEqual(host.ExternalEditor.FailureReason.invalid_command, result.failed.reason);
        try std.testing.expect(result.failed.kept_path == null);
    }
}

test "external editor returns valid text and treats nonzero exit as cancellation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    var edited = try editWithCommand(
        alloc,
        "/bin/sh -c 'printf changed > \"$1\"' sh",
        root,
        "seed",
        1024,
    );
    defer edited.deinit(alloc);
    try std.testing.expectEqualStrings("changed", edited.edited);

    var canceled = try editWithCommand(
        alloc,
        "/bin/sh -c 'exit 7' sh",
        root,
        "seed",
        1024,
    );
    defer canceled.deinit(alloc);
    try std.testing.expect(canceled == .canceled);

    var check_dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), root, .{ .iterate = true });
    defer check_dir.close(io_mod.getIo());
    var iterator = check_dir.iterate();
    try std.testing.expect(try iterator.next(io_mod.getIo()) == null);
}

test "external editor keeps oversized saved output for recovery" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    var result = try editWithCommand(
        alloc,
        "/bin/sh -c 'printf too-long > \"$1\"' sh",
        root,
        "seed",
        3,
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(host.ExternalEditor.FailureReason.output_too_large, result.failed.reason);
    const kept_path = result.failed.kept_path.?;
    var kept = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), kept_path, .{});
    defer kept.close(io_mod.getIo());
    const contents = try io_mod.readFileToEnd(alloc, &kept, 64);
    defer alloc.free(contents);
    try std.testing.expectEqualStrings("too-long", contents);
}

test "external editor keeps invalid saved text for recovery" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);

    var result = try editWithCommand(
        alloc,
        "/bin/sh -c 'printf \"bad\\000text\" > \"$1\"' sh",
        root,
        "seed",
        64,
    );
    defer result.deinit(alloc);
    try std.testing.expectEqual(host.ExternalEditor.FailureReason.output_invalid, result.failed.reason);
    try std.testing.expect(result.failed.kept_path != null);
}
