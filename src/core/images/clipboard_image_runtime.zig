const std = @import("std");
const builtin = @import("builtin");
const image_attachments = @import("image_attachments.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const StartOutcome = enum {
    started,
    already_running,
    unsupported,
};

pub const Completion = union(enum) {
    loaded: image_attachments.ClipboardImageAttachment,
    no_image,
    failed: anyerror,

    pub fn deinit(self: *Completion, alloc: Allocator) void {
        switch (self.*) {
            .loaded => |*loaded| loaded.deinit(alloc),
            .no_image, .failed => {},
        }
        self.* = undefined;
    }
};

pub const Loader = struct {
    ctx: ?*anyopaque = null,
    load: *const fn (
        ?*anyopaque,
        Allocator,
        *std.atomic.Value(bool),
    ) anyerror!image_attachments.ClipboardImageAttachment,
};

const State = enum {
    idle,
    loading,
    complete,
};

pub const Runtime = struct {
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    state: State = .idle,
    completion: ?Completion = null,
    cancel_requested: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *Runtime, alloc: Allocator) !StartOutcome {
        if (comptime builtin.os.tag != .macos) return .unsupported;
        return self.startWithLoader(alloc, .{ .load = loadClipboardImage });
    }

    pub fn startWithLoader(
        self: *Runtime,
        alloc: Allocator,
        loader: Loader,
    ) !StartOutcome {
        self.finishThreadIfDone();

        self.mutex.lockUncancelable(io_mod.getIo());
        if (self.state != .idle) {
            self.mutex.unlock(io_mod.getIo());
            return .already_running;
        }
        self.state = .loading;
        self.mutex.unlock(io_mod.getIo());
        self.cancel_requested.store(false, .release);

        self.thread = std.Thread.spawn(
            .{},
            loadThreadMain,
            .{ self, alloc, loader },
        ) catch |err| {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.state = .idle;
            self.mutex.unlock(io_mod.getIo());
            return err;
        };
        return .started;
    }

    pub fn takeCompletion(self: *Runtime) ?Completion {
        self.finishThreadIfDone();

        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.state != .complete) return null;

        const completion = self.completion orelse unreachable;
        self.completion = null;
        self.state = .idle;
        return completion;
    }

    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        self.cancel_requested.store(true, .release);
        if (self.thread) |thread| {
            self.thread = null;
            thread.join();
        }

        self.mutex.lockUncancelable(io_mod.getIo());
        const completion = self.completion;
        self.completion = null;
        self.state = .idle;
        self.mutex.unlock(io_mod.getIo());

        if (completion) |value| {
            var owned = value;
            owned.deinit(alloc);
        }
        self.* = .{};
    }

    fn loadThreadMain(
        self: *Runtime,
        alloc: Allocator,
        loader: Loader,
    ) void {
        const completion: Completion = if (loader.load(
            loader.ctx,
            alloc,
            &self.cancel_requested,
        )) |loaded|
            .{ .loaded = loaded }
        else |err| switch (err) {
            error.NoClipboardImage => .no_image,
            else => .{ .failed = err },
        };

        self.mutex.lockUncancelable(io_mod.getIo());
        self.completion = completion;
        self.state = .complete;
        self.mutex.unlock(io_mod.getIo());
    }

    fn finishThreadIfDone(self: *Runtime) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        const should_join = self.state == .complete and self.thread != null;
        const thread = if (should_join) self.thread.? else null;
        if (should_join) self.thread = null;
        self.mutex.unlock(io_mod.getIo());
        if (thread) |handle| handle.join();
    }
};

fn loadClipboardImage(
    _: ?*anyopaque,
    alloc: Allocator,
    cancel_requested: *std.atomic.Value(bool),
) !image_attachments.ClipboardImageAttachment {
    return image_attachments.loadClipboardImageAttachmentWithBudget(
        alloc,
        .{ .cancel_flag = cancel_requested },
    );
}

const BlockingLoader = struct {
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),

    fn load(
        ctx: ?*anyopaque,
        _: Allocator,
        cancel_requested: *std.atomic.Value(bool),
    ) !image_attachments.ClipboardImageAttachment {
        const self: *BlockingLoader = @ptrCast(@alignCast(ctx.?));
        self.entered.store(true, .release);
        while (!self.release.load(.acquire)) {
            if (cancel_requested.load(.acquire)) {
                self.cancelled.store(true, .release);
                return error.Cancelled;
            }
            io_mod.sleep(std.time.ns_per_ms);
        }
        return error.NoClipboardImage;
    }
};

fn waitForFlag(flag: *const std.atomic.Value(bool)) !void {
    var remaining_ms: usize = 5_000;
    while (!flag.load(.acquire) and remaining_ms > 0) : (remaining_ms -= 1) {
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(flag.load(.acquire));
}

test "clipboard image load runs in the background and rejects duplicate starts" {
    var runtime: Runtime = .{};
    defer runtime.deinit(std.testing.allocator);
    var loader: BlockingLoader = .{};
    const deps: Loader = .{ .ctx = &loader, .load = BlockingLoader.load };

    try std.testing.expectEqual(
        StartOutcome.started,
        try runtime.startWithLoader(std.testing.allocator, deps),
    );
    try waitForFlag(&loader.entered);
    try std.testing.expect(runtime.takeCompletion() == null);
    try std.testing.expectEqual(
        StartOutcome.already_running,
        try runtime.startWithLoader(std.testing.allocator, deps),
    );

    loader.release.store(true, .release);
    var completion: ?Completion = null;
    var remaining_ms: usize = 5_000;
    while (completion == null and remaining_ms > 0) : (remaining_ms -= 1) {
        completion = runtime.takeCompletion();
        if (completion == null) io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(completion != null);
    var owned = completion.?;
    defer owned.deinit(std.testing.allocator);
    try std.testing.expect(owned == .no_image);
}

test "clipboard image runtime cancels and joins its loader" {
    var runtime: Runtime = .{};
    var loader: BlockingLoader = .{};

    try std.testing.expectEqual(
        StartOutcome.started,
        try runtime.startWithLoader(std.testing.allocator, .{
            .ctx = &loader,
            .load = BlockingLoader.load,
        }),
    );
    try waitForFlag(&loader.entered);

    runtime.deinit(std.testing.allocator);
    try std.testing.expect(loader.cancelled.load(.acquire));
}
