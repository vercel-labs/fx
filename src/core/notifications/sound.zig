const std = @import("std");
const builtin = @import("builtin");
const notification_contract = @import("notification_contract.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const macos_player_path = "/usr/bin/afplay";

// Sound defaults on only where a real audio player exists (macOS). Elsewhere
// the fallback is the terminal bell, so notifications stay opt-in.
pub const default_enabled: bool = builtin.os.tag == .macos;

// One-shot notifications still construct Player directly. Keep these aliases
// until that path moves behind its own provider boundary.
pub const Cue = notification_contract.Cue;
pub const Kind = notification_contract.Kind;

// Chimes derived from cuelume's MIT-licensed recipes by Daniel Belyi, rendered
// at 48kHz and encoded as AAC. `click` has no recipe to re-render from, so it
// stays the original IMA4 CAF.
fn embeddedChime(cue: Cue) []const u8 {
    return switch (cue) {
        .click => @embedFile("click.caf"),
        inline else => |named_cue| @embedFile(@tagName(named_cue) ++ ".m4a"),
    };
}

fn materializedName(cue: Cue) []const u8 {
    return switch (cue) {
        .click => "fx-click.caf",
        inline else => |named_cue| "fx-" ++ @tagName(named_cue) ++ ".m4a",
    };
}

var sound_path_mutex: std.Io.Mutex = .init;
var materialized_paths = [_]?[]const u8{null} ** std.enums.values(Cue).len;
var sound_path_bufs: [std.enums.values(Cue).len][std.fs.max_path_bytes]u8 = undefined;

// Materialize lazily to protect startup latency. Atomic replacement avoids following symlinks.
fn ensureCueSoundPath(cue: Cue) ?[]const u8 {
    const idx = @intFromEnum(cue);
    sound_path_mutex.lockUncancelable(io_mod.getIo());
    defer sound_path_mutex.unlock(io_mod.getIo());
    if (materialized_paths[idx]) |path| return path;

    const dir = io_mod.getenv("TMPDIR") orelse "/tmp";
    const sep: []const u8 = if (dir.len > 0 and dir[dir.len - 1] == '/') "" else "/";
    const path = std.fmt.bufPrint(&sound_path_bufs[idx], "{s}{s}{s}", .{ dir, sep, materializedName(cue) }) catch return null;
    const chime = embeddedChime(cue);

    const reusable = cueFileMatches(path, chime);
    if (!reusable) writeCueFile(path, chime) catch |err| {
        debug_trace.logf(
            "notifications",
            "sound materialize failed cue={s} err={s}; using terminal bell",
            .{ @tagName(cue), @errorName(err) },
        );
        return null;
    };
    materialized_paths[idx] = path;
    return path;
}

fn cueFileMatches(path: []const u8, expected: []const u8) bool {
    const io = io_mod.getIo();
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    if (stat.kind != .file or stat.size != expected.len) return false;

    var file = std.Io.Dir.openFileAbsolute(io, path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch return false;
    defer file.close(io);
    const opened_stat = file.stat(io) catch return false;
    if (opened_stat.kind != .file or opened_stat.size != expected.len) return false;

    var reader_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    var chunk: [4096]u8 = undefined;
    var offset: usize = 0;
    while (true) {
        const read_len = reader.interface.readSliceShort(&chunk) catch return false;
        if (read_len == 0) return offset == expected.len;
        if (read_len > expected.len - offset) return false;
        if (!std.mem.eql(u8, chunk[0..read_len], expected[offset .. offset + read_len])) return false;
        offset += read_len;
    }
}

fn writeCueFile(path: []const u8, bytes: []const u8) !void {
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io_mod.getIo(), path, .{ .replace = true });
    defer atomic_file.deinit(io_mod.getIo());
    try atomic_file.file.writeStreamingAll(io_mod.getIo(), bytes);
    try atomic_file.replace(io_mod.getIo());
}

fn productionSoundPath(_: ?*anyopaque, cue: Cue) ?[]const u8 {
    return ensureCueSoundPath(cue);
}

pub const BellSink = struct {
    ctx: *anyopaque,
    emit: *const fn (*anyopaque) void,
};

const Process = struct {
    ctx: *anyopaque,
    wait: *const fn (*anyopaque) void,

    fn reap(self: Process) void {
        self.wait(self.ctx);
    }
};

const Platform = enum {
    macos,
    linux,
    unsupported,
};

const SpawnFn = *const fn (?*anyopaque, []const []const u8) std.process.SpawnError!Process;
const StartWaiterFn = *const fn (?*anyopaque, Process) std.Thread.SpawnError!void;
const SoundPathFn = *const fn (?*anyopaque, Cue) ?[]const u8;

const Dependencies = struct {
    ctx: ?*anyopaque,
    platform: Platform,
    spawn: SpawnFn,
    start_waiter: StartWaiterFn,
    sound_path: SoundPathFn,

    fn production() Dependencies {
        if (comptime builtin.os.tag != .macos) {
            return .{
                .ctx = null,
                .platform = if (builtin.os.tag == .linux) .linux else .unsupported,
                .spawn = unsupportedSpawnSoundProcess,
                .start_waiter = unsupportedStartWaiter,
                .sound_path = unavailableSoundPath,
            };
        }
        return .{
            .ctx = null,
            .platform = .macos,
            .spawn = spawnSoundProcess,
            .start_waiter = startDetachedWaiter,
            .sound_path = productionSoundPath,
        };
    }
};

pub const Player = struct {
    bell: BellSink,
    dependencies: Dependencies = Dependencies.production(),

    pub fn init(bell: BellSink) Player {
        return .{ .bell = bell };
    }

    pub fn play(self: *Player, cue: Cue) void {
        switch (self.dependencies.platform) {
            .macos => self.playMacos(cue, true),
            .linux, .unsupported => self.emitBell(),
        }
    }

    // Attention notifications always include a terminal BEL so multiplexers
    // can mark the pane, even when macOS also plays the configured chime.
    pub fn playAttention(self: *Player, cue: Cue) void {
        self.emitBell();
        if (self.dependencies.platform == .macos) {
            self.playMacos(cue, false);
        }
    }

    fn playMacos(self: *Player, cue: Cue, bell_on_failure: bool) void {
        const sound_path = self.dependencies.sound_path(self.dependencies.ctx, cue) orelse {
            if (bell_on_failure) self.emitBell();
            return;
        };
        const argv = [_][]const u8{ macos_player_path, sound_path };
        const process = self.dependencies.spawn(
            self.dependencies.ctx,
            &argv,
        ) catch |err| {
            if (bell_on_failure) {
                debug_trace.logf(
                    "notifications",
                    "sound spawn failed err={s}; using terminal bell",
                    .{@errorName(err)},
                );
                self.emitBell();
            } else {
                debug_trace.logf(
                    "notifications",
                    "sound spawn failed err={s}; terminal bell already emitted",
                    .{@errorName(err)},
                );
            }
            return;
        };
        self.dependencies.start_waiter(self.dependencies.ctx, process) catch |err| {
            debug_trace.logf(
                "notifications",
                "sound waiter start failed err={s}; reaping synchronously",
                .{@errorName(err)},
            );
            process.reap();
        };
    }

    fn emitBell(self: *Player) void {
        self.bell.emit(self.bell.ctx);
    }
};

const ChildWaiter = struct {
    child: std.process.Child,

    fn reap(raw: *anyopaque) void {
        const self: *ChildWaiter = @ptrCast(@alignCast(raw));
        const term = self.child.wait(io_mod.getIo()) catch |err| {
            debug_trace.logf(
                "notifications",
                "sound child wait failed err={s}",
                .{@errorName(err)},
            );
            std.heap.c_allocator.destroy(self);
            return;
        };
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    debug_trace.logf(
                        "notifications",
                        "sound child exited status={d}",
                        .{code},
                    );
                }
            },
            .signal => |signal| debug_trace.logf(
                "notifications",
                "sound child signaled signal={d}",
                .{@intFromEnum(signal)},
            ),
            .stopped => |signal| debug_trace.logf(
                "notifications",
                "sound child stopped signal={d}",
                .{@intFromEnum(signal)},
            ),
            .unknown => |status| debug_trace.logf(
                "notifications",
                "sound child ended with unknown status={d}",
                .{status},
            ),
        }
        std.heap.c_allocator.destroy(self);
    }
};

fn unavailableSoundPath(_: ?*anyopaque, _: Cue) ?[]const u8 {
    return null;
}

fn unsupportedSpawnSoundProcess(_: ?*anyopaque, _: []const []const u8) std.process.SpawnError!Process {
    return error.SystemResources;
}

fn unsupportedStartWaiter(_: ?*anyopaque, _: Process) std.Thread.SpawnError!void {
    return error.SystemResources;
}

fn spawnSoundProcess(_: ?*anyopaque, argv: []const []const u8) std.process.SpawnError!Process {
    const waiter = try std.heap.c_allocator.create(ChildWaiter);
    errdefer std.heap.c_allocator.destroy(waiter);
    waiter.* = .{
        .child = try std.process.spawn(io_mod.getIo(), .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }),
    };
    return .{
        .ctx = waiter,
        .wait = ChildWaiter.reap,
    };
}

fn startDetachedWaiter(_: ?*anyopaque, process: Process) std.Thread.SpawnError!void {
    const thread = try std.Thread.spawn(.{}, Process.reap, .{process});
    thread.detach();
}

const test_sound_path = "/tmp/fx-success-test.wav";

const TestState = struct {
    bell_count: usize = 0,
    spawn_count: usize = 0,
    waiter_count: usize = 0,
    reap_count: usize = 0,
    sound_path_count: usize = 0,
    fail_spawn: bool = false,
    fail_waiter: bool = false,
    no_sound_path: bool = false,
    argv_matches: bool = false,
    last_cue: ?Cue = null,

    fn emitBell(raw: *anyopaque) void {
        const self: *TestState = @ptrCast(@alignCast(raw));
        self.bell_count += 1;
    }

    fn soundPath(raw: ?*anyopaque, cue: Cue) ?[]const u8 {
        const self: *TestState = @ptrCast(@alignCast(raw.?));
        self.sound_path_count += 1;
        self.last_cue = cue;
        if (self.no_sound_path) return null;
        return test_sound_path;
    }

    fn spawn(raw: ?*anyopaque, argv: []const []const u8) std.process.SpawnError!Process {
        const self: *TestState = @ptrCast(@alignCast(raw.?));
        self.spawn_count += 1;
        if (self.fail_spawn) return error.OutOfMemory;
        self.argv_matches = argv.len == 2 and
            std.mem.eql(u8, argv[0], macos_player_path) and
            std.mem.eql(u8, argv[1], test_sound_path);
        return .{ .ctx = self, .wait = reap };
    }

    fn startWaiter(raw: ?*anyopaque, process: Process) std.Thread.SpawnError!void {
        const self: *TestState = @ptrCast(@alignCast(raw.?));
        self.waiter_count += 1;
        if (self.fail_waiter) return error.ThreadQuotaExceeded;
        process.reap();
    }

    fn reap(raw: *anyopaque) void {
        const self: *TestState = @ptrCast(@alignCast(raw));
        self.reap_count += 1;
    }
};

fn testPlayer(state: *TestState, platform: Platform) Player {
    return .{
        .bell = .{ .ctx = state, .emit = TestState.emitBell },
        .dependencies = .{
            .ctx = state,
            .platform = platform,
            .spawn = TestState.spawn,
            .start_waiter = TestState.startWaiter,
            .sound_path = TestState.soundPath,
        },
    };
}

test "cue file write replaces a symlink without modifying its target" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "victim.txt",
        .data = "original",
    });
    tmp.dir.symLink(
        io_mod.getIo(),
        "victim.txt",
        "cue.wav",
        .{ .is_directory = false },
    ) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const cue_path = try std.fs.path.join(alloc, &.{ root, "cue.wav" });
    defer alloc.free(cue_path);

    try writeCueFile(cue_path, "replacement");

    var victim_file = try tmp.dir.openFile(io_mod.getIo(), "victim.txt", .{});
    defer victim_file.close(io_mod.getIo());
    const victim = try io_mod.readFileToEnd(alloc, &victim_file, 64);
    defer alloc.free(victim);
    try std.testing.expectEqualStrings("original", victim);

    const cue_stat = try tmp.dir.statFile(io_mod.getIo(), "cue.wav", .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.file, cue_stat.kind);
    var cue_file = try tmp.dir.openFile(io_mod.getIo(), "cue.wav", .{});
    defer cue_file.close(io_mod.getIo());
    const cue = try io_mod.readFileToEnd(alloc, &cue_file, 64);
    defer alloc.free(cue);
    try std.testing.expectEqualStrings("replacement", cue);
}

test "cue cache match verifies content, not only size" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io_mod.getIo(), .{
        .sub_path = "cue.wav",
        .data = "wrong",
    });

    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const cue_path = try std.fs.path.join(alloc, &.{ root, "cue.wav" });
    defer alloc.free(cue_path);

    try std.testing.expect(!cueFileMatches(cue_path, "sound"));
    try writeCueFile(cue_path, "sound");
    try std.testing.expect(cueFileMatches(cue_path, "sound"));
}

test "macOS sound plays the materialized chime and reaps the child" {
    var state = TestState{};
    var player = testPlayer(&state, .macos);
    player.play(.@"error");

    try std.testing.expectEqual(@as(usize, 1), state.sound_path_count);
    try std.testing.expectEqual(@as(?Cue, .@"error"), state.last_cue);
    try std.testing.expectEqual(@as(usize, 1), state.spawn_count);
    try std.testing.expectEqual(@as(usize, 1), state.waiter_count);
    try std.testing.expectEqual(@as(usize, 1), state.reap_count);
    try std.testing.expectEqual(@as(usize, 0), state.bell_count);
    try std.testing.expect(state.argv_matches);
}

test "macOS falls back to one terminal bell when the chime cannot be written" {
    var state = TestState{ .no_sound_path = true };
    var player = testPlayer(&state, .macos);
    player.play(.success);

    try std.testing.expectEqual(@as(usize, 1), state.sound_path_count);
    try std.testing.expectEqual(@as(usize, 0), state.spawn_count);
    try std.testing.expectEqual(@as(usize, 1), state.bell_count);
}

test "macOS spawn failure falls back to one terminal bell" {
    var state = TestState{ .fail_spawn = true };
    var player = testPlayer(&state, .macos);
    player.play(.success);

    try std.testing.expectEqual(@as(usize, 1), state.spawn_count);
    try std.testing.expectEqual(@as(usize, 0), state.waiter_count);
    try std.testing.expectEqual(@as(usize, 0), state.reap_count);
    try std.testing.expectEqual(@as(usize, 1), state.bell_count);
}

test "waiter startup failure still reaps the child" {
    var state = TestState{ .fail_waiter = true };
    var player = testPlayer(&state, .macos);
    player.play(.success);

    try std.testing.expectEqual(@as(usize, 1), state.waiter_count);
    try std.testing.expectEqual(@as(usize, 1), state.reap_count);
    try std.testing.expectEqual(@as(usize, 0), state.bell_count);
}

test "Linux sound emits one bell without spawning" {
    var state = TestState{};
    var player = testPlayer(&state, .linux);
    player.play(.success);

    try std.testing.expectEqual(@as(usize, 0), state.spawn_count);
    try std.testing.expectEqual(@as(usize, 1), state.bell_count);
}

test "macOS attention emits one terminal bell and plays the chime" {
    var state = TestState{};
    var player = testPlayer(&state, .macos);
    player.playAttention(.success);

    try std.testing.expectEqual(@as(usize, 1), state.sound_path_count);
    try std.testing.expectEqual(@as(usize, 1), state.spawn_count);
    try std.testing.expectEqual(@as(usize, 1), state.waiter_count);
    try std.testing.expectEqual(@as(usize, 1), state.reap_count);
    try std.testing.expectEqual(@as(usize, 1), state.bell_count);
}

test "macOS attention emits only one bell when the chime is unavailable" {
    var missing_state = TestState{ .no_sound_path = true };
    var missing_player = testPlayer(&missing_state, .macos);
    missing_player.playAttention(.success);

    try std.testing.expectEqual(@as(usize, 0), missing_state.spawn_count);
    try std.testing.expectEqual(@as(usize, 1), missing_state.bell_count);

    var failed_state = TestState{ .fail_spawn = true };
    var failed_player = testPlayer(&failed_state, .macos);
    failed_player.playAttention(.success);

    try std.testing.expectEqual(@as(usize, 1), failed_state.spawn_count);
    try std.testing.expectEqual(@as(usize, 0), failed_state.waiter_count);
    try std.testing.expectEqual(@as(usize, 1), failed_state.bell_count);
}

test "Linux attention emits exactly one bell without spawning" {
    var state = TestState{};
    var player = testPlayer(&state, .linux);
    player.playAttention(.success);

    try std.testing.expectEqual(@as(usize, 0), state.sound_path_count);
    try std.testing.expectEqual(@as(usize, 0), state.spawn_count);
    try std.testing.expectEqual(@as(usize, 1), state.bell_count);
}
