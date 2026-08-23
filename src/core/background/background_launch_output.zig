const std = @import("std");
const background_process_provider = @import(
    "../execution/background_process_provider.zig",
);
const io_mod = @import("../shared/io.zig");
const session_child_store = @import("../session/session_child_store.zig");

const Allocator = std.mem.Allocator;

pub const Output = union(enum) {
    managed_session: struct {
        capability: *session_child_store.SessionChildCapability,
        file: session_child_store.ManagedFile,
        name: []u8,
        display_path: []u8,
    },
    external: struct {
        file: std.Io.File,
        path: []u8,
    },

    pub fn childStdioFile(self: *const Output) std.Io.File {
        return switch (self.*) {
            .managed_session => |value| value.file.childStdioFile(),
            .external => |value| value.file,
        };
    }

    pub fn providerCapability(
        self: *const Output,
    ) background_process_provider.OutputCapability {
        return .{ .context = self };
    }

    pub fn childStdioFileForProvider(
        capability: background_process_provider.OutputCapability,
    ) std.Io.File {
        const self: *const Output = @ptrCast(@alignCast(capability.context));
        return self.childStdioFile();
    }

    pub fn displayPath(self: *const Output) []const u8 {
        return switch (self.*) {
            .managed_session => |value| value.display_path,
            .external => |value| value.path,
        };
    }

    pub fn managedLogName(self: *const Output) ?[]const u8 {
        return switch (self.*) {
            .managed_session => |value| value.name,
            .external => null,
        };
    }

    pub fn deinit(self: *Output, alloc: Allocator, remove: bool) void {
        switch (self.*) {
            .managed_session => |*value| {
                value.file.deinit();
                if (remove) {
                    value.capability.delete(
                        .background_logs,
                        value.name,
                    ) catch {};
                }
                alloc.free(value.name);
                alloc.free(value.display_path);
            },
            .external => |value| {
                value.file.close(io_mod.getIo());
                if (remove) {
                    std.Io.Dir.deleteFileAbsolute(
                        io_mod.getIo(),
                        value.path,
                    ) catch {};
                }
                alloc.free(value.path);
            },
        }
        self.* = undefined;
    }
};

pub fn prepareManaged(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
) !Output {
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        const name = try randomLogName(alloc);
        var file = capability.createExclusiveFile(
            alloc,
            .background_logs,
            name,
        ) catch |err| switch (err) {
            error.PathAlreadyExists => {
                alloc.free(name);
                continue;
            },
            else => {
                alloc.free(name);
                return err;
            },
        };
        errdefer file.deinit();
        const display_path = try alloc.dupe(
            u8,
            file.displayPath() orelse return error.SessionChildStoreFailed,
        );
        return .{ .managed_session = .{
            .capability = capability,
            .file = file,
            .name = name,
            .display_path = display_path,
        } };
    }
    return error.BackgroundIdentityUnavailable;
}

pub fn prepareExternal(alloc: Allocator) !Output {
    const root = io_mod.tempDir();
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        const name = try randomLogName(alloc);
        defer alloc.free(name);
        const path = try std.fs.path.join(alloc, &.{ root, name });
        const file = std.Io.Dir.createFileAbsolute(
            io_mod.getIo(),
            path,
            .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .permissions = io_mod.private_file_permissions,
            },
        ) catch |err| switch (err) {
            error.PathAlreadyExists => {
                alloc.free(path);
                continue;
            },
            else => {
                alloc.free(path);
                return err;
            },
        };
        return .{ .external = .{ .file = file, .path = path } };
    }
    return error.BackgroundIdentityUnavailable;
}

fn randomLogName(alloc: Allocator) ![]u8 {
    var random: [16]u8 = undefined;
    try std.Io.randomSecure(io_mod.getIo(), &random);
    var encoded: [32]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (random, 0..) |byte, index| {
        encoded[index * 2] = alphabet[byte >> 4];
        encoded[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return std.fmt.allocPrint(
        alloc,
        "fx-cmd-{s}.log",
        .{encoded[0..]},
    );
}

test "background launch output removes external log on cancellation" {
    const alloc = std.testing.allocator;
    var output = try prepareExternal(alloc);
    const path = try alloc.dupe(u8, output.displayPath());
    defer alloc.free(path);

    output.deinit(alloc, true);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}),
    );
}

test "background launch output removes managed log on cancellation" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        io_mod.private_dir_permissions,
    );
    const display_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(display_path);
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        display_path,
        .writable,
        .{},
    );
    defer capability.deinit();

    var output = try prepareManaged(alloc, &capability);
    const name = try alloc.dupe(u8, output.managedLogName().?);
    defer alloc.free(name);

    output.deinit(alloc, true);
    try std.testing.expectError(
        error.FileNotFound,
        capability.stat(.background_logs, name),
    );
}
