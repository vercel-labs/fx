const std = @import("std");

var wrapped_vtable: std.Io.VTable = undefined;
var wrapped_original_vtable: ?*const std.Io.VTable = null;

pub fn wrap(original: std.Io) std.Io {
    if (wrapped_original_vtable) |original_vtable| {
        std.debug.assert(original_vtable == original.vtable);
    } else {
        wrapped_vtable = original.vtable.*;
        wrapped_vtable.dirOpenFile = dirOpenFile;
        wrapped_original_vtable = original.vtable;
    }
    return .{
        .userdata = original.userdata,
        .vtable = &wrapped_vtable,
    };
}

fn dirOpenFile(
    userdata: ?*anyopaque,
    dir: std.Io.Dir,
    sub_path: []const u8,
    options: std.Io.Dir.OpenFileOptions,
) std.Io.File.OpenError!std.Io.File {
    var file = try wrapped_original_vtable.?.dirOpenFile(
        userdata,
        dir,
        sub_path,
        options,
    );
    // Zig 0.16 opens no-follow Windows files asynchronously but reports the
    // handle as blocking. Positional reads then treat a normal PENDING result
    // as an invariant failure. Keep the handle metadata aligned with NtCreateFile.
    file.flags.nonblocking = !options.follow_symlinks;
    return file;
}

test "no-follow Windows files report asynchronous handles" {
    if (comptime @import("builtin").os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var created = try tmp.dir.createFile(std.testing.io, "value", .{});
        defer created.close(std.testing.io);
        try created.writeStreamingAll(std.testing.io, "ok");
    }

    const wrapped = wrap(std.testing.io);
    var file = try tmp.dir.openFile(wrapped, "value", .{ .follow_symlinks = false });
    defer file.close(wrapped);
    try std.testing.expect(file.flags.nonblocking);
    var bytes: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try file.readPositionalAll(wrapped, &bytes, 0));
    try std.testing.expectEqualStrings("ok", &bytes);
}
