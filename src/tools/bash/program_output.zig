//! A finished bash program's output, read once: saved as the next numbered file in
//! the results folder with its index row, and kept as the head and tail the model
//! may see. The model's text is built by bash_results. The order is the one in
//! tests/tla/bash_tool/ResultStore.tla: the file is written before its index row
//! (`File`, `Index`), and the text is built only after both (`SavedBeforeShown`).

const std = @import("std");
const bash_results = @import("../../core/bash_results/bash_results.zig");
const command_replay_store = @import("../../core/session/command_replay_store.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const result_files = @import("../../core/session/result_files.zig");

const Allocator = std.mem.Allocator;

/// The most bytes the head and the tail each keep, unless the inline budget needs more.
pub const keep_min_bytes: usize = 64 * 1024;

/// The bytes one read from the replay hands to the folder at a time.
const chunk_bytes: usize = 4096;

/// The first bytes of an output, its last bytes, and its counts, fed one chunk at a time.
pub const Keep = struct {
    alloc: Allocator,
    /// The most bytes the head keeps, and the tail keeps up to twice this.
    keep: usize,
    stats: bash_results.Stats = .{},
    head_buf: []u8,
    head_len: usize = 0,
    tail_buf: []u8,
    tail_len: usize = 0,

    pub fn init(alloc: Allocator, keep: usize) Allocator.Error!Keep {
        const head_buf = try alloc.alloc(u8, keep);
        errdefer alloc.free(head_buf);
        const tail_buf = try alloc.alloc(u8, 2 * keep);
        return .{ .alloc = alloc, .keep = keep, .head_buf = head_buf, .tail_buf = tail_buf };
    }

    pub fn deinit(self: *Keep) void {
        self.alloc.free(self.head_buf);
        self.alloc.free(self.tail_buf);
        self.* = undefined;
    }

    pub fn feed(self: *Keep, bytes: []const u8) void {
        self.stats.feed(bytes);
        const head_take = @min(bytes.len, self.keep - self.head_len);
        @memcpy(self.head_buf[self.head_len..][0..head_take], bytes[0..head_take]);
        self.head_len += head_take;
        self.pushTail(bytes);
    }

    /// Appends `bytes` to the tail buffer. When the buffer is full, its last `keep`
    /// bytes move to the front, so the tail is always one slice at the end.
    fn pushTail(self: *Keep, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            if (self.tail_len == self.tail_buf.len) {
                @memcpy(self.tail_buf[0..self.keep], self.tail_buf[self.tail_len - self.keep ..][0..self.keep]);
                self.tail_len = self.keep;
            }
            const take = @min(rest.len, self.tail_buf.len - self.tail_len);
            @memcpy(self.tail_buf[self.tail_len..][0..take], rest[0..take]);
            self.tail_len += take;
            rest = rest[take..];
        }
    }

    /// The first bytes of the output, up to `keep` of them.
    pub fn head(self: *const Keep) []const u8 {
        return self.head_buf[0..self.head_len];
    }

    /// The last bytes of the output, up to `keep` of them.
    pub fn tail(self: *const Keep) []const u8 {
        return self.tail_buf[self.tail_len - @min(self.tail_len, self.keep) .. self.tail_len];
    }
};

/// Where a finished program's whole output is, if it was kept.
pub const Replay = union(enum) {
    /// The program printed nothing, so its output is empty.
    empty,
    /// The program printed, but fx kept no capture of its output.
    missing,
    /// The capture is named, but fx could not open it.
    unreadable,
    /// The capture, read from its first byte.
    reader: *command_replay_store.Reader,
};

/// A reader of the whole output that feeds `keep` with every byte it hands on. It takes
/// the replay a frame at a time, so a large output is not decoded byte by byte.
pub const ReplayReader = struct {
    replay: *command_replay_store.Reader,
    keep: *Keep,
    alloc: Allocator,
    /// The frame being handed on, owned by `alloc`, and the part of it not yet handed on.
    frame: ?[]u8 = null,
    unread: []u8 = &.{},
    /// The error the replay returned, when a read failed.
    failure: ?anyerror = null,
    interface: std.Io.Reader,

    fn init(alloc: Allocator, replay: *command_replay_store.Reader, keep: *Keep) ReplayReader {
        return .{
            .replay = replay,
            .keep = keep,
            .alloc = alloc,
            .interface = .{ .vtable = &vtable, .buffer = &.{}, .seek = 0, .end = 0 },
        };
    }

    fn deinit(self: *ReplayReader) void {
        if (self.frame) |bytes| self.alloc.free(bytes);
        self.frame = null;
        self.unread = &.{};
    }

    const vtable: std.Io.Reader.VTable = .{ .stream = stream };

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *ReplayReader = @fieldParentPtr("interface", r);
        while (self.unread.len == 0) {
            if (self.frame) |bytes| {
                self.alloc.free(bytes);
                self.frame = null;
            }
            const next = self.replay.next(self.alloc) catch |err| {
                self.failure = err;
                return error.ReadFailed;
            };
            const frame = next orelse return error.EndOfStream;
            self.frame = frame.payload;
            self.unread = frame.payload;
        }
        const take = limit.minInt(self.unread.len);
        self.keep.feed(self.unread[0..take]);
        w.writeAll(self.unread[0..take]) catch return error.WriteFailed;
        self.unread = self.unread[take..];
        return take;
    }
};

/// A finished program's output as its result shows it.
pub const Output = struct {
    saved: bash_results.Saved,
    stats: bash_results.Stats,
    head: []const u8,
    tail: []const u8,
    /// Owns `head` and `tail` when they came from the whole output. Null when they
    /// borrow the program's undelivered output, which is all fx has.
    keep: ?Keep = null,
    /// The file was saved, but its index line was not written.
    index_missing: bool = false,

    pub fn deinit(self: *Output) void {
        if (self.keep) |*keep| keep.deinit();
        self.* = undefined;
    }
};

pub const Request = struct {
    alloc: Allocator,
    /// The results folder `$FX_OUT` named, or null when the host gives none.
    folder_path: ?[]const u8,
    limits: result_files.Limits,
    /// Bytes the head and the tail each keep: the whole of a short output, or each end of a long one.
    keep_bytes: usize,
    command: []const u8,
    exit: result_files.Exit,
    replay: Replay,
    /// What the program printed since its last result. The output when `replay` has none.
    delta: []const u8,
    /// Test seam: runs after a number is picked and before its file is published, so a test
    /// can let another writer take the number. Null outside tests.
    after_number: ?*const fn (folder: *result_files.ResultFolder, number: u64) void = null,
};

/// Saves a finished program's output as its next numbered file, then adds its index
/// row (`File`, `Index`). A file the folder refuses gets no row (`FullNoticed`). Every
/// other failure is logged, and the output is then shown from `delta`.
pub fn save(request: Request) Allocator.Error!Output {
    switch (request.replay) {
        .missing => return fromDelta(request.delta, .{ .not_saved_error = "the output was not kept" }),
        .unreadable => return fromDelta(request.delta, .{ .not_saved_error = "the output could not be read" }),
        .empty, .reader => {},
    }
    const path = request.folder_path orelse
        return fromDelta(request.delta, .{ .not_saved_error = "the results folder is not available" });
    var folder = result_files.ResultFolder.initWithLimits(request.alloc, path, request.limits) catch |err| {
        debug_trace.logf("bash", "result not saved: results folder not opened err={s}", .{@errorName(err)});
        return fromDelta(request.delta, .{ .not_saved_error = "the results folder could not be opened" });
    };
    defer folder.deinit();
    var number = folder.nextNumber() catch |err| {
        debug_trace.logf("bash", "result not saved: results folder not read err={s}", .{@errorName(err)});
        return fromDelta(request.delta, .{ .not_saved_error = "the results folder could not be read" });
    };

    var keep = try Keep.init(request.alloc, request.keep_bytes);
    var replay_source: ?ReplayReader = null;
    defer if (replay_source) |*adapter| adapter.deinit();
    var empty_source = std.Io.Reader.fixed("");
    const source: *std.Io.Reader = switch (request.replay) {
        .reader => |reader| blk: {
            replay_source = ReplayReader.init(request.alloc, reader, &keep);
            break :blk &replay_source.?.interface;
        },
        else => &empty_source,
    };
    var captured = folder.capture(source) catch |err| {
        keep.deinit();
        if (replay_source) |adapter| {
            if (adapter.failure) |cause| {
                debug_trace.logf("bash", "result not saved: output not read err={s}", .{@errorName(cause)});
                return fromDelta(request.delta, .{ .not_saved_error = "the output could not be read" });
            }
        }
        debug_trace.logf("bash", "result not saved: results folder not written n={d} err={s}", .{ number, @errorName(err) });
        return fromDelta(request.delta, .{ .not_saved_error = "the results folder could not be written" });
    };
    defer captured.deinit(request.alloc);

    // A number another writer takes after nextNumber is picked again, once, with the same output.
    if (request.after_number) |hook| hook(&folder, number);
    const outcome = folder.publish(number, &captured) catch |err| switch (err) {
        error.NumberTaken => taken: {
            debug_trace.logf("bash", "result number taken, picking again n={d}", .{number});
            number = folder.nextNumber() catch |again| {
                keep.deinit();
                debug_trace.logf("bash", "result not saved: results folder not read err={s}", .{@errorName(again)});
                return fromDelta(request.delta, .{ .not_saved_error = "the results folder could not be read" });
            };
            if (request.after_number) |hook| hook(&folder, number);
            break :taken folder.publish(number, &captured) catch |again| switch (again) {
                error.NumberTaken => {
                    keep.deinit();
                    debug_trace.logf("bash", "result not saved: number taken twice n={d}", .{number});
                    return fromDelta(request.delta, .{ .not_saved_error = "the result number was taken twice" });
                },
                else => {
                    keep.deinit();
                    debug_trace.logf("bash", "result not saved: results folder not written n={d} err={s}", .{ number, @errorName(again) });
                    return fromDelta(request.delta, .{ .not_saved_error = "the results folder could not be written" });
                },
            };
        },
        else => {
            keep.deinit();
            debug_trace.logf("bash", "result not saved: results folder not written n={d} err={s}", .{ number, @errorName(err) });
            return fromDelta(request.delta, .{ .not_saved_error = "the results folder could not be written" });
        },
    };
    switch (outcome) {
        .full => |full| {
            debug_trace.logf("bash", "result not saved: results folder full used={d} needed={d}", .{ full.used_bytes, full.needed_bytes });
            return whole(keep, .not_saved_full);
        },
        .saved => |written| {
            const saved: bash_results.Saved = if (written.cut_bytes > 0)
                .{ .file_cut = .{ .number = number, .kept_each_bytes = folder.limits.max_file_bytes / 2 } }
            else
                .{ .file = number };
            var index_missing = false;
            folder.appendIndex(.{
                .n = number,
                .exit = request.exit,
                .bytes = keep.stats.bytes,
                .lines = keep.stats.lines(),
                .command = request.command,
            }) catch |err| {
                index_missing = true;
                debug_trace.logf("bash", "result index row not written n={d} err={s}", .{ number, @errorName(err) });
            };
            var output = whole(keep, saved);
            output.index_missing = index_missing;
            return output;
        },
    }
}

fn whole(keep: Keep, saved: bash_results.Saved) Output {
    var owned = keep;
    return .{
        .saved = saved,
        .stats = owned.stats,
        .head = owned.head(),
        .tail = owned.tail(),
        .keep = owned,
    };
}

fn fromDelta(delta: []const u8, saved: bash_results.Saved) Output {
    var stats: bash_results.Stats = .{};
    stats.feed(delta);
    return .{ .saved = saved, .stats = stats, .head = delta, .tail = delta, .keep = null };
}

const FolderBed = struct {
    tmp: std.testing.TmpDir,
    /// The results folder's path, which does not exist yet.
    path: [:0]u8,

    fn init(alloc: Allocator) !FolderBed {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
        defer alloc.free(root);
        const path = try alloc.printSentinel("{s}/results", .{root}, 0);
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *FolderBed, alloc: Allocator) void {
        alloc.free(self.path);
        self.tmp.cleanup();
    }

    fn read(self: *FolderBed, alloc: Allocator, name: []const u8) ![]u8 {
        var dir = try self.tmp.dir.openDir(std.testing.io, "results", .{});
        defer dir.close(std.testing.io);
        return dir.readFileAlloc(std.testing.io, name, alloc, .limited(1 << 20));
    }
};

fn requestFor(alloc: Allocator, path: ?[]const u8, replay: Replay, delta: []const u8) Request {
    return .{
        .alloc = alloc,
        .folder_path = path,
        .limits = .{},
        .keep_bytes = keep_min_bytes,
        .command = "true",
        .exit = .{ .code = 0 },
        .replay = replay,
        .delta = delta,
    };
}

fn expectFile(saved: bash_results.Saved, want: u64) !void {
    switch (saved) {
        .file => |number| try std.testing.expectEqual(want, number),
        else => return error.TestUnexpectedSaved,
    }
}

fn expectNotSavedError(saved: bash_results.Saved, want: []const u8) !void {
    switch (saved) {
        .not_saved_error => |reason| try std.testing.expectEqualStrings(want, reason),
        else => return error.TestUnexpectedSaved,
    }
}

test "keep holds the first and last bytes, and the same counts however the bytes are split" {
    const alloc = std.testing.allocator;
    var text: std.Io.Writer.Allocating = .init(alloc);
    defer text.deinit();
    for (0..30_000) |number| try text.writer.print("{d}\n", .{number});
    const bytes = text.written();

    var whole_keep = try Keep.init(alloc, 1024);
    defer whole_keep.deinit();
    whole_keep.feed(bytes);

    var split_keep = try Keep.init(alloc, 1024);
    defer split_keep.deinit();
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 7) split_keep.feed(bytes[offset..@min(bytes.len, offset + 7)]);

    try std.testing.expectEqualStrings(bytes[0..1024], split_keep.head());
    try std.testing.expectEqualStrings(bytes[bytes.len - 1024 ..], split_keep.tail());
    try std.testing.expectEqualStrings(whole_keep.head(), split_keep.head());
    try std.testing.expectEqualStrings(whole_keep.tail(), split_keep.tail());
    try std.testing.expectEqual(whole_keep.stats.bytes, split_keep.stats.bytes);
    try std.testing.expectEqual(whole_keep.stats.lines(), split_keep.stats.lines());
    try std.testing.expectEqual(@as(u64, 30_000), split_keep.stats.lines());
}

test "a short output keeps all of itself as its head and as its tail" {
    const alloc = std.testing.allocator;
    var keep = try Keep.init(alloc, 64);
    defer keep.deinit();
    keep.feed("abc\n");
    keep.feed("de");
    try std.testing.expectEqualStrings("abc\nde", keep.head());
    try std.testing.expectEqualStrings("abc\nde", keep.tail());
}

test "an empty output is saved as an empty file, with its index row" {
    const alloc = std.testing.allocator;
    var bed: FolderBed = try .init(alloc);
    defer bed.deinit(alloc);
    var output = try save(requestFor(alloc, bed.path, .empty, ""));
    defer output.deinit();
    try expectFile(output.saved, 1);
    try std.testing.expectEqual(@as(u64, 0), output.stats.bytes);
    const row = try bed.read(alloc, "index.tsv");
    defer alloc.free(row);
    try std.testing.expectEqualStrings("n\texit\tbytes\tlines\tcommand\n1\t0\t0\t0\ttrue\n", row);
    const empty = try bed.read(alloc, "1.txt");
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "a program whose output was not kept says so, and its text is the output fx has" {
    const alloc = std.testing.allocator;
    var bed: FolderBed = try .init(alloc);
    defer bed.deinit(alloc);
    var output = try save(requestFor(alloc, bed.path, .missing, "hello\n"));
    defer output.deinit();
    try expectNotSavedError(output.saved, "the output was not kept");
    try std.testing.expectEqual(@as(u64, 6), output.stats.bytes);
    try std.testing.expectEqualStrings("hello\n", output.head);
    try std.testing.expectEqualStrings("hello\n", output.tail);
    try std.testing.expect(output.keep == null);
    try std.testing.expectError(error.FileNotFound, bed.tmp.dir.access(std.testing.io, "results", .{}));
}

test "a capture that cannot be opened says so, and its text is the output fx has" {
    const alloc = std.testing.allocator;
    var bed: FolderBed = try .init(alloc);
    defer bed.deinit(alloc);
    var output = try save(requestFor(alloc, bed.path, .unreadable, "tail only\n"));
    defer output.deinit();
    try expectNotSavedError(output.saved, "the output could not be read");
    try std.testing.expectEqualStrings("tail only\n", output.head);
}

test "a results folder that cannot be opened is not saved, and the output is still shown" {
    const alloc = std.testing.allocator;
    var output = try save(requestFor(alloc, "/nonexistent-fx-bash-results/results", .empty, "shown\n"));
    defer output.deinit();
    try expectNotSavedError(output.saved, "the results folder could not be opened");
    try std.testing.expectEqualStrings("shown\n", output.head);
}

test "a program with no results folder is not saved" {
    const alloc = std.testing.allocator;
    var output = try save(requestFor(alloc, null, .empty, "x"));
    defer output.deinit();
    try expectNotSavedError(output.saved, "the results folder is not available");
}

test "a saved file whose index line cannot be written is kept, and the output says so" {
    const alloc = std.testing.allocator;
    var bed: FolderBed = try .init(alloc);
    defer bed.deinit(alloc);
    try std.Io.Dir.cwd().createDir(std.testing.io, bed.path, .fromMode(0o700));
    {
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, bed.path, .{});
        defer dir.close(std.testing.io);
        try dir.writeFile(std.testing.io, .{ .sub_path = "index.tsv", .data = "n\texit\tbytes\tlines\tcommand\n" });
        // A second name gives index.tsv two links, which the folder refuses to rewrite.
        try std.Io.Dir.hardLink(dir, "index.tsv", dir, "index-link", std.testing.io, .{});
    }
    var output = try save(requestFor(alloc, bed.path, .empty, ""));
    defer output.deinit();
    try expectFile(output.saved, 1);
    try std.testing.expect(output.index_missing);
    const file = try bed.read(alloc, "1.txt");
    defer alloc.free(file);
    try std.testing.expectEqualStrings("", file);
    const index = try bed.read(alloc, "index.tsv");
    defer alloc.free(index);
    try std.testing.expectEqualStrings("n\texit\tbytes\tlines\tcommand\n", index);
}

/// Lets another writer take number 1, as a program writing `1.txt` itself would.
fn takeFirstNumber(folder: *result_files.ResultFolder, number: u64) void {
    if (number != 1) return;
    folder.dir.dir.writeFile(std.testing.io, .{
        .sub_path = "1.txt",
        .data = "written by the program\n",
        .flags = .{ .permissions = .fromMode(0o600) },
    }) catch unreachable;
}

/// Lets another writer take every number, so the retry is refused too.
fn takeEveryNumber(folder: *result_files.ResultFolder, number: u64) void {
    var buf: [32]u8 = undefined;
    const name = std.mem.print(&buf, "{d}.txt", .{number}) catch unreachable;
    folder.dir.dir.writeFile(std.testing.io, .{
        .sub_path = name,
        .data = "written by the program\n",
        .flags = .{ .permissions = .fromMode(0o600) },
    }) catch unreachable;
}

test "a number another writer takes before the file is published is kept, and the result is saved as the next number" {
    const alloc = std.testing.allocator;
    var bed: FolderBed = try .init(alloc);
    defer bed.deinit(alloc);
    var request = requestFor(alloc, bed.path, .empty, "");
    request.after_number = takeFirstNumber;
    var output = try save(request);
    defer output.deinit();
    try expectFile(output.saved, 2);
    const kept = try bed.read(alloc, "1.txt");
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("written by the program\n", kept);
    const index = try bed.read(alloc, "index.tsv");
    defer alloc.free(index);
    try std.testing.expectEqualStrings("n\texit\tbytes\tlines\tcommand\n2\t0\t0\t0\ttrue\n", index);
}

test "a number taken again on the retry is not saved, with a short reason, and both files are kept" {
    const alloc = std.testing.allocator;
    var bed: FolderBed = try .init(alloc);
    defer bed.deinit(alloc);
    var request = requestFor(alloc, bed.path, .empty, "");
    request.after_number = takeEveryNumber;
    var output = try save(request);
    defer output.deinit();
    try expectNotSavedError(output.saved, "the result number was taken twice");
    for ([_][]const u8{ "1.txt", "2.txt" }) |name| {
        const kept = try bed.read(alloc, name);
        defer alloc.free(kept);
        try std.testing.expectEqualStrings("written by the program\n", kept);
    }
    try std.testing.expectError(error.FileNotFound, bed.tmp.dir.access(std.testing.io, "results/index.tsv", .{}));
}

test "a saved file holds every frame of the replay, in order, whatever their sizes" {
    const alloc = std.testing.allocator;
    var bed: FolderBed = try .init(alloc);
    defer bed.deinit(alloc);
    const store_path = try bed.tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(store_path);
    var store = command_replay_store.EphemeralStore.initForTesting(alloc, store_path);
    defer store.deinit();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const capture = try command_replay_store.Capture.createEphemeral(arena, 0, &store);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(alloc);
    for ([_]usize{ 1, 4096, 70_000, 3, 200_000 }) |size| {
        const frame = try arena.alloc(u8, size);
        const fill: u8 = @intCast('a' + size % 26);
        @memset(frame, fill);
        try capture.appendAcceptedRequired(arena, .stdout, frame);
        try expected.appendSlice(alloc, frame);
    }
    const descriptor = (try capture.retainRequired(arena)) orelse return error.TestExpectedReplay;
    var replay = try command_replay_store.Reader.openEphemeralHandle(alloc, &store, descriptor.handle);
    defer replay.deinit();
    var output = try save(requestFor(alloc, bed.path, .{ .reader = &replay }, ""));
    defer output.deinit();
    try expectFile(output.saved, 1);
    try std.testing.expectEqual(@as(u64, expected.items.len), output.stats.bytes);
    const file = try bed.read(alloc, "1.txt");
    defer alloc.free(file);
    try std.testing.expectEqualSlices(u8, expected.items, file);
}
