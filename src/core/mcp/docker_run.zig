const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;
const max_container_id_bytes: usize = 128;
const cleanup_timeout: std.Io.Timeout = .{
    .duration = .{
        .raw = .{ .nanoseconds = 15 * std.time.ns_per_s },
        .clock = .awake,
    },
};

pub const Prepared = struct {
    argv: []const []const u8,
    owned_argv: ?[][]const u8 = null,
    cleanup: ?Cleanup = null,

    pub fn takeCleanup(self: *Prepared) ?Cleanup {
        const cleanup = self.cleanup;
        self.cleanup = null;
        return cleanup;
    }

    pub fn deinit(self: *Prepared, alloc: Allocator) void {
        if (self.owned_argv) |owned| alloc.free(owned);
        if (self.cleanup) |*cleanup| cleanup.deinit(alloc);
        self.* = undefined;
    }
};

pub const Cleanup = struct {
    docker_command: []u8,
    cidfile_path: []u8,
    environ_map: ?std.process.Environ.Map = null,

    pub fn cloneEnvironment(
        self: *Cleanup,
        alloc: Allocator,
        source: *const std.process.Environ.Map,
    ) !void {
        std.debug.assert(self.environ_map == null);
        self.environ_map = try source.clone(alloc);
    }

    pub fn deinit(self: *Cleanup, alloc: Allocator) void {
        if (self.environ_map) |*environment| environment.deinit();
        alloc.free(self.docker_command);
        alloc.free(self.cidfile_path);
        self.* = undefined;
    }

    pub fn run(self: *const Cleanup, alloc: Allocator) void {
        defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), self.cidfile_path) catch {};
        const container_id = readContainerId(alloc, self.cidfile_path) catch |err| {
            if (err != error.FileNotFound) {
                debug_trace.logf(
                    "mcp",
                    "docker MCP cleanup skipped unreadable cidfile err={s}",
                    .{@errorName(err)},
                );
            }
            return;
        };
        defer alloc.free(container_id);
        const result = std.process.run(alloc, io_mod.getIo(), .{
            .argv = &.{ self.docker_command, "rm", "-f", container_id },
            .stdout_limit = .limited(max_container_id_bytes),
            .stderr_limit = .limited(4096),
            .timeout = cleanup_timeout,
            .environ_map = if (self.environ_map) |*environment| environment else null,
        }) catch |err| {
            debug_trace.logf(
                "mcp",
                "docker MCP cleanup failed err={s}",
                .{@errorName(err)},
            );
            return;
        };
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            debug_trace.logf(
                "mcp",
                "docker MCP cleanup failed term={t}",
                .{result.term},
            );
            return;
        }
        debug_trace.logf("mcp", "docker MCP container cleanup complete", .{});
    }
};

pub fn prepare(alloc: Allocator, argv: []const []const u8) !Prepared {
    if (!isDirectDockerRun(argv) or hasCidfile(argv)) return .{ .argv = argv };

    const temp_root = temporaryRoot() orelse return .{ .argv = argv };
    if (!std.fs.path.isAbsolute(temp_root)) return .{ .argv = argv };
    var nonce: [16]u8 = undefined;
    try std.Io.randomSecure(io_mod.getIo(), &nonce);
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    const cidfile_path = try std.fmt.allocPrint(
        alloc,
        "{s}/fx-mcp-{s}.cid",
        .{ std.mem.trimEnd(u8, temp_root, "/\\"), &nonce_hex },
    );
    errdefer alloc.free(cidfile_path);
    const docker_command = try alloc.dupe(u8, argv[0]);
    errdefer alloc.free(docker_command);

    const owned_argv = try alloc.alloc([]const u8, argv.len + 2);
    errdefer alloc.free(owned_argv);
    owned_argv[0] = argv[0];
    owned_argv[1] = argv[1];
    owned_argv[2] = "--cidfile";
    owned_argv[3] = cidfile_path;
    @memcpy(owned_argv[4..], argv[2..]);
    return .{
        .argv = owned_argv,
        .owned_argv = owned_argv,
        .cleanup = .{
            .docker_command = docker_command,
            .cidfile_path = cidfile_path,
        },
    };
}

fn isDirectDockerRun(argv: []const []const u8) bool {
    if (argv.len < 2 or !std.mem.eql(u8, argv[1], "run")) return false;
    const command = std.fs.path.basename(argv[0]);
    return std.ascii.eqlIgnoreCase(command, "docker") or
        std.ascii.eqlIgnoreCase(command, "docker.exe");
}

fn hasCidfile(argv: []const []const u8) bool {
    for (argv[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--cidfile") or
            std.mem.startsWith(u8, arg, "--cidfile=")) return true;
    }
    return false;
}

fn temporaryRoot() ?[]const u8 {
    return io_mod.getenv("TMPDIR") orelse
        io_mod.getenv("TEMP") orelse
        io_mod.getenv("TMP") orelse
        if (@import("builtin").os.tag == .windows) null else "/tmp";
}

fn readContainerId(alloc: Allocator, path: []const u8) ![]u8 {
    const parent_path = std.fs.path.dirname(path) orelse return error.InvalidContainerId;
    const basename = std.fs.path.basename(path);
    var parent = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), parent_path, .{});
    defer parent.close(io_mod.getIo());
    var file = try io_mod.openExistingRegularFile(parent, basename, .read_only);
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.size > max_container_id_bytes) return error.InvalidContainerId;
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_container_id_bytes);
    errdefer alloc.free(bytes);
    const id = std.mem.trim(u8, bytes, " \t\r\n");
    if (id.len < 12 or id.len > 64) return error.InvalidContainerId;
    for (id) |byte| if (!std.ascii.isHex(byte)) return error.InvalidContainerId;
    if (id.ptr == bytes.ptr and id.len == bytes.len) return bytes;
    const owned = try alloc.dupe(u8, id);
    alloc.free(bytes);
    return owned;
}

test "docker MCP launch preparation injects one private cidfile" {
    const alloc = std.testing.allocator;
    var prepared = try prepare(alloc, &.{
        "/usr/local/bin/docker",
        "run",
        "--rm",
        "-i",
        "fixture",
    });
    defer prepared.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 7), prepared.argv.len);
    try std.testing.expectEqualStrings("--cidfile", prepared.argv[2]);
    try std.testing.expect(prepared.cleanup != null);
    try std.testing.expectEqualStrings(prepared.argv[3], prepared.cleanup.?.cidfile_path);

    var explicit = try prepare(alloc, &.{
        "docker",
        "run",
        "--cidfile=/tmp/owned.cid",
        "fixture",
    });
    defer explicit.deinit(alloc);
    try std.testing.expect(explicit.owned_argv == null);
    try std.testing.expect(explicit.cleanup == null);

    var unrelated = try prepare(alloc, &.{ "podman", "run", "fixture" });
    defer unrelated.deinit(alloc);
    try std.testing.expect(unrelated.owned_argv == null);
}

test "docker MCP cleanup accepts only bounded hexadecimal container ids" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const cidfile = try std.fmt.allocPrint(alloc, "{s}/fixture.cid", .{root});
    defer alloc.free(cidfile);

    {
        var file = try std.Io.Dir.createFileAbsolute(std.testing.io, cidfile, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "0123456789abcdef\n");
    }
    const valid = try readContainerId(alloc, cidfile);
    defer alloc.free(valid);
    try std.testing.expectEqualStrings("0123456789abcdef", valid);

    {
        var file = try std.Io.Dir.createFileAbsolute(std.testing.io, cidfile, .{ .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "not-a-container-id\n");
    }
    try std.testing.expectError(error.InvalidContainerId, readContainerId(alloc, cidfile));
}
